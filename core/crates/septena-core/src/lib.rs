//! Septena task rules and sync decisions, shared by every client (ADR 0025,
//! `docs/SHARED_CORE_SPEC.md`).
//!
//! The core does no I/O: no network, no storage, no clock, no secrets. A host
//! passes in the current time and the rows; the core returns values and plans
//! that the host applies. Row fields cross the boundary as JSON object
//! strings. Every rule here is verified by `registry/conformance/*.json`.

#[cfg(feature = "ffi")]
uniffi::setup_scaffolding!();

/// `scripts/gen-registries.mjs` output. Never edit by hand.
mod generated {
    pub mod registry;
}

mod conformance;
mod convo;
mod date;
mod do_session;
mod error;
mod fade;
mod json;
mod nfc;
mod nfc_table;
mod recurrence;
mod refs;
mod reminders;
mod sync;
mod task_dates;
mod views;

pub use conformance::*;
pub use convo::*;
pub use do_session::*;
pub use error::*;
pub use fade::*;
pub use json::*;
pub use recurrence::*;
pub use refs::*;
pub use reminders::*;
pub use sync::*;
pub use task_dates::*;
pub use views::*;

pub use generated::registry;

/// The version of this core, for host logs and the job summary.
#[cfg_attr(feature = "ffi", uniffi::export)]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}
