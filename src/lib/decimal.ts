import Decimal from 'decimal.js';

// Exact intermediate products can contain 24 integer and 60 fractional digits.
Decimal.set({ precision: 96, rounding: Decimal.ROUND_HALF_UP });
export const STOCK_RESULT_SCALE = 36;
export const UNIT_COST_SCALE = 24;
export const COMPOSITION_COST_SCALE = 32;
export const QUANTITY_MAX = new Decimal('999999999999.99999999');

export function parseDecimalInput(value: string, options: { scale?: number; allowNegative?: boolean; positive?: boolean } = {}): Decimal {
  let normalized = value.trim().replace(/\s+/g, '');
  if (normalized.includes(',')) normalized = normalized.replace(/\./g, '').replace(',', '.');
  if (!/^-?\d+(?:\.\d+)?$/.test(normalized)) throw new Error('Informe um número válido; use vírgula para a parte decimal.');
  const result = new Decimal(normalized);
  if (!result.isFinite() || result.abs().gt(QUANTITY_MAX)) throw new Error('Número fora do limite permitido.');
  if (!options.allowNegative && result.isNegative()) throw new Error('O valor não pode ser negativo.');
  if (options.positive && !result.gt(0)) throw new Error('A quantidade deve ser maior que zero.');
  const scale = options.scale ?? 8;
  if (result.decimalPlaces() > scale) throw new Error(`Use no máximo ${scale} casas decimais.`);
  return result;
}

export function formatDecimal(value: string | number | Decimal | null | undefined, scale = 8, fixed = false): string {
  if (value === null || value === undefined || value === '') return '—';
  try {
    const decimal = new Decimal(value);
    if (!decimal.isFinite()) return '—';
    let text = decimal.toFixed(scale);
    if (!fixed && text.includes('.')) text = text.replace(/0+$/, '').replace(/\.$/, '');
    const negative = text.startsWith('-');
    const [integer, fraction] = text.replace(/^-/, '').split('.');
    return `${negative ? '−' : ''}${integer.replace(/\B(?=(\d{3})+(?!\d))/g, '.')}${fraction ? ',' + fraction : ''}`;
  } catch { return '—'; }
}

export function decimalString(value: Decimal): string {
  if (!value.isFinite() || value.abs().gt(QUANTITY_MAX) || value.decimalPlaces() > 8) throw new Error('Resultado excede a precisão de estoque.');
  return value.toFixed();
}

export function unitCostPreview(total: string, quantity: string): string | null {
  try {
    const cost = parseDecimalInput(total);
    const units = parseDecimalInput(quantity, { positive: true });
    return cost.div(units).toDecimalPlaces(UNIT_COST_SCALE).toFixed();
  } catch { return null; }
}

export function localDateToday(): string {
  const date = new Date();
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
}

export { Decimal };
