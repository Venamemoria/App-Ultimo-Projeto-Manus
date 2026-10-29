# Pedidos — evidência da fatia

Schemas `20261030002000_orders` e `20261030002200_order_returns` aplicados e registrados no Supabase autorizado em 29/10/2026; RLS em tabelas públicas/privadas confirmado. Antes da aplicação: PostgreSQL 16 local, cadeia cumulativa, **22 grupos orders** com concorrência de duas conexões e **nove grupos order_returns**. Parsing separado confirmou funções e DO; não substitui execução.

Baixa exata/única em Em Produção ou Concluído direto; multiitem agregado; todos os saldos validados antes de mutar; rollback integral com um entre dois materiais insuficiente; snapshots históricos/ledgers idempotentes. Pagamentos positivos reais geram income paid atômico, não excedem saldo; conclusão não fabrica quitação. Eventos/status/notificações/outbox estruturais atômicos.

UI em `/pedidos`, `/pedidos/:id`, `/producao`, `/agenda`: lista paginada/busca/filtros/CSV, criação real com previews Decimal e override explícito, detalhe readonly de itens/receitas/custos/eventos/consumos/pagamentos, Kanban confirmado por RPC, calendário local e notificações own-read com Postgres Changes/estado de conexão. Formulário de devolução somente owner/admin, cancelado e consumido; motivo e quantidades físicas explícitas, vazias por padrão, limitadas ao restante real por material. Sem presumir devolução total, somar unidades distintas, ocultar consumo ou fazer reembolso.

Typecheck, **28 testes puros**, build lazy e manifesto servido de **13 rotas reais** passaram. Nenhum pedido, pagamento, material devolvido, arquivo ou mensagem demonstrativa foi criado no Supabase. Login e organização reais foram criados pelo usuário/onboarding.

Tarefas e módulos de paridade continuam abertos. Orçamento/aceite/rastreio e dispatch WhatsApp não estão entregues neste marco. Não houve publicação. Contratos em `orders-api.md`, `order-returns-api.md`; QA em `database-orders-tests.md`; UI em `orders-ui.md`, `order-returns-ui.md`.
