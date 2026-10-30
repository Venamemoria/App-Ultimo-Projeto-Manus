# Harness PostgreSQL isolado de QA

Este harness é uma infraestrutura temporária de testes do banco local. Ele não substitui o Supabase, não é usado pelo Vite/app e não afirma nada sobre o banco Supabase real ou sobre uma publicação da aplicação.

## Execução

Use o Python do ambiente de banco:

```bash
cd /home/ubuntu/venamemoria
/home/ubuntu/.venvs/venamemoria-db/bin/python scripts/run_database_tests.py
```

A execução padrão cria/recria somente o database `vm_test` dentro do cluster marcado em `/home/ubuntu/venamemoria/.local/test-db`, aplica `20261029203500_foundation.sql` em transação e executa `tests/database/foundation.sql`. O runner deixa o cluster ativo para o parent; ao finalizar, o estado esperado é `pg_ctl: running`. Para parar explicitamente somente este cluster marcado:

```bash
/home/ubuntu/.venvs/venamemoria-db/bin/python scripts/run_database_tests.py --stop
```

O cluster usa exclusivamente socket Unix em `/home/ubuntu/venamemoria/.local/test-db/socket`, `listen_addresses=''` e porta configurada `55432` (sem listener TCP). O runner verifica antes de qualquer fixture: `current_database() = 'vm_test'`, `inet_server_addr() IS NULL`, porta/socket esperados, marcador próprio do cluster e roles de teste sem `SUPERUSER`. Um cluster default do pacote nunca é usado.

## Isolamento e Auth local

O reset só é permitido quando o database existente possui o marcador interno correspondente ao cluster e ao caminho do socket; um database não marcado causa falha, não fallback. O reset recria somente `vm_test` nesse cluster. Nenhum dado é gravado no Supabase para fixtures.

Antes dos testes, o runner cria somente dois UUIDs locais em `auth.users`, além de `auth.uid()`, `auth.role()` e `auth.jwt()`. As implementações dos três helpers são obtidas uma vez com `pg_get_functiondef` em transação remota `READ ONLY`, usando os mesmos parâmetros protegidos de `scripts/apply_foundation.py`; o cache fica em `.local/test-db/auth-helper-defs.sql` e não contém URI, senha, chaves, e-mails ou JWTs. O cache é executado apenas no database local. `anon` e `authenticated` são roles sem `SUPERUSER`, com `USAGE`/execução dos helpers Auth necessários ao teste.

As organizações são então criadas pelo RPC real no banco local. As verificações posteriores usam `SET LOCAL ROLE authenticated` ou `anon` e os GUCs JWT, portanto as consultas RLS não rodam como o administrador local. O seed administrativo termina antes de qualquer mudança para uma role de sessão autenticada; não há usuário fake na UI nem bypass de autenticação no app.

## Cobertura da foundation

A suite SQL aborta em qualquer assertion falha e cobre:

- contrato real dos helpers `auth.uid()`, `auth.role()` e `auth.jwt()`;
- dois usuários/tenants locais e criação de organizações via RPC;
- vazamento zero entre tenants sob RLS;
- barreiras de autorização e FKs compostas para fornecedor/material cruzado;
- ausência de leitura/execução para `anon`;
- ausência de DML direto de saldo e histórico para `authenticated`;
- custo unitário e quantidades fracionárias calculados pelo PostgreSQL com `numeric(20,8)`, além da rejeição de escala excedente;
- recebimento idempotente e rejeição de reutilização da chave com payload diferente;
- rollback integral do ajuste negativo que deixaria saldo menor que zero;
- composição de produto versionada, preservando a versão anterior.

A foundation não testa como seguro o ajuste legado sem idempotência, nem NaN/Infinity: essas são lacunas corrigidas pela migration inventory e não devem ser mascaradas por expectativas da suite foundation.

## Suite inventory

O runner de `inventory` é autossuficiente: recria o mesmo database local marcado, aplica **todas** as migrations `.sql` versionadas em ordem (`foundation` e `inventory`) e executa somente `tests/database/inventory.sql`. A suite declara no próprio arquivo os helpers de assertion e as fixtures mínimas locais, sem executar nem alterar `tests/database/foundation.sql`. Se o arquivo não existir, o runner falha com dependência explícita. A migration inventory é incremental e não é editada por este harness.

Execução verificada:

```bash
/home/ubuntu/.venvs/venamemoria-db/bin/python scripts/run_database_tests.py --suite inventory
```

Resultado obtido: **16 grupos passaram, 0 falhas**. Foram aplicadas `20261029203500_foundation` e `20261029221500_inventory` no database `vm_test`. A execução confirmou fixtures locais por RPC, views `text` com `security_invoker` e grants/RLS sem leitura cruzada; rejeição de `NaN`, `Infinity` e escala excedente; recebimento avulso sem compra/despesa e com chave/nota obrigatórias; cadastro idempotente após mudança de saldo e mismatch; ajuste seguro com chave/motivo, replay sem duplicação e rollback negativo; compra atômica com saldo, movimento, compra e caixa ligados, estados `pending`/`paid` e valores decimais exatos; replay/mismatch/colisão de chave; compra permitida a `finance` sem spoof de UID e negada a `production`/`viewer`; FKs compostas entre tenants; negação a `anon`; e histórico append-only por privilégios e triggers.

Evidência do runner: database `vm_test`, socket Unix `/home/ubuntu/venamemoria/.local/test-db/socket`, `listen_addresses=''`, porta configurada `55432`, cluster marcado `/home/ubuntu/venamemoria/.local/test-db` e `pg_ctl: running`. O cluster foi deixado ativo para a próxima suite; para pará-lo explicitamente, use `--stop`.

Esses 16 grupos são resultados somente do banco local isolado. Não constituem alegação de teste no Supabase autorizado, de teste de frontend, WebSocket/Realtime, integração externa ou app publicada.

## Suite Products

A suite `products` é executada no mesmo cluster PostgreSQL local marcado. O runner recria somente `vm_test`, aplica em ordem as migrations versionadas até `20261029233000_products.sql` (`foundation`, `inventory` e `products`) e executa somente `tests/database/products.sql`. O arquivo de teste declara seus próprios helpers de assertion e suas fixtures mínimas; ele não executa nem altera as suites `foundation` ou `inventory`.

Execução:

```bash
/home/ubuntu/.venvs/venamemoria-db/bin/python scripts/run_database_tests.py --suite products
```

Resultado registrado: **11 grupos passaram, 0 falhas**. A versão revisada da migration Products foi processada pelo parser PostgreSQL em 69 statements SQL e seis funções PL/pgSQL. Isso é evidência do contrato no `vm_test` isolado, não aplicação da migration no Supabase, nem teste de UI, PostgREST em rede, WebSocket/Realtime ou aplicação publicada. A aplicação real posterior está registrada separadamente em `products-verification.md`.

Os 11 grupos são:

1. fixtures locais de Products e custo fracionário exato do material;
2. views textuais Products com `security_invoker` e grants;
3. campos do produto v1, tiers, variações e custo de composição calculado pelo banco;
4. retry idempotente e colisão por payload diferente;
5. unidade de cobrança `m2` e snapshots históricos imutáveis;
6. barreiras contra RPC legada e mutação direta do histórico;
7. validação de escala numérica, `NaN`, `Infinity`, MOQ, modo, tiers e unidade;
8. isolamento de leitura e mutação entre tenants;
9. bloqueio de mutação do catálogo pelo papel `finance`;
10. bucket Storage privado, policy de path, verificação do objeto e registro dos metadados do arquivo;
11. RLS do Storage sem vazamento entre tenants.

As fixtures de Products são exclusivamente SQL local. O teste do Storage insere uma linha controlada em `storage.objects` para exercitar o contrato de bucket/policy e depois chama `vm_register_product_file` para verificar MIME e tamanho; isso é uma fixture do contrato local, **não** um upload HTTP, não um upload de runtime e não um download real. A suite também verifica que registrar arquivo inexistente, inserir diretamente na tabela de arquivos, usar path malicioso ou atravessar tenant falha.

A suite Products não afirma que `vm-product-media` foi criado no Supabase real, que qualquer objeto foi enviado a Storage real ou que uma URL assinada foi emitida. O resultado mantém a distinção entre o banco local isolado e o ambiente Supabase autorizado.

## Suite Public Sales

A suite `public_sales` recria somente o database local marcado `vm_test`, aplica em ordem as migrations versionadas até `20261030004000_tracking_minimal_acl.sql` e executa `tests/database/public_sales.sql`, além do probe de concorrência com duas conexões reais locais.

Execução verificada:

```bash
/home/ubuntu/.venvs/venamemoria-db/bin/python scripts/run_database_tests.py --suite public_sales --stop
```

Resultado observado: **17 grupos passaram, 0 falhas**. Grupos: tenants e identidades owner/finance; fixtures reais locais de cliente/material/produto versionado; ACL pública e ausência de leitura anônima de tabelas; emissão com totais/termos congelados; projeção pública e token inválido; imutabilidade dos snapshots após alterações de catálogo/cliente; aceite anônimo formando pedido pendente dos snapshots congelados; replay idempotente; vínculo de revisão e imutabilidade de aprovado; revogação e tokens desconhecidos sem gravações parciais; ACL de tracking e validade; paginação/listagem administrativa; projeção allowlist de `vm_get_quote_admin`, preço catalogado oculto, preço manual exposto e comportamento NULL por tenant; finance autorizado e viewer/anon negados; ACL do getter administrativo de tracking para owner/finance com viewer/tenant/anon negados e projeção pública exata sem dados comerciais; fixture concorrente; e probe de corrida de aceite em duas conexões, com somente um pedido/aceite/evento/conjunto de notificações e sem dedução de material.

O runner reportou `vm_test`, socket Unix `/home/ubuntu/venamemoria/.local/test-db/socket`, `listen_addresses=''` e cluster marcado `/home/ubuntu/venamemoria/.local/test-db`; o runner interrompeu o cluster isolado após a suite. Esse resultado é exclusivamente local. Separadamente, as migrations `20261030003000_public_sales`, `20261030003500_quote_admin_list` e `20261030004000_tracking_minimal_acl` foram aplicadas no Supabase autorizado; sua verificação está em `docs/public-sales-verification.md`. Isso não comprova chamada de PostgREST pela UI, entrega Realtime em navegador ou publicação.
