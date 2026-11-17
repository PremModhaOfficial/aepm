//! User key overrides for the full-screen tree.
//!
//! [`DEFAULTS`] is the only place a key names an action. `tui.conf`'s `[keys]`
//! section replaces them one line at a time. A missing file means defaults; an
//! unknown action name or an unreadable key is an error at load, never a
//! silent skip.
//!
//! shortcut: the footer text is still static, so a rebound key is not named
//! there; upgrade when the footer is generated from this table.

use std::io;
use std::path::Path;

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

use crate::error::Error;

/// Every action the interactive tree has. `confirm` and `attest` are modal-only,
/// but they are keys like any other, so they live in the same table.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    Quit,
    Interrupt,
    Suspend,
    Help,
    Back,
    Ledger,
    Down,
    Up,
    Log,
    Install,
    Refresh,
    Fetch,
    Confirm,
    Attest,
}

/// One key: a code plus whether Ctrl must be held. Shift is ignored, so `F` and
/// `f` stay distinct without a modifier table.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Key {
    code: KeyCode,
    ctrl: bool,
}

impl Key {
    const fn plain(code: KeyCode) -> Self {
        Self { code, ctrl: false }
    }

    const fn ctrl(code: KeyCode) -> Self {
        Self { code, ctrl: true }
    }
}

/// How the key is written in a config file and in the help overlay.
impl std::fmt::Display for Key {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let code = match self.code {
            KeyCode::Char(' ') => "space".to_string(),
            KeyCode::Char(c) => c.to_string(),
            KeyCode::Esc => "esc".to_string(),
            KeyCode::Enter => "enter".to_string(),
            KeyCode::Tab => "tab".to_string(),
            KeyCode::Up => "up".to_string(),
            KeyCode::Down => "down".to_string(),
            KeyCode::Left => "left".to_string(),
            KeyCode::Right => "right".to_string(),
            other => format!("{other:?}").to_lowercase(),
        };
        if self.ctrl {
            write!(f, "ctrl-{code}")
        } else {
            f.write_str(&code)
        }
    }
}

/// The v1 bindings, in the order the footer has always named them. This is the
/// table the handler and the help overlay both read.
pub const DEFAULTS: &[(&str, Action, Key)] = &[
    ("quit", Action::Quit, Key::plain(KeyCode::Char('q'))),
    (
        "interrupt",
        Action::Interrupt,
        Key::ctrl(KeyCode::Char('c')),
    ),
    ("suspend", Action::Suspend, Key::ctrl(KeyCode::Char('z'))),
    ("help", Action::Help, Key::plain(KeyCode::Char('?'))),
    ("back", Action::Back, Key::plain(KeyCode::Esc)),
    ("ledger", Action::Ledger, Key::plain(KeyCode::Char('g'))),
    ("down", Action::Down, Key::plain(KeyCode::Char('j'))),
    ("up", Action::Up, Key::plain(KeyCode::Char('k'))),
    ("log", Action::Log, Key::plain(KeyCode::Char('l'))),
    ("install", Action::Install, Key::plain(KeyCode::Char('i'))),
    ("refresh", Action::Refresh, Key::plain(KeyCode::Char('r'))),
    ("fetch", Action::Fetch, Key::plain(KeyCode::Char('F'))),
    ("confirm", Action::Confirm, Key::plain(KeyCode::Enter)),
    ("attest", Action::Attest, Key::plain(KeyCode::Char(' '))),
];

/// The action a name refers to. The parser and the error message both read the
/// one table, so an action cannot exist in one and be missing from the other.
fn action_named(name: &str) -> Option<Action> {
    DEFAULTS
        .iter()
        .find(|(default, _, _)| *default == name)
        .map(|(_, action, _)| *action)
}

fn known_actions() -> String {
    DEFAULTS
        .iter()
        .map(|(name, _, _)| *name)
        .collect::<Vec<&str>>()
        .join(", ")
}

/// One bound key per action.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Keymap {
    keys: Vec<(Action, Key)>,
}

impl Default for Keymap {
    fn default() -> Self {
        Self {
            keys: DEFAULTS
                .iter()
                .map(|(_, action, key)| (*action, *key))
                .collect(),
        }
    }
}

impl Keymap {
    /// The user's file, or the defaults when there is no file. Any other read
    /// error and any parse error stops the app.
    pub fn load(path: &Path) -> Result<Self, Error> {
        match std::fs::read_to_string(path) {
            Ok(text) => Self::parse(&text)
                .map_err(|err| Error::failed(format!("{}: {err}", path.display()))),
            Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(Self::default()),
            Err(err) => Err(Error::failed(format!(
                "cannot read {}: {err}",
                path.display()
            ))),
        }
    }

    /// Hand-parsed like the state file: full-line comments, one `[keys]`
    /// section, and one `action = key` per line. Anything else is an error, so
    /// a typo cannot quietly do nothing.
    pub fn parse(text: &str) -> Result<Self, Error> {
        let mut keymap = Self::default();
        let mut in_keys = false;
        for (index, raw) in text.lines().enumerate() {
            let line = raw.trim();
            let at = |message: String| Error::failed(format!("line {}: {message}", index + 1));
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if line.starts_with('[') {
                if line != "[keys]" {
                    return Err(at(format!(
                        "`{line}` is not a section; only [keys] is read"
                    )));
                }
                in_keys = true;
                continue;
            }
            let Some((name, value)) = line.split_once('=') else {
                return Err(at(format!("expected `action = key`, got `{line}`")));
            };
            let (name, value) = (name.trim(), value.trim());
            if !in_keys {
                return Err(at(format!(
                    "`{name}` is not read; only the [keys] section is"
                )));
            }
            let action = action_named(name).ok_or_else(|| {
                at(format!(
                    "unknown action `{name}`; known actions: {}",
                    known_actions()
                ))
            })?;
            let key = parse_key(value).ok_or_else(|| at(format!("`{value}` is not a key")))?;
            keymap.bind(action, key);
        }
        Ok(keymap)
    }

    fn bind(&mut self, action: Action, key: Key) {
        if let Some(slot) = self.keys.iter_mut().find(|(bound, _)| *bound == action) {
            slot.1 = key;
        }
    }

    /// What a press means, or `None` when the key is unbound. A key bound to
    /// plain `c` does not fire on Ctrl-C, and `ctrl-c` does not fire on plain
    /// `c`. Other modifiers are ignored, so `F` arrives with Shift held.
    pub fn action_for(&self, key: &KeyEvent) -> Option<Action> {
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        self.keys
            .iter()
            .find(|(_, bound)| bound.code == key.code && bound.ctrl == ctrl)
            .map(|(action, _)| *action)
    }
}

/// `q`, `F`, `esc`, `enter`, `space`, `tab`, the arrows, and `ctrl-c` / `^c`.
fn parse_key(name: &str) -> Option<Key> {
    let lower = name.to_ascii_lowercase();
    let plain = match lower.as_str() {
        "esc" => KeyCode::Esc,
        "enter" | "return" => KeyCode::Enter,
        "space" => KeyCode::Char(' '),
        "tab" => KeyCode::Tab,
        "up" => KeyCode::Up,
        "down" => KeyCode::Down,
        "left" => KeyCode::Left,
        "right" => KeyCode::Right,
        _ => {
            let rest = lower
                .strip_prefix("ctrl-")
                .or_else(|| lower.strip_prefix("c-"))
                .or_else(|| lower.strip_prefix('^'));
            return match rest {
                Some(rest) => single_char(rest).map(Key::ctrl),
                // The original text, so `F` and `f` stay different bindings.
                None => single_char(name).map(Key::plain),
            };
        }
    };
    Some(Key::plain(plain))
}

fn single_char(text: &str) -> Option<KeyCode> {
    let mut chars = text.chars();
    match (chars.next(), chars.next()) {
        (Some(c), None) => Some(KeyCode::Char(c)),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

    use super::{Action, Keymap};

    fn press(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
    }

    fn ctrl(c: char) -> KeyEvent {
        KeyEvent::new(KeyCode::Char(c), KeyModifiers::CONTROL)
    }

    #[test]
    fn defaults_are_todays_bindings() {
        let keymap = Keymap::default();
        for (key, action) in [
            (press(KeyCode::Char('q')), Action::Quit),
            (ctrl('c'), Action::Interrupt),
            (ctrl('z'), Action::Suspend),
            (press(KeyCode::Char('?')), Action::Help),
            (press(KeyCode::Esc), Action::Back),
            (press(KeyCode::Char('g')), Action::Ledger),
            (press(KeyCode::Char('j')), Action::Down),
            (press(KeyCode::Char('k')), Action::Up),
            (press(KeyCode::Char('l')), Action::Log),
            (press(KeyCode::Char('i')), Action::Install),
            (press(KeyCode::Char('r')), Action::Refresh),
            (press(KeyCode::Char('F')), Action::Fetch),
            (press(KeyCode::Enter), Action::Confirm),
            (press(KeyCode::Char(' ')), Action::Attest),
        ] {
            assert_eq!(keymap.action_for(&key), Some(action), "{key:?}");
        }
    }

    #[test]
    fn a_custom_binding_replaces_the_default() {
        let keymap = Keymap::parse("[keys]\nquit = x\n").expect("keymap");

        assert_eq!(
            keymap.action_for(&press(KeyCode::Char('x'))),
            Some(Action::Quit)
        );
        assert_eq!(keymap.action_for(&press(KeyCode::Char('q'))), None);
    }

    #[test]
    fn an_unknown_action_name_is_an_error() {
        let error = Keymap::parse("[keys]\nquits = x\n").expect_err("unknown action");

        assert!(
            error.to_string().contains("unknown action `quits`"),
            "{error}"
        );
        assert!(error.to_string().contains("line 2"), "{error}");
    }

    #[test]
    fn an_unparsable_key_is_an_error() {
        let error = Keymap::parse("[keys]\nquit = qq\n").expect_err("bad key");

        assert!(error.to_string().contains("`qq` is not a key"), "{error}");
    }

    #[test]
    fn a_setting_outside_the_keys_section_is_an_error() {
        let error = Keymap::parse("theme = ansi\n").expect_err("unknown setting");

        assert!(error.to_string().contains("`theme` is not read"), "{error}");
    }

    #[test]
    fn comments_and_blank_lines_are_skipped_and_ctrl_has_three_spellings() {
        let keymap = Keymap::parse("# my keys\n\n[keys]\nquit = ctrl-x\nhelp = ^h\nback = c-b\n")
            .expect("keymap");

        assert_eq!(keymap.action_for(&ctrl('x')), Some(Action::Quit));
        assert_eq!(keymap.action_for(&ctrl('h')), Some(Action::Help));
        assert_eq!(keymap.action_for(&ctrl('b')), Some(Action::Back));
        assert_eq!(keymap.action_for(&press(KeyCode::Esc)), None);
    }

    #[test]
    fn a_ctrl_key_does_not_fire_on_the_plain_letter() {
        let keymap = Keymap::default();

        assert_eq!(keymap.action_for(&press(KeyCode::Char('c'))), None);
        assert_eq!(keymap.action_for(&ctrl('q')), None);
    }

    #[test]
    fn every_bound_key_displays_the_way_it_is_written() {
        let labels: Vec<String> = super::DEFAULTS
            .iter()
            .map(|(_, _, key)| key.to_string())
            .collect();

        assert_eq!(
            labels,
            vec![
                "q", "ctrl-c", "ctrl-z", "?", "esc", "g", "j", "k", "l", "i", "r", "F", "enter",
                "space",
            ]
        );
    }

    #[test]
    fn a_missing_file_means_defaults() {
        let path = std::env::temp_dir().join("aepm-keymap-that-does-not-exist.conf");

        assert_eq!(Keymap::load(&path).expect("load"), Keymap::default());
    }
}
