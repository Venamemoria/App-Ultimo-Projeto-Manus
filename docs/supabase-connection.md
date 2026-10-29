# Configuração de conexão Supabase

A conexão ainda não foi validada e nenhuma migration foi aplicada ao projeto Supabase.

`VITE_SUPABASE_URL` precisa ser a URL-base HTTPS da API do projeto, sem `/rest/v1`, colchetes ou formatação Markdown. A chave pública é usada pelo frontend; service_role e a URI PostgreSQL não podem entrar no bundle.

A URI do PostgreSQL deve ser copiada do botão **Connect** no painel do projeto. Escolher **Session pooler** quando a rede exige IPv4. Copiar host, porta e usuário exatamente como fornecidos pelo Supabase; não inferir o host a partir da região. Substituir o marcador de senha pela senha real do banco e codificar caracteres reservados para URL. Não incluir os colchetes dos exemplos na entrada final.[1]

A documentação diferencia API de dados e conexão PostgreSQL. Para o frontend basta URL de projeto e chave pública; para migrations é necessária uma conexão administrativa PostgreSQL. Session pooler usa porta 5432 e usuário que inclui a referência do projeto; a conexão direta pode depender de IPv6.[1]

Em 29/10/2026, as chaves de API foram aceitas em consultas de leitura no endereço-base inicialmente fornecido. As entradas corrigidas ainda falharam na validação estrutural: URL da API sem protocolo HTTPS válido e URI do banco com delimitadores inválidos. As mensagens originais e os valores fornecidos não são incluídos neste documento.

## Referências

[1]: https://supabase.com/docs/guides/database/connecting-to-postgres "Supabase — Connect to your database"
