import { QueryClient } from '@tanstack/react-query';
import { describe, expect, it } from 'vitest';
import { contactsQueryKeys } from '../src/features/contacts/api';
import { inventoryQueryKeys, invalidateStockQueries } from '../src/features/inventory/cache';
import { movementLabel } from '../src/features/inventory/movements';
import { invalidateAfterOrderMutation, ordersQueryKeys } from '../src/features/orders/cache';
import { returnsQueryKeys } from '../src/features/orders/returns-api';
import { productsQueryKeys } from '../src/features/products/api';

const filters = { search: '', status: 'all' as const, from: '', to: '', product: '' };

describe('atualização de estoque por organização', () => {
  it('invalida saldos, movimentos e consultas derivadas sem afetar outro tenant', async () => {
    const queryClient = new QueryClient();
    const affected = [
      inventoryQueryKeys.materials('a'), inventoryQueryKeys.movements('a'),
      productsQueryKeys.materials('a'), productsQueryKeys.all('a'), productsQueryKeys.detail('a', 'p'),
      contactsQueryKeys.all('a', 'supplier'), ordersQueryKeys.catalog('a'), returnsQueryKeys.history('a', 'o'),
    ];
    const untouched = [inventoryQueryKeys.materials('b'), inventoryQueryKeys.movements('b'),
      productsQueryKeys.detail('b', 'p'), contactsQueryKeys.all('b', 'supplier'), contactsQueryKeys.all('a', 'client')];
    [...affected, ...untouched].forEach((key) => queryClient.setQueryData(key, 'cached'));
    await invalidateStockQueries(queryClient, 'a');
    affected.forEach((key) => expect(queryClient.getQueryState(key)?.isInvalidated).toBe(true));
    untouched.forEach((key) => expect(queryClient.getQueryState(key)?.isInvalidated).toBe(false));
    queryClient.clear();
  });

  it('invalida listas e detalhe do pedido e o estoque, inclusive sem resposta do RPC', async () => {
    const queryClient = new QueryClient();
    const keys = [ordersQueryKeys.all('a'), ordersQueryKeys.page('a', filters, null),
      ordersQueryKeys.detail('a', 'o'), [...ordersQueryKeys.detail('a', 'o'), 'financial'],
      [...ordersQueryKeys.detail('a', 'o'), 'operational'], inventoryQueryKeys.materials('a'), inventoryQueryKeys.movements('a')];
    const other = ordersQueryKeys.detail('b', 'o');
    [...keys, other].forEach((key) => queryClient.setQueryData(key, 'cached'));
    await invalidateAfterOrderMutation(queryClient, 'a', 'o');
    keys.forEach((key) => expect(queryClient.getQueryState(key)?.isInvalidated).toBe(true));
    expect(queryClient.getQueryState(other)?.isInvalidated).toBe(false);
    queryClient.clear();

    // A criação pode ter sido confirmada mesmo se não houver resultado do RPC.
    queryClient.setQueryData(ordersQueryKeys.all('a'), 'cached');
    queryClient.setQueryData(inventoryQueryKeys.materials('a'), 'cached');
    await invalidateAfterOrderMutation(queryClient, 'a');
    expect(queryClient.getQueryState(ordersQueryKeys.all('a'))?.isInvalidated).toBe(true);
    expect(queryClient.getQueryState(inventoryQueryKeys.materials('a'))?.isInvalidated).toBe(true);
    queryClient.clear();
  });
});

describe('histórico de movimentos', () => {
  it('distingue baixa e devolução de pedido de ajuste manual', () => {
    expect(movementLabel({ movement_type: 'order_deduction', purchase_id: null })).toBe('Baixa de pedido');
    expect(movementLabel({ movement_type: 'order_return', purchase_id: null })).toBe('Devolução de pedido');
    expect(movementLabel({ movement_type: 'receipt', purchase_id: 'compra' })).toBe('Compra');
    expect(movementLabel({ movement_type: 'adjustment', purchase_id: null })).toBe('Ajuste');
  });
});
