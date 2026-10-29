# Referências de interface — Vê na Memória

Inspeção realizada em 29/10/2026 em sessões autorizadas. Foram abertas páginas e um diálogo de orientação sem salvar alterações. Este documento contém somente organização de interface e fluxos, não os dados das contas, screenshots privados ou HTML exportado.

## AtelierFlow

Em `https://www.atelierflow.com.br/dashboard`, a navegação lateral oferece Dashboard, Fluxo de Caixa, Pedidos, Clientes, Tarefas, Tabela de Preços, Calculadora, Ajuda e Configurações. O grupo Estoque & Custos reúne Inventário, Registro de Compras, Catálogo de Produtos e link de Vitrine Pública. A apresentação usa fundo creme e destaques quentes. O dashboard combina saudação, seleção de mês, ação de adicionar, pedidos pendentes, indicadores de resultado, atividade, desempenho financeiro e pedidos recentes. Recursos promocionais/trial pertencem ao SaaS de referência, não aos dados do ateliê.

Em `https://www.atelierflow.com.br/pedidos`, há abas Fluxo de Trabalho, Histórico de Vendas, Saldos a Receber e Relatórios. A lista tem busca por cliente/telefone/serviço/código, filtros de mês e serviço, exportação e ação Novo Pedido. Os filtros de estado são Novo, Em Processo, Pedido Pronto/Aguardando Retirada, Entregue e Cancelado. As colunas incluem cliente, serviços, faturamento/saldo, prazo e status, com ações de comprovante, mudança de etapa e menu contextual. O formulário completo de pedido ainda não foi inspecionado.

Em `https://www.atelierflow.com.br/estoque`, a página Inventário de Materiais contém Lista de Insumos, Alertas de Reposição e Relatórios de Consumo; busca de material, filtro de categoria, relatório, sincronização e ação de adicionar. A lista apresenta material, categoria, preço unitário, saldo e popularidade. O texto informa que as entradas vêm de compras e saídas de conclusão do pedido.

A ação Adicionar Material abriu um diálogo explicando que o Registro de Compras mantém o Fluxo de Caixa e os custos atualizados. Para cadastrar saldo inicial sem despesa, a referência exige habilitar um modo de migração nas configurações. Não foi habilitado nenhum modo nem criado material. Essa distinção entre saldo inicial e compra é relevante para o ERP.

## Papelaria On

Em `https://papelariaon.com/dashboard/index.php`, a navegação lateral usa grupos expansíveis. Vendas: Pedidos, Novo pedido, PDV, Calendário e Kanban. Produtos: Produtos, Novo produto, Arquivos digitais, Estoque das variações, Insumos e Fornecedores. Clientes: listagem e cadastro. Financeiro: visão geral, receitas, despesas e livro caixa. Relatórios: geral, diário, funcionários e notas fiscais. Catálogo: configuração, personalização, cupons, promoção, frete e domínio. Configurações: sistema, integrações, treinamentos, funcionários e indicações. Há ainda um serviço Studio separado e controles da assinatura/conta.

O dashboard usa barra lateral escura, acentos roxos e cartões brancos em fundo claro. Apresenta resumo do mês, atenção de pedidos sem previsão/aguardando pagamento/artes pendentes/alterações/orçamentos parados, pedidos de hoje, atrasos, estoque em risco, resumo financeiro, alertas, agenda, produção do dia, próximos sete dias, últimos pedidos e aniversariantes. Os banners de renovação são específicos do SaaS de referência.

Em `https://papelariaon.com/dashboard/insumos.php`, há indicadores de itens cadastrados, valor em estoque ao custo, valor potencial de venda e atenção de saldo baixo. Ações: Novo insumo, Cadastro em lote, Categorias, Fornecedores, Importar, Histórico e Exportar. Há busca por nome/categoria/código e filtros avançados. O saldo vazio mostra mensagem de ausência com orientação, sem carregar demonstração. O formulário Novo insumo ainda não foi aberto.

Em `https://papelariaon.com/dashboard/novo_produto.php`, o cadastro é organizado em quatro etapas: Produto, Preço, Descrição e Ajustes finais. A primeira pede nome, foto principal, múltiplas categorias com a primeira como principal e subcategoria opcional. Aceita foto JPG/PNG/WEBP e indica galeria depois do salvamento. Ao lado há prévia de catálogo e qualidade do cadastro. Nome e categoria são obrigatórios nesta etapa. Não foi enviado o formulário nem usado um modelo para cadastrar produto.

Em `https://papelariaon.com/dashboard/novo_pedido.php`, o fluxo começa por dados básicos e adiciona itens/pagamentos depois. Campos visíveis: cliente pesquisável, cadastro rápido de cliente, data do pedido, status inicial, previsão de produção, entrega e descrição breve. Os estados iniciais observados são Pendente, Em Produção, Pedido do Catálogo e Orçamento. Previsão de produção é opcional e aparece no calendário; entrega é opcional apenas em orçamento. Nenhum pedido foi criado.

## Limites concretos da inspeção atual

Ainda não houve inspeção detalhada dos demais formulários, menu contextual de pedido, edição da composição, arte/aprovação, pagamentos, relatórios, PDV, catálogo, permissões, integrações, notas fiscais, recursos de voz ou serviços de terceiros. A aparição de um link no menu não comprova um fluxo ou requisito técnico completo. Essas páginas precisam ser observadas quando a respectiva fatia for implementada. Não foi acessado código backend de nenhuma referência.

O requisito de baixa na entrada em Em Produção OU Concluído vem do briefing do usuário e prevalece sobre o texto de inventário do AtelierFlow, que menciona apenas conclusão. O ERP precisa implementar a regra solicitada e impedir a segunda baixa.
