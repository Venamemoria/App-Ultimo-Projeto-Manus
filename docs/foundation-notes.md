# Fundação técnica — status atual

A migration `20261029203500_foundation` foi aplicada ao projeto Supabase Ve no atelie em 29/10/2026 às 17:58 BRT. A execução foi transacional e a verificação efetiva passou: nove tabelas com RLS, 14 políticas, cinco RPCs com execução permitida a authenticated e negada a anon. Leitura anônima de insumos, update direto do saldo e insert/update/delete direto em movimentos de estoque estão bloqueados. O relatório de metadados está em `foundation-verification.json`.

Nenhum usuário, organização, insumo, produto ou pedido de demonstração foi criado. Antes da aplicação, consulta somente leitura confirmou o schema de aplicação vazio, zero usuários em auth.users e publicação supabase_realtime existente. Nenhum reset, exclusão de dados ou redefinição de senha foi necessário.

A migration passou também em parser PostgreSQL: 92 comandos SQL e sete funções PL/pgSQL. A verificação sintática não foi usada como substituta da execução: a aplicação e a inspeção das permissões ocorreram no Supabase real.

## Conexão

Os parâmetros corretos de Session pooler foram copiados do diálogo Connect do próprio projeto: cluster aws-1 da região sa-east-1, porta 5432. A normalização limitada em memória remove delimitadores de exemplo das entradas protegidas; os valores armazenados não foram copiados para arquivos ou Git. A conexão usa SSL e a senha já fornecida. Parâmetros públicos de projeto estão em `supabase/project.json`.

A URI direta inicialmente recebida exigia IPv6, não alcançável pela rede do ambiente; o host aws-0 informado posteriormente não correspondia ao projeto. O navegador retornou após indisponibilidade temporária e permitiu verificar o host exato, sem inferi-lo pela região. Para aplicar a migration, não foi necessário executar SQL pelo navegador nem modificar a infraestrutura.

## Segurança

RLS combina grants e políticas por operação. Helpers de membership ficam em schema privado para evitar recursão e exposição desnecessária. Funções com privilégios elevados fixam search_path e usam nomes qualificados; autenticação, papel e organização são validados no banco. Chaves privadas nunca são incluídas no navegador.[1]

## Referências

[1]: https://supabase.com/docs/guides/database/postgres/row-level-security "Supabase — Row Level Security"
