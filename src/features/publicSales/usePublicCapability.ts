import { useCallback, useEffect, useRef, useState } from 'react';
import { isUuid } from './api';

const REFRESH_INTERVAL_MS = 30_000;

type State<T> = { token: string; data: T | null; loading: boolean; error: string };

/**
 * Public capabilities can expire or be revoked while a tab stays open.
 * Revalidate on focus, visibility and a short interval. Never restore a stale
 * response after a newer request, route change, unmount, or network failure.
 * This is a UI aid: authorization is always decided by the database RPC.
 */
export function usePublicCapability<T>(token: string, fetcher: (token: string) => Promise<T | null>) {
  const [state, setState] = useState<State<T>>({ token, data: null, loading: true, error: '' });
  const generation = useRef(0);

  const refresh = useCallback(async (showLoading = false) => {
    const request = ++generation.current;
    setState((previous) => ({
      token,
      data: previous.token === token ? previous.data : null,
      loading: showLoading || previous.token !== token,
      error: '',
    }));
    try {
      if (!isUuid(token)) {
        if (generation.current === request) setState({ token, data: null, loading: false, error: '' });
        return;
      }
      const data = await fetcher(token);
      if (generation.current === request) setState({ token, data, loading: false, error: '' });
    } catch {
      if (generation.current === request) {
        setState({ token, data: null, loading: false, error: 'Não foi possível confirmar a validade do link. Tente novamente.' });
      }
    }
  }, [token, fetcher]);

  useEffect(() => {
    void refresh(true);
    const onFocus = () => { void refresh(); };
    const onVisibility = () => { if (document.visibilityState === 'visible') void refresh(); };
    const timer = window.setInterval(() => { if (document.visibilityState === 'visible') void refresh(); }, REFRESH_INTERVAL_MS);
    window.addEventListener('focus', onFocus);
    document.addEventListener('visibilitychange', onVisibility);
    return () => {
      generation.current += 1;
      window.clearInterval(timer);
      window.removeEventListener('focus', onFocus);
      document.removeEventListener('visibilitychange', onVisibility);
    };
  }, [refresh]);

  // React effects run after rendering; never render the previous token's data
  // even for the first frame after client-side navigation to another link.
  const current = state.token === token ? state : { token, data: null, loading: true, error: '' };
  return { ...current, refresh };
}
