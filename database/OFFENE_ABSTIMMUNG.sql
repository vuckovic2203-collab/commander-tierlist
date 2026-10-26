-- NACH dem bisherigen UPGRADE.sql ausführen; alte Bewertungen bleiben erhalten.
-- Öffentliche Abstimmung OHNE Login, bearbeitbar mit privatem, zufälligem Code.
BEGIN;
ALTER TABLE public.commander_votes ADD COLUMN IF NOT EXISTS edit_token_hash text;
CREATE UNIQUE INDEX IF NOT EXISTS commander_votes_unique_edit_token ON public.commander_votes (edit_token_hash);

-- Direkter Tabellenzugriff bleibt gesperrt. Votes werden NUR über kontrollierte RPC gespeichert.
REVOKE ALL ON public.commander_votes FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.save_guest_commander_vote(_ranks jsonb, _code text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE _id uuid; _t text; _deck text; _all text[]:=ARRAY[]::text[];
 _valid text[]; _hash text;
BEGIN
 IF _code IS NULL OR _code !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'Ungültiger Bearbeitungscode'; END IF;
 IF _ranks IS NULL OR jsonb_typeof(_ranks)<>'object' OR octet_length(_ranks::text)>60000 THEN
  RAISE EXCEPTION 'Ungültige Tierliste'; END IF;
 SELECT array_agg(c.value->>'id') INTO _valid
 FROM public.commander_catalog k, LATERAL jsonb_array_elements(k.cards) c(value) WHERE k.id=1;
 IF coalesce(cardinality(_valid),0)=0 THEN RAISE EXCEPTION 'Commander-Katalog nicht gefunden'; END IF;
 FOR _t IN SELECT jsonb_object_keys(_ranks) LOOP
  IF _t <> ALL(ARRAY['S','A','B','C','D','E','F','?']) OR jsonb_typeof(_ranks->_t)<>'array' THEN
   RAISE EXCEPTION 'Unbekannte Tier-Stufe'; END IF;
  FOR _deck IN SELECT jsonb_array_elements_text(_ranks->_t) LOOP
   IF _deck=ANY(_all) THEN RAISE EXCEPTION 'Commander mehrfach eingeordnet'; END IF;
   IF NOT _deck=ANY(_valid) THEN RAISE EXCEPTION 'Commander ist nicht in der aktuellen Liste: %',_deck; END IF;
   _all:=array_append(_all,_deck);
  END LOOP;
 END LOOP;
 IF cardinality(_all)<>cardinality(_valid) THEN
  RAISE EXCEPTION 'Bitte alle % Commander einordnen (aktuell %)',cardinality(_valid),cardinality(_all);
 END IF;
 _hash=encode(sha256(convert_to(_code,'UTF8')),'hex');
 INSERT INTO public.commander_votes(id,ranks,edit_token_hash,updated_at)
 VALUES(gen_random_uuid(),_ranks,_hash,now())
 ON CONFLICT(edit_token_hash) DO UPDATE
 SET ranks=EXCLUDED.ranks,updated_at=now()
 WHERE public.commander_votes.voter_id IS NULL
 RETURNING id INTO _id;
 IF _id IS NULL THEN RAISE EXCEPTION 'Dieser Bearbeitungscode kann nicht verwendet werden'; END IF;
 RETURN _id;
END $$;

CREATE OR REPLACE FUNCTION public.my_guest_commander_vote(_code text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE result jsonb;
BEGIN
 IF _code IS NULL OR _code !~ '^[0-9a-f]{64}$' THEN RETURN NULL; END IF;
 SELECT jsonb_build_object('ranks',v.ranks,'updated_at',v.updated_at)
 INTO result FROM public.commander_votes v
 WHERE v.edit_token_hash=encode(sha256(convert_to(_code,'UTF8')),'hex') AND v.voter_id IS NULL;
 RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.admin_link_legacy_guest_vote(_id uuid,_code text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE _hash text;
BEGIN
 IF auth.uid() IS NULL OR lower(auth.jwt()->>'email') <> 'vuckovic2203@gmail.com' THEN
  RAISE EXCEPTION 'Nur Organisator'; END IF;
 IF _code IS NULL OR _code !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'Ungültiger Code'; END IF;
 _hash=encode(sha256(convert_to(_code,'UTF8')),'hex');
 IF EXISTS(SELECT 1 FROM public.commander_votes WHERE edit_token_hash=_hash) THEN
  RAISE EXCEPTION 'Dieser Code ist bereits einer Stimme zugeordnet'; END IF;
 UPDATE public.commander_votes SET edit_token_hash=_hash,updated_at=now()
 WHERE id=_id AND edit_token_hash IS NULL AND voter_id IS NULL;
 IF NOT FOUND THEN RAISE EXCEPTION 'Alte Stimme nicht gefunden oder schon verknüpft'; END IF;
 RETURN TRUE;
END $$;

CREATE OR REPLACE FUNCTION public.admin_unlinked_votes()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE _result jsonb;
BEGIN
 IF auth.uid() IS NULL OR lower(auth.jwt()->>'email') <> 'vuckovic2203@gmail.com' THEN
  RAISE EXCEPTION 'Nur Organisator'; END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',id,'ranks',ranks,'created_at',created_at) ORDER BY created_at),'[]'::jsonb)
 INTO _result FROM
 (SELECT id,ranks,created_at FROM public.commander_votes
  WHERE voter_id IS NULL AND edit_token_hash IS NULL ORDER BY created_at LIMIT 1500) t;
 RETURN _result;
END $$;

REVOKE ALL ON FUNCTION public.save_guest_commander_vote(jsonb,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.my_guest_commander_vote(text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.admin_link_legacy_guest_vote(uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.save_guest_commander_vote(jsonb,text) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.my_guest_commander_vote(text) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.admin_link_legacy_guest_vote(uuid,text) TO authenticated;
COMMIT;
