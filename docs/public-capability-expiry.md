# Validade e revogação dos links públicos

A migration `20261031001000_public_capability_expiry` usa o relógio do banco e o fuso **America/Sao_Paulo**. A validade é inclusiva até o fim da data informada, não até meia-noite UTC nem até a meia-noite do dispositivo do cliente. O formulário usa o mesmo fuso para orientar o usuário, mas somente o banco decide se o link está válido.

- A leitura pública de orçamento inexistente, vencido ou revogado retorna `NULL`, sem o conteúdo comercial. A aprovação desses links falha sem criar pedido.
- A primeira aprovação válida cria um único pedido pendente e o respectivo link de rastreio. Uma repetição retorna o mesmo pedido e o **rastreio original** somente se orçamento e rastreio original ainda estiverem válidos e não revogados. Se o rastreio foi revogado ou expirou, não é reativado e o orçamento não entrega o token de outro rastreio. O estabelecimento pode gerar e compartilhar explicitamente um novo link pelo pedido.
- O vencimento do orçamento não revoga, por si só, um rastreio independente ainda válido. O rastreio tem prazo e revogação próprios.
- Na listagem administrativa, `Sent` vencido é exibido como `Expired`; o estado histórico continua `Sent`, de modo que owner/admin/finance podem revisá-lo, escolhendo outra validade. A revisão revoga o link anterior.
- As páginas públicas revalidam ao voltar à aba e aproximadamente a cada 30 segundos enquanto visíveis. Se a consulta falhar, a tela deixa de exibir o conteúdo até ser validado novamente. Isso não apaga dados já visualizados, nem substitui a checagem do servidor; a confirmação depende da rede.
- A leitura serializa com a revogação do orçamento. O replay bloqueia a capability original durante a confirmação e verifica novamente os prazos depois de esperar por locks, sem reemitir ou permitir aceite duplicado.

## Verificação local

`python scripts/run_database_tests.py --suite public_capabilities --stop` aplica a cadeia atual em PostgreSQL isolado e valida: fronteiras da meia-noite, histórico de horário de verão, sessão em outra data, ACLs, link expirado/revogado, revisão administrativa, replay, rastreio substituído e corridas reais em duas conexões (inclusive expiração durante espera de lock). Para simular passagem de dias, o teste altera somente fixtures do cluster local marcado; nenhuma fixture é aplicada no Supabase. `pnpm test` também verifica os limites do fuso e a remoção de dados obsoletos durante revalidação/navegação.

Testes de contrato locais não comprovam navegação ponta a ponta em implantação, entrega Realtime ou uso por clientes reais. O app precisa ser publicado com a versão correspondente da interface após a migration.

## Supabase autorizado

A migration foi aplicada ao projeto `kasupbixvesyyrvmfzgm`, sem fixtures, em transação com ambos os históricos. Os dois registros têm **13 versões correspondentes**. O SQL registrado no histórico oficial tem MD5 `a909f8452657d458748c4e3c90c6ded0`, igual ao conteúdo do arquivo local sem a quebra final; o arquivo tem SHA-256 `1c97188ec729a0ec989335e1bddcef118aa89038e8c565041f3e17a2adc2f1a0`. As cinco definições instaladas coincidiram com as do teste PostgreSQL 17, os grants públicos/administrativos foram preservados e as duas fronteiras de meia-noite foram verificadas sem consultar dados de cliente.
