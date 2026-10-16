# TODO — conspectus

*Offene Punkte und Überlegungen, die nicht in Code oder NOTES.md stehen.
Reihenfolge-Tabelle = geplant; „Notiert, nicht geplant" = Gedanken mit
Auslöser, ohne Termin.*

## Reihenfolge

| Schritt | Inhalt | Stand |
|---|---|---|
| 1 | Automatischer yazi-Re-Theme nach light↔dark (wartet, bis die Pane ruht) | gebaut 2026-10-11, im Alltag zu beobachten: flackert der Neustart bei Sonnenauf-/-untergang störend? |

## Notiert, nicht geplant

- **Ordnerliste: Datumsspalte am rechten Rand** (2026-10-16). Die Spalte
  Größe + Datum sitzt heute an einem Tab-Stop hinter dem längsten Namen
  (`folderListingNameColumn`), weil `renderListing` die Pane-Breite nicht
  kennt; yazi setzt sie an den rechten Rand. Lösung: rechtsbündiger Tab-Stop,
  gesetzt in `Panel+Preview` beim Anwenden, wo die Text-View-Breite bekannt
  ist, und neu gesetzt bei Resize. Bekannte Grenzen derselben Stelle:
  die Namensbreite zählt Zeichen, nicht Zellen (CJK/Emoji doppelt breit);
  „heute" veraltet über Mitternacht, bis die Pane neu rendert (Hover oder
  Refresh). Auslöser: wenn die springende Spalte beim Ordnerwechsel stört.

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
