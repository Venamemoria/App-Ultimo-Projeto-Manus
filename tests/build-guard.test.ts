import { spawnSync } from 'node:child_process';
import { cwd, env, execPath } from 'node:process';
import { expect, it } from 'vitest';

it('bloqueia a compilação antes de incluir uma chave privada no frontend', () => {
  const result = spawnSync(execPath, ['node_modules/vite/bin/vite.js', 'build'], {
    cwd: cwd(),
    env: { ...env, VITE_SUPABASE_ANON_KEY: 'sb_secret_rejected_by_build_guard' },
    encoding: 'utf8',
    timeout: 15_000,
  });
  expect(result.status).not.toBe(0);
  expect(result.stderr).toContain('Build bloqueado para não expor uma chave privada');
  expect(result.stdout).not.toContain('building client environment for production');
});
