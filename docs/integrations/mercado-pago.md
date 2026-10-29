# Mercado Pago — preparação documental do adaptador

**Escopo.** Esta é uma pesquisa somente documental para um ERP Vite/React/Tailwind com Supabase Edge Functions. Não houve login, uso de credenciais, chamadas reais de criação de cobrança, compra, cotação ou ativação. O Checkout Pro redireciona o comprador para o ambiente do Mercado Pago e usa a Preferences API; a criação da preferência deve ocorrer no backend, não no bundle Vite. [1] [2]

## Base, autenticação e credenciais

- **URL-base oficial da API:** `https://api.mercadopago.com`.
- **Header para chamadas server-side:** `Authorization: Bearer <ACCESS_TOKEN>` e `Content-Type: application/json`. A referência oficial mostra o Access Token no Bearer tanto na criação da preferência quanto na consulta de pagamento. [3] [4]
- O Access Token é uma credencial privada de backend e nunca deve ser exposto no frontend. Há credenciais de teste e de produção separadas; a produção exige ativação da aplicação e os dados solicitados pelo Mercado Pago. [6] [10]
- Para uma conta vendedora própria, usa-se o Access Token da aplicação. OAuth só é necessário se a integração atuar em nome de terceiros; nesse caso a documentação prevê authorization code ou client credentials, com `client_id`, `client_secret` e, conforme o fluxo, consentimento/redirect do vendedor. [7]
- Produção requer URL HTTPS/SSL para a integração. A configuração de Webhooks também exige uma URL HTTPS no modo produtivo e a seleção dos eventos no painel da aplicação. [5] [10]

## Rotas que o adaptador deve documentar

### 1. Criar preferência Checkout Pro

`POST https://api.mercadopago.com/checkout/preferences` [3]

**Headers:** `Authorization: Bearer <ACCESS_TOKEN>` e `Content-Type: application/json`.

**Corpo mínimo demonstrado oficialmente:**

```json
{
  "items": [
    {
      "title": "Meu produto",
      "quantity": 1,
      "unit_price": 2000,
      "currency_id": "BRL"
    }
  ]
}
```

`items` é uma lista; cada item usa título, quantidade e preço unitário. A página oficial confirma que o total da preferência é a soma dos preços dos itens. `quantity` é contagem de unidades e `unit_price` é valor monetário na moeda indicada; para este ERP, representar BRL explicitamente com `currency_id: "BRL"` e manter valores decimais, sem tratar centavos como unidade implícita. A referência também documenta campos opcionais como `id`, `description`, `picture_url`, `category_id`, `payer`, `payment_methods`, `shipments`, `back_urls`, `notification_url`, `auto_return`, `external_reference` e expiração. [2] [3]

`back_urls.success`, `back_urls.pending` e `back_urls.failure` são URLs de retorno; `notification_url` é a URL de notificação por preferência. O retorno contém, entre outros campos, `id`, `init_point` e, quando aplicável, `sandbox_init_point`; o `init_point` é o destino que o frontend pode abrir depois que a Edge Function criar a preferência. O retorno de navegador não confirma pagamento. [2] [3]

**Resposta/erro relevante:** a referência lista erros de validação para itens, preço, URLs de retorno, métodos de pagamento, datas e Access Token. O `collector_id` também pode estar bloqueado por pendências de identidade/conformidade, impedindo nova preferência. [3]

### 2. Consultar pagamento por ID — validação server-side

`GET https://api.mercadopago.com/v1/payments/{id}` [4]

**Headers:** `Authorization: Bearer <ACCESS_TOKEN>` e, conforme o exemplo oficial, `Content-Type: application/json`. Não há corpo.

O `{id}` deve ser o identificador do pagamento recebido no evento (`data.id`) ou obtido de uma fonte server-side confiável. A resposta traz `status`, `status_detail`, `currency_id`, `transaction_amount`, `external_reference`, dados do pagador e datas. O estado interno do ERP só deve ser atualizado depois de consultar esse endpoint com o Access Token e validar a correspondência com o pedido, moeda e valor esperados; não confiar apenas em `back_urls`, query string do retorno ou no JSON superficial do webhook. A própria documentação de Webhooks orienta recuperar o recurso completo no endpoint correspondente após confirmar a recepção. [4] [5]

Estados como `approved`, `pending` e outros devem ser tratados conforme o valor efetivamente retornado, incluindo `status_detail`; não declarar sucesso para um retorno HTTP recebido, para um redirect ou para uma notificação sem consulta.

### 3. Consultas auxiliares documentadas

- `GET https://api.mercadopago.com/checkout/preferences/{id}` consulta a preferência por ID. [9]
- `GET https://api.mercadopago.com/checkout/preferences/search` pesquisa preferências por filtros, como `external_reference`, `sponsor_id`, `site_id` e `marketplace`; a documentação limita a busca aos últimos 90 dias, portanto não usar essa pesquisa como histórico ilimitado. [9]

Essas rotas são leitura/diagnóstico. O foco de ativação continua sendo apenas criar a preferência e consultar o pagamento; não incluir rotas de reembolso, cancelamento ou captura sem decisão e autorização próprias.

## Idempotência e replay

### Criação de preferência

A página oficial consultada para `POST /checkout/preferences` mostra `Content-Type` e `Authorization`, mas **não documenta `X-Idempotency-Key` para a Preferences API**. Portanto, não afirmar que esse POST é idempotente no Mercado Pago nem reutilizar automaticamente a regra de Orders/Payments nele. Para o adaptador, o fluxo preparado deve ter sua própria chave lógica no banco — por exemplo, um pedido interno único — persistir o `preference.id` antes de devolver o link e, em timeout, procurar/reconciliar pela referência externa antes de tentar outra criação. Essa é uma salvaguarda do ERP, não uma garantia de idempotência do provedor. [3]

A documentação do Mercado Pago exige `X-Idempotency-Key` em outras operações de escrita, como criação de pagamentos da Payments API, e informa que a chave serve para evitar pagamentos duplicados. A página de erros documenta tamanho de 1 a 128 caracteres, conflito quando já usada e bloqueio temporário; esses fatos não devem ser extrapolados para o POST de preferência sem confirmação específica da rota. [8] [11]

### Webhook e reentrega

A notificação inclui um `id` próprio no corpo e `data.id` do recurso. Persistir uma chave de deduplicação antes do processamento, como `application_id + notification.id` e, como proteção adicional, `type + data.id + action`, evitando aplicar duas vezes a mesma transição. Validar assinatura antes de enfileirar efeitos. Responder `200` ou `201` em até 22 segundos e processar a consulta/atualização de forma assíncrona; sem confirmação, o Mercado Pago pode reenviar em intervalos de aproximadamente 15 minutos, com intervalo ampliado após falhas. [5]

A documentação oficial descreve `ts` e `v1` no `x-signature`, mas não publica nessa página uma janela temporal obrigatória para rejeitar replay. Assim, o adaptador não deve inventar um TTL oficial: deduplicar eventos, guardar `x-request-id`/identificador da notificação e aplicar uma política local de frescor somente como defesa adicional.

## Webhook: autenticidade realmente suportada

Configurar no painel da aplicação o evento **payment** e uma URL HTTPS. O Mercado Pago envia um POST com query params como `data.id` e `type`, corpo contendo `action`, `api_version`, `application_id`, `date_created`, `id`, `live_mode`, `type`, `user_id` e `data`, além dos headers `x-signature` e `x-request-id`. [5]

A proteção oficial é uma **assinatura secreta HMAC**. O Mercado Pago gera uma chave secreta por aplicação; ela não expira, mas a documentação recomenda rotação periódica. O SDK oficial fornece `WebhookSignatureValidator`, que recebe `x-signature`, `x-request-id`, `data.id` e o segredo. Em assinatura inválida, os exemplos oficiais respondem `401`; em assinatura válida, confirmar o recebimento com `200` ou `201`. [5]

Sugestão de rota própria, ainda não implementada: `POST /functions/v1/mercado-pago-webhook`. A função deve capturar a query original, headers e corpo, validar HMAC sem confiar no frontend, deduplicar, responder rapidamente e depois consultar `GET /v1/payments/{data.id}`. Não há, nas fontes consultadas, suporte oficial documentado para substituir a assinatura HMAC por uma allowlist de IP ou por um segredo inventado no payload.

## Erros, limites e observabilidade

Tratar `400` como requisição inválida — JSON, propriedades obrigatórias, tipos, valores, datas ou headers —, `401` como Access Token inválido, `403` como falta de permissão/escopo, `404` como recurso inexistente e `409` conforme o conflito da operação/idempotência. Em `429 usage_quota_exceeded`, ler `Retry-After` e aplicar backoff exponencial com jitter, como recomenda a documentação. Em `500`, registrar o `x-request-id` e não duplicar automaticamente uma operação sem preservar a chave/reconciliação adequada. [8]

A página de erros consultada não publica uma cota numérica universal; o adaptador deve tratar `Retry-After` como autoridade da resposta e manter logs sem Access Token, segredo HMAC, dados completos do pagador ou documentos. [8]

## Variáveis de ambiente sugeridas, sem valores

- `MERCADOPAGO_API_BASE_URL`
- `MERCADOPAGO_ACCESS_TOKEN`
- `MERCADOPAGO_WEBHOOK_SECRET`
- `MERCADOPAGO_WEBHOOK_URL`
- `MERCADOPAGO_ENV`
- `MERCADOPAGO_TEST_ACCESS_TOKEN` — se o ambiente quiser separar explicitamente teste e produção.
- `MERCADOPAGO_PROD_ACCESS_TOKEN` — somente quando produção for ativada e autorizada.
- `MERCADOPAGO_CLIENT_ID` — somente para OAuth.
- `MERCADOPAGO_CLIENT_SECRET` — somente para OAuth; nunca no frontend.
- `MERCADOPAGO_REDIRECT_URI` — somente para OAuth.

`MERCADOPAGO_PUBLIC_KEY` pode existir apenas se uma etapa futura realmente inicializar um SDK no navegador; ela não é necessária para a criação server-side da preferência nem para a consulta server-side do pagamento. Nenhuma variável acima contém valor neste documento.

## Pré-requisitos, lacunas e limitações desta preparação

- É necessária uma conta de vendedor e uma aplicação Mercado Pago. Credenciais de teste são criadas com a aplicação; credenciais de produção dependem de ativação, setor/site e aceite dos termos no painel. [1] [6] [10]
- É necessária configuração de Webhooks no painel, com URL HTTPS produtiva, evento `payment` e segredo HMAC. Isso não foi ativado nesta pesquisa.
- Não foram fornecidas credenciais e nenhum endpoint real foi chamado. Logo, não há preferência, pagamento, webhook recebido, aprovação, cotação ou prontidão operacional declarados.
- O suporte de `X-Idempotency-Key` para `POST /checkout/preferences` não foi encontrado na referência oficial visitada; documentou-se apenas a proteção de idempotência do próprio ERP e a regra oficial para endpoints que a exigem.
- A documentação visitada não define uma janela anti-replay em segundos para `x-signature`; deduplicação por evento e política local continuam necessárias.
- Os documentos oficiais consultados não publicam uma cota numérica universal de rate limit; respeitar `Retry-After` em `429`.
- A busca de preferências cobre somente 90 dias; guardar os IDs e referências no ERP e consultar a preferência por ID quando necessário. [9]

## Referências

[1]: https://www.mercadopago.com.br/developers/pt/docs/checkout-pro-preferences/overview "Visão geral do Checkout Pro via Preferences API"
[2]: https://www.mercadopago.com.br/developers/pt/docs/checkout-pro/create-payment-preference "Criar e configurar uma preferência de pagamento"
[3]: https://www.mercadopago.com.br/developers/pt/reference/online-payments/checkout-pro-preferences/create-preference/post "Referência de POST para criar preferência"
[4]: https://www.mercadopago.com.br/developers/pt/reference/online-payments/checkout-api-payments/get-payment/get "Referência de GET para consultar pagamento"
[5]: https://www.mercadopago.com.br/developers/pt/docs/checkout-pro-preferences/additional-content/notifications/webhooks "Webhooks do Checkout Pro"
[6]: https://www.mercadopago.com.br/developers/pt/docs/your-integrations/credentials "Credenciais do Mercado Pago"
[7]: https://www.mercadopago.com.br/developers/pt/docs/subscriptions/additional-content/security/oauth/creation "Obter Access Token via OAuth"
[8]: https://www.mercadopago.com.br/developers/pt/docs/checkout-api-orders/payment-management/integration-errors/api "Possíveis erros da API"
[9]: https://www.mercadopago.com.br/developers/pt/reference/online-payments/checkout-pro-preferences/search-preferences/get "Referência de busca e consulta de preferências"
[10]: https://www.mercadopago.com.br/developers/pt/docs/checkout-pro-orders/go-to-production?scope=prod "Subir em produção"
[11]: https://www.mercadopago.com.br/developers/pt/docs/checkout-api-payments/integration-configuration/other-payment-methods "Idempotência na criação de pagamentos"
