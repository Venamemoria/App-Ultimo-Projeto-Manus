# Inventário — evidência de aplicação

Em 29/10/2026 às 19:10 BRT, a migration `20261029221500_inventory.sql` foi aplicada ao Supabase autorizado após 16 grupos de testes transacionais e de RLS passarem no PostgreSQL local isolado `vm_test`. O runner usou socket Unix exclusivo e nenhum TCP; não há fixtures no banco do usuário.

O aplicador verificou o registro da migration e RLS nas 11 tabelas públicas operacionais/controle. O payload privado de criação de material também tem RLS e nenhuma concessão direta à API. Hash da migration aplicada: `5b7a6631f41c84b57107080da939170b33ef3eebae4c44b9ba61d063beebf7f7`. Relatório automático: `migrations-verification.json`.

A suite isolada cobre valores especiais/escala, projeções textuais, idempotência por payload, entrada sem despesa, ajustes com motivo e rollback, compras com vínculo de movimento/caixa, estado pago/pendente, papéis, barreiras entre organizações e histórico append-only. A foundation revisada passou separadamente 11 grupos. Os testes puros TypeScript de configuração/decimal/data passaram em 10 casos.

A conta e a organização reais do proprietário foram preservadas. Nenhum insumo, compra, cliente, produto ou pagamento demonstrativo foi criado. Banco/API desta fatia aplicados; as telas estão em implementação e não são ainda declaradas concluídas nem publicadas. Campos extras da paridade das referências permanecem explicitados no TODO e em reference-inventory.md.
