import type { QueryClient } from '@tanstack/react-query';
import { invalidateStockQueries } from '../inventory/cache';
import type { OrderListFilters } from './types';

export const ordersQueryKeys = {
  page: (organizationId: string, filters: OrderListFilters, cursor: string | null) => ['orders', 'page', organizationId, filters, cursor] as const,
  all: (organizationId: string) => ['orders', 'all', organizationId] as const,
  detail: (organizationId: string, orderId: string) => ['orders', 'detail', organizationId, orderId] as const,
  catalog: (organizationId: string) => ['orders', 'catalog', organizationId] as const,
};

export async function invalidateAfterOrderMutation(queryClient: QueryClient, organizationId: string, orderId?: string): Promise<void> {
  await Promise.all([
    queryClient.invalidateQueries({ queryKey: ordersQueryKeys.all(organizationId) }),
    queryClient.invalidateQueries({ queryKey: ['orders', 'page', organizationId] }),
    orderId ? queryClient.invalidateQueries({ queryKey: ordersQueryKeys.detail(organizationId, orderId) }) : Promise.resolve(),
    invalidateStockQueries(queryClient, organizationId),
  ]);
}
