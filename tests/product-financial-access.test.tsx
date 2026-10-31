import { describe, expect, it } from 'vitest';
import { renderToStaticMarkup } from 'react-dom/server';
import { productOperationsRpcParams } from '../src/features/products/api';
import { ProductTable, productCsvRows } from '../src/features/products/ProductsPage';
import { canEditProducts, canEditProductOperations, type ProductDto, type ProductOperationsInput } from '../src/features/products/types';

// Synthetic data exist only in tests; the production code reads Supabase.
const product = {
  id: 'product', organization_id: 'org', name: 'Envelope', category: 'Papel', categories: ['Papel'],
  sku: 'A', pricing_mode: 'unit', price: '839.42', promo_price: '713.21', minimum_quantity: '1',
  current_composition_cost: '321.45', current_material_cost: '456.78', is_catalog_visible: true,
  is_featured: false, updated_at: '2026-01-01', inventory_mode: 'materials',
} as unknown as ProductDto;

const operation = {
  organizationId: 'org', productId: 'product', expectedVersion: '4', idempotencyKey: 'nonce',
  inventoryMode: 'materials', description: 'Produção', materialInfo: 'Papel', personalizationInfo: '', productionDays: '2',
  components: [{ material_id: 'material', quantity: '0,33333333', unit: 'g', unit_cost: 'SECRET_COST', line_cost: 'SECRET_LINE' }],
  variants: [{ id: 'variant', name: 'Modelo', sku: null, price: 'SECRET_PRICE', promo_price: 'SECRET_PROMO', active: true,
    minimum_quantity: null, composition_mode: 'own', composition_cost: 'SECRET_COST',
    components: [{ material_id: 'material', quantity: '0.25', unit: 'g', unit_cost: 'SECRET_VARIANT_COST' }] }],
} satisfies ProductOperationsInput;

describe('acesso financeiro do catálogo', () => {
  it('separa edição financeira, operação de receitas e leitura', () => {
    for (const role of ['owner', 'admin', 'finance'] as const) {
      expect(canEditProducts(role)).toBe(true);
      expect(canEditProductOperations(role)).toBe(true);
    }
    expect(canEditProducts('production')).toBe(false);
    expect(canEditProductOperations('production')).toBe(true);
    expect(canEditProducts('viewer')).toBe(false);
    expect(canEditProductOperations('viewer')).toBe(false);
  });

  it('envia apenas uma allowlist operacional, mesmo se o estado contiver preços', () => {
    const payload = productOperationsRpcParams(operation);
    expect(payload.p_expected_version).toBe(4);
    expect(JSON.stringify(payload)).not.toContain('SECRET');
    expect(payload.p_data).toEqual({ description: 'Produção', material_info: 'Papel', personalization_info: null, production_days: 2,
      components: [{ material_id: 'material', quantity: '0.33333333', unit: 'g' }],
      variants: [{ id: 'variant', composition_mode: 'own', components: [{ material_id: 'material', quantity: '0.25', unit: 'g' }] }],
    });
    expect(() => productOperationsRpcParams({ ...operation, expectedVersion: '0' })).toThrow();
  });

  it('não apresenta nem exporta valores para a visão operacional, mesmo com dados em cache', () => {
    const rows = productCsvRows([product], false);
    const csv = JSON.stringify(rows);
    expect(csv).not.toContain('Preço normal');
    expect(csv).not.toContain('839');
    expect(csv).not.toContain('321');
    expect(JSON.stringify(productCsvRows([product], true))).toContain('Preço normal');
    const html = renderToStaticMarkup(<ProductTable products={[product]} canEdit={false} canOperate showFinance={false} onEdit={() => {}} onOperate={() => {}} onDetails={() => {}} />);
    expect(html).toContain('Editar produção');
    expect(html).not.toContain('839');
    expect(html).not.toContain('713');
    expect(html).not.toContain('Custo receita');
  });
});
