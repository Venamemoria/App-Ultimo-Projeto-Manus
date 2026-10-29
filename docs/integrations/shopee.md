# Shopee Open Platform — preparação do adaptador

Escopo: documentação para um ERP Vite/React/Tailwind com Supabase Edge Functions. Este documento descreve preparação server-side; não ativa o aplicativo, não contém credenciais e não autoriza chamadas reais de envio, compra ou cotação.

## Domínios, transporte e parâmetros comuns

A documentação atual de Open API v2 lista estes domínios de produção: `https://partner.shopeemobile.com/` para desenvolvedores próximos de SG, `https://openplatform.shopee.com.br/` para desenvolvedores próximos dos EUA e `https://openplatform.shopee.cn/` para a China continental. Para sandbox, lista `https://openplatform.sandbox.test-stable.shopee.sg/` e `https://openplatform.sandbox.test-stable.shopee.cn/`. A região deve ser uma configuração server-side, não uma decisão feita pelo navegador. [1]

A autorização usa URLs fixas separadas do host da API: produção global `https://open.shopee.com/auth`, China `https://open.shopee.cn/auth` e Brasil `https://open.shopee.com.br/auth`; o guia também lista os hosts sandbox correspondentes. [2] O protocolo v2 é HTTP/JSON na maioria das APIs; a plataforma suporta somente GET e POST. Em GET, parâmetros comuns e de negócio ficam na URL; em POST, os comuns ficam na query e os de negócio no JSON body. Os exemplos oficiais usam `Content-Type: application/json` e `Accept: application/json`; não há um header `Authorization: Bearer` documentado para substituir os parâmetros comuns. [1] [2]

Parâmetros comuns por tipo de API:

- **Shop API:** `partner_id`, `timestamp`, `sign`, `access_token`, `shop_id`.
- **Merchant API:** `partner_id`, `timestamp`, `sign`, `access_token`, `merchant_id`; o guia diz que Merchant API se aplica a vendedores cross-border.
- **Public API:** `partner_id`, `timestamp`, `sign`, sem `access_token`.

`partner_id` e `partner_key` vêm do App no Console. `timestamp` é inteiro Unix em segundos e cada requisição precisa ser feita dentro de cinco minutos desse timestamp. `shop_id` e `merchant_id` são identificadores inteiros retornados no fluxo de autorização. [1]

## Autorização de partner/shop e OAuth

O fluxo atual tem três partes: gerar o link, o vendedor autorizar e trocar o código por tokens. O link `/auth` exige `partner_id`, `auth_type` (`seller` para autorizar loja/merchant), `redirect_uri` e `response_type=code`; `state` é opcional e deve ser aleatório e imprevisível para proteção contra CSRF. O domínio do `redirect_uri` precisa corresponder ao domínio de callback de teste/live declarado no Console. [2]

Uma autorização por conta da loja retorna `code` e `shop_id`; uma autorização por conta principal pode retornar `code` e `main_account_id`. Subconta não pode entrar na página de autorização. O `code` só pode ser usado uma vez e expira em dez minutos. A autorização escolhida pelo vendedor pode durar até 365 dias, conforme a tela/documentação do fluxo. [2]

Rotas de token documentadas:

- `POST {API_BASE}/api/v2/auth/token/get`: query com `partner_id`, `timestamp`, `sign`; JSON com `code`, `partner_id` e exatamente um identificador de autorização (`shop_id` ou `main_account_id`). Retorna `access_token`, `refresh_token`, `expire_in`, além de `request_id`, `error` e `message`; para conta principal pode retornar listas de merchants/shops. [2]
- `POST {API_BASE}/api/v2/auth/access_token/get`: query com `partner_id`, `timestamp`, `sign`; JSON com `refresh_token` e exatamente um alvo por renovação (`shop_id` ou `merchant_id`). Cada refresh token é válido por 30 dias e só pode ser usado uma vez para um shop/merchant; o novo access token vale quatro horas. Após emitir novo access token, o anterior permanece válido por mais cinco minutos. [2]

A documentação da mesma página ainda mostra o endpoint legado `/api/v2/shop/auth_partner` e exemplos HMAC para gerar links antigos. Não tratar esse exemplo legado como substituto automático do link `/auth` atual; o tipo de App e a página de autorização do Console devem prevalecer. [2]

Tokens devem ser armazenados separadamente por `shop_id`/`merchant_id` em armazenamento protegido da Edge Function, com rotação atômica do refresh token. Não colocar tokens, partner key ou `service_role` no bundle Vite ou em tabelas expostas ao cliente.

## Assinatura HMAC-SHA256

Para cada chamada v2, a assinatura é o HMAC-SHA256 da string-base concatenada sem separadores, usando `partner_key`; o resultado é hexadecimal minúsculo. A string-base usa o path sem host e a ordem exata abaixo: [1]

- Shop: `partner_id + api_path + timestamp + access_token + shop_id`.
- Merchant: `partner_id + api_path + timestamp + access_token + merchant_id`.
- Public/token: `partner_id + api_path + timestamp`.

O `sign` é enviado como parâmetro comum na query. Não há assinatura do body descrita para as chamadas JSON. Repetições após cinco minutos exigem novo timestamp e novo `sign`; não reutilizar uma URL assinada expirada. [1] [2]

## Pedidos e catálogo: rotas e limites verificáveis

A página geral confirma que os módulos Product e Order existem em v2 e que o módulo Order consulta lista/detalhes; ela não fixa uma unidade monetária ou uma idempotency key geral. [1]

As páginas oficiais de endpoint abaixo foram visitadas, mas o `fetch` retornou somente o shell “Shopee Open Platform”; por isso, os campos que seguem são apenas os que a própria indexação/página geral expôs. O verbo e o schema completo devem ser reconfirmados no documento do endpoint antes de codificar o adaptador; não inventar defaults, limites ou nomes de headers.

- `/api/v2/order/get_order_list` (verbo não confirmável na extração; o guia v2 admite GET/POST) — consulta por loja. A página oficial expõe `time_range_field`, `time_from`, `time_to` e `page_size`; `time_from`/`time_to` delimitam a janela e a janela máxima documentada é de 15 dias. Usar timestamps Unix em segundos e particionar janelas; o restante da paginação e os valores máximos de `page_size` ficaram inacessíveis na extração. [10]
- `/api/v2/order/get_order_detail` (verbo não confirmável na extração) — consulta por loja. `shop_id` é parâmetro comum; `order_sn` é obrigatório e, quando houver vários, a documentação indexada exige lista separada por vírgula com limite de 1 a 50. `order_sn` é string, não número. [11]
- `/api/v2/product/get_item_list` (verbo não confirmável na extração) — lista de itens da loja. A rota está publicada na documentação oficial; a página de schema abriu apenas o shell e não permitiu confirmar campos opcionais, paginação ou método na sessão. [12]
- `/api/v2/product/get_item_base_info` (verbo não confirmável na extração) — detalhes básicos de itens. `shop_id` é parâmetro comum e `item_id_list` é obrigatório; a documentação indexada indica lista `int64` com limite de 0–50 itens. [13]
- O módulo Product também documenta árvore de categorias, atributos/marcas, dados de itens e variações. A criação de produto exige categoria folha e atributos obrigatórios retornados por `v2.product.get_attribute_tree`; isso é requisito de catálogo da Shopee, não uma permissão para criar/alterar produtos nesta preparação. [1] [8]

Unidades a preservar no adaptador: IDs de shop/item em inteiro ou `int64`; `timestamp`, `time_from`, `time_to`, `update_time` e `expire_in` em segundos quando assim definidos pelos payloads/exemplos oficiais; `order_sn` como string; `sign` como hex de HMAC-SHA256. Não converter timestamps para milissegundos nem arredondar valores de catálogo sem confirmar o schema por mercado. A página de criação informa ainda que regras de casas decimais de preço variam por marketplace; não assumir uma unidade monetária universal. [8]

## Push/callbacks oficiais e segurança realmente suportada

O Push Mechanism oficial permite configurar callback e verificar/salvar a URL no Console; o sandbox v2 descreve `Test Call Back URL`, “Verify and Save” e envio de dados de teste. As páginas de configuração `v2.push.set_app_push_config` e `v2.push.get_app_push_config` foram visitadas, mas abriram apenas o shell, então o payload final de configuração deve ser conferido no Console. [15] [16] [17]

Eventos relevantes para o ERP:

- `order_status_push`, código `3`: o exemplo oficial traz `data.ordersn`, `data.status`, `data.completed_scenario`, `data.update_time`, `shop_id`, `code` e `timestamp`. Timeout documentado: 3 s; sequência não garantida; a mesma mensagem pode repetir; retries documentados em 300 s, 1.800 s e 10.800 s. [18]
- `shop_authorization_push`, código `1`: notifica autorização de loja/merchant e traz `partner_id` ou `shop_id`/`main_account_id`/`merchant_id`, `code`, `timestamp` e `data.success`. Timeout: 3 s; sequência não garantida; repetição permitida; retries em 300 s, 1.800 s e 10.800 s. [19]
- O índice oficial também lista `order_trackingno_push`, `shop_authorization_canceled_push`, `open_api_authorization_expiry`, retornos e outros pushes; assinar somente os tipos permitidos ao tipo de App. [18] [20]

**Autenticidade:** nos payloads oficiais consultados de `order_status_push`, `shop_authorization_push` e `webchat_push` não aparece campo `sign`, e não foi encontrada documentação oficial de header, segredo ou HMAC específico para autenticar o callback. Portanto, não declarar que o webhook Shopee tem HMAC próprio. O que pode ser documentado é HTTPS, validação do `partner_id`/`shop_id` contra autorizações armazenadas, limite de corpo, resposta rápida e processamento assíncrono. A página de gerenciamento também menciona, como opção de rede, obter ranges de IP por `v2.public.get_shopee_ip_ranges`; allowlist de IP é defesa adicional, não prova criptográfica de autenticidade. [3] [18] [19]

Como mensagens podem repetir e não têm sequência garantida, o adaptador deve responder em até 2–3 s somente depois de validar formato mínimo, registrar o payload bruto sem segredos e inserir uma chave de deduplicação própria. Como não há event ID universal nos exemplos, usar uma impressão estável do payload junto com parceiro/loja/código e chave de negócio (`ordersn` quando existir), com retenção e tratamento explícitos de replay. A documentação não define janela de replay; não inventar uma.

## Erros, limites e idempotência

Toda resposta v2 deve ser tratada pelo JSON, não apenas pelo HTTP status: a documentação lista `request_id` sempre, `error` sempre, `message` para detalhe, e `warning`/`response` quando aplicáveis. A própria regra de performance define sucesso como HTTP 200 **e** `error` e `message` vazios. Persistir `request_id`, endpoint, status, erro e tentativa sem tokens ou dados PII completos. [1] [6]

A Shopee pode limitar número de requisições e usuários por App; chamadas dos usuários contam para o limite do App, e não há um valor global único publicado no guia acessível. Há indicação oficial de redução do limite diário como penalidade, mas os valores por rota/mercado precisam ser consultados na página específica/Console. [6] [21] A política exige, entre outros pontos, que o App fique live em até 90 dias da criação, faça ao menos uma chamada nos 90 dias após ficar live e mantenha média diária de sucesso de pelo menos 90%; APIs públicas de refresh são excluídas dessa métrica. [6]

Para um adaptador server-side: aplicar backoff com jitter somente para falhas transitórias/rate limit; respeitar `Retry-After` se a resposta futura o fornecer; não repetir escrita sem chave própria; limitar concorrência por partner/shop; e regenerar assinatura quando o timestamp expirar. Não há uma chave de idempotência oficial geral documentada para Order/Product.

## Requisitos de partner/app aprovado

A conta de desenvolvedor precisa estar aprovada para criar Apps no Console. Para um ERP que atende vendedores, o tipo oficial apropriado é **ERP System**; um Third-party Partner Platform (ISV) pode criar ERP, Product Management, Order Management, Accounting and Finance e Marketing conforme a matriz de permissões. Apps novos recebem permissões somente v2.0. [3]

Ao criar o App, o Console fornece Test Partner ID e Test Key, válidos somente no sandbox. Depois dos testes, o fluxo Go Live exige submissão; a página de gerenciamento informa revisão em 24 horas e, após aprovação, disponibiliza Live Partner ID e Live Key para produção. App em status Developing não pode autorizar lojas nem chamar APIs de produção; isso só ocorre em Online. [3]

Dados sensíveis começam mascarados. Para pedir buyer PII não mascarado, é necessário declarar necessidade e todos os IPs de servidores que acessarão OpenAPI; para ISVs que atendem ou planejam atender vendedores em TH/MY/SG/PH, CNCB ou HKCB, a documentação exige relatório de penetration test válido. A aprovação desse acesso tem validade de dois anos a partir da emissão do relatório para ISVs. [5] A existência de um relatório ou de uma conta não significa que este ERP esteja aprovado, live ou autorizado a uma loja.

## Variáveis server-side sugeridas (sem valores)

- `SHOPEE_PARTNER_ID`
- `SHOPEE_PARTNER_KEY`
- `SHOPEE_PRODUCTION_API_BASE_URL`
- `SHOPEE_SANDBOX_API_BASE_URL`
- `SHOPEE_PRODUCTION_AUTH_BASE_URL`
- `SHOPEE_SANDBOX_AUTH_BASE_URL`
- `SHOPEE_OAUTH_REDIRECT_URI`
- `SHOPEE_WEBHOOK_CALLBACK_URL`
- `SHOPEE_API_REGION`

Access/refresh tokens não devem ser variáveis Vite nem um único segredo global: devem ficar por loja/merchant em armazenamento server-side protegido. Não criar `SHOPEE_WEBHOOK_SECRET` como se fosse um recurso oficial; a documentação consultada não confirma segredo/HMAC de callback. Se a aplicação acrescentar um token interno de ingress, nomeá-lo separadamente de Shopee e não tratá-lo como autenticação emitida pela Shopee.

## Limitações verificadas

1. As páginas de schema de `get_order_list`, `get_order_detail`, `get_item_list`, `get_item_base_info` e configuração de push foram visitadas, mas o extrator retornou somente o shell da Open Platform. Os campos completos, verbos confirmados, paginação detalhada, quotas por rota e body exato devem ser reabertos no Console/documentação autenticada antes da implementação.
2. O guia geral e exemplos confirmam HMAC para chamadas Open API, não para callbacks. Não foi encontrada evidência oficial suficiente para declarar assinatura de webhook, replay window ou event ID universal.
3. Não foram usados conta, partner key, token, sandbox real ou endpoints de produção; nenhuma ativação, autorização de loja ou transação foi realizada.
4. “Preparado/documentado” não significa “aprovado”, “live”, “autorizado”, “testado” ou “ativado”.

## Referências

[1]: https://open.shopee.com/developer-guide/16 "Open API v2 general guide"
[2]: https://open.shopee.com/developer-guide/20 "Authorization and Authentication"
[3]: https://open.shopee.com/developer-guide/14 "App management"
[4]: https://open.shopee.com/developer-guide/4 "Developer guide and integration overview"
[5]: https://open.shopee.com/developer-guide/718 "Requesting Access to Sensitive Data"
[6]: https://open.shopee.com/developer-guide/34 "Platform Partner Rules"
[7]: https://open.shopee.com/developer-guide/36 "Shopee Open Platform Terms of Service"
[8]: https://open.shopee.com/developer-guide/211 "Creating product"
[9]: https://open.shopee.com/developer-guide/644 "Sandbox Testing V2"
[10]: https://open.shopee.com/documents/v2/v2.order.get_order_list?module=94&type=1 "v2.order.get_order_list"
[11]: https://open.shopee.com/documents/v2/v2.order.get_order_detail?module=94&type=1 "v2.order.get_order_detail"
[12]: https://open.shopee.com/documents/v2/v2.product.get_item_list?module=89&type=1 "v2.product.get_item_list"
[13]: https://open.shopee.com/documents/v2/v2.product.get_item_base_info?module=89&type=1 "v2.product.get_item_base_info"
[15]: https://open.shopee.com/developer-guide/18 "Understanding Push Mechanism notifications"
[16]: https://open.shopee.com/documents/v2/v2.push.set_app_push_config?module=105&type=1 "v2.push.set_app_push_config"
[17]: https://open.shopee.com/documents/v2/v2.push.get_app_push_config?module=105&type=1 "v2.push.get_app_push_config"
[18]: https://open.shopee.com/push-mechanism/1 "order_status_push"
[19]: https://open.shopee.com/push-mechanism/15 "shop_authorization_push"
[20]: https://open.shopee.com/push-mechanism/4 "Push Mechanism index"
[21]: https://open.shopee.com/documents/v2/v2.ams.get_open_campaign_added_product?module=127&type=1 "Open API error and limit fields"
