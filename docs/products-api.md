# Products API — contrato de banco

## Estado e escopo

Este documento descreve o contrato definido em `supabase/migrations/20261029233000_products.sql`, exercitado pela suite SQL local e aplicado ao Supabase autorizado em 29/10/2026 às 19:38 BRT. RLS e registro foram verificados; evidência em `products-verification.md`. A UI conectada está em implementação; não há alegação de upload real demonstrativo, vitrine ou publicação. A assinatura das RPCs abaixo é a assinatura SQL atual e não deve ser alterada apenas pela documentação.

As chamadas são RPCs PostgreSQL expostas pelo PostgREST após a migration aplicada. O contrato não é uma promessa de que um upload HTTP real já tenha sido executado nesta fatia.

As RPCs de mutação exigem sessão `authenticated` e membership com papel `owner`, `admin` ou `production` na organização informada. `finance`, `viewer` e `anon` não têm permissão para mutar o catálogo. As views são `security_invoker`; a leitura continua sujeita ao RLS das tabelas de origem e à organização do usuário.

## `vm_upsert_product_v2`

Assinatura lógica:

```text
public.vm_upsert_product_v2(
  uuid, text, text, jsonb, text, text, text, text, integer, text,
  numeric, numeric, numeric, text, boolean, boolean, jsonb, numeric,
  numeric, numeric, numeric, text, text, jsonb, jsonb, jsonb, uuid, uuid
)
```

A ordem, o tipo SQL e o default são parte do contrato. Há 28 parâmetros:

| # | Parâmetro | Tipo SQL | Default declarado | Regra principal |
|---:|---|---|---|---|
| 1 | `p_organization_id` | `uuid` | — | Organização alvo; precisa existir e pertencer à sessão autorizada. |
| 2 | `p_name` | `text` | — | Obrigatório; trim, não vazio, no máximo 200 caracteres. |
| 3 | `p_category` | `text` | — | Obrigatório; trim, não vazio, no máximo 120 caracteres. |
| 4 | `p_categories` | `jsonb` | `'[]'::jsonb` | Array de strings não vazias, até 120 caracteres cada, sem duplicatas. |
| 5 | `p_subcategory` | `text` | `NULL` | Opcional; quando informada, não vazia após trim e até 120 caracteres. |
| 6 | `p_description` | `text` | `NULL` | Opcional; até 20.000 caracteres. |
| 7 | `p_material_info` | `text` | `NULL` | Opcional; até 5.000 caracteres. |
| 8 | `p_personalization_info` | `text` | `NULL` | Opcional; até 5.000 caracteres. |
| 9 | `p_production_days` | `integer` | `0` | Inteiro de 0 a 10.000. |
| 10 | `p_pricing_mode` | `text` | `'unit'` | Um de `unit`, `variation` ou `m2`. `variation` exige ao menos uma variação. |
| 11 | `p_price` | `numeric` | `NULL` | Preço normal. Embora o default da assinatura seja `NULL`, a validação exige valor numérico finito, não negativo e com até 8 casas. |
| 12 | `p_promo_price` | `numeric` | `NULL` | Opcional; numérico válido e menor ou igual a `p_price`. |
| 13 | `p_minimum_quantity` | `numeric` | `1` | MOQ do produto; positivo, finito e com até 8 casas. |
| 14 | `p_billing_unit` | `text` | `'unit'` | Só pode ser `unit` ou `m2`; `m2` é obrigatório quando `p_pricing_mode = 'm2'`, e `unit` nos demais modos. |
| 15 | `p_is_catalog_visible` | `boolean` | `false` | Indicador persistido de visibilidade; não publica uma vitrine que ainda não existe. |
| 16 | `p_is_featured` | `boolean` | `false` | Indicador persistido de destaque. |
| 17 | `p_custom_questions` | `jsonb` | `'[]'::jsonb` | Array de perguntas com shape validado; `type` é `text`, `textarea`, `select`, `boolean` ou `number`. `required` é booleano. `select` exige `options` como array não vazio de strings não vazias, únicas e de até 120 caracteres. |
| 18 | `p_weight_kg` | `numeric` | `NULL` | Opcional; quando informado, positivo, finito e com até 8 casas. |
| 19 | `p_width_cm` | `numeric` | `NULL` | Opcional; quando informado, positivo, finito e com até 8 casas. |
| 20 | `p_height_cm` | `numeric` | `NULL` | Opcional; quando informado, positivo, finito e com até 8 casas. |
| 21 | `p_depth_cm` | `numeric` | `NULL` | Opcional; quando informado, positivo, finito e com até 8 casas. |
| 22 | `p_sku` | `text` | `NULL` | Opcional; trim, não vazio após trim, até 120 caracteres e único por organização sem diferenciar maiúsculas/minúsculas. |
| 23 | `p_barcode` | `text` | `NULL` | Opcional; trim, não vazio após trim, até 120 caracteres e único por organização sem diferenciar maiúsculas/minúsculas. |
| 24 | `p_wholesale_tiers` | `jsonb` | `'[]'::jsonb` | Array ordenado de `{minimum_quantity, unit_price}`; MOQ positivo e estritamente crescente, preço finito/não negativo e até 8 casas. |
| 25 | `p_components` | `jsonb` | `'[]'::jsonb` | Array de `{material_id, quantity, unit}`; materiais distintos da mesma organização e unidade exatamente igual à unidade do insumo. |
| 26 | `p_variants` | `jsonb` | `'[]'::jsonb` | Upsert parcial de variações; cada item exige nome, preço e `composition_mode`. |
| 27 | `p_product_id` | `uuid` | `NULL` | `NULL` cria o produto na versão 1; UUID existente atualiza esse produto e cria uma nova versão imutável. |
| 28 | `p_idempotency_key` | `uuid` | `NULL` | Obrigatória em runtime; a chave é escopada por organização e não pode ser omitida. |

### Validação numérica e payloads JSON

Os campos numéricos da RPC são validados antes do cast para colunas `numeric(20,8)`. Para os valores não negativos, o limite absoluto é `999999999999.99999999`; `NULL`, `NaN`, `Infinity`, `-Infinity`, escala acima de 8 casas e valores negativos onde não permitidos são rejeitados. Não há arredondamento silencioso para fazer o valor caber.

A precisão de 8 casas é a fronteira do cálculo do catálogo e da composição; ela não significa que a moeda de uma ordem já esteja resolvida em 8 casas. A futura ordem deve definir explicitamente a fronteira de moeda (normalmente 2 casas), além de resolver a unidade de cobrança (`unit` ou `m2`), o preço normal/promocional e o tier cuja MOQ seja aplicável. Essa resolução de billing, preço/tier e MOQ é futura e não é implementada por esta RPC.

A composição base aceita `material_id` UUID, `quantity` positiva e `unit` não vazia com até 40 caracteres. A RPC rejeita material inexistente, material de outro tenant, unidades divergentes e material repetido. A soma de `quantity * unit_cost` é calculada no banco.

Cada item de `p_variants` tem este shape lógico:

```json
{
  "id": "uuid opcional",
  "name": "nome obrigatório",
  "sku": "SKU opcional",
  "price": "numeric obrigatório",
  "promo_price": "numeric opcional",
  "active": true,
  "minimum_quantity": "numeric opcional",
  "composition_mode": "inherit_base ou own",
  "components": [
    {"material_id": "uuid", "quantity": "numeric", "unit": "g"}
  ]
}
```

`active` assume `true` quando omitido. Em `composition_mode = 'own'`, `components` é validado e gravado como receita da variação. Em `inherit_base`, a variação usa a composição base da versão do produto e `components` deve ser omitido ou vazio; uma composição própria não pode ser silenciosamente ignorada.

### Retorno

A RPC retorna uma linha com as colunas abaixo, nesta ordem:

| Coluna | Tipo retornado | Significado |
|---|---|---|
| `product_id` | `uuid` | Produto criado ou atualizado. |
| `version` | `text` | Número da versão convertido para texto. |
| `pricing_mode` | `text` | `unit`, `variation` ou `m2`. |
| `normal_price` | `text` | `p_price` serializado como texto para preservar precisão. |
| `promo_price` | `text` | Promoção como texto; `NULL` quando ausente. |
| `minimum_quantity` | `text` | MOQ do produto como texto. |
| `component_count` | `integer` | Quantidade de linhas da composição base recebida. |
| `composition_cost` | `text` | Soma calculada no banco a partir dos snapshots de custo dos insumos. |

Mesmo os valores numéricos do retorno são `text`; o consumidor não deve parsear para `float` e reintroduzir arredondamento binário.

### Idempotência, payload estrito e versões

`p_idempotency_key` é obrigatório e é único dentro da organização. A primeira execução registra a chave junto com o payload canônico, o produto, a versão e os valores textuais retornados. Uma nova chamada com a mesma chave e payload equivalente retorna a mesma operação sem criar outra versão. A mesma chave com payload diferente falha com colisão (`SQLSTATE 23505`); não é um mecanismo de “alterar o pedido original”.

O payload comparado inclui os campos do produto, `product_id` e a composição normalizada pelo servidor. Nomes, categoria, subcategoria, SKU e barcode são trimados; a composição base é serializada em ordem determinística por `material_id`. Portanto, o cliente deve reutilizar a mesma intenção completa, e não apenas um subconjunto de campos, ao repetir uma chamada.

Com `p_product_id = NULL`, o cadastro começa em `version = 1`. Com um `p_product_id` existente, o produto corrente é atualizado e sua `current_version` é incrementada. Cada versão guarda uma fotografia imutável dos campos, composição, variações e custo da composição. As versões históricas continuam legíveis; os triggers bloqueiam update/delete direto das versões e das receitas versionadas.

O upsert de variações é deliberadamente parcial: variações presentes no array são criadas ou atualizadas; **variações omitidas permanecem disponíveis**. Omitir uma variação não a remove nem a desativa. Uma variação existente é identificada por `id` dentro do mesmo produto e organização; uma UUID de variação pertencente a outro produto é rejeitada.

## Custo, snapshots e fronteira monetária

Ao gravar uma versão, a RPC lê `vm_materials.unit_cost` e grava `component_unit` e `unit_cost_snapshot` em cada linha. `line_cost` e `composition_cost` são derivados desses snapshots. O valor é um custo indicativo da composição calculado na gravação da versão; não é uma leitura viva do custo corrente do material.

Assim, o custo da última versão do produto é diferente do custo corrente hoje registrado no material. Alterar o custo de um insumo não reescreve versões históricas nem recalcula automaticamente o `composition_cost` retornado pela view. Para comparar com o custo corrente, é necessário consultar o catálogo de materiais pelo contrato de Inventory e fazer essa comparação explicitamente.

A distinção é importante para ordens futuras: a ordem deve guardar sua própria decisão de preço, unidade de cobrança, tier e MOQ, além da política de arredondamento monetário. Esta migration preserva precisão de catálogo em 8 casas e não implementa a conversão para moeda de 2 casas nem o resolvedor de preço de pedido.

## DTOs de leitura

Todas as cinco views abaixo foram definidas com `security_invoker = true`. Os nomes são os nomes reais das colunas SQL; não usar aliases de UI como se fossem parte deste contrato. As colunas numéricas expostas pelas views são convertidas para `text`.

### `public.vm_products_read`

```text
id
organization_id
name
category
categories
subcategory
description
material_info
personalization_info
production_days       -- text
pricing_mode
price                 -- text
promo_price           -- text
minimum_quantity      -- text
billing_unit
is_catalog_visible
is_featured
custom_questions
weight_kg             -- text
width_cm              -- text
height_cm             -- text
depth_cm              -- text
sku
barcode
wholesale_tiers
current_version       -- text
current_composition_cost -- text
created_at
updated_at
```

`current_composition_cost` vem da linha da `vm_product_versions` com `product_version = current_version`. Apesar do nome “current”, é o custo do snapshot da última versão, não o custo corrente material em `vm_materials` e não uma recomputação no momento da leitura. Atualmente não há uma coluna `current_material_cost` nessa view; se o SQL final acrescentar esse campo antes da aplicação, esta documentação deve ser revisada a partir da definição final da view, sem reinterpretar `current_composition_cost` como custo vivo.

### `public.vm_product_components_read`

```text
organization_id
product_id
product_version       -- text
material_id
component_unit
quantity              -- text
unit_cost             -- text; snapshot do custo do insumo
line_cost             -- text
created_at
```

### `public.vm_product_versions_read`

```text
organization_id
product_id
product_version       -- text
name
category
categories
subcategory
description
material_info
personalization_info
production_days       -- text
pricing_mode
billing_unit
price                 -- text
promo_price           -- text
minimum_quantity      -- text
is_catalog_visible
is_featured
custom_questions
weight_kg              -- text
width_cm              -- text
height_cm              -- text
depth_cm               -- text
sku
barcode
wholesale_tiers
composition_snapshot
variants_snapshot
composition_cost       -- text
snapshot_metadata
created_by
created_at
```

`composition_snapshot` e `variants_snapshot` são as fotografias históricas usadas pela versão; não devem ser substituídas por uma nova leitura de estado vivo para exibir um pedido histórico.

### `public.vm_product_variants_read`

```text
id
organization_id
product_id
name
sku
price                 -- text
promo_price           -- text
active
minimum_quantity      -- text
composition_mode
current_version       -- text
created_at
updated_at
```

A view de variações expõe os metadados correntes da variação. A receita própria histórica está nas linhas versionadas de `vm_product_variant_components` e é refletida no snapshot da versão do produto; `inherit_base` não possui receita própria.

### `public.vm_product_files_read`

```text
id
organization_id
product_id
kind
path
mime_type
size_bytes            -- text
name
created_by
created_at
```

A leitura de `vm_product_files_read` é metadado de arquivo, não uma garantia de download público. O objeto continua no bucket privado.

## `vm_register_product_file`

A RPC registra metadados somente depois que o objeto Storage já existe e pode ser verificado:

```text
public.vm_register_product_file(
  p_organization_id uuid,
  p_product_id uuid,
  p_kind text,
  p_path text,
  p_mime_type text,
  p_size_bytes bigint,
  p_name text
)
RETURNS TABLE(
  file_id uuid,
  organization_id uuid,
  product_id uuid,
  kind text,
  path text,
  mime_type text,
  size_bytes text,
  name text,
  created_by uuid,
  created_at timestamptz
)
```

Os sete parâmetros, na ordem, são `p_organization_id`, `p_product_id`, `p_kind`, `p_path`, `p_mime_type`, `p_size_bytes` e `p_name`. `p_kind` é `photo`, `digital` ou `production`. Os MIME aceitos são `image/jpeg`, `image/png`, `image/webp`, `application/pdf` e `application/zip`; `photo` aceita somente os três MIME de imagem. `p_size_bytes` deve estar entre 0 e 52.428.800 bytes (50 MiB), e `p_name` deve ser não vazio e ter até 255 caracteres.

O path precisa ter exatamente a forma lógica:

```text
<organization_uuid>/<product_uuid>/<filename>
```

O filename começa por caractere alfanumérico e pode conter somente caracteres alfanuméricos, ponto, sublinhado e hífen, com até 255 caracteres. Não são aceitos barra invertida, `..` ou barras duplicadas. Os dois primeiros segmentos precisam corresponder à organização e ao produto da chamada.

Antes da RPC, a aplicação deve fazer o upload real para `vm-product-media`. A RPC consulta `storage.objects` e exige que exista uma linha do bucket com o mesmo `name`, além de `metadata.mimetype` igual ao MIME normalizado e `metadata.size` igual ao tamanho informado como texto. Se o upload falhar, não se deve registrar metadado nem mostrar sucesso de download. Inserir diretamente em `vm_product_files` também não faz parte do contrato: o acesso DML direto é revogado.

Registrar novamente o mesmo path com exatamente os mesmos metadados retorna o registro existente. O mesmo path com produto, tipo, MIME, tamanho ou nome diferente falha com colisão (`SQLSTATE 23505`). O retorno tem `size_bytes` como `text`, pelos mesmos motivos de preservação de precisão/serialização usados nos DTOs.

### Bucket, políticas e leitura

O bucket é `vm-product-media` e deve ser **privado**, com limite declarado de 52.428.800 bytes e os cinco MIME acima. A migration cria o bucket somente se ele estiver ausente. Se o bucket já existir e for público, a migration falha; ela não deve transformar silenciosamente um bucket preexistente público em privado nem substituir configurações/ownership alheios.

As policies nomeadas para `storage.objects` são `vm_product_media_select`, `vm_product_media_insert` e `vm_product_media_delete`. A leitura exige membership e path válido; o upload exige papel `owner`, `admin` ou `production`; a policy de delete também exige esses papéis. Isso não cria uma API pública de remoção de arquivo.

Para exibir ou baixar um arquivo, a aplicação deve consultar o metadado autorizado e solicitar uma URL assinada de curta duração para o path do bucket privado, por exemplo pelo cliente Storage autenticado. A resposta de `vm_register_product_file` sozinha não é uma URL, e uma linha de metadado não deve ser usada para fingir que um download ocorreu. Não usar URL pública nem marcar sucesso quando o upload, a assinatura ou a transferência falhar.

Não existe uma RPC de delete para `vm_product_files`. A remoção direta do objeto Storage pode deixar uma referência pendente em `vm_product_files`; sem uma nova RPC de reconciliação/remoção, a UI **não deve expor remoção**. A policy de delete existente é uma capacidade de Storage de baixo nível, não um contrato de exclusão sincronizada do arquivo do ERP.

## Limites desta fatia

Estoque acabado e variações finas específicas de PDV não são afirmados por este contrato e permanecem fora desta documentação. Cadastro, upload e leitura de produtos também não significam que o catálogo esteja publicado. Qualquer implementação futura deve preservar os snapshots históricos, o contrato textual dos DTOs, a idempotência estrita e os limites de Storage descritos aqui.
