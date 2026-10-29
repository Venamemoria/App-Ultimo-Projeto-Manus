import { describe, expect, it } from 'vitest';
import { assertSafeAnonKey, getSafeNextPath, normalizeSupabaseUrl } from '../src/lib/supabase';

const validHost = 'abcdefghijklmnopqrst.supabase.co';

function jwt(payload: Record<string, unknown>): string {
  const encode = (value: string) => globalThis.btoa(value).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
  return `${encode(JSON.stringify({ alg: 'HS256', typ: 'JWT' }))}.${encode(JSON.stringify(payload))}.signature`;
}

describe('configuração segura do auth', () => {
  it('normaliza somente host de projeto Supabase com exatamente 20 caracteres', () => {
    expect(normalizeSupabaseUrl(validHost)).toBe(`https://${validHost}`);
    expect(normalizeSupabaseUrl(`[https://${validHost}]`)).toBe(`https://${validHost}`);
    expect(normalizeSupabaseUrl(`https://${validHost}/`)).toBe(`https://${validHost}`);
    expect(normalizeSupabaseUrl(`https://[${validHost}]`)).toBe(`https://${validHost}`);
    expect(normalizeSupabaseUrl(`[abcdefghijklmnopqrst].supabase.co`)).toBe(`https://${validHost}`);
  });

  it('rejeita URL fora do formato de projeto Supabase', () => {
    expect(() => normalizeSupabaseUrl('https://example.com')).toThrow();
    expect(() => normalizeSupabaseUrl(`https://${validHost}.evil.example`)).toThrow();
    expect(() => normalizeSupabaseUrl('https://abcdefghijklmnopqrs.supabase.co')).toThrow();
    expect(() => normalizeSupabaseUrl(`${validHost} uvwxyzabcdefghijklmn.supabase.co`)).toThrow();
  });

  it('bloqueia segredo sb_secret e JWT service_role no bundle', () => {
    expect(() => assertSafeAnonKey('sb_secret_not_for_browser')).toThrow();
    expect(() => assertSafeAnonKey(jwt({ role: 'service_role' }))).toThrow();
    expect(assertSafeAnonKey(jwt({ role: 'anon' }))).toContain('.');
  });

  it('aceita somente redirects locais previstos', () => {
    expect(getSafeNextPath('/conta')).toBe('/conta');
    expect(getSafeNextPath('/')).toBe('/');
    expect(getSafeNextPath('https://evil.example')).toBe('/');
    expect(getSafeNextPath('/conta?next=https://evil.example')).toBe('/');
    expect(getSafeNextPath('/admin')).toBe('/');
  });
});
