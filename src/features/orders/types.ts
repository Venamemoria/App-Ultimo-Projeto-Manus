import type { MembershipRole } from '../../lib/types';
import { canViewFinance } from '../../lib/permissions';
import type { ProductDto, ProductEditSnapshot, VariantSnapshot } from '../products/types';
import type { ClientDto } from '../contacts/types';

export type OrderStatus = 'Pendente' | 'Em Produção' | 'Concluído' | 'Entregue' | 'Cancelado';
export type OrderInitialStatus = Exclude<OrderStatus, 'Entregue' | 'Cancelado'>;
export type DiscountType = 'none' | 'fixed' | 'percent';
export type OrderItemKind = 'product' | 'manual_service';
export type PaymentMethod = 'pix' | 'cash' | 'card' | 'bank_transfer' | 'other';
export type RealtimeStatus = 'connected' | 'reconnecting';

export interface OrderDto {
  id: string;
  organization_id: string;
  code: string;
  client_id: string;
  client_name: string;
  client_name_snapshot: string;
  title: string;
  status: OrderStatus;
  status_version: string;
  order_date: string;
  production_date: string | null;
  delivery_date: string | null;
  responsible_membership_id: string | null;
  public_notes: string | null;
  internal_notes: string | null;
  subtotal: string | null;
  discount_type: DiscountType | null;
  discount_value: string | null;
  discount_amount: string | null;
  shipping_amount: string | null;
  total_amount: string | null;
  paid_amount: string | null;
  balance_amount: string | null;
  currency: 'BRL';
  inventory_deducted: boolean;
  consumed_at: string | null;
  item_count: string;
  created_by: string | null;
  created_at: string;
  updated_at: string;
}

export interface OrderDimensions { width_cm: string; height_cm: string; }

export interface OrderRecipeSnapshot {
  material_id: string;
  material_name: string;
  quantitySnapshot: string;
  unit: string;
  unit_cost_snapshot: string;
  consumption_quantity: string;
  consumption_cost: string;
}

export interface OrderItemDto {
  id: string;
  organization_id: string;
  order_id: string;
  position: string;
  kind: OrderItemKind;
  product_id: string | null;
  product_version: string | null;
  variant_id: string | null;
  variant_version: string | null;
  title: string;
  quantity: string;
  billing_unit: 'unit' | 'm2';
  dimensions: OrderDimensions | null;
  dimensions_factor: string;
  billed_quantity: string;
  unit_price: string;
  price_source: 'catalog' | 'override' | 'manual';
  price_override_reason: string | null;
  line_amount_raw: string;
  line_amount: string;
  recipe_mode: 'base' | 'inherit_base' | 'own' | 'none';
  unit_composition_cost: string;
  total_composition_cost: string;
  product_snapshot: Record<string, unknown>;
  price_snapshot: Record<string, unknown>;
  recipe_snapshot: OrderRecipeSnapshot[];
  details: string | null;
  personalization: Record<string, unknown> | null;
  production_date: string | null;
  delivery_date: string | null;
  created_at: string;
}

export interface OrderConsumptionDto {
  organization_id: string;
  order_id: string;
  material_id: string;
  unit: string;
  quantity: string;
  movement_id: string;
  stock_after: string;
  created_at: string;
}

export interface OrderPaymentDto {
  id: string;
  organization_id: string;
  order_id: string;
  amount: string;
  payment_date: string;
  method: PaymentMethod;
  currency: 'BRL';
  nonce: string;
  cash_entry_id: string;
  created_by: string;
  created_at: string;
}

export interface OrderEventDto {
  id: string;
  organization_id: string;
  order_id: string;
  status_version: string;
  event_type: 'created' | 'status_changed';
  previous_status: OrderStatus | null;
  status: OrderStatus;
  reason: string | null;
  payload: Record<string, unknown>;
  created_by: string | null;
  created_at: string;
}

export interface OrderBundle {
  order: OrderDto;
  items: OrderItemDto[];
  events: OrderEventDto[];
  consumptions: OrderConsumptionDto[];
  payments: OrderPaymentDto[];
}

export interface OrderListFilters {
  search: string;
  status: OrderStatus | 'all';
  from: string;
  to: string;
  product: string;
}

export interface OrdersPage {
  rows: OrderDto[];
  remaining: number;
  total: number | null;
  cursor: string | null;
}

export interface OrderCreateData {
  client_id: string;
  title: string;
  order_date: string;
  production_date: string | null;
  delivery_date: string | null;
  responsible_membership_id: string | null;
  public_notes: string | null;
  internal_notes: string | null;
  initial_status: OrderInitialStatus;
  discount_type: DiscountType;
  discount_value: string;
  shipping_amount: string;
}

export interface OrderCreateItem {
  kind: OrderItemKind;
  product_id: string | null;
  variant_id: string | null;
  title: string | null;
  quantity: string;
  unit_price: string | null;
  price_override: boolean;
  price_override_reason: string | null;
  dimensions: OrderDimensions | null;
  details: string | null;
  personalization: Record<string, unknown> | null;
  production_date: string | null;
  delivery_date: string | null;
}

export interface CreateOrderInput {
  organizationId: string;
  data: OrderCreateData;
  items: OrderCreateItem[];
  idempotencyKey: string;
}

export interface CreateOrderResult {
  order_id: string;
  code: string;
  status: OrderStatus;
  status_version: string;
  event_id: string | null;
  consumed_at: string | null;
  subtotal: string;
  discount_amount: string;
  shipping_amount: string;
  total_amount: string;
  paid_amount: string;
  balance_amount: string;
}

export interface SetOrderStatusInput {
  organizationId: string;
  orderId: string;
  status: OrderStatus;
  reason: string | null;
  idempotencyKey: string;
}

export interface SetOrderStatusResult {
  order_id: string;
  status: OrderStatus;
  status_version: string;
  event_id: string | null;
  consumed_at: string | null;
  changed: boolean;
}

export interface RecordOrderPaymentInput {
  organizationId: string;
  orderId: string;
  amount: string;
  paymentDate: string;
  method: PaymentMethod;
  idempotencyKey: string;
}

export interface RecordOrderPaymentResult {
  payment_id: string;
  cash_entry_id: string;
  order_id: string;
  amount: string;
  payment_date: string;
  method: PaymentMethod;
  total_amount: string;
  paid_amount: string;
  balance_amount: string;
}

export interface OrderCatalog {
  products: ProductDto[];
  clients: ClientDto[];
  memberships: ResponsibleMembership[];
}

export interface ResponsibleMembership {
  id: string;
  organization_id: string;
  user_id: string;
  role: MembershipRole;
  created_at: string;
}

export interface ProductSelection {
  product: ProductDto;
  snapshot: ProductEditSnapshot | null;
  variant: VariantSnapshot | null;
}

export interface StatusTransition {
  from: OrderStatus;
  to: OrderStatus;
}

export const ORDER_STATUSES: OrderStatus[] = ['Pendente', 'Em Produção', 'Concluído', 'Entregue', 'Cancelado'];
export const ORDER_INITIAL_STATUSES: OrderInitialStatus[] = ['Pendente', 'Em Produção', 'Concluído'];
export const PAYMENT_METHODS: PaymentMethod[] = ['pix', 'cash', 'card', 'bank_transfer', 'other'];

export const canCreateOrders = (role: MembershipRole | null): boolean => role === 'owner' || role === 'admin' || role === 'finance';
export const canStartConsumingOrder = (role: MembershipRole | null): boolean => role === 'owner' || role === 'admin';
export const canSetProductionStage = (role: MembershipRole | null): boolean => role === 'owner' || role === 'admin' || role === 'production';
export const canCancelBeforeConsumption = (role: MembershipRole | null): boolean => role === 'owner' || role === 'admin' || role === 'finance';
export const canCancelAfterConsumption = (role: MembershipRole | null): boolean => role === 'owner' || role === 'admin';
export const canRecordPayment = canViewFinance;

export const statusTransitions: Record<OrderStatus, OrderStatus[]> = {
  Pendente: ['Em Produção', 'Concluído', 'Cancelado'],
  'Em Produção': ['Concluído', 'Cancelado'],
  Concluído: ['Entregue', 'Cancelado'],
  Entregue: [],
  Cancelado: [],
};

export function canTransition(from: OrderStatus, to: OrderStatus): boolean {
  return from === to || statusTransitions[from].includes(to);
}
