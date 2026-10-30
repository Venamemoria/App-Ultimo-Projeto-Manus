# Verificação — resumo financeiro inicial

## Entrega

A migration `20261030005000_finance_summary` foi aplicada ao Supabase autorizado. O relatório versionado registra `status=applied`, verificação aprovada e SHA-256 do SQL `e381ecf64b5d090a85a5047e3ee6e2f12d6149b84a2ebf2a73168d21c197b782`. Uma consulta somente leitura ao catálogo confirmou função `SECURITY DEFINER`, `search_path` vazio e execução concedida apenas a `authenticated`; não foram consultados valores de pedidos, clientes ou caixa na verificação remota. A suíte SQL `finance_summary` foi executada em PostgreSQL local isolado, com fixtures somente de QA.

A rota autenticada `/financeiro` consulta a RPC por organização e está limitada na UI aos papéis owner/admin/finance. O manifesto `GET /manus-routes.json` foi servido com a rota, e `/financeiro` respondeu HTTP 200 no Vite. `pnpm typecheck`, os nove arquivos Vitest (36 testes) e `pnpm build` passaram. Os testes cobrem validação do intervalo, contrato dos agregados e retorno seguro pós-login. Não houve gravação, pagamento, compra, lançamento ou outra movimentação de negócio.

## Limites conhecidos

Esta é uma primeira visão agregada read-only baseada em pagamentos confirmados, despesas pagas e saldos estimados de pedidos/compras dentro do período selecionado. Valores a receber/a pagar são explicitamente estimativas por data de origem, não vencimentos. A interface não foi exercitada com a sessão de negócio do proprietário; por isso, nenhum total real de negócio é reproduzido neste documento.

Ainda não implementa lançamento manual, livro-caixa detalhado, contas a pagar/receber com vencimentos, conciliação, saldo de abertura/fechamento, taxas, tributos, reembolsos ou relatório contábil. `Movimento líquido` não significa lucro. O item de paridade financeira completa permanece aberto em `TODO.md`; a aplicação ainda não está publicada.
