use std::fmt;

/// The one error type of the core. `reason` is the text a host logs or
/// shows; the conformance vectors compare it exactly. (Not `message`: that
/// name clashes with `Throwable.message` in the Kotlin bindings.)
#[derive(Clone, Debug, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Error))]
pub enum CoreError {
    InvalidInput { reason: String },
}

impl CoreError {
    pub(crate) fn invalid(message: impl Into<String>) -> Self {
        CoreError::InvalidInput { reason: message.into() }
    }

    pub fn message(&self) -> &str {
        match self {
            CoreError::InvalidInput { reason } => reason,
        }
    }
}

impl fmt::Display for CoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.message())
    }
}

impl std::error::Error for CoreError {}
