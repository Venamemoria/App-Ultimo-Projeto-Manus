# QA isolado — pedidos

Executado `scripts/run_database_tests.py --suite orders --stop` em 29/10/2026. A cadeia cumulativa de cinco migrations compilou no PostgreSQL 16 `vm_test` marcado, via socket Unix sem listener TCP. Resultado: **22 grupos aprovados**, incluindo sonda real de duas conexões concorrentes.

Cobertura: tenant/papéis, cliente ativo/arquivado/cross-org, preço e MOQ/tier, variações own/inherit, dimensões m² exatas, overrides e serviço manual, snapshots/replay, transições, baixa única diretamente Concluído e depois de Em Produção, receita vazia com ledger, agregação de dois itens por insumo com um só movimento, insuficiência de um entre dois materiais sem baixar o outro nem gerar pedido/evento/caixa, idempotência, pagamentos reais e vínculos income, overpayment/colisão, conclusão não quita automaticamente, cancelamento sem estorno automático, own-read/outbox privado, RLS/anon/DML/guards de histórico, constraints diferidas em validação imediata.

A sonda abriu duas sessões psycopg no cluster local para o mesmo status: uma mudança real e um no-op; apenas uma baixa e dois eventos totais (criação + transição). Fixtures existem somente no teste, isolado do Supabase. `--stop` encerra o cluster no finally; pg_ctl no JSON é medido antes do encerramento.

Corrigidos erros de expectativa/fixture, não o mecanismo de produção: não cancelar Entregue, receita vazia não significa valor gratuito, membro em dois tenants não é caller sem autorização, coluna PK correta na assertion e alvo explícito da concorrência. Não houve redução de validação, seed operacional, envio de mensagem, fake pagamento ou bypass de Auth na prévia.

O verificador sintático foi ampliado para CREATE FUNCTION sem OR REPLACE, formato inline e DO: confirmou **86 statements, 20 funções PL/pgSQL e três blocos DO** na migration orders. Parsing não é execução; a prova decisiva de transações/permissões é o PostgreSQL isolado. UI, rotas públicas e worker são fatias distintas.
