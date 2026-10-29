# UI de devolução física de insumos — evidência da fatia

Implementação atual em `src/features/orders/returns.tsx` e `src/features/orders/returns-api.ts`, integrada de forma limitada em `src/features/orders/detail.tsx`. Nenhuma rota nova foi criada. A migration `20261030002200_order_returns` e o banco não foram alterados por esta fatia; nenhum seed, mock, fixture ou registro físico foi criado.

## Comportamento implementado

- O bloco só aparece no detalhe quando o pedido está em `Cancelado`, tem `consumed_at` real e possui linhas reais de consumo.
- A leitura consulta exclusivamente `vm_order_returns_read`, paginando por `return_line_id` ascendente com `count: exact`. Falta de `count`, cursor inválido ou limite seguro interrompe a consulta sem apresentar lista parcial.
- A leitura é disponível a qualquer membro autorizado a ler o pedido. A ação de mutação e o botão do cabeçalho são exibidos somente para `owner` e `admin`.
- Cada material consumido é mostrado com unidade e quantidade original. O formulário começa vazio por linha: não presume devolução total. O motivo é obrigatório e cada quantidade informada é validada como decimal positivo com no máximo oito casas.
- O cliente bloqueia quantidades acima do restante calculado por material, mas o servidor continua sendo a autoridade final. O RPC recebe somente `{ material_id, quantity }` e a chave UUID `p_idempotency_key`.
- O histórico é agregado por material usando `Decimal`; quando não há linhas de retorno, o total devolvido é zero e o restante usa a quantidade real de `vm_order_consumptions`. Não existe métrica somando unidades diferentes nem cabeçalho com a soma técnica `returned_quantity` do evento.
- A UI exibe por material e por linha: unidade, quantidade da linha, total devolvido naquele material, restante, saldo após retorno e saldo atual, com oito casas decimais. Datas usam o helper local já existente.
- Um nonce é mantido para a mesma intenção dentro do par organização/pedido. Resposta perdida mantém motivo, quantidades e intenção para repetir sem mudar os dados; mudança de payload gera outro nonce. Colisão `23505` é apresentada como erro de tentativa, sem sucesso simulado.
- Depois de resposta RPC confirmada, a UI invalida detalhe do pedido, histórico de returns, materiais e movimentos de inventário. Não há atualização otimista, alteração de `status`, `consumed_at`, `vm_order_consumptions`, pagamentos ou valores financeiros.
- Erros de banco são convertidos para mensagens genéricas por código; a interface não expõe mensagem bruta do servidor.

## Validações de código

`pnpm typecheck` passou após a integração. `pnpm test` passou com 7 arquivos e 28 testes; `pnpm build` passou com Vite e TypeScript, gerando o chunk lazy do detalhe atualizado. A evidência desta documentação descreve somente o código da UI; não é uma declaração de paridade total do sistema nem de criação de dados físicos.
