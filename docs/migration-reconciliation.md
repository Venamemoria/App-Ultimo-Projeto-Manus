# Reconciliação do histórico de migrações

## Estado verificado em 30/10/2026

No projeto `kasupbixvesyyrvmfzgm`, o registro próprio `public.vm_schema_migrations` continha as dez versões até `20261030005000_finance_summary`, mas o registro do Supabase CLI não existia. Não foi reaplicada nenhuma migração de negócio.

Antes de reparar o histórico, as dez migrations do Git foram executadas em um PostgreSQL 16 isolado e comparadas com o PostgreSQL 17 remoto por `scripts/schema_fingerprint.sql`. Os fingerprints coincidiram para 820 colunas, 515 constraints, 80 funções, 148 índices, 25 políticas, 43 tabelas com seu estado RLS, 47 triggers e 16 views. A comparação é estrutural e não garante, por si só, equivalência de privilégios, Storage, Realtime, dados ou comportamento de ponta a ponta. Os privilégios do novo registro também foram verificados separadamente: `anon` e `authenticated` não têm acesso ao schema nem à tabela.

`scripts/reconcile_migration_history.sql` foi executado uma única vez no projeto autorizado: ele cria somente o registro oficial e insere as dez versões e nomes já verificados, sob lock e em uma transação. O script recusa históricos inesperados ou parciais, e não altera tabelas ou registros de negócio. A API de migrações do Supabase passou a listar as mesmas dez versões.

## Limitação dos registros históricos

Os arquivos SQL originais estão no Git. O campo `statements` das dez entradas históricas foi deixado como `NULL`, porque os conteúdos não foram enviados ao banco durante o reparo. Assim, **não use `supabase migration fetch` como fonte dos arquivos históricos**; obtenha-os do Git. Se necessário, um administrador com conexão de banco apropriada pode usar `supabase migration repair --status applied` para cada versão, apontando para os arquivos locais revisados, para preencher os statements sem reaplicar o SQL. Nunca use `reset` ou marque todas as versões automaticamente sem conferir o esquema.

## Aplicações futuras

- O aplicador `scripts/apply_foundation.py` cria a fundação e ambos os registros atomicamente apenas em uma instalação sem histórico anterior.
- `scripts/apply_migrations.py` recusa divergências entre os dois registros; migração, entrada própria e entrada oficial são confirmadas ou revertidas juntas. As entradas novas incluem os statements derivados do arquivo revisado.
- Aplicar uma migration manualmente por SQL sem registrar **ambos** os históricos volta a causar divergência. Não execute o reparo específico desta linha de base em outro projeto ou após novas migrations sem uma nova auditoria.
- `scripts/run_database_tests.py --suite foundation_history --stop` e `--suite migration_history --stop` verificam bootstrap, idempotência, recusa de histórico divergente e rollback em um cluster local marcado, sem fixtures no Supabase. O caminho dos binários locais PostgreSQL 16 pode ser informado por `VM_TEST_POSTGRES_BIN`.
