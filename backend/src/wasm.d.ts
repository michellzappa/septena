// Ambient declaration so TypeScript accepts `import mod from "./x.wasm"`.
// Wrangler's default `CompiledWasm` rule turns the import into a compiled
// `WebAssembly.Module` at bundle time.
declare module "*.wasm" {
  const module: WebAssembly.Module;
  export default module;
}
