# Inspeção de PDV e estoque de produto acabado

**Status da inspeção:** parcial. Os módulos visíveis da PapelariaOn foram observados em modo somente leitura. Nas páginas autorizadas do AtelierFlow, não foi encontrado um módulo PDV nem um estoque de produto acabado; foi confirmado apenas o inventário de materiais/insumos. Esta inspeção não afirma paridade implementada.

## AtelierFlow

Na página de pedidos, a interface é intitulada **Gestão de Pedidos** e apresenta as abas **Fluxo de Trabalho**, **Histórico de Vendas**, **Saldos a Receber** e **Relatórios**. Há busca por cliente/telefone/serviço/código, ações **Exportar** e **Novo Pedido**, filtros de estado **Todos os Pedidos**, **Novo**, **Em Processo**, **Pedido Pronto (Aguardando Retirada)**, **Entregue** e **Cancelado**, além de mês e serviço. As colunas observadas são **Cliente**, **Serviços**, **Faturamento**, **Prazo de Entrega** e **Status**, com ações de comprovante e mudança de etapa. Não apareceu rótulo ou fluxo de **PDV** nessa rota.

O link real **Inventário** abriu **Inventário de Materiais**, com a descrição de acompanhamento de saldo, consumo e custos de insumos. Os controles visíveis foram **Sincronizar Estoque**, **Adicionar Material**, **Lista de Insumos**, **Alertas de Reposição**, **Relatórios de Consumo**, busca **Pesquisar material pelo nome...**, **Relatório** e **Todos os Materiais**. As colunas são **Material**, **Categoria**, **Preço Unitário**, **Saldo em Estoque** e **Popularidade**. A microcopy informa que as entradas vêm do **Registro de Compras** e as saídas ocorrem ao **Concluir um Pedido**. Trata-se de insumo/material, não de estoque de produto acabado. Nenhum cadastro, sincronização ou alteração foi executado.

## PapelariaON — PDV

No dashboard, o grupo **Vendas** contém **Pedidos**, **Novo pedido**, **PDV**, **Calendário** e **Kanban**. O href observado para PDV foi `pedidos.php?visao=pdv`.

A rota de pedidos/PDV exibe **Gerencie seus pedidos** e as ações **Tags**, **Imprimir produção**, **Imprimir comprovantes**, **Exportar**, **Kanban**, **Venda rápida**, **Criar orçamento** e **Novo pedido**. Os cards de visão/status são **Pedidos — Visão geral**, **Produção — Em andamento**, **Pendente — Aguardando**, **Orçamentos — Pré-venda**, **Catálogo — Online**, **Finalizados — Aguard. entrega**, **Entregues — Concluídos**, **PDV — Venda rápida** e **Cancelados — Encerrados**. Há busca com o placeholder **Ex.: 1024 ou Maria**, ação **Buscar agora**, **Limpar tudo** e **Filtros**. O estado observado da lista foi **Nenhum pedido encontrado.**

Abrir **Venda rápida** não mostrou campos editáveis diretamente. Em vez disso, abriu o diálogo **Iniciar venda rápida?** com a pergunta **Deseja realmente abrir um pedido rápido no PDV?** e os botões **Sim, iniciar** e **Cancelar**. **Sim, iniciar** foi deliberadamente bloqueado porque poderia criar um registro; somente **Cancelar** foi acionado. Portanto, os campos internos da venda rápida, itens, cliente, recebimento e confirmação não foram observados e não devem ser inferidos.

## PapelariaON — estoque de produto acabado

No grupo **Produtos**, o menu expõe **Produtos**, **Novo produto**, **Arquivos digitais**, **Estoque das variações**, **Insumos** e **Fornecedores**. O href real observado para o estoque foi `produtos_estoque_variacoes.php`.

A página é intitulada **Estoque das variações** e usa a microcopy **Saldo por opção de produto**. Explica que acompanha camisetas, tamanhos, modelos e qualquer variação com estoque próprio. Os indicadores são **Opções com estoque**, **Itens de estoque**, **Saldo total** e **Baixo ou zerado**. O filtro de busca aceita **Produto, grupo, opção ou item de estoque**; a seleção **Visão** oferece **Todos os saldos** e **Somente baixo/zerado**, com o botão **Filtrar**.

A seção **Variações vinculadas** informa que mostra somente opções com estoque próprio vinculado. As colunas observadas são **Produto**, **Variação**, **Estoque**, **Saldo**, **Entradas**, **Saídas** e **Última mov.** A seção **Últimas movimentações** descreve **Entradas manuais, criação de estoque e baixas vindas de pedidos**, com colunas **Data**, **Produto/opção**, **Origem**, **Movimento** e **Saldo final**. O estado observado foi **Nenhuma variação com estoque próprio encontrada.** e **Ainda não há movimentações para variações.** Não havia ação visível de edição, entrada, ajuste, importação ou exportação nessa página; nenhuma alteração foi realizada.

## Restrições e bloqueios

- Inspeção limitada a navegação, menus, visualização, rótulos e estados vazios.
- Não foram enviados formulários, criados pedidos/produtos/estoques, escolhidos itens ou clientes, confirmadas vendas, realizados pagamentos, emitidas notas, exportados dados, baixados CSVs ou alteradas configurações.
- A confirmação **Sim, iniciar** do PDV foi bloqueada por risco de criação de pedido.
- Os dados exibidos em estado vazio não comprovam ausência geral de capacidade; apenas registram o estado observado nessa sessão.
- Não foi inferida integração funcionando nem declarada paridade com qualquer referência.

## Sources

- [1]: https://www.atelierflow.com.br/pedidos "AtelierFlow — Gestão de Pedidos"
- [2]: https://www.atelierflow.com.br/estoque "AtelierFlow — Inventário de Materiais"
- [3]: https://papelariaon.com/dashboard/index.php "PapelariaON — Dashboard"
- [4]: https://papelariaon.com/dashboard/pedidos.php?visao=pdv "PapelariaON — Pedidos / PDV"
- [5]: https://papelariaon.com/dashboard/produtos_estoque_variacoes.php "PapelariaON — Estoque das variações"
