import type { StockMovementDto } from './types';

export function movementLabel(movement: Pick<StockMovementDto, 'movement_type' | 'purchase_id'>): string {
  switch (movement.movement_type) {
    case 'opening': return 'Saldo inicial';
    case 'receipt': return movement.purchase_id ? 'Compra' : 'Entrada avulsa';
    case 'adjustment': return 'Ajuste';
    case 'order_deduction': return 'Baixa de pedido';
    case 'order_return': return 'Devolução de pedido';
    default: return 'Outro movimento';
  }
}
