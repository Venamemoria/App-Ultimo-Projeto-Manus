# UI de clientes e fornecedores

Status: **implementado no frontend e conectado ao contrato Supabase de contatos**. A migration de contatos já aplicada não foi alterada. Esta implementação não criou, importou ou publicou nenhum cadastro real durante o desenvolvimento; a aplicação continua dependente de uma sessão Supabase Auth e da organização escolhida nessa sessão.

## Rotas e acesso

- `/clientes` e `/fornecedores` são lazy, protegidas por sessão e renderizadas dentro do `AppLayout`.
- O menu lateral apresenta as duas rotas sob **Relacionamento**.
- A lista usa a organização ativa e a chave de consulta inclui `organization_id`. A troca de organização remonta a página e reinicia formulário, retry, preview e estado de importação.
- `owner`, `admin` e `finance` podem criar, editar, importar e arquivar/recuperar. `production` e `viewer` consultam os registros, mas não recebem ações de mutação na UI. A autorização definitiva permanece nas RPCs/RLS do backend.

## Lista, detalhe e status

As views `vm_clients_read` e `vm_suppliers_read` são consultadas com paginação por cursor, `count: exact` e sem truncamento silencioso. O filtro local pesquisa nome, contato, e-mail, cidade, UF, CPF/CNPJ e, para fornecedores, site. A lista separa **Ativos**, **Arquivados** e **Todos**. O detalhe mostra identificação, contato, endereço com as sete chaves, observações e site somente como link `http://`/`https://` seguro, sem execução de JavaScript.

Arquivar e recuperar usam `vm_archive_contact`, exigem motivo, pedem confirmação e preservam a linha, referências e eventos append-only. Não existe exclusão física na UI.

A página de clientes mostra somente totais derivados do array real carregado. Não há filtros ou indicadores de pedidos: o contrato atual não possui `order_count` nem equivalente. A página de fornecedores mostra `material_count`, `current_stock_cost` e `stocks_by_unit` recebidos da view. Custos e quantidades são tratados como decimais textuais; unidades distintas nunca são somadas como uma medida única.

## Formulário e payload

O formulário comum cobre nome obrigatório, pessoa física/jurídica, CPF/CNPJ opcional, telefone, e-mail, endereço (CEP, rua, número, bairro, complemento, cidade e UF) e observações. Cliente pessoa física pode informar nascimento; fornecedor aceita site opcional. O endereço é enviado com valores vazios como `null`, não como string vazia, e uma edição envia a intenção completa para limpar campos antigos.

CPF/CNPJ é normalizado removendo apenas `.`, `/`, `-` e espaços e convertendo letras para maiúsculas. O CNPJ alfanumérico e zeros iniciais são preservados. A validação é de formato; a UI não declara existência, titularidade, cálculo de dígito verificador ou situação fiscal verificada.

`vm_upsert_contact` recebe um UUID de idempotência. Criar e editar preservam a mesma chave quando o usuário repete exatamente o payload após erro; alterar o formulário cria nova tentativa. Um erro de rede não é descrito como rollback: a mensagem orienta repetir sem mudar os dados para consultar o mesmo resultado idempotente.

## CSV

O parser próprio aceita UTF-8 com BOM, `;` ou `,`, campos entre aspas, aspas escapadas e quebras de linha CRLF/LF dentro de campos. Cabeçalhos desconhecidos, duplicados, linhas malformadas e lotes acima de 500 linhas são rejeitados antes da chamada. A prévia exibe somente linhas realmente lidas do arquivo selecionado.

A importação chama explicitamente `vm_import_contacts` com as linhas analisadas e uma chave de lote estável para retry exato. O retorno mostra os textos reais de `created`, `updated` e `skipped`; não há contadores simulados nem atualização automática de cadastro por CPF/CNPJ.

A exportação usa apenas as linhas filtradas reais, BOM UTF-8, campos entre aspas, escape de aspas e CRLF. Valores iniciados por `=`, `+`, `-` ou `@` recebem proteção contra fórmula de planilha; telefones continuam representados integralmente no arquivo. Nenhuma exportação foi executada durante esta implementação.
