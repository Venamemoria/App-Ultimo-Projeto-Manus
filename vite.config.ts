import { Buffer } from 'node:buffer';
import { cwd } from 'node:process';
import { defineConfig, loadEnv } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';
import { fileURLToPath, URL } from 'node:url';

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, cwd(), 'VITE_');
  const key = env.VITE_SUPABASE_ANON_KEY?.trim();
  if (key) {
    let publicKey = key.startsWith('sb_publishable_');
    if (!publicKey && key.split('.').length === 3) {
      try {
        publicKey = JSON.parse(Buffer.from(key.split('.')[1], 'base64url').toString('utf8')).role === 'anon';
      } catch { publicKey = false; }
    }
    if (!publicKey) throw new Error('Use somente a chave pública anon/publishable. Build bloqueado para não expor uma chave privada.');
  } else if (mode !== 'test') {
    throw new Error('Configure VITE_SUPABASE_ANON_KEY antes de iniciar ou compilar o aplicativo.');
  }
  return {
    plugins: [react(), tailwindcss()],
    resolve: { alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) } },
    build: {
      rollupOptions: {
        output: {
          manualChunks: {
            react: ['react', 'react-dom', 'react-router-dom'],
            supabase: ['@supabase/supabase-js'],
            query: ['@tanstack/react-query'],
          },
        },
      },
    },
    server: { host: '0.0.0.0', port: 3000, strictPort: true },
  };
});
