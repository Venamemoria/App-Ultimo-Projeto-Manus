import type { QueryClient, QueryKey } from '@tanstack/react-query';

export const inventoryQueryKeys = {
  materials: (organizationId: string) => ['inventory', 'materials', organizationId] as const,
  movements: (organizationId: string) => ['inventory', 'movements', organizationId] as const,
  suppliers: (organizationId: string) => ['inventory', 'suppliers', organizationId] as const,
  purchases: (organizationId: string) => ['purchases', 'materials', organizationId] as const,
};

// These queries contain balances, live material costs, or supplier aggregates.
// Partial keys deliberately mark every detail/return query for this tenant stale.
export function stockDependentQueryKeys(organizationId: string): QueryKey[] {
  return [
    inventoryQueryKeys.materials(organizationId),
    inventoryQueryKeys.movements(organizationId),
    ['products', 'materials', organizationId],
    ['products', 'all', organizationId],
    ['products', 'detail', organizationId],
    ['contacts', 'supplier', organizationId],
    ['orders', 'catalog', organizationId],
    ['orders', 'returns', organizationId],
  ];
}

export async function invalidateStockQueries(queryClient: QueryClient, organizationId: string): Promise<void> {
  await Promise.all(stockDependentQueryKeys(organizationId).map((queryKey) => queryClient.invalidateQueries({ queryKey })));
}
