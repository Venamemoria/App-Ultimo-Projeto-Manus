import { Decimal, parseDecimalInput } from '../../lib/decimal';
import { formatCurrency, formatDate } from '../../lib/format';
import type { MembershipRole } from '../../lib/types';
import type { OrderDto, OrderStatus, PaymentMethod } from './types';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function isUuid(value: string | null | undefined): value is string {
  return Boolean(value && UUID_RE.test(value));
}

export function newIdempotencyKey(): string {
  return globalThis.crypto.randomUUID();
}

export function todayIso(): string {
  const now = new Date();
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')}`;
}

export function isIsoDate(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const [year, month, day] = value.split('-').map(Number);
  const date = new Date(year, month - 1, day);
  return date.getFullYear() === year && date.getMonth() === month - 1 && date.getDate() === day;
}

export function compareIsoDates(left: string, right: string): number {
  return left.localeCompare(right);
}

export function dateAtLocalNoon(value: string): Date | null {
  if (!isIsoDate(value)) return null;
  const [year, month, day] = value.split('-').map(Number);
  return new Date(year, month - 1, day, 12, 0, 0, 0);
}

export function isoFromLocalDate(date: Date): string {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
}

export function shiftMonth(month: string, amount: number): string {
  const [year, value] = month.split('-').map(Number);
  const date = new Date(year, value - 1 + amount, 1, 12, 0, 0, 0);
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}`;
}

export function monthLabel(month: string): string {
  const [year, value] = month.split('-').map(Number);
  return new Intl.DateTimeFormat('pt-BR', { month: 'long', year: 'numeric' }).format(new Date(year, value - 1, 1, 12));
}

export function decimalAtScale(value: string, scale: number, positive = false, label = 'Valor'): string {
  try {
    const parsed = parseDecimalInput(value, { scale, positive });
    return parsed.toFixed();
  } catch (error) {
    throw new Error(error instanceof Error ? `${label}: ${error.message.toLowerCase()}` : `${label} inválido.`);
  }
}

export function moneyAtTwoDecimals(value: string, positive = false, label = 'Valor'): string {
  return decimalAtScale(value, 2, positive, label);
}

export function roundedMoney(value: Decimal): string {
  return value.toDecimalPlaces(2, Decimal.ROUND_HALF_UP).toFixed(2);
}

export function optionalText(value: string, max: number): string | null {
  const trimmed = value.trim();
  return trimmed ? trimmed.slice(0, max) : null;
}

export function orderStatusLabel(status: OrderStatus): string { return status; }

export const paymentMethodLabels: Record<PaymentMethod, string> = {
  pix: 'Pix',
  cash: 'Dinheiro',
  card: 'Cartão',
  bank_transfer: 'Transferência bancária',
  other: 'Outro',
};

export const roleLabels: Record<MembershipRole, string> = {
  owner: 'Proprietário',
  admin: 'Administração',
  production: 'Produção',
  finance: 'Financeiro',
  viewer: 'Leitura',
};

export function orderTotalLabel(order: OrderDto): string {
  return `${formatCurrency(order.total_amount)} · ${order.currency}`;
}

export function csvCell(value: unknown): string {
  const text = value === null || value === undefined ? '' : String(value);
  return `"${text.replace(/"/g, '""')}"`;
}

export function ordersCsv(orders: OrderDto[], includeFinancial: boolean): string {
  const headers = ['Código', 'Cliente', 'Título', 'Status', 'Data do pedido', 'Produção', 'Entrega'];
  if (includeFinancial) headers.push('Subtotal', 'Desconto', 'Frete', 'Total', 'Recebido', 'Saldo', 'Moeda');
  const rows = orders.map((order) => {
    const row = [order.code, order.client_name, order.title, order.status, formatDate(order.order_date),
      formatDate(order.production_date), formatDate(order.delivery_date)];
    if (includeFinancial) row.push(formatCurrency(order.subtotal), formatCurrency(order.discount_amount),
      formatCurrency(order.shipping_amount), formatCurrency(order.total_amount), formatCurrency(order.paid_amount),
      formatCurrency(order.balance_amount), order.currency);
    return row;
  });
  return [headers, ...rows].map((row) => row.map(csvCell).join(';')).join('\r\n');
}

export function downloadCsv(filename: string, content: string): void {
  const blob = new Blob([`\uFEFF${content}`], { type: 'text/csv;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement('a');
  anchor.href = url;
  anchor.download = filename;
  anchor.click();
  URL.revokeObjectURL(url);
}

export function monthOf(value: string | null): string | null {
  return value && /^\d{4}-\d{2}-\d{2}$/.test(value) ? value.slice(0, 7) : null;
}
