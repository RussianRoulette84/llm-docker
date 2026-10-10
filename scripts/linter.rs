#!/usr/bin/env rust-script
//! Rust linter for llm-docker projects — fmt + clippy + check + tests + audit.
//!
//! Enabled by `INSTALL_RUST=true` in `src/llm-docker.conf`, which installs the
//! rustup toolchain plus `rust-script` (what makes this file directly
//! executable). Std-only, no crate dependencies.
//!
//! Usage:
//!   ./scripts/linter.rs [PATH] [--fix] [--no-test] [--no-audit] [--no-color]
//!
//! PATH defaults to the current directory; the crate root is found by walking
//! up to the nearest Cargo.toml. Exit code is the number of failed steps.
//!
//! Without rust-script installed it still runs the long way:
//!   rustc -O -o /tmp/linter scripts/linter.rs && /tmp/linter

use std::env;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const PURPLE: &str = "\x1b[1;35m";
const GREEN: &str = "\x1b[1;32m";
const RED: &str = "\x1b[1;31m";
const YELLOW: &str = "\x1b[1;33m";
const DIM: &str = "\x1b[2m";
const RESET: &str = "\x1b[0m";

struct Opts {
    root: PathBuf,
    fix: bool,
    test: bool,
    audit: bool,
    color: bool,
}

struct Step {
    name: &'static str,
    argv: Vec<String>,
    /// Missing binary is a skip, not a failure (cargo-audit, cargo-nextest).
    optional: bool,
}

fn main() {
    let opts = match parse_args() {
        Ok(o) => o,
        Err(msg) => {
            eprintln!("{}", msg);
            std::process::exit(2);
        }
    };

    let p = Paint::new(opts.color);
    let width = term_width();

    p.box_top(width, "RUST LINTER");
    p.box_line(width, &format!("crate root: {}", opts.root.display()));
    p.box_line(
        width,
        &format!("mode: {}", if opts.fix { "fix" } else { "check" }),
    );
    p.box_bottom(width);

    let steps = build_steps(&opts);
    let mut failed: Vec<&str> = Vec::new();

    for step in &steps {
        p.step_start(step.name);
        match run(&step.argv, &opts.root, opts.color) {
            RunResult::Missing => {
                if step.optional {
                    p.step_end(step.name, Status::Skipped, "not installed");
                } else {
                    p.step_end(step.name, Status::Failed, "command not found");
                    failed.push(step.name);
                }
            }
            RunResult::Ok => p.step_end(step.name, Status::Passed, ""),
            RunResult::Failed(code, output) => {
                p.step_end(step.name, Status::Failed, &format!("exit {}", code));
                p.detail(&output);
                failed.push(step.name);
            }
        }
    }

    p.gap();
    if failed.is_empty() {
        p.box_top(width, "ALL CLEAN");
        p.box_line(width, &format!("{} step(s) passed", steps.len()));
        p.box_bottom(width);
    } else {
        p.box_top(width, "FAILED");
        for name in &failed {
            p.box_line(width, name);
        }
        p.box_bottom(width);
    }
    std::process::exit(failed.len() as i32);
}

fn parse_args() -> Result<Opts, String> {
    let mut start = env::current_dir().map_err(|e| e.to_string())?;
    let (mut fix, mut test, mut audit) = (false, true, true);
    let mut color = env::var_os("NO_COLOR").is_none();

    for arg in env::args().skip(1) {
        match arg.as_str() {
            "--fix" => fix = true,
            "--no-test" => test = false,
            "--no-audit" => audit = false,
            "--no-color" => color = false,
            "-h" | "--help" => {
                println!(
                    "usage: linter.rs [PATH] [--fix] [--no-test] [--no-audit] [--no-color]"
                );
                std::process::exit(0);
            }
            other if other.starts_with('-') => {
                return Err(format!("unknown flag: {}", other));
            }
            path => start = PathBuf::from(path),
        }
    }

    let root = find_crate_root(&start)
        .ok_or_else(|| format!("no Cargo.toml at or above {}", start.display()))?;
    Ok(Opts {
        root,
        fix,
        test,
        audit,
        color,
    })
}

/// Walk up from `start` to the nearest directory holding a Cargo.toml.
fn find_crate_root(start: &Path) -> Option<PathBuf> {
    let mut dir = start.canonicalize().ok()?;
    loop {
        if dir.join("Cargo.toml").is_file() {
            return Some(dir);
        }
        if !dir.pop() {
            return None;
        }
    }
}

fn argv(parts: &[&str]) -> Vec<String> {
    parts.iter().map(|s| s.to_string()).collect()
}

fn build_steps(o: &Opts) -> Vec<Step> {
    let mut steps = Vec::new();

    steps.push(if o.fix {
        Step {
            name: "rustfmt",
            argv: argv(&["cargo", "fmt", "--all"]),
            optional: false,
        }
    } else {
        Step {
            name: "rustfmt",
            argv: argv(&["cargo", "fmt", "--all", "--check"]),
            optional: false,
        }
    });

    steps.push(Step {
        name: "check",
        argv: argv(&["cargo", "check", "--all-targets", "--all-features"]),
        optional: false,
    });

    steps.push(if o.fix {
        Step {
            name: "clippy",
            argv: argv(&[
                "cargo",
                "clippy",
                "--fix",
                "--allow-dirty",
                "--allow-staged",
                "--all-targets",
                "--all-features",
            ]),
            optional: false,
        }
    } else {
        Step {
            name: "clippy",
            argv: argv(&[
                "cargo",
                "clippy",
                "--all-targets",
                "--all-features",
                "--",
                "-D",
                "warnings",
            ]),
            optional: false,
        }
    });

    if o.test {
        // nextest is the faster runner installed by the RUST devpack group;
        // plain `cargo test` covers the case where it is missing.
        let has_nextest = which("cargo-nextest");
        steps.push(Step {
            name: "tests",
            argv: if has_nextest {
                // --no-tests=pass: a crate with no test targets is not a
                // lint failure; nextest's default is to exit non-zero there.
                argv(&["cargo", "nextest", "run", "--all-features", "--no-tests=pass"])
            } else {
                argv(&["cargo", "test", "--all-features"])
            },
            optional: false,
        });
    }

    if o.audit {
        steps.push(Step {
            name: "audit",
            argv: argv(&["cargo", "audit"]),
            optional: true,
        });
    }

    steps
}

fn which(bin: &str) -> bool {
    env::var_os("PATH")
        .map(|paths| env::split_paths(&paths).any(|d| d.join(bin).is_file()))
        .unwrap_or(false)
}

enum RunResult {
    Ok,
    Failed(i32, String),
    Missing,
}

fn run(args: &[String], cwd: &Path, color: bool) -> RunResult {
    // Cargo subcommands are separate `cargo-<sub>` binaries on PATH. Probe
    // first so a missing optional tool reads as "skipped" rather than as a
    // cargo error. fmt/clippy count as built-in: they come with the toolchain
    // INSTALL_RUST provisions, so their absence IS a failure worth reporting.
    const BUILTIN: [&str; 6] = ["check", "test", "build", "run", "fmt", "clippy"];
    if args[0] == "cargo" && args.len() > 1 {
        let sub = args[1].as_str();
        if !BUILTIN.contains(&sub) && !which(&format!("cargo-{}", sub)) {
            return RunResult::Missing;
        }
    }

    // Cargo's own colors are re-printed inside our tree, so they have to follow
    // the same on/off decision — otherwise a NO_COLOR run still leaks escapes.
    let out = Command::new(&args[0])
        .args(&args[1..])
        .current_dir(cwd)
        .env("CARGO_TERM_COLOR", if color { "always" } else { "never" })
        .stdin(Stdio::null())
        .output();

    match out {
        Err(_) => RunResult::Missing,
        Ok(o) if o.status.success() => RunResult::Ok,
        Ok(o) => {
            let mut text = String::from_utf8_lossy(&o.stderr).into_owned();
            text.push_str(&String::from_utf8_lossy(&o.stdout));
            RunResult::Failed(o.status.code().unwrap_or(-1), text)
        }
    }
}

fn term_width() -> usize {
    if let Ok(cols) = env::var("COLUMNS") {
        if let Ok(n) = cols.parse::<usize>() {
            return n.clamp(40, 120);
        }
    }
    if let Ok(o) = Command::new("tput").arg("cols").output() {
        if let Ok(n) = String::from_utf8_lossy(&o.stdout).trim().parse::<usize>() {
            return n.clamp(40, 120);
        }
    }
    80
}

/// Keep the tail of `text` (the informative end of a path) within `max` chars.
fn truncate_left(text: &str, max: usize) -> String {
    let n = text.chars().count();
    if n <= max {
        return text.to_string();
    }
    let keep = max.saturating_sub(1);
    let skip = n - keep;
    let tail: String = text.chars().skip(skip).collect();
    format!("…{}", tail)
}

enum Status {
    Passed,
    Failed,
    Skipped,
}

struct Paint {
    color: bool,
}

impl Paint {
    fn new(color: bool) -> Self {
        Paint { color }
    }

    fn c<'a>(&self, code: &'a str) -> &'a str {
        if self.color {
            code
        } else {
            ""
        }
    }

    fn reset(&self) -> &str {
        self.c(RESET)
    }

    fn box_top(&self, width: usize, title: &str) {
        let inner = width.saturating_sub(4);
        let dashes = inner.saturating_sub(title.chars().count() + 2);
        println!(
            "{}├ ◆ {} {}╮{}",
            self.c(PURPLE),
            title,
            "─".repeat(dashes),
            self.reset()
        );
    }

    fn box_line(&self, width: usize, text: &str) {
        let inner = width.saturating_sub(4);
        // Long values (crate paths) get head-truncated so the right wall of the
        // box stays where it belongs — a ragged wall is the sloppy-output look.
        let text = &truncate_left(text, inner);
        let pad = inner.saturating_sub(text.chars().count());
        println!(
            "{}│{} {}{} {}│{}",
            self.c(PURPLE),
            self.reset(),
            text,
            " ".repeat(pad),
            self.c(PURPLE),
            self.reset()
        );
    }

    fn box_bottom(&self, width: usize) {
        println!(
            "{}├{}╯{}",
            self.c(PURPLE),
            "─".repeat(width.saturating_sub(2)),
            self.reset()
        );
    }

    fn step_start(&self, name: &str) {
        println!("{}├ ◆ {}{}", self.c(PURPLE), name, self.reset());
    }

    fn step_end(&self, name: &str, status: Status, note: &str) {
        let (mark, color) = match status {
            Status::Passed => ("PASS", GREEN),
            Status::Failed => ("FAIL", RED),
            Status::Skipped => ("SKIP", YELLOW),
        };
        let tail = if note.is_empty() {
            String::new()
        } else {
            format!(" {}({}){}", self.c(DIM), note, self.reset())
        };
        println!(
            "{}├ ◇ {} {}{}{}{}",
            self.c(PURPLE),
            name,
            self.c(color),
            mark,
            self.reset(),
            tail
        );
    }

    fn detail(&self, output: &str) {
        for line in output.lines().take(40) {
            println!("{}│{}   {}", self.c(PURPLE), self.reset(), line);
        }
        if output.lines().count() > 40 {
            println!(
                "{}│{}   {}… output truncated{}",
                self.c(PURPLE),
                self.reset(),
                self.c(DIM),
                self.reset()
            );
        }
    }

    fn gap(&self) {
        println!("{}│{}", self.c(PURPLE), self.reset());
    }
}
