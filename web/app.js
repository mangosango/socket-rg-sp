'use strict';
const $ = id => document.getElementById(id);
const panel = $('panel'), apk = $('apk'), form = $('options'), reset = $('reset'), download = $('download');
const readyTitle = 'Drop your Socket APK here';
let state, worker, selected, resultURL;

function show(next, title, message = '') {
  state = panel.dataset.state = next;
  const view = panel.dataset.view = next === 'options' ? 'options' : ['busy', 'done'].includes(next) ? 'guide' : 'drop';
  panel.classList.remove('dragging');
  $('drop').hidden = view !== 'drop'; form.hidden = view !== 'options'; $('guide').hidden = view !== 'guide';
  $('heading').textContent = title; $('status').textContent = message;
  apk.disabled = !['ready','failed','options'].includes(next);
  apk.setAttribute('aria-label', next === 'failed' ? 'Choose another APK' : 'Choose APK');
  $('retry-file').hidden = next !== 'failed';
  $('get').hidden = next !== 'ready'; $('intro').hidden = next !== 'ready';
  download.hidden = next !== 'done'; $('progress').hidden = next !== 'busy';
  reset.hidden = ['ready','failed','options'].includes(next);
  reset.textContent = ({done:'Reset', unavailable:'Retry', paused:'Start converter'})[next] || 'Cancel';
}
function clearOptions() {
  form.reset();
  for (const field of form.querySelectorAll('fieldset')) field.disabled = false;
  for (const input of form.querySelectorAll('fieldset input')) input.setCustomValidity('');
  selected = null; $('filename').textContent = ''; $('size').textContent = '';
}
function stop() {
  worker?.terminate(); worker = null;
  if (resultURL) URL.revokeObjectURL(resultURL);
  resultURL = null; download.removeAttribute('href'); $('step-download').removeAttribute('href'); apk.value = '';
}
function failure(message) {
  const starting = state !== 'busy';
  stop(); clearOptions();
  show(starting ? 'unavailable' : 'failed', starting ? 'Converter unavailable' : 'Conversion stopped', starting ? `${message} Reconnect if offline, then retry.` : message);
  (starting ? reset : apk).focus();
}
function start(job) {
  stop(); show('loading', 'Preparing converter', 'Loading the card runtime and conversion tools…');
  try {
    const current = worker = new Worker('./worker.js', {type:'module'});
    current.onerror = current.onmessageerror = () => { if (current === worker) failure('The converter could not continue.'); };
    current.onmessage = ({data}) => {
      if (current !== worker) return;
      if (data.type === 'ready' && state === 'loading') {
        if (job) { convert(job); job = null; }
        else { const focus = document.activeElement === reset; show('ready', readyTitle); if (focus) apk.focus(); }
      } else if (data.type === 'error') failure(data.message || 'Could not complete this step.');
      else if (data.type === 'stage' && state === 'busy') {
        progress(data.percent);
        if ($('status').textContent !== data.message) $('status').textContent = data.message;
      }
      else if (data.type === 'done' && state === 'busy') {
        if (!(data.blob instanceof Blob) || !data.blob.size) return failure('The converter returned an empty ZIP.');
        progress(100);
        const focus = document.activeElement === reset;
        stop(); $('step-download').href = download.href = resultURL = URL.createObjectURL(data.blob);
        show('done', '', 'Conversion complete!'); if (focus) download.focus();
      }
    };
  } catch { failure('Could not start the local converter.'); }
}
function progress(percent) {
  $('meter').setAttribute('aria-valuenow', percent);
  $('arc').setAttribute('stroke-dashoffset', 100 - percent);
}
function convert(job) {
  progress(0);
  show('busy', '', 'Checking APK…'); reset.focus();
  try { worker.postMessage({type:'convert', ...job}); } catch { failure('Could not read this APK.'); }
}
function choose(files) {
  if (apk.disabled || !files.length) return;
  apk.value = '';
  if (files.length !== 1 || !/\.apk$/i.test(files[0].name)) { $('status').textContent = 'Choose one Socket APK (.apk) at a time.'; return; }
  clearOptions(); selected = files[0]; $('filename').textContent = selected.name; $('size').textContent = `${(selected.size / 1000000).toFixed(1)} MB`;
  show('options', 'Port options'); $('wifi').focus();
}
apk.onchange = () => choose(Array.from(apk.files));
$('another').onclick = () => apk.click();
$('drop').onclick = event => { if (!apk.disabled && !event.target.closest('a,input,label')) apk.click(); };
for (const toggle of form.querySelectorAll('[role=switch]')) toggle.onchange = () => {
  const fields = toggle.closest('.option').querySelector('fieldset'); fields.disabled = !toggle.checked;
  for (const input of fields.elements) { input.value = ''; input.setCustomValidity(''); }
};
form.oninput = () => { for (const input of form.querySelectorAll('fieldset input')) input.setCustomValidity(''); };
form.onsubmit = event => {
  event.preventDefault();
  const options = {};
  for (const fields of form.querySelectorAll('fieldset')) {
    const inputs = [...fields.elements];
    if (fields.disabled || inputs.every(input => !input.value)) continue;
    for (const input of inputs) {
      const value = input.value, n = new TextEncoder().encode(value).length;
      const max = {ssid:32, psk:64, username:31, password:255}[input.name];
      if (!n || n > max || value !== value.trim() || /[\x00-\x1f\x7f]/.test(value) || (input.name === 'psk' && (n < 8 || (n === 64 && !/^[a-f0-9]{64}$/i.test(value))))) {
        input.setCustomValidity(input.name === 'psk' ? 'Use 8–63 bytes or 64 hexadecimal digits, without surrounding spaces.' : `Enter 1–${max} bytes without control characters or surrounding spaces.`); input.reportValidity(); return;
      }
      options[input.name] = value;
    }
  }
  const job = {file:selected, options}; clearOptions(); if (worker) convert(job); else { start(job); reset.focus(); }
};
reset.onclick = () => {
  if (state === 'loading') { stop(); show('paused','Preparation canceled','Start the converter when you’re ready.'); }
  else { start(); reset.focus(); }
};
window.addEventListener('dragover', e => e.preventDefault()); window.addEventListener('drop', e => e.preventDefault());
panel.ondragover = e => { if (state === 'ready' && e.dataTransfer.types.includes('Files')) { panel.classList.add('dragging'); $('heading').textContent = 'Drop to convert'; } };
function endDrag() { if (panel.classList.contains('dragging')) { panel.classList.remove('dragging'); $('heading').textContent = readyTitle; } }
panel.ondragleave = e => { if (!panel.contains(e.relatedTarget)) endDrag(); };
panel.ondrop = e => { endDrag(); choose(Array.from(e.dataTransfer.files)); };
start();
