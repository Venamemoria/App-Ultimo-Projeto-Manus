import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase, supabaseConfigError } from '../../lib/supabase';
import { fetchContacts } from '../contacts/api';
import { invalidateAfterOrderMutation, ordersQueryKeys } from './cache';
export { ordersQueryKeys } from './cache';
import type { ClientDto } from '../contacts/types';
import { fetchProductDetail, fetchProducts } from '../products/api';
import type {
  CreateOrderInput,
  CreateOrderResult,
  OrderBundle,
  OrderConsumptionDto,
  OrderCreateItem,
  OrderDto,
  OrderEventDto,
  OrderInitialStatus,
  OrderItemDto,
  OrderListFilters,
  OrderPaymentDto,
  OrdersPage,
  RecordOrderPaymentInput,
  RecordOrderPaymentResult,
  ResponsibleMembership,
  SetOrderStatusInput,
  SetOrderStatusResult,
} from './types';
import { decimalAtScale, isUuid, moneyAtTwoDecimals } from './utils';

const PAGE_SIZE = 40;
const MAX_PAGES = 1000;

function client() {
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
    case 'VM002': return new Error('A classificação sem estoque está inconsistente com a composição. Solicite a revisão ou recriação do pedido.');
    case 'VM001': return new Error('Produto sem composição de insumos. Cadastre a receita antes de criar pedidos ou orçamentos; pedidos antigos precisam ser revisados ou recriados com composição.');
    case '42501': return new Error('Seu papel, sua sessão ou sua organização não autoriza esta operação.');
    case '22023': return new Error('O pedido contém um campo, status, data ou regra inválida.');
    case '22003': return new Error('Um decimal excede a precisão permitida. Revise quantidades e valores sem alterar a tentativa pendente.');
    case '22P02': return new Error('O identificador ou formato informado é inválido.');
    case '23503': return new Error('O registro informado não está disponível nesta organização.');
    case '23505': return new Error('Esta tentativa já foi usada com outra intenção ou já foi registrada. Mantenha os mesmos dados ao tentar novamente.');
    case '23514': return new Error('A operação não passou nas regras de saldo, estoque ou integridade do pedido.');
    case '55000': return new Error('Esta alteração não é suportada para o histórico imutável do pedido.');
    default: return new Error(fallback);
  }
}

export function userFacingOrderError(error: unknown, fallback = 'Não foi possível concluir esta ação agora.'): string {
  return error instanceof Error && error.message ? error.message : fallback;
}

function safeSearch(value: string): string {
  return value.replace(/[^\p{L}\p{N}\s@_-]/gu, ' ').replace(/\s+/g, ' ').trim().slice(0, 100);
}

async function findProductOrderIds(organizationId: string, term: string): Promise<string[]> {
  const cleaned = safeSearch(term);
  if (!cleaned) return [];
  const query = client().from('vm_order_items_read').select('order_id', { count: 'exact' })
    .eq('organization_id', organizationId).ilike('title', `%${cleaned}%`).order('order_id', { ascending: true }).limit(1000);
  const { data, error, count } = await query;
  if (error) throw databaseError(error, 'Não foi possível aplicar o filtro de produto nos pedidos.');
  if (count !== null && count > (data?.length ?? 0)) throw new Error('O filtro de produto excede o limite seguro; restrinja o texto antes de tentar novamente.');
  return Array.from(new Set(((data ?? []) as Array<{ order_id: string }>).map((row) => row.order_id).filter(isUuid)));
}

export async function fetchOrdersPage(organizationId: string, filters: OrderListFilters, cursor: string | null = null): Promise<OrdersPage> {
  if (!isUuid(organizationId)) throw new Error('Organização inválida; nenhuma consulta foi enviada.');
  const productIds = filters.product.trim() ? await findProductOrderIds(organizationId, filters.product) : null;
  if (productIds && productIds.length === 0) return { rows: [], remaining: 0, total: 0, cursor };

  let query = client().from('vm_orders_read').select('*', { count: 'exact' })
    .eq('organization_id', organizationId).order('id', { ascending: true }).limit(PAGE_SIZE);
  if (cursor) query = query.gt('id', cursor);
  if (filters.status !== 'all') query = query.eq('status', filters.status);
  if (filters.from) query = query.gte('order_date', filters.from);
  if (filters.to) query = query.lte('order_date', filters.to);
  const search = safeSearch(filters.search);
  if (search) query = query.or(`code.ilike.%${search}%,client_name.ilike.%${search}%,title.ilike.%${search}%`);
  if (productIds) query = query.in('id', productIds);

  const { data, error, count } = await query;
  if (error) throw databaseError(error, 'Não foi possível carregar os pedidos.');
  const batch = (data ?? []) as OrderDto[];
  if (count === null) throw new Error('O serviço não confirmou a paginação; nenhuma lista parcial de pedidos foi apresentada.');
  const remaining = Math.max(0, count - batch.length);
  const nextCursor = batch.length ? batch[batch.length - 1].id : cursor;
  return { rows: batch, remaining, total: count, cursor: nextCursor };
}

export async function fetchAllOrders(organizationId: string, filters: OrderListFilters = { search: '', status: 'all', from: '', to: '', product: '' }): Promise<OrderDto[]> {
  const result: OrderDto[] = [];
  let cursor: string | null = null;
  for (let page = 0; page < MAX_PAGES; page += 1) {
    const current = await fetchOrdersPage(organizationId, filters, cursor);
    result.push(...current.rows);
    if (!current.rows.length || current.remaining === 0) return result;
    if (!current.cursor || current.cursor === cursor) throw new Error('A paginação de pedidos retornou um cursor inválido; nenhuma lista parcial foi apresentada.');
    cursor = current.cursor;
  }
  throw new Error('A consulta ultrapassou o limite seguro. Restrinja os filtros antes de carregar todos os pedidos.');
}

async function fetchOrderRows<T extends { id?: string; material_id?: string; event_id?: string }>(table: string, organizationId: string, orderId: string, fallback: string, orderColumn = 'id'): Promise<T[]> {
  const result: T[] = [];
  let cursor: string | null = null;
  for (let page = 0; page < MAX_PAGES; page += 1) {
    let query = client().from(table).select('*', { count: 'exact' }).eq('organization_id', organizationId).eq('order_id', orderId).order(orderColumn, { ascending: true }).limit(500);
    if (cursor) query = query.gt(orderColumn, cursor);
    const { data, error, count } = await query;
    if (error) throw databaseError(error, fallback);
    const batch = (data ?? []) as T[];
    result.push(...batch);
    if (count === null) throw new Error(`${fallback} O serviço não confirmou a paginação; nenhuma lista parcial foi apresentada.`);
    if (!batch.length || batch.length >= count) return result;
    const last = batch[batch.length - 1] as T & Record<string, unknown>;
    const next = last[orderColumn];
    if (typeof next !== 'string' || next === cursor) throw new Error(`${fallback} A paginação retornou um cursor inválido.`);
    cursor = next;
  }
  throw new Error(`${fallback} O histórico excede o limite seguro; nenhuma lista parcial foi apresentada.`);
}

export async function fetchOrderBundle(organizationId: string, orderId: string, includePayments: boolean): Promise<OrderBundle> {
  if (!isUuid(organizationId) || !isUuid(orderId)) throw new Error('Identificador de pedido inválido; nenhuma consulta foi enviada.');
  const orderResult = await client().from('vm_orders_read').select('*').eq('organization_id', organizationId).eq('id', orderId).maybeSingle();
  if (orderResult.error) throw databaseError(orderResult.error, 'Não foi possível carregar o pedido.');
  if (!orderResult.data) throw new Error('Pedido não encontrado nesta organização.');
  const [items, events, consumptions, payments] = await Promise.all([
    fetchOrderRows<OrderItemDto>('vm_order_items_read', organizationId, orderId, 'Não foi possível carregar os itens congelados.', 'id'),
    fetchOrderRows<OrderEventDto>('vm_order_events', organizationId, orderId, 'Não foi possível carregar o histórico do pedido.', 'id'),
    fetchOrderRows<OrderConsumptionDto>('vm_order_consumptions_read', organizationId, orderId, 'Não foi possível carregar o consumo real.', 'material_id'),
    includePayments ? fetchOrderRows<OrderPaymentDto>('vm_order_payments_read', organizationId, orderId, 'Não foi possível carregar os pagamentos reais.', 'id') : Promise.resolve([]),
  ]);
  return {
    order: orderResult.data as OrderDto,
    items,
    events: events.sort((left, right) => left.status_version.localeCompare(right.status_version, undefined, { numeric: true })),
    consumptions,
    payments,
  };
}

export async function fetchOrderCatalog(organizationId: string): Promise<{ clients: ClientDto[]; products: Awaited<ReturnType<typeof fetchProducts>>; memberships: ResponsibleMembership[] }> {
  const [rawClients, products, membershipsResult] = await Promise.all([
    fetchContacts('client', organizationId),
    fetchProducts(organizationId),
    client().from('vm_memberships').select('id, organization_id, user_id, role, created_at').eq('organization_id', organizationId).order('created_at', { ascending: true }),
  ]);
  if (membershipsResult.error) throw databaseError(membershipsResult.error, 'Não foi possível carregar os responsáveis desta organização.');
  const clients = rawClients.filter((contact): contact is ClientDto => contact.archived_at === null);
  return { clients, products, memberships: (membershipsResult.data ?? []) as ResponsibleMembership[] };
}

async function callRpc<T>(name: string, params: Record<string, unknown>, fallback: string): Promise<T> {
  const { data, error } = await client().rpc(name, params);
  if (error) throw databaseError(error, fallback);
  const value = rows<T>(data)[0];
  if (!value) throw new Error(fallback);
  return value;
}

export function orderCreateRpcParams(input: CreateOrderInput): Record<string, unknown> {
  if (!isUuid(input.organizationId)) throw new Error('Organização inválida; o pedido não foi enviado.');
  if (!input.items.length || input.items.length > 200) throw new Error('O pedido precisa ter entre 1 e 200 itens.');
  const data = {
    client_id: input.data.client_id,
    title: input.data.title.trim(),
    order_date: input.data.order_date,
    production_date: input.data.production_date,
    delivery_date: input.data.delivery_date,
    responsible_membership_id: input.data.responsible_membership_id,
    public_notes: input.data.public_notes,
    internal_notes: input.data.internal_notes,
    initial_status: input.data.initial_status,
    discount_type: input.data.discount_type,
    discount_value: input.data.discount_value,
    shipping_amount: input.data.shipping_amount,
  };
  const items: OrderCreateItem[] = input.items.map((item) => ({
    kind: item.kind,
    product_id: item.product_id,
    variant_id: item.variant_id,
    title: item.title,
    quantity: item.quantity,
    unit_price: item.unit_price,
    price_override: item.price_override,
    price_override_reason: item.price_override_reason,
    dimensions: item.dimensions,
    details: item.details,
    personalization: item.personalization,
    production_date: item.production_date,
    delivery_date: item.delivery_date,
  }));
  return { p_organization_id: input.organizationId, p_data: data, p_items: items, p_idempotency_key: input.idempotencyKey };
}

export async function createOrder(input: CreateOrderInput): Promise<CreateOrderResult> {
  return callRpc<CreateOrderResult>('vm_create_order', orderCreateRpcParams(input), 'Não foi possível confirmar o pedido. A tentativa permanece identificada; repita sem mudar os dados para verificar o resultado.');
}

export async function setOrderStatus(input: SetOrderStatusInput): Promise<SetOrderStatusResult> {
  if (!isUuid(input.organizationId) || !isUuid(input.orderId)) throw new Error('Identificador inválido; a alteração não foi enviada.');
  return callRpc<SetOrderStatusResult>('vm_set_order_status', {
    p_organization_id: input.organizationId,
    p_order_id: input.orderId,
    p_status: input.status,
    p_reason: input.reason,
    p_idempotency_key: input.idempotencyKey,
  }, 'Não foi possível confirmar a mudança de etapa. O servidor pode ter confirmado; repita a mesma tentativa para consultar o resultado.');
}

export async function recordOrderPayment(input: RecordOrderPaymentInput): Promise<RecordOrderPaymentResult> {
  if (!isUuid(input.organizationId) || !isUuid(input.orderId)) throw new Error('Identificador inválido; o pagamento não foi enviado.');
  const amount = moneyAtTwoDecimals(input.amount, true, 'Pagamento');
  return callRpc<RecordOrderPaymentResult>('vm_record_order_payment', {
    p_organization_id: input.organizationId,
    p_order_id: input.orderId,
    p_amount: amount,
    p_payment_date: input.paymentDate,
    p_method: input.method,
    p_idempotency_key: input.idempotencyKey,
  }, 'Não foi possível confirmar o recebimento. O servidor pode ter confirmado; repita a mesma tentativa para consultar o resultado.');
}

export function useOrdersPageQuery(organizationId: string | null, filters: OrderListFilters, cursor: string | null) {
  return useQuery({
    queryKey: organizationId ? ordersQueryKeys.page(organizationId, filters, cursor) : ['orders', 'page', 'no-organization'],
    queryFn: () => fetchOrdersPage(organizationId!, filters, cursor),
    enabled: Boolean(organizationId),
  });
}

export function useAllOrdersQuery(organizationId: string | null) {
  return useQuery({
    queryKey: organizationId ? ordersQueryKeys.all(organizationId) : ['orders', 'all', 'no-organization'],
    queryFn: () => fetchAllOrders(organizationId!),
    enabled: Boolean(organizationId),
  });
}

export function useOrderDetailQuery(organizationId: string | null, orderId: string | null, includePayments: boolean) {
  const valid = Boolean(organizationId && orderId && isUuid(orderId));
  return useQuery({
    queryKey: valid ? [...ordersQueryKeys.detail(organizationId!, orderId!), includePayments ? 'financial' : 'operational'] : ['orders', 'detail', 'invalid'],
    queryFn: () => fetchOrderBundle(organizationId!, orderId!, includePayments),
    enabled: valid,
  });
}

export function useOrderCatalogQuery(organizationId: string | null) {
  return useQuery({
    queryKey: organizationId ? ordersQueryKeys.catalog(organizationId) : ['orders', 'catalog', 'no-organization'],
    queryFn: () => fetchOrderCatalog(organizationId!),
    enabled: Boolean(organizationId),
  });
}

export function useCreateOrderMutation(_organizationId: string | null) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: createOrder,
    onSettled: async (result, _error, input) => {
      // A timeout can follow a committed RPC; refresh even when its response failed.
      await invalidateAfterOrderMutation(queryClient, input.organizationId, result?.order_id);
    },
  });
}

export function useSetOrderStatusMutation(_organizationId: string | null, _orderId: string | null) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: setOrderStatus,
    onSettled: async (_result, _error, input) => {
      await invalidateAfterOrderMutation(queryClient, input.organizationId, input.orderId);
    },
  });
}

export function useRecordOrderPaymentMutation(organizationId: string | null, orderId: string | null) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: recordOrderPayment,
    onSuccess: async () => {
      if (!organizationId) return;
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: ordersQueryKeys.all(organizationId) }),
        queryClient.invalidateQueries({ queryKey: ['orders', 'page', organizationId] }),
        orderId ? queryClient.invalidateQueries({ queryKey: ordersQueryKeys.detail(organizationId, orderId) }) : Promise.resolve(),
      ]);
    },
  });
}

export function normalizeOrderFilters(filters: OrderListFilters): OrderListFilters {
  return {
    search: filters.search.trim(),
    status: filters.status,
    from: filters.from,
    to: filters.to,
    product: filters.product.trim(),
  };
}

export function initialOrderData(status: OrderInitialStatus = 'Pendente') {
  return { status };
}

export { fetchProductDetail };
