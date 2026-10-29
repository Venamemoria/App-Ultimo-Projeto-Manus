# Adaptador Mercado Livre — pesquisa de documentação

**Escopo:** preparação documental para um ERP Vite/React/Tailwind com Supabase Edge Functions. Esta pesquisa não ativou aplicativo, não usou credenciais, não chamou endpoints de produção e não executou envio, compra ou cotação. A integração deve ficar server-side; o bundle Vite não deve receber `client_secret`, access token ou refresh token.

## OAuth do vendedor

O fluxo recomendado para o ERP é **OAuth 2.0 Authorization Code no servidor**. Para seller brasileiro, a documentação oficial mostra a autorização em `https://auth.mercadolivre.com.br/authorization`; o `redirect_uri` deve ser estático e corresponder exatamente ao cadastrado. `response_type=code` e `client_id` são obrigatórios no exemplo. `state` é recomendado para vincular o callback a uma tentativa iniciada pelo próprio ERP. PKCE é opcional na documentação, mas `code_challenge`/`code_verifier` tornam-se obrigatórios se PKCE estiver habilitado no aplicativo. [1]

```text
GET https://auth.mercadolivre.com.br/authorization
  ?response_type=code
  &client_id={APP_ID}
  &redirect_uri={REDIRECT_URI}
  [&state={STATE}]
  [&code_challenge={CODE_CHALLENGE}&code_challenge_method=S256]
```

Troca do código, sem acessar a API real nesta pesquisa:

```text
POST https://api.mercadolibre.com/oauth/token
Accept: application/json
Content-Type: application/x-www-form-urlencoded

grant_type=authorization_code
client_id={APP_ID}
client_secret={CLIENT_SECRET}
code={AUTHORIZATION_CODE}
redirect_uri={REDIRECT_URI}
[code_verifier={CODE_VERIFIER}]
```

A resposta documentada contém `access_token`, `token_type=bearer`, `expires_in=21600`, `scope`, `user_id` e `refresh_token`. O Mercado Livre descreve o access token como válido por seis horas. O refresh token é de uso único e cada renovação devolve outro refresh token, que deve substituir o anterior de forma atômica. [1]

Renovação:

```text
POST https://api.mercadolibre.com/oauth/token
Accept: application/json
Content-Type: application/x-www-form-urlencoded

grant_type=refresh_token
client_id={APP_ID}
client_secret={CLIENT_SECRET}
refresh_token={REFRESH_TOKEN_ATUAL}
```

A documentação informa que o refresh token expira após seis meses e que `invalid_grant` exige novo fluxo de autorização. Ela também documenta `invalid_client`, `invalid_scope`, `invalid_request`, `unsupported_grant_type`, `forbidden` (403), `local_rate_limited` (429), `unauthorized_client` e `unauthorized_application`. [1]

Para consultas somente de pedidos, manter o escopo mínimo `read`; `write` só é necessário para métodos de alteração. A página de permissões distingue leitura (`GET`) de leitura e escrita (`POST`, `PUT`, `DELETE`) e informa o erro `PA_UNAUTHORIZED_RESULT_FROM_POLICIES` com HTTP 403 quando falta a permissão funcional correspondente. [3]

### Segredos sugeridos

Variáveis de ambiente/configuração, sem valores neste documento:

- `MERCADO_LIVRE_APP_ID`
- `MERCADO_LIVRE_CLIENT_ID` — alias operacional do App ID; escolher um nome canônico no projeto, não duplicar os dois em produção.
- `MERCADO_LIVRE_CLIENT_SECRET`
- `MERCADO_LIVRE_REDIRECT_URI`
- `MERCADO_LIVRE_AUTH_BASE_URL`
- `MERCADO_LIVRE_API_BASE_URL`
- `MERCADO_LIVRE_OAUTH_SCOPES`
- `MERCADO_LIVRE_TOKEN_ENCRYPTION_KEY`
- `MERCADO_LIVRE_WEBHOOK_URL`
- `MERCADO_LIVRE_WEBHOOK_ALLOWED_IPS` — apenas se uma allowlist for adotada e for atualizada conforme a documentação oficial.

`access_token` e `refresh_token` são por seller e devem ser armazenados cifrados, com acesso restrito e logs sanitizados; não devem aparecer na query string. A própria documentação recomenda criptografia em repouso e uso do header `Authorization`, não de `?access_token=...`. [9] Tokens por seller não devem ser colocados em `.env` compartilhado; a variável é somente para a chave que cifra o armazenamento server-side.

## URL-base, headers e pedidos

A URL-base documentada para os recursos abaixo é `https://api.mercadolibre.com`. As chamadas autenticadas usam `Authorization: Bearer {ACCESS_TOKEN}`. A documentação de pedidos exemplifica esse header em `orders/search`; a documentação de segurança reforça que o token deve trafegar em header e não em URL. [5] [9]

### Buscar pedidos do seller

```text
GET https://api.mercadolibre.com/orders/search?seller={SELLER_ID}
Authorization: Bearer {ACCESS_TOKEN}
```

`seller` é o identificador do seller no exemplo oficial. A mesma rota aceita a busca exemplificada por pedido com `q={ORDER_ID}`. A resposta usa paginação com `paging.total`, `paging.offset` e `paging.limit`; `offset` e `limit` são contagens de registros, não valores monetários nem unidades físicas. O endpoint também expõe uma alternativa de busca por `buyer={BUYER_ID}`, que não é o fluxo principal deste ERP. [5]

A resposta de cada pedido inclui `id`, estados (`status`, `status_detail`), datas (`date_created`, `date_closed`, `date_last_updated`), `currency_id`, `total_amount`, pagamentos, envio, comprador, seller, tags e `order_items`. Cada item documentado contém `item.id`, título, categoria, variação, `quantity`, `unit_price`, `sale_fee` e `currency_id`. Portanto, `quantity` deve ser tratado como quantidade vendida; valores monetários devem sempre permanecer associados a `currency_id`. A página não define uma unidade física de estoque para `quantity`, nem autoriza converter isso em gramas, centímetros ou unidades de embalagem. As datas dos exemplos são ISO 8601 com offset ou `Z`. [5]

### Consultar o pedido notificado

```text
GET https://api.mercadolibre.com/orders/{ORDER_ID}
Authorization: Bearer {ACCESS_TOKEN}
```

A própria documentação oficial de segurança usa essa consulta autorizada como a etapa de verificação após um webhook. O corpo recebido no webhook é apenas um aviso; o estado autoritativo deve vir da resposta autenticada do pedido. [6]

### Atributos específicos do produto do pedido

```text
GET https://api.mercadolibre.com/orders/{ORDER_ID}/product
Authorization: Bearer {ACCESS_TOKEN}
```

`ORDER_ID` é obrigatório. A página oficial informa que esse resultado pode ser paginado com `offset` e `limit` e retorna atributos específicos do produto. [5]

### Dado fiscal relacionado ao pedido

O endpoint legado de billing foi declarado depreciado. O fluxo atual é obter `buyer.billing_info.id` a partir de `/orders` e consultar `GET /orders/billing-info/{site_id}/{billing_info_id}`. O billing address não é equivalente ao endereço logístico; para entrega, a documentação aponta `/shipments/{shipment_id}`. Não usar o endpoint legado no adaptador novo. [10]

## Notificações oficiais e autenticidade

A URL de callback deve ser HTTPS e configurada no gerenciador do aplicativo. Na documentação oficial de segurança, o exemplo de notificação contém `resource` como `/orders/123` e `user_id`; ele recomenda responder HTTP 200 em menos de 500 ms, enfileirar o aviso e consultar o recurso diretamente com o access token do seller. O HTTP 200 confirma recebimento/enfileiramento, **não** confirma processamento nem autenticidade do conteúdo. [6]

A página oficial de notificações consultada, atualizada em 03/01/2024, registra apenas que a quantidade de novas tentativas foi reduzida de oito para cinco em uma janela de uma hora. [7] A documentação detalhada de notificações não ficou exposta pelo extrator nesta consulta; por isso este relatório não presume tópicos, identificador de evento, ordenação ou contrato de replay que não estejam visíveis nas fontes abertas.

### Política real de verificação

Nas páginas oficiais consultadas **não há contrato de HMAC, assinatura, `X-Signature`, segredo compartilhado, timestamp assinado ou canonicalização do corpo** para webhook do Mercado Livre. Não implementar HMAC inventado e não considerar a presença de um POST ou de HTTP 200 como prova de origem.

A documentação de segurança lista IPs de origem como uma opção de validação e avisa que a lista pode mudar. A allowlist, se usada, deve ser mantida a partir da documentação atual e aplicada somente sobre o endereço de origem confiável da infraestrutura; ela é uma camada auxiliar, não substitui a consulta autorizada. [6]

O adaptador proposto é:

1. receber apenas HTTPS, limitar tamanho/tempo localmente e registrar o envelope sem segredos;
2. validar o formato mínimo conhecido (`resource` e `user_id`) e guardar o aviso para deduplicação;
3. devolver 200 rapidamente somente depois de persistir/enfileirar o aviso, sem declarar o pedido sincronizado;
4. no worker, selecionar o token do seller correspondente e fazer `GET /orders/{ORDER_ID}` com Bearer;
5. aceitar mudanças somente do recurso autorizado e usar os campos retornados pelo GET, como `status`, `order_items` e `date_last_updated`;
6. tornar a aplicação local idempotente por recurso e versão/estado observado, porque as páginas consultadas não documentam exatamente-once nem um event ID oficial. Reavisos devem ser seguros; não processar o corpo do webhook como fonte financeira.

A fonte de verdade para autenticidade é, portanto, a combinação de callback HTTPS, controles de transporte/origem documentados e **consulta autorizada ao recurso do seller**. A consulta pode falhar ou o token pode não estar disponível; nesse caso o evento fica pendente para retry interno e não deve ser transformado em pedido confirmado.

## Rate limit, erros e idempotência

O Mercado Livre documenta HTTP 429 para excesso de requisições e informa que o controle principal é por Client ID e por endpoint. Não publica nesta página um número universal de RPM para `orders/search`. A orientação oficial é evitar picos e concorrência extrema, consumir paginação/scroll dentro da validade, usar batching somente quando o endpoint suportar e aplicar backoff com jitter; não assumir que todo endpoint possui multiget. [8]

O adaptador deve tratar 429 como retryable com backoff limitado e jitter, respeitando a janela de notificações e evitando retries em massa. Para 401/credencial expirada, tentar uma renovação serializada por seller apenas uma vez; se o refresh falhar com `invalid_grant`, marcar a conexão como reautorização necessária. Para 403, distinguir escopo/permissão funcional ausente do bloqueio da aplicação. Para 404 de um recurso notificado, manter o aviso e registrar a inconsistência para investigação, sem fabricar um pedido.

Não existe garantia oficial de idempotência para as consultas. A idempotência é responsabilidade do adaptador: uma chave local pode combinar seller, `resource` e a versão/estado retornado por consulta, com restrição única e transação no Supabase. Como não foi encontrado um identificador de evento oficial na página atual acessível, não usar `sent`, horário de chegada ou hash do corpo como prova de unicidade; esses valores, se futuramente documentados, ainda seriam apenas metadados até a consulta autorizada.

## Pré-requisitos, aprovação e limitações

É necessário criar e configurar um aplicativo no DevCenter, cadastrar exatamente o redirect URI, obter App ID/Client Secret, obter consentimento OAuth do seller e configurar a URL HTTPS de notificação. O seller deve autorizar a aplicação; a documentação de autorização também orienta verificar se ele usa a conta principal e não um colaborador. [1] A gestão do aplicativo permite consultar grants e revogar a autorização com `DELETE /users/{USER_ID}/applications/{APP_ID}`; revogação invalida as credenciais e exige novo consentimento. [4]

Esta pesquisa não afirma integração preparada, ativada ou certificada. Permanecem lacunas que exigem uma revisão posterior na documentação oficial acessível ou no DevCenter autenticado: catálogo completo de tópicos de notificação, payload completo, método oficial de assinatura caso seja introduzido, event ID/semântica de replay, quotas específicas por endpoint de orders e regras regionais de retenção/PII. Não foram usadas credenciais nem realizados testes de leitura ou escrita em contas reais.

## Referências

[1]: https://developers.mercadolivre.com.br/pt_br/escolha-tipo-de-servico/autenticacao-e-autorizacao "Autenticação e Autorização — OAuth, PKCE, refresh e erros"
[2]: https://developers.mercadolivre.com.br/pt_br/escolha-tipo-de-servico/obtencao-do-access-token "Obtenção do Access Token"
[3]: https://developers.mercadolivre.com.br/pt_br/api-docs-pt-br/permissoes-funcionais "Permissões funcionais"
[4]: https://developers.mercadolivre.com.br/pt_br/registre-o-seu-aplicativo/gerencie-seu-aplicativo "Gerencie seu aplicativo"
[5]: https://developers.mercadolivre.com.br/pt_br/vendas-e-envios/pedidos-e-opinioes "Pedidos e opiniões"
[6]: https://developers.mercadolivre.com.br/en_us/product-identifiers/application-security "Application security"
[7]: https://developers.mercadolivre.com.br/pt_br/notificacoes "Notificações"
[8]: https://developers.mercadolivre.com.br/pt_br/usuarios-e-aplicativos/rate-limit-erro-429 "Rate limit / Erro 429 e solicitações de aumento de RL"
[9]: https://developers.mercadolivre.com.br/pt_br/tendencias/gestao-de-identidades-e-acessos-oauth-e-tokens "Gestão de Identidades e Acessos — OAuth e Tokens"
[10]: https://developers.mercadolivre.com.br/pt_br/mercado-envios-modo-2/faturamento-billing-info "Faturamento / Billing info"
