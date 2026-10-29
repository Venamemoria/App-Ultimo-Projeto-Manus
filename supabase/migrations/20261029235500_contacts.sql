BEGIN;

-- Cadastros: a tabela legada permanece como fonte de leitura do inventário;
-- novas escritas passam exclusivamente pelas RPCs abaixo.
ALTER TABLE public.vm_clients
  ADD COLUMN person_type text NOT NULL DEFAULT 'individual',
  ADD COLUMN tax_id text,
  ADD COLUMN birth_date date,
  ADD COLUMN address jsonb,
  ADD COLUMN archived_at timestamptz;

ALTER TABLE public.vm_suppliers
  ADD COLUMN person_type text NOT NULL DEFAULT 'individual',
  ADD COLUMN tax_id text,
  ADD COLUMN address jsonb,
  ADD COLUMN website text,
  ADD COLUMN archived_at timestamptz;

CREATE OR REPLACE FUNCTION vm_private.vm_contact_address_valid(p_value jsonb)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog,public,vm_private
AS $function$
DECLARE
  v_key text;
  v_value text;
BEGIN
  IF p_value IS NULL OR pg_catalog.jsonb_typeof(p_value) = 'null' THEN
    RETURN true;
  END IF;
  IF pg_catalog.jsonb_typeof(p_value) <> 'object' THEN
    RETURN false;
  END IF;
  FOR v_key IN SELECT key FROM pg_catalog.jsonb_each(p_value) LOOP
    IF v_key NOT IN ('postal_code','street','number','district','complement','city','state') THEN
      RETURN false;
    END IF;
    IF pg_catalog.jsonb_typeof(p_value -> v_key) NOT IN ('string','null') THEN
      RETURN false;
    END IF;
    IF pg_catalog.jsonb_typeof(p_value -> v_key) = 'string' THEN
      v_value := p_value ->> v_key;
      IF pg_catalog.btrim(v_value) = '' THEN
        RETURN false;
      END IF;
      IF v_key = 'postal_code' AND pg_catalog.char_length(pg_catalog.btrim(v_value)) > 20 THEN RETURN false; END IF;
      IF v_key = 'street' AND pg_catalog.char_length(pg_catalog.btrim(v_value)) > 200 THEN RETURN false; END IF;
      IF v_key = 'number' AND pg_catalog.char_length(pg_catalog.btrim(v_value)) > 40 THEN RETURN false; END IF;
      IF v_key = 'district' AND pg_catalog.char_length(pg_catalog.btrim(v_value)) > 120 THEN RETURN false; END IF;
      IF v_key = 'complement' AND pg_catalog.char_length(pg_catalog.btrim(v_value)) > 120 THEN RETURN false; END IF;
      IF v_key = 'city' AND pg_catalog.char_length(pg_catalog.btrim(v_value)) > 120 THEN RETURN false; END IF;
      IF v_key = 'state' AND pg_catalog.char_length(pg_catalog.btrim(v_value)) <> 2 THEN RETURN false; END IF;
    END IF;
  END LOOP;
  RETURN true;
END
$function$;

ALTER TABLE public.vm_clients
  ADD CONSTRAINT vm_clients_person_type_ck CHECK (person_type IN ('individual','business')),
  ADD CONSTRAINT vm_clients_tax_id_ck CHECK (tax_id IS NULL OR tax_id ~ '^([0-9]{11}|[A-Z0-9]{12}[0-9]{2})$'),
  ADD CONSTRAINT vm_clients_email_ck CHECK (email IS NULL OR (btrim(email) = email AND char_length(email) BETWEEN 3 AND 320 AND email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$')),
  ADD CONSTRAINT vm_clients_phone_ck CHECK (phone IS NULL OR (btrim(phone) = phone AND char_length(phone) BETWEEN 1 AND 100)),
  ADD CONSTRAINT vm_clients_notes_ck CHECK (notes IS NULL OR char_length(notes) <= 5000),
  ADD CONSTRAINT vm_clients_birth_date_ck CHECK (birth_date IS NULL OR (vm_private.vm_date_valid(birth_date) AND birth_date <= CURRENT_DATE)),
  ADD CONSTRAINT vm_clients_business_birth_date_ck CHECK (person_type <> 'business' OR birth_date IS NULL),
  ADD CONSTRAINT vm_clients_address_ck CHECK (vm_private.vm_contact_address_valid(address));

ALTER TABLE public.vm_suppliers
  ADD CONSTRAINT vm_suppliers_person_type_ck CHECK (person_type IN ('individual','business')),
  ADD CONSTRAINT vm_suppliers_tax_id_ck CHECK (tax_id IS NULL OR tax_id ~ '^([0-9]{11}|[A-Z0-9]{12}[0-9]{2})$'),
  ADD CONSTRAINT vm_suppliers_email_ck CHECK (email IS NULL OR (btrim(email) = email AND char_length(email) BETWEEN 3 AND 320 AND email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$')),
  ADD CONSTRAINT vm_suppliers_phone_ck CHECK (phone IS NULL OR (btrim(phone) = phone AND char_length(phone) BETWEEN 1 AND 100)),
  ADD CONSTRAINT vm_suppliers_notes_ck CHECK (notes IS NULL OR char_length(notes) <= 5000),
  ADD CONSTRAINT vm_suppliers_address_ck CHECK (vm_private.vm_contact_address_valid(address)),
  ADD CONSTRAINT vm_suppliers_website_ck CHECK (website IS NULL OR (btrim(website) = website AND char_length(website) <= 2048 AND website ~* '^https?://[^[:space:]]+$'));

CREATE UNIQUE INDEX vm_clients_org_tax_id_uq
  ON public.vm_clients (organization_id,tax_id)
  WHERE tax_id IS NOT NULL;
CREATE UNIQUE INDEX vm_suppliers_org_tax_id_uq
  ON public.vm_suppliers (organization_id,tax_id)
  WHERE tax_id IS NOT NULL;
CREATE INDEX vm_clients_org_tax_id_idx ON public.vm_clients (organization_id,tax_id) WHERE tax_id IS NOT NULL;
CREATE INDEX vm_suppliers_org_tax_id_idx ON public.vm_suppliers (organization_id,tax_id) WHERE tax_id IS NOT NULL;
CREATE INDEX vm_clients_org_active_idx ON public.vm_clients (organization_id,archived_at,lower(name));
CREATE INDEX vm_suppliers_org_active_idx ON public.vm_suppliers (organization_id,archived_at,lower(name));

-- A alteração normal de um cadastro nunca pode trocar seu tenant, id ou origem.
CREATE OR REPLACE FUNCTION vm_private.vm_protect_contact_identity()
RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog,public,vm_private
AS $function$
BEGIN
  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.organization_id IS DISTINCT FROM OLD.organization_id
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'Identidade e organização do cadastro são imutáveis' USING ERRCODE = '55000';
  END IF;
  RETURN NEW;
END
$function$;
CREATE TRIGGER vm_clients_identity_guard
  BEFORE UPDATE ON public.vm_clients FOR EACH ROW EXECUTE FUNCTION vm_private.vm_protect_contact_identity();
CREATE TRIGGER vm_suppliers_identity_guard
  BEFORE UPDATE ON public.vm_suppliers FOR EACH ROW EXECUTE FUNCTION vm_private.vm_protect_contact_identity();

-- Os eventos são append-only e não carregam PII adicional além do motivo
-- fornecido pelo usuário. A coluna de contato é polimórfica porque clientes e
-- fornecedores usam tabelas legadas distintas, validadas pela RPC.
CREATE TABLE public.vm_contact_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
  entity text NOT NULL CHECK (entity IN ('client','supplier')),
  contact_id uuid NOT NULL,
  event_type text NOT NULL CHECK (event_type IN ('archived','unarchived')),
  archived boolean NOT NULL,
  reason text NOT NULL CHECK (btrim(reason) <> '' AND char_length(reason) <= 2000),
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id,id)
);
CREATE INDEX vm_contact_events_org_contact_idx
  ON public.vm_contact_events (organization_id,entity,contact_id,created_at DESC);
CREATE INDEX vm_contact_events_org_created_idx
  ON public.vm_contact_events (organization_id,created_at DESC);

CREATE OR REPLACE FUNCTION vm_private.vm_reject_contact_event_mutation()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog,public,vm_private
AS $function$
BEGIN
  RAISE EXCEPTION 'Evento de cadastro é somente apêndice' USING ERRCODE = '55000';
END
$function$;
CREATE TRIGGER vm_contact_events_append_only
  BEFORE UPDATE OR DELETE ON public.vm_contact_events FOR EACH ROW
  EXECUTE FUNCTION vm_private.vm_reject_contact_event_mutation();

-- Request ledgers stay outside the exposed API. RLS is enabled even though no
-- client role has a grant or policy on these tables.
CREATE TABLE vm_private.vm_contact_upsert_requests (
  organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
  entity text NOT NULL CHECK (entity IN ('client','supplier')),
  idempotency_key uuid NOT NULL,
  contact_id uuid NOT NULL,
  payload jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (organization_id,entity,idempotency_key)
);
ALTER TABLE vm_private.vm_contact_upsert_requests ENABLE ROW LEVEL SECURITY;
CREATE TABLE vm_private.vm_contact_import_requests (
  organization_id uuid NOT NULL REFERENCES public.vm_organizations(id) ON DELETE RESTRICT,
  batch_key uuid NOT NULL,
  entity text NOT NULL CHECK (entity IN ('client','supplier')),
  rows_payload jsonb NOT NULL,
  created_count integer NOT NULL DEFAULT 0 CHECK (created_count >= 0),
  updated_count integer NOT NULL DEFAULT 0 CHECK (updated_count >= 0),
  skipped_count integer NOT NULL DEFAULT 0 CHECK (skipped_count >= 0),
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (organization_id,batch_key)
);
ALTER TABLE vm_private.vm_contact_import_requests ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION vm_private.vm_contact_optional_text(
  p_data jsonb,
  p_key text,
  p_max_length integer
) RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog,public,vm_private
AS $function$
DECLARE
  v_type text := pg_catalog.jsonb_typeof(p_data -> p_key);
  v_text text;
BEGIN
  IF NOT (p_data ? p_key) OR v_type IS NULL OR v_type = 'null' THEN RETURN NULL; END IF;
  IF v_type <> 'string' THEN
    RAISE EXCEPTION 'Campo % deve ser texto ou nulo', p_key USING ERRCODE = '22023';
  END IF;
  v_text := NULLIF(pg_catalog.btrim(p_data ->> p_key),'');
  IF v_text IS NOT NULL AND pg_catalog.char_length(v_text) > p_max_length THEN
    RAISE EXCEPTION 'Campo % excede o limite permitido', p_key USING ERRCODE = '22023';
  END IF;
  RETURN v_text;
END
$function$;

CREATE OR REPLACE FUNCTION vm_private.vm_contact_address_canonical(p_value jsonb)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog,public,vm_private
AS $function$
DECLARE
  v_postal text;
  v_street text;
  v_number text;
  v_district text;
  v_complement text;
  v_city text;
  v_state text;
BEGIN
  IF p_value IS NULL OR pg_catalog.jsonb_typeof(p_value) = 'null' THEN RETURN NULL; END IF;
  IF NOT vm_private.vm_contact_address_valid(p_value) THEN
    RAISE EXCEPTION 'Endereço inválido' USING ERRCODE = '22023';
  END IF;
  v_postal := vm_private.vm_contact_optional_text(p_value,'postal_code',20);
  v_street := vm_private.vm_contact_optional_text(p_value,'street',200);
  v_number := vm_private.vm_contact_optional_text(p_value,'number',40);
  v_district := vm_private.vm_contact_optional_text(p_value,'district',120);
  v_complement := vm_private.vm_contact_optional_text(p_value,'complement',120);
  v_city := vm_private.vm_contact_optional_text(p_value,'city',120);
  v_state := vm_private.vm_contact_optional_text(p_value,'state',2);
  IF v_state IS NOT NULL THEN v_state := pg_catalog.upper(v_state); END IF;
  RETURN pg_catalog.jsonb_build_object(
    'postal_code',v_postal,'street',v_street,'number',v_number,
    'district',v_district,'complement',v_complement,'city',v_city,'state',v_state
  );
END
$function$;

CREATE OR REPLACE FUNCTION vm_private.vm_contact_canonicalize(
  p_entity text,
  p_data jsonb,
  p_contact_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = pg_catalog,public,vm_private
AS $function$
DECLARE
  v_key text;
  v_allowed text[];
  v_name text;
  v_email text;
  v_phone text;
  v_notes text;
  v_person_type text;
  v_tax_id text;
  v_birth_date date;
  v_address jsonb;
  v_website text;
  v_date_text text;
  v_type text;
BEGIN
  IF p_entity NOT IN ('client','supplier') THEN
    RAISE EXCEPTION 'Entidade de cadastro inválida' USING ERRCODE = '22023';
  END IF;
  IF p_data IS NULL OR pg_catalog.jsonb_typeof(p_data) <> 'object' THEN
    RAISE EXCEPTION 'Payload de cadastro deve ser um objeto JSON' USING ERRCODE = '22023';
  END IF;
  IF p_entity = 'client' THEN
    v_allowed := ARRAY['name','email','phone','notes','person_type','tax_id','birth_date','address'];
  ELSE
    v_allowed := ARRAY['name','email','phone','notes','person_type','tax_id','address','website'];
  END IF;
  FOR v_key IN SELECT key FROM pg_catalog.jsonb_each(p_data) LOOP
    IF NOT (v_key = ANY(v_allowed)) THEN
      RAISE EXCEPTION 'Campo de cadastro não reconhecido: %', v_key USING ERRCODE = '22023';
    END IF;
  END LOOP;
  v_type := pg_catalog.jsonb_typeof(p_data -> 'name');
  IF v_type IS DISTINCT FROM 'string' THEN
    RAISE EXCEPTION 'Nome é obrigatório e deve ser texto' USING ERRCODE = '22023';
  END IF;
  v_name := pg_catalog.btrim(p_data ->> 'name');
  IF v_name = '' OR pg_catalog.char_length(v_name) > 200 THEN
    RAISE EXCEPTION 'Nome de cadastro inválido' USING ERRCODE = '22023';
  END IF;
  v_person_type := COALESCE(NULLIF(pg_catalog.lower(vm_private.vm_contact_optional_text(p_data,'person_type',20)),''),'individual');
  IF v_person_type NOT IN ('individual','business') THEN
    RAISE EXCEPTION 'person_type deve ser individual ou business' USING ERRCODE = '22023';
  END IF;
  v_email := vm_private.vm_contact_optional_text(p_data,'email',320);
  IF v_email IS NOT NULL THEN
    v_email := pg_catalog.lower(v_email);
    IF v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' THEN
      RAISE EXCEPTION 'E-mail inválido' USING ERRCODE = '22023';
    END IF;
  END IF;
  v_phone := vm_private.vm_contact_optional_text(p_data,'phone',100);
  IF v_phone IS NOT NULL THEN v_phone := pg_catalog.regexp_replace(v_phone,'[[:space:]]+',' ','g'); END IF;
  v_notes := vm_private.vm_contact_optional_text(p_data,'notes',5000);
  v_tax_id := pg_catalog.upper(vm_private.vm_contact_optional_text(p_data,'tax_id',14));
  IF v_tax_id IS NOT NULL AND v_tax_id !~ '^([0-9]{11}|[A-Z0-9]{12}[0-9]{2})$' THEN
    RAISE EXCEPTION 'CPF deve ter 11 números; CNPJ deve ter 12 letras/números e dois dígitos finais, sem máscara' USING ERRCODE = '22023';
  END IF;
  v_address := vm_private.vm_contact_address_canonical(p_data -> 'address');
  IF p_entity = 'client' THEN
    IF p_data ? 'birth_date' THEN
      v_type := pg_catalog.jsonb_typeof(p_data -> 'birth_date');
      IF v_type IS NOT NULL AND v_type <> 'null' AND v_type <> 'string' THEN
        RAISE EXCEPTION 'birth_date deve ser uma data ISO ou nulo' USING ERRCODE = '22023';
      END IF;
    END IF;
    v_date_text := vm_private.vm_contact_optional_text(p_data,'birth_date',10);
    IF v_date_text IS NOT NULL THEN
      IF v_date_text !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
        RAISE EXCEPTION 'birth_date deve usar o formato YYYY-MM-DD' USING ERRCODE = '22023';
      END IF;
      BEGIN
        v_birth_date := v_date_text::date;
      EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'birth_date inválida' USING ERRCODE = '22023';
      END;
      IF NOT vm_private.vm_date_valid(v_birth_date) OR v_birth_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'birth_date não pode ser futura ou infinita' USING ERRCODE = '22023';
      END IF;
      IF v_person_type = 'business' THEN
        RAISE EXCEPTION 'Pessoa jurídica não pode informar birth_date' USING ERRCODE = '22023';
      END IF;
    END IF;
    RETURN pg_catalog.jsonb_build_object(
      'name',v_name,'email',v_email,'phone',v_phone,'notes',v_notes,
      'person_type',v_person_type,'tax_id',v_tax_id,'birth_date',v_birth_date,'address',v_address
    );
  END IF;
  IF p_data ? 'birth_date' THEN
    RAISE EXCEPTION 'Fornecedor não aceita birth_date' USING ERRCODE = '22023';
  END IF;
  v_website := vm_private.vm_contact_optional_text(p_data,'website',2048);
  IF v_website IS NOT NULL AND v_website !~* '^https?://[^[:space:]]+$' THEN
    RAISE EXCEPTION 'website deve usar HTTP ou HTTPS' USING ERRCODE = '22023';
  END IF;
  RETURN pg_catalog.jsonb_build_object(
    'name',v_name,'email',v_email,'phone',v_phone,'notes',v_notes,
    'person_type',v_person_type,'tax_id',v_tax_id,'address',v_address,'website',v_website
  );
END
$function$;

CREATE OR REPLACE FUNCTION vm_private.vm_contact_import_row_key(p_batch_key uuid,p_row_number integer)
RETURNS uuid LANGUAGE sql IMMUTABLE SET search_path = pg_catalog,public,vm_private
AS $function$
  SELECT pg_catalog.md5(p_batch_key::text || ':' || p_row_number::text)::uuid
$function$;

CREATE OR REPLACE FUNCTION vm_private.vm_contact_upsert_canonical(
  p_organization_id uuid,
  p_entity text,
  p_data jsonb,
  p_contact_id uuid,
  p_idempotency_key uuid
) RETURNS TABLE(contact_id uuid,created boolean,updated_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog,public,vm_private
AS $function$
DECLARE
  v_existing vm_private.vm_contact_upsert_requests%ROWTYPE;
  v_payload jsonb;
  v_id uuid;
  v_created boolean := false;
  v_updated_at timestamptz;
  v_canonical jsonb;
  v_uid uuid := auth.uid();
  v_tax_id text;
BEGIN
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'p_idempotency_key é obrigatório' USING ERRCODE = '22023';
  END IF;
  v_canonical := vm_private.vm_contact_canonicalize(p_entity,p_data,p_contact_id);
  IF p_entity NOT IN ('client','supplier') THEN
    RAISE EXCEPTION 'Entidade de cadastro inválida' USING ERRCODE = '22023';
  END IF;
  v_payload := pg_catalog.jsonb_build_object('entity',p_entity,'contact_id',p_contact_id,'data',v_canonical);
  PERFORM 1 FROM public.vm_organizations AS o WHERE o.id=p_organization_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Organização não encontrada' USING ERRCODE = '23503';
  END IF;
  SELECT r.* INTO v_existing
  FROM vm_private.vm_contact_upsert_requests AS r
  WHERE r.organization_id=p_organization_id AND r.entity=p_entity AND r.idempotency_key=p_idempotency_key
  FOR UPDATE;
  IF FOUND THEN
    IF v_existing.payload IS DISTINCT FROM v_payload THEN
      RAISE EXCEPTION 'Chave de idempotência reutilizada com payload diferente' USING ERRCODE = '23505';
    END IF;
    IF p_entity='client' THEN
      SELECT c.id,c.updated_at INTO v_id,v_updated_at FROM public.vm_clients AS c
      WHERE c.organization_id=p_organization_id AND c.id=v_existing.contact_id;
    ELSE
      SELECT s.id,s.updated_at INTO v_id,v_updated_at FROM public.vm_suppliers AS s
      WHERE s.organization_id=p_organization_id AND s.id=v_existing.contact_id;
    END IF;
    IF v_id IS NULL THEN
      RAISE EXCEPTION 'Cadastro idempotente não encontrado' USING ERRCODE = '40001';
    END IF;
    RETURN QUERY SELECT v_id,false,v_updated_at;
    RETURN;
  END IF;
  v_tax_id := v_canonical ->> 'tax_id';
  IF p_entity='client' THEN
    IF p_contact_id IS NULL THEN
      INSERT INTO public.vm_clients(organization_id,name,email,phone,notes,person_type,tax_id,birth_date,address)
      VALUES (p_organization_id,v_canonical->>'name',NULLIF(v_canonical->>'email',''),NULLIF(v_canonical->>'phone',''),NULLIF(v_canonical->>'notes',''),v_canonical->>'person_type',v_tax_id,(v_canonical->>'birth_date')::date,v_canonical->'address')
      RETURNING vm_clients.id,vm_clients.updated_at INTO v_id,v_updated_at;
      v_created := true;
    ELSE
      SELECT c.id INTO v_id FROM public.vm_clients AS c
      WHERE c.organization_id=p_organization_id AND c.id=p_contact_id FOR UPDATE;
      IF NOT FOUND THEN RAISE EXCEPTION 'Cliente não encontrado nesta organização' USING ERRCODE = '23503'; END IF;
      UPDATE public.vm_clients AS c SET name=v_canonical->>'name',email=NULLIF(v_canonical->>'email',''),phone=NULLIF(v_canonical->>'phone',''),notes=NULLIF(v_canonical->>'notes',''),person_type=v_canonical->>'person_type',tax_id=v_tax_id,birth_date=(v_canonical->>'birth_date')::date,address=v_canonical->'address'
      WHERE c.organization_id=p_organization_id AND c.id=p_contact_id
      RETURNING c.id,c.updated_at INTO v_id,v_updated_at;
    END IF;
  ELSE
    IF p_contact_id IS NULL THEN
      INSERT INTO public.vm_suppliers(organization_id,name,email,phone,notes,person_type,tax_id,address,website)
      VALUES (p_organization_id,v_canonical->>'name',NULLIF(v_canonical->>'email',''),NULLIF(v_canonical->>'phone',''),NULLIF(v_canonical->>'notes',''),v_canonical->>'person_type',v_tax_id,v_canonical->'address',NULLIF(v_canonical->>'website',''))
      RETURNING vm_suppliers.id,vm_suppliers.updated_at INTO v_id,v_updated_at;
      v_created := true;
    ELSE
      SELECT s.id INTO v_id FROM public.vm_suppliers AS s
      WHERE s.organization_id=p_organization_id AND s.id=p_contact_id FOR UPDATE;
      IF NOT FOUND THEN RAISE EXCEPTION 'Fornecedor não encontrado nesta organização' USING ERRCODE = '23503'; END IF;
      UPDATE public.vm_suppliers AS s SET name=v_canonical->>'name',email=NULLIF(v_canonical->>'email',''),phone=NULLIF(v_canonical->>'phone',''),notes=NULLIF(v_canonical->>'notes',''),person_type=v_canonical->>'person_type',tax_id=v_tax_id,address=v_canonical->'address',website=NULLIF(v_canonical->>'website','')
      WHERE s.organization_id=p_organization_id AND s.id=p_contact_id
      RETURNING s.id,s.updated_at INTO v_id,v_updated_at;
    END IF;
  END IF;
  INSERT INTO vm_private.vm_contact_upsert_requests(organization_id,entity,idempotency_key,contact_id,payload)
  VALUES (p_organization_id,p_entity,p_idempotency_key,v_id,v_payload);
  RETURN QUERY SELECT v_id,v_created,v_updated_at;
END
$function$;

CREATE OR REPLACE FUNCTION public.vm_upsert_contact(
  p_organization_id uuid,
  p_entity text,
  p_data jsonb,
  p_contact_id uuid DEFAULT NULL,
  p_idempotency_key uuid DEFAULT NULL
) RETURNS TABLE(contact_id uuid,entity text,created boolean,updated_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog,public,vm_private
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_canonical jsonb;
  v_contact uuid;
  v_created boolean;
  v_updated_at timestamptz;
BEGIN
  IF v_uid IS NULL OR auth.role() <> 'authenticated'
     OR NOT vm_private.vm_has_role(p_organization_id,ARRAY['owner','admin','finance']::text[]) THEN
    RAISE EXCEPTION 'Sem permissão para alterar cadastros nesta organização' USING ERRCODE = '42501';
  END IF;
  v_canonical := vm_private.vm_contact_canonicalize(p_entity,p_data,p_contact_id);
  SELECT r.contact_id,r.created,r.updated_at INTO v_contact,v_created,v_updated_at
  FROM vm_private.vm_contact_upsert_canonical(p_organization_id,p_entity,v_canonical,p_contact_id,p_idempotency_key) AS r;
  RETURN QUERY SELECT v_contact,p_entity,v_created,v_updated_at;
END
$function$;

CREATE OR REPLACE FUNCTION public.vm_archive_contact(
  p_organization_id uuid,
  p_entity text,
  p_contact_id uuid,
  p_archived boolean,
  p_reason text
) RETURNS TABLE(contact_id uuid,entity text,archived boolean,archived_at timestamptz,event_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog,public,vm_private
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_reason text := NULLIF(pg_catalog.btrim(p_reason),'');
  v_old_archived boolean;
  v_archived_at timestamptz;
  v_event uuid;
  v_changed boolean := false;
BEGIN
  IF v_uid IS NULL OR auth.role() <> 'authenticated'
     OR NOT vm_private.vm_has_role(p_organization_id,ARRAY['owner','admin','finance']::text[]) THEN
    RAISE EXCEPTION 'Sem permissão para arquivar cadastros nesta organização' USING ERRCODE = '42501';
  END IF;
  IF p_entity NOT IN ('client','supplier') OR p_contact_id IS NULL OR p_archived IS NULL
     OR v_reason IS NULL OR pg_catalog.char_length(v_reason)>2000 THEN
    RAISE EXCEPTION 'Parâmetros de arquivamento inválidos' USING ERRCODE = '22023';
  END IF;
  PERFORM 1 FROM public.vm_organizations AS o WHERE o.id=p_organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Organização não encontrada' USING ERRCODE = '23503'; END IF;
  IF p_entity='client' THEN
    SELECT (c.archived_at IS NOT NULL),c.archived_at INTO v_old_archived,v_archived_at
    FROM public.vm_clients AS c WHERE c.organization_id=p_organization_id AND c.id=p_contact_id FOR UPDATE;
  ELSE
    SELECT (s.archived_at IS NOT NULL),s.archived_at INTO v_old_archived,v_archived_at
    FROM public.vm_suppliers AS s WHERE s.organization_id=p_organization_id AND s.id=p_contact_id FOR UPDATE;
  END IF;
  IF v_old_archived IS NULL THEN RAISE EXCEPTION 'Cadastro não encontrado nesta organização' USING ERRCODE = '23503'; END IF;
  IF v_old_archived IS DISTINCT FROM p_archived THEN
    v_changed := true;
    v_archived_at := CASE WHEN p_archived THEN pg_catalog.clock_timestamp() ELSE NULL END;
    IF p_entity='client' THEN
      UPDATE public.vm_clients SET archived_at=v_archived_at WHERE organization_id=p_organization_id AND id=p_contact_id;
    ELSE
      UPDATE public.vm_suppliers SET archived_at=v_archived_at WHERE organization_id=p_organization_id AND id=p_contact_id;
    END IF;
    INSERT INTO public.vm_contact_events(organization_id,entity,contact_id,event_type,archived,reason,created_by)
    VALUES (p_organization_id,p_entity,p_contact_id,CASE WHEN p_archived THEN 'archived' ELSE 'unarchived' END,p_archived,v_reason,v_uid)
    RETURNING id INTO v_event;
  END IF;
  RETURN QUERY SELECT p_contact_id,p_entity,p_archived,v_archived_at,v_event;
END
$function$;

CREATE OR REPLACE FUNCTION public.vm_import_contacts(
  p_organization_id uuid,
  p_entity text,
  p_rows jsonb,
  p_key uuid
) RETURNS TABLE(batch_key uuid,created text,updated text,skipped text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog,public,vm_private
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_canonical_rows jsonb := '[]'::jsonb;
  v_row jsonb;
  v_canonical jsonb;
  v_existing vm_private.vm_contact_import_requests%ROWTYPE;
  v_rows_count integer;
  v_index integer;
  v_created integer := 0;
  v_updated integer := 0;
  v_skipped integer := 0;
  v_tax_id text;
  v_seen boolean;
  v_contact uuid;
  v_was_created boolean;
  v_updated_at timestamptz;
BEGIN
  IF v_uid IS NULL OR auth.role() <> 'authenticated'
     OR NOT vm_private.vm_has_role(p_organization_id,ARRAY['owner','admin','finance']::text[]) THEN
    RAISE EXCEPTION 'Sem permissão para importar cadastros nesta organização' USING ERRCODE = '42501';
  END IF;
  IF p_key IS NULL OR p_entity NOT IN ('client','supplier')
     OR p_rows IS NULL OR pg_catalog.jsonb_typeof(p_rows) <> 'array'
     OR pg_catalog.jsonb_array_length(p_rows) > 500 THEN
    RAISE EXCEPTION 'Importação deve conter no máximo 500 linhas válidas' USING ERRCODE = '22023';
  END IF;
  v_rows_count := pg_catalog.jsonb_array_length(p_rows);
  -- Validate and normalize every row before inserting the batch ledger or any
  -- contact. Thus one malformed CSV row rolls back the whole import.
  IF v_rows_count > 0 THEN
    FOR v_index IN 0..(v_rows_count-1) LOOP
      v_row := p_rows -> v_index;
      v_canonical := vm_private.vm_contact_canonicalize(p_entity,v_row,NULL);
      v_canonical_rows := v_canonical_rows || pg_catalog.jsonb_build_array(v_canonical);
    END LOOP;
  END IF;
  PERFORM 1 FROM public.vm_organizations AS o WHERE o.id=p_organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Organização não encontrada' USING ERRCODE = '23503'; END IF;
  SELECT r.* INTO v_existing
  FROM vm_private.vm_contact_import_requests AS r
  WHERE r.organization_id=p_organization_id AND r.batch_key=p_key
  FOR UPDATE;
  IF FOUND THEN
    IF v_existing.entity IS DISTINCT FROM p_entity OR v_existing.rows_payload IS DISTINCT FROM v_canonical_rows THEN
      RAISE EXCEPTION 'Chave de importação reutilizada com payload diferente' USING ERRCODE = '23505';
    END IF;
    RETURN QUERY SELECT p_key,v_existing.created_count::text,v_existing.updated_count::text,v_existing.skipped_count::text;
    RETURN;
  END IF;
  INSERT INTO vm_private.vm_contact_import_requests(organization_id,batch_key,entity,rows_payload,created_by)
  VALUES (p_organization_id,p_key,p_entity,v_canonical_rows,v_uid);
  IF v_rows_count > 0 THEN
    FOR v_index IN 0..(v_rows_count-1) LOOP
      v_canonical := v_canonical_rows -> v_index;
      v_tax_id := v_canonical ->> 'tax_id';
      v_seen := EXISTS (
        SELECT 1 FROM pg_catalog.jsonb_array_elements(v_canonical_rows) WITH ORDINALITY AS earlier(value,ordinality)
        WHERE (earlier.ordinality - 1) < v_index AND earlier.value = v_canonical
      );
      IF v_seen THEN
        v_skipped := v_skipped + 1;
        CONTINUE;
      END IF;
      IF v_tax_id IS NOT NULL AND (
        (p_entity='client' AND EXISTS (SELECT 1 FROM public.vm_clients c WHERE c.organization_id=p_organization_id AND c.tax_id=v_tax_id))
        OR (p_entity='supplier' AND EXISTS (SELECT 1 FROM public.vm_suppliers s WHERE s.organization_id=p_organization_id AND s.tax_id=v_tax_id))
      ) THEN
        -- Safe import policy: a matching tax id is reported as skipped; it is
        -- never a license to overwrite an existing record.
        v_skipped := v_skipped + 1;
        CONTINUE;
      END IF;
      SELECT r.contact_id,r.created,r.updated_at INTO v_contact,v_was_created,v_updated_at
      FROM vm_private.vm_contact_upsert_canonical(
        p_organization_id,p_entity,v_canonical,NULL,
        vm_private.vm_contact_import_row_key(p_key,v_index)
      ) AS r;
      IF v_was_created THEN v_created := v_created + 1; ELSE v_updated := v_updated + 1; END IF;
    END LOOP;
  END IF;
  UPDATE vm_private.vm_contact_import_requests
  SET created_count=v_created,updated_count=v_updated,skipped_count=v_skipped
  WHERE vm_contact_import_requests.organization_id=p_organization_id AND vm_contact_import_requests.batch_key=p_key;
  RETURN QUERY SELECT p_key,v_created::text,v_updated::text,v_skipped::text;
END
$function$;

-- Preserve direct SELECT for existing inventory code, but remove every
-- legacy write path. RLS remains mandatory for both tables and event reads.
DROP POLICY IF EXISTS vm_clients_write_insert ON public.vm_clients;
DROP POLICY IF EXISTS vm_clients_write_update ON public.vm_clients;
DROP POLICY IF EXISTS vm_clients_write_delete ON public.vm_clients;
DROP POLICY IF EXISTS vm_suppliers_write_insert ON public.vm_suppliers;
DROP POLICY IF EXISTS vm_suppliers_write_update ON public.vm_suppliers;
DROP POLICY IF EXISTS vm_suppliers_write_delete ON public.vm_suppliers;
CREATE POLICY vm_contact_events_member_select
  ON public.vm_contact_events FOR SELECT TO authenticated
  USING ((SELECT vm_private.vm_is_member(organization_id)));
ALTER TABLE public.vm_contact_events ENABLE ROW LEVEL SECURITY;

REVOKE INSERT,UPDATE,DELETE ON TABLE public.vm_clients,public.vm_suppliers FROM PUBLIC,anon,authenticated;
REVOKE INSERT (organization_id,name,email,phone,notes), UPDATE (name,email,phone,notes) ON public.vm_clients FROM PUBLIC,anon,authenticated;
REVOKE INSERT (organization_id,name,email,phone,notes), UPDATE (name,email,phone,notes) ON public.vm_suppliers FROM PUBLIC,anon,authenticated;
GRANT SELECT ON TABLE public.vm_clients,public.vm_suppliers TO authenticated;
REVOKE ALL ON TABLE public.vm_contact_events FROM PUBLIC,anon,authenticated;
GRANT SELECT ON TABLE public.vm_contact_events TO authenticated;
REVOKE ALL ON TABLE vm_private.vm_contact_upsert_requests,vm_private.vm_contact_import_requests FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION vm_private.vm_contact_address_valid(jsonb),vm_private.vm_contact_optional_text(jsonb,text,integer),vm_private.vm_contact_address_canonical(jsonb),vm_private.vm_contact_canonicalize(text,jsonb,uuid),vm_private.vm_contact_import_row_key(uuid,integer),vm_private.vm_contact_upsert_canonical(uuid,text,jsonb,uuid,uuid) FROM PUBLIC,anon,authenticated;

CREATE VIEW public.vm_clients_read
WITH (security_invoker = true)
AS
SELECT c.id,c.organization_id,c.name,c.email,c.phone,c.notes,c.person_type,c.tax_id,c.birth_date,c.address,c.archived_at,c.created_at,c.updated_at
FROM public.vm_clients AS c;

CREATE VIEW public.vm_suppliers_read
WITH (security_invoker = true)
AS
SELECT
  s.id,s.organization_id,s.name,s.email,s.phone,s.notes,s.person_type,s.tax_id,s.address,s.website,s.archived_at,
  s.created_at,s.updated_at,
  count(m.id)::text AS material_count,
  COALESCE((sum(m.stock_quantity * m.unit_cost))::numeric(20,8)::text,'0') AS current_stock_cost,
  COALESCE((
    SELECT pg_catalog.jsonb_object_agg(unit_totals.unit,unit_totals.quantity::text)
    FROM (
      SELECT m2.unit,sum(m2.stock_quantity)::numeric(20,8) AS quantity
      FROM public.vm_materials AS m2
      WHERE m2.organization_id=s.organization_id AND m2.supplier_id=s.id
      GROUP BY m2.unit
    ) AS unit_totals
  )::text,'{}') AS stocks_by_unit
FROM public.vm_suppliers AS s
LEFT JOIN public.vm_materials AS m
  ON m.organization_id=s.organization_id AND m.supplier_id=s.id
GROUP BY s.id,s.organization_id,s.name,s.email,s.phone,s.notes,s.person_type,s.tax_id,s.address,s.website,s.archived_at,s.created_at,s.updated_at;

REVOKE ALL ON TABLE public.vm_clients_read,public.vm_suppliers_read FROM PUBLIC,anon,authenticated;
GRANT SELECT ON TABLE public.vm_clients_read,public.vm_suppliers_read TO authenticated;
REVOKE ALL ON FUNCTION public.vm_upsert_contact(uuid,text,jsonb,uuid,uuid),public.vm_archive_contact(uuid,text,uuid,boolean,text),public.vm_import_contacts(uuid,text,jsonb,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.vm_upsert_contact(uuid,text,jsonb,uuid,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.vm_archive_contact(uuid,text,uuid,boolean,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.vm_import_contacts(uuid,text,jsonb,uuid) TO authenticated;

DO $publication$
DECLARE v_table text;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_publication WHERE pubname='supabase_realtime' AND puballtables) THEN RETURN; END IF;
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_publication WHERE pubname='supabase_realtime') THEN
    FOREACH v_table IN ARRAY ARRAY['vm_contact_events'] LOOP
      IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_publication_tables WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename=v_table) THEN
        EXECUTE pg_catalog.format('ALTER PUBLICATION %I ADD TABLE %I.%I','supabase_realtime','public',v_table);
      END IF;
    END LOOP;
  END IF;
END
$publication$;

INSERT INTO public.vm_schema_migrations(version,description)
VALUES ('20261029235500_contacts','Cadastros: clientes e fornecedores validados, idempotência, importação transacional, arquivamento, RLS e views textuais')
ON CONFLICT (version) DO NOTHING;
NOTIFY pgrst, 'reload schema';
COMMIT;
