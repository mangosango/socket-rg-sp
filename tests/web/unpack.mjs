// CHROME_PATH=/path/to/chrome node tests/web/unpack.mjs work/web-unpack [/path/to/native/godot-unpack]
import assert from 'node:assert/strict';
import { createCipheriv, createHash, randomBytes } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { chromium } from 'playwright';

const build = resolve(process.argv[2] || 'work/web-unpack');
const key = randomBytes(32);
const lib = Buffer.concat([randomBytes(8), key]); // last valid aligned offset
function encrypt(plain) {
  const padded = Buffer.alloc(Math.ceil(plain.length / 16) * 16);
  plain.copy(padded);
  const iv = randomBytes(16), cipher = createCipheriv('aes-256-cfb', key, iv);
  const len = Buffer.alloc(8);
  len.writeBigUInt64LE(BigInt(plain.length));
  return Buffer.concat([createHash('md5').update(plain).digest(), len, iv, cipher.update(padded), cipher.final()]);
}
const cfg = encrypt(Buffer.from('ECFG fixture config'));
const plain = Buffer.from('a non-aligned asset');
const asset = encrypt(plain), empty = encrypt(Buffer.alloc(0));
const corrupt = Buffer.from(asset);
corrupt[0] ^= 1;

if (process.argv[3]) {
  const tmp = mkdtempSync(join(tmpdir(), 'unpack-test-'));
  try {
    mkdirSync(join(tmp, 'src'));
    for (const [name, bytes] of [['lib', lib], ['src/project.binary', cfg], ['src/asset', asset], ['src/empty', empty]]) {
      writeFileSync(join(tmp, name), bytes);
    }
    const run = () => execFileSync(resolve(process.argv[3]), ['extract', 'lib', 'src', 'dst'], { cwd: tmp, stdio: 'pipe' });
    run();
    assert.deepEqual(readFileSync(join(tmp, 'dst/asset')), plain);
    assert.equal(readFileSync(join(tmp, 'dst/empty')).length, 0);
    writeFileSync(join(tmp, 'src/asset'), corrupt);
    assert.throws(run, err => err.status === 2);
  } finally { rmSync(tmp, { recursive: true, force: true }); }
}

async function checks({ lib, cfg, asset, empty, plain, corrupt }) {
  const check = ok => { if (!ok) throw Error('fixture check failed'); };
  const rejects = fn => {
    try { fn(); } catch (e) { check(e.message === 'Asset unpack failed'); return; }
    throw Error('expected rejection');
  };
  rejects(() => decryptAsset(asset));
  await Promise.all([initUnpack(), initUnpack()]);
  rejects(() => decryptAsset(asset));
  startUnpack(lib, cfg);
  const first = decryptAsset(asset);
  check(first instanceof Uint8Array && String(first) === String(plain));
  first.fill(0);
  check(String(decryptAsset(asset)) === String(plain) && decryptAsset(empty).length === 0);
  const huge = asset.slice(); huge[23] = 255;
  for (const bad of [asset.slice(1), asset.slice(0, 16), new Uint8Array([...asset, 0]), corrupt, huge]) {
    rejects(() => decryptAsset(bad));
  }
  const badCfg = cfg.slice(); badCfg[0] ^= 1;
  for (const [l, c] of [[lib, badCfg], [lib.subarray(1), cfg], [null, cfg], [lib, new Uint8Array((4 << 20) + 1)]]) {
    startUnpack(lib, cfg);
    rejects(() => startUnpack(l, c));
    rejects(() => decryptAsset(asset));
  }
}
const files = new Map([['/', ['text/html', '<!doctype html>']], ['/worker.js', ['text/javascript',
  `import {initUnpack, startUnpack, decryptAsset} from './unpack.js';
   self.onmessage = ({data}) => (${checks})(data).then(() => postMessage('ok'), e => postMessage(e.message));`]]]);
for (const name of ['unpack.js', 'unpack-wasm.js', 'unpack-wasm.wasm']) {
  files.set('/' + name, [name.endsWith('.wasm') ? 'application/wasm' : 'text/javascript', readFileSync(join(build, name))]);
}
const server = createServer((req, res) => {
  const file = files.get(req.url);
  if (!file) { res.writeHead(404).end(); return; }
  res.writeHead(200, { 'Content-Type': file[0] }).end(file[1]);
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
let browser;
try {
  browser = await chromium.launch({ executablePath: process.env.CHROME_PATH });
  const page = await browser.newPage();
  await page.goto(`http://127.0.0.1:${server.address().port}`);
  const result = await page.evaluate(arrays => new Promise((resolve, reject) => {
    const worker = new Worker('./worker.js', { type: 'module' });
    const timeout = setTimeout(() => reject(Error('worker timed out')), 15000);
    worker.onerror = e => reject(Error(e.message));
    worker.onmessage = e => { clearTimeout(timeout); resolve(e.data); };
    worker.postMessage(Object.fromEntries(Object.entries(arrays).map(([k, a]) => [k, Uint8Array.from(a)])));
  }), Object.fromEntries(Object.entries({ lib, cfg, plain, asset, empty, corrupt }).map(([k, a]) => [k, Array.from(a)])));
  assert.equal(result, 'ok');
  console.log('unpack fixture passed');
} finally {
  await browser?.close();
  server.close();
}
