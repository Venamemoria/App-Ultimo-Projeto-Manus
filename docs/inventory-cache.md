# Atualização das consultas de estoque

Depois de criação ou mudança de status de pedido, devolução física, cadastro, ajuste, entrada ou compra de insumo, a aplicação invalida as consultas de saldos, movimentos e dados derivados da mesma organização. Também invalida em caso de erro de rede: uma RPC pode ter sido confirmada no servidor antes de a resposta se perder. A organização usada na invalidação é a enviada na operação, mesmo que a seleção da interface tenha mudado.

As telas de estoque e histórico consultadas ativamente são atualizadas ao voltar à aba e a cada 30 segundos. Eventos de pedido recebidos pelo canal de notificações também invalidam os dados; a reconexão consulta novamente. O evento não é tratado como saldo e não é uma garantia de entrega: o saldo sempre vem da consulta autorizada ao banco. Telas de produtos, fornecedores e devoluções com dados dependentes também são atualizadas quando ativas. Não há assinatura nova de tabelas com valores financeiros.

O histórico diferencia `order_deduction` de `order_return` e de ajustes manuais e mostra a referência do pedido quando presente. Os testes usam um `QueryClient` real para verificar invalidação e isolamento entre organizações. A entrega Realtime de ponta a ponta no ambiente publicado continua exigindo validação real.
