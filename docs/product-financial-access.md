# Catálogo financeiro e edição operacional

A migration `20261031006000_product_financial_access` separa a leitura financeira das operações de produção:

| Papel | Preços e custos | Produto e preço | Dados de produção e receita | Arquivos privados |
| --- | --- | --- | --- | --- |
| Proprietário, Administrador, Financeiro | sim | criar e editar | editar | ler e registrar |
| Produção | não | não | editar produto existente | ler e registrar |
| Leitura | não | não | consultar | ler |

O editor operacional permite alterar descrição, material/acabamento, personalização, dias de produção, classificação de estoque e receitas base e das variações existentes. Criar produto, criar/renomear/desativar variações e alterar preço, condições comerciais ou outras propriedades continuam no editor financeiro. A edição operacional não aceita preços na entrada nem os devolve; o banco preserva os valores comerciais atuais sob bloqueio da organização e registra uma nova versão. Versão esperada evita substituir uma alteração concorrente; a mesma chave e payload reproduzem a resposta sem nova versão. Receitas e classificação continuam sujeitas às regras de estoque e precisão. Pedidos antigos mantêm seu snapshot, pedidos novos usam a nova receita.

Cinco tabelas diretas de produtos, componentes, variações, componentes de variações e versões passam a usar RLS financeira. As quatro views de leitura do catálogo usam barreira e validação explícita da organização: retornam `NULL` para valores monetários e faixas de preço de não financeiros, enquanto os snapshots JSON são construídos por allowlist operacional, inclusive nas receitas das variações. As RPCs públicas v2/v3 ficam restritas aos papéis financeiros; a nova `vm_update_product_operations` chama cópias privadas e não executáveis pelos clientes da implementação revisada. Atualizações futuras da lógica de produto devem revisar e atualizar ambas as implementações e seus testes. As políticas de Storage consultam a projeção operacional para manter o acesso a arquivos; Financeiro ganha permissão de registro de arquivos em conjunto com a edição do catálogo.

O frontend separa os caches financeiro/operacional, não exporta valores em CSV operacional e abre um formulário específico para Produção. Após uma falha de rede, a tentativa é congelada para replay seguro; para alterar dados, feche e recarregue. Uma versão antiga do frontend pode ainda mostrar o formulário com preço ou o botão de editar, mas o banco recusa a RPC financeira de Produção; é necessário publicar o frontend atualizado para recuperar a edição operacional pela interface.

## Limitações

A proteção cobre os campos estruturados e caminhos verificados, não impede que valores sejam digitados em campos de texto, nomes ou arquivos anexados. Arquivos de produto são acessíveis aos membros autorizados da organização e podem conter informações financeiras; não anexar documentos financeiros ali se Produção não deve vê-los. Orçamentos públicos válidos mostram preços a qualquer portador do link, independentemente do papel interno. O build de produção configurado, publicação web, navegação E2E e entrega real de Storage/Realtime não foram comprovados nesta etapa. Não interpretar esses testes como prova absoluta de ausência de outros canais de informação.

## Verificação local

Com PostgreSQL isolado e dependências de `scripts/requirements.txt`, executar `python scripts/run_database_tests.py --suite financial_products --stop` (30 grupos, incluindo corrida real de duas conexões, mudança de papel, tenants, fraude de claim, snapshots, precisão, Storage local e preservação de preços). Também passaram `financial_inventory`, `inventory_return_privacy`, `financial_orders`, `financial_ledgers`, `recipe_guard`, `fractional_precision`, `public_capabilities`, `products` (original e `--latest`) e `public_sales --latest`. `pnpm typecheck`, 58 testes de frontend e `vite build --mode test` passaram. Os contratos locais de Storage/Realtime não constituem testes dos serviços externos.

No projeto Supabase autorizado `kasupbixvesyyrvmfzgm`, a migration foi aplicada uma vez e verificada: os dois históricos têm 18 versões e zero divergências. MD5 do SQL registrado: `1d3b12110af65be0b2140e7827c4277b`; SHA-256 do arquivo: `1bd0cc1ed381aef1b5912dd1acdde79c0c2074a61e0db8baeffea4619d06bc7a`. Os hashes das quatro views, oito funções e três políticas de Storage correspondem ao banco de testes; RLS e ACLs foram verificadas. A aplicação web ainda precisa ser publicada e validada com usuários reais.
