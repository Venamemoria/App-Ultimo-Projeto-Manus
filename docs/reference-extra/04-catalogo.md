# Catálogo público — inspeção de referências

**Status:** parcial. A Papelaria On foi observada nas telas de configuração e personalização do catálogo. No AtelierFlow, a navegação permitiu confirmar a entrada de vitrine pública, mas o controle é um botão sem href e não foi acionado para evitar copiar/abrir um recurso da conta. Esta inspeção não comprova paridade nem funcionamento de integração.

## AtelierFlow

Fonte inicial: `/pedidos`.

Na navegação lateral, o grupo **Estoque & Custos** apresenta **Catálogo de Produtos** com href real `/catalogo` e o controle **Vitrine Pública COPIAR LINK**. O segundo elemento é um `button`, não um link, e não expõe href. Não foi clicado; portanto, a inspeção não determinou se ele abre a vitrine, copia uma URL ou exige outra condição. Nenhum catálogo público foi aberto e nenhuma ação de cópia ou alteração foi executada.

## Papelaria On — configuração do catálogo

A navegação do grupo **Catálogo** expõe estes links reais: **Configurar catálogo** (`catalogo.php`), **Personalizar** (`catalogo_personalizar.php`), **Cupons** (`catalogo_cupons.php`), **Promoção** (`catalogo_promocao.php`), **Frete** (`catalogo_frete.php`) e **Domínio próprio** (`catalogo_dominio_proprio.php`). Apenas os dois primeiros foram abertos; os demais foram registrados como entradas de menu, sem inferir seus fluxos.

Em **Configurações do Catálogo** (`catalogo.php`), a microcopy orienta a organizar links, banners, destaques e ordem dos produtos. A área de link principal contém os rótulos **URL do catálogo**, **Copiar link do catálogo**, **Compartilhar agora**, **Abrir catálogo** e **Ver opções de link**. Não foram acionados copiar, compartilhar ou abrir.

As abas observadas são **Resumo**, **Links**, **Produtos (ordem)**, **Destaques** e **Banners**.

- **Resumo:** cartões para produtos cadastrados, cobertura no catálogo, produtos em destaque e produtos com imagem; bloco de visitas; produtos mais clicados; saúde do catálogo com estados **Fora do catálogo**, **Sem imagem** e **Estoque baixo**; distribuição por categorias; atalho **Ir para ordenar produtos**. O estado sem cliques e a mensagem de distribuição indisponível foram observados como estados vazios.
- **Links:** área **Meu Catálogo Online**, ações de compartilhar e abrir, **Editar link personalizado** e **Solicitar domínio próprio**. A regra/microcopy observada diz que a solicitação de domínio próprio passa por ativação da equipe e que o apontamento DNS só deve ocorrer depois da aprovação, porque antes disso o domínio precisa ser criado no servidor. Nenhuma solicitação, edição ou compartilhamento foi executada.
- **Produtos (ordem):** **Ordem dos produtos no catálogo**, instrução para arrastar para cima/baixo e clicar em **Salvar ordem**, além de **Resetar (por ID)**. O estado vazio informa que não há produto cadastrado. Nenhuma ordem foi arrastada, resetada ou salva.
- **Destaques:** texto explicando que a chamada aparece no catálogo; campos **Título do destaque** e **Descrição**; exemplos de microcopy para título/descrição; botão **Salvar**. Nenhum campo foi preenchido ou salvo.
- **Banners:** rótulo **Selecione o banner**, campo de arquivo com aceitação `image/*`, indicação de tamanho ideal e limite de arquivo, botão **Enviar Banner**, contagem de banners e estado **Você ainda não adicionou banners**. Não houve seleção de arquivo, upload ou envio.

## Papelaria On — personalização

Em **Personalizar catálogo** (`catalogo_personalizar.php`), a página orienta escolher um estilo pronto ou ajustar detalhes, com prévia que muda antes de salvar. Os templates rotulados são **Tema Padrão**, **Loja premium com filtros**, **Ateliê gráfico**, **E-commerce profissional**, **Megaloja** (marcado como novo) e **Boutique de marca** (marcado como novo).

As áreas de edição observadas são **Banners** (desktop, mobile e medidas ideais), **Categorias** (ordem do menu superior), **Mensagem dos produtos** (personalizar ou remover a frase dos cards), **Modelo de loja** (cores, botões e vitrine de templates premium) e **Ateliê gráfico** (topo, menu, banner lateral e diferenciais). Os controles **Ver catálogo**, **Salvar e ver catálogo** e **Salvar personalização** estão presentes. Nenhum template foi escolhido, nenhuma opção foi alterada e nenhum botão de salvar ou abrir foi acionado.

## Layout, regras e limites observados

A Papelaria On usa barra lateral escura com grupos expansíveis e uma área clara de trabalho. As telas do catálogo usam cartões claros, abas para separar operações e, na personalização, editor à esquerda com prévia visual à direita. Os textos distinguem prévia imediata de persistência: a prévia muda antes de salvar, enquanto os botões de salvar são ações explícitas.

Não foram inspecionados os conteúdos internos de Cupons, Promoção, Frete ou Domínio próprio. Não foram executados copiar, compartilhar, abrir catálogo, edição de link, solicitação de domínio, seleção de template, salvar, resetar, upload ou envio de banner. Não se deve afirmar que URL pública, domínio, compartilhamento, upload, métricas ou integrações estejam funcionando apenas pela presença dos controles.

## Sources

[1]: https://www.atelierflow.com.br/pedidos "AtelierFlow — Pedidos e navegação do catálogo"
[2]: https://papelariaon.com/dashboard/index.php "Papelaria On — Dashboard e menu Catálogo"
[3]: https://papelariaon.com/dashboard/catalogo.php "Papelaria On — Configurações do Catálogo"
[4]: https://papelariaon.com/dashboard/catalogo_personalizar.php "Papelaria On — Personalizar catálogo"
