// Exercise worker lifecycle edge cases without a real APK or runtime download.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { resolve } = require('node:path');
const { chromium } = require('playwright');

test('startup retry, cancellation, stale events and result cleanup', async t => {
  const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH });
  t.after(() => browser.close());
  const page = await browser.newPage();
  await page.route('**/*', route => {
    const name = new URL(route.request().url()).pathname.split('/').pop();
    assert.ok(['index.html', 'style.css', 'app.js', 'departure.woff2'].includes(name));
    return route.fulfill({ path: resolve(__dirname, '../../web', name) });
  });
  await page.addInitScript(() => {
    window.workers = [];
    window.Worker = class {
      constructor(url, options) {
        if (url !== './worker.js' || options?.type !== 'module') throw new Error('Expected local module worker');
        workers.push(this);
        queueMicrotask(() => workers.length === 1 ? this.onerror() : this.emit({ type: 'ready' }));
      }
      emit(data) { this.onmessage({ data }); }
      postMessage({ type, file, options }) {
        this.options = options;
        if (type === 'convert') this.emit({ type: 'stage', percent: 60, message: `Packing ${file.name}` });
      }
      terminate() { this.stopped = true; }
    };
  });
  await page.goto('https://local.test/socket-rg-sp/index.html');
  assert.match(await page.locator('#status').innerText(), /Reconnect/);
  await page.getByRole('button', { name: 'Retry' }).click();
  const apk = { name: 'fixture.apk', mimeType: '', buffer: Buffer.from('fixture') };
  await page.getByLabel('Choose APK').setInputFiles(apk);
  await page.getByLabel('SSID').fill('test network');
  await page.locator('[name=psk]').fill('example-only');
  await page.locator('.primary').click();
  assert.deepEqual(await page.evaluate(() => workers.at(-1).options), {ssid:'test network', psk:'example-only'});
  assert.equal(await page.locator('[name=psk]').inputValue(), '');
  assert.equal(await page.locator('#status').innerText(), 'Packing fixture.apk');
  assert.equal(await page.getByRole('progressbar').getAttribute('aria-valuenow'), '60');
  assert.equal(await page.locator('#arc').getAttribute('stroke-dashoffset'), '40');
  await page.getByRole('button', { name: 'Cancel' }).click();
  assert.ok(await page.evaluate(() => workers[1].stopped));
  await page.evaluate(() => workers[1].emit({ type: 'error', message: 'stale' }));
  await page.getByLabel('Choose APK').setInputFiles(apk);
  await page.locator('.primary').click();
  await page.evaluate(() => workers.at(-1).emit({ type: 'error', message: 'Unsupported version' }));
  assert.equal(await page.locator('#status').innerText(), 'Unsupported version');
  await page.getByLabel('Choose another APK').setInputFiles(apk);
  await page.locator('.primary').click();
  await page.evaluate(() => workers.at(-1).emit({ type: 'done', blob: new Blob(['ZIP']) }));
  const link = page.getByRole('link', { name: 'Download socket-baseos.zip' });
  assert.equal(await link.getAttribute('download'), 'socket-baseos.zip');
  assert.match(await page.locator('#status').innerText(), /Conversion complete/);
  assert.match(await page.locator('#guide').innerText(), /Merge folders; do not replace System/);
  assert.equal(await page.getByRole('link', { name: 'GitHub repository' }).getAttribute('href'), 'https://github.com/mangosango/socket-rg-sp');
  const url = await link.getAttribute('href');
  const step = page.locator('#step-download');
  assert.equal(await step.getAttribute('href'), url);
  const [file] = await Promise.all([page.waitForEvent('download'), step.click()]);
  assert.equal(file.suggestedFilename(), 'socket-baseos.zip');
  const badge = await link.boundingBox();
  assert.equal(badge.height, 24);
  assert.ok(badge.y + badge.height <= (await page.locator('#status').boundingBox()).y);
  await page.getByRole('button', { name: 'Reset' }).click();
  assert.equal(await step.getAttribute('href'), null);
  assert.ok(await page.evaluate(url => fetch(url).then(() => false, () => true), url));
  assert.ok(await link.isHidden());
});
