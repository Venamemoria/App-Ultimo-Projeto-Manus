import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase, supabaseConfigError } from '../../lib/supabase';
import { inventoryQueryKeys } from '../inventory/api';
import { Decimal, STOCK_RESULT_SCALE } from '../../lib/decimal';
import { decimalAtScale, isUuid } from './utils';
import { ordersQueryKeys } from './api';

const PAGE_SIZE = 500;
const MAX_PAGES = 1000;

export interface OrderReturnReadDto {
  return_id: string;
  organization_id: string;
  order_id: string;
  status: string;
  reason: string;
  idempotency_key: string;
  return_line_count: string;
  event_returned_quantity: string;
  created_by: string;
  created_at: string;
  return_line_id: string;
  material_id: string;
  material_name: string;
  unit: string;
  original_consumed_quantity: string;
  returned_quantity: string;
  returned_quantity_total: string;
  remaining_quantity: string;
  stock_movement_id: string;
  stock_after: string;
  current_stock_quantity: string;
  line_created_by: string;
  line_created_at: string;
}

export interface OrderReturnLineInput {
  material_id: string;
  quantity: string;
}

export interface RecordOrderReturnInput {
  organizationId: string;
  orderId: string;
  reason: string;
  returns: OrderReturnLineInput[];
  idempotencyKey: string;
}

export interface RecordOrderReturnResult {
  return_id: string;
  order_id: string;
  status: string;
  line_count: string;
  returned_quantity: string;
  remaining_quantity: string;
}

export const returnsQueryKeys = {
  history: (organizationId: string, orderId: string) => ['orders', 'returns', organizationId, orderId] as const,
};

function getClient() {
  if (!supabase) throw new Error(supabaseConfigError ?? 'O serviço de dados está indisponível neste ambiente.');
  return supabase;
}

function rows<T>(data: unknown): T[] {
  if (Array.isArray(data)) return data as T[];
  if (data && typeof data === 'object') return [data as T];
  return [];
}

function databaseError(error: { code?: string | null } | null, fallback: string): Error {
  if (!error) return new Error(fallback);
  switch (error.code) {
    case '42501': return new Error('Seu papel, sua sessão ou sua organização não autoriza esta operação.');
    case '22023': return new Error('O motivo, estado ou quantidade informada não atende às regras da devolução.');
    case '22003': return new Error('Uma quantidade excede a precisão de oito casas permitida.');
    case '22P02': return new Error('O identificador ou formato informado é inválido.');
    case '23503': return new Error('O pedido ou material não está disponível nesta organização.');
    case '23505': return new Error('Esta chave já foi usada com outra intenção. Mantenha os mesmos dados para repetir a tentativa ou altere a intenção para gerar outra chave.');
    case '23514': return new Error('A devolução não passou nas regras de consumo, saldo ou integridade do estoque.');
    case '55000': return new Error('Esta alteração não é suportada para o histórico imutável.');
    default: return new Error(fallback);
  }
}

export function userFacingOrderReturnError(error: unknown, fallback = 'Não foi possível carregar ou confirmar a devolução física agora.'): string {
  return error instanceof Error && error.message ? error.message : fallback;
}

export async function fetchOrderReturns(organizationId: string, orderId: string): Promise<OrderReturnReadDto[]> {
  if (!isUuid(organizationId) || !isUuid(orderId)) throw new Error('Identificador de devolução inválido; nenhuma consulta foi enviada.');

  const result: OrderReturnReadDto[] = [];
  let cursor: string | null = null;
  for (let page = 0; page < MAX_PAGES; page += 1) {
    let query = getClient().from('vm_order_returns_read').select('*', { count: 'exact' })
      .eq('organization_id', organizationId)
      .eq('order_id', orderId)
      .order('return_line_id', { ascending: true })
      .limit(PAGE_SIZE);
    if (cursor) query = query.gt('return_line_id', cursor);

    const { data, error, count } = await query;
    if (error) throw databaseError(error, 'Não foi possível carregar o histórico de devoluções físicas.');
    if (count === null) throw new Error('O serviço não confirmou a paginação do histórico de devoluções; nenhuma lista parcial foi apresentada.');

    const batch = (data ?? []) as OrderReturnReadDto[];
    result.push(...batch);
    if (!batch.length || result.length >= count) return result;

    const nextCursor = batch[batch.length - 1]?.return_line_id;
    if (!isUuid(nextCursor) || nextCursor === cursor) throw new Error('A paginação do histórico de devoluções retornou um cursor inválido; nenhuma lista parcial foi apresentada.');
    cursor = nextCursor;
  }

  throw new Error('O histórico de devoluções excede o limite seguro; nenhuma lista parcial foi apresentada.');
}

export function orderReturnRpcParams(input: RecordOrderReturnInput): Record<string, unknown> {
  if (!isUuid(input.organizationId) || !isUuid(input.orderId) || !isUuid(input.idempotencyKey)) {
    throw new Error('Identificador inválido; a devolução não foi enviada.');
  }
  const reason = input.reason.trim();
  if (!reason || reason.length > 2000) throw new Error('Informe um motivo com até 2000 caracteres.');
  if (!input.returns.length || input.returns.length > 200) throw new Error('Selecione ao menos um material para devolver.');

  const seen = new Set<string>();
  const returns = input.returns.map((line) => {
    if (!isUuid(line.material_id)) throw new Error('O material selecionado é inválido.');
    if (seen.has(line.material_id)) throw new Error('Cada material deve aparecer uma única vez na devolução.');
    seen.add(line.material_id);
    return {
      material_id: line.material_id,
      quantity: decimalAtScale(line.quantity, STOCK_RESULT_SCALE, true, 'Quantidade devolvida'),
    };
  });

  return {
    p_organization_id: input.organizationId,
    p_order_id: input.orderId,
    p_reason: reason,
    p_returns: returns,
    p_idempotency_key: input.idempotencyKey,
  };
}

async function callRpc<T>(name: string, params: Record<string, unknown>, fallback: string): Promise<T> {
  const { data, error } = await getClient().rpc(name, params);
  if (error) throw databaseError(error, fallback);
  const value = rows<T>(data)[0];
  if (!value) throw new Error(fallback);
  return value;
}

export async function recordOrderReturn(input: RecordOrderReturnInput): Promise<RecordOrderReturnResult> {
  return callRpc<RecordOrderReturnResult>(
    'vm_record_order_return',
    orderReturnRpcParams(input),
    'Não foi possível confirmar a devolução física. O servidor pode ter confirmado; repita a mesma tentativa sem mudar os dados para verificar o resultado.',
  );
}

export function useOrderReturnsQuery(organizationId: string | null, orderId: string | null, enabled = true) {
  const valid = Boolean(organizationId && orderId && isUuid(orderId));
  return useQuery({
    queryKey: valid ? returnsQueryKeys.history(organizationId!, orderId!) : ['orders', 'returns', 'invalid'],
    queryFn: () => fetchOrderReturns(organizationId!, orderId!),
    enabled: valid && enabled,
  });
}

export function useRecordOrderReturnMutation(organizationId: string | null, orderId: string | null) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: recordOrderReturn,
    onSuccess: async () => {
      if (!organizationId) return;
      await Promise.all([
        orderId ? queryClient.invalidateQueries({ queryKey: ordersQueryKeys.detail(organizationId, orderId) }) : Promise.resolve(),
        orderId ? queryClient.invalidateQueries({ queryKey: returnsQueryKeys.history(organizationId, orderId) }) : Promise.resolve(),
        queryClient.invalidateQueries({ queryKey: inventoryQueryKeys.materials(organizationId) }),
        queryClient.invalidateQueries({ queryKey: inventoryQueryKeys.movements(organizationId) }),
      ]);
    },
  });
}

export function decimalQuantity(value: string): Decimal {
  try {
    const decimal = new Decimal(value);
    if (!decimal.isFinite() || decimal.decimalPlaces() > STOCK_RESULT_SCALE) throw new Error('invalid');
    return decimal;
  } catch {
    throw new Error('O histórico de devoluções retornou uma quantidade inválida.');
  }
}
