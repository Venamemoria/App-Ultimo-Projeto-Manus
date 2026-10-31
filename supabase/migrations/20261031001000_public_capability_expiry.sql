BEGIN;
SET LOCAL lock_timeout = '5s';

-- Fail closed if any reviewed RPC has changed since the current migration
-- chain. CREATE OR REPLACE below preserves function ownership and ACLs.
DO $guard$
DECLARE r record; actual text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.vm_create_quote(uuid,jsonb,jsonb,date,text,uuid,uuid)','bb85c7e6edf8a3202407b470e2032930'),
    ('public.vm_approve_quote(uuid)','d269623ad6fc416f71daaf14e5c87618'),
    ('public.vm_get_quote(uuid)','a588483cc569750893e8dce46f969062'),
    ('public.vm_list_quotes(uuid,timestamp with time zone,uuid,integer)','ef993056f21d591341d875c1d1c0ba26')
  ) AS expected(signature,definition_hash) LOOP
    SELECT pg_catalog.md5(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(r.signature))) INTO actual;
    IF actual IS DISTINCT FROM r.definition_hash THEN
      RAISE EXCEPTION 'Reviewed public quote RPC differs: %', r.signature;
    END IF;
  END LOOP;
END;
$guard$;

-- A quote is valid through 23:59:59 in the agreed business timezone. The
-- caller's PostgreSQL session timezone cannot extend a public capability.
CREATE FUNCTION vm_private.vm_quote_business_date(p_at timestamptz)
RETURNS date LANGUAGE sql STABLE SET search_path = '' AS $function$
  SELECT pg_catalog.timezone('America/Sao_Paulo',p_at)::date
$function$;
REVOKE ALL ON FUNCTION vm_private.vm_quote_business_date(timestamptz) FROM PUBLIC,anon,authenticated;

-- Issuance and the admin list use the same date boundary as the public RPCs.
DO $patch$
DECLARE v_def text; old_text text; new_text text;
BEGIN
  v_def:=pg_catalog.pg_get_functiondef('public.vm_create_quote(uuid,jsonb,jsonb,date,text,uuid,uuid)'::regprocedure);
  old_text:='p_valid_until < CURRENT_DATE';
  new_text:='p_valid_until < vm_private.vm_quote_business_date(pg_catalog.clock_timestamp())';
  IF (length(v_def)-length(replace(v_def,old_text,'')))/length(old_text)<>1 THEN RAISE EXCEPTION 'Unexpected create-quote validity check'; END IF;
  v_def:=replace(v_def,old_text,new_text);
  -- Issuance may wait for tenant/product locks across midnight; check again
  -- immediately before inserting any quote or revoking its parent.
  old_text:='v_now := pg_catalog.clock_timestamp();';
  new_text:='v_now := pg_catalog.clock_timestamp(); IF p_valid_until < vm_private.vm_quote_business_date(v_now) THEN RAISE EXCEPTION ''Validade do orçamento inválida'' USING ERRCODE = ''22023''; END IF;';
  IF (length(v_def)-length(replace(v_def,old_text,'')))/length(old_text)<>1 THEN RAISE EXCEPTION 'Unexpected create-quote insertion point'; END IF;
  EXECUTE replace(v_def,old_text,new_text);

  v_def:=pg_catalog.pg_get_functiondef('public.vm_list_quotes(uuid,timestamp with time zone,uuid,integer)'::regprocedure);
  old_text:='SELECT q.id, q.public_token, q.client_name_snapshot, q.title, q.status, q.valid_until,';
  new_text:='SELECT q.id, q.public_token, q.client_name_snapshot, q.title, CASE WHEN q.status = ''Sent'' AND q.valid_until < vm_private.vm_quote_business_date(pg_catalog.clock_timestamp()) THEN ''Expired'' ELSE q.status END, q.valid_until,';
  IF (length(v_def)-length(replace(v_def,old_text,'')))/length(old_text)<>1 THEN RAISE EXCEPTION 'Unexpected quote-list projection'; END IF;
  EXECUTE replace(v_def,old_text,new_text);
END;
$patch$;

-- Unknown, expired and revoked quote capabilities all return NULL. No
-- commercial snapshot is returned merely to say why a capability failed.
CREATE OR REPLACE FUNCTION public.vm_get_quote(p_token uuid)
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
    'status',q.status,'accepted_at',q.accepted_at,
    'tracking_available',CASE WHEN q.status='Approved' THEN EXISTS (
      SELECT 1 FROM vm_private.vm_quote_acceptances a
      JOIN public.vm_tracking_capabilities t ON t.organization_id=a.organization_id AND t.id=a.tracking_id AND t.order_id=a.order_id
      WHERE a.organization_id=q.organization_id AND a.quote_id=q.id AND q.accepted_order_id=a.order_id
        AND t.revoked_at IS NULL AND t.expires_at>pg_catalog.clock_timestamp()
    ) ELSE false END
  ) INTO v_result
  FROM public.vm_quotes q JOIN public.vm_organizations o ON o.id=q.organization_id
  WHERE q.public_token=p_token AND q.revoked_at IS NULL AND q.status IN ('Sent','Approved')
    AND q.valid_until>=vm_private.vm_quote_business_date(pg_catalog.clock_timestamp())
  FOR SHARE OF q;
  -- Re-evaluate after any lock wait and projection work across midnight.
  IF v_result IS NOT NULL AND (v_result->>'valid_until')::date<vm_private.vm_quote_business_date(pg_catalog.clock_timestamp()) THEN
    RETURN NULL;
  END IF;
  RETURN v_result;
END;
$function$;

-- A replay remains idempotent only while both the quote and its ORIGINAL
-- tracking capability are valid. Revocation must not disclose an old token or
-- automatically grant a replacement; an administrator can issue a new link.
CREATE OR REPLACE FUNCTION public.vm_approve_quote(p_token uuid)
RETURNS TABLE(order_id uuid,tracking_token uuid,tracking_expires_at timestamptz,status text,accepted_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE v_quote public.vm_quotes%ROWTYPE; v_accept vm_private.vm_quote_acceptances%ROWTYPE; v_order_result jsonb; v_cap public.vm_tracking_capabilities%ROWTYPE;
  v_result jsonb; v_time timestamptz; v_event_id uuid; v_order uuid; v_expiry timestamptz;
BEGIN
  IF p_token IS NULL THEN RAISE EXCEPTION 'Orçamento inválido ou indisponível' USING ERRCODE = '22023'; END IF;
  SELECT q.* INTO v_quote FROM public.vm_quotes q WHERE q.public_token=p_token FOR UPDATE;
  IF NOT FOUND OR v_quote.revoked_at IS NOT NULL OR v_quote.status NOT IN ('Sent','Approved')
     OR v_quote.valid_until<vm_private.vm_quote_business_date(pg_catalog.clock_timestamp()) THEN
    RAISE EXCEPTION 'Orçamento inválido ou indisponível' USING ERRCODE = '22023';
  END IF;
  SELECT a.* INTO v_accept FROM vm_private.vm_quote_acceptances a WHERE a.organization_id=v_quote.organization_id AND a.quote_id=v_quote.id;
  IF FOUND THEN
    IF v_quote.status<>'Approved' OR v_quote.accepted_order_id IS DISTINCT FROM v_accept.order_id THEN
      RAISE EXCEPTION 'Orçamento inválido ou indisponível' USING ERRCODE = '22023';
    END IF;
    SELECT t.* INTO v_cap FROM public.vm_tracking_capabilities t
      WHERE t.organization_id=v_accept.organization_id AND t.id=v_accept.tracking_id AND t.order_id=v_accept.order_id
        AND t.revoked_at IS NULL AND t.expires_at>pg_catalog.clock_timestamp() FOR SHARE;
    -- A concurrent revocation may have held the tracking row lock until after
    -- either deadline. Recheck with the real clock after acquiring that lock.
    IF NOT FOUND OR v_cap.expires_at<=pg_catalog.clock_timestamp()
       OR v_quote.valid_until<vm_private.vm_quote_business_date(pg_catalog.clock_timestamp()) THEN
      RAISE EXCEPTION 'Orçamento inválido ou indisponível' USING ERRCODE = '22023';
    END IF;
    RETURN QUERY SELECT v_accept.order_id,v_cap.token,v_cap.expires_at,'Approved'::text,v_accept.accepted_at;
    RETURN;
  END IF;
  IF v_quote.status<>'Sent' THEN RAISE EXCEPTION 'Orçamento inválido ou indisponível' USING ERRCODE = '22023'; END IF;
  v_time := pg_catalog.clock_timestamp();
  v_order_result := vm_private.vm_quote_build_order(v_quote.organization_id,v_quote.id);
  v_order := (v_order_result->>'order_id')::uuid;
  -- If resolution waited across the business-day boundary, the exception
  -- rolls back the new order and every side effect of the attempt.
  IF v_quote.valid_until<vm_private.vm_quote_business_date(pg_catalog.clock_timestamp()) THEN
    RAISE EXCEPTION 'Orçamento inválido ou indisponível' USING ERRCODE = '22023';
  END IF;
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

INSERT INTO public.vm_schema_migrations(version,description)
VALUES('20261031001000_public_capability_expiry','Bloqueio de orçamento expirado ou revogado e reprise segura do rastreio') ON CONFLICT(version) DO NOTHING;
NOTIFY pgrst,'reload schema';
COMMIT;
