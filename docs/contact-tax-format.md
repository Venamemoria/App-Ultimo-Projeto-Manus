# Formato de CPF/CNPJ no cadastro

O cadastro aceita CPF numérico de 11 posições e CNPJ de 14 posições, numérico ou alfanumérico. O formato novo mantém 12 caracteres A–Z/0–9 e dois dígitos finais numéricos. CNPJs antigos permanecem inalterados; os formatos coexistem. A implantação oficial do primeiro CNPJ alfanumérico foi anunciada para 31/07/2026. Portanto, o app não deve descartar letras de um identificador empresarial digitado/importado.[1] [2] [3]

A UI remove somente a máscara/espaços, preserva letras e zeros iniciais e normaliza maiúsculas. O backend valida o formato, não declara verificação cadastral na Receita, titularidade, situação fiscal ou cálculo do dígito verificador. Nenhuma consulta de contribuinte ou submissão fiscal é realizada; dados são opcionais no cadastro privado do negócio.

## References

[1]: https://www.gov.br/receitafederal/pt-br/acesso-a-informacao/acoes-e-programas/programas-e-atividades/cnpj-alfanumerico "Receita Federal — CNPJ Alfanumérico"
[2]: https://agenciagov.ebc.com.br/noticias/202607/implantacao-do-cnpj-alfanumerico-ocorrera-a-partir-de-31-de-julho "Agência Gov — Implantação do CNPJ Alfanumérico"
[3]: https://www.gov.br/receitafederal/pt-br/centrais-de-conteudo/publicacoes/perguntas-e-respostas/cnpj/cnpj-alfanumerico.pdf "Receita Federal — Perguntas e respostas sobre CNPJ alfanumérico"
