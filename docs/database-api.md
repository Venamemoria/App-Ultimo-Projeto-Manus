# Vê na Memória — contrato inicial PostgreSQL/Supabase

A migration `supabase/migrations/20261029203500_foundation.sql` cria somente a fundação do ERP. Ela não foi aplicada por este trabalho e não cria organizações, usuários, tenants ou dados fictícios. A aplicação deve usar um projeto Supabase autorizado e uma sessão real do Supabase Auth.

## Escopo e regras comuns

Todas as entidades operacionais carregam `organization_id`. Os relacionamentos entre tenant e entidade usam chaves compostas, por exemplo `(organization_id, material_id)`, para impedir que um ID de outra organização seja associado. IDs são `uuid`; os defaults usam `gen_random_uuid()`.

Valores de dinheiro e quantidades são armazenados como `numeric(20,8)`. A API deve enviar números decimais como strings ou valores `numeric` sem usar `float` para regras de estoque. Entradas com mais de oito casas decimais são rejeitadas nas RPCs. `vm_materials.unit_cost` é uma coluna gerada por `package_cost / package_quantity`, armazenada com oito casas; nunca deve ser enviado pelo cliente.

A identidade da sessão vem de `auth.uid()`/JWT. Nenhuma RPC aceita `user_id` ou `created_by` do chamador para escolher o usuário efetivo. O `vm_create_organization` usa exclusivamente o usuário autenticado como criador e owner inicial.

## Organizações, memberships e papéis

`public.vm_organizations` contém `id`, `name`, `created_by`, `created_at` e `updated_at`. A criação ocorre apenas pela RPC `public.vm_create_organization`.

`public.vm_memberships` contém `id`, `organization_id`, `user_id` (FK para `auth.users`), `role` e `created_at`. Há uma membership por `(organization_id, user_id)`. Os únicos papéis são `owner`, `admin`, `production`, `finance` e `viewer`.

Todos os membros podem consultar os registros do tenant. Em termos de escrita nesta fundação:

- `owner` e `admin` podem cadastrar insumos, ajustar estoque e alterar produtos.
- `owner`, `admin` e `production` podem registrar recebimentos e alterar produtos.
- `owner`, `admin` e `finance` podem criar, editar e excluir clientes e fornecedores.
- `viewer` só consulta.

Não existe endpoint direto para convidar, trocar ou excluir memberships nesta fatia. O frontend não deve tentar inserir ou atualizar `vm_memberships`.

Os helpers de autorização ficam no schema não exposto `vm_private`: `vm_is_member(organization_id)`, `vm_has_role(organization_id, roles text[])`, `vm_membership_role(organization_id)` e `vm_jwt_membership_roles()`. Eles são `SECURITY DEFINER`, usam `search_path=''` e referências qualificadas; as policies não consultam `vm_memberships` diretamente, evitando recursão. O schema tem `USAGE` e os helpers têm `EXECUTE` apenas para `authenticated`.

## Cadastros consultáveis

`public.vm_clients` possui `id`, `organization_id`, `name`, `email`, `phone`, `notes`, `created_at` e `updated_at`. O cliente pode fazer `SELECT`; para escrita, use a tabela diretamente com a sessão Supabase e envie apenas `organization_id`, `name`, `email`, `phone` e `notes` no insert. `id` e timestamps são gerados pelo banco; `organization_id` não pode ser alterado.

`public.vm_suppliers` possui os mesmos campos de cadastro. A exclusão é permitida somente para `owner`, `admin` e `finance`; referências futuras e a referência de fornecedor em material usam `ON DELETE RESTRICT`.

As policies ainda são obrigatórias mesmo quando o frontend oculta ações. A tabela `public.vm_schema_migrations` registra `20261029203500_foundation`, mas não recebe grant para `anon` ou `authenticated`; é metadado interno da migration.

## Insumos e estoque

`public.vm_materials` possui:

- `id`, `organization_id`, `name`, `category` e `unit`;
- `package_cost` e `package_quantity`, com `package_quantity > 0`;
- `unit_cost`, gerado pelo banco;
- `stock_quantity >= 0` e `reorder_level >= 0`;
- `supplier_id` opcional, com FK composta para fornecedor do mesmo tenant;
- `creation_idempotency_key` opcional, `created_at` e `updated_at`.

`public.vm_stock_movements` é histórico append-only. Cada linha tem `movement_type` (`opening`, `receipt` ou `adjustment`), `quantity_delta`, `stock_after`, snapshot opcional de custo/quantidade da embalagem, `note`, `idempotency_key`, `created_by` e `created_at`. Updates e deletes são rejeitados por trigger, além de não haver grants de escrita. O cliente só pode consultar movimentos autorizados do próprio tenant.

Não há escrita direta em `vm_materials.stock_quantity`, `package_cost`, `package_quantity`, `vm_stock_movements` ou seus equivalentes sensíveis. O saldo muda somente nas RPCs abaixo, todas transacionais e com lock da organização/material.

## RPCs públicas para o Data API

As funções abaixo são `public.vm_*`, portanto podem ser chamadas pelo Supabase Data API. `EXECUTE` é revogado de `PUBLIC` e `anon` e concedido exatamente a `authenticated`. Todas validam `auth.uid()`, papel, tenant e parâmetros.

### `vm_create_organization(p_name text)`

Cria uma organização e, na mesma transação, a membership `owner` do usuário autenticado. Retorna uma linha:

```ts
{ organization_id: string, membership_id: string }
```

Não recebe usuário, owner ou membership externo. `p_name` é obrigatório, não vazio e limitado a 200 caracteres. Uma nova chamada cria uma nova organização; idempotência de criação de organização não faz parte deste estágio.

### `vm_create_material(...)`

Assinatura:

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
```

Permitida a `owner` e `admin`. `package_cost >= 0`, `package_quantity > 0`, `initial_stock >= 0` e `reorder_level >= 0`. O banco calcula `unit_cost = package_cost / package_quantity`. Quando `p_initial_stock > 0`, a função cria um movimento `opening` com o saldo inicial; saldo inicial não é despesa financeira.

A resposta é:

```ts
{
  material_id: string,
  opening_movement_id: string | null,
  unit_cost: string,
  stock_quantity: string
}
```

Se `p_idempotency_key` for enviado, ele é único por organização para criação do material. Uma repetição com a mesma chave retorna o mesmo material e o mesmo movimento `opening` (ou `null` se o saldo inicial original foi zero). O chamador deve reutilizar a chave somente para o mesmo payload lógico.

### `vm_receive_material(...)`

Assinatura:

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
```

Permitida a `owner`, `admin` e `production`. `p_idempotency_key` é obrigatório em execução: a função rejeita `null`. Quantidade e custo devem ser válidos, com quantidade de recebimento positiva, custo não negativo e quantidade da embalagem positiva.

A função bloqueia o material, soma `p_quantity` ao saldo, atualiza o último custo/quantidade de embalagem, gera `unit_cost` e grava um movimento `receipt`. Retorna:

```ts
{
  movement_id: string,
  material_id: string,
  stock_quantity: string,
  package_cost: string,
  package_quantity: string,
  unit_cost: string
}
```

A chave é única por `(organization_id, idempotency_key)`. Uma repetição com a mesma chave retorna o mesmo movimento e o estado atual do material sem somar o recebimento novamente. Reutilizar uma chave já usada por `opening` ou `adjustment` gera erro.

### `vm_adjust_material_stock(...)`

Assinatura:

```text
vm_adjust_material_stock(
  p_organization_id uuid,
  p_material_id uuid,
  p_delta numeric,
  p_reason text
)
```

Permitida somente a `owner` e `admin`. `p_delta` não pode ser zero e aceita valores positivos ou negativos com até oito casas. `p_reason` é obrigatório, não vazio e limitado a 2.000 caracteres. O resultado é:

```ts
{
  movement_id: string,
  material_id: string,
  stock_quantity: string
}
```

A operação aborta se o saldo resultante for negativo. O ajuste grava movimento `adjustment` append-only, com motivo e snapshot do pacote; não há alteração silenciosa do histórico.

### `vm_upsert_product(...)`

Assinatura:

```text
vm_upsert_product(
  p_organization_id uuid,
  p_name text,
  p_price numeric,
  p_category text = null,
  p_components jsonb = [],
  p_product_id uuid = null
)
```

Permitida a `owner`, `admin` e `production`. `p_price` é não negativo. `p_components` deve ser um array JSON de objetos com `material_id` UUID e `quantity` positiva, por exemplo:

```json
[
  {"material_id": "00000000-0000-0000-0000-000000000000", "quantity": "0.12500000"}
]
```

Os materiais precisam pertencer à mesma organização, sem material repetido. Sem `p_product_id`, cria o produto na versão 1. Com `p_product_id`, altera os dados do produto e cria a próxima versão. A composição antiga nunca é atualizada ou excluída.

A resposta é:

```ts
{
  product_id: string,
  version: number,
  price: string,
  component_count: number
}
```

`public.vm_products.current_version` aponta para a versão corrente. Para ler a composição corrente, consulte `vm_products` e filtre `vm_product_components` pelo mesmo tenant, `product_id` e `product_version = current_version`. Pedidos e snapshots históricos ainda pertencem a migrations futuras.

## RLS, grants e Realtime

Todas as tabelas da fundação têm RLS habilitado. Policies são destinadas a `authenticated`; não há policy nem grant para `anon`. O acesso só ocorre quando a membership do usuário está no mesmo `organization_id`. Grants e policies são usados juntos: revogar grant não é substituído por policy, e policy não concede privilégio de tabela.

O grant de leitura explícito cobre organizações, memberships, clientes, fornecedores, materiais, movimentos, produtos e componentes para `authenticated`, sempre filtrado por RLS. Clientes e fornecedores recebem apenas os grants de CRUD necessários. Não há grants diretos de insert/update/delete nas tabelas de saldo, movimentos, produtos, componentes, memberships ou organizações.

A migration usa um bloco `DO` que verifica se a publicação `supabase_realtime` existe e, se existir, adiciona sem duplicar as tabelas relevantes: organizações, memberships, clientes, fornecedores, materiais, movimentos, produtos e componentes. Se a publicação não existir, nenhum comando de infraestrutura é forçado. Realtime não abre acesso para `anon`; a leitura continua sujeita a grant e RLS.

## Referências de segurança

A separação entre grants e RLS, o uso de helpers `SECURITY DEFINER` fora de schemas expostos, `search_path=''` e grants seletivos seguem a documentação do Supabase e do PostgreSQL: [Supabase RLS][1] e [PostgreSQL `CREATE FUNCTION`][2].

[1]: https://supabase.com/docs/guides/database/postgres/row-level-security "Supabase — Row Level Security"
[2]: https://www.postgresql.org/docs/current/sql-createfunction.html "PostgreSQL — CREATE FUNCTION"
