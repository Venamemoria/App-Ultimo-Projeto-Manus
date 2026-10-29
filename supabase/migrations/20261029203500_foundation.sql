BEGIN;
CREATE SCHEMA vm_private;
CREATE TABLE public.vm_schema_migrations (version text PRIMARY KEY, description text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE public.vm_organizations (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text NOT NULL CHECK (btrim(name) <> '' AND char_length(name) <= 200),
 created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.vm_memberships (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
 user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE, role text NOT NULL CHECK (role IN ('owner','admin','production','finance','viewer')),
 created_at timestamptz NOT NULL DEFAULT now(), UNIQUE (organization_id,user_id), UNIQUE (organization_id,id)
);
CREATE TABLE public.vm_clients (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
 name text NOT NULL CHECK (btrim(name) <> '' AND char_length(name) <= 200), email text, phone text, notes text,
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), UNIQUE (organization_id,id)
);
CREATE TABLE public.vm_suppliers (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
 name text NOT NULL CHECK (btrim(name) <> '' AND char_length(name) <= 200), email text, phone text, notes text,
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), UNIQUE (organization_id,id)
);
CREATE TABLE public.vm_materials (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
 name text NOT NULL CHECK (btrim(name) <> '' AND char_length(name) <= 200), category text CHECK (category IS NULL OR (btrim(category) <> '' AND char_length(category) <= 120)),
 unit text NOT NULL CHECK (btrim(unit) <> '' AND char_length(unit) <= 40), package_cost numeric(20,8) NOT NULL CHECK (package_cost >= 0), package_quantity numeric(20,8) NOT NULL CHECK (package_quantity > 0),
 unit_cost numeric(20,8) GENERATED ALWAYS AS ((package_cost / NULLIF(package_quantity,0))::numeric(20,8)) STORED,
 stock_quantity numeric(20,8) NOT NULL DEFAULT 0 CHECK (stock_quantity >= 0), reorder_level numeric(20,8) NOT NULL DEFAULT 0 CHECK (reorder_level >= 0),
 supplier_id uuid, creation_idempotency_key uuid, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), UNIQUE (organization_id,id),
 CONSTRAINT vm_materials_supplier_same_org_fk FOREIGN KEY (organization_id,supplier_id) REFERENCES public.vm_suppliers(organization_id,id) ON DELETE RESTRICT
);
CREATE TABLE public.vm_stock_movements (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT, material_id uuid NOT NULL,
 movement_type text NOT NULL CHECK (movement_type IN ('opening','receipt','adjustment')), quantity_delta numeric(20,8) NOT NULL CHECK (quantity_delta <> 0), stock_after numeric(20,8) NOT NULL CHECK (stock_after >= 0),
 package_cost numeric(20,8), package_quantity numeric(20,8), note text CHECK (note IS NULL OR char_length(note) <= 2000), idempotency_key uuid,
 created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT, created_at timestamptz NOT NULL DEFAULT now(), UNIQUE (organization_id,id),
 CONSTRAINT vm_stock_movements_material_same_org_fk FOREIGN KEY (organization_id,material_id) REFERENCES public.vm_materials(organization_id,id) ON DELETE RESTRICT,
 CONSTRAINT vm_stock_movements_delta_type_ck CHECK ((movement_type IN ('opening','receipt') AND quantity_delta > 0) OR (movement_type = 'adjustment' AND quantity_delta <> 0)),
 CONSTRAINT vm_stock_movements_package_pair_ck CHECK ((package_cost IS NULL AND package_quantity IS NULL) OR (package_cost IS NOT NULL AND package_quantity IS NOT NULL AND package_cost >= 0 AND package_quantity > 0))
);
CREATE TABLE public.vm_products (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
 name text NOT NULL CHECK (btrim(name) <> '' AND char_length(name) <= 200), category text CHECK (category IS NULL OR (btrim(category) <> '' AND char_length(category) <= 120)),
 price numeric(20,8) NOT NULL CHECK (price >= 0), current_version integer NOT NULL DEFAULT 1 CHECK (current_version > 0),
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), UNIQUE (organization_id,id)
);
CREATE TABLE public.vm_product_components (
 organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT, product_id uuid NOT NULL, product_version integer NOT NULL CHECK (product_version > 0), material_id uuid NOT NULL,
 quantity numeric(20,8) NOT NULL CHECK (quantity > 0), created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (organization_id,product_id,product_version,material_id),
 CONSTRAINT vm_product_components_product_same_org_fk FOREIGN KEY (organization_id,product_id) REFERENCES public.vm_products(organization_id,id) ON DELETE RESTRICT,
 CONSTRAINT vm_product_components_material_same_org_fk FOREIGN KEY (organization_id,material_id) REFERENCES public.vm_materials(organization_id,id) ON DELETE RESTRICT
);
CREATE UNIQUE INDEX vm_materials_creation_idempotency_uq ON public.vm_materials (organization_id,creation_idempotency_key) WHERE creation_idempotency_key IS NOT NULL;
CREATE UNIQUE INDEX vm_stock_movements_idempotency_uq ON public.vm_stock_movements (organization_id,idempotency_key) WHERE idempotency_key IS NOT NULL;
CREATE INDEX vm_memberships_user_org_idx ON public.vm_memberships (user_id,organization_id);
CREATE INDEX vm_memberships_org_role_idx ON public.vm_memberships (organization_id,role);
CREATE INDEX vm_clients_org_name_idx ON public.vm_clients (organization_id,lower(name));
CREATE INDEX vm_suppliers_org_name_idx ON public.vm_suppliers (organization_id,lower(name));
CREATE INDEX vm_materials_org_name_idx ON public.vm_materials (organization_id,lower(name));
CREATE INDEX vm_materials_reorder_idx ON public.vm_materials (organization_id,reorder_level,stock_quantity);
CREATE INDEX vm_stock_movements_material_created_idx ON public.vm_stock_movements (organization_id,material_id,created_at DESC);
CREATE INDEX vm_products_org_name_idx ON public.vm_products (organization_id,lower(name));
CREATE INDEX vm_product_components_product_version_idx ON public.vm_product_components (organization_id,product_id,product_version);
CREATE INDEX vm_product_components_material_idx ON public.vm_product_components (organization_id,material_id);
CREATE OR REPLACE FUNCTION vm_private.vm_set_updated_at() RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $function$
BEGIN NEW.updated_at := pg_catalog.clock_timestamp(); RETURN NEW; END;
$function$;
CREATE OR REPLACE FUNCTION vm_private.vm_reject_immutable_row() RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $function$
BEGIN RAISE EXCEPTION 'Registro % é somente apêndice/versionado', TG_TABLE_NAME USING ERRCODE = '55000'; END;
$function$;
CREATE OR REPLACE FUNCTION vm_private.vm_is_member(p_organization_id uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $function$
SELECT EXISTS (SELECT 1 FROM public.vm_memberships m WHERE m.organization_id = p_organization_id AND m.user_id = (SELECT auth.uid()));
$function$;
CREATE OR REPLACE FUNCTION vm_private.vm_has_role(p_organization_id uuid,p_allowed_roles text[]) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $function$
SELECT EXISTS (SELECT 1 FROM public.vm_memberships m WHERE m.organization_id = p_organization_id AND m.user_id = (SELECT auth.uid()) AND m.role = ANY(COALESCE(p_allowed_roles,ARRAY[]::text[])));
$function$;
CREATE OR REPLACE FUNCTION vm_private.vm_membership_role(p_organization_id uuid) RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $function$
SELECT m.role FROM public.vm_memberships m WHERE m.organization_id = p_organization_id AND m.user_id = (SELECT auth.uid());
$function$;
CREATE OR REPLACE FUNCTION vm_private.vm_jwt_membership_roles() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $function$
SELECT COALESCE(pg_catalog.jsonb_object_agg(m.organization_id::text,m.role),'{}'::jsonb) FROM public.vm_memberships m WHERE m.user_id = (NULLIF(auth.jwt() ->> 'sub',''))::uuid;
$function$;
CREATE TRIGGER vm_organizations_updated_at BEFORE UPDATE ON public.vm_organizations FOR EACH ROW EXECUTE FUNCTION vm_private.vm_set_updated_at();
CREATE TRIGGER vm_clients_updated_at BEFORE UPDATE ON public.vm_clients FOR EACH ROW EXECUTE FUNCTION vm_private.vm_set_updated_at();
CREATE TRIGGER vm_suppliers_updated_at BEFORE UPDATE ON public.vm_suppliers FOR EACH ROW EXECUTE FUNCTION vm_private.vm_set_updated_at();
CREATE TRIGGER vm_materials_updated_at BEFORE UPDATE ON public.vm_materials FOR EACH ROW EXECUTE FUNCTION vm_private.vm_set_updated_at();
CREATE TRIGGER vm_products_updated_at BEFORE UPDATE ON public.vm_products FOR EACH ROW EXECUTE FUNCTION vm_private.vm_set_updated_at();
CREATE TRIGGER vm_stock_movements_append_only BEFORE UPDATE OR DELETE ON public.vm_stock_movements FOR EACH ROW EXECUTE FUNCTION vm_private.vm_reject_immutable_row();
CREATE TRIGGER vm_product_components_versioned_only BEFORE UPDATE OR DELETE ON public.vm_product_components FOR EACH ROW EXECUTE FUNCTION vm_private.vm_reject_immutable_row();
CREATE OR REPLACE FUNCTION public.vm_create_organization(p_name text) RETURNS TABLE(organization_id uuid,membership_id uuid) LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog,public AS $function$
DECLARE v_uid uuid := auth.uid(); v_org uuid; v_membership uuid;
BEGIN
 IF v_uid IS NULL OR auth.role() <> 'authenticated' THEN RAISE EXCEPTION 'É necessário um usuário autenticado real' USING ERRCODE='28000'; END IF;
 IF p_name IS NULL OR btrim(p_name)='' OR char_length(p_name)>200 THEN RAISE EXCEPTION 'Nome da organização inválido' USING ERRCODE='22023'; END IF;
 INSERT INTO public.vm_organizations(name,created_by) VALUES (btrim(p_name),v_uid) RETURNING id INTO v_org;
 INSERT INTO public.vm_memberships(organization_id,user_id,role) VALUES (v_org,v_uid,'owner') RETURNING id INTO v_membership;
 organization_id:=v_org; membership_id:=v_membership; RETURN NEXT;
END;
$function$;
CREATE OR REPLACE FUNCTION public.vm_create_material(
 p_organization_id uuid,p_name text,p_unit text,p_package_cost numeric,p_package_quantity numeric,p_initial_stock numeric,p_reorder_level numeric,
 p_category text DEFAULT NULL,p_supplier_id uuid DEFAULT NULL,p_idempotency_key uuid DEFAULT NULL
) RETURNS TABLE(material_id uuid,opening_movement_id uuid,unit_cost numeric,stock_quantity numeric) LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog,public AS $function$
DECLARE v_uid uuid:=auth.uid(); v_material uuid; v_opening uuid;
BEGIN
 IF v_uid IS NULL OR auth.role()<>'authenticated' OR NOT vm_private.vm_has_role(p_organization_id,ARRAY['owner','admin']::text[]) THEN RAISE EXCEPTION 'Sem permissão para cadastrar insumo nesta organização' USING ERRCODE='42501'; END IF;
 IF p_name IS NULL OR btrim(p_name)='' OR char_length(p_name)>200 OR p_unit IS NULL OR btrim(p_unit)='' OR char_length(p_unit)>40 OR p_package_cost IS NULL OR p_package_cost<0 OR p_package_quantity IS NULL OR p_package_quantity<=0 OR p_initial_stock IS NULL OR p_initial_stock<0 OR p_reorder_level IS NULL OR p_reorder_level<0 THEN RAISE EXCEPTION 'Parâmetros de insumo inválidos' USING ERRCODE='22023'; END IF;
 IF p_package_cost<>round(p_package_cost,8) OR p_package_quantity<>round(p_package_quantity,8) OR p_initial_stock<>round(p_initial_stock,8) OR p_reorder_level<>round(p_reorder_level,8) THEN RAISE EXCEPTION 'Quantidades e valores aceitam no máximo 8 casas decimais' USING ERRCODE='22003'; END IF;
 IF p_category IS NOT NULL AND (btrim(p_category)='' OR char_length(p_category)>120) THEN RAISE EXCEPTION 'Categoria inválida' USING ERRCODE='22023'; END IF;
 IF p_supplier_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.vm_suppliers s WHERE s.organization_id=p_organization_id AND s.id=p_supplier_id) THEN RAISE EXCEPTION 'Fornecedor não pertence à organização' USING ERRCODE='23503'; END IF;
 PERFORM 1 FROM public.vm_organizations o WHERE o.id=p_organization_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Organização não encontrada' USING ERRCODE='23503'; END IF;
 IF p_idempotency_key IS NOT NULL THEN
  INSERT INTO public.vm_materials(organization_id,name,category,unit,package_cost,package_quantity,stock_quantity,reorder_level,supplier_id,creation_idempotency_key) VALUES (p_organization_id,btrim(p_name),NULLIF(btrim(p_category),''),btrim(p_unit),p_package_cost,p_package_quantity,p_initial_stock,p_reorder_level,p_supplier_id,p_idempotency_key) ON CONFLICT (organization_id,creation_idempotency_key) WHERE creation_idempotency_key IS NOT NULL DO NOTHING RETURNING id INTO v_material;
  IF v_material IS NULL THEN
   SELECT m.id INTO v_material FROM public.vm_materials m WHERE m.organization_id=p_organization_id AND m.creation_idempotency_key=p_idempotency_key FOR UPDATE;
   IF v_material IS NULL THEN RAISE EXCEPTION 'Não foi possível resolver a criação idempotente' USING ERRCODE='40001'; END IF;
   SELECT sm.id INTO v_opening FROM public.vm_stock_movements sm WHERE sm.organization_id=p_organization_id AND sm.material_id=v_material AND sm.movement_type='opening';
   RETURN QUERY SELECT m.id,v_opening,m.unit_cost,m.stock_quantity FROM public.vm_materials m WHERE m.organization_id=p_organization_id AND m.id=v_material; RETURN;
  END IF;
 ELSE
  INSERT INTO public.vm_materials(organization_id,name,category,unit,package_cost,package_quantity,stock_quantity,reorder_level,supplier_id) VALUES (p_organization_id,btrim(p_name),NULLIF(btrim(p_category),''),btrim(p_unit),p_package_cost,p_package_quantity,p_initial_stock,p_reorder_level,p_supplier_id) RETURNING id INTO v_material;
 END IF;
 IF p_initial_stock>0 THEN
  INSERT INTO public.vm_stock_movements(organization_id,material_id,movement_type,quantity_delta,stock_after,package_cost,package_quantity,idempotency_key,created_by) VALUES (p_organization_id,v_material,'opening',p_initial_stock,p_initial_stock,p_package_cost,p_package_quantity,p_idempotency_key,v_uid) RETURNING id INTO v_opening;
 END IF;
 RETURN QUERY SELECT m.id,v_opening,m.unit_cost,m.stock_quantity FROM public.vm_materials m WHERE m.organization_id=p_organization_id AND m.id=v_material;
END;
$function$;
CREATE OR REPLACE FUNCTION public.vm_receive_material(
 p_organization_id uuid,p_material_id uuid,p_quantity numeric,p_package_cost numeric,p_package_quantity numeric,p_note text DEFAULT NULL,p_idempotency_key uuid DEFAULT NULL
) RETURNS TABLE(movement_id uuid,material_id uuid,stock_quantity numeric,package_cost numeric,package_quantity numeric,unit_cost numeric) LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog,public AS $function$
DECLARE v_uid uuid:=auth.uid(); v_old numeric; v_new numeric; v_movement uuid; v_type text;
BEGIN
 IF v_uid IS NULL OR auth.role()<>'authenticated' OR NOT vm_private.vm_has_role(p_organization_id,ARRAY['owner','admin','production']::text[]) THEN RAISE EXCEPTION 'Sem permissão para receber insumo nesta organização' USING ERRCODE='42501'; END IF;
 IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'p_idempotency_key é obrigatório para recebimento' USING ERRCODE='22023'; END IF;
 IF p_quantity IS NULL OR p_quantity<=0 OR p_package_cost IS NULL OR p_package_cost<0 OR p_package_quantity IS NULL OR p_package_quantity<=0 OR p_quantity<>round(p_quantity,8) OR p_package_cost<>round(p_package_cost,8) OR p_package_quantity<>round(p_package_quantity,8) OR (p_note IS NOT NULL AND char_length(p_note)>2000) THEN RAISE EXCEPTION 'Parâmetros de recebimento inválidos' USING ERRCODE='22023'; END IF;
 PERFORM 1 FROM public.vm_organizations o WHERE o.id=p_organization_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Organização não encontrada' USING ERRCODE='23503'; END IF;
 SELECT sm.id,sm.movement_type INTO v_movement,v_type FROM public.vm_stock_movements sm WHERE sm.organization_id=p_organization_id AND sm.idempotency_key=p_idempotency_key FOR UPDATE;
 IF v_movement IS NOT NULL THEN
  IF v_type<>'receipt' THEN RAISE EXCEPTION 'A chave de idempotência já foi usada por outro movimento' USING ERRCODE='23505'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.vm_stock_movements sm WHERE sm.id=v_movement AND sm.organization_id=p_organization_id AND sm.material_id=p_material_id AND sm.quantity_delta=p_quantity AND sm.package_cost=p_package_cost AND sm.package_quantity=p_package_quantity AND sm.note IS NOT DISTINCT FROM p_note) THEN RAISE EXCEPTION 'Chave de idempotência reutilizada com dados diferentes' USING ERRCODE='23505'; END IF;
  RETURN QUERY SELECT sm.id,m.id,m.stock_quantity,m.package_cost,m.package_quantity,m.unit_cost FROM public.vm_stock_movements sm JOIN public.vm_materials m ON m.organization_id=sm.organization_id AND m.id=sm.material_id WHERE sm.organization_id=p_organization_id AND sm.id=v_movement; RETURN;
 END IF;
 SELECT m.stock_quantity INTO v_old FROM public.vm_materials m WHERE m.organization_id=p_organization_id AND m.id=p_material_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Insumo não encontrado nesta organização' USING ERRCODE='23503'; END IF;
 v_new:=v_old+p_quantity;
 UPDATE public.vm_materials SET package_cost=p_package_cost,package_quantity=p_package_quantity,stock_quantity=v_new WHERE organization_id=p_organization_id AND id=p_material_id;
 INSERT INTO public.vm_stock_movements(organization_id,material_id,movement_type,quantity_delta,stock_after,package_cost,package_quantity,note,idempotency_key,created_by) VALUES (p_organization_id,p_material_id,'receipt',p_quantity,v_new,p_package_cost,p_package_quantity,p_note,p_idempotency_key,v_uid) RETURNING id INTO v_movement;
 RETURN QUERY SELECT v_movement,m.id,m.stock_quantity,m.package_cost,m.package_quantity,m.unit_cost FROM public.vm_materials m WHERE m.organization_id=p_organization_id AND m.id=p_material_id;
END;
$function$;
CREATE OR REPLACE FUNCTION public.vm_adjust_material_stock(p_organization_id uuid,p_material_id uuid,p_delta numeric,p_reason text)
RETURNS TABLE(movement_id uuid,material_id uuid,stock_quantity numeric) LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog,public AS $function$
DECLARE v_uid uuid:=auth.uid(); v_old numeric; v_new numeric; v_movement uuid;
BEGIN
 IF v_uid IS NULL OR auth.role()<>'authenticated' OR NOT vm_private.vm_has_role(p_organization_id,ARRAY['owner','admin']::text[]) THEN RAISE EXCEPTION 'Sem permissão para ajustar estoque nesta organização' USING ERRCODE='42501'; END IF;
 IF p_delta IS NULL OR p_delta=0 OR p_delta<>round(p_delta,8) OR p_reason IS NULL OR btrim(p_reason)='' OR char_length(p_reason)>2000 THEN RAISE EXCEPTION 'Delta e motivo do ajuste são obrigatórios e válidos' USING ERRCODE='22023'; END IF;
 PERFORM 1 FROM public.vm_organizations o WHERE o.id=p_organization_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Organização não encontrada' USING ERRCODE='23503'; END IF;
 SELECT m.stock_quantity INTO v_old FROM public.vm_materials m WHERE m.organization_id=p_organization_id AND m.id=p_material_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Insumo não encontrado nesta organização' USING ERRCODE='23503'; END IF;
 v_new:=v_old+p_delta; IF v_new<0 THEN RAISE EXCEPTION 'O ajuste não pode deixar o estoque negativo' USING ERRCODE='23514'; END IF;
 UPDATE public.vm_materials SET stock_quantity=v_new WHERE organization_id=p_organization_id AND id=p_material_id;
 INSERT INTO public.vm_stock_movements(organization_id,material_id,movement_type,quantity_delta,stock_after,package_cost,package_quantity,note,created_by) SELECT p_organization_id,m.id,'adjustment',p_delta,v_new,m.package_cost,m.package_quantity,btrim(p_reason),v_uid FROM public.vm_materials m WHERE m.organization_id=p_organization_id AND m.id=p_material_id RETURNING id INTO v_movement;
 RETURN QUERY SELECT v_movement,p_material_id,v_new;
END;
$function$;
CREATE OR REPLACE FUNCTION public.vm_upsert_product(
 p_organization_id uuid,p_name text,p_price numeric,p_category text DEFAULT NULL,p_components jsonb DEFAULT '[]'::jsonb,p_product_id uuid DEFAULT NULL
) RETURNS TABLE(product_id uuid,version integer,price numeric,component_count integer) LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog,public AS $function$
DECLARE v_uid uuid:=auth.uid(); v_product uuid:=p_product_id; v_version integer; v_count integer; v_materials integer; v_values_ok boolean;
BEGIN
 IF v_uid IS NULL OR auth.role()<>'authenticated' OR NOT vm_private.vm_has_role(p_organization_id,ARRAY['owner','admin','production']::text[]) THEN RAISE EXCEPTION 'Sem permissão para alterar produto nesta organização' USING ERRCODE='42501'; END IF;
 IF p_name IS NULL OR btrim(p_name)='' OR char_length(p_name)>200 OR p_price IS NULL OR p_price<0 OR p_price<>round(p_price,8) OR p_components IS NULL OR jsonb_typeof(p_components)<>'array' THEN RAISE EXCEPTION 'Parâmetros de produto inválidos' USING ERRCODE='22023'; END IF;
 IF p_category IS NOT NULL AND (btrim(p_category)='' OR char_length(p_category)>120) THEN RAISE EXCEPTION 'Categoria inválida' USING ERRCODE='22023'; END IF;
 SELECT count(*)::integer,count(DISTINCT c.material_id)::integer,COALESCE(bool_and(c.material_id IS NOT NULL AND c.quantity IS NOT NULL AND c.quantity>0 AND c.quantity=round(c.quantity,8)),true) INTO v_count,v_materials,v_values_ok FROM jsonb_to_recordset(p_components) c(material_id uuid,quantity numeric);
 IF v_count<>v_materials OR NOT v_values_ok THEN RAISE EXCEPTION 'Componentes devem ter material_id único e quantidade positiva com até 8 casas' USING ERRCODE='22023'; END IF;
 PERFORM 1 FROM public.vm_organizations o WHERE o.id=p_organization_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Organização não encontrada' USING ERRCODE='23503'; END IF;
 SELECT count(*)::integer INTO v_materials FROM public.vm_materials m JOIN jsonb_to_recordset(p_components) c(material_id uuid,quantity numeric) ON c.material_id=m.id WHERE m.organization_id=p_organization_id;
 IF v_materials<>v_count THEN RAISE EXCEPTION 'Todos os componentes devem ser insumos da mesma organização' USING ERRCODE='23503'; END IF;
 IF v_product IS NULL THEN
  INSERT INTO public.vm_products(organization_id,name,category,price,current_version) VALUES (p_organization_id,btrim(p_name),NULLIF(btrim(p_category),''),p_price,1) RETURNING id,current_version INTO v_product,v_version;
 ELSE
  SELECT p.current_version INTO v_version FROM public.vm_products p WHERE p.organization_id=p_organization_id AND p.id=v_product FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Produto não encontrado nesta organização' USING ERRCODE='23503'; END IF;
  v_version:=v_version+1;
  UPDATE public.vm_products SET name=btrim(p_name),category=NULLIF(btrim(p_category),''),price=p_price,current_version=v_version WHERE organization_id=p_organization_id AND id=v_product;
 END IF;
 INSERT INTO public.vm_product_components(organization_id,product_id,product_version,material_id,quantity) SELECT p_organization_id,v_product,v_version,c.material_id,c.quantity::numeric(20,8) FROM jsonb_to_recordset(p_components) c(material_id uuid,quantity numeric);
 RETURN QUERY SELECT v_product,v_version,p_price,v_count;
END;
$function$;
ALTER TABLE public.vm_schema_migrations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vm_organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vm_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vm_clients ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vm_suppliers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vm_materials ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vm_stock_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vm_products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vm_product_components ENABLE ROW LEVEL SECURITY;
CREATE POLICY vm_organizations_member_select ON public.vm_organizations FOR SELECT TO authenticated USING ((SELECT vm_private.vm_is_member(id)));
CREATE POLICY vm_memberships_member_select ON public.vm_memberships FOR SELECT TO authenticated USING ((SELECT vm_private.vm_is_member(organization_id)));
CREATE POLICY vm_clients_member_select ON public.vm_clients FOR SELECT TO authenticated USING ((SELECT vm_private.vm_is_member(organization_id)));
CREATE POLICY vm_clients_write_insert ON public.vm_clients FOR INSERT TO authenticated WITH CHECK ((SELECT vm_private.vm_has_role(organization_id,ARRAY['owner','admin','finance']::text[])));
CREATE POLICY vm_clients_write_update ON public.vm_clients FOR UPDATE TO authenticated USING ((SELECT vm_private.vm_has_role(organization_id,ARRAY['owner','admin','finance']::text[]))) WITH CHECK ((SELECT vm_private.vm_has_role(organization_id,ARRAY['owner','admin','finance']::text[])));
CREATE POLICY vm_clients_write_delete ON public.vm_clients FOR DELETE TO authenticated USING ((SELECT vm_private.vm_has_role(organization_id,ARRAY['owner','admin','finance']::text[])));
CREATE POLICY vm_suppliers_member_select ON public.vm_suppliers FOR SELECT TO authenticated USING ((SELECT vm_private.vm_is_member(organization_id)));
CREATE POLICY vm_suppliers_write_insert ON public.vm_suppliers FOR INSERT TO authenticated WITH CHECK ((SELECT vm_private.vm_has_role(organization_id,ARRAY['owner','admin','finance']::text[])));
CREATE POLICY vm_suppliers_write_update ON public.vm_suppliers FOR UPDATE TO authenticated USING ((SELECT vm_private.vm_has_role(organization_id,ARRAY['owner','admin','finance']::text[]))) WITH CHECK ((SELECT vm_private.vm_has_role(organization_id,ARRAY['owner','admin','finance']::text[])));
CREATE POLICY vm_suppliers_write_delete ON public.vm_suppliers FOR DELETE TO authenticated USING ((SELECT vm_private.vm_has_role(organization_id,ARRAY['owner','admin','finance']::text[])));
CREATE POLICY vm_materials_member_select ON public.vm_materials FOR SELECT TO authenticated USING ((SELECT vm_private.vm_is_member(organization_id)));
CREATE POLICY vm_stock_movements_member_select ON public.vm_stock_movements FOR SELECT TO authenticated USING ((SELECT vm_private.vm_is_member(organization_id)));
CREATE POLICY vm_products_member_select ON public.vm_products FOR SELECT TO authenticated USING ((SELECT vm_private.vm_is_member(organization_id)));
CREATE POLICY vm_product_components_member_select ON public.vm_product_components FOR SELECT TO authenticated USING ((SELECT vm_private.vm_is_member(organization_id)));
DO $publication$
DECLARE v_table text;
BEGIN
 IF EXISTS (SELECT 1 FROM pg_catalog.pg_publication WHERE pubname='supabase_realtime' AND puballtables) THEN RETURN; END IF;
 IF EXISTS (SELECT 1 FROM pg_catalog.pg_publication WHERE pubname='supabase_realtime') THEN
  FOREACH v_table IN ARRAY ARRAY['vm_organizations','vm_memberships','vm_clients','vm_suppliers','vm_materials','vm_stock_movements','vm_products','vm_product_components'] LOOP
   IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_publication_tables WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename=v_table) THEN EXECUTE pg_catalog.format('ALTER PUBLICATION %I ADD TABLE %I.%I','supabase_realtime','public',v_table); END IF;
  END LOOP;
 END IF;
END;
$publication$;
REVOKE ALL ON SCHEMA vm_private FROM PUBLIC,anon,authenticated;
GRANT USAGE ON SCHEMA vm_private TO authenticated;
REVOKE ALL ON TABLE public.vm_schema_migrations,public.vm_organizations,public.vm_memberships,public.vm_clients,public.vm_suppliers,public.vm_materials,public.vm_stock_movements,public.vm_products,public.vm_product_components FROM PUBLIC,anon,authenticated;
GRANT SELECT ON TABLE public.vm_organizations,public.vm_memberships,public.vm_clients,public.vm_suppliers,public.vm_materials,public.vm_stock_movements,public.vm_products,public.vm_product_components TO authenticated;
GRANT INSERT (organization_id,name,email,phone,notes) ON TABLE public.vm_clients TO authenticated;
GRANT UPDATE (name,email,phone,notes) ON TABLE public.vm_clients TO authenticated;
GRANT DELETE ON TABLE public.vm_clients TO authenticated;
GRANT INSERT (organization_id,name,email,phone,notes) ON TABLE public.vm_suppliers TO authenticated;
GRANT UPDATE (name,email,phone,notes) ON TABLE public.vm_suppliers TO authenticated;
GRANT DELETE ON TABLE public.vm_suppliers TO authenticated;
REVOKE ALL ON FUNCTION vm_private.vm_set_updated_at(),vm_private.vm_reject_immutable_row(),vm_private.vm_is_member(uuid),vm_private.vm_has_role(uuid,text[]),vm_private.vm_membership_role(uuid),vm_private.vm_jwt_membership_roles() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION vm_private.vm_is_member(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION vm_private.vm_has_role(uuid,text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION vm_private.vm_membership_role(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION vm_private.vm_jwt_membership_roles() TO authenticated;
REVOKE ALL ON FUNCTION public.vm_create_organization(text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.vm_create_material(uuid,text,text,numeric,numeric,numeric,numeric,text,uuid,uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.vm_receive_material(uuid,uuid,numeric,numeric,numeric,text,uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.vm_adjust_material_stock(uuid,uuid,numeric,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.vm_upsert_product(uuid,text,numeric,text,jsonb,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.vm_create_organization(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.vm_create_material(uuid,text,text,numeric,numeric,numeric,numeric,text,uuid,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.vm_receive_material(uuid,uuid,numeric,numeric,numeric,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.vm_adjust_material_stock(uuid,uuid,numeric,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.vm_upsert_product(uuid,text,numeric,text,jsonb,uuid) TO authenticated;
INSERT INTO public.vm_schema_migrations(version,description) VALUES ('20261029203500_foundation','Fundação ERP: organizações, memberships, cadastros, estoque, produtos, RLS e RPCs') ON CONFLICT (version) DO NOTHING;
COMMIT;
