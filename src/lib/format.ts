import { formatDecimal } from './decimal';

export function formatNumber(value: string | number | null | undefined): string {
  return formatDecimal(value, 2);
}

export function formatCurrency(value: string | number | null | undefined): string {
  const text = formatDecimal(value, 2, true);
  return text === '—' ? text : `R$ ${text}`;
}

export function formatDate(value: string | null | undefined): string {
  if (!value) return '—';
  const isoDate = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (isoDate) return `${isoDate[3]}/${isoDate[2]}/${isoDate[1]}`;
  const date = new Date(value);
  return Number.isNaN(date.getTime())
    ? '—'
    : new Intl.DateTimeFormat('pt-BR', { dateStyle: 'medium' }).format(date);
}

export function initials(value: string | null | undefined): string {
  const parts = (value ?? '').trim().split(/\s+/).filter(Boolean);
  if (!parts.length) return 'VM';
  return parts.slice(0, 2).map((part) => part[0]?.toUpperCase()).join('');
}
