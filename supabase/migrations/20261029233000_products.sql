BEGIN;

-- Products extends the foundation catalog without replacing legacy columns or
-- historical component rows. All new numeric values are validated before the
-- numeric(20,8) boundary and are kept exact until a future billing boundary.
CREATE OR REPLACE FUNCTION vm_private.vm_json_text_array_valid(p_value jsonb)
RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = ''
AS $function$
  SELECT CASE
    WHEN p_value IS NULL OR pg_catalog.jsonb_typeof(p_value) <> 'array' THEN false
    ELSE NOT EXISTS (
      SELECT 1
      FROM pg_catalog.jsonb_array_elements(p_value) AS e(value)
      WHERE pg_catalog.jsonb_typeof(e.value) <> 'string'
         OR pg_catalog.btrim(e.value #>> '{}') = ''
         OR pg_catalog.char_length(e.value #>> '{}') > 120
    )
    AND (
      SELECT pg_catalog.count(*) = pg_catalog.count(DISTINCT e.value #>> '{}')
      FROM pg_catalog.jsonb_array_elements(p_value) AS e(value)
    )
  END
$function$;

CREATE OR REPLACE FUNCTION vm_private.vm_custom_questions_valid(p_value jsonb)
RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = ''
AS $function$
  SELECT CASE
    WHEN p_value IS NULL OR pg_catalog.jsonb_typeof(p_value) <> 'array' THEN false
    ELSE NOT EXISTS (
      SELECT 1
      FROM pg_catalog.jsonb_array_elements(p_value) AS e(value)
      WHERE pg_catalog.jsonb_typeof(e.value) <> 'object'
         OR NOT (e.value ? 'label')
         OR pg_catalog.jsonb_typeof(e.value -> 'label') IS DISTINCT FROM 'string'
         OR pg_catalog.btrim(e.value ->> 'label') = ''
         OR pg_catalog.char_length(e.value ->> 'label') > 200
         OR NOT (e.value ? 'type')
         OR pg_catalog.jsonb_typeof(e.value -> 'type') IS DISTINCT FROM 'string'
         OR (e.value ->> 'type') NOT IN ('text','textarea','select','boolean','number')
         OR ((e.value ->> 'type') = 'select' AND (
           NOT vm_private.vm_json_text_array_valid(e.value -> 'options')
           OR pg_catalog.jsonb_array_length(COALESCE(e.value -> 'options','[]'::jsonb)) = 0
         ))
         OR NOT (e.value ? 'required')
         OR pg_catalog.jsonb_typeof(e.value -> 'required') <> 'boolean'
    )
  END
$function$;

CREATE OR REPLACE FUNCTION vm_private.vm_components_json_valid(p_value jsonb)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $function$
DECLARE
  v_item jsonb;
  v_material_text text;
  v_quantity numeric;
  v_unit text;
  v_material uuid;
BEGIN
  IF p_value IS NULL OR pg_catalog.jsonb_typeof(p_value) <> 'array' THEN RETURN false; END IF;
  FOR v_item IN SELECT value FROM pg_catalog.jsonb_array_elements(p_value) AS x(value) LOOP
    IF pg_catalog.jsonb_typeof(v_item) <> 'object'
       OR NOT (v_item ? 'material_id') OR NOT (v_item ? 'quantity') OR NOT (v_item ? 'unit') THEN
      RETURN false;
    END IF;
    v_material_text := v_item ->> 'material_id';
    v_unit := pg_catalog.btrim(v_item ->> 'unit');
    BEGIN
      v_material := v_material_text::uuid;
      v_quantity := (v_item ->> 'quantity')::numeric;
    EXCEPTION WHEN OTHERS THEN
      RETURN false;
    END;
    IF v_material IS NULL OR v_unit IS NULL OR v_unit = '' OR pg_catalog.char_length(v_unit) > 40
       OR NOT vm_private.vm_numeric_valid(v_quantity,8,999999999999.99999999,true)
       OR v_quantity <= 0 THEN
      RETURN false;
    END IF;
  END LOOP;
  RETURN true;
END
$function$;

CREATE OR REPLACE FUNCTION vm_private.vm_wholesale_tiers_valid(p_value jsonb)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $function$
DECLARE
  v_item jsonb;
  v_quantity numeric;
  v_price numeric;
  v_previous numeric;
BEGIN
  IF p_value IS NULL OR pg_catalog.jsonb_typeof(p_value) <> 'array' THEN RETURN false; END IF;
  FOR v_item IN SELECT value FROM pg_catalog.jsonb_array_elements(p_value) AS x(value) LOOP
    IF pg_catalog.jsonb_typeof(v_item) <> 'object'
       OR NOT (v_item ? 'minimum_quantity') OR NOT (v_item ? 'unit_price') THEN
      RETURN false;
    END IF;
    BEGIN
      v_quantity := (v_item ->> 'minimum_quantity')::numeric;
      v_price := (v_item ->> 'unit_price')::numeric;
    EXCEPTION WHEN OTHERS THEN
      RETURN false;
    END;
    IF NOT vm_private.vm_numeric_valid(v_quantity,8,999999999999.99999999,true)
       OR v_quantity <= 0
       OR NOT vm_private.vm_numeric_valid(v_price,8,999999999999.99999999,true)
       OR (v_previous IS NOT NULL AND v_quantity <= v_previous) THEN
      RETURN false;
    END IF;
    v_previous := v_quantity;
  END LOOP;
  RETURN true;
END
$function$;

CREATE OR REPLACE FUNCTION vm_private.vm_variants_json_valid(p_value jsonb)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $function$
DECLARE
  v_item jsonb;
  v_price numeric;
  v_promo numeric;
  v_minimum numeric;
  v_id uuid;
  v_mode text;
BEGIN
  IF p_value IS NULL OR pg_catalog.jsonb_typeof(p_value) <> 'array' THEN RETURN false; END IF;
  FOR v_item IN SELECT value FROM pg_catalog.jsonb_array_elements(p_value) AS x(value) LOOP
    IF pg_catalog.jsonb_typeof(v_item) <> 'object'
       OR pg_catalog.jsonb_typeof(v_item -> 'name') IS DISTINCT FROM 'string'
       OR pg_catalog.btrim(v_item ->> 'name') = ''
       OR pg_catalog.char_length(v_item ->> 'name') > 200
       OR NOT (v_item ? 'price')
       OR NOT (v_item ? 'composition_mode')
       OR pg_catalog.jsonb_typeof(v_item -> 'composition_mode') IS DISTINCT FROM 'string'
       OR (v_item ? 'active' AND pg_catalog.jsonb_typeof(v_item -> 'active') IS DISTINCT FROM 'boolean') THEN
      RETURN false;
    END IF;
    BEGIN
      v_price := (v_item ->> 'price')::numeric;
      IF v_item ? 'promo_price' AND v_item ->> 'promo_price' IS NOT NULL THEN
        v_promo := (v_item ->> 'promo_price')::numeric;
      ELSE
        v_promo := NULL;
      END IF;
      IF v_item ? 'minimum_quantity' AND v_item ->> 'minimum_quantity' IS NOT NULL THEN
        v_minimum := (v_item ->> 'minimum_quantity')::numeric;
      ELSE
        v_minimum := NULL;
      END IF;
      IF v_item ? 'id' AND v_item ->> 'id' IS NOT NULL THEN v_id := (v_item ->> 'id')::uuid; END IF;
    EXCEPTION WHEN OTHERS THEN
      RETURN false;
    END;
    v_mode := v_item ->> 'composition_mode';
    IF v_id IS NULL AND v_item ? 'id' AND v_item ->> 'id' IS NOT NULL THEN RETURN false; END IF;
    IF NOT vm_private.vm_numeric_valid(v_price,8,999999999999.99999999,true)
       OR (v_promo IS NOT NULL AND (NOT vm_private.vm_numeric_valid(v_promo,8,999999999999.99999999,true) OR v_promo > v_price))
       OR (v_minimum IS NOT NULL AND (NOT vm_private.vm_numeric_valid(v_minimum,8,999999999999.99999999,true) OR v_minimum <= 0))
       OR v_mode NOT IN ('inherit_base','own') THEN
      RETURN false;
    END IF;
    IF v_mode = 'own' THEN
      IF NOT vm_private.vm_components_json_valid(COALESCE(v_item -> 'components','[]'::jsonb)) THEN RETURN false; END IF;
    ELSIF (v_item ? 'components') AND pg_catalog.jsonb_array_length(COALESCE(v_item -> 'components','[]'::jsonb)) <> 0 THEN
      RETURN false;
    END IF;
  END LOOP;
  RETURN true;
END
$function$;

CREATE OR REPLACE FUNCTION vm_private.vm_product_storage_path_valid(p_path text)
RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = ''
AS $function$
  SELECT p_path IS NOT NULL
     AND p_path !~ '[\\\\]'
     AND p_path !~ '(^|/)\.\.($|/)'
     AND p_path !~ '//'
     AND p_path ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[A-Za-z0-9][A-Za-z0-9._-]{0,254}$'
$function$;

ALTER TABLE public.vm_products
  ADD COLUMN categories jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN subcategory text,
  ADD COLUMN description text,
  ADD COLUMN material_info text,
  ADD COLUMN personalization_info text,
  ADD COLUMN production_days integer NOT NULL DEFAULT 0,
  ADD COLUMN pricing_mode text NOT NULL DEFAULT 'unit',
  ADD COLUMN promo_price numeric(20,8),
  ADD COLUMN minimum_quantity numeric(20,8) NOT NULL DEFAULT 1,
  ADD COLUMN billing_unit text NOT NULL DEFAULT 'unit',
  ADD COLUMN is_catalog_visible boolean NOT NULL DEFAULT false,
  ADD COLUMN is_featured boolean NOT NULL DEFAULT false,
  ADD COLUMN custom_questions jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN weight_kg numeric(20,8),
  ADD COLUMN width_cm numeric(20,8),
  ADD COLUMN height_cm numeric(20,8),
  ADD COLUMN depth_cm numeric(20,8),
  ADD COLUMN sku text,
  ADD COLUMN barcode text,
  ADD COLUMN wholesale_tiers jsonb NOT NULL DEFAULT '[]'::jsonb;

ALTER TABLE public.vm_products
  ADD CONSTRAINT vm_products_categories_valid_ck CHECK (vm_private.vm_json_text_array_valid(categories)),
  ADD CONSTRAINT vm_products_subcategory_valid_ck CHECK (subcategory IS NULL OR (btrim(subcategory) <> '' AND char_length(subcategory) <= 120)),
  ADD CONSTRAINT vm_products_description_valid_ck CHECK (description IS NULL OR char_length(description) <= 20000),
  ADD CONSTRAINT vm_products_material_info_valid_ck CHECK (material_info IS NULL OR char_length(material_info) <= 5000),
  ADD CONSTRAINT vm_products_personalization_info_valid_ck CHECK (personalization_info IS NULL OR char_length(personalization_info) <= 5000),
  ADD CONSTRAINT vm_products_production_days_valid_ck CHECK (production_days >= 0 AND production_days <= 10000),
  ADD CONSTRAINT vm_products_pricing_mode_valid_ck CHECK (pricing_mode IN ('unit','variation','m2')),
  ADD CONSTRAINT vm_products_promo_price_valid_ck CHECK (promo_price IS NULL OR (vm_private.vm_numeric_valid(promo_price,8,999999999999.99999999,true) AND promo_price <= price)),
  ADD CONSTRAINT vm_products_minimum_quantity_valid_ck CHECK (vm_private.vm_numeric_valid(minimum_quantity,8,999999999999.99999999,true) AND minimum_quantity > 0),
  ADD CONSTRAINT vm_products_billing_unit_valid_ck CHECK ((pricing_mode = 'm2' AND billing_unit = 'm2') OR (pricing_mode IN ('unit','variation') AND billing_unit = 'unit')),
  ADD CONSTRAINT vm_products_custom_questions_valid_ck CHECK (vm_private.vm_custom_questions_valid(custom_questions)),
  ADD CONSTRAINT vm_products_weight_valid_ck CHECK (weight_kg IS NULL OR (vm_private.vm_numeric_valid(weight_kg,8,999999999999.99999999,true) AND weight_kg > 0)),
  ADD CONSTRAINT vm_products_width_valid_ck CHECK (width_cm IS NULL OR (vm_private.vm_numeric_valid(width_cm,8,999999999999.99999999,true) AND width_cm > 0)),
  ADD CONSTRAINT vm_products_height_valid_ck CHECK (height_cm IS NULL OR (vm_private.vm_numeric_valid(height_cm,8,999999999999.99999999,true) AND height_cm > 0)),
  ADD CONSTRAINT vm_products_depth_valid_ck CHECK (depth_cm IS NULL OR (vm_private.vm_numeric_valid(depth_cm,8,999999999999.99999999,true) AND depth_cm > 0)),
  ADD CONSTRAINT vm_products_sku_valid_ck CHECK (sku IS NULL OR (btrim(sku) <> '' AND char_length(sku) <= 120)),
  ADD CONSTRAINT vm_products_barcode_valid_ck CHECK (barcode IS NULL OR (btrim(barcode) <> '' AND char_length(barcode) <= 120)),
  ADD CONSTRAINT vm_products_wholesale_tiers_valid_ck CHECK (vm_private.vm_wholesale_tiers_valid(wholesale_tiers));

CREATE UNIQUE INDEX vm_products_org_sku_uq ON public.vm_products (organization_id, lower(sku)) WHERE sku IS NOT NULL;
CREATE UNIQUE INDEX vm_products_org_barcode_uq ON public.vm_products (organization_id, lower(barcode)) WHERE barcode IS NOT NULL;
CREATE INDEX vm_products_org_catalog_idx ON public.vm_products (organization_id, is_catalog_visible, is_featured, lower(name));
CREATE INDEX vm_products_org_pricing_idx ON public.vm_products (organization_id, pricing_mode, minimum_quantity);

-- Replace the old component row's implicit live material cost with explicit
-- snapshots. The existing quantity/material/version history is untouched.
ALTER TABLE public.vm_product_components
  ADD COLUMN component_unit text,
  ADD COLUMN unit_cost_snapshot numeric(20,8);
UPDATE public.vm_product_components AS c
SET component_unit = m.unit,
    unit_cost_snapshot = m.unit_cost
FROM public.vm_materials AS m
WHERE m.organization_id = c.organization_id AND m.id = c.material_id;
ALTER TABLE public.vm_product_components
  ALTER COLUMN component_unit SET NOT NULL,
  ALTER COLUMN unit_cost_snapshot SET NOT NULL,
  ADD CONSTRAINT vm_product_components_unit_valid_ck CHECK (btrim(component_unit) <> '' AND char_length(component_unit) <= 40),
  ADD CONSTRAINT vm_product_components_unit_cost_valid_ck CHECK (vm_private.vm_numeric_valid(unit_cost_snapshot,8,999999999999.99999999,true));
ALTER TABLE public.vm_product_components
  ADD COLUMN line_cost numeric(20,8) GENERATED ALWAYS AS ((quantity * unit_cost_snapshot)::numeric(20,8)) STORED;
ALTER TABLE public.vm_product_components
  ADD CONSTRAINT vm_product_components_line_cost_valid_ck CHECK (vm_private.vm_numeric_valid(line_cost,8,999999999999.99999999,true));

CREATE TABLE public.vm_product_variants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
  product_id uuid NOT NULL,
  name text NOT NULL CHECK (btrim(name) <> '' AND char_length(name) <= 200),
  sku text,
  price numeric(20,8) NOT NULL,
  promo_price numeric(20,8),
  active boolean NOT NULL DEFAULT true,
  minimum_quantity numeric(20,8),
  composition_mode text NOT NULL CHECK (composition_mode IN ('inherit_base','own')),
  current_version integer NOT NULL DEFAULT 1 CHECK (current_version > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id,id),
  CONSTRAINT vm_product_variants_product_same_org_fk FOREIGN KEY (organization_id,product_id)
    REFERENCES public.vm_products(organization_id,id) ON DELETE RESTRICT,
  CONSTRAINT vm_product_variants_sku_valid_ck CHECK (sku IS NULL OR (btrim(sku) <> '' AND char_length(sku) <= 120)),
  CONSTRAINT vm_product_variants_price_valid_ck CHECK (vm_private.vm_numeric_valid(price,8,999999999999.99999999,true)),
  CONSTRAINT vm_product_variants_promo_valid_ck CHECK (promo_price IS NULL OR (vm_private.vm_numeric_valid(promo_price,8,999999999999.99999999,true) AND promo_price <= price)),
  CONSTRAINT vm_product_variants_minimum_valid_ck CHECK (minimum_quantity IS NULL OR (vm_private.vm_numeric_valid(minimum_quantity,8,999999999999.99999999,true) AND minimum_quantity > 0))
);
CREATE UNIQUE INDEX vm_product_variants_org_sku_uq ON public.vm_product_variants (organization_id, lower(sku)) WHERE sku IS NOT NULL;
CREATE INDEX vm_product_variants_product_idx ON public.vm_product_variants (organization_id,product_id,active);

CREATE TABLE public.vm_product_variant_components (
  organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
  variant_id uuid NOT NULL,
  variant_version integer NOT NULL CHECK (variant_version > 0),
  material_id uuid NOT NULL,
  component_unit text NOT NULL,
  quantity numeric(20,8) NOT NULL,
  unit_cost_snapshot numeric(20,8) NOT NULL,
  line_cost numeric(20,8) GENERATED ALWAYS AS ((quantity * unit_cost_snapshot)::numeric(20,8)) STORED,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (organization_id,variant_id,variant_version,material_id),
  CONSTRAINT vm_product_variant_components_variant_same_org_fk FOREIGN KEY (organization_id,variant_id)
    REFERENCES public.vm_product_variants(organization_id,id) ON DELETE RESTRICT,
  CONSTRAINT vm_product_variant_components_material_same_org_fk FOREIGN KEY (organization_id,material_id)
    REFERENCES public.vm_materials(organization_id,id) ON DELETE RESTRICT,
  CONSTRAINT vm_product_variant_components_quantity_valid_ck CHECK (vm_private.vm_numeric_valid(quantity,8,999999999999.99999999,true) AND quantity > 0),
  CONSTRAINT vm_product_variant_components_unit_cost_valid_ck CHECK (vm_private.vm_numeric_valid(unit_cost_snapshot,8,999999999999.99999999,true)),
  CONSTRAINT vm_product_variant_components_line_cost_valid_ck CHECK (vm_private.vm_numeric_valid(line_cost,8,999999999999.99999999,true)),
  CONSTRAINT vm_product_variant_components_unit_valid_ck CHECK (btrim(component_unit) <> '' AND char_length(component_unit) <= 40)
);
CREATE INDEX vm_product_variant_components_idx ON public.vm_product_variant_components (organization_id,variant_id,variant_version);

CREATE TABLE public.vm_product_versions (
  organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
  product_id uuid NOT NULL,
  product_version integer NOT NULL CHECK (product_version > 0),
  name text NOT NULL,
  category text,
  categories jsonb NOT NULL,
  subcategory text,
  description text,
  material_info text,
  personalization_info text,
  production_days integer NOT NULL,
  pricing_mode text NOT NULL,
  billing_unit text NOT NULL,
  price numeric(20,8) NOT NULL,
  promo_price numeric(20,8),
  minimum_quantity numeric(20,8) NOT NULL,
  is_catalog_visible boolean NOT NULL,
  is_featured boolean NOT NULL,
  custom_questions jsonb NOT NULL,
  weight_kg numeric(20,8),
  width_cm numeric(20,8),
  height_cm numeric(20,8),
  depth_cm numeric(20,8),
  sku text,
  barcode text,
  wholesale_tiers jsonb NOT NULL,
  composition_snapshot jsonb NOT NULL,
  variants_snapshot jsonb NOT NULL,
  composition_cost numeric(20,8) NOT NULL,
  snapshot_metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (organization_id,product_id,product_version),
  CONSTRAINT vm_product_versions_product_same_org_fk FOREIGN KEY (organization_id,product_id)
    REFERENCES public.vm_products(organization_id,id) ON DELETE RESTRICT,
  CONSTRAINT vm_product_versions_numeric_ck CHECK (
    vm_private.vm_numeric_valid(price,8,999999999999.99999999,true)
    AND (promo_price IS NULL OR (vm_private.vm_numeric_valid(promo_price,8,999999999999.99999999,true) AND promo_price <= price))
    AND vm_private.vm_numeric_valid(minimum_quantity,8,999999999999.99999999,true)
    AND minimum_quantity > 0
    AND vm_private.vm_numeric_valid(composition_cost,8,999999999999.99999999,true)
  ),
  CONSTRAINT vm_product_versions_shapes_ck CHECK (
    pricing_mode IN ('unit','variation','m2')
    AND ((pricing_mode = 'm2' AND billing_unit = 'm2') OR (pricing_mode IN ('unit','variation') AND billing_unit = 'unit'))
    AND production_days >= 0
    AND vm_private.vm_json_text_array_valid(categories)
    AND vm_private.vm_custom_questions_valid(custom_questions)
    AND vm_private.vm_wholesale_tiers_valid(wholesale_tiers)
    AND pg_catalog.jsonb_typeof(composition_snapshot) = 'array'
    AND pg_catalog.jsonb_typeof(variants_snapshot) = 'array'
  )
);
CREATE INDEX vm_product_versions_org_product_idx ON public.vm_product_versions (organization_id,product_id,product_version DESC);

-- Every version already present in the foundation receives a clearly marked
-- legacy snapshot. Its component recipe/cost is exact; pre-Products price and
-- metadata were not historically stored, so those fields are marked as the
-- current legacy values rather than being invented as old values.
INSERT INTO public.vm_product_versions(
 organization_id,product_id,product_version,name,category,categories,subcategory,description,material_info,
 personalization_info,production_days,pricing_mode,billing_unit,price,promo_price,minimum_quantity,
 is_catalog_visible,is_featured,custom_questions,weight_kg,width_cm,height_cm,depth_cm,sku,barcode,
 wholesale_tiers,composition_snapshot,variants_snapshot,composition_cost,snapshot_metadata,created_by
)
SELECT
 p.organization_id,p.id,v.product_version,p.name,p.category,p.categories,p.subcategory,p.description,p.material_info,
 p.personalization_info,p.production_days,p.pricing_mode,p.billing_unit,p.price,p.promo_price,p.minimum_quantity,
 p.is_catalog_visible,p.is_featured,p.custom_questions,p.weight_kg,p.width_cm,p.height_cm,p.depth_cm,p.sku,p.barcode,
 p.wholesale_tiers,
 COALESCE((SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
   'material_id',c.material_id::text,'quantity',c.quantity::text,'unit',c.component_unit,
   'unit_cost',c.unit_cost_snapshot::text,'line_cost',c.line_cost::text) ORDER BY c.material_id)
   FROM public.vm_product_components AS c WHERE c.organization_id=p.organization_id AND c.product_id=p.id AND c.product_version=v.product_version),'[]'::jsonb),
 '[]'::jsonb,
 COALESCE((SELECT pg_catalog.sum(c.line_cost) FROM public.vm_product_components AS c WHERE c.organization_id=p.organization_id AND c.product_id=p.id AND c.product_version=v.product_version),0)::numeric(20,8),
 '{"legacy_backfill":true,"price_is_current_legacy_value":true}'::jsonb,
 o.created_by
FROM public.vm_products AS p
JOIN public.vm_organizations AS o ON o.id = p.organization_id
JOIN (SELECT organization_id,product_id,product_version FROM public.vm_product_components
      UNION
      SELECT organization_id,id,current_version FROM public.vm_products) AS v
  ON v.organization_id=p.organization_id AND v.product_id=p.id
ON CONFLICT (organization_id,product_id,product_version) DO NOTHING;

CREATE TABLE public.vm_product_files (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
  product_id uuid NOT NULL,
  kind text NOT NULL CHECK (kind IN ('photo','digital','production')),
  path text NOT NULL,
  mime_type text NOT NULL,
  size_bytes bigint NOT NULL,
  name text NOT NULL,
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id,path),
  CONSTRAINT vm_product_files_product_same_org_fk FOREIGN KEY (organization_id,product_id)
    REFERENCES public.vm_products(organization_id,id) ON DELETE RESTRICT,
  CONSTRAINT vm_product_files_path_valid_ck CHECK (vm_private.vm_product_storage_path_valid(path) AND split_part(path,'/',1) = organization_id::text AND split_part(path,'/',2) = product_id::text),
  CONSTRAINT vm_product_files_mime_valid_ck CHECK (
    lower(btrim(mime_type)) IN ('image/jpeg','image/png','image/webp','application/pdf','application/zip')
    AND NOT (kind = 'photo' AND lower(btrim(mime_type)) NOT IN ('image/jpeg','image/png','image/webp'))
  ),
  CONSTRAINT vm_product_files_size_valid_ck CHECK (size_bytes >= 0 AND size_bytes <= 52428800),
  CONSTRAINT vm_product_files_name_valid_ck CHECK (btrim(name) <> '' AND char_length(name) <= 255)
);
CREATE INDEX vm_product_files_product_idx ON public.vm_product_files (organization_id,product_id,kind,created_at DESC);

CREATE TABLE vm_private.vm_product_upsert_requests (
  organization_id uuid NOT NULL,
  idempotency_key uuid NOT NULL,
  product_id uuid NOT NULL,
  product_version integer NOT NULL,
  payload jsonb NOT NULL,
  component_count integer NOT NULL,
  normal_price text NOT NULL,
  promo_price text,
  minimum_quantity text NOT NULL,
  composition_cost text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (organization_id,idempotency_key),
  UNIQUE (organization_id,product_id,product_version),
  CONSTRAINT vm_product_upsert_req_product_fk FOREIGN KEY (organization_id,product_id)
    REFERENCES public.vm_products(organization_id,id) ON DELETE RESTRICT
);
ALTER TABLE vm_private.vm_product_upsert_requests ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION vm_private.vm_validate_component_unit()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $function$
DECLARE v_unit text;
BEGIN
  SELECT m.unit INTO v_unit FROM public.vm_materials AS m
  WHERE m.organization_id = NEW.organization_id AND m.id = NEW.material_id;
  IF v_unit IS NULL OR v_unit <> NEW.component_unit THEN
    RAISE EXCEPTION 'A unidade da composição deve ser a unidade do insumo' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END
$function$;
CREATE TRIGGER vm_product_components_unit_guard
BEFORE INSERT OR UPDATE ON public.vm_product_components
FOR EACH ROW EXECUTE FUNCTION vm_private.vm_validate_component_unit();
CREATE TRIGGER vm_product_variant_components_unit_guard
BEFORE INSERT OR UPDATE ON public.vm_product_variant_components
FOR EACH ROW EXECUTE FUNCTION vm_private.vm_validate_component_unit();
CREATE TRIGGER vm_product_variants_updated_at
BEFORE UPDATE ON public.vm_product_variants
FOR EACH ROW EXECUTE FUNCTION vm_private.vm_set_updated_at();
CREATE TRIGGER vm_product_versions_immutable
BEFORE UPDATE OR DELETE ON public.vm_product_versions
FOR EACH ROW EXECUTE FUNCTION vm_private.vm_reject_immutable_row();
CREATE TRIGGER vm_product_variant_components_immutable
BEFORE UPDATE OR DELETE ON public.vm_product_variant_components
FOR EACH ROW EXECUTE FUNCTION vm_private.vm_reject_immutable_row();

CREATE OR REPLACE FUNCTION public.vm_upsert_product_v2(
 p_organization_id uuid,
 p_name text,
 p_category text,
 p_categories jsonb DEFAULT '[]'::jsonb,
 p_subcategory text DEFAULT NULL,
 p_description text DEFAULT NULL,
 p_material_info text DEFAULT NULL,
 p_personalization_info text DEFAULT NULL,
 p_production_days integer DEFAULT 0,
 p_pricing_mode text DEFAULT 'unit',
 p_price numeric DEFAULT NULL,
 p_promo_price numeric DEFAULT NULL,
 p_minimum_quantity numeric DEFAULT 1,
 p_billing_unit text DEFAULT 'unit',
 p_is_catalog_visible boolean DEFAULT false,
 p_is_featured boolean DEFAULT false,
 p_custom_questions jsonb DEFAULT '[]'::jsonb,
 p_weight_kg numeric DEFAULT NULL,
 p_width_cm numeric DEFAULT NULL,
 p_height_cm numeric DEFAULT NULL,
 p_depth_cm numeric DEFAULT NULL,
 p_sku text DEFAULT NULL,
 p_barcode text DEFAULT NULL,
 p_wholesale_tiers jsonb DEFAULT '[]'::jsonb,
 p_components jsonb DEFAULT '[]'::jsonb,
 p_variants jsonb DEFAULT '[]'::jsonb,
 p_product_id uuid DEFAULT NULL,
 p_idempotency_key uuid DEFAULT NULL
) RETURNS TABLE(
 product_id uuid,
 version text,
 pricing_mode text,
 normal_price text,
 promo_price text,
 minimum_quantity text,
 component_count integer,
 composition_cost text
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog,public,storage
AS $function$
DECLARE
 v_uid uuid := auth.uid();
 v_product uuid := p_product_id;
 v_version integer;
 v_name text := btrim(p_name);
 v_category text := NULLIF(btrim(p_category),'');
 v_subcategory text := NULLIF(btrim(p_subcategory),'');
 v_sku text := NULLIF(btrim(p_sku),'');
 v_barcode text := NULLIF(btrim(p_barcode),'');
 v_description text := p_description;
 v_material_info text := p_material_info;
 v_personalization_info text := p_personalization_info;
 v_components jsonb;
 v_variants jsonb := p_variants;
 v_payload jsonb;
 v_existing_payload jsonb;
 v_existing_product uuid;
 v_existing_version integer;
 v_component_count integer;
 v_distinct_count integer;
 v_units_ok boolean;
 v_composition_cost numeric := 0;
 v_variant_item jsonb;
 v_variant_id uuid;
 v_variant_version integer;
 v_variant_name text;
 v_variant_sku text;
 v_variant_price numeric;
 v_variant_promo numeric;
 v_variant_minimum numeric;
 v_variant_active boolean;
 v_variant_mode text;
 v_variant_components jsonb;
 v_variant_component_count integer;
 v_variant_material_count integer;
 v_variant_units_ok boolean;
 v_variant_cost numeric;
 v_variant_found boolean;
 v_variants_snapshot jsonb;
 v_replay record;
BEGIN
 IF v_uid IS NULL OR auth.role() <> 'authenticated'
    OR NOT vm_private.vm_has_role(p_organization_id,ARRAY['owner','admin','production']::text[]) THEN
  RAISE EXCEPTION 'Sem permissão para alterar produto nesta organização' USING ERRCODE='42501';
 END IF;
 IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'p_idempotency_key é obrigatório' USING ERRCODE='22023'; END IF;
 IF p_name IS NULL OR v_name = '' OR char_length(v_name) > 200
    OR p_category IS NULL OR v_category IS NULL OR char_length(v_category) > 120
    OR NOT vm_private.vm_json_text_array_valid(p_categories)
    OR (v_subcategory IS NOT NULL AND char_length(v_subcategory) > 120)
    OR (v_description IS NOT NULL AND char_length(v_description) > 20000)
    OR (v_material_info IS NOT NULL AND char_length(v_material_info) > 5000)
    OR (v_personalization_info IS NOT NULL AND char_length(v_personalization_info) > 5000)
    OR p_production_days IS NULL OR p_production_days < 0 OR p_production_days > 10000
    OR p_pricing_mode NOT IN ('unit','variation','m2')
    OR p_billing_unit NOT IN ('unit','m2')
    OR (p_pricing_mode = 'm2' AND p_billing_unit <> 'm2')
    OR (p_pricing_mode IN ('unit','variation') AND p_billing_unit <> 'unit')
    OR NOT vm_private.vm_numeric_valid(p_price,8,999999999999.99999999,true)
    OR (p_promo_price IS NOT NULL AND (NOT vm_private.vm_numeric_valid(p_promo_price,8,999999999999.99999999,true) OR p_promo_price > p_price))
    OR NOT vm_private.vm_numeric_valid(p_minimum_quantity,8,999999999999.99999999,true) OR p_minimum_quantity <= 0
    OR NOT vm_private.vm_custom_questions_valid(p_custom_questions)
    OR (p_weight_kg IS NOT NULL AND (NOT vm_private.vm_numeric_valid(p_weight_kg,8,999999999999.99999999,true) OR p_weight_kg <= 0))
    OR (p_width_cm IS NOT NULL AND (NOT vm_private.vm_numeric_valid(p_width_cm,8,999999999999.99999999,true) OR p_width_cm <= 0))
    OR (p_height_cm IS NOT NULL AND (NOT vm_private.vm_numeric_valid(p_height_cm,8,999999999999.99999999,true) OR p_height_cm <= 0))
    OR (p_depth_cm IS NOT NULL AND (NOT vm_private.vm_numeric_valid(p_depth_cm,8,999999999999.99999999,true) OR p_depth_cm <= 0))
    OR (v_sku IS NOT NULL AND char_length(v_sku) > 120)
    OR (v_barcode IS NOT NULL AND char_length(v_barcode) > 120)
    OR NOT vm_private.vm_wholesale_tiers_valid(p_wholesale_tiers)
    OR NOT vm_private.vm_components_json_valid(p_components)
    OR NOT vm_private.vm_variants_json_valid(p_variants)
    OR (p_pricing_mode = 'variation' AND pg_catalog.jsonb_array_length(p_variants) = 0) THEN
  RAISE EXCEPTION 'Parâmetros de produto, preço, composição ou variações inválidos' USING ERRCODE='22023';
 END IF;

 SELECT COALESCE(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
   'material_id',c.material_id::text,'quantity',c.quantity::text,'unit',pg_catalog.btrim(c.unit)
   ) ORDER BY c.material_id),'[]'::jsonb)
 INTO v_components
 FROM pg_catalog.jsonb_to_recordset(p_components) AS c(material_id uuid,quantity numeric,unit text);

 PERFORM 1 FROM public.vm_organizations AS o WHERE o.id = p_organization_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Organização não encontrada' USING ERRCODE='23503'; END IF;

 v_payload := pg_catalog.jsonb_build_object(
   'name',v_name,'category',v_category,'categories',p_categories,'subcategory',v_subcategory,
   'description',v_description,'material_info',v_material_info,'personalization_info',v_personalization_info,
   'production_days',p_production_days,'pricing_mode',p_pricing_mode,'price',p_price::text,
   'promo_price',CASE WHEN p_promo_price IS NULL THEN NULL ELSE p_promo_price::text END,
   'minimum_quantity',p_minimum_quantity::text,'billing_unit',p_billing_unit,
   'is_catalog_visible',p_is_catalog_visible,'is_featured',p_is_featured,'custom_questions',p_custom_questions,
   'weight_kg',CASE WHEN p_weight_kg IS NULL THEN NULL ELSE p_weight_kg::text END,
   'width_cm',CASE WHEN p_width_cm IS NULL THEN NULL ELSE p_width_cm::text END,
   'height_cm',CASE WHEN p_height_cm IS NULL THEN NULL ELSE p_height_cm::text END,
   'depth_cm',CASE WHEN p_depth_cm IS NULL THEN NULL ELSE p_depth_cm::text END,
   'sku',v_sku,'barcode',v_barcode,'wholesale_tiers',p_wholesale_tiers,
   'components',v_components,'variants',p_variants,'product_id',p_product_id
 );
 SELECT r.* INTO v_replay FROM vm_private.vm_product_upsert_requests AS r
 WHERE r.organization_id = p_organization_id AND r.idempotency_key = p_idempotency_key FOR UPDATE;
 IF FOUND THEN
  IF v_replay.payload <> v_payload THEN
    RAISE EXCEPTION 'Chave de idempotência reutilizada com payload diferente' USING ERRCODE='23505';
  END IF;
  RETURN QUERY SELECT v_replay.product_id,v_replay.product_version::text,
    (SELECT p.pricing_mode FROM public.vm_products AS p WHERE p.organization_id=p_organization_id AND p.id=v_replay.product_id),
    v_replay.normal_price,v_replay.promo_price,v_replay.minimum_quantity,v_replay.component_count,v_replay.composition_cost;
  RETURN;
 END IF;

 SELECT count(*)::integer,count(DISTINCT c.material_id)::integer,
        COALESCE(bool_and(c.unit = m.unit),true)
 INTO v_component_count,v_distinct_count,v_units_ok
 FROM pg_catalog.jsonb_to_recordset(v_components) AS c(material_id uuid,quantity numeric,unit text)
 LEFT JOIN public.vm_materials AS m ON m.organization_id=p_organization_id AND m.id=c.material_id;
 IF v_component_count <> v_distinct_count OR NOT v_units_ok OR EXISTS (
   SELECT 1 FROM pg_catalog.jsonb_to_recordset(v_components) AS c(material_id uuid,quantity numeric,unit text)
   LEFT JOIN public.vm_materials AS m ON m.organization_id=p_organization_id AND m.id=c.material_id
   WHERE m.id IS NULL
 ) THEN
  RAISE EXCEPTION 'Composição deve usar insumos distintos da organização e suas unidades exatas' USING ERRCODE='23503';
 END IF;

 IF v_product IS NULL THEN
  INSERT INTO public.vm_products(
    organization_id,name,category,categories,subcategory,description,material_info,personalization_info,
    production_days,pricing_mode,price,promo_price,minimum_quantity,billing_unit,is_catalog_visible,is_featured,
    custom_questions,weight_kg,width_cm,height_cm,depth_cm,sku,barcode,wholesale_tiers,current_version
  ) VALUES (
    p_organization_id,v_name,v_category,p_categories,v_subcategory,v_description,v_material_info,v_personalization_info,
    p_production_days,p_pricing_mode,p_price,p_promo_price,p_minimum_quantity,p_billing_unit,p_is_catalog_visible,p_is_featured,
    p_custom_questions,p_weight_kg,p_width_cm,p_height_cm,p_depth_cm,v_sku,v_barcode,p_wholesale_tiers,1
  ) RETURNING id,current_version INTO v_product,v_version;
 ELSE
  SELECT p.current_version INTO v_version FROM public.vm_products AS p
  WHERE p.organization_id=p_organization_id AND p.id=v_product FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Produto não encontrado nesta organização' USING ERRCODE='23503'; END IF;
  v_version := v_version + 1;
  UPDATE public.vm_products AS p SET
    name=v_name,category=v_category,categories=p_categories,subcategory=v_subcategory,description=v_description,
    material_info=v_material_info,personalization_info=v_personalization_info,production_days=p_production_days,
    pricing_mode=p_pricing_mode,price=p_price,promo_price=p_promo_price,minimum_quantity=p_minimum_quantity,
    billing_unit=p_billing_unit,is_catalog_visible=p_is_catalog_visible,is_featured=p_is_featured,
    custom_questions=p_custom_questions,weight_kg=p_weight_kg,width_cm=p_width_cm,height_cm=p_height_cm,depth_cm=p_depth_cm,
    sku=v_sku,barcode=v_barcode,wholesale_tiers=p_wholesale_tiers,current_version=v_version
  WHERE p.organization_id=p_organization_id AND p.id=v_product;
 END IF;

 INSERT INTO public.vm_product_components(organization_id,product_id,product_version,material_id,component_unit,quantity,unit_cost_snapshot)
 SELECT p_organization_id,v_product,v_version,c.material_id,c.unit,c.quantity::numeric(20,8),m.unit_cost
 FROM pg_catalog.jsonb_to_recordset(v_components) AS c(material_id uuid,quantity numeric,unit text)
 JOIN public.vm_materials AS m ON m.organization_id=p_organization_id AND m.id=c.material_id;
 SELECT COALESCE(pg_catalog.sum(c.quantity * c.unit_cost_snapshot),0)::numeric(20,8)
 INTO v_composition_cost
 FROM public.vm_product_components AS c
 WHERE c.organization_id=p_organization_id AND c.product_id=v_product AND c.product_version=v_version;
 IF NOT vm_private.vm_numeric_valid(v_composition_cost,8,999999999999.99999999,true) THEN
  RAISE EXCEPTION 'Custo indicativo da composição excede a precisão' USING ERRCODE='22003';
 END IF;

 -- A variant payload is an explicit partial upsert. Omitted variants remain
 -- available; each supplied variant gets its own immutable recipe version.
 FOR v_variant_item IN SELECT value FROM pg_catalog.jsonb_array_elements(v_variants) AS x(value) LOOP
  v_variant_name := pg_catalog.btrim(v_variant_item ->> 'name');
  v_variant_sku := NULLIF(pg_catalog.btrim(v_variant_item ->> 'sku'),'');
  v_variant_price := (v_variant_item ->> 'price')::numeric;
  v_variant_promo := CASE WHEN v_variant_item ? 'promo_price' AND v_variant_item ->> 'promo_price' IS NOT NULL THEN (v_variant_item ->> 'promo_price')::numeric ELSE NULL END;
  v_variant_minimum := CASE WHEN v_variant_item ? 'minimum_quantity' AND v_variant_item ->> 'minimum_quantity' IS NOT NULL THEN (v_variant_item ->> 'minimum_quantity')::numeric ELSE NULL END;
  v_variant_active := CASE WHEN v_variant_item ? 'active' THEN (v_variant_item ->> 'active')::boolean ELSE true END;
  v_variant_mode := v_variant_item ->> 'composition_mode';
  v_variant_components := COALESCE(v_variant_item -> 'components','[]'::jsonb);
  v_variant_id := CASE WHEN v_variant_item ? 'id' AND v_variant_item ->> 'id' IS NOT NULL THEN (v_variant_item ->> 'id')::uuid ELSE NULL END;
  v_variant_found := false;
  IF v_variant_id IS NOT NULL THEN
    SELECT v.current_version INTO v_variant_version FROM public.vm_product_variants AS v
    WHERE v.organization_id=p_organization_id AND v.id=v_variant_id AND v.product_id=v_product FOR UPDATE;
    IF FOUND THEN v_variant_found := true; END IF;
    IF NOT v_variant_found AND EXISTS (SELECT 1 FROM public.vm_product_variants AS v WHERE v.organization_id=p_organization_id AND v.id=v_variant_id) THEN
      RAISE EXCEPTION 'A variação não pertence a este produto' USING ERRCODE='23503';
    END IF;
  END IF;
  IF NOT v_variant_found THEN
    v_variant_version := 1;
    INSERT INTO public.vm_product_variants(organization_id,product_id,name,sku,price,promo_price,active,minimum_quantity,composition_mode,current_version)
    VALUES (p_organization_id,v_product,v_variant_name,v_variant_sku,v_variant_price,v_variant_promo,v_variant_active,v_variant_minimum,v_variant_mode,1)
    RETURNING id INTO v_variant_id;
  ELSE
    v_variant_version := v_variant_version + 1;
    UPDATE public.vm_product_variants AS v SET name=v_variant_name,sku=v_variant_sku,price=v_variant_price,promo_price=v_variant_promo,
      active=v_variant_active,minimum_quantity=v_variant_minimum,composition_mode=v_variant_mode,current_version=v_variant_version
    WHERE v.organization_id=p_organization_id AND v.id=v_variant_id;
  END IF;
  SELECT count(*)::integer,count(DISTINCT c.material_id)::integer,COALESCE(bool_and(c.unit=m.unit),true)
  INTO v_variant_component_count,v_variant_material_count,v_variant_units_ok
  FROM pg_catalog.jsonb_to_recordset(v_variant_components) AS c(material_id uuid,quantity numeric,unit text)
  LEFT JOIN public.vm_materials AS m ON m.organization_id=p_organization_id AND m.id=c.material_id;
  IF v_variant_mode='own' AND (v_variant_component_count<>v_variant_material_count OR NOT v_variant_units_ok OR EXISTS (
    SELECT 1 FROM pg_catalog.jsonb_to_recordset(v_variant_components) AS c(material_id uuid,quantity numeric,unit text)
    LEFT JOIN public.vm_materials AS m ON m.organization_id=p_organization_id AND m.id=c.material_id WHERE m.id IS NULL
  )) THEN
    RAISE EXCEPTION 'Composição própria da variação inválida ou fora da organização' USING ERRCODE='23503';
  END IF;
  IF v_variant_mode='own' THEN
    INSERT INTO public.vm_product_variant_components(organization_id,variant_id,variant_version,material_id,component_unit,quantity,unit_cost_snapshot)
    SELECT p_organization_id,v_variant_id,v_variant_version,c.material_id,c.unit,c.quantity::numeric(20,8),m.unit_cost
    FROM pg_catalog.jsonb_to_recordset(v_variant_components) AS c(material_id uuid,quantity numeric,unit text)
    JOIN public.vm_materials AS m ON m.organization_id=p_organization_id AND m.id=c.material_id;
  END IF;
 END LOOP;

 SELECT COALESCE(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
   'id',v.id::text,'name',v.name,'sku',v.sku,'price',v.price::text,'promo_price',CASE WHEN v.promo_price IS NULL THEN NULL ELSE v.promo_price::text END,
   'active',v.active,'minimum_quantity',CASE WHEN v.minimum_quantity IS NULL THEN NULL ELSE v.minimum_quantity::text END,
   'composition_mode',v.composition_mode,'version',v.current_version::text,
   'composition_cost',CASE WHEN v.composition_mode='inherit_base' THEN NULL ELSE COALESCE((SELECT pg_catalog.sum(vc.line_cost) FROM public.vm_product_variant_components AS vc WHERE vc.organization_id=v.organization_id AND vc.variant_id=v.id AND vc.variant_version=v.current_version),0)::text END,
   'components',COALESCE((SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('material_id',vc.material_id::text,'quantity',vc.quantity::text,'unit',vc.component_unit,'unit_cost',vc.unit_cost_snapshot::text,'line_cost',vc.line_cost::text) ORDER BY vc.material_id) FROM public.vm_product_variant_components AS vc WHERE vc.organization_id=v.organization_id AND vc.variant_id=v.id AND vc.variant_version=v.current_version),'[]'::jsonb)
 ) ORDER BY v.id),'[]'::jsonb)
 INTO v_variants_snapshot FROM public.vm_product_variants AS v
 WHERE v.organization_id=p_organization_id AND v.product_id=v_product;

 INSERT INTO public.vm_product_versions(
   organization_id,product_id,product_version,name,category,categories,subcategory,description,material_info,
   personalization_info,production_days,pricing_mode,billing_unit,price,promo_price,minimum_quantity,
   is_catalog_visible,is_featured,custom_questions,weight_kg,width_cm,height_cm,depth_cm,sku,barcode,wholesale_tiers,
   composition_snapshot,variants_snapshot,composition_cost,snapshot_metadata,created_by
 ) VALUES (
   p_organization_id,v_product,v_version,v_name,v_category,p_categories,v_subcategory,v_description,v_material_info,
   v_personalization_info,p_production_days,p_pricing_mode,p_billing_unit,p_price,p_promo_price,p_minimum_quantity,
   p_is_catalog_visible,p_is_featured,p_custom_questions,p_weight_kg,p_width_cm,p_height_cm,p_depth_cm,v_sku,v_barcode,p_wholesale_tiers,
   COALESCE((SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('material_id',c.material_id::text,'quantity',c.quantity::text,'unit',c.component_unit,'unit_cost',c.unit_cost_snapshot::text,'line_cost',c.line_cost::text) ORDER BY c.material_id) FROM public.vm_product_components AS c WHERE c.organization_id=p_organization_id AND c.product_id=v_product AND c.product_version=v_version),'[]'::jsonb),
   v_variants_snapshot,v_composition_cost,pg_catalog.jsonb_build_object('billing_unit',p_billing_unit),v_uid
 );

 INSERT INTO vm_private.vm_product_upsert_requests(
   organization_id,idempotency_key,product_id,product_version,payload,component_count,normal_price,promo_price,minimum_quantity,composition_cost
 ) VALUES (
   p_organization_id,p_idempotency_key,v_product,v_version,v_payload,v_component_count,p_price::text,
   CASE WHEN p_promo_price IS NULL THEN NULL ELSE p_promo_price::text END,p_minimum_quantity::text,v_composition_cost::text
 );
 RETURN QUERY SELECT v_product,v_version::text,p_pricing_mode,p_price::text,
   CASE WHEN p_promo_price IS NULL THEN NULL ELSE p_promo_price::text END,p_minimum_quantity::text,v_component_count,v_composition_cost::text;
END
$function$;

CREATE OR REPLACE FUNCTION public.vm_register_product_file(
 p_organization_id uuid,
 p_product_id uuid,
 p_kind text,
 p_path text,
 p_mime_type text,
 p_size_bytes bigint,
 p_name text
) RETURNS TABLE(file_id uuid,organization_id uuid,product_id uuid,kind text,path text,mime_type text,size_bytes text,name text,created_by uuid,created_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog,public,storage
AS $function$
DECLARE
 v_uid uuid := auth.uid();
 v_kind text := lower(btrim(p_kind));
 v_mime text := lower(btrim(p_mime_type));
 v_name text := btrim(p_name);
 v_existing record;
 v_file uuid;
BEGIN
 IF v_uid IS NULL OR auth.role() <> 'authenticated'
    OR NOT vm_private.vm_has_role(p_organization_id,ARRAY['owner','admin','production']::text[]) THEN
  RAISE EXCEPTION 'Sem permissão para registrar arquivo nesta organização' USING ERRCODE='42501';
 END IF;
 IF p_product_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.vm_products AS p WHERE p.organization_id=p_organization_id AND p.id=p_product_id)
    OR v_kind NOT IN ('photo','digital','production')
    OR NOT vm_private.vm_product_storage_path_valid(p_path)
    OR split_part(p_path,'/',1) <> p_organization_id::text OR split_part(p_path,'/',2) <> p_product_id::text
    OR v_mime NOT IN ('image/jpeg','image/png','image/webp','application/pdf','application/zip')
    OR (v_kind='photo' AND v_mime NOT IN ('image/jpeg','image/png','image/webp'))
    OR p_size_bytes IS NULL OR p_size_bytes < 0 OR p_size_bytes > 52428800
    OR v_name = '' OR char_length(v_name) > 255 THEN
  RAISE EXCEPTION 'Metadados de arquivo inválidos' USING ERRCODE='22023';
 END IF;
 IF NOT EXISTS (
   SELECT 1 FROM storage.objects AS o
   WHERE o.bucket_id='vm-product-media' AND o.name=p_path
     AND o.metadata ->> 'mimetype' = v_mime
     AND o.metadata ->> 'size' = p_size_bytes::text
 ) THEN
  RAISE EXCEPTION 'O objeto Storage privado deve existir com MIME e tamanho verificáveis antes do registro' USING ERRCODE='23503';
 END IF;
 SELECT f.* INTO v_existing FROM public.vm_product_files AS f
 WHERE f.organization_id=p_organization_id AND f.path=p_path FOR UPDATE;
 IF FOUND THEN
  IF v_existing.product_id <> p_product_id OR v_existing.kind <> v_kind OR v_existing.mime_type <> v_mime
     OR v_existing.size_bytes <> p_size_bytes OR v_existing.name <> v_name THEN
    RAISE EXCEPTION 'O caminho de arquivo já foi registrado com metadados diferentes' USING ERRCODE='23505';
  END IF;
  RETURN QUERY SELECT v_existing.id,v_existing.organization_id,v_existing.product_id,v_existing.kind,v_existing.path,v_existing.mime_type,v_existing.size_bytes::text,v_existing.name,v_existing.created_by,v_existing.created_at;
  RETURN;
 END IF;
 INSERT INTO public.vm_product_files(organization_id,product_id,kind,path,mime_type,size_bytes,name,created_by)
 VALUES (p_organization_id,p_product_id,v_kind,p_path,v_mime,p_size_bytes,v_name,v_uid)
 RETURNING id INTO v_file;
 RETURN QUERY SELECT f.id,f.organization_id,f.product_id,f.kind,f.path,f.mime_type,f.size_bytes::text,f.name,f.created_by,f.created_at
 FROM public.vm_product_files AS f WHERE f.id=v_file;
END
$function$;

-- Read DTOs intentionally cast every numeric value to text. security_invoker
-- preserves the base-table RLS policy instead of bypassing it.
CREATE VIEW public.vm_products_read WITH (security_invoker = true) AS
SELECT p.id,p.organization_id,p.name,p.category,p.categories,p.subcategory,p.description,p.material_info,p.personalization_info,
 p.production_days::text AS production_days,p.pricing_mode,p.price::text AS price,p.promo_price::text AS promo_price,
 p.minimum_quantity::text AS minimum_quantity,p.billing_unit,p.is_catalog_visible,p.is_featured,p.custom_questions,
 p.weight_kg::text AS weight_kg,p.width_cm::text AS width_cm,p.height_cm::text AS height_cm,p.depth_cm::text AS depth_cm,
 p.sku,p.barcode,p.wholesale_tiers,p.current_version::text AS current_version,
 v.composition_cost::text AS current_composition_cost,
 (SELECT COALESCE(sum(c.quantity*m.unit_cost),0)::numeric(20,8)::text
  FROM public.vm_product_components c JOIN public.vm_materials m
    ON m.organization_id=c.organization_id AND m.id=c.material_id
  WHERE c.organization_id=p.organization_id AND c.product_id=p.id AND c.product_version=p.current_version) AS current_material_cost,
 p.created_at,p.updated_at
FROM public.vm_products AS p
LEFT JOIN public.vm_product_versions AS v
 ON v.organization_id=p.organization_id AND v.product_id=p.id AND v.product_version=p.current_version;

CREATE VIEW public.vm_product_components_read WITH (security_invoker = true) AS
SELECT c.organization_id,c.product_id,c.product_version::text AS product_version,c.material_id,c.component_unit,
 c.quantity::text AS quantity,c.unit_cost_snapshot::text AS unit_cost,c.line_cost::text AS line_cost,c.created_at
FROM public.vm_product_components AS c;

CREATE VIEW public.vm_product_versions_read WITH (security_invoker = true) AS
SELECT v.organization_id,v.product_id,v.product_version::text AS product_version,v.name,v.category,v.categories,v.subcategory,
 v.description,v.material_info,v.personalization_info,v.production_days::text AS production_days,v.pricing_mode,v.billing_unit,
 v.price::text AS price,v.promo_price::text AS promo_price,v.minimum_quantity::text AS minimum_quantity,v.is_catalog_visible,v.is_featured,
 v.custom_questions,v.weight_kg::text AS weight_kg,v.width_cm::text AS width_cm,v.height_cm::text AS height_cm,v.depth_cm::text AS depth_cm,
 v.sku,v.barcode,v.wholesale_tiers,v.composition_snapshot,v.variants_snapshot,v.composition_cost::text AS composition_cost,
 v.snapshot_metadata,v.created_by,v.created_at
FROM public.vm_product_versions AS v;

CREATE VIEW public.vm_product_variants_read WITH (security_invoker = true) AS
SELECT v.id,v.organization_id,v.product_id,v.name,v.sku,v.price::text AS price,v.promo_price::text AS promo_price,v.active,
 v.minimum_quantity::text AS minimum_quantity,v.composition_mode,v.current_version::text AS current_version,v.created_at,v.updated_at
FROM public.vm_product_variants AS v;

CREATE VIEW public.vm_product_files_read WITH (security_invoker = true) AS
SELECT f.id,f.organization_id,f.product_id,f.kind,f.path,f.mime_type,f.size_bytes::text AS size_bytes,f.name,f.created_by,f.created_at
FROM public.vm_product_files AS f;

ALTER TABLE public.vm_product_variants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vm_product_variant_components ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vm_product_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vm_product_files ENABLE ROW LEVEL SECURITY;
CREATE POLICY vm_product_variants_member_select ON public.vm_product_variants FOR SELECT TO authenticated USING ((SELECT vm_private.vm_is_member(organization_id)));
CREATE POLICY vm_product_variant_components_member_select ON public.vm_product_variant_components FOR SELECT TO authenticated USING ((SELECT vm_private.vm_is_member(organization_id)));
CREATE POLICY vm_product_versions_member_select ON public.vm_product_versions FOR SELECT TO authenticated USING ((SELECT vm_private.vm_is_member(organization_id)));
CREATE POLICY vm_product_files_member_select ON public.vm_product_files FOR SELECT TO authenticated USING ((SELECT vm_private.vm_is_member(organization_id)));

-- Storage is private. The bucket is created only when absent; existing bucket
-- limits and ownership are deliberately preserved. Policy names are unique to
-- this migration and existing policies are never altered.
DO $storage_bucket$
BEGIN
 IF pg_catalog.to_regclass('storage.buckets') IS NOT NULL THEN
  IF NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id='vm-product-media') THEN
   INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
   VALUES ('vm-product-media','vm-product-media',false,52428800::bigint,
     ARRAY['image/jpeg','image/png','image/webp','application/pdf','application/zip']::text[]);
  ELSIF EXISTS (SELECT 1 FROM storage.buckets WHERE id='vm-product-media' AND public) THEN
   RAISE EXCEPTION 'Bucket preexistente deve ser privado antes de habilitar arquivos de produtos' USING ERRCODE='22023';
  END IF;
 END IF;
END
$storage_bucket$;

DO $storage_policies$
BEGIN
 IF pg_catalog.to_regclass('storage.objects') IS NOT NULL THEN
  EXECUTE 'GRANT USAGE ON SCHEMA storage TO authenticated';
  EXECUTE 'GRANT SELECT, INSERT, DELETE ON TABLE storage.objects TO authenticated';
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_policy pol JOIN pg_catalog.pg_class c ON c.oid=pol.polrelid JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE pol.polname='vm_product_media_select' AND n.nspname='storage' AND c.relname='objects') THEN
   EXECUTE $policy$CREATE POLICY vm_product_media_select ON storage.objects FOR SELECT TO authenticated USING (
     bucket_id = 'vm-product-media'
     AND vm_private.vm_product_storage_path_valid(name)
     AND EXISTS (SELECT 1 FROM public.vm_products p WHERE p.organization_id::text=split_part(storage.objects.name,'/',1) AND p.id::text=split_part(storage.objects.name,'/',2) AND vm_private.vm_is_member(p.organization_id))
   )$policy$;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_policy pol JOIN pg_catalog.pg_class c ON c.oid=pol.polrelid JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE pol.polname='vm_product_media_insert' AND n.nspname='storage' AND c.relname='objects') THEN
   EXECUTE $policy$CREATE POLICY vm_product_media_insert ON storage.objects FOR INSERT TO authenticated WITH CHECK (
     bucket_id = 'vm-product-media'
     AND vm_private.vm_product_storage_path_valid(name)
     AND EXISTS (SELECT 1 FROM public.vm_products p WHERE p.organization_id::text=split_part(storage.objects.name,'/',1) AND p.id::text=split_part(storage.objects.name,'/',2) AND vm_private.vm_has_role(p.organization_id,ARRAY['owner','admin','production']::text[]))
   )$policy$;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_policy pol JOIN pg_catalog.pg_class c ON c.oid=pol.polrelid JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE pol.polname='vm_product_media_delete' AND n.nspname='storage' AND c.relname='objects') THEN
   EXECUTE $policy$CREATE POLICY vm_product_media_delete ON storage.objects FOR DELETE TO authenticated USING (
     bucket_id = 'vm-product-media'
     AND vm_private.vm_product_storage_path_valid(name)
     AND EXISTS (SELECT 1 FROM public.vm_products p WHERE p.organization_id::text=split_part(storage.objects.name,'/',1) AND p.id::text=split_part(storage.objects.name,'/',2) AND vm_private.vm_has_role(p.organization_id,ARRAY['owner','admin','production']::text[]))
   )$policy$;
  END IF;
 END IF;
END
$storage_policies$;

ALTER TABLE public.vm_product_components ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.vm_products,public.vm_product_components,public.vm_product_variants,public.vm_product_variant_components,public.vm_product_versions,public.vm_product_files FROM PUBLIC,anon,authenticated;
GRANT SELECT ON TABLE public.vm_products,public.vm_product_components,public.vm_product_variants,public.vm_product_variant_components,public.vm_product_versions,public.vm_product_files TO authenticated;
REVOKE ALL ON TABLE vm_private.vm_product_upsert_requests FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION vm_private.vm_json_text_array_valid(jsonb),vm_private.vm_custom_questions_valid(jsonb),vm_private.vm_components_json_valid(jsonb),vm_private.vm_wholesale_tiers_valid(jsonb),vm_private.vm_variants_json_valid(jsonb),vm_private.vm_product_storage_path_valid(text),vm_private.vm_validate_component_unit(),public.vm_upsert_product(uuid,text,numeric,text,jsonb,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION vm_private.vm_product_storage_path_valid(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.vm_upsert_product_v2(uuid,text,text,jsonb,text,text,text,text,integer,text,numeric,numeric,numeric,text,boolean,boolean,jsonb,numeric,numeric,numeric,numeric,text,text,jsonb,jsonb,jsonb,uuid,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.vm_register_product_file(uuid,uuid,text,text,text,bigint,text) TO authenticated;
REVOKE ALL ON FUNCTION public.vm_upsert_product_v2(uuid,text,text,jsonb,text,text,text,text,integer,text,numeric,numeric,numeric,text,boolean,boolean,jsonb,numeric,numeric,numeric,numeric,text,text,jsonb,jsonb,jsonb,uuid,uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.vm_register_product_file(uuid,uuid,text,text,text,bigint,text) FROM PUBLIC,anon;
REVOKE ALL ON TABLE public.vm_products_read,public.vm_product_components_read,public.vm_product_versions_read,public.vm_product_variants_read,public.vm_product_files_read FROM PUBLIC,anon,authenticated;
GRANT SELECT ON TABLE public.vm_products_read,public.vm_product_components_read,public.vm_product_versions_read,public.vm_product_variants_read,public.vm_product_files_read TO authenticated;

DO $publication$
DECLARE v_table text;
BEGIN
 IF EXISTS (SELECT 1 FROM pg_catalog.pg_publication WHERE pubname='supabase_realtime' AND puballtables) THEN RETURN; END IF;
 IF EXISTS (SELECT 1 FROM pg_catalog.pg_publication WHERE pubname='supabase_realtime') THEN
  FOREACH v_table IN ARRAY ARRAY['vm_product_variants','vm_product_variant_components','vm_product_versions','vm_product_files'] LOOP
   IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_publication_tables WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename=v_table) THEN
    EXECUTE pg_catalog.format('ALTER PUBLICATION %I ADD TABLE %I.%I','supabase_realtime','public',v_table);
   END IF;
  END LOOP;
 END IF;
END
$publication$;

INSERT INTO public.vm_schema_migrations(version,description)
VALUES ('20261029233000_products','Produtos, variações, preços, snapshots versionados, composição fracionária e arquivos Storage privados')
ON CONFLICT (version) DO NOTHING;
NOTIFY pgrst, 'reload schema';
COMMIT;
