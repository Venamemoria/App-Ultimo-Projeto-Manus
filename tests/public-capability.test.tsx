// @vitest-environment happy-dom
import { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { usePublicCapability } from '../src/features/publicSales/usePublicCapability';
import { quoteBusinessDate } from '../src/features/publicSales/validity';

const firstToken = '550e8400-e29b-41d4-a716-446655440000';
const secondToken = '550e8400-e29b-41d4-a716-446655440001';
type Request = { token: string; resolve: (value: string | null) => void; reject: (reason: Error) => void };

function deferredRequests() {
  const requests: Request[] = [];
  const fetcher = (token: string) => new Promise<string | null>((resolve, reject) => { requests.push({ token, resolve, reject }); });
  return { requests, fetcher };
}

function Probe({ token, fetcher }: { token: string; fetcher: (token: string) => Promise<string | null> }) {
  const { data, loading, error, refresh } = usePublicCapability(token, fetcher);
  return <div><span data-testid="state">{loading ? 'loading' : error ? 'error' : data ?? 'unavailable'}</span><button onClick={() => void refresh()}>refresh</button></div>;
}

describe('validade civil de orçamentos', () => {
  it('usa o dia de São Paulo nos dois lados da meia-noite, independentemente do fuso do navegador', () => {
    expect(quoteBusinessDate(new Date('2026-10-31T02:59:59.999Z'))).toBe('2026-10-30');
    expect(quoteBusinessDate(new Date('2026-10-31T03:00:00.000Z'))).toBe('2026-10-31');
  });

  it('considera o histórico real de horário de verão de São Paulo', () => {
    expect(quoteBusinessDate(new Date('2018-02-18T02:30:00.000Z'))).toBe('2018-02-17');
    expect(quoteBusinessDate(new Date('2018-02-18T03:00:00.000Z'))).toBe('2018-02-18');
  });
});

describe('revalidação de capabilities públicas', () => {
  let container: HTMLDivElement;
  let root: Root;
  beforeEach(() => {
    Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
    container = document.createElement('div');
    document.body.append(container);
    root = createRoot(container);
  });
  afterEach(async () => {
    await act(async () => root.unmount());
    container.remove();
    vi.useRealTimers();
  });
  const state = () => container.querySelector('[data-testid="state"]')?.textContent;
  const clickRefresh = async () => { await act(async () => container.querySelector('button')?.click()); };

  it('descarta dados quando a revalidação informa revogação ou falha de rede', async () => {
    const { requests, fetcher } = deferredRequests();
    await act(async () => root.render(<Probe token={firstToken} fetcher={fetcher}/>));
    expect(state()).toBe('loading');
    await act(async () => requests[0].resolve('conteúdo autorizado'));
    expect(state()).toBe('conteúdo autorizado');
    await clickRefresh();
    await act(async () => requests[1].resolve(null));
    expect(state()).toBe('unavailable');
    await clickRefresh();
    await act(async () => requests[2].resolve('conteúdo autorizado'));
    await clickRefresh();
    await act(async () => requests[3].reject(new Error('rede indisponível')));
    expect(state()).toBe('error');
  });

  it('impede que respostas antigas reabram um link revogado ou outro token', async () => {
    const { requests, fetcher } = deferredRequests();
    await act(async () => root.render(<Probe token={firstToken} fetcher={fetcher}/>));
    await act(async () => requests[0].resolve('primeiro link'));
    await clickRefresh();
    await clickRefresh();
    await act(async () => requests[2].resolve(null));
    await act(async () => requests[1].resolve('resposta antiga'));
    expect(state()).toBe('unavailable');
    await clickRefresh();
    await act(async () => root.render(<Probe token={secondToken} fetcher={fetcher}/>));
    expect(state()).toBe('loading');
    expect(requests[4].token).toBe(secondToken);
    await act(async () => requests[4].resolve('segundo link'));
    await act(async () => requests[3].resolve('primeiro link atrasado'));
    expect(state()).toBe('segundo link');
  });

  it('revalida ao recuperar foco e a cada 30 segundos, sem manter listeners após desmontagem', async () => {
    vi.useFakeTimers();
    Object.defineProperty(document, 'visibilityState', { configurable: true, value: 'visible' });
    const { requests, fetcher } = deferredRequests();
    await act(async () => root.render(<Probe token={firstToken} fetcher={fetcher}/>));
    await act(async () => requests[0].resolve('ativo'));
    await act(async () => window.dispatchEvent(new Event('focus')));
    expect(requests).toHaveLength(2);
    await act(async () => requests[1].resolve(null));
    expect(state()).toBe('unavailable');
    await act(async () => vi.advanceTimersByTime(30_000));
    expect(requests).toHaveLength(3);
    await act(async () => root.unmount());
    await act(async () => window.dispatchEvent(new Event('focus')));
    await act(async () => vi.advanceTimersByTime(30_000));
    expect(requests).toHaveLength(3);
    // The pending response is ignored after unmount.
    await act(async () => requests[2].resolve('não deve voltar'));
  });
});
