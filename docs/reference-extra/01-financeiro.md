# Inspeção autorizada — Financeiro e Livro Caixa

Inspeção somente de leitura realizada em 29/10/2026 nas referências autorizadas. Nenhum campo foi preenchido e nenhuma ação de cadastro, salvamento, alteração, exportação, cobrança, pagamento, emissão fiscal ou configuração foi executada. As páginas exibiam conteúdo de demonstração ou estado vazio; nomes, identificadores, datas específicas, valores e demais dados financeiros foram deliberadamente omitidos.

## AtelierFlow — Fluxo de Caixa

Fonte de entrada: [Pedidos](https://www.atelierflow.com.br/pedidos). O menu lateral expõe o link real **Fluxo de Caixa**, observado como `/fluxo-caixa`.

Na tela **Controle Financeiro / Balanço e Fluxo**, a organização visual reúne uma linha do tempo consolidada de entradas e saídas e um seletor mensal. Há um bloco **Controle de Caixa Diário** com estado de caixa fechado, orientação para registrar o fundo de troco inicial e ações **Histórico** e **Abrir Caixa do Dia**. A ação de abertura não foi executada por poder iniciar um fluxo financeiro.

Os cartões e seções observados foram: **Lucro Líquido**, **Entradas (Faturamento)**, **Saídas (Custo Real)**, **Discriminação por Meio de Pagamento**, **Configurar Taxas**, **Distribuição do Faturamento**, **Recebido em Caixa**, **Previsto a Receber**, **Total Projetado**, filtros **Todos / Entradas / Saídas**, preferência **Edição Manual (Não recomendado)**, **Lançamentos Recentes**, **Ver resumo do dia**, **Contas & Compras a Pagar**, filtros **Todas / Contas Fixas / Compras a Pagar**, **Ver Taxas/Juros**, **Fiados e Saldos a Receber**, **Ver todos**, **Abater Pagamento** e **Receber**.

A página também informa que o fluxo consolida entradas e saídas, separa faturamento bruto, taxas e líquido, distingue caixa realizado de valores previstos a receber e agrupa contas a pagar, compras e saldos de pedidos. A presença dos controles foi registrada como interface observada; não foi inferido que qualquer integração de pagamento, taxa ou recebimento esteja ativa.

## Papelaria On — módulo Financeiro

Fonte de entrada: [Dashboard](https://papelariaon.com/dashboard/index.php). O grupo expansível **Financeiro** contém os links reais **Visão geral** (`financeiro.php`), **Receitas** (`receitas.php`), **Despesas** (`despesas.php`) e **Livro caixa** (`livro_caixa.php`).

Na [Visão geral financeira](https://papelariaon.com/dashboard/financeiro.php), foram observados os controles de abas **Visão geral**, **Pedidos em aberto**, **Receitas**, **Despesas** e **Livro de caixa**. Há filtros de período **Início** e **Fim**, ações **Aplicar** e **Limpar**, e a orientação de que os gráficos usam os últimos 30 dias quando não se aplica um intervalo.

Os blocos de leitura exibidos foram: **Saldo hoje**, **Saldo 7 dias**, **Saldo 30 dias**, **Pedidos em aberto (saldo)**, **Custo produção (30d) — estimado**, **Lucro bruto (30d) — estimado**, **Previsão de caixa**, **Próximos 7 dias**, **Entradas previstas**, **Saídas previstas**, **Janela de 30 dias**, **Contas a receber** com faixas **Vencidos / Vence hoje / 1 a 7 dias / 8 a 30 dias**, **Contas a pagar** com faixas **Atrasadas / Vencem hoje / 1 a 7 dias / 8 a 30 dias**, **Comparativo com período anterior**, **Pedidos com saldo devedor**, **Fluxo de Caixa (30 dias)**, **Receitas por origem (30d)**, **Despesas por categoria (30d)** e **Resumo rápido** com **A pagar hoje / Atrasadas / Próximas (7 dias)**.

A microcopy distingue valores recebidos/pagos de valores previstos, trata custo e lucro como estimados quando aplicável e observa que o saldo do gráfico considera despesas pagas. O link de detalhes de pedidos em aberto foi observado, mas não aberto por não ser necessário ao escopo.

## Papelaria On — Livro Caixa

Fonte direta observada no menu: [Livro caixa](https://papelariaon.com/dashboard/livro_caixa.php). A tela é intitulada **Livro Caixa** e descreve **Entradas, saídas e saldo — com visão diária/mensal e quebra por funcionário**. Há o link **Voltar** para o financeiro.

Filtros e opções vazias observados: **Período** com **Hoje / Ontem / Últimos 7 dias / Mês atual / Mês anterior / Personalizado**; campos **Início** e **Fim**; **Modo** com **Caixa (recebido/pago) / Previsto (valor pedidos)**; **Pagamento** com **Todas as formas / PIX / Dinheiro / Cartão crédito / Cartão débito / Boleto / Shopee/ML/ELO7 / Ifood / Faturado / Outros**; **Agrupar** com **Dia / Mês**; **Quebra** com **Geral / Por funcionário**; e ações **Atualizar** e **Exportar CSV**. Nenhum filtro foi alterado e o CSV não foi exportado.

Os cartões observados foram **Entradas (Caixa)**, **Saídas (Caixa)** e **Saldo**. A seção **Entradas por forma de pagamento** informa que considera somente pagamentos de pedidos e que receitas avulsas não possuem forma de pagamento. A seção **Controle diario do caixa** traz indicadores de períodos com movimento, dias com movimentação, médias de entradas e saídas, maior entrada, maior saída, pior saldo e saldo final acumulado. **Alertas do caixa** apresenta a conferência de dias sem movimento registrados.

A tabela final **Livro Caixa** possui as colunas **Data / Entradas / Saídas / Saldo / Acumulado / Detalhes** e um estado vazio de ausência de movimentações no período observado. A página exibiu estados e rótulos reais da interface; não foi inferida persistência ou integração além do que estava visível.

## Limites da evidência

Este registro documenta paridade visual e textual observada apenas para o módulo Financeiro, Fluxo de Caixa e Livro Caixa. Não afirma paridade implementada no produto Vê na Memória, não valida integrações, não testa permissões e não comprova funcionamento de pagamentos, taxas, exportação ou lançamentos manuais.

## Referências

[1]: https://www.atelierflow.com.br/pedidos "AtelierFlow — Pedidos, fonte do menu Fluxo de Caixa"
[2]: https://www.atelierflow.com.br/fluxo-caixa "AtelierFlow — Controle Financeiro / Balanço e Fluxo"
[3]: https://papelariaon.com/dashboard/index.php "Papelaria On — Dashboard e menu Financeiro"
[4]: https://papelariaon.com/dashboard/financeiro.php "Papelaria On — Visão geral financeira"
[5]: https://papelariaon.com/dashboard/livro_caixa.php "Papelaria On — Livro Caixa"
