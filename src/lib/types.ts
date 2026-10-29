export type MembershipRole = 'owner' | 'admin' | 'production' | 'finance' | 'viewer';

export interface Organization {
  id: string;
  name: string;
}

export interface Membership {
  id: string;
  organization_id: string;
  user_id: string;
  role: MembershipRole;
  created_at: string;
  organization: Organization | null;
}

export interface Material {
  id: string;
  organization_id: string;
  name: string;
  category: string | null;
  unit: string;
  package_cost: string;
  package_quantity: string;
  unit_cost: string;
  stock_quantity: string;
  reorder_level: string;
  supplier_id: string | null;
  created_at: string;
  updated_at: string;
}

export interface StockMovement {
  id: string;
  organization_id: string;
  material_id: string;
  movement_type: 'opening' | 'receipt' | 'adjustment';
  quantity_delta: string;
  stock_after: string;
  package_cost: string | null;
  package_quantity: string | null;
  note: string | null;
  idempotency_key: string | null;
  created_by: string;
  created_at: string;
}

export interface Product {
  id: string;
  organization_id: string;
  name: string;
  category: string | null;
  price: string;
  current_version: number;
  created_at: string;
  updated_at: string;
}

export interface Supplier {
  id: string;
  organization_id: string;
  name: string;
  email: string | null;
  phone: string | null;
  notes: string | null;
  created_at: string;
  updated_at: string;
}

export interface Client {
  id: string;
  organization_id: string;
  name: string;
  email: string | null;
  phone: string | null;
  notes: string | null;
  created_at: string;
  updated_at: string;
}
