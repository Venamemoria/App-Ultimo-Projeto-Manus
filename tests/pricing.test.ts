import { describe, expect, it } from 'vitest';
import { compositionCost, highestQualifiedWholesalePrice, resolveProductPrice, resolvePromoPrice } from '../src/features/products/pricing';

describe('precificação de produtos', () => {
  it('preserva a composição com custo unitário de 24 casas', () => {
    const components = [{ material_id: 'm1', unit: 'un', quantity: '0.00000001' }];
    expect(compositionCost(components, new Map([['m1', '0.333333333333333333333333']]))).toBe('0.00000000333333333333333333333333');
  });
  it('usa a promoção somente quando ela não supera o preço normal', () => {
    expect(resolvePromoPrice('19,99999999', '17,12500000')).toBe('17.125');
    expect(() => resolvePromoPrice('10', '10,01')).toThrow('não pode ser maior');
  });

  it('seleciona a maior faixa de atacado qualificada sem float', () => {
    const tier = highestQualifiedWholesalePrice('12,12500000', [
      { minimum_quantity: '5', unit_price: '8,25' },
      { minimum_quantity: '10', unit_price: '7,12500001' },
    ]);
    expect(tier?.unit_price).toBe('7,12500001');
  });

  it('resolve promoção e total por unidade com precisão textual', () => {
    const result = resolveProductPrice({
      pricingMode: 'unit', normalPrice: '10,125', promoPrice: '9,875', quantity: '3,2', minimumQuantity: '1',
    });
    expect(result.unitPrice).toBe('9.875');
    expect(result.totalPrice).toBe('31.6');
    expect(result.source).toBe('promo');
  });

  it('resolve variação e respeita o mínimo próprio da variação', () => {
    const result = resolveProductPrice({
      pricingMode: 'variation', normalPrice: '40', quantity: '6', minimumQuantity: '1',
      variant: { id: 'variant-1', name: 'Grande', sku: null, price: '42,50', promo_price: '39,90', active: true, minimum_quantity: '5', composition_mode: 'inherit_base', components: [] },
    });
    expect(result.unitPrice).toBe('39.9');
    expect(result.totalPrice).toBe('239.4');
    expect(() => resolveProductPrice({ pricingMode: 'variation', normalPrice: '40', quantity: '4', minimumQuantity: '1', variant: { id: 'variant-1', name: 'Grande', sku: null, price: '42,50', promo_price: null, active: true, minimum_quantity: '5', composition_mode: 'inherit_base', components: [] } })).toThrow('abaixo do mínimo');
  });

  it('calcula m² usando a área textual e não inventa carrinho', () => {
    const result = resolveProductPrice({ pricingMode: 'm2', normalPrice: '12,50', quantity: '1', areaM2: '2,4', minimumQuantity: '1' });
    expect(result.billingUnit).toBe('m2');
    expect(result.unitPrice).toBe('12.5');
    expect(result.totalPrice).toBe('30');
  });
});
