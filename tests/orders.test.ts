import { describe, expect, it } from 'vitest';
import { previewProductPricing } from '../src/features/orders/pricingPreview';
import { canTransition } from '../src/features/orders/types';
import { isIsoDate, ordersCsv, shiftMonth } from '../src/features/orders/utils';
import type { ProductDto, ProductEditSnapshot } from '../src/features/products/types';

const product: ProductDto = {
  id: '11111111-1111-4111-8111-111111111111', organization_id: '22222222-2222-4222-8222-222222222222', name: 'Caixa', category: 'Papel', categories: ['Papel'], subcategory: null, description: null, material_info: null, personalization_info: null, production_days: '3', pricing_mode: 'unit', price: '10.125', promo_price: '9.875', minimum_quantity: '1', billing_unit: 'unit', is_catalog_visible: true, is_featured: false, custom_questions: [], weight_kg: null, width_cm: null, height_cm: null, depth_cm: null, sku: 'CX-1', barcode: null, wholesale_tiers: [{ minimum_quantity: '10', unit_price: '8.5' }], current_version: '2', current_composition_cost: '1.2', created_at: '2026-01-01T00:00:00Z', updated_at: '2026-01-01T00:00:00Z',
};
const snapshot = { product, version: { product_id: product.id, product_version: '2', name: product.name, category: product.category, categories: product.categories, subcategory: null, description: null, material_info: null, personalization_info: null, production_days: '3', pricing_mode: 'unit', billing_unit: 'unit', price: product.price, promo_price: product.promo_price, minimum_quantity: '1', is_catalog_visible: true, is_featured: false, custom_questions: [], weight_kg: null, width_cm: null, height_cm: null, depth_cm: null, sku: product.sku, barcode: null, wholesale_tiers: product.wholesale_tiers, composition_snapshot: [], variants_snapshot: [], composition_cost: '1.2', snapshot_metadata: {}, organization_id: product.organization_id, created_by: '33333333-3333-4333-8333-333333333333', created_at: '2026-01-01T00:00:00Z' }, versionHistory: [], variants: [], files: [] } as ProductEditSnapshot;

describe('preview puro de pedidos', () => {
  it('usa promoção e faixa real sem float', () => {
    const preview = previewProductPricing({ product, snapshot, variantId: null, quantity: '12.12500000', dimensions: null, override: false, overridePrice: '' });
    expect(preview.unitPrice).toBe('8.5');
    expect(preview.billedQuantity).toBe('12.125');
    expect(preview.source).toBe('catalog');
  });

  it('exige dimensões para catálogo m² e conserva fator textual', () => {
    const areaProduct = { ...product, billing_unit: 'm2' as const, pricing_mode: 'm2' as const };
    const areaSnapshot = { ...snapshot, product: areaProduct, version: { ...snapshot.version, billing_unit: 'm2' as const, pricing_mode: 'm2' as const } };
    expect(() => previewProductPricing({ product: areaProduct, snapshot: areaSnapshot, variantId: null, quantity: '1', dimensions: null, override: false, overridePrice: '' })).toThrow('largura');
    const preview = previewProductPricing({ product: areaProduct, snapshot: areaSnapshot, variantId: null, quantity: '1', dimensions: { width_cm: '100', height_cm: '100' }, override: false, overridePrice: '' });
    expect(preview.dimensionsFactor).toBe('1');
    expect(preview.billedQuantity).toBe('1');
  });

  it('não aceita override sem preço e motivo no contrato de intenção', () => {
    expect(() => previewProductPricing({ product, snapshot, variantId: null, quantity: '1', dimensions: null, override: true, overridePrice: '' })).toThrow('Preço unitário');
  });
});

describe('regras puras de fluxo', () => {
  it('aceita apenas transições backend válidas', () => {
    expect(canTransition('Pendente', 'Em Produção')).toBe(true);
    expect(canTransition('Em Produção', 'Pendente')).toBe(false);
    expect(canTransition('Entregue', 'Cancelado')).toBe(false);
  });

  it('valida calendário local e mudança de mês sem UTC', () => {
    expect(isIsoDate('2026-02-28')).toBe(true);
    expect(isIsoDate('2026-02-30')).toBe(false);
    expect(shiftMonth('2026-01', -1)).toBe('2025-12');
    expect(shiftMonth('2026-12', 1)).toBe('2027-01');
  });

  it('exporta somente os pedidos recebidos pela consulta real', () => {
    const csv = ordersCsv([{ id: '44444444-4444-4444-8444-444444444444', organization_id: product.organization_id, code: 'PED-1', client_id: '55555555-5555-4555-8555-555555555555', client_name: 'Cliente real', client_name_snapshot: 'Cliente real', title: 'Pedido real', status: 'Pendente', status_version: '1', order_date: '2026-02-28', production_date: null, delivery_date: null, responsible_membership_id: null, public_notes: null, internal_notes: null, subtotal: '10.00', discount_type: 'none', discount_value: '0', discount_amount: '0.00', shipping_amount: '0.00', total_amount: '10.00', paid_amount: '0.00', balance_amount: '10.00', currency: 'BRL', inventory_deducted: false, consumed_at: null, item_count: '1', created_by: null, created_at: '2026-02-28T12:00:00Z', updated_at: '2026-02-28T12:00:00Z' }]);
    expect(csv).toContain('PED-1');
    expect(csv).not.toContain('demo');
  });
});
