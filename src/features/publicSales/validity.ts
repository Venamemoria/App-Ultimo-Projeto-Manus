/** Client-side guidance only. The database clock is authoritative. */
const businessDateFormatter = new Intl.DateTimeFormat('en-CA', {
  timeZone: 'America/Sao_Paulo',
  year: 'numeric',
  month: '2-digit',
  day: '2-digit',
});

export function quoteBusinessDate(at = new Date()): string {
  const parts = businessDateFormatter.formatToParts(at);
  const part = (name: Intl.DateTimeFormatPartTypes) => parts.find((value) => value.type === name)?.value ?? '';
  return `${part('year')}-${part('month')}-${part('day')}`;
}
