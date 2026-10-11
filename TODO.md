# TODO — conspectus

*Offene Punkte und Überlegungen, die nicht in Code oder NOTES.md stehen.
Reihenfolge-Tabelle = geplant; „Notiert, nicht geplant" = Gedanken mit
Auslöser, ohne Termin.*

## Reihenfolge

| Schritt | Inhalt | Stand |
|---|---|---|
| 1 | Automatischer yazi-Re-Theme nach light↔dark (wartet, bis die Pane ruht) | gebaut 2026-10-11, im Alltag zu beobachten: flackert der Neustart bei Sonnenauf-/-untergang störend? |

## Notiert, nicht geplant

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
