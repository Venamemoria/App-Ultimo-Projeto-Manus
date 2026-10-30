export const QUOTE_PAGE_SIZE = 20;

type QuotePageRow = { quote_id: string; created_at: string };

export function visibleQuotePage<T extends QuotePageRow>(received: T[]) {
  const items = received.slice(0, QUOTE_PAGE_SIZE);
  const last = items.at(-1);
  const cursor = received.length > QUOTE_PAGE_SIZE && last
    ? { at: last.created_at, id: last.quote_id }
    : null;
  return { items, cursor };
}
