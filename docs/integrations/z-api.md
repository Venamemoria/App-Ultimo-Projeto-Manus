# Z-API — preparação documental do adaptador

Pesquisa consultada em 29/10/2026. O documento descreve somente o contrato publicado pela Z-API para um adaptador server-side de envio transacional de texto. Não houve login, ativação de instância, envio, compra, cotação ou chamada a endpoint real. Preparado não significa ativado.

## Escopo e fluxo confirmado

A Z-API se descreve como uma API REST para interagir com WhatsApp, usando instâncias e webhooks. O fluxo oficial de texto é assíncrono: a API recebe a mensagem, coloca-a em fila e retorna identificadores; a instância processa o envio; depois o webhook de delivery informa processamento com envio ou falha. O webhook de status informa mudanças posteriores como `RECEIVED` e `READ`. Portanto, o HTTP `200` do envio é confirmação de aceitação/resposta da API, não confirmação de entrega ao destinatário. [1] [2]

A própria introdução de webhooks esclarece que delivery significa entrega da mensagem ao WhatsApp e **não garante** que o contato a recebeu. O estado `RECEIVED` no webhook de status é a confirmação posterior documentada para recebimento; `READ` é leitura. [3] [4]

## Configuração server-side sugerida

Os nomes abaixo são apenas nomes de configuração, sem valores:

- `ZAPI_BASE_URL` — base fixa sugerida: `https://api.z-api.io`.
- `ZAPI_INSTANCE_ID` — ID da instância.
- `ZAPI_INSTANCE_TOKEN` — token da instância.
- `ZAPI_CLIENT_TOKEN` — token de segurança da conta, quando o recurso estiver ativado.
- `ZAPI_DELIVERY_WEBHOOK_URL` — URL HTTPS que receberá o callback de delivery.
- `ZAPI_MESSAGE_STATUS_WEBHOOK_URL` — URL HTTPS que receberá o callback de status.
- `ZAPI_WEBHOOK_INGRESS_SECRET` — somente se o ERP adotar um controle próprio de ingresso; **não** é uma assinatura ou header oficialmente documentado pela Z-API e não deve ser tratado como autenticação fornecida pelo provedor.

O ID e o token da instância compõem a URL e identificam a instância. A Z-API alerta que quem possui esses dados pode enviar mensagens em nome da instância e recomenda que as chamadas partam de servidor, nunca do frontend. Em Vite/React + Supabase, esses segredos ficam exclusivamente em Supabase Edge Functions/secrets; não entram no bundle. [5]

O `Client-Token` é o “Account Security Token”. A documentação descreve sua geração no painel, inicialmente desativada, e sua ativação posterior; depois de ativado, as instâncias da conta aceitam apenas requisições com o header `Client-Token`. Os exemplos oficiais usam também `Content-Type: application/json`. [6]

## Endpoint de envio de texto

**Base URL:** `https://api.z-api.io`.

**Rota:** `POST /instances/{instanceId}/token/{token}/send-text`. [7]

Headers publicados nos exemplos:

```http
Content-Type: application/json
Client-Token: <account-security-token>
```

O `Client-Token` deve ser enviado quando a validação do token de segurança da conta estiver ativada; a página de referência o trata como header de segurança das requisições. [6] [8]

Body mínimo documentado:

```json
{
  "phone": "5511999999999",
  "message": "Texto transacional"
}
```

`phone` e `message` são obrigatórios. `phone` aceita telefone do destinatário ou ID de grupo; deve ser enviado somente com dígitos, sem máscara, no formato DDI + DDD + número, por exemplo `5511999999999`. A Z-API documenta `message` como o texto a enviar. [7]

A página também lista opções de comportamento: `delayMessage`, em segundos, entre 1 e 15, com padrão de 1–3 segundos quando omitido; e `delayTyping`, em segundos, entre 1 e 15, com padrão 0. A mesma página lista edição de mensagem anterior por identificador, mas a extração textual da documentação não mostra com segurança o nome do atributo junto dessa descrição; esse recurso não deve ser incluído no adaptador sem confirmação específica. [7]

Resposta `200` publicada:

```json
{
  "zaapId": "...",
  "messageId": "...",
  "id": "..."
}
```

`zaapId` é o identificador na Z-API; `messageId` é o identificador no WhatsApp; `id` existe para compatibilidade com Zapier e tem o mesmo valor de `messageId`. Esses IDs identificam a mensagem aceita/processada pela API, mas não substituem os callbacks de delivery/status. [7]

## Configuração dos webhooks

A configuração é feita pela API ou pelo painel. As rotas de configuração abaixo são chamadas administrativas do ERP para a Z-API e exigem a mesma autenticação por instância e `Client-Token` aplicável:

- `PUT /instances/{instanceId}/token/{token}/update-webhook-delivery`
- `PUT /instances/{instanceId}/token/{token}/update-webhook-message-status`

Body obrigatório de cada rota:

```json
{
  "value": "https://endereco-do-erp.example/webhook"
}
```

A Z-API não aceita URL de webhook que não seja HTTPS. A resposta `200` publicada para a configuração é `{ "value": true }`; isso confirma a atualização da configuração, não a entrega futura de eventos. [9] [4]

A instância faz requisições `POST` aos URLs configurados, com JSON específico para cada evento. [3]

### Delivery (`DeliveryCallback`)

O callback de delivery documenta os campos `phone`, `zaapId`, `messageId`, `instanceId`, `momment` e `type`; `type` será `DeliveryCallback`. `momment` é o nome publicado pela Z-API e representa timestamp em milissegundos. `error` aparece somente em casos de erro e contém a descrição do problema de envio. [9]

Exemplo de forma publicada, sem tratar os valores como reais:

```json
{
  "phone": "554499999999",
  "zaapId": "...",
  "messageId": "...",
  "instanceId": "...",
  "momment": 1777494009341,
  "type": "DeliveryCallback"
}
```

### Status (`MessageStatusCallback`)

O callback de status documenta `instanceId`, `status`, `ids`, `momment`, `phoneDevice`, `phone`, `type` e `isGroup`. Os estados publicados são `SENT`, `RECEIVED`, `READ`, `READ_BY_ME` e `PLAYED`. `phoneDevice` é documentado como tipo de dispositivo, com `0` para celular; `isGroup` indica se o chat é grupo; `type` será `MessageStatusCallback`. [4]

Exemplo de forma publicada:

```json
{
  "instanceId": "instance.id",
  "status": "SENT",
  "ids": ["999999999999999999999"],
  "momment": 1632234645000,
  "phoneDevice": 0,
  "phone": "5544999999999",
  "type": "MessageStatusCallback",
  "isGroup": false
}
```

## Autenticidade, replay e idempotência

O mecanismo de autenticidade de webhook oficialmente verificável nas páginas consultadas é a exigência de URL HTTPS. Não foi encontrada documentação de assinatura HMAC, header `X-Signature`, segredo compartilhado, mTLS, `Idempotency-Key`, nonce ou endpoint de verificação para callbacks. O `Client-Token` documentado autentica chamadas do ERP **para a Z-API**; as páginas de callbacks não dizem que ele será enviado nas chamadas da Z-API **para o ERP**. Não inventar uma validação por assinatura nem considerar o payload autêntico apenas por conter `instanceId`.

Também não foi encontrada política oficial de retries, ordem, janela de replay ou garantia de entrega única dos webhooks. A camada do ERP deve manter outbox e estado de entrega próprios, registrar os IDs retornados (`zaapId`/`messageId`), deduplicar eventos repetidos por uma chave local baseada no evento e identificador/status, e separar “aceito pela API”, “delivery”, `RECEIVED` e `READ`. Em caso de timeout após um `POST` de envio, um retry automático pode duplicar a mensagem; a Z-API não documenta idempotência do envio, portanto o adaptador não deve prometer exatamente-uma-vez.

Se o ERP adotar uma URL de ingresso com segredo próprio, isso será defesa da aplicação, não recurso de autenticação oficial da Z-API. A URL continuará precisando ser HTTPS e o desenho não deve alegar assinatura do provedor.

## Erros, limites e tratamento conservador

A documentação de `send-text` publica `405` para método HTTP incorreto e `415` quando falta `Content-Type: application/json`. O callback de delivery publica `error` apenas quando há falha de envio, mas as páginas consultadas não fornecem uma política geral de classificação ou retry. [9] [13] [14]

Não foi localizada documentação oficial de `429`, janela de rate limit, cabeçalho `Retry-After`, backoff ou limite numérico por instância. A introdução afirma “não temos limite” de quantidade de mensagens, enquanto o guia oficial de boas práticas recomenda intervalos entre mensagens, parte de um mínimo de 5 minutos, limitação gradual de volume e uso natural do número. Isso não é um SLA de throughput: o guia também alerta para risco de bloqueios/restrições, e a Z-API opera sobre sessão do WhatsApp Web. [1] [10]

Assim, não tratar “sem limite” como autorização para disparo em massa. Sem código de erro documentado, o adaptador deve preservar o evento de falha, evitar retry cego, aplicar backoff somente como política local após classificação segura e deixar a repetição sob controle explícito. Bloqueios, shadowban, rejeição pelo WhatsApp, estado desconectado e falha de rede continuam possíveis; a própria documentação de boas práticas diz que não existe configuração que garanta proteção total. [10] [11]

A restrição por IP é uma opção de segurança publicada para limitar os IPs que chamam a API. A documentação não confirma a compatibilidade de uma lista fixa de IPs com a saída de Supabase Edge Functions; qualquer ativação exigiria validação específica da infraestrutura e aprovação, sem testar contra a conta real nesta pesquisa. [12]

## O que exige credenciais, painel ou aprovação

Para uso real, é necessário ter conta Z-API, instância criada, ID/token da instância e número WhatsApp conectado à instância; esses dados ficam no painel. [5] [15] Ativar o Account Security Token exige acesso ao painel e configuração coordenada dos clientes. Configurar os webhooks exige URL HTTPS pública e credenciais da instância. O envio exige todas essas credenciais e autorização operacional do proprietário do número. Nada disso foi executado aqui; o ERP deve permanecer indisponível/desabilitado enquanto os segredos e a autorização não existirem.

## References

[1]: https://developer.z-api.io/ "Z-API Docs: Introdução"
[2]: https://developer.z-api.io/en/quickstart/introduction "Z-API Documentation: Introduction"
[3]: https://developer.z-api.io/en/webhooks/introduction "Z-API Webhooks: Introduction"
[4]: https://developer.z-api.io/webhooks/on-whatsapp-message-status-changes "Z-API Webhooks: Status da mensagem"
[5]: https://developer.z-api.io/en/security/introduction "Z-API Security: ID and Token"
[6]: https://developer.z-api.io/en/security/client-token "Z-API Security: Account Security Token"
[7]: https://developer.z-api.io/message/send-text "Z-API Messages: Enviar texto simples"
[8]: https://developer.z-api.io/en/api-reference/introduction "Z-API API Reference: Introduction"
[9]: https://developer.z-api.io/webhooks/on-message-send "Z-API Webhooks: Ao enviar"
[10]: https://developer.z-api.io/tips/best-practices "Z-API Tips: Guia de Boas Práticas para Uso do WhatsApp via API"
[11]: https://developer.z-api.io/tips/blockednumbernew "Z-API Tips: Bloqueios e Banimentos (2026)"
[12]: https://developer.z-api.io/en/security/ip-block "Z-API Security: IP Request Restriction"
[13]: https://developer.z-api.io/en/message/send-text "Z-API Messages: Send plain text"
[14]: https://developer.z-api.io/en/webhooks/on-message-send "Z-API Webhooks: On send"
[15]: https://developer.z-api.io/en/instance/introduction "Z-API Instance: Introduction"
