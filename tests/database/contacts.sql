-- Contacts contract suite. The runner applies foundation, inventory, Products
-- and Contacts in the marked local vm_test database. Every business fixture is
-- local and uses the real auth.uid/auth.role/auth.jwt helper contract.
CREATE TEMP TABLE qa_test_results (
  ordinal integer GENERATED ALWAYS AS IDENTITY,
  label text NOT NULL
) ON COMMIT PRESERVE ROWS;
CREATE OR REPLACE FUNCTION pg_temp.assert_true(p_condition boolean, p_label text)
RETURNS void LANGUAGE plpgsql AS $function$
BEGIN
  IF NOT COALESCE(p_condition,false) THEN
    RAISE EXCEPTION 'assertion failed: %',p_label USING ERRCODE='P0001';
  END IF;
END
$function$;
CREATE OR REPLACE FUNCTION pg_temp.assert_raises(p_label text,p_sqlstate text,p_statement text)
RETURNS void LANGUAGE plpgsql AS $function$
DECLARE v_sqlstate text;
BEGIN
  BEGIN
    EXECUTE p_statement;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate=RETURNED_SQLSTATE;
    IF p_sqlstate IS NULL OR v_sqlstate=p_sqlstate THEN RETURN; END IF;
    RAISE EXCEPTION 'assertion failed: % (unexpected SQLSTATE)',p_label USING ERRCODE='P0001';
  END;
  RAISE EXCEPTION 'assertion failed: % (expected error)',p_label USING ERRCODE='P0001';
END
$function$;
CREATE OR REPLACE FUNCTION pg_temp.pass_test(p_label text)
RETURNS void LANGUAGE sql AS $function$
  INSERT INTO pg_temp.qa_test_results(label) VALUES (p_label)
$function$;
GRANT INSERT ON qa_test_results TO authenticated,anon;

CREATE TEMP TABLE qa_identity(user_a uuid NOT NULL,user_b uuid NOT NULL) ON COMMIT DROP;
INSERT INTO qa_identity VALUES
 ('00000000-0000-0000-0000-0000000000a1'::uuid,
  '00000000-0000-0000-0000-0000000000b2'::uuid);
CREATE TEMP TABLE qa_orgs(
  user_id uuid NOT NULL,
  organization_id uuid PRIMARY KEY,
  membership_id uuid NOT NULL
) ON COMMIT DROP;
CREATE TEMP TABLE qa_client_a(contact_id uuid NOT NULL) ON COMMIT DROP;
CREATE TEMP TABLE qa_supplier_a(contact_id uuid NOT NULL) ON COMMIT DROP;
CREATE TEMP TABLE qa_supplier_b(contact_id uuid NOT NULL) ON COMMIT DROP;
CREATE TEMP TABLE qa_materials_a(material_id uuid NOT NULL,unit text NOT NULL) ON COMMIT DROP;
CREATE TEMP TABLE qa_import(batch_key uuid,created text,updated text,skipped text) ON COMMIT DROP;
GRANT SELECT ON qa_identity,qa_orgs,qa_client_a,qa_supplier_a,qa_supplier_b,qa_materials_a,qa_import TO authenticated,anon;
GRANT INSERT ON qa_orgs,qa_client_a,qa_supplier_a,qa_supplier_b,qa_materials_a,qa_import TO authenticated;

-- Two organizations are created by the public organization RPC, not by an
-- administrator fixture. The only local auth users are the runner identities.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','authenticated')::text,true);
INSERT INTO qa_orgs
SELECT i.user_a,c.organization_id,c.membership_id
FROM qa_identity AS i
CROSS JOIN LATERAL public.vm_create_organization('Contacts tenant A') AS c;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_b::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_b::text FROM qa_identity),'role','authenticated')::text,true);
INSERT INTO qa_orgs
SELECT i.user_b,c.organization_id,c.membership_id
FROM qa_identity AS i
CROSS JOIN LATERAL public.vm_create_organization('Contacts tenant B') AS c;
SELECT pg_temp.assert_true((SELECT count(*) FROM qa_orgs)=2,'contacts fixtures create two organizations through Auth');
SELECT pg_temp.assert_true(NOT has_table_privilege('authenticated','public.vm_memberships','INSERT'),'authenticated cannot tamper with memberships');
SELECT pg_temp.assert_true(NOT has_table_privilege('anon','public.vm_clients_read','SELECT'),'anon has no contact view grant');
SELECT pg_temp.assert_true(has_table_privilege('authenticated','public.vm_clients_read','SELECT') AND has_table_privilege('authenticated','public.vm_suppliers_read','SELECT'),'authenticated can read contact views');
SELECT pg_temp.assert_true(has_function_privilege('authenticated','public.vm_upsert_contact(uuid,text,jsonb,uuid,uuid)','EXECUTE'),'authenticated can execute contact upsert');
SELECT pg_temp.assert_true(NOT has_function_privilege('anon','public.vm_upsert_contact(uuid,text,jsonb,uuid,uuid)','EXECUTE'),'anon cannot execute contact upsert');
SELECT pg_temp.pass_test('RLS grants and real Auth fixture contract');

-- A client is normalized through the RPC: optional blanks become null, email
-- is lower-case, phone spaces are canonicalized, and nested address values
-- are trimmed/upper-cased. The fiscal identifier is only format-validated.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','authenticated')::text,true);
INSERT INTO qa_client_a
SELECT contact_id
FROM public.vm_upsert_contact(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 'client',
 '{"name":"  Ana da Vila  ","email":" Ana@Example.COM ","phone":"11   9999 0000","notes":"  observação  ","person_type":"individual","tax_id":"12345678901","birth_date":"1990-05-04","address":{"postal_code":" 01001-000 ","street":" Rua A ","number":" 10 ","city":" São Paulo ","state":" sp "}}'::jsonb,
 NULL,'30000000-0000-0000-0000-000000000001'::uuid);
SELECT pg_temp.assert_true((SELECT name FROM public.vm_clients WHERE id=(SELECT contact_id FROM qa_client_a))='Ana da Vila','client name is trimmed');
SELECT pg_temp.assert_true((SELECT email FROM public.vm_clients WHERE id=(SELECT contact_id FROM qa_client_a))='ana@example.com','client email is normalized');
SELECT pg_temp.assert_true((SELECT phone FROM public.vm_clients WHERE id=(SELECT contact_id FROM qa_client_a))='11 9999 0000','client phone whitespace is normalized');
SELECT pg_temp.assert_true((SELECT address->>'state' FROM public.vm_clients WHERE id=(SELECT contact_id FROM qa_client_a))='SP','address state is normalized');
SELECT pg_temp.assert_true((SELECT tax_id FROM public.vm_clients WHERE id=(SELECT contact_id FROM qa_client_a))='12345678901','tax id is stored as supplied digits only');
SELECT pg_temp.assert_true((SELECT birth_date FROM public.vm_clients WHERE id=(SELECT contact_id FROM qa_client_a))='1990-05-04'::date,'client birth date is stored as SQL date');
SELECT pg_temp.pass_test('client normalization and shape persistence');

-- Supplier creation is also idempotent and remains the original inventory
-- table source. Two different units are deliberately used to prove the view
-- never adds grams to lengths.
INSERT INTO qa_supplier_a
SELECT contact_id
FROM public.vm_upsert_contact(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 'supplier',
 '{"name":" Papel e Cia ","email":" contato@papel.example ","phone":"11 3333 4444","notes":"prazo","person_type":"business","tax_id":"12345678901234","website":"https://papel.example/catalogo","address":{"city":"Campinas","state":"sp"}}'::jsonb,
 NULL,'30000000-0000-0000-0000-000000000002'::uuid);
INSERT INTO qa_materials_a
SELECT m.material_id,'g'::text
FROM public.vm_create_material(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 'Papel de teste','g',10::numeric,2::numeric,3::numeric,0::numeric,NULL::text,
 (SELECT contact_id FROM qa_supplier_a),'30000000-0000-0000-0000-000000000003'::uuid) AS m;
INSERT INTO qa_materials_a
SELECT m.material_id,'cm'::text
FROM public.vm_create_material(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 'Fita de teste','cm',4::numeric,2::numeric,2::numeric,0::numeric,NULL::text,
 (SELECT contact_id FROM qa_supplier_a),'30000000-0000-0000-0000-000000000004'::uuid) AS m;
SELECT pg_temp.assert_true((SELECT id FROM public.vm_suppliers WHERE id=(SELECT contact_id FROM qa_supplier_a))=(SELECT contact_id FROM qa_supplier_a),'inventory keeps supplier id/origin');
SELECT pg_temp.assert_true((SELECT material_count FROM public.vm_suppliers_read WHERE id=(SELECT contact_id FROM qa_supplier_a))='2','supplier material count is textual');
SELECT pg_temp.assert_true((SELECT current_stock_cost FROM public.vm_suppliers_read WHERE id=(SELECT contact_id FROM qa_supplier_a))='19.00000000','supplier current stock cost is database-derived text');
SELECT pg_temp.assert_true((SELECT stocks_by_unit::jsonb FROM public.vm_suppliers_read WHERE id=(SELECT contact_id FROM qa_supplier_a)) = '{"g":"3.00000000","cm":"2.00000000"}'::jsonb,'supplier stocks keep units separate');
SELECT pg_temp.assert_true((SELECT data_type FROM information_schema.columns WHERE table_schema='public' AND table_name='vm_suppliers_read' AND column_name='current_stock_cost')='text','supplier cost DTO is text');
SELECT pg_temp.pass_test('supplier inventory aggregates and textual DTOs');

-- Same idempotency key and exact payload returns the same id. A different
-- payload on that key is a collision, not a second contact or an overwrite.
SELECT pg_temp.assert_true(
 (SELECT contact_id FROM public.vm_upsert_contact(
   (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
   'client','{"name":"Ana da Vila","email":"ana@example.com","phone":"11 9999 0000","notes":"observação","person_type":"individual","tax_id":"12345678901","birth_date":"1990-05-04","address":{"postal_code":"01001-000","street":"Rua A","number":"10","district":null,"complement":null,"city":"São Paulo","state":"SP"}}'::jsonb,
   NULL,'30000000-0000-0000-0000-000000000001'::uuid))=(SELECT contact_id FROM qa_client_a),
 'same upsert key and canonical payload returns same contact');
SELECT pg_temp.assert_raises('upsert key payload mismatch','23505',format($sql$SELECT * FROM public.vm_upsert_contact('%s','client','{"name":"Outra pessoa"}'::jsonb,'%s','30000000-0000-0000-0000-000000000001'::uuid)$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT contact_id FROM qa_client_a)));
SELECT pg_temp.assert_true(
 (SELECT contact_id FROM public.vm_upsert_contact(
   (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
   'client','{"name":"Ana da Vila","email":"NEW@EXAMPLE.COM","person_type":"individual","tax_id":"12345678901"}'::jsonb,
   (SELECT contact_id FROM qa_client_a),'30000000-0000-0000-0000-000000000005'::uuid))=(SELECT contact_id FROM qa_client_a),
 'explicit contact id updates without changing identity');
SELECT pg_temp.assert_true((SELECT email FROM public.vm_clients WHERE id=(SELECT contact_id FROM qa_client_a))='new@example.com','explicit update is normalized');
SELECT pg_temp.pass_test('contact idempotency collision and immutable identity');

-- Constraints happen before any row is made; unknown keys are rejected and a
-- business client cannot carry a birth date. javascript is never a website.
SELECT pg_temp.assert_raises('unknown contact field rejected','22023',format($sql$SELECT * FROM public.vm_upsert_contact('%s','client','{"name":"bad","mystery":true}'::jsonb,NULL,'30000000-0000-0000-0000-000000000006'::uuid)$sql$,(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))));
SELECT pg_temp.assert_raises('future birth date rejected','22023',format($sql$SELECT * FROM public.vm_upsert_contact('%s','client','{"name":"future","birth_date":"2999-01-01"}'::jsonb,NULL,'30000000-0000-0000-0000-000000000007'::uuid)$sql$,(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))));
SELECT pg_temp.assert_raises('business birth date rejected','22023',format($sql$SELECT * FROM public.vm_upsert_contact('%s','client','{"name":"business","person_type":"business","birth_date":"1990-01-01"}'::jsonb,NULL,'30000000-0000-0000-0000-000000000008'::uuid)$sql$,(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))));
SELECT pg_temp.assert_raises('javascript website rejected','22023',format($sql$SELECT * FROM public.vm_upsert_contact('%s','supplier','{"name":"bad site","website":"javascript:alert(1)"}'::jsonb,NULL,'30000000-0000-0000-0000-000000000009'::uuid)$sql$,(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))));
SELECT pg_temp.assert_raises('invalid address shape rejected','22023',format($sql$SELECT * FROM public.vm_upsert_contact('%s','client','{"name":"bad address","address":{"city":42}}'::jsonb,NULL,'30000000-0000-0000-0000-000000000010'::uuid)$sql$,(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))));
SELECT pg_temp.assert_raises('invalid tax id rejected','22023',format($sql$SELECT * FROM public.vm_upsert_contact('%s','client','{"name":"bad tax","tax_id":"123.456.789-01"}'::jsonb,NULL,'30000000-0000-0000-0000-000000000011'::uuid)$sql$,(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))));
SELECT pg_temp.assert_true((SELECT count(*) FROM public.vm_clients WHERE name IN ('future','business','bad address','bad tax'))=0,'invalid contact payloads create no rows');
SELECT pg_temp.pass_test('contact payload, date and site validation');
SELECT pg_temp.assert_true((SELECT contact_id FROM public.vm_upsert_contact((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),'client',jsonb_build_object('name','Alpha CNPJ local','person_type','business','tax_id',repeat('a',12)||'01'),NULL,'30000000-0000-0000-0000-000000000040'::uuid)) IS NOT NULL,'alphanumeric CNPJ accepted in local fixture');
SELECT pg_temp.assert_true((SELECT tax_id FROM public.vm_clients WHERE name='Alpha CNPJ local')=repeat('A',12)||'01','CNPJ letters normalize to uppercase without losing leading characters');
SELECT pg_temp.assert_raises('CNPJ check positions remain numeric','22023',format($sql$SELECT * FROM public.vm_upsert_contact('%s','client',jsonb_build_object('name','invalid check','tax_id',repeat('A',14)),NULL,'30000000-0000-0000-0000-000000000041'::uuid)$sql$,(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))));
SELECT pg_temp.pass_test('numeric and alphanumeric CNPJ format coexistence');

-- Tax ids are unique only inside an organization. Names without tax ids do not
-- cause false merges, while a duplicate tax id is an explicit conflict.
SELECT pg_temp.assert_raises('duplicate client tax id rejected','23505',format($sql$SELECT * FROM public.vm_upsert_contact('%s','client','{"name":"Different name","tax_id":"12345678901"}'::jsonb,NULL,'30000000-0000-0000-0000-000000000012'::uuid)$sql$,(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))));
SELECT pg_temp.assert_true(
 (SELECT contact_id FROM public.vm_upsert_contact((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),'client','{"name":"Ana da Vila"}'::jsonb,NULL,'30000000-0000-0000-0000-000000000013'::uuid)) IS NOT NULL,
 'same name without tax id is a distinct contact');
SELECT pg_temp.assert_true((SELECT count(*) FROM public.vm_clients WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)) AND name='Ana da Vila')=2,'name matching never merges without tax policy');
SELECT pg_temp.pass_test('tax id uniqueness and no false name merge');

-- The other tenant cannot read or mutate tenant A; an out-of-tenant contact id
-- is never returned by an update path. The legacy direct write grants remain off.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_b::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_b::text FROM qa_identity),'role','authenticated')::text,true);
SELECT pg_temp.assert_true((SELECT count(*) FROM public.vm_clients_read WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)))=0,'tenant B cannot read client view A');
SELECT pg_temp.assert_true((SELECT count(*) FROM public.vm_suppliers_read WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)))=0,'tenant B cannot read supplier view A');
SELECT pg_temp.assert_raises('cross tenant upsert is forbidden','42501',format($sql$SELECT * FROM public.vm_upsert_contact('%s','client','{"name":"cross"}'::jsonb,NULL,'30000000-0000-0000-0000-000000000014'::uuid)$sql$,(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))));
SELECT pg_temp.assert_raises('contact id from another tenant is hidden','23503',format($sql$SELECT * FROM public.vm_upsert_contact('%s','client','{"name":"cross"}'::jsonb,'%s','30000000-0000-0000-0000-000000000015'::uuid)$sql$,(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_b FROM qa_identity)),(SELECT contact_id FROM qa_client_a)));
SELECT pg_temp.assert_true(NOT has_table_privilege('authenticated','public.vm_clients','INSERT') AND NOT has_table_privilege('authenticated','public.vm_clients','UPDATE') AND NOT has_table_privilege('authenticated','public.vm_clients','DELETE'),'legacy client CRUD grants are revoked');
SELECT pg_temp.assert_true(NOT has_table_privilege('authenticated','public.vm_suppliers','INSERT') AND NOT has_table_privilege('authenticated','public.vm_suppliers','UPDATE') AND NOT has_table_privilege('authenticated','public.vm_suppliers','DELETE'),'legacy supplier CRUD grants are revoked');
SELECT pg_temp.assert_true(NOT has_column_privilege('authenticated','public.vm_clients','name','INSERT') AND NOT has_column_privilege('authenticated','public.vm_clients','name','UPDATE'),'legacy client column grants are revoked');
SELECT pg_temp.assert_true(NOT has_column_privilege('authenticated','public.vm_suppliers','name','INSERT') AND NOT has_column_privilege('authenticated','public.vm_suppliers','name','UPDATE'),'legacy supplier column grants are revoked');
SELECT pg_temp.pass_test('cross tenant RLS and legacy CRUD barriers');

-- Return to owner A for archive and import operations.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','authenticated')::text,true);
SELECT pg_temp.assert_true((SELECT archived_at FROM public.vm_suppliers WHERE id=(SELECT contact_id FROM qa_supplier_a)) IS NULL,'new supplier is active');
SELECT pg_temp.assert_true((SELECT event_id FROM public.vm_archive_contact((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),'supplier',(SELECT contact_id FROM qa_supplier_a),true,'fornecedor encerrado')) IS NOT NULL,'archive writes an audit event');
SELECT pg_temp.assert_true((SELECT archived_at FROM public.vm_suppliers_read WHERE id=(SELECT contact_id FROM qa_supplier_a)) IS NOT NULL,'archived supplier remains readable');
SELECT pg_temp.assert_true((SELECT count(*) FROM public.vm_contact_events WHERE contact_id=(SELECT contact_id FROM qa_supplier_a) AND event_type='archived')=1,'archive event is readable by tenant');
SELECT pg_temp.assert_true((SELECT reason FROM public.vm_contact_events WHERE contact_id=(SELECT contact_id FROM qa_supplier_a) AND event_type='archived')='fornecedor encerrado','archive reason persists');
SELECT pg_temp.assert_true((SELECT supplier_id FROM public.vm_materials WHERE id=(SELECT material_id FROM qa_materials_a LIMIT 1))=(SELECT contact_id FROM qa_supplier_a),'archive preserves material reference');
SELECT pg_temp.assert_true((SELECT event_id FROM public.vm_archive_contact((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),'supplier',(SELECT contact_id FROM qa_supplier_a),true,'retry archive')) IS NULL,'repeated archive does not duplicate audit event');
SELECT pg_temp.assert_true((SELECT count(*) FROM public.vm_contact_events WHERE contact_id=(SELECT contact_id FROM qa_supplier_a))=1,'archive history remains append-only');
SELECT pg_temp.assert_raises('direct contact delete is denied','42501',format($sql$DELETE FROM public.vm_suppliers WHERE id='%s'$sql$,(SELECT contact_id FROM qa_supplier_a)));
SELECT pg_temp.pass_test('archive, audit reason and historical material reference');

-- Import validates all rows before mutation. Matching tax ids are skipped by
-- policy; exact duplicate rows in the same batch are also skipped.
INSERT INTO qa_import
SELECT * FROM public.vm_import_contacts(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 'client',
 jsonb_build_array(
   jsonb_build_object('name','Import one','tax_id','11111111111','email','ONE@EXAMPLE.COM'),
   jsonb_build_object('name','Import two','phone','99 1111 2222'),
   jsonb_build_object('name','Import two','phone','99 1111 2222')
 ),
 '30000000-0000-0000-0000-000000000020'::uuid);
SELECT pg_temp.assert_true((SELECT created FROM qa_import)='2' AND (SELECT updated FROM qa_import)='0' AND (SELECT skipped FROM qa_import)='1','import creates and exact-deduplicates rows with text counters');
SELECT pg_temp.assert_true((SELECT count(*) FROM public.vm_clients WHERE name IN ('Import one','Import two'))=2,'import rows are persisted');
SELECT pg_temp.assert_true((SELECT created FROM public.vm_import_contacts(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),'client',
 jsonb_build_array(jsonb_build_object('name','Import one','tax_id','11111111111','email','ONE@EXAMPLE.COM'),jsonb_build_object('name','Import two','phone','99 1111 2222'),jsonb_build_object('name','Import two','phone','99 1111 2222')),
 '30000000-0000-0000-0000-000000000020'::uuid))='2','import replay returns stored result');
SELECT pg_temp.assert_raises('import key payload mismatch','23505',format($sql$SELECT * FROM public.vm_import_contacts('%s','client','[{"name":"different"}]'::jsonb,'30000000-0000-0000-0000-000000000020'::uuid)$sql$,(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))));
SELECT pg_temp.assert_true((SELECT created FROM public.vm_import_contacts(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),'client',
 jsonb_build_array(jsonb_build_object('name','Existing tax','tax_id','12345678901')),
 '30000000-0000-0000-0000-000000000021'::uuid))='0','import skips an existing matching tax id');
SELECT pg_temp.assert_true((SELECT skipped FROM public.vm_import_contacts(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),'client',
 jsonb_build_array(jsonb_build_object('name','Existing tax','tax_id','12345678901')),
 '30000000-0000-0000-0000-000000000021'::uuid))='1','unrelated replay uses exact original counters');
SELECT pg_temp.pass_test('transactional import idempotency and safe tax matching');

SELECT pg_temp.assert_raises('invalid import row aborts full batch','22023',format($sql$SELECT * FROM public.vm_import_contacts('%s','supplier','[{"name":"Must rollback"},{"name":"bad","website":"javascript:bad"}]'::jsonb,'30000000-0000-0000-0000-000000000022'::uuid)$sql$,(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))));
SELECT pg_temp.assert_true((SELECT count(*) FROM public.vm_suppliers WHERE name='Must rollback')=0,'invalid import leaves no half-success row');
SELECT pg_temp.assert_raises('import over 500 rows rejected','22023',format($sql$SELECT * FROM public.vm_import_contacts('%s','client',(SELECT jsonb_agg(jsonb_build_object('name','row '||g)) FROM generate_series(1,501) AS gs(g)),'30000000-0000-0000-0000-000000000023'::uuid)$sql$,(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))));
SELECT pg_temp.pass_test('import all-or-nothing validation and row limit');

RESET ROLE;
SELECT pg_temp.assert_true(current_user='ubuntu','contacts suite returns to local admin');
UPDATE public.vm_memberships SET role='viewer' WHERE user_id=(SELECT user_b FROM qa_identity);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_b::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_b::text FROM qa_identity),'role','authenticated')::text,true);
SELECT pg_temp.assert_raises('viewer cannot create contact','42501',format($sql$SELECT * FROM public.vm_upsert_contact('%s','client','{"name":"blocked"}'::jsonb,NULL,'30000000-0000-0000-0000-000000000030'::uuid)$sql$,(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_b FROM qa_identity))));
SELECT pg_temp.assert_raises('viewer cannot import contacts','42501',format($sql$SELECT * FROM public.vm_import_contacts('%s','client','[{"name":"blocked"}]'::jsonb,'30000000-0000-0000-0000-000000000031'::uuid)$sql$,(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_b FROM qa_identity))));
RESET ROLE;
UPDATE public.vm_memberships SET role='finance' WHERE user_id=(SELECT user_b FROM qa_identity);
SET LOCAL ROLE authenticated;
SELECT pg_temp.assert_true((SELECT contact_id FROM public.vm_upsert_contact((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_b FROM qa_identity)),'client','{"name":"Finance local contact"}'::jsonb,NULL,'30000000-0000-0000-0000-000000000032'::uuid)) IS NOT NULL,'finance can create own tenant contact without UID spoof');
SELECT pg_temp.pass_test('viewer mutation barrier and finance contact permission');
RESET ROLE;
