import { describe, expect, it } from 'vitest';
import { Decimal, decimalString, formatDecimal, parseDecimalInput, unitCostPreview } from '../src/lib/decimal';
import { formatCurrency, formatDate } from '../src/lib/format';

describe('decimais sem float de estoque', () => {
  it('aceita vírgula, agrupamento pt-BR e ponto decimal', () => {
    expect(parseDecimalInput('1.234,50000001').toFixed()).toBe('1234.50000001');
    expect(parseDecimalInput('0.125').toFixed()).toBe('0.125');
  });
  it('rejeita especiais, escala excessiva, zero positivo e negativos', () => {
    for (const input of ['NaN', 'Infinity', '1,123456789', '-1', '1e8']) expect(() => parseDecimalInput(input)).toThrow();
    expect(() => parseDecimalInput('0', { positive: true })).toThrow();
    expect(parseDecimalInput('-0,25', { allowNegative: true }).toFixed()).toBe('-0.25');
    expect(() => parseDecimalInput('0,001', { scale: 2 })).toThrow();
  });
  it('preserva oito casas de quantidade grande sem Number', () => {
    expect(formatDecimal('999999999999.12345678')).toBe('999.999.999.999,12345678');
    expect(decimalString(new Decimal('0.125').times('3'))).toBe(new Decimal('0.125').times('3').toFixed());
  });
  it('preview divide e quantiza como custo unitário PostgreSQL', () => {
    expect(unitCostPreview('10,00000001', '3')).toBe(new Decimal('10.00000001').div('3').toDecimalPlaces(8).toFixed());
    expect(unitCostPreview('10', '0')).toBeNull();
  });
  it('formata moeda e mantém a data civil independente de timezone', () => {
    expect(formatCurrency('12.5')).toBe('R$ 12,50');
    expect(formatDate('2026-10-29')).toBe('29/10/2026');
    expect(formatDate('inválida')).toBe('—');
  });
});
