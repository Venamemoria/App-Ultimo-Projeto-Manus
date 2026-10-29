export type PaymentStatus = 'pending' | 'paid';

export interface PurchaseDto {
  id: string;
  organization_id: string;
  material_id: string;
  material_name: string;
  quantity_acquired: string;
  total_amount: string;
  unit_cost: string;
  purchase_date: string;
  supplier_id: string | null;
  supplier_name: string | null;
  document_reference: string | null;
  payment_status: PaymentStatus;
  paid_at: string | null;
  receipt_movement_id: string | null;
  cash_entry_id: string | null;
  created_by: string;
  created_at: string;
}

export interface CreatePurchaseInput {
  organizationId: string;
  materialId: string;
  quantityAcquired: string;
  totalAmount: string;
  purchaseDate: string;
  paymentStatus: PaymentStatus;
  paidAt: string | null;
  idempotencyKey: string;
  supplierId: string | null;
  documentReference: string | null;
}
