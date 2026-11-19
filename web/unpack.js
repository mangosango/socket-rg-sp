import createUnpackModule from './unpack-wasm.js';

let wasm, loading;
const fail = () => { throw new Error('Asset unpack failed'); };
export function initUnpack() {
  return loading ??= createUnpackModule({ print() {}, printErr() {} })
    .then(module => { wasm = module; }, fail);
}

function withBytes(bytes, limit, use) {
  if (!(bytes instanceof Uint8Array) || !bytes.length || bytes.length > limit) fail();
  const ptr = wasm._malloc(bytes.length);
  if (!ptr) fail();
  try {
    wasm.HEAPU8.set(bytes, ptr);
    return use(ptr);
  } finally {
    wasm.HEAPU8.fill(0, ptr, ptr + bytes.length);
    wasm._free(ptr);
  }
}

export function startUnpack(lib, cfg) {
  if (!wasm) fail();
  wasm._reset_unpack(); // A failed replacement must not reuse a previous APK's key.
  try {
    withBytes(cfg, 4 << 20, c => withBytes(lib, 256 << 20, l => {
      if (!wasm._start_unpack(l, lib.length, c, cfg.length)) fail();
    }));
  } catch { fail(); }
}

export function decryptAsset(input) {
  if (!wasm) fail();
  try {
    return withBytes(input, 128 << 20, ptr => {
      const n = wasm._decrypt_asset(ptr, input.length);
      if (n < 0) fail();
      return wasm.HEAPU8.slice(ptr + 40, ptr + 40 + n);
    });
  } catch { fail(); }
}
