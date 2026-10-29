# Pedidos — contrato PostgreSQL/Supabase

## Estado e escopo

Contrato da migration incremental `supabase/migrations/20261030002000_orders.sql`, sobre foundation, inventory, products e contacts. **Schema aplicado e registrado no Supabase autorizado em 29/10/2026 após 22 grupos PostgreSQL isolados aprovados, incluindo concorrência real com duas conexões.** RLS nas tabelas públicas/privadas foi confirmada. Nenhum pedido, pagamento, cliente ou seed demonstrativo criado no Supabase; fixtures apenas em `vm_test`. UI ainda em implementação; parser não substitui execução SQL efetiva. Evidência em `database-orders-tests.md`.

Os quatro nomes públicos para `supabase.rpc(...)` são **`vm_create_order`**, **`vm_set_order_status`**, **`vm_record_order_payment`** e **`vm_mark_notification_read`**. Não existem RPCs de update/delete de pedido ou item, de aceite público de orçamento, rastreio público, compensação física ou reembolso nesta migration.

## Sessão, organização e permissões

Todas as RPCs públicas exigem `auth.role() = 'authenticated'`, `auth.uid()` não nulo e membership autorizada na organização. A API não recebe identidade efetiva, owner ou `created_by`; a autoria vem exclusivamente da sessão real. O usuário real já existente e sua organização não são alterados.

| Operação | owner | admin | production | finance | viewer |
|---|:---:|:---:|:---:|:---:|:---:|
| Ler pedidos, itens, receitas, pagamentos e eventos do tenant | sim | sim | sim | sim | sim |
| Ler próprias notificações do tenant / marcar própria leitura | sim | sim | sim | sim | sim |
| Criar pedido Pendente | sim | sim | não | sim | não |
| Criar pedido já Em Produção / Concluído | sim | sim | não | não | não |
| Definir preço manual / override durante criação | sim | sim | não | sim | não |
| Etapas Em Produção / Concluído / Entregue | sim | sim | sim | não | não |
| Cancelar antes da baixa | sim | sim | não | sim | não |
| Cancelar após baixa | sim | sim | não | não | não |
| Registrar pagamento real | sim | sim | não | sim | não |
| Alterar diretamente saldo, status, snapshots, ledgers ou caixa | não | não | não | não | não |
| Ler/escrever diretamente outbox ou snapshot privado de cliente | não | não | não | não | não |

O responsável opcional é **ID de membership**, não ID de usuário: precisa pertencer à mesma organização e ter papel `owner`, `admin` ou `production`.

Todas as tabelas novas têm RLS habilitada. Nas tabelas operacionais, somente SELECT de membro é concedido a `authenticated`; não há policies/grants de DML. `vm_notifications` aplica adicionalmente `recipient_user_id = auth.uid()`: mesmo owner/admin não lê a caixa de outro membro. `vm_notification_outbox` e as tabelas de `vm_private` não têm policy/grant de API, inclusive para membros administrativos. `anon`/`PUBLIC` não recebem leitura nem execução pública. As views usam `security_invoker = true`, mantendo RLS das tabelas-base.

FKs compostas por organização vinculam cliente, responsável, produto/versionamento, variação/produto, item, insumo, pedido, evento, movimento e pagamento/caixa. As entidades novas com autoria também vinculam `(organization_id, created_by)` à membership do mesmo tenant, além da FK de Auth. Autoria nullable existe apenas para possibilitar futura criação confiável por aceite público sem impersonação; **as RPCs públicas atuais sempre gravam autor real não nulo**. Consumo e pagamento exigem autor não nulo.

## Decimais e fronteiras

A aplicação deve enviar decimais como strings e conservar os textos retornados. Não converter preços, quantidades ou montantes para `float` nas regras de negócio.

| Campo / cálculo | Escala e limite |
|---|---|
| Quantidade, fator de dimensões, quantidade cobrável, fração de receita, consumo por item/insumo | Exatamente representável em até 8 casas; positivo; máximo `999999999999.99999999` |
| Preço operacional/catalogado e custo unitário de insumo congelado | Até 8 casas; não negativo; máximo `999999999999.99999999` |
| Desconto percentual | Até 8 casas; de 0 a 100 |
| Desconto fixo e frete informados no JSON | Até 2 casas; de 0 a `999999999999.99` |
| Valor bruto da linha, custo unitário da composição e custo consumido da linha | Até 16 casas exatas; máximo `999999999999999999999999.9999999999999999` |
| Linha cobrada, subtotal, desconto calculado, total, pagamento, pago e saldo | Até 2 casas; máximo `999999999999999999.99`; pagamento estritamente positivo |

`numeric(20,8)`, `numeric(40,16)` e `numeric(20,2)` são os tipos de armazenamento correspondentes. As RPCs validam **numeric sem typmod antes do armazenamento**. `NULL` obrigatório, NaN, Infinity, -Infinity, sinal inválido, precisão não representável e overflow são rejeitados. Zeros decimais insignificantes não mudam o valor e são aceitos; a canonicalização usa `trim_scale`, portanto `"1"`, `"1.00000000"` e o JSON numeric equivalente representam a mesma intenção.

A única política de arredondamento monetário é explícita:

1. `line_amount_raw = billed_quantity × unit_price`, preservado exatamente.
2. `line_amount = round(line_amount_raw, 2)`, PostgreSQL numeric: empate afasta de zero. Com preços não negativos, equivale a half-up.
3. `subtotal = sum(line_amount)`; não se arredonda o subtotal bruto agregado para substituir as linhas.
4. Desconto `fixed` já vem em duas casas; `percent` calcula `round(subtotal × discount_value × 0.01, 2)`.
5. `total_amount = subtotal - discount_amount + shipping_amount`.

O frete não integra a base de desconto. Desconto não pode exceder subtotal, nem produzir total negativo. Pedido gratuito é permitido, mas não aceita pagamento positivo porque não tem saldo. **Nenhuma quantidade ou consumo é arredondado para caber.** Até um pedido inicialmente Pendente rejeita demanda calculada ou agregada que não caiba na precisão do estoque.

## `public.vm_create_order`

Assinatura SQL completa, sem defaults:

```text
public.vm_create_order(
  p_organization_id uuid,
  p_data jsonb,
  p_items jsonb,
  p_idempotency_key uuid
)
RETURNS TABLE(
  order_id uuid,
  code text,
  status text,
  status_version text,
  event_id uuid,
  consumed_at timestamptz,
  subtotal text,
  discount_amount text,
  shipping_amount text,
  total_amount text,
  paid_amount text,
  balance_amount text
)
```

`p_idempotency_key` é obrigatório. A operação inteira é atômica: validação, snapshots, itens, eventual baixa inicial, status, evento, notificações, outbox e ledger. Não cria pagamentos. O retorno é uma linha PostgREST, normalmente array com um objeto, e contém o resultado original armazenado no ledger.

### `p_data`: objeto estrito

Não há chaves extras aceitas. Campos opcionais ausentes/null tornam-se NULL ou o default descrito. Textos são trimados; texto opcional vazio vira NULL.

| Chave | Tipo JSON | Obrigatório / default | Regra |
|---|---|---|---|
| `client_id` | string UUID | obrigatório | Cliente ativo (`archived_at IS NULL`) na mesma organização. |
| `title` | string | obrigatório | Não vazio, até 200 caracteres. |
| `order_date` | string ISO date | obrigatório | `YYYY-MM-DD`, calendário válido e data finita; retroativo permitido. |
| `production_date` | string ISO date ou null | null | Previsão do pedido; não anterior a `order_date`. |
| `delivery_date` | string ISO date ou null | null | Não anterior ao pedido nem à previsão de produção quando ambas existirem. |
| `responsible_membership_id` | string UUID ou null | null | Membership de produção da mesma organização, conforme papéis acima. |
| `public_notes` | string ou null | null | Até 5000 caracteres; separada de notas internas. Continua privada ao tenant nesta fatia. |
| `internal_notes` | string ou null | null | Até 10000 caracteres; nunca incluída em evento/notificação/outbox. |
| `initial_status` | string ou null | `Pendente` | Exatamente `Pendente`, `Em Produção` ou `Concluído`; financeiro só Pendente. |
| `discount_type` | string ou null | `none` | Exatamente `none`, `fixed` ou `percent`. |
| `discount_value` | string decimal / numeric / null | 0 | `none` exige zero; `fixed` moeda 2; `percent` até 8 casas de 0 a 100. |
| `shipping_amount` | string decimal / numeric / null | 0 | Frete não negativo, já em duas casas. |

Datas opcionais vazias são NULL. Não são aceitos `infinity`, datas sem formato ISO, datas inválidas ou normalizadas silenciosamente pelo parser. Datas de previsão não são timestamps efetivos da execução: `consumed_at` e eventos registram os instantes reais.

### `p_items`: array estrito, 1 a 200 itens

Limite adicional: serialização JSONB de `p_items` até 500000 bytes. Cada posição é significativa; ordenar itens de outro modo muda o payload idempotente. UUIDs inválidos, produtos/variações cruzados entre organizações ou variação inativa abortam tudo.

| Chave | Tipo JSON | Obrigatório / default | Regra |
|---|---|---|---|
| `kind` | string | obrigatório | `product` ou `manual_service`. |
| `product_id` | string UUID ou null | obrigatório para `product` | Produto existente com `current_version` correspondente a uma versão congelada na organização. Manual exige NULL/ausente. |
| `variant_id` | string UUID ou null | null | Variação ativa do produto e organização; deve corresponder ao snapshot da versão corrente. Obrigatória em `pricing_mode = variation`. |
| `title` | string ou null | obrigatório no manual | Identificação da peça/serviço, até 200; em produto, default nome congelado + nome da variação, se houver. Se esse default exceder 200, informar título menor. |
| `quantity` | string decimal / numeric | obrigatório | Positiva, precisão 8. |
| `unit_price` | string decimal / numeric / null | obrigatório no override/manual | Proibido sem `price_override = true`; não negativo, precisão 8. |
| `price_override` | boolean | false | JSON null/string não são booleano. Manual exige true. |
| `price_override_reason` | string ou null | obrigatório quando override | Não vazio, até 2000. Proibido sem flag. |
| `dimensions` | objeto ou null | null; obrigatório para produto m2 | Shape exato descrito abaixo. Manual não aceita dimensões. |
| `details` | string ou null | null | Até 5000. |
| `personalization` | objeto ou null | null | JSON opaco de respostas/detalhes, até 20000 bytes. Não é fonte de quantidade, preço ou estoque. |
| `production_date` | string ISO date ou null | null | Previsão por peça, não anterior ao pedido. |
| `delivery_date` | string ISO date ou null | null | Não anterior ao pedido nem à produção da própria peça quando presente. |

Somente essas chaves são aceitas. Fotos, adicionais hierárquicos por peça, pontos, divisão entre múltiplos responsáveis, comprovantes e upload não são implementados; um adicional pode ser outro item explicitamente identificado, sem fingir hierarquia inexistente.

`dimensions` contém **somente** `width_cm` e `height_cm`, ambos decimais positivos, precisão 8. Ambos são obrigatórios quando o objeto existe. O servidor devolve dimensões com valores textuais:

```json
{"width_cm":"...","height_cm":"..."}
```

### Resolução de preço e unidade

O pedido não aceita que o cliente da API injete preço sob aparência de catálogo. Sem override, o preço é escolhido no servidor:

- Produto base: `min(preço promocional se existente, senão preço normal; preço do tier com maior minimum_quantity atingida, se houver)`.
- Variação: preço promocional da variação se existente, senão preço normal da variação; MOQ da variação quando informado, senão MOQ do produto. **Tiers do produto base não se aplicam implicitamente à variação.**
- MOQ e seleção de tier usam **quantidade cobrável** do item; múltiplas linhas não são somadas para atingir um tier.
- Override congela o preço explícito, flag, motivo e preço catalogado que teria sido aplicado. Não ignora MOQ nem muda receita/unidade.
- Serviço manual é identificado por título, cobrado por unidade e exige override explícito com motivo. Receita vazia; não inventa consumo.

As versões atuais do catálogo não têm flag global `active` no produto. “Produto vigente” significa linha existente da organização e sua `current_version` válida; visibilidade de catálogo não é autorização operacional. Variações têm `active`, que é exigido. A seleção não aceita um `product_version` arbitrário do chamador.

### Fator de dimensões e consumo exato

Em `billing_unit = unit`: `dimensions_factor = 1`, `billed_quantity = quantity`. Dimensões opcionais são somente informação da peça e **não** multiplicam preço/receita.

Em `billing_unit = m2`: dimensões são por peça; `dimensions_factor = width_cm × height_cm × 0.0001`, em m², e `billed_quantity = quantity × dimensions_factor`. A multiplicação por `0.0001` preserva a aritmética decimal exata sem divisão de escala implícita. Fator e quantidade cobrável precisam ser exatamente representáveis em 8 casas.

**A receita é definida por uma unidade de cobrança**: unidade produzida em produtos `unit` e um m² em produtos `m2`. Não há conversão de unidade do insumo. Para cada fração congelada:

```text
consumption_quantity = quantity_snapshot × billed_quantity
consumption_cost = consumption_quantity × unit_cost_snapshot
```

`quantity_snapshot` vem da versão do produto. Receita `base` usa componentes da `product_version`; `inherit_base` usa essa mesma receita base; `own` usa componentes da `variant_version` congelada. Custo é o `unit_cost_snapshot` armazenado no Produto, **não** `vm_materials.unit_cost` corrente. Título, IDs/versionamentos, preço normal/promocional/tier, preço escolhido, MOQ, unidade, motivo de override, frações, unidades e custos ficam congelados no pedido.

Cada produto de fração × quantidade cobrável é validado antes do cast. Agregação soma `consumption_quantity` de todos os itens por insumo; também valida precisão 8, limite e unidade única. Não compensa erros de precisão entre linhas nem faz round para permitir produção.

### Snapshot privado de cliente e imutabilidade

`vm_private.vm_order_client_snapshots` guarda nome, pessoa, documento, nascimento, email, telefone, endereço e captura original, vinculado por FKs ao pedido/cliente da organização. Não guarda notas do cadastro. Não é exposto por view/RPC e não recebe SELECT de API. `vm_orders.client_name_snapshot` conserva o nome histórico; a lista também mostra o nome real atual via join de cliente.

Pedidos, itens e snapshots **não têm edição nesta fatia**, mesmo antes da produção. O único update de pedido permitido pelo guard altera status/versionamento/marca durável de consumo, respaldados por evento/ledger; não muda conteúdo comercial. Itens e frações só são inseridos enquanto a criação está incompleta na própria transação e são append-only depois. Revisão comercial exige migration/fluxo explícito futuro.

## `public.vm_set_order_status`

```text
public.vm_set_order_status(
  p_organization_id uuid,
  p_order_id uuid,
  p_status text,
  p_reason text,
  p_idempotency_key uuid
)
RETURNS TABLE(
  order_id uuid,
  status text,
  status_version text,
  event_id uuid,
  consumed_at timestamptz,
  changed boolean
)
```

Todos os parâmetros são declarados sem defaults; `p_reason` pode ser enviado como NULL, exceto no cancelamento. Motivo é trimado, vazio vira NULL e limite 2000. A chave é obrigatória.

| Estado atual | Próximos estados diferentes permitidos |
|---|---|
| Pendente | Em Produção, Concluído, Cancelado |
| Em Produção | Concluído, Cancelado |
| Concluído | Entregue, Cancelado |
| Entregue | Nenhum |
| Cancelado | Nenhum |

Solicitar o próprio estado é no-op autorizado: `changed=false`, `event_id=NULL`, sem evento/outbox/baixa novos; uma chave nova registra esse resultado no ledger. `Pendente` só pode ser solicitado como no-op operacional por owner/admin/production, não para retroceder etapas. Finance não fabrica nem entrega.

Rótulos de referência são mapeados por semântica: Novo → Pendente; Em Processo → Em Produção; Pedido Pronto/Aguardando Retirada → Concluído; Entregue e Cancelado permanecem. “Pedido do Catálogo” e “Orçamento” não são etapas operacionais aqui. **Concluído não significa pago.**

### Baixa única e concorrência

A ordem de locks segue a convenção das migrations anteriores: organização `FOR UPDATE`, pedido `FOR UPDATE`, insumos `FOR UPDATE` em ordem crescente de UUID. A serialização por organização é deliberadamente conservadora; não se promete paralelismo de escrita dentro de um mesmo tenant.

Ao entrar em Em Produção ou diretamente Concluído, inclusive criação já nesses estados:

1. Ler somente a demanda congelada; agregar todos os itens por insumo.
2. Validar escala/limite/unidade e bloquear **todos** os insumos em ordem determinística, verificando todos os saldos antes de qualquer update de estoque.
3. Falta de qualquer insumo, unidade atual divergente do snapshot ou qualquer outro erro aborta a transação completa: pedido/criação, baixa, status, evento, notificações, outbox e ledger não ficam parciais.
4. Criar `vm_order_consumption_runs`, uma linha durável única `(organization_id, order_id)`, mesmo se a receita é vazia; isso registra que aquela execução já passou pelo consumo.
5. Atualizar saldos e registrar um movimento `order_deduction` negativo por insumo e uma linha de `vm_order_consumptions` com unicidade `(organization_id, order_id, material_id)`.
6. Gravar evento, status, marca `consumed_at`, notificações e outbox na mesma transação.

Uma restrição única adicional em movimentos impede segunda baixa por pedido/insumo. FKs ligam consumo ao movimento do mesmo pedido/insumo. Trigger diferido verifica até COMMIT a integridade completa da execução e os valores exatos contra a demanda congelada. Após produção → concluído, a marca/execução durável é reutilizada, sem segundo consumo. Retry de chave retorna o resultado original; retry com outra chave no mesmo estado é no-op.

Cancelamento antes da baixa não gera movimento. Após baixa, materiais permanecem consumidos e `consumed_at` não é apagado. Nenhuma devolução física, ajuste genérico, reembolso ou eliminação de histórico é disparada automaticamente.

**Pendente nesta fatia:** RPC administrativa específica de devolução física, com motivo obrigatório, movimento compensatório auditado e unicidade por execução. Não usar `vm_adjust_material_stock_safe` como se fosse compensação vinculada ao pedido: é outro contrato de ajuste e não implementa unicidade/auditoria de devolução de produção. Reembolso financeiro também é fluxo separado e não está implementado.

## `public.vm_record_order_payment`

```text
public.vm_record_order_payment(
  p_organization_id uuid,
  p_order_id uuid,
  p_amount numeric,
  p_payment_date date,
  p_method text,
  p_idempotency_key uuid
)
RETURNS TABLE(
  payment_id uuid,
  cash_entry_id uuid,
  order_id uuid,
  amount text,
  payment_date date,
  method text,
  total_amount text,
  paid_amount text,
  balance_amount text
)
```

Sem defaults. Permitida a owner/admin/finance. `p_amount > 0`, finito e já em moeda de duas casas; `p_payment_date` deve ser data finita, não futura; `p_method` é exatamente `pix`, `cash`, `card`, `bank_transfer` ou `other`. A data pode ser retroativa, inclusive depósito anterior à data do pedido. Chave obrigatória, copiada para `vm_order_payments.nonce`.

Bloqueia organização e pedido, soma somente pagamentos reais existentes e rejeita valor que exceda `total_amount - sum(payments.amount)`. Não admite pagamento novo em pedido Cancelado. Pagamentos anteriores continuam íntegros após cancelamento; não são apagados nem reembolsados automaticamente.

Na **mesma transação**, cria:

- `vm_order_payments` com valor, data, método, BRL, nonce e autoria/stamp imutáveis;
- `vm_cash_entries` com `entry_type='income'`, `payment_status='paid'`, mesmo valor, `entry_date=paid_at=payment_date`, pedido, pagamento e método; fornecedor/compra são NULL;
- ledger privado do resultado.

Valor, data, método, autoria e `created_at` são copiados exatamente do pagamento para o caixa e validados por trigger. FK composta `(organization_id, order_id, order_payment_id)` e índice único garantem um lançamento por pagamento no tenant correto. Trigger diferido exige receita vinculada até COMMIT e pagamentos agregados não maiores que o total. Pagamento e caixa são append-only; não existem RPCs de mutação/reembolso.

`paid_amount` é soma de pagamentos reais; `balance_amount` é total menos essa soma. Não há pagamento fictício, quitação ao concluir produção, receita pending criada para simular recebido, chamada de adquirente nem afirmação de liquidação externa. Este RPC é o registro financeiro autorizado de recebimento real declarado pelo operador.

## Idempotência estrita das três operações comerciais

`vm_private.vm_order_requests` é RLS-enabled, append-only e fechado à API. A chave primária é `(organization_id, idempotency_key)` e é **compartilhada entre create/status/payment desta migration**. Uma chave dessas operações não pode ser reutilizada por outra operação de pedidos. Isso não amplia o namespace dos ledgers de inventário/contatos/catalogue, que têm contratos próprios.

O ledger guarda operação, pedido, payload canônico, resultado textual original e autor. Mesmo tenant/chave/operação/payload retorna os mesmos IDs e resultado original, sem nova criação/transição/baixa/receita. Qualquer alteração do payload ou tipo de operação falha com `23505`. A permissão atual é validada também em replay; um viewer não executa um comando antigo privilegiado.

A canonicalização da criação independe do catálogo/cliente atuais. Um replay legítimo após alteração de catálogo, pagamento posterior ou arquivamento do cliente retorna a operação original, não tenta refazer snapshots nem comparar com estado vivo. A intenção canônica inclui todos os defaults, texto trimado, datas ISO, decimais sem zeros insignificantes e os itens em ordem. Objetos JSONB não dependem da ordem das chaves; personalização permanece JSONB opaco.

**Os retornos dos RPCs são resultados históricos da operação**, não a tela atualizada para sempre. Por exemplo, replay da criação continua com `paid_amount='0.00'`, embora haja pagamentos posteriores. Para estado/status/saldo atuais, consultar as views. A UI deve conservar a chave enquanto repete a mesma intenção e gerar outra para uma operação diferente.

## `public.vm_mark_notification_read`

```text
public.vm_mark_notification_read(
  p_organization_id uuid,
  p_notification_id uuid
)
RETURNS TABLE(
  notification_id uuid,
  read_at timestamptz
)
```

Sem defaults. Membership real e destinatário igual ao usuário autenticado. Bloqueia a própria notificação e preenche apenas a primeira marca de leitura; nova chamada retorna a mesma marca, sem alterá-la. Notificação de outro usuário/tenant é erro `42501`. Não usa chave de idempotência comercial porque a leitura é monotônica por registro. Conteúdo, destinatário e evento não são editáveis.

## Eventos, notificações e outbox

`vm_order_events` é histórico interno append-only, membro-read, com colunas exatas:

```text
id uuid; organization_id uuid; order_id uuid; status_version bigint;
event_type text ('created'|'status_changed'); previous_status text|null;
status text; reason text|null; payload jsonb;
created_by uuid|null; created_at timestamptz
```

Há unicidade `(organization_id, order_id, status_version)`. A criação gera versão 1 e `previous_status=NULL`, inclusive se inicialmente Pendente. Transições reais incrementam a versão uma vez. Motivo de cancelamento é histórico interno, não entra no payload distribuído.

O `payload` é exatamente a projeção de estado da transação:

```text
order_id: UUID string
code: string
status: string
status_version: string decimal inteira
order_date: date ISO
production_date: date ISO|null
delivery_date: date ISO|null
inventory_deducted: boolean
```

Sem documento/endereço/contato, preço, margem/custo, nota interna, personalização ou motivo. Essa projeção continua **interna**, não uma autorização pública por conter menos dados.

`vm_notifications` contém `id`, `organization_id`, `event_id`, `recipient_user_id`, `title`, `payload`, `read_at`, `created_at`. Um registro por evento/destinatário, para cada membership existente na organização ao ocorrer o evento. O título é `Pedido <code> — <status>`. Conteúdo é imutável; somente a primeira leitura muda pela RPC. FK de membership com RESTRICT preserva a referência histórica; exclusão física de membership com histórico exige desenho futuro próprio.

`vm_notification_outbox` contém exatamente:

```text
id uuid; organization_id uuid; event_id uuid;
channel text = 'order_status'; payload jsonb;
state text = 'pending' ('pending'|'processing'|'delivered'|'failed');
attempts integer = 0; next_attempt_at timestamptz;
locked_at timestamptz|null; locked_by text|null;
last_error text|null (até 2000); delivered_at timestamptz|null;
created_at timestamptz; updated_at timestamptz
```

Idempotência estrutural: `UNIQUE (organization_id, event_id, channel)`; o UUID da outbox é identificador estável disponível para futuros adaptadores. Estado processing exige lock/stamp; fora dele ambos devem ser NULL. Estado delivered exige `delivered_at`; demais estados não o admitem. Tentativas não podem diminuir, identidade/payload não mudam e uma entrega confirmada é terminal no guard. Há índice de pending/failed por `next_attempt_at`. Um futuro worker deve reclamar/retentar com locks server-side, sanitizar erros sem segredos e só marcar delivered com evidência real.

**Nesta migration não há worker, adaptador WhatsApp, envio, cron, webhook, Web Push, `realtime.send` ou resposta de sucesso simulada.** Todo evento novo entra como pending. Processamento e política de retries pertencem à fatia de integrações. Outbox não é pagamento nem tarefa externa executada.

Se existir publicação `supabase_realtime` não `puballtables`, são acrescentadas sem duplicar `vm_orders`, `vm_order_events`, `vm_notifications` e `vm_order_payments`. São Postgres Changes reais sujeitos a grants/RLS. Não se força criação de publicação nem se altera infraestrutura quando ausente. Outbox e snapshots/ledgers privados não são adicionados explicitamente. Se a publicação preexistente for `puballtables`, ela permanece intacta; a falta de grant/policy continua bloqueando leitura API dos privados. Não há acesso anônimo, canal público/token nem alegação de acompanhamento público pronto. Views não emitem Postgres Changes por si mesmas; consumidor autorizado deve refazer consulta ao receber mudança de tabela-base.

## Views de leitura — nomes/colunas exatos

Todos os decimais e contadores destas views são **text**; UUID é string no JSON, datas são ISO date e timestamps timestamptz. Nullable conforme indicado. As views não ocultam automaticamente Cancelado ou clientes arquivados.

### `public.vm_orders_read`

```text
id uuid
organization_id uuid
code text
client_id uuid
client_name text                 -- nome real atual via cliente do mesmo tenant
client_name_snapshot text        -- nome histórico capturado
title text
status text
status_version text
order_date date
production_date date|null
delivery_date date|null
responsible_membership_id uuid|null
public_notes text|null
internal_notes text|null
subtotal text
discount_type text
discount_value text
discount_amount text
shipping_amount text
total_amount text
paid_amount text
balance_amount text
currency text ('BRL')
inventory_deducted boolean
consumed_at timestamptz|null
item_count text
created_by uuid|null
created_at timestamptz
updated_at timestamptz
```

`paid_amount=sum(vm_order_payments.amount)`; ausência de pagamentos resulta no zero real da agregação. `balance_amount=total_amount-paid_amount`. Para saldos ativos a receber, filtrar `status <> 'Cancelado'` e saldo positivo com comparação decimal controlada; cancelamento não apaga a obrigação/histórico da view. `inventory_deducted` deriva da marca respaldada pela execução durável, inclusive execução sem insumos.

### `public.vm_order_items_read`

```text
id uuid
organization_id uuid
order_id uuid
position text
kind text ('product'|'manual_service')
product_id uuid|null
product_version text|null
variant_id uuid|null
variant_version text|null
title text
quantity text
billing_unit text ('unit'|'m2')
dimensions jsonb|null                -- width_cm/height_cm são strings
dimensions_factor text
billed_quantity text
unit_price text
price_source text ('catalog'|'override'|'manual')
price_override_reason text|null
line_amount_raw text
line_amount text
recipe_mode text ('base'|'inherit_base'|'own'|'none')
unit_composition_cost text
total_composition_cost text
product_snapshot jsonb
price_snapshot jsonb
recipe_snapshot jsonb
details text|null
personalization jsonb|null
production_date date|null
delivery_date date|null
created_at timestamptz
```

`product_snapshot` tem exatamente `product_id`, `product_version`, `name`, `category`, `sku`, `pricing_mode`, `billing_unit`, `production_days`, `variant_id`, `variant_version`, `variant_name`, `variant_sku`, `recipe_mode`, `snapshot_metadata`; valores numéricos/versionamentos/dias são text, IDs strings e opcionais NULL. Para manual é `{}`; identidade manual está no título/kind.

`price_snapshot` tem `normal_price`, `promo_price`, `minimum_quantity`, `applicable_tier`, `catalog_resolved_price`, `billing_unit`, `currency`, `rounding`, `selected_price`, `source`. Preços/quantidade são text ou NULL. `applicable_tier` é NULL ou `{minimum_quantity: string, unit_price: string}`; não é JSON numérico de preço. Manual tem preços catalogados NULL, MOQ textual zero e preço explícito escolhido. `rounding` é `round_line_half_away_from_zero_2dp`.

`recipe_snapshot` é array ordenado por `material_id`, vazio no manual/receita vazia. Cada elemento tem exatamente:

```ts
{
  material_id: string;
  material_name: string;
  quantitySnapshot: string; // fração por unidade de cobrança; camelCase intencional nesta projeção
  unit: string;
  unit_cost_snapshot: string;
  consumption_quantity: string;
  consumption_cost: string;
}
```

Na tabela normalizada `vm_order_item_materials`, o nome SQL dessa fração é **`quantity_snapshot`**, não `quantitySnapshot`. Demais colunas da tabela são `organization_id`, `order_id`, `item_id`, `material_id`, `material_name_snapshot`, `unit`, `unit_cost_snapshot`, `consumption_quantity`, `consumption_cost`. A leitura direta é membro-RLS, mas serializa numeric do PostgREST; preferir a projeção textual da view. Personalização é metadata opaca recebida, não uma promessa de que qualquer número arbitrário em respostas livres seja um preço/quantidade validado.

### `public.vm_order_consumptions_read`

```text
organization_id uuid
order_id uuid
material_id uuid
unit text
quantity text
movement_id uuid
stock_after text
created_at timestamptz
```

`quantity` é a quantidade positiva agregada realmente baixada; `stock_after` é snapshot do movimento, não saldo vivo. Execuções de receita vazia têm `vm_order_consumption_runs` mas zero linhas nesta view.

### `public.vm_order_payments_read`

```text
id uuid
organization_id uuid
order_id uuid
amount text
payment_date date
method text
currency text ('BRL')
nonce uuid
cash_entry_id uuid
created_by uuid
created_at timestamptz
```

O join exige o pagamento/caixa do mesmo pedido e tenant; a integridade diferida garante que o vínculo existe quando a transação é confirmada.

### Extensões compatíveis de views existentes

`vm_clients_read` conserva **todas** as colunas anteriores, ordem e tipos, e acrescenta no fim:

```text
order_count text
open_order_count text
```

São contagens de registros reais de `vm_orders` por organização/cliente. `order_count` inclui todos os estados; `open_order_count` conta exatamente Pendente, Em Produção e Concluído (pronto aguardando entrega). Entregue e Cancelado não são abertos. Cliente sem pedido tem contagem real `"0"`; cliente arquivado conserva suas contagens. Não é contador estático nem derivado de outro indicador. Este contrato substitui a ausência de contagem registrada na fatia anterior de Contacts.

`vm_stock_movements_read` conserva todas as 13 colunas anteriores e acrescenta `order_id uuid|null` ao fim. `movement_type` agora inclui `order_deduction`, negativo e com order_id obrigatório; opening/receipt/adjustment continuam com order_id NULL. Receipt de compra mantém purchase_id e seu contrato/FKs; movimentos antigos não são reescritos. A constraint anterior de delta/tipo foi ampliada antes de criar funções consumidoras; trigger append-only existente permanece.

`vm_cash_entries_read` conserva todas as 12 colunas anteriores e acrescenta, nessa ordem:

```text
order_id uuid|null
order_payment_id uuid|null
payment_method text|null
```

Compras/despesas antigas continuam com esses campos NULL e preservam os vínculos de compra/fornecedor. Receitas de pedido são paid reais, vinculadas a pagamento. Nenhuma coluna existente mudou de tipo/ordem e nenhuma compra/despesa/histórico foi atualizada.

## Helpers confiáveis e próxima migration pública

`vm_private.vm_order_build(uuid,jsonb,uuid)` é builder privado de intenção já canonicalizada e chama resolvedor/baixa/status privados. **Nenhum helper desta fatia tem EXECUTE para PUBLIC, anon ou authenticated.** Somente RPCs públicas confiáveis, após validar sessão/permissão, podem chamá-los com identidade do servidor. Os helpers usam `search_path=''` e referências qualificadas. `vm_order_apply_status` depende da disciplina de lock de organização do builder/RPC chamador; `vm_order_consume` reforça também organização/pedido.

Futuro aceite de orçamento poderá validar token/validade/revogação e intenção congelada no servidor e então chamar builder com ator NULL para pedido Pendente. Isso exige contrato próprio na próxima migration; não deve alterar JWT, fingir `auth.uid()` de cliente ou conceder EXECUTE de helper ao público. Aceite com etapa consumidora requer operação/autoria operacional autorizada, não fabricação sob usuário fictício.

## Erros e verificação restante

Erros principais são `42501` (sessão/papel/tenant/destinatário), `22023` (payload/data/status/regra inválidos), `22003` (decimal/escala/limite/computação não representável), `23503` (referência da organização inexistente/inativa), `23505` (idempotência/unicidade), `23514` (saldo/unidade/integridade/overpayment) e `55000` (mutação/revisão/transição sem suporte). UUID malformada pode retornar `22P02`. Não capturar esses erros para retornar sucesso: a RPC deve abortar e o cliente deve exibir o erro apropriado.

QA do agente principal deve compilar/aplicar em PostgreSQL isolado e cobrir papéis/tenant, overscale/especiais, datas/cliente/variação inválidos, fator m2, preços/tier/override, custos congelados após mudança de catálogo, múltiplos itens/materiais, precisão calculada e agregada, falta de um dos insumos com rollback total, retry/concorrência, criação consumidora, produção→concluído sem segunda baixa, cancelamento sem retorno, pagamento parcial/integral/overpayment/nonce, pagamento+income e stamps na mesma transação, RLS/own-read de notificações e bloqueio de helper/DML. Nenhum fixture foi criado nesta entrega; nenhum teste comportamental ou aplicação no banco real é declarado.

Migration contém BEGIN/COMMIT, registro `20261030002000_orders` em `vm_schema_migrations` com `ON CONFLICT DO NOTHING` e `NOTIFY pgrst, 'reload schema'`. A execução preserva históricos e acrescenta schema/views/constraints. UI, aceite de quote, rastreio público, compensação física, reembolso, worker/adaptadores e integrações externas permanecem fora deste escopo.
