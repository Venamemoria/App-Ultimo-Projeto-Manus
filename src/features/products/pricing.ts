import { Decimal, decimalString, parseDecimalInput } from '../../lib/decimal';
import type { PricingMode, ProductComponent, VariantSnapshot, WholesaleTier } from './types';

export interface PriceResolutionInput {
  pricingMode: PricingMode;
  normalPrice: string;
  promoPrice?: string | null;
  quantity: string;
  minimumQuantity?: string | null;
  wholesaleTiers?: WholesaleTier[];
  variant?: VariantSnapshot | null;
  areaM2?: string;
}

export interface PriceResolution {
  unitPrice: string;
  totalPrice: string;
  source: 'normal' | 'promo' | 'wholesale' | 'variant' | 'variant-promo';
  appliedMinimum: string;
  billingUnit: 'unit' | 'm2';
}

function validMoney(value: string, label: string): Decimal {
  try {
    return parseDecimalInput(value, { scale: 8 });
  } catch {
    throw new Error(`${label} inválido.`);
  }
}

export function resolvePromoPrice(normalPrice: string, promoPrice?: string | null): string {
  const normal = validMoney(normalPrice, 'Preço');
  if (!promoPrice?.trim()) return decimalString(normal);
  const promo = validMoney(promoPrice, 'Preço promocional');
  if (promo.gt(normal)) throw new Error('O preço promocional não pode ser maior que o preço normal.');
  return decimalString(promo);
}

export function highestQualifiedWholesalePrice(quantity: string, tiers: WholesaleTier[] = []): WholesaleTier | null {
  const requested = parseDecimalInput(quantity, { positive: true });
  let selected: WholesaleTier | null = null;
  let selectedMinimum: Decimal | null = null;
  for (const tier of tiers) {
    const minimum = parseDecimalInput(tier.minimum_quantity, { positive: true });
    if (requested.gte(minimum) && (!selectedMinimum || minimum.gt(selectedMinimum))) {
      validMoney(tier.unit_price, 'Preço de atacado');
      selected = tier;
      selectedMinimum = minimum;
    }
  }
  return selected;
}

export function resolveProductPrice(input: PriceResolutionInput): PriceResolution {
  const quantity = parseDecimalInput(input.quantity, { positive: true });
  const productMinimum = parseDecimalInput(input.minimumQuantity ?? '1', { positive: true });
  if (quantity.lt(productMinimum)) throw new Error('A quantidade está abaixo do mínimo do produto.');

  const variant = input.pricingMode === 'variation' ? input.variant ?? null : null;
  if (input.pricingMode === 'variation' && !variant) throw new Error('Selecione uma variação para visualizar o preço.');

  const normal = variant ? validMoney(variant.price, 'Preço da variação') : validMoney(input.normalPrice, 'Preço');
  const promo = variant?.promo_price ?? input.promoPrice;
  const promoValue = promo?.trim() ? validMoney(promo, 'Preço promocional') : null;
  if (promoValue && promoValue.gt(normal)) throw new Error('O preço promocional não pode ser maior que o preço normal.');

  const variantMinimum = variant?.minimum_quantity ? parseDecimalInput(variant.minimum_quantity, { positive: true }) : null;
  const minimum = variantMinimum && variantMinimum.gt(productMinimum) ? variantMinimum : productMinimum;
  if (quantity.lt(minimum)) throw new Error('A quantidade está abaixo do mínimo desta variação.');

  const wholesale = highestQualifiedWholesalePrice(quantity.toFixed(), input.wholesaleTiers);
  let unitPrice = wholesale ? validMoney(wholesale.unit_price, 'Preço de atacado') : promoValue ?? normal;
  let source: PriceResolution['source'] = wholesale ? 'wholesale' : promoValue ? (variant ? 'variant-promo' : 'promo') : variant ? 'variant' : 'normal';
  const billingUnit = input.pricingMode === 'm2' ? 'm2' : 'unit';
  const billableQuantity = billingUnit === 'm2' ? parseDecimalInput(input.areaM2 ?? quantity.toFixed(), { positive: true }) : quantity;
  if (billingUnit === 'm2' && billableQuantity.lt(productMinimum)) throw new Error('A área está abaixo do mínimo do produto.');
  unitPrice = unitPrice.toDecimalPlaces(8);
  return {
    unitPrice: decimalString(unitPrice),
    totalPrice: decimalString(unitPrice.times(billableQuantity).toDecimalPlaces(8)),
    source,
    appliedMinimum: decimalString(minimum),
    billingUnit,
  };
}

export function compositionCost(components: ProductComponent[], materialUnitCosts: Map<string, string>): string {
  return decimalString(components.reduce((total, component) => {
    const cost = materialUnitCosts.get(component.material_id);
    if (!cost) return total;
    const quantity = parseDecimalInput(component.quantity, { positive: true });
    return total.plus(quantity.times(validMoney(cost, 'Custo unitário')));
  }, new Decimal(0)).toDecimalPlaces(8));
}

export function validateWholesaleTiers(tiers: WholesaleTier[]): string | null {
  let previous: Decimal | null = null;
  for (const tier of tiers) {
    try {
      const minimum = parseDecimalInput(tier.minimum_quantity, { positive: true });
      validMoney(tier.unit_price, 'Preço de atacado');
      if (previous && minimum.lte(previous)) return 'As faixas de atacado devem ter quantidade mínima estritamente crescente.';
      previous = minimum;
    } catch (error) {
      return error instanceof Error ? error.message : 'Faixa de atacado inválida.';
    }
  }
  return null;
}
