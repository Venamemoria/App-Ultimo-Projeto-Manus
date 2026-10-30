# Tabela de preços e calculadora — inspeção de referências

**Status:** parcial. A Tabela de Preços e a Calculadora foram verificadas no AtelierFlow. No PapelariaOn, a rota autorizada do dashboard foi verificada, mas não expõe texto ou link visível com esses nomes; não foram abertos módulos adjacentes para tentar inferir um fluxo.

## AtelierFlow — Tabela de Preços

A entrada foi observada na navegação lateral de `/pedidos` pelo link real **Tabela de Preços**, com destino `/tabela-precos`. A página aberta exibe o título **Tabela de Preços** e o bloco **Padronização do Ateliê**, com microcopy sobre manter preços e categorias atualizados para orçamentos rápidos e precisos. [1] [2]

Elementos e rótulos visíveis:

- Link **Configurações de Serviços Adicionais**, com destino observado `/configuracoes?tab=additional-services`.
- Abas/controles **Lista de Serviços** e **Categorias**.
- Link **Serviços Adicionais**, apontando para `/configuracoes?tab=additional-services`.
- Link **Histórico de Reajustes**, com destino observado `/implementando`; o destino não foi executado e não é tratado como recurso funcionando.
- Campo de busca com placeholder **Pesquisar por nome do serviço ou descrição...**.
- Controles **Planilhas**, **Catálogo**, **Adicionais**, **Novo Serviço** e **Exportar para o Catálogo**.
- Filtro/controle **Todos os Serviços** e ordenação/colunas acionáveis **NOME DO SERVIÇO** e **CATEGORIA**.
- Tabela com colunas **Nome do Serviço**, **Categoria**, **Complexidade** e **Valor Padrão**.
- Estado vazio **Nenhum serviço encontrado.**
- Ação **Novo Serviço** e ação **Exportar para o Catálogo** permaneceram sem execução, conforme a restrição de não cadastrar, salvar ou exportar.

A página não foi alterada. Não foram copiados nomes de conta, clientes ou valores privados.

## AtelierFlow — Calculadora

A entrada foi observada na navegação lateral de `/pedidos` pelo link real **Calculadora**, com destino `/calculadora`. A página aberta exibe **Calculadora de Orçamentos**. A microcopy informa que o preço final considera material, hora da profissional, custo do ateliê/imóvel e meta de margem de lucro. Também informa que o resultado pode ser salvo no catálogo, mas essa ação não foi executada. [1] [3]

Fluxo, campos e rótulos visíveis, sem preenchimento:

1. **Identificação**
   - **Nome do Produto/Serviço**.
   - **Categoria / Nicho**.
   - **Descrição (Opcional)**.
2. **Custos de Mão de Obra e Operação**
   - Grupo **Profissional**: **Custo da Hora (R$)** e **Total de Horas**.
   - Grupo **Ateliê (Imóvel)**, com indicação **Mensal**: **Custo da Hora (R$)** e **Total de Horas**.
3. **Materiais & Insumos**
   - Botão **Novo Material**.
   - Estado vazio **Nenhum material adicionado a este orçamento.**
   - Orientação para usar o botão para puxar insumos do estoque ou adicionar manualmente.
4. **Margem & Precificação**
   - **Tipo de Margem**.
   - Opções observadas: **Porcentagem (%)** e **Valor Fixo (R$)**.
   - **Margem Alvo (%)**.
   - **Preço de Venda**, com indicação **Manual** e microcopy de recálculo automático da margem e do lucro.
5. **Resultado**
   - **Preço Final / Sugerido**.
   - Indicadores **Margem** e **Markup**.
   - **Resumo de Custos**, com **Mão de Obra**, **Imóvel/Ateliê**, **Materiais** e **Custo Total**.
   - **Resumo de Lucro & Margens**, com **Lucro Líquido Estimado**, **Margem de Lucro** e **Markup (Multiplicador)**.
6. **Ações**
   - **Imprimir Orçamento**.
   - **Salvar Orçamento**.

A guia rápida mostra as etapas **Identificação**, **Mão de Obra**, **Custo do Ateliê**, **Materiais**, **Margem & Lucro** e **Salvar**. Nenhum campo foi preenchido, nenhum material foi adicionado, nenhum cálculo dependente de entrada foi disparado e nenhuma ação de impressão ou salvamento foi executada. Portanto, a inspeção confirma os campos, opções, microcopy e organização, mas não comprova cálculo com dados de entrada nem persistência do orçamento.

## PapelariaOn — verificação da rota autorizada

Na rota autorizada do dashboard, a navegação visível usa os grupos **Vendas**, **Produtos**, **Clientes**, **Financeiro**, **Relatórios**, **Catálogo** e **Configurações**. Não foi encontrado texto contendo **Calculadora** nem **Tabela de Preços** na página por busca textual da interface. [4]

A inspeção foi encerrada nessa rota. O menu **Produtos** não foi aberto, pois isso iniciaria a pesquisa de outro módulo e não permitiria afirmar que existe uma Tabela de Preços ou Calculadora equivalente. Não foi inferida integração, cálculo ou paridade a partir da simples existência de produtos, catálogo ou preços em outros fluxos.

## Restrições e bloqueios

- A sessão autenticada estava disponível e não houve bloqueio de login.
- Não foram preenchidos campos, enviados formulários, cadastrados serviços/materiais/produtos, salvos orçamentos, exportados dados, baixados CSV, emitidas notas, efetuados pagamentos, trocadas configurações ou consumidos créditos.
- A referência do PapelariaOn não expôs o módulo solicitado na única rota autorizada; localizar uma possível tela equivalente exigiria abrir outros módulos ou usar URLs não observadas, o que ficou fora do escopo.
- Este relatório descreve somente observação de interface e não afirma paridade implementada.

## Referências

[1]: https://www.atelierflow.com.br/pedidos "AtelierFlow — Pedidos e navegação lateral"
[2]: https://www.atelierflow.com.br/tabela-precos "AtelierFlow — Tabela de Preços"
[3]: https://www.atelierflow.com.br/calculadora "AtelierFlow — Calculadora de Orçamentos"
[4]: https://papelariaon.com/dashboard/index.php "PapelariaOn — Dashboard"
