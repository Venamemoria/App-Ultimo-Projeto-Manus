import { useQuery } from '@tanstack/react-query';
import { supabase, supabaseConfigError } from '../../lib/supabase';
import { localDateToday } from '../../lib/decimal';

export type FinanceGrouping = 'day' | 'month';
export interface FinancePeriodFilter { from: string; to: string; grouping: FinanceGrouping }
export interface FinanceSummary {
  currency: 'BRL';
  period: FinancePeriodFilter;
  realized: {
    received: string;
    paid: string;
    net: string;
    paymentMethods: Array<{ method: string; amount: string }>;
  };
  estimate: { receivable: string; payable: string; projectedNet: string; isEstimate: true };
  series: Array<{ period: string; received: string; paid: string }>;
  dueDatesAvailable: false;
}

const moneyPattern = /^-?(?:0|[1-9]\d*)(?:\.\d{1,2})?$/;
const civilDatePattern = /^(\d{4})-(\d{2})-(\d{2})$/;

export function financeDateRangeError(from: string, to: string): string | null {
  const startMatch = civilDatePattern.exec(from);
  const endMatch = civilDatePattern.exec(to);
  if (!startMatch || !endMatch) return 'Informe uma data inicial e uma data final válidas.';
  const start = Date.parse(`${from}T00:00:00.000Z`);
  const end = Date.parse(`${to}T00:00:00.000Z`);
  if (!Number.isFinite(start) || !Number.isFinite(end)
    || new Date(start).toISOString().slice(0, 10) !== from
    || new Date(end).toISOString().slice(0, 10) !== to) {
    return 'Informe datas de calendário válidas.';
  }
  if (start > end) return 'A data inicial precisa ser anterior ou igual à final.';
  if ((end - start) / 86_400_000 > 366) return 'O período pode ter no máximo 367 dias.';
  return null;
}

export function defaultFinancePeriod(today = localDateToday()): FinancePeriodFilter {
  return { from: `${today.slice(0, 7)}-01`, to: today, grouping: 'day' };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function isMoney(value: unknown): value is string {
  return typeof value === 'string' && moneyPattern.test(value);
}

function isCivilDate(value: unknown): value is string {
  if (typeof value !== 'string' || !civilDatePattern.test(value)) return false;
  const time = Date.parse(`${value}T00:00:00.000Z`);
  return Number.isFinite(time) && new Date(time).toISOString().slice(0, 10) === value;
}

export function isFinanceSummary(value: unknown, expected: FinancePeriodFilter): value is FinanceSummary {
  if (!isRecord(value) || value.currency !== 'BRL' || value.dueDatesAvailable !== false) return false;
  if (!isRecord(value.period) || value.period.from !== expected.from || value.period.to !== expected.to || value.period.grouping !== expected.grouping) return false;
  if (!isRecord(value.realized) || !isMoney(value.realized.received) || !isMoney(value.realized.paid) || !isMoney(value.realized.net)) return false;
  if (!Array.isArray(value.realized.paymentMethods) || !value.realized.paymentMethods.every((item) =>
    isRecord(item) && typeof item.method === 'string' && item.method.length > 0 && item.method.length <= 40 && isMoney(item.amount))) return false;
  if (!isRecord(value.estimate) || value.estimate.isEstimate !== true
    || !isMoney(value.estimate.receivable) || !isMoney(value.estimate.payable) || !isMoney(value.estimate.projectedNet)) return false;
  if (!Array.isArray(value.series) || value.series.length > 367 || !value.series.every((item) =>
    isRecord(item) && isCivilDate(item.period) && isMoney(item.received) && isMoney(item.paid))) return false;
  return true;
}

function financeError(error: { code?: string; message?: string }, fallback: string): Error {
  if (error.code === '42501') return new Error('Seu papel não permite consultar o financeiro desta organização.');
  if (error.code === '22023') return new Error('Confira as datas e o agrupamento; o intervalo máximo é de 367 dias.');
  return new Error(fallback);
}

export async function fetchFinanceSummary(organizationId: string, filter: FinancePeriodFilter): Promise<FinanceSummary> {
  const rangeError = financeDateRangeError(filter.from, filter.to);
  if (rangeError) throw new Error(rangeError);
  if (filter.grouping !== 'day' && filter.grouping !== 'month') throw new Error('Escolha um agrupamento válido.');
  if (!supabase) throw new Error(supabaseConfigError ?? 'O serviço financeiro está indisponível neste ambiente.');

  const { data, error } = await supabase.rpc('vm_get_finance_summary', {
    p_organization_id: organizationId,
    p_from: filter.from,
    p_to: filter.to,
    p_grouping: filter.grouping,
  });
  if (error) throw financeError(error, 'Não foi possível consultar o resumo financeiro real.');
  if (!isFinanceSummary(data, filter)) throw new Error('A resposta financeira não corresponde ao contrato esperado. Atualize a tela ou tente novamente.');
  return data;
}

export function useFinanceSummaryQuery(organizationId: string | null, filter: FinancePeriodFilter, enabled: boolean) {
  return useQuery({
    queryKey: ['finance-summary', organizationId, filter.from, filter.to, filter.grouping],
    queryFn: () => fetchFinanceSummary(organizationId!, filter),
    enabled: Boolean(organizationId) && enabled,
    staleTime: 30_000,
  });
}
