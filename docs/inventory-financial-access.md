# Custos de estoque e recebimento

Conforme a decisão operacional, apenas `owner`, `admin` e `finance` podem registrar uma entrada de material com custo. A RPC existente `vm_receive_material` verifica esse papel no banco antes de processar ou reproduzir uma tentativa. Produção continua consultando saldos, movimentos, consumo e devoluções, mas não pode registrar entrada por essa RPC. A entrada avulsa não cria compra nem despesa; compras reais continuam usando seu fluxo próprio.

A migration `20261031005000_inventory_financial_access` restringe as tabelas de materiais e movimentos aos papéis financeiros por organização. As views operacionais mantêm as quantidades e ocultam custo da embalagem e custo unitário com `NULL`; o valor agregado dos fornecedores e o custo corrente de materiais do produto também são ocultados em vez de representados como zero. As views de material e movimento usam `security_invoker=false` e `security_barrier=true`, com validação explícita da organização; as views de consumo, devolução, fornecedor e produto usam essas projeções para preservar operações. O papel de serviço efetivo mantém acesso privilegiado; um claim isolado sob `authenticated` não concede acesso. Textos livres podem conter informações digitadas manualmente e não são automaticamente censurados.

A interface atualizada oculta os custos de inventário e fornecedores de papéis não financeiros, remove o custo do CSV operacional, e mostra o recebimento a Financeiro/Administrador/Proprietário. Em dados financeiros ausentes não fabrica zero. A UI precisa ser publicada; uma versão antiga pode mostrar botão de receber para Produção, mas o banco já recusará a operação.

## Limites

A proteção financeira do ERP ainda não é completa: tabelas, snapshots e RPCs de produtos/variantes ainda podem revelar preços e custos a papéis não financeiros. Um orçamento público válido mostra preço a qualquer portador de seu link. Não considerar a ocultação da interface como prova de confidencialidade total. Não foi feita navegação E2E ou validação real de entrega Realtime; a consulta ativa de estoque revalida no foco e a cada 30 segundos.

## Verificação

- `python scripts/run_database_tests.py --suite financial_inventory --stop` passou 25 grupos locais, incluindo leitura direta e via views por papel/tenant, produção negada, recebimento financeiro com replay exatamente uma vez, mudança de papel, admin, anônimo e papel de serviço. `--suite inventory_return_privacy --stop` passou 10 grupos e confirmou devoluções operacionais sem acesso a movimentos financeiros. Os testes são restritos ao PostgreSQL isolado.
- Regressões de pedidos, pagamentos, produtos, receitas, links públicos e precisão/concorrência passaram; 55 testes de frontend, typecheck e build Vite em modo de teste também passaram. Uma transação de aplicação local rejeitou e reverteu corretamente política inesperada. O build de produção configurado e a implantação web não foram verificados nesta etapa.
- No projeto autorizado `kasupbixvesyyrvmfzgm`, ambos históricos possuem 17 versões e zero divergências. MD5 do SQL registrado: `4e123841a4e2a8d0b60ca41b88ca64bd`; SHA-256 do arquivo: `e2d80c0da66fbddf4b1a585064dabd02f51115e35a8015600998d94364ff5e18`. Foram verificadas as políticas, ACLs e hashes das seis views e da RPC instalada, coincidentes com o teste local.
