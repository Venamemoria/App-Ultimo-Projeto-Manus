# API de resumo financeiro — primeira fatia

## Estado

A migration `supabase/migrations/20261030005000_finance_summary.sql` cria a RPC read-only `public.vm_get_finance_summary` e foi aplicada ao projeto Supabase autorizado em 30/10/2026. O relatório versionado de migrations registra a versão e seu hash. A verificação remota por catálogo, estritamente somente leitura, confirmou `SECURITY DEFINER`, `search_path=''` e ACL de execução concedido somente a `authenticated`. A suite `finance_summary` cria fixtures exclusivamente no PostgreSQL local isolado. A UI consome esta API em `/financeiro`; ela não grava lançamentos financeiros.

## Assinatura e acesso

```text
public.vm_get_finance_summary(
  p_organization_id uuid,
  p_from date,
  p_to date,
  p_grouping text -- 'day' | 'month'
) RETURNS jsonb
```

A chamada exige sessão Supabase `authenticated` e membership `owner`, `admin` ou `finance` na organização, conferidas no servidor por `vm_private.vm_has_role`. `anon`, `viewer`, `production` e sessão de outro tenant são recusados. A função é `SECURITY DEFINER` com `search_path=''`; o grant de execução é removido de `PUBLIC`/`anon` e concedido somente a `authenticated`. A resposta contém agregados, sem IDs operacionais ou PII.

`p_from` e `p_to` são datas inclusivas, finitas e ordenadas, com no máximo 367 datas consecutivas (diferença máxima de 366 dias). `p_grouping` é obrigatório e aceita somente `day` ou `month`. Datas ou parâmetros inválidos são rejeitados.

## Resposta

A RPC retorna `currency`, `period`, `realized`, `estimate`, `series` e `dueDatesAvailable`. Valores monetários em BRL são textos decimais; o frontend os mantém como strings/`Decimal`, sem `float`.

- `realized.received`: soma de `vm_order_payments.amount`, com `payment_date` na janela escolhida. Essa tabela é a origem canônica do recebimento; a entrada-espelho em `vm_cash_entries` não é somada novamente.
- `realized.paid`: despesas de `vm_cash_entries` marcadas `paid` com `paid_at` na janela. Compras aparecem pelo lançamento de caixa vinculado; apenas uma compra paga sem seu lançamento de caixa esperado usa fallback em `vm_material_purchases`, evitando duplicidade.
- `realized.net`: `received - paid`; diferença operacional de caixa das fontes acima, não lucro líquido contábil.
- `realized.paymentMethods`: soma de recebimentos por método registrado em `vm_order_payments`; não inventa categorias ou método para compras.
- `estimate.receivable`: saldo ainda aberto de pedidos não cancelados cujo `order_date` está na janela. A data seleciona os pedidos incluídos; ela **não é vencimento**.
- `estimate.payable`: despesas pendentes selecionadas por `entry_date` e compras pendentes selecionadas por `purchase_date`; essas datas também **não são vencimentos**.
- `estimate.projectedNet`: `realized.net + estimate.receivable - estimate.payable`, sempre apresentado como estimativa.
- `series`: somente o caixa realizado, agregado por dia ou mês conforme `period.grouping`. A série inclui datas/meses com apenas despesas, com `received = "0"`.
- `dueDatesAvailable`: `false`; as fontes atuais não possuem vencimento confirmado de contas a pagar/receber.

A função não relata saldo bancário, abertura/fechamento de caixa, conciliação, taxas, tributos, reembolsos, custo de produção/consumo ou categorias financeiras não armazenadas. Também não há lançamentos manuais de receitas/despesas, lista detalhada de lançamentos recentes ou análise contábil nesta fatia. Não chamar `realized.net` de “Lucro Líquido”.

## Verificação

QA local aprovado: seis grupos de assertions funcionais cobrem owner e finance permitidos; viewer, production, outro tenant e `anon` negados; parâmetros e data infinita; agrupamento diário/mensal; despesas sem recebimentos no dia; método de pagamento; saldo a receber/a pagar explicitamente estimado; valores exatos; não duplicidade; resposta mínima; grants e configuração `SECURITY DEFINER`/`search_path`. A migration aplicada no remoto e a consulta de catálogo não são testes de interface nem de integração ao vivo com movimentações do usuário.
