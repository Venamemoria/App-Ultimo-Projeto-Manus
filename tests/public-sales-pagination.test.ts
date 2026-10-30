import { describe, expect, it } from 'vitest';
import { QUOTE_PAGE_SIZE, visibleQuotePage } from '../src/features/publicSales/pagination';

type Row = { quote_id: string; created_at: string };
const makeRows = (count: number): Row[] => Array.from({ length: count }, (_, index) => ({
  quote_id: `quote-${index + 1}`,
  created_at: `2026-10-${String(29 - Math.floor(index / 24)).padStart(2, '0')}T12:${String(index % 60).padStart(2, '0')}:00Z`,
}));

describe('paginação de orçamentos', () => {
  it('não oferece continuação quando não há resultados', () => {
    expect(visibleQuotePage([])).toEqual({ items: [], cursor: null });
  });

  it('encerra na última página curta', () => {
    const received = makeRows(7);
    expect(visibleQuotePage(received)).toEqual({ items: received, cursor: null });
  });

  it('encerra quando há exatamente vinte resultados', () => {
    const received = makeRows(QUOTE_PAGE_SIZE);
    expect(visibleQuotePage(received)).toEqual({ items: received, cursor: null });
  });

  it('mostra no máximo vinte linhas e ancora o cursor na vigésima quando há mais', () => {
    const received = makeRows(QUOTE_PAGE_SIZE + 1);
    const page = visibleQuotePage(received);
    expect(page.items).toHaveLength(QUOTE_PAGE_SIZE);
    expect(page.items).not.toContain(received[QUOTE_PAGE_SIZE]);
    expect(page.cursor).toEqual({ at: received[QUOTE_PAGE_SIZE - 1].created_at, id: received[QUOTE_PAGE_SIZE - 1].quote_id });
  });
});
