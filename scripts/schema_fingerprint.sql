-- Read-only structural comparison for vm_* application objects; no business rows.
-- Run against a fresh isolated database and the approved remote baseline.
-- ACLs and Storage/Realtime contracts require separate verification.
WITH items AS (
  SELECT 'functions' AS category, n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS name,
    md5(p.prosrc) || ':' || p.prosecdef::text || ':' || coalesce(array_to_string(p.proconfig,','),'') AS value
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname IN ('public','vm_private') AND p.proname LIKE 'vm\_%' ESCAPE '\'
  UNION ALL
  SELECT 'columns', n.nspname || '.' || c.relname || '.' || a.attname,
    format_type(a.atttypid,a.atttypmod) || ':' || a.attnotnull::text || ':' || a.attgenerated::text || ':' || coalesce(pg_get_expr(d.adbin,d.adrelid),'')
  FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_attribute a ON a.attrelid=c.oid
    LEFT JOIN pg_attrdef d ON d.adrelid=c.oid AND d.adnum=a.attnum
  WHERE n.nspname IN ('public','vm_private') AND c.relname LIKE 'vm\_%' ESCAPE '\' AND c.relkind IN ('r','p','v') AND a.attnum>0 AND NOT a.attisdropped
  UNION ALL
  SELECT 'constraints', n.nspname || '.' || c.relname || '.' || x.conname, pg_get_constraintdef(x.oid)
  FROM pg_constraint x JOIN pg_class c ON c.oid=x.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname IN ('public','vm_private') AND c.relname LIKE 'vm\_%' ESCAPE '\'
  UNION ALL
  SELECT 'indexes', n.nspname || '.' || c.relname, pg_get_indexdef(c.oid)
  FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname IN ('public','vm_private') AND c.relname LIKE 'vm\_%' ESCAPE '\' AND c.relkind='i'
  UNION ALL
  SELECT 'policies', n.nspname || '.' || c.relname || '.' || p.polname,
    p.polcmd::text || ':' || p.polpermissive::text || ':' ||
    coalesce((SELECT string_agg(r.rolname,',' ORDER BY r.rolname) FROM pg_roles r WHERE r.oid=ANY(p.polroles)),'public') || ':' ||
    coalesce(pg_get_expr(p.polqual,p.polrelid),'') || ':' || coalesce(pg_get_expr(p.polwithcheck,p.polrelid),'')
  FROM pg_policy p JOIN pg_class c ON c.oid=p.polrelid JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname IN ('public','vm_private') AND c.relname LIKE 'vm\_%' ESCAPE '\'
  UNION ALL
  SELECT 'triggers', n.nspname || '.' || c.relname || '.' || t.tgname, pg_get_triggerdef(t.oid)
  FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE NOT t.tgisinternal AND n.nspname IN ('public','vm_private') AND c.relname LIKE 'vm\_%' ESCAPE '\'
  UNION ALL
  SELECT 'views', n.nspname || '.' || c.relname, pg_get_viewdef(c.oid,true) || ':' || coalesce(array_to_string(c.reloptions,','),'')
  FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE c.relkind='v' AND n.nspname IN ('public','vm_private') AND c.relname LIKE 'vm\_%' ESCAPE '\'
  UNION ALL
  SELECT 'tables_rls', n.nspname || '.' || c.relname, c.relrowsecurity::text || ':' || c.relforcerowsecurity::text
  FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE c.relkind IN ('r','p') AND n.nspname IN ('public','vm_private') AND c.relname LIKE 'vm\_%' ESCAPE '\'
)
SELECT category,count(*) AS objects,md5(string_agg(name || '=' || value,E'\n' ORDER BY name)) AS fingerprint FROM items GROUP BY category ORDER BY category
