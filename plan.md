# Vê na Memória — plano de implementação

Plano aprovado pelo usuário em 29/10/2026, incluindo a identidade unificada e a cópia versionada ao repositório existente. A fundação Supabase foi aplicada e verificada às 17:58 BRT; a execução progride por fatias verticais com evidências em `TODO.md` e `docs/`. O repositório `Venamemoria/App-No-Atelie` já recebeu a preparação da fundação. As referências foram acessadas com login autorizado, somente para leitura e inspeção. A publicação não está habilitada automaticamente.

## Stack e infraestrutura

Usar estritamente Vite, React, TypeScript, TailwindCSS e Supabase. Não introduzir TanStack Start, Nitro, banco MySQL, Drizzle, autenticação Manus nem uma camada de servidor que substitua o Supabase. O frontend será uma SPA Vite; Supabase Auth, PostgreSQL, RLS, RPCs transacionais, Storage, Realtime e Edge Functions serão o backend. As partes dependentes de APIs externas ficam em funções server-side, nunca no navegador.

O frontend poderá ser migrado via Git para Lovable.dev sem depender de APIs internas do Manus para autenticação ou regras de negócio. Essa escolha mantém a stack solicitada; compatibilidade de importação e configurações externas precisam ser verificadas no destino, não são uma garantia absoluta antecipada.

A prévia local usará Vite em `0.0.0.0:3000`, porta já configurada no projeto. A aplicação publicada servirá `dist/`, com fallback SPA para páginas, sem mascarar erros de assets e APIs. O backend será executado no projeto Supabase autorizado. Somente URL e chave pública do Supabase podem entrar no bundle Vite. Conexão administrativa ao PostgreSQL, `service_role` e tokens de terceiros serão protegidos e usados exclusivamente no ambiente server-side.

## Identidade visual e referências

Diretriz visual atualizada pelo usuário em 31/10/2026: usar exclusivamente o padrão estético e a experiência SaaS do Atelier Flow — minimalista, premium e focado no conteúdo. Abandonar qualquer semelhança visual com a Papelaria On; essa referência deixa de orientar o design do produto. A hierarquia funcional dos módulos e as regras de negócio já existentes continuam preservadas.

O App Shell terá cabeçalho limpo e barra lateral persistente, elegante e intuitiva; em telas menores, a navegação torna-se um painel acessível e recolhível. Dashboard e páginas de gestão reutilizam superfícies, cartões e tabelas espaçosos, com hierarquia visual clara e sem excesso de ornamentos. A primeira fatia aplica a refatoração visual ao Header, Sidebar e Dashboard principal, mantendo intactos autenticação, rotas, permissões e consultas Supabase.

Usar tons quentes de creme/off-white como base, superfícies claras e destaques/ações primárias em tons terrosos e terracota. Títulos principais usam serif elegante; dados, navegação e controles usam sans-serif limpa. Preservar o wordmark e a marca existentes, aplicar foco visível e microinterações sutis que respeitem movimento reduzido. Microcopy direta: “Cadastrar insumo” e “Estoque insuficiente para iniciar a produção”.

A paridade funcional continua como requisito separado do design: nenhuma página será considerada concluída apenas porque aparece no menu. Esta refatoração visual não deve introduzir dados fictícios, substituir a stack Vite/React/Tailwind/Supabase, alterar contratos de backend nem expor custos a papéis sem permissão. Usar componentes shadcn/ui locais e acessíveis para os elementos compartilhados desta fatia.

## Banco de dados e segurança primeiro

A primeira entrega técnica será o schema Supabase com migrations versionadas, relacionamentos, restrições, RLS e RPCs. Não começar pela UI nem simular a persistência. Aplicar migrations somente no projeto Supabase indicado e autorizado pelo usuário; não substituir tabelas existentes ou rodar comandos destrutivos de reset.

Separar organizações/ateliês, usuários e permissões. Todas as tabelas operacionais carregam a organização, com relacionamentos que impedem misturar dados entre ateliês. RLS nega acesso por padrão e valida associação do usuário autenticado. Papéis iniciais cobrem administração, produção, financeiro e leitura. Cadastro público de usuário não pode se atribuir privilégios em organização existente.

As entidades centrais cobrem clientes e fornecedores; insumos, unidades, compras e movimentos de estoque; produtos, variações e versões da composição; orçamentos, itens, pedidos, pagamentos e histórico de status; tarefas, agenda, lançamentos financeiros, configurações, notificações e eventos de integração. Adicionar extensões de schema por migration conforme os módulos das referências forem implementados, sem inventar recursos além do escopo.

RPCs protegidas executam mudanças que afetam estoque, estados, aceite, pagamento e auditoria. Bloquear escrita direta nos saldos, movimentos, status sensíveis e fila de notificações. Funções com privilégios elevados terão `search_path` fixo, parâmetros mínimos, validação de identidade e concessões explícitas. Segredos não serão armazenados em tabelas visíveis ao cliente.

## Estoque, custos e composição

Ao registrar insumo, aceitar nome, categoria, unidade, custo total da embalagem, quantidade da embalagem, saldo inicial e limite de reposição. Quantidade da embalagem deve ser maior que zero; o backend calcula `custo unitário = custo total / quantidade da embalagem`. Mostrar o cálculo durante o preenchimento e persistir o valor calculado pelo banco. Entradas por compra terão documento/histórico; saldo inicial não será automaticamente tratado como despesa do caixa.

Usar `numeric` no PostgreSQL e representação decimal controlada no código. Quantidades fracionárias terão precisão definida, sem uso de float nas regras de consumo. Valores monetários internos terão precisão suficiente para custo fracionado; arredondar moeda na fronteira de cobrança e apresentação, não antes de calcular consumo.

A composição de cada produto associa insumos a quantidades fracionárias por unidade produzida. Validar unidade compatível, quantidades positivas e custo de fabricação. Versionar a composição e congelar composição, preços e custos necessários no pedido/produção; mudanças posteriores no catálogo não podem alterar pedidos históricos.

Implementar cadastro, edição controlada, consulta, filtros, alertas de reposição, compras e histórico com persistência real. Estoque começa vazio, com estados vazios úteis, sem carga demonstrativa.

## Pedidos e baixa automática

Implementar criação de pedidos, associação de clientes, itens, personalização, previsão de produção, entrega, pagamentos e status. Lista com filtros por cliente, período, serviço/produto e estado; histórico, visão de produção/Kanban, agenda e consultas financeiras conforme os fluxos das referências forem analisados.

Ao entrar em “Em Produção” ou diretamente em “Concluído”, calcular e deduzir exatamente as frações armazenadas para os itens. Baixa, status, histórico e evento de notificação ocorrerão na mesma transação. Bloquear o pedido e os saldos necessários, validar todos os insumos e abortar a operação inteira se houver falta; não permitir baixa parcial ou saldo negativo.

Uma restrição de unicidade por pedido/execução de produção impedirá baixa duplicada. A mudança de “Em Produção” para “Concluído” não consumirá novamente os insumos. Pedidos com múltiplos itens somam o consumo por insumo antes da verificação; alterações depois da baixa exigem um fluxo explícito de revisão, não edição silenciosa.

Regra proposta para cancelamento: antes da produção, cancelar sem movimento de estoque; depois da baixa, não devolver material automaticamente. Estorno físico somente com autorização administrativa, motivo e movimentos compensatórios auditáveis, porque papel já cortado ou material transformado não volta ao estoque utilizável. Essa regra será confirmada no plano; reembolso financeiro é um processo separado.

## Orçamentos públicos e acompanhamento

Criar orçamento com cliente, itens, valor, prazo e validade, gerando URL pública `/orcamento/[id]`. O identificador público será opaco e imprevisível, separado do ID interno. A página mostrará os termos aprováveis e o botão “Aprovar Orçamento”.

Aceite por função transacional: validar validade/revogação, bloquear o orçamento, atualizar para `Approved`, criar/vincular o pedido, congelar os itens e devolver o link de acompanhamento. Cliques repetidos retornam o mesmo resultado, sem duplicar pedido ou notificações. Depois do sucesso, redirecionar para `/rastreio/[id]`. Aceite inválido ou expirado mostra uma mensagem clara e não altera registros.

O público não terá SELECT nas tabelas internas de clientes, pedidos ou orçamentos. Somente endpoints/RPCs com projeção limitada. Links não expõem CPF, endereço, telefone, e-mail, margens, custos, observações internas ou chaves. Um link é um acesso por posse do token; permitir validade e revogação.

A página `/rastreio/[id]` exibirá etapa atual, datas e histórico público permitido. Usar Realtime com autorização compatível com o token/projeção, sem abrir tabelas operacionais a anônimos. Se for necessário um canal privado intermediado, a Edge Function emite autorização limitada; não mascarar polling periódico como tempo real.

## Notificações e integrações

Cada mudança de status grava um evento de outbox dentro da transação. Processamento server-side terá idempotência, tentativas, retomada, logs sem segredos e estado de entrega. Falha de WhatsApp não desfaz uma produção já confirmada, mas permanece visível e pode ser repetida com controle.

Implementar notificações na interface com registros persistidos e atualização em tempo real. Para WhatsApp, preparar os adaptadores Z-API/Evolution API e o disparo apenas quando a conta real estiver configurada e autorizada. Notificações internas do app são diferentes de Web Push do navegador; se a paridade exigir Web Push, adicionar permissão, assinatura e serviço seguro, sem prometer push externo antes de configurá-lo.

Preparar variáveis documentadas e rotas server-side para Mercado Pago, Frenet, Shopee e Mercado Livre. Recepção de webhooks deve validar autenticidade conforme cada provedor, evitar duplicidade e traduzir eventos externos para estados internos. Não implementar rotas que retornam sucesso falso, pagamentos fictícios ou cotações simuladas. Configuração ausente será explicitamente desabilitada/indisponível. O requisito atual é arquitetura preparada; ativação e testes de transações reais dependem de contas, credenciais e autorização específica.

## Cobertura dos demais módulos das referências

Manter no escopo os módulos de clientes, tarefas/calendário, tabela de preços/calculadora, financeiro/fluxo de caixa, relatórios, produtos/variações/arquivos digitais, fornecedores, catálogo público, configurações e integrações. Recursos observados como cupons, promoções, frete, domínio de catálogo, equipe, PDV, arte/aprovações e notas fiscais deverão ser inspecionados em seus fluxos específicos antes de definir detalhes e implementar a paridade.

Esses módulos serão construídos em fatias verticais reais depois da fundação e dos fluxos centrais. Não adicionar menus que apontam para páginas vazias como se representassem funcionalidades concluídas. Emissão fiscal, pagamentos externos e marketplaces podem exigir serviço contratado; preparar a arquitetura não significa emitir documentos fiscais ou movimentar dinheiro sem autorização.

## Estrutura do projeto

- `src/app/`: roteamento React, providers, autenticação e composição do shell.
- `src/features/`: módulos separados de estoque, produtos, clientes, pedidos, orçamentos, acompanhamento, produção, financeiro, relatórios, catálogo e configurações.
- `src/components/` e `src/components/ui/`: controles compartilhados, componentes shadcn/ui, formulários, tabelas, estados vazios e navegação responsiva.
- `src/lib/`: cliente Supabase, tipos gerados, decimal, validação, datas e formatação pt-BR.
- `supabase/migrations/`: schema, índices, RLS, RPCs e evolução versionada.
- `supabase/functions/`: endpoints públicos protegidos, adaptadores e processamento de eventos.
- `public/`: identidade visual, favicon e manifesto atualizado `manus-routes.json`.
- `tests/`: verificações automatizadas dos cálculos e integrações transacionais em ambiente dedicado, sem dados fictícios dentro da aplicação ou banco do usuário.
- `docs/`: instalação, configuração e instruções das integrações, sem credenciais.

## Fatia atual: App Shell e Dashboard no padrão Atelier Flow

Manter o projeto como SPA Vite/React/TypeScript com TailwindCSS e Supabase. Usar componentes shadcn/ui em `src/components/ui/`, instalados como código local com aliases compatíveis ao setup Vite atual; não introduzir outro framework, serviço de dados ou camada de servidor. `src/app/layout.tsx` concentra Header, Sidebar, contexto de organização, papel, notificações e saída; deve conservar links reais e visibilidade por papel. `src/app/pages.tsx` continua responsável pelo onboarding e Dashboard, preservando métricas consultadas do Supabase, estados de carregamento/erro e seletor de organização. `src/index.css` define tokens quentes, tipografia, espaçamento e superfícies compartilhadas; os estilos comuns de cartões e tabelas devem resultar em páginas de gestão mais espaçosas sem reescrever suas regras de negócio nesta fatia. Nenhuma métrica ou atividade recente será inventada para preencher espaço.

## Sequência de entregas e GitHub

Depois da aprovação, registrar `TODO.md` com os critérios completos e configurar diagnósticos de TypeScript antes de escrever código de aplicação. Em seguida executar a sequência: schema/RLS/RPCs; autenticação e organização; insumos/compras/custo unitário; produtos/composição; pedidos/baixa automática; orçamento/aceite/rastreio; notificações/arquitetura de integrações; demais módulos de paridade. Cada fatia deve conectar banco, API e UI e passar seus checks antes de ser considerada concluída.

O repositório informado é público. Código, migrations e documentação podem ser enviados; segredos, dados de clientes, HTML privado das referências e arquivos `.env` não serão publicados. Não fazer force-push nem substituir o commit inicial.

A conexão canônica do Manus aceita um repositório GitHub novo, não a adoção deste repositório existente. Arranjo aprovado: preservar o repositório já informado e enviar a ele uma cópia de código versionada com commit/push ao concluir cada funcionalidade central; manter separadamente os checkpoints da prévia no repositório gerenciado Manus. Não criar outro repositório GitHub nem trocar `origin` do projeto para contornar a limitação. A cópia e cada push são verificados e não incluem arquivos privados.

Instalar dependências com gerenciador fixado e permissões de scripts revisadas. Executar verificação de tipos, build e verificações pertinentes à funcionalidade. Usar um agente somente leitura para conferir as conexões da implementação complexa. Não realizar testes que gravem ou apaguem registros em produção sem uma decisão explícita sobre ambiente de teste. Publicação só será declarada quando confirmada; nenhuma publicação automática está habilitada.

## Configuração e dependências externas

O projeto Supabase autorizado foi configurado por formulário protegido e inspecionado antes da fundação. A conexão do Session pooler foi verificada no painel; não houve reset ou redefinição de senha. O proprietário realizou pessoalmente cadastro e login no aplicativo, e sua organização real foi vinculada. Migrations seguintes continuam preservando dados existentes.

As contas e chaves de WhatsApp e outros provedores serão solicitadas quando a fatia correspondente precisar ser ativada, não como segredos obrigatórios fictícios. Nenhuma senha das referências será copiada ao projeto.

Plano, identidade unificada, cópia versionada ao GitHub existente e Supabase já foram aprovados/resolvidos. A aplicação progride por fatias com evidências no TODO e docs; não alegar paridade, integração ativada ou publicação sem sua verificação específica.
