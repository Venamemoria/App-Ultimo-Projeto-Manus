# Pedidos — evidência da fatia

Migration `20261030002000_orders` aplicada e registrada no Supabase autorizado em 29/10/2026. Relatório confirmou RLS nas tabelas operacionais e privadas. Antes da aplicação, PostgreSQL 16 local compilou a cadeia de cinco migrations e aprovou **22 grupos**, com duas conexões de status concorrentes produzindo apenas uma mudança e uma baixa.

Baixa exata e única em Em Produção ou Concluído direto, multiitem agregado por insumo, validação de todos os saldos antes de mutar, rollback integral com um entre dois insumos insuficiente, snapshots históricos e ledgers idempotentes. Pagamentos positivos reais geram income paid na mesma transação e não excedem saldo; conclusão não fabrica quitação. Eventos/status/notificações/outbox estruturais são atômicos. Nenhuma devolução automática ao cancelar; compensação física administrativa/reembolso continuam pendentes de implementação própria.

UI de pedidos/produção/agenda/notificações em implementação neste registro. Não houve pedido, pagamento ou mensagem de demonstração no Supabase e não houve publicação. Orçamento/aceite/rastreio e dispatch WhatsApp ainda não implementados neste marco. Contrato exato em `orders-api.md`, QA em `database-orders-tests.md`.
