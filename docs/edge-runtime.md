# Runtime de APIs Supabase

Frontend permanece Vite/React/Tailwind/Supabase. Funções server-side futuras usarão Supabase Edge Functions (Deno), não Express, TanStack Start, Nitro ou MySQL.

A instalação oficial do Deno aceita npm [1]. O validador fica fora do app em `/home/ubuntu/.local/venamemoria-deno`, sem mudar dependências da aplicação ou iniciar daemon. Versão efetiva é medida por `deno --version`. Apenas `deno check`/testes puros validam código; isso não comprova deploy Supabase, credentials, assinatura de callback real ou conexão de conta externa. Nenhuma função/API foi implantada por este registro.

A implantação efetiva das funções e seus secrets deve ocorrer no projeto Supabase autorizado, com chave administrativa apenas server-side. A prévia Vite não é um worker hospedado. Configuração ausente retorna indisponibilidade explícita, sem sucesso fictício.

## References

[1]: https://docs.deno.com/runtime/getting_started/installation/ "Deno official installation"
