# Fundação técnica

O projeto Supabase selecionado pelo usuário é Ve no atelie. Uma consulta somente leitura realizada pelo SQL Editor autenticado em 29/10/2026 confirmou: nenhuma tabela nos schemas public/vm_private, zero usuários em auth.users e publicação supabase_realtime existente. A criação da fundação será feita por migration transacional versionada, não por reset do banco. Não serão criados usuários, organizações ou pedidos de demonstração.

A URI PostgreSQL recebida não passou na validação de formato. A sessão autenticada no painel permite aplicar e verificar o SQL sem alterar senha ou configurações de conexão. Essa aplicação será registrada apenas depois de seu resultado real. Para migrations futuras via CLI, a URI precisa ser configurada corretamente.

RLS combina grants e políticas por operação. Helpers de membership ficam em schema privado para evitar recursão e exposição desnecessária; funções com privilégios elevados usam search_path fixo e nomes qualificados. Chaves privadas nunca são incluídas no navegador.[1]

## Referências

[1]: https://supabase.com/docs/guides/database/postgres/row-level-security "Supabase — Row Level Security"

## Verificação sintática e acesso

A migration inicial contém nove tabelas com RLS e passou no parser PostgreSQL: 92 comandos SQL e sete funções PL/pgSQL analisados sem erro sintático. A verificação não substitui execução nem testes de políticas no Supabase. Nenhuma migration foi aplicada até este registro.

A normalização limitada em memória recuperou a URL de API e a estrutura da URI recebidas, sem modificar segredos armazenados. A API respondeu HTTP 200; a conexão PostgreSQL direta falhou por indisponibilidade de rede IPv6. É necessário o host e o usuário exatos do Session pooler exibidos no painel, ou a retomada da sessão de editor SQL. Não inferir host a partir da região.
