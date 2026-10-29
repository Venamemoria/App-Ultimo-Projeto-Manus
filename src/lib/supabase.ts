import { createClient, type SupabaseClient } from '@supabase/supabase-js';

const projectHostPattern = /^[a-z0-9]{20}\.supabase\.co$/i;

type AuthStorage = {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
};

class MemoryStorage implements AuthStorage {
  private readonly values = new Map<string, string>();

  getItem(key: string): string | null {
    return this.values.get(key) ?? null;
  }

  setItem(key: string, value: string): void {
    this.values.set(key, value);
  }

  removeItem(key: string): void {
    this.values.delete(key);
  }
}

function getAuthStorage(): { storage: AuthStorage; warning: string | null; mode: 'local' | 'memory' } {
  const fallback = new MemoryStorage();

  if (typeof window === 'undefined') {
    return {
      storage: fallback,
      mode: 'memory',
      warning: 'Este ambiente não disponibiliza armazenamento local. A sessão ficará apenas na memória desta aba.',
    };
  }

  try {
    const localStorage = window.localStorage;
    if (!localStorage) throw new Error('localStorage indisponível');
    const probe = `vm-storage-${Date.now()}`;
    localStorage.setItem(probe, 'ok');
    localStorage.removeItem(probe);
    return { storage: localStorage, mode: 'local', warning: null };
  } catch {
    return {
      storage: fallback,
      mode: 'memory',
      warning: 'O armazenamento local foi bloqueado neste iframe. A sessão ficará apenas na memória desta aba.',
    };
  }
}

export function normalizeSupabaseUrl(raw: string | undefined): string {
  if (!raw?.trim()) {
    throw new Error('VITE_SUPABASE_URL não foi configurada.');
  }

  const candidate = raw.trim().replace(/[\[\]]/g, '');
  const hosts = new Set(candidate.match(/(?<![a-z0-9])[a-z0-9]{20}\.supabase\.co(?![a-z0-9.-])/gi)?.map((host) => host.toLowerCase()) ?? []);
  if (hosts.size !== 1) {
    throw new Error('VITE_SUPABASE_URL deve ser exatamente o host de um projeto Supabase válido.');
  }

  const host = [...hosts][0];
  if (!projectHostPattern.test(host)) throw new Error('Host do Supabase inválido.');
  return `https://${host}`;
}

function decodeJwtPayload(value: string): Record<string, unknown> | null {
  const parts = value.split('.');
  if (parts.length !== 3 || typeof globalThis.atob !== 'function') return null;

  try {
    const normalized = parts[1].replace(/-/g, '+').replace(/_/g, '/');
    const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, '=');
    const decoded = globalThis.atob(padded);
    const bytes = Array.from(decoded, (character) => `%${character.charCodeAt(0).toString(16).padStart(2, '0')}`);
    return JSON.parse(decodeURIComponent(bytes.join(''))) as Record<string, unknown>;
  } catch {
    return null;
  }
}

export function assertSafeAnonKey(raw: string | undefined): string {
  const value = raw?.trim() ?? '';
  if (!value) throw new Error('VITE_SUPABASE_ANON_KEY não foi configurada.');
  if (/sb_secret/i.test(value) || /\bservice_role\b/i.test(value)) {
    throw new Error('A chave configurada não é pública e foi bloqueada no frontend.');
  }

  const payload = decodeJwtPayload(value);
  if (payload?.role === 'service_role') {
    throw new Error('Uma chave JWT service_role nunca pode ser exposta pelo frontend.');
  }

  return value;
}

export function getSafeNextPath(value: string | null | undefined): '/' | '/conta' {
  return value === '/conta' ? '/conta' : '/';
}

export function readSupabaseConfig(): { url: string; anonKey: string } {
  return {
    url: normalizeSupabaseUrl(import.meta.env.VITE_SUPABASE_URL),
    anonKey: assertSafeAnonKey(import.meta.env.VITE_SUPABASE_ANON_KEY),
  };
}

const authStorage = getAuthStorage();
export const authStorageMode = authStorage.mode;
export const authStorageWarning = authStorage.warning;

let configError: string | null = null;
let configuredClient: SupabaseClient | null = null;

try {
  const config = readSupabaseConfig();
  configuredClient = createClient(config.url, config.anonKey, {
    auth: {
      autoRefreshToken: true,
      persistSession: true,
      detectSessionInUrl: true,
      storage: authStorage.storage,
    },
  });
} catch (error) {
  configError = error instanceof Error ? error.message : 'Configuração do Supabase inválida.';
}

export const supabase = configuredClient;
export const supabaseConfigError = configError;
