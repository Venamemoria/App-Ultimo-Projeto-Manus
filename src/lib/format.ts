const numberFormatter = new Intl.NumberFormat('pt-BR', {
  maximumFractionDigits: 2,
});

const currencyFormatter = new Intl.NumberFormat('pt-BR', {
  style: 'currency',
  currency: 'BRL',
  maximumFractionDigits: 2,
});

export function formatNumber(value: string | number | null | undefined): string {
  if (value === null || value === undefined || value === '') return '—';
  const parsed = typeof value === 'number' ? value : Number(value);
  return Number.isFinite(parsed) ? numberFormatter.format(parsed) : '—';
}

export function formatCurrency(value: string | number | null | undefined): string {
  if (value === null || value === undefined || value === '') return '—';
  const parsed = typeof value === 'number' ? value : Number(value);
  return Number.isFinite(parsed) ? currencyFormatter.format(parsed) : '—';
}

export function formatDate(value: string | null | undefined): string {
  if (!value) return '—';
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
