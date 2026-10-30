import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase, supabaseConfigError } from '../../lib/supabase';
import { invalidateStockQueries, inventoryQueryKeys } from './cache';
export { inventoryQueryKeys } from './cache';
import type {
  AdjustMaterialInput,
  CreateMaterialInput,
  MaterialDto,
  ReceiveMaterialInput,
  StockMovementDto,
  SupplierOption,
  UpdateMaterialInput,
} from './types';
import type { PurchaseDto, CreatePurchaseInput } from '../purchases/types';

function getClient() {
  if (!supabase) throw new Error(supabaseConfigError ?? 'O serviço de dados está indisponível neste ambiente.');
  return supabase;
}

function rows<T>(data: unknown): T[] {
  if (Array.isArray(data)) return data as T[];
  if (data && typeof data === 'object') return [data as T];
  return [];
}

function publicDatabaseError(error: { code?: string | null; message?: string | null } | null, fallback: string): Error {
  if (!error) return new Error(fallback);
  if (error.code === '42501') return new Error('Seu papel não permite realizar esta ação.');
  if (error.code === '23505') return new Error('Esta operação já foi registrada ou a chave de tentativa já foi usada com outros dados.');
  if (error.code === '23503') return new Error('O insumo ou fornecedor informado não está disponível nesta organização.');
  if (['22003', '22023', '22P02', '23514'].includes(error.code ?? '')) return new Error('Confira os valores, a precisão decimal e o motivo. Se esta tentativa já foi enviada, mantenha os mesmos dados.');
  return new Error(fallback);
}

export function userFacingInventoryError(error: unknown, fallback = 'Não foi possível concluir esta ação agora.') {
  if (error instanceof Error && error.message) return error.message;
  return fallback;
}

async function readOrganization<T>(table: string, organizationId: string, fallback: string, columns = '*'): Promise<T[]> {
  const result: T[] = [];
  let cursor: string | null = null;
  for (let page = 0; page < 100; page += 1) {
    let query = getClient().from(table).select(columns, { count: 'exact' })
      .eq('organization_id', organizationId).order('id', { ascending: true }).limit(500);
    if (cursor) query = query.gt('id', cursor);
    const { data, error, count } = await query;
    if (error) throw publicDatabaseError(error, fallback);
    const batch = (data ?? []) as unknown as (T & { id: string })[];
    result.push(...batch);
    if (!batch.length || (count !== null && batch.length >= count)) return result;
    const next = batch[batch.length - 1]?.id;
    if (typeof next !== 'string' || next === cursor) throw new Error(fallback);
    cursor = next;
  }
  throw new Error('A consulta ultrapassou o limite seguro. Restrinja o período antes de exportar todos os registros.');
}

export async function fetchMaterials(organizationId: string): Promise<MaterialDto[]> {
  return readOrganization<MaterialDto>('vm_materials_read', organizationId, 'Não foi possível carregar os materiais.');
}

export async function fetchMovements(organizationId: string): Promise<StockMovementDto[]> {
  const movements = await readOrganization<StockMovementDto>('vm_stock_movements_read', organizationId, 'Não foi possível carregar o histórico de estoque.');
  return movements.sort((a, b) => b.created_at.localeCompare(a.created_at));
}

export async function fetchSuppliers(organizationId: string): Promise<SupplierOption[]> {
  const suppliers = await readOrganization<SupplierOption>('vm_suppliers', organizationId, 'Não foi possível carregar os fornecedores.', 'id, organization_id, name');
  return suppliers.sort((a, b) => a.name.localeCompare(b.name, 'pt-BR'));
}

export async function fetchPurchases(organizationId: string): Promise<PurchaseDto[]> {
  const purchases = await readOrganization<PurchaseDto>('vm_material_purchases_read', organizationId, 'Não foi possível carregar as compras.');
  return purchases.sort((a, b) => `${b.purchase_date}${b.created_at}`.localeCompare(`${a.purchase_date}${a.created_at}`));
}

async function callRpc<T>(name: string, params: Record<string, unknown>, fallback: string): Promise<T> {
  const { data, error } = await getClient().rpc(name, params);
  if (error) throw publicDatabaseError(error, fallback);
  const result = rows<T>(data)[0];
  if (!result) throw new Error(fallback);
  return result;
}

export function useMaterialsQuery(organizationId: string | null) {
  return useQuery({
    queryKey: organizationId ? inventoryQueryKeys.materials(organizationId) : ['inventory', 'materials', 'no-organization'],
    queryFn: () => fetchMaterials(organizationId!),
    enabled: Boolean(organizationId),
    refetchOnWindowFocus: 'always',
    refetchInterval: 30_000,
  });
}

export function useMovementsQuery(organizationId: string | null, enabled = true) {
  return useQuery({
    queryKey: organizationId ? inventoryQueryKeys.movements(organizationId) : ['inventory', 'movements', 'no-organization'],
    queryFn: () => fetchMovements(organizationId!),
    enabled: Boolean(organizationId) && enabled,
    refetchOnWindowFocus: 'always',
    refetchInterval: 30_000,
  });
}

export function useSuppliersQuery(organizationId: string | null) {
  return useQuery({
    queryKey: organizationId ? inventoryQueryKeys.suppliers(organizationId) : ['inventory', 'suppliers', 'no-organization'],
    queryFn: () => fetchSuppliers(organizationId!),
    enabled: Boolean(organizationId),
  });
}

export function usePurchasesQuery(organizationId: string | null) {
  return useQuery({
    queryKey: organizationId ? inventoryQueryKeys.purchases(organizationId) : ['purchases', 'materials', 'no-organization'],
    queryFn: () => fetchPurchases(organizationId!),
    enabled: Boolean(organizationId),
  });
}

function useInventoryMutation<TInput extends { organizationId: string }, TResult>(
  _organizationId: string | null,
  mutationFn: (input: TInput) => Promise<TResult>,
  includePurchases = false,
) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn,
    // A request can commit even if its response is lost; refresh on failure too.
    // Use the submitted organization rather than the currently selected tenant.
    onSettled: async (_result, _error, input) => {
      const organizationId = input.organizationId;
      await Promise.all([
        invalidateStockQueries(queryClient, organizationId),
        includePurchases ? queryClient.invalidateQueries({ queryKey: inventoryQueryKeys.purchases(organizationId) }) : Promise.resolve(),
        includePurchases ? queryClient.invalidateQueries({ queryKey: ['finance-summary', organizationId] }) : Promise.resolve(),
      ]);
    },
  });
}

export function useCreateMaterialMutation(organizationId: string | null) {
  return useInventoryMutation<CreateMaterialInput, Record<string, unknown>>(organizationId, (input) => callRpc('vm_create_material', {
    p_organization_id: input.organizationId,
    p_name: input.name,
    p_unit: input.unit,
    p_package_cost: input.packageCost,
    p_package_quantity: input.packageQuantity,
    p_initial_stock: input.initialStock,
    p_reorder_level: input.reorderLevel,
    p_category: input.category,
    p_supplier_id: input.supplierId,
    p_idempotency_key: input.idempotencyKey,
  }, 'Não foi possível cadastrar o insumo.'));
}

export function useUpdateMaterialMutation(organizationId: string | null) {
  return useInventoryMutation<UpdateMaterialInput, Record<string, unknown>>(organizationId, (input) => callRpc('vm_update_material', {
    p_organization_id: input.organizationId,
    p_material_id: input.materialId,
    p_name: input.name,
    p_reorder_level: input.reorderLevel,
    p_category: input.category,
    p_supplier_id: input.supplierId,
  }, 'Não foi possível atualizar o insumo.'));
}

export function useReceiveMaterialMutation(organizationId: string | null) {
  return useInventoryMutation<ReceiveMaterialInput, Record<string, unknown>>(organizationId, (input) => callRpc('vm_receive_material', {
    p_organization_id: input.organizationId,
    p_material_id: input.materialId,
    p_quantity: input.quantity,
    p_package_cost: input.packageCost,
    p_package_quantity: input.packageQuantity,
    p_note: input.note,
    p_idempotency_key: input.idempotencyKey,
  }, 'Não foi possível registrar a entrada avulsa.'));
}

export function useAdjustMaterialMutation(organizationId: string | null) {
  return useInventoryMutation<AdjustMaterialInput, Record<string, unknown>>(organizationId, (input) => callRpc('vm_adjust_material_stock_safe', {
    p_organization_id: input.organizationId,
    p_material_id: input.materialId,
    p_delta: input.delta,
    p_reason: input.reason,
    p_idempotency_key: input.idempotencyKey,
  }, 'Não foi possível confirmar o ajuste. Tente novamente com os mesmos dados para verificar esta operação.'));
}

export function useCreatePurchaseMutation(organizationId: string | null) {
  return useInventoryMutation<CreatePurchaseInput, Record<string, unknown>>(organizationId, (input) => callRpc('vm_create_material_purchase', {
    p_organization_id: input.organizationId,
    p_material_id: input.materialId,
    p_quantity_acquired: input.quantityAcquired,
    p_total_amount: input.totalAmount,
    p_purchase_date: input.purchaseDate,
    p_payment_status: input.paymentStatus,
    p_paid_at: input.paidAt,
    p_idempotency_key: input.idempotencyKey,
    p_supplier_id: input.supplierId,
    p_document_reference: input.documentReference,
  }, 'Não foi possível confirmar a compra. Tente novamente sem mudar os dados para verificar a mesma operação.'), true);
}
