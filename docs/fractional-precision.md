# Multiplicações fracionárias

A migration `20261030010000_fractional_multiplication` preserva os dados existentes e amplia a precisão dos resultados derivados de pedidos e orçamentos. Entradas de quantidade, dimensões, preço e composição continuam aceitando até **oito casas**; os resultados intermediários, saldos, movimentos, consumos e devoluções aceitam até **36 casas**, e os custos totais intermediários até **44**. O limite de magnitude anterior é mantido e valores monetários finais continuam arredondados a duas casas.

Exemplo: uma composição de `0,00001` multiplicada por `0,0001` baixa exatamente `0,000000001`, não zero. A área em m² pode combinar duas dimensões e quantidade fracionárias; a receita congelada do orçamento é copiada ao pedido aprovado sem truncar. Depois de uma baixa com mais de oito casas, ajuste, entrada, compra e devolução continuam preservando o saldo. A baixa permanece transacional e protegida contra repetição.

Os campos derivados de leitura continuam sendo decimais textuais. As views afetadas são recriadas na mesma transação, preservando `security_invoker`, comentários e ACLs explícitas, inclusive quando o banco define permissões padrão para novas views. O código cliente exibe as casas significativas e aceita a devolução da fração exata.

A precisão do **custo unitário calculado pela divisão do lote** ainda é de oito casas e será tratada em uma fatia própria; esta migration não reescreve snapshots históricos de custo.

Validação: `python scripts/run_database_tests.py --suite fractional_precision --stop` usa o banco local marcado e exercita as RPCs reais, aprovação, baixa, devolução e concorrência; `--latest` permite rodar suítes compatíveis contra todas as migrations; suítes históricas que dependem de permissões antigas podem exigir seu recorte original. Os testes locais não provam entrega Realtime nem substituem validação de navegação no ambiente publicado.
