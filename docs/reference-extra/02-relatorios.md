# Relatórios e indicadores — inspeção somente leitura

Inspeção autenticada realizada em 29/10/2026 nas referências autorizadas. O conteúdo abaixo registra apenas estrutura de interface, rótulos, opções, microcopy e regras observáveis. Valores financeiros, nomes, datas específicas, identificadores de pedidos, e-mails, tokens e demais dados privados da sessão foram deliberadamente omitidos. Esta inspeção não comprova paridade implementada no sistema de origem nem no produto Vê na Memória.

## AtelierFlow — Gestão de Pedidos / Relatórios

A página de relatórios é acessível pela aba `Relatórios` da área de pedidos. O cabeçalho usa a microcopy **“Acompanhamento operacional, relatórios consolidados e métricas de vendas”**. A apresentação mantém a navegação lateral do AtelierFlow e organiza o conteúdo em cartões e áreas de análise.

### Controles e filtros observados

- Ações visíveis: `Exportar CSV` e `Atualizar`.
- Escopo de período: `Por Mês`, `Datas Específicas` e `Todo o Período`.
- Métrica para a visualização: `Por Volume (Qtd)` ou `Por Receita (R$)`.
- Visualização do detalhamento: `Visualizar em Tabela` ou `Visualizar em Cards`.
- Segmentação do detalhamento: `Todos`, `Serviços` e `Produtos`.
- Ordenação: `Mais Vendidos (Qtd)`, `Maior Receita (R$)` e `Nome (A - Z)`.
- Busca: campo com o placeholder `Buscar serviço ou produto pelo nome ou categoria...`.

### Indicadores, visualizações e estados

- Cartões principais: `Peças & Serviços`, `Faturamento do Mês`, `Ordens & Balcão` e `Item Campeão`.
- Seção `Distribuição Visual de Vendas & Pedidos`, com os blocos `Mix: Serviços vs. Produtos` e `Top Itens & Concentração`.
- O bloco de concentração explicita `Top 5 + Demais`, indicando uma agregação de itens dominantes.
- Seção `Mix de Produtos & Serviços` e seção `Pedidos & Vendas Detalhados`.
- O detalhamento descreve saídas unitárias, receita acumulada, ticket médio e percentuais calculados.
- Estados vazios observados: `Sem dados para exibir o gráfico`, `Nenhum item encontrado` e `Nenhum pedido ou venda foi registrado ainda para gerar o relatório.`
- Há um indicador textual de atualização do documento e uma explicação de processamento incremental, sem que isso seja tratado como prova de integração externa.

O relatório não foi exportado, atualizado por ação, filtrado, ordenado ou preenchido. Os botões de exportação foram apenas observados.

## PapelariaOn — Relatório Geral e indicadores

No dashboard da PapelariaOn, o grupo expansível `Relatórios` mostra os links `Geral`, `Diário`, `Funcionários` e `Notas fiscais`. O link efetivamente aberto foi o href relativo observado `relatorio.php`, resolvido na página autorizada abaixo. Os demais links foram apenas listados no menu e não foram abertos nesta inspeção.

O cabeçalho da página geral usa `Relatórios` e `Relatório & Tomada de Decisão`. O layout combina barra lateral escura, navegação agrupada, um painel superior de filtros e cartões de indicadores, seguido por navegação interna por âncoras e seções analíticas.

### Controles e filtros observados

- Seletor de período com as opções `Hoje`, `Últimos 7 dias`, `Últimos 30 dias`, `Mês atual` e `Personalizado`.
- Campos de data rotulados `Início` e `Fim`; os campos foram somente observados e não preenchidos.
- Ação `Atualizar`.
- Links rápidos `Relatório Diário`, `Funcionários` e `Livro de Caixa`.
- Bloco `Caixa do dia`, com campo de data e ação `Ver Caixa`.
- Ação `Exportar PDF`, somente observada.
- Âncoras internas: `Visão Geral`, `Gráficos`, `Pagamentos`, `Estoque`, `Vendas` e `Rentabilidade`.

### Cartões e seções

Cartões de destaque observados: `Recebido no período`, `Lucro bruto produtos`, `Forma líder de pagamento` e `Produto líder`.

A seção `Visão geral do período` é descrita como `Resumo executivo com prioridades, ritmo da operação e indicadores principais`. Ela contém:

- `Resumo executivo`, com a microcopy `o que mais importa`;
- `Prioridades do periodo`, com a microcopy `o que olhar agora` e avisos de atenção;
- `Radar da papelaria`, com a microcopy `gestao e operacao`;
- indicadores de ritmo de pedidos, eficiência operacional, ticket médio, taxa de recebimento, conversão de catálogo, pedidos no período, pedidos em andamento, clientes novos, pedidos de hoje, atrasados, próximos 7 dias, previsto líquido, saldo em aberto, lucro estimado, despesas pagas, custo dos produtos e lucro bruto dos produtos.

A seção `Gráficos e tendências` contém os rótulos `Pedidos por dia`, `Pedidos por status`, `Recebido por dia`, `Visitas por dia` e `Top produtos vendidos`.

A seção `Pagamentos e receitas` contém `Pagamentos por método` e `Participação por método`.

A seção `Estoque e reposição` contém `Estoque crítico`.

A seção `Vendas, clientes e pedidos` contém `Itens vendidos no período`, `Top clientes`, `Top receitas` e `Top pedidos`.

A seção `Rentabilidade` contém `Venda x custo` e `Venda x custo x lucro`.

### Regras e microcopy observáveis

- O período pode ser predefinido ou personalizado por datas de início e fim.
- O cartão de atraso usa a regra textual `previsao_entrega < hoje`.
- A descrição de `Taxa de recebimento` relaciona o indicador ao previsto líquido já convertido em pagamento.
- `Saldo em aberto` é descrito como a diferença entre previsto líquido e recebido.
- `Lucro estimado` é descrito como recebimentos menos despesas pagas.
- `Custo dos produtos` pode ser estimado por custo simples ou composição.
- Avisos de prioridade usam o marcador `atencao` e orientam revisão de produção, contato com clientes ou cobrança de saldos em aberto.
- O conteúdo inclui estados como `Sem dados`, mas nenhum valor desse estado foi copiado para este arquivo.

O relatório não foi atualizado, não houve preenchimento de datas, não foi aberto o caixa, não houve exportação para PDF e nenhum dos relatórios irmãos foi executado.

## Limites da observação

A inspeção confirma a existência e a organização visual dos controles descritos, mas não valida cálculos, persistência, permissões, integrações ou funcionamento de exportação. Ações de exportar, atualizar, consultar caixa, acessar notas fiscais, efetuar pagamento, alterar configurações e quaisquer ações de cadastro foram intencionalmente evitadas. Não houve bloqueio de login nesta sessão. Como os relatórios `Diário`, `Funcionários` e `Notas fiscais` da PapelariaOn foram apenas observados no menu, o status desta fatia é **parcial** para cobertura de todos os sublinks do grupo Relatórios.

## Referências

[1]: https://www.atelierflow.com.br/pedidos "AtelierFlow — Gestão de Pedidos"
[2]: https://www.atelierflow.com.br/pedidos/relatorios "AtelierFlow — Relatórios"
[3]: https://papelariaon.com/dashboard/index.php "PapelariaOn — Dashboard"
[4]: https://papelariaon.com/dashboard/relatorio.php "PapelariaOn — Relatório Geral"
