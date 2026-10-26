-- SELBSTVERWALTUNG ALTER CSV-STIMMEN
-- Einmalig NACH OFFENE_ABSTIMMUNG.sql ausführen.
-- KEINE bestehenden Tabellen löschen. Keine Stimmen werden bei der Installation verändert.
-- Diese Funktion ist nur für eine vertrauensbasierte, offene Spielgruppe gedacht:
-- Sie kann KEINE geheime Eigentümerschaft nachweisen, weil alte CSV-Stimmen
-- ohne vorher vergebenen Bearbeitungscode importiert wurden.
BEGIN;
CREATE OR REPLACE FUNCTION public.claim_saved_legacy_commander_vote(_ranks jsonb, _code text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
 _t text; _deck text; _all text[]:=ARRAY[]::text[];
 _hash text; _found uuid; _matches int;
BEGIN
 IF _code IS NULL OR _code !~ '^[0-9a-f]{64}$' THEN
  RAISE EXCEPTION 'Ungültiger Bearbeitungscode';
 END IF;
 IF _ranks IS NULL OR jsonb_typeof(_ranks)<>'object' OR octet_length(_ranks::text)>60000 THEN
  RAISE EXCEPTION 'Ungültige alte Tierlist';
 END IF;
 FOR _t IN SELECT jsonb_object_keys(_ranks) LOOP
  IF NOT (_t = ANY (ARRAY['S','A','B','C','D','E','F','?'])) OR jsonb_typeof(_ranks->_t)<>'array' THEN
   RAISE EXCEPTION 'Ungültige Tier-Stufe';
  END IF;
  FOR _deck IN SELECT jsonb_array_elements_text(_ranks->_t) LOOP
   IF _deck=ANY(_all) THEN RAISE EXCEPTION 'Ein Commander wurde mehrfach eingeordnet'; END IF;
   _all:=array_append(_all,_deck);
  END LOOP;
 END LOOP;
 IF cardinality(_all)<15 THEN RAISE EXCEPTION 'Zu wenige Commander für einen sicheren Abgleich'; END IF;
 _hash=encode(sha256(convert_to(_code,'UTF8')),'hex');
 IF EXISTS(SELECT 1 FROM public.commander_votes WHERE edit_token_hash=_hash) THEN
   RAISE EXCEPTION 'Dieser Code gehört bereits zu einer Stimme';
 END IF;
 -- Nur bislang nicht zugewiesene CSV-Altstimmen abgleichen.
 -- Jeder früher gerankte Commander muss im damals gespeicherten Tier liegen.
 -- Innerhalb der Tiers ist die Reihenfolge unerheblich; neue Decks dürfen hinzukommen.
 SELECT count(*), min(v.id) INTO _matches, _found
 FROM public.commander_votes v
 WHERE v.edit_token_hash IS NULL AND v.voter_id IS NULL
   AND (SELECT count(*) FROM jsonb_each(v.ranks) AS tier(k,ids),
        LATERAL jsonb_array_elements_text(tier.ids) AS deck(id)) >= 15
   AND NOT EXISTS (
     SELECT 1 FROM jsonb_each(v.ranks) AS tier(k,ids),
          LATERAL jsonb_array_elements_text(tier.ids) AS deck(id)
     WHERE COALESCE((_ranks->tier.k) ? deck.id, false) = false
   );
 IF _matches=0 THEN RAISE EXCEPTION 'Keine exakt passende alte Stimme gefunden'; END IF;
 IF _matches>1 THEN RAISE EXCEPTION 'Mehrere identische alte Stimmen gefunden: automatische Zuordnung nicht eindeutig'; END IF;
 UPDATE public.commander_votes SET edit_token_hash=_hash, updated_at=now()
 WHERE id=_found AND edit_token_hash IS NULL AND voter_id IS NULL;
 IF NOT FOUND THEN RAISE EXCEPTION 'Die Stimme wurde zwischenzeitlich bereits übernommen'; END IF;
 RETURN _found;
END $$;
REVOKE ALL ON FUNCTION public.claim_saved_legacy_commander_vote(jsonb,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.claim_saved_legacy_commander_vote(jsonb,text) TO anon,authenticated;
COMMIT;
