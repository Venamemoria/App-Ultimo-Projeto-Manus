# Configurações de marca, equipe e domínio

Status da inspeção: **partial**. As telas autorizadas foram abertas em sessão autenticada compartilhada. A inspeção ficou restrita a navegação, rótulos, opções visíveis, campos vazios e microcopy. Nenhum campo foi preenchido e nenhuma ação de cadastrar, contratar, salvar, comprar domínio, alterar configuração, exportar ou enviar formulário foi executada.

## AtelierFlow

Na rota de configurações, o agrupamento de conta apresenta `Meu Perfil`, `Minha Equipe` e `Assinatura`; o agrupamento de sistema apresenta `Preferências` e `Privacidade`; e há seções de `Layout do Comprovante`, `Padrão de Pedidos`, `Serviços Adicionais` e `Mensagens WhatsApp`.[1]

Em `Meu Perfil`, os rótulos observados foram `Foto de Perfil`, `Alterar Foto`, `Nome de Exibição`, `Atualizar Nome`, `Converter para Login com E-mail e Senha`, `Novo E-mail`, `Definir Senha de Acesso`, `Converter Conta`, `Senha Atual`, `Nova Senha`, `Confirmar Nova Senha` e `Alterar Senha`. A tela informa armazenamento de foto em nuvem segura e aceita JPG, PNG ou WebP. Esses controles são de identidade da conta; não foi observado um editor dedicado de marca ou domínio nesta tela.[1]

Em `Minha Equipe`, a tela é intitulada `Gestão de Equipe` e `Contas para Funcionários`. A microcopy descreve delegação de pedidos, tarefas, clientes e estoque com bloqueio de faturamento, custos e dados financeiros. Há `Capacidade de Assentos`, estado de nenhum assento contratado, opções de contratação de assento/pacote e `Membros da Equipe`. O estado vazio informa que é necessário contratar assento antes de cadastrar funcionário; a ação `Cadastrar Funcionário` aparece condicionada a essa contratação. As ações de contratação e qualquer alteração ficaram bloqueadas por serem pagas/confirmatórias.[2]

Não foi observado, nas telas autorizadas de configurações do AtelierFlow, um controle dedicado de domínio próprio nem um editor explícito de identidade visual da marca. Isso é apenas ausência de observação no escopo aberto, não uma afirmação sobre outras áreas não inspecionadas.

## PapelariaOn — marca e personalização

O menu do catálogo separa `Configurar catálogo`, `Personalizar`, `Cupons`, `Promoção`, `Frete` e `Domínio próprio`; o menu de configurações separa `Sistema`, `Integrações`, `Treinamentos`, `Funcionários` e `Indicações`.[3]

Na tela `Personalizar catálogo`, o fluxo informa: `Monte a vitrine do seu jeito` e permite escolher um `Template do catálogo`. As opções visíveis foram `Tema Padrão`, `Loja premium com filtros`, `Ateliê gráfico`, `E-commerce profissional`, `Megaloja` e `Boutique de marca`. A microcopy diz que a prévia muda na hora antes de salvar.[4]

As áreas de personalização visíveis foram:

- `Banners` — desktop, mobile e medidas ideais;
- `Categorias` — definição da ordem do menu superior;
- `Mensagem dos produtos` — personalizar ou remover a frase exibida nos cards;
- `Modelo de loja` — cores, botões e vitrine dos templates premium;
- `Ateliê gráfico` — topo, menu, banner lateral e diferenciais.

Também foram observadas as ações `Ver catálogo`, `Salvar e ver catálogo` e `Salvar personalização`. A prévia da vitrine e seus textos foram apenas visualizados; nenhuma seleção ou salvamento foi feito.[4]

## PapelariaOn — domínio

A tela `Domínio próprio` orienta a apontar o domínio para o catálogo e informa que a aprovação acontece automaticamente. O fluxo se chama `Solicitar domínio próprio` e pede o domínio exatamente como comprado.[5]

O campo vazio `Seu domínio` usa o placeholder genérico `minhapapelaria.com.br`. A regra exibida é: não usar `https://` nem caminhos; informar somente o domínio. Há ainda o campo vazio `Observações`, com microcopy opcional para informar domínio recém-comprado, pedir ajuda na configuração ou indicar uso de `www` também. A ação é `Salvar e acompanhar`.[5]

A tela contém a orientação para comprar o endereço no Registro.br e o link `Comprar domínio`. A seção `Solicitações salvas` mostra estado vazio e informa que a solicitação aparecerá ali após o envio. Nenhum domínio foi informado, salvo, comprado ou acompanhado.[5]

## PapelariaOn — equipe

A listagem `Funcionários` oferece busca por `Nome, e-mail ou ID`, ações `Buscar` e `Limpar`, e `Novo funcionário`. O estado observado foi `Funcionários cadastrados`, total zero, `Nenhum funcionário encontrado` e orientação para cadastrar um funcionário para delegar acesso ao painel.[6]

O formulário vazio `Novo funcionário` apresenta os rótulos `Nome`, `E-mail (login)` e `Senha`, além das ações `Voltar` e `Cadastrar`. A tela exibe uma observação técnica sobre o armazenamento da senha; ela foi registrada apenas como microcopy observada e não foi executada nenhuma operação de cadastro.[7]

Não foi aberta uma matriz de permissões ou um fluxo posterior de acesso. Portanto, a inspeção confirma os campos básicos e o estado vazio, mas não confirma regras de permissão além da delegação genérica indicada na listagem.

## Restrições e bloqueios

- Nenhum dado de referência foi copiado para este relatório: nomes de pessoas, e-mails, preços, valores financeiros, pedidos, tokens e outros dados identificáveis foram omitidos.
- Ações de contratar assentos, cadastrar funcionário, salvar personalização, solicitar domínio, comprar domínio e salvar qualquer configuração foram deliberadamente não executadas.
- A aprovação automática do domínio foi observada como microcopy da tela, mas não foi testada; integração DNS, compra, ativação e funcionamento do domínio permanecem não verificados.
- A inspeção não estabelece paridade implementada no projeto Vê na Memória. Ela apenas registra o que foi observado nas referências autorizadas.
- No AtelierFlow, marca/domínio dedicados não foram localizados nas telas de configurações abertas; outras áreas não foram pesquisadas por restrição de escopo.

## Referências

[1]: https://www.atelierflow.com.br/configuracoes "AtelierFlow — Configurações"
[2]: https://www.atelierflow.com.br/configuracoes "AtelierFlow — Configurações / Minha Equipe"
[3]: https://papelariaon.com/dashboard/index.php "PapelariaOn — Dashboard e navegação"
[4]: https://papelariaon.com/dashboard/catalogo_personalizar.php "PapelariaOn — Personalizar catálogo"
[5]: https://papelariaon.com/dashboard/catalogo_dominio_proprio.php "PapelariaOn — Domínio próprio"
[6]: https://papelariaon.com/dashboard/funcionarios.php "PapelariaOn — Funcionários"
[7]: https://papelariaon.com/dashboard/funcionario_novo.php "PapelariaOn — Novo funcionário"
