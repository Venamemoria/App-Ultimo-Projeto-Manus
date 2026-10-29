# Pedidos, orçamento e produção — referências

Inspeção somente leitura em 29/10/2026 de `https://papelariaon.com/dashboard/novo_pedido.php` e `https://www.atelierflow.com.br/pedidos`, incluindo o formulário Novo Pedido aberto sem preenchimento/submissão. Nenhum pedido, pagamento, orçamento ou alteração de status foi criado nos sistemas de referência. Exemplos/contatos presentes no trial não foram copiados para o app ou documento.

Papelaria On inicia por dados básicos, adicionando produtos e pagamentos depois de salvar. Cliente pesquisável e cadastro rápido; data retroativa; status inicial Pendente, Em Produção, Pedido do Catálogo ou Orçamento; previsão de produção opcional que aparece no calendário; entrega opcional apenas para orçamento; descrição curta. As telas internas posteriores não foram abertas mediante criação de um registro fictício.

AtelierFlow usa abas Fluxo de Trabalho, Histórico de Vendas, Saldos a Receber e Relatórios. Busca cliente/telefone/serviço/código, mês/serviço, exportação e Novo Pedido. Etapas Novo, Em Processo, Pedido Pronto/Aguardando Retirada, Entregue e Cancelado. Lista cliente, serviços, faturamento/saldo, prazo, etapa, comprovante e mudança de estado. O mapeamento precisa preservar semântica entre rótulos diferentes.

No formulário AtelierFlow: cliente pesquisável/cadastro manual; itens consultam tabela de preços/catálogo ou serviço manual, quantidade, pontos, preço unitário, identificação da peça para via do cliente, detalhes e prazo individual. Cada peça aceita serviços adicionais de catálogo ou personalizados. Há fotos/referências, link externo de acompanhamento com título opcional, desconto fixo/percentual, total/pago/a receber, entrega, estado inicial, responsável e divisão da produção por peça. Finalizar pode gerar comprovante. Não se observou upload ou emissão real neste levantamento.

O comportamento do guia que marca quitação integral ao concluir não deve ser copiado como pagamento fictício: o ERP registra pagamentos financeiros reais separadamente do status operacional. Produção/entrega não significam dinheiro recebido por si só.

Regra explícita do usuário: ao entrar em Em Produção OU Concluído, baixar frações da receita uma única vez. Pedido criado já em etapa consumidora passa pela mesma transação; ir de produção para concluído não consome outra vez. Estoque insuficiente aborta integralmente. Cancelamento não devolve material utilizado sem comando compensatório administrativo auditável.

Orçamento público `/orcamento/:id` e rastreio `/rastreio/:id` usam tokens opacos/projeção mínima, sem dados privados de cliente/estoque. Aprovação atualiza Approved e cria/associa um único pedido, redirecionando; repetição devolve mesma associação. Pedido congela receita/preço/custos para proteger histórico. Status/Realtime refletem transação confirmada, não simulação local. Os campos financeiros/arte/equipe e paridade proprietária permanecem no TODO até implementação operacional.
