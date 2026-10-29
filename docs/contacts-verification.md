# Cadastros — evidência da fatia

Schema `20261029235500_contacts` aplicado e registrado no Supabase autorizado em 29/10/2026 após 12 grupos SQL isolados aprovados. O relatório incremental confirmou RLS nas tabelas públicas e privadas, incluindo eventos e ledgers de idempotência. Grants legados por coluna de insert/update foram explicitamente revogados além de remover as policies de escrita.

Testes locais: normalização/endereço/data/URL, CPF numérico e CNPJ numérico/alfanumérico, idempotência/collision, formato sem validação oficial de titularidade, unidades diferentes separadas nos indicadores de fornecedor, isolamento entre organizações, viewer bloqueado e finance autorizado, archive auditável com preservação de referência, importação atômica e limite de 500 linhas. O fixture que alterava nome num retry foi corrigido; a regra de rejeitar payload diferente não foi enfraquecida. Fixtures existiram somente em `vm_test` isolado, sem listener TCP.

UI de cadastros ainda em implementação neste registro. Nenhum cliente/fornecedor/importação de demonstração foi criado no Supabase. Pedidos não existem nesta etapa; por isso os DTOs não inventam contagens de pedidos. Contrato completo em `contacts-api.md` e padrão atual do identificador em `contact-tax-format.md`.
