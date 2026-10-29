# Orçamento e acompanhamento — desenho da próxima fatia

## Origem e invariantes

O backend de pedidos já aplicado resolve itens pelo catálogo dentro de `vm_private.vm_order_build`; ele não serve diretamente ao aceite de orçamento previamente enviado, pois reconsultaria preço/composição. A próxima fatia deverá capturar a resolução comercial e a receita uma vez, na emissão, e construir o pedido a partir dessa resolução congelada no aceite. Não chamar o construtor normal com o catálogo atual, não inserir pedido provisório para simular orçamento e não falsificar a identidade de um usuário na função pública.

Orçamento emitido: itens, preços, dimensões, promoções/faixas, frete, desconto, prazos/termos e receitas são imutáveis. Revisão comercial gera emissão nova e revoga a anterior. A validade/revogação é verificada no servidor. Status final de aceite é exatamente `Approved`. Lock de organização e orçamento, pedido/eventos/outbox/primeira capability de tracking na mesma transação, única vinculação e retorno durável fazem cliques repetidos devolverem o mesmo pedido/link. Aceite não marca pagamento, não começa produção e não consome material; pedido inicia Pendente. Contato e receita históricos permanecem congelados, sem reusar dados privados do cadastro corrente como fonte da projeção pública.

## Capabilities e projeção

`/orcamento/:id` e `/rastreio/:id` recebem UUIDs aleatórios independentes dos IDs internos. Nenhum SELECT anônimo é concedido nas tabelas operacionais. Getter e aceite públicos usam capability válida, funções com `search_path` fixo, ACLs explícitas e projeção construída por allowlist, nunca `to_jsonb(row)` inteira. Público: marca/nome do ateliê, título/código público, itens comerciais/quantidades/preços, frete/total/desconto, prazos/termos e status/datas/histórico público. Não incluir CPF/CNPJ, endereço, nascimento, contato/e-mail, autoria, IDs internos, notas internas, custo/receita/material/margem ou credenciais. Nenhuma imagem privada é prometida sem mecanismo de autorização válido.

## Realtime

O projeto tem `realtime.send(jsonb,text,text,boolean)` confirmado por metadados. Broadcast usa tópico por capability imprevisível e payload mínimo (versão/status/sinal sem PII), cessa em token revogado/expirado e somente invalida a consulta. Navegador recarrega o getter verdadeiro; não aceita o conteúdo do pacote como status confiável. Não chamar polling de tempo real. SQL de teste precisa provar atomicidade e revogação; um substitute no-op de Realtime não é evidência de envio real. Compartilhamento/expiração/revogação de links separam fluxo público de permissões internas.

As rotas públicas devem ser noindex, sem analytics contendo capability/dados comerciais. A prévia não é URL de produção; após publicação confirmada, acrescentar os callbacks Supabase exatos da origem pública e gerar links pela origem do navegador, não por Host interno.

## Estado

Desenho salvo; nenhum orçamento/token de negócio, pedido, envio ou automação foi criado por esta preparação. SQL, QA, aplicação e UI desta fatia ainda não foram entregues neste registro. Worker WhatsApp permanece separado e depende de credenciais/consentimento/autorização e execução hospedada, não de loop no Sandbox.
