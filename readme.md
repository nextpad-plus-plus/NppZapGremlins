# Zap Gremlins (Nextpad++ macOS plugin)

Remove or replace "gremlin" characters — invisible, control, or non-ASCII
characters that sneak into files and cause subtle bugs. Inspired by BBEdit's
classic "Zap Gremlins" feature.

## Usage
`Plugins > Zap Gremlins > Zap Gremlins…` opens the dialog. It operates on the
current **selection** if there is one, otherwise the **whole document**, as a
single undo step.

**Search for** (any combination):
- **Non-ASCII characters** — any code point above U+007F
- **Control characters** — C0 controls (U+0000–U+001F) and DEL (U+007F),
  excluding Tab, CR and LF
- **Null (ASCII 0) characters** — U+0000

**…and then**:
- **Delete** — remove the matched characters
- **Replace with character** — substitute each with a character you choose (default `*`)
- **Replace with code** — `\uXXXX` (or `\u{XXXXX}` for astral planes).
  *Use ASCII equivalent* first transliterates common typographic characters
  (smart quotes → `'` `"`, en/em dash → `-`, NBSP → space, ellipsis → `...`, …)
- **Replace with HTML entity** — `&#NNN;`, or a *named entity* (`&nbsp;`,
  `&mdash;`, `&eacute;`, …) when available

## Quick Zap
`Plugins > Zap Gremlins > Quick Zap` runs immediately using your saved settings —
no dialog, no result popup — so it can be bound to a keyboard shortcut or driven
from a macro. Configure the behavior once in the Zap Gremlins window, then use
Quick Zap for one-keystroke cleanups.

## Highlight gremlins
`Plugins > Zap Gremlins > Highlight gremlins` toggles a Scintilla indicator that
marks a curated set of invisible/ambiguous Unicode characters (zero-width
spaces, bidi controls, smart quotes, NBSP, soft hyphen, …).

## License
GNU General Public License v3.
