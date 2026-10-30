BEGIN;

-- Public sales is deliberately additive. Existing order helpers remain unchanged:
-- quote issuance resolves the live catalog once; acceptance copies only quote rows.
-- No temporary order, client JWT impersonation, payment, production or consumption.

ALTER TABLE public.vm_orders
  ADD COLUMN commercial_terms text
    CHECK (commercial_terms IS NULL OR char_length(commercial_terms) <= 20000);

CREATE TABLE public.vm_quotes (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
  public_token uuid NOT NULL DEFAULT pg_catalog.gen_random_uuid(),
  parent_quote_id uuid,
  client_id uuid NOT NULL,
  client_name_snapshot text NOT NULL CHECK (btrim(client_name_snapshot) <> '' AND char_length(client_name_snapshot) <= 200),
  title text NOT NULL CHECK (btrim(title) <> '' AND char_length(title) <= 200),
  order_date date NOT NULL CHECK (vm_private.vm_date_valid(order_date)),
  production_date date CHECK (production_date IS NULL OR vm_private.vm_date_valid(production_date)),
  delivery_date date CHECK (delivery_date IS NULL OR vm_private.vm_date_valid(delivery_date)),
  responsible_membership_id uuid,
  public_notes text CHECK (public_notes IS NULL OR char_length(public_notes) <= 5000),
  internal_notes text CHECK (internal_notes IS NULL OR char_length(internal_notes) <= 10000),
  commercial_terms text CHECK (commercial_terms IS NULL OR char_length(commercial_terms) <= 20000),
  subtotal numeric(20,2) NOT NULL CHECK (vm_private.vm_numeric_valid(subtotal,2,999999999999999999.99,true)),
  discount_type text NOT NULL CHECK (discount_type IN ('none','fixed','percent')),
  discount_value numeric(20,8) NOT NULL CHECK (vm_private.vm_numeric_valid(discount_value,8,999999999999.99999999,true)),
  discount_amount numeric(20,2) NOT NULL CHECK (vm_private.vm_numeric_valid(discount_amount,2,999999999999999999.99,true)),
  shipping_amount numeric(20,2) NOT NULL CHECK (vm_private.vm_numeric_valid(shipping_amount,2,999999999999999999.99,true)),
  total_amount numeric(20,2) NOT NULL CHECK (vm_private.vm_numeric_valid(total_amount,2,999999999999999999.99,true)),
  currency text NOT NULL DEFAULT 'BRL' CHECK (currency = 'BRL'),
  valid_until date NOT NULL CHECK (vm_private.vm_date_valid(valid_until)),
  status text NOT NULL DEFAULT 'Sent' CHECK (status IN ('Sent','Approved','Revoked')),
  status_version bigint NOT NULL DEFAULT 1 CHECK (status_version > 0),
  revoked_at timestamptz,
  accepted_at timestamptz,
  accepted_order_id uuid,
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  UNIQUE (organization_id,id),
  UNIQUE (organization_id,public_token),
  FOREIGN KEY (organization_id,parent_quote_id) REFERENCES public.vm_quotes(organization_id,id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,client_id) REFERENCES public.vm_clients(organization_id,id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,responsible_membership_id) REFERENCES public.vm_memberships(organization_id,id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,accepted_order_id) REFERENCES public.vm_orders(organization_id,id) ON DELETE RESTRICT,
  CHECK (discount_amount <= subtotal AND total_amount = subtotal - discount_amount + shipping_amount),
  CHECK ((discount_type = 'none' AND discount_value = 0 AND discount_amount = 0)
      OR (discount_type = 'fixed' AND discount_value = discount_amount)
      OR (discount_type = 'percent' AND discount_value <= 100)),
  CHECK (production_date IS NULL OR production_date >= order_date),
  CHECK (delivery_date IS NULL OR delivery_date >= order_date),
  CHECK (production_date IS NULL OR delivery_date IS NULL OR delivery_date >= production_date),
  CHECK ((status = 'Sent' AND accepted_order_id IS NULL AND accepted_at IS NULL)
      OR (status = 'Revoked' AND accepted_order_id IS NULL AND accepted_at IS NULL)
      OR (status = 'Approved' AND accepted_order_id IS NOT NULL AND accepted_at IS NOT NULL)),
  CHECK ((status = 'Revoked') = (revoked_at IS NOT NULL))
);
CREATE INDEX vm_quotes_org_status_idx ON public.vm_quotes(organization_id,status,valid_until);
CREATE INDEX vm_quotes_parent_idx ON public.vm_quotes(organization_id,parent_quote_id);
CREATE UNIQUE INDEX vm_quotes_accepted_order_uq
  ON public.vm_quotes(organization_id,accepted_order_id) WHERE accepted_order_id IS NOT NULL;

CREATE TABLE public.vm_quote_items (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
  quote_id uuid NOT NULL,
  position integer NOT NULL CHECK (position BETWEEN 1 AND 200),
  kind text NOT NULL CHECK (kind IN ('product','manual_service')),
  product_id uuid,
  product_version integer,
  variant_id uuid,
  variant_version integer,
  title text NOT NULL CHECK (btrim(title) <> '' AND char_length(title) <= 200),
  quantity numeric(20,8) NOT NULL CHECK (quantity > 0 AND vm_private.vm_numeric_valid(quantity,8,999999999999.99999999,true)),
  billing_unit text NOT NULL CHECK (billing_unit IN ('unit','m2')),
  dimensions jsonb CHECK (dimensions IS NULL OR pg_catalog.jsonb_typeof(dimensions) = 'object'),
  dimensions_factor numeric(20,8) NOT NULL CHECK (dimensions_factor > 0 AND vm_private.vm_numeric_valid(dimensions_factor,8,999999999999.99999999,true)),
  billed_quantity numeric(20,8) NOT NULL CHECK (billed_quantity > 0 AND vm_private.vm_numeric_valid(billed_quantity,8,999999999999.99999999,true)),
  unit_price numeric(20,8) NOT NULL CHECK (vm_private.vm_numeric_valid(unit_price,8,999999999999.99999999,true)),
  price_source text NOT NULL CHECK (price_source IN ('catalog','override','manual')),
  price_override_reason text CHECK (price_override_reason IS NULL OR (btrim(price_override_reason) <> '' AND char_length(price_override_reason) <= 2000)),
  line_amount_raw numeric(40,16) NOT NULL CHECK (vm_private.vm_numeric_valid(line_amount_raw,16,999999999999999999999999.9999999999999999,true)),
  line_amount numeric(20,2) NOT NULL CHECK (vm_private.vm_numeric_valid(line_amount,2,999999999999999999.99,true)),
  recipe_mode text NOT NULL CHECK (recipe_mode IN ('base','inherit_base','own','none')),
  unit_composition_cost numeric(40,16) NOT NULL CHECK (vm_private.vm_numeric_valid(unit_composition_cost,16,999999999999999999999999.9999999999999999,true)),
  total_composition_cost numeric(40,16) NOT NULL CHECK (vm_private.vm_numeric_valid(total_composition_cost,16,999999999999999999999999.9999999999999999,true)),
  product_snapshot jsonb NOT NULL CHECK (pg_catalog.jsonb_typeof(product_snapshot) = 'object'),
  price_snapshot jsonb NOT NULL CHECK (pg_catalog.jsonb_typeof(price_snapshot) = 'object'),
  details text CHECK (details IS NULL OR char_length(details) <= 5000),
  personalization jsonb CHECK (personalization IS NULL OR (pg_catalog.jsonb_typeof(personalization) = 'object' AND pg_catalog.octet_length(personalization::text) <= 20000)),
  production_date date CHECK (production_date IS NULL OR vm_private.vm_date_valid(production_date)),
  delivery_date date CHECK (delivery_date IS NULL OR vm_private.vm_date_valid(delivery_date)),
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  UNIQUE (organization_id,id), UNIQUE (organization_id,quote_id,id), UNIQUE (organization_id,quote_id,position),
  FOREIGN KEY (organization_id,quote_id) REFERENCES public.vm_quotes(organization_id,id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,product_id,product_version) REFERENCES public.vm_product_versions(organization_id,product_id,product_version) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,variant_id) REFERENCES public.vm_product_variants(organization_id,id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,product_id,variant_id) REFERENCES public.vm_product_variants(organization_id,product_id,id) ON DELETE RESTRICT,
  CHECK ((kind = 'product' AND product_id IS NOT NULL AND product_version IS NOT NULL AND recipe_mode <> 'none')
      OR (kind = 'manual_service' AND product_id IS NULL AND product_version IS NULL AND variant_id IS NULL AND variant_version IS NULL AND recipe_mode = 'none' AND billing_unit = 'unit')),
  CHECK ((variant_id IS NULL AND variant_version IS NULL) OR (variant_id IS NOT NULL AND variant_version > 0)),
  CHECK (billed_quantity = quantity * dimensions_factor),
  CHECK (line_amount_raw = billed_quantity * unit_price AND line_amount = pg_catalog.round(line_amount_raw,2)),
  CHECK ((price_source = 'catalog' AND price_override_reason IS NULL) OR (price_source IN ('override','manual') AND price_override_reason IS NOT NULL))
);
CREATE INDEX vm_quote_items_quote_idx ON public.vm_quote_items(organization_id,quote_id,position);

CREATE TABLE public.vm_quote_item_materials (
  organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
  quote_id uuid NOT NULL,
  item_id uuid NOT NULL,
  material_id uuid NOT NULL,
  material_name_snapshot text NOT NULL,
  unit text NOT NULL CHECK (btrim(unit) <> '' AND char_length(unit) <= 40),
  quantity_snapshot numeric(20,8) NOT NULL CHECK (quantity_snapshot > 0 AND vm_private.vm_numeric_valid(quantity_snapshot,8,999999999999.99999999,true)),
  unit_cost_snapshot numeric(20,8) NOT NULL CHECK (vm_private.vm_numeric_valid(unit_cost_snapshot,8,999999999999.99999999,true)),
  consumption_quantity numeric(20,8) NOT NULL CHECK (consumption_quantity > 0 AND vm_private.vm_numeric_valid(consumption_quantity,8,999999999999.99999999,true)),
  consumption_cost numeric(40,16) NOT NULL CHECK (vm_private.vm_numeric_valid(consumption_cost,16,999999999999999999999999.9999999999999999,true)),
  PRIMARY KEY (organization_id,item_id,material_id),
  FOREIGN KEY (organization_id,quote_id,item_id) REFERENCES public.vm_quote_items(organization_id,quote_id,id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,material_id) REFERENCES public.vm_materials(organization_id,id) ON DELETE RESTRICT,
  CHECK (consumption_cost = consumption_quantity * unit_cost_snapshot)
);
CREATE INDEX vm_quote_item_materials_quote_idx ON public.vm_quote_item_materials(organization_id,quote_id,material_id);

CREATE TABLE vm_private.vm_quote_client_snapshots (
  organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
  quote_id uuid NOT NULL,
  client_id uuid NOT NULL,
  snapshot jsonb NOT NULL CHECK (pg_catalog.jsonb_typeof(snapshot) = 'object'),
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  PRIMARY KEY (organization_id,quote_id),
  FOREIGN KEY (organization_id,quote_id) REFERENCES public.vm_quotes(organization_id,id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,client_id) REFERENCES public.vm_clients(organization_id,id) ON DELETE RESTRICT
);

CREATE TABLE public.vm_quote_events (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
  quote_id uuid NOT NULL,
  status_version bigint NOT NULL CHECK (status_version > 0),
  event_type text NOT NULL CHECK (event_type IN ('created','revoked','approved')),
  previous_status text,
  status text NOT NULL CHECK (status IN ('Sent','Revoked','Approved')),
  payload jsonb NOT NULL CHECK (pg_catalog.jsonb_typeof(payload) = 'object'),
  created_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  UNIQUE (organization_id,quote_id,status_version),
  FOREIGN KEY (organization_id,quote_id) REFERENCES public.vm_quotes(organization_id,id) ON DELETE RESTRICT
);
CREATE INDEX vm_quote_events_quote_idx ON public.vm_quote_events(organization_id,quote_id,status_version);

CREATE TABLE vm_private.vm_quote_requests (
  organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
  nonce uuid NOT NULL,
  operation text NOT NULL CHECK (operation IN ('create','revoke','issue_tracking','revoke_tracking')),
  quote_id uuid,
  payload jsonb NOT NULL CHECK (pg_catalog.jsonb_typeof(payload) = 'object'),
  result jsonb NOT NULL CHECK (pg_catalog.jsonb_typeof(result) = 'object'),
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  PRIMARY KEY (organization_id,nonce),
  FOREIGN KEY (organization_id,quote_id) REFERENCES public.vm_quotes(organization_id,id) ON DELETE RESTRICT
);

CREATE TABLE public.vm_tracking_capabilities (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
  order_id uuid NOT NULL,
  token uuid NOT NULL DEFAULT pg_catalog.gen_random_uuid(),
  source_quote_id uuid,
  source_expiry date,
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  issued_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  UNIQUE (organization_id,id), UNIQUE (organization_id,token),
  FOREIGN KEY (organization_id,order_id) REFERENCES public.vm_orders(organization_id,id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,source_quote_id) REFERENCES public.vm_quotes(organization_id,id) ON DELETE RESTRICT,
  CHECK (expires_at > created_at),
  CHECK (revoked_at IS NULL OR revoked_at >= created_at)
);
CREATE UNIQUE INDEX vm_tracking_current_order_uq
  ON public.vm_tracking_capabilities(organization_id,order_id) WHERE revoked_at IS NULL;
CREATE INDEX vm_tracking_token_valid_idx
  ON public.vm_tracking_capabilities(token,expires_at) WHERE revoked_at IS NULL;

CREATE TABLE vm_private.vm_quote_acceptances (
  organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
  quote_id uuid NOT NULL,
  order_id uuid NOT NULL,
  tracking_id uuid NOT NULL,
  accepted_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  result jsonb NOT NULL CHECK (pg_catalog.jsonb_typeof(result) = 'object'),
  PRIMARY KEY (organization_id,quote_id),
  UNIQUE (organization_id,order_id),
  UNIQUE (organization_id,tracking_id),
  FOREIGN KEY (organization_id,quote_id) REFERENCES public.vm_quotes(organization_id,id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,order_id) REFERENCES public.vm_orders(organization_id,id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,tracking_id) REFERENCES public.vm_tracking_capabilities(organization_id,id) ON DELETE RESTRICT
);

CREATE TABLE vm_private.vm_tracking_requests (
  organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
  nonce uuid NOT NULL,
  operation text NOT NULL CHECK (operation IN ('issue_tracking','revoke_tracking')),
  tracking_id uuid,
  payload jsonb NOT NULL CHECK (pg_catalog.jsonb_typeof(payload) = 'object'),
  result jsonb NOT NULL CHECK (pg_catalog.jsonb_typeof(result) = 'object'),
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  PRIMARY KEY (organization_id,nonce),
  FOREIGN KEY (organization_id,tracking_id) REFERENCES public.vm_tracking_capabilities(organization_id,id) ON DELETE RESTRICT
);

CREATE TABLE vm_private.vm_tracking_broadcasts (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
  tracking_id uuid NOT NULL,
  event_id uuid NOT NULL,
  status_version bigint NOT NULL,
  status text NOT NULL,
  topic text NOT NULL,
  payload jsonb NOT NULL CHECK (pg_catalog.jsonb_typeof(payload) = 'object'),
  send_state text NOT NULL CHECK (send_state IN ('enqueued','failed')),
  attempts integer NOT NULL DEFAULT 1 CHECK (attempts >= 1),
  last_error text,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  UNIQUE (organization_id,tracking_id,event_id),
  FOREIGN KEY (organization_id,tracking_id) REFERENCES public.vm_tracking_capabilities(organization_id,id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,event_id) REFERENCES public.vm_order_events(organization_id,id) ON DELETE RESTRICT
);
CREATE INDEX vm_tracking_broadcasts_admin_idx ON vm_private.vm_tracking_broadcasts(organization_id,created_at DESC);

-- Private append-only rows and controlled capability/status mutations.
CREATE FUNCTION vm_private.vm_quote_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $function$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Orçamento histórico não pode ser apagado' USING ERRCODE = '55000';
  END IF;
  IF pg_catalog.current_setting('vm.quote_mutation',true) IS DISTINCT FROM '1' THEN
    RAISE EXCEPTION 'Orçamento é imutável; use a RPC de revisão/aceite/revogação' USING ERRCODE = '55000';
  END IF;
  IF (pg_catalog.to_jsonb(NEW)-ARRAY['status','status_version','revoked_at','accepted_at','accepted_order_id','updated_at'])
       IS DISTINCT FROM (pg_catalog.to_jsonb(OLD)-ARRAY['status','status_version','revoked_at','accepted_at','accepted_order_id','updated_at']) THEN
    RAISE EXCEPTION 'Dados comerciais do orçamento são imutáveis' USING ERRCODE = '55000';
  END IF;
  IF NEW.status_version <> OLD.status_version + 1
     OR NOT EXISTS (
       SELECT 1 FROM public.vm_quote_events e
       WHERE e.organization_id = NEW.organization_id AND e.quote_id = NEW.id
         AND e.status_version = NEW.status_version AND e.status = NEW.status
         AND e.previous_status = OLD.status
     ) THEN
    RAISE EXCEPTION 'Mudança do orçamento exige evento transacional' USING ERRCODE = '55000';
  END IF;
  IF NOT ((OLD.status = 'Sent' AND NEW.status IN ('Revoked','Approved'))
       OR (OLD.status = NEW.status)) THEN
    RAISE EXCEPTION 'Transição de orçamento inválida' USING ERRCODE = '22023';
  END IF;
  IF NEW.status = 'Revoked' AND (NEW.revoked_at IS NULL OR NEW.accepted_order_id IS NOT NULL OR NEW.accepted_at IS NOT NULL) THEN
    RAISE EXCEPTION 'Revogação de orçamento inválida' USING ERRCODE = '22023';
  END IF;
  IF NEW.status = 'Approved' AND (NEW.accepted_order_id IS NULL OR NEW.accepted_at IS NULL OR NEW.revoked_at IS NOT NULL) THEN
    RAISE EXCEPTION 'Aceite de orçamento inválido' USING ERRCODE = '22023';
  END IF;
  NEW.updated_at := pg_catalog.clock_timestamp();
  RETURN NEW;
END;
$function$;
CREATE TRIGGER vm_quotes_guard BEFORE UPDATE OR DELETE ON public.vm_quotes
  FOR EACH ROW EXECUTE FUNCTION vm_private.vm_quote_guard();

CREATE FUNCTION vm_private.vm_tracking_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $function$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Capability de rastreio não pode ser apagada' USING ERRCODE = '55000';
  END IF;
  IF pg_catalog.current_setting('vm.tracking_mutation',true) IS DISTINCT FROM '1'
     OR (pg_catalog.to_jsonb(NEW)-'revoked_at') IS DISTINCT FROM (pg_catalog.to_jsonb(OLD)-'revoked_at')
     OR OLD.revoked_at IS NOT NULL OR NEW.revoked_at IS NULL THEN
    RAISE EXCEPTION 'Capability só pode ser revogada pela RPC' USING ERRCODE = '55000';
  END IF;
  RETURN NEW;
END;
$function$;
CREATE TRIGGER vm_tracking_guard BEFORE UPDATE OR DELETE ON public.vm_tracking_capabilities
  FOR EACH ROW EXECUTE FUNCTION vm_private.vm_tracking_guard();

DO $append_only$
DECLARE v_table text;
BEGIN
  FOREACH v_table IN ARRAY ARRAY[
    'public.vm_quote_items','public.vm_quote_item_materials','public.vm_quote_events',
    'vm_private.vm_quote_client_snapshots','vm_private.vm_quote_requests',
    'vm_private.vm_quote_acceptances','vm_private.vm_tracking_requests','vm_private.vm_tracking_broadcasts'
  ] LOOP
    EXECUTE pg_catalog.format('CREATE TRIGGER vm_public_sales_append_only BEFORE UPDATE OR DELETE ON %s FOR EACH ROW EXECUTE FUNCTION vm_private.vm_reject_immutable_row()',v_table);
  END LOOP;
END;
$append_only$;

CREATE FUNCTION vm_private.vm_quote_canonical(p_data jsonb,p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path = '' AS $function$
DECLARE v_payload jsonb;
BEGIN
  PERFORM vm_private.vm_order_keys(p_data,ARRAY['client_id','title','order_date','production_date','delivery_date','responsible_membership_id','public_notes','internal_notes','discount_type','discount_value','shipping_amount']);
  v_payload := vm_private.vm_order_canonical(p_data || pg_catalog.jsonb_build_object('initial_status','Pendente'),p_items);
  RETURN pg_catalog.jsonb_build_object('data',(v_payload->'data')::jsonb-'initial_status'::text,'items',v_payload->'items');
END;
$function$;

CREATE FUNCTION vm_private.vm_quote_event_payload(p_quote public.vm_quotes,p_status text)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = '' AS $function$
  SELECT pg_catalog.jsonb_build_object(
    'quote_token',p_quote.public_token,'status',p_status,'status_version',p_quote.status_version::text,
    'title',p_quote.title,'order_date',p_quote.order_date,'production_date',p_quote.production_date,
    'delivery_date',p_quote.delivery_date,'public_notes',p_quote.public_notes,
    'commercial_terms',p_quote.commercial_terms,'subtotal',p_quote.subtotal::text,
    'discount_type',p_quote.discount_type,'discount_value',p_quote.discount_value::text,
    'discount_amount',p_quote.discount_amount::text,'shipping_amount',p_quote.shipping_amount::text,
    'total_amount',p_quote.total_amount::text,'currency',p_quote.currency,'valid_until',p_quote.valid_until
  )
$function$;

CREATE FUNCTION vm_private.vm_quote_issue_tracking(p_organization_id uuid,p_order_id uuid,p_quote_id uuid,p_source_expiry date,p_actor uuid,p_expires_at timestamptz)
RETURNS public.vm_tracking_capabilities LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE v_cap public.vm_tracking_capabilities%ROWTYPE;
BEGIN
  IF p_expires_at IS NULL OR p_expires_at <= pg_catalog.clock_timestamp() THEN
    RAISE EXCEPTION 'Expiração de rastreio deve ser futura' USING ERRCODE = '22023';
  END IF;
  INSERT INTO public.vm_tracking_capabilities(organization_id,order_id,source_quote_id,source_expiry,expires_at,issued_by)
    VALUES(p_organization_id,p_order_id,p_quote_id,p_source_expiry,p_expires_at,p_actor)
    RETURNING * INTO v_cap;
  RETURN v_cap;
END;
$function$;

-- Build directly from quote snapshots. This intentionally never calls the current catalog resolver.
CREATE FUNCTION vm_private.vm_quote_build_order(p_organization_id uuid,p_quote_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE
  v_quote public.vm_quotes%ROWTYPE; v_order uuid; v_code text; v_item record; v_material record;
  v_item_id uuid; v_position integer := 0; v_status_result jsonb;
BEGIN
  SELECT q.* INTO v_quote FROM public.vm_quotes q
    WHERE q.organization_id = p_organization_id AND q.id = p_quote_id FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Orçamento não encontrado' USING ERRCODE = '23503'; END IF;
  v_order := pg_catalog.gen_random_uuid();
  v_code := 'PED-' || pg_catalog.upper(pg_catalog.replace(v_order::text,'-',''));
  INSERT INTO public.vm_orders(
    id,organization_id,code,client_id,client_name_snapshot,title,order_date,production_date,delivery_date,
    responsible_membership_id,public_notes,internal_notes,commercial_terms,subtotal,discount_type,discount_value,
    discount_amount,shipping_amount,total_amount,created_by
  ) VALUES (
    v_order,p_organization_id,v_code,v_quote.client_id,v_quote.client_name_snapshot,v_quote.title,v_quote.order_date,
    v_quote.production_date,v_quote.delivery_date,v_quote.responsible_membership_id,v_quote.public_notes,
    v_quote.internal_notes,v_quote.commercial_terms,v_quote.subtotal,v_quote.discount_type,v_quote.discount_value,
    v_quote.discount_amount,v_quote.shipping_amount,v_quote.total_amount,NULL
  );
  INSERT INTO vm_private.vm_order_client_snapshots(organization_id,order_id,client_id,snapshot)
    SELECT p_organization_id,v_order,s.client_id,s.snapshot
    FROM vm_private.vm_quote_client_snapshots s
    WHERE s.organization_id = p_organization_id AND s.quote_id = p_quote_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Snapshot privado do cliente ausente no orçamento' USING ERRCODE = '23514'; END IF;
  FOR v_item IN SELECT i.* FROM public.vm_quote_items i WHERE i.organization_id = p_organization_id AND i.quote_id = p_quote_id ORDER BY i.position LOOP
    v_position := v_position + 1;
    INSERT INTO public.vm_order_items(
      organization_id,order_id,position,kind,product_id,product_version,variant_id,variant_version,title,
      quantity,billing_unit,dimensions,dimensions_factor,billed_quantity,unit_price,price_source,price_override_reason,
      line_amount_raw,line_amount,recipe_mode,unit_composition_cost,total_composition_cost,product_snapshot,price_snapshot,
      details,personalization,production_date,delivery_date
    ) VALUES (
      p_organization_id,v_order,v_position,v_item.kind,v_item.product_id,v_item.product_version,v_item.variant_id,v_item.variant_version,
      v_item.title,v_item.quantity,v_item.billing_unit,v_item.dimensions,v_item.dimensions_factor,v_item.billed_quantity,v_item.unit_price,
      v_item.price_source,v_item.price_override_reason,v_item.line_amount_raw,v_item.line_amount,v_item.recipe_mode,
      v_item.unit_composition_cost,v_item.total_composition_cost,v_item.product_snapshot,v_item.price_snapshot,v_item.details,
      v_item.personalization,v_item.production_date,v_item.delivery_date
    ) RETURNING id INTO v_item_id;
    FOR v_material IN
      SELECT m.* FROM public.vm_quote_item_materials m
      WHERE m.organization_id = p_organization_id AND m.quote_id = p_quote_id AND m.item_id = v_item.id
      ORDER BY m.material_id
    LOOP
      INSERT INTO public.vm_order_item_materials(
        organization_id,order_id,item_id,material_id,material_name_snapshot,unit,quantity_snapshot,unit_cost_snapshot,
        consumption_quantity,consumption_cost
      ) VALUES (
        p_organization_id,v_order,v_item_id,v_material.material_id,v_material.material_name_snapshot,v_material.unit,
        v_material.quantity_snapshot,v_material.unit_cost_snapshot,v_material.consumption_quantity,v_material.consumption_cost
      );
    END LOOP;
  END LOOP;
  IF v_position = 0 THEN RAISE EXCEPTION 'Orçamento sem itens congelados' USING ERRCODE = '23514'; END IF;
  v_status_result := vm_private.vm_order_apply_status(p_organization_id,v_order,'Pendente',NULL,NULL,true);
  RETURN v_status_result || pg_catalog.jsonb_build_object(
    'code',v_code,'subtotal',v_quote.subtotal::text,'discount_amount',v_quote.discount_amount::text,
    'shipping_amount',v_quote.shipping_amount::text,'total_amount',v_quote.total_amount::text,
    'paid_amount','0.00','balance_amount',v_quote.total_amount::text
  );
END;
$function$;

CREATE FUNCTION public.vm_create_quote(
  p_organization_id uuid,p_data jsonb,p_items jsonb,p_valid_until date,
  p_terms text DEFAULT NULL,p_nonce uuid DEFAULT NULL,p_parent_quote_id uuid DEFAULT NULL
)
RETURNS TABLE(quote_id uuid,public_token uuid,status text,status_version text,valid_until date,subtotal text,discount_amount text,shipping_amount text,total_amount text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE
  v_actor uuid := auth.uid(); v_terms text := NULLIF(pg_catalog.btrim(p_terms),''); v_canonical jsonb; v_payload jsonb;
  v_request vm_private.vm_quote_requests%ROWTYPE; v_parent public.vm_quotes%ROWTYPE; v_client public.vm_clients%ROWTYPE;
  v_quote public.vm_quotes%ROWTYPE; v_item jsonb; v_resolved jsonb; v_items jsonb := '[]'::jsonb; v_subtotal numeric := 0;
  v_discount numeric; v_total numeric; v_position integer := 0; v_event_id uuid; v_now timestamptz;
  v_aggregate record; v_result jsonb;
BEGIN
  IF v_actor IS NULL OR auth.role() IS DISTINCT FROM 'authenticated'
     OR NOT vm_private.vm_has_role(p_organization_id,ARRAY['owner','admin','finance']::text[]) THEN
    RAISE EXCEPTION 'Sem permissão para emitir orçamento nesta organização' USING ERRCODE = '42501';
  END IF;
  IF p_nonce IS NULL THEN RAISE EXCEPTION 'Chave de idempotência obrigatória' USING ERRCODE = '22023'; END IF;
  IF p_valid_until IS NULL OR NOT vm_private.vm_date_valid(p_valid_until) OR p_valid_until < CURRENT_DATE THEN
    RAISE EXCEPTION 'Validade do orçamento inválida' USING ERRCODE = '22023';
  END IF;
  IF v_terms IS NOT NULL AND pg_catalog.char_length(v_terms) > 20000 THEN
    RAISE EXCEPTION 'Termos excedem 20000 caracteres' USING ERRCODE = '22023';
  END IF;
  v_canonical := vm_private.vm_quote_canonical(p_data,p_items);
  v_payload := pg_catalog.jsonb_build_object('canonical',v_canonical,'valid_until',p_valid_until,'terms',v_terms,'parent_quote_id',p_parent_quote_id);
  PERFORM 1 FROM public.vm_organizations o WHERE o.id = p_organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Organização não encontrada' USING ERRCODE = '23503'; END IF;
  SELECT r.* INTO v_request FROM vm_private.vm_quote_requests r
    WHERE r.organization_id = p_organization_id AND r.nonce = p_nonce;
  IF FOUND THEN
    IF v_request.operation <> 'create' OR v_request.payload IS DISTINCT FROM v_payload THEN
      RAISE EXCEPTION 'Chave de orçamento reutilizada com payload diferente' USING ERRCODE = '23505';
    END IF;
    v_result := v_request.result;
    RETURN QUERY SELECT r.quote_id,r.public_token,r.status,r.status_version::text,r.valid_until,r.subtotal,r.discount_amount,r.shipping_amount,r.total_amount
      FROM pg_catalog.jsonb_to_record(v_result) r(quote_id uuid,public_token uuid,status text,status_version text,valid_until date,subtotal text,discount_amount text,shipping_amount text,total_amount text);
    RETURN;
  END IF;
  IF p_parent_quote_id IS NOT NULL THEN
    SELECT q.* INTO v_parent FROM public.vm_quotes q
      WHERE q.organization_id = p_organization_id AND q.id = p_parent_quote_id FOR UPDATE;
    IF NOT FOUND OR v_parent.status <> 'Sent' THEN
      RAISE EXCEPTION 'Somente orçamento enviado pode ser revisado' USING ERRCODE = '55000';
    END IF;
  END IF;
  SELECT c.* INTO v_client FROM public.vm_clients c
    WHERE c.organization_id = p_organization_id AND c.id = (v_canonical->'data'->>'client_id')::uuid AND c.archived_at IS NULL FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Cliente deve estar ativo ao emitir o orçamento' USING ERRCODE = '23503'; END IF;
  IF v_canonical->'data'->>'responsible_membership_id' IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.vm_memberships m WHERE m.organization_id = p_organization_id AND m.id = (v_canonical->'data'->>'responsible_membership_id')::uuid
      AND m.role IN ('owner','admin','production')
  ) THEN RAISE EXCEPTION 'Responsável não pertence à organização' USING ERRCODE = '23503'; END IF;
  FOR v_item IN SELECT value FROM pg_catalog.jsonb_array_elements(v_canonical->'items') LOOP
    v_resolved := vm_private.vm_order_resolve_item(p_organization_id,v_item);
    v_items := v_items || pg_catalog.jsonb_build_array(v_resolved);
    v_subtotal := v_subtotal + (v_resolved->>'line_amount')::numeric;
  END LOOP;
  FOR v_aggregate IN
    SELECT r.material_id,count(DISTINCT r.unit) AS unit_count,sum(r.consumption_quantity) AS quantity
    FROM pg_catalog.jsonb_array_elements(v_items) i(value)
    CROSS JOIN LATERAL pg_catalog.jsonb_to_recordset(i.value->'materials') r(material_id uuid,unit text,consumption_quantity numeric)
    GROUP BY r.material_id
  LOOP
    PERFORM vm_private.vm_order_number(v_aggregate.quantity,8,999999999999.99999999,true);
    IF v_aggregate.unit_count <> 1 THEN RAISE EXCEPTION 'Snapshot contém unidades divergentes' USING ERRCODE = '23514'; END IF;
  END LOOP;
  PERFORM vm_private.vm_order_number(v_subtotal,2,999999999999999999.99);
  v_discount := CASE v_canonical->'data'->>'discount_type'
    WHEN 'fixed' THEN (v_canonical->'data'->>'discount_value')::numeric
    WHEN 'percent' THEN pg_catalog.round(v_subtotal*(v_canonical->'data'->>'discount_value')::numeric*0.01,2)
    ELSE 0 END;
  IF v_discount > v_subtotal THEN RAISE EXCEPTION 'Desconto excede subtotal' USING ERRCODE = '22023'; END IF;
  v_total := v_subtotal-v_discount+(v_canonical->'data'->>'shipping_amount')::numeric;
  PERFORM vm_private.vm_order_number(v_discount,2,999999999999999999.99);
  PERFORM vm_private.vm_order_number(v_total,2,999999999999999999.99);
  v_now := pg_catalog.clock_timestamp();
  INSERT INTO public.vm_quotes(
    organization_id,parent_quote_id,client_id,client_name_snapshot,title,order_date,production_date,delivery_date,
    responsible_membership_id,public_notes,internal_notes,commercial_terms,subtotal,discount_type,discount_value,
    discount_amount,shipping_amount,total_amount,valid_until,created_by,created_at,updated_at
  ) VALUES (
    p_organization_id,p_parent_quote_id,v_client.id,v_client.name,v_canonical->'data'->>'title',(v_canonical->'data'->>'order_date')::date,
    (v_canonical->'data'->>'production_date')::date,(v_canonical->'data'->>'delivery_date')::date,
    (v_canonical->'data'->>'responsible_membership_id')::uuid,v_canonical->'data'->>'public_notes',v_canonical->'data'->>'internal_notes',
    v_terms,v_subtotal,v_canonical->'data'->>'discount_type',(v_canonical->'data'->>'discount_value')::numeric,v_discount,
    (v_canonical->'data'->>'shipping_amount')::numeric,v_total,p_valid_until,v_actor,v_now,v_now
  ) RETURNING * INTO v_quote;
  INSERT INTO vm_private.vm_quote_client_snapshots(organization_id,quote_id,client_id,snapshot)
    VALUES(p_organization_id,v_quote.id,v_client.id,pg_catalog.jsonb_build_object(
      'client_id',v_client.id,'name',v_client.name,'person_type',v_client.person_type,'tax_id',v_client.tax_id,
      'birth_date',v_client.birth_date,'email',v_client.email,'phone',v_client.phone,'address',v_client.address,'captured_at',v_now));
  FOR v_item IN SELECT value FROM pg_catalog.jsonb_array_elements(v_items) LOOP
    v_position := v_position + 1;
    INSERT INTO public.vm_quote_items(
      organization_id,quote_id,position,kind,product_id,product_version,variant_id,variant_version,title,quantity,billing_unit,
      dimensions,dimensions_factor,billed_quantity,unit_price,price_source,price_override_reason,line_amount_raw,line_amount,
      recipe_mode,unit_composition_cost,total_composition_cost,product_snapshot,price_snapshot,details,personalization,production_date,delivery_date
    ) VALUES (
      p_organization_id,v_quote.id,v_position,v_item->>'kind',(v_item->>'product_id')::uuid,(v_item->>'product_version')::integer,
      (v_item->>'variant_id')::uuid,(v_item->>'variant_version')::integer,v_item->>'title',(v_item->>'quantity')::numeric,v_item->>'billing_unit',
      NULLIF(v_item->'dimensions','null'::jsonb),(v_item->>'dimensions_factor')::numeric,(v_item->>'billed_quantity')::numeric,
      (v_item->>'unit_price')::numeric,v_item->>'price_source',v_item->>'price_override_reason',(v_item->>'line_amount_raw')::numeric,
      (v_item->>'line_amount')::numeric,v_item->>'recipe_mode',(v_item->>'unit_composition_cost')::numeric,(v_item->>'total_composition_cost')::numeric,
      v_item->'product_snapshot',v_item->'price_snapshot',v_item->>'details',NULLIF(v_item->'personalization','null'::jsonb),
      (v_item->>'production_date')::date,(v_item->>'delivery_date')::date
    ) RETURNING id INTO v_event_id;
    INSERT INTO public.vm_quote_item_materials(
      organization_id,quote_id,item_id,material_id,material_name_snapshot,unit,quantity_snapshot,unit_cost_snapshot,consumption_quantity,consumption_cost
    )
    SELECT p_organization_id,v_quote.id,v_event_id,r.material_id,r.material_name_snapshot,r.unit,r.quantity_snapshot,r.unit_cost_snapshot,r.consumption_quantity,r.consumption_cost
    FROM pg_catalog.jsonb_to_recordset(v_item->'materials') r(material_id uuid,material_name_snapshot text,unit text,quantity_snapshot numeric,unit_cost_snapshot numeric,consumption_quantity numeric,consumption_cost numeric);
  END LOOP;
  INSERT INTO public.vm_quote_events(organization_id,quote_id,status_version,event_type,previous_status,status,payload,created_by)
    VALUES(p_organization_id,v_quote.id,1,'created',NULL,'Sent',vm_private.vm_quote_event_payload(v_quote,'Sent'),v_actor) RETURNING id INTO v_event_id;
  IF p_parent_quote_id IS NOT NULL THEN
    INSERT INTO public.vm_quote_events(organization_id,quote_id,status_version,event_type,previous_status,status,payload,created_by)
      VALUES(p_organization_id,v_parent.id,v_parent.status_version+1,'revoked',v_parent.status,'Revoked',vm_private.vm_quote_event_payload(v_parent,'Revoked'),v_actor);
    PERFORM pg_catalog.set_config('vm.quote_mutation','1',true);
    UPDATE public.vm_quotes AS q SET status='Revoked',status_version=q.status_version+1,revoked_at=v_now WHERE q.organization_id=p_organization_id AND q.id=v_parent.id;
  END IF;
  v_result := pg_catalog.jsonb_build_object('quote_id',v_quote.id,'public_token',v_quote.public_token,'status','Sent','status_version','1',
    'valid_until',v_quote.valid_until,'subtotal',v_quote.subtotal::numeric(20,2)::text,'discount_amount',v_quote.discount_amount::numeric(20,2)::text,
    'shipping_amount',v_quote.shipping_amount::numeric(20,2)::text,'total_amount',v_quote.total_amount::numeric(20,2)::text);
  INSERT INTO vm_private.vm_quote_requests(organization_id,nonce,operation,quote_id,payload,result,created_by)
    VALUES(p_organization_id,p_nonce,'create',v_quote.id,v_payload,v_result,v_actor);
  RETURN QUERY SELECT v_quote.id,v_quote.public_token,'Sent'::text,'1'::text,v_quote.valid_until,v_quote.subtotal::numeric(20,2)::text,
    v_quote.discount_amount::numeric(20,2)::text,v_quote.shipping_amount::numeric(20,2)::text,v_quote.total_amount::numeric(20,2)::text;
END;
$function$;

CREATE FUNCTION public.vm_revise_quote(
  p_organization_id uuid,p_quote_id uuid,p_data jsonb,p_items jsonb,p_valid_until date,p_terms text DEFAULT NULL,p_nonce uuid DEFAULT NULL
)
RETURNS TABLE(quote_id uuid,public_token uuid,status text,status_version text,valid_until date,subtotal text,discount_amount text,shipping_amount text,total_amount text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
BEGIN
  RETURN QUERY SELECT * FROM public.vm_create_quote(p_organization_id,p_data,p_items,p_valid_until,p_terms,p_nonce,p_quote_id);
END;
$function$;

CREATE FUNCTION public.vm_revoke_quote(p_organization_id uuid,p_quote_id uuid,p_reason text,p_nonce uuid DEFAULT NULL)
RETURNS TABLE(quote_id uuid,status text,status_version text,revoked_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE v_actor uuid := auth.uid(); v_quote public.vm_quotes%ROWTYPE; v_request vm_private.vm_quote_requests%ROWTYPE;
  v_reason text := NULLIF(pg_catalog.btrim(p_reason),''); v_payload jsonb; v_result jsonb; v_time timestamptz;
BEGIN
  IF v_actor IS NULL OR auth.role() IS DISTINCT FROM 'authenticated' OR NOT vm_private.vm_has_role(p_organization_id,ARRAY['owner','admin','finance']::text[]) THEN
    RAISE EXCEPTION 'Sem permissão para revogar orçamento nesta organização' USING ERRCODE = '42501';
  END IF;
  IF p_quote_id IS NULL OR v_reason IS NULL OR pg_catalog.char_length(v_reason) > 2000 THEN
    RAISE EXCEPTION 'Motivo e orçamento são obrigatórios' USING ERRCODE = '22023';
  END IF;
  IF p_nonce IS NULL THEN p_nonce := pg_catalog.gen_random_uuid(); END IF;
  v_payload := pg_catalog.jsonb_build_object('quote_id',p_quote_id,'reason',v_reason);
  PERFORM 1 FROM public.vm_organizations o WHERE o.id = p_organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Organização não encontrada' USING ERRCODE = '23503'; END IF;
  SELECT r.* INTO v_request FROM vm_private.vm_quote_requests r WHERE r.organization_id=p_organization_id AND r.nonce=p_nonce;
  IF FOUND THEN
    IF v_request.operation <> 'revoke' OR v_request.payload IS DISTINCT FROM v_payload THEN RAISE EXCEPTION 'Chave de revogação reutilizada' USING ERRCODE = '23505'; END IF;
    v_result := v_request.result;
    RETURN QUERY SELECT r.quote_id,r.status,r.status_version,r.revoked_at FROM pg_catalog.jsonb_to_record(v_result) r(quote_id uuid,status text,status_version text,revoked_at timestamptz);
    RETURN;
  END IF;
  SELECT q.* INTO v_quote FROM public.vm_quotes q WHERE q.organization_id=p_organization_id AND q.id=p_quote_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Orçamento não encontrado nesta organização' USING ERRCODE = '23503'; END IF;
  IF v_quote.status = 'Approved' THEN RAISE EXCEPTION 'Orçamento aprovado não pode ser removido nem revogado' USING ERRCODE = '55000'; END IF;
  IF v_quote.status = 'Revoked' THEN
    v_result := pg_catalog.jsonb_build_object('quote_id',v_quote.id,'status','Revoked','status_version',v_quote.status_version::text,'revoked_at',v_quote.revoked_at);
  ELSE
    v_time := pg_catalog.clock_timestamp();
    INSERT INTO public.vm_quote_events(organization_id,quote_id,status_version,event_type,previous_status,status,payload,created_by)
      VALUES(p_organization_id,v_quote.id,v_quote.status_version+1,'revoked',v_quote.status,'Revoked',vm_private.vm_quote_event_payload(v_quote,'Revoked'),v_actor);
    PERFORM pg_catalog.set_config('vm.quote_mutation','1',true);
    UPDATE public.vm_quotes AS q SET status='Revoked',status_version=q.status_version+1,revoked_at=v_time WHERE q.organization_id=p_organization_id AND q.id=p_quote_id;
    v_result := pg_catalog.jsonb_build_object('quote_id',v_quote.id,'status','Revoked','status_version',(v_quote.status_version+1)::text,'revoked_at',v_time);
  END IF;
  INSERT INTO vm_private.vm_quote_requests(organization_id,nonce,operation,quote_id,payload,result,created_by)
    VALUES(p_organization_id,p_nonce,'revoke',p_quote_id,v_payload,v_result,v_actor);
  RETURN QUERY SELECT r.quote_id,r.status,r.status_version,r.revoked_at FROM pg_catalog.jsonb_to_record(v_result) r(quote_id uuid,status text,status_version text,revoked_at timestamptz);
END;
$function$;

CREATE FUNCTION public.vm_approve_quote(p_token uuid)
RETURNS TABLE(order_id uuid,tracking_token uuid,tracking_expires_at timestamptz,status text,accepted_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE v_quote public.vm_quotes%ROWTYPE; v_accept vm_private.vm_quote_acceptances%ROWTYPE; v_order_result jsonb; v_cap public.vm_tracking_capabilities%ROWTYPE;
  v_result jsonb; v_time timestamptz; v_event_id uuid; v_order uuid; v_expiry timestamptz;
BEGIN
  IF p_token IS NULL THEN RAISE EXCEPTION 'Orçamento inválido ou indisponível' USING ERRCODE = '22023'; END IF;
  SELECT q.* INTO v_quote FROM public.vm_quotes q WHERE q.public_token=p_token FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Orçamento inválido ou indisponível' USING ERRCODE = '22023'; END IF;
  SELECT a.* INTO v_accept FROM vm_private.vm_quote_acceptances a WHERE a.organization_id=v_quote.organization_id AND a.quote_id=v_quote.id;
  IF FOUND THEN
    RETURN QUERY SELECT (v_accept.result->>'order_id')::uuid,(v_accept.result->>'tracking_token')::uuid,(v_accept.result->>'tracking_expires_at')::timestamptz,
      v_accept.result->>'status',v_accept.accepted_at;
    RETURN;
  END IF;
  IF v_quote.status <> 'Sent' OR v_quote.revoked_at IS NOT NULL OR v_quote.valid_until < CURRENT_DATE THEN
    RAISE EXCEPTION 'Orçamento inválido ou indisponível' USING ERRCODE = '22023';
  END IF;
  v_time := pg_catalog.clock_timestamp();
  v_order_result := vm_private.vm_quote_build_order(v_quote.organization_id,v_quote.id);
  v_order := (v_order_result->>'order_id')::uuid;
  v_expiry := v_time + interval '30 days';
  v_cap := vm_private.vm_quote_issue_tracking(v_quote.organization_id,v_order,v_quote.id,v_quote.valid_until,NULL,v_expiry);
  INSERT INTO public.vm_quote_events(organization_id,quote_id,status_version,event_type,previous_status,status,payload,created_by)
    VALUES(v_quote.organization_id,v_quote.id,v_quote.status_version+1,'approved',v_quote.status,'Approved',vm_private.vm_quote_event_payload(v_quote,'Approved'),NULL)
    RETURNING id INTO v_event_id;
  PERFORM pg_catalog.set_config('vm.quote_mutation','1',true);
  UPDATE public.vm_quotes AS q SET status='Approved',status_version=q.status_version+1,accepted_at=v_time,accepted_order_id=v_order
    WHERE q.organization_id=v_quote.organization_id AND q.id=v_quote.id;
  v_result := pg_catalog.jsonb_build_object('order_id',v_order,'tracking_token',v_cap.token,'tracking_expires_at',v_cap.expires_at,'status','Approved');
  INSERT INTO vm_private.vm_quote_acceptances(organization_id,quote_id,order_id,tracking_id,accepted_at,result)
    VALUES(v_quote.organization_id,v_quote.id,v_order,v_cap.id,v_time,v_result);
  RETURN QUERY SELECT v_order,v_cap.token,v_cap.expires_at,'Approved'::text,v_time;
END;
$function$;

CREATE FUNCTION public.vm_get_quote(p_token uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE v_result jsonb;
BEGIN
  IF p_token IS NULL THEN RETURN NULL; END IF;
  SELECT pg_catalog.jsonb_build_object(
    'brand',o.name,'quote_token',q.public_token,'title',q.title,'items',COALESCE((
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'kind',i.kind,'title',i.title,'quantity',i.quantity::text,'billing_unit',i.billing_unit,'dimensions',i.dimensions,
        'unit_price',i.unit_price::text,'line_amount',i.line_amount::text,
        'product',CASE WHEN i.kind='product' THEN pg_catalog.jsonb_build_object(
          'name',i.product_snapshot->>'name','category',i.product_snapshot->>'category','sku',i.product_snapshot->>'sku',
          'variant_name',i.product_snapshot->>'variant_name','variant_sku',i.product_snapshot->>'variant_sku') ELSE NULL END
      ) ORDER BY i.position)
      FROM public.vm_quote_items i WHERE i.organization_id=q.organization_id AND i.quote_id=q.id),'[]'::jsonb),
    'subtotal',q.subtotal::text,'discount_type',q.discount_type,'discount_value',q.discount_value::text,
    'discount_amount',q.discount_amount::text,'shipping_amount',q.shipping_amount::text,'total_amount',q.total_amount::text,
    'currency',q.currency,'order_date',q.order_date,'production_date',q.production_date,'delivery_date',q.delivery_date,
    'valid_until',q.valid_until,'terms',q.commercial_terms,'public_notes',q.public_notes,
    'status',CASE WHEN q.status='Sent' AND q.valid_until < CURRENT_DATE THEN 'Expired' ELSE q.status END,
    'accepted_at',q.accepted_at
  ) INTO v_result
  FROM public.vm_quotes q JOIN public.vm_organizations o ON o.id=q.organization_id
  WHERE q.public_token=p_token;
  RETURN v_result;
END;
$function$;

CREATE FUNCTION public.vm_get_tracking(p_token uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE v_result jsonb;
BEGIN
  IF p_token IS NULL THEN RETURN NULL; END IF;
  SELECT pg_catalog.jsonb_build_object(
    'brand',org.name,'tracking_token',t.token,'code',o.code,'title',o.title,'status',o.status,
    'status_version',o.status_version::text,'order_date',o.order_date,'production_date',o.production_date,
    'delivery_date',o.delivery_date,'public_notes',o.public_notes,'commercial_terms',o.commercial_terms,
    'items',COALESCE((SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'kind',i.kind,'title',i.title,'quantity',i.quantity::text,'billing_unit',i.billing_unit,'dimensions',i.dimensions,
      'unit_price',i.unit_price::text,'line_amount',i.line_amount::text,
      'product',CASE WHEN i.kind='product' THEN pg_catalog.jsonb_build_object(
        'name',i.product_snapshot->>'name','category',i.product_snapshot->>'category','sku',i.product_snapshot->>'sku',
        'variant_name',i.product_snapshot->>'variant_name','variant_sku',i.product_snapshot->>'variant_sku') ELSE NULL END
    ) ORDER BY i.position) FROM public.vm_order_items i WHERE i.organization_id=o.organization_id AND i.order_id=o.id),'[]'::jsonb),
    'subtotal',o.subtotal::text,'discount_type',o.discount_type,'discount_value',o.discount_value::text,
    'discount_amount',o.discount_amount::text,'shipping_amount',o.shipping_amount::text,'total_amount',o.total_amount::text,
    'currency',o.currency,'expires_at',t.expires_at,'history',COALESCE((SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'status',e.status,'status_version',e.status_version::text,'created_at',e.created_at) ORDER BY e.status_version)
      FROM public.vm_order_events e WHERE e.organization_id=o.organization_id AND e.order_id=o.id),'[]'::jsonb)
  ) INTO v_result
  FROM public.vm_tracking_capabilities t
  JOIN public.vm_orders o ON o.organization_id=t.organization_id AND o.id=t.order_id
  JOIN public.vm_organizations org ON org.id=t.organization_id
  WHERE t.token=p_token AND t.revoked_at IS NULL AND t.expires_at > pg_catalog.clock_timestamp();
  RETURN v_result;
END;
$function$;

CREATE FUNCTION public.vm_issue_tracking(p_organization_id uuid,p_order_id uuid,p_expires_at timestamptz,p_nonce uuid DEFAULT NULL)
RETURNS TABLE(tracking_id uuid,tracking_token uuid,expires_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE v_actor uuid:=auth.uid(); v_request vm_private.vm_tracking_requests%ROWTYPE; v_order public.vm_orders%ROWTYPE; v_current public.vm_tracking_capabilities%ROWTYPE;
  v_payload jsonb; v_result jsonb; v_cap public.vm_tracking_capabilities%ROWTYPE;
BEGIN
  IF v_actor IS NULL OR auth.role() IS DISTINCT FROM 'authenticated' OR NOT vm_private.vm_has_role(p_organization_id,ARRAY['owner','admin','finance']::text[]) THEN
    RAISE EXCEPTION 'Sem permissão para emitir rastreio nesta organização' USING ERRCODE = '42501';
  END IF;
  IF p_nonce IS NULL THEN p_nonce := pg_catalog.gen_random_uuid(); END IF;
  IF p_expires_at IS NULL OR p_expires_at <= pg_catalog.clock_timestamp() OR p_expires_at > pg_catalog.clock_timestamp()+interval '365 days' THEN
    RAISE EXCEPTION 'Expiração de rastreio deve estar entre agora e 365 dias' USING ERRCODE = '22023';
  END IF;
  v_payload:=pg_catalog.jsonb_build_object('order_id',p_order_id,'expires_at',p_expires_at);
  PERFORM 1 FROM public.vm_organizations o WHERE o.id=p_organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Organização não encontrada' USING ERRCODE = '23503'; END IF;
  SELECT r.* INTO v_request FROM vm_private.vm_tracking_requests r WHERE r.organization_id=p_organization_id AND r.nonce=p_nonce;
  IF FOUND THEN
    IF v_request.operation <> 'issue_tracking' OR v_request.payload IS DISTINCT FROM v_payload THEN RAISE EXCEPTION 'Chave de rastreio reutilizada' USING ERRCODE = '23505'; END IF;
    v_result:=v_request.result;
    RETURN QUERY SELECT (v_result->>'tracking_id')::uuid,(v_result->>'tracking_token')::uuid,(v_result->>'expires_at')::timestamptz;
    RETURN;
  END IF;
  SELECT o.* INTO v_order FROM public.vm_orders o WHERE o.organization_id=p_organization_id AND o.id=p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pedido não encontrado nesta organização' USING ERRCODE = '23503'; END IF;
  SELECT t.* INTO v_current FROM public.vm_tracking_capabilities t WHERE t.organization_id=p_organization_id AND t.order_id=p_order_id AND t.revoked_at IS NULL FOR UPDATE;
  IF FOUND THEN
    PERFORM pg_catalog.set_config('vm.tracking_mutation','1',true);
    UPDATE public.vm_tracking_capabilities SET revoked_at=pg_catalog.clock_timestamp() WHERE organization_id=p_organization_id AND id=v_current.id;
  END IF;
  INSERT INTO public.vm_tracking_capabilities(organization_id,order_id,expires_at,issued_by)
    VALUES(p_organization_id,p_order_id,p_expires_at,v_actor) RETURNING * INTO v_cap;
  v_result:=pg_catalog.jsonb_build_object('tracking_id',v_cap.id,'tracking_token',v_cap.token,'expires_at',v_cap.expires_at);
  INSERT INTO vm_private.vm_tracking_requests(organization_id,nonce,operation,tracking_id,payload,result,created_by)
    VALUES(p_organization_id,p_nonce,'issue_tracking',v_cap.id,v_payload,v_result,v_actor);
  RETURN QUERY SELECT v_cap.id,v_cap.token,v_cap.expires_at;
END;
$function$;

CREATE FUNCTION public.vm_revoke_tracking(p_organization_id uuid,p_tracking_token uuid,p_nonce uuid DEFAULT NULL)
RETURNS TABLE(tracking_id uuid,revoked_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE v_actor uuid:=auth.uid(); v_request vm_private.vm_tracking_requests%ROWTYPE; v_cap public.vm_tracking_capabilities%ROWTYPE; v_payload jsonb; v_result jsonb; v_time timestamptz;
BEGIN
  IF v_actor IS NULL OR auth.role() IS DISTINCT FROM 'authenticated' OR NOT vm_private.vm_has_role(p_organization_id,ARRAY['owner','admin','finance']::text[]) THEN
    RAISE EXCEPTION 'Sem permissão para revogar rastreio nesta organização' USING ERRCODE = '42501';
  END IF;
  IF p_tracking_token IS NULL THEN RAISE EXCEPTION 'Capability inválida' USING ERRCODE = '22023'; END IF;
  IF p_nonce IS NULL THEN p_nonce := pg_catalog.gen_random_uuid(); END IF;
  v_payload:=pg_catalog.jsonb_build_object('tracking_token',p_tracking_token);
  PERFORM 1 FROM public.vm_organizations o WHERE o.id=p_organization_id FOR UPDATE;
  SELECT r.* INTO v_request FROM vm_private.vm_tracking_requests r WHERE r.organization_id=p_organization_id AND r.nonce=p_nonce;
  IF FOUND THEN
    IF v_request.operation <> 'revoke_tracking' OR v_request.payload IS DISTINCT FROM v_payload THEN RAISE EXCEPTION 'Chave de rastreio reutilizada' USING ERRCODE = '23505'; END IF;
    v_result:=v_request.result;
    RETURN QUERY SELECT (v_result->>'tracking_id')::uuid,(v_result->>'revoked_at')::timestamptz;
    RETURN;
  END IF;
  SELECT t.* INTO v_cap FROM public.vm_tracking_capabilities t WHERE t.organization_id=p_organization_id AND t.token=p_tracking_token FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Capability não encontrada nesta organização' USING ERRCODE = '22023'; END IF;
  IF v_cap.revoked_at IS NULL THEN
    v_time:=pg_catalog.clock_timestamp();
    PERFORM pg_catalog.set_config('vm.tracking_mutation','1',true);
    UPDATE public.vm_tracking_capabilities SET revoked_at=v_time WHERE organization_id=p_organization_id AND id=v_cap.id;
  ELSE v_time:=v_cap.revoked_at; END IF;
  v_result:=pg_catalog.jsonb_build_object('tracking_id',v_cap.id,'revoked_at',v_time);
  INSERT INTO vm_private.vm_tracking_requests(organization_id,nonce,operation,tracking_id,payload,result,created_by)
    VALUES(p_organization_id,p_nonce,'revoke_tracking',v_cap.id,v_payload,v_result,v_actor);
  RETURN QUERY SELECT v_cap.id,v_time;
END;
$function$;

CREATE FUNCTION public.vm_get_order_tracking(p_organization_id uuid,p_order_id uuid)
RETURNS TABLE(tracking_token uuid,expires_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE v_actor uuid:=auth.uid();
BEGIN
  IF v_actor IS NULL OR auth.role() IS DISTINCT FROM 'authenticated' OR NOT vm_private.vm_is_member(p_organization_id) THEN
    RAISE EXCEPTION 'Sessão/membership exigida' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY SELECT t.token,t.expires_at FROM public.vm_tracking_capabilities t
    WHERE t.organization_id=p_organization_id AND t.order_id=p_order_id AND t.revoked_at IS NULL AND t.expires_at>pg_catalog.clock_timestamp();
END;
$function$;

-- Status changes signal only currently valid, non-revoked capabilities. The native
-- sender is attempted, then the local/production result is recorded as a signal;
-- no claim of WebSocket delivery is made.
CREATE FUNCTION vm_private.vm_tracking_status_signal()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE v_event record; v_cap record; v_topic text; v_payload jsonb; v_state text; v_error text;
BEGIN
  IF TG_OP <> 'UPDATE' OR NEW.status_version IS NOT DISTINCT FROM OLD.status_version THEN RETURN NEW; END IF;
  SELECT e.id,e.status_version,e.status INTO v_event FROM public.vm_order_events e
    WHERE e.organization_id=NEW.organization_id AND e.order_id=NEW.id AND e.status_version=NEW.status_version LIMIT 1;
  IF NOT FOUND THEN RETURN NEW; END IF;
  FOR v_cap IN SELECT t.id,t.token FROM public.vm_tracking_capabilities t
    WHERE t.organization_id=NEW.organization_id AND t.order_id=NEW.id AND t.revoked_at IS NULL AND t.expires_at>pg_catalog.clock_timestamp()
    FOR UPDATE OF t
  LOOP
    v_topic := 'tracking:' || v_cap.token::text;
    v_payload := pg_catalog.jsonb_build_object('id',v_event.id,'status',NEW.status,'status_version',NEW.status_version::text);
    v_state := 'failed'; v_error := NULL;
    BEGIN
      PERFORM realtime.send(v_payload,'status',v_topic,false);
      IF EXISTS (SELECT 1 FROM realtime.messages m WHERE m.topic=v_topic AND m.event='status' AND m.payload->>'id'=v_event.id::text) THEN
        v_state := 'enqueued';
      ELSE
        v_error := 'native realtime.send não deixou mensagem observável';
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_error := pg_catalog.left(SQLERRM,2000);
    END;
    INSERT INTO vm_private.vm_tracking_broadcasts(organization_id,tracking_id,event_id,status_version,status,topic,payload,send_state,last_error)
      VALUES(NEW.organization_id,v_cap.id,v_event.id,NEW.status_version,NEW.status,v_topic,v_payload,v_state,v_error);
  END LOOP;
  RETURN NEW;
END;
$function$;
CREATE TRIGGER vm_orders_tracking_status_signal AFTER UPDATE OF status,status_version ON public.vm_orders
  FOR EACH ROW EXECUTE FUNCTION vm_private.vm_tracking_status_signal();

-- RLS and ACL: public clients see only the two capability functions.
DO $rls$
DECLARE v_table text;
BEGIN
  FOREACH v_table IN ARRAY ARRAY['vm_quotes','vm_quote_items','vm_quote_item_materials','vm_quote_events','vm_tracking_capabilities'] LOOP
    EXECUTE pg_catalog.format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',v_table);
    EXECUTE pg_catalog.format('REVOKE ALL ON TABLE public.%I FROM PUBLIC,anon,authenticated',v_table);
  END LOOP;
  FOREACH v_table IN ARRAY ARRAY['vm_private.vm_quote_client_snapshots','vm_private.vm_quote_requests','vm_private.vm_quote_acceptances','vm_private.vm_tracking_requests','vm_private.vm_tracking_broadcasts'] LOOP
    EXECUTE pg_catalog.format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY',v_table);
    EXECUTE pg_catalog.format('REVOKE ALL ON TABLE %s FROM PUBLIC,anon,authenticated',v_table);
  END LOOP;
END;
$rls$;
REVOKE ALL ON FUNCTION vm_private.vm_quote_canonical(jsonb,jsonb),vm_private.vm_quote_event_payload(public.vm_quotes,text),
  vm_private.vm_quote_issue_tracking(uuid,uuid,uuid,date,uuid,timestamptz),vm_private.vm_quote_build_order(uuid,uuid),
  vm_private.vm_quote_guard(),vm_private.vm_tracking_guard(),vm_private.vm_tracking_status_signal()
  FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.vm_create_quote(uuid,jsonb,jsonb,date,text,uuid,uuid),public.vm_revise_quote(uuid,uuid,jsonb,jsonb,date,text,uuid),
  public.vm_revoke_quote(uuid,uuid,text,uuid),public.vm_approve_quote(uuid),public.vm_get_quote(uuid),public.vm_get_tracking(uuid),
  public.vm_issue_tracking(uuid,uuid,timestamptz,uuid),public.vm_revoke_tracking(uuid,uuid,uuid),public.vm_get_order_tracking(uuid,uuid)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.vm_create_quote(uuid,jsonb,jsonb,date,text,uuid,uuid),public.vm_revise_quote(uuid,uuid,jsonb,jsonb,date,text,uuid),
  public.vm_revoke_quote(uuid,uuid,text,uuid),public.vm_issue_tracking(uuid,uuid,timestamptz,uuid),public.vm_revoke_tracking(uuid,uuid,uuid),
  public.vm_get_order_tracking(uuid,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.vm_approve_quote(uuid),public.vm_get_quote(uuid),public.vm_get_tracking(uuid) TO anon,authenticated;

INSERT INTO public.vm_schema_migrations(version,description)
  VALUES('20261030003000_public_sales','Quotes públicos congelados, aceite idempotente, tracking por capability, projeções allowlist e sinal Realtime')
  ON CONFLICT(version) DO NOTHING;
NOTIFY pgrst, 'reload schema';
COMMIT;
