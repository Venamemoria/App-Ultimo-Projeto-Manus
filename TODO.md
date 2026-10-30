# Vê na Memória — entregas e critérios

Plano aprovado pelo usuário em 29/10/2026. Fundação Supabase, autenticação/organização, inventário/compras, produtos/receitas, cadastros, pedidos/baixa/produção/agenda/devolução auditada e orçamento/rastreio público estão implementados. A execução segue para notificações, integrações e paridade restante; ainda não há aplicação publicada. O schema evolui por migrations, preservando dados.

## [x] Fundação Supabase e segurança antes da UI

Usar estritamente Vite, React, TypeScript, TailwindCSS e Supabase; manter o projeto migrável via Git para Lovable.dev. Não usar TanStack Start, Nitro, MySQL/Drizzle ou autenticação Manus no lugar de Supabase. Configurar o schema Supabase e políticas RLS PRIMEIRO. Migrations versionadas devem preservar dados existentes; não resetar o banco. Todas as tabelas operacionais devem separar organizações e negar acesso não autorizado. Relacionamentos impedem mistura entre organizações. RPCs validam identidade/papel, fixam search_path quando elevam privilégios e não deixam o cliente escrever diretamente em saldo, movimentos ou status protegidos. Segredos de banco/serviços ficam fora do frontend, logs e Git. Configuração depende de um projeto Supabase real indicado pelo usuário.

Evidência: `docs/foundation-verification.json` registra nove tabelas com RLS, 14 políticas, cinco RPCs sem execução anônima e bloqueio de leitura anônima de insumos e de alterações diretas em saldo/histórico. Migration transacional aplicada sem seed, reset ou redefinição de senha.

## [x] Autenticação, organização e permissões reais

Implementar login e sessão por Supabase Auth, sem usuário fictício ou bypass de autenticação na prévia. Associar usuário autenticado à organização autorizada; impedir que um cadastro público assuma privilégios em organização existente. Cobrir administração, produção, financeiro e leitura. Navegação, consultas e comandos devem respeitar permissões efetivas no banco, não somente esconder botões.

Evidência: UI real de entrada/cadastro/recuperação/sessão e onboarding por RPC implementada; rotas privadas validam `getUser` no Supabase e memberships respeitam RLS. Typecheck, cinco testes de segurança/configuração e build passaram; Vite e manifesto retornaram HTTP 200. Dois redirects exatos foram persistidos no painel. Em 29/10/2026 às 18:54 BRT, após o usuário realizar signup/login, o RPC criou a organização real Vê na Memória e a interface exibiu o papel proprietário e contagens autorizadas vazias de materiais/produtos/clientes. Nenhum usuário ou dado de negócio fictício foi criado.

## [x] Inventário, cadastro de insumos, compras e custo unitário

Ao cadastrar Insumo com custo total e quantidade da embalagem, calcular automaticamente custo unitário fracionado (`custo total / quantidade da embalagem`) no backend e mostrar o cálculo na interface. Quantidade de embalagem maior que zero; quantidade e custo devem ser validados com precisão decimal. Registrar nome, categoria, unidade, saldo e limite de reposição. Permitir cadastro/consulta/edição controlada, filtros, alertas e histórico real. Distinguir saldo inicial sem despesa de uma compra que entra no estoque e tem vínculo financeiro. Usar numeric e cálculo decimal controlado, sem float nas regras de consumo. Não iniciar com dados demonstrativos.

Evidência: migration de inventário aplicada e registrada no Supabase, views negam acesso anônimo (HTTP 401), 16 grupos SQL isolados passaram. `/estoque` e `/compras` usam views textuais decimais e RPCs reais com papéis, motivo, retry idempotente e vínculo de compra/movimento/caixa. Cadastro, edição limitada, entrada sem despesa, ajuste, filtros, alertas, histórico e CSV implementados. Typecheck, 12 testes puros e build dividido em chunks passaram; manifesto servido contém as seis rotas reais. Nenhum insumo ou compra demonstrativa foi criado. Fotos/PDV e campos extras de paridade continuam no item próprio.

## [x] Produtos, variações, preços e composição por frações

Produtos são compostos por quantidades fracionárias específicas de Insumos. Validar quantidades positivas e compatibilidade de unidade. Persistir a composição e calcular custo real de fabricação; versionar a receita. Cobrir os campos e fluxos inspecionados das referências, incluindo nome, categorias, imagens, preço, descrição e ajustes de produção. Alteração de catálogo/composição não deve modificar os snapshots de pedidos históricos. Arquivos e imagens devem ter persistência real e políticas de acesso.

Evidência: schema/RLS/Storage privado aplicado, 11 grupos SQL isolados passaram, RPCs idempotentes e views decimais textuais conectadas a `/produtos`. Cadastro em quatro etapas, categorias, preços unidade/variação/m², promoções/faixas/mínimos, descrição/personalização/produção/frete, receitas base/próprias, versões e custo atual versus congelado. Upload/registro e URLs assinadas usam Supabase real; nenhum arquivo de demonstração enviado. Typecheck, 17 testes puros e build passaram; manifesto contém sete rotas. Runtime de upload HTTP não foi exercitado com arquivo fictício; controle de produto acabado, remoção sincronizada e vitrine ativa continuam pendentes.

## [x] Clientes e fornecedores reais vinculados à organização

Inspecionar e implementar cadastros, busca, edição, importação/exportação e indicadores reais de clientes/fornecedores. Clientes incluem pessoa física/jurídica, nome obrigatório, CPF/CNPJ, nascimento aplicável, contato/e-mail e endereço para frete (CEP, rua, número, bairro, complemento, cidade/UF). Fornecedores incluem nome, telefone, e-mail, CPF/CNPJ, site e observações, lista/detalhe e indicadores de insumos vinculados. Respeitar RLS e papéis, preservar compras/pedidos históricos, não copiar dados pessoais da referência nem gerar contatos de demonstração. Filtros relacionados a pedidos dependem de registros reais e não devem mostrar zeros fictícios ou sucesso simulado.

Evidência: schema aplicado/RLS, 12 grupos SQL isolados, `/clientes` e `/fornecedores` conectados a RPCs reais, edição completa/arquivo recuperável auditado, importação CSV atômica/preview e exportação dos registros atuais. Busca, endereço, PF/PJ e CNPJ alfanumérico, indicadores decimais por unidade implementados. Typecheck, 22 testes puros e build passaram; manifesto servido contém nove rotas. Não foram criados contatos/importações demonstrativos. Contagens/filtros de pedidos dependentes serão adicionados ao existir o contrato de pedidos.

## [x] Pedidos e baixa automática única, exata e transacional

Criar pedidos reais com cliente, itens, personalização, datas de pedido/produção/entrega, pagamentos e status. Ao marcar um Pedido como “Em Produção” OU diretamente como “Concluído”, deduzir automaticamente as frações exatas dos Insumos. A mudança posterior de “Em Produção” para “Concluído” NÃO deve deduzir novamente. Pedidos com vários itens somam consumo por insumo. Bloquear concorrência e usar restrição de unicidade para evitar segunda baixa. Validar todos os saldos antes da alteração; falta de qualquer insumo faz rollback integral de baixa/status/eventos. Não permitir baixa parcial nem saldo negativo. Congelar preços, composição e quantidades de consumo necessários ao histórico. Status, movimentos, histórico e evento de outbox são gravados na mesma transação. Não permitir edição silenciosa dos itens após baixa.

Evidência: schema aplicado, 22 grupos PostgreSQL isolados incluindo duas conexões concorrentes/baixa agregada/rollback de dois materiais. `/pedidos` e detalhe conectados a RPCs reais e snapshots. 28 testes puros, typecheck e build passaram; nenhuma venda, pagamento ou baixa fictícia executada no Supabase.

## [ ] Fluxo de produção, consultas, agenda e cancelamento auditável

Implementar lista, busca e filtros de pedidos por cliente/código, período, produto/serviço e status; histórico de vendas, saldos a receber, etapas/Kanban, calendário e tarefas conforme os fluxos de referência. Permitir navegar de pendências para os registros reais. Cancelamento antes da baixa não gera movimento de estoque. Depois da baixa, não devolver material automaticamente: estorno físico exige autorização administrativa, motivo e movimentos compensatórios auditáveis, impedindo duplo estorno. Reembolso financeiro é um fluxo separado. Não alterar retroativamente histórico concluído para esconder consumo.

Evidência: Orders usa views/RLS e RPCs Supabase reais, lista paginada por UUID com restante, detalhe readonly de snapshots/eventos/consumos/pagamentos, Kanban com transições confirmadas e agenda mensal sem UTC. Notificações têm consulta própria, RPC de leitura e Postgres Changes com estado conectado/reconectando. `pnpm typecheck`, `pnpm test` (28 testes puros) e `pnpm build` passaram; nenhum dado de negócio, fixture, browser ou SQL foi criado pela UI.

Devolução física: schema aplicado, nove grupos SQL isolados e formulário owner/admin integrado, motivo/quantidade física explícita, cap por consumo e replay sem duplo retorno. Nenhum retorno real de negócio criado. Pendências do item completo: gestão de tarefas; reembolso é um fluxo financeiro separado. Paridade não inspecionada continua aberta.

## [x] Orçamentos interativos com URL pública e aceite

Gerar URL pública `/orcamento/[id]` para cada orçamento; identificador opaco e imprevisível, distinto do ID interno, com validade e revogação. Exibir itens, valor, prazos/termos permitidos e botão “Aprovar Orçamento”. Ao clicar, validar e atualizar o status para `Approved`, criar/vincular o pedido com snapshots na mesma transação e redirecionar o cliente à página de acompanhamento. Cliques repetidos retornam o mesmo pedido/link sem duplicação de pedido, eventos ou notificações. Orçamento inválido, expirado ou revogado não pode ser aprovado. Público não recebe SELECT nas tabelas internas nem custos, margens, observações internas, CPF, endereço, telefone, e-mail ou credenciais.

Evidência: migrations 030/035 aplicadas e RPCs administrativos verificadas; 17 grupos SQL isolados, inclusive concorrência real local, passaram. `/orcamentos` emite/revisa/revoga propostas multi-item com produtos/serviços, variantes, m² e override justificado. `/orcamento/:id` apresenta o snapshot comercial permitido; aceite chama RPC idempotente, cria pedido pendente e encaminha ao rastreio. Não foi criado nem aprovado orçamento de negócio real. Ver `docs/public-sales-verification.md`.

## [x] Página pública de acompanhamento em tempo real

Criar `/rastreio/[id]` para que o cliente veja em tempo real o estado atual do pedido, datas e histórico público permitido. Usar token público opaco com acesso limitado e revogável. Realtime deve respeitar autorização da projeção pública; não abrir tabelas operacionais a anônimos. Não apresentar polling periódico como tempo real. Página deve lidar com link inválido, conexão interrompida e pedido indisponível sem expor dados privados.

Evidência: migration 040 aplicada; consulta remota somente leitura confirmou que `vm_get_order_tracking` requer owner/admin/finance e não pode ser executada por `anon`, enquanto a projeção pública de `vm_get_tracking` expõe apenas marca/código/título/status/datas/histórico, sem itens, preços, notas ou termos. Os 17 grupos SQL isolados cobrem viewer/tenant negado e allowlist exata. A UI assina Broadcast e atualiza via RPC, sem polling; entrega de frame WebSocket ao vivo não foi exercitada. Nenhum link real foi enviado a cliente; o app não está publicado. Ver `docs/public-sales-verification.md`.

## [ ] Notificações persistidas na UI e estrutura WhatsApp

Cada mudança de status gera evento na mesma transação do pedido. Implementar notificações na interface com registros reais e atualização em tempo real. Preparar integração de webhook/API para WhatsApp via Z-API ou Evolution API. Adaptadores e segredos somente server-side. Outbox tem idempotência, tentativas, retomada e estado de entrega; falha do provedor não desfaz o pedido confirmado, e fica visível sem vazar credenciais. Disparos reais dependem da conta configurada/autorizada; não marcar como enviado sem resposta real. Se houver Web Push externo, exigir permissão/assinatura e serviço seguro, distinguindo-o das notificações dentro da UI.

## [ ] Arquitetura de integrações Mercado Pago, Frenet, Shopee e Mercado Livre

Preparar variáveis de ambiente documentadas e rotas de API server-side para os quatro provedores. Separar identidades externas dos IDs internos. Webhooks validam autenticidade conforme provedor, impedem processamento duplicado e traduzem eventos externos em eventos internos controlados. Não escrever funções placeholder, respostas de sucesso falso, pagamentos fictícios ou fretes simulados. Configuração ausente deve permanecer explicitamente desabilitada/indisponível. Arquitetura preparada não será declarada integração ativada; ativação e testes reais dependem de contas, credenciais e autorização apropriada.

## [ ] Paridade dos demais módulos das referências

Inspecionar e implementar os fluxos necessários de clientes, fornecedores, financeiro/fluxo de caixa, receitas/despesas/livro caixa, relatórios, tabela de preços/calculadora, produtos/variações/arquivos digitais, catálogo público e configurações. Recursos observados de cupons, promoções, frete, domínio, equipe, PDV, arte/aprovações e notas fiscais precisam ser inspecionados especificamente antes de definir a paridade. Um menu visível não comprova recurso funcionando. Não criar páginas vazias ou menus inativos como se fossem entregas completas. Serviços proprietários ou bloqueados da referência devem ser explicitamente resolvidos; não afirmar paridade de recurso não inspecionado/implementado.

## [ ] Interface responsiva e identidade visual aprovada

Usar a navegação agrupada da Papelaria On e os tons quentes/apresentação clara do AtelierFlow sob a marca Vê na Memória, conforme plano aprovado. Barra lateral persistente no desktop e recolhível no celular; área de trabalho com indicadores, filtros, tabelas e formulários por etapas quando apropriado. Cores de estado acompanhadas por texto, controles acessíveis sem hover, suporte a movimento reduzido e microcopy pt-BR. Estados vazios e de erro verdadeiros, sem dados fictícios ou imagens decorativas para preencher o app. Não alegar cópia pixel a pixel simultânea de duas interfaces visualmente diferentes.

## [ ] Entregas verticais e pushes por funcionalidade

Construir em fatias completas banco → API → UI; cada funcionalidade deve funcionar antes de avançar. Ao concluir cada funcionalidade central, criar commit e push para `https://github.com/Venamemoria/App-No-Atelie`, sem esperar a conclusão de todo o sistema. Preservar o README/commit inicial e alterações concorrentes; nunca force-push. Conforme plano aprovado, manter a cópia versionada no repositório existente e os checkpoints da prévia Manus separados, sem criar outro repositório GitHub ou trocar origin do projeto para contornar limitação. O repositório é público: excluir segredos, .env, dados de clientes e conteúdo privado exportado das referências. Confirmar o resultado de cada push e distinguir do checkpoint Manus.

## [ ] Build operacional, revisão técnica e entrega honesta

Fixar gerenciador/dependências e política de scripts; configurar diagnósticos TypeScript antes do código. Frontend Vite em `0.0.0.0:3000` na prévia, produção em `dist/`, backend Supabase. Servir manifesto atualizado de páginas `manus-routes.json` antes do primeiro dev server e sincronizá-lo com as rotas reais. Verificar tipos, build e caminhos afetados; usar um agente somente leitura para revisar conexões da implementação complexa. Não gravar/apagar dados reais do usuário durante testes sem decisão explícita sobre ambiente dedicado. Não usar mocks/dados demonstrativos/funções placeholder na aplicação. Não declarar banco aplicado, funcionalidade concluída ou site publicado antes da evidência correspondente. Publicação é separada de checkpoint; não ativar auto_publish.
