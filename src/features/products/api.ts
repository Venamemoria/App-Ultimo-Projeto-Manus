import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase, supabaseConfigError } from '../../lib/supabase';
import { useSession } from '../../app/AuthProvider';
import { canViewFinance } from '../../lib/permissions';
import { Decimal, decimalString, parseDecimalInput } from '../../lib/decimal';
import type { MaterialDto } from '../inventory/types';
import type {
  ProductDto,
  ProductEditSnapshot,
  ProductFileDto,
  ProductFileKind,
  ProductFileUploadInput,
  ProductFormValues,
  ProductUpsertInput,
  ProductOperationsInput,
  ProductOperationsResult,
  ProductUpsertResult,
  ProductVariantDto,
  ProductVersionDto,
  VariantSnapshot,
} from './types';

const PAGE_SIZE = 1000;
const MAX_PAGES = 100;
const BUCKET = 'vm-product-media';

export const productsQueryKeys = {
  all: (organizationId: string) => ['products', 'all', organizationId] as const,
  materials: (organizationId: string) => ['products', 'materials', organizationId] as const,
  detail: (organizationId: string, productId: string) => ['products', 'detail', organizationId, productId] as const,
};

function getClient() {
  if (!supabase) throw new Error(supabaseConfigError ?? 'O serviço de dados está indisponível neste ambiente.');
  return supabase;
}

function rows<T>(data: unknown): T[] {
  if (Array.isArray(data)) return data as T[];
  if (data && typeof data === 'object') return [data as T];
  return [];
}

function publicDatabaseError(error: { code?: string | null; message?: string | null } | null, fallback: string): Error {
  if (!error) return new Error(fallback);
  if (error.code === 'VM002') return new Error('Um produto sem consumo de estoque não pode ter composição ativa de insumos. Remova a receita ou escolha consumo de materiais.');
  if (error.code === '42501') return new Error('Seu papel não permite alterar produtos nesta organização.');
  if (error.code === '40001') return new Error('O produto mudou desde a abertura. Feche e recarregue antes de editar novamente.');
  if (error.code === '23505') return new Error('Já existe um produto, SKU, código de barras ou tentativa com estes dados. Se a operação ficou pendente, tente novamente sem mudar o formulário.');
  if (error.code === '23503') return new Error('O produto, organização, material ou arquivo não está disponível nesta organização.');
  if (error.code === '23514') return new Error('A unidade da composição, o preço ou outro valor não passou nas regras do banco.');
  if (['22003', '22023', '22P02'].includes(error.code ?? '')) return new Error('Confira os valores e a precisão decimal. Se esta tentativa já foi enviada, mantenha exatamente os mesmos dados.');
  return new Error(fallback);
}

export function userFacingProductError(error: unknown, fallback = 'Não foi possível concluir esta ação agora.') {
  return error instanceof Error && error.message ? error.message : fallback;
}

async function fetchPaged<T>(table: string, organizationId: string, columns: string, fallback: string): Promise<T[]> {
  const result: T[] = [];
  let cursor: string | null = null;
  for (let page = 0; page < MAX_PAGES; page += 1) {
    let query = getClient().from(table).select(columns, { count: 'exact' })
      .eq('organization_id', organizationId).order('id', { ascending: true }).limit(PAGE_SIZE);
    if (cursor) query = query.gt('id', cursor);
    const { data, error, count } = await query;
    if (error) throw publicDatabaseError(error, fallback);
    const batch = (data ?? []) as unknown as Array<T & { id: string }>;
    result.push(...batch);
    // PostgREST count includes the cursor filter: it counts remaining rows, not
    // the accumulated result. Short pages can also reflect a server row limit.
    if (!batch.length || (count !== null && batch.length >= count)) return result;
    const next = batch[batch.length - 1]?.id;
    if (typeof next !== 'string' || next === cursor) throw new Error(fallback);
    cursor = next;
  }
  throw new Error('A consulta ultrapassou o limite seguro. Restrinja os dados antes de tentar novamente.');
}

async function callRpc<T>(name: string, params: Record<string, unknown>, fallback: string): Promise<T> {
  const { data, error } = await getClient().rpc(name, params);
  if (error) throw publicDatabaseError(error, fallback);
  const result = rows<T>(data)[0];
  if (!result) throw new Error(fallback);
  return result;
}

async function signedFile(file: ProductFileDto): Promise<ProductFileDto> {
  const { data, error } = await getClient().storage.from(BUCKET).createSignedUrl(file.path, 600);
  return error || !data?.signedUrl ? file : { ...file, signed_url: data.signedUrl };
}

export async function fetchMaterialsForProducts(organizationId: string): Promise<MaterialDto[]> {
  return fetchPaged<MaterialDto>('vm_materials_read', organizationId, 'id, organization_id, name, category, unit, package_cost, package_quantity, unit_cost, stock_quantity, reorder_level, is_low_stock, supplier_id, created_at, updated_at', 'Não foi possível carregar os materiais para a composição.');
}

export async function fetchProductFiles(organizationId: string, productId?: string): Promise<ProductFileDto[]> {
  const files = productId
    ? await (async () => {
      const { data, error, count } = await getClient().from('vm_product_files_read').select('*', { count: 'exact' }).eq('organization_id', organizationId).eq('product_id', productId).order('created_at', { ascending: false }).limit(PAGE_SIZE);
      if (error) throw publicDatabaseError(error, 'Não foi possível carregar os arquivos do produto.');
      if (count !== null && count > (data?.length ?? 0)) throw new Error('Este produto excede o limite de arquivos por consulta. Não foi apresentada uma lista parcial.');
      return (data ?? []) as ProductFileDto[];
    })()
    : await fetchPaged<ProductFileDto>('vm_product_files_read', organizationId, '*', 'Não foi possível carregar os arquivos dos produtos.');
  return Promise.all(files.map((file) => signedFile(file)));
}

export async function fetchProducts(organizationId: string): Promise<ProductDto[]> {
  const [products, files] = await Promise.all([
    fetchPaged<ProductDto>('vm_products_read', organizationId, '*', 'Não foi possível carregar os produtos.'),
    fetchProductFiles(organizationId),
  ]);
  const photoByProduct = new Map<string, ProductFileDto>();
  for (const file of files) if (file.kind === 'photo' && !photoByProduct.has(file.product_id)) photoByProduct.set(file.product_id, file);
  return products.map((product) => ({
    ...product,
    categories: Array.isArray(product.categories) ? product.categories : [],
    custom_questions: Array.isArray(product.custom_questions) ? product.custom_questions : [],
    wholesale_tiers: Array.isArray(product.wholesale_tiers) ? product.wholesale_tiers : null,
    ...(photoByProduct.get(product.id)?.signed_url ? { thumbnail_url: photoByProduct.get(product.id)?.signed_url } : {}),
  })) as ProductDto[];
}

export async function fetchProductDetail(organizationId: string, productId: string): Promise<ProductEditSnapshot> {
  const client = getClient();
  const { data: productData, error: productError } = await client.from('vm_products_read').select('*').eq('organization_id', organizationId).eq('id', productId).limit(1);
  if (productError) throw publicDatabaseError(productError, 'Não foi possível carregar o produto.');
  const product = (productData?.[0] ?? null) as ProductDto | null;
  if (!product) throw new Error('Produto não encontrado nesta organização.');

  const [versionResult, variantResult, files] = await Promise.all([
    client.from('vm_product_versions_read').select('*', { count: 'exact' }).eq('organization_id', organizationId).eq('product_id', productId).order('created_at', { ascending: false }).limit(PAGE_SIZE),
    client.from('vm_product_variants_read').select('*', { count: 'exact' }).eq('organization_id', organizationId).eq('product_id', productId).order('id', { ascending: true }).limit(PAGE_SIZE),
    fetchProductFiles(organizationId, productId),
  ]);
  if (versionResult.error) throw publicDatabaseError(versionResult.error, 'Não foi possível carregar a versão atual do produto.');
  if (variantResult.error) throw publicDatabaseError(variantResult.error, 'Não foi possível carregar as variações do produto.');
  if ((versionResult.count !== null && versionResult.count > (versionResult.data?.length ?? 0)) || (variantResult.count !== null && variantResult.count > (variantResult.data?.length ?? 0))) throw new Error('Este produto excede o limite seguro de versões ou variações por consulta. Nenhum histórico parcial foi usado para edição.');
  const versionHistory = ((versionResult.data ?? []) as ProductVersionDto[]).sort((left, right) => new Decimal(right.product_version).cmp(new Decimal(left.product_version)));
  const version = versionHistory.find((item) => item.product_version === product.current_version);
  if (!version) throw new Error('A versão atual do produto não está disponível para edição.');
  const snapshotVariants = Array.isArray(version.variants_snapshot) ? version.variants_snapshot : [];
  const variants = snapshotVariants.length ? snapshotVariants : (variantResult.data ?? []).map((variant) => ({ ...variant, components: [] })) as VariantSnapshot[];
  return { product, version: { ...version, composition_snapshot: Array.isArray(version.composition_snapshot) ? version.composition_snapshot : [], variants_snapshot: snapshotVariants }, versionHistory, variants, files };
}

function decimalParam(value: string, label: string, positive = false): string {
  return decimalString(parseDecimalInput(value, { positive, scale: 8 }));
}

function optionalDecimalParam(value: string, label: string, positive = true): string | null {
  if (!value.trim()) return null;
  return decimalParam(value, label, positive);
}

function variantPayload(variant: VariantSnapshot) {
  const payload: Record<string, unknown> = {
    name: variant.name.trim(),
    sku: variant.sku?.trim() || null,
    price: decimalParam(variant.price ?? '', 'Preço da variação'),
    promo_price: variant.promo_price?.trim() ? decimalParam(variant.promo_price, 'Preço promocional da variação') : null,
    active: variant.active,
    minimum_quantity: variant.minimum_quantity?.trim() ? decimalParam(variant.minimum_quantity, 'Quantidade mínima da variação', true) : null,
    composition_mode: variant.composition_mode,
  };
  if (variant.id?.trim()) payload.id = variant.id;
  if (variant.composition_mode === 'own') {
    payload.components = variant.components.map((component) => ({ material_id: component.material_id, quantity: decimalParam(component.quantity, 'Quantidade da composição', true), unit: component.unit }));
  }
  return payload;
}

export function productRpcParams(input: ProductUpsertInput): Record<string, unknown> {
  const values = input.values;
  const categories = Array.from(new Set([values.categories[0], ...values.categories].map((value) => value.trim()).filter(Boolean)));
  const productionDays = Number(values.productionDays);
  if (!Number.isInteger(productionDays) || productionDays < 0 || productionDays > 10000) throw new Error('Dias de produção deve ser um número inteiro entre 0 e 10.000.');
  return {
    p_organization_id: input.organizationId,
    p_name: values.name.trim(),
    p_category: categories[0] ?? '',
    p_categories: categories,
    p_subcategory: values.subcategory.trim() || null,
    p_description: values.description || null,
    p_material_info: values.materialInfo || null,
    p_personalization_info: values.personalizationInfo || null,
    p_production_days: productionDays,
    p_pricing_mode: values.pricingMode,
    p_price: decimalParam(values.price, 'Preço'),
    p_promo_price: optionalDecimalParam(values.promoPrice, 'Preço promocional', false),
    p_minimum_quantity: decimalParam(values.minimumQuantity, 'Quantidade mínima', true),
    p_billing_unit: values.pricingMode === 'm2' ? 'm2' : 'unit',
    p_is_catalog_visible: values.isCatalogVisible,
    p_is_featured: values.isFeatured,
    p_custom_questions: values.customQuestions.map((question) => ({ ...question, label: question.label.trim(), options: question.type === 'select' ? (question.options ?? []).map((option) => option.trim()).filter(Boolean) : undefined })),
    p_weight_kg: optionalDecimalParam(values.weightKg, 'Peso'),
    p_width_cm: optionalDecimalParam(values.widthCm, 'Largura'),
    p_height_cm: optionalDecimalParam(values.heightCm, 'Altura'),
    p_depth_cm: optionalDecimalParam(values.depthCm, 'Profundidade'),
    p_sku: values.sku.trim() || null,
    p_barcode: values.barcode.trim() || null,
    p_wholesale_tiers: values.wholesaleTiers.map((tier) => ({ minimum_quantity: decimalParam(tier.minimum_quantity, 'Quantidade da faixa', true), unit_price: decimalParam(tier.unit_price, 'Preço da faixa') })),
    p_components: values.components.map((component) => ({ material_id: component.material_id, quantity: decimalParam(component.quantity, 'Quantidade da composição', true), unit: component.unit })),
    p_variants: values.variants.map(variantPayload),
    p_product_id: input.productId,
    p_idempotency_key: input.idempotencyKey,
  };
}

export async function upsertProduct(input: ProductUpsertInput): Promise<ProductUpsertResult> {
  const { p_organization_id, p_idempotency_key, ...p_data } = productRpcParams(input);
  return callRpc<ProductUpsertResult>('vm_upsert_product_v3', { p_organization_id, p_idempotency_key, p_data, p_inventory_mode: input.values.inventoryMode }, 'Não foi possível salvar o produto.');
}

// Explicit allowlist: neither live nor frozen financial fields are sent by
// the operational editor. The RPC rechecks membership and preserves prices.
export function productOperationsRpcParams(input: ProductOperationsInput): Record<string, unknown> {
  const expectedVersion = Number(input.expectedVersion);
  const productionDays = Number(input.productionDays);
  if (!Number.isSafeInteger(expectedVersion) || expectedVersion < 1) throw new Error('Versão do produto inválida; recarregue.');
  if (!/^\d+$/.test(input.productionDays.trim()) || !Number.isInteger(productionDays) || productionDays < 0 || productionDays > 10000) throw new Error('Dias de produção deve ser um inteiro entre 0 e 10.000.');
  const components = (items: ProductOperationsInput['components']) => items.map((component) => ({
    material_id: component.material_id, quantity: decimalParam(component.quantity, 'Quantidade da composição', true), unit: component.unit,
  }));
  if (input.variants.some((variant) => !variant.id)) throw new Error('Uma variação não está identificada; recarregue o produto.');
  return {
    p_organization_id: input.organizationId,
    p_product_id: input.productId,
    p_expected_version: expectedVersion,
    p_idempotency_key: input.idempotencyKey,
    p_inventory_mode: input.inventoryMode,
    p_data: {
      description: input.description || null,
      material_info: input.materialInfo || null,
      personalization_info: input.personalizationInfo || null,
      production_days: productionDays,
      components: components(input.components),
      variants: input.variants.map((variant) => ({ id: variant.id, composition_mode: variant.composition_mode,
        components: variant.composition_mode === 'own' ? components(variant.components) : [] })),
    },
  };
}

export async function updateProductOperations(input: ProductOperationsInput): Promise<ProductOperationsResult> {
  return callRpc<ProductOperationsResult>('vm_update_product_operations', productOperationsRpcParams(input), 'Não foi possível salvar os dados de produção.');
}

export function useProductOperationsMutation(organizationId: string | null) {
  const queryClient = useQueryClient();
  return useMutation({ mutationFn: updateProductOperations, onSettled: async (_result, _error, input) => {
    if (!organizationId) return;
    await Promise.all([
      queryClient.invalidateQueries({ queryKey: productsQueryKeys.all(organizationId) }),
      queryClient.invalidateQueries({ queryKey: productsQueryKeys.detail(organizationId, input.productId) }),
    ]);
  } });
}

function fileExtension(file: File): string {
  const byMime: Record<string, string> = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp', 'application/pdf': 'pdf', 'application/zip': 'zip' };
  return byMime[file.type] ?? 'bin';
}

export class ProductFileRegistrationError extends Error {
  readonly path: string;
  constructor(path: string, message: string) { super(message); this.name = 'ProductFileRegistrationError'; this.path = path; }
}

export async function uploadAndRegisterProductFile(input: ProductFileUploadInput): Promise<ProductFileDto> {
  if (input.file.size > 52428800) throw new Error('O arquivo ultrapassa o limite de 50 MiB.');
  const path = `${input.organizationId}/${input.productId}/${globalThis.crypto.randomUUID()}.${fileExtension(input.file)}`;
  const { error: uploadError } = await getClient().storage.from(BUCKET).upload(path, input.file, { upsert: false, contentType: input.file.type });
  if (uploadError) throw new Error(`Não foi possível enviar o arquivo: ${uploadError.message}`);
  const registered = await getClient().rpc('vm_register_product_file', {
    p_organization_id: input.organizationId,
    p_product_id: input.productId,
    p_kind: input.kind,
    p_path: path,
    p_mime_type: input.file.type,
    p_size_bytes: input.file.size,
    p_name: input.file.name,
  });
  if (registered.error) throw new ProductFileRegistrationError(path, publicDatabaseError(registered.error, 'O upload foi concluído, mas o registro do arquivo falhou. Tente registrar novamente sem reenviar o arquivo.').message);
  const file = rows<ProductFileDto>(registered.data)[0];
  if (!file) throw new ProductFileRegistrationError(path, 'O upload foi concluído, mas não recebemos os metadados do arquivo.');
  return signedFile(file);
}

export async function registerExistingProductFile(input: Omit<ProductFileUploadInput, 'file'> & { path: string; mimeType: string; sizeBytes: number; name: string }): Promise<ProductFileDto> {
  const result = await callRpc<ProductFileDto>('vm_register_product_file', {
    p_organization_id: input.organizationId,
    p_product_id: input.productId,
    p_kind: input.kind,
    p_path: input.path,
    p_mime_type: input.mimeType,
    p_size_bytes: input.sizeBytes,
    p_name: input.name,
  }, 'Não foi possível registrar o arquivo já enviado.');
  return signedFile(result);
}

export function useProductsQuery(organizationId: string | null) {
  const { currentMembershipRole } = useSession();
  const scope = canViewFinance(currentMembershipRole) ? 'financial' : 'operational';
  return useQuery({ queryKey: organizationId ? [...productsQueryKeys.all(organizationId), scope] : ['products', 'all', 'no-organization'], queryFn: () => fetchProducts(organizationId!), enabled: Boolean(organizationId && currentMembershipRole), refetchOnWindowFocus: 'always', refetchInterval: 30_000 });
}

export function useProductMaterialsQuery(organizationId: string | null) {
  const { currentMembershipRole } = useSession();
  const scope = canViewFinance(currentMembershipRole) ? 'financial' : 'operational';
  return useQuery({ queryKey: organizationId ? [...productsQueryKeys.materials(organizationId), scope] : ['products', 'materials', 'no-organization'], queryFn: () => fetchMaterialsForProducts(organizationId!), enabled: Boolean(organizationId && currentMembershipRole), refetchOnWindowFocus: 'always', refetchInterval: 30_000 });
}

export function useProductDetailQuery(organizationId: string | null, productId: string | null) {
  const { currentMembershipRole } = useSession();
  const scope = canViewFinance(currentMembershipRole) ? 'financial' : 'operational';
  return useQuery({ queryKey: organizationId && productId ? [...productsQueryKeys.detail(organizationId, productId), scope] : ['products', 'detail', 'none'], queryFn: () => fetchProductDetail(organizationId!, productId!), enabled: Boolean(organizationId && productId && currentMembershipRole), refetchOnWindowFocus: 'always' });
}

export function useUpsertProductMutation(organizationId: string | null) {
  const queryClient = useQueryClient();
  return useMutation({ mutationFn: upsertProduct, onSuccess: async (result) => {
    if (!organizationId) return;
    await queryClient.invalidateQueries({ queryKey: productsQueryKeys.all(organizationId) });
    await queryClient.invalidateQueries({ queryKey: productsQueryKeys.detail(organizationId, result.product_id) });
  } });
}

export function useProductFileMutation(organizationId: string | null) {
  const queryClient = useQueryClient();
  return useMutation({ mutationFn: uploadAndRegisterProductFile, onSuccess: async (file) => {
    if (!organizationId) return;
    await queryClient.invalidateQueries({ queryKey: productsQueryKeys.all(organizationId) });
    await queryClient.invalidateQueries({ queryKey: productsQueryKeys.detail(organizationId, file.product_id) });
  } });
}

export function productFileKindLabel(kind: ProductFileKind): string {
  return kind === 'photo' ? 'Foto' : kind === 'digital' ? 'Arquivo digital' : 'Arquivo de produção';
}

export type { ProductVariantDto };
