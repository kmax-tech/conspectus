# TODO — conspectus

*Offene Punkte und Überlegungen, die nicht in Code oder NOTES.md stehen.
Reihenfolge-Tabelle = geplant; „Notiert, nicht geplant" = Gedanken mit
Auslöser, ohne Termin.*

## Reihenfolge

| Schritt | Inhalt | Stand |
|---|---|---|
| 1 | Automatischer yazi-Re-Theme nach light↔dark (wartet, bis die Pane ruht) | gebaut 2026-10-11, im Alltag zu beobachten: flackert der Neustart bei Sonnenauf-/-untergang störend? |

## Notiert, nicht geplant

- **`conspectus ssh`: an echten Hosts erproben** (2026-11-04). Gebaut und lokal getestet gegen einen nachgebauten Server (Mac als „Remote" über `/usr/libexec/sftp-server`, falsches `sudo` auf `PATH`); an einem echten Host noch nie gelaufen. Zu prüfen: ssh-Passwort/Passphrase im startenden Terminal, TRAMP-Pfad mit `|sudo:` und echtem sudo-Passwort (die Erkennung sucht `password is required` in sudos Meldung), Verhalten beim Abreißen der Verbindung (`reconnect` schickt das Passwort neu). Auslöser: erster echter Einsatz, z. B. `/ssh:leguin|sudo:root@leguin:/home/textimg/ComfyUI/output/`.

- **yazis eigenes SFTP (`sftp://` in `vfs.toml`) in conspectus** (2026-11-04). yazi 26.5 kann SFTP selbst; das Plugin schickt der App dann eine `sftp://`-URL (`plugins/conspectus.yazi/main.lua:56`), die die Vorschau nicht lesen kann. Möglich: die App erkennt das Schema und zeigt einen Hinweis statt einer kaputten Vorschau. Nicht geplant, weil `conspectus ssh` (sshfs) alles abdeckt. Auslöser: wenn jemand das yazi-SFTP doch direkt nutzt.

- **lazycvs: Revision einer Binärdatei (PDF, Bild) ansehen** (2026-10-21,
  gebaut in `~/projects/lazycvs`: History-Tab `o` / `Ctrl-o` öffnen die
  Revision unter dem Cursor als Temp-Datei; Extraktion läuft byte-genau
  über einen stdout-only-Lauf; Dateien ohne `-kb` werden rot gemeldet).
  Offen: ob `alt_open` im eigenen lazycvs-Config auf `qlpeek send $FILE`
  wechselt (dann landet die Revision im Vorschau-Panel, aber `Ctrl-o`
  auf Textdateien geht nicht mehr an Emacs) oder ein kleines Skript nach
  Dateityp verteilt. Entschieden (2026-10-21): keine Opener-Tabelle in
  lazycvs (lazygit hat auch nur einen Befehl; das Routing lebt in der
  Shell). Falls das Skript je nach Tab oder Revision unterscheiden muss:
  lazycvs gibt dem Opener Kontext als Umgebungsvariablen (`LAZYCVS_TAB`,
  `LAZYCVS_REV`), kein Config-Format. Auslöser: erste echte
  Bild-/PDF-Historie.

- **Ordnerliste: Datumsspalte am rechten Rand** (2026-10-16). Die Spalte
  Größe + Datum sitzt heute an einem Tab-Stop hinter dem längsten Namen,
  Namen über 40 Zeichen (`folderListingNameColumn`) werden wie in yazi mit
  „…" gekürzt, weil `renderListing` die Pane-Breite nicht kennt; yazi kürzt
  erst an der Pane-Breite und setzt die Spalte an den rechten Rand. Lösung:
  rechtsbündiger Tab-Stop und Kürzung an der Breite, gesetzt in
  `Panel+Preview` beim Anwenden, wo die Text-View-Breite bekannt ist, und neu
  gesetzt bei Resize. Bekannte Grenzen derselben Stelle:
  die Namensbreite zählt Zeichen, nicht Zellen (CJK/Emoji doppelt breit);
  „today" veraltet über Mitternacht, bis die Pane neu rendert (Hover oder
  Refresh). Auslöser: wenn die springende Spalte beim Ordnerwechsel stört.

- **CVS-Status: was die Offline-Variante nicht kann** (2026-10-18; gebaut
  sind M/A/R/C/? in yazi und in der Ordnervorschau, siehe README). Offen:
  (a) „needs update" ist seit 2026-10-18 das `U`-Zeichen: `cvs -n -q update
  -l` pro betretenem Ordner im Fetcher, Cache 300 s (`CONSPECTUS_CVS_REMOTE`);
  gemessen 0,24 s warm / 0,69 s kalt; die Zeile über dem Dateiinhalt
  („1.4 — current (checked today 10:32)") gibt es seit demselben Tag
  (`Panel+CVSBar.swift`). Offen daran: die Ordnervorschau rechts zeigt `U`
  nur aus dem Cache (kein Serveraufruf pro Hover auf einen Ordner);
  (b) Ordner zeigen keinen Sammelstatus ihres Inhalts (git.yazi rollt hoch;
  für CVS hieße das einen rekursiven Lauf); (c) im echten Fenster noch
  anzusehen: Ausrichtung neben den git.yazi-Platzhaltern. Auslöser: wenn
  eines davon im Alltag fehlt.

- **Kontextmenü: fehlende Finder-Einträge** (2026-10-11). Tags (schreibbar
  über `URLResourceKey.tagNamesKey`, braucht aber eine Farbpunkt-UI),
  Komprimieren (`ditto -c -k --keepParent`), Duplizieren, Alias erzeugen
  (`URL.writeBookmarkData`). Auslöser: wenn einer davon im Alltag fehlt.
  Offen zu prüfen am echten Fenster: füllt AppKit das Services-Untermenü im
  Kontextmenü (Quick Actions) und erscheint die Automation-Abfrage für
  „Informationen" nur einmal?

- **Theme auf ANSI-Indizes statt Truecolor-Flavor** (2026-10-11). Ein eigenes
  `theme.toml` nur mit den 16 Terminalfarben würde den Palettentausch von
  SwiftTerm sofort auf yazi durchschlagen lassen: kein Neustart, kein
  Zustandsverlust. Preis: Catppuccins Flächentöne (Hover-Hintergrund, Rahmen,
  Tab-Leiste) gibt es in 16 Farben nicht, also ein eigener Design-Durchgang.
  Vorab zu prüfen: rendert SwiftTerm bestehende Zellen beim Palettentausch
  wirklich neu? Auslöser: wenn das Neustart-Flackern aus Schritt 1 stört.
- **Pane-Manager (tmux) statt eigener Pane-Verwaltung** geprüft und
  verworfen (2026-10-11): löst das Theme-Problem nicht (yazi liest den
  Hintergrund einmal beim Start, in jedem Terminal), und die native Vorschau
  lebt nicht in einem tmux-Pane; die Variante „Vorschau als eigenes Fenster"
  ist `qlpeek`. Einziger echter Nutzen wäre, dass yazi einen conspectus-
  Neustart überlebt (detach/attach).

- **Audit 2026-10-13 — Rest** (gefixt und committet: Editor-Pane-Theming,
  erzwungenes Event-Log, toter glow-Code, Icon-Hex, geteilte Helfer,
  Doku-Drift in README/CLAUDE/NOTES/Headern). Übrig, ohne Termin:
  - `update()` schreibt `lastPath` und liest `previewPinned` auf dem
    FIFO-Thread ohne Lock (Panel+Preview.swift), während `skipDirs` eines
    bekam. Entweder ein Lock oder ein „Main thread only"-Verdikt mit
    Begründung. Auslöser: ein Race im Alltag.
  - Kleinere Klarheit: `yankChanged("copy:")` als Reset
    (Panel+Terminal.swift), `resolveStart(home: currentYaziDir())` als
    Fallback-Zweckentfremdung (Panel+Terminal.swift).
  - Panel ist das God-Object (rund 90 Stored Properties, zehn Extensions);
    einziger größerer Hebel wäre ein Preview-Controller (Cover-Logik + Watch
    + Dedup). Auslöser: wenn Panel+Preview beim nächsten Feature kippt.
