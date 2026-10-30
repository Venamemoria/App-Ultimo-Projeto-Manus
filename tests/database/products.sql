-- Products contract suite. The runner applies foundation, inventory and Products
-- into the marked local vm_test only. No application or Supabase data is used.

CREATE TEMP TABLE qa_test_results (
  ordinal integer GENERATED ALWAYS AS IDENTITY,
  label text NOT NULL
) ON COMMIT PRESERVE ROWS;

CREATE OR REPLACE FUNCTION pg_temp.assert_true(p_condition boolean, p_label text)
RETURNS void LANGUAGE plpgsql AS $function$
BEGIN
  IF NOT COALESCE(p_condition, false) THEN
    RAISE EXCEPTION 'assertion failed: %', p_label USING ERRCODE = 'P0001';
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION pg_temp.assert_raises(p_label text, p_sqlstate text, p_statement text)
RETURNS void LANGUAGE plpgsql AS $function$
DECLARE v_sqlstate text;
BEGIN
  BEGIN
    EXECUTE p_statement;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
    IF p_sqlstate IS NULL OR v_sqlstate = p_sqlstate THEN RETURN; END IF;
    RAISE EXCEPTION 'assertion failed: % (unexpected SQLSTATE %)', p_label, v_sqlstate USING ERRCODE = 'P0001';
  END;
  RAISE EXCEPTION 'assertion failed: % (expected error)', p_label USING ERRCODE = 'P0001';
END;
$function$;

CREATE OR REPLACE FUNCTION pg_temp.pass_test(p_label text)
RETURNS void LANGUAGE sql AS $function$
  INSERT INTO pg_temp.qa_test_results(label) VALUES (p_label)
$function$;
GRANT INSERT ON qa_test_results TO authenticated, anon;

CREATE TEMP TABLE qa_identity(user_a uuid NOT NULL,user_b uuid NOT NULL) ON COMMIT DROP;
INSERT INTO qa_identity VALUES
 ('00000000-0000-0000-0000-0000000000a1'::uuid,'00000000-0000-0000-0000-0000000000b2'::uuid);
CREATE TEMP TABLE qa_orgs(user_id uuid NOT NULL,organization_id uuid PRIMARY KEY,membership_id uuid NOT NULL) ON COMMIT DROP;
CREATE TEMP TABLE qa_material_a(material_id uuid NOT NULL,opening_movement_id uuid,unit_cost numeric,stock_quantity numeric) ON COMMIT DROP;
CREATE TEMP TABLE qa_material_b(material_id uuid NOT NULL,opening_movement_id uuid,unit_cost numeric,stock_quantity numeric) ON COMMIT DROP;
CREATE TEMP TABLE qa_product_v1(product_id uuid,version text,pricing_mode text,normal_price text,promo_price text,minimum_quantity text,component_count integer,composition_cost text) ON COMMIT DROP;
CREATE TEMP TABLE qa_product_retry(product_id uuid,version text,pricing_mode text,normal_price text,promo_price text,minimum_quantity text,component_count integer,composition_cost text) ON COMMIT DROP;
CREATE TEMP TABLE qa_product_v2(product_id uuid,version text,pricing_mode text,normal_price text,promo_price text,minimum_quantity text,component_count integer,composition_cost text) ON COMMIT DROP;
CREATE TEMP TABLE qa_file(file_id uuid,organization_id uuid,product_id uuid,kind text,path text,mime_type text,size_bytes text,name text,created_by uuid,created_at timestamptz) ON COMMIT DROP;
GRANT SELECT ON qa_identity,qa_orgs,qa_material_a,qa_material_b,qa_product_v1,qa_product_retry,qa_product_v2,qa_file TO authenticated,anon;
GRANT INSERT ON qa_orgs,qa_material_a,qa_material_b,qa_product_v1,qa_product_retry,qa_product_v2,qa_file TO authenticated;

-- Real local Auth helper contract and two tenants created through the real RPC.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','authenticated')::text,true);
INSERT INTO qa_orgs
SELECT i.user_a,c.organization_id,c.membership_id FROM qa_identity i CROSS JOIN LATERAL public.vm_create_organization('Products tenant A') c;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_b::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_b::text FROM qa_identity),'role','authenticated')::text,true);
INSERT INTO qa_orgs
SELECT i.user_b,c.organization_id,c.membership_id FROM qa_identity i CROSS JOIN LATERAL public.vm_create_organization('Products tenant B') c;

INSERT INTO qa_material_b
SELECT * FROM public.vm_create_material(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_b FROM qa_identity)),
 'Material B','g',2.00000000::numeric,1.00000000::numeric,1.00000000::numeric,0::numeric,'paper',NULL::uuid,NULL::uuid);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','authenticated')::text,true);
INSERT INTO qa_material_a
SELECT * FROM public.vm_create_material(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 'Material A','g',12.00000000::numeric,3.00000000::numeric,10.00000000::numeric,0::numeric,'paper',NULL::uuid,NULL::uuid);
SELECT pg_temp.assert_true((SELECT count(*) FROM qa_orgs)=2,'products fixtures create two local tenants via Auth RPC');
SELECT pg_temp.assert_true((SELECT unit_cost FROM qa_material_a)=4.00000000::numeric,'fixture unit cost is exact');
SELECT pg_temp.pass_test('local products fixtures and exact fractional material cost');

-- Read DTOs, textual numerics, security_invoker and grants.
SELECT pg_temp.assert_true(
 (SELECT count(*) FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='public' AND c.relname IN ('vm_products_read','vm_product_components_read','vm_product_versions_read','vm_product_variants_read','vm_product_files_read')
  AND c.relkind='v' AND 'security_invoker=true'=ANY(c.reloptions))=5,
 'all Products read views use security_invoker');
SELECT pg_temp.assert_true(
 (SELECT count(*) FROM information_schema.columns
  WHERE table_schema='public' AND table_name IN ('vm_products_read','vm_product_components_read','vm_product_versions_read','vm_product_variants_read','vm_product_files_read')
    AND data_type IN ('numeric','integer','bigint'))=0,
 'all numeric Product DTO columns are text');
SELECT pg_temp.assert_true(has_table_privilege('authenticated','public.vm_products_read','SELECT') AND has_table_privilege('authenticated','public.vm_product_versions_read','SELECT'), 'authenticated can read Product views');
SELECT pg_temp.assert_true(NOT has_table_privilege('anon','public.vm_products_read','SELECT') AND NOT has_function_privilege('anon','public.vm_upsert_product_v2(uuid,text,text,jsonb,text,text,text,text,integer,text,numeric,numeric,numeric,text,boolean,boolean,jsonb,numeric,numeric,numeric,numeric,text,text,jsonb,jsonb,jsonb,uuid,uuid)','EXECUTE'), 'anon has no Product read or mutation grant');
SELECT pg_temp.pass_test('Product textual security-invoker views and grants');

-- Version 1: one fractional base component plus explicit inherit/own variants.
INSERT INTO qa_product_v1
SELECT * FROM public.vm_upsert_product_v2(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 'Album artesanal','papelaria','["papelaria","presente"]'::jsonb,'álbuns','Descrição','Cartão','Nome e data',3,'unit',100.12345678::numeric,95.00000000::numeric,2.00000000::numeric,'unit',false,false,
 '[{"label":"Texto da capa","type":"text","required":true}]'::jsonb,0.25000000::numeric,10.00000000::numeric,20.00000000::numeric,2.00000000::numeric,'ALB-001','7890001',
 '[{"minimum_quantity":"5","unit_price":"90.00000000"},{"minimum_quantity":"10","unit_price":"85.00000000"}]'::jsonb,
 jsonb_build_array(jsonb_build_object('material_id',(SELECT material_id FROM qa_material_a),'quantity','0.25000000','unit','g')),
 jsonb_build_array(
  jsonb_build_object('name','Padrão','price','100.12345678','composition_mode','inherit_base'),
  jsonb_build_object('name','Premium','price','125.00000000','promo_price','120.00000000','active',true,'minimum_quantity','1.00000000','composition_mode','own','components',jsonb_build_array(jsonb_build_object('material_id',(SELECT material_id FROM qa_material_a),'quantity','0.50000000','unit','g')))
 ),NULL::uuid,'20000000-0000-0000-0000-000000000001'::uuid);
SELECT pg_temp.assert_true((SELECT version FROM qa_product_v1)='1' AND (SELECT component_count FROM qa_product_v1)=1 AND (SELECT composition_cost::numeric FROM qa_product_v1)=1.00000000::numeric,'v1 stores fractional recipe and DB-derived composition cost');
SELECT pg_temp.assert_true((SELECT is_catalog_visible FROM public.vm_products WHERE id=(SELECT product_id FROM qa_product_v1))=false,'catalog visibility defaults to private false');
SELECT pg_temp.assert_true((SELECT count(*) FROM public.vm_product_variants WHERE product_id=(SELECT product_id FROM qa_product_v1))=2,'variant prices are persisted');
SELECT pg_temp.assert_true((SELECT count(*) FROM public.vm_product_variant_components WHERE variant_id=(SELECT id FROM public.vm_product_variants WHERE product_id=(SELECT product_id FROM qa_product_v1) AND name='Premium') AND variant_version=1)=1,'own variant recipe is versioned');
SELECT pg_temp.pass_test('v1 product fields, tiers, variants and DB composition cost');

-- Same key/payload is a no-op; changed payload is an explicit collision.
INSERT INTO qa_product_retry
SELECT * FROM public.vm_upsert_product_v2(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 'Album artesanal','papelaria','["papelaria","presente"]'::jsonb,'álbuns','Descrição','Cartão','Nome e data',3,'unit',100.12345678::numeric,95.00000000::numeric,2.00000000::numeric,'unit',false,false,
 '[{"label":"Texto da capa","type":"text","required":true}]'::jsonb,0.25000000::numeric,10.00000000::numeric,20.00000000::numeric,2.00000000::numeric,'ALB-001','7890001',
 '[{"minimum_quantity":"5","unit_price":"90.00000000"},{"minimum_quantity":"10","unit_price":"85.00000000"}]'::jsonb,
 jsonb_build_array(jsonb_build_object('material_id',(SELECT material_id FROM qa_material_a),'quantity','0.25000000','unit','g')),
 jsonb_build_array(
  jsonb_build_object('name','Padrão','price','100.12345678','composition_mode','inherit_base'),
  jsonb_build_object('name','Premium','price','125.00000000','promo_price','120.00000000','active',true,'minimum_quantity','1.00000000','composition_mode','own','components',jsonb_build_array(jsonb_build_object('material_id',(SELECT material_id FROM qa_material_a),'quantity','0.50000000','unit','g')))
 ),NULL::uuid,'20000000-0000-0000-0000-000000000001'::uuid);
SELECT pg_temp.assert_true((SELECT product_id FROM qa_product_retry)=(SELECT product_id FROM qa_product_v1) AND (SELECT version FROM qa_product_retry)='1' AND (SELECT count(*) FROM public.vm_product_versions WHERE product_id=(SELECT product_id FROM qa_product_v1))=1,'same idempotency key returns same version without duplicate');
SELECT pg_temp.assert_raises('Product idempotency payload mismatch','23505',format($$SELECT * FROM public.vm_upsert_product_v2('%s','Album artesanal','papelaria','["papelaria"]'::jsonb,NULL,NULL,NULL,NULL,3,'unit',101::numeric,95::numeric,2::numeric,'unit',false,false,'[]'::jsonb,NULL,NULL,NULL,NULL,'ALB-001','7890001','[]'::jsonb,'[]'::jsonb,'[]'::jsonb,'%s','20000000-0000-0000-0000-000000000001'::uuid)$$,(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT product_id FROM qa_product_v1)));
SELECT pg_temp.pass_test('Product idempotency retry and payload collision');

-- Version 2 changes billing semantics to m2 and freezes a new price/recipe;
-- version 1 remains immutable and retains its old cost and metadata snapshot.
INSERT INTO qa_product_v2
SELECT * FROM public.vm_upsert_product_v2(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 'Album artesanal m2','papelaria','["papelaria","presente","m2"]'::jsonb,'álbuns','Descrição v2','Cartão','Nome e data',4,'m2',140.00000000::numeric,130.00000000::numeric,1.50000000::numeric,'m2',false,false,
 '[{"label":"Texto da capa","type":"textarea","required":false}]'::jsonb,0.30000000::numeric,12.00000000::numeric,22.00000000::numeric,2.50000000::numeric,'ALB-001-V2','7890002',
 '[{"minimum_quantity":"1.50000000","unit_price":"135.00000000"},{"minimum_quantity":"3.00000000","unit_price":"125.00000000"}]'::jsonb,
 jsonb_build_array(jsonb_build_object('material_id',(SELECT material_id FROM qa_material_a),'quantity','0.50000000','unit','g')),
 jsonb_build_array(jsonb_build_object('name','Padrão m2','price','140.00000000','composition_mode','inherit_base')),
 (SELECT product_id FROM qa_product_v1),'20000000-0000-0000-0000-000000000002'::uuid);
SELECT pg_temp.assert_true((SELECT version FROM qa_product_v2)='2' AND (SELECT pricing_mode FROM qa_product_v2)='m2' AND (SELECT composition_cost::numeric FROM qa_product_v2)=2.00000000::numeric,'m2 v2 persists billing mode and exact new cost');
SELECT pg_temp.assert_true((SELECT price FROM public.vm_product_versions WHERE product_id=(SELECT product_id FROM qa_product_v1) AND product_version=1)='100.12345678' AND (SELECT composition_cost FROM public.vm_product_versions WHERE product_id=(SELECT product_id FROM qa_product_v1) AND product_version=1)='1.00000000','v1 snapshot preserves old price and recipe cost');
SELECT pg_temp.assert_true((SELECT price FROM public.vm_product_versions WHERE product_id=(SELECT product_id FROM qa_product_v1) AND product_version=2)='140.00000000' AND (SELECT composition_cost FROM public.vm_product_versions WHERE product_id=(SELECT product_id FROM qa_product_v1) AND product_version=2)='2.00000000','v2 snapshot preserves new price and recipe cost');
SELECT pg_temp.assert_true((SELECT count(*) FROM public.vm_product_components WHERE product_id=(SELECT product_id FROM qa_product_v1) AND product_version=1 AND quantity=0.25000000::numeric)=1 AND (SELECT count(*) FROM public.vm_product_components WHERE product_id=(SELECT product_id FROM qa_product_v1) AND product_version=2 AND quantity=0.50000000::numeric)=1,'old composition row remains after update');
SELECT pg_temp.pass_test('m2 billing unit and immutable historical snapshots');

-- Direct mutation is blocked; no RPC can bypass the version/snapshot contract.
SELECT pg_temp.assert_raises('direct component update blocked','42501',format($$UPDATE public.vm_product_components SET quantity=9 WHERE product_id='%s'$$,(SELECT product_id FROM qa_product_v1)));
SELECT pg_temp.assert_raises('direct version delete blocked','42501',format($$DELETE FROM public.vm_product_versions WHERE product_id='%s'$$,(SELECT product_id FROM qa_product_v1)));
SELECT pg_temp.assert_true(NOT has_function_privilege('authenticated','public.vm_upsert_product(uuid,text,numeric,text,jsonb,uuid)','EXECUTE'),'legacy product RPC has no authenticated execute privilege');
SELECT pg_temp.pass_test('legacy RPC and direct historical mutation barriers');

-- Numeric/shape/MOQ/pricing validation occurs before any catalog row is made.
SELECT pg_temp.assert_raises('NaN product price rejected','22023',format($$SELECT * FROM public.vm_upsert_product_v2('%s','NaN product','cat','[]'::jsonb,NULL,NULL,NULL,NULL,0,'unit','NaN'::numeric,NULL,1,'unit',false,false,'[]'::jsonb,NULL,NULL,NULL,NULL,NULL,NULL,'[]'::jsonb,'[]'::jsonb,'[]'::jsonb,NULL,'20000000-0000-0000-0000-000000000011'::uuid)$$,(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))));
SELECT pg_temp.assert_raises('Infinity price rejected','22023',format($$SELECT * FROM public.vm_upsert_product_v2('%s','Infinity product','cat','[]'::jsonb,NULL,NULL,NULL,NULL,0,'unit','Infinity'::numeric,NULL,1,'unit',false,false,'[]'::jsonb,NULL,NULL,NULL,NULL,NULL,NULL,'[]'::jsonb,'[]'::jsonb,'[]'::jsonb,NULL,'20000000-0000-0000-0000-000000000012'::uuid)$$,(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))));
SELECT pg_temp.assert_raises('price scale beyond eight rejected','22023',format($$SELECT * FROM public.vm_upsert_product_v2('%s','Scale product','cat','[]'::jsonb,NULL,NULL,NULL,NULL,0,'unit',1.123456789::numeric,NULL,1,'unit',false,false,'[]'::jsonb,NULL,NULL,NULL,NULL,NULL,NULL,'[]'::jsonb,'[]'::jsonb,'[]'::jsonb,NULL,'20000000-0000-0000-0000-000000000013'::uuid)$$,(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))));
SELECT pg_temp.assert_raises('MOQ zero rejected','22023',format($$SELECT * FROM public.vm_upsert_product_v2('%s','MOQ product','cat','[]'::jsonb,NULL,NULL,NULL,NULL,0,'unit',1,NULL,0,'unit',false,false,'[]'::jsonb,NULL,NULL,NULL,NULL,NULL,NULL,'[]'::jsonb,'[]'::jsonb,'[]'::jsonb,NULL,'20000000-0000-0000-0000-000000000014'::uuid)$$,(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))));
SELECT pg_temp.assert_raises('m2 requires m2 billing unit','22023',format($$SELECT * FROM public.vm_upsert_product_v2('%s','Mode product','cat','[]'::jsonb,NULL,NULL,NULL,NULL,0,'m2',1,NULL,1,'unit',false,false,'[]'::jsonb,NULL,NULL,NULL,NULL,NULL,NULL,'[]'::jsonb,'[]'::jsonb,'[]'::jsonb,NULL,'20000000-0000-0000-0000-000000000015'::uuid)$$,(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))));
SELECT pg_temp.assert_raises('unsorted wholesale tiers rejected','22023',format($$SELECT * FROM public.vm_upsert_product_v2('%s','Tier product','cat','[]'::jsonb,NULL,NULL,NULL,NULL,0,'unit',1,NULL,1,'unit',false,false,'[]'::jsonb,NULL,NULL,NULL,NULL,NULL,NULL,'[{"minimum_quantity":"2","unit_price":"1"},{"minimum_quantity":"1","unit_price":"0.5"}]'::jsonb,'[]'::jsonb,'[]'::jsonb,NULL,'20000000-0000-0000-0000-000000000016'::uuid)$$,(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))));
SELECT pg_temp.assert_raises('component unit mismatch rejected','23503',format($$SELECT * FROM public.vm_upsert_product_v2('%s','Unit product','cat','[]'::jsonb,NULL,NULL,NULL,NULL,0,'unit',1,NULL,1,'unit',false,false,'[]'::jsonb,NULL,NULL,NULL,NULL,NULL,NULL,'[]'::jsonb,jsonb_build_array(jsonb_build_object('material_id','%s','quantity','1','unit','kg')),'[]'::jsonb,NULL,'20000000-0000-0000-0000-000000000017'::uuid)$$,(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT material_id FROM qa_material_a)));
SELECT pg_temp.assert_raises('null question label rejected','22023',format($$SELECT * FROM public.vm_upsert_product_v2('%s','Invalid question','cat','[]'::jsonb,NULL,NULL,NULL,NULL,0,'unit',1,NULL,1,'unit',false,false,'[{"label":null,"type":"text","required":true}]'::jsonb,NULL,NULL,NULL,NULL,NULL,NULL,'[]'::jsonb,'[]'::jsonb,'[]'::jsonb,NULL,'20000000-0000-0000-0000-000000000020'::uuid)$$,(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))));
SELECT pg_temp.assert_raises('select question without options rejected','22023',format($$SELECT * FROM public.vm_upsert_product_v2('%s','Invalid select','cat','[]'::jsonb,NULL,NULL,NULL,NULL,0,'unit',1,NULL,1,'unit',false,false,'[{"label":"Cor","type":"select","required":true}]'::jsonb,NULL,NULL,NULL,NULL,NULL,NULL,'[]'::jsonb,'[]'::jsonb,'[]'::jsonb,NULL,'20000000-0000-0000-0000-000000000021'::uuid)$$,(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))));
SELECT pg_temp.assert_raises('null variant name rejected','22023',format($$SELECT * FROM public.vm_upsert_product_v2('%s','Invalid variant','cat','[]'::jsonb,NULL,NULL,NULL,NULL,0,'unit',1,NULL,1,'unit',false,false,'[]'::jsonb,NULL,NULL,NULL,NULL,NULL,NULL,'[]'::jsonb,'[]'::jsonb,'[{"name":null,"price":"1","composition_mode":"inherit_base"}]'::jsonb,NULL,'20000000-0000-0000-0000-000000000022'::uuid)$$,(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))));
SELECT pg_temp.assert_true((SELECT count(*) FROM public.vm_products WHERE name IN ('NaN product','Infinity product','Scale product','MOQ product','Mode product','Tier product','Unit product'))=0,'invalid Product payloads create no rows');
SELECT pg_temp.pass_test('numeric scale NaN Infinity MOQ mode tiers and unit schema guards');

-- Tenant and role isolation use real Auth JWT GUCs and memberships.
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_b::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_b::text FROM qa_identity),'role','authenticated')::text,true);
SELECT pg_temp.assert_true((SELECT count(*) FROM public.vm_products_read WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)))=0,'other tenant Product rows are invisible');
SELECT pg_temp.assert_raises('cross tenant Product mutation forbidden','42501',format($$SELECT * FROM public.vm_upsert_product_v2('%s','Cross tenant','cat','[]'::jsonb,NULL,NULL,NULL,NULL,0,'unit',1,NULL,1,'unit',false,false,'[]'::jsonb,NULL,NULL,NULL,NULL,NULL,NULL,'[]'::jsonb,'[]'::jsonb,'[]'::jsonb,'%s','20000000-0000-0000-0000-000000000018'::uuid)$$,(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT product_id FROM qa_product_v1)));
SELECT pg_temp.pass_test('cross tenant Product read and mutation isolation');

-- A finance membership is a real role but cannot mutate this product catalog.
RESET ROLE;
INSERT INTO public.vm_memberships(organization_id,user_id,role)
VALUES ((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT user_b FROM qa_identity),'finance');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_b::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_b::text FROM qa_identity),'role','finance')::text,true);
SELECT pg_temp.assert_raises('finance cannot mutate Product catalog','42501',format($$SELECT * FROM public.vm_upsert_product_v2('%s','Finance attempt','cat','[]'::jsonb,NULL,NULL,NULL,NULL,0,'unit',1,NULL,1,'unit',false,false,'[]'::jsonb,NULL,NULL,NULL,NULL,NULL,NULL,'[]'::jsonb,'[]'::jsonb,'[]'::jsonb,NULL,'20000000-0000-0000-0000-000000000019'::uuid)$$,(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))));
SELECT pg_temp.pass_test('finance role cannot mutate Product catalog');

-- Storage bucket/policies are private and path-safe. This SQL object insert is
-- only a local policy fixture, not a real upload or production call.
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','owner')::text,true);
SELECT pg_temp.assert_true((SELECT public FROM storage.buckets WHERE id='vm-product-media')=false,'Product bucket is private');
SELECT pg_temp.assert_true((SELECT file_size_limit FROM storage.buckets WHERE id='vm-product-media')=52428800,'Product bucket keeps its declared size limit');
SELECT pg_temp.assert_true((SELECT count(*) FROM pg_policy pol JOIN pg_class c ON c.oid=pol.polrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='storage' AND c.relname='objects' AND pol.polname IN ('vm_product_media_select','vm_product_media_insert','vm_product_media_delete'))=3,'Product Storage policies exist without replacing unrelated policies');
INSERT INTO storage.objects(bucket_id,name,owner_id,metadata)
VALUES ('vm-product-media',(SELECT organization_id::text FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)) || '/' || (SELECT product_id::text FROM qa_product_v1) || '/cover.jpg',(SELECT user_a FROM qa_identity),jsonb_build_object('mimetype','image/jpeg','size','1024'));
SELECT pg_temp.assert_raises('malicious Storage path is rejected by policy', '42501', format($$INSERT INTO storage.objects(bucket_id,name,owner_id,metadata) VALUES ('vm-product-media','%s/../evil/cover.jpg','%s','{"mimetype":"image/jpeg","size":"10"}'::jsonb)$$,(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT user_a FROM qa_identity)));
INSERT INTO qa_file
SELECT * FROM public.vm_register_product_file(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT product_id FROM qa_product_v1),'photo',
 (SELECT organization_id::text FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)) || '/' || (SELECT product_id::text FROM qa_product_v1) || '/cover.jpg','image/jpeg',1024,'cover.jpg');
SELECT pg_temp.assert_true((SELECT mime_type FROM qa_file)='image/jpeg' AND (SELECT size_bytes FROM qa_file)='1024','registered file returns verified metadata');
SELECT pg_temp.assert_raises('file registration requires existing object','23503',format($$SELECT * FROM public.vm_register_product_file('%s','%s','digital','%s/%s/missing.pdf','application/pdf',25,'missing.pdf')$$,(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT product_id FROM qa_product_v1),(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT product_id FROM qa_product_v1)));
SELECT pg_temp.assert_raises('direct Product file insert blocked','42501',format($$INSERT INTO public.vm_product_files(organization_id,product_id,kind,path,mime_type,size_bytes,name,created_by) VALUES ('%s','%s','photo','%s/%s/direct.jpg','image/jpeg',1,'direct.jpg','%s')$$,(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT product_id FROM qa_product_v1),(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT product_id FROM qa_product_v1),(SELECT user_a FROM qa_identity)));
SELECT pg_temp.pass_test('private Storage bucket path policy object verification and file metadata registration');

-- Remove the temporary finance membership before asserting cross-tenant denial.
RESET ROLE;
DELETE FROM public.vm_memberships
WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))
  AND user_id=(SELECT user_b FROM qa_identity);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_b::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_b::text FROM qa_identity),'role','authenticated')::text,true);
SELECT pg_temp.assert_true((SELECT count(*) FROM public.vm_product_files_read WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)))=0,'other tenant cannot read Product files');
SELECT pg_temp.assert_true((SELECT count(*) FROM storage.objects WHERE bucket_id='vm-product-media')=0,'other tenant cannot read private Storage object');
SELECT pg_temp.pass_test('Storage RLS has no cross-tenant leakage');

RESET ROLE;
SELECT pg_temp.assert_true(current_user='ubuntu','suite returns to local admin after role checks');
