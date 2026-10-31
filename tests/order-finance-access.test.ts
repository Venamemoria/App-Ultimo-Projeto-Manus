import { beforeEach, describe, expect, it, vi } from 'vitest';

const transport = vi.hoisted(() => ({ tables: [] as string[] }));
vi.mock('../src/lib/supabase', () => ({
  supabase: {
    from: (table: string) => {
      transport.tables.push(table);
      const builder = {
        select: () => builder,
        eq: () => builder,
        order: () => builder,
        limit: () => Promise.resolve({ data: [], error: null, count: 0 }),
        maybeSingle: () => Promise.resolve({ data: { id: 'local-test-order' }, error: null }),
      };
      return builder;
    },
  },
}));
import { fetchOrderBundle } from '../src/features/orders/api';

const organization = '11111111-1111-4111-8111-111111111111';
const order = '22222222-2222-4222-8222-222222222222';

describe('consulta do detalhe conforme privilégio', () => {
  beforeEach(() => { transport.tables.length = 0; });
  it('não consulta pagamentos para acesso operacional', async () => {
    const result = await fetchOrderBundle(organization, order, false);
    expect(transport.tables).toContain('vm_order_items_read');
    expect(transport.tables).toContain('vm_order_consumptions_read');
    expect(transport.tables).not.toContain('vm_order_payments_read');
    expect(result.payments).toEqual([]);
  });
  it('consulta pagamentos para acesso financeiro', async () => {
    await fetchOrderBundle(organization, order, true);
    expect(transport.tables).toContain('vm_order_payments_read');
  });
});
