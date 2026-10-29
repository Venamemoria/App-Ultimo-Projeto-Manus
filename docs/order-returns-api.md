# Devolução física de insumos de pedido cancelado

## Escopo

A migration `supabase/migrations/20261030002200_order_returns.sql` implementa **somente** a devolução física administrativa de insumos já consumidos por um pedido que esteja em `Cancelado`. É uma compensação de estoque vinculada ao pedido e ao consumo original; não é reembolso financeiro, revisão comercial, ajuste avulso, cancelamento de pedido ou reativação de produção.

O cancelamento continua sendo feito por `vm_set_order_status`. Cancelar antes da baixa não cria execução de consumo e, portanto, não há material para devolver. Cancelar depois da baixa não devolve nada automaticamente. O operador precisa chamar explicitamente a RPC abaixo e informar a quantidade física efetivamente conferida.

A migration é incremental e não altera a migration aplicada de orders `20261030002000_orders.sql`. Valores históricos de abertura, recebimento, ajuste e `order_deduction` permanecem válidos; a constraint de movimentos é ampliada para preservar também `order_return`.

## RPC pública

O único nome público desta fatia é:

```text
public.vm_record_order_return(
  p_organization_id uuid,
  p_order_id uuid,
  p_reason text,
  p_returns jsonb,
  p_idempotency_key uuid
)
RETURNS TABLE(
  return_id uuid,
  order_id uuid,
  status text,
  line_count text,
  returned_quantity text,
  remaining_quantity text
)
```

Todos os parâmetros são obrigatórios. A identidade não é recebida do cliente: a função usa o `auth.uid()` real da sessão autenticada e grava esse UUID em evento, linha e movimento.

### Sessão e autorização

A sessão deve ter `auth.role() = 'authenticated'`, `auth.uid()` não nulo e membership na organização com papel `owner` ou `admin`. `production`, `finance`, `viewer`, `anon` e usuários de outro tenant não podem executar a mutação. A autorização é reavaliada inclusive no replay de uma chave antiga; um usuário somente leitura não pode reaplicar um comando originalmente privilegiado.

Não há `INSERT`, `UPDATE` ou `DELETE` concedido à API nas tabelas de eventos, linhas ou movimentos. A única mutação exposta é a RPC acima. Helpers em `vm_private` são `SECURITY DEFINER`, usam `SET search_path = ''` e não têm `EXECUTE` para `PUBLIC`, `anon` ou `authenticated`.

## Validação de `p_returns`

`p_returns` deve ser um array JSON não vazio, com no máximo 200 objetos. Cada objeto aceita **somente** estas chaves:

```json
{"material_id":"uuid","quantity":"0.50000000"}
```

`material_id` deve ser UUID válido e `quantity` pode ser string decimal ou JSON number. A função rejeita `NULL`, NaN, Infinity, -Infinity, zero, quantidade negativa, escala superior a oito casas, overflow e quantidade que não caiba em `numeric(20,8)`. A validação ocorre antes do cast tipado e não há `float`, arredondamento ou ajuste silencioso. A canonicalização conserva a intenção decimal com `trim_scale`; a aplicação deve enviar e ler quantidades como texto.

O array deve conter material único: não é permitido repetir o mesmo `material_id`, mesmo que as quantidades pudessem ser somadas. Cada material precisa ter uma linha imutável em `vm_order_consumptions` para **aquele mesmo** `(organization_id, order_id, material_id)`. Material apenas cadastrado, material de outro pedido, material de outro tenant ou material sem execução de consumo é rejeitado.

O pedido precisa estar exatamente em `status = 'Cancelado'`, com `consumed_at` preenchido e uma linha correspondente em `vm_order_consumption_runs`. Pedido `Pendente`, `Em Produção`, `Concluído` ou `Entregue` não é devolvível por esta RPC. Em particular, entrega não pode ser cancelada primeiro pela máquina de estados existente, então não existe devolução posterior sem uma transição explícita de cancelamento válida.

A quantidade solicitada é a quantidade física escolhida pelo operador. Para cada material:

```text
sum(devoluções históricas do pedido/material) + quantity_solicitada
  <= vm_order_consumptions.quantity
```

A função também valida que o saldo de estoque após a devolução continua finito, não negativo e representável em oito casas. Todas as linhas, materiais, unidades e limites são validados antes de qualquer aumento de estoque. A ordem de locks é organização, pedido e materiais em ordem crescente de UUID; o lock de organização serializa devolução, consumo e demais escritas de inventário no tenant.

## Efeitos atômicos

Uma chamada nova bem-sucedida grava na mesma transação:

1. um evento imutável em `public.vm_order_return_events`;
2. uma linha imutável em `public.vm_order_return_lines` por material;
3. um movimento positivo em `public.vm_stock_movements` por linha, com `movement_type = 'order_return'`, `order_id` do pedido e `return_line_id` da linha;
4. o aumento exato de `vm_materials.stock_quantity` pela quantidade física informada;
5. uma entrada durável em `vm_private.vm_order_requests` com `operation = 'order_return'`, payload canônico, resultado original e autoria real.

O movimento copia somente `package_cost` e `package_quantity` atuais como contexto de auditoria. A RPC não atualiza custo de compra, pacote, produto, versão, receita, `vm_order_consumptions`, `vm_order_consumption_runs`, `consumed_at`, status ou pagamentos. O `order_return` não tem `purchase_id` e não cria caixa, receita ou reembolso.

Se qualquer material da requisição for inválido, a transação inteira falha: nenhum saldo, evento, linha, movimento ou request de devolução fica gravado. FKs compostas por tenant ligam organização, pedido, material consumido, movimento de baixa, linha de retorno e movimento positivo. Constraints diferidas conferem no commit que cada evento tem linhas, que cada linha aponta para o movimento `order_return` correspondente e que o total devolvido não excede a baixa original.

## Idempotência

`p_idempotency_key` é UUID obrigatório e compartilha o namespace durável de `vm_private.vm_order_requests` com criação, status e pagamento. A combinação `(organization_id, idempotency_key)` é única.

O payload comparado é exatamente o objeto canônico:

```json
{
  "order_id": "UUID",
  "reason": "motivo trimado",
  "returns": [
    {"material_id":"UUID","quantity":"0.5"}
  ]
}
```

Repetir a mesma chave com a mesma operação e payload retorna o resultado histórico original (`return_id`, contagem e quantidades), sem consultar o saldo atual para recalculá-lo e sem criar evento, linha ou movimento extra. Portanto, uma alteração posterior de estoque não altera a resposta do replay. Reutilizar a chave para outra operação ou com qualquer payload diferente falha com `23505`; não há sucesso simulado nem linha de request criada para chamadas inválidas.

O resultado da chamada inicial e do replay contém:

- `line_count`: número de materiais no retorno daquela operação, como texto;
- `returned_quantity`: soma exata devolvida naquela operação, com oito casas no DTO;
- `remaining_quantity`: soma, para os materiais daquela operação, da baixa original menos todas as devoluções anteriores e a operação atual, com oito casas no DTO.

## Tabelas append-only

### `vm_order_return_events`

Cabeçalho auditável por operação: `id`, `organization_id`, `order_id`, `status` (`Cancelado`), `reason`, `idempotency_key`, `payload`, `line_count`, `returned_quantity`, `created_by` e `created_at`. Possui FKs de tenant para pedido e membership/autoria e unicidade por pedido/chave.

### `vm_order_return_lines`

Uma linha por `(return_event_id, material_id)`: `id`, organização, evento, pedido, `material_id`, `material_name_snapshot`, `unit`, `source_consumption_movement_id`, `quantity`, `stock_movement_id`, autoria e timestamp. A linha aponta por FKs compostas para o consumo original e para o movimento físico de retorno; a relação circular entre linha e movimento é diferida até o commit para permitir a gravação atômica dos dois IDs.

Eventos e linhas têm trigger append-only. UPDATE/DELETE, inclusive por um papel privilegiado de banco, falha com `55000`. A tabela de movimentos já era append-only e permanece assim.

## View de leitura

A view pública para a UI futura é:

```text
public.vm_order_returns_read
```

Ela usa `security_invoker = true`, RLS de tenant e SELECT autenticado. Cada linha representa um material devolvido e expõe:

```text
return_id uuid
organization_id uuid
order_id uuid
status text
reason text
idempotency_key uuid
return_line_count text
event_returned_quantity text
created_by uuid
created_at timestamptz
return_line_id uuid
material_id uuid
material_name text
unit text
original_consumed_quantity text
returned_quantity text
returned_quantity_total text
remaining_quantity text
stock_movement_id uuid
stock_after text
current_stock_quantity text
line_created_by uuid
line_created_at timestamptz
```

Todos os campos quantitativos são `text`; a view não converte para `float` e não arredonda. `original_consumed_quantity` é a quantidade real congelada na baixa; `returned_quantity_total` agrega as devoluções efetivamente gravadas daquele pedido/material; `remaining_quantity` é a diferença decimal exata; `stock_after` é o snapshot do movimento positivo e `current_stock_quantity` é o saldo atual. A view não esconde pedidos cancelados nem altera o histórico de consumo.

`public.vm_stock_movements_read` preserva todas as colunas existentes e acrescenta ao final `return_line_id uuid`. Movimentos antigos continuam com esse campo `NULL`; movimentos `order_return` têm o link da linha auditável.

As tabelas-base de evento e linha têm RLS com leitura para membro do tenant, mas nenhuma mutação de API. A view e as tabelas de leitura não têm grant para `anon`; o RPC tem `EXECUTE` somente para `authenticated`, com owner/admin verificados dentro da função.

## Erros principais

- `42501`: sessão ausente, papel insuficiente, tenant incorreto ou helper privado;
- `22023`: motivo, payload, UUID, array, estado ou quantidade inválidos;
- `22003`: escala, limite ou representação decimal inválida;
- `23503`: pedido/material/consumo da organização inexistente;
- `23505`: nonce compartilhado com operação/payload diferente;
- `23514`: cancelamento antes da baixa, consumo ausente, excesso, saldo ou ledger inconsistente;
- `55000`: tentativa de alterar/apagar ledger append-only.

Não há vínculo automático entre cancelamento e retorno, nem integração de pagamento. O fluxo deliberadamente representa a quantidade física realmente devolvida, não uma devolução total presumida e não um estorno financeiro.
