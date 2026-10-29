# Primeira interface — autenticação e organização

A fundação Supabase aplicada está conectada a uma SPA Vite/React/Tailwind. As páginas atuais são Painel, Entrar, Recuperar acesso e Conta. Somente essas rotas estão no manifesto e na navegação; módulos futuros não aparecem como páginas vazias.

A sessão é recebida pelo Supabase Auth e validada por `getUser` antes de liberar rotas privadas. O provider consulta associações do usuário corrente sob RLS, permite escolher somente organizações autorizadas e cria organização própria por `vm_create_organization`. Cache e seleção são limpos em troca de usuário e logout. Produção/financeiro/leitura são papéis provenientes do banco, não privilégios atribuídos por cadastro público.

O cadastro real respeita confirmação de e-mail; recuperação usa o evento do provedor e uma sessão validada. Em iframe sem localStorage, o armazenamento é limitado à memória da aba com aviso visível. O build rejeita chave privada antes de produzir o frontend. Nenhuma chave de serviço, conexão de banco ou token administrativo é importado pelo aplicativo.

Evidência: `pnpm typecheck` passou; `pnpm test` passou com cinco testes em dois arquivos, cobrindo URL, redirects e rejeição de chaves privadas no cliente e antes da compilação; `pnpm build` gerou dist. O Vite retornou HTTP 200 e `/manus-routes.json` serviu o JSON de quatro rotas, não HTML de fallback. A prévia de entrada foi aberta para conferir a correção observada na configuração e mostrou a UI desconectada sem erro de Supabase. O bundle medido foi de 541,70 kB antes de gzip e 158,73 kB com gzip; o Vite emitiu um aviso de tamanho, sem erro de build.

Os retornos exatos de confirmação e recuperação foram salvos e conferidos no painel Supabase. Não foi executado cadastro fictício, login com credencial do usuário ou gravação de dados de teste no banco. A conclusão do primeiro acesso real permanece pendente no TODO. Não há publicação confirmada.
