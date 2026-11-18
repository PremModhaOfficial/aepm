# STATE-MACHINES.md: the machines the code keeps implicit

Status: documentation. This file adds no state and changes no behaviour. When a
table here and the code disagree, one of them is wrong.

`scripts/gate-state-machines.sh` (run by `./ci.sh`) fails when a variant listed
here leaves the code, or when a line cited in [the anchors](#anchors) no longer
says what the table claims. Read with [`TUI.md`](../TUI.md) for screens and
keys, [`docs/ANIMATION.md`](ANIMATION.md) for the execution frontier,
[`GLOSSARY.md`](../GLOSSARY.md) for the words, and [`NEXT.md`](../NEXT.md), which
wins on order.

## Why this file exists

A machine assembled from `Option<Session>`, `Option<Notice>` and one nested
`match` has states nobody can name. Nobody can review a transition, test a dead
state, or notice a flag left behind by the screen that owned it. Each section
below names one machine, its states, its transitions, and **the one place that
owns its precedence**. "Owner" means the single function whose control flow
decides the next state. A second place deciding the same thing is the defect.

Two labels recur, and they are not decoration:

- **Enforced** means a test, an `assert!`, or a type refuses the illegal
  transition, and the row names which.
- **Not enforced** means the transition is the order of control flow. Those
  sections say so, and say what would prove it.

## M1. TUI screens, body and modal stack (`src/tui/mod.rs`)

The screen is not one value. It is a body plus a stack of overlays, and the two
axes resolve differently: **the body is a precedence, the overlays are a
stack.** `run_interactive` holds the whole state:

| field | type | a state the reader has to infer |
|---|---|---|
| `session` | `Option<FetchSession>` | a fetch that is running, frozen, or finished |
| `notice` | `Option<Notice>` | a refusal, or a post-install result, over the static tree |
| `install_gate` | `Option<InstallGate>` | the pre-flight screen, read-only |
| `post_install` | `Option<Receipt>` | the after-the-fact install summary |
| `help`, `ledger` | `bool` | body modes, not overlays |
| `log_open` | `bool` | the log of the session that owns it |
| `news_attested` | `bool` | "I read the news", for this TUI process only |
| `selection` | `live::Selection` | the cursor, always re-planned against the drawn frame |

### Body states

| body | guard | entered by |
|---|---|---|
| static tree | `session = None` and `notice = None` | start-up, `r`, dismissing a session |
| live | `session` at `Phase::Running` | `F` with every gate passing |
| frozen | `session` at `Phase::Failed`, repair card set | a nonzero command exit |
| finished | `session` at `Phase::Finished { unproven }` | a zero command exit |
| notice | `session = None` and `notice = Some` | a gate refusal, or a finished install |

**Precedence, owned by `frame_parts` in `src/tui/mod.rs`:** `session` first, then
`notice`, then the static tree. The body is chosen by
[`frame_parts`](#anchors), and both the draw closure and the `j`/`k` cursor
planner consume its result, so a session always shadows a notice and the planned
frame cannot disagree with the drawn one. Consequence: an install started while
a finished fetch is on screen leaves that notice invisible until the session is
dismissed, because `Esc` clears the session and keeps the notice. Shadowed,
never lost.

### Overlay stack

| rank | overlay | guard | paint order |
|---|---|---|---|
| 1 (top) | post-install receipt | `post_install.is_some()` | last |
| 2 | install gate | `install_gate.is_some()` | after the log |
| 3 | log | `log_open` and `session.is_some()` | after the body |
| 4 (bottom) | body | always | first |

**Precedence, owned by `accepts` in `src/tui/mod.rs`:** the same order decides
which actions are live. `resolve` turns a press into the action the keymap binds
and `accepts` refuses any action the open modal does not list, so the receipt and
the gate each get their own small set and no global binding can fire under a
modal. The loop keeps the rank order `if post_install.is_some()`, then `if
install_gate.is_some()`, then the main match, each ending its branch with
`continue`. A key that reaches a lower rank is a key the higher rank does not
accept, not a key it declined.

The tables below name the v1 default binding for each row. `[keys]` in
`tui.conf` rebinds the action without changing the rank: every row is an action,
and `src/keymap.rs` is the one place a key is attached to it.

`help` is drawn by the body renderer, so an open help stays visible under a
modal that opened afterwards; `?` cannot toggle it while a modal has the keys.
`ledger` is a body mode with the same rule.

### Transitions

Main rank (no modal open):

| from | key | to | note |
|---|---|---|---|
| any | `q` | exit 0 | exits without killing a fetch; the child keeps running |
| any | `^c` | exit 130 | `Error::Interrupted` |
| any | `^z` | same | suspends, restores the terminal, repaints |
| any | `?` | same | toggles `help` |
| any | `g` | same | toggles `ledger` |
| any | `j` / `k` | same | moves the cursor over the rows actually drawn |
| `session = Some` | `l` | same | toggles `log_open`; ignored when there is no session |
| running | `i`, `r`, `F` | same | writes a refusal into the status line: one mutation at a time |
| not running | `i` | gate open | pre-flight runs here, read-only |
| not running | `r` | static tree | clears session, notice and `log_open`, recollects |
| not running | `F` | live, or notice | new session, or `StartFailure` as a notice |

`Esc` is a ladder, not a key: it consumes exactly one rung per press.

| rung | guard | effect |
|---|---|---|
| 1 | `help` | `help = false` |
| 2 | `log_open` | `log_open = false` |
| 3 | `session` running | detach: exit 0, and print that pacman may still run |
| 4 | `session` present | dismiss: `session = None`, `log_open = false`, recollect |
| 5 | otherwise | `notice = None` |

Gate rank:

| from | key | to | note |
|---|---|---|---|
| gate | `Esc` | body unchanged | **the attestation survives this** by design |
| gate | `space` | gate | `news_attested = true` |
| gate | `Enter` | receipt | only when armed: attested, no gate failed, euid known |
| gate | `Enter` | gate | not armed: repaint only, no message |
| gate | `q` / `^c` | exit 0 / exit 130 | |

An armed `Enter` is the one transition that leaves the TUI. It drops the
terminal, runs `yay -Syuu` attached with the CLI's `Options`, restores the
terminal, recollects the snapshot, opens the receipt, stores the install notice
and **resets `news_attested`**.

Receipt rank: `Esc` or `Enter` closes it, `q` quits, `^c` exits 130, every other
key is ignored. Closing reveals whatever was underneath; `session` and `notice`
are untouched by the receipt.

### The invariants

| invariant | enforced by |
|---|---|
| `session.is_some() or not log_open` | [`assert!` at the top of every loop iteration](#anchors), and `sim/49` under a pty |
| the log never outlives its session | every path that ends a session clears `log_open`; the `assert!` catches a future one that forgets |
| an attached install never runs concurrently with a fetch | `i` refuses while running, and the gate's `Enter` re-checks |
| the attestation is never written to disk | it is a local `bool`, set only by `space` |

The log-flag invariant is the one #45 found missing: dismissing a finished
session used to leave `log_open = true` with no session to toggle it off, and
only `r` and `F` cleared it. #57 closed it on both sides, the clearing branch
and the `assert!`; `sim/49` opens a log, ends its session with a refused fetch,
and requires one `Esc` to clear the notice rather than be spent on a stranded
flag.

**Not enforced:** no type names the composite screen, so the precedence above
is the order of one `match` and two `if`s. No unit test covers the ranking; the
pty scenarios reach it only where they already drive a key (`sim/32` the gate,
`sim/36` the receipt, `sim/49` the log). A wrong order is a sim failure at best,
never a compile error.

## M2. Fetch session (`Phase`)

One fetch is one session. The gates are not a phase: a refusal happens before a
session exists.

| state | meaning | terminal |
|---|---|---|
| `Running` | the worker owns the command; the view polls the cache | no |
| `Finished { unproven }` | exit 0; `unproven` downloads never proved a final artifact | yes |
| `Failed { evidence }` | exit nonzero; `evidence` is the exit code and a bounded stderr excerpt | yes |

| from | event | to | owner |
|---|---|---|---|
| none | a failing gate | `StartFailure`, never a session | `fetch::plan_observed` |
| none | all gates pass, command spawned | `Running` | `FetchSession::start` |
| `Running` | exit 0 | `Finished { unproven }` | `fold_exit` |
| `Running` | exit nonzero, or the worker dies without an exit | `Failed { evidence }` | `fold_exit` |
| `Running` | cache read fails | `Running` | the error is latched and shown; the real exit still decides |

Terminal phases are absorbing: only a new session leaves them, and only through
`F` or `r`. `Finished` does not freeze the graph, because a zero exit is not a
failure; `Failed` does.

## M3. Gates (`GateState`)

A gate is one observed check, not an action.

| state | means | effect |
|---|---|---|
| `Pass` | the check succeeded | the sequence continues |
| `Warn` | the input was incomplete, the check did not block | the sequence continues |
| `Fail` | the check blocked | see the two sequences below |

**Who owns precedence:** the order of the calls inside the collector. Both
collectors report the gates in the order they run, so a footer can only show
checks that actually happened.

| sequence | order | on the first `Fail` |
|---|---|---|
| fetch, `fetch::plan_observed` | lock, lists, cache, space (cache), space (`/`), state | returns the error; later gates are **absent** |
| install, `install::preflight` | root, lock, lists, trust, state, news (`Warn`) | pushes the failure and **continues** |

The asymmetry is deliberate: fetch gates guard a download, so the first block
ends the plan; install gates are all read-only, so the gate screen shows the
whole checklist and `Preflight::blocked()` (any `Fail`) decides whether `Enter`
arms. A fetch `Fail` becomes a `Notice`; an install `Fail` disables arming and
nothing runs.

## M4. Lock gate (`LockState`)

Two readers of one probe. `lock::running` asks `pgrep -x
pacman|yay|makepkg|aurto`; `lock::check` turns the answer into a refusal, and
`collect_lock` turns the same answer into a report value. `doctor` asks it a
third time, from the pair of answers, because the pair is the diagnosis.

| probe | `lock::check` (the gate) | `LockState` (report) | `doctor` (audit) |
|---|---|---|---|
| a process matched, `db.lck` exists | `Blocked`, naming the process | `HeldBy(name)` | `Ok`, "held by {name}" |
| a process matched, no file | `Blocked`, naming the process | `HeldBy(name)` | `Blocked`, "{lock} is missing while {name} runs" |
| no match, file exists | `Blocked`, "stale lock", never deleted | `Stale(path)` | `Blocked`, "stale {lock}" |
| no match, no file | `Ok` | `None` | `Ok`, "no transaction or build running" |
| `pgrep` exited other than 0 or 1 | `Failed`, exit 2 | the section is `Failed` | the check errors, exit 2 |
| `pgrep` exited 0 without printing a name | `Failed`, exit 2 | the section is `Failed` | the check errors, exit 2 |

**Who owns precedence:** `lock::check` is the refusal for `fetch`, `install` and
`check`, and it is always the `lock` gate in both gate sequences (M3). No caller
re-implements that rule. `LockState` is observation only and decides nothing.
`check` and `doctor` report the state and never refuse to run: `check` counts a
non-`None` state as one actionable item, which is why `check` exits 1 while
still printing the whole report.

One deliberate disagreement: a live process **with** the lock file is `Ok` for
`doctor` and `Blocked` for the gate. The gate cannot tell a healthy transaction
from a build that left the file behind, and refusing is the safe read; naming
which one it is happens to be `doctor`'s whole job.

**Known and inherent:** a `pgrep` that answers before the command starts is a
TOCTOU gap. A second process can take the database between the probe and the
`pacman` call. The state machine cannot close it from user space; `pacman`'s own
lock is the backstop.

## M5. Artifact state (`ArtifactState`, and the dead `Cached`)

`ArtifactState` is what the cache scan proves about one package. Seven states,
one per package, and `rank()` is the **glyph** precedence for a row that has
several observations, not a state transition.

| state | means | ready |
|---|---|---|
| `Cached` | a current file sits in the download cache | yes |
| `Built` | a current file sits in the build output | yes |
| `Stale` | a file exists for an older version | no |
| `Partial` | some files present, not all | no |
| `Missing` | nothing on disk | no |
| `BuildPending` | `aurto` or `yay` is building it | no |
| `Unknown` | the scan could not answer | no |

`Cached` (the older enum on `Update`, not `ArtifactState`) has three variants:

| variant | produced by |
|---|---|
| `Yes` | nothing |
| `No` | nothing |
| `Unknown` | every writer |

`Yes` and `No` are dead states: every construction site writes `Unknown`. A
branch on them is a branch that never runs. Tracked as issue 66; the table stays
here so a reader does not discover it by reading three files.

`Counts.held` is the same class of thing: `Option<usize>`, always `None`,
because no IgnorePkg or IgnoreGroup parser exists. `None` is an honest "not
known", never a guessed zero. Tracked as issue 67.

## M6. Clean builds (`YayAction`)

One build directory under the yay cache, older than 30 days, plus one flag for
the directory as a whole.

| state | means |
|---|---|
| `KeepUnidentified` | nothing in the directory names the package: no `.SRCINFO` and no built archive |
| `KeepNotInstalled` | none of the names it declares is installed |
| `WouldRemove` | installed, and this is a dry run |
| `Removed` | installed, and `--apply` deleted it |

| from | evidence | to | owner |
|---|---|---|---|
| a build directory, any action | no declared name | `KeepUnidentified` | `collect_yay` |
| a build directory, any action | names declared, none installed | `KeepNotInstalled` | `collect_yay` |
| a build directory, dry run | a declared name is installed | `WouldRemove` | `collect_yay` |
| a build directory, `--apply` | a declared name is installed | `Removed` | `collect_yay` |
| the whole report | the yay cache directory is missing | `YayReport::absent` | `collect_yay` |

**Who owns precedence:** the decision order in `collect_yay`: identify, then
membership, then act. A build is never deleted on a guess, so
`KeepUnidentified` outranks everything.

Issue 47 recorded a leak here: the `.SRCINFO`-missing fallback could misclassify
a split package's installed name and keep the build forever. The state that
closes it is `KeepUnidentified`: an unreadable build is kept **and reported as
unidentified**, not as "not installed". A kept build is disk space, not
corruption, and the report names it.

## M7. Execution frontier (`NodeState`)

The seven node states — `Pending`, `Ready`, `Running`, `Done`, `Failed`,
`Skipped`, `Blocked` — and their transitions are owned by
[`docs/ANIMATION.md`](ANIMATION.md) sections 2 and 3; this file does not restate
them. What is implicit there is that two flags sit **beside** the node states
and can disagree with them:

| flag | means | terminal |
|---|---|---|
| a node's `NodeState` | what the reducer has observed | `Done`, `Failed`, `Skipped`, `Blocked` |
| `GraphState::frozen` | a failure was observed; every later observation is ignored | no |
| `GraphState::is_complete` | every node is terminal | yes |

`frozen` is not a node state and not completion. A failure freezes the run while
independent `Ready` nodes stay `Ready`, because the reducer never moves a node
outside the failure's closure — so the model says "could start" and the run
will never start it. The view reconciles the two: `LiveState::from_node`
maps `Pending` and `Ready` to `BlockedByFreeze` once the run is frozen, so a
promise the run cannot keep is never drawn. Issue 69 is the record of that
reconciliation.

Rule: read `frozen` before drawing any `Ready` row, and never infer
`is_complete` from `frozen`.

## M8. Exit codes (`Error`)

Three typed failures, mapped once.

| state | exit | raised by |
|---|---|---|
| `Blocked` | 1 | a gate refused; the user can act on it |
| `Failed` | 2 | an execution error the tool did not control |
| `Interrupted` | 130 | Ctrl-C in the TUI, or a signal flag |
| ok | 0 | a normal quit, including a detach |
| actionable snapshot | 1 | `--render-once` only: `attention` found work |

**Who owns precedence:** `Error::exit_code` is the only mapping; `main` does
nothing but hand it to `ExitCode`. A command that wants a different code must
return a different error, not compute one.

## M9. Partial upgrade (`State::last_fetch_pending_names`)

A partial upgrade is a name the last successful `fetch` planned that is still
pending after `yay -Syuu` exits 0. The two sets are package names, never
counts: a count cannot tell a finished upgrade from a different unfinished one.

| planned ∩ still pending (`pacman -Qu`) | state after `install` | writes |
|---|---|---|
| empty | the upgrade is complete: the install time is recorded | the state file, as today |
| non-empty | `Failed`, exit 2, one sentence naming the packages | **nothing**: no state, no package DB, no `/usr` |
| the fetch recorded no names | `Ok` with a warning that it cannot be told | the state file, as today |

**Who owns precedence:** `install::check_partial_upgrade`. It runs only after
the helper returned 0, and it is the only place that decides. `check`'s
`PartialUpgrade` reads `pacman.log` as evidence and refuses nothing, so the two
never contradict each other: one writes nothing, the other is the refusal.

**Known and inherent:** the set is the last fetch's, so a `pacman -Sy` in
between can make new packages pending that the set never named. Those are the
next fetch's business, not a partial upgrade, and `install` is right to leave
them to it.

## Declared but unreachable

States the model declares and no path produces. Each is a documentation fact
until its issue closes it; none is a bug in a transition.

| declaration | why it is unreachable | issue |
|---|---|---|
| `Cached` | only `Unknown` exists; `Yes`/`No` deleted, no producer could set them | 66 |
| `Counts.held` | no IgnorePkg or IgnoreGroup parser | 67 |

## Anchors

Every row is checked by `scripts/gate-state-machines.sh`: the cited line must
still say exactly the text in the third column. A moved line fails the gate on
purpose, so this table cannot quietly describe an older tree.

| Claim | Anchor | The line says |
|---|---|---|
| the body precedence, and its order | `src/tui/mod.rs:641` | `let (footer, gates, body) = match (session, notice) {` |
| the receipt rank, above the gate | `src/tui/mod.rs:239` | `if post_install.is_some() {` |
| the gate rank, above the main match | `src/tui/mod.rs:251` | `if install_gate.is_some() {` |
| the log-flag invariant | `src/tui/mod.rs:155` | `assert!(` |
| the `Esc` ladder | `src/tui/mod.rs:341` | `Some(Action::Back) => {` |
| the arming predicate | `src/tui/mod.rs:256` | `let armed = news_attested` |
| the attestation reset | `src/tui/mod.rs:306` | `news_attested = false;` |
| the modal action allow-list | `src/tui/mod.rs:502` | `fn accepts(context: Context, action: Action) -> bool {` |
| the session phases | `src/tui/fetch_session.rs:61` | `pub enum Phase {` |
| the exit fold | `src/tui/fetch_session.rs:355` | `fn fold_exit(&mut self, output: CommandOutput, at: SystemTime, tick: &mut Tick) {` |
| the fetch gate order | `src/commands/fetch.rs:103` | `pub fn plan_observed(` |
| the partial-upgrade refusal | `src/commands/install.rs:339` | `fn check_partial_upgrade(` |
| the install gate order | `src/commands/install.rs:53` | `pub fn preflight(config: &Config, runner: &dyn CommandRunner) -> Preflight {` |
| the install arming verdict | `src/commands/install.rs:44` | `pub fn blocked(&self) -> bool {` |
| the lock probe | `src/lock.rs:17` | `pub fn running(runner: &dyn CommandRunner) -> Result<Option<String>, Error> {` |
| the lock refusal | `src/lock.rs:42` | `pub fn check(config: &Config, runner: &dyn CommandRunner, action: &str) -> Result<(), Error> {` |
| the lock observation | `src/commands/check.rs:466` | `fn collect_lock(config: &Config, runner: &dyn CommandRunner) -> Result<LockState, Error> {` |
| the third reader of the lock probe | `src/commands/doctor.rs:103` | `fn report_lock(` |
| the clean decision loop | `src/commands/clean.rs:187` | `fn collect_yay(` |
| the freeze on failure | `src/frontier.rs:401` | `self.frozen = true;` |
| completion is separate from freezing | `src/frontier.rs:512` | `pub fn is_complete(&self) -> bool {` |
| `Ready` under a freeze draws blocked | `src/tui/live.rs:95` | `fn from_node(state: NodeState, frozen: bool) -> Self {` |
| the exit-code mapping | `src/error.rs:24` | `pub fn exit_code(&self) -> u8 {` |
