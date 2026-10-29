# Inventário — fatia banco/API/UI

A migration `20261029221500_inventory.sql` foi aplicada ao Supabase autorizado em 29/10/2026 às 19:10 BRT, após 16 grupos de testes transacionais/RLS passarem no PostgreSQL isolado `vm_test`. O runner utilizou socket Unix exclusivo, sem TCP; nenhuma fixture foi criada no banco do usuário. Hash aplicado: `5b7a6631f41c84b57107080da939170b33ef3eebae4c44b9ba61d063beebf7f7`.

O aplicador verificou o registro e RLS nas 11 tabelas públicas operacionais/controle. O payload privado também possui RLS e nenhuma concessão direta à API. As views vm_materials_read e vm_material_purchases_read retornaram HTTP 401 sem sessão. Relatório automático em `migrations-verification.json`.

As telas `/estoque` e `/compras` estão conectadas a views com números textuais e RPCs reais. Há cadastro com custo fracionado calculado no banco, edição controlada, recebimento sem despesa, ajuste com motivo, filtros, alertas, histórico auditável e exportação CSV. A compra cria estoque, compra e despesa na mesma transação, com estado pago/pendente explícito e chave estável para retry. Consultas usam paginação por ID e limite seguro, evitando truncamento silencioso; troca de organização reinicia formulários. Resposta perdida não é apresentada como certeza de rollback.

A suite SQL cobre valores especiais/escala, idempotência por payload, entradas sem despesa, ajustes/rollback, compra vinculada, pagamento, papéis, barreiras entre organizações e append-only. Foundation passou separadamente 11 grupos. Typecheck, 12 testes puros e build final passaram em 29/10/2026 às 19:22 BRT. Os módulos são lazy e o build foi dividido em chunks; não houve aviso de tamanho. O manifesto servido contém Painel, Entrar, Recuperar, Conta, Estoque e Compras.

A conta/organização reais do proprietário foram preservadas. Nenhum insumo, compra, cliente, produto ou pagamento demonstrativo foi criado. A fatia central está implementada; isso não declara o sistema completo, fotos/PDV/paridade extra ou publicação. Os itens pendentes permanecem no TODO e nos registros de referência.
