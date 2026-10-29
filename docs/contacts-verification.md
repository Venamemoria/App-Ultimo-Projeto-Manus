# Cadastros — evidência da fatia

Schema `20261029235500_contacts` aplicado e registrado no Supabase autorizado após 12 grupos SQL isolados aprovados. RLS e grants por coluna protegidos; tabelas públicas/privadas e histórico auditável verificados. Testes cobrem normalização, endereços, formato fiscal numérico/alfanumérico, idempotência, papéis, isolamento, archive e importação atômica até 500 linhas, sem fixtures no Supabase.

`/clientes` e `/fornecedores` estão conectados aos RPCs e views reais, com navegação protegida, busca/ativos/arquivados, formulário completo, detalhe e indicador de estoque por unidade. UI mantém nonce no retry e separa arquivamento de exclusão física. CSV UTF-8 com BOM, delimitador, aspas/quebras, preview do arquivo efetivo, importação explícita e contagens reais; exportação evita fórmula de planilha e preserva telefone. Dados/opções/custos não são semeados; nenhum contato/importação demonstrativo criado.

Typecheck, 22 testes puros em seis arquivos e build passaram. Manifesto HTTP 200 com nove rotas reais. Não há contagens/filtros de pedidos fictícios: dependem da próxima migration de pedidos. Uma entrada operacional por usuário do negócio não foi feita como teste neste registro; as ações chamam Supabase real e serão persistidas quando o usuário confirmar na UI.
