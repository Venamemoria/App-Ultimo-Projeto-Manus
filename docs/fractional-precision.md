# Precisão fracionária

As entradas de quantidade, dimensões, preço e composição continuam aceitando até **oito casas decimais**. As migrations `20261030010000_fractional_multiplication` e `20261030011000_fractional_unit_cost` ampliam os resultados intermediários sem alterar a stack ou usar números binários para dinheiro:

- Divisão de custo do lote pela quantidade: **24 casas**, arredondadas pelo PostgreSQL em `numeric`. Divisões não terminantes, como 1/3, têm uma representação finita de 24 casas, não uma fração matemática infinita.
- Custo de cada linha de composição: até **32 casas**; custo total do item de pedido ou orçamento: até **60 casas**.
- Saldos, movimentos, consumos e devoluções: até **36 casas**. Os limites de magnitude das entradas são mantidos e valores cobrados continuam arredondados a duas casas.

Por exemplo, uma composição de `0,00001` multiplicada por `0,0001` baixa exatamente `0,000000001`, não zero. Uma unidade comprada por R$ 1 em um lote de três gera custo `0,333333333333333333333333`; ao usar `0,00000001` dessa unidade, a composição registra `0,00000000333333333333333333333333`.

A receita é congelada na versão de produto e copiada ao orçamento e pedido; a baixa permanece transacional e protegida contra repetição. A precisão maior se aplica às **novas versões**; custos e JSON de versões históricas mantêm os valores que foram registrados na época. Atualizar o custo de um insumo não reescreve um produto já congelado: salve uma nova versão para refletir o custo atual. Os campos legados de oito casas nas tabelas de materiais e compras continuam disponíveis para compatibilidade; as views e RPCs da aplicação usam o custo preciso.

Os campos decimais das views continuam textuais. As views afetadas são recriadas na mesma transação, preservando `security_invoker`, comentários e ACLs explícitas, inclusive quando o banco define permissões padrão para novas views. A interface exibe casas significativas de custos e permite a devolução da fração exata.

Validação isolada: `python scripts/run_database_tests.py --suite fractional_precision --stop` exercita as RPCs reais, aprovação, baixa, devolução, variantes e concorrência; `python tests/database/unit_cost_upgrade.py` valida versões históricas e ACLs durante a migração. O runner usa somente o banco local marcado. `--latest` permite executar suítes compatíveis contra todas as migrations; suítes históricas que dependem de permissões antigas podem exigir seu recorte original. Estes testes não provam entrega Realtime nem substituem validação de navegação no ambiente publicado.
