//! SpawnTests.swift's resolving and running halves, ported. The detached
//! half checks for children left to reap, which other tests' children would
//! confuse, so it is a test binary of its own (tests/detached.rs).

use super::*;
use std::fs;

#[test]
fn a_bare_name_is_found_on_the_path() {
    assert_eq!(resolve_executable("sh", Some("/nonexistent:/bin")).as_deref(), Some("/bin/sh"));
    assert_eq!(resolve_executable("sh", Some("/bin/")).as_deref(), Some("/bin/sh"), "a trailing slash");
}

#[test]
fn a_path_is_taken_as_given_or_refused() {
    assert_eq!(resolve_executable("/bin/sh", None).as_deref(), Some("/bin/sh"));
    assert_eq!(resolve_executable("/bin/no-such-program-here", None), None);
    assert_eq!(resolve_executable("", None), None);
    assert_eq!(resolve_executable("sh", Some("/nonexistent")), None);
}

#[test]
fn only_an_executable_regular_file_counts() {
    let dir = std::env::temp_dir().join(format!("abyss-spawn-{}", std::process::id()));
    fs::create_dir_all(dir.join("adir")).unwrap();
    let plain = dir.join("notexec");
    fs::write(&plain, "#!/bin/sh\n").unwrap();
    assert_eq!(resolve_executable(plain.to_str().unwrap(), None), None, "not executable");
    assert_eq!(resolve_executable(dir.join("adir").to_str().unwrap(), None), None, "a directory is executable, and not a program");
    fs::remove_dir_all(dir).unwrap();
}

fn opts() -> Options {
    Options::default()
}

#[test]
fn stdout_and_stderr_are_kept_apart_and_the_exit_code_is_reported() {
    let r = run(&["sh", "-c", "echo out; echo err >&2; exit 3"]);
    assert_eq!(r.stdout_text(), "out\n");
    assert_eq!(r.stderr_text(), "err\n", "stderr must never be parsed as data, so it is kept apart");
    assert_eq!((r.exit_code(), r.code(), r.succeeded()), (Some(3), 3, false));
    assert_eq!(r.failure, None);
}

#[test]
fn merged_output_keeps_its_order() {
    let r = run_with(&["sh", "-c", "echo a; echo b >&2; echo c"], Options { stderr: ErrorOutput::Merge, ..opts() });
    assert_eq!(r.stdout_text(), "a\nb\nc\n");
    assert!(r.stderr.is_empty());
}

/// Without input a child reads /dev/null: `cat` must finish.
#[test]
fn without_input_stdin_is_dev_null() {
    let r = run(&["cat"]);
    assert!(r.succeeded() && r.stdout.is_empty());
}

/// More than a pipe holds, both ways at once.
#[test]
fn input_and_output_larger_than_a_pipe_do_not_deadlock() {
    let input: Vec<u8> = (0..1u32 << 20).map(|i| i.wrapping_mul(7) as u8).collect();
    let r = run_with(&["cat"], Options { input: Some(input.clone()), limit: 2 << 20, ..opts() });
    assert!(r.succeeded());
    assert_eq!(r.stdout, input);
}

/// The fathom bug: stderr full before stdout is written.
#[test]
fn a_full_stderr_before_stdout_does_not_deadlock() {
    let r = run_with(&["sh", "-c", "head -c 1048576 /dev/zero >&2; echo done"], Options { limit: 2 << 20, ..opts() });
    assert!(r.succeeded());
    assert_eq!(r.stderr.len(), 1 << 20);
    assert_eq!(r.stdout_text(), "done\n");
}

/// The installer's bug: past the limit the rest is drained, and the
/// program finishes rather than dying of SIGPIPE.
#[test]
fn past_the_limit_the_rest_is_drained_and_the_program_finishes() {
    let r = run_with(&["head", "-c", "3000000", "/dev/zero"], Options { limit: 1000, ..opts() });
    assert_eq!(r.stdout.len(), 1000);
    assert_eq!(r.exit_code(), Some(0), "the program did not finish normally (signal {:?})", r.signal());
}

/// A child that exits without reading its input cannot kill the caller.
#[test]
fn a_child_that_ignores_its_input_cannot_kill_the_caller() {
    let r = run_with(&["true"], Options { input: Some(vec![65; 4 << 20]), ..opts() });
    assert_eq!(r.exit_code(), Some(0));
}

#[test]
fn a_signalled_program_is_reported_as_signalled() {
    let r = run(&["sh", "-c", "kill -TERM $$"]);
    assert_eq!((r.exit_code(), r.signal(), r.code()), (None, Some(15), 128 + 15));
}

#[test]
fn a_program_that_is_not_found_says_so() {
    let r = run(&["no-such-program-anywhere-at-all"]);
    assert_eq!((r.raw_status, r.code()), (None, 127), "the shell's number for not found");
    assert_eq!(r.failure.as_deref(), Some("no-such-program-anywhere-at-all: not found"));
    assert_eq!(run(&[]).failure.as_deref(), Some("empty command"));
}

#[test]
fn the_environment_is_added_to_ours_not_instead_of_it() {
    let env = BTreeMap::from([("ABYSS_SPAWN_T".to_owned(), "given".to_owned())]);
    let r = run_with(&["sh", "-c", "echo \"$ABYSS_SPAWN_T:${PATH:+path}\""], Options { environment: env.clone(), ..opts() });
    assert_eq!(r.stdout_text(), "given:path\n");
    let block = environment_block(&env);
    assert_eq!(block.iter().filter(|e| e.starts_with(b"ABYSS_SPAWN_T=")).count(), 1);
}
