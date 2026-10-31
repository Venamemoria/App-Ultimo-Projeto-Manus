import type { MembershipRole } from '../../lib/types';

export const MATERIAL_UNITS = ['un', 'cm', 'm', 'g', 'ml', 'caixa'] as const;
export type MaterialUnit = typeof MATERIAL_UNITS[number];

export type MovementType = 'opening' | 'receipt' | 'adjustment' | 'order_deduction' | 'order_return';
export type InventoryTab = 'list' | 'alerts' | 'history';

export interface MaterialDto {
  id: string;
  organization_id: string;
  name: string;
  category: string | null;
  unit: string;
  package_cost: string | null;
  package_quantity: string;
  unit_cost: string | null;
  stock_quantity: string;
  reorder_level: string;
  is_low_stock: boolean;
  supplier_id: string | null;
  created_at: string;
  updated_at: string;
}

export interface StockMovementDto {
  id: string;
  organization_id: string;
  material_id: string;
  movement_type: MovementType;
  quantity_delta: string;
  stock_after: string;
  package_cost: string | null;
  package_quantity: string | null;
  note: string | null;
  purchase_id: string | null;
  order_id: string | null;
  return_line_id: string | null;
  idempotency_key: string | null;
  created_by: string;
  created_at: string;
}

export interface SupplierOption {
  id: string;
  organization_id?: string;
  name: string;
}

export interface CreateMaterialInput {
  organizationId: string;
  name: string;
  category: string | null;
  unit: MaterialUnit;
  packageCost: string;
  packageQuantity: string;
  initialStock: string;
  reorderLevel: string;
  supplierId: string | null;
  idempotencyKey: string;
}

export interface UpdateMaterialInput {
  organizationId: string;
  materialId: string;
  name: string;
  category: string | null;
  reorderLevel: string;
  supplierId: string | null;
}

export interface ReceiveMaterialInput {
  organizationId: string;
  materialId: string;
  quantity: string;
  packageCost: string;
  packageQuantity: string;
  note: string;
  idempotencyKey: string;
}

export interface AdjustMaterialInput {
  organizationId: string;
  materialId: string;
  delta: string;
  reason: string;
  idempotencyKey: string;
}

export const canManageInventory = (role: MembershipRole | null): boolean => role === 'owner' || role === 'admin';
export const canReceiveInventory = (role: MembershipRole | null): boolean => canManageInventory(role) || role === 'finance';
export const canRegisterPurchase = (role: MembershipRole | null): boolean => role === 'owner' || role === 'admin' || role === 'finance';
