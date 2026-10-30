BEGIN;

CREATE OR REPLACE FUNCTION public.vm_get_order_tracking(p_organization_id uuid,p_order_id uuid)
RETURNS TABLE(tracking_token uuid,expires_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
BEGIN
  IF auth.uid() IS NULL
     OR auth.role() IS DISTINCT FROM 'authenticated'
     OR NOT vm_private.vm_has_role(p_organization_id,ARRAY['owner','admin','finance']::text[]) THEN
    RAISE EXCEPTION 'Sem permissão para consultar rastreio nesta organização' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT t.token,t.expires_at
  FROM public.vm_tracking_capabilities t
  JOIN public.vm_orders o ON o.organization_id=t.organization_id AND o.id=t.order_id
  WHERE t.organization_id=p_organization_id AND t.order_id=p_order_id
    AND t.revoked_at IS NULL AND t.expires_at>pg_catalog.clock_timestamp();
END;
$function$;

CREATE OR REPLACE FUNCTION public.vm_get_tracking(p_token uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE v_result jsonb;
BEGIN
  IF p_token IS NULL THEN RETURN NULL; END IF;
  SELECT pg_catalog.jsonb_build_object(
    'brand',org.name,
    'code',o.code,
    'title',o.title,
    'status',o.status,
    'status_version',o.status_version::text,
    'order_date',o.order_date,
    'production_date',o.production_date,
    'delivery_date',o.delivery_date,
    'expires_at',t.expires_at,
    'history',COALESCE((
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'status',e.status,'status_version',e.status_version::text,'created_at',e.created_at
      ) ORDER BY e.status_version)
      FROM public.vm_order_events e
      WHERE e.organization_id=o.organization_id AND e.order_id=o.id
    ),'[]'::jsonb)
  ) INTO v_result
  FROM public.vm_tracking_capabilities t
  JOIN public.vm_orders o ON o.organization_id=t.organization_id AND o.id=t.order_id
  JOIN public.vm_organizations org ON org.id=t.organization_id
  WHERE t.token=p_token AND t.revoked_at IS NULL AND t.expires_at>pg_catalog.clock_timestamp();
  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.vm_get_order_tracking(uuid,uuid),public.vm_get_tracking(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.vm_get_tracking(uuid) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.vm_get_order_tracking(uuid,uuid) TO authenticated;

INSERT INTO public.vm_schema_migrations(version,description)
  VALUES('20261030004000_tracking_minimal_acl','Tracking mínimo: ACL por papel e projeção pública allowlist')
  ON CONFLICT(version) DO NOTHING;
NOTIFY pgrst, 'reload schema';
COMMIT;
