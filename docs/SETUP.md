# Executar e migrar o ERP

O projeto usa Vite, React, TypeScript, TailwindCSS, React Router e Supabase. Não usa TanStack Start, Nitro, MySQL ou autenticação Manus para regras de negócio. O código está no repositório informado pelo proprietário; o README inicial e sua história foram preservados.

## Frontend

Use uma versão de Node compatível com Vite 7 e pnpm 11.25.0. Instale com `pnpm install --frozen-lockfile`, copie `.env.example` para `.env.local` fora do Git e preencha somente as variáveis públicas VITE_SUPABASE_URL e VITE_SUPABASE_ANON_KEY. A URL é a base HTTPS do projeto Supabase, sem `/rest/v1`; a chave precisa ser anon/publishable. O build recusa uma chave privada no campo público.

Execute `pnpm dev` para desenvolvimento, `pnpm typecheck` e `pnpm test` para checks locais, e `pnpm build` para gerar `dist/`. O Vite escuta a porta 3000 nesta tarefa. Rotas de página exigem fallback SPA para index.html; assets e APIs inexistentes não devem cair nesse fallback. O manifesto de rotas fica em public/manus-routes.json.

## Supabase

O frontend se conecta diretamente ao projeto Supabase escolhido pelo proprietário, com sessão Supabase Auth e RLS. Migrations ficam em supabase/migrations e são incrementais/transacionais. NÃO usar reset em um banco com dados. As migrations já aplicadas e a evidência de cada fatia ficam em docs. Um clone do frontend não copia automaticamente tabelas, contas, arquivos ou secrets para outro projeto Supabase.

Configure no Supabase Auth as URLs exatas de retorno de confirmação/recuperação da origem onde o app roda. O código usa `/` e `/recuperar`; mudanças de origem, inclusive migração/publicação, exigem atualizar a allowlist preservando as outras configurações. Confirmação de e-mail não foi desabilitada. SMTP e credenciais reais dependem do projeto autorizado.

Somente scripts administrativos e futuras Edge Functions usam SUPABASE_DATABASE_URL e SUPABASE_SERVICE_ROLE_KEY. Nunca prefixar essas variáveis com VITE_, enviá-las ao Git ou incluí-las no navegador. Integrações externas permanecem inativas até código, configuração e autorização próprios; a documentação dos provedores não é uma ativação.

## QA PostgreSQL opcional

Os testes de banco são separados do app. Em Linux com PostgreSQL 16, crie um venv e instale scripts/requirements.txt. O runner scripts/run_database_tests.py usa somente um cluster marcado em `.local/test-db`, por socket Unix, database `vm_test` e sem listener TCP. Fixtures nunca vão ao Supabase. Use a suite pertinente e `--stop` ao terminar; não configurar um DSN de produção como ambiente de teste.

## Importação em Lovable

Importe o código Git e configure as duas variáveis públicas para o mesmo backend Supabase autorizado, ou aplique as migrations cuidadosamente em outro backend dedicado. Fotos/arquivos de negócio devem continuar no Storage associado; a marca do app está em public/ e é migrável com o código. Não há dependência de API Manus para login, estoque ou registros comerciais. app.config.ts contém somente metadado de marca da plataforma e não é uma regra de negócio.

A arquitetura preserva a stack solicitada e facilita a migração; a importação em Lovable ainda não foi executada/verificada nesta tarefa, portanto não se declara compatibilidade absoluta de ambiente sem o teste no destino. Publicação e domínio final também são etapas separadas do salvamento Git.
