# Produtos — aplicação do backend

A migration `20261029233000_products.sql` foi aplicada ao Supabase autorizado em 29/10/2026 às 19:38 BRT. Hash SHA-256 aplicado: `881553761c72e121a83f64a85596563f2d8b44bd7861058613fc70ebf6c5f66f`. O aplicador verificou o registro e RLS de todas as 15 tabelas públicas e duas privadas operacionais/controle. Não alterou usuários, organização ou registros comerciais existentes.

A versão revisada passou no parser PostgreSQL (69 statements, seis funções PL/pgSQL) e em 11 grupos SQL isolados. A falha inicial foi uma aspas ausente na assertion de caminho Storage; corrigiu-se também o fixture que continuava membro financeiro antes de testar outra organização. Os guards adicionais rejeitam rótulo/perguntas nulos, select sem opções e variação sem nome; bucket preexistente público faz a migration abortar em vez de expor arquivos.

O schema preserva receitas e snapshots, preços por unidade/m²/variação, campos de produção/personalização/mínimos/faixas, arquivos de produto privados e DTOs numéricos textuais. A view diferencia custo material corrente de custo congelado da versão. RPCs são transacionais e autenticadas; a RPC legada que não criava snapshot completo perdeu EXECUTE. Leitura e relacionamentos seguem organização/papel.

O bucket privado e policies foram configurados, mas nenhum arquivo demonstrativo foi enviado ao Storage. A suite exercitou somente o contrato relacional Storage do banco local, não um upload HTTP nem o runtime Storage. A UI conectada ainda está em implementação; não se declara esta fatia completa, vitrine pública ou publicação. Os limites de paridade permanecem no TODO.
