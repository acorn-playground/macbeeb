declare module "*.wasm" {
  const module: WebAssembly.Module;
  export default module;
}
declare module "*.rom" {
  const data: ArrayBuffer;
  export default data;
}
