-- COMMUNiTY V2: einmalig nach dem bisherigen SUPABASE_SETUP.sql ausführen.
-- Nicht die alte Tabelle löschen: vorhandene 3+ Import-Stimmen bleiben erhalten.
BEGIN;
ALTER TABLE public.commander_votes
 ADD COLUMN IF NOT EXISTS voter_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
 ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();
CREATE UNIQUE INDEX IF NOT EXISTS commander_votes_one_per_voter ON public.commander_votes(voter_id) WHERE voter_id IS NOT NULL;

-- Alte Client-Inserts deaktivieren: nur sichere RPC-Aufrufe schreiben neue Stimmen.
DROP POLICY IF EXISTS "Anonyme Bewertung abgeben" ON public.commander_votes;
REVOKE INSERT, UPDATE, DELETE ON public.commander_votes FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.save_my_commander_vote(_ranks jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE _id uuid; _t text; _deck text; _all text[] := ARRAY[]::text[];
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Bitte zuerst einloggen'; END IF;
 IF jsonb_typeof(_ranks) <> 'object' OR octet_length(_ranks::text)>60000 THEN RAISE EXCEPTION 'Ungültige Bewertung'; END IF;
 FOR _t IN SELECT jsonb_object_keys(_ranks) LOOP
  IF _t <> ALL(ARRAY['S','A','B','C','D','E','F','?']) OR jsonb_typeof(_ranks->_t)<>'array' THEN
   RAISE EXCEPTION 'Unbekannte Tier-Stufe'; END IF;
  FOR _deck IN SELECT jsonb_array_elements_text(_ranks->_t) LOOP
   IF _deck=ANY(_all) THEN RAISE EXCEPTION 'Commander mehrfach bewertet'; END IF;
   _all:=array_append(_all,_deck);
  END LOOP;
 END LOOP;
 IF cardinality(_all)>500 THEN RAISE EXCEPTION 'Zu viele Einträge'; END IF;
 INSERT INTO public.commander_votes (id, voter_id, ranks, updated_at)
 VALUES (gen_random_uuid(), auth.uid(), _ranks, now())
 ON CONFLICT(voter_id) WHERE voter_id IS NOT NULL
 DO UPDATE SET ranks=EXCLUDED.ranks, updated_at=now()
 RETURNING id INTO _id;
 RETURN _id;
END $$;

CREATE OR REPLACE FUNCTION public.my_commander_vote()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
 SELECT (SELECT jsonb_build_object('ranks', ranks, 'updated_at', updated_at)
 FROM public.commander_votes WHERE voter_id=auth.uid() LIMIT 1)
$$;

CREATE OR REPLACE FUNCTION public.import_legacy_commander_vote(_id uuid, _ranks jsonb)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
 IF auth.uid() IS NULL OR lower(auth.jwt()->>'email') <> 'vuckovic2203@gmail.com' THEN
  RAISE EXCEPTION 'Nur Organisator'; END IF;
 IF jsonb_typeof(_ranks)<>'object' OR octet_length(_ranks::text)>60000 THEN
  RAISE EXCEPTION 'Ungültige Bewertung'; END IF;
 INSERT INTO public.commander_votes(id, ranks) VALUES (_id,_ranks)
 ON CONFLICT(id) DO NOTHING;
 RETURN FOUND;
END $$;

-- Nur für Organisator: importierte Stimmen identifizieren, ohne sie öffentlich zuzuordnen.
CREATE OR REPLACE FUNCTION public.admin_unlinked_votes()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE _result jsonb;
BEGIN
 IF auth.uid() IS NULL OR lower(auth.jwt()->>'email') <> 'vuckovic2203@gmail.com' THEN
  RAISE EXCEPTION 'Nur Organisator'; END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',id,'ranks',ranks,'created_at',created_at) ORDER BY created_at),'[]'::jsonb)
 INTO _result FROM (SELECT id,ranks,created_at FROM public.commander_votes WHERE voter_id IS NULL ORDER BY created_at LIMIT 1500) t;
 RETURN _result;
END $$;

CREATE OR REPLACE FUNCTION public.admin_link_legacy_vote(_id uuid, _email text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE _user uuid;
BEGIN
 IF auth.uid() IS NULL OR lower(auth.jwt()->>'email') <> 'vuckovic2203@gmail.com' THEN
  RAISE EXCEPTION 'Nur Organisator'; END IF;
 SELECT id INTO _user FROM auth.users WHERE lower(email)=lower(trim(_email)) LIMIT 1;
 IF _user IS NULL THEN RAISE EXCEPTION 'Dieses Mitglied hat noch kein Konto erstellt'; END IF;
 IF EXISTS(SELECT 1 FROM public.commander_votes WHERE voter_id=_user) THEN
  RAISE EXCEPTION 'Dieses Mitglied hat schon eine Stimme. Kein Doppelzählen erlaubt'; END IF;
 UPDATE public.commander_votes SET voter_id=_user,updated_at=now()
 WHERE id=_id AND voter_id IS NULL;
 IF NOT FOUND THEN RAISE EXCEPTION 'Alte Stimme nicht gefunden oder schon zugewiesen'; END IF;
 RETURN true;
END $$;

CREATE TABLE IF NOT EXISTS public.commander_sync_status (
 id int PRIMARY KEY DEFAULT 1 CHECK (id=1), checked_at timestamptz,
 synced_at timestamptz, status text NOT NULL DEFAULT 'Noch nie geprüft',
 message text NOT NULL DEFAULT ''
);
INSERT INTO public.commander_sync_status (id) VALUES(1) ON CONFLICT DO NOTHING;
ALTER TABLE public.commander_sync_status ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.commander_sync_status FROM anon,authenticated;
GRANT SELECT ON public.commander_sync_status TO anon,authenticated;
DROP POLICY IF EXISTS "Sync-Status öffentlich" ON public.commander_sync_status;
CREATE POLICY "Sync-Status öffentlich" ON public.commander_sync_status FOR SELECT TO anon,authenticated USING(true);

REVOKE ALL ON FUNCTION public.save_my_commander_vote(jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.save_my_commander_vote(jsonb) TO authenticated;
REVOKE ALL ON FUNCTION public.my_commander_vote() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.my_commander_vote() TO authenticated;
REVOKE ALL ON FUNCTION public.import_legacy_commander_vote(uuid,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.import_legacy_commander_vote(uuid,jsonb) TO authenticated;
REVOKE ALL ON FUNCTION public.admin_unlinked_votes() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.admin_unlinked_votes() TO authenticated;
REVOKE ALL ON FUNCTION public.admin_link_legacy_vote(uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.admin_link_legacy_vote(uuid,text) TO authenticated;
COMMIT;
