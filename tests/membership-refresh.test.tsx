// @vitest-environment happy-dom
import { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { QueryClient } from '@tanstack/react-query';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { MembershipRole } from '../src/lib/types';

const transport = vi.hoisted(() => ({
  requests: [] as Array<(value: unknown) => void>,
  user: { id: 'test-user' },
}));

// Isolated transport double: no credentials, production records or network.
vi.mock('../src/lib/supabase', () => ({
  authStorageWarning: null,
  supabaseConfigError: null,
  supabase: {
    auth: {
      onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
      getSession: async () => ({ data: { session: { access_token: 'test', user: transport.user } }, error: null }),
      getUser: async () => ({ data: { user: transport.user }, error: null }),
    },
    from: () => ({ select: () => ({ eq: () => ({ order: () => new Promise((resolve) => transport.requests.push(resolve)) }) }) }),
  },
}));

import { AuthProvider, useSession } from '../src/app/AuthProvider';

function Probe() {
  const { currentMembershipRole, organizationId, error } = useSession();
  return <div data-testid="state">{`${currentMembershipRole ?? 'none'}:${organizationId ?? 'none'}:${error ? 'error' : 'ok'}`}</div>;
}

function membership(role: MembershipRole) {
  return { id: 'membership', organization_id: 'organization', user_id: transport.user.id, role,
    created_at: '2026-01-01T00:00:00Z', organization: { id: 'organization', name: 'Local test' } };
}

describe('revalidação dos papéis da sessão', () => {
  let container: HTMLDivElement;
  let root: Root;
  let queryClient: QueryClient;
  const state = () => container.querySelector('[data-testid="state"]')?.textContent;
  beforeEach(() => {
    transport.requests.length = 0;
    Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
    Object.defineProperty(document, 'visibilityState', { configurable: true, value: 'visible' });
    container = document.createElement('div');
    document.body.append(container);
    root = createRoot(container);
    queryClient = new QueryClient();
  });
  afterEach(async () => {
    await act(async () => root.unmount());
    queryClient.clear();
    container.remove();
    vi.useRealTimers();
  });

  it('invalida cache na troca de papel, ignora resposta antiga e nega acesso em erro', async () => {
    await act(async () => root.render(<AuthProvider queryClient={queryClient}><Probe /></AuthProvider>));
    expect(transport.requests).toHaveLength(1);
    await act(async () => transport.requests[0]({ data: [membership('owner')], error: null }));
    expect(state()).toBe('owner:organization:ok');
    queryClient.setQueryData(['protected'], 'previously authorized data');

    await act(async () => window.dispatchEvent(new Event('focus')));
    await act(async () => window.dispatchEvent(new Event('focus')));
    expect(transport.requests).toHaveLength(3);
    await act(async () => transport.requests[2]({ data: [membership('production')], error: null }));
    expect(state()).toBe('production:organization:ok');
    expect(queryClient.getQueryData(['protected'])).toBeUndefined();
    await act(async () => transport.requests[1]({ data: [membership('owner')], error: null }));
    expect(state()).toBe('production:organization:ok');

    queryClient.setQueryData(['protected'], 'stale');
    await act(async () => window.dispatchEvent(new Event('focus')));
    await act(async () => transport.requests[3]({ data: null, error: new Error('network') }));
    expect(state()).toBe('none:none:error');
    expect(queryClient.getQueryData(['protected'])).toBeUndefined();
    await act(async () => window.dispatchEvent(new Event('focus')));
    await act(async () => transport.requests[4]({ data: [membership('finance')], error: null }));
    expect(state()).toBe('finance:organization:ok');
  });

  it('revalida a cada 30 segundos e remove listeners ao desmontar', async () => {
    vi.useFakeTimers();
    await act(async () => root.render(<AuthProvider queryClient={queryClient}><Probe /></AuthProvider>));
    await act(async () => transport.requests[0]({ data: [membership('owner')], error: null }));
    await act(async () => vi.advanceTimersByTime(30_000));
    expect(transport.requests).toHaveLength(2);
    await act(async () => root.unmount());
    await act(async () => window.dispatchEvent(new Event('focus')));
    await act(async () => vi.advanceTimersByTime(30_000));
    expect(transport.requests).toHaveLength(2);
    await act(async () => transport.requests[1]({ data: [membership('owner')], error: null }));
  });
});
