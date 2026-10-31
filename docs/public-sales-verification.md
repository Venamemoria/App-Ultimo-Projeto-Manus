# Verificação — orçamentos públicos e acompanhamento

## Supabase autorizado

As migrations `20261030003000_public_sales`, `20261030003500_quote_admin_list` e `20261030004000_tracking_minimal_acl` foram aplicadas ao projeto Supabase indicado pelo proprietário, sem seed, reset, pedido, pagamento ou aprovação de demonstração. A migration 040 foi aplicada em 30/10/2026 com SHA-256 `b4f4261e1efc75627a964c441b53c344ad7616ec424d1928a5649d18a173ba92`. O verificador registrou nove migrations `already_applied`, `verification=passed` e RLS habilitado em todas as tabelas `vm_%` operacionais.

Uma transação PostgreSQL remota estritamente `READ ONLY` confirmou o registry da 040 e os grants: `anon` não executa `vm_get_order_tracking`; `authenticated` executa; `anon` e `authenticated` executam `vm_get_tracking`. A definição remota da consulta administrativa contém o gate de papel owner/admin/finance. A função pública não projeta token, itens, preços, notas, termos, contatos, totais ou custos. Nenhuma linha de cliente, orçamento ou pedido foi consultada.

## QA transacional isolado

`python scripts/run_database_tests.py --suite public_sales --stop` passou em **17 grupos, sem falhas**, aplicando nove migrations ao database local isolado `vm_test` e parando esse cluster ao final. A cobertura inclui snapshot de preços/composição, revogação, tokens inválidos, papéis e tenants, allowlists, `vm_get_quote_admin`, paginação keyset, autorização server-side do getter de tracking, projeção pública mínima e concorrência de aceite em duas conexões. A corrida confirma um único pedido, aceite, evento inicial e conjunto de notificações, sem baixa de material. O parser PostgreSQL também processou as migrations; nenhum fixture foi aplicado no Supabase real.

## Aplicação web

O módulo autenticado `/orcamentos` consulta clientes e produtos reais da organização, emite itens múltiplos de produto ou serviço manual, aceita variações e medidas em m², oferece override de preço claramente explícito com motivo preservando `product_id` e receita, cria revisões de propostas enviadas e permite revogar com motivo. Sem override, preço, versão e composição do produto continuam sob autoridade do RPC. `/orcamento/:id` apresenta a proposta comercial permitida; aprovação chama o RPC idempotente e encaminha ao rastreio.

`/rastreio/:id` recebe somente marca, código/título do pedido, status atual, datas e histórico público. O token é capability opaca, expira/revoga e o getter administrativo agora exige owner/admin/finance também no banco; viewer não pode recuperar o link chamando a RPC diretamente. A página assina Broadcast e refaz consulta por RPC, mantendo atualização manual e estados de reconexão; a revisão posterior descrita em `docs/public-capability-expiry.md` acrescenta revalidação periódica e ao recuperar foco. O detalhe privado do pedido permite emitir, consultar, copiar, rotacionar e revogar link com nonce persistente em retry inconclusivo.

Após a correção do encerramento da última página de propostas, `pnpm typecheck`, `pnpm test` (**32 testes**, incluindo quatro casos de paginação), `pnpm build`, manifesto HTTP, parser das migrations e `git diff --check` passaram. A API busca 21 linhas, exibe no máximo 20 e oferece continuação somente quando existe mais uma linha. O manifesto inclui as rotas públicas e protegidas reais.

## Limites

Não foram emitidos orçamentos reais, aprovados pedidos, executados pagamentos, baixado estoque nem enviados links a clientes. A aprovação por browser e o recebimento de um frame WebSocket no navegador não foram exercitados ao vivo; os testes transacionais e a inspeção remota de schema/grants não substituem essa evidência. O app não foi publicado.
