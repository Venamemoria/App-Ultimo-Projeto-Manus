# Inventário, compras e custo — contrato PostgreSQL/Supabase

Migration deste contrato: `20261029221500_inventory.sql`, aplicada e verificada no Supabase autorizado em 29/10/2026 às 19:10 BRT após 16 grupos de testes isolados passarem. Ela é incremental sobre `20261029203500_foundation.sql` e não cria dados, fixtures, usuários ou organizações. A conexão com a UI é a etapa seguinte; não há publicação confirmada.

## Regras comuns

- Todas as operações públicas exigem sessão Supabase Auth com `auth.role() = 'authenticated'`; a identidade é sempre `auth.uid()`. Nenhuma assinatura recebe `user_id` ou `created_by` para escolher o autor.
- Todas as entidades abaixo carregam `organization_id`. O tenant é validado por `vm_private.vm_is_member`/`vm_private.vm_has_role`; FKs compostas impedem associar material, fornecedor, compra, movimento ou lançamento de outra organização.
- As RPCs de escrita usam `SECURITY DEFINER`, `search_path = pg_catalog,public`, bloqueio da organização e, quando há saldo envolvido, bloqueio do insumo. Não há DML de API direto em saldos, movimentos, compras ou lançamentos.
- `numeric(20,8)` é o armazenamento das quantidades e custos unitários. O limite é oito casas; os RPCs validam o `numeric` recebido **antes** do cast para a coluna, portanto `1.123456789` é rejeitado e não arredondado silenciosamente. Montantes de compra/caixa efetivamente cobrados podem ter duas casas e são `numeric(20,2)`.
- Todos os números rejeitam `NULL`, `NaN`, `Infinity`, `-Infinity`, sinal/regra de positividade inválidos, escala excedente e estouro do limite da coluna. Constraints também reforçam as colunas numéricas preexistentes de materiais, movimentos, produtos e componentes.
- Valores numéricos dos DTOs das views e das RPCs desta fatia são `text` quando precisam conservar precisão no JSON/JavaScript. Datas são `date` ou `timestamptz` conforme indicado; UUIDs são `string` no cliente.
- As tabelas históricas `vm_stock_movements`, `vm_material_purchases` e `vm_cash_entries` são append-only. Não há grants de `INSERT`, `UPDATE` ou `DELETE` para `authenticated`; triggers também rejeitam mutações mesmo em chamadas privilegiadas acidentais. Futuras baixas financeiras deverão ser uma RPC própria, não uma edição direta ou placeholder.

## Papéis

| Operação | `owner` | `admin` | `production` | `finance` | `viewer` |
|---|:---:|:---:|:---:|:---:|:---:|
| Consultar views/tabelas autorizadas do tenant | sim | sim | sim | sim | sim |
| Cadastrar insumo | sim | sim | não | não | não |
| Editar nome/categoria/fornecedor/limite | sim | sim | não | não | não |
| Receber insumo sem compra/despesa | sim | sim | sim | não | não |
| Ajustar saldo com chave e motivo | sim | sim | não | não | não |
| Criar compra, entrada e despesa vinculada | sim | sim | não | sim | não |
| Alterar/apagar histórico de estoque ou caixa | não | não | não | não | não |

As permissões são verificadas no banco, não apenas pela UI. `finance` registra compra pelo próprio RPC autorizado; não precisa e não pode falsificar `auth.uid()` ou o papel de outro usuário para chamar uma função de estoque.

## RPCs públicas

Os nomes abaixo são os identificadores exatos para `supabase.rpc`. Os tipos são os tipos reais de `RETURNS TABLE`, não uma aproximação TypeScript.

### `vm_create_material`

Assinatura mantida:

```text
vm_create_material(
  p_organization_id uuid,
  p_name text,
  p_unit text,
  p_package_cost numeric,
  p_package_quantity numeric,
  p_initial_stock numeric,
  p_reorder_level numeric,
  p_category text = null,
  p_supplier_id uuid = null,
  p_idempotency_key uuid = null
)
RETURNS TABLE(
  material_id uuid,
  opening_movement_id uuid,
  unit_cost numeric,
  stock_quantity numeric
)
```

Permitida a `owner`/`admin`. `p_package_cost >= 0`, `p_package_quantity > 0`, `p_initial_stock >= 0` e `p_reorder_level >= 0`, todos com até oito casas e sem especiais. O banco calcula `unit_cost = package_cost / package_quantity`; `unit_cost` não é parâmetro.

Quando `p_initial_stock > 0`, cria um movimento `opening`; quando é zero, `opening_movement_id` é `null`. Saldo inicial é migração de estoque e **não** cria `vm_cash_entries` nem despesa.

Com `p_idempotency_key`, o payload canônico é guardado no schema privado `vm_private`. Replay com a mesma chave e o mesmo payload retorna o mesmo material/movimento, sem comparar o saldo atual. Assim, recebimentos posteriores não fazem um replay legítimo falhar. A comparação usa nome/unidade normalizados com `btrim`, categoria vazia como `null`, valores decimais originais e fornecedor.

A mesma chave com qualquer payload diferente é erro `23505`. Uma chave que já pertence a movimento, compra ou material de outro tipo também é erro. Um material legado criado antes desta migration cuja chave não tenha payload privado não é tratado como sucesso idempotente: deve ser chamado com uma chave nova, pois o banco não inventa o saldo inicial original.

### `vm_update_material`

```text
vm_update_material(
  p_organization_id uuid,
  p_material_id uuid,
  p_name text,
  p_reorder_level numeric,
  p_category text = null,
  p_supplier_id uuid = null
)
RETURNS TABLE(
  material_id uuid,
  name text,
  category text,
  unit text,
  supplier_id uuid,
  reorder_level text,
  updated_at timestamptz
)
```

Permitida a `owner`/`admin`. Atualiza somente nome, categoria, fornecedor opcional do mesmo tenant e limite de reposição. Não recebe nem altera saldo, custo, quantidade da embalagem, unidade ou histórico. A unidade fica imutável nesta fatia para permanecer coerente com o histórico. `reorder_level` volta como `text`.

### `vm_receive_material`

Assinatura preservada:

```text
vm_receive_material(
  p_organization_id uuid,
  p_material_id uuid,
  p_quantity numeric,
  p_package_cost numeric,
  p_package_quantity numeric,
  p_note text = null,
  p_idempotency_key uuid = null
)
RETURNS TABLE(
  movement_id uuid,
  material_id uuid,
  stock_quantity numeric,
  package_cost numeric,
  package_quantity numeric,
  unit_cost numeric
)
```

Permitida a `owner`/`admin`/`production`; a chave é obrigatória na execução. Quantidade recebida e quantidade da embalagem são positivas; custo não é negativo; todos têm no máximo oito casas. Bloqueia o material, soma a entrada e faz o lote/embalagem vigente (`package_cost`, `package_quantity`) refletir o recebimento.

Este é o recebimento **sem compra e sem despesa**. Embora a assinatura preserve o default legado `p_note = null`, a execução exige `p_note` não nulo, não vazio e limitado a 2.000 caracteres; o valor é normalizado com `btrim`. A função não cria `vm_material_purchases` nem `vm_cash_entries`.

Replay com a mesma chave compara material, quantidade, custo, quantidade da embalagem e nota armazenados no movimento original; não compara o saldo atual. Retorna o estado atual do material sem somar novamente. Chave de `opening`, `adjustment`, compra ou payload diferente é erro `23505`. Uma entrada originada de compra também não pode ser reutilizada como recebimento avulso.

### `vm_adjust_material_stock_safe`

```text
vm_adjust_material_stock_safe(
  p_organization_id uuid,
  p_material_id uuid,
  p_delta numeric,
  p_reason text,
  p_idempotency_key uuid
)
RETURNS TABLE(
  movement_id uuid,
  material_id uuid,
  stock_quantity text
)
```

Permitida somente a `owner`/`admin`. A chave UUID é obrigatória; `p_delta` não pode ser zero e pode ser positivo ou negativo, com até oito casas; `p_reason` é obrigatório, não vazio e limitado a 2.000 caracteres. O resultado negativo aborta toda a transação. O movimento é `adjustment`, append-only, com snapshot do pacote vigente.

Replay exige exatamente a mesma chave, insumo, delta e motivo normalizado. Replay igual retorna o movimento sem aplicar o delta outra vez; chave de outro tipo/insumo/payload é erro. A antiga `vm_adjust_material_stock(uuid,uuid,numeric,text)` da fundação permanece apenas como símbolo histórico e tem `EXECUTE` revogado para `PUBLIC`, `anon` e `authenticated`; a UI deve usar somente o RPC seguro com chave.

### `vm_create_material_purchase`

```text
vm_create_material_purchase(
  p_organization_id uuid,
  p_material_id uuid,
  p_quantity_acquired numeric,
  p_total_amount numeric,
  p_purchase_date date,
  p_payment_status text,
  p_paid_at date,
  p_idempotency_key uuid,
  p_supplier_id uuid,
  p_document_reference text
)
RETURNS TABLE(
  purchase_id uuid,
  movement_id uuid,
  cash_entry_id uuid,
  material_id uuid,
  quantity_acquired text,
  total_amount text,
  unit_cost text,
  stock_quantity text,
  payment_status text,
  paid_at date
)
```

Permitida a `owner`/`admin`/`finance`. Os parâmetros opcionais de negócio são enviados como `null`: fornecedor pode ser `null` ou pertencer à mesma organização; documento/nota pode ser `null` e, quando presente, tem até 500 caracteres. A chave é obrigatória e protegida, dentro da organização, contra colisão com criação de material, recebimento, abertura ou ajuste.

Regras de entrada:

- `p_quantity_acquired > 0`, até oito casas;
- `p_total_amount >= 0`, até duas casas e dentro de `numeric(20,2)`;
- `p_purchase_date` é uma data finita;
- `p_payment_status` é exatamente `pending` ou `paid`;
- `paid` exige `p_paid_at` finito; `pending` exige `p_paid_at = null`;
- nenhuma data especial (`infinity`/`-infinity`) é aceita.

A função bloqueia organização e material e, em uma única transação, cria:

1. uma linha em `vm_material_purchases` com a quantidade e o **valor total real** da compra;
2. a entrada `receipt` em `vm_stock_movements`, com `purchase_id`, quantidade adquirida, `package_cost = total_amount` e `package_quantity = quantity_acquired`;
3. a atualização do saldo e do lote/embalagem vigentes do material;
4. uma despesa em `vm_cash_entries`, com `entry_type = 'expense'`, o mesmo montante, fornecedor, data e estado de pagamento.

`unit_cost` é calculado pelo banco como `total_amount / quantity_acquired` e volta como `text`. A compra é o único caminho desta fatia que cria despesa. `pending` nunca aparece como dinheiro pago: tanto compra quanto lançamento ficam `payment_status = 'pending'` e `paid_at = null`. Não há inferência de pagamento, chamada externa ou baixa financeira automática.

Replay com a mesma chave compara material, quantidade, total, data, fornecedor, documento canônico, estado e data de pagamento. Payload diferente é erro `23505`; replay igual devolve os mesmos IDs de compra, movimento e lançamento, sem nova entrada, despesa ou alteração de saldo. As constraints `UNIQUE (organization_id,purchase_id)` em movimentos e lançamentos, junto das FKs compostas, garantem um movimento e um lançamento por compra.

## Views de leitura e DTOs

As quatro views têm `WITH (security_invoker = true)`: as policies de RLS das tabelas-base continuam valendo. Há `SELECT` explícito para `authenticated`; `anon` não recebe grant nem policy. As colunas numéricas abaixo são `text` porque a view faz `numeric::text`.

### `vm_materials_read`

DTO:

```ts
{
  id: string;
  organization_id: string;
  name: string;
  category: string | null;
  unit: string;
  package_cost: string;
  package_quantity: string;
  unit_cost: string;
  stock_quantity: string;
  reorder_level: string;
  is_low_stock: boolean;
  supplier_id: string | null;
  created_at: string;
  updated_at: string;
}
```

`is_low_stock` é `stock_quantity <= reorder_level`. O saldo vazio é representado pelos valores reais do banco; não há carga demonstrativa.

### `vm_stock_movements_read`

DTO:

```ts
{
  id: string;
  organization_id: string;
  material_id: string;
  movement_type: 'opening' | 'receipt' | 'adjustment';
  quantity_delta: string;
  stock_after: string;
  package_cost: string | null;
  package_quantity: string | null;
  note: string | null;
  purchase_id: string | null;
  idempotency_key: string | null;
  created_by: string;
  created_at: string;
}
```

`opening` é saldo inicial sem despesa; `receipt` pode ser compra (`purchase_id` preenchido) ou recebimento avulso (`purchase_id = null`); `adjustment` é a correção autorizada e idempotente.

### `vm_material_purchases_read`

DTO:

```ts
{
  id: string;
  organization_id: string;
  material_id: string;
  material_name: string;
  quantity_acquired: string;
  total_amount: string;
  unit_cost: string;
  purchase_date: string; // date ISO
  supplier_id: string | null;
  supplier_name: string | null;
  document_reference: string | null;
  payment_status: 'pending' | 'paid';
  paid_at: string | null; // date ISO
  receipt_movement_id: string | null;
  cash_entry_id: string | null;
  created_by: string;
  created_at: string;
}
```

A view faz joins somente dentro do mesmo `organization_id`; os IDs de movimento/caixa são os vínculos realmente criados na mesma transação.

### `vm_cash_entries_read`

DTO:

```ts
{
  id: string;
  organization_id: string;
  entry_type: 'income' | 'expense';
  amount: string;
  entry_date: string; // date ISO
  description: string;
  payment_status: 'pending' | 'paid';
  paid_at: string | null; // date ISO
  material_purchase_id: string | null;
  supplier_id: string | null;
  created_by: string;
  created_at: string;
}
```

Nesta fatia só é criado `entry_type = 'expense'` para uma compra. A tabela é uma base incremental do futuro livro caixa; não é o módulo financeiro completo e não oferece edição, exclusão ou baixa placeholder.

As tabelas-base continuam com RLS de membro e `SELECT` autenticado para que `security_invoker` possa aplicar a policy; o contrato de leitura da aplicação deve preferir as views textuais para não depender da serialização numérica direta do PostgREST.

## Diferença operacional

| Conceito | Movimento | Altera saldo | Cria compra | Cria despesa |
|---|---|---:|---:|---:|
| Saldo inicial do cadastro | `opening` | sim | não | não |
| Recebimento sem compra | `receipt`, `purchase_id = null` | sim | não | não |
| Compra de insumo | `receipt`, `purchase_id` preenchido | sim | sim | sim |
| Ajuste auditável | `adjustment` | sim | não | não |

Não se deve representar saldo inicial como compra, nem recebimento operacional como dinheiro pago. O valor financeiro só nasce em `vm_create_material_purchase` e seu estado de pagamento é exatamente o declarado pelo chamador.

## Checks executados nesta entrega

- `pglast` v8.7 parseou a migration inteira: 58 statements e oito funções PL/pgSQL, sem erro de sintaxe; a revisão adicionou RLS ao payload privado.
- A preparação pelo agente não alterou o Supabase. Depois da revisão, o aplicador executou somente a migration no projeto autorizado e verificou o registro e RLS. Nenhum insumo, compra ou dado de negócio demonstrativo foi criado.
- A migration contém `BEGIN`/`COMMIT`, registra `20261029221500_inventory` em `vm_schema_migrations` com `ON CONFLICT DO NOTHING` e envia `NOTIFY pgrst, 'reload schema'`.
- As views consultadas sem sessão retornaram HTTP 401, sem dados expostos. Evidências adicionais estão em `inventory-verification.md`, `migrations-verification.json` e `database-tests.md`.
