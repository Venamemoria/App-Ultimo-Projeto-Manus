BEGIN;

-- Incremental orders backend. No seed, reset, external dispatch or public token.
-- Quantities/prices: exact 8 decimals; costs: exact 16; currency boundary: 2.
CREATE FUNCTION vm_private.vm_order_number(p_value numeric, p_scale integer, p_max numeric, p_positive boolean DEFAULT false)
RETURNS numeric LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $function$
BEGIN
  IF NOT vm_private.vm_numeric_valid(p_value,p_scale,p_max,true)
     OR (p_positive AND p_value <= 0) THEN
    RAISE EXCEPTION 'Decimal inválido: valor finito, escala e limite exigidos (% casas)',p_scale USING ERRCODE='22003';
  END IF;
  RETURN p_value;
END;
$function$;

CREATE FUNCTION vm_private.vm_order_keys(p_data jsonb,p_allowed text[])
RETURNS void LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $function$
DECLARE v_key text;
BEGIN
  IF p_data IS NULL OR pg_catalog.jsonb_typeof(p_data) <> 'object' THEN
    RAISE EXCEPTION 'Payload deve ser objeto JSON' USING ERRCODE='22023';
  END IF;
  FOR v_key IN SELECT key FROM pg_catalog.jsonb_each(p_data) LOOP
    IF NOT (v_key = ANY(p_allowed)) THEN
      RAISE EXCEPTION 'Campo de pedido desconhecido: %',v_key USING ERRCODE='22023';
    END IF;
  END LOOP;
END;
$function$;

CREATE FUNCTION vm_private.vm_order_json_number(p_data jsonb,p_key text,p_required boolean DEFAULT true)
RETURNS numeric LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $function$
DECLARE v_type text := pg_catalog.jsonb_typeof(p_data->p_key); v_value numeric;
BEGIN
  IF v_type IS NULL OR v_type='null' THEN
    IF NOT p_required THEN RETURN NULL; END IF;
    RAISE EXCEPTION 'Decimal obrigatório: %',p_key USING ERRCODE='22023';
  END IF;
  IF v_type NOT IN ('string','number') THEN
    RAISE EXCEPTION 'Campo % deve ser decimal textual ou numeric',p_key USING ERRCODE='22023';
  END IF;
  BEGIN v_value := (p_data->>p_key)::numeric;
  EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
    RAISE EXCEPTION 'Decimal inválido: %',p_key USING ERRCODE='22023';
  END;
  RETURN vm_private.vm_order_number(v_value,8,999999999999.99999999,false);
END;
$function$;

CREATE FUNCTION vm_private.vm_order_json_date(p_data jsonb,p_key text,p_required boolean DEFAULT false)
RETURNS date LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $function$
DECLARE v_text text; v_date date;
BEGIN
  v_text := vm_private.vm_contact_optional_text(p_data,p_key,10);
  IF v_text IS NULL THEN
    IF p_required THEN RAISE EXCEPTION 'Data obrigatória: %',p_key USING ERRCODE='22023'; END IF;
    RETURN NULL;
  END IF;
  IF v_text !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
    RAISE EXCEPTION 'Data % deve ser ISO YYYY-MM-DD',p_key USING ERRCODE='22023';
  END IF;
  BEGIN v_date := v_text::date;
  EXCEPTION WHEN invalid_datetime_format OR datetime_field_overflow THEN
    RAISE EXCEPTION 'Data inválida: %',p_key USING ERRCODE='22023';
  END;
  IF NOT vm_private.vm_date_valid(v_date) OR pg_catalog.to_char(v_date,'YYYY-MM-DD')<>v_text THEN
    RAISE EXCEPTION 'Data inválida: %',p_key USING ERRCODE='22023';
  END IF;
  RETURN v_date;
END;
$function$;

CREATE TABLE public.vm_orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
  code text NOT NULL CHECK (btrim(code)<>'' AND char_length(code)<=50),
  client_id uuid NOT NULL,
  client_name_snapshot text NOT NULL CHECK (btrim(client_name_snapshot)<>'' AND char_length(client_name_snapshot)<=200),
  title text NOT NULL CHECK (btrim(title)<>'' AND char_length(title)<=200),
  order_date date NOT NULL CHECK (vm_private.vm_date_valid(order_date)),
  production_date date CHECK (production_date IS NULL OR vm_private.vm_date_valid(production_date)),
  delivery_date date CHECK (delivery_date IS NULL OR vm_private.vm_date_valid(delivery_date)),
  responsible_membership_id uuid,
  public_notes text CHECK (public_notes IS NULL OR char_length(public_notes)<=5000),
  internal_notes text CHECK (internal_notes IS NULL OR char_length(internal_notes)<=10000),
  subtotal numeric(20,2) NOT NULL CHECK (vm_private.vm_numeric_valid(subtotal,2,999999999999999999.99,true)),
  discount_type text NOT NULL CHECK (discount_type IN ('none','fixed','percent')),
  discount_value numeric(20,8) NOT NULL CHECK (vm_private.vm_numeric_valid(discount_value,8,999999999999.99999999,true)),
  discount_amount numeric(20,2) NOT NULL CHECK (vm_private.vm_numeric_valid(discount_amount,2,999999999999999999.99,true)),
  shipping_amount numeric(20,2) NOT NULL CHECK (vm_private.vm_numeric_valid(shipping_amount,2,999999999999999999.99,true)),
  total_amount numeric(20,2) NOT NULL CHECK (vm_private.vm_numeric_valid(total_amount,2,999999999999999999.99,true)),
  currency text NOT NULL DEFAULT 'BRL' CHECK (currency='BRL'),
  status text NOT NULL DEFAULT 'Pendente' CHECK (status IN ('Pendente','Em Produção','Concluído','Entregue','Cancelado')),
  status_version bigint NOT NULL DEFAULT 0 CHECK (status_version>=0),
  consumed_at timestamptz,
  created_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id,id), UNIQUE (organization_id,code),
  FOREIGN KEY (organization_id,client_id) REFERENCES public.vm_clients(organization_id,id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,responsible_membership_id) REFERENCES public.vm_memberships(organization_id,id) ON DELETE RESTRICT,
  CHECK (discount_amount<=subtotal AND total_amount=subtotal-discount_amount+shipping_amount),
  CHECK ((discount_type='none' AND discount_value=0 AND discount_amount=0)
      OR (discount_type='fixed' AND discount_value=discount_amount)
      OR (discount_type='percent' AND discount_value<=100)),
  CHECK (production_date IS NULL OR production_date>=order_date),
  CHECK (delivery_date IS NULL OR delivery_date>=order_date),
  CHECK (production_date IS NULL OR delivery_date IS NULL OR delivery_date>=production_date),
  CHECK (status NOT IN ('Em Produção','Concluído','Entregue') OR consumed_at IS NOT NULL)
);
CREATE INDEX vm_orders_client_idx ON public.vm_orders(organization_id,client_id,status);
CREATE INDEX vm_orders_status_dates_idx ON public.vm_orders(organization_id,status,delivery_date,order_date DESC);
CREATE INDEX vm_orders_created_idx ON public.vm_orders(organization_id,created_at DESC,id);

CREATE TABLE vm_private.vm_order_client_snapshots (
  organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
  order_id uuid NOT NULL, client_id uuid NOT NULL, snapshot jsonb NOT NULL CHECK (jsonb_typeof(snapshot)='object'),
  created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(organization_id,order_id),
  FOREIGN KEY(organization_id,order_id) REFERENCES public.vm_orders(organization_id,id) ON DELETE RESTRICT,
  FOREIGN KEY(organization_id,client_id) REFERENCES public.vm_clients(organization_id,id) ON DELETE RESTRICT
);

CREATE TABLE public.vm_order_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
  order_id uuid NOT NULL, position integer NOT NULL CHECK(position BETWEEN 1 AND 200),
  kind text NOT NULL CHECK(kind IN ('product','manual_service')),
  product_id uuid, product_version integer, variant_id uuid, variant_version integer,
  title text NOT NULL CHECK(btrim(title)<>'' AND char_length(title)<=200),
  quantity numeric(20,8) NOT NULL CHECK(quantity>0 AND vm_private.vm_numeric_valid(quantity,8,999999999999.99999999,true)),
  billing_unit text NOT NULL CHECK(billing_unit IN ('unit','m2')),
  dimensions jsonb CHECK(dimensions IS NULL OR jsonb_typeof(dimensions)='object'),
  dimensions_factor numeric(20,8) NOT NULL CHECK(dimensions_factor>0 AND vm_private.vm_numeric_valid(dimensions_factor,8,999999999999.99999999,true)),
  billed_quantity numeric(20,8) NOT NULL CHECK(billed_quantity>0 AND vm_private.vm_numeric_valid(billed_quantity,8,999999999999.99999999,true)),
  unit_price numeric(20,8) NOT NULL CHECK(vm_private.vm_numeric_valid(unit_price,8,999999999999.99999999,true)),
  price_source text NOT NULL CHECK(price_source IN ('catalog','override','manual')),
  price_override_reason text CHECK(price_override_reason IS NULL OR (btrim(price_override_reason)<>'' AND char_length(price_override_reason)<=2000)),
  line_amount_raw numeric(40,16) NOT NULL CHECK(vm_private.vm_numeric_valid(line_amount_raw,16,999999999999999999999999.9999999999999999,true)),
  line_amount numeric(20,2) NOT NULL CHECK(vm_private.vm_numeric_valid(line_amount,2,999999999999999999.99,true)),
  recipe_mode text NOT NULL CHECK(recipe_mode IN ('base','inherit_base','own','none')),
  unit_composition_cost numeric(40,16) NOT NULL CHECK(vm_private.vm_numeric_valid(unit_composition_cost,16,999999999999999999999999.9999999999999999,true)),
  total_composition_cost numeric(40,16) NOT NULL CHECK(vm_private.vm_numeric_valid(total_composition_cost,16,999999999999999999999999.9999999999999999,true)),
  product_snapshot jsonb NOT NULL CHECK(jsonb_typeof(product_snapshot)='object'),
  price_snapshot jsonb NOT NULL CHECK(jsonb_typeof(price_snapshot)='object'),
  details text CHECK(details IS NULL OR char_length(details)<=5000),
  personalization jsonb CHECK(personalization IS NULL OR (jsonb_typeof(personalization)='object' AND octet_length(personalization::text)<=20000)),
  production_date date CHECK(production_date IS NULL OR vm_private.vm_date_valid(production_date)),
  delivery_date date CHECK(delivery_date IS NULL OR vm_private.vm_date_valid(delivery_date)),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(organization_id,id), UNIQUE(organization_id,order_id,id), UNIQUE(organization_id,order_id,position),
  FOREIGN KEY(organization_id,order_id) REFERENCES public.vm_orders(organization_id,id) ON DELETE RESTRICT,
  FOREIGN KEY(organization_id,product_id,product_version) REFERENCES public.vm_product_versions(organization_id,product_id,product_version) ON DELETE RESTRICT,
  FOREIGN KEY(organization_id,variant_id) REFERENCES public.vm_product_variants(organization_id,id) ON DELETE RESTRICT,
  CHECK((kind='product' AND product_id IS NOT NULL AND product_version IS NOT NULL AND recipe_mode<>'none')
     OR (kind='manual_service' AND product_id IS NULL AND product_version IS NULL AND variant_id IS NULL AND variant_version IS NULL AND recipe_mode='none' AND billing_unit='unit')),
  CHECK((variant_id IS NULL AND variant_version IS NULL) OR (variant_id IS NOT NULL AND variant_version>0)),
  CHECK(billed_quantity=quantity*dimensions_factor),
  CHECK(line_amount_raw=billed_quantity*unit_price AND line_amount=round(line_amount_raw,2)),
  CHECK((price_source='catalog' AND price_override_reason IS NULL) OR (price_source IN ('override','manual') AND price_override_reason IS NOT NULL))
);
CREATE INDEX vm_order_items_product_idx ON public.vm_order_items(organization_id,product_id,order_id);

-- Normalized recipe snapshot. quantity_snapshot is the recipe fraction per
-- billing unit. consumption_quantity is EXACT fraction * billed_quantity.
CREATE TABLE public.vm_order_item_materials (
  organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
  order_id uuid NOT NULL, item_id uuid NOT NULL, material_id uuid NOT NULL,
  material_name_snapshot text NOT NULL, unit text NOT NULL CHECK(btrim(unit)<>'' AND char_length(unit)<=40),
  quantity_snapshot numeric(20,8) NOT NULL CHECK(quantity_snapshot>0 AND vm_private.vm_numeric_valid(quantity_snapshot,8,999999999999.99999999,true)),
  unit_cost_snapshot numeric(20,8) NOT NULL CHECK(vm_private.vm_numeric_valid(unit_cost_snapshot,8,999999999999.99999999,true)),
  consumption_quantity numeric(20,8) NOT NULL CHECK(consumption_quantity>0 AND vm_private.vm_numeric_valid(consumption_quantity,8,999999999999.99999999,true)),
  consumption_cost numeric(40,16) NOT NULL CHECK(vm_private.vm_numeric_valid(consumption_cost,16,999999999999999999999999.9999999999999999,true)),
  PRIMARY KEY(organization_id,item_id,material_id),
  FOREIGN KEY(organization_id,order_id,item_id) REFERENCES public.vm_order_items(organization_id,order_id,id) ON DELETE RESTRICT,
  FOREIGN KEY(organization_id,material_id) REFERENCES public.vm_materials(organization_id,id) ON DELETE RESTRICT,
  CHECK(consumption_cost=consumption_quantity*unit_cost_snapshot)
);
CREATE INDEX vm_order_item_materials_order_idx ON public.vm_order_item_materials(organization_id,order_id,material_id);

CREATE TABLE public.vm_order_consumption_runs (
  organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
  order_id uuid NOT NULL, consumed_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  PRIMARY KEY(organization_id,order_id),
  FOREIGN KEY(organization_id,order_id) REFERENCES public.vm_orders(organization_id,id) ON DELETE RESTRICT
);

-- Extend both existing checks BEFORE any order deduction function is created.
ALTER TABLE public.vm_stock_movements
  DROP CONSTRAINT vm_stock_movements_movement_type_check,
  DROP CONSTRAINT vm_stock_movements_delta_type_ck,
  ADD COLUMN order_id uuid,
  ADD CONSTRAINT vm_stock_movements_movement_type_check CHECK(movement_type IN ('opening','receipt','adjustment','order_deduction')),
  ADD CONSTRAINT vm_stock_movements_delta_type_ck CHECK(
    (movement_type IN ('opening','receipt') AND quantity_delta>0)
    OR (movement_type='adjustment' AND quantity_delta<>0)
    OR (movement_type='order_deduction' AND quantity_delta<0)),
  ADD CONSTRAINT vm_stock_movements_order_fk FOREIGN KEY(organization_id,order_id) REFERENCES public.vm_orders(organization_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT vm_stock_movements_order_type_ck CHECK(
    (order_id IS NULL AND movement_type<>'order_deduction')
    OR (order_id IS NOT NULL AND movement_type='order_deduction' AND purchase_id IS NULL)),
  ADD CONSTRAINT vm_stock_movements_order_material_identity_uq UNIQUE(organization_id,order_id,material_id,id);
CREATE UNIQUE INDEX vm_stock_movements_order_deduction_uq ON public.vm_stock_movements(organization_id,order_id,material_id) WHERE movement_type='order_deduction';

CREATE TABLE public.vm_order_consumptions (
  organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
  order_id uuid NOT NULL, material_id uuid NOT NULL, unit text NOT NULL,
  quantity numeric(20,8) NOT NULL CHECK(quantity>0 AND vm_private.vm_numeric_valid(quantity,8,999999999999.99999999,true)),
  movement_id uuid NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(organization_id,order_id,material_id), UNIQUE(organization_id,movement_id),
  FOREIGN KEY(organization_id,order_id) REFERENCES public.vm_order_consumption_runs(organization_id,order_id) ON DELETE RESTRICT,
  FOREIGN KEY(organization_id,material_id) REFERENCES public.vm_materials(organization_id,id) ON DELETE RESTRICT,
  FOREIGN KEY(organization_id,order_id,material_id,movement_id) REFERENCES public.vm_stock_movements(organization_id,order_id,material_id,id) ON DELETE RESTRICT
);

CREATE TABLE public.vm_order_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
  order_id uuid NOT NULL, status_version bigint NOT NULL CHECK(status_version>0),
  event_type text NOT NULL CHECK(event_type IN ('created','status_changed')),
  previous_status text CHECK(previous_status IS NULL OR previous_status IN ('Pendente','Em Produção','Concluído','Entregue','Cancelado')),
  status text NOT NULL CHECK(status IN ('Pendente','Em Produção','Concluído','Entregue','Cancelado')),
  reason text CHECK(reason IS NULL OR (btrim(reason)<>'' AND char_length(reason)<=2000)),
  payload jsonb NOT NULL CHECK(jsonb_typeof(payload)='object'),
  created_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT, created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(organization_id,id), UNIQUE(organization_id,order_id,status_version),
  FOREIGN KEY(organization_id,order_id) REFERENCES public.vm_orders(organization_id,id) ON DELETE RESTRICT
);
CREATE INDEX vm_order_events_order_idx ON public.vm_order_events(organization_id,order_id,status_version);

CREATE TABLE public.vm_notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
  event_id uuid NOT NULL, recipient_user_id uuid NOT NULL,
  title text NOT NULL CHECK(char_length(title)<=200), payload jsonb NOT NULL CHECK(jsonb_typeof(payload)='object'),
  read_at timestamptz, created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(organization_id,id), UNIQUE(organization_id,event_id,recipient_user_id),
  FOREIGN KEY(organization_id,event_id) REFERENCES public.vm_order_events(organization_id,id) ON DELETE RESTRICT,
  FOREIGN KEY(organization_id,recipient_user_id) REFERENCES public.vm_memberships(organization_id,user_id) ON DELETE RESTRICT
);
CREATE INDEX vm_notifications_recipient_idx ON public.vm_notifications(organization_id,recipient_user_id,created_at DESC);

CREATE TABLE public.vm_notification_outbox (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
  event_id uuid NOT NULL, channel text NOT NULL DEFAULT 'order_status' CHECK(channel='order_status'),
  payload jsonb NOT NULL CHECK(jsonb_typeof(payload)='object'),
  state text NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','processing','delivered','failed')),
  attempts integer NOT NULL DEFAULT 0 CHECK(attempts>=0),
  next_attempt_at timestamptz NOT NULL DEFAULT now(), locked_at timestamptz, locked_by text,
  last_error text CHECK(last_error IS NULL OR char_length(last_error)<=2000), delivered_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(organization_id,id), UNIQUE(organization_id,event_id,channel),
  FOREIGN KEY(organization_id,event_id) REFERENCES public.vm_order_events(organization_id,id) ON DELETE RESTRICT,
  CHECK((state='delivered' AND delivered_at IS NOT NULL) OR (state<>'delivered' AND delivered_at IS NULL)),
  CHECK((state='processing' AND locked_at IS NOT NULL AND locked_by IS NOT NULL) OR (state<>'processing' AND locked_at IS NULL AND locked_by IS NULL))
);
CREATE INDEX vm_notification_outbox_pending_idx ON public.vm_notification_outbox(state,next_attempt_at,id) WHERE state IN ('pending','failed');

CREATE TABLE public.vm_order_payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
  order_id uuid NOT NULL, amount numeric(20,2) NOT NULL CHECK(amount>0 AND vm_private.vm_numeric_valid(amount,2,999999999999999999.99,true)),
  payment_date date NOT NULL CHECK(vm_private.vm_date_valid(payment_date)),
  method text NOT NULL CHECK(method IN ('pix','cash','card','bank_transfer','other')),
  currency text NOT NULL DEFAULT 'BRL' CHECK(currency='BRL'), nonce uuid NOT NULL,
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT, created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(organization_id,id), UNIQUE(organization_id,order_id,id), UNIQUE(organization_id,nonce),
  FOREIGN KEY(organization_id,order_id) REFERENCES public.vm_orders(organization_id,id) ON DELETE RESTRICT
);
CREATE INDEX vm_order_payments_order_idx ON public.vm_order_payments(organization_id,order_id,payment_date,id);
ALTER TABLE public.vm_cash_entries
  ADD COLUMN order_id uuid, ADD COLUMN order_payment_id uuid, ADD COLUMN payment_method text,
  ADD CONSTRAINT vm_cash_entries_order_fk FOREIGN KEY(organization_id,order_id) REFERENCES public.vm_orders(organization_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT vm_cash_entries_order_payment_fk FOREIGN KEY(organization_id,order_id,order_payment_id) REFERENCES public.vm_order_payments(organization_id,order_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT vm_cash_entries_order_payment_ck CHECK(
    (order_id IS NULL AND order_payment_id IS NULL AND payment_method IS NULL)
    OR (order_id IS NOT NULL AND order_payment_id IS NOT NULL AND payment_method IS NOT NULL
        AND entry_type='income' AND payment_status='paid' AND amount>0 AND material_purchase_id IS NULL AND supplier_id IS NULL));
CREATE UNIQUE INDEX vm_cash_entries_order_payment_uq ON public.vm_cash_entries(organization_id,order_payment_id) WHERE order_payment_id IS NOT NULL;

CREATE TABLE vm_private.vm_order_requests (
  organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
  idempotency_key uuid NOT NULL, operation text NOT NULL CHECK(operation IN ('create','status','payment')),
  order_id uuid NOT NULL, payload jsonb NOT NULL CHECK(jsonb_typeof(payload)='object'),
  result jsonb NOT NULL CHECK(jsonb_typeof(result)='object'),
  created_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT, created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(organization_id,idempotency_key),
  FOREIGN KEY(organization_id,order_id) REFERENCES public.vm_orders(organization_id,id) ON DELETE RESTRICT
);

-- Permanent snapshots/ledgers cannot be edited even by an accidental privileged DML.
DO $guards$
DECLARE v_table text;
BEGIN
  FOREACH v_table IN ARRAY ARRAY['public.vm_order_items','public.vm_order_item_materials','public.vm_order_consumption_runs','public.vm_order_consumptions','public.vm_order_events','public.vm_order_payments','vm_private.vm_order_client_snapshots','vm_private.vm_order_requests'] LOOP
    EXECUTE format('CREATE TRIGGER vm_orders_append_only BEFORE UPDATE OR DELETE ON %s FOR EACH ROW EXECUTE FUNCTION vm_private.vm_reject_immutable_row()',v_table);
  END LOOP;
END;
$guards$;

CREATE FUNCTION vm_private.vm_order_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $function$
BEGIN
  IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Pedido histórico não pode ser apagado' USING ERRCODE='55000'; END IF;
  IF (pg_catalog.to_jsonb(NEW)-ARRAY['status','status_version','consumed_at','updated_at'])
     IS DISTINCT FROM (pg_catalog.to_jsonb(OLD)-ARRAY['status','status_version','consumed_at','updated_at']) THEN
    RAISE EXCEPTION 'Pedido e snapshots são imutáveis; revisão exige fluxo próprio' USING ERRCODE='55000';
  END IF;
  IF NEW.status_version<>OLD.status_version+1 OR NOT EXISTS (
    SELECT 1 FROM public.vm_order_events e WHERE e.organization_id=NEW.organization_id AND e.order_id=NEW.id
      AND e.status_version=NEW.status_version AND e.status=NEW.status
      AND ((OLD.status_version=0 AND e.event_type='created' AND e.previous_status IS NULL)
        OR (OLD.status_version>0 AND e.event_type='status_changed' AND e.previous_status=OLD.status))
  ) THEN RAISE EXCEPTION 'Status requer evento transacional auditado' USING ERRCODE='55000'; END IF;
  IF (OLD.consumed_at IS NOT NULL AND NEW.consumed_at IS DISTINCT FROM OLD.consumed_at)
     OR (NEW.consumed_at IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.vm_order_consumption_runs r WHERE r.organization_id=NEW.organization_id AND r.order_id=NEW.id AND r.consumed_at=NEW.consumed_at
     )) THEN RAISE EXCEPTION 'Marca de consumo deve corresponder ao ledger imutável' USING ERRCODE='55000'; END IF;
  NEW.updated_at := pg_catalog.clock_timestamp();
  RETURN NEW;
END;
$function$;
CREATE TRIGGER vm_orders_guard BEFORE UPDATE OR DELETE ON public.vm_orders FOR EACH ROW EXECUTE FUNCTION vm_private.vm_order_guard();

CREATE FUNCTION vm_private.vm_notification_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $function$
BEGIN
  IF TG_OP='DELETE' OR (pg_catalog.to_jsonb(NEW)-'read_at') IS DISTINCT FROM (pg_catalog.to_jsonb(OLD)-'read_at')
     OR OLD.read_at IS NOT NULL OR NEW.read_at IS NULL THEN
    RAISE EXCEPTION 'Notificação imutável, exceto primeira marca de leitura' USING ERRCODE='55000';
  END IF;
  RETURN NEW;
END;
$function$;
CREATE TRIGGER vm_notifications_guard BEFORE UPDATE OR DELETE ON public.vm_notifications FOR EACH ROW EXECUTE FUNCTION vm_private.vm_notification_guard();

CREATE FUNCTION vm_private.vm_outbox_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $function$
BEGIN
  IF TG_OP='DELETE' OR (pg_catalog.to_jsonb(NEW)-ARRAY['state','attempts','next_attempt_at','locked_at','locked_by','last_error','delivered_at','updated_at'])
    IS DISTINCT FROM (pg_catalog.to_jsonb(OLD)-ARRAY['state','attempts','next_attempt_at','locked_at','locked_by','last_error','delivered_at','updated_at'])
    OR NEW.attempts<OLD.attempts OR OLD.state='delivered' THEN
    RAISE EXCEPTION 'Identidade/payload de outbox e entrega confirmada são imutáveis' USING ERRCODE='55000';
  END IF;
  NEW.updated_at:=pg_catalog.clock_timestamp(); RETURN NEW;
END;
$function$;
CREATE TRIGGER vm_notification_outbox_guard BEFORE UPDATE OR DELETE ON public.vm_notification_outbox FOR EACH ROW EXECUTE FUNCTION vm_private.vm_outbox_guard();

CREATE FUNCTION vm_private.vm_order_cash_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $function$
BEGIN
  IF NEW.order_payment_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.vm_order_payments p WHERE p.organization_id=NEW.organization_id AND p.order_id=NEW.order_id AND p.id=NEW.order_payment_id
      AND p.amount=NEW.amount AND p.payment_date=NEW.entry_date AND p.payment_date=NEW.paid_at
      AND p.method=NEW.payment_method AND p.created_by=NEW.created_by AND p.created_at=NEW.created_at
  ) THEN RAISE EXCEPTION 'Lançamento deve copiar os stamps do pagamento real' USING ERRCODE='23514'; END IF;
  RETURN NEW;
END;
$function$;
CREATE TRIGGER vm_cash_entries_order_guard BEFORE INSERT ON public.vm_cash_entries FOR EACH ROW EXECUTE FUNCTION vm_private.vm_order_cash_guard();

ALTER TABLE public.vm_product_variants ADD CONSTRAINT vm_product_variants_org_product_id_uq UNIQUE(organization_id,product_id,id);
ALTER TABLE public.vm_order_items ADD CONSTRAINT vm_order_items_variant_product_fk
  FOREIGN KEY(organization_id,product_id,variant_id) REFERENCES public.vm_product_variants(organization_id,product_id,id) ON DELETE RESTRICT;

ALTER TABLE public.vm_orders ADD CONSTRAINT vm_orders_actor_org_fk
  FOREIGN KEY(organization_id,created_by) REFERENCES public.vm_memberships(organization_id,user_id) ON DELETE RESTRICT;
ALTER TABLE public.vm_order_events ADD CONSTRAINT vm_order_events_actor_org_fk
  FOREIGN KEY(organization_id,created_by) REFERENCES public.vm_memberships(organization_id,user_id) ON DELETE RESTRICT;
ALTER TABLE public.vm_order_payments ADD CONSTRAINT vm_order_payments_actor_org_fk
  FOREIGN KEY(organization_id,created_by) REFERENCES public.vm_memberships(organization_id,user_id) ON DELETE RESTRICT;
ALTER TABLE public.vm_order_consumption_runs ADD CONSTRAINT vm_order_consumption_actor_org_fk
  FOREIGN KEY(organization_id,created_by) REFERENCES public.vm_memberships(organization_id,user_id) ON DELETE RESTRICT;
ALTER TABLE vm_private.vm_order_requests ADD CONSTRAINT vm_order_requests_actor_org_fk
  FOREIGN KEY(organization_id,created_by) REFERENCES public.vm_memberships(organization_id,user_id) ON DELETE RESTRICT;

-- Input-only normalization: replays do not reread mutable catalog/contact state.
CREATE FUNCTION vm_private.vm_order_canonical(p_data jsonb,p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path = '' AS $function$
DECLARE
  v_data jsonb; v_items jsonb:='[]'; v_item jsonb; v_dimensions jsonb;
  v_client uuid; v_responsible uuid; v_product uuid; v_variant uuid;
  v_title text; v_kind text; v_status text; v_discount_type text; v_discount numeric; v_shipping numeric;
  v_order_date date; v_production date; v_delivery date; v_item_production date; v_item_delivery date;
  v_qty numeric; v_price numeric; v_override boolean; v_reason text; v_width numeric; v_height numeric;
BEGIN
  PERFORM vm_private.vm_order_keys(p_data,ARRAY['client_id','title','order_date','production_date','delivery_date','responsible_membership_id','public_notes','internal_notes','initial_status','discount_type','discount_value','shipping_amount']);
  IF p_items IS NULL OR pg_catalog.jsonb_typeof(p_items)<>'array' THEN
    RAISE EXCEPTION 'items deve ser array' USING ERRCODE='22023';
  END IF;
  IF pg_catalog.jsonb_array_length(p_items) NOT BETWEEN 1 AND 200 OR pg_catalog.octet_length(p_items::text)>500000 THEN
    RAISE EXCEPTION 'Pedido exige 1 a 200 itens e payload de até 500000 bytes' USING ERRCODE='22023';
  END IF;
  v_client:=vm_private.vm_contact_optional_text(p_data,'client_id',36)::uuid;
  v_responsible:=vm_private.vm_contact_optional_text(p_data,'responsible_membership_id',36)::uuid;
  v_title:=vm_private.vm_contact_optional_text(p_data,'title',200);
  IF v_client IS NULL OR v_title IS NULL THEN RAISE EXCEPTION 'client_id e title obrigatórios' USING ERRCODE='22023'; END IF;
  v_order_date:=vm_private.vm_order_json_date(p_data,'order_date',true);
  v_production:=vm_private.vm_order_json_date(p_data,'production_date');
  v_delivery:=vm_private.vm_order_json_date(p_data,'delivery_date');
  IF (v_production IS NOT NULL AND v_production<v_order_date) OR (v_delivery IS NOT NULL AND v_delivery<v_order_date)
     OR (v_production IS NOT NULL AND v_delivery IS NOT NULL AND v_delivery<v_production) THEN
    RAISE EXCEPTION 'Datas de produção/entrega fora da sequência do pedido' USING ERRCODE='22023';
  END IF;
  v_status:=COALESCE(vm_private.vm_contact_optional_text(p_data,'initial_status',30),'Pendente');
  IF v_status NOT IN ('Pendente','Em Produção','Concluído') THEN RAISE EXCEPTION 'Status inicial inválido' USING ERRCODE='22023'; END IF;
  v_discount_type:=COALESCE(vm_private.vm_contact_optional_text(p_data,'discount_type',10),'none');
  v_discount:=COALESCE(vm_private.vm_order_json_number(p_data,'discount_value',false),0);
  v_shipping:=COALESCE(vm_private.vm_order_json_number(p_data,'shipping_amount',false),0);
  PERFORM vm_private.vm_order_number(v_shipping,2,999999999999.99);
  IF v_discount_type NOT IN ('none','fixed','percent') OR (v_discount_type='none' AND v_discount<>0)
     OR (v_discount_type='percent' AND v_discount>100) THEN RAISE EXCEPTION 'Desconto inválido' USING ERRCODE='22023'; END IF;
  IF v_discount_type='fixed' THEN PERFORM vm_private.vm_order_number(v_discount,2,999999999999.99); END IF;
  v_data:=pg_catalog.jsonb_build_object('client_id',v_client,'title',v_title,'order_date',v_order_date,
    'production_date',v_production,'delivery_date',v_delivery,'responsible_membership_id',v_responsible,
    'public_notes',vm_private.vm_contact_optional_text(p_data,'public_notes',5000),
    'internal_notes',vm_private.vm_contact_optional_text(p_data,'internal_notes',10000),'initial_status',v_status,
    'discount_type',v_discount_type,'discount_value',pg_catalog.trim_scale(v_discount)::text,'shipping_amount',pg_catalog.trim_scale(v_shipping)::text);
  FOR v_item IN SELECT value FROM pg_catalog.jsonb_array_elements(p_items) LOOP
    PERFORM vm_private.vm_order_keys(v_item,ARRAY['kind','product_id','variant_id','title','quantity','unit_price','price_override','price_override_reason','dimensions','details','personalization','production_date','delivery_date']);
    v_kind:=vm_private.vm_contact_optional_text(v_item,'kind',20);
    v_product:=vm_private.vm_contact_optional_text(v_item,'product_id',36)::uuid;
    v_variant:=vm_private.vm_contact_optional_text(v_item,'variant_id',36)::uuid;
    v_title:=vm_private.vm_contact_optional_text(v_item,'title',200);
    IF v_kind IS NULL OR v_kind NOT IN ('product','manual_service')
       OR (v_kind='product' AND v_product IS NULL)
       OR (v_kind='manual_service' AND (v_title IS NULL OR v_product IS NOT NULL OR v_variant IS NOT NULL)) THEN
      RAISE EXCEPTION 'Item deve identificar produto ou serviço manual com título' USING ERRCODE='22023';
    END IF;
    v_qty:=vm_private.vm_order_json_number(v_item,'quantity');
    PERFORM vm_private.vm_order_number(v_qty,8,999999999999.99999999,true);
    v_price:=vm_private.vm_order_json_number(v_item,'unit_price',false);
    IF v_item ? 'price_override' AND pg_catalog.jsonb_typeof(v_item->'price_override') IS DISTINCT FROM 'boolean' THEN
      RAISE EXCEPTION 'price_override deve ser booleano explícito' USING ERRCODE='22023';
    END IF;
    v_override:=COALESCE((v_item->>'price_override')::boolean,false);
    v_reason:=vm_private.vm_contact_optional_text(v_item,'price_override_reason',2000);
    IF (v_override AND (v_price IS NULL OR v_reason IS NULL))
       OR (NOT v_override AND (v_price IS NOT NULL OR v_reason IS NOT NULL))
       OR (v_kind='manual_service' AND NOT v_override) THEN
      RAISE EXCEPTION 'Preço manual/override exige flag, preço e motivo; catálogo não aceita preço enviado' USING ERRCODE='22023';
    END IF;
    v_dimensions:=NULL;
    IF v_item ? 'dimensions' AND pg_catalog.jsonb_typeof(v_item->'dimensions')<>'null' THEN
      PERFORM vm_private.vm_order_keys(v_item->'dimensions',ARRAY['width_cm','height_cm']);
      v_width:=vm_private.vm_order_json_number(v_item->'dimensions','width_cm');
      v_height:=vm_private.vm_order_json_number(v_item->'dimensions','height_cm');
      PERFORM vm_private.vm_order_number(v_width,8,999999999999.99999999,true);
      PERFORM vm_private.vm_order_number(v_height,8,999999999999.99999999,true);
      v_dimensions:=pg_catalog.jsonb_build_object('width_cm',pg_catalog.trim_scale(v_width)::text,'height_cm',pg_catalog.trim_scale(v_height)::text);
    END IF;
    IF v_kind='manual_service' AND v_dimensions IS NOT NULL THEN RAISE EXCEPTION 'Serviço manual é cobrado por unidade; não aceita dimensions' USING ERRCODE='22023'; END IF;
    IF v_item ? 'personalization' AND pg_catalog.jsonb_typeof(v_item->'personalization')<>'null'
       AND (pg_catalog.jsonb_typeof(v_item->'personalization')<>'object' OR pg_catalog.octet_length((v_item->'personalization')::text)>20000) THEN
      RAISE EXCEPTION 'personalization deve ser objeto até 20000 bytes' USING ERRCODE='22023';
    END IF;
    v_item_production:=vm_private.vm_order_json_date(v_item,'production_date');
    v_item_delivery:=vm_private.vm_order_json_date(v_item,'delivery_date');
    IF (v_item_production IS NOT NULL AND v_item_production<v_order_date)
       OR (v_item_delivery IS NOT NULL AND v_item_delivery<v_order_date)
       OR (v_item_production IS NOT NULL AND v_item_delivery IS NOT NULL AND v_item_delivery<v_item_production) THEN
      RAISE EXCEPTION 'Datas do item inválidas' USING ERRCODE='22023';
    END IF;
    v_items:=v_items||pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'kind',v_kind,'product_id',v_product,'variant_id',v_variant,'title',v_title,'quantity',pg_catalog.trim_scale(v_qty)::text,
      'unit_price',CASE WHEN v_price IS NULL THEN NULL ELSE pg_catalog.trim_scale(v_price)::text END,
      'price_override',v_override,'price_override_reason',v_reason,'dimensions',v_dimensions,
      'details',vm_private.vm_contact_optional_text(v_item,'details',5000),
      'personalization',NULLIF(v_item->'personalization','null'::jsonb),'production_date',v_item_production,'delivery_date',v_item_delivery));
  END LOOP;
  RETURN pg_catalog.jsonb_build_object('data',v_data,'items',v_items);
END;
$function$;

-- Resolve a single canonical item under the organization's lock. Versioned
-- recipe rows, never today's unit_cost, supply the cost snapshots.
CREATE FUNCTION vm_private.vm_order_resolve_item(p_organization_id uuid,p_item jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path = '' AS $function$
DECLARE
  v_product public.vm_product_versions%ROWTYPE; v_variant jsonb; v_live_variant public.vm_product_variants%ROWTYPE;
  v_product_id uuid:=(p_item->>'product_id')::uuid; v_variant_id uuid:=(p_item->>'variant_id')::uuid;
  v_kind text:=p_item->>'kind'; v_title text:=p_item->>'title'; v_qty numeric:=(p_item->>'quantity')::numeric;
  v_billing text:='unit'; v_factor numeric:=1; v_billed numeric; v_minimum numeric:=0; v_normal numeric; v_promo numeric;
  v_tier jsonb; v_tier_price numeric; v_price numeric; v_source text; v_mode text:='none'; v_variant_version integer;
  v_recipe jsonb:='[]'; v_component record; v_consumption numeric; v_unit_cost numeric:=0; v_total_cost numeric:=0;
  v_raw numeric; v_line numeric; v_product_snapshot jsonb:='{}'; v_price_snapshot jsonb;
BEGIN
  IF v_kind='product' THEN
    SELECT pv.* INTO v_product FROM public.vm_products p JOIN public.vm_product_versions pv
      ON pv.organization_id=p.organization_id AND pv.product_id=p.id AND pv.product_version=p.current_version
    WHERE p.organization_id=p_organization_id AND p.id=v_product_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Produto vigente não encontrado nesta organização' USING ERRCODE='23503'; END IF;
    v_billing:=v_product.billing_unit; v_normal:=v_product.price; v_promo:=v_product.promo_price;
    v_minimum:=v_product.minimum_quantity; v_mode:='base';
    IF v_variant_id IS NOT NULL THEN
      SELECT v.* INTO v_live_variant FROM public.vm_product_variants v
        WHERE v.organization_id=p_organization_id AND v.product_id=v_product_id AND v.id=v_variant_id AND v.active;
      IF NOT FOUND THEN RAISE EXCEPTION 'Variação inativa, inexistente ou de outro produto/tenant' USING ERRCODE='23503'; END IF;
      SELECT e.value INTO v_variant FROM pg_catalog.jsonb_array_elements(v_product.variants_snapshot) e(value)
        WHERE e.value->>'id'=v_variant_id::text AND (e.value->>'active')::boolean;
      IF v_variant IS NULL OR (v_variant->>'version')::integer<>v_live_variant.current_version THEN
        RAISE EXCEPTION 'Variação não corresponde ao snapshot vigente do produto' USING ERRCODE='23514';
      END IF;
      v_variant_version:=(v_variant->>'version')::integer;
      v_normal:=(v_variant->>'price')::numeric; v_promo:=(v_variant->>'promo_price')::numeric;
      v_minimum:=COALESCE((v_variant->>'minimum_quantity')::numeric,v_minimum);
      v_mode:=v_variant->>'composition_mode';
    ELSIF v_product.pricing_mode='variation' THEN
      RAISE EXCEPTION 'Produto com preço por variação exige variant_id' USING ERRCODE='22023';
    END IF;
    IF v_title IS NULL THEN v_title:=v_product.name||CASE WHEN v_variant IS NULL THEN '' ELSE ' — '||(v_variant->>'name') END; END IF;
    IF pg_catalog.char_length(v_title)>200 THEN RAISE EXCEPTION 'Título do item excede 200 caracteres; informe title explícito' USING ERRCODE='22023'; END IF;
    IF v_billing='m2' THEN
      IF p_item->'dimensions'='null'::jsonb OR p_item->'dimensions' IS NULL THEN
        RAISE EXCEPTION 'Produto m2 exige width_cm e height_cm por peça' USING ERRCODE='22023';
      END IF;
      v_factor:=(p_item->'dimensions'->>'width_cm')::numeric*(p_item->'dimensions'->>'height_cm')::numeric*0.0001;
      PERFORM vm_private.vm_order_number(v_factor,8,999999999999.99999999,true);
    END IF;
    v_product_snapshot:=pg_catalog.jsonb_build_object('product_id',v_product_id,'product_version',v_product.product_version::text,
      'name',v_product.name,'category',v_product.category,'sku',v_product.sku,'pricing_mode',v_product.pricing_mode,
      'billing_unit',v_billing,'production_days',v_product.production_days::text,'variant_id',v_variant_id,
      'variant_version',v_variant_version::text,'variant_name',v_variant->>'name','variant_sku',v_variant->>'sku',
      'recipe_mode',v_mode,'snapshot_metadata',v_product.snapshot_metadata);
  END IF;
  v_billed:=v_qty*v_factor;
  PERFORM vm_private.vm_order_number(v_billed,8,999999999999.99999999,true);
  IF v_billed<v_minimum THEN RAISE EXCEPTION 'Quantidade cobrável abaixo do mínimo do catálogo' USING ERRCODE='22023'; END IF;
  IF v_kind='product' THEN
    v_price:=COALESCE(v_promo,v_normal);
    -- Base wholesale tiers are not implicitly applied to a variant's price.
    IF v_variant_id IS NULL THEN
      SELECT e.value INTO v_tier FROM pg_catalog.jsonb_array_elements(v_product.wholesale_tiers) e(value)
        WHERE (e.value->>'minimum_quantity')::numeric<=v_billed
        ORDER BY (e.value->>'minimum_quantity')::numeric DESC LIMIT 1;
      IF v_tier IS NOT NULL THEN
        v_tier_price:=(v_tier->>'unit_price')::numeric; v_price:=LEAST(v_price,v_tier_price);
      END IF;
    END IF;
    v_source:='catalog';
  ELSE v_source:='manual'; END IF;
  v_price_snapshot:=pg_catalog.jsonb_build_object('normal_price',v_normal::text,'promo_price',v_promo::text,
    'minimum_quantity',v_minimum::text,'applicable_tier',CASE WHEN v_tier IS NULL THEN NULL ELSE pg_catalog.jsonb_build_object(
      'minimum_quantity',(v_tier->>'minimum_quantity')::numeric::text,'unit_price',(v_tier->>'unit_price')::numeric::text) END,
    'catalog_resolved_price',v_price::text,'billing_unit',v_billing,'currency','BRL','rounding','round_line_half_away_from_zero_2dp');
  IF (p_item->>'price_override')::boolean THEN
    v_price:=(p_item->>'unit_price')::numeric;
    IF v_kind='product' THEN v_source:='override'; END IF;
  END IF;
  PERFORM vm_private.vm_order_number(v_price,8,999999999999.99999999);
  v_raw:=v_billed*v_price;
  PERFORM vm_private.vm_order_number(v_raw,16,999999999999999999999999.9999999999999999);
  -- Only this deliberate charge boundary rounds; input/consumption never do.
  v_line:=pg_catalog.round(v_raw,2);
  PERFORM vm_private.vm_order_number(v_line,2,999999999999999999.99);
  FOR v_component IN
    SELECT c.material_id,c.component_unit,c.quantity,c.unit_cost_snapshot,m.name,m.unit
    FROM public.vm_product_components c JOIN public.vm_materials m ON m.organization_id=c.organization_id AND m.id=c.material_id
    WHERE c.organization_id=p_organization_id AND c.product_id=v_product_id AND c.product_version=v_product.product_version AND v_mode IN ('base','inherit_base')
    UNION ALL
    SELECT c.material_id,c.component_unit,c.quantity,c.unit_cost_snapshot,m.name,m.unit
    FROM public.vm_product_variant_components c JOIN public.vm_materials m ON m.organization_id=c.organization_id AND m.id=c.material_id
    WHERE c.organization_id=p_organization_id AND c.variant_id=v_variant_id AND c.variant_version=v_variant_version AND v_mode='own'
    ORDER BY material_id
  LOOP
    IF v_component.component_unit<>v_component.unit THEN RAISE EXCEPTION 'Unidade de insumo mudou desde a receita' USING ERRCODE='23514'; END IF;
    v_consumption:=v_component.quantity*v_billed;
    PERFORM vm_private.vm_order_number(v_consumption,8,999999999999.99999999,true);
    v_unit_cost:=v_unit_cost+v_component.quantity*v_component.unit_cost_snapshot;
    v_total_cost:=v_total_cost+v_consumption*v_component.unit_cost_snapshot;
    v_recipe:=v_recipe||pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'material_id',v_component.material_id,'material_name_snapshot',v_component.name,'unit',v_component.component_unit,
      'quantity_snapshot',v_component.quantity::text,'unit_cost_snapshot',v_component.unit_cost_snapshot::text,
      'consumption_quantity',v_consumption::text,'consumption_cost',(v_consumption*v_component.unit_cost_snapshot)::text));
  END LOOP;
  PERFORM vm_private.vm_order_number(v_unit_cost,16,999999999999999999999999.9999999999999999);
  PERFORM vm_private.vm_order_number(v_total_cost,16,999999999999999999999999.9999999999999999);
  RETURN p_item||pg_catalog.jsonb_build_object('title',v_title,'product_version',v_product.product_version::text,
    'variant_version',v_variant_version::text,'billing_unit',v_billing,'dimensions_factor',v_factor::text,'billed_quantity',v_billed::text,
    'unit_price',v_price::text,'price_source',v_source,'line_amount_raw',v_raw::text,'line_amount',v_line::text,
    'recipe_mode',v_mode,'unit_composition_cost',v_unit_cost::text,'total_composition_cost',v_total_cost::text,
    'product_snapshot',v_product_snapshot,'price_snapshot',v_price_snapshot||pg_catalog.jsonb_build_object('selected_price',v_price::text,'source',v_source),
    'materials',v_recipe);
END;
$function$;

-- Trusted helpers have NO API-role EXECUTE. They receive an explicit actor
-- from a validated public RPC, never set JWT/auth.uid() or impersonate a client.
CREATE FUNCTION vm_private.vm_order_consume(p_organization_id uuid,p_order_id uuid,p_actor uuid)
RETURNS timestamptz LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE v_consumed timestamptz; v_material record; v_stock public.vm_materials%ROWTYPE; v_movement uuid; v_new numeric;
BEGIN
  PERFORM 1 FROM public.vm_organizations o WHERE o.id=p_organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Organização não encontrada' USING ERRCODE='23503'; END IF;
  PERFORM 1 FROM public.vm_orders o WHERE o.organization_id=p_organization_id AND o.id=p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pedido não encontrado nesta organização' USING ERRCODE='23503'; END IF;
  SELECT r.consumed_at INTO v_consumed FROM public.vm_order_consumption_runs r WHERE r.organization_id=p_organization_id AND r.order_id=p_order_id;
  IF FOUND THEN RETURN v_consumed; END IF;
  IF p_actor IS NULL THEN RAISE EXCEPTION 'Consumo exige autor operacional real' USING ERRCODE='42501'; END IF;
  -- First lock and validate ALL balances; no stock mutation in this loop.
  FOR v_material IN
    SELECT s.material_id,min(s.unit) AS unit,count(DISTINCT s.unit) AS unit_count,sum(s.consumption_quantity) AS quantity
    FROM public.vm_order_item_materials s WHERE s.organization_id=p_organization_id AND s.order_id=p_order_id
    GROUP BY s.material_id ORDER BY s.material_id
  LOOP
    PERFORM vm_private.vm_order_number(v_material.quantity,8,999999999999.99999999,true);
    SELECT m.* INTO v_stock FROM public.vm_materials m
      WHERE m.organization_id=p_organization_id AND m.id=v_material.material_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Insumo não encontrado nesta organização' USING ERRCODE='23503'; END IF;
    IF v_material.unit_count<>1 OR v_stock.unit<>v_material.unit THEN
      RAISE EXCEPTION 'Unidade do insumo diverge do snapshot do pedido' USING ERRCODE='23514';
    END IF;
    IF v_stock.stock_quantity<v_material.quantity THEN
      RAISE EXCEPTION 'Estoque insuficiente para iniciar produção: insumo %',v_material.material_id USING ERRCODE='23514';
    END IF;
  END LOOP;
  v_consumed:=pg_catalog.clock_timestamp();
  INSERT INTO public.vm_order_consumption_runs(organization_id,order_id,consumed_at,created_by)
    VALUES(p_organization_id,p_order_id,v_consumed,p_actor);
  FOR v_material IN
    SELECT s.material_id,min(s.unit) AS unit,sum(s.consumption_quantity) AS quantity
    FROM public.vm_order_item_materials s WHERE s.organization_id=p_organization_id AND s.order_id=p_order_id
    GROUP BY s.material_id ORDER BY s.material_id
  LOOP
    SELECT m.* INTO v_stock FROM public.vm_materials m WHERE m.organization_id=p_organization_id AND m.id=v_material.material_id;
    v_new:=v_stock.stock_quantity-v_material.quantity;
    PERFORM vm_private.vm_order_number(v_new,8,999999999999.99999999);
    UPDATE public.vm_materials m SET stock_quantity=v_new WHERE m.organization_id=p_organization_id AND m.id=v_material.material_id;
    INSERT INTO public.vm_stock_movements(organization_id,material_id,movement_type,quantity_delta,stock_after,package_cost,package_quantity,note,order_id,created_by)
      VALUES(p_organization_id,v_material.material_id,'order_deduction',-v_material.quantity,v_new,v_stock.package_cost,v_stock.package_quantity,'Baixa de produção do pedido',p_order_id,p_actor)
      RETURNING id INTO v_movement;
    INSERT INTO public.vm_order_consumptions(organization_id,order_id,material_id,unit,quantity,movement_id)
      VALUES(p_organization_id,p_order_id,v_material.material_id,v_material.unit,v_material.quantity,v_movement);
  END LOOP;
  RETURN v_consumed;
END;
$function$;

CREATE FUNCTION vm_private.vm_order_apply_status(p_organization_id uuid,p_order_id uuid,p_status text,p_reason text,p_actor uuid,p_creation boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE v_order public.vm_orders%ROWTYPE; v_event uuid; v_consumed timestamptz; v_payload jsonb; v_version bigint;
BEGIN
  SELECT o.* INTO v_order FROM public.vm_orders o WHERE o.organization_id=p_organization_id AND o.id=p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pedido não encontrado nesta organização' USING ERRCODE='23503'; END IF;
  IF p_status IS NULL OR p_status NOT IN ('Pendente','Em Produção','Concluído','Entregue','Cancelado') THEN
    RAISE EXCEPTION 'Status inválido' USING ERRCODE='22023';
  END IF;
  IF p_creation THEN
    IF v_order.status_version<>0 OR p_status NOT IN ('Pendente','Em Produção','Concluído') THEN
      RAISE EXCEPTION 'Criação já finalizada ou estado inicial inválido' USING ERRCODE='55000';
    END IF;
  ELSE
    IF v_order.status_version=0 THEN RAISE EXCEPTION 'Pedido sem criação finalizada' USING ERRCODE='55000'; END IF;
    IF p_status=v_order.status THEN
      RETURN pg_catalog.jsonb_build_object('order_id',v_order.id,'status',v_order.status,'status_version',v_order.status_version::text,'event_id',NULL,
        'consumed_at',v_order.consumed_at,'changed',false);
    END IF;
    IF NOT ((v_order.status='Pendente' AND p_status IN ('Em Produção','Concluído','Cancelado'))
       OR (v_order.status='Em Produção' AND p_status IN ('Concluído','Cancelado'))
       OR (v_order.status='Concluído' AND p_status IN ('Entregue','Cancelado'))) THEN
      RAISE EXCEPTION 'Transição não permitida: % -> %',v_order.status,p_status USING ERRCODE='22023';
    END IF;
  END IF;
  IF p_status='Cancelado' AND (p_reason IS NULL OR pg_catalog.btrim(p_reason)='' OR pg_catalog.char_length(p_reason)>2000) THEN
    RAISE EXCEPTION 'Cancelamento exige motivo' USING ERRCODE='22023';
  END IF;
  v_consumed:=v_order.consumed_at;
  IF p_status IN ('Em Produção','Concluído') AND v_consumed IS NULL THEN
    v_consumed:=vm_private.vm_order_consume(p_organization_id,p_order_id,p_actor);
  END IF;
  v_version:=v_order.status_version+1;
  -- Deliberately excludes PII, client snapshot, prices, costs and internal notes.
  v_payload:=pg_catalog.jsonb_build_object('order_id',p_order_id,'code',v_order.code,'status',p_status,
    'status_version',v_version::text,'order_date',v_order.order_date,'production_date',v_order.production_date,
    'delivery_date',v_order.delivery_date,'inventory_deducted',v_consumed IS NOT NULL);
  INSERT INTO public.vm_order_events(organization_id,order_id,status_version,event_type,previous_status,status,reason,payload,created_by)
    VALUES(p_organization_id,p_order_id,v_version,CASE WHEN p_creation THEN 'created' ELSE 'status_changed' END,
      CASE WHEN p_creation THEN NULL ELSE v_order.status END,p_status,p_reason,v_payload,p_actor)
    RETURNING id INTO v_event;
  UPDATE public.vm_orders o SET status=p_status,status_version=v_version,consumed_at=v_consumed
    WHERE o.organization_id=p_organization_id AND o.id=p_order_id;
  INSERT INTO public.vm_notifications(organization_id,event_id,recipient_user_id,title,payload)
    SELECT p_organization_id,v_event,m.user_id,'Pedido '||v_order.code||' — '||p_status,v_payload
    FROM public.vm_memberships m WHERE m.organization_id=p_organization_id;
  INSERT INTO public.vm_notification_outbox(organization_id,event_id,payload)
    VALUES(p_organization_id,v_event,v_payload);
  RETURN pg_catalog.jsonb_build_object('order_id',p_order_id,'status',p_status,'status_version',v_version::text,
    'event_id',v_event,'consumed_at',v_consumed,'changed',true);
END;
$function$;

CREATE FUNCTION vm_private.vm_order_build(p_organization_id uuid,p_canonical jsonb,p_actor uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE
  v_data jsonb:=p_canonical->'data'; v_items jsonb:='[]'; v_item jsonb; v_client public.vm_clients%ROWTYPE;
  v_order uuid; v_item_id uuid; v_code text; v_position integer:=0;
  v_subtotal numeric:=0; v_discount numeric; v_total numeric; v_status_result jsonb; v_aggregate record;
BEGIN
  PERFORM 1 FROM public.vm_organizations o WHERE o.id=p_organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Organização não encontrada' USING ERRCODE='23503'; END IF;
  SELECT c.* INTO v_client FROM public.vm_clients c
    WHERE c.organization_id=p_organization_id AND c.id=(v_data->>'client_id')::uuid AND c.archived_at IS NULL FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Cliente deve estar ativo na organização' USING ERRCODE='23503'; END IF;
  IF v_data->>'responsible_membership_id' IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.vm_memberships m WHERE m.organization_id=p_organization_id
      AND m.id=(v_data->>'responsible_membership_id')::uuid AND m.role IN ('owner','admin','production')
  ) THEN RAISE EXCEPTION 'Responsável deve ser membership de produção da mesma organização' USING ERRCODE='23503'; END IF;
  FOR v_item IN SELECT value FROM pg_catalog.jsonb_array_elements(p_canonical->'items') LOOP
    v_item:=vm_private.vm_order_resolve_item(p_organization_id,v_item);
    v_items:=v_items||pg_catalog.jsonb_build_array(v_item);
    v_subtotal:=v_subtotal+(v_item->>'line_amount')::numeric;
  END LOOP;
  -- Reject an aggregate that cannot fit before writing an order, including
  -- pending orders: later consumption uses precisely this frozen demand.
  FOR v_aggregate IN
    SELECT r.material_id,count(DISTINCT r.unit) AS unit_count,sum(r.consumption_quantity) AS quantity
    FROM pg_catalog.jsonb_array_elements(v_items) i(value)
    CROSS JOIN LATERAL pg_catalog.jsonb_to_recordset(i.value->'materials') r(material_id uuid,unit text,consumption_quantity numeric)
    GROUP BY r.material_id
  LOOP
    PERFORM vm_private.vm_order_number(v_aggregate.quantity,8,999999999999.99999999,true);
    IF v_aggregate.unit_count<>1 THEN RAISE EXCEPTION 'Snapshot contém unidades divergentes para um insumo' USING ERRCODE='23514'; END IF;
  END LOOP;
  PERFORM vm_private.vm_order_number(v_subtotal,2,999999999999999999.99);
  v_discount:=CASE v_data->>'discount_type'
    WHEN 'fixed' THEN (v_data->>'discount_value')::numeric
    WHEN 'percent' THEN pg_catalog.round(v_subtotal*(v_data->>'discount_value')::numeric*0.01,2)
    ELSE 0 END;
  IF v_discount>v_subtotal THEN RAISE EXCEPTION 'Desconto excede subtotal' USING ERRCODE='22023'; END IF;
  v_total:=v_subtotal-v_discount+(v_data->>'shipping_amount')::numeric;
  PERFORM vm_private.vm_order_number(v_discount,2,999999999999999999.99);
  PERFORM vm_private.vm_order_number(v_total,2,999999999999999999.99);
  v_order:=pg_catalog.gen_random_uuid(); v_code:='PED-'||pg_catalog.upper(pg_catalog.replace(v_order::text,'-',''));
  INSERT INTO public.vm_orders(id,organization_id,code,client_id,client_name_snapshot,title,order_date,production_date,delivery_date,
    responsible_membership_id,public_notes,internal_notes,subtotal,discount_type,discount_value,discount_amount,shipping_amount,total_amount,created_by)
    VALUES(v_order,p_organization_id,v_code,v_client.id,v_client.name,v_data->>'title',(v_data->>'order_date')::date,
      (v_data->>'production_date')::date,(v_data->>'delivery_date')::date,(v_data->>'responsible_membership_id')::uuid,
      v_data->>'public_notes',v_data->>'internal_notes',v_subtotal,v_data->>'discount_type',(v_data->>'discount_value')::numeric,
      v_discount,(v_data->>'shipping_amount')::numeric,v_total,p_actor);
  INSERT INTO vm_private.vm_order_client_snapshots(organization_id,order_id,client_id,snapshot)
    VALUES(p_organization_id,v_order,v_client.id,pg_catalog.jsonb_build_object('client_id',v_client.id,'name',v_client.name,
      'person_type',v_client.person_type,'tax_id',v_client.tax_id,'birth_date',v_client.birth_date,'email',v_client.email,
      'phone',v_client.phone,'address',v_client.address,'captured_at',pg_catalog.clock_timestamp()));
  FOR v_item IN SELECT value FROM pg_catalog.jsonb_array_elements(v_items) LOOP
    v_position:=v_position+1;
    INSERT INTO public.vm_order_items(organization_id,order_id,position,kind,product_id,product_version,variant_id,variant_version,title,
      quantity,billing_unit,dimensions,dimensions_factor,billed_quantity,unit_price,price_source,price_override_reason,
      line_amount_raw,line_amount,recipe_mode,unit_composition_cost,total_composition_cost,product_snapshot,price_snapshot,
      details,personalization,production_date,delivery_date)
      VALUES(p_organization_id,v_order,v_position,v_item->>'kind',(v_item->>'product_id')::uuid,(v_item->>'product_version')::integer,
        (v_item->>'variant_id')::uuid,(v_item->>'variant_version')::integer,v_item->>'title',(v_item->>'quantity')::numeric,
        v_item->>'billing_unit',NULLIF(v_item->'dimensions','null'::jsonb),(v_item->>'dimensions_factor')::numeric,
        (v_item->>'billed_quantity')::numeric,(v_item->>'unit_price')::numeric,v_item->>'price_source',v_item->>'price_override_reason',
        (v_item->>'line_amount_raw')::numeric,(v_item->>'line_amount')::numeric,v_item->>'recipe_mode',
        (v_item->>'unit_composition_cost')::numeric,(v_item->>'total_composition_cost')::numeric,v_item->'product_snapshot',v_item->'price_snapshot',
        v_item->>'details',NULLIF(v_item->'personalization','null'::jsonb),(v_item->>'production_date')::date,(v_item->>'delivery_date')::date)
      RETURNING id INTO v_item_id;
    INSERT INTO public.vm_order_item_materials(organization_id,order_id,item_id,material_id,material_name_snapshot,unit,
      quantity_snapshot,unit_cost_snapshot,consumption_quantity,consumption_cost)
      SELECT p_organization_id,v_order,v_item_id,r.material_id,r.material_name_snapshot,r.unit,r.quantity_snapshot,r.unit_cost_snapshot,r.consumption_quantity,r.consumption_cost
      FROM pg_catalog.jsonb_to_recordset(v_item->'materials') r(material_id uuid,material_name_snapshot text,unit text,
        quantity_snapshot numeric,unit_cost_snapshot numeric,consumption_quantity numeric,consumption_cost numeric);
  END LOOP;
  v_status_result:=vm_private.vm_order_apply_status(p_organization_id,v_order,v_data->>'initial_status',NULL,p_actor,true);
  RETURN v_status_result||pg_catalog.jsonb_build_object('code',v_code,'subtotal',v_subtotal::numeric(20,2)::text,
    'discount_amount',v_discount::numeric(20,2)::text,'shipping_amount',(v_data->>'shipping_amount')::numeric(20,2)::text,
    'total_amount',v_total::numeric(20,2)::text,'paid_amount','0.00','balance_amount',v_total::numeric(20,2)::text);
END;
$function$;

CREATE FUNCTION public.vm_create_order(p_organization_id uuid,p_data jsonb,p_items jsonb,p_idempotency_key uuid)
RETURNS TABLE(order_id uuid,code text,status text,status_version text,event_id uuid,consumed_at timestamptz,subtotal text,discount_amount text,shipping_amount text,total_amount text,paid_amount text,balance_amount text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE v_actor uuid:=auth.uid(); v_payload jsonb; v_result jsonb; v_request vm_private.vm_order_requests%ROWTYPE;
BEGIN
  IF v_actor IS NULL OR auth.role() IS DISTINCT FROM 'authenticated'
     OR NOT vm_private.vm_has_role(p_organization_id,ARRAY['owner','admin','finance']) THEN
    RAISE EXCEPTION 'Sem permissão para criar pedido nesta organização' USING ERRCODE='42501';
  END IF;
  IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'Chave de idempotência obrigatória' USING ERRCODE='22023'; END IF;
  v_payload:=vm_private.vm_order_canonical(p_data,p_items);
  IF v_payload->'data'->>'initial_status' IN ('Em Produção','Concluído')
     AND NOT vm_private.vm_has_role(p_organization_id,ARRAY['owner','admin','production']) THEN
    RAISE EXCEPTION 'Financeiro não pode iniciar fabricação' USING ERRCODE='42501';
  END IF;
  PERFORM 1 FROM public.vm_organizations o WHERE o.id=p_organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Organização não encontrada' USING ERRCODE='23503'; END IF;
  SELECT r.* INTO v_request FROM vm_private.vm_order_requests r WHERE r.organization_id=p_organization_id AND r.idempotency_key=p_idempotency_key;
  IF FOUND THEN
    IF v_request.operation<>'create' OR v_request.payload IS DISTINCT FROM v_payload THEN
      RAISE EXCEPTION 'Chave reutilizada com operação/payload diferente' USING ERRCODE='23505';
    END IF;
    v_result:=v_request.result;
  ELSE
    v_result:=vm_private.vm_order_build(p_organization_id,v_payload,v_actor);
    INSERT INTO vm_private.vm_order_requests(organization_id,idempotency_key,operation,order_id,payload,result,created_by)
      VALUES(p_organization_id,p_idempotency_key,'create',(v_result->>'order_id')::uuid,v_payload,v_result,v_actor);
  END IF;
  RETURN QUERY SELECT r.order_id,r.code,r.status,r.status_version,r.event_id,r.consumed_at,r.subtotal,r.discount_amount,r.shipping_amount,r.total_amount,r.paid_amount,r.balance_amount
    FROM pg_catalog.jsonb_to_record(v_result) r(order_id uuid,code text,status text,status_version text,event_id uuid,consumed_at timestamptz,subtotal text,discount_amount text,shipping_amount text,total_amount text,paid_amount text,balance_amount text);
END;
$function$;

CREATE FUNCTION public.vm_set_order_status(p_organization_id uuid,p_order_id uuid,p_status text,p_reason text,p_idempotency_key uuid)
RETURNS TABLE(order_id uuid,status text,status_version text,event_id uuid,consumed_at timestamptz,changed boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE v_actor uuid:=auth.uid(); v_payload jsonb; v_result jsonb; v_request vm_private.vm_order_requests%ROWTYPE; v_order public.vm_orders%ROWTYPE; v_reason text:=NULLIF(pg_catalog.btrim(p_reason),'');
BEGIN
  IF v_actor IS NULL OR auth.role() IS DISTINCT FROM 'authenticated' OR NOT vm_private.vm_is_member(p_organization_id) THEN
    RAISE EXCEPTION 'Sessão/membership exigida' USING ERRCODE='42501';
  END IF;
  IF p_idempotency_key IS NULL OR p_order_id IS NULL OR p_status IS NULL
     OR p_status NOT IN ('Pendente','Em Produção','Concluído','Entregue','Cancelado') OR pg_catalog.char_length(v_reason)>2000
     OR (p_status='Cancelado' AND v_reason IS NULL) THEN
    RAISE EXCEPTION 'Chave, status ou motivo inválidos' USING ERRCODE='22023';
  END IF;
  -- Do not let a viewer replay an old privileged command.
  IF p_status IN ('Pendente','Em Produção','Concluído','Entregue') AND NOT vm_private.vm_has_role(p_organization_id,ARRAY['owner','admin','production']) THEN
    RAISE EXCEPTION 'Etapa operacional exige permissão de produção' USING ERRCODE='42501';
  END IF;
  IF p_status='Cancelado' AND NOT vm_private.vm_has_role(p_organization_id,ARRAY['owner','admin','finance']) THEN
    RAISE EXCEPTION 'Sem permissão para cancelar pedido' USING ERRCODE='42501';
  END IF;
  PERFORM 1 FROM public.vm_organizations o WHERE o.id=p_organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Organização não encontrada' USING ERRCODE='23503'; END IF;
  v_payload:=pg_catalog.jsonb_build_object('order_id',p_order_id,'status',p_status,'reason',v_reason);
  SELECT r.* INTO v_request FROM vm_private.vm_order_requests r WHERE r.organization_id=p_organization_id AND r.idempotency_key=p_idempotency_key;
  IF FOUND THEN
    IF v_request.operation<>'status' OR v_request.payload IS DISTINCT FROM v_payload THEN
      RAISE EXCEPTION 'Chave reutilizada com operação/payload diferente' USING ERRCODE='23505';
    END IF;
    -- Permission for a finance cancellation is evaluated at its original event,
    -- not against a later mutable state (a canceled order is terminal).
    IF p_status='Cancelado' AND vm_private.vm_membership_role(p_organization_id)='finance'
       AND v_request.result->>'consumed_at' IS NOT NULL THEN
      RAISE EXCEPTION 'Financeiro só cancela antes da baixa' USING ERRCODE='42501';
    END IF;
    v_result:=v_request.result;
  ELSE
    SELECT o.* INTO v_order FROM public.vm_orders o WHERE o.organization_id=p_organization_id AND o.id=p_order_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Pedido não encontrado nesta organização' USING ERRCODE='23503'; END IF;
    IF p_status='Cancelado' AND v_order.consumed_at IS NOT NULL AND NOT vm_private.vm_has_role(p_organization_id,ARRAY['owner','admin']) THEN
      RAISE EXCEPTION 'Cancelamento após baixa exige owner/admin' USING ERRCODE='42501';
    END IF;
    v_result:=vm_private.vm_order_apply_status(p_organization_id,p_order_id,p_status,v_reason,v_actor);
    INSERT INTO vm_private.vm_order_requests(organization_id,idempotency_key,operation,order_id,payload,result,created_by)
      VALUES(p_organization_id,p_idempotency_key,'status',p_order_id,v_payload,v_result,v_actor);
  END IF;
  RETURN QUERY SELECT r.order_id,r.status,r.status_version,r.event_id,r.consumed_at,r.changed
    FROM pg_catalog.jsonb_to_record(v_result) r(order_id uuid,status text,status_version text,event_id uuid,consumed_at timestamptz,changed boolean);
END;
$function$;

CREATE FUNCTION public.vm_record_order_payment(p_organization_id uuid,p_order_id uuid,p_amount numeric,p_payment_date date,p_method text,p_idempotency_key uuid)
RETURNS TABLE(payment_id uuid,cash_entry_id uuid,order_id uuid,amount text,payment_date date,method text,total_amount text,paid_amount text,balance_amount text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE
  v_actor uuid:=auth.uid(); v_request vm_private.vm_order_requests%ROWTYPE; v_order public.vm_orders%ROWTYPE;
  v_payload jsonb; v_result jsonb; v_paid numeric; v_payment uuid; v_cash uuid; v_time timestamptz;
BEGIN
  IF v_actor IS NULL OR auth.role() IS DISTINCT FROM 'authenticated'
     OR NOT vm_private.vm_has_role(p_organization_id,ARRAY['owner','admin','finance']) THEN
    RAISE EXCEPTION 'Sem permissão para registrar pagamento real' USING ERRCODE='42501';
  END IF;
  PERFORM vm_private.vm_order_number(p_amount,2,999999999999999999.99,true);
  IF p_idempotency_key IS NULL OR p_order_id IS NULL OR NOT vm_private.vm_date_valid(p_payment_date)
     OR p_payment_date>CURRENT_DATE OR p_method IS NULL OR p_method NOT IN ('pix','cash','card','bank_transfer','other') THEN
    RAISE EXCEPTION 'Chave, data efetiva ou método do pagamento inválidos' USING ERRCODE='22023';
  END IF;
  v_payload:=pg_catalog.jsonb_build_object('order_id',p_order_id,'amount',pg_catalog.trim_scale(p_amount)::text,'payment_date',p_payment_date,'method',p_method);
  PERFORM 1 FROM public.vm_organizations o WHERE o.id=p_organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Organização não encontrada' USING ERRCODE='23503'; END IF;
  SELECT r.* INTO v_request FROM vm_private.vm_order_requests r WHERE r.organization_id=p_organization_id AND r.idempotency_key=p_idempotency_key;
  IF FOUND THEN
    IF v_request.operation<>'payment' OR v_request.payload IS DISTINCT FROM v_payload THEN
      RAISE EXCEPTION 'Chave reutilizada com operação/payload diferente' USING ERRCODE='23505';
    END IF;
    v_result:=v_request.result;
  ELSE
    SELECT o.* INTO v_order FROM public.vm_orders o WHERE o.organization_id=p_organization_id AND o.id=p_order_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Pedido não encontrado nesta organização' USING ERRCODE='23503'; END IF;
    IF v_order.status='Cancelado' THEN RAISE EXCEPTION 'Não registrar recebimento novo em pedido cancelado' USING ERRCODE='22023'; END IF;
    SELECT COALESCE(sum(p.amount),0) INTO v_paid FROM public.vm_order_payments p WHERE p.organization_id=p_organization_id AND p.order_id=p_order_id;
    IF p_amount>v_order.total_amount-v_paid THEN RAISE EXCEPTION 'Pagamento excede saldo a receber' USING ERRCODE='23514'; END IF;
    v_time:=pg_catalog.clock_timestamp();
    INSERT INTO public.vm_order_payments(organization_id,order_id,amount,payment_date,method,nonce,created_by,created_at)
      VALUES(p_organization_id,p_order_id,p_amount,p_payment_date,p_method,p_idempotency_key,v_actor,v_time) RETURNING id INTO v_payment;
    INSERT INTO public.vm_cash_entries(organization_id,entry_type,amount,entry_date,description,payment_status,paid_at,
      order_id,order_payment_id,payment_method,created_by,created_at)
      VALUES(p_organization_id,'income',p_amount,p_payment_date,'Pagamento do pedido '||v_order.code,'paid',p_payment_date,
        p_order_id,v_payment,p_method,v_actor,v_time) RETURNING id INTO v_cash;
    v_paid:=v_paid+p_amount;
    v_result:=pg_catalog.jsonb_build_object('payment_id',v_payment,'cash_entry_id',v_cash,'order_id',p_order_id,
      'amount',p_amount::numeric(20,2)::text,'payment_date',p_payment_date,'method',p_method,
      'total_amount',v_order.total_amount::text,'paid_amount',v_paid::numeric(20,2)::text,'balance_amount',(v_order.total_amount-v_paid)::numeric(20,2)::text);
    INSERT INTO vm_private.vm_order_requests(organization_id,idempotency_key,operation,order_id,payload,result,created_by)
      VALUES(p_organization_id,p_idempotency_key,'payment',p_order_id,v_payload,v_result,v_actor);
  END IF;
  RETURN QUERY SELECT r.payment_id,r.cash_entry_id,r.order_id,r.amount,r.payment_date,r.method,r.total_amount,r.paid_amount,r.balance_amount
    FROM pg_catalog.jsonb_to_record(v_result) r(payment_id uuid,cash_entry_id uuid,order_id uuid,amount text,payment_date date,method text,total_amount text,paid_amount text,balance_amount text);
END;
$function$;

CREATE FUNCTION public.vm_mark_notification_read(p_organization_id uuid,p_notification_id uuid)
RETURNS TABLE(notification_id uuid,read_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE v_actor uuid:=auth.uid(); v_read timestamptz;
BEGIN
  IF v_actor IS NULL OR auth.role() IS DISTINCT FROM 'authenticated' OR NOT vm_private.vm_is_member(p_organization_id) THEN
    RAISE EXCEPTION 'Sessão/membership exigida' USING ERRCODE='42501';
  END IF;
  SELECT n.read_at INTO v_read FROM public.vm_notifications n WHERE n.organization_id=p_organization_id
    AND n.id=p_notification_id AND n.recipient_user_id=v_actor FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Notificação não pertence ao usuário nesta organização' USING ERRCODE='42501'; END IF;
  IF v_read IS NULL THEN
    v_read:=pg_catalog.clock_timestamp();
    UPDATE public.vm_notifications n SET read_at=v_read WHERE n.organization_id=p_organization_id AND n.id=p_notification_id AND n.recipient_user_id=v_actor;
  END IF;
  RETURN QUERY SELECT p_notification_id,v_read;
END;
$function$;

CREATE FUNCTION vm_private.vm_order_item_insert_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $function$
DECLARE v_order public.vm_orders%ROWTYPE; v_billed numeric;
BEGIN
  SELECT o.* INTO v_order FROM public.vm_orders o WHERE o.organization_id=NEW.organization_id AND o.id=NEW.order_id;
  IF NOT FOUND OR v_order.status_version<>0 THEN RAISE EXCEPTION 'Itens/receita só podem ser inseridos durante criação atômica' USING ERRCODE='55000'; END IF;
  IF TG_TABLE_NAME='vm_order_item_materials' THEN
    SELECT i.billed_quantity INTO v_billed FROM public.vm_order_items i WHERE i.organization_id=NEW.organization_id AND i.order_id=NEW.order_id AND i.id=NEW.item_id;
    IF NEW.consumption_quantity IS DISTINCT FROM NEW.quantity_snapshot*v_billed THEN
      RAISE EXCEPTION 'Consumo deve ser fração congelada vezes quantidade cobrável' USING ERRCODE='23514';
    END IF;
  ELSE
    IF (NEW.production_date IS NOT NULL AND NEW.production_date<v_order.order_date)
       OR (NEW.delivery_date IS NOT NULL AND NEW.delivery_date<v_order.order_date)
       OR (NEW.production_date IS NOT NULL AND NEW.delivery_date IS NOT NULL AND NEW.delivery_date<NEW.production_date) THEN
      RAISE EXCEPTION 'Datas do item fora da sequência do pedido' USING ERRCODE='23514';
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;
CREATE TRIGGER vm_order_items_creation_only BEFORE INSERT ON public.vm_order_items FOR EACH ROW EXECUTE FUNCTION vm_private.vm_order_item_insert_guard();
CREATE TRIGGER vm_order_item_materials_creation_only BEFORE INSERT ON public.vm_order_item_materials FOR EACH ROW EXECUTE FUNCTION vm_private.vm_order_item_insert_guard();

-- Deferred checks require BOTH sides of the financial/stock link by COMMIT.
-- A privileged accidental insertion cannot leave a payment without its income
-- or a durable consumption run without the complete immutable material ledger.
CREATE FUNCTION vm_private.vm_order_payment_complete()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE v_paid numeric; v_total numeric;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.vm_cash_entries c WHERE c.organization_id=NEW.organization_id AND c.order_payment_id=NEW.id) THEN
    RAISE EXCEPTION 'Pagamento sem lançamento de receita vinculado' USING ERRCODE='23514';
  END IF;
  SELECT COALESCE(sum(p.amount),0) INTO v_paid FROM public.vm_order_payments p WHERE p.organization_id=NEW.organization_id AND p.order_id=NEW.order_id;
  SELECT o.total_amount INTO v_total FROM public.vm_orders o WHERE o.organization_id=NEW.organization_id AND o.id=NEW.order_id;
  IF v_paid>v_total THEN RAISE EXCEPTION 'Pagamentos excedem total do pedido' USING ERRCODE='23514'; END IF;
  RETURN NULL;
END;
$function$;
CREATE CONSTRAINT TRIGGER vm_order_payments_complete AFTER INSERT ON public.vm_order_payments
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION vm_private.vm_order_payment_complete();

CREATE FUNCTION vm_private.vm_order_consumption_complete()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.vm_orders o WHERE o.organization_id=NEW.organization_id AND o.id=NEW.order_id AND o.consumed_at=NEW.consumed_at)
     OR EXISTS (
       SELECT 1 FROM (
         SELECT s.material_id,min(s.unit) AS unit,count(DISTINCT s.unit) AS unit_count,sum(s.consumption_quantity) AS quantity
         FROM public.vm_order_item_materials s WHERE s.organization_id=NEW.organization_id AND s.order_id=NEW.order_id GROUP BY s.material_id
       ) expected FULL JOIN (
         SELECT c.material_id,c.unit,c.quantity,m.quantity_delta,m.movement_type FROM public.vm_order_consumptions c
         JOIN public.vm_stock_movements m ON m.organization_id=c.organization_id AND m.id=c.movement_id
         WHERE c.organization_id=NEW.organization_id AND c.order_id=NEW.order_id
       ) actual ON actual.material_id=expected.material_id
       WHERE expected.material_id IS NULL OR actual.material_id IS NULL OR expected.unit_count<>1
         OR expected.quantity IS DISTINCT FROM actual.quantity OR expected.unit IS DISTINCT FROM actual.unit
         OR actual.quantity_delta IS DISTINCT FROM -expected.quantity OR actual.movement_type<>'order_deduction'
     ) THEN RAISE EXCEPTION 'Baixa incompleta ou divergente dos snapshots' USING ERRCODE='23514'; END IF;
  RETURN NULL;
END;
$function$;
CREATE CONSTRAINT TRIGGER vm_order_consumption_complete AFTER INSERT ON public.vm_order_consumption_runs
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION vm_private.vm_order_consumption_complete();

CREATE VIEW public.vm_orders_read WITH(security_invoker=true) AS
SELECT o.id,o.organization_id,o.code,o.client_id,c.name AS client_name,o.client_name_snapshot,o.title,o.status,o.status_version::text AS status_version,
  o.order_date,o.production_date,o.delivery_date,o.responsible_membership_id,o.public_notes,o.internal_notes,
  o.subtotal::text AS subtotal,o.discount_type,o.discount_value::text AS discount_value,o.discount_amount::text AS discount_amount,
  o.shipping_amount::text AS shipping_amount,o.total_amount::text AS total_amount,
  COALESCE(p.paid_amount,0)::numeric(20,2)::text AS paid_amount,(o.total_amount-COALESCE(p.paid_amount,0))::numeric(20,2)::text AS balance_amount,
  o.currency,(o.consumed_at IS NOT NULL) AS inventory_deducted,o.consumed_at,
  (SELECT count(*)::text FROM public.vm_order_items i WHERE i.organization_id=o.organization_id AND i.order_id=o.id) AS item_count,
  o.created_by,o.created_at,o.updated_at
FROM public.vm_orders o JOIN public.vm_clients c ON c.organization_id=o.organization_id AND c.id=o.client_id
LEFT JOIN LATERAL (SELECT sum(p.amount) AS paid_amount FROM public.vm_order_payments p WHERE p.organization_id=o.organization_id AND p.order_id=o.id) p ON true;

CREATE VIEW public.vm_order_items_read WITH(security_invoker=true) AS
SELECT i.id,i.organization_id,i.order_id,i.position::text AS position,i.kind,i.product_id,i.product_version::text AS product_version,
  i.variant_id,i.variant_version::text AS variant_version,i.title,i.quantity::text AS quantity,i.billing_unit,i.dimensions,
  i.dimensions_factor::text AS dimensions_factor,i.billed_quantity::text AS billed_quantity,i.unit_price::text AS unit_price,
  i.price_source,i.price_override_reason,i.line_amount_raw::text AS line_amount_raw,i.line_amount::text AS line_amount,
  i.recipe_mode,i.unit_composition_cost::text AS unit_composition_cost,i.total_composition_cost::text AS total_composition_cost,
  i.product_snapshot,i.price_snapshot,
  COALESCE((SELECT jsonb_agg(jsonb_build_object('material_id',s.material_id,'material_name',s.material_name_snapshot,
    'quantitySnapshot',s.quantity_snapshot::text,'unit',s.unit,'unit_cost_snapshot',s.unit_cost_snapshot::text,
    'consumption_quantity',s.consumption_quantity::text,'consumption_cost',s.consumption_cost::text) ORDER BY s.material_id)
    FROM public.vm_order_item_materials s WHERE s.organization_id=i.organization_id AND s.order_id=i.order_id AND s.item_id=i.id),'[]'::jsonb) AS recipe_snapshot,
  i.details,i.personalization,i.production_date,i.delivery_date,i.created_at
FROM public.vm_order_items i;

CREATE VIEW public.vm_order_consumptions_read WITH(security_invoker=true) AS
SELECT c.organization_id,c.order_id,c.material_id,c.unit,c.quantity::text AS quantity,c.movement_id,m.stock_after::text AS stock_after,c.created_at
FROM public.vm_order_consumptions c JOIN public.vm_stock_movements m ON m.organization_id=c.organization_id AND m.id=c.movement_id;

CREATE VIEW public.vm_order_payments_read WITH(security_invoker=true) AS
SELECT p.id,p.organization_id,p.order_id,p.amount::text AS amount,p.payment_date,p.method,p.currency,p.nonce,c.id AS cash_entry_id,p.created_by,p.created_at
FROM public.vm_order_payments p JOIN public.vm_cash_entries c ON c.organization_id=p.organization_id AND c.order_id=p.order_id AND c.order_payment_id=p.id;

-- Append-only extensions: preserve every existing view column's name/order/type.
CREATE OR REPLACE VIEW public.vm_clients_read WITH(security_invoker=true) AS
SELECT c.id,c.organization_id,c.name,c.email,c.phone,c.notes,c.person_type,c.tax_id,c.birth_date,c.address,c.archived_at,c.created_at,c.updated_at,
  (SELECT count(*)::text FROM public.vm_orders o WHERE o.organization_id=c.organization_id AND o.client_id=c.id) AS order_count,
  (SELECT count(*)::text FROM public.vm_orders o WHERE o.organization_id=c.organization_id AND o.client_id=c.id AND o.status IN ('Pendente','Em Produção','Concluído')) AS open_order_count
FROM public.vm_clients c;

CREATE OR REPLACE VIEW public.vm_stock_movements_read WITH(security_invoker=true) AS
SELECT sm.id,sm.organization_id,sm.material_id,sm.movement_type,sm.quantity_delta::text AS quantity_delta,sm.stock_after::text AS stock_after,
  sm.package_cost::text AS package_cost,sm.package_quantity::text AS package_quantity,sm.note,sm.purchase_id,sm.idempotency_key,sm.created_by,sm.created_at,sm.order_id
FROM public.vm_stock_movements sm;

CREATE OR REPLACE VIEW public.vm_cash_entries_read WITH(security_invoker=true) AS
SELECT ce.id,ce.organization_id,ce.entry_type,ce.amount::text AS amount,ce.entry_date,ce.description,ce.payment_status,ce.paid_at,
  ce.material_purchase_id,ce.supplier_id,ce.created_by,ce.created_at,ce.order_id,ce.order_payment_id,ce.payment_method
FROM public.vm_cash_entries ce;

DO $rls$
DECLARE v_table text;
BEGIN
  FOREACH v_table IN ARRAY ARRAY['vm_orders','vm_order_items','vm_order_item_materials','vm_order_consumption_runs','vm_order_consumptions','vm_order_events','vm_order_payments'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',v_table);
    EXECUTE format('CREATE POLICY vm_orders_member_select ON public.%I FOR SELECT TO authenticated USING ((SELECT vm_private.vm_is_member(organization_id)))',v_table);
    EXECUTE format('REVOKE ALL ON TABLE public.%I FROM PUBLIC,anon,authenticated',v_table);
    EXECUTE format('GRANT SELECT ON TABLE public.%I TO authenticated',v_table);
  END LOOP;
END;
$rls$;
ALTER TABLE public.vm_notifications ENABLE ROW LEVEL SECURITY;
CREATE POLICY vm_notifications_own_member_select ON public.vm_notifications FOR SELECT TO authenticated
  USING(recipient_user_id=(SELECT auth.uid()) AND (SELECT vm_private.vm_is_member(organization_id)));
ALTER TABLE public.vm_notification_outbox ENABLE ROW LEVEL SECURITY;
ALTER TABLE vm_private.vm_order_client_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE vm_private.vm_order_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.vm_notifications,public.vm_notification_outbox,vm_private.vm_order_client_snapshots,vm_private.vm_order_requests FROM PUBLIC,anon,authenticated;
GRANT SELECT ON TABLE public.vm_notifications TO authenticated;
REVOKE ALL ON TABLE public.vm_orders_read,public.vm_order_items_read,public.vm_order_consumptions_read,public.vm_order_payments_read FROM PUBLIC,anon,authenticated;
GRANT SELECT ON TABLE public.vm_orders_read,public.vm_order_items_read,public.vm_order_consumptions_read,public.vm_order_payments_read TO authenticated;
-- Existing read views retain authenticated SELECT; explicitly deny anon/public.
REVOKE ALL ON TABLE public.vm_clients_read,public.vm_stock_movements_read,public.vm_cash_entries_read FROM PUBLIC,anon;

REVOKE ALL ON FUNCTION
  vm_private.vm_order_number(numeric,integer,numeric,boolean),vm_private.vm_order_keys(jsonb,text[]),
  vm_private.vm_order_json_number(jsonb,text,boolean),vm_private.vm_order_json_date(jsonb,text,boolean),
  vm_private.vm_order_guard(),vm_private.vm_notification_guard(),vm_private.vm_outbox_guard(),vm_private.vm_order_cash_guard(),
  vm_private.vm_order_canonical(jsonb,jsonb),vm_private.vm_order_resolve_item(uuid,jsonb),
  vm_private.vm_order_consume(uuid,uuid,uuid),vm_private.vm_order_apply_status(uuid,uuid,text,text,uuid,boolean),
  vm_private.vm_order_build(uuid,jsonb,uuid),vm_private.vm_order_item_insert_guard(),
  vm_private.vm_order_payment_complete(),vm_private.vm_order_consumption_complete()
FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.vm_create_order(uuid,jsonb,jsonb,uuid),public.vm_set_order_status(uuid,uuid,text,text,uuid),
  public.vm_record_order_payment(uuid,uuid,numeric,date,text,uuid),public.vm_mark_notification_read(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.vm_create_order(uuid,jsonb,jsonb,uuid),public.vm_set_order_status(uuid,uuid,text,text,uuid),
  public.vm_record_order_payment(uuid,uuid,numeric,date,text,uuid),public.vm_mark_notification_read(uuid,uuid) TO authenticated;

-- Real Postgres Changes only for authorized operational records. Outbox and
-- private client/request tables are intentionally not explicitly published.
DO $publication$
DECLARE v_table text;
BEGIN
  IF EXISTS(SELECT 1 FROM pg_catalog.pg_publication WHERE pubname='supabase_realtime' AND puballtables) THEN RETURN; END IF;
  IF EXISTS(SELECT 1 FROM pg_catalog.pg_publication WHERE pubname='supabase_realtime') THEN
    FOREACH v_table IN ARRAY ARRAY['vm_orders','vm_order_events','vm_notifications','vm_order_payments'] LOOP
      IF NOT EXISTS(SELECT 1 FROM pg_catalog.pg_publication_tables WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename=v_table) THEN
        EXECUTE pg_catalog.format('ALTER PUBLICATION %I ADD TABLE public.%I','supabase_realtime',v_table);
      END IF;
    END LOOP;
  END IF;
END;
$publication$;

INSERT INTO public.vm_schema_migrations(version,description)
  VALUES('20261030002000_orders','Pedidos imutáveis, baixa única exata, pagamentos reais vinculados ao caixa, eventos/outbox, RLS e DTOs textuais')
  ON CONFLICT(version) DO NOTHING;
NOTIFY pgrst, 'reload schema';
COMMIT;
