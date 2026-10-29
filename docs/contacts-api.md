# Contacts API — contrato PostgreSQL/Supabase

## Escopo, fontes e estado

Este documento descreve o contrato definido por:

- `supabase/migrations/20261029235500_contacts.sql`;
- `tests/database/contacts.sql`;
- `docs/reference-contacts.md`.

A migration foi aplicada no Supabase autorizado em 29/10/2026 após 12 grupos SQL isolados aprovados. O relatório incremental confirmou RLS nas tabelas públicas/privadas e o registro transacional da versão. Nenhum contato/importação demonstrativo foi criado no Supabase. Isso não é publicação do frontend.

A UI de clientes/fornecedores permanece pendente de conexão a este contrato. A referência de UI foi observada somente em modo de leitura e não representa cadastro, importação, edição ou exclusão de dados reais. Os casos locais usam identidades, organizações e valores sintéticos; este documento não contém nem afirma PII de fixtures.

As funções `public.vm_*` são chamadas pelo Supabase Data API/PostgREST com `supabase.rpc(...)`. A aplicação deve usar uma sessão Supabase Auth real. A identidade efetiva vem de `auth.uid()` e o papel de sessão de `auth.role()`; não se envia `user_id` ou `created_by` para escolher o autor.

## Regras comuns de sessão, tenant e papéis

As três RPCs públicas desta migration exigem simultaneamente:

- `auth.role() = 'authenticated'`;
- `auth.uid()` não nulo;
- membership do usuário na `p_organization_id` com papel `owner`, `admin` ou `finance`.

A autorização é feita no banco por `vm_private.vm_has_role(...)`, não por ocultação de botão na UI. `production`, `viewer` e `anon` não podem executar as mutações de contacts. `authenticated` recebe `EXECUTE` somente nas três funções públicas; `PUBLIC` e `anon` não recebem esse privilégio.

Cada cadastro pertence a uma organização por `organization_id`. As verificações de leitura e mutação são sempre tenant-scoped. Um UUID de outra organização não pode ser usado para atualizar ou arquivar um cadastro. O contrato não permite trocar `id`, `organization_id` ou `created_at` numa atualização normal; o trigger de identidade rejeita essa tentativa.

A migration remove os grants de `INSERT`, `UPDATE` e `DELETE` diretos em `public.vm_clients` e `public.vm_suppliers` para `PUBLIC`, `anon` e `authenticated`. A escrita deve passar pelas RPCs abaixo. O `SELECT` direto das tabelas legadas continua concedido a `authenticated`, mas permanece sujeito à RLS; para a aplicação, prefira as views de leitura descritas adiante.

## RPCs públicas — assinaturas reais

As assinaturas abaixo preservam o nome, a ordem, o tipo SQL e os defaults declarados na migration. Os defaults de assinatura não significam que a execução aceite todos esses valores: a validação de runtime pode tornar um parâmetro efetivamente obrigatório.

### `public.vm_upsert_contact`

```text
public.vm_upsert_contact(
  p_organization_id uuid,
  p_entity text,
  p_data jsonb,
  p_contact_id uuid DEFAULT NULL,
  p_idempotency_key uuid DEFAULT NULL
)
RETURNS TABLE(
  contact_id uuid,
  entity text,
  created boolean,
  updated_at timestamptz
)
```

Parâmetros:

| Parâmetro | Tipo | Default SQL | Contrato |
|---|---|---:|---|
| `p_organization_id` | `uuid` | — | Organização alvo; deve existir e pertencer ao usuário autenticado. |
| `p_entity` | `text` | — | Exatamente `client` ou `supplier`. |
| `p_data` | `jsonb` | — | Objeto JSON com as chaves permitidas para a entidade. |
| `p_contact_id` | `uuid` | `NULL` | `NULL` cria; UUID não nulo atualiza o cadastro desse tenant. |
| `p_idempotency_key` | `uuid` | `NULL` | Obrigatória na execução; chave idempotente por organização e entidade. |

`p_contact_id` não é um modo de atualização parcial. O servidor canonicaliza o objeto inteiro e a atualização grava os valores canônicos de todos os campos da entidade; campos opcionais ausentes tornam-se `NULL`. Para preservar campos existentes, o chamador deve reenviar a intenção completa.

#### Chaves de `p_data`

As chaves desconhecidas são rejeitadas antes de qualquer linha ser criada ou atualizada. `name` é obrigatório para clientes e fornecedores.

| Entidade | Chaves aceitas |
|---|---|
| `client` | `name`, `email`, `phone`, `notes`, `person_type`, `tax_id`, `birth_date`, `address` |
| `supplier` | `name`, `email`, `phone`, `notes`, `person_type`, `tax_id`, `address`, `website` |

`name` deve ser string, recebe `btrim`, não pode ficar vazio e tem no máximo 200 caracteres. O banco grava o nome já trimado.

#### Campos opcionais e normalização

A função privada `vm_private.vm_contact_optional_text` trata campo ausente, JSON `null` e string vazia após trim como `NULL`, além de exigir string quando o campo foi informado. Os limites são:

| Campo | Limite | Normalização/validação |
|---|---:|---|
| `email` | 320 | trim; lower-case; formato `local@domínio.tld`; sem espaços. |
| `phone` | 100 | trim; sequências de whitespace viram um único espaço. |
| `notes` | 5000 | trim; texto opcional. |
| `person_type` | 20 | trim, lower-case; default `individual`; somente `individual` ou `business`. |
| `tax_id` | 14 | trim/maiúsculas; CPF 11 números ou CNPJ 12 letras/números + dois dígitos finais, sem máscara. |
| `birth_date` | 10 | Somente em `client`; string ISO `YYYY-MM-DD`, data válida, não futura e não infinita. |
| `website` | 2048 | Somente em `supplier`; trim e URL não vazia iniciada por `http://` ou `https://`, sem whitespace. |

`tax_id` é apenas validação de formato. Não há consulta cadastral, prova de titularidade ou cálculo oficial do dígito verificador. CNPJ numérico e alfanumérico coexistem; a UI remove somente máscara/espaços, não as letras. Fontes e regra vigente estão em `docs/contact-tax-format.md`. Passar no regex não significa que o documento exista ou seja matematicamente válido.

`birth_date` não é aceito para `supplier`. Em `client`, uma pessoa jurídica (`person_type = 'business'`) não pode informar `birth_date`; uma pessoa física pode. Datas futuras, inválidas ou especiais são rejeitadas com `SQLSTATE 22023`.

#### `address`

`address` é opcional e deve ser `NULL` ou um objeto contendo somente estas chaves:

```json
{
  "postal_code": "...",
  "street": "...",
  "number": "...",
  "district": "...",
  "complement": "...",
  "city": "...",
  "state": "SP"
}
```

Cada valor deve ser string ou JSON `null`. Strings não podem ficar vazias após trim. Os limites são `postal_code` 20, `street` 200, `number` 40, `district` 120, `complement` 120, `city` 120 e `state` exatamente 2 caracteres após trim. `state` é gravado em maiúsculas. O objeto é reconstruído pelo servidor com as sete chaves canônicas, inclusive valores nulos; uma forma inválida ou uma chave extra é rejeitada com `SQLSTATE 22023`.

#### Retorno e idempotência

A primeira chamada com `p_contact_id = NULL` cria uma linha e retorna `created = true`. Com `p_contact_id` existente na organização, atualiza essa linha e retorna `created = false`. `entity` repete `client` ou `supplier`; `updated_at` é o timestamp da linha retornado pelo banco.

A chave `p_idempotency_key` é obrigatória em runtime, embora o parâmetro tenha default SQL `NULL`. O ledger privado guarda o payload canônico formado por `entity`, `contact_id` e `data`:

- mesma organização, entidade, chave e payload canônico: retorna o mesmo `contact_id` sem criar uma segunda linha nem reaplicar a atualização;
- mesma chave com payload diferente: colisão com `SQLSTATE 23505`;
- chave registrada cujo cadastro desapareceu: erro de serialização/retry `SQLSTATE 40001`;
- organização inexistente: `SQLSTATE 23503`;
- usuário sem papel permitido ou tenant incorreto: `SQLSTATE 42501`.

A identidade de uma linha é imutável. A unicidade de `tax_id` é uma regra separada da idempotência.

### `public.vm_archive_contact`

```text
public.vm_archive_contact(
  p_organization_id uuid,
  p_entity text,
  p_contact_id uuid,
  p_archived boolean,
  p_reason text
)
RETURNS TABLE(
  contact_id uuid,
  entity text,
  archived boolean,
  archived_at timestamptz,
  event_id uuid
)
```

Todos os cinco parâmetros são obrigatórios; não há default declarado. `p_entity` deve ser `client` ou `supplier`, `p_contact_id` não pode ser nulo, `p_archived` não pode ser nulo e `p_reason`, após trim, deve ser não vazio e ter até 2.000 caracteres.

`p_archived = true` grava `archived_at = clock_timestamp()` e um evento `event_type = 'archived'`. `p_archived = false` desarquiva, grava `archived_at = NULL` e um evento `event_type = 'unarchived'`. O evento carrega `reason` e `created_by = auth.uid()`; o chamador não escolhe o autor.

Arquivar **não exclui fisicamente** o cliente ou fornecedor. A linha permanece legível pela view, com `archived_at` preenchido. Referências existentes, inclusive `vm_materials.supplier_id`, são preservadas. O histórico em `public.vm_contact_events` também continua legível para membros do mesmo tenant.

Repetir a mesma operação quando o cadastro já está no estado solicitado não cria outro evento: retorna `event_id = NULL` e o timestamp de arquivamento vigente. Alterar ou apagar diretamente um evento é rejeitado pelo trigger append-only. Não existe RPC pública de exclusão física de contact nesta migration; os grants diretos de delete estão revogados.

### `public.vm_import_contacts`

```text
public.vm_import_contacts(
  p_organization_id uuid,
  p_entity text,
  p_rows jsonb,
  p_key uuid
)
RETURNS TABLE(
  batch_key uuid,
  created text,
  updated text,
  skipped text
)
```

Parâmetros:

| Parâmetro | Tipo | Default SQL | Contrato |
|---|---|---:|---|
| `p_organization_id` | `uuid` | — | Organização alvo, validada pela membership. |
| `p_entity` | `text` | — | Exatamente `client` ou `supplier`. |
| `p_rows` | `jsonb` | — | Array de objetos com o mesmo contrato de `p_data` do upsert. |
| `p_key` | `uuid` | — | Chave do lote; obrigatória e única por organização. |

`p_rows` deve ser array com no máximo 500 itens. Cada linha é validada e canonicalizada primeiro, sem inserir contactos durante essa etapa. Uma linha inválida, chave desconhecida, data inválida, website não HTTP(S) ou qualquer outro erro de payload aborta o lote inteiro com `SQLSTATE 22023`; nenhuma linha parcialmente criada permanece.

Os contadores retornam como `text`, não como `integer`:

- `created`: linhas realmente criadas;
- `updated`: coluna preservada no retorno/ledger, mas a implementação desta importação chama o upsert interno sem `p_contact_id`, portanto não atualiza registros;
- `skipped`: duplicatas ou linhas que a política segura decidiu não sobrescrever.

#### Política de duplicatas e `tax_id`

A importação nunca usa um `tax_id` correspondente como licença para sobrescrever um cadastro existente. Para a mesma organização e entidade:

1. se o `tax_id` já existe no banco, a linha é contada como `skipped`;
2. se uma linha posterior do mesmo lote encontra o `tax_id` criado por uma linha anterior, também é `skipped`;
3. linhas exatamente iguais, após canonicalização, repetidas no mesmo array são `skipped`;
4. uma linha sem `tax_id` não é fundida por nome, e-mail ou telefone;
5. `tax_id` é comparado dentro da entidade: a unicidade de clientes e a de fornecedores são índices separados.

A contagem é armazenada no ledger privado e retornada como texto.

#### Idempotência de lote, retry e rollback

O ledger privado é `vm_private.vm_contact_import_requests`, com chave primária `(organization_id, batch_key)`. A primeira execução armazena a entidade, as linhas canonicalizadas e o usuário autenticado. Um retry com a mesma organização, `p_key`, entidade e payload canonicalizado retorna os contadores originais e não cria novas linhas.

Reutilizar `p_key` com entidade ou payload canonicalizado diferente é colisão `SQLSTATE 23505`; não é uma forma de corrigir ou editar um lote anterior. A validação completa ocorre antes da inserção do ledger e de qualquer contact. A criação do ledger, as inserções e a atualização dos contadores estão na mesma transação da RPC: se qualquer linha falhar, o lote e todas as linhas já processadas são revertidos. O limite de 500 itens também é validado antes da mutação.

O fixture foi corrigido para repetir exatamente o payload original no replay; a colisão com payload diferente permanece testada e rejeitada. A suite também confirmou revogação dos grants legados por coluna, bloqueio de viewer e permissão financeira real no tenant próprio.

## Unicidade e formato de identificação fiscal

A migration cria estes índices parciais:

```text
vm_clients_org_tax_id_uq
  UNIQUE (organization_id, tax_id) WHERE tax_id IS NOT NULL

vm_suppliers_org_tax_id_uq
  UNIQUE (organization_id, tax_id) WHERE tax_id IS NOT NULL
```

Assim, um cliente não pode compartilhar `tax_id` com outro cliente da mesma organização, e um fornecedor não pode compartilhar `tax_id` com outro fornecedor da mesma organização. O mesmo texto pode existir uma vez em cada entidade porque são índices separados. Registros com `tax_id = NULL` não participam da unicidade. Nome igual sem `tax_id` não causa merge automático.

A regra aceita CPF numérico e CNPJ numérico/alfanumérico vigente, normalizado em maiúsculas. Não há cálculo do dígito verificador, consulta à Receita ou prova de titularidade.

## Modelo, FKs e isolamento de organização

As tabelas legadas `public.vm_clients` e `public.vm_suppliers` continuam sendo as fontes de armazenamento do inventário. A migration adiciona:

- `person_type text NOT NULL DEFAULT 'individual'`;
- `tax_id text`;
- `address jsonb`;
- `archived_at timestamptz`;
- `birth_date date` somente em `vm_clients`;
- `website text` somente em `vm_suppliers`.

As duas tabelas têm `organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT`, além de suas chaves `(organization_id, id)` usadas pelas FKs compostas do domínio. A fundação mantém `vm_materials(organization_id, supplier_id)` referenciando `vm_suppliers(organization_id, id) ON DELETE RESTRICT`; por isso arquivar um fornecedor preserva a referência do material e não exige uma exclusão destrutiva.

`public.vm_contact_events` usa:

- `organization_id` com FK para `vm_organizations(id) ON DELETE RESTRICT`;
- `created_by` com FK para `auth.users(id) ON DELETE RESTRICT`;
- `entity` limitado a `client`/`supplier`;
- `contact_id` polimórfico sem FK direta, porque clientes e fornecedores estão em tabelas distintas e a RPC valida o par entidade/ID no tenant.

Os ledgers privados de upsert e importação também têm FK `organization_id` para `vm_organizations(id) ON DELETE RESTRICT`; seus `created_by`/dados de autoria são protegidos no schema privado. O ledger de upsert tem chave `(organization_id, entity, idempotency_key)`. O de importação tem chave `(organization_id, batch_key)`.

A organização é bloqueada (`FOR UPDATE`) durante as operações de upsert, archive e import, e as consultas de cadastro sempre incluem `organization_id`. Isso evita reutilizar por engano um ID de outro tenant e serializa operações concorrentes no escopo da organização.

## RLS, grants e objetos públicos

As views abaixo são `WITH (security_invoker = true)`: a policy da tabela de origem continua sendo aplicada. `authenticated` recebe `SELECT` nas views; `anon` não recebe grant nem policy. A view de eventos não existe; a leitura autorizada é feita diretamente em `vm_contact_events` por `authenticated`.

A policy de leitura de `vm_contact_events` exige membership na organização. A tabela é RLS-enabled e seus grants de `INSERT`, `UPDATE` e `DELETE` são revogados para os papéis de API. Os ledgers `vm_private.vm_contact_upsert_requests` e `vm_private.vm_contact_import_requests` também têm RLS habilitada e nenhum grant para `PUBLIC`, `anon` ou `authenticated`; somente as funções `SECURITY DEFINER` os acessam.

A migration mantém a leitura das tabelas legadas para `authenticated`, mas revoga todas as escritas diretas. A segurança é a combinação de grant e policy: uma policy não concede privilégio de tabela e um grant sozinho não ignora RLS.

Se a publicação `supabase_realtime` existir e não for `puballtables`, a migration tenta adicionar `public.vm_contact_events` sem duplicar a entrada. Isso não concede acesso a `anon` nem substitui grant/RLS.

## Views de leitura e DTOs

### `public.vm_clients_read`

A view expõe exatamente:

```ts
{
  id: string;                 // uuid
  organization_id: string;    // uuid
  name: string;
  email: string | null;
  phone: string | null;
  notes: string | null;
  person_type: 'individual' | 'business';
  tax_id: string | null;
  birth_date: string | null; // date ISO
  address: {
    postal_code: string | null;
    street: string | null;
    number: string | null;
    district: string | null;
    complement: string | null;
    city: string | null;
    state: string | null;
  } | null;
  archived_at: string | null; // timestamptz ISO
  created_at: string;          // timestamptz ISO
  updated_at: string;          // timestamptz ISO
}
```

Os nomes são os nomes SQL da view, não aliases de tela. A view não filtra arquivados; o consumidor deve observar `archived_at` e decidir o filtro de ativos.

### `public.vm_suppliers_read`

```ts
{
  id: string;                 // uuid
  organization_id: string;    // uuid
  name: string;
  email: string | null;
  phone: string | null;
  notes: string | null;
  person_type: 'individual' | 'business';
  tax_id: string | null;
  address: {
    postal_code: string | null;
    street: string | null;
    number: string | null;
    district: string | null;
    complement: string | null;
    city: string | null;
    state: string | null;
  } | null;
  website: string | null;
  archived_at: string | null; // timestamptz ISO
  created_at: string;          // timestamptz ISO
  updated_at: string;          // timestamptz ISO
  material_count: string;
  current_stock_cost: string;
  stocks_by_unit: string;
}
```

Os agregados de fornecedor são derivados de `public.vm_materials` no mesmo `organization_id` e `supplier_id`:

- `material_count` é `count(m.id)::text`; sem materiais, o `LEFT JOIN` produz `"0"`;
- `current_stock_cost` é a soma de `stock_quantity * unit_cost`, convertida para `numeric(20,8)::text`; sem materiais, é `"0"`;
- `stocks_by_unit` é um JSON serializado como `text`, com cada unidade como chave e a quantidade agregada naquela unidade como string; sem materiais, é `"{}"`.

Exemplo de shape após `JSON.parse(stocks_by_unit)` — não uma carga fixa:

```ts
Record<string, string> // { "g": "3.00000000", "cm": "2.00000000" }
```

Unidades diferentes permanecem separadas. A API não soma gramas, centímetros ou outras unidades como se fossem uma única medida. Os campos numéricos derivados são texto para preservar a serialização decimal; o cliente não deve convertê-los para `float` para depois reintroduzir arredondamento binário.

`vm_suppliers_read` não possui contagem de pedidos. `vm_clients_read` também não possui contagem de pedidos.

## Arquivamento, referências e histórico

Arquivamento é um estado reversível, não exclusão:

- a linha original de cliente/fornecedor continua existente;
- `archived_at` torna-se a marca do estado;
- materiais continuam referenciando o fornecedor por FK composta;
- eventos `archived`/`unarchived` permanecem em histórico append-only;
- repetir o mesmo estado não duplica o evento;
- não há deleção em cascata de referências nem ocultação automática nas views.

A UI pode separar ativos e arquivados com base em `archived_at`, mas não deve apresentar archive como delete físico nem apagar referências históricas para simular limpeza.

## Pedidos e contagens futuras

A referência de UI menciona lista de clientes, clientes com pedidos abertos e clientes sem pedidos. **Pedidos/ordens ainda não existem nesta migration nem há uma projeção de `order_count`, `open_order_count` ou equivalente.** Não retornar zero estático, não criar uma contagem derivada de indicadores e não afirmar que filtros de pedidos estão implementados.

Quando a migration de orders existir, a contagem deve ser refinada a partir do contrato real, nesta ordem:

1. identificar a tabela/view de ordens e sua FK de organização/cliente;
2. confirmar os nomes reais dos estados que significam “aberto”;
3. criar uma view ou RPC tenant-scoped que conte linhas reais, com join pela organização e pelo cliente;
4. adicionar testes para cliente sem ordens, com ordens, status aberto/fechado, arquivado e organizações diferentes;
5. só então acrescentar o campo ao DTO e atualizar esta documentação com a assinatura/coluna real.

Até essa migration, a projeção correta é ausência de contagem, não uma contagem inventada.

## Limites de verificação e operação

A suite isolada aprovou 12 grupos de contrato: Auth/tenant, normalização, indicadores por unidade, grants por coluna, papéis, idempotência, CPF/CNPJ numérico e alfanumérico, isolamento, archive/auditoria e importação atômica com limite. Fixtures existiram somente no cluster `vm_test` sem listener TCP, não na aplicação.

A aplicação incremental registrou `20261029235500_contacts` e notificou reload de PostgREST. A UI e um cadastro/importação operacional realizado pelo negócio ainda não foram exercitados neste registro. Não foram criados contatos fictícios para preencher telas.
