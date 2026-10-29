BEGIN;

-- Physical returns are a separate append-only inventory flow.  They never
-- mutate order consumption, purchase/cost snapshots, payment rows or status.
ALTER TABLE vm_private.vm_order_requests
  DROP CONSTRAINT vm_order_requests_operation_check,
  ADD CONSTRAINT vm_order_requests_operation_check
    CHECK (operation IN ('create','status','payment','order_return'));

-- The four-column identity makes a return line point to the exact immutable
-- consumption row, not merely to a material that happened to exist in the
-- order.  Existing rows satisfy this constraint; no historical row is edited.
ALTER TABLE public.vm_order_consumptions
  ADD CONSTRAINT vm_order_consumptions_return_identity_uq
    UNIQUE (organization_id,order_id,material_id,movement_id);

CREATE TABLE public.vm_order_return_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
  order_id uuid NOT NULL,
  status text NOT NULL DEFAULT 'Cancelado' CHECK (status='Cancelado'),
  reason text NOT NULL CHECK (btrim(reason)<>'' AND char_length(reason)<=2000),
  idempotency_key uuid NOT NULL,
  payload jsonb NOT NULL CHECK (jsonb_typeof(payload)='object'),
  line_count integer NOT NULL CHECK (line_count>0 AND line_count<=200),
  returned_quantity numeric(20,8) NOT NULL
    CHECK (returned_quantity>0 AND vm_private.vm_numeric_valid(returned_quantity,8,999999999999.99999999,true)),
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id,id),
  UNIQUE (organization_id,idempotency_key),
  UNIQUE (organization_id,id,order_id),
  FOREIGN KEY (organization_id,order_id) REFERENCES public.vm_orders(organization_id,id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,created_by) REFERENCES public.vm_memberships(organization_id,user_id) ON DELETE RESTRICT
);

CREATE TABLE public.vm_order_return_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
  return_event_id uuid NOT NULL,
  order_id uuid NOT NULL,
  material_id uuid NOT NULL,
  material_name_snapshot text NOT NULL CHECK (btrim(material_name_snapshot)<>'' AND char_length(material_name_snapshot)<=200),
  unit text NOT NULL CHECK (btrim(unit)<>'' AND char_length(unit)<=40),
  source_consumption_movement_id uuid NOT NULL,
  quantity numeric(20,8) NOT NULL
    CHECK (quantity>0 AND vm_private.vm_numeric_valid(quantity,8,999999999999.99999999,true)),
  stock_movement_id uuid NOT NULL,
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id,id),
  UNIQUE (organization_id,return_event_id,material_id),
  FOREIGN KEY (organization_id,return_event_id,order_id)
    REFERENCES public.vm_order_return_events(organization_id,id,order_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,order_id,material_id,source_consumption_movement_id)
    REFERENCES public.vm_order_consumptions(organization_id,order_id,material_id,movement_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,stock_movement_id)
    REFERENCES public.vm_stock_movements(organization_id,id) DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (organization_id,created_by) REFERENCES public.vm_memberships(organization_id,user_id) ON DELETE RESTRICT
);
CREATE INDEX vm_order_return_events_order_idx
  ON public.vm_order_return_events(organization_id,order_id,created_at,id);
CREATE INDEX vm_order_return_lines_order_material_idx
  ON public.vm_order_return_lines(organization_id,order_id,material_id,created_at,id);

-- The stock ledger already has opening/receipt/adjustment/order_deduction.
-- Extend that check without rewriting any existing movement.  A return is a
-- positive stock movement with an order and exactly one immutable return line.
ALTER TABLE public.vm_stock_movements
  ADD COLUMN return_line_id uuid,
  DROP CONSTRAINT vm_stock_movements_movement_type_check,
  DROP CONSTRAINT vm_stock_movements_delta_type_ck,
  DROP CONSTRAINT vm_stock_movements_order_type_ck,
  ADD CONSTRAINT vm_stock_movements_movement_type_check
    CHECK (movement_type IN ('opening','receipt','adjustment','order_deduction','order_return')),
  ADD CONSTRAINT vm_stock_movements_delta_type_ck CHECK(
    (movement_type IN ('opening','receipt') AND quantity_delta>0)
    OR (movement_type='adjustment' AND quantity_delta<>0)
    OR (movement_type='order_deduction' AND quantity_delta<0)
    OR (movement_type='order_return' AND quantity_delta>0)),
  ADD CONSTRAINT vm_stock_movements_order_type_ck CHECK(
    (order_id IS NULL AND movement_type IN ('opening','receipt','adjustment') AND return_line_id IS NULL)
    OR (order_id IS NOT NULL AND movement_type IN ('order_deduction','order_return') AND purchase_id IS NULL)),
  ADD CONSTRAINT vm_stock_movements_return_type_ck CHECK(
    (return_line_id IS NULL AND movement_type<>'order_return')
    OR (return_line_id IS NOT NULL AND movement_type='order_return')),
  ADD CONSTRAINT vm_stock_movements_return_line_fk
    FOREIGN KEY (organization_id,return_line_id)
    REFERENCES public.vm_order_return_lines(organization_id,id)
    DEFERRABLE INITIALLY DEFERRED;
CREATE UNIQUE INDEX vm_stock_movements_return_line_uq
  ON public.vm_stock_movements(organization_id,return_line_id)
  WHERE return_line_id IS NOT NULL;

CREATE FUNCTION vm_private.vm_order_return_canonical(p_returns jsonb)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $function$
DECLARE
  v_entry jsonb;
  v_id uuid;
  v_quantity numeric;
  v_type text;
  v_result jsonb := '[]'::jsonb;
  v_ids uuid[] := ARRAY[]::uuid[];
BEGIN
  IF p_returns IS NULL OR pg_catalog.jsonb_typeof(p_returns)<>'array'
     OR pg_catalog.jsonb_array_length(p_returns) NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION 'p_returns deve ser array não vazio de até 200 linhas' USING ERRCODE='22023';
  END IF;
  FOR v_entry IN SELECT value FROM pg_catalog.jsonb_array_elements(p_returns) LOOP
    PERFORM vm_private.vm_order_keys(v_entry,ARRAY['material_id','quantity']);
    IF v_entry->>'material_id' IS NULL OR pg_catalog.jsonb_typeof(v_entry->'quantity') NOT IN ('string','number') THEN
      RAISE EXCEPTION 'Cada devolução exige material_id e quantity' USING ERRCODE='22023';
    END IF;
    BEGIN
      v_id := (v_entry->>'material_id')::uuid;
    EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
      RAISE EXCEPTION 'material_id inválido na devolução' USING ERRCODE='22023';
    END;
    BEGIN
      v_quantity := (v_entry->>'quantity')::numeric;
    EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
      RAISE EXCEPTION 'quantity inválida na devolução' USING ERRCODE='22023';
    END;
    PERFORM vm_private.vm_order_number(v_quantity,8,999999999999.99999999,true);
    IF v_id = ANY(v_ids) THEN
      RAISE EXCEPTION 'Cada material pode aparecer uma única vez em p_returns' USING ERRCODE='22023';
    END IF;
    v_ids := array_append(v_ids,v_id);
    v_result := v_result || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('material_id',v_id,'quantity',pg_catalog.trim_scale(v_quantity)::text));
  END LOOP;
  RETURN v_result;
END;
$function$;

CREATE FUNCTION vm_private.vm_order_return_complete()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE
  v_event public.vm_order_return_events%ROWTYPE;
  v_line_count integer;
  v_returned numeric;
  v_bad integer;
BEGIN
  SELECT e.* INTO v_event
  FROM public.vm_order_return_events e
  WHERE e.organization_id=NEW.organization_id AND e.id=NEW.id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Evento de devolução não encontrado' USING ERRCODE='23514';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.vm_orders o
    WHERE o.organization_id=v_event.organization_id AND o.id=v_event.order_id
      AND o.status='Cancelado' AND o.consumed_at IS NOT NULL
      AND EXISTS (SELECT 1 FROM public.vm_order_consumption_runs r
                  WHERE r.organization_id=o.organization_id AND r.order_id=o.id
                    AND r.consumed_at=o.consumed_at)
  ) THEN
    RAISE EXCEPTION 'Devolução exige pedido cancelado com execução de consumo' USING ERRCODE='23514';
  END IF;
  SELECT count(*)::integer,COALESCE(sum(l.quantity),0)
    INTO v_line_count,v_returned
  FROM public.vm_order_return_lines l
  WHERE l.organization_id=v_event.organization_id AND l.return_event_id=v_event.id;
  IF v_line_count<>v_event.line_count OR v_line_count=0 OR v_returned IS DISTINCT FROM v_event.returned_quantity THEN
    RAISE EXCEPTION 'Evento de devolução sem linhas ou total divergente' USING ERRCODE='23514';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM (
      SELECT l.material_id,sum(l.quantity) AS returned,c.quantity AS consumed
      FROM public.vm_order_return_lines l
      JOIN public.vm_order_consumptions c
        ON c.organization_id=l.organization_id AND c.order_id=l.order_id
       AND c.material_id=l.material_id AND c.movement_id=l.source_consumption_movement_id
      WHERE l.organization_id=v_event.organization_id AND l.order_id=v_event.order_id
      GROUP BY l.material_id,c.quantity
    ) x
    WHERE x.returned>x.consumed
  ) THEN
    RAISE EXCEPTION 'Devoluções excedem o consumo original' USING ERRCODE='23514';
  END IF;
  SELECT count(*) INTO v_bad
  FROM public.vm_order_return_lines l
  LEFT JOIN public.vm_stock_movements m
    ON m.organization_id=l.organization_id AND m.id=l.stock_movement_id
  WHERE l.organization_id=v_event.organization_id AND l.return_event_id=v_event.id
    AND (m.id IS NULL OR m.return_line_id IS DISTINCT FROM l.id OR m.order_id<>l.order_id
      OR m.material_id<>l.material_id OR m.movement_type<>'order_return'
      OR m.quantity_delta IS DISTINCT FROM l.quantity OR m.created_by IS DISTINCT FROM l.created_by);
  IF v_bad<>0 THEN
    RAISE EXCEPTION 'Movimento de devolução não corresponde à linha auditada' USING ERRCODE='23514';
  END IF;
  RETURN NULL;
END;
$function$;

-- Header and lines are append-only ledgers.  The deferred event check above
-- validates the complete event after both sides of the stock link exist.
CREATE TRIGGER vm_order_return_events_append_only
  BEFORE UPDATE OR DELETE ON public.vm_order_return_events
  FOR EACH ROW EXECUTE FUNCTION vm_private.vm_reject_immutable_row();
CREATE TRIGGER vm_order_return_lines_append_only
  BEFORE UPDATE OR DELETE ON public.vm_order_return_lines
  FOR EACH ROW EXECUTE FUNCTION vm_private.vm_reject_immutable_row();
CREATE CONSTRAINT TRIGGER vm_order_return_event_complete
  AFTER INSERT ON public.vm_order_return_events
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
  EXECUTE FUNCTION vm_private.vm_order_return_complete();

CREATE FUNCTION public.vm_record_order_return(
  p_organization_id uuid,
  p_order_id uuid,
  p_reason text,
  p_returns jsonb,
  p_idempotency_key uuid
)
RETURNS TABLE(
  return_id uuid,
  order_id uuid,
  status text,
  line_count text,
  returned_quantity text,
  remaining_quantity text
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE
  v_actor uuid := auth.uid();
  v_reason text := NULLIF(pg_catalog.btrim(p_reason),'');
  v_returns jsonb;
  v_payload jsonb;
  v_request vm_private.vm_order_requests%ROWTYPE;
  v_result jsonb;
  v_order public.vm_orders%ROWTYPE;
  v_item jsonb;
  v_material_id uuid;
  v_requested numeric;
  v_original numeric;
  v_already numeric;
  v_total numeric := 0;
  v_remaining numeric := 0;
  v_line_count integer := 0;
  v_new_stock numeric;
  v_consumption_movement uuid;
  v_stock public.vm_materials%ROWTYPE;
  v_line_id uuid;
  v_movement_id uuid;
  v_event_id uuid;
BEGIN
  IF v_actor IS NULL OR auth.role() IS DISTINCT FROM 'authenticated'
     OR NOT vm_private.vm_has_role(p_organization_id,ARRAY['owner','admin']) THEN
    RAISE EXCEPTION 'Devolução física exige owner/admin autenticado nesta organização' USING ERRCODE='42501';
  END IF;
  IF p_organization_id IS NULL OR p_order_id IS NULL OR p_idempotency_key IS NULL
     OR v_reason IS NULL OR pg_catalog.char_length(v_reason)>2000 THEN
    RAISE EXCEPTION 'Pedido, chave e motivo da devolução são obrigatórios' USING ERRCODE='22023';
  END IF;
  v_returns := vm_private.vm_order_return_canonical(p_returns);
  v_payload := pg_catalog.jsonb_build_object(
    'order_id',p_order_id,'reason',v_reason,'returns',v_returns);

  -- The organization lock serializes return, consumption and inventory writes in
  -- the tenant.  Replays stop here and return the durable original result.
  PERFORM 1 FROM public.vm_organizations o WHERE o.id=p_organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Organização não encontrada' USING ERRCODE='23503'; END IF;
  SELECT r.* INTO v_request
  FROM vm_private.vm_order_requests r
  WHERE r.organization_id=p_organization_id AND r.idempotency_key=p_idempotency_key;
  IF FOUND THEN
    IF v_request.operation<>'order_return' OR v_request.payload IS DISTINCT FROM v_payload THEN
      RAISE EXCEPTION 'Chave reutilizada com operação/payload diferente' USING ERRCODE='23505';
    END IF;
    v_result := v_request.result;
    RETURN QUERY SELECT (v_result->>'return_id')::uuid,(v_result->>'order_id')::uuid,
      v_result->>'status',v_result->>'line_count',v_result->>'returned_quantity',v_result->>'remaining_quantity';
    RETURN;
  END IF;

  SELECT o.* INTO v_order
  FROM public.vm_orders o
  WHERE o.organization_id=p_organization_id AND o.id=p_order_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pedido não encontrado nesta organização' USING ERRCODE='23503'; END IF;
  IF v_order.status<>'Cancelado' THEN
    RAISE EXCEPTION 'Devolução física só aceita pedido Cancelado' USING ERRCODE='22023';
  END IF;
  IF v_order.consumed_at IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.vm_order_consumption_runs r
    WHERE r.organization_id=p_organization_id AND r.order_id=p_order_id
      AND r.consumed_at=v_order.consumed_at
  ) THEN
    RAISE EXCEPTION 'Pedido cancelado antes da baixa não possui consumo para devolver' USING ERRCODE='23514';
  END IF;

  -- First pass locks every material in UUID order and validates the complete
  -- request.  No stock quantity is increased in this pass.
  FOR v_item IN
    SELECT value FROM pg_catalog.jsonb_array_elements(v_returns) value
    ORDER BY (value->>'material_id')::uuid
  LOOP
    v_material_id := (v_item->>'material_id')::uuid;
    v_requested := (v_item->>'quantity')::numeric;
    SELECT c.quantity,c.movement_id
      INTO v_original,v_consumption_movement
    FROM public.vm_order_consumptions c
    WHERE c.organization_id=p_organization_id AND c.order_id=p_order_id AND c.material_id=v_material_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Material não foi consumido por este pedido' USING ERRCODE='23503';
    END IF;
    SELECT m.* INTO v_stock
    FROM public.vm_materials m
    WHERE m.organization_id=p_organization_id AND m.id=v_material_id
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Material do consumo não existe nesta organização' USING ERRCODE='23503';
    END IF;
    SELECT COALESCE(sum(l.quantity),0) INTO v_already
    FROM public.vm_order_return_lines l
    JOIN public.vm_order_return_events e
      ON e.organization_id=l.organization_id AND e.id=l.return_event_id
    WHERE l.organization_id=p_organization_id AND l.order_id=p_order_id AND l.material_id=v_material_id;
    IF v_already+v_requested>v_original THEN
      RAISE EXCEPTION 'Quantidade devolvida excede o consumo original do material' USING ERRCODE='23514';
    END IF;
    v_new_stock := v_stock.stock_quantity+v_requested;
    PERFORM vm_private.vm_order_number(v_new_stock,8,999999999999.99999999,false);
    v_total := v_total+v_requested;
    v_remaining := v_remaining+(v_original-v_already-v_requested);
    v_line_count := v_line_count+1;
  END LOOP;

  INSERT INTO public.vm_order_return_events(
    organization_id,order_id,status,reason,idempotency_key,payload,line_count,returned_quantity,created_by)
  VALUES(
    p_organization_id,p_order_id,'Cancelado',v_reason,p_idempotency_key,v_payload,v_line_count,
    v_total,v_actor)
  RETURNING id INTO v_event_id;

  -- Second pass applies the already validated positive physical quantities.
  -- Package cost/quantity and the original consumption row are only copied as
  -- audit context; no purchase, cost, version or consumption flag is changed.
  FOR v_item IN SELECT value FROM pg_catalog.jsonb_array_elements(v_returns) value LOOP
    v_material_id := (v_item->>'material_id')::uuid;
    v_requested := (v_item->>'quantity')::numeric;
    SELECT c.movement_id INTO v_consumption_movement
    FROM public.vm_order_consumptions c
    WHERE c.organization_id=p_organization_id AND c.order_id=p_order_id AND c.material_id=v_material_id;
    SELECT m.* INTO v_stock
    FROM public.vm_materials m
    WHERE m.organization_id=p_organization_id AND m.id=v_material_id
    FOR UPDATE;
    v_line_id := pg_catalog.gen_random_uuid();
    v_movement_id := pg_catalog.gen_random_uuid();
    UPDATE public.vm_materials m
    SET stock_quantity=m.stock_quantity+v_requested
    WHERE m.organization_id=p_organization_id AND m.id=v_material_id
    RETURNING m.stock_quantity INTO v_new_stock;
    INSERT INTO public.vm_order_return_lines(
      id,organization_id,return_event_id,order_id,material_id,material_name_snapshot,unit,
      source_consumption_movement_id,quantity,stock_movement_id,created_by)
    VALUES(
      v_line_id,p_organization_id,v_event_id,p_order_id,v_material_id,v_stock.name,v_stock.unit,
      v_consumption_movement,v_requested,v_movement_id,v_actor);
    INSERT INTO public.vm_stock_movements(
      id,organization_id,material_id,movement_type,quantity_delta,stock_after,package_cost,package_quantity,
      note,order_id,return_line_id,created_by)
    VALUES(
      v_movement_id,p_organization_id,v_material_id,'order_return',v_requested,v_new_stock,
      v_stock.package_cost,v_stock.package_quantity,'Devolução física do pedido',p_order_id,v_line_id,v_actor);
  END LOOP;

  v_result := pg_catalog.jsonb_build_object(
    'return_id',v_event_id,'order_id',p_order_id,'status','Cancelado',
    'line_count',v_line_count::text,
    'returned_quantity',(v_total::numeric(20,8))::text,
    'remaining_quantity',(v_remaining::numeric(40,8))::text);
  INSERT INTO vm_private.vm_order_requests(
    organization_id,idempotency_key,operation,order_id,payload,result,created_by)
  VALUES(p_organization_id,p_idempotency_key,'order_return',p_order_id,v_payload,v_result,v_actor);
  RETURN QUERY SELECT v_event_id,p_order_id,'Cancelado',v_line_count::text,
    (v_total::numeric(20,8))::text,(v_remaining::numeric(40,8))::text;
END;
$function$;

CREATE VIEW public.vm_order_returns_read WITH (security_invoker=true) AS
SELECT
  e.id AS return_id,
  e.organization_id,
  e.order_id,
  e.status,
  e.reason,
  e.idempotency_key,
  e.line_count::text AS return_line_count,
  e.returned_quantity::text AS event_returned_quantity,
  e.created_by,
  e.created_at,
  l.id AS return_line_id,
  l.material_id,
  l.material_name_snapshot AS material_name,
  l.unit,
  c.quantity::text AS original_consumed_quantity,
  l.quantity::text AS returned_quantity,
  (SELECT COALESCE(sum(l2.quantity),0)::numeric(20,8)::text
   FROM public.vm_order_return_lines l2
   WHERE l2.organization_id=l.organization_id AND l2.order_id=l.order_id AND l2.material_id=l.material_id)
    AS returned_quantity_total,
  (c.quantity-(SELECT COALESCE(sum(l2.quantity),0)
   FROM public.vm_order_return_lines l2
   WHERE l2.organization_id=l.organization_id AND l2.order_id=l.order_id AND l2.material_id=l.material_id))::numeric(20,8)::text
    AS remaining_quantity,
  l.stock_movement_id,
  sm.stock_after::text AS stock_after,
  m.stock_quantity::text AS current_stock_quantity,
  l.created_by AS line_created_by,
  l.created_at AS line_created_at
FROM public.vm_order_return_events e
JOIN public.vm_order_return_lines l
  ON l.organization_id=e.organization_id AND l.return_event_id=e.id
JOIN public.vm_order_consumptions c
  ON c.organization_id=l.organization_id AND c.order_id=l.order_id
 AND c.material_id=l.material_id AND c.movement_id=l.source_consumption_movement_id
JOIN public.vm_stock_movements sm
  ON sm.organization_id=l.organization_id AND sm.id=l.stock_movement_id
JOIN public.vm_materials m
  ON m.organization_id=l.organization_id AND m.id=l.material_id;

-- Preserve all prior movement-read columns and append the return-line link.
CREATE OR REPLACE VIEW public.vm_stock_movements_read WITH(security_invoker=true) AS
SELECT sm.id,sm.organization_id,sm.material_id,sm.movement_type,sm.quantity_delta::text AS quantity_delta,
  sm.stock_after::text AS stock_after,sm.package_cost::text AS package_cost,sm.package_quantity::text AS package_quantity,
  sm.note,sm.purchase_id,sm.idempotency_key,sm.created_by,sm.created_at,sm.order_id,sm.return_line_id
FROM public.vm_stock_movements sm;

ALTER TABLE public.vm_order_return_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vm_order_return_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY vm_order_return_events_member_select ON public.vm_order_return_events
  FOR SELECT TO authenticated USING ((SELECT vm_private.vm_is_member(organization_id)));
CREATE POLICY vm_order_return_lines_member_select ON public.vm_order_return_lines
  FOR SELECT TO authenticated USING ((SELECT vm_private.vm_is_member(organization_id)));
REVOKE ALL ON TABLE public.vm_order_return_events,public.vm_order_return_lines FROM PUBLIC,anon,authenticated;
GRANT SELECT ON TABLE public.vm_order_return_events,public.vm_order_return_lines TO authenticated;
REVOKE ALL ON TABLE public.vm_order_returns_read FROM PUBLIC,anon,authenticated;
GRANT SELECT ON TABLE public.vm_order_returns_read TO authenticated;

REVOKE ALL ON FUNCTION vm_private.vm_order_return_canonical(jsonb),vm_private.vm_order_return_complete() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.vm_record_order_return(uuid,uuid,text,jsonb,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.vm_record_order_return(uuid,uuid,text,jsonb,uuid) TO authenticated;

INSERT INTO public.vm_schema_migrations(version,description)
VALUES('20261030002200_order_returns','Devolução física administrativa, ledger append-only, cap por consumo, estoque exato, RLS e RPC idempotente')
ON CONFLICT(version) DO NOTHING;
NOTIFY pgrst, 'reload schema';
COMMIT;
