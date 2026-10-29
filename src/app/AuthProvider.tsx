import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import type { QueryClient } from '@tanstack/react-query';
import type { Session, User } from '@supabase/supabase-js';
import { authStorageWarning, supabase, supabaseConfigError } from '../lib/supabase';
import type { Membership, MembershipRole, Organization } from '../lib/types';

interface AuthResult {
  error: string | null;
}

interface SessionContextValue {
  loading: boolean;
  membershipsLoading: boolean;
  error: string | null;
  session: Session | null;
  user: User | null;
  organization: Organization | null;
  memberships: Membership[];
  currentMembership: Membership | null;
  currentMembershipRole: MembershipRole | null;
  organizationId: string | null;
  storageWarning: string | null;
  recoveryMode: boolean;
  refreshMemberships: () => Promise<void>;
  selectOrganization: (organizationId: string) => void;
  createOrganization: (name: string) => Promise<AuthResult>;
  signIn: (email: string, password: string) => Promise<AuthResult>;
  signUp: (email: string, password: string) => Promise<AuthResult & { confirmed: boolean }>;
  resetPassword: (email: string) => Promise<AuthResult>;
  updatePassword: (password: string) => Promise<AuthResult>;
  signOut: () => Promise<AuthResult>;
}

type MembershipRow = Omit<Membership, 'organization'> & {
  organization: Organization | Organization[] | null;
};

const SessionContext = createContext<SessionContextValue | undefined>(undefined);
let exchangePromise: Promise<{ error: Error | null }> | null = null;
let exchangeCode: string | null = null;

function exchangeCodeOnce(code: string): Promise<{ error: Error | null }> {
  if (exchangePromise && exchangeCode === code) return exchangePromise;
  exchangeCode = code;
  exchangePromise = (async () => {
    if (!supabase) return { error: new Error(supabaseConfigError ?? 'Supabase indisponível.') };
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    return { error: error ? new Error(error.message) : null };
  })();
  return exchangePromise;
}

function errorMessage(error: unknown): string {
  if (error && typeof error === 'object' && 'message' in error && typeof error.message === 'string') {
    return error.message;
  }
  return 'Não foi possível concluir esta ação agora.';
}

function publicAuthMessage(error: unknown): string {
  const message = errorMessage(error);
  if (/invalid login credentials/i.test(message)) return 'E-mail ou senha não conferem.';
  if (/email not confirmed/i.test(message)) return 'Confirme seu e-mail antes de entrar.';
  if (/already registered|user already registered/i.test(message)) return 'Este e-mail já possui cadastro. Tente entrar.';
  return message;
}

export function AuthProvider({ children, queryClient }: { children: ReactNode; queryClient: QueryClient }) {
  const [loading, setLoading] = useState(Boolean(supabase));
  const [membershipsLoading, setMembershipsLoading] = useState(false);
  const [runtimeError, setRuntimeError] = useState<string | null>(null);
  const [session, setSession] = useState<Session | null>(null);
  const [sessionCandidate, setSessionCandidate] = useState<Session | null>(null);
  const [initialized, setInitialized] = useState(false);
  const [memberships, setMemberships] = useState<Membership[]>([]);
  const [selectedOrganizationId, setSelectedOrganizationId] = useState<string | null>(null);
  const [recoveryMode, setRecoveryMode] = useState(false);
  const previousUserId = useRef<string | null>(null);

  useEffect(() => {
    if (!supabase) {
      setLoading(false);
      return;
    }
    const client = supabase;

    let mounted = true;
    const { data } = client.auth.onAuthStateChange((event, nextSession) => {
      if (!mounted) return;
      if (event === 'PASSWORD_RECOVERY') setRecoveryMode(true);
      if (event === 'SIGNED_OUT') setRecoveryMode(false);
      setSessionCandidate(nextSession);
    });

    const code = typeof window !== 'undefined' ? new URLSearchParams(window.location.search).get('code') : null;
    const initialize = async () => {
      const exchange = code ? await exchangeCodeOnce(code) : { error: null };
      const result = await client.auth.getSession();
      if (!mounted) return;

      if (result.error) setRuntimeError(publicAuthMessage(result.error));
      else if (exchange.error && !result.data.session) setRuntimeError('O link de autenticação expirou ou já foi utilizado. Solicite um novo e-mail.');
      setSessionCandidate(result.data.session);
      setInitialized(true);

      if (code && !exchange.error && typeof window !== 'undefined') {
        window.history.replaceState({}, document.title, `${window.location.pathname}${window.location.hash}`);
      }
    };
    void initialize();

    return () => {
      mounted = false;
      data.subscription.unsubscribe();
    };
  }, []);

  useEffect(() => {
    if (!supabase || !initialized) return;
    if (!sessionCandidate) {
      setSession(null);
      setLoading(false);
      return;
    }
    let active = true;
    setLoading(true);
    const validate = async () => {
      const { data, error } = await supabase!.auth.getUser(sessionCandidate.access_token);
      if (!active) return;
      if (error || !data.user || data.user.id !== sessionCandidate.user.id) {
        setSession(null);
        setRuntimeError('Sua sessão não pôde ser validada. Entre novamente.');
      } else {
        setSession({ ...sessionCandidate, user: data.user });
      }
      setLoading(false);
    };
    void validate().catch(() => {
      if (active) {
        setSession(null);
        setRuntimeError('Não foi possível validar a sessão. Verifique sua conexão.');
        setLoading(false);
      }
    });
    return () => { active = false; };
  }, [initialized, sessionCandidate]);

  const refreshMemberships = useCallback(async () => {
    if (!supabase || !session?.user.id) {
      setMemberships([]);
      return;
    }

    setMembershipsLoading(true);
    const { data, error } = await supabase
      .from('vm_memberships')
      .select('id, organization_id, user_id, role, created_at, organization:vm_organizations(id, name)')
      .eq('user_id', session.user.id)
      .order('created_at', { ascending: true });

    if (previousUserId.current !== session.user.id) return;
    if (error) {
      setRuntimeError(`Não foi possível carregar suas organizações: ${error.message}`);
      setMembershipsLoading(false);
      return;
    }

    const normalized = ((data ?? []) as unknown as MembershipRow[]).map((membership) => ({
      ...membership,
      organization: Array.isArray(membership.organization) ? membership.organization[0] ?? null : membership.organization,
    }));
    setMemberships(normalized);
    setRuntimeError(null);
    setMembershipsLoading(false);
  }, [session?.user.id]);

  useEffect(() => {
    const userId = session?.user.id ?? null;
    const changedUser = previousUserId.current !== userId;
    if (changedUser) {
      queryClient.clear();
      setSelectedOrganizationId(null);
      setMemberships([]);
      previousUserId.current = userId;
    }
    if (userId) void refreshMemberships();
  }, [queryClient, refreshMemberships, session?.user.id]);

  useEffect(() => {
    if (!memberships.length) {
      setSelectedOrganizationId(null);
      return;
    }
    if (!selectedOrganizationId || !memberships.some((membership) => membership.organization_id === selectedOrganizationId)) {
      setSelectedOrganizationId(memberships[0].organization_id);
    }
  }, [memberships, selectedOrganizationId]);

  const signIn = useCallback(async (email: string, password: string): Promise<AuthResult> => {
    if (!supabase) return { error: supabaseConfigError ?? 'Supabase não está configurado.' };
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) return { error: publicAuthMessage(error) };
    setRuntimeError(null);
    return { error: null };
  }, []);

  const signUp = useCallback(async (email: string, password: string): Promise<AuthResult & { confirmed: boolean }> => {
    if (!supabase) return { error: supabaseConfigError ?? 'Supabase não está configurado.', confirmed: false };
    const redirectTo = `${window.location.origin}/entrar`;
    const { data, error } = await supabase.auth.signUp({
      email,
      password,
      options: { emailRedirectTo: redirectTo },
    });
    if (error) return { error: publicAuthMessage(error), confirmed: false };
    setRuntimeError(null);
    return { error: null, confirmed: Boolean(data.session) };
  }, []);

  const resetPassword = useCallback(async (email: string): Promise<AuthResult> => {
    if (!supabase) return { error: supabaseConfigError ?? 'Supabase não está configurado.' };
    const redirectTo = `${window.location.origin}/recuperar`;
    const { error } = await supabase.auth.resetPasswordForEmail(email, { redirectTo });
    return error ? { error: publicAuthMessage(error) } : { error: null };
  }, []);

  const updatePassword = useCallback(async (password: string): Promise<AuthResult> => {
    if (!supabase) return { error: supabaseConfigError ?? 'Supabase não está configurado.' };
    const { error } = await supabase.auth.updateUser({ password });
    if (error) return { error: publicAuthMessage(error) };
    setRecoveryMode(false);
    return { error: null };
  }, []);

  const signOut = useCallback(async (): Promise<AuthResult> => {
    if (!supabase) return { error: supabaseConfigError ?? 'Supabase não está configurado.' };
    const { error } = await supabase.auth.signOut({ scope: 'local' });
    if (error) return { error: publicAuthMessage(error) };
    queryClient.clear();
    setSelectedOrganizationId(null);
    setMemberships([]);
    setSession(null);
    return { error: null };
  }, [queryClient]);

  const selectOrganization = useCallback((organizationId: string) => {
    if (memberships.some((membership) => membership.organization_id === organizationId)) {
      setSelectedOrganizationId(organizationId);
    }
  }, [memberships]);

  const createOrganization = useCallback(async (name: string): Promise<AuthResult> => {
    if (!supabase || !session) return { error: 'Entre novamente para criar uma organização.' };
    const { data, error } = await supabase.rpc('vm_create_organization', { p_name: name.trim() });
    if (error) return { error: publicAuthMessage(error) };

    const rows = Array.isArray(data) ? data : data ? [data] : [];
    const createdOrganizationId = (rows[0] as { organization_id?: string } | undefined)?.organization_id;
    await refreshMemberships();
    if (createdOrganizationId) setSelectedOrganizationId(createdOrganizationId);
    return { error: null };
  }, [refreshMemberships, session]);

  const currentMembership = memberships.find((membership) => membership.organization_id === selectedOrganizationId) ?? null;
  const value = useMemo<SessionContextValue>(() => ({
    loading,
    membershipsLoading,
    error: supabaseConfigError ?? runtimeError,
    session,
    user: session?.user ?? null,
    organization: currentMembership?.organization ?? null,
    memberships,
    currentMembership,
    currentMembershipRole: currentMembership?.role ?? null,
    organizationId: currentMembership?.organization_id ?? null,
    storageWarning: authStorageWarning,
    recoveryMode,
    refreshMemberships,
    selectOrganization,
    createOrganization,
    signIn,
    signUp,
    resetPassword,
    updatePassword,
    signOut,
  }), [createOrganization, currentMembership, loading, memberships, membershipsLoading, recoveryMode, refreshMemberships, resetPassword, runtimeError, selectOrganization, session, signIn, signOut, signUp, updatePassword]);

  return <SessionContext.Provider value={value}>{children}</SessionContext.Provider>;
}

export function useSession(): SessionContextValue {
  const context = useContext(SessionContext);
  if (!context) throw new Error('useSession deve ser usado dentro de AuthProvider.');
  return context;
}
