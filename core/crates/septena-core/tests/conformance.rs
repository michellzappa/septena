//! Runs every `registry/conformance/*.json` file through the core. A fixture
//! the core has no runner for fails this test: under ADR 0025 a shared rule
//! lives in the core.

use std::fs;
use std::path::PathBuf;

use septena_core::{CONFORMANCE_FIXTURES, run_conformance};

fn conformance_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../registry/conformance")
}

#[test]
fn every_vector_passes() {
    let mut files: Vec<PathBuf> = fs::read_dir(conformance_dir())
        .expect("registry/conformance exists")
        .map(|entry| entry.expect("readable entry").path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "json"))
        .collect();
    files.sort();
    assert!(!files.is_empty(), "no conformance fixtures found");

    let mut failures = Vec::new();
    let mut total = 0;
    for path in &files {
        let fixture = path.file_stem().unwrap().to_string_lossy().to_string();
        assert!(
            CONFORMANCE_FIXTURES.contains(&fixture.as_str()),
            "registry/conformance/{fixture}.json has no runner in the shared core (core/crates/septena-core/src/conformance.rs)"
        );
        let report = run_conformance(fixture.clone(), fs::read_to_string(path).unwrap()).unwrap();
        println!("{fixture}: {} cases, {} failures", report.cases, report.failures.len());
        total += report.cases;
        failures.extend(report.failures.into_iter().map(|f| format!("{fixture}: {f}")));
    }
    println!("SEPTENA_CORE_VECTORS {total} cases in {} files", files.len());
    assert!(failures.is_empty(), "conformance failures:\n{}", failures.join("\n"));
}

#[test]
fn json_entry_point_reports_errors_as_data() {
    let out = septena_core::invoke_json("planPullRow".into(), r#"{"entity":"turn","row":{"seq":1}}"#.into()).unwrap();
    assert_eq!(out, r#"{"error":"Pulled turn is missing taskId"}"#);
    assert!(septena_core::invoke_json("noSuchFunction".into(), "{}".into()).is_err());
}
