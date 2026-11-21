# GLOSSARY

The words this project uses for its own things. One meaning per word, one word
per meaning. If code and this file disagree, the code is wrong or this file is.

Test names, commit messages and issues use these words, not synonyms.

## Commands

| Word | Means |
|---|---|
| `check` | Read-only report: what is pending, what is cached, whether a fetch would be allowed. Writes nothing. |
| `fetch` | Downloads pending packages into the cache. Writes only the pacman sync database and the cache. Never installs. |
| `install` | Installs what `fetch` downloaded. Never rebuilds a package that was already built. |
| `clean` | Reports or deletes stale cache entries. Dry run unless told otherwise. |
| `init` | Writes the aepm half of the one-shot setup: the sudoers rule, and the user service and timer. aurto's repo and its `Include` line are `aurto init`'s. |
| `doctor` | Read-only audit of the setup: paths, permissions, timer state, disk. |
| `sim` | The disposable Arch container that every writing behaviour is proven in. Lives in `sim/`. |

## The update model

| Word | Means |
|---|---|
| **pending** | An installed package with an update available. The unit the whole tool counts. |
| **artifact** | The downloaded or built file for one package. States below. |
| **cached** | A current package file sits in the download cache. Ready to install. |
| **built** | A current package file sits in the build output. Ready to install. |
| **stale** | A file exists but is for an older version than the pending one. Not ready. |
| **partial** | Some of a package's files are present, not all. Not ready. |
| **missing** | Nothing on disk for it. |
| **unknown** | The scan could not answer. A value, never a silent zero. |
| **build pending** | `aurto` or `yay` is building it now. |
| **space floor** | The minimum free bytes below which `fetch` refuses. One calculation, shared with `check`. |
| **pending download** | Bytes the pending packages will need. Raises the floor; it does not replace it. |
| **lock gate** | The refusal while `pacman`, `yay`, `makepkg` or `aurto` is running. Checked by process name first, then by `db.lck`. |

## The tree

| Word | Means |
|---|---|
| **forest** | The whole view. One row per package. |
| **tree** | The pending packages and their pending dependencies, arranged bottom-up. |
| **root** | A pending package with no pending package depending on it. One root per top-level update. |
| **display-only leaf** | A dependency shown with `?` because it is outside the pending set. Shown, never counted. |
| **frontier** | The set of packages whose dependencies are already satisfied, so work may start. |
| **readiness** | Whether a package's requirements are met. Computed once, in `frontier`. |
| **frame model** | The rows, the budget for one screen, and the forest and live view they were measured against. Built only in `plan_frame`. |
| **`plan_frame`** | The single owner of body layout arithmetic and of the forest that arithmetic names. Nothing else may compute a row budget or build a second forest per frame. |

## Reporting

| Word | Means |
|---|---|
| **report layer** | The shared types (`report.rs`) every command and the TUI fills in. |
| **section** | One collected fact, carrying `ready`, `failed` or `not collected` and the time it was taken. `not collected` is not zero. |
| **verdict** | `ok`, `warn`, `blocked`, `error` or `skipped`. |
| **gate** | A refusal with a reason the user can act on. |
| **pre-flight** | The gates shown before a fetch starts, from `fetch::plan_observed`. |
| **receipt** | The read-only after-the-fact summary of an install. Changes nothing. |
| **repair card** | What the TUI shows after a failed fetch: the failure, and the rows it blocked. |
| **log ledger** | The `l` screen: the real captured lines, not a reconstruction. |

## Setup and safety

| Word | Means |
|---|---|
| **snapshot** | A `snapper` rollback point taken before an install. |
| **aurto** | The background AUR builder. Builds as the user, installs with root. |
| **trust** | Whether `aurto` will build a maintainer's package. |
| **drift** | A built package whose cached artifact no longer matches the recipe. |
| **partial upgrade** | An update that installed some packages and not others. `install` refuses one: the names the last `fetch` planned are compared with `pacman -Qu` once `yay -Syuu` exits 0, and a name on both sides is exit 2 with the packages named and nothing written. `check` also reports one from `pacman.log`. Never resolved silently. |
| **state file** | The only file this tool writes about itself. It carries the last fetch's pending **names**, so a later `install` can compare sets. A failed write is a warning, never a failed download. |
| **invariant** | A rule proven by a test and a sim scenario, not by inspection. |

## State machines

Tabulated, with its transitions and its owner, in
[`docs/STATE-MACHINES.md`](../docs/STATE-MACHINES.md). Use these words for these
things and no synonyms.

| Word | Means |
|---|---|
| **machine** | A set of states one owner moves between. Named in the table, never re-derived from a `match`. |
| **owner** | The one function whose control flow decides the next state. A second place deciding it is the bug. |
| **precedence** | The one order that resolves what is drawn and which key runs. Modal first, then body. |
| **body** | What fills the frame: the static tree, a live session, or a notice. One of the three, by precedence. |
| **overlay** | A layer over the body: the log, the install gate, the receipt. Stacked in that order. |
| **modal** | An overlay that takes every key. The gate and the receipt are modal; help and the log are not. |
| **log open** | The `l` flag. It belongs to a session and cannot be true without one. |
| **attestation** | The `space` in the install gate, meaning "I read the news". In the TUI process only, never on disk. |
| **phase** | Where a fetch is: running, finished, failed. A gate refusal never reaches a phase. |
| **lock state** | `None`, `HeldBy` or `Stale`: what the probe found. Reported, never decisive; the **lock gate** refuses. |
| **dead state** | A variant nothing produces. Documented as dead, never branched on. |
| **anchor** | A `path:line` claim in the docs that a gate re-reads before CI can pass. |

## Where these live

`spec.md` for the plain-language flow, `PROGRESS.md` for the tree states,
`TUI.md` for the screens, `docs/STATE-MACHINES.md` for the states and who owns
precedence between them, `docs/ANIMATION.md` for the execution model, `NEXT.md`
for the order of work.
