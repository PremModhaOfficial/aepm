# aur-prefetch TUI, playable in a browser

`aur-prefetch.html` is a self-contained demo of the landed TUI: no build step
needed to open it, no server, no network.

Its screens are the app's own captures. `tests/golden/*.txt` is the fixture set
`src/tui/render.rs` asserts byte for byte, so every screen here is what the Rust
binary printed, not a redrawing of it.

## Run it

```sh
xdg-open prototype/web/aur-prefetch.html
```

Keys: `F` fetch (PRE-FLIGHT → streaming → progress → failure → repair), `i`
install (gate → receipt), `l` log, `g` ledger, `Esc` close or detach, `q` quit,
`Ctrl-A` ascii glyph tier, `Ctrl-V` self-check. The scene picker jumps straight
to any captured screen.

## What is captured and what is reconstructed

| Thing | Status |
|---|---|
| Every cell of every screen | captured: byte-identical to `tests/golden` |
| Geometry (80x24, 120x40) | captured; a screen only ever captured at 120x40 is shown at 120x40 |
| Key paths | replayed from the landed state machine in `src/tui/` |
| Colour, bold, dim | **reconstructed** from the token table in `TUI.md`; the golden fixtures store text only |
| Timing | 700 ms per captured step; a real fetch has no machine-readable progress |
| Screens with no capture (Dashboard, Caches, Doctor, help, palette) | absent on purpose |

## Regenerate and check

```sh
node prototype/web/build.mjs     # tests/golden -> aur-prefetch.html
node prototype/web/verify.mjs    # headless chromium: 43 assertions
```

`verify.mjs` renders every capture in chromium and compares the DOM text of the
terminal pane with the fixture, then drives the key paths and compares those
screens too. Both scripts fail loudly; neither is part of `ci.sh`.
