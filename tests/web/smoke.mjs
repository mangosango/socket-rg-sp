// No real APK in CI. Optional private parity check: smoke.mjs SITE APK NATIVE_PCK.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createCipheriv, createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { mkdtemp, rm, stat, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { chromium, firefox, webkit } from 'playwright';

const [site, apk, reference] = process.argv.slice(2);
assert(site && !!apk === !!reference, 'Usage: smoke.mjs SITE [PRIVATE_APK NATIVE_PCK]');
const prefix = '/socket-rg-sp/';
const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://localhost');
    assert.equal(req.method, 'GET');
    assert(url.pathname.startsWith(prefix));
    const name = decodeURIComponent(url.pathname.slice(prefix.length)) || 'index.html';
    const file = path.resolve(site, name);
    assert(file.startsWith(path.resolve(site) + path.sep));
    const size = (await stat(file)).size;
    const mime = { '.html': 'text/html', '.css': 'text/css', '.js': 'text/javascript', '.mjs': 'text/javascript', '.wasm': 'application/wasm', '.json': 'application/json' };
    res.writeHead(200, { 'Content-Type': mime[path.extname(name)] || 'application/octet-stream', 'Content-Length': size });
    createReadStream(file).pipe(res);
  } catch { res.writeHead(404).end(); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const folder = await mkdtemp(path.join(tmpdir(), 'socket-smoke-'));
let browser, sampler;
try {
  const engine = process.env.BROWSER || 'chromium';
  browser = await ({ chromium, firefox, webkit })[engine].launch({ executablePath: engine === 'chromium' ? process.env.CHROME_PATH : undefined });
  const context = await browser.newContext();
  const page = await context.newPage();
  const url = `http://127.0.0.1:${server.address().port}${prefix}`;
  let badRequests = 0;
  let offline = false;
  context.on('request', req => {
    if (/^https?:/.test(req.url()) && (offline || req.method() !== 'GET' || !req.url().startsWith(url))) badRequests++;
  });
  const ready = async () => {
    await page.waitForFunction(() => ['Drop your Socket APK here', 'Converter unavailable'].includes(document.querySelector('#heading')?.textContent), undefined, { timeout: 120000 });
    assert.equal(await page.locator('#heading').textContent(), 'Drop your Socket APK here', await page.locator('#status').textContent());
  };
  const setOffline = async value => { offline = value; await context.setOffline(value); };
  await page.goto(url);
  await ready();
  await setOffline(true);
  // Exercise the actual drop handler and worker, not a replacement worker.
  await page.locator('#panel').evaluate(panel => {
    const dt = new DataTransfer();
    dt.items.add(new File(['not a ZIP'], 'broken.apk'));
    panel.dispatchEvent(new DragEvent('drop', { bubbles: true, dataTransfer: dt }));
  });
  await page.locator('.primary').click();
  await page.getByRole('heading', { name: 'Conversion stopped' }).waitFor();
  assert(await page.locator('#download').isHidden());
  await setOffline(false);
  // A generated encrypted ECFG header exercises the unpacker without Socket assets.
  const plaintext = Buffer.from('ECFG' + '\0'.repeat(12));
  const key = Buffer.alloc(32, 42), iv = Buffer.alloc(16, 17), len = Buffer.alloc(8);
  len.writeBigUInt64LE(BigInt(plaintext.length));
  const cipher = createCipheriv('aes-256-cfb', key, iv);
  await writeFile(path.join(folder, 'project'), Buffer.concat([createHash('md5').update(plaintext).digest(), len, iv, cipher.update(plaintext), cipher.final()]));
  await writeFile(path.join(folder, 'lib'), key);
  execFileSync('python3', ['-c', `import zipfile
with zipfile.ZipFile('synthetic.apk','w',zipfile.ZIP_DEFLATED) as z:
 z.write('project','assets/project.binary'); z.write('lib','lib/arm64-v8a/libgodot_android.so')`], { cwd: folder });
  await page.locator('#apk').setInputFiles(path.join(folder, 'synthetic.apk'));
  await page.locator('.primary').click();
  await page.getByRole('heading', { name: 'Conversion stopped' }).waitFor({ timeout: 120000 });
  // This diagnostic is reached only after ZIP checks, WASM decryption and the Python bridge.
  assert.match(await page.locator('#status').innerText(), /Unsupported Socket release/);
  assert(await page.locator('#download').isHidden());
  // Retry startup and cancel in the same turn, before the new worker becomes ready.
  await page.locator('#apk').evaluate(input => {
    const dt = new DataTransfer(); dt.items.add(new File(['x'], 'cancel.apk'));
    input.files = dt.files; input.dispatchEvent(new Event('change'));
    document.querySelector('.primary').click();
    document.getElementById('reset').click();
  });
  await page.getByRole('heading', { name: 'Preparation canceled' }).waitFor();
  await page.locator('#reset').click();
  await ready();
  await setOffline(true);
  if (apk) {
    const start = performance.now();
    // Aggregate RSS includes shared browser pages; report a rough desktop budget, not JS heap size.
    const system = engine === 'chromium' ? await browser.newBrowserCDPSession() : null;
    const rss = async () => {
      const { processInfo } = await system.send('SystemInfo.getProcessInfo');
      return execFileSync('ps', ['-o', 'rss=', '-p', processInfo.map(p => p.id).join(',')], { encoding: 'utf8' }).trim().split(/\s+/).reduce((a, n) => a + Number(n), 0) / 1024;
    };
    const baseline = system ? await rss() : 0; let peak = baseline;
    if (system) sampler = setInterval(() => rss().then(n => { peak = Math.max(n, peak); }).catch(() => {}), 500);
    try { await page.locator('#apk').setInputFiles(path.resolve(apk)); }
    catch { throw new Error('Could not select the private APK'); }
    await page.locator('.primary').click();
    const link = page.locator('#download');
    await Promise.race([link.waitFor({ timeout: 600000 }), page.getByRole('heading', { name: 'Conversion stopped' }).waitFor({ timeout: 600000 }).then(async () => { throw new Error(await page.locator('#status').innerText()); })]);
    const downloaded = page.waitForEvent('download');
    await link.click();
    const result = await downloaded;
    assert.equal(result.suggestedFilename(), 'socket-baseos.zip');
    const zip = path.join(folder, 'result.zip'); await result.saveAs(zip);
    try { execFileSync('python3', ['-c', `import hashlib, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z, open(sys.argv[2],'rb') as native, zipfile.ZipFile(sys.argv[3]) as runtime:
 pck = 'System/socket/socket.pck'
 assert pck not in runtime.namelist() and 'System/socket/cores/mgba_libretro.so' in runtime.namelist()
 assert sorted(z.namelist()) == sorted([*runtime.namelist(), pck])
 for member in runtime.infolist():
  assert z.getinfo(member.filename).external_attr == member.external_attr
  with runtime.open(member) as src, z.open(member.filename) as dst:
   assert hashlib.file_digest(src,'sha256').digest() == hashlib.file_digest(dst,'sha256').digest()
 with z.open(pck) as p:
  assert hashlib.file_digest(p,'sha256').digest() == hashlib.file_digest(native,'sha256').digest()`, zip, path.resolve(reference), path.resolve(site, 'card-runtime.zip')], { stdio: 'pipe' }); } catch { throw new Error('First-install ZIP contents or PCK parity check failed'); }
    console.log(`Private offline first-install ZIP matched the runtime, core and native PCK (${((performance.now()-start)/1000).toFixed(1)} s including download and verification${system ? `; sampled Chromium RSS ${Math.round(baseline)} → ${Math.round(peak)} MiB` : ''}).`);
  }
  assert.equal(badRequests, 0, 'Unexpected network requests during local conversion');
  console.log('Browser worker, offline drop, error, retry and cancel checks passed.');
} finally {
  clearInterval(sampler);
  await browser?.close(); server.closeAllConnections(); server.close();
  await rm(folder, { recursive: true, force: true });
}
