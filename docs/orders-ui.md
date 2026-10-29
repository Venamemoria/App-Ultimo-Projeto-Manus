# UI de pedidos — evidência da fatia

Implementação concluída em `src/features/orders/` e `src/features/notifications/`, sem alteração da migration ou criação de registros. A fatia usa exclusivamente Supabase Auth, views/RLS e as quatro RPCs públicas descritas em `docs/orders-api.md`.

## Estrutura modular

- `types.ts`: DTOs, enums backend, permissões efetivas e transições.
- `api.ts`: views, paginação por `id`, filtros, catálogo, detalhe, RPCs e invalidação React Query por organização.
- `pricingPreview.ts`: preview decimal derivado do catálogo atual, com tier/promoção, variação ativa e m².
- `form.tsx`: modal de criação, cliente ativo, datas ISO, responsável membership, notas, itens, override e nonce.
- `list.tsx`: lista paginada com restante, filtros reais e CSV somente dos registros consultados.
- `detail.tsx`: itens/receitas/custos readonly, eventos, consumo, pagamentos e transições auditadas.
- `board.tsx`: Kanban das etapas reais com botões acessíveis e drag-and-drop que chama RPC.
- `calendar.tsx`: agenda mensal de datas reais de produção/entrega sem conversão UTC.
- `utils.ts`: datas locais, limites, UUID, CSV e chaves de idempotência.

Notificações ficam em `src/features/notifications/`: consulta própria a `vm_notifications` (RLS por destinatário), `vm_mark_notification_read`, campainha no `AppLayout` e Postgres Changes autorizado para `vm_notifications`/`vm_order_events`. A interface exibe `conectado` somente após `SUBSCRIBED`; em qualquer outro estado exibe `reconectando`. O canal é removido quando organização ou usuário mudam.

## Evidências e limites honestos

- `pnpm typecheck`: passou.
- `pnpm test`: passou com 28 testes puros, sem browser, SQL, fixture ou dados demonstrativos.
- `pnpm build`: passou, gerando chunks lazy separados para lista, detalhe, Kanban e agenda.
- `find ... | wc -l`: nenhum arquivo de Orders excede 600 linhas; o maior é `api.ts` com 326 linhas.
- `public/manus-routes.json` contém as rotas existentes e `/pedidos`, `/pedidos/:id`, `/producao` e `/agenda`.

O servidor continua sendo a autoridade de preço final, estoque, status, pagamentos, RLS e idempotência. A UI não apresenta rollback falso em erro de rede, não cria pagamento automático ao concluir, não oferece edição comercial inexistente e não envia WhatsApp/e-mail: o outbox permanece responsabilidade futura server-side.
