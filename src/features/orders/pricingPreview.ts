import { Decimal, decimalString, parseDecimalInput, STOCK_RESULT_SCALE } from '../../lib/decimal';
import type { ProductDto, ProductEditSnapshot, VariantSnapshot, WholesaleTier } from '../products/types';
import type { OrderDimensions } from './types';
import { roundedMoney } from './utils';

export interface PricingPreviewInput {
  product: ProductDto;
  snapshot: ProductEditSnapshot | null;
  variantId: string | null;
  quantity: string;
  dimensions: OrderDimensions | null;
  override: boolean;
  overridePrice: string;
}

export interface PricingPreview {
  unitPrice: string;
  billedQuantity: string;
  dimensionsFactor: string;
  lineAmountRaw: string;
  lineAmount: string;
  minimumQuantity: string;
  label: string;
  source: 'catalog' | 'override';
  variant: VariantSnapshot | null;
}

function decimal(value: string, label: string, positive = false): Decimal {
  try {
    return parseDecimalInput(value, { scale: 8, positive });
  } catch {
    throw new Error(`${label} inválido ou fora da precisão permitida.`);
  }
}

function checkedProductVersion(input: PricingPreviewInput) {
  const version = input.snapshot?.version;
  if (!version || version.product_id !== input.product.id || version.product_version !== input.product.current_version) {
    throw new Error('A versão vigente do produto ainda não foi carregada; o preço não foi estimado.');
  }
  return version;
}

function activeVariant(input: PricingPreviewInput, version: ReturnType<typeof checkedProductVersion>): VariantSnapshot | null {
  if (input.product.pricing_mode !== 'variation') {
    if (input.variantId) throw new Error('Este produto não aceita variação nesta linha.');
    return null;
  }
  if (!input.variantId) throw new Error('Selecione uma variação ativa para este produto.');
  const variant = (input.snapshot?.variants ?? version.variants_snapshot ?? []).find((candidate) => candidate.id === input.variantId);
  if (!variant || !variant.active) throw new Error('A variação selecionada não está ativa no catálogo vigente.');
  return variant;
}

function highestTier(quantity: Decimal, tiers: WholesaleTier[]): WholesaleTier | null {
  let chosen: WholesaleTier | null = null;
  let chosenMinimum: Decimal | null = null;
  for (const tier of tiers) {
    const minimum = decimal(tier.minimum_quantity, 'Quantidade mínima da faixa', true);
    if (quantity.gte(minimum) && (!chosenMinimum || minimum.gt(chosenMinimum))) {
      decimal(tier.unit_price, 'Preço da faixa');
      chosen = tier;
      chosenMinimum = minimum;
    }
  }
  return chosen;
}

function checkedQuantity(value: Decimal, label: string, scale: number, positive = false): string {
  if (positive && !value.gt(0)) throw new Error(`${label} deve ser maior que zero.`);
  if (value.decimalPlaces() > scale || value.abs().gt(new Decimal('999999999999.99999999'))) throw new Error(`${label} excede a precisão de ${scale} casas.`);
  return value.toFixed();
}

export function previewProductPricing(input: PricingPreviewInput): PricingPreview {
  const version = checkedProductVersion(input);
  const variant = activeVariant(input, version);
  const recipe = variant?.composition_mode === 'own' ? variant.components : version.composition_snapshot;
  const noStock = input.snapshot?.product.inventory_mode === 'no_stock';
  if (!noStock && (!Array.isArray(recipe) || recipe.length === 0)) {
    throw new Error('Produto sem composição de insumos. Cadastre a receita no produto ou na variação antes de continuar.');
  }
  if (noStock && Array.isArray(recipe) && recipe.length > 0) throw new Error('Produto sem consumo de estoque não pode ter composição ativa de insumos.');
  const quantity = decimal(input.quantity, 'Quantidade', true);
  let factor = new Decimal(1);
  if (version.billing_unit === 'm2') {
    if (!input.dimensions) throw new Error('Informe largura e altura para um produto cobrado por m².');
    const width = decimal(input.dimensions.width_cm, 'Largura', true);
    const height = decimal(input.dimensions.height_cm, 'Altura', true);
    factor = width.times(height).times(new Decimal('0.0001'));
    checkedQuantity(factor, 'Fator de área', STOCK_RESULT_SCALE, true);
  }
  const billedQuantity = quantity.times(factor);
  const billedQuantityText = checkedQuantity(billedQuantity, 'Quantidade cobrável', STOCK_RESULT_SCALE, true);
  const minimum = decimal(variant?.minimum_quantity || version.minimum_quantity, 'Quantidade mínima', true);
  if (billedQuantity.lt(minimum)) throw new Error('A quantidade cobrável está abaixo do mínimo vigente do catálogo.');

  let unitPrice: Decimal;
  let source: PricingPreview['source'] = 'catalog';
  let label = 'Estimativa do catálogo vigente';
  if (input.override) {
    unitPrice = decimal(input.overridePrice, 'Preço unitário do override');
    source = 'override';
    label = 'Preço manual informado; o servidor preservará o motivo e o catálogo aplicável';
  } else {
    const normalPrice = variant ? variant.price : version.price;
    if (normalPrice == null) throw new Error('Preço do catálogo indisponível para esta permissão.');
    const normal = decimal(normalPrice, 'Preço catalogado');
    const promoText = variant?.promo_price ?? version.promo_price;
    const promo = promoText ? decimal(promoText, 'Preço promocional') : null;
    if (promo && promo.gt(normal)) throw new Error('O preço promocional vigente é inválido.');
    unitPrice = promo ?? normal;
    if (!variant) {
      const tier = highestTier(billedQuantity, version.wholesale_tiers ?? []);
      if (tier) {
        unitPrice = decimal(tier.unit_price, 'Preço da faixa');
        label = 'Estimativa do catálogo vigente com faixa aplicável';
      } else if (promo) label = 'Estimativa do catálogo vigente com promoção';
    } else if (promo) label = 'Estimativa da variação vigente com promoção';
  }

  const lineAmountRaw = billedQuantity.times(unitPrice);
  if (lineAmountRaw.decimalPlaces() > STOCK_RESULT_SCALE || lineAmountRaw.gt(new Decimal('999999999999999999999999.9999999999999999'))) {
    throw new Error('O valor bruto da linha excede a precisão permitida.');
  }
  return {
    unitPrice: checkedQuantity(unitPrice, 'Preço unitário', 8),
    billedQuantity: billedQuantityText,
    dimensionsFactor: checkedQuantity(factor, 'Fator de dimensão', STOCK_RESULT_SCALE, true),
    lineAmountRaw: lineAmountRaw.toFixed(),
    lineAmount: roundedMoney(lineAmountRaw),
    minimumQuantity: decimalString(minimum),
    label,
    source,
    variant,
  };
}

export function previewManualService(quantity: string, unitPrice: string): PricingPreview {
  const requested = decimal(quantity, 'Quantidade', true);
  const price = decimal(unitPrice, 'Preço unitário', false);
  const raw = requested.times(price);
  return {
    unitPrice: decimalString(price),
    billedQuantity: decimalString(requested),
    dimensionsFactor: '1',
    lineAmountRaw: raw.toFixed(),
    lineAmount: roundedMoney(raw),
    minimumQuantity: '1',
    label: 'Serviço manual; preço e motivo serão registrados no pedido',
    source: 'override',
    variant: null,
  };
}
