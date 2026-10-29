import { describe, expect, it } from 'vitest';
import { getSafeNextPath } from '../src/lib/supabase';

describe('retorno de navegação após login', () => {
  it('mantém apenas as páginas internas implementadas', () => {
    for (const path of ['/conta', '/estoque', '/compras', '/produtos', '/clientes', '/fornecedores', '/pedidos', '/producao', '/agenda'] as const) expect(getSafeNextPath(path)).toBe(path);
    expect(getSafeNextPath('/')).toBe('/');
  });
  it('nega redirecionamento externo, relativo ou não implementado', () => {
    for (const path of ['https://example.com', '//example.com', '/pedidos/:id', '/%2fexample.com', null]) expect(getSafeNextPath(path)).toBe('/');
  });
});
