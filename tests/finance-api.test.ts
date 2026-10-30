import { describe, expect, it } from 'vitest';
import { defaultFinancePeriod, financeDateRangeError, isFinanceSummary } from '../src/features/finance/api';
import type { FinancePeriodFilter } from '../src/features/finance/api';

const period: FinancePeriodFilter = { from: '2026-10-01', to: '2026-10-30', grouping: 'day' };
const validSummary = {
  currency: 'BRL',
  period,
  realized: { received: '25.00', paid: '8.00', net: '17.00', paymentMethods: [{ method: 'pix', amount: '25.00' }] },
  estimate: { receivable: '25.00', payable: '3.00', projectedNet: '39.00', isEstimate: true },
  series: [{ period: '2026-10-29', received: '0.00', paid: '8.00' }, { period: '2026-10-30', received: '25.00', paid: '0.00' }],
  dueDatesAvailable: false,
};

describe('resumo financeiro real', () => {
  it('inicia o filtro no primeiro dia do mês local', () => {
    expect(defaultFinancePeriod('2026-10-30')).toEqual(period);
  });

  it('aceita uma janela inclusiva de até 367 datas', () => {
    expect(financeDateRangeError('2025-10-01', '2026-10-02')).toBeNull();
    expect(financeDateRangeError('2025-10-01', '2026-10-03')).toContain('367 dias');
    expect(financeDateRangeError('2026-10-31', '2026-10-01')).toContain('anterior');
  });

  it('recusa datas civis inexistentes e campos vazios', () => {
    expect(financeDateRangeError('2026-02-30', '2026-03-01')).toContain('válidas');
    expect(financeDateRangeError('', '2026-10-30')).toContain('data inicial');
  });

  it('aceita apenas o contrato agregado que corresponde ao filtro', () => {
    expect(isFinanceSummary(validSummary, period)).toBe(true);
    expect(isFinanceSummary({ ...validSummary, dueDatesAvailable: true }, period)).toBe(false);
    expect(isFinanceSummary({ ...validSummary, period: { ...period, from: '2026-09-01' } }, period)).toBe(false);
    expect(isFinanceSummary({ ...validSummary, realized: { ...validSummary.realized, paid: 'NaN' } }, period)).toBe(false);
    expect(isFinanceSummary({ ...validSummary, series: [{ period: '2026-02-30', received: '1.00', paid: '0.00' }] }, period)).toBe(false);
  });
});
