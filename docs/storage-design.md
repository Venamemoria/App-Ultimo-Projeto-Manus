# Arquivos e fotos de produtos

Usar Supabase Storage privado para fotos e arquivos internos do ERP. Buckets privados aplicam RLS tanto no upload como no download; a leitura exige sessão autorizada ou URL assinada de duração limitada. Um bucket público ignora controles de leitura para quem possui a URL, por isso não deve ser o padrão para documentos de produção.[1]

O caminho de objeto deve carregar organização e identificador do recurso, e a policy deve validar a membership/papel do usuário antes de aceitar escrita. Upload por API exige INSERT em storage.objects; sobrescrita por upsert exige também SELECT e UPDATE. O ERP deve preferir nomes de arquivo únicos e registrar o caminho no recurso depois da transferência, sem publicar um arquivo fictício ou tratar falha de upload como sucesso.[2]

Limites de tamanho e MIME são configurados no bucket e também validados na interface. Fotos aceitas serão JPG/PNG/WebP reais enviados pelo usuário, não imagens de produto geradas para simular catálogo. Documentos internos e arquivos digitais precisam de políticas próprias de recurso/organização. A service_role não entra no frontend; ela contorna RLS e só pode ser usada por funções server-side confiáveis.[2]

Essas decisões são preparação da próxima fatia; não afirmam que um bucket ou upload de produto já esteja configurado. Nenhum arquivo demonstrativo foi enviado ao Storage.

## Referências

[1]: https://supabase.com/docs/guides/storage/buckets/fundamentals "Supabase — Storage Buckets"
[2]: https://supabase.com/docs/guides/storage/security/access-control "Supabase — Storage Access Control"
