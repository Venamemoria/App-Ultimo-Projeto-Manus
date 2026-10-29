# Pedidos, orçamento e produção — referências

Inspeção somente leitura em 29/10/2026 de `https://papelariaon.com/dashboard/novo_pedido.php` e, anteriormente, `https://www.atelierflow.com.br/pedidos`. Nenhum pedido, pagamento ou orçamento foi criado nos sistemas de referência.

Papelaria On inicia por dados básicos, adicionando produtos e pagamentos depois de salvar. Cliente pesquisável e cadastro rápido; data do pedido com opção retroativa; status inicial Pendente, Em Produção, Pedido do Catálogo ou Orçamento; previsão de produção opcional que aparece no calendário; entrega opcional apenas para orçamento; descrição curta para identificação. A inspeção não avançou mediante criação de um registro fictício: telas internas de itens/arte/cobrança ainda precisam ser vistas quando disponíveis sem gravação.

AtelierFlow usa abas Fluxo de Trabalho, Histórico de Vendas, Saldos a Receber e Relatórios. Busca cliente/telefone/serviço/código, mês/serviço, exportação e Novo Pedido. As etapas observadas são Novo, Em Processo, Pedido Pronto/Aguardando Retirada, Entregue e Cancelado. A lista reúne cliente, serviços, faturamento/saldo, prazo e etapa, com comprovante e mudança de estado. O mapeamento do ERP precisa preservar semântica, não apenas copiar rótulos conflitantes.

Regra explícita do usuário prevalece: ao entrar em Em Produção OU Concluído, baixar exatamente frações da receita uma única vez. Pedido criado já em etapa consumidora deve passar pela mesma transação; repetir etapa/ir de produção para concluído não consome outra vez. Estoque insuficiente aborta a mudança. Cancelamento não devolve material fisicamente utilizado sem comando compensatório auditável.

Orçamento público `/orcamento/:id` e rastreio `/rastreio/:id` exigem tokens opacos, projeção mínima, sem exposição de dados privados de clientes ou estoque. Aprovação atualiza status Approved e cria/associa um único pedido, redirecionando ao acompanhamento; repetição devolve a mesma associação. Pedido congela receita, preços e custos relevantes para impedir que edição de catálogo altere o histórico. Status/Realtime devem refletir transação confirmada, nunca uma animação ou simulação local.
