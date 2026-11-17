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

App keys, per `src/tui/mod.rs`: `F` fetch (PRE-FLIGHT → streaming → progress),
`i` install (modal gate: `space` attests, then `enter`), `l` log once a fetch
has started, `g` ledger toggle, `r` refresh, `j`/`k` cursor, `?` help,
`Esc` close or end, `q` quit. The install gate and the receipt are modal: they
take no other key, exactly as the landed loop does.

Demo-only controls: `x` replays the failing fetch the repair card explains,
`Ctrl-A` switches to the ascii tier, `Ctrl-V` runs a self-check that reads the
DOM back and compares it with the capture. The scene picker jumps to any
captured screen.

## What is captured and what is simulated

| Thing | Status |
|---|---|
| Every cell of every screen | captured: byte-identical to `tests/golden` |
| Geometry (80x24, 120x40) | captured; a screen only ever captured at 120x40 is shown at 120x40, and the substitution is announced in the note line |
| Key paths, refusals, modality | simulated from `src/tui/mod.rs`; each path has an assertion in `verify.mjs` |
| Colour, bold, dim | **reconstructed** from the palette constants in `src/tui/render.rs` (`PLANNED` blue, `ACTIVE` yellow, `DONE` green, `DIM`, `FAILURE` red, cyan cursor); the fixtures store text only |
| Timing | 700 ms per captured step; a real fetch has no machine-readable tick |
| Ledger and log | captured frames, not the app's in-place redraw over the current tree |
| `showcase` | a `#[cfg(test)]` synthetic composite in `render.rs`; selectable in the picker, labelled, never part of a run |
| Screens with no capture (Dashboard, Caches, Doctor, help, palette) | absent on purpose, and the demo says so when asked for them |

## Regenerate and check

```sh
node prototype/web/build.mjs     # tests/golden + app.js -> aur-prefetch.html
node prototype/web/verify.mjs    # headless chromium: 66 assertions
```

`verify.mjs` renders every capture in chromium and compares the DOM text of the
terminal pane with the fixture; then it drives the key paths, modal refusals,
the timed runs, the size selection, the palette classes per glyph, the ascii
tier's monochrome rule, and both outcomes of the self-check. Both scripts fail
loudly. Neither is part of `ci.sh`: this directory is a demo, not a command.
