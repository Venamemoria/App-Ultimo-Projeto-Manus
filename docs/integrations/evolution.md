# Evolution API v2 — pesquisa documental para adaptador

**Escopo:** somente Evolution API v2, para ser chamada server-side por uma Supabase Edge Function. Esta pesquisa não ativou conta, não usou credenciais, não chamou envio, não criou instância e não declarou integração pronta.

## Base, deployment e pré-requisitos

A documentação pública usa `http://localhost:8080` como base de exemplo para uma instalação própria. Em produção, a base do adaptador deve ser a URL pública do deployment Evolution API, com `SERVER_URL` configurada para essa URL; não foi confirmada nesta pesquisa uma base SaaS pública que possa ser usada sem contrato/credenciais. As rotas abaixo são relativas à base. [1] [2]

O deployment é um serviço separado do Supabase Edge Functions. A referência oficial atual exige Node.js 20+, PostgreSQL ou MySQL e recomenda Redis; a instalação Docker também pressupõe banco e Redis, com a API escutando normalmente na porta 8080. Deve haver persistência do diretório de instâncias/credenciais e HTTPS por proxy reverso antes de expor webhooks ou o endpoint de mensagens. [1] [3] [4]

Desde a Evolution API 2.4.0, a documentação oficial informa que a ativação gratuita da licença é exigida no primeiro acesso. Sem ativação, a release 2.4.0 informa `503`/`LICENSE_REQUIRED` para o tráfego de negócio e deixa rotas de recuperação/manager públicas. A licença `community` é apresentada como gratuita, sem assinatura ou limite de mensagens/instâncias; o registro pode exigir operador identificado por e-mail (e a página de licenciamento informa também telefone). Versões anteriores à 2.4.0 não têm essa exigência, conforme a própria documentação. O servidor de licenciamento não é o mesmo que autenticação do endpoint de WhatsApp. [5] [6]

A conexão WhatsApp precisa existir e estar utilizável antes de um envio: a Evolution API documenta o canal Baileys, baseado no WhatsApp Web e conectado por QR Code, e o WhatsApp Cloud API oficial da Meta. O adaptador não deve confundir uma resposta HTTP aceita com mensagem entregue ao destinatário. [1] [7]

## Autenticação e variáveis sem valores

A autenticação REST usa o header `apikey`. A documentação descreve chave global ou específica da instância; a configuração self-hosted define a chave global em `AUTHENTICATION_API_KEY`. A chave não deve entrar no bundle Vite, ser armazenada em tabela acessível ao cliente ou ser logada. [1] [2]

Nomes sugeridos para secrets/configuração do adaptador (sem valores):

- `EVOLUTION_API_BASE_URL`
- `EVOLUTION_API_INSTANCE`
- `EVOLUTION_API_APIKEY`
- `EVOLUTION_API_ENABLED`
- `EVOLUTION_API_WEBHOOK_URL`
- `EVOLUTION_API_WEBHOOK_JWT_KEY`
- `EVOLUTION_API_REQUEST_TIMEOUT_MS`
- `EVOLUTION_API_RETRY_MAX_ATTEMPTS`
- `EVOLUTION_API_WEBHOOK_EVENT_SECRET`

Nomes nativos relevantes da instalação Evolution API, também sem valores: `SERVER_URL`, `SERVER_PORT`, `AUTHENTICATION_API_KEY`, `DATABASE_PROVIDER`, `DATABASE_CONNECTION_URI`, `DATABASE_CONNECTION_CLIENT_NAME`, `CACHE_REDIS_ENABLED`, `CACHE_REDIS_URI`, `WEBHOOK_GLOBAL_ENABLED`, `WEBHOOK_GLOBAL_URL`, `WEBHOOK_GLOBAL_WEBHOOK_BY_EVENTS`, `WEBHOOK_EVENTS_MESSAGES_UPDATE`, `WEBHOOK_EVENTS_SEND_MESSAGE`, `WEBHOOK_EVENTS_SEND_MESSAGE_UPDATE`, `WEBHOOK_REQUEST_TIMEOUT_MS`, `WEBHOOK_RETRY_MAX_ATTEMPTS`, `WEBHOOK_RETRY_INITIAL_DELAY_SECONDS`, `WEBHOOK_RETRY_USE_EXPONENTIAL_BACKOFF`, `WEBHOOK_RETRY_MAX_DELAY_SECONDS`, `WEBHOOK_RETRY_JITTER_FACTOR` e `WEBHOOK_RETRY_NON_RETRYABLE_STATUS_CODES`. Os últimos parâmetros aparecem no `.env.example` oficial atual; o adaptador deve tratá-los como configuração da instalação, não como secrets do frontend. [2] [8]

## Envio de texto

**Rota documentada:** `POST /message/sendText/{instanceName}`.

**Headers:** `Content-Type: application/json` e `apikey: <api-key>`. `instanceName` é obrigatório no caminho e identifica a sessão WhatsApp. [9]

A página oficial de referência publica este corpo:

```json
{
  "number": "<destinatário>",
  "textMessage": { "text": "<texto>" },
  "delay": 123,
  "quoted": {},
  "linkPreview": true,
  "mentioned": ["<número>" ]
}
```

`number` e o texto são os dados essenciais; `delay` é inteiro em milissegundos e os demais campos são opções de citação, prévia de link e menções. A resposta de sucesso exemplificada contém `key`, `message` e `status`; o router atual do repositório responde HTTP 201. [9] [10]

Há uma divergência que precisa ser tratada como bloqueio de compatibilidade, não como detalhe cosmético: a página pública atual mostra `textMessage.text`, enquanto o schema de validação no branch oficial `main` exige `number` e `text` no nível superior e o router passa esse objeto diretamente ao controller. Sem fixar a versão da imagem e validar em ambiente autorizado, não se deve afirmar qual forma prevalece em uma instalação específica. O adaptador deve manter um contrato de versão explícito e não alternar silenciosamente o payload. [10] [11]

Não há campo `Idempotency-Key`, nem garantia de idempotência, nem mecanismo de deduplicação documentado para `sendText`. Uma nova tentativa de um `POST` depois de timeout pode duplicar a mensagem. A fila/outbox do ERP deve registrar uma chave própria antes de enviar, persistir a resposta e só repetir com decisão controlada; nunca fazer retry cego desse POST.

## Instância e estado do canal

Rotas de suporte documentadas para preparar/inspecionar a sessão:

- `POST /instance/create`: cria instância; o corpo público inclui `instanceName`, `qrcode`, `integration`, `token`, `number` e configuração opcional de `webhook`. Exige `apikey` e JSON. A própria resposta de exemplo pode estar em `connecting`, portanto criação não é conexão pronta. [12]
- `GET /instance/connectionState/{instanceName}`: consulta o estado da conexão, com `apikey`; o exemplo retorna `instance.state`, como `close`. [13]
- `POST /webhook/set/{instanceName}`: configura webhook por instância. [14]
- `GET /webhook/find/{instanceName}`: lê a configuração ativa do webhook. [15]

Essas rotas são administrativas e exigem credencial Evolution. A preparação da Edge Function não deve criá-las, alterá-las ou “simular” seus resultados sem autorização e ambiente próprios.

## Webhooks e status de entrega

Há duas modalidades: webhook global por `.env` e webhook por instância. No endpoint por instância, a referência atual documenta `POST /webhook/set/{instanceName}` com `enabled` e `url` obrigatórios, além de `events`, `headers` e `base64`; a resposta de sucesso é apenas uma confirmação de configuração. [14] A configuração `webhook_by_events` acrescenta o nome do evento em kebab-case ao final da URL, por exemplo `/messages-update`. [16]

Para acompanhar um envio, os eventos relevantes são `SEND_MESSAGE`, `SEND_MESSAGE_UPDATE` e `MESSAGES_UPDATE`; `CONNECTION_UPDATE` informa o canal e `MESSAGES_UPSERT` é voltado à chegada de mensagens. A documentação define `MESSAGES_UPDATE` apenas como mensagem atualizada. O código oficial também registra status inteiro no banco e mantém esses eventos no catálogo, mas não foi localizada uma rota pública estável que consulte o estado final de entrega por `messageId`, nem um contrato oficial que mapeie, para cada versão/canal, estados como enviado, entregue, lido e falhou. Portanto, o `status` da resposta do `sendText` é assíncrono/inicial até prova em contrário; estados internos só devem ser atualizados por eventos recebidos e armazenados com versão do payload. [16] [17] [18]

O envelope efetivamente montado pelo controller oficial inclui `event`, `instance`, `data`, `destination`, `date_time`, `sender`, `server_url` e `apikey`. A presença de `apikey` no corpo torna obrigatório redigir esse campo de logs e limitar o conteúdo armazenado. [19]

## Autenticidade do webhook: suporte real

O suporte real não é um HMAC genérico documentado para todos os webhooks. O endpoint de configuração aceita `headers` estáticos por instância. No controller oficial, se os headers locais contiverem `jwt_key`, a Evolution API gera um JWT HS256 com `iat`, expiração de 10 minutos, `app: evolution` e `action: webhook`, envia-o como `Authorization: Bearer ...` e remove `jwt_key` antes da requisição. Essa lógica é local/por instância; o caminho de webhook global mostrado no mesmo controller não aplica esses headers nem esse JWT. [14] [19]

Logo, o receptor Supabase deve exigir HTTPS e, para webhook local, verificar o Bearer JWT com o mesmo segredo mantido fora do cliente. Se a instalação não usar `jwt_key`, um header secreto estático é somente autenticação por posse e não prova integridade nem frescor. A pesquisa não encontrou, na documentação pública de eventos ou no controller atual, assinatura HMAC `X-Signature`, timestamp/nonce ou assinatura automática equivalente para o webhook comum. O HMAC `X-Signature` documentado em licenciamento pertence às chamadas do servidor de ativação, não aos eventos de WhatsApp. [6] [19]

O receiver deve ser idempotente: o código Evolution repete entregas quando necessário e não foi documentado um identificador de entrega único. Deduplique por uma chave interna composta, no mínimo, de instância, evento e identificador da mensagem em `data`, mantendo hash/payload bruto apenas conforme a política de dados do ERP. Responda rapidamente com 2xx depois de persistir o evento; não faça processamento longo na mesma requisição.

## Retries, erros e rate limit

O `.env.example` atual configura timeout de webhook de 60.000 ms, até 10 tentativas, atraso inicial de 5 s, backoff exponencial, teto de 300 s, jitter de 20% e códigos não reprocessáveis `400,401,403,404,422`. O controller confirma essa política e repete falhas/timeout que não estejam nessa lista; `429` não aparece entre os não reprocessáveis. [2] [19]

A referência de `sendText` exemplifica `400 BAD_REQUEST`, `401 UNAUTHORIZED`, `403 FORBIDDEN`, `404 NOT_FOUND` e `500 INTERNAL_SERVER_ERROR`; `503 LICENSE_REQUIRED` é relevante em versões 2.4.0+ não ativadas. O ERP deve guardar status HTTP e corpo sanitizado, separar falha permanente de transitória e não converter erro em sucesso. [9] [5]

Não há quota pública atual nem contrato de `Retry-After` encontrado na documentação. Há issue oficial relatando `429` sob rajadas, mas a issue é da versão 1.8.1 e não define limite por instância/end point; ela não deve ser usada como SLA. Para a integração preparada, tratar `429`, timeout e 5xx como transitórios com backoff limitado, sem repetir automaticamente `sendText` sem idempotência própria. [20]

## Limitações e decisões pendentes

- É necessário fixar a imagem/versão Evolution API antes de congelar o adaptador, porque a documentação pública e o schema atual divergem no corpo de `sendText` e a nomenclatura de webhook aparece em camelCase e snake_case em páginas distintas. [9] [10] [16]
- Não foi confirmada uma rota oficial de consulta de entrega nem um mapeamento estável de todos os estados; `MESSAGES_UPDATE`/`SEND_MESSAGE_UPDATE` devem ser tratados como eventos assíncronos, não como confirmação de entrega.
- Não há idempotência nativa documentada para o POST de envio.
- A autenticidade automática de eventos comuns é limitada a headers configuráveis e ao JWT local por `jwt_key`; não declarar HMAC genérico, IP allowlist ou replay protection como recurso nativo.
- Ativação gratuita da licença em 2.4.0+ exige fluxo de conta/operador, mesmo sem assinatura paga; conexão WhatsApp, credencial `apikey`, instância e autorização do responsável ainda são pré-requisitos reais. Nada disso foi fornecido ou operado nesta pesquisa.
- Supabase Edge Functions pode funcionar como adaptador server-side, mas não substitui o runtime Evolution API, seu banco/Redis, armazenamento de sessão, conexão WhatsApp ou fluxo de licença.

## References

[1]: https://github.com/evolution-foundation/evolution-api "Repositório oficial da Evolution API"
[2]: https://raw.githubusercontent.com/evolution-foundation/evolution-api/main/.env.example "Variáveis de ambiente oficiais"
[3]: https://docs.evolutionfoundation.com.br/en/evolution-api/requirements/database "Requisitos oficiais de banco de dados"
[4]: https://docs.evolutionfoundation.com.br/en/evolution-api/install/docker "Instalação oficial com Docker"
[5]: https://docs.evolutionfoundation.com.br/licensing "Licenciamento oficial da Evolution Foundation"
[6]: https://docs.evolutionfoundation.com.br/licensing/activation "Fluxo oficial de ativação e HMAC do licenciamento"
[7]: https://docs.evolutionfoundation.com.br/en/evolution-api "Visão geral oficial da Evolution API"
[8]: https://docs.evolutionfoundation.com.br/evolution-api/configuration/env "Variáveis oficiais da Evolution API em português"
[9]: https://docs.evolutionfoundation.com.br/en/evolution-api/send-text-message "Referência oficial de envio de texto"
[10]: https://raw.githubusercontent.com/evolution-foundation/evolution-api/main/src/api/routes/sendMessage.router.ts "Router oficial de mensagens"
[11]: https://raw.githubusercontent.com/evolution-foundation/evolution-api/main/src/validate/message.schema.ts "Schema oficial de validação de mensagens"
[12]: https://docs.evolutionfoundation.com.br/en/evolution-api/create-instance "Referência oficial de criação de instância"
[13]: https://docs.evolutionfoundation.com.br/en/evolution-api/get-connection-state "Referência oficial do estado de conexão"
[14]: https://docs.evolutionfoundation.com.br/en/evolution-api/set-webhook "Referência oficial de configuração de webhook"
[15]: https://docs.evolutionfoundation.com.br/en/evolution-api/get-webhook "Referência oficial de consulta de webhook"
[16]: https://docs.evolutionfoundation.com.br/evolution-api/configuration/webhooks.md "Documentação oficial de eventos de webhook"
[17]: https://raw.githubusercontent.com/evolution-foundation/evolution-api/main/src/api/integrations/event/event.controller.ts "Catálogo oficial de eventos"
[18]: https://raw.githubusercontent.com/evolution-foundation/evolution-api/main/prisma/postgresql-migrations/20241001180457_add_message_status/migration.sql "Migration oficial de status de mensagem"
[19]: https://raw.githubusercontent.com/evolution-foundation/evolution-api/main/src/api/integrations/event/webhook/webhook.controller.ts "Controller oficial de webhook, JWT e retry"
[20]: https://github.com/evolution-foundation/evolution-api/issues/691 "Issue oficial sobre resposta 429 sob rajadas"
