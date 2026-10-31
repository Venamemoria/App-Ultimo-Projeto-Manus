import { describe, expect, it } from 'vitest';
import { canReceiveInventory } from '../src/features/inventory/types';

describe('recebimento de materiais', () => {
  it('permite entrada com custo só aos papéis financeiros', () => {
    expect(canReceiveInventory('owner')).toBe(true);
    expect(canReceiveInventory('admin')).toBe(true);
    expect(canReceiveInventory('finance')).toBe(true);
    expect(canReceiveInventory('production')).toBe(false);
    expect(canReceiveInventory('viewer')).toBe(false);
    expect(canReceiveInventory(null)).toBe(false);
  });
});
