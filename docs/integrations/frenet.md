# Frenet — cotação de frete e adaptador

Pesquisa somente em documentação oficial Frenet, sem usar credenciais e sem chamar endpoints de cadastro, cotação, envio ou compra. O documento descreve preparação de contrato para uma Edge Function Supabase; estar documentado não significa integração ativada.

## Conclusão operacional

A Frenet publica duas famílias de cotação que não devem ser misturadas:

- **Shipping API clássica:** `POST https://api.frenet.com.br/shipping/quote`, autenticada apenas pelo header `token` do cliente. A especificação também lista o host HTTP, mas o adaptador deve considerar somente HTTPS. [1]
- **Orders/Whitelabel:** `POST https://whitelabel.frenet.com.br/v1/quotes`, autenticada por `token` do cliente e `x-partner-token` do parceiro. [2]

As duas rotas retornam cotações de transportadoras e têm nomes de campos, requisitos e formatos de resposta diferentes. O ERP precisa selecionar uma família por configuração da conta/parceria, sem fazer fallback silencioso entre elas.

## Rotas, métodos e headers

1. **Cotação clássica:** `POST https://api.frenet.com.br/shipping/quote`.
   Headers documentados: `token: <token do cliente>`, `Content-Type: application/json`; `Accept: application/json` aparece no exemplo da documentação. [1] [12]
2. **Serviços vinculados ao token clássico:** `GET https://api.frenet.com.br/shipping/info`, com `token` obrigatório. Retorna `ShippingSeviceAvailableArray` com `ServiceCode`, `ServiceDescription`, `Carrier` e `CarrierCode`. [3]
3. **Cotação Whitelabel:** `POST https://whitelabel.frenet.com.br/v1/quotes`, com `token` e `x-partner-token` obrigatórios, além de `Content-Type: application/json` e `Accept: application/json`. [2]
4. **Cadastro de cliente para onboarding:** `POST https://register.apifrenet.com.br/v1/partner/register`, com `x-partner-token` obrigatório. A operação retorna `Success` e, quando criada com sucesso, `Token`; a própria Frenet diz que o cadastro também pode ser feito diretamente no painel, portanto esta rota não é necessária para uma integração que já recebeu o token. [4]
5. **Serviços Whitelabel:** `GET https://whitelabel-configuration.frenet.com.br/v1/carriers/services` é publicado na referência atual, mas a página aberta não expõe schema de autenticação nem exemplo de resposta. Não assumir headers ou formato além do que a Frenet confirmar. [5]

As referências atuais também listam o `llms.txt` como índice canônico e mostram que existem APIs separadas para pedidos, etiquetas, carteira e tracking. Elas não fazem parte desta preparação de cotação. [6]

## Contrato da cotação clássica (`/shipping/quote`)

Body JSON com campos obrigatórios `SellerCEP` (CEP de origem, string), `RecipientCEP` (CEP de destino, string) e `ShipmentInvoiceValue` (valor total do pedido, número). `RecipientCountry`, `ShippingServiceCode`, `Coupom` (grafia exata publicada) e `ShippingItemArray` são opcionais no schema. [1]

Cada item de `ShippingItemArray` deve conter `Weight` em **kg**, `Length`, `Height` e `Width` em **cm**, e `Quantity`. `SKU`, `Category`, `isFragile` e `Diameter` são opcionais; a documentação descreve `Diameter` como “em cm³”, unidade inconsistente para diâmetro, portanto não se deve normalizar esse campo sem confirmação da Frenet. CEPs devem ser tratados como strings de oito dígitos, preservando zeros à esquerda. [1]

A resposta `200` tem `ShippingSevicesArray` — grafia publicada com `Sevices` — e `Timeout`. Cada serviço pode conter `Carrier`, `CarrierCode`, `DeliveryTime`, `Msg`, `ServiceCode`, `ServiceDescription`, `ShippingPrice`, `OriginalDeliveryTime`, `OriginalShippingPrice` e `Error`. A OpenAPI declara vários preços como string; o adaptador deve preservar o valor bruto e converter somente com regra decimal definida. [1]

A documentação legada exibe um exemplo de serviço Correios/Sedex com preço, prazo, preços original e calculado e `Error: false`; é exemplo da documentação, não resposta de uma chamada feita para este trabalho. [12]

## Contrato da cotação Whitelabel (`/v1/quotes`)

O body obrigatório contém `SenderZipCode`, `RecipientZipCode`, `RecipientCountry`, `ShipmentItemValue` e `Volumes`. Os CEPs são strings; `RecipientCountry` é país de destino; `ShipmentItemValue` é valor do item enviado. Cada volume exige `Weight` em **kg**; `Length`, `Height` e `Width` são dimensões em **cm** e `IsFragile` é booleano. A especificação marca somente `Weight` como obrigatório dentro do volume, embora o exemplo mostre dimensões com zero; não tratar zero como dimensão válida sem confirmação, pois a própria API possui erro para dimensões inválidas. [2]

`Services` é opcional e pode conter `DeclaredValue`, `ReceiptNotification` e `OwnHand`, todos booleanos. A especificação declara propriedades em PascalCase (`SenderZipCode`, `Volumes`, `Weight`), mas o exemplo usa mistura de camelCase/minúsculas (`senderZipCode`, `volumes`, `weight`). Essa inconsistência é uma lacuna de contrato: validar com a Frenet/homologação qual capitalização é aceita, sem escolher silenciosamente uma variante. [2]

A resposta `200` contém `SessionId` e `Quotations`. Cada cotação pode ter `Carrier`, `CarrierCode`, `ShippingServiceCode`, `ShippingServiceName`, `PlatformShippingPrice`, `ShippingPrice`, `ShippingCompetitorPrice`, `DeliveryTime`, `Services`, `Error` e `Msg`. `DeliveryTime` é prazo em dias; `ShippingPrice` considera o contrato Frenet; `PlatformShippingPrice` é o valor exibido pela plataforma. O exemplo oficial mostra cotações de Jadlog e Correios com preços e prazos, mas é somente exemplo documentacional, não resultado ao vivo. [2]

## Erros, timeout e credenciais

Na rota Whitelabel, erros HTTP documentados são `400` (erro de negócio), `401` (não autorizado) e `500` (erro interno), com body `{ "Message": string, "Details": [{ "Code": integer, "Message": string }] }`. Entre os códigos relevantes para cotação estão `401` token inválido, `403` sem permissão, `1000` sessão inválida, `1001`/`1002` CEP inválido, `1003` lista de volumes inválida, `1004` peso inválido, `1005` nenhuma cotação retornada, `1999` erro ao processar, `2020` dimensões inválidas, `2021` peso do volume inválido, `2022` valor de frete inválido e `4000` problema de comunicação com a transportadora. `3000` significa saldo insuficiente e é relevante para operações de etiqueta; não tratar isso como cotação disponível. [2]

A rota clássica documenta a resposta `200`, o campo de serviço `Error`/`Msg` e o campo top-level `Timeout`, mas não publica um schema completo de respostas não-`2xx`. Erros HTTP fora do contrato publicado devem ser tratados como falha, nunca como cotação vazia ou sucesso. [1]

Para o onboarding, `Name` e `Email` são obrigatórios; `x-partner-token` é obrigatório; vários identificadores de plataforma/plano e alguns dados precisam ser fornecidos pela equipe de integração. A resposta pode retornar `Fields` com campos ausentes e um token de autenticação. [4] O token também pode ser obtido no painel Frenet em “Dados cadastrais”; ele é segredo server-side, nunca variável Vite pública. [7]

A Frenet exige contato com Parcerias e, para testes, cadastro/validação de e-mail e celular e solicitação de liberação de limite, etiquetas e créditos. [8] Há uma ressalva importante: uma FAQ oficial diz que não há ambiente de homologação geral, embora possa liberar contas para testes; a checklist atual publica `cadastro-hml.apifrenet.com.br`, e o processo de homologação diz que a validação assistida ocorre em produção. Não assumir sandbox isolado: confirmar o fluxo e a conta com a Frenet antes de qualquer teste. [9] [8] [10]

## Webhook aplicável e autenticidade

Não há webhook de cotação documentado. Os webhooks oficiais aplicáveis ao ciclo de envio são:

- **Atualização de dados de pedidos:** POST JSON quando muda o status do pedido. O payload inclui `OrderId`, `ShipmentId`, `ShipmentStatus`, `Volume` e `Balance`; no volume, altura/largura/comprimento são **cm**, peso é **kg** e preço é **R$**. Os status documentados são `5` Postado e `7` Cancelado. [11]
- **Atualização de tracking:** POST JSON quando ocorre evento de rastreamento. Inclui `OrderId`, `ShipmentId`, `TrackingUrl`, `TrackingNumber` e `TrackingEvents`; somente o último evento é enviado, com data `dd/MM/yyyy HH:mm`, local, descrição e código de evento. [13]

Ambos exigem resposta HTTP `2xx` em no máximo 10 segundos; redirecionamentos `3xx` não são seguidos e são considerados falha. A Frenet permite configurar um par `TOKEN_NAME`/`TOKEN_VALUE`, enviado como header escolhido, mas diz expressamente que ambos são opcionais e que o webhook funciona sem eles. As páginas não documentam assinatura HMAC, timestamp, assinatura assimétrica, ID de evento, sequência, política de retry ou replay protection. Portanto, a única autenticidade oficialmente suportada nesta documentação é o header secreto configurável; o receptor deve exigir HTTPS, validar o nome/valor configurado e manter deduplicação interna por evento/pedido, sem alegar que isso seja uma garantia da Frenet. [11] [13]

## Idempotência, replay, rate limit e limites

As referências de cotação não documentam `Idempotency-Key`, chave de requisição, garantia de idempotência, janela de replay, política de retry, `429` ou número de requisições por minuto. Também não há rate limit publicado nas páginas oficiais consultadas. Não considerar uma repetição automaticamente segura e não interpretar ausência de preço como sucesso; a política de retry, backoff, limites e eventual deduplicação deve ser confirmada com o suporte parceiro. O único limite operacional explicitamente encontrado para webhook é responder em até 10 segundos; a homologação também depende de limite/etiquetas/créditos liberados pela Frenet. [2] [8] [11] [13]

## Nomes de ambiente sugeridos, sem valores

- `FRENET_CLASSIC_API_BASE_URL`
- `FRENET_WHITELABEL_API_BASE_URL`
- `FRENET_CLIENT_TOKEN`
- `FRENET_PARTNER_TOKEN`
- `FRENET_WEBHOOK_TOKEN_NAME`
- `FRENET_WEBHOOK_TOKEN_VALUE`

Esses nomes são convenções do adaptador, não nomes exigidos pela Frenet. Todos os tokens ficam somente na Edge Function/Supabase Secrets. Não há motivo para armazenar credenciais no bundle Vite.

## Limitações e pré-condições

- Nenhuma conta, token, assinatura, chamada real, cotação, compra ou emissão foi executada; exemplos documentais não são evidência de sucesso ao vivo.
- A cotação clássica e a Whitelabel exigem credenciais diferentes e têm contratos divergentes; a rota selecionada precisa ser autorizada pela parceria/conta Frenet.
- O host de produção, headers e schema da cotação estão documentados; rate limit, idempotência, replay, retry e erros `429` não estão.
- O webhook documentado cobre pedidos/tracking, não cotação. Seu header opcional não equivale a assinatura criptográfica.
- O cadastro Whitelabel, a homologação, o limite de testes, créditos e etiquetas exigem conta e aprovação/liberação da Frenet. “Preparado” não significa “ativado”.

## Referências

[1]: https://docs.frenet.com.br/reference/calculateshippingquote.md "Calcular frete — Frenet API Shipping"
[2]: https://docs.frenet.com.br/reference/getshipmentquoteasync.md "Cotar envio — Frenet Orders Integration API"
[3]: https://docs.frenet.com.br/reference/getshippinginfo.md "Obter serviços de frete disponíveis — Frenet API Shipping"
[4]: https://docs.frenet.com.br/reference/cadastrar-um-novo-cliente.md "Cadastrar um novo cliente — Frenet API"
[5]: https://docs.frenet.com.br/reference/getservices "Consultar lista de serviços disponíveis — Frenet Whitelabel"
[6]: https://docs.frenet.com.br/llms.txt "Índice da documentação oficial Frenet"
[7]: https://ajuda.frenet.com.br/knowledge-base/api-frenet/ "Saiba como conseguir acesso à API Frenet"
[8]: https://docs.frenet.com.br/docs/pr%C3%A9-requisitos-checklist-para-integra%C3%A7%C3%A3o "Pré-requisitos para integração"
[9]: https://ajuda.frenet.com.br/knowledge-base/a-frenet-possui-uma-ambiente-de-homologacao/ "A Frenet possui um ambiente de homologação?"
[10]: https://docs.frenet.com.br/docs/processo-de-homologa%C3%A7%C3%A3o "Processo de Homologação"
[11]: https://docs.frenet.com.br/docs/webhook-atualiza%C3%A7%C3%A3o-de-dados-de-pedidos.md "Webhook — Atualização de Dados de Pedidos"
[12]: https://frenetapi.docs.apiary.io/reference/shipping/shippingquote/post "Shipping quote — documentação Frenet"
[13]: https://docs.frenet.com.br/docs/webhook-atualiza%C3%A7%C3%A3o-de-tracking.md "Webhook — Atualização de Tracking"
