BEGIN;

CREATE OR REPLACE FUNCTION public.vm_get_finance_summary(
  p_organization_id uuid,
  p_from date,
  p_to date,
  p_grouping text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE
  v_result jsonb;
BEGIN
  IF auth.uid() IS NULL
     OR auth.role() IS DISTINCT FROM 'authenticated'
     OR NOT vm_private.vm_has_role(p_organization_id,ARRAY['owner','admin','finance']::text[]) THEN
    RAISE EXCEPTION 'Sem permissão para consultar resumo financeiro nesta organização' USING ERRCODE='42501';
  END IF;
  IF p_organization_id IS NULL OR p_from IS NULL OR p_to IS NULL
     OR NOT vm_private.vm_date_valid(p_from) OR NOT vm_private.vm_date_valid(p_to)
     OR p_from > p_to OR p_to - p_from > 366
     OR p_grouping IS NULL OR p_grouping NOT IN ('day','month') THEN
    RAISE EXCEPTION 'Parâmetros financeiros inválidos' USING ERRCODE='22023';
  END IF;

  WITH income AS (
    -- vm_order_payments is the canonical receipt source. The linked cash-entry
    -- row is an accounting projection of the same payment and must not be added.
    SELECT p.payment_date AS d,p.amount,p.method
    FROM public.vm_order_payments p
    WHERE p.organization_id=p_organization_id AND p.payment_date BETWEEN p_from AND p_to
  ), cash_expense AS (
    -- Includes linked purchase expenses and any non-purchase expense entry;
    -- never count an order-payment mirror as an expense.
    SELECT ce.paid_at AS d,ce.amount
    FROM public.vm_cash_entries ce
    WHERE ce.organization_id=p_organization_id AND ce.entry_type='expense'
      AND ce.payment_status='paid' AND ce.paid_at BETWEEN p_from AND p_to
      AND ce.order_payment_id IS NULL
  ), orphan_purchases AS (
    -- Defensive fallback for a paid purchase lacking its expected cash row.
    -- Normal purchases are counted once through vm_cash_entries above.
    SELECT p.paid_at AS d,p.total_amount AS amount
    FROM public.vm_material_purchases p
    WHERE p.organization_id=p_organization_id AND p.payment_status='paid'
      AND p.paid_at BETWEEN p_from AND p_to
      AND NOT EXISTS (
        SELECT 1 FROM public.vm_cash_entries ce
        WHERE ce.organization_id=p.organization_id AND ce.material_purchase_id=p.id
      )
  ), forecast_income AS (
    -- This is an estimate for orders created in the selected window, not a
    -- due-date forecast: the schema does not store a confirmed receivable due date.
    SELECT greatest(o.total_amount-coalesce(sum(p.amount),0),0)::numeric AS amount
    FROM public.vm_orders o
    LEFT JOIN public.vm_order_payments p ON p.organization_id=o.organization_id AND p.order_id=o.id
    WHERE o.organization_id=p_organization_id AND o.status<>'Cancelado'
      AND o.order_date BETWEEN p_from AND p_to
    GROUP BY o.id,o.total_amount
  ), forecast_expense AS (
    -- Non-purchase pending expense entries have no confirmed due date.
    SELECT ce.amount
    FROM public.vm_cash_entries ce
    WHERE ce.organization_id=p_organization_id AND ce.entry_type='expense'
      AND ce.payment_status='pending' AND ce.entry_date BETWEEN p_from AND p_to
      AND ce.material_purchase_id IS NULL
    UNION ALL
    -- Pending purchases are selected by purchase date only, never mislabeled
    -- as due on that date. Their linked mirror row is excluded above.
    SELECT p.total_amount
    FROM public.vm_material_purchases p
    WHERE p.organization_id=p_organization_id AND p.payment_status='pending'
      AND p.purchase_date BETWEEN p_from AND p_to
  ), realized_in AS (
    SELECT coalesce(sum(i.amount),0) AS amount FROM income i
  ), realized_out AS (
    SELECT coalesce((SELECT sum(e.amount) FROM cash_expense e),0)
         + coalesce((SELECT sum(p.amount) FROM orphan_purchases p),0) AS amount
  ), forecast_in AS (
    SELECT coalesce(sum(f.amount),0) AS amount FROM forecast_income f
  ), forecast_out AS (
    SELECT coalesce(sum(f.amount),0) AS amount FROM forecast_expense f
  ), methods AS (
    SELECT coalesce(
      jsonb_agg(jsonb_build_object('method',x.method,'amount',x.amount::text) ORDER BY x.method),
      '[]'::jsonb
    ) AS data
    FROM (SELECT i.method,sum(i.amount) AS amount FROM income i GROUP BY i.method) x
  ), event_rows AS (
    SELECT CASE WHEN p_grouping='month' THEN date_trunc('month',i.d)::date ELSE i.d END AS period,
           i.amount,'received'::text AS direction
    FROM income i
    UNION ALL
    SELECT CASE WHEN p_grouping='month' THEN date_trunc('month',e.d)::date ELSE e.d END,
           e.amount,'paid'::text
    FROM cash_expense e
    UNION ALL
    SELECT CASE WHEN p_grouping='month' THEN date_trunc('month',p.d)::date ELSE p.d END,
           p.amount,'paid'::text
    FROM orphan_purchases p
  ), series AS (
    -- UNION ALL makes expense-only dates and months visible as well.
    SELECT r.period,
      coalesce(sum(r.amount) FILTER (WHERE r.direction='received'),0) AS received,
      coalesce(sum(r.amount) FILTER (WHERE r.direction='paid'),0) AS paid
    FROM event_rows r
    GROUP BY r.period
  )
  SELECT jsonb_build_object(
    'currency','BRL',
    'period',jsonb_build_object('from',p_from,'to',p_to,'grouping',p_grouping),
    'realized',jsonb_build_object(
      'received',ri.amount::text,
      'paid',ro.amount::text,
      'net',(ri.amount-ro.amount)::text,
      'paymentMethods',m.data
    ),
    'estimate',jsonb_build_object(
      'receivable',fi.amount::text,
      'payable',fo.amount::text,
      'projectedNet',(ri.amount-ro.amount+fi.amount-fo.amount)::text,
      'isEstimate',true
    ),
    'series',coalesce((
      SELECT jsonb_agg(jsonb_build_object('period',s.period,'received',s.received::text,'paid',s.paid::text) ORDER BY s.period)
      FROM series s
    ),'[]'::jsonb),
    'dueDatesAvailable',false
  ) INTO v_result
  FROM realized_in ri CROSS JOIN realized_out ro CROSS JOIN forecast_in fi CROSS JOIN forecast_out fo CROSS JOIN methods m;

  RETURN v_result;
END;
$function$;

COMMENT ON FUNCTION public.vm_get_finance_summary(uuid,date,date,text) IS
  'Resumo financeiro agregado read-only. Recebimentos canônicos por payment_date; despesas pagas por paid_at; previsão selecionada por datas de origem, sem inferir vencimentos.';
REVOKE ALL ON FUNCTION public.vm_get_finance_summary(uuid,date,date,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.vm_get_finance_summary(uuid,date,date,text) TO authenticated;

INSERT INTO public.vm_schema_migrations(version,description)
  VALUES('20261030005000_finance_summary','Resumo financeiro agregado e previsões explicitamente estimadas')
  ON CONFLICT(version) DO NOTHING;
NOTIFY pgrst, 'reload schema';
COMMIT;
