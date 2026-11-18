//! Full-screen TUI entry point.
//!
//! The static tree is read-only. `F` runs the existing `fetch` command through
//! [`fetch_session`] and draws the real cache until it exits; a nonzero exit
//! freezes the run and shows the repair card. `i` opens the install gate, the
//! one screen that hands the terminal to `yay`. The screens, the precedence
//! between them and the log's owner are tabulated in
//! `docs/STATE-MACHINES.md` (M1), not inferred from this file.

pub mod fetch_session;
pub mod guard;
pub mod live;
pub mod render;
pub mod sanitize;
pub mod tree;

use std::io::{self, IsTerminal, stdout};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, SystemTime};

use crossterm::event::{self, Event, KeyEvent, KeyEventKind};
use crossterm::terminal;
use ratatui::Terminal;
use ratatui::backend::CrosstermBackend;
use signal_hook::consts::{SIGHUP, SIGINT, SIGTERM};
use signal_hook::flag;

use crate::commands::check;
use crate::commands::install;
use crate::config::Config;
use crate::error::Error;
use crate::gate::Gate;
use crate::keymap::{Action, Keymap};
use crate::post_install;
use crate::progress;
use crate::report::{Snapshot, attention};
use crate::runner::SystemRunner;
use crate::tui::fetch_session::{FetchSession, StartFailure};
use crate::tui::tree::Tree;

pub fn run(render_once: bool, ascii: bool, motion: bool) -> Result<(), Error> {
    let config = Config::from_env()?;
    // Loaded before any frame, so a broken `tui.conf` fails at once and not
    // silently on the first keypress.
    let keymap = config.keymap()?;
    let color = use_color(ascii, std::env::var_os("NO_COLOR").is_some());

    if render_once {
        // A pipe diagnostic must work without a tty. Fall back to the compact
        // supported size when the terminal cannot report one.
        let (width, height) = terminal::size().unwrap_or((80, 24));
        let snapshot = collect_snapshot(&config, SystemTime::now())?;
        // The keymap reaches the frame here too, so `--render-once` advertises
        // the same keys the interactive tree would dispatch.
        let footer = render::Footer {
            keymap: Some(&keymap),
            ..render::Footer::default()
        };
        print!(
            "{}",
            render::render_frame_status(
                &snapshot,
                footer,
                width,
                height,
                ascii,
                color,
                false,
                false,
                None,
                live::Selection::none(),
            )
        );
        if let Some(error) = snapshot.fatal.clone() {
            return Err(error);
        }
        return attention(snapshot.actionable, "item(s) need attention");
    }

    ensure_interactive(
        io::stdin().is_terminal(),
        stdout().is_terminal(),
        std::env::var("TERM").ok().as_deref(),
    )?;
    run_interactive(&config, &keymap, ascii, color, motion)
}

/// ASCII mode is a no-color mode: the glyph fallback is the signal, and the
/// layout must read the same with or without a palette.
fn use_color(ascii: bool, no_color: bool) -> bool {
    !ascii && !no_color
}

fn ensure_interactive(stdin_tty: bool, stdout_tty: bool, term: Option<&str>) -> Result<(), Error> {
    if !stdin_tty || !stdout_tty {
        return Err(Error::failed(
            "tui needs a terminal; use --render-once in a pipe",
        ));
    }
    if term == Some("dumb") {
        return Err(Error::failed(
            "TERM=dumb has no cursor addressing; use --render-once",
        ));
    }
    Ok(())
}

fn run_interactive(
    config: &Config,
    keymap: &Keymap,
    ascii: bool,
    color: bool,
    motion: bool,
) -> Result<(), Error> {
    guard::install_panic_hook();
    let mut guard = guard::Guard::enter()
        .map_err(|err| Error::failed(format!("cannot enter the terminal: {err}")))?;

    // The sim image is built with `sim-hooks`; a packaged build never enables
    // it. This panics after raw mode and the alternate screen are active, so
    // the pty check proves the panic hook restores the terminal.
    #[cfg(feature = "sim-hooks")]
    if std::env::var_os("AEPM_TUI_TEST_PANIC").is_some() {
        panic!("forced TUI panic for terminal-restore test");
    }

    let mut terminal = Terminal::new(CrosstermBackend::new(io::stdout()))
        .map_err(|err| Error::failed(format!("cannot start the terminal: {err}")))?;
    let mut snapshot = collect_snapshot(config, SystemTime::now())?;
    let mut session: Option<FetchSession> = None;
    let mut notice: Option<Notice> = None;
    let mut help = false;
    let mut ledger = false;
    let mut log_open = false;
    let mut install_gate: Option<InstallGate> = None;
    let mut post_install: Option<post_install::Receipt> = None;
    // The news attestation lasts for this TUI session, not just one opening
    // of the gate, and is never written to disk.
    let mut news_attested = false;
    let mut dirty = true;
    let mut selection = live::Selection::none();

    let interrupted = Arc::new(AtomicBool::new(false));
    for signal in [SIGINT, SIGTERM, SIGHUP] {
        flag::register(signal, Arc::clone(&interrupted))
            .map_err(|err| Error::failed(format!("cannot watch signal {signal}: {err}")))?;
    }

    loop {
        if interrupted.load(Ordering::Relaxed) {
            return Err(Error::Interrupted);
        }
        // The log screen belongs to a session. A flag left behind could never
        // be toggled off, because every key that reads it needs the session.
        assert!(
            session.is_some() || !log_open,
            "the log flag outlived its session"
        );

        if session.as_ref().is_some_and(FetchSession::running) {
            let tick = session
                .as_mut()
                .expect("a running session is present")
                .tick(SystemTime::now(), log_open);
            if tick.changed {
                dirty = true;
            }
        }

        if dirty {
            terminal
                .draw(|frame| {
                    let (footer, gates, body) =
                        frame_parts(session.as_ref(), notice.as_ref(), ledger, keymap);
                    // Enforced again at the consumer: the body that was chosen
                    // is the one whose gate list reaches the renderer.
                    debug_assert!(
                        gates.is_some() != matches!(body, BodyKind::Static),
                        "the drawn body and its gate list must agree"
                    );
                    match body {
                        BodyKind::Live => render::draw_live_status(
                            frame,
                            &snapshot,
                            session
                                .as_ref()
                                .expect("BodyKind::Live is only returned with a session")
                                .live(),
                            footer,
                            ascii,
                            color,
                            help,
                            ledger,
                            gates,
                            selection.clone(),
                        ),
                        BodyKind::Notice | BodyKind::Static => render::draw_status(
                            frame,
                            &snapshot,
                            footer,
                            ascii,
                            color,
                            help,
                            ledger,
                            gates,
                            selection.clone(),
                        ),
                    }
                    if log_open {
                        if let Some(live) = session.as_ref() {
                            render::draw_log(frame, live.lines(), ascii, color);
                        }
                    }
                    if let Some(open) = install_gate.as_ref() {
                        render::draw_install_gate(
                            frame,
                            &open.preflight,
                            news_attested,
                            ascii,
                            color,
                        );
                    }
                    if let Some(receipt) = post_install.as_ref() {
                        render::draw_post_install(frame, receipt, ascii, color);
                    }
                })
                .map_err(|err| Error::failed(format!("cannot draw the terminal: {err}")))?;
            dirty = false;
        }

        let wait = if session.as_ref().is_some_and(FetchSession::running) {
            Duration::from_millis(100)
        } else {
            Duration::from_millis(250)
        };
        if !event::poll(wait)
            .map_err(|err| Error::failed(format!("cannot read the terminal: {err}")))?
        {
            continue;
        }

        match event::read()
            .map_err(|err| Error::failed(format!("cannot read the terminal: {err}")))?
        {
            Event::Key(key) if key.kind == KeyEventKind::Press => {
                // The post-install receipt is read-only and modal.
                if post_install.is_some() {
                    match resolve(Context::Receipt, keymap, &key) {
                        Some(Action::Back | Action::Confirm) => post_install = None,
                        Some(Action::Quit) => break,
                        Some(Action::Interrupt) => return Err(Error::Interrupted),
                        _ => {}
                    }
                    dirty = true;
                    continue;
                }
                // The install gate is modal: only attest, the armed install,
                // cancel and quit are live while it is open.
                if install_gate.is_some() {
                    match resolve(Context::Gate, keymap, &key) {
                        Some(Action::Back) => install_gate = None,
                        Some(Action::Attest) => news_attested = true,
                        Some(Action::Confirm) => {
                            let armed = news_attested
                                && install_gate.as_ref().is_some_and(|open| {
                                    !open.preflight.blocked() && open.preflight.euid.is_some()
                                });
                            if armed {
                                let open = install_gate.take().expect("checked above");
                                let euid = open.preflight.euid.expect("checked above");
                                // The attached command owns the terminal. The
                                // same guard path as Ctrl-Z restores it after.
                                drop(terminal);
                                // Restore the terminal without stopping the
                                // process: yay needs the plain terminal, and a
                                // SIGTSTP would leave the install waiting for
                                // `fg`.
                                guard.restore();
                                let outcome = install::run_with_status(
                                    config,
                                    &SystemRunner,
                                    install::Options {
                                        // The gate never supplies the CLI's
                                        // confirmation: a missing or empty
                                        // trust file blocks above, and a silent
                                        // `--yes` here would answer a question
                                        // the gate had just refused to ask.
                                        yes: false,
                                        force: false,
                                        stdin_is_tty: true,
                                        euid,
                                    },
                                );
                                let receipt = match &outcome {
                                    Ok(code) => post_install::collect(&SystemRunner, *code, ""),
                                    Err(error) => post_install::collect_not_run(
                                        &SystemRunner,
                                        &error.to_string(),
                                    ),
                                };
                                guard = guard::Guard::enter().map_err(|err| {
                                    Error::failed(format!("cannot restore the terminal: {err}"))
                                })?;
                                terminal = Terminal::new(CrosstermBackend::new(io::stdout()))
                                    .map_err(|err| {
                                        Error::failed(format!("cannot restart the terminal: {err}"))
                                    })?;
                                terminal.clear().map_err(|err| {
                                    Error::failed(format!("cannot clear the terminal: {err}"))
                                })?;
                                snapshot = collect_snapshot(config, SystemTime::now())?;
                                post_install = Some(receipt);
                                notice = Some(Notice::install(outcome));
                                news_attested = false;
                            }
                        }
                        Some(Action::Quit) => break,
                        Some(Action::Interrupt) => return Err(Error::Interrupted),
                        _ => {}
                    }
                    dirty = true;
                    continue;
                }
                match resolve(Context::Global, keymap, &key) {
                    Some(Action::Quit) => {
                        // Detach, never kill: the drop below closes our end of the
                        // stream, but the worker keeps the child alive.
                        break;
                    }
                    Some(Action::Interrupt) => {
                        return Err(Error::Interrupted);
                    }
                    Some(Action::Suspend) => {
                        drop(terminal);
                        guard.suspend(&SystemRunner)?;
                        terminal =
                            Terminal::new(CrosstermBackend::new(io::stdout())).map_err(|err| {
                                Error::failed(format!("cannot restart the terminal: {err}"))
                            })?;
                        terminal.clear().map_err(|err| {
                            Error::failed(format!("cannot clear the terminal: {err}"))
                        })?;
                        dirty = true;
                    }
                    Some(Action::Help) => {
                        help = !help;
                        dirty = true;
                    }
                    Some(Action::Back) => {
                        if help {
                            help = false;
                        } else if log_open {
                            log_open = false;
                        } else if session.as_ref().is_some_and(FetchSession::running) {
                            // Detach while the command runs. No result is claimed.
                            break;
                        } else if session.take().is_some() {
                            // Dismissing a session closes its log with it.
                            log_open = false;
                            snapshot = collect_snapshot(config, SystemTime::now())?;
                        } else {
                            notice = None;
                        }
                        dirty = true;
                    }
                    Some(Action::Ledger) => {
                        // A view toggle only; it never touches the fetch or a file.
                        ledger = !ledger;
                        dirty = true;
                    }
                    Some(action @ (Action::Down | Action::Up)) => {
                        // Move the cursor over the rows actually on screen. The
                        // frame is recomputed here because the window depends on
                        // the current snapshot and run, and a cursor must never
                        // point at a row that is not drawn.
                        // The cursor walks the rows that are actually drawn.
                        // During a fetch that is the live window; otherwise it
                        // is the static forest, whose display order the
                        // renderer uses when there is no window.
                        // Ask the renderer to plan the frame it will draw, with
                        // the same footer and the same gates. Anything computed
                        // here independently has been wrong twice.
                        let (width, height) = terminal::size().unwrap_or((80, 24));
                        // Mirror what `draw_with` actually draws: a notice frame
                        // shows `notice.gates` and its status/keys, not an empty
                        // footer. Passing `&[]` here planned 9 rows while the
                        // frame drew 3.
                        let (footer, gates, body) =
                            frame_parts(session.as_ref(), notice.as_ref(), ledger, keymap);
                        // The plan must be built from exactly what the frame
                        // draws: the same body, the same gates.
                        debug_assert!(
                            gates.is_some() != matches!(body, BodyKind::Static),
                            "the planned body and its gate list must agree"
                        );
                        let plan = render::plan_frame(
                            &snapshot,
                            session.as_ref().map(FetchSession::live),
                            footer,
                            width,
                            height,
                            ascii,
                            color,
                            gates,
                        );
                        // The forest the cursor walks is the one the plan
                        // measured. A second build here was the duplicate the
                        // plan exists to remove, and it had no type saying so.
                        if let Some(Ok(tree)) = plan.tree.as_ref() {
                            let delta = if action == Action::Down { 1 } else { -1 };
                            selection = selection.moved(tree, &plan.slots, delta);
                            dirty = true;
                        }
                    }
                    Some(Action::Log) => {
                        // The log exists only after a fetch session starts.
                        if session.is_some() {
                            log_open = !log_open;
                            dirty = true;
                        }
                    }
                    Some(Action::Install) => {
                        if session.as_ref().is_some_and(FetchSession::running) {
                            // One mutation at a time: the fetch owns pacman's lock.
                            session
                                .as_mut()
                                .expect("a running session is present")
                                .refuse("install blocked: the fetch owns pacman's lock");
                            dirty = true;
                        } else {
                            install_gate = Some(InstallGate {
                                preflight: install::preflight(config, &SystemRunner),
                            });
                            dirty = true;
                        }
                    }
                    Some(Action::Refresh) => {
                        if session.as_ref().is_some_and(FetchSession::running) {
                            // The live poll owns the refresh while the fetch runs.
                            session
                                .as_mut()
                                .expect("a running session is present")
                                .refuse("refresh deferred while the fetch runs");
                            dirty = true;
                        } else {
                            session = None;
                            notice = None;
                            log_open = false;
                            snapshot = collect_snapshot(config, SystemTime::now())?;
                            dirty = true;
                        }
                    }
                    Some(Action::Fetch) => {
                        if session.as_ref().is_some_and(FetchSession::running) {
                            // One fetch at a time. No second child.
                            session
                                .as_mut()
                                .expect("a running session is present")
                                .refuse("one fetch at a time; esc detaches");
                            dirty = true;
                        } else {
                            if session.is_some() || notice.is_some() {
                                session = None;
                                // Ending the session closes its log, so a refusal
                                // below cannot leave the flag orphaned.
                                log_open = false;
                                snapshot = collect_snapshot(config, SystemTime::now())?;
                            }
                            match start_fetch(config, &snapshot, SystemTime::now(), motion) {
                                Ok(started) => {
                                    session = Some(started);
                                    notice = None;
                                    log_open = false;
                                }
                                Err(failure) => notice = Some(Notice::from_failure(failure)),
                            }
                            dirty = true;
                        }
                    }
                    _ => {}
                }
            }
            Event::Resize(_, _) => dirty = true,
            Event::Paste(_) => {}
            _ => {}
        }
    }

    let detached = session.as_ref().is_some_and(FetchSession::running);
    drop(terminal);
    drop(guard);
    if detached {
        // The spec allows detaching but forbids claiming its result. The child
        // may still be running; we never killed it.
        eprintln!("aepm: fetch detached; pacman may still be running");
    }
    Ok(())
}

/// Which modal owns the keyboard. A key only means something in a context that
/// accepts its action, so no global binding can fire under a modal.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Context {
    Global,
    Gate,
    Receipt,
}

/// The actions each context accepts. This is the precedence rule — modal over
/// global — in one place, not in the order of a match.
fn accepts(context: Context, action: Action) -> bool {
    match (context, action) {
        (Context::Receipt, Action::Quit | Action::Interrupt | Action::Back | Action::Confirm) => {
            true
        }
        (
            Context::Gate,
            Action::Quit | Action::Interrupt | Action::Back | Action::Confirm | Action::Attest,
        ) => true,
        (Context::Receipt | Context::Gate, _) => false,
        // Enter and space mean nothing over the static tree.
        (Context::Global, Action::Confirm | Action::Attest) => false,
        (Context::Global, _) => true,
    }
}

/// Resolve a press to the action this context accepts. The loop and its tests
/// share this, so a rebound key reaches exactly one arm.
fn resolve(context: Context, keymap: &Keymap, key: &KeyEvent) -> Option<Action> {
    keymap
        .action_for(key)
        .filter(|action| accepts(context, *action))
}

/// The install gate screen. It is read-only and never runs `yay`.
struct InstallGate {
    preflight: install::Preflight,
}

/// A refused action or an observation error shown over the static tree. It has
/// no live frontier because no command started.
struct Notice {
    status: String,
    failure: bool,
    /// The gates that ran before the refusal. Empty when the action failed
    /// before any gate, so the checklist never invents a row.
    gates: Vec<Gate>,
    kind: NoticeKind,
}

/// Which action produced the notice. The footer offers only that action.
#[derive(Clone, Copy, PartialEq, Eq)]
enum NoticeKind {
    Fetch,
    Install,
}

impl Notice {
    fn install(result: Result<i32, Error>) -> Self {
        match result {
            Ok(0) => Self {
                status: "install: yay -Syuu exited 0".to_string(),
                failure: false,
                gates: Vec::new(),
                kind: NoticeKind::Install,
            },
            Ok(code) => Self {
                status: format!("install failed: yay -Syuu exited {code}"),
                failure: true,
                gates: Vec::new(),
                kind: NoticeKind::Install,
            },
            Err(error) => Self {
                status: format!("install failed: {error}"),
                failure: true,
                gates: Vec::new(),
                kind: NoticeKind::Install,
            },
        }
    }

    fn from_failure(failure: StartFailure) -> Self {
        let prefix = match &failure.error {
            Error::Blocked(_) => "fetch blocked",
            Error::Failed(_) => "fetch failed",
            Error::Interrupted => "fetch interrupted",
        };
        Self {
            status: format!("{prefix}: {}", failure.error),
            failure: true,
            gates: failure.gates,
            kind: NoticeKind::Fetch,
        }
    }

    fn keys(&self) -> &'static [(Action, &'static str)] {
        match self.kind {
            NoticeKind::Fetch => fetch_notice_keys(),
            NoticeKind::Install => install_notice_keys(),
        }
    }
}

fn fetch_notice_keys() -> &'static [(Action, &'static str)] {
    &[
        (Action::Fetch, "retry"),
        (Action::Ledger, "ledger"),
        (Action::Refresh, "refresh"),
        (Action::Quit, "quit"),
        (Action::Help, "help"),
    ]
}

fn install_notice_keys() -> &'static [(Action, &'static str)] {
    &[
        (Action::Install, "install gate"),
        (Action::Refresh, "refresh"),
        (Action::Quit, "quit"),
        (Action::Help, "help"),
    ]
}

/// Which body is on screen. [`frame_parts`] returns exactly one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum BodyKind {
    Live,
    Notice,
    Static,
}

/// The one owner of "which body is on screen", and of the footer and gate list
/// that body draws with.
///
/// This decision used to live twice: in the draw closure and again in the
/// `j`/`k` arm, where the event loop re-derived it to plan a cursor move. The
/// second copy had already drifted (it planned a `Footer::default()` and no
/// gates where the draw closure drew real keys and the notice's gate rows), so
/// the planned frame disagreed with the drawn one. One function owns it now;
/// both callers pass the result straight through and cannot disagree again.
///
/// `ledger` is a parameter because the static body builds its key line from
/// [`static_keys`], and the gate list is an `Option` because the static body
/// owns no gates while the live and notice bodies each own their own list.
fn frame_parts<'a>(
    session: Option<&'a FetchSession>,
    notice: Option<&'a Notice>,
    ledger: bool,
    keymap: &'a Keymap,
) -> (render::Footer<'a>, Option<&'a [Gate]>, BodyKind) {
    let (footer, gates, body) = match (session, notice) {
        (Some(live), _) => {
            let mut footer = live.footer();
            footer.keymap = Some(keymap);
            (footer, Some(live.gates()), BodyKind::Live)
        }
        (None, Some(notice)) => (
            render::Footer {
                status: Some(&notice.status),
                keys: Some(notice.keys()),
                keymap: Some(keymap),
                failed: notice.failure,
                repair: None,
            },
            Some(notice.gates.as_slice()),
            BodyKind::Notice,
        ),
        (None, None) => (
            render::Footer {
                status: None,
                keys: Some(static_keys(ledger)),
                keymap: Some(keymap),
                failed: false,
                repair: None,
            },
            None,
            BodyKind::Static,
        ),
    };
    // The positive invariant: a session is the live body, and only a session is.
    debug_assert!(
        session.is_some() == matches!(body, BodyKind::Live),
        "only a session becomes the live body"
    );
    // The negative space: a notice never falls through to the static body.
    debug_assert!(
        !matches!((body, notice.is_some()), (BodyKind::Static, true)),
        "a held notice is never the static body"
    );
    // The static body is the only gateless one; every other body reports gates.
    debug_assert!(
        !matches!(body, BodyKind::Static) || gates.is_none(),
        "the static body owns no gate list"
    );
    debug_assert!(
        matches!(body, BodyKind::Static) || gates.is_some(),
        "a body that owns gates must report them"
    );
    (footer, gates, body)
}

/// The static tree's own key hints. `--render-once` builds the default footer,
/// so its frozen frame is unchanged. The ASCII separator is applied by
/// `footer_lines`, so there is one line here, not one per mode.
fn static_keys(ledger: bool) -> &'static [(Action, &'static str)] {
    const LEDGER: &[(Action, &str)] = &[
        (Action::Quit, "quit"),
        (Action::Ledger, "ledger"),
        (Action::Help, "help"),
        (Action::Refresh, "refresh"),
    ];
    const TREE: &[(Action, &str)] = &[
        (Action::Quit, "quit"),
        (Action::Ledger, "tree"),
        (Action::Help, "help"),
        (Action::Refresh, "refresh"),
    ];
    if ledger { TREE } else { LEDGER }
}

fn start_fetch(
    config: &Config,
    snapshot: &Snapshot,
    now: SystemTime,
    motion: bool,
) -> Result<FetchSession, StartFailure> {
    let failure = |error: Error| StartFailure {
        error,
        gates: Vec::new(),
    };
    let Some(report) = snapshot.prefetch.data() else {
        let message = snapshot
            .prefetch
            .error()
            .unwrap_or("prefetch data is not available");
        return Err(failure(Error::failed(message.to_string())));
    };
    let tree =
        Tree::build(&report.packages).map_err(|error| failure(Error::failed(error.to_string())))?;
    FetchSession::start(config, SystemRunner, tree, now, motion)
}

fn collect_snapshot(config: &Config, now: SystemTime) -> Result<Snapshot, Error> {
    let mut snapshot = check::collect(config, &SystemRunner, now)?;
    snapshot.prefetch = progress::collect(config, &SystemRunner, &snapshot, now);
    Ok(snapshot)
}

#[cfg(test)]
mod tests {
    use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

    use super::{
        BodyKind, Context, Keymap, Notice, ensure_interactive, frame_parts, resolve, static_keys,
        use_color,
    };
    use crate::keymap::Action;

    fn press(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
    }

    #[test]
    fn the_defaults_resolve_the_actions_the_loop_handles() {
        let keymap = Keymap::default();

        assert_eq!(
            resolve(Context::Global, &keymap, &press(KeyCode::Char('q'))),
            Some(Action::Quit)
        );
        assert_eq!(
            resolve(Context::Global, &keymap, &press(KeyCode::Esc)),
            Some(Action::Back)
        );
        assert_eq!(
            resolve(Context::Global, &keymap, &press(KeyCode::Char('F'))),
            Some(Action::Fetch)
        );
        // Enter and space are modal-only; they do nothing over the tree.
        assert_eq!(
            resolve(Context::Global, &keymap, &press(KeyCode::Enter)),
            None
        );
        assert_eq!(
            resolve(Context::Global, &keymap, &press(KeyCode::Char(' '))),
            None
        );
    }

    #[test]
    fn a_custom_binding_dispatches_the_same_action_as_the_default() {
        let keymap = Keymap::parse("[keys]\nquit = x\nledger = L\n").expect("keymap");

        assert_eq!(
            resolve(Context::Global, &keymap, &press(KeyCode::Char('x'))),
            Some(Action::Quit)
        );
        assert_eq!(
            resolve(Context::Global, &keymap, &press(KeyCode::Char('L'))),
            Some(Action::Ledger)
        );
        assert_eq!(
            resolve(Context::Global, &keymap, &press(KeyCode::Char('q'))),
            None
        );
        assert_eq!(
            resolve(Context::Global, &keymap, &press(KeyCode::Char('g'))),
            None
        );
    }

    #[test]
    fn a_modal_rejects_the_global_actions_and_accepts_its_own() {
        let keymap = Keymap::default();

        assert_eq!(
            resolve(Context::Gate, &keymap, &press(KeyCode::Char(' '))),
            Some(Action::Attest)
        );
        assert_eq!(
            resolve(Context::Gate, &keymap, &press(KeyCode::Char('i'))),
            None
        );
        assert_eq!(
            resolve(Context::Gate, &keymap, &press(KeyCode::Char('g'))),
            None
        );
        assert_eq!(
            resolve(Context::Receipt, &keymap, &press(KeyCode::Enter)),
            Some(Action::Confirm)
        );
        assert_eq!(
            resolve(Context::Receipt, &keymap, &press(KeyCode::Char(' '))),
            None
        );
    }

    #[test]
    fn ascii_and_no_color_both_disable_the_palette() {
        assert!(use_color(false, false));
        assert!(!use_color(false, true));
        assert!(!use_color(true, false));
        assert!(!use_color(true, true));
    }

    #[test]
    fn a_pipe_is_not_interactive() {
        assert!(ensure_interactive(false, true, Some("xterm")).is_err());
        assert!(ensure_interactive(true, false, Some("xterm")).is_err());
    }

    #[test]
    fn dumb_terminals_are_rejected() {
        assert!(ensure_interactive(true, true, Some("dumb")).is_err());
        assert!(ensure_interactive(true, true, Some("xterm-256color")).is_ok());
        assert!(ensure_interactive(true, true, None).is_ok());
    }

    // The precedence is the one decision `frame_parts` owns; the live arm needs
    // a real session, so the two arms a test can build are pinned here.
    #[test]
    fn the_static_body_is_gateless_and_a_notice_owns_its_gates() {
        let keymap = Keymap::default();
        let (footer, gates, body) = frame_parts(None, None, true, &keymap);
        assert_eq!(body, BodyKind::Static);
        assert!(gates.is_none(), "the static body owns no gates");
        assert_eq!(footer.keys, Some(static_keys(true)));
        assert!(
            footer.keymap.is_some(),
            "the footer advertises through the resolved keymap"
        );

        let notice = Notice::install(Ok(0));
        let (footer, gates, body) = frame_parts(None, Some(&notice), false, &keymap);
        assert_eq!(body, BodyKind::Notice);
        assert!(gates.is_some(), "a notice reports its own gate list");
        assert_eq!(footer.status, Some(notice.status.as_str()));
    }
}
