use std::fmt::Write as _;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::commands::{fetch, install};
use crate::config::Config;
use crate::error::Error;
use crate::lock;
use crate::report::{
    CacheUsage, Cached, DiskStatus, DiskUsage, Drift, LockState, PartialUpgrade, Policy, Repo,
    Section, Snapshot, StateInfo, TimerState, TrustState, Update, attention,
};
use crate::runner::{CommandOutput, CommandRunner, SystemRunner};
use crate::state::State;
use crate::util::{human_bytes, path_str, resolve_cache_dir};

pub fn run(json: bool) -> Result<(), Error> {
    let config = Config::from_env()?;
    run_with_options(&config, &SystemRunner, json)
}

pub fn run_with(config: &Config, runner: &dyn CommandRunner) -> Result<(), Error> {
    run_with_options(config, runner, false)
}

/// Read-only: this command never writes state or the caches it inspects.
pub fn run_with_options(
    config: &Config,
    runner: &dyn CommandRunner,
    json: bool,
) -> Result<(), Error> {
    let snapshot = collect(config, runner, SystemTime::now())?;
    if json {
        println!("{}", crate::json::check(&snapshot)?);
    } else {
        print!("{}", render_text(&snapshot));
    }
    if let Some(error) = snapshot.fatal.clone() {
        return Err(error);
    }
    attention(snapshot.actionable, "item(s) need attention")
}

macro_rules! collect_or_fatal {
    ($snapshot:ident, $expr:expr) => {
        match $expr {
            Ok(value) => value,
            Err(error) => {
                $snapshot.fatal = Some(error);
                return Ok($snapshot);
            }
        }
    };
}

/// Which sections one collection pass reads.
///
/// `du` over five caches is the slow tier (`TUI.md` T8), so the TUI's 60s wake
/// re-reads [`Tier::Fast`] only. A fast pass carries the previous slow sections
/// forward untouched: their own `at` is what lets the frame show how old they
/// are, instead of presenting a carried reading as fresh.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tier {
    Fast,
    All,
}

/// Collect the check snapshot. This never prints and never writes.
pub fn collect(
    config: &Config,
    runner: &dyn CommandRunner,
    now: SystemTime,
) -> Result<Snapshot, Error> {
    collect_tier(config, runner, now, Tier::All, &Snapshot::default())
}

/// Re-read the fast tier over a previous snapshot.
///
/// The slow sections survive as they were, so an idle minute never pays for a
/// cache scan, and never reads as a fresh one either.
pub fn refresh_fast(
    config: &Config,
    runner: &dyn CommandRunner,
    now: SystemTime,
    previous: &Snapshot,
) -> Result<Snapshot, Error> {
    collect_tier(config, runner, now, Tier::Fast, previous)
}

fn collect_tier(
    config: &Config,
    runner: &dyn CommandRunner,
    now: SystemTime,
    tier: Tier,
    previous: &Snapshot,
) -> Result<Snapshot, Error> {
    let mut snapshot = Snapshot::default();
    let mut actionable = 0u32;

    let pacman = collect_or_fatal!(snapshot, path_str(&config.pacman));
    let official = collect_or_fatal!(snapshot, runner.run(pacman, &["-Qu"]));
    if official.code != 0 && official.code != 1 {
        snapshot.fatal = Some(Error::failed(format!(
            "pacman -Qu exited {}: {}",
            official.code,
            official.stderr.trim()
        )));
        return Ok(snapshot);
    }

    // The pending names `install` compares its refusal against.
    let still_pending = queried_pending(&official);
    let updates = parse_updates(&official.stdout, Repo::Unknown);
    if !updates.is_empty() {
        actionable += 1;
    }
    snapshot.official = Section::ready(updates, now);

    snapshot.aur = match runner.run("yay", &["-Qua"]) {
        Ok(output) if output.code == 0 || output.code == 1 => {
            let updates = parse_updates(&output.stdout, Repo::Aur);
            if !updates.is_empty() {
                actionable += 1;
            }
            Section::ready(updates, now)
        }
        Ok(output) => {
            actionable += 1;
            Section::failed(format!("unavailable (yay exited {})", output.code), now)
        }
        Err(_) => {
            actionable += 1;
            Section::failed("unavailable (yay not found)", now)
        }
    };

    // The same floor `fetch` refuses on, pending download included: a check
    // that reports more free space than the next fetch needs sends the user
    // nowhere.
    let pending_bytes = collect_or_fatal!(
        snapshot,
        fetch::pending_download(pacman, runner, true).map(|(bytes, _)| bytes)
    );
    let need = fetch::space_floor(config, pending_bytes);

    let cache_dir = collect_or_fatal!(snapshot, resolve_cache_dir(config, runner));
    let mut disks = Vec::new();
    if cache_dir.exists() {
        let disk = collect_or_fatal!(snapshot, collect_disk(runner, &cache_dir, need));
        if disk.below_floor {
            actionable += 1;
        }
        disks.push(disk);
    } else {
        // A missing CacheDir is action needed, not an execution error. `df`
        // would exit non-zero and turn this into exit 2.
        disks.push(DiskUsage {
            path: cache_dir.clone(),
            total: 0,
            available: 0,
            inode_total: 0,
            inode_available: 0,
            status: DiskStatus::NotChecked("cache dir is missing".to_string()),
            floor: need,
            below_floor: false,
        });
        actionable += 1;
    }
    if cache_dir != PathBuf::from("/") {
        let disk = collect_or_fatal!(snapshot, collect_disk(runner, Path::new("/"), need));
        if disk.below_floor {
            actionable += 1;
        }
        disks.push(disk);
    }
    snapshot.disk = Section::ready(disks, now);

    let lock = collect_or_fatal!(snapshot, collect_lock(config, runner));
    if !matches!(lock, LockState::None) {
        actionable += 1;
    }
    snapshot.lock = Section::ready(lock, now);

    // The system-owned caches are usually root-only. Reporting them as
    // unreadable is honest, but it is not a problem the invoking user can fix,
    // so only the user-owned caches make `check` action needed.
    //
    // A fast pass does not scan them at all: `du` over five trees is the slow
    // tier (`TUI.md` T8). It carries the last reading, and with it the
    // actionable items already counted against it, so an idle minute does not
    // shrink the header total just because nothing was re-read.
    if tier == Tier::Fast {
        actionable += cache_actionable(previous);
        snapshot.caches = previous.caches.clone();
    } else {
        let mut caches = Vec::new();
        for (label, path, unreadable_is_actionable, policy) in [
            ("downloads", cache_dir.as_path(), true, Policy::KeepOne),
            (
                "yay builds",
                config.yay_cache_dir.as_path(),
                true,
                Policy::OlderThan30DaysInstalledOnly,
            ),
            (
                "aurto repo",
                config.aurto_repo.as_path(),
                false,
                Policy::ReportOnly,
            ),
            (
                "aurbuild chroot",
                config.aurbuild_dir.as_path(),
                false,
                Policy::ReportOnly,
            ),
            (
                "archbuild chroot",
                config.archbuild_dir.as_path(),
                false,
                Policy::ReportOnly,
            ),
        ] {
            // A `du` that cannot even be spawned is the slow lane's own
            // failure, and the flag is what lets a fast pass keep it: that
            // pass never re-reads this section, so clearing the error would
            // leave the carried reading on screen as if it were taken.
            let cache = match collect_cache(runner, label, path, unreadable_is_actionable, policy) {
                Ok(cache) => cache,
                Err(error) => {
                    snapshot.fatal = Some(error);
                    snapshot.slow_fatal = true;
                    return Ok(snapshot);
                }
            };
            if cache.actionable {
                actionable += 1;
            }
            caches.push(cache);
        }
        snapshot.caches = Section::ready(caches, now);
    }

    let timer = collect_or_fatal!(snapshot, collect_timer(runner));
    if timer.actionable {
        actionable += 1;
    }
    snapshot.timer = Section::ready(timer, now);

    let state = collect_or_fatal!(snapshot, State::load(&config.state_file));
    snapshot.drift = collect_drift(
        config,
        &state,
        pending_count(&snapshot),
        still_pending.as_deref(),
    );
    snapshot.state = Section::ready(state_info(config, &state), now);
    let trust = collect_or_fatal!(snapshot, collect_trust(config));
    snapshot.trust = Section::ready(trust, now);
    // A slow-lane failure outlives a fast pass, because the fast pass does not
    // read the section that produced it (issue #135). Dropping it here would
    // clear the error while the carried cache reading stayed on screen.
    if tier == Tier::Fast && previous.slow_fatal {
        assert!(
            previous.fatal.is_some(),
            "a slow fatal names the error that stopped the pass"
        );
        snapshot.fatal = previous.fatal.clone();
        snapshot.slow_fatal = true;
    }
    snapshot.actionable = actionable;
    Ok(snapshot)
}

/// The actionable items a slow-tier reading already accounted for. A fast pass
/// carries them with the reading, so the header total is the same answer a full
/// pass gave and not a smaller one.
fn cache_actionable(previous: &Snapshot) -> u32 {
    previous.caches.data().map_or(0, |caches| {
        caches.iter().filter(|cache| cache.actionable).count() as u32
    })
}

/// Render the same text the CLI printed before the report layer existed.
pub fn render_text(snapshot: &Snapshot) -> String {
    let mut out = String::new();
    render_updates(&mut out, "official", &snapshot.official);
    render_updates(&mut out, "aur", &snapshot.aur);
    render_disk(&mut out, &snapshot.disk);
    render_lock(&mut out, &snapshot.lock);
    render_caches(&mut out, &snapshot.caches);
    render_timer(&mut out, &snapshot.timer);
    render_state(&mut out, &snapshot.state);
    render_drift(&mut out, &snapshot.drift);
    render_trust(&mut out, &snapshot.trust);

    if snapshot.fatal.is_some() {
        return out;
    }
    if snapshot.actionable == 0 {
        out.push_str("check: clean\n");
    } else {
        writeln!(
            out,
            "check: action needed ({} item(s))",
            snapshot.actionable
        )
        .expect("writing to a String cannot fail");
    }
    out
}

fn render_drift(out: &mut String, drift: &Drift) {
    match &drift.partial_upgrade {
        PartialUpgrade::None => {}
        PartialUpgrade::Possible => out.push_str(
            "check: partial upgrade: cannot tell (pacman.log unreadable while updates are pending)\n",
        ),
        PartialUpgrade::Unrecorded => out.push_str(
            "check: partial upgrade: cannot tell (the last fetch recorded no pending set)\n",
        ),
        PartialUpgrade::Detected(detail) => {
            writeln!(out, "check: partial upgrade: {detail}").expect("writing to a String cannot fail");
        }
    }
}

fn render_updates(out: &mut String, label: &str, section: &Section<Vec<Update>>) {
    match section {
        Section::Ready { data, .. } => {
            writeln!(out, "check: {label} updates: {}", data.len())
                .expect("writing to a String cannot fail");
            for update in data {
                writeln!(out, "  {}", update.raw).expect("writing to a String cannot fail");
            }
        }
        Section::Failed { error, .. } => {
            writeln!(out, "check: {label} updates: {error}")
                .expect("writing to a String cannot fail");
        }
        Section::NotCollected => {}
    }
}

fn render_disk(out: &mut String, section: &Section<Vec<DiskUsage>>) {
    match section {
        Section::Ready { data, .. } => {
            for disk in data {
                match &disk.status {
                    DiskStatus::Measured => {
                        writeln!(
                            out,
                            "check: disk {}: {} free of {}, {} inodes free of {}",
                            disk.path.display(),
                            human_bytes(disk.available),
                            human_bytes(disk.total),
                            disk.inode_available,
                            disk.inode_total
                        )
                        .expect("writing to a String cannot fail");
                        if disk.below_floor {
                            writeln!(
                                out,
                                "check: disk {}: below the {} floor",
                                disk.path.display(),
                                human_bytes(disk.floor)
                            )
                            .expect("writing to a String cannot fail");
                        }
                    }
                    DiskStatus::NotChecked(reason) => {
                        writeln!(
                            out,
                            "check: disk {}: not checked ({reason})",
                            disk.path.display()
                        )
                        .expect("writing to a String cannot fail");
                    }
                }
            }
        }
        Section::Failed { error, .. } => {
            writeln!(out, "check: disk: {error}").expect("writing to a String cannot fail");
        }
        Section::NotCollected => {}
    }
}

fn render_lock(out: &mut String, section: &Section<LockState>) {
    match section {
        Section::Ready { data, .. } => match data {
            LockState::None => out.push_str("check: lock: none\n"),
            LockState::HeldBy(name) => {
                let _ = writeln!(out, "check: lock: held by {name}");
            }
            LockState::Stale(path) => {
                writeln!(out, "check: lock: stale {}", path.display())
                    .expect("writing to a String cannot fail");
            }
        },
        Section::Failed { error, .. } => {
            writeln!(out, "check: lock: {error}").expect("writing to a String cannot fail");
        }
        Section::NotCollected => {}
    }
}

fn render_caches(out: &mut String, section: &Section<Vec<CacheUsage>>) {
    match section {
        Section::Ready { data, .. } => {
            for cache in data {
                if let Some(bytes) = cache.bytes {
                    writeln!(out, "check: cache {}: {}", cache.label, human_bytes(bytes))
                        .expect("writing to a String cannot fail");
                } else if let Some(note) = &cache.note {
                    writeln!(out, "check: cache {}: {note}", cache.label)
                        .expect("writing to a String cannot fail");
                } else {
                    writeln!(out, "check: cache {}: unknown", cache.label)
                        .expect("writing to a String cannot fail");
                }
            }
        }
        Section::Failed { error, .. } => {
            writeln!(out, "check: caches: {error}").expect("writing to a String cannot fail");
        }
        Section::NotCollected => {}
    }
}

fn render_timer(out: &mut String, section: &Section<TimerState>) {
    match section {
        Section::Ready { data, .. } => {
            if !data.available {
                out.push_str("check: timer: unavailable\n");
            } else if let Some(next) = &data.next {
                writeln!(out, "check: timer: {next}").expect("writing to a String cannot fail");
            } else {
                out.push_str("check: timer: not scheduled\n");
            }
            if let Some(result) = &data.last_result {
                writeln!(out, "check: timer: last service result: {result}")
                    .expect("writing to a String cannot fail");
            }
        }
        Section::Failed { error, .. } => {
            writeln!(out, "check: timer: {error}").expect("writing to a String cannot fail");
        }
        Section::NotCollected => {}
    }
}

fn render_state(out: &mut String, section: &Section<StateInfo>) {
    match section {
        Section::Ready { data, at } => {
            let now = unix_seconds(*at);
            writeln!(
                out,
                "check: state: last fetch {}, last install {}",
                ago(data.last_fetch_unix, now),
                ago(data.last_install_unix, now)
            )
            .expect("writing to a String cannot fail");
            if let Some(fallback) = &data.fallback {
                writeln!(out, "check: state: {fallback}").expect("writing to a String cannot fail");
            }
        }
        Section::Failed { error, .. } => {
            writeln!(out, "check: state: {error}").expect("writing to a String cannot fail");
        }
        Section::NotCollected => {}
    }
}

fn render_trust(out: &mut String, section: &Section<TrustState>) {
    match section {
        Section::Ready { data, .. } => match data {
            TrustState::Missing => out.push_str("check: trust: missing (aurto trusts everyone)\n"),
            TrustState::Empty => out.push_str("check: trust: empty (trusts no one)\n"),
            TrustState::Allowlist(count) => {
                writeln!(out, "check: trust: {count} maintainer(s)")
                    .expect("writing to a String cannot fail");
            }
        },
        Section::Failed { error, .. } => {
            writeln!(out, "check: trust: {error}").expect("writing to a String cannot fail");
        }
        Section::NotCollected => {}
    }
}

fn unix_seconds(time: SystemTime) -> u64 {
    time.duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs())
        .unwrap_or(0)
}

fn parse_updates(stdout: &str, repo: Repo) -> Vec<Update> {
    stdout
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(|line| {
            let (left, available) = line.split_once(" -> ").unwrap_or((line, ""));
            let (name, installed) = left.split_once(' ').unwrap_or((left, ""));
            Update {
                name: name.to_string(),
                repo: repo.clone(),
                installed: installed.trim().to_string(),
                available: available.trim().to_string(),
                download_bytes: None,
                cached: Cached::Unknown,
                raw: line.to_string(),
            }
        })
        .collect()
}

fn collect_disk(runner: &dyn CommandRunner, path: &Path, floor: u64) -> Result<DiskUsage, Error> {
    let path_text = path_str(path)?;

    let size = runner.run("df", &["-B1", "--output=size,avail", path_text])?;
    let (total, available) = parse_pair(&size.stdout)
        .ok_or_else(|| Error::failed(format!("cannot parse df output for {path_text}")))?;

    let inodes = runner.run("df", &["--output=itotal,iavail", path_text])?;
    let (inode_total, inode_available) = parse_pair(&inodes.stdout)
        .ok_or_else(|| Error::failed(format!("cannot parse df inode output for {path_text}")))?;

    Ok(DiskUsage {
        path: path.to_path_buf(),
        total,
        available,
        inode_total,
        inode_available,
        status: DiskStatus::Measured,
        floor,
        below_floor: available < floor,
    })
}

fn parse_pair(stdout: &str) -> Option<(u64, u64)> {
    let line = stdout.lines().rev().find(|line| !line.trim().is_empty())?;
    let mut parts = line.split_whitespace();
    Some((parts.next()?.parse().ok()?, parts.next()?.parse().ok()?))
}

fn collect_lock(config: &Config, runner: &dyn CommandRunner) -> Result<LockState, Error> {
    if let Some(name) = lock::running(runner)? {
        return Ok(LockState::HeldBy(name));
    }

    if !config.pacman_lock.exists() {
        return Ok(LockState::None);
    }

    Ok(LockState::Stale(config.pacman_lock.clone()))
}

fn collect_cache(
    runner: &dyn CommandRunner,
    label: &str,
    path: &Path,
    unreadable_is_actionable: bool,
    policy: Policy,
) -> Result<CacheUsage, Error> {
    let path_text = path_str(path)?;
    let output = runner.run("du", &["-sb", path_text])?;

    if output.code != 0 {
        if Path::new(path).exists() {
            return Ok(CacheUsage {
                label: label.to_string(),
                path: path.to_path_buf(),
                bytes: None,
                note: Some(format!("unreadable ({})", output.stderr.trim())),
                policy,
                actionable: unreadable_is_actionable,
            });
        }
        return Ok(CacheUsage {
            label: label.to_string(),
            path: path.to_path_buf(),
            bytes: None,
            note: Some("absent".to_string()),
            policy,
            actionable: false,
        });
    }

    match output
        .stdout
        .split_whitespace()
        .next()
        .and_then(|value| value.parse::<u64>().ok())
    {
        Some(bytes) => Ok(CacheUsage {
            label: label.to_string(),
            path: path.to_path_buf(),
            bytes: Some(bytes),
            note: None,
            policy,
            actionable: false,
        }),
        None => Ok(CacheUsage {
            label: label.to_string(),
            path: path.to_path_buf(),
            bytes: None,
            note: Some("unreadable (no size in du output)".to_string()),
            policy,
            actionable: unreadable_is_actionable,
        }),
    }
}

fn collect_timer(runner: &dyn CommandRunner) -> Result<TimerState, Error> {
    let output = runner.run("systemctl", &["--user", "list-timers"])?;
    if output.code != 0 {
        return Ok(TimerState {
            available: false,
            next: None,
            last_result: None,
            actionable: true,
        });
    }

    let next = scheduled_timer(&output.stdout)
        .map(|line| line.split_whitespace().collect::<Vec<_>>().join(" "));

    let result = runner.run(
        "systemctl",
        &["--user", "show", "aepm.service", "--property=Result"],
    )?;
    let value = result.stdout.trim();
    let last_result = if result.code == 0 && !value.is_empty() {
        Some(value.to_string())
    } else {
        None
    };

    Ok(TimerState {
        available: true,
        next,
        last_result,
        actionable: false,
    })
}

/// A loaded timer is not enough: its NEXT column must name a real run.
fn scheduled_timer(stdout: &str) -> Option<&str> {
    stdout
        .lines()
        .find(|line| line.contains("aepm"))
        .filter(|line| !line.trim_start().starts_with("n/a"))
}

fn state_info(config: &Config, state: &State) -> StateInfo {
    let fallback = if state.last_fetch_unix.is_none() && state.last_install_unix.is_none() {
        collect_log_fallback(config)
    } else {
        None
    };

    StateInfo {
        last_fetch_unix: state.last_fetch_unix,
        last_fetch_pending: state.last_fetch_pending,
        last_install_unix: state.last_install_unix,
        fallback,
    }
}

fn collect_log_fallback(config: &Config) -> Option<String> {
    let Ok(log) = fs::read_to_string(&config.pacman_log) else {
        return Some("no pacman.log fallback".to_string());
    };

    let (fetch, install) = log_positions(&log);
    Some(match (fetch, install) {
        (Some(fetch), Some(install)) if fetch > install => {
            "log shows a download after the last install".to_string()
        }
        (Some(_), Some(_)) => "log shows no download after the last install".to_string(),
        (Some(_), None) => "log shows a download and no install".to_string(),
        _ => "log shows no download record".to_string(),
    })
}

/// The last download-only fetch and the last ALPM install or upgrade, by line
/// position. pacman appends, so a later line happened later.
fn log_positions(log: &str) -> (Option<usize>, Option<usize>) {
    let lines: Vec<&str> = log.lines().collect();
    (
        lines.iter().rposition(|line| line.contains("-Syuw")),
        lines.iter().rposition(|line| {
            line.contains("[ALPM] installed") || line.contains("[ALPM] upgraded")
        }),
    )
}

/// How many updates the lists actually reported. A failed or uncollected
/// section proves no pending package, so it contributes nothing.
fn pending_count(snapshot: &Snapshot) -> usize {
    fn len(section: &Section<Vec<Update>>) -> usize {
        match section {
            Section::Ready { data, .. } => data.len(),
            _ => 0,
        }
    }
    len(&snapshot.official) + len(&snapshot.aur)
}

/// The names `pacman -Qu` still reports, or `None` when it could not answer.
///
/// Exit 1 means "nothing pending" only when both streams are silent: pacman
/// exits 1 on an unreadable database too, and reading that as an empty list
/// would clear a partial upgrade (#110).
fn queried_pending(output: &CommandOutput) -> Option<Vec<String>> {
    match output.code {
        0 => Some(install::package_names(&output.stdout)),
        1 if output.stdout.trim().is_empty() && output.stderr.trim().is_empty() => Some(Vec::new()),
        _ => None,
    }
}

/// The drift record, and the one decision behind the partial-upgrade answer.
///
/// `install` refuses on the set the last `fetch` recorded; `check` answered the
/// same question from `pacman.log` alone, so the two could disagree (#118).
/// The state file answers when it recorded an install after that fetch: only it
/// knows which names the fetch planned. `pacman.log` answers only when the state
/// file cannot, because no install since the fetch was recorded and an install
/// this tool did not make is then the only thing that can have moved. The line
/// the renderer prints names the evidence that decided.
///
/// `Possible` is a value, not a silence: unknown is never reported as `none`.
fn collect_drift(
    config: &Config,
    state: &State,
    pending: usize,
    still_pending: Option<&[String]>,
) -> Drift {
    let drift = Drift {
        last_fetch: state.last_fetch_unix,
        last_install: state.last_install_unix,
        partial_upgrade: PartialUpgrade::None,
    };
    if pending == 0 {
        return drift;
    }
    let installed_since_fetch = matches!(
        (state.last_fetch_unix, state.last_install_unix),
        (Some(fetch), Some(install)) if install > fetch
    );
    if installed_since_fetch {
        // The fetch recorded a set and this tool recorded the install that
        // followed it, so the state file is the evidence. Three states, never
        // collapsed: no set says so, an empty set is a clean upgrade, and a
        // recorded set is compared against what is still pending.
        let partial_upgrade = match state.last_fetch_pending_names.as_deref() {
            Some(planned) => match still_pending {
                Some(still) => from_state_file(planned, still),
                None => PartialUpgrade::Possible,
            },
            None => PartialUpgrade::Unrecorded,
        };
        return Drift {
            partial_upgrade,
            ..drift
        };
    }
    match fs::read_to_string(&config.pacman_log) {
        Ok(log) => Drift {
            partial_upgrade: detect_partial_upgrade(&log, pending),
            ..drift
        },
        Err(_) => Drift {
            partial_upgrade: PartialUpgrade::Possible,
            ..drift
        },
    }
}

/// `install`'s own intersection, asked of the pending set `check` already read:
/// the names the fetch planned that a later query still reports.
fn from_state_file(planned: &[String], still_pending: &[String]) -> PartialUpgrade {
    let left = install::partial_upgrade(planned, still_pending);
    if left.is_empty() {
        return PartialUpgrade::None;
    }
    PartialUpgrade::Detected(format!(
        "{} package(s) the last fetch planned are still pending ({}); evidence: the state file",
        left.len(),
        left.join(", ")
    ))
}

/// An install or upgrade after the last download-only fetch, with updates still
/// pending, is the mixed system `spec.md` calls a partial upgrade: the lists
/// are new, some packages moved, the rest did not.
///
/// This is the fallback evidence, used only when the state file recorded no
/// install after the fetch, so the sentence is the one the log has always
/// produced and stays byte-identical: `check`'s output for this evidence path
/// is not the thing #118 changes.
fn detect_partial_upgrade(log: &str, pending: usize) -> PartialUpgrade {
    if pending == 0 {
        return PartialUpgrade::None;
    }
    match log_positions(log) {
        (Some(fetch), Some(install)) if install > fetch => PartialUpgrade::Detected(format!(
            "an upgrade ran after the last fetch and {pending} update(s) are still pending"
        )),
        _ => PartialUpgrade::None,
    }
}

fn collect_trust(config: &Config) -> Result<TrustState, Error> {
    match fs::read_to_string(&config.trusted_users) {
        Ok(text) => {
            let count = text
                .lines()
                .filter(|line| {
                    let line = line.trim();
                    !line.is_empty() && !line.starts_with('#')
                })
                .count();
            if count == 0 {
                Ok(TrustState::Empty)
            } else {
                Ok(TrustState::Allowlist(count))
            }
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(TrustState::Missing),
        Err(err) => Err(Error::failed(format!(
            "cannot read {}: {err}",
            config.trusted_users.display()
        ))),
    }
}

fn ago(timestamp: Option<u64>, now: u64) -> String {
    let Some(timestamp) = timestamp else {
        return "never".to_string();
    };
    let seconds = now.saturating_sub(timestamp);

    if seconds < 3600 {
        format!("{}m ago", seconds / 60)
    } else if seconds < 86_400 {
        format!("{}h ago", seconds / 3600)
    } else {
        format!("{}d ago", seconds / 86_400)
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    use super::{
        collect, collect_cache, collect_drift, detect_partial_upgrade, queried_pending,
        refresh_fast, render_text, run_with, run_with_options, scheduled_timer,
    };
    use crate::commands::fetch;
    use crate::config::Config;
    use crate::error::Error;
    use crate::report::{
        CacheUsage, Cached, DiskStatus, DiskUsage, LockState, PartialUpgrade, Policy, Repo,
        Section, Snapshot, StateInfo, TimerState, TrustState, Update,
    };
    use crate::runner::{CommandOutput, FakeRunner};
    use crate::state::State;

    static COUNTER: AtomicU64 = AtomicU64::new(0);

    fn temp_dir() -> PathBuf {
        let id = COUNTER.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("aepm-check-{}-{id}", std::process::id()));
        fs::create_dir_all(&dir).expect("create temp dir");
        dir
    }

    fn test_config(dir: &Path) -> Config {
        let mut map: HashMap<String, String> = HashMap::new();
        for (key, value) in [
            ("AEPM_STATE", dir.join("state.json")),
            ("AEPM_PACMAN_LOCK", dir.join("db.lck")),
            ("AEPM_PACMAN_LOG", dir.join("pacman.log")),
            ("AEPM_YAY_CACHE_DIR", dir.join("yay")),
            ("AEPM_TRUSTED_USERS", dir.join("trusted-users")),
            ("AEPM_SNAPPER_CONFIG_DIR", dir.join("snapper")),
        ] {
            map.insert(key.to_string(), value.to_string_lossy().into_owned());
        }
        map.insert("AEPM_MIN_FREE_BYTES".to_string(), "1048576".to_string());

        Config::from_lookup(move |name| map.get(name).cloned()).expect("config")
    }

    fn ok(stdout: &str) -> CommandOutput {
        CommandOutput {
            code: 0,
            stdout: stdout.to_string(),
            stderr: String::new(),
        }
    }

    /// `pacman -Qui` output straight from the fixture shape, one pending
    /// package whose download size is known.
    fn qui(pending: u64) -> CommandOutput {
        ok(&format!(
            "Name            : simapp\nDownload Size   : {pending} B\n"
        ))
    }

    /// No pacman, yay, makepkg or aurto is running.
    fn none_running() -> CommandOutput {
        let mut output = ok("");
        output.code = 1;
        output
    }

    /// Queue one response per external call, in the order `run_with` makes them.
    fn queue(
        runner: &FakeRunner,
        dir: &Path,
        official: &str,
        available: u64,
        lock_held: bool,
        pending: u64,
    ) {
        let cache = dir.join("cache");
        fs::create_dir_all(&cache).expect("cache dir");

        runner.push_output(ok(official));
        runner.push_output(ok(""));
        runner.push_output(qui(pending));
        runner.push_output(ok(&format!("{}\n", cache.to_string_lossy())));

        let size = format!("107374182400 {available}\n");
        runner.push_output(ok(&size));
        runner.push_output(ok("6553600 3200000\n"));
        runner.push_output(ok(&size));
        runner.push_output(ok("6553600 3200000\n"));

        if lock_held {
            runner.push_output(ok("4321 pacman\n"));
        } else {
            runner.push_output(none_running());
        }

        for _ in 0..5 {
            runner.push_output(ok("1048576\n"));
        }
        runner.push_output(ok(""));
        runner.push_output(ok(""));
    }

    /// The fast tier's calls, in the order `collect_tier` makes them: no `du`
    /// for any of the five caches.
    fn queue_fast(runner: &FakeRunner, dir: &Path) {
        let cache = dir.join("cache");
        let size = "107374182400 53687091200\n";
        runner.push_output(ok(""));
        runner.push_output(ok(""));
        runner.push_output(qui(0));
        runner.push_output(ok(&format!("{}\n", cache.to_string_lossy())));
        for output in [
            ok(size),
            ok("6553600 3200000\n"),
            ok(size),
            ok("6553600 3200000\n"),
        ] {
            runner.push_output(output);
        }
        runner.push_output(none_running());
        runner.push_output(ok(""));
        runner.push_output(ok(""));
    }

    #[test]
    fn a_clean_system_exits_zero_and_writes_no_state() {
        let dir = temp_dir();
        let config = test_config(&dir);
        let runner = FakeRunner::new();
        queue(&runner, &dir, "", 53_687_091_200, false, 0);

        run_with(&config, &runner).expect("check");

        assert!(!config.state_file.exists(), "check must not write state");

        fs::remove_dir_all(&dir).expect("clean temp dir");
    }

    #[test]
    fn a_pending_update_exits_one() {
        let dir = temp_dir();
        let config = test_config(&dir);
        let runner = FakeRunner::new();
        queue(
            &runner,
            &dir,
            "simapp 1.0.0-1 -> 2.0.0-1\n",
            53_687_091_200,
            false,
            0,
        );

        let result = run_with(&config, &runner);

        assert!(matches!(result, Err(Error::Blocked(_))));
        assert_eq!(result.unwrap_err().exit_code(), 1);

        fs::remove_dir_all(&dir).expect("clean temp dir");
    }

    #[test]
    fn a_held_lock_exits_one_and_is_not_deleted() {
        let dir = temp_dir();
        let config = test_config(&dir);
        fs::write(&config.pacman_lock, "").expect("lock file");
        let runner = FakeRunner::new();
        queue(&runner, &dir, "", 53_687_091_200, true, 0);

        let result = run_with(&config, &runner);

        assert!(matches!(result, Err(Error::Blocked(_))));
        assert!(config.pacman_lock.exists());

        fs::remove_dir_all(&dir).expect("clean temp dir");
    }

    #[test]
    fn low_space_exits_one_even_with_no_updates() {
        let dir = temp_dir();
        let config = test_config(&dir);
        let runner = FakeRunner::new();
        queue(&runner, &dir, "", 1000, false, 0);

        let result = run_with(&config, &runner);

        assert!(matches!(result, Err(Error::Blocked(_))));

        fs::remove_dir_all(&dir).expect("clean temp dir");
    }

    /// #31: check must give the same verdict as fetch, one byte around the
    /// floor, with a pending download so the doubled size term is live.
    #[test]
    fn check_blocks_exactly_where_fetch_blocks() {
        let pending = 104_857_600; // 100 MiB
        let snapshot_floor = 5 * 1024 * 1024 * 1024;

        for delta in [-1i64, 0, 1] {
            let dir = temp_dir();
            let config = test_config(&dir);
            fs::create_dir_all(&config.snapper_config_dir).expect("snapper config dir");
            let floor = snapshot_floor + 2 * pending;
            let available = (floor as i64 + delta) as u64;
            assert_eq!(
                fetch::space_floor(&config, pending),
                floor,
                "delta {delta}: the shared floor"
            );

            // fetch on this machine: the same space, the same pending download.
            let fetch_runner = FakeRunner::new();
            fetch_runner.push_output(none_running());
            fetch_runner.push_output(qui(pending));
            fetch_runner.push_output(ok(&format!("{}\n", dir.join("cache").to_string_lossy())));
            fetch_runner.push_output(ok(&format!("{available}\n")));
            fetch_runner.push_output(ok(&format!("{available}\n")));
            fetch_runner.push_output(ok("0\n"));
            fetch_runner.push_output(ok(""));
            let fetched = fetch::run_with(&config, &fetch_runner);

            let check_runner = FakeRunner::new();
            queue(&check_runner, &dir, "", available, false, pending);
            let checked = run_with(&config, &check_runner);

            assert_eq!(
                checked.is_err(),
                fetched.is_err(),
                "delta {delta}: check and fetch must agree (check {:?}, fetch {:?})",
                checked.as_ref().err().map(ToString::to_string),
                fetched.as_ref().err().map(ToString::to_string)
            );
            assert_eq!(
                fetched.is_err(),
                delta < 0,
                "delta {delta}: fetch's own boundary is the shared floor"
            );

            fs::remove_dir_all(&dir).expect("clean temp dir");
        }
    }

    #[test]
    fn a_pacman_query_failure_exits_two() {
        let dir = temp_dir();
        let config = test_config(&dir);
        let runner = FakeRunner::new();
        let mut failed = ok("");
        failed.code = 2;
        failed.stderr = "database error".to_string();
        runner.push_output(failed);

        let result = run_with(&config, &runner);

        assert!(matches!(result, Err(Error::Failed(_))));
        assert_eq!(result.unwrap_err().exit_code(), 2);

        fs::remove_dir_all(&dir).expect("clean temp dir");
    }

    #[test]
    fn a_missing_cache_dir_is_actionable_not_an_execution_error() {
        let dir = temp_dir();
        let config = test_config(&dir);
        let missing = dir.join("missing-cache");

        let runner = FakeRunner::new();
        runner.push_output(ok(""));
        runner.push_output(ok(""));
        runner.push_output(qui(0));
        runner.push_output(ok(&format!("{}\n", missing.to_string_lossy())));
        runner.push_output(ok("107374182400 53687091200\n"));
        runner.push_output(ok("6553600 3200000\n"));
        runner.push_output(none_running());
        for _ in 0..5 {
            runner.push_output(ok("1048576\n"));
        }
        runner.push_output(ok(""));
        runner.push_output(ok(""));

        let result = run_with(&config, &runner);

        assert!(matches!(result, Err(Error::Blocked(_))));
        assert_eq!(result.unwrap_err().exit_code(), 1);

        // Only the root filesystem is probed; `df` never sees the missing path.
        let df_paths: Vec<String> = runner
            .calls()
            .into_iter()
            .filter(|(program, _)| program == "df")
            .map(|(_, args)| args.last().cloned().unwrap_or_default())
            .collect();
        assert!(!df_paths.is_empty(), "the root disk is still checked");
        assert!(
            df_paths.iter().all(|path| path == "/"),
            "df was called on the missing cache dir: {df_paths:?}"
        );

        fs::remove_dir_all(&dir).expect("clean temp dir");
    }

    #[test]
    fn an_unavailable_aur_check_is_actionable() {
        let dir = temp_dir();
        let config = test_config(&dir);
        let runner = FakeRunner::new();
        let cache = dir.join("cache");
        fs::create_dir_all(&cache).expect("cache dir");

        runner.push_output(ok(""));
        let mut failed = ok("");
        failed.code = 2;
        runner.push_output(failed);
        runner.push_output(qui(0));
        runner.push_output(ok(&format!("{}\n", cache.to_string_lossy())));
        runner.push_output(ok("107374182400 53687091200\n"));
        runner.push_output(ok("6553600 3200000\n"));
        runner.push_output(ok("107374182400 53687091200\n"));
        runner.push_output(ok("6553600 3200000\n"));
        runner.push_output(none_running());
        for _ in 0..5 {
            runner.push_output(ok("1048576\n"));
        }
        runner.push_output(ok(""));
        runner.push_output(ok(""));

        let result = run_with(&config, &runner);

        assert!(matches!(result, Err(Error::Blocked(_))));

        fs::remove_dir_all(&dir).expect("clean temp dir");
    }

    #[test]
    fn an_unreadable_cache_is_actionable() {
        let dir = temp_dir();
        let config = test_config(&dir);
        let cache = dir.join("cache");
        fs::create_dir_all(&cache).expect("cache dir");

        let runner = FakeRunner::new();
        runner.push_output(ok(""));
        runner.push_output(ok(""));
        runner.push_output(qui(0));
        runner.push_output(ok(&format!("{}\n", cache.to_string_lossy())));
        runner.push_output(ok("107374182400 53687091200\n"));
        runner.push_output(ok("6553600 3200000\n"));
        runner.push_output(ok("107374182400 53687091200\n"));
        runner.push_output(ok("6553600 3200000\n"));
        runner.push_output(none_running());

        let mut unreadable = ok("");
        unreadable.code = 1;
        unreadable.stderr = "permission denied".to_string();
        runner.push_output(unreadable);
        for _ in 0..4 {
            let mut absent = ok("");
            absent.code = 1;
            runner.push_output(absent);
        }
        runner.push_output(ok(""));
        runner.push_output(ok(""));

        let result = run_with(&config, &runner);

        assert!(matches!(result, Err(Error::Blocked(_))));

        fs::remove_dir_all(&dir).expect("clean temp dir");
    }

    #[test]
    fn an_unreadable_system_cache_is_informational() {
        let dir = temp_dir();
        let cache = dir.join("system-cache");
        fs::create_dir_all(&cache).expect("cache dir");

        let runner = FakeRunner::new();
        let mut unreadable = ok("");
        unreadable.code = 1;
        unreadable.stderr = "permission denied".to_string();
        runner.push_output(unreadable);

        let usage = collect_cache(
            &runner,
            "aurbuild chroot",
            &cache,
            false,
            Policy::ReportOnly,
        )
        .expect("collect cache");

        assert!(
            !usage.actionable,
            "system-owned caches must not force action"
        );

        fs::remove_dir_all(&dir).expect("clean temp dir");
    }

    #[test]
    fn an_inactive_timer_is_not_scheduled() {
        assert!(scheduled_timer("n/a  n/a  Tue 2026-11-11 00:00:00 UTC  aepm.timer").is_none());
        assert!(scheduled_timer("Tue 2026-11-11 00:00:00 UTC  aepm.timer").is_some());
    }

    fn at() -> SystemTime {
        UNIX_EPOCH + Duration::from_secs(1_760_000_000)
    }

    fn base_snapshot() -> Snapshot {
        Snapshot {
            official: Section::ready(Vec::new(), at()),
            aur: Section::ready(Vec::new(), at()),
            disk: Section::ready(
                vec![DiskUsage {
                    path: PathBuf::from("/var/cache/pacman/pkg"),
                    total: 107_374_182_400,
                    available: 53_687_091_200,
                    inode_total: 6_553_600,
                    inode_available: 3_200_000,
                    status: DiskStatus::Measured,
                    floor: 1_048_576,
                    below_floor: false,
                }],
                at(),
            ),
            lock: Section::ready(LockState::None, at()),
            caches: Section::ready(
                vec![CacheUsage {
                    label: "downloads".to_string(),
                    path: PathBuf::from("/var/cache/pacman/pkg"),
                    bytes: Some(1_048_576),
                    note: None,
                    policy: Policy::KeepOne,
                    actionable: false,
                }],
                at(),
            ),
            timer: Section::ready(
                TimerState {
                    available: true,
                    next: Some("Tue 2026-11-11 00:00:00 UTC aepm.timer".to_string()),
                    last_result: Some("success".to_string()),
                    actionable: false,
                },
                at(),
            ),
            state: Section::ready(
                StateInfo {
                    last_fetch_unix: Some(1_759_999_400),
                    last_fetch_pending: Some(2),
                    last_install_unix: Some(1_759_913_600),
                    fallback: None,
                },
                at(),
            ),
            trust: Section::ready(TrustState::Allowlist(2), at()),
            actionable: 0,
            ..Snapshot::default()
        }
    }

    #[test]
    fn clean_text_is_frozen() {
        assert_eq!(
            render_text(&base_snapshot()),
            "\
check: official updates: 0
check: aur updates: 0
check: disk /var/cache/pacman/pkg: 50.0 GiB free of 100.0 GiB, 3200000 inodes free of 6553600
check: lock: none
check: cache downloads: 1.0 MiB
check: timer: Tue 2026-11-11 00:00:00 UTC aepm.timer
check: timer: last service result: success
check: state: last fetch 10m ago, last install 1d ago
check: trust: 2 maintainer(s)
check: clean
"
        );
    }

    #[test]
    fn pending_text_is_frozen() {
        let mut snapshot = base_snapshot();
        snapshot.official = Section::ready(
            vec![Update {
                name: "bash".to_string(),
                repo: Repo::Unknown,
                installed: "5.2.037-1".to_string(),
                available: "5.2.037-2".to_string(),
                download_bytes: None,
                cached: Cached::Unknown,
                raw: "bash 5.2.037-1 -> 5.2.037-2".to_string(),
            }],
            at(),
        );
        snapshot.actionable = 1;

        assert_eq!(
            render_text(&snapshot),
            "\
check: official updates: 1
  bash 5.2.037-1 -> 5.2.037-2
check: aur updates: 0
check: disk /var/cache/pacman/pkg: 50.0 GiB free of 100.0 GiB, 3200000 inodes free of 6553600
check: lock: none
check: cache downloads: 1.0 MiB
check: timer: Tue 2026-11-11 00:00:00 UTC aepm.timer
check: timer: last service result: success
check: state: last fetch 10m ago, last install 1d ago
check: trust: 2 maintainer(s)
check: action needed (1 item(s))
"
        );
    }

    #[test]
    fn a_fatal_error_keeps_the_lines_collected_before_it() {
        let mut snapshot = base_snapshot();
        snapshot.caches = Section::NotCollected;
        snapshot.timer = Section::NotCollected;
        snapshot.state = Section::NotCollected;
        snapshot.trust = Section::NotCollected;
        snapshot.fatal = Some(Error::failed("du failed"));

        let text = render_text(&snapshot);

        assert!(text.contains("check: official updates: 0"));
        assert!(text.contains("check: lock: none"));
        assert!(!text.contains("not collected"));
        assert!(!text.contains("check: clean"));
    }

    #[test]
    fn json_keeps_the_exit_code_and_prints_no_colour() {
        let dir = temp_dir();
        let config = test_config(&dir);
        let runner = FakeRunner::new();
        queue(
            &runner,
            &dir,
            "simapp 1.0.0-1 -> 2.0.0-1\n",
            53_687_091_200,
            false,
            0,
        );

        let result = run_with_options(&config, &runner, true);

        assert!(matches!(result, Err(Error::Blocked(_))));
        assert_eq!(result.unwrap_err().exit_code(), 1);
        assert!(!config.state_file.exists(), "check must not write state");

        fs::remove_dir_all(&dir).expect("clean temp dir");
    }

    #[test]
    fn a_partial_upgrade_is_an_install_after_the_last_fetch_with_updates_pending() {
        let window = "\
[2026-11-14T10:00:00+0000] [PACMAN] Running 'pacman -Syuw --noconfirm'
[2026-11-14T10:05:00+0000] [ALPM] upgraded bigpkg (1.0.0-1 -> 2.0.0-1)
";
        assert_eq!(
            detect_partial_upgrade(window, 1),
            PartialUpgrade::Detected(
                "an upgrade ran after the last fetch and 1 update(s) are still pending".to_string()
            )
        );
        assert_eq!(
            detect_partial_upgrade(window, 0),
            PartialUpgrade::None,
            "nothing pending means the upgrade finished"
        );

        let fetched_last = "\
[2026-11-14T10:00:00+0000] [ALPM] upgraded old (1.0-1 -> 2.0-1)
[2026-11-14T11:00:00+0000] [PACMAN] Running 'pacman -Syuw --noconfirm'
";
        assert_eq!(
            detect_partial_upgrade(fetched_last, 3),
            PartialUpgrade::None,
            "a fetch after the last install is the window open, not mixed"
        );

        let no_fetch = "[2026-11-14T10:05:00+0000] [ALPM] installed thing (1.0-1)\n";
        assert_eq!(
            detect_partial_upgrade(no_fetch, 3),
            PartialUpgrade::None,
            "without a recorded fetch there is no window to have crossed"
        );
    }

    #[test]
    fn an_unreadable_log_is_a_possible_drift_not_a_none() {
        let dir = temp_dir();
        let config = test_config(&dir);
        // No install after the fetch was recorded, so the state file cannot
        // answer and the log is the evidence: absent, which is unknown.
        let state = State {
            last_fetch_unix: Some(1_760_000_000),
            last_fetch_pending: Some(2),
            last_fetch_pending_names: Some(vec!["glibc".to_string(), "firefox".to_string()]),
            last_install_unix: None,
        };

        let drift = collect_drift(&config, &state, 2, Some(&[]));

        assert_eq!(drift.last_fetch, Some(1_760_000_000));
        assert_eq!(drift.partial_upgrade, PartialUpgrade::Possible);
        assert!(
            render_text(&Snapshot {
                drift,
                ..base_snapshot()
            })
            .contains("check: partial upgrade: cannot tell"),
            "an unknown answer is printed, never reported as none"
        );

        fs::remove_dir_all(&dir).expect("clean temp dir");
    }

    /// #110's trap: `pacman -Qu` exits 1 both for "nothing pending" and for a
    /// database it could not read, and the second is not an empty list.
    #[test]
    fn only_a_silent_exit_one_means_nothing_is_pending() {
        let pending = ok("simapp 1.0.0-1 -> 2.0.0-1\n");
        assert_eq!(queried_pending(&pending), Some(vec!["simapp".to_string()]));

        let mut silent = ok("");
        silent.code = 1;
        assert_eq!(queried_pending(&silent), Some(Vec::new()));

        let mut unreadable = ok("");
        unreadable.code = 1;
        unreadable.stderr = "error: could not open file /var/lib/pacman/db.lck".to_string();
        assert_eq!(
            queried_pending(&unreadable),
            None,
            "an unreadable database is not \"nothing pending\""
        );
    }

    /// The state file records the fetch's planned set and this tool's own
    /// install, while `pacman.log` mentions only the fetch, so the log would
    /// call the system clean. The state file decides: a name the fetch planned
    /// is still pending. `check` names that evidence and writes neither file.
    #[test]
    fn the_state_file_wins_when_the_log_would_call_it_clean() {
        let dir = temp_dir();
        let config = test_config(&dir);
        let recorded = concat!(
            "{\"last_fetch_unix\":1000,\"last_fetch_pending\":2,",
            "\"last_fetch_pending_names\":[\"simapp\",\"bigpkg\"],",
            "\"last_install_unix\":2000}\n"
        );
        fs::write(&config.state_file, recorded).expect("state file");
        let log = "\
[2026-11-14T10:00:00+0000] [PACMAN] Running 'pacman -Syuw --noconfirm'
";
        fs::write(&config.pacman_log, log).expect("pacman log");

        let exiting = FakeRunner::new();
        queue(
            &exiting,
            &dir,
            "simapp 1.0.0-1 -> 2.0.0-1\n",
            53_687_091_200,
            false,
            0,
        );
        let result = run_with(&config, &exiting);

        let runner = FakeRunner::new();
        queue(
            &runner,
            &dir,
            "simapp 1.0.0-1 -> 2.0.0-1\n",
            53_687_091_200,
            false,
            0,
        );
        let snapshot = collect(&config, &runner, SystemTime::now()).expect("collect");
        let text = render_text(&snapshot);

        assert!(
            matches!(
                &snapshot.drift.partial_upgrade,
                PartialUpgrade::Detected(detail) if detail.contains("evidence: the state file")
            ),
            "the state file's evidence is named: {:?}",
            snapshot.drift.partial_upgrade
        );
        assert!(
            text.contains("simapp"),
            "the packages the fetch planned and did not move are named: {text}"
        );
        assert!(
            !text.contains("check: clean"),
            "it must not claim clean: {text}"
        );
        assert_eq!(snapshot.actionable, 1);
        assert_eq!(
            result.as_ref().err().map(Error::exit_code),
            Some(1),
            "a partial upgrade is action needed"
        );
        assert_eq!(
            fs::read_to_string(&config.state_file).expect("state file"),
            recorded,
            "check wrote the state file"
        );
        assert_eq!(
            fs::read_to_string(&config.pacman_log).expect("pacman log"),
            log,
            "check wrote pacman.log"
        );

        fs::remove_dir_all(&dir).expect("clean temp dir");
    }

    /// A recorded-but-empty set is an answer, not a silence: the fetch planned
    /// nothing, so an install after it cannot have left part of that set
    /// behind. The log here would report an upgrade after a fetch, and it must
    /// not override the state file.
    #[test]
    fn a_recorded_empty_set_is_clean_even_when_the_log_would_disagree() {
        let dir = temp_dir();
        let config = test_config(&dir);
        fs::write(
            &config.state_file,
            concat!(
                "{\"last_fetch_unix\":1000,\"last_fetch_pending\":0,",
                "\"last_fetch_pending_names\":[],\"last_install_unix\":2000}\n"
            ),
        )
        .expect("state file");
        fs::write(
            &config.pacman_log,
            "\
[2026-11-14T10:00:00+0000] [PACMAN] Running 'pacman -Syuw --noconfirm'
[2026-11-14T10:05:00+0000] [ALPM] upgraded simapp (1.0.0-1 -> 2.0.0-1)
",
        )
        .expect("pacman log");
        let state = State {
            last_fetch_unix: Some(1_000),
            last_fetch_pending: Some(0),
            last_fetch_pending_names: Some(Vec::new()),
            last_install_unix: Some(2_000),
        };

        let drift = collect_drift(&config, &state, 1, Some(&["simapp".to_string()]));

        assert_eq!(drift.partial_upgrade, PartialUpgrade::None);
        assert!(
            !render_text(&Snapshot {
                drift,
                ..base_snapshot()
            })
            .contains("partial upgrade"),
            "an empty recorded set is clean"
        );

        fs::remove_dir_all(&dir).expect("clean temp dir");
    }

    /// An install after the fetch is recorded, but the fetch recorded no set
    /// (an older state file). There is nothing to compare, so `check` says it
    /// cannot tell instead of reading the log or claiming clean.
    #[test]
    fn an_unrecorded_set_says_so_instead_of_reading_the_log() {
        let dir = temp_dir();
        let config = test_config(&dir);
        fs::write(
            &config.pacman_log,
            "\
[2026-11-14T10:00:00+0000] [PACMAN] Running 'pacman -Syuw --noconfirm'
[2026-11-14T10:05:00+0000] [ALPM] upgraded simapp (1.0.0-1 -> 2.0.0-1)
",
        )
        .expect("pacman log");
        let state = State {
            last_fetch_unix: Some(1_000),
            last_fetch_pending: Some(1),
            last_fetch_pending_names: None,
            last_install_unix: Some(2_000),
        };

        let drift = collect_drift(&config, &state, 1, Some(&["simapp".to_string()]));

        assert_eq!(drift.partial_upgrade, PartialUpgrade::Unrecorded);
        let text = render_text(&Snapshot {
            drift,
            ..base_snapshot()
        });
        assert!(
            text.contains("cannot tell (the last fetch recorded no pending set)"),
            "the unrecorded set is named: {text}"
        );
        assert!(
            !text.contains("an upgrade ran after the last fetch"),
            "the log did not decide: {text}"
        );

        fs::remove_dir_all(&dir).expect("clean temp dir");
    }

    /// The state file records no install since the fetch, so the only thing
    /// that can have moved is an install this tool did not make. That is the
    /// one thing `pacman.log` is kept for, and its sentence is unchanged by
    /// #118: only the new state-file path names itself.
    #[test]
    fn the_log_answers_only_when_no_install_since_the_fetch_was_recorded() {
        let dir = temp_dir();
        let config = test_config(&dir);
        fs::write(
            &config.pacman_log,
            "\
[2026-11-14T10:00:00+0000] [PACMAN] Running 'pacman -Syuw --noconfirm'
[2026-11-14T10:05:00+0000] [ALPM] upgraded bigpkg (1.0.0-1 -> 2.0.0-1)
",
        )
        .expect("pacman log");
        let state = State {
            last_fetch_unix: Some(1_760_000_000),
            last_fetch_pending: Some(2),
            last_fetch_pending_names: Some(vec!["simapp".to_string(), "bigpkg".to_string()]),
            last_install_unix: None,
        };

        let drift = collect_drift(&config, &state, 1, Some(&["simapp".to_string()]));

        assert_eq!(
            drift.partial_upgrade,
            PartialUpgrade::Detected(
                "an upgrade ran after the last fetch and 1 update(s) are still pending".to_string()
            ),
            "the log's sentence is the one it has always printed"
        );
        assert_eq!(drift.last_fetch, Some(1_760_000_000));

        fs::remove_dir_all(&dir).expect("clean temp dir");
    }

    /// Nothing is pending, so both evidence paths answer "no partial upgrade".
    /// The text is the frozen clean report, so no new evidence line can appear
    /// in this case and break existing output silently.
    #[test]
    fn check_output_is_unchanged_when_the_evidence_agrees() {
        let dir = temp_dir();
        let config = test_config(&dir);
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock")
            .as_secs();
        fs::write(
            &config.state_file,
            format!(
                "{{\"last_fetch_unix\":{},\"last_fetch_pending\":1,\
                 \"last_fetch_pending_names\":[\"simapp\"],\"last_install_unix\":{}}}\n",
                now - 600,
                now - 86_400
            ),
        )
        .expect("state file");
        let runner = FakeRunner::new();
        queue(&runner, &dir, "", 53_687_091_200, false, 0);

        let snapshot = collect(&config, &runner, SystemTime::now()).expect("collect");
        let cache = dir.join("cache");
        let sizes = "50.0 GiB free of 100.0 GiB, 3200000 inodes free of 6553600\n";
        let expected = format!(
            "\
check: official updates: 0
check: aur updates: 0
check: disk {}: {sizes}check: disk /: {sizes}check: lock: none
check: cache downloads: 1.0 MiB
check: cache yay builds: 1.0 MiB
check: cache aurto repo: 1.0 MiB
check: cache aurbuild chroot: 1.0 MiB
check: cache archbuild chroot: 1.0 MiB
check: timer: not scheduled
check: state: last fetch 10m ago, last install 1d ago
check: trust: missing (aurto trusts everyone)
check: clean
",
            cache.display()
        );

        assert_eq!(snapshot.actionable, 0);
        assert_eq!(render_text(&snapshot), expected);

        fs::remove_dir_all(&dir).expect("clean temp dir");
    }

    #[test]
    fn json_keeps_the_execution_error() {
        let dir = temp_dir();
        let config = test_config(&dir);
        let runner = FakeRunner::new();
        let mut failed = ok("");
        failed.code = 2;
        failed.stderr = "database error".to_string();
        runner.push_output(failed);

        let result = run_with_options(&config, &runner, true);

        assert!(matches!(result, Err(Error::Failed(_))));
        assert_eq!(result.unwrap_err().exit_code(), 2);

        fs::remove_dir_all(&dir).expect("clean temp dir");
    }

    /// A fast pass re-reads the fast tier and carries the slow one. The clock
    /// is a parameter, so this asserts stamps and never wall time.
    #[test]
    fn a_fast_pass_carries_the_slow_tier_with_its_age() {
        let dir = temp_dir();
        let config = test_config(&dir);
        let runner = FakeRunner::new();
        let start = UNIX_EPOCH + Duration::from_secs(1_000_000);
        let later = start + Duration::from_secs(61);
        queue(&runner, &dir, "", 53_687_091_200, false, 0);

        let mut first = collect(&config, &runner, start).expect("full pass");
        // One unreadable user cache is an actionable item the fast pass cannot
        // recount, because it does not read it.
        if let Section::Ready { data, .. } = &mut first.caches {
            data[0].actionable = true;
        }
        first.actionable = 1;

        // The fast tier's calls, in the order `collect_tier` makes them: no
        // `du` for any of the five caches.
        queue_fast(&runner, &dir);
        let seen = runner.calls().len();

        let second = refresh_fast(&config, &runner, later, &first).expect("fast pass");

        assert_eq!(second.caches, first.caches, "the slow tier is carried");
        assert_eq!(
            second.caches.at(),
            Some(start),
            "the carried reading keeps the age it was taken at"
        );
        assert_eq!(second.official.at(), Some(later), "the fast tier is fresh");
        assert_eq!(
            second.actionable, 1,
            "the carried cache item stays counted in the header total"
        );
        let programs: Vec<String> = runner.calls()[seen..]
            .iter()
            .map(|(program, _)| program.clone())
            .collect();
        assert!(
            !programs.iter().any(|program| program == "du"),
            "a fast pass must not scan the caches: {programs:?}"
        );

        fs::remove_dir_all(&dir).expect("clean temp dir");
    }

    /// A snapshot a full pass collected, then stopped by a failure. `slow_lane`
    /// says which lane owns it: only a full pass reads the cache scan.
    fn snapshot_stopped_by(slow_lane: bool) -> (PathBuf, Config, FakeRunner, Snapshot) {
        let dir = temp_dir();
        let config = test_config(&dir);
        let runner = FakeRunner::new();
        queue(&runner, &dir, "", 53_687_091_200, false, 0);
        let start = UNIX_EPOCH + Duration::from_secs(1_000_000);
        let mut snapshot = collect(&config, &runner, start).expect("full pass");
        snapshot.fatal = Some(Error::failed("du could not be spawned"));
        snapshot.slow_fatal = slow_lane;
        (dir, config, runner, snapshot)
    }

    /// Issue #135: a fatal the slow lane recorded is not cleared by a pass that
    /// never re-reads the slow lane.
    #[test]
    fn a_fast_pass_keeps_a_slow_lane_fatal() {
        let (dir, config, runner, stopped) = snapshot_stopped_by(true);
        queue_fast(&runner, &dir);

        let later = UNIX_EPOCH + Duration::from_secs(1_000_061);
        let next = refresh_fast(&config, &runner, later, &stopped).expect("fast pass");

        assert_eq!(
            next.fatal, stopped.fatal,
            "the error the slow lane recorded stands"
        );
        assert!(
            next.slow_fatal,
            "the next pass carries it too, instead of presenting the carried \
             cache reading as one nobody had to read"
        );

        fs::remove_dir_all(&dir).expect("clean temp dir");
    }

    /// The carry is not a latch: a failure the fast pass did re-read is cleared
    /// by the pass that re-read it.
    #[test]
    fn a_fast_pass_clears_a_fatal_it_re_read() {
        let (dir, config, runner, mut stopped) = snapshot_stopped_by(false);
        stopped.fatal = Some(Error::failed("pacman -Qu exited 2: database error"));
        queue_fast(&runner, &dir);

        let later = UNIX_EPOCH + Duration::from_secs(1_000_061);
        let next = refresh_fast(&config, &runner, later, &stopped).expect("fast pass");

        assert!(
            next.fatal.is_none(),
            "the section that failed was re-read clean: {:?}",
            next.fatal
        );
        assert!(!next.slow_fatal, "there is no slow-lane error to carry");

        fs::remove_dir_all(&dir).expect("clean temp dir");
    }
}
