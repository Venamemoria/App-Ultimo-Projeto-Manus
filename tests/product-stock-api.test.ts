import { describe, expect, it, vi } from 'vitest';
import { emptyFormValues } from '../src/features/products/types';

const transport = vi.hoisted(() => ({ calls: [] as Array<{ name: string; params: Record<string, unknown> }> }));
vi.mock('../src/lib/supabase', () => ({
  supabase: { rpc: async (name: string, params: Record<string, unknown>) => {
    transport.calls.push({ name, params });
    return { data: [{ product_id: 'local-id', version: '1', pricing_mode: 'unit', normal_price: '5', promo_price: null, minimum_quantity: '1', component_count: 0, composition_cost: '0' }], error: null };
  } },
  supabaseConfigError: null,
}));
import { upsertProduct } from '../src/features/products/api';

describe('salvar classificação de consumo', () => {
  it('envia escolha explícita junto com os dados e a mesma chave na RPC transacional', async () => {
    transport.calls.length = 0;
    const values = { ...emptyFormValues(), name: 'Arquivo', categories: ['Digital'], price: '5', inventoryMode: 'no_stock' as const };
    await upsertProduct({ organizationId: 'organization', productId: null, idempotencyKey: 'nonce', values });
    expect(transport.calls).toHaveLength(1);
    expect(transport.calls[0].name).toBe('vm_upsert_product_v3');
    expect(transport.calls[0].params).toMatchObject({ p_organization_id: 'organization', p_idempotency_key: 'nonce', p_inventory_mode: 'no_stock', p_data: { p_name: 'Arquivo', p_components: [] } });
  });
});
