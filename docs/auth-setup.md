# Supabase Auth — configuração do aplicativo

O app usa Supabase Auth real, com validação de usuário pelo servidor antes de liberar as rotas privadas. A chave pública configurada foi verificada como JWT de papel anon, sem expor seu valor. O Vite impede build/inicialização com chave privada e o cliente também rejeita service_role e sb_secret. Não são criados usuários demonstrativos ou bypass de sessão.

Em 29/10/2026 às 18:19 BRT, foram confirmadas no painel Authentication → URL Configuration duas URLs persistidas: `/entrar` e `/recuperar`, na origem exata da prévia registrada no projeto Manus. Nenhum wildcard foi adicionado. O Site URL preexistente, `http://localhost:3000`, foi preservado; os fluxos do SDK informam explicitamente o retorno da origem atual. Nenhuma senha, usuário ou outra opção de autenticação foi alterada nesse ajuste.

Com confirmação de e-mail habilitada, `signUp` devolve usuário, mas a sessão permanece nula até a confirmação. O app mantém o estado desconectado. O link de recuperação provoca `PASSWORD_RECOVERY`, e a nova senha é aplicada por `updateUser`. O logout usa `signOut({ scope: 'local' })` para encerrar apenas a sessão atual.[2]

Para desenvolvimento em outra origem, adicionar os caminhos exatos `/entrar` e `/recuperar` à allowlist, preservando os existentes. A origem publicada definitiva deve ser adicionada depois da publicação, e o Site URL deve ser revisado então; não adivinhar domínio de produção.[1]

Os e-mails usam a configuração real do projeto Supabase. A ativação pública em produção precisa também revisar SMTP, limites de envio, proteção contra abuso e templates. Não considerar e-mail enviado nem login confirmado se o provedor retornar erro. O proprietário realizou pessoalmente o primeiro cadastro/login em 29/10/2026 e o vínculo à organização Vê na Memória foi confirmado; não foi realizado um teste criando conta fictícia.

## Referências

[1]: https://supabase.com/docs/guides/auth/redirect-urls "Supabase — Redirect URLs"
[2]: https://supabase.com/docs/reference/javascript/auth-signup "Supabase JavaScript — Auth methods"
