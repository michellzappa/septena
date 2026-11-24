/* tslint:disable */
/* eslint-disable */

/**
 * The function names `invoke` accepts, as a JSON array.
 */
export function coreFunctions(): string;

export function coreVersion(): string;

/**
 * Calls one core function by name. See `septena_core::JSON_FUNCTIONS`.
 */
export function invoke(_function: string, input_json: string): string;

/**
 * Runs one conformance fixture inside the core. Returns the report as JSON.
 */
export function runConformance(fixture: string, json: string): string;

export type InitInput = RequestInfo | URL | Response | BufferSource | WebAssembly.Module;

export interface InitOutput {
    readonly memory: WebAssembly.Memory;
    readonly coreFunctions: () => [number, number];
    readonly coreVersion: () => [number, number];
    readonly invoke: (a: number, b: number, c: number, d: number) => [number, number, number, number];
    readonly runConformance: (a: number, b: number, c: number, d: number) => [number, number, number, number];
    readonly __wbindgen_externrefs: WebAssembly.Table;
    readonly __wbindgen_free: (a: number, b: number, c: number) => void;
    readonly __wbindgen_malloc: (a: number, b: number) => number;
    readonly __wbindgen_realloc: (a: number, b: number, c: number, d: number) => number;
    readonly __externref_table_dealloc: (a: number) => void;
    readonly __wbindgen_start: () => void;
}

export type SyncInitInput = BufferSource | WebAssembly.Module;

/**
 * Instantiates the given `module`, which can either be bytes or
 * a precompiled `WebAssembly.Module`.
 *
 * @param {{ module: SyncInitInput }} module - Passing `SyncInitInput` directly is deprecated.
 *
 * @returns {InitOutput}
 */
export function initSync(module: { module: SyncInitInput } | SyncInitInput): InitOutput;

/**
 * If `module_or_path` is {RequestInfo} or {URL}, makes a request and
 * for everything else, calls `WebAssembly.instantiate` directly.
 *
 * @param {{ module_or_path: InitInput | Promise<InitInput> }} module_or_path - Passing `InitInput` directly is deprecated.
 *
 * @returns {Promise<InitOutput>}
 */
export default function __wbg_init (module_or_path?: { module_or_path: InitInput | Promise<InitInput> } | InitInput | Promise<InitInput>): Promise<InitOutput>;
