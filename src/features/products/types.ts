import type { MembershipRole } from '../../lib/types';

export type PricingMode = 'unit' | 'variation' | 'm2';
export type BillingUnit = 'unit' | 'm2';
export type CompositionMode = 'inherit_base' | 'own';
export type ProductFileKind = 'photo' | 'digital' | 'production';
export type QuestionType = 'text' | 'textarea' | 'select' | 'boolean' | 'number';

export interface MaterialOption {
  id: string;
  organization_id: string;
  name: string;
  unit: string;
  unit_cost: string;
  stock_quantity: string;
}

export interface ProductDto {
  id: string;
  organization_id: string;
  name: string;
  category: string;
  categories: string[];
  subcategory: string | null;
  description: string | null;
  material_info: string | null;
  personalization_info: string | null;
  production_days: string;
  pricing_mode: PricingMode;
  price: string;
  promo_price: string | null;
  minimum_quantity: string;
  billing_unit: BillingUnit;
  is_catalog_visible: boolean;
  is_featured: boolean;
  custom_questions: CustomQuestion[];
  weight_kg: string | null;
  width_cm: string | null;
  height_cm: string | null;
  depth_cm: string | null;
  sku: string | null;
  barcode: string | null;
  wholesale_tiers: WholesaleTier[];
  current_version: string;
  current_composition_cost: string;
  current_material_cost?: string;
  created_at: string;
  updated_at: string;
}

export interface WholesaleTier {
  minimum_quantity: string;
  unit_price: string;
}

export interface ProductComponent {
  material_id: string;
  quantity: string;
  unit: string;
  unit_cost?: string;
  line_cost?: string;
}

export interface VariantSnapshot {
  id: string;
  name: string;
  sku: string | null;
  price: string;
  promo_price: string | null;
  active: boolean;
  minimum_quantity: string | null;
  composition_mode: CompositionMode;
  version?: string;
  composition_cost?: string | null;
  components: ProductComponent[];
}

export interface ProductVariantDto {
  id: string;
  organization_id: string;
  product_id: string;
  name: string;
  sku: string | null;
  price: string;
  promo_price: string | null;
  active: boolean;
  minimum_quantity: string | null;
  composition_mode: CompositionMode;
  current_version: string;
  created_at: string;
  updated_at: string;
}

export interface CustomQuestion {
  label: string;
  type: QuestionType;
  required: boolean;
  options?: string[];
}

export interface ProductVersionDto {
  organization_id: string;
  product_id: string;
  product_version: string;
  name: string;
  category: string;
  categories: string[];
  subcategory: string | null;
  description: string | null;
  material_info: string | null;
  personalization_info: string | null;
  production_days: string;
  pricing_mode: PricingMode;
  billing_unit: BillingUnit;
  price: string;
  promo_price: string | null;
  minimum_quantity: string;
  is_catalog_visible: boolean;
  is_featured: boolean;
  custom_questions: CustomQuestion[];
  weight_kg: string | null;
  width_cm: string | null;
  height_cm: string | null;
  depth_cm: string | null;
  sku: string | null;
  barcode: string | null;
  wholesale_tiers: WholesaleTier[];
  composition_snapshot: ProductComponent[];
  variants_snapshot: VariantSnapshot[];
  composition_cost: string;
  snapshot_metadata: Record<string, unknown>;
  created_by: string;
  created_at: string;
}

export interface ProductFileDto {
  id: string;
  organization_id: string;
  product_id: string;
  kind: ProductFileKind;
  path: string;
  mime_type: string;
  size_bytes: string;
  name: string;
  created_by: string;
  created_at: string;
  signed_url?: string;
}

export interface ProductFormValues {
  name: string;
  categories: string[];
  categoryInput: string;
  subcategory: string;
  description: string;
  materialInfo: string;
  personalizationInfo: string;
  productionDays: string;
  pricingMode: PricingMode;
  price: string;
  promoPrice: string;
  minimumQuantity: string;
  wholesaleTiers: WholesaleTier[];
  components: ProductComponent[];
  variants: VariantSnapshot[];
  weightKg: string;
  widthCm: string;
  heightCm: string;
  depthCm: string;
  sku: string;
  barcode: string;
  isCatalogVisible: boolean;
  isFeatured: boolean;
  customQuestions: CustomQuestion[];
}

export interface ProductEditSnapshot {
  product: ProductDto;
  version: ProductVersionDto;
  versionHistory: ProductVersionDto[];
  variants: VariantSnapshot[];
  files: ProductFileDto[];
}

export interface ProductUpsertInput {
  organizationId: string;
  productId: string | null;
  idempotencyKey: string;
  values: ProductFormValues;
}

export interface ProductUpsertResult {
  product_id: string;
  version: string;
  pricing_mode: PricingMode;
  normal_price: string;
  promo_price: string | null;
  minimum_quantity: string;
  component_count: number;
  composition_cost: string;
}

export interface ProductFileUploadInput {
  organizationId: string;
  productId: string;
  kind: ProductFileKind;
  file: File;
}

export const canManageProducts = (role: MembershipRole | null): boolean => role === 'owner' || role === 'admin' || role === 'production';
export const canEditProducts = canManageProducts;
export const canReadProducts = (role: MembershipRole | null): boolean => Boolean(role);

export const emptyFormValues = (): ProductFormValues => ({
  name: '',
  categories: [],
  categoryInput: '',
  subcategory: '',
  description: '',
  materialInfo: '',
  personalizationInfo: '',
  productionDays: '0',
  pricingMode: 'unit',
  price: '',
  promoPrice: '',
  minimumQuantity: '1',
  wholesaleTiers: [],
  components: [],
  variants: [],
  weightKg: '',
  widthCm: '',
  heightCm: '',
  depthCm: '',
  sku: '',
  barcode: '',
  isCatalogVisible: false,
  isFeatured: false,
  customQuestions: [],
});

export function formValuesFromSnapshot(snapshot: ProductEditSnapshot): ProductFormValues {
  const { product, version } = snapshot;
  return {
    name: version.name,
    categories: version.categories?.length ? version.categories : [version.category],
    categoryInput: '',
    subcategory: version.subcategory ?? '',
    description: version.description ?? '',
    materialInfo: version.material_info ?? '',
    personalizationInfo: version.personalization_info ?? '',
    productionDays: version.production_days,
    pricingMode: version.pricing_mode,
    price: version.price,
    promoPrice: version.promo_price ?? '',
    minimumQuantity: version.minimum_quantity,
    wholesaleTiers: version.wholesale_tiers ?? [],
    components: version.composition_snapshot ?? [],
    variants: snapshot.variants.length ? snapshot.variants : version.variants_snapshot ?? [],
    weightKg: version.weight_kg ?? '',
    widthCm: version.width_cm ?? '',
    heightCm: version.height_cm ?? '',
    depthCm: version.depth_cm ?? '',
    sku: version.sku ?? product.sku ?? '',
    barcode: version.barcode ?? product.barcode ?? '',
    isCatalogVisible: version.is_catalog_visible,
    isFeatured: version.is_featured,
    customQuestions: version.custom_questions ?? [],
  };
}
