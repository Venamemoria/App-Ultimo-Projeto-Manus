import { describe, expect, it } from 'vitest';
import { previewManualService, previewProductPricing } from '../src/features/orders/pricingPreview';
import { decimalQuantity, orderReturnRpcParams } from '../src/features/orders/returns-api';
import { Decimal, formatDecimal, STOCK_RESULT_SCALE } from '../src/lib/decimal';
import { canTransition } from '../src/features/orders/types';
import { isIsoDate, ordersCsv, shiftMonth } from '../src/features/orders/utils';
import { canViewFinance } from '../src/lib/permissions';
import type { ProductDto, ProductEditSnapshot } from '../src/features/products/types';

const product: ProductDto = {
  id: '11111111-1111-4111-8111-111111111111', organization_id: '22222222-2222-4222-8222-222222222222', name: 'Caixa', category: 'Papel', categories: ['Papel'], subcategory: null, description: null, material_info: null, personalization_info: null, production_days: '3', pricing_mode: 'unit', price: '10.125', promo_price: '9.875', minimum_quantity: '1', billing_unit: 'unit', is_catalog_visible: true, is_featured: false, custom_questions: [], weight_kg: null, width_cm: null, height_cm: null, depth_cm: null, sku: 'CX-1', barcode: null, wholesale_tiers: [{ minimum_quantity: '10', unit_price: '8.5' }], current_version: '2', inventory_mode: 'materials', current_composition_cost: '1.2', created_at: '2026-01-01T00:00:00Z', updated_at: '2026-01-01T00:00:00Z',
};
const snapshot = { product, version: { product_id: product.id, product_version: '2', name: product.name, category: product.category, categories: product.categories, subcategory: null, description: null, material_info: null, personalization_info: null, production_days: '3', pricing_mode: 'unit', billing_unit: 'unit', price: product.price, promo_price: product.promo_price, minimum_quantity: '1', is_catalog_visible: true, is_featured: false, custom_questions: [], weight_kg: null, width_cm: null, height_cm: null, depth_cm: null, sku: product.sku, barcode: null, wholesale_tiers: product.wholesale_tiers, composition_snapshot: [{ material_id: '66666666-6666-4666-8666-666666666666', quantity: '0.5', unit: 'g' }], variants_snapshot: [], composition_cost: '1.2', snapshot_metadata: {}, organization_id: product.organization_id, created_by: '33333333-3333-4333-8333-333333333333', created_at: '2026-01-01T00:00:00Z' }, versionHistory: [], variants: [], files: [] } as ProductEditSnapshot;

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

  it('preserva os resultados fracionários de área, faturamento e preço sem truncar', () => {
    const areaProduct = { ...product, billing_unit: 'm2' as const, pricing_mode: 'm2' as const };
    const areaSnapshot = { ...snapshot, product: areaProduct, version: { ...snapshot.version, billing_unit: 'm2' as const, pricing_mode: 'm2' as const } };
    const preview = previewProductPricing({ product: areaProduct, snapshot: areaSnapshot, variantId: null, quantity: '1.00000001', dimensions: { width_cm: '100.00000001', height_cm: '100.00000001' }, override: false, overridePrice: '' });
    const factor = new Decimal('100.00000001').times('100.00000001').times('0.0001');
    const billed = factor.times('1.00000001');
    expect(preview.dimensionsFactor).toBe(factor.toFixed());
    expect(preview.billedQuantity).toBe(billed.toFixed());
    expect(preview.billedQuantity.split('.')[1].length).toBeGreaterThan(8);
    expect(preview.lineAmountRaw).toBe(billed.times('9.875').toFixed());
  });

  it('permite conferir e devolver um consumo inferior a oito casas', () => {
    expect(decimalQuantity('0.000000001').toFixed()).toBe('0.000000001');
    expect(formatDecimal('0.000000001', STOCK_RESULT_SCALE)).toBe('0,000000001');
    const params = orderReturnRpcParams({ organizationId: '11111111-1111-4111-8111-111111111111', orderId: '22222222-2222-4222-8222-222222222222', idempotencyKey: '33333333-3333-4333-8333-333333333333', reason: 'Conferido', returns: [{ material_id: '44444444-4444-4444-8444-444444444444', quantity: '0,000000001' }] });
    expect(params.p_returns).toEqual([{ material_id: '44444444-4444-4444-8444-444444444444', quantity: '0.000000001' }]);
    expect(() => decimalQuantity('0.' + '0'.repeat(36) + '1')).toThrow();
  });

  it('exige composição para produto, mas não para serviço manual', () => {
    const empty = { ...snapshot, version: { ...snapshot.version, composition_snapshot: [] } };
    expect(() => previewProductPricing({ product, snapshot: empty, variantId: null, quantity: '1', dimensions: null, override: false, overridePrice: '' })).toThrow('sem composição');
    expect(previewManualService('1', '3').lineAmount).toBe('3.00');
    const exemptProduct = { ...product, inventory_mode: 'no_stock' as const };
    const exempt = { ...empty, product: exemptProduct };
    expect(previewProductPricing({ product: exemptProduct, snapshot: exempt, variantId: null, quantity: '1', dimensions: null, override: false, overridePrice: '' }).lineAmount).toBe('9.88');
  });

  it('não aceita override sem preço e motivo no contrato de intenção', () => {
    expect(() => previewProductPricing({ product, snapshot, variantId: null, quantity: '1', dimensions: null, override: true, overridePrice: '' })).toThrow('Preço unitário');
  });
});

describe('regras puras de fluxo', () => {
  it('mantém proprietário, administração e financeiro e nega produção e visualização', () => {
    expect(['owner', 'admin', 'finance'].map((role) => canViewFinance(role as 'owner' | 'admin' | 'finance'))).toEqual([true, true, true]);
    expect(canViewFinance('production')).toBe(false);
    expect(canViewFinance('viewer')).toBe(false);
    expect(canViewFinance(null)).toBe(false);
  });
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
    const order = { id: '44444444-4444-4444-8444-444444444444', organization_id: product.organization_id, code: 'PED-1', client_id: '55555555-5555-4555-8555-555555555555', client_name: 'Cliente real', client_name_snapshot: 'Cliente real', title: 'Pedido real', status: 'Pendente', status_version: '1', order_date: '2026-02-28', production_date: null, delivery_date: null, responsible_membership_id: null, public_notes: null, internal_notes: null, subtotal: '10.00', discount_type: 'none', discount_value: '0', discount_amount: '0.00', shipping_amount: '0.00', total_amount: '10.00', paid_amount: '0.00', balance_amount: '10.00', currency: 'BRL', inventory_deducted: false, consumed_at: null, item_count: '1', created_by: null, created_at: '2026-02-28T12:00:00Z', updated_at: '2026-02-28T12:00:00Z' } as const;
    const csv = ordersCsv([order], true);
    const operational = ordersCsv([order], false);
    expect(operational).toContain('PED-1');
    expect(operational).not.toMatch(/Subtotal|Desconto|Frete|Total|Recebido|Saldo|Moeda|10,00/);
    expect(csv).toContain('Total');
    expect(csv).toContain('10,00');
    expect(csv).toContain('PED-1');
    expect(csv).not.toContain('demo');
  });
});
