# Commander Tierlist – Webseite mit automatischem Archidekt-Abgleich

Diese Git-Version enthält die **neueste Selbstverwaltungs-Webseite** (alte CSV-Stimmen können von der jeweiligen Person selbst übernommen werden), die E-Mail-Abgabe an Netlify Forms sowie eine geplante Serverfunktion `archidekt-sync`.

## Voraussetzung

- Deine bestehende Netlify-Site `celebrated-truffle-f4b7d3` und dein Supabase-Projekt bleiben bestehen.
- Datenbankmigrationen `UPGRADE.sql`, `OFFENE_ABSTIMMUNG.sql` und `SELBSTVERWALTUNG.sql` wurden bereits ausgeführt. **Nicht erneut ausführen, wenn erledigt.**
- **Wichtig:** Ein früher im Chat offengelegter Supabase Secret Key muss vor Einrichtung widerrufen/ersetzt werden.

## GitHub und Netlify verbinden

1. Im eigenen GitHub-Konto ein neues **privates** Repository erstellen, z. B. `commander-tierlist`.
2. Dieses ZIP **entpacken**. Dateien und Ordner **aus dem Archivwurzelverzeichnis** ins Repository hochladen. Auf oberster Ebene müssen `public/`, `netlify/` und `netlify.toml` liegen. Nicht das ZIP als einzelne Datei ins Repo hochladen.
3. Im **bereits bestehenden** Netlify-Projekt auf **Cloud compute → Functions → Connect to repository** (oder Project configuration → Developer settings → Continuous deployment) gehen. GitHub verbinden, das eben erstellte Repository auswählen und `main` als Produktionsbranch einstellen. **Keine neue Netlify-Site erstellen**, um den bestehenden Link zu behalten.
4. In Netlify unter **Project configuration → Environment variables** diese beiden Variablen für Functions anlegen:
   - `SUPABASE_URL`: Deine bestehende Projekt-URL (`https://…supabase.co`)
   - `SUPABASE_SECRET_KEY`: Ein **NEUER** sicher verwahrter Supabase Secret Key (`sb_secret_…`). Niemals in Repository, HTML, Screenshot oder Chat veröffentlichen.
5. Netlify baut und veröffentlicht die Site. `netlify.toml` liefert den Inhalt von `public` aus und richtet die Scheduled Function alle sechs Stunden ein.
6. Unter **Cloud compute → Functions** `archidekt-sync` aufrufen. Erst `Run now` testen und **Logs** prüfen. In Supabase den Status `commander_sync_status` und den Katalog `commander_catalog` prüfen. Ein Fehler lässt die bisherige Liste unverändert.

## Sicherheitslogik

- Synchronisationsintervall 6 Stunden, jeweils 00/06/12/18 UTC.
- Wenn Archidekt keine plausible Liste mit genügend Decks/Besitzern liefert, schlägt die Funktion fehl und verändert den aktiven Katalog nicht.
- Unveränderte Commander behalten ihre IDs und damit die Bewertungshistorie. Neu aufgenommene Commander erhalten neue IDs; entfernte erscheinen nicht mehr in der aktiven Deckliste.
- Der Supabase Secret Key darf nur in Netlify-Serverumgebungsvariablen liegen. Die Website enthält lediglich den Publishable Key.

## Grenzen

Das API-Verhalten von Archidekt ist nicht als stabil garantiert. Der Abruf **aus der echten Netlify-Laufzeit** wurde noch nicht bestätigt. Bitte den ersten `Run now`-Test und die Logs abwarten, bevor ein erfolgreicher Live-Abgleich angenommen wird.

**Achtung:** Eine Git-verbundene Site wird durch Pushes auf `main` neu veröffentlicht. Nach einem Git-Deployment keine älteren HTML-ZIPs mehr auf die Site laden, sonst können neuere Funktionen beim manuellen Deployment wieder fehlen.
