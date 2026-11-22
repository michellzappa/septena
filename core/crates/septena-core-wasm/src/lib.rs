//! The shared core for JavaScript hosts: the web client (WB2, #248) and,
//! later, the Worker (C3, #249). JSON in, JSON out, through the same entry
//! point the conformance runner uses.

use wasm_bindgen::prelude::*;

/// Calls one core function by name. See `septena_core::JSON_FUNCTIONS`.
#[wasm_bindgen]
pub fn invoke(function: &str, input_json: &str) -> Result<String, JsError> {
    septena_core::invoke_json(function.to_string(), input_json.to_string()).map_err(|e| JsError::new(e.message()))
}

/// Runs one conformance fixture inside the core. Returns the report as JSON.
#[wasm_bindgen(js_name = runConformance)]
pub fn run_conformance(fixture: &str, json: &str) -> Result<String, JsError> {
    let report =
        septena_core::run_conformance(fixture.to_string(), json.to_string()).map_err(|e| JsError::new(e.message()))?;
    serde_json::to_string(&report).map_err(|e| JsError::new(&e.to_string()))
}

/// The function names `invoke` accepts, as a JSON array.
#[wasm_bindgen(js_name = coreFunctions)]
pub fn core_functions() -> String {
    serde_json::to_string(septena_core::JSON_FUNCTIONS).unwrap_or_else(|_| "[]".into())
}

#[wasm_bindgen(js_name = coreVersion)]
pub fn core_version() -> String {
    septena_core::core_version()
}
