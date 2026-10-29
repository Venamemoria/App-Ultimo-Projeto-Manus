BEGIN;

-- A fundação usava numeric(20,8), mas numeric aceita NaN (e versões recentes
-- também aceitam Infinity). Estas funções são usadas por constraints e RPCs.
CREATE OR REPLACE FUNCTION vm_private.vm_numeric_valid(
 p_value numeric,
 p_scale integer,
 p_max_abs numeric,
 p_nonnegative boolean
) RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $function$
 SELECT CASE
   WHEN p_value IS NULL THEN false
   WHEN pg_catalog.lower(p_value::text) IN ('nan','infinity','-infinity') THEN false
   WHEN p_value <> pg_catalog.round(p_value,p_scale) THEN false
   WHEN pg_catalog.abs(p_value) > p_max_abs THEN false
   WHEN p_nonnegative AND p_value < 0 THEN false
   ELSE true
 END
$function$;

CREATE OR REPLACE FUNCTION vm_private.vm_date_valid(p_value date)
RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $function$
 SELECT p_value IS NOT NULL AND p_value <> 'infinity'::date AND p_value <> '-infinity'::date
$function$;

-- Reforço das colunas numeric já existentes. Os RPCs também validam o valor
-- antes do cast para numeric(20,8), evitando arredondamento silencioso de input.
ALTER TABLE public.vm_materials
  ADD CONSTRAINT vm_materials_package_cost_valid_ck CHECK (vm_private.vm_numeric_valid(package_cost,8,999999999999.99999999,true)),
  ADD CONSTRAINT vm_materials_package_quantity_valid_ck CHECK (vm_private.vm_numeric_valid(package_quantity,8,999999999999.99999999,true)),
  ADD CONSTRAINT vm_materials_unit_cost_valid_ck CHECK (vm_private.vm_numeric_valid(unit_cost,8,999999999999.99999999,true)),
  ADD CONSTRAINT vm_materials_stock_quantity_valid_ck CHECK (vm_private.vm_numeric_valid(stock_quantity,8,999999999999.99999999,true)),
  ADD CONSTRAINT vm_materials_reorder_level_valid_ck CHECK (vm_private.vm_numeric_valid(reorder_level,8,999999999999.99999999,true));

ALTER TABLE public.vm_stock_movements
  ADD CONSTRAINT vm_stock_movements_quantity_delta_valid_ck CHECK (vm_private.vm_numeric_valid(quantity_delta,8,999999999999.99999999,false)),
  ADD CONSTRAINT vm_stock_movements_stock_after_valid_ck CHECK (vm_private.vm_numeric_valid(stock_after,8,999999999999.99999999,true)),
  ADD CONSTRAINT vm_stock_movements_package_cost_valid_ck CHECK (package_cost IS NULL OR vm_private.vm_numeric_valid(package_cost,8,999999999999.99999999,true)),
  ADD CONSTRAINT vm_stock_movements_package_quantity_valid_ck CHECK (package_quantity IS NULL OR vm_private.vm_numeric_valid(package_quantity,8,999999999999.99999999,true));

ALTER TABLE public.vm_products
  ADD CONSTRAINT vm_products_price_valid_ck CHECK (vm_private.vm_numeric_valid(price,8,999999999999.99999999,true));

ALTER TABLE public.vm_product_components
  ADD CONSTRAINT vm_product_components_quantity_valid_ck CHECK (vm_private.vm_numeric_valid(quantity,8,999999999999.99999999,true));

-- O payload canônico fica fora do schema público. Isso permite distinguir um
-- replay do cadastro original sem comparar contra o saldo que mudou depois.
CREATE TABLE vm_private.vm_material_creation_requests (
 organization_id uuid NOT NULL,
 idempotency_key uuid NOT NULL,
 material_id uuid NOT NULL,
 opening_movement_id uuid,
 name text NOT NULL,
 category text,
 unit text NOT NULL,
 package_cost numeric(20,8) NOT NULL,
 package_quantity numeric(20,8) NOT NULL,
 initial_stock numeric(20,8) NOT NULL,
 reorder_level numeric(20,8) NOT NULL,
 supplier_id uuid,
 created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY (organization_id,idempotency_key),
 UNIQUE (organization_id,material_id),
 CONSTRAINT vm_material_creation_req_material_fk
   FOREIGN KEY (organization_id,material_id)
   REFERENCES public.vm_materials(organization_id,id) ON DELETE RESTRICT,
 CONSTRAINT vm_material_creation_req_opening_fk
   FOREIGN KEY (organization_id,opening_movement_id)
   REFERENCES public.vm_stock_movements(organization_id,id) ON DELETE RESTRICT,
 CONSTRAINT vm_material_creation_req_supplier_fk
   FOREIGN KEY (organization_id,supplier_id)
   REFERENCES public.vm_suppliers(organization_id,id) ON DELETE RESTRICT,
 CONSTRAINT vm_material_creation_req_package_cost_ck
   CHECK (vm_private.vm_numeric_valid(package_cost,8,999999999999.99999999,true)),
 CONSTRAINT vm_material_creation_req_package_quantity_ck
   CHECK (vm_private.vm_numeric_valid(package_quantity,8,999999999999.99999999,true)),
 CONSTRAINT vm_material_creation_req_initial_stock_ck
   CHECK (vm_private.vm_numeric_valid(initial_stock,8,999999999999.99999999,true)),
 CONSTRAINT vm_material_creation_req_reorder_level_ck
   CHECK (vm_private.vm_numeric_valid(reorder_level,8,999999999999.99999999,true))
);
ALTER TABLE vm_private.vm_material_creation_requests ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.vm_material_purchases (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
 material_id uuid NOT NULL,
 quantity_acquired numeric(20,8) NOT NULL,
 total_amount numeric(20,2) NOT NULL,
 unit_cost numeric(20,8) GENERATED ALWAYS AS ((total_amount / NULLIF(quantity_acquired,0))::numeric(20,8)) STORED,
 purchase_date date NOT NULL,
 supplier_id uuid,
 document_reference text,
 payment_status text NOT NULL CHECK (payment_status IN ('pending','paid')),
 paid_at date,
 idempotency_key uuid NOT NULL,
 created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE (organization_id,id),
 CONSTRAINT vm_material_purchases_material_same_org_fk
   FOREIGN KEY (organization_id,material_id)
   REFERENCES public.vm_materials(organization_id,id) ON DELETE RESTRICT,
 CONSTRAINT vm_material_purchases_supplier_same_org_fk
   FOREIGN KEY (organization_id,supplier_id)
   REFERENCES public.vm_suppliers(organization_id,id) ON DELETE RESTRICT,
 CONSTRAINT vm_material_purchases_document_ck
   CHECK (document_reference IS NULL OR (btrim(document_reference) <> '' AND char_length(document_reference) <= 500)),
 CONSTRAINT vm_material_purchases_payment_state_ck
   CHECK ((payment_status = 'paid' AND paid_at IS NOT NULL) OR (payment_status = 'pending' AND paid_at IS NULL)),
 CONSTRAINT vm_material_purchases_date_ck CHECK (vm_private.vm_date_valid(purchase_date)),
 CONSTRAINT vm_material_purchases_paid_date_ck CHECK (paid_at IS NULL OR vm_private.vm_date_valid(paid_at)),
 CONSTRAINT vm_material_purchases_quantity_ck CHECK (quantity_acquired > 0 AND vm_private.vm_numeric_valid(quantity_acquired,8,999999999999.99999999,true)),
 CONSTRAINT vm_material_purchases_amount_ck CHECK (vm_private.vm_numeric_valid(total_amount,2,999999999999999999.99,true)),
 CONSTRAINT vm_material_purchases_unit_cost_ck CHECK (vm_private.vm_numeric_valid(unit_cost,8,999999999999.99999999,true))
);

CREATE UNIQUE INDEX vm_material_purchases_idempotency_uq
 ON public.vm_material_purchases (organization_id,idempotency_key);
CREATE INDEX vm_material_purchases_material_date_idx
 ON public.vm_material_purchases (organization_id,material_id,purchase_date DESC,created_at DESC);

-- purchase_id é o vínculo que identifica uma entrada originada por compra.
-- Recebimentos avulsos continuam com purchase_id NULL.
ALTER TABLE public.vm_stock_movements
  ADD COLUMN purchase_id uuid,
  ADD CONSTRAINT vm_stock_movements_purchase_fk
    FOREIGN KEY (organization_id,purchase_id)
    REFERENCES public.vm_material_purchases(organization_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT vm_stock_movements_purchase_type_ck
    CHECK (purchase_id IS NULL OR movement_type = 'receipt');
CREATE UNIQUE INDEX vm_stock_movements_purchase_uq
 ON public.vm_stock_movements (organization_id,purchase_id)
 WHERE purchase_id IS NOT NULL;

CREATE TABLE public.vm_cash_entries (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
 entry_type text NOT NULL CHECK (entry_type IN ('income','expense')),
 amount numeric(20,2) NOT NULL,
 entry_date date NOT NULL,
 description text NOT NULL CHECK (btrim(description) <> '' AND char_length(description) <= 2000),
 payment_status text NOT NULL CHECK (payment_status IN ('pending','paid')),
 paid_at date,
 material_purchase_id uuid,
 supplier_id uuid,
 created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE (organization_id,id),
 CONSTRAINT vm_cash_entries_purchase_fk
   FOREIGN KEY (organization_id,material_purchase_id)
   REFERENCES public.vm_material_purchases(organization_id,id) ON DELETE RESTRICT,
 CONSTRAINT vm_cash_entries_supplier_same_org_fk
   FOREIGN KEY (organization_id,supplier_id)
   REFERENCES public.vm_suppliers(organization_id,id) ON DELETE RESTRICT,
 CONSTRAINT vm_cash_entries_purchase_type_ck
   CHECK (material_purchase_id IS NULL OR entry_type = 'expense'),
 CONSTRAINT vm_cash_entries_date_ck CHECK (vm_private.vm_date_valid(entry_date)),
 CONSTRAINT vm_cash_entries_paid_date_ck CHECK (paid_at IS NULL OR vm_private.vm_date_valid(paid_at)),
 CONSTRAINT vm_cash_entries_payment_state_ck
   CHECK ((payment_status = 'paid' AND paid_at IS NOT NULL) OR (payment_status = 'pending' AND paid_at IS NULL)),
 CONSTRAINT vm_cash_entries_amount_ck
   CHECK (vm_private.vm_numeric_valid(amount,2,999999999999999999.99,true))
);
CREATE UNIQUE INDEX vm_cash_entries_purchase_uq
 ON public.vm_cash_entries (organization_id,material_purchase_id)
 WHERE material_purchase_id IS NOT NULL;
CREATE INDEX vm_cash_entries_org_date_idx
 ON public.vm_cash_entries (organization_id,entry_date DESC,created_at DESC);

CREATE OR REPLACE FUNCTION vm_private.vm_reject_cash_entry_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $function$
BEGIN
 RAISE EXCEPTION 'Lançamento financeiro é somente apêndice; use uma RPC de baixa futura'
   USING ERRCODE = '55000';
END;
$function$;
CREATE TRIGGER vm_cash_entries_append_only
 BEFORE UPDATE OR DELETE ON public.vm_cash_entries
 FOR EACH ROW EXECUTE FUNCTION vm_private.vm_reject_cash_entry_mutation();

CREATE OR REPLACE FUNCTION vm_private.vm_reject_purchase_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $function$
BEGIN
 RAISE EXCEPTION 'Compra histórica é somente apêndice; não pode ser editada ou apagada'
   USING ERRCODE = '55000';
END;
$function$;
CREATE TRIGGER vm_material_purchases_append_only
 BEFORE UPDATE OR DELETE ON public.vm_material_purchases
 FOR EACH ROW EXECUTE FUNCTION vm_private.vm_reject_purchase_mutation();

-- Views públicas de leitura: numeric vira text no limite do banco, sem perda no
-- JSON/JavaScript. WITH security_invoker mantém as policies das tabelas-base.
CREATE VIEW public.vm_materials_read
WITH (security_invoker = true)
AS
SELECT
 m.id,
 m.organization_id,
 m.name,
 m.category,
 m.unit,
 m.package_cost::text AS package_cost,
 m.package_quantity::text AS package_quantity,
 m.unit_cost::text AS unit_cost,
 m.stock_quantity::text AS stock_quantity,
 m.reorder_level::text AS reorder_level,
 (m.stock_quantity <= m.reorder_level) AS is_low_stock,
 m.supplier_id,
 m.created_at,
 m.updated_at
FROM public.vm_materials AS m;

CREATE VIEW public.vm_stock_movements_read
WITH (security_invoker = true)
AS
SELECT
 sm.id,
 sm.organization_id,
 sm.material_id,
 sm.movement_type,
 sm.quantity_delta::text AS quantity_delta,
 sm.stock_after::text AS stock_after,
 sm.package_cost::text AS package_cost,
 sm.package_quantity::text AS package_quantity,
 sm.note,
 sm.purchase_id,
 sm.idempotency_key,
 sm.created_by,
 sm.created_at
FROM public.vm_stock_movements AS sm;

CREATE VIEW public.vm_material_purchases_read
WITH (security_invoker = true)
AS
SELECT
 p.id,
 p.organization_id,
 p.material_id,
 m.name AS material_name,
 p.quantity_acquired::text AS quantity_acquired,
 p.total_amount::text AS total_amount,
 p.unit_cost::text AS unit_cost,
 p.purchase_date,
 p.supplier_id,
 s.name AS supplier_name,
 p.document_reference,
 p.payment_status,
 p.paid_at,
 sm.id AS receipt_movement_id,
 ce.id AS cash_entry_id,
 p.created_by,
 p.created_at
FROM public.vm_material_purchases AS p
JOIN public.vm_materials AS m
  ON m.organization_id = p.organization_id AND m.id = p.material_id
LEFT JOIN public.vm_suppliers AS s
  ON s.organization_id = p.organization_id AND s.id = p.supplier_id
LEFT JOIN public.vm_stock_movements AS sm
  ON sm.organization_id = p.organization_id AND sm.purchase_id = p.id
LEFT JOIN public.vm_cash_entries AS ce
  ON ce.organization_id = p.organization_id AND ce.material_purchase_id = p.id;

CREATE VIEW public.vm_cash_entries_read
WITH (security_invoker = true)
AS
SELECT
 ce.id,
 ce.organization_id,
 ce.entry_type,
 ce.amount::text AS amount,
 ce.entry_date,
 ce.description,
 ce.payment_status,
 ce.paid_at,
 ce.material_purchase_id,
 ce.supplier_id,
 ce.created_by,
 ce.created_at
FROM public.vm_cash_entries AS ce;

-- RLS nega leitura cruzada e não há policies de escrita para estas tabelas.
ALTER TABLE public.vm_material_purchases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vm_cash_entries ENABLE ROW LEVEL SECURITY;
CREATE POLICY vm_material_purchases_member_select
 ON public.vm_material_purchases FOR SELECT TO authenticated
 USING ((SELECT vm_private.vm_is_member(organization_id)));
CREATE POLICY vm_cash_entries_member_select
 ON public.vm_cash_entries FOR SELECT TO authenticated
 USING ((SELECT vm_private.vm_is_member(organization_id)));

-- Cadastro de material: mesma assinatura pública, agora com payload canônico
-- privado e replay que nunca consulta o saldo atual para validar o payload.
CREATE OR REPLACE FUNCTION public.vm_create_material(
 p_organization_id uuid,p_name text,p_unit text,p_package_cost numeric,p_package_quantity numeric,p_initial_stock numeric,p_reorder_level numeric,
 p_category text DEFAULT NULL,p_supplier_id uuid DEFAULT NULL,p_idempotency_key uuid DEFAULT NULL
) RETURNS TABLE(material_id uuid,opening_movement_id uuid,unit_cost numeric,stock_quantity numeric)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog,public
AS $function$
DECLARE
 v_uid uuid := auth.uid();
 v_material uuid;
 v_opening uuid;
 v_request_material uuid;
 v_request_opening uuid;
 v_category text := NULLIF(btrim(p_category),'');
 v_name text := btrim(p_name);
 v_unit text := btrim(p_unit);
BEGIN
 IF v_uid IS NULL OR auth.role() <> 'authenticated' OR NOT vm_private.vm_has_role(p_organization_id,ARRAY['owner','admin']::text[]) THEN
  RAISE EXCEPTION 'Sem permissão para cadastrar insumo nesta organização' USING ERRCODE='42501';
 END IF;
 IF p_name IS NULL OR v_name = '' OR char_length(v_name) > 200
    OR p_unit IS NULL OR v_unit = '' OR char_length(v_unit) > 40
    OR NOT vm_private.vm_numeric_valid(p_package_cost,8,999999999999.99999999,true)
    OR NOT vm_private.vm_numeric_valid(p_package_quantity,8,999999999999.99999999,true) OR p_package_quantity <= 0
    OR NOT vm_private.vm_numeric_valid(p_initial_stock,8,999999999999.99999999,true)
    OR NOT vm_private.vm_numeric_valid(p_reorder_level,8,999999999999.99999999,true) THEN
  RAISE EXCEPTION 'Parâmetros de insumo inválidos' USING ERRCODE='22023';
 END IF;
 IF p_category IS NOT NULL AND (v_category IS NULL OR char_length(v_category) > 120) THEN
  RAISE EXCEPTION 'Categoria inválida' USING ERRCODE='22023';
 END IF;
 IF p_supplier_id IS NOT NULL AND NOT EXISTS (
   SELECT 1 FROM public.vm_suppliers AS s
   WHERE s.organization_id = p_organization_id AND s.id = p_supplier_id
 ) THEN
  RAISE EXCEPTION 'Fornecedor não pertence à organização' USING ERRCODE='23503';
 END IF;
 PERFORM 1 FROM public.vm_organizations AS o WHERE o.id = p_organization_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Organização não encontrada' USING ERRCODE='23503'; END IF;

 IF p_idempotency_key IS NOT NULL THEN
  SELECT r.material_id,r.opening_movement_id
    INTO v_request_material,v_request_opening
  FROM vm_private.vm_material_creation_requests AS r
  WHERE r.organization_id = p_organization_id AND r.idempotency_key = p_idempotency_key
  FOR UPDATE;
  IF v_request_material IS NOT NULL THEN
   IF NOT EXISTS (
     SELECT 1 FROM vm_private.vm_material_creation_requests AS r
     WHERE r.organization_id = p_organization_id AND r.idempotency_key = p_idempotency_key
       AND r.name = v_name AND r.category IS NOT DISTINCT FROM v_category AND r.unit = v_unit
       AND r.package_cost = p_package_cost AND r.package_quantity = p_package_quantity
       AND r.initial_stock = p_initial_stock AND r.reorder_level = p_reorder_level
       AND r.supplier_id IS NOT DISTINCT FROM p_supplier_id
   ) THEN
    RAISE EXCEPTION 'Chave de idempotência reutilizada com payload diferente' USING ERRCODE='23505';
   END IF;
   RETURN QUERY
     SELECT m.id,v_request_opening,m.unit_cost,m.stock_quantity
     FROM public.vm_materials AS m
     WHERE m.organization_id = p_organization_id AND m.id = v_request_material;
   RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM public.vm_materials AS m WHERE m.organization_id=p_organization_id AND m.creation_idempotency_key=p_idempotency_key)
     OR EXISTS (SELECT 1 FROM public.vm_stock_movements AS sm WHERE sm.organization_id=p_organization_id AND sm.idempotency_key=p_idempotency_key)
     OR EXISTS (SELECT 1 FROM public.vm_material_purchases AS p WHERE p.organization_id=p_organization_id AND p.idempotency_key=p_idempotency_key) THEN
   RAISE EXCEPTION 'Chave de idempotência já pertence a outro cadastro ou operação' USING ERRCODE='23505';
  END IF;
 END IF;

 INSERT INTO public.vm_materials(organization_id,name,category,unit,package_cost,package_quantity,stock_quantity,reorder_level,supplier_id,creation_idempotency_key)
 VALUES (p_organization_id,v_name,v_category,v_unit,p_package_cost,p_package_quantity,p_initial_stock,p_reorder_level,p_supplier_id,p_idempotency_key)
 RETURNING id INTO v_material;
 IF p_initial_stock > 0 THEN
  INSERT INTO public.vm_stock_movements(organization_id,material_id,movement_type,quantity_delta,stock_after,package_cost,package_quantity,idempotency_key,created_by)
  VALUES (p_organization_id,v_material,'opening',p_initial_stock,p_initial_stock,p_package_cost,p_package_quantity,p_idempotency_key,v_uid)
  RETURNING id INTO v_opening;
 END IF;
 IF p_idempotency_key IS NOT NULL THEN
  INSERT INTO vm_private.vm_material_creation_requests(
    organization_id,idempotency_key,material_id,opening_movement_id,name,category,unit,
    package_cost,package_quantity,initial_stock,reorder_level,supplier_id
  ) VALUES (
    p_organization_id,p_idempotency_key,v_material,v_opening,v_name,v_category,v_unit,
    p_package_cost,p_package_quantity,p_initial_stock,p_reorder_level,p_supplier_id
  );
 END IF;
 RETURN QUERY
   SELECT m.id,v_opening,m.unit_cost,m.stock_quantity
   FROM public.vm_materials AS m
   WHERE m.organization_id = p_organization_id AND m.id = v_material;
END;
$function$;

-- Recebimento avulso: mantém a assinatura da fundação, mas separa compra,
-- compara o movimento original e rejeita NaN/Infinity/escala excedente.
CREATE OR REPLACE FUNCTION public.vm_receive_material(
 p_organization_id uuid,p_material_id uuid,p_quantity numeric,p_package_cost numeric,p_package_quantity numeric,p_note text DEFAULT NULL,p_idempotency_key uuid DEFAULT NULL
) RETURNS TABLE(movement_id uuid,material_id uuid,stock_quantity numeric,package_cost numeric,package_quantity numeric,unit_cost numeric)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog,public
AS $function$
DECLARE
 v_uid uuid := auth.uid();
 v_old numeric;
 v_new numeric;
 v_movement uuid;
 v_type text;
 v_purchase uuid;
 v_note text := btrim(p_note);
BEGIN
 IF v_uid IS NULL OR auth.role() <> 'authenticated' OR NOT vm_private.vm_has_role(p_organization_id,ARRAY['owner','admin','production']::text[]) THEN
  RAISE EXCEPTION 'Sem permissão para receber insumo nesta organização' USING ERRCODE='42501';
 END IF;
 IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'p_idempotency_key é obrigatório para recebimento' USING ERRCODE='22023'; END IF;
 IF NOT vm_private.vm_numeric_valid(p_quantity,8,999999999999.99999999,true) OR p_quantity <= 0
    OR NOT vm_private.vm_numeric_valid(p_package_cost,8,999999999999.99999999,true)
    OR NOT vm_private.vm_numeric_valid(p_package_quantity,8,999999999999.99999999,true) OR p_package_quantity <= 0
    OR p_note IS NULL OR v_note='' OR char_length(v_note) > 2000 THEN
  RAISE EXCEPTION 'Parâmetros de recebimento inválidos' USING ERRCODE='22023';
 END IF;
 PERFORM 1 FROM public.vm_organizations AS o WHERE o.id=p_organization_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Organização não encontrada' USING ERRCODE='23503'; END IF;
 SELECT sm.id,sm.movement_type,sm.purchase_id
   INTO v_movement,v_type,v_purchase
 FROM public.vm_stock_movements AS sm
 WHERE sm.organization_id=p_organization_id AND sm.idempotency_key=p_idempotency_key
 FOR UPDATE;
 IF v_movement IS NOT NULL THEN
  IF v_type <> 'receipt' OR v_purchase IS NOT NULL THEN
   RAISE EXCEPTION 'A chave de idempotência já foi usada por outra operação' USING ERRCODE='23505';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.vm_stock_movements AS sm
    WHERE sm.organization_id=p_organization_id AND sm.id=v_movement
      AND sm.material_id=p_material_id AND sm.quantity_delta=p_quantity
      AND sm.package_cost=p_package_cost AND sm.package_quantity=p_package_quantity
      AND sm.note=v_note
  ) THEN
   RAISE EXCEPTION 'Chave de idempotência reutilizada com dados diferentes' USING ERRCODE='23505';
  END IF;
  RETURN QUERY
    SELECT sm.id,m.id,m.stock_quantity,m.package_cost,m.package_quantity,m.unit_cost
    FROM public.vm_stock_movements AS sm
    JOIN public.vm_materials AS m ON m.organization_id=sm.organization_id AND m.id=sm.material_id
    WHERE sm.organization_id=p_organization_id AND sm.id=v_movement;
  RETURN;
 END IF;
 IF EXISTS (SELECT 1 FROM public.vm_material_purchases AS p WHERE p.organization_id=p_organization_id AND p.idempotency_key=p_idempotency_key)
    OR EXISTS (SELECT 1 FROM public.vm_materials AS m WHERE m.organization_id=p_organization_id AND m.creation_idempotency_key=p_idempotency_key) THEN
  RAISE EXCEPTION 'A chave de idempotência já foi usada por outra operação' USING ERRCODE='23505';
 END IF;
 SELECT m.stock_quantity INTO v_old
 FROM public.vm_materials AS m
 WHERE m.organization_id=p_organization_id AND m.id=p_material_id
 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Insumo não encontrado nesta organização' USING ERRCODE='23503'; END IF;
 v_new := v_old + p_quantity;
 IF NOT vm_private.vm_numeric_valid(v_new,8,999999999999.99999999,true) THEN
  RAISE EXCEPTION 'O saldo resultante excede a precisão de estoque' USING ERRCODE='22003';
 END IF;
 UPDATE public.vm_materials AS m
 SET package_cost=p_package_cost,package_quantity=p_package_quantity,stock_quantity=v_new
 WHERE m.organization_id=p_organization_id AND m.id=p_material_id;
 INSERT INTO public.vm_stock_movements(organization_id,material_id,movement_type,quantity_delta,stock_after,package_cost,package_quantity,note,idempotency_key,created_by)
 VALUES (p_organization_id,p_material_id,'receipt',p_quantity,v_new,p_package_cost,p_package_quantity,v_note,p_idempotency_key,v_uid)
 RETURNING id INTO v_movement;
 RETURN QUERY
   SELECT v_movement,m.id,m.stock_quantity,m.package_cost,m.package_quantity,m.unit_cost
   FROM public.vm_materials AS m
   WHERE m.organization_id=p_organization_id AND m.id=p_material_id;
END;
$function$;

-- Edição controlada: custo, unidade, quantidade da embalagem e saldo não são
-- parâmetros desta função e nunca podem ser alterados por ela.
CREATE OR REPLACE FUNCTION public.vm_update_material(
 p_organization_id uuid,p_material_id uuid,p_name text,p_reorder_level numeric,
 p_category text DEFAULT NULL,p_supplier_id uuid DEFAULT NULL
) RETURNS TABLE(material_id uuid,name text,category text,unit text,supplier_id uuid,reorder_level text,updated_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog,public
AS $function$
DECLARE
 v_uid uuid := auth.uid();
 v_name text := btrim(p_name);
 v_category text := NULLIF(btrim(p_category),'');
BEGIN
 IF v_uid IS NULL OR auth.role() <> 'authenticated' OR NOT vm_private.vm_has_role(p_organization_id,ARRAY['owner','admin']::text[]) THEN
  RAISE EXCEPTION 'Sem permissão para editar insumo nesta organização' USING ERRCODE='42501';
 END IF;
 IF p_name IS NULL OR v_name='' OR char_length(v_name)>200
    OR NOT vm_private.vm_numeric_valid(p_reorder_level,8,999999999999.99999999,true) THEN
  RAISE EXCEPTION 'Nome ou limite de reposição inválido' USING ERRCODE='22023';
 END IF;
 IF p_category IS NOT NULL AND (v_category IS NULL OR char_length(v_category)>120) THEN
  RAISE EXCEPTION 'Categoria inválida' USING ERRCODE='22023';
 END IF;
 PERFORM 1 FROM public.vm_organizations AS o WHERE o.id=p_organization_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Organização não encontrada' USING ERRCODE='23503'; END IF;
 IF p_supplier_id IS NOT NULL AND NOT EXISTS (
   SELECT 1 FROM public.vm_suppliers AS s WHERE s.organization_id=p_organization_id AND s.id=p_supplier_id
 ) THEN RAISE EXCEPTION 'Fornecedor não pertence à organização' USING ERRCODE='23503'; END IF;
 UPDATE public.vm_materials AS m
 SET name=v_name,category=v_category,supplier_id=p_supplier_id,reorder_level=p_reorder_level
 WHERE m.organization_id=p_organization_id AND m.id=p_material_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Insumo não encontrado nesta organização' USING ERRCODE='23503'; END IF;
 RETURN QUERY
   SELECT m.id,m.name,m.category,m.unit,m.supplier_id,m.reorder_level::text,m.updated_at
   FROM public.vm_materials AS m
   WHERE m.organization_id=p_organization_id AND m.id=p_material_id;
END;
$function$;

-- Ajuste novo, com chave obrigatória e replay por payload. O RPC legado sem
-- chave permanece no catálogo somente para compatibilidade, mas fica fechado.
CREATE OR REPLACE FUNCTION public.vm_adjust_material_stock_safe(
 p_organization_id uuid,p_material_id uuid,p_delta numeric,p_reason text,p_idempotency_key uuid
) RETURNS TABLE(movement_id uuid,material_id uuid,stock_quantity text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog,public
AS $function$
DECLARE
 v_uid uuid := auth.uid();
 v_old numeric;
 v_new numeric;
 v_movement uuid;
 v_type text;
 v_purchase uuid;
 v_note text := btrim(p_reason);
BEGIN
 IF v_uid IS NULL OR auth.role() <> 'authenticated' OR NOT vm_private.vm_has_role(p_organization_id,ARRAY['owner','admin']::text[]) THEN
  RAISE EXCEPTION 'Sem permissão para ajustar estoque nesta organização' USING ERRCODE='42501';
 END IF;
 IF p_idempotency_key IS NULL OR NOT vm_private.vm_numeric_valid(p_delta,8,999999999999.99999999,false) OR p_delta=0
    OR p_reason IS NULL OR v_note='' OR char_length(v_note)>2000 THEN
  RAISE EXCEPTION 'Chave, delta e motivo do ajuste são obrigatórios e válidos' USING ERRCODE='22023';
 END IF;
 PERFORM 1 FROM public.vm_organizations AS o WHERE o.id=p_organization_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Organização não encontrada' USING ERRCODE='23503'; END IF;
 SELECT sm.id,sm.movement_type,sm.purchase_id
   INTO v_movement,v_type,v_purchase
 FROM public.vm_stock_movements AS sm
 WHERE sm.organization_id=p_organization_id AND sm.idempotency_key=p_idempotency_key
 FOR UPDATE;
 IF v_movement IS NOT NULL THEN
  IF v_type <> 'adjustment' OR v_purchase IS NOT NULL THEN
   RAISE EXCEPTION 'A chave de idempotência já foi usada por outra operação' USING ERRCODE='23505';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.vm_stock_movements AS sm
    WHERE sm.organization_id=p_organization_id AND sm.id=v_movement
      AND sm.material_id=p_material_id AND sm.quantity_delta=p_delta AND sm.note=v_note
  ) THEN
   RAISE EXCEPTION 'Chave de idempotência reutilizada com dados diferentes' USING ERRCODE='23505';
  END IF;
  RETURN QUERY
    SELECT sm.id,sm.material_id,m.stock_quantity::text
    FROM public.vm_stock_movements AS sm
    JOIN public.vm_materials AS m ON m.organization_id=sm.organization_id AND m.id=sm.material_id
    WHERE sm.organization_id=p_organization_id AND sm.id=v_movement;
  RETURN;
 END IF;
 IF EXISTS (SELECT 1 FROM public.vm_material_purchases AS p WHERE p.organization_id=p_organization_id AND p.idempotency_key=p_idempotency_key)
    OR EXISTS (SELECT 1 FROM public.vm_materials AS m WHERE m.organization_id=p_organization_id AND m.creation_idempotency_key=p_idempotency_key) THEN
  RAISE EXCEPTION 'A chave de idempotência já foi usada por outra operação' USING ERRCODE='23505';
 END IF;
 SELECT m.stock_quantity INTO v_old
 FROM public.vm_materials AS m
 WHERE m.organization_id=p_organization_id AND m.id=p_material_id
 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Insumo não encontrado nesta organização' USING ERRCODE='23503'; END IF;
 v_new := v_old + p_delta;
 IF NOT vm_private.vm_numeric_valid(v_new,8,999999999999.99999999,true) THEN
  RAISE EXCEPTION 'O ajuste não pode deixar o estoque negativo ou exceder a precisão' USING ERRCODE='23514';
 END IF;
 UPDATE public.vm_materials AS m SET stock_quantity=v_new
 WHERE m.organization_id=p_organization_id AND m.id=p_material_id;
 INSERT INTO public.vm_stock_movements(organization_id,material_id,movement_type,quantity_delta,stock_after,package_cost,package_quantity,note,idempotency_key,created_by)
 SELECT p_organization_id,m.id,'adjustment',p_delta,v_new,m.package_cost,m.package_quantity,v_note,p_idempotency_key,v_uid
 FROM public.vm_materials AS m
 WHERE m.organization_id=p_organization_id AND m.id=p_material_id
 RETURNING id INTO v_movement;
 RETURN QUERY SELECT v_movement,p_material_id,v_new::text;
END;
$function$;

-- Compra transacional: compra, entrada, atualização do lote vigente e despesa
-- são uma única unidade. Nenhuma chamada externa ou inferência de pagamento.
CREATE OR REPLACE FUNCTION public.vm_create_material_purchase(
 p_organization_id uuid,
 p_material_id uuid,
 p_quantity_acquired numeric,
 p_total_amount numeric,
 p_purchase_date date,
 p_payment_status text,
 p_paid_at date,
 p_idempotency_key uuid,
 p_supplier_id uuid,
 p_document_reference text
) RETURNS TABLE(
 purchase_id uuid,
 movement_id uuid,
 cash_entry_id uuid,
 material_id uuid,
 quantity_acquired text,
 total_amount text,
 unit_cost text,
 stock_quantity text,
 payment_status text,
 paid_at date
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog,public
AS $function$
DECLARE
 v_uid uuid := auth.uid();
 v_purchase uuid;
 v_movement uuid;
 v_cash uuid;
 v_existing_material uuid;
 v_existing_movement uuid;
 v_old numeric;
 v_new numeric;
 v_existing_status text;
 v_existing_paid date;
 v_existing_supplier uuid;
 v_existing_document text;
 v_existing_quantity numeric;
 v_existing_total numeric;
 v_existing_date date;
 v_document text := NULLIF(btrim(p_document_reference),'');
BEGIN
 IF v_uid IS NULL OR auth.role() <> 'authenticated' OR NOT vm_private.vm_has_role(p_organization_id,ARRAY['owner','admin','finance']::text[]) THEN
  RAISE EXCEPTION 'Sem permissão para registrar compra nesta organização' USING ERRCODE='42501';
 END IF;
 IF p_idempotency_key IS NULL
    OR NOT vm_private.vm_numeric_valid(p_quantity_acquired,8,999999999999.99999999,true) OR p_quantity_acquired <= 0
    OR NOT vm_private.vm_numeric_valid(p_total_amount,2,999999999999999999.99,true)
    OR NOT vm_private.vm_date_valid(p_purchase_date)
    OR p_payment_status IS NULL OR p_payment_status NOT IN ('pending','paid')
    OR (p_payment_status='paid' AND NOT vm_private.vm_date_valid(p_paid_at))
    OR (p_payment_status='pending' AND p_paid_at IS NOT NULL)
    OR (p_document_reference IS NOT NULL AND (v_document IS NULL OR char_length(v_document)>500)) THEN
  RAISE EXCEPTION 'Parâmetros de compra inválidos' USING ERRCODE='22023';
 END IF;
 PERFORM 1 FROM public.vm_organizations AS o WHERE o.id=p_organization_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Organização não encontrada' USING ERRCODE='23503'; END IF;

 SELECT p.id,p.material_id,p.quantity_acquired,p.total_amount,p.purchase_date,p.supplier_id,p.document_reference,p.payment_status,p.paid_at
   INTO v_purchase,v_existing_material,v_existing_quantity,v_existing_total,v_existing_date,v_existing_supplier,v_existing_document,v_existing_status,v_existing_paid
 FROM public.vm_material_purchases AS p
 WHERE p.organization_id=p_organization_id AND p.idempotency_key=p_idempotency_key
 FOR UPDATE;
 IF v_purchase IS NOT NULL THEN
  IF v_existing_material IS DISTINCT FROM p_material_id
     OR v_existing_quantity IS DISTINCT FROM p_quantity_acquired
     OR v_existing_total IS DISTINCT FROM p_total_amount
     OR v_existing_date IS DISTINCT FROM p_purchase_date
     OR v_existing_supplier IS DISTINCT FROM p_supplier_id
     OR v_existing_document IS DISTINCT FROM v_document
     OR v_existing_status IS DISTINCT FROM p_payment_status
     OR v_existing_paid IS DISTINCT FROM p_paid_at THEN
   RAISE EXCEPTION 'Chave de idempotência reutilizada com payload diferente' USING ERRCODE='23505';
  END IF;
  SELECT sm.id INTO v_movement FROM public.vm_stock_movements AS sm
  WHERE sm.organization_id=p_organization_id AND sm.purchase_id=v_purchase;
  SELECT ce.id INTO v_cash FROM public.vm_cash_entries AS ce
  WHERE ce.organization_id=p_organization_id AND ce.material_purchase_id=v_purchase;
  IF v_movement IS NULL OR v_cash IS NULL THEN
   RAISE EXCEPTION 'Compra idempotente sem vínculos completos' USING ERRCODE='40001';
  END IF;
  SELECT m.stock_quantity INTO v_new FROM public.vm_materials AS m
  WHERE m.organization_id=p_organization_id AND m.id=v_existing_material
  FOR UPDATE;
  RETURN QUERY
    SELECT p.id,v_movement,v_cash,p.material_id,p.quantity_acquired::text,p.total_amount::text,p.unit_cost::text,v_new::text,p.payment_status,p.paid_at
    FROM public.vm_material_purchases AS p
    WHERE p.organization_id=p_organization_id AND p.id=v_purchase;
  RETURN;
 END IF;

 IF EXISTS (SELECT 1 FROM public.vm_materials AS m WHERE m.organization_id=p_organization_id AND m.creation_idempotency_key=p_idempotency_key)
    OR EXISTS (SELECT 1 FROM public.vm_stock_movements AS sm WHERE sm.organization_id=p_organization_id AND sm.idempotency_key=p_idempotency_key) THEN
  RAISE EXCEPTION 'A chave de idempotência já foi usada por outra operação' USING ERRCODE='23505';
 END IF;
 IF p_supplier_id IS NOT NULL AND NOT EXISTS (
   SELECT 1 FROM public.vm_suppliers AS s WHERE s.organization_id=p_organization_id AND s.id=p_supplier_id
 ) THEN RAISE EXCEPTION 'Fornecedor não pertence à organização' USING ERRCODE='23503'; END IF;
 SELECT m.stock_quantity INTO v_old
 FROM public.vm_materials AS m
 WHERE m.organization_id=p_organization_id AND m.id=p_material_id
 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Insumo não encontrado nesta organização' USING ERRCODE='23503'; END IF;
 v_new := v_old + p_quantity_acquired;
 IF NOT vm_private.vm_numeric_valid(v_new,8,999999999999.99999999,true) THEN
  RAISE EXCEPTION 'O saldo resultante excede a precisão de estoque' USING ERRCODE='22003';
 END IF;
 INSERT INTO public.vm_material_purchases(
   organization_id,material_id,quantity_acquired,total_amount,purchase_date,supplier_id,document_reference,payment_status,paid_at,idempotency_key,created_by
 ) VALUES (
   p_organization_id,p_material_id,p_quantity_acquired,p_total_amount,p_purchase_date,p_supplier_id,v_document,p_payment_status,p_paid_at,p_idempotency_key,v_uid
 ) RETURNING id INTO v_purchase;
 UPDATE public.vm_materials AS m
 SET package_cost=p_total_amount,package_quantity=p_quantity_acquired,stock_quantity=v_new
 WHERE m.organization_id=p_organization_id AND m.id=p_material_id;
 INSERT INTO public.vm_stock_movements(
   organization_id,material_id,movement_type,quantity_delta,stock_after,package_cost,package_quantity,note,idempotency_key,purchase_id,created_by
 ) VALUES (
   p_organization_id,p_material_id,'receipt',p_quantity_acquired,v_new,p_total_amount,p_quantity_acquired,v_document,p_idempotency_key,v_purchase,v_uid
 ) RETURNING id INTO v_movement;
 INSERT INTO public.vm_cash_entries(
   organization_id,entry_type,amount,entry_date,description,payment_status,paid_at,material_purchase_id,supplier_id,created_by
 ) VALUES (
   p_organization_id,'expense',p_total_amount,p_purchase_date,
   'Compra de insumo' || CASE WHEN v_document IS NULL THEN '' ELSE ' — documento: ' || v_document END,
   p_payment_status,p_paid_at,v_purchase,p_supplier_id,v_uid
 ) RETURNING id INTO v_cash;
 RETURN QUERY
   SELECT p.id,v_movement,v_cash,p.material_id,p.quantity_acquired::text,p.total_amount::text,p.unit_cost::text,v_new::text,p.payment_status,p.paid_at
   FROM public.vm_material_purchases AS p
   WHERE p.organization_id=p_organization_id AND p.id=v_purchase;
END;
$function$;

-- Produtos/componentes já existentes também passam a rejeitar valores especiais
-- e escala excedente antes de serem convertidos para numeric(20,8).
CREATE OR REPLACE FUNCTION public.vm_upsert_product(
 p_organization_id uuid,p_name text,p_price numeric,p_category text DEFAULT NULL,p_components jsonb DEFAULT '[]'::jsonb,p_product_id uuid DEFAULT NULL
) RETURNS TABLE(product_id uuid,version integer,price numeric,component_count integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog,public
AS $function$
DECLARE
 v_uid uuid := auth.uid();
 v_product uuid := p_product_id;
 v_version integer;
 v_count integer;
 v_materials integer;
 v_values_ok boolean;
BEGIN
 IF v_uid IS NULL OR auth.role() <> 'authenticated' OR NOT vm_private.vm_has_role(p_organization_id,ARRAY['owner','admin','production']::text[]) THEN
  RAISE EXCEPTION 'Sem permissão para alterar produto nesta organização' USING ERRCODE='42501';
 END IF;
 IF p_name IS NULL OR btrim(p_name)='' OR char_length(p_name)>200
    OR NOT vm_private.vm_numeric_valid(p_price,8,999999999999.99999999,true)
    OR p_components IS NULL OR jsonb_typeof(p_components)<>'array' THEN
  RAISE EXCEPTION 'Parâmetros de produto inválidos' USING ERRCODE='22023';
 END IF;
 IF p_category IS NOT NULL AND (btrim(p_category)='' OR char_length(p_category)>120) THEN RAISE EXCEPTION 'Categoria inválida' USING ERRCODE='22023'; END IF;
 SELECT count(*)::integer,count(DISTINCT c.material_id)::integer,
        COALESCE(bool_and(c.material_id IS NOT NULL AND c.quantity IS NOT NULL
          AND c.quantity>0 AND vm_private.vm_numeric_valid(c.quantity,8,999999999999.99999999,true)),true)
 INTO v_count,v_materials,v_values_ok
 FROM jsonb_to_recordset(p_components) AS c(material_id uuid,quantity numeric);
 IF v_count<>v_materials OR NOT v_values_ok THEN
  RAISE EXCEPTION 'Componentes devem ter material_id único e quantidade positiva com até 8 casas' USING ERRCODE='22023';
 END IF;
 PERFORM 1 FROM public.vm_organizations AS o WHERE o.id=p_organization_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Organização não encontrada' USING ERRCODE='23503'; END IF;
 SELECT count(*)::integer INTO v_materials
 FROM public.vm_materials AS m
 JOIN jsonb_to_recordset(p_components) AS c(material_id uuid,quantity numeric) ON c.material_id=m.id
 WHERE m.organization_id=p_organization_id;
 IF v_materials<>v_count THEN RAISE EXCEPTION 'Todos os componentes devem ser insumos da mesma organização' USING ERRCODE='23503'; END IF;
 IF v_product IS NULL THEN
  INSERT INTO public.vm_products(organization_id,name,category,price,current_version)
  VALUES (p_organization_id,btrim(p_name),NULLIF(btrim(p_category),''),p_price,1)
  RETURNING id,current_version INTO v_product,v_version;
 ELSE
  SELECT p.current_version INTO v_version
  FROM public.vm_products AS p
  WHERE p.organization_id=p_organization_id AND p.id=v_product
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Produto não encontrado nesta organização' USING ERRCODE='23503'; END IF;
  v_version:=v_version+1;
  UPDATE public.vm_products AS p
  SET name=btrim(p_name),category=NULLIF(btrim(p_category),''),price=p_price,current_version=v_version
  WHERE p.organization_id=p_organization_id AND p.id=v_product;
 END IF;
 INSERT INTO public.vm_product_components(organization_id,product_id,product_version,material_id,quantity)
 SELECT p_organization_id,v_product,v_version,c.material_id,c.quantity::numeric(20,8)
 FROM jsonb_to_recordset(p_components) AS c(material_id uuid,quantity numeric);
 RETURN QUERY SELECT v_product,v_version,p_price,v_count;
END;
$function$;

-- Policies/grants explícitos: sem DML direto nos saldos, movimentos, compras
-- ou lançamentos. As views têm SELECT autenticado; anon não recebe nada.
REVOKE ALL ON TABLE vm_private.vm_material_creation_requests FROM PUBLIC,anon,authenticated;
REVOKE ALL ON TABLE public.vm_material_purchases,public.vm_cash_entries FROM PUBLIC,anon,authenticated;
GRANT SELECT ON TABLE public.vm_material_purchases,public.vm_cash_entries TO authenticated;
REVOKE ALL ON TABLE public.vm_materials_read,public.vm_stock_movements_read,public.vm_material_purchases_read,public.vm_cash_entries_read FROM PUBLIC,anon,authenticated;
GRANT SELECT ON TABLE public.vm_materials_read,public.vm_stock_movements_read,public.vm_material_purchases_read,public.vm_cash_entries_read TO authenticated;

REVOKE ALL ON FUNCTION vm_private.vm_numeric_valid(numeric,integer,numeric,boolean),vm_private.vm_date_valid(date),vm_private.vm_reject_cash_entry_mutation(),vm_private.vm_reject_purchase_mutation() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.vm_create_material(uuid,text,text,numeric,numeric,numeric,numeric,text,uuid,uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.vm_receive_material(uuid,uuid,numeric,numeric,numeric,text,uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.vm_adjust_material_stock(uuid,uuid,numeric,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.vm_adjust_material_stock_safe(uuid,uuid,numeric,text,uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.vm_update_material(uuid,uuid,text,numeric,text,uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.vm_create_material_purchase(uuid,uuid,numeric,numeric,date,text,date,uuid,uuid,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.vm_upsert_product(uuid,text,numeric,text,jsonb,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.vm_create_material(uuid,text,text,numeric,numeric,numeric,numeric,text,uuid,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.vm_receive_material(uuid,uuid,numeric,numeric,numeric,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.vm_adjust_material_stock_safe(uuid,uuid,numeric,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.vm_update_material(uuid,uuid,text,numeric,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.vm_create_material_purchase(uuid,uuid,numeric,numeric,date,text,date,uuid,uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.vm_upsert_product(uuid,text,numeric,text,jsonb,uuid) TO authenticated;

DO $publication$
DECLARE v_table text;
BEGIN
 IF EXISTS (SELECT 1 FROM pg_catalog.pg_publication WHERE pubname='supabase_realtime' AND puballtables) THEN RETURN; END IF;
 IF EXISTS (SELECT 1 FROM pg_catalog.pg_publication WHERE pubname='supabase_realtime') THEN
  FOREACH v_table IN ARRAY ARRAY['vm_material_purchases','vm_cash_entries'] LOOP
   IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_publication_tables WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename=v_table) THEN
    EXECUTE pg_catalog.format('ALTER PUBLICATION %I ADD TABLE %I.%I','supabase_realtime','public',v_table);
   END IF;
  END LOOP;
 END IF;
END;
$publication$;

INSERT INTO public.vm_schema_migrations(version,description)
VALUES ('20261029221500_inventory','Inventário operacional, edição controlada, ajustes idempotentes, compras e lançamentos de despesa')
ON CONFLICT (version) DO NOTHING;

NOTIFY pgrst, 'reload schema';
COMMIT;
