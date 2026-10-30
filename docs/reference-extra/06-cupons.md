# Cupons e promoção — inspeção observacional

**Escopo:** somente o módulo de Cupons e promoção nas URLs autorizadas. Não houve preenchimento, cadastro, salvamento, upload, exportação, pagamento ou alteração de configuração. O conteúdo abaixo registra apenas interface, rótulos, microcopy genérico, estados vazios e hrefs reais observados.

## Resultado

Status da inspeção: **partial**. O módulo foi observado no PapelariaOn. Na página autorizada de pedidos do AtelierFlow não foram encontrados rótulos ou links de “cupom”/“promoção”; a navegação disponível nessa página não expôs um grupo de catálogo promocional. Isso não comprova inexistência do recurso em outras rotas nem paridade de implementação.

## AtelierFlow

Fonte inspecionada: [Pedidos — AtelierFlow][1]

- A navegação observada na página de pedidos apresenta Dashboard, Fluxo de Caixa, Pedidos, Clientes, Tarefas, Tabela de Preços, Calculadora, Central de Ajuda, Configurações e o grupo Estoque & Custos.
- Não foi localizado texto contendo “cupom” ou “promoção” na página autorizada `/pedidos`.
- Não foi aberta outra rota do AtelierFlow, para manter o escopo no endereço autorizado e no módulo solicitado.

## PapelariaOn — menu e Cupons

Fontes inspecionadas: [Dashboard — PapelariaON][2] e [Cupons de desconto — PapelariaON][3].

- O grupo **Catálogo** do dashboard contém os links **Configurar catálogo**, **Personalizar**, **Cupons**, **Promoção**, **Frete** e **Domínio próprio**.
- O href real observado para Cupons é `/dashboard/catalogo_cupons.php`.
- A página tem o título **Cupons de desconto** e a microcopy informa que é possível criar cupons livres, exclusivos para clientes ou vinculados a produtos específicos, acompanhando uso, limite e impacto em descontos.
- A área de resumo apresenta os rótulos **Cupons**, **Ativos**, **Usos** e **Descontos**.
- A tabela de cupons cadastrados usa as colunas **Cupom**, **Desconto**, **Aplicação**, **Validade**, **Uso**, **Status** e **Ações**.
- O estado observado é vazio, com mensagem de que nenhum cupom foi cadastrado. Também aparecem os rótulos **Produto específico** e **Cliente específico** como indicadores de aplicação.

### Formulário vazio de Novo cupom

O diálogo **Novo cupom** foi apenas aberto para leitura. Os campos, opções e microcopy observados foram:

- Escolha de aplicação: **Livre** — qualquer cliente pode usar no catálogo; **Cliente** — somente um cliente específico poderá usar; **Produto** — o desconto vale para um produto escolhido.
- **Código**.
- **Tipo de desconto**, com as opções **Valor fixo (R$)** e **Percentual (%)**.
- **Valor**.
- **Limite de uso**, com microcopy de limite sem restrição quando o campo permanece no padrão.
- **Uso por cliente** e a opção **Permitir apenas 1 uso por cliente**, acompanhada de microcopy para cupons de boas-vindas.
- **Validade**, com as opções **Sem validade definida** e **Definir período**.
- **Status**, com as opções **Ativo** e **Inativo**.
- Campos de data **Início** e **Fim**.
- Ações **Cancelar** e **Salvar cupom**. A ação de salvar não foi executada.

## PapelariaOn — Promoção

Fonte inspecionada: [Promoção do catálogo — PapelariaON][4].

- O href real observado para Promoção é `/dashboard/catalogo_promocao.php`.
- O cabeçalho descreve **Promoções para toda a loja** e uma campanha geral do catálogo.
- A microcopy informa que o desconto automático se aplica a todos os produtos do catálogo e que o efeito pode ser acompanhado nos pedidos e itens vendidos durante a campanha.
- A seção **Configurar promoção** informa que a promoção aparece automaticamente no carrinho e na finalização.
- Campos/rótulos vazios observados: **Nome da campanha**, **Desconto (%)**, **Início**, **Fim** e **Banner do popup**.
- O banner aceita arquivo de imagem; a orientação de interface informa formato JPG, PNG ou WebP e recomenda imagem quadrada. Nenhum arquivo foi escolhido ou enviado.
- A ação disponível é **Salvar promoção**; não foi executada.
- A seção **Resultado da campanha atual** mostra estado **Inativa** e os rótulos **Pedidos**, **Itens**, **Vendido** e **Descontos**, sem campanha ativa observada.
- A seção **Histórico de promoções** informa que os dados são calculados pelo período de cada campanha e apresenta estado vazio, sem promoção cadastrada.

## Limitações

A inspeção não comprova integração com pedidos, carrinho, checkout, catálogo público, clientes ou cálculo financeiro. Não foi criada ou alterada nenhuma entidade e não foi executado nenhum botão de confirmação. A ausência do módulo na página `/pedidos` do AtelierFlow não deve ser interpretada como ausência global do produto.

## Referências

[1]: https://www.atelierflow.com.br/pedidos "Pedidos — AtelierFlow"
[2]: https://papelariaon.com/dashboard/index.php "Dashboard — PapelariaON"
[3]: https://papelariaon.com/dashboard/catalogo_cupons.php "Cupons de desconto — PapelariaON"
[4]: https://papelariaon.com/dashboard/catalogo_promocao.php "Promoção do catálogo — PapelariaON"
