BEGIN;

CREATE FUNCTION public.vm_list_quotes(
  p_organization_id uuid,
  p_cursor_created_at timestamptz DEFAULT NULL,
  p_cursor_quote_id uuid DEFAULT NULL,
  p_limit integer DEFAULT 40
)
RETURNS TABLE(
  quote_id uuid,
  public_token uuid,
  client_name_snapshot text,
  title text,
  status text,
  valid_until date,
  subtotal text,
  discount_amount text,
  shipping_amount text,
  total_amount text,
  currency text,
  accepted_order_id uuid,
  created_at timestamptz,
  revoked_at timestamptz,
  accepted_at timestamptz,
  parent_quote_id uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_actor uuid := auth.uid();
BEGIN
  IF v_actor IS NULL OR auth.role() IS DISTINCT FROM 'authenticated'
     OR NOT vm_private.vm_has_role(p_organization_id, ARRAY['owner','admin','finance']::text[]) THEN
    RAISE EXCEPTION 'Sem permissão para listar orçamentos nesta organização' USING ERRCODE = '42501';
  END IF;
  IF p_organization_id IS NULL OR p_limit IS NULL OR p_limit < 1 OR p_limit > 100
     OR ((p_cursor_created_at IS NULL) <> (p_cursor_quote_id IS NULL)) THEN
    RAISE EXCEPTION 'Cursor e limite inválidos' USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  SELECT q.id, q.public_token, q.client_name_snapshot, q.title, q.status, q.valid_until,
    q.subtotal::numeric(20,2)::text, q.discount_amount::numeric(20,2)::text,
    q.shipping_amount::numeric(20,2)::text, q.total_amount::numeric(20,2)::text,
    q.currency, q.accepted_order_id, q.created_at, q.revoked_at, q.accepted_at, q.parent_quote_id
  FROM public.vm_quotes AS q
  WHERE q.organization_id = p_organization_id
    AND (p_cursor_created_at IS NULL OR (q.created_at, q.id) < (p_cursor_created_at, p_cursor_quote_id))
  ORDER BY q.created_at DESC, q.id DESC
  LIMIT p_limit;
END;
$function$;

REVOKE ALL ON FUNCTION public.vm_list_quotes(uuid,timestamptz,uuid,integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.vm_list_quotes(uuid,timestamptz,uuid,integer) TO authenticated;

CREATE FUNCTION public.vm_get_quote_admin(p_organization_id uuid,p_quote_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_quote public.vm_quotes%ROWTYPE;
  v_data jsonb;
  v_items jsonb;
BEGIN
  IF auth.uid() IS NULL OR auth.role() IS DISTINCT FROM 'authenticated'
     OR NOT vm_private.vm_has_role(p_organization_id,ARRAY['owner','admin','finance']::text[]) THEN
    RAISE EXCEPTION 'Sem permissão para consultar orçamento nesta organização' USING ERRCODE = '42501';
  END IF;
  SELECT q.* INTO v_quote FROM public.vm_quotes q
  WHERE q.organization_id=p_organization_id AND q.id=p_quote_id;
  IF NOT FOUND THEN RETURN NULL; END IF;

  v_data := pg_catalog.jsonb_build_object(
    'client_id',v_quote.client_id,'title',v_quote.title,'order_date',v_quote.order_date,
    'production_date',v_quote.production_date,'delivery_date',v_quote.delivery_date,
    'responsible_membership_id',v_quote.responsible_membership_id,
    'public_notes',v_quote.public_notes,'internal_notes',v_quote.internal_notes,
    'discount_type',v_quote.discount_type,'discount_value',v_quote.discount_value::text,
    'shipping_amount',v_quote.shipping_amount::text
  );
  SELECT COALESCE(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'kind',i.kind,'product_id',i.product_id,'variant_id',i.variant_id,'title',i.title,
    'quantity',i.quantity::text,
    'unit_price',CASE WHEN i.price_source='catalog' THEN NULL ELSE i.unit_price::text END,
    'price_override',i.price_source IN ('override','manual'),
    'price_override_reason',i.price_override_reason,'dimensions',i.dimensions,
    'details',i.details,'personalization',i.personalization,
    'production_date',i.production_date,'delivery_date',i.delivery_date
  ) ORDER BY i.position),'[]'::jsonb) INTO v_items
  FROM public.vm_quote_items i
  WHERE i.organization_id=p_organization_id AND i.quote_id=p_quote_id;
  RETURN pg_catalog.jsonb_build_object(
    'quote_id',v_quote.id,'status',v_quote.status,'parent_quote_id',v_quote.parent_quote_id,
    'valid_until',v_quote.valid_until,'terms',v_quote.commercial_terms,
    'data',v_data,'items',v_items
  );
END;
$function$;
REVOKE ALL ON FUNCTION public.vm_get_quote_admin(uuid,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.vm_get_quote_admin(uuid,uuid) TO authenticated;

INSERT INTO public.vm_schema_migrations(version,description)
VALUES ('20261030003500_quote_admin_list','RPC administrativa paginada de orçamentos com projeção allowlist')
ON CONFLICT(version) DO NOTHING;
NOTIFY pgrst, 'reload schema';
COMMIT;
