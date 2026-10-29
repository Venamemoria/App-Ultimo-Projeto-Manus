# Insumos — formulário de referência observado

Fonte: https://papelariaon.com/dashboard/insumos.php, sessão autorizada, inspeção somente leitura em 29/10/2026. Nenhum cadastro, importação, pagamento ou alteração foi enviado.

O botão Novo insumo abre modal com categoria, código de barras opcional, nome, descrição opcional, foto e opção de uso interno ou venda no PDV. Categorias podem ser escolhidas; a tela oferece gerenciamento separado. A foto é um arquivo enviado pelo usuário, não imagem demonstrativa.

Há dois modos de entrada. “Lançar do jeito que comprei” permite unidade, caixa, metro ou centímetro; recebe quantidade e preço de compra por item cadastrado. “Converter pacote em unidades” mostra pacotes comprados, unidades por pacote e custo total da compra; calcula a quantidade total como pacotes × unidades e o custo unitário como custo total / quantidade total. O painel mostra os resultados durante o preenchimento. O preço de venda é por unidade final se a venda no PDV está marcada; uso interno dispensa preço de venda.

A lista possui busca por nome/categoria/código, filtros avançados, histórico, exportação, importação e cadastro em lote. Mostra indicadores de número de insumos, valor de estoque ao custo, valor potencial de venda e itens abaixo de cinco unidades. O ERP próprio usa o limite de reposição definido por insumo, conforme requisito aprovado, em vez de depender de um limite global fixo.

Esses são campos/fluxos de referência, não uma afirmação de que todos já foram implementados. O backend da fatia inicial de inventário prioriza o cálculo decimal, saldo inicial sem despesa, compras com vínculo financeiro e histórico auditável. Código de barras, foto, venda no PDV e ferramentas de lote precisam ser persistidos/implementados na paridade correspondente antes de alegar equivalência completa. Não criar controles que fingem salvar campos ausentes no backend.
