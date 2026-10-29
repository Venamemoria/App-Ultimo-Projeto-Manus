# Cadastro de produto — referência observada

Inspeção em 29/10/2026 de `https://papelariaon.com/dashboard/novo_produto.php`, em sessão autorizada e somente leitura. Foram lidos rótulos e estrutura DOM já carregados; nenhum valor foi preenchido, modelo aplicado, produto salvo ou recurso de assinatura ativado. Este registro não contém dados pessoais nem categorias/IDs particulares da conta.

A referência organiza o formulário em Produto, Preço, Descrição e Ajustes finais. Produto exige nome e categoria; permite múltiplas categorias com a primeira como principal, subcategoria opcional e foto JPG/PNG/WebP. A galeria é indicada após salvar. A prévia de catálogo e a qualidade do cadastro são derivadas dos campos, não registros persistidos de demonstração.

Preço possui três modos: fixo por unidade, variável por opção e por metro quadrado. Há preço normal/promocional, preço por m²/promocional por m² e opção de atacado. Os exemplos do SaaS não devem virar registros do ERP. Regras completas de variações/atacado ainda precisam ser explicitamente preservadas na implementação, não apenas um seletor sem comportamento.

Descrição inclui material/acabamento, personalização permitida, dias de produção e editor de descrição. Ajustes finais agrupam presença/destaque no catálogo, quantidade mínima e regra de variação, perguntas ao cliente, controle de estoque, peso em kg e medidas em cm, código de barras/SKU. O DOM também contém configuração de modo/composição de estoque; a regra solicitada no briefing para baixa fracionária continua prevalecendo.

O ERP deve persistir o que expõe: categorias, descrição, opções/preços, mínimos, informações de produção, medidas e arquivos precisam de contrato real. A composição material é versionada, calculada com decimal/numeric e congela o que será necessário aos pedidos. Visibilidade no catálogo não significa publicar automaticamente uma vitrine ainda não configurada. Campos sem comportamento completo permanecem pendentes, nunca fingidos.
