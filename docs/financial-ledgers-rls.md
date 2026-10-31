# Controle de acesso a caixa, pagamentos e compras

A migration `20261031002000_financial_ledgers_rls` restringe a leitura direta das tabelas `vm_cash_entries`, `vm_order_payments` e `vm_material_purchases` aos membros `owner`, `admin` e `finance` da organização de cada linha. As views correspondentes continuam usando as permissões e o RLS do invocador. O resumo financeiro já possuía a mesma regra no RPC. As operações de registro existentes continuam sujeitas às verificações no banco.

A view operacional `vm_orders_read` conserva os pedidos para Produção e Leitura, mas substitui por `NULL` subtotal, desconto, frete, total, recebido e saldo para esses papéis. Em particular, pagamento filtrado por RLS não é apresentado como recebimento zero. Os papéis financeiros continuam vendo os totais reais. A migration recusa sua aplicação se a view ou as políticas de leitura revisadas tiverem mudado.

A interface correspondente não consulta pagamentos em detalhes operacionais, separa o cache de detalhe por privilégio, oculta valores e exporta somente colunas operacionais para Produção/Leitura. O acesso à página de compras é bloqueado para esses papéis. A lista de membros é revalidada ao recuperar o foco/visibilidade e aproximadamente a cada 30 segundos; uma mudança de papéis limpa o cache, respostas mais antigas são descartadas e falhas de validação removem o acesso exibido até nova confirmação. A RLS, e não o estado da interface, continua sendo a autoridade. Dados já obtidos enquanto o acesso era legítimo não podem ser apagados da memória do usuário.

## Limite importante desta etapa

**Esta etapa não concluiu a proteção de todos os dados financeiros do ERP.** A fatia posterior descrita em [proteção dos valores de pedidos](order-financial-access.md) protege as tabelas e os snapshots de pedidos. Materiais, movimentos, produtos, variantes e algumas RPCs ainda podem expor preços ou custos diretamente a membros não financeiros; suas alterações exigem outras fatias DB → API → UI para não quebrar as operações. Orçamentos públicos são links de portador e necessariamente exibem o preço a qualquer pessoa com um link válido, independentemente do papel interno. Não usar a ocultação de interface como prova de confidencialidade completa.

A aplicação web precisa ser publicada com esta versão da interface após a migration. A versão antiga pode interpretar uma lista de pagamentos filtrada como vazia. Publicação ou navegação real não foram verificadas nesta etapa.

## Verificação

- `python scripts/run_database_tests.py --suite financial_ledgers --stop` executa, apenas no cluster local isolado, testes de caixa, compras, pagamentos e pedidos para `owner`, `admin`, `finance`, `production`, `viewer` e anônimo, incluindo usuário com papéis diferentes em duas organizações, acesso direto às tabelas/views e mudança operacional de status.
- PostgreSQL local validou também a transação de aplicação com os dois históricos e o bloqueio da migration diante de uma política permissiva inesperada. As suítes de pedidos, precisão, devoluções, produtos e links públicos passaram com a migration; `pnpm typecheck`, testes e build passaram. Os testes são locais e não comprovam uma implantação ou navegador real.
- No projeto autorizado `kasupbixvesyyrvmfzgm`, a migration foi aplicada sem fixtures, atomicamente com os históricos próprio e oficial. Os dois históricos têm 14 versões sem divergência; o SQL registrado tem MD5 `6da88a4c42390b21cf737111f92f3beb`, o arquivo tem SHA-256 `52c7c0987b11c15650be4a2bd5d2ce26e8c1072214eb7f405f50bf6a7752596c` e a definição da view instalada tem o mesmo MD5 `fb7c512f04028bf52c9a8f9921bfd5df` do teste PostgreSQL 17. Foram conferidos RLS, políticas e grants da view por metadados, sem consultas a registros de clientes.
