# Clientes e fornecedores — referência

Em 29/10/2026 foram inspecionadas, somente em modo leitura e sessão autorizada, `https://papelariaon.com/dashboard/clientes.php?novo=1` e `https://papelariaon.com/dashboard/fornecedores.php`. Nenhum cliente/fornecedor foi cadastrado, importado, editado ou excluído. O documento contém somente campos e regras de interface, não valores privados.

Clientes usam lista, clientes com pedidos abertos e clientes sem pedidos. A busca inclui nome, contato, e-mail, cidade e estado. A lista mostra cliente, contato, e-mail, cidade/UF, pedidos e ações; há cadastro, importação CSV e exportação. Os filtros de pedidos exigem dados reais de pedidos, não indicadores estáticos.

O diálogo Novo cliente alterna pessoa física/jurídica. Identificação inclui nome obrigatório, CPF/CNPJ e nascimento quando aplicável; contato e e-mail. Endereço para frete inclui CEP, rua, número, bairro, complemento, cidade e UF. Dados incompletos de endereço não devem ser apresentados como válidos para solicitar frete. Nenhum CPF/CNPJ ou contato particular foi copiado.

Fornecedores usam lista lateral com busca e formulário de detalhes. Nome obrigatório, telefone, e-mail, CPF/CNPJ, site e observações (prazos, condições, frete e contatos). Há criar, limpar seleção, editar o selecionado e excluir. Indicadores mostram fornecedores, itens de estoque vinculados, quantidade e custo, tanto agregado como por fornecedor. Esses indicadores precisam derivar de registros reais e unidades distintas não devem ser somadas como se fossem uma única medida.

Cadastros devem manter FKs de organização, leitura RLS e escrita por papéis. Importação, deduplicação e exclusão preservam pedidos/compras históricos; não usar exclusão ampla sem intenção clara nem simular sucesso. Clientes/fornecedores sem dados mostram estado vazio verdadeiro. Filtros e ações que dependem das próximas migrations permanecem pendentes até terem contrato completo.
