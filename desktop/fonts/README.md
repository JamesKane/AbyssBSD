# Vendored fonts (PHASE11 P11.7)

Plan Neo's four families, one per type role, vendored so the same files are on
the dev box, the FreeBSD guest and the medium (installed to
`/usr/local/share/abyss/fonts`). All are under the SIL Open Font License 1.1,
which permits redistribution with the licence; each directory carries its
`OFL.txt`.

| Directory | Family | Role in Plan Neo | Source |
|---|---|---|---|
| `ibmplexsanscondensed/` | IBM Plex Sans Condensed (regular, bold, italic, bold italic) | interface | google/fonts `ofl/ibmplexsanscondensed` |
| `ibmplexmono/` | IBM Plex Mono (regular, bold) | mono | google/fonts `ofl/ibmplexmono` |
| `chakrapetch/` | Chakra Petch (regular, bold) | chrome | google/fonts `ofl/chakrapetch` |
| `vt323/` | VT323 (regular) | readout | google/fonts `ofl/vt323` |

Fetched 2026-09-25 from `https://raw.githubusercontent.com/google/fonts/main/ofl/`.
A theme names a family per role in `[fonts]`; the toolkit finds it by name
through fontconfig, with this directory added (`ThemeLoader.fontDirs`).
