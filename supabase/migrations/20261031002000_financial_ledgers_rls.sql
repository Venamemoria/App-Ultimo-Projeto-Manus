BEGIN;
SET LOCAL lock_timeout='5s';

-- Reviewed baseline: preserve the view's identity, grants and invoker mode.
DO $guard$
DECLARE expected record;
BEGIN
  IF pg_catalog.md5(pg_catalog.pg_get_viewdef('public.vm_orders_read'::regclass,true))<>'77ba63c4085caa19785908e375c763d8' THEN
    RAISE EXCEPTION 'Reviewed order-read view differs';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_class WHERE oid='public.vm_orders_read'::regclass AND reloptions @> ARRAY['security_invoker=true']) THEN
    RAISE EXCEPTION 'Order-read view must remain security invoker';
  END IF;
  FOR expected IN SELECT * FROM (VALUES
    ('vm_cash_entries','vm_cash_entries_member_select'),
    ('vm_order_payments','vm_orders_member_select'),
    ('vm_material_purchases','vm_material_purchases_member_select')
  ) AS policies(table_name,policy_name) LOOP
    IF (SELECT count(*) FROM pg_catalog.pg_policy WHERE polrelid=pg_catalog.to_regclass('public.'||expected.table_name) AND polcmd IN ('r','*'))<>1
       OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_policy WHERE polrelid=pg_catalog.to_regclass('public.'||expected.table_name)
                      AND polname=expected.policy_name AND polcmd='r' AND polpermissive) THEN
      RAISE EXCEPTION 'Unexpected read policies on %',expected.table_name;
    END IF;
  END LOOP;
END;
$guard$;

-- authenticated is shared by every user. RLS must check the membership of
-- each row's organization, including for direct table and view queries.
ALTER POLICY vm_cash_entries_member_select ON public.vm_cash_entries
  USING ((SELECT vm_private.vm_has_role(organization_id,ARRAY['owner','admin','finance']::text[])));
ALTER POLICY vm_material_purchases_member_select ON public.vm_material_purchases
  USING ((SELECT vm_private.vm_has_role(organization_id,ARRAY['owner','admin','finance']::text[])));
ALTER POLICY vm_orders_member_select ON public.vm_order_payments
  USING ((SELECT vm_private.vm_has_role(organization_id,ARRAY['owner','admin','finance']::text[])));

-- Non-finance operational order rows remain visible, but no amount or payment
-- aggregate is returned by this view. In particular an RLS-filtered payment
-- sum must never be misrepresented as zero or as the true remaining balance.
CREATE OR REPLACE VIEW public.vm_orders_read WITH (security_invoker=true) AS
SELECT o.id,o.organization_id,o.code,o.client_id,c.name AS client_name,o.client_name_snapshot,o.title,
  o.status,o.status_version::text AS status_version,o.order_date,o.production_date,o.delivery_date,
  o.responsible_membership_id,o.public_notes,o.internal_notes,
  CASE WHEN vm_private.vm_has_role(o.organization_id,ARRAY['owner','admin','finance']::text[]) THEN o.subtotal::text END AS subtotal,
  CASE WHEN vm_private.vm_has_role(o.organization_id,ARRAY['owner','admin','finance']::text[]) THEN o.discount_type END AS discount_type,
  CASE WHEN vm_private.vm_has_role(o.organization_id,ARRAY['owner','admin','finance']::text[]) THEN o.discount_value::text END AS discount_value,
  CASE WHEN vm_private.vm_has_role(o.organization_id,ARRAY['owner','admin','finance']::text[]) THEN o.discount_amount::text END AS discount_amount,
  CASE WHEN vm_private.vm_has_role(o.organization_id,ARRAY['owner','admin','finance']::text[]) THEN o.shipping_amount::text END AS shipping_amount,
  CASE WHEN vm_private.vm_has_role(o.organization_id,ARRAY['owner','admin','finance']::text[]) THEN o.total_amount::text END AS total_amount,
  CASE WHEN vm_private.vm_has_role(o.organization_id,ARRAY['owner','admin','finance']::text[]) THEN COALESCE(p.paid_amount,0)::numeric(20,2)::text END AS paid_amount,
  CASE WHEN vm_private.vm_has_role(o.organization_id,ARRAY['owner','admin','finance']::text[]) THEN (o.total_amount-COALESCE(p.paid_amount,0))::numeric(20,2)::text END AS balance_amount,
  o.currency,(o.consumed_at IS NOT NULL) AS inventory_deducted,o.consumed_at,
  (SELECT count(*)::text FROM public.vm_order_items i WHERE i.organization_id=o.organization_id AND i.order_id=o.id) AS item_count,
  o.created_by,o.created_at,o.updated_at
FROM public.vm_orders o
JOIN public.vm_clients c ON c.organization_id=o.organization_id AND c.id=o.client_id
LEFT JOIN LATERAL (SELECT sum(pay.amount) AS paid_amount FROM public.vm_order_payments pay
  WHERE pay.organization_id=o.organization_id AND pay.order_id=o.id) p ON true;

INSERT INTO public.vm_schema_migrations(version,description)
VALUES('20261031002000_financial_ledgers_rls','Restringe caixa, compras e pagamentos aos papéis financeiros') ON CONFLICT(version) DO NOTHING;
NOTIFY pgrst,'reload schema';
COMMIT;
