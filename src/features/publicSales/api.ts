import { supabase, supabaseConfigError } from '../../lib/supabase';
import { fetchContacts } from '../contacts/api';
import type { ClientDto } from '../contacts/types';
import { fetchProducts } from '../products/api';
import type { ProductDto } from '../products/types';
import { QUOTE_PAGE_SIZE } from './pagination';

export type QuoteStatus = 'Sent' | 'Expired' | 'Revoked' | 'Approved';
export interface QuoteListRow { quote_id: string; public_token: string; status: QuoteStatus; title: string; client_name_snapshot: string; total_amount: string; valid_until: string; created_at: string; }
export interface QuoteItem { kind: 'product' | 'manual_service'; title: string; quantity: string; billing_unit: string; dimensions: { width_cm: string; height_cm: string } | null; unit_price: string; line_amount: string; product: { name: string; category: string | null; sku: string | null; variant_name: string | null; variant_sku: string | null } | null }
export interface PublicQuote { brand: string; quote_token: string; title: string; items: QuoteItem[]; subtotal: string; discount_type: 'none' | 'fixed' | 'percent'; discount_value: string; discount_amount: string; shipping_amount: string; total_amount: string; currency: string; order_date: string; production_date: string | null; delivery_date: string | null; valid_until: string; terms: string | null; public_notes: string | null; status: QuoteStatus; accepted_at: string | null }
export interface Tracking { brand: string; code: string; title: string; status: string; status_version: string; order_date: string; production_date: string | null; delivery_date: string | null; expires_at: string; history: { status: string; status_version: string; created_at: string }[] }
export interface AdminQuote { quote_id: string; status: QuoteStatus; valid_until: string; terms: string | null; data: Record<string, unknown>; items: Record<string, unknown>[] }
const db = () => { if (!supabase) throw new Error(supabaseConfigError ?? 'Serviço temporariamente indisponível.'); return supabase; };
const rows = <T,>(value: unknown): T[] => Array.isArray(value) ? value as T[] : value && typeof value === 'object' ? [value as T] : [];
function safeError(error: { code?: string; message?: string } | null): never {
  const code = error?.code;
  if (code === '42501') throw new Error('Você não tem permissão para esta ação.');
  if (code === '22023' || code === '23503') throw new Error('Os dados informados são inválidos ou o registro não está disponível.');
  if (code === '23505') throw new Error('Esta solicitação já foi processada ou conflita com uma operação anterior.');
  if (code === 'PGRST116') throw new Error('Registro não encontrado ou indisponível.');
  throw new Error('Não foi possível concluir a operação. Tente novamente.');
}
const check = (error: { code?: string; message?: string } | null) => { if (error) safeError(error); };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
export const isUuid = (value: string) => UUID.test(value);
export async function fetchQuotePage(org: string, createdAt: string | null, quoteId: string | null) { const { data, error } = await db().rpc('vm_list_quotes', { p_organization_id: org, p_cursor_created_at: createdAt, p_cursor_quote_id: quoteId, p_limit: QUOTE_PAGE_SIZE + 1 }); check(error); return rows<QuoteListRow>(data); }
export async function fetchAdminQuote(org: string, id: string) { const { data, error } = await db().rpc('vm_get_quote_admin', { p_organization_id: org, p_quote_id: id }); check(error); return data as AdminQuote | null; }
export async function fetchQuoteCatalog(org: string): Promise<{ clients: ClientDto[]; products: ProductDto[] }> { const [clients, products] = await Promise.all([fetchContacts('client', org), fetchProducts(org)]); return { clients: clients.filter((client) => client.archived_at === null) as ClientDto[], products }; }
export async function issueQuote(input: { organizationId: string; data: Record<string, unknown>; items: Record<string, unknown>[]; validUntil: string; terms: string | null; nonce: string; parentQuoteId?: string }) { const revision = Boolean(input.parentQuoteId); const { data, error } = await db().rpc(revision ? 'vm_revise_quote' : 'vm_create_quote', revision ? { p_organization_id: input.organizationId, p_quote_id: input.parentQuoteId, p_data: input.data, p_items: input.items, p_valid_until: input.validUntil, p_terms: input.terms, p_nonce: input.nonce } : { p_organization_id: input.organizationId, p_data: input.data, p_items: input.items, p_valid_until: input.validUntil, p_terms: input.terms, p_nonce: input.nonce }); check(error); return rows<{ quote_id: string; public_token: string; status: QuoteStatus }>(data)[0]; }
export async function revokeQuote(org: string, id: string, reason: string, nonce: string) { const { data, error } = await db().rpc('vm_revoke_quote', { p_organization_id: org, p_quote_id: id, p_reason: reason, p_nonce: nonce }); check(error); return rows<{ status: QuoteStatus }>(data)[0]; }
export async function fetchPublicQuote(token: string) { const { data, error } = await db().rpc('vm_get_quote', { p_token: token }); check(error); return data as PublicQuote | null; }
export async function approvePublicQuote(token: string) { const { data, error } = await db().rpc('vm_approve_quote', { p_token: token }); check(error); return rows<{ order_id: string; tracking_token: string; status: string }>(data)[0]; }
export async function fetchTracking(token: string) { const { data, error } = await db().rpc('vm_get_tracking', { p_token: token }); check(error); return data as Tracking | null; }
export async function fetchOrderTracking(org: string, orderId: string) { const { data, error } = await db().rpc('vm_get_order_tracking', { p_organization_id: org, p_order_id: orderId }); check(error); return rows<{ tracking_token: string; expires_at: string }>(data)[0] ?? null; }
export async function issueTracking(org: string, orderId: string, expiresAt: string, nonce: string) { const { data, error } = await db().rpc('vm_issue_tracking', { p_organization_id: org, p_order_id: orderId, p_expires_at: expiresAt, p_nonce: nonce }); check(error); return rows<{ tracking_id: string; tracking_token: string; expires_at: string }>(data)[0]; }
export async function revokeTracking(org: string, token: string, nonce: string) { const { data, error } = await db().rpc('vm_revoke_tracking', { p_organization_id: org, p_tracking_token: token, p_nonce: nonce }); check(error); return rows<{ tracking_id: string; revoked_at: string }>(data)[0]; }
