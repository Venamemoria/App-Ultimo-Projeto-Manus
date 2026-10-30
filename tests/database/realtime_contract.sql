-- Local VMTEST contract only. The runner must verify vm_test, Unix socket,
-- empty listen_addresses and vm.test_cluster=isolated before applying this.
-- Minimal message table contract plus the exact realtime.send definition read
-- READ ONLY from the authorized Supabase pg_catalog on 2026-10-29.
-- This tests SQL enqueue/rollback and failure semantics, NOT WebSocket delivery
-- or production partitioning/subscriber authorization. No messages go outside
-- the isolated local PostgreSQL. This producer inserts real local rows.
CREATE SCHEMA IF NOT EXISTS realtime;
CREATE TABLE realtime.messages (
  id uuid PRIMARY KEY,
  payload jsonb,
  event text,
  topic text,
  private boolean,
  extension text NOT NULL CHECK (extension='broadcast'),
  inserted_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE realtime.messages ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON SCHEMA realtime FROM PUBLIC,anon,authenticated;
REVOKE ALL ON TABLE realtime.messages FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION realtime.send(payload jsonb, event text, topic text, private boolean DEFAULT true)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
  generated_id uuid;
  final_payload jsonb;
BEGIN
  BEGIN
    generated_id := gen_random_uuid();
    IF payload ? 'id' THEN
      final_payload := payload;
    ELSE
      final_payload := jsonb_set(payload, '{id}', to_jsonb(generated_id));
    END IF;
    EXECUTE format('SET LOCAL realtime.topic TO %L', topic);
    INSERT INTO realtime.messages (id, payload, event, topic, private, extension)
    VALUES (generated_id, final_payload, event, topic, private, 'broadcast');
  EXCEPTION
    WHEN OTHERS THEN
      RAISE WARNING 'WarnSendingBroadcastMessage: %', SQLERRM;
  END;
END;
$function$;
REVOKE ALL ON FUNCTION realtime.send(jsonb,text,text,boolean) FROM PUBLIC,anon,authenticated;
