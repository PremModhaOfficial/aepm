use std::process::Command;

fn binary() -> Command {
    Command::new(env!("CARGO_BIN_EXE_aepm"))
}

#[test]
fn help_lists_every_subcommand() {
    let output = binary().arg("--help").output().expect("run --help");

    assert!(output.status.success());
    let text = String::from_utf8_lossy(&output.stdout);
    for name in [
        "init", "check", "fetch", "install", "clean", "doctor", "tui",
    ] {
        assert!(text.contains(name), "help is missing {name}");
    }
}

#[test]
fn tui_help_lists_the_safe_flags() {
    let output = binary()
        .args(["tui", "--help"])
        .output()
        .expect("run tui --help");

    assert!(output.status.success());
    let text = String::from_utf8_lossy(&output.stdout);
    assert!(text.contains("--render-once"));
    assert!(text.contains("--ascii"));
    assert!(text.contains("--no-motion"));
}

#[test]
fn init_dry_run_says_aurto_is_not_run() {
    // `init` writes the sudoers rule and the user units. aurto's repo and its
    // `Include` line are `aurto init`'s, so the glossary must not claim them.
    let output = binary().arg("init").output().expect("run init");

    assert!(output.status.success(), "init dry run failed");
    let text = String::from_utf8_lossy(&output.stdout);
    assert!(
        text.contains("aurto is not run by this tool"),
        "init must say aurto is not run by this tool:\n{text}"
    );
}

#[test]
fn check_and_doctor_offer_json() {
    for command in ["check", "doctor"] {
        let output = binary()
            .args([command, "--help"])
            .output()
            .expect("run --help");
        assert!(output.status.success(), "{command} --help failed");
        let text = String::from_utf8_lossy(&output.stdout);
        assert!(text.contains("--json"), "{command} help is missing --json");
    }
}
