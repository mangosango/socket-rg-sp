// One job per worker: closing it releases the input, WASM heaps and all intermediates.
let currentStage;
self.converterStage = (message, percent) => {
  currentStage = message;
  self.postMessage({ type: 'stage', message, percent });
};

async function initialize() {
  const [{ loadPyodide }, { initUnpack, startUnpack, decryptAsset }] = await Promise.all([
    import('./runtime/pyodide.mjs'), import('./unpack.js'),
  ]);
  Object.assign(self, { startUnpack, decryptAsset });
  const runtime = new URL('./runtime/', self.location.href).href;
  const [py, , archive, card] = await Promise.all([
    loadPyodide({ indexURL: runtime, packageBaseUrl: runtime, stdout() {}, stderr() {} }),
    initUnpack(),
    fetch('./converter.zip').then(response => {
      if (!response.ok) throw new Error();
      return response.arrayBuffer();
    }),
    fetch('./card-runtime.zip').then(response => {
      if (!response.ok) throw new Error();
      return response.blob();
    }),
  ]);
  py.FS.mkdir('/converter');
  py.FS.mkdir('/input');
  py.FS.mkdir('/card');
  py.FS.mount(py.FS.filesystems.WORKERFS, { blobs: [{ name: 'runtime.zip', data: card }] }, '/card');
  const parts = [];
  self.cardPrefix = end => { parts.push(card.slice(0, end)); };
  self.cardAppend = bytes => { parts.push(new Blob([bytes])); };
  py.unpackArchive(archive, 'zip', { extractDir: '/converter' });
  py.runPython(`
import sys
sys.path[:0] = ['/converter/tools', '/converter']
from compression import zstd
from build_pack import build_pack, validate_version
from convert import worker_convert
import zipfile
with zipfile.ZipFile('/card/runtime.zip'):
    pass
`);

  self.onmessage = ({ data }) => {
    if (data?.type !== 'convert') return;
    self.onmessage = null;
    try {
      if (!(data.file instanceof Blob)) throw new Error('Choose a Socket APK file.');
      // WORKERFS reads Blob slices on demand and ignores the user-provided filename.
      py.FS.mount(py.FS.filesystems.WORKERFS, { blobs: [{ name: 'input.apk', data: data.file }] }, '/input');
      self.portOptions = data.options || {};
      const message = py.runPython('worker_convert()');
      if (message) {
        self.postMessage({ type: 'error', message: `${currentStage}: ${message}` });
      } else {
        const blob = new Blob(parts, { type: 'application/zip' });
        self.postMessage({ type: 'done', blob });
      }
    } catch {
      self.postMessage({ type: 'error', message: `${currentStage || 'Checking APK'}: Could not complete conversion. Try the desktop converter.` });
    } finally {
      self.close();
    }
  };
  self.postMessage({ type: 'ready' });
}

initialize().catch(() => {
  self.postMessage({ type: 'error', message: 'Converter startup failed. Reload the page to fetch the local runtime and tools.' });
  self.close();
});
