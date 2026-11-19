# Plan: local APK converter on GitHub Pages

Historical design for the initial asset-only converter. The shipped installer now combines the private pack with a public, prebuilt RG SP runtime and mGBA. For the current first-install flow, build, tests and deployment, see [Browser installer](web-converter.md).

**Input:** one user-owned Socket APK, dropped on the page or selected with a keyboard-accessible **Choose APK** button. **Output:** `socket-assets.zip`, containing `System/socket/socket.pck` at the archive root path. Unzip it at the root of a card that already has the matching BaseOS port installed. Make clear before conversion that this replaces the pack; it is not a complete installation. The ZIP contains Socket assets and is for personal use, not redistribution.

Use `tools/build-pack.sh` as the reference, not the whole `build.sh`: only the pack depends on the APK. Building the Linux engine, RetroArch and device helpers, writing to a mounted card and fetching artwork are outside this converter. GitHub Pages serves the converter, never the APK or the result.

## 1. Prove the conversion before building the UI

- Run the pipeline in a single Web Worker. Start with a pinned, self-hosted Pyodide runtime so the browser can reuse `gdc2gd.py`, `patch-socket.py` and `pack.py`. Avoid a second implementation of the version-specific patches. Compile `godot-unpack.c` with its crypto dependency for single-threaded WebAssembly; run it against worker-local files, without launching a subprocess. Replace the decoder's `zstd -dc` call in the browser with a compatible in-process zstd decoder. Test both compressed and uncompressed scripts.
- Move the file-selection, patch and overlay steps from `build-pack.sh` into a shared Python function. Keep the shell CLI and its arguments working; give the CLI and worker separate adapters for the native/WASM unpacker and decompressor. Preserve the current script/remap replacement rules, optional version-specific files, shader changes and AYN Thor removal. Package the repo's `overlay/` at site-build time, not from a user's card.
- First milestone: privately convert one supported APK in a desktop browser. Compare the SHA-256 of the **inner PCK**, not ZIP metadata, against the native build from the same commit and APK. Measure peak memory and elapsed time on the largest available input before committing to an in-memory filesystem. Process entries incrementally and discard intermediates as soon as possible; if the pack cannot fit the chosen browser budget, use worker-local temporary storage for the large stages before shipping.

## 2. Add the drop-to-download flow

- Use one static HTML page, a labeled file input and a drop target feeding the same handler. Show the stages (checking APK, converting, packing, ready) in a live status region. Allow cancel/reset by terminating the worker. Enable **Download ZIP** only after the complete pack succeeds; release the Blob URL and temporary files on reset.
- Treat the APK as an untrusted ZIP, not as executable code. Read only the entries used by `build-pack.sh`. Reject unsafe or duplicate paths, corrupt entries, missing required files and unsupported Socket versions. Bound entry count, actual inflated bytes and decompressor output using limits informed by the prototype. Report the failing stage and a useful next step, never key material, decoded scripts or raw tool logs. Do not offer a partial ZIP.
- Load all code, WASM, Python modules and overlays from the same Pages site **before** marking the converter ready. No upload endpoint, CDN fallback, analytics or remote error reporting. Keep inputs, intermediates and results out of browser persistence unless temporary storage is required; in that case clean it on success, cancellation and failure.

### Visual direction

Use the [Socket product page](https://depmots.com/socket) as a reference for its narrow, centered layout, black background, white-to-slate title and rounded dark panels. Make the converter the focus rather than recreating the marketing page.

- **Header:** Center “Socket asset converter” above “Turn your Socket APK into a BaseOS asset pack. Your APK stays in this browser.” Keep the column at most 36rem wide with 1rem side gutters on phones. Use a bold, tightly spaced system sans title and reserve monospace for filenames and paths.
- **Drop panel:** Use a deep slate surface (`#020617`), a thin slate border and 20px corners. Center “Drop your APK here” over a white **Choose APK** button with dark text. On drag-over, brighten the border and change the prompt to “Release to convert”; keep a visible keyboard focus ring for the picker.
- **Progress and result:** Keep the panel in place while its contents change. Show the filename and current stage as text, with **Cancel** as a secondary action. On success, make **Download ZIP** the primary white button; on error, show the cause and **Choose another APK**. Never rely on color or animation to communicate a state.
- **Supporting details:** Below the panel, use compact rows separated by fine slate rules for supported versions, ZIP contents and the existing-installation requirement. Use original text and plain CSS; do not load the reference site's icon, videos, fonts or scripts.

## 3. Verify and publish

- In CI, use generated, redistributable fixtures for drop/picker, conversion, ZIP layout, malformed input, unsupported version, cancellation and retry. Once the page is ready, disable networking in a browser test and require a successful download. For release validation, run the private native/browser parity check for each available [supported APK version](socket-versions.md); identify any unverified versions instead of uploading real APKs to CI. Smoke-test the extracted pack with the existing packed-app checks and test the download in desktop Chrome, Firefox and Safari.
- Build a dedicated static-site directory in GitHub Actions using an explicit allowlist of interface files, worker, pinned runtime dependencies, converter tools, overlays and required license notices. Never publish the repository root, `work/`, `dist/`, APKs, keys, generated packs or test output. Use relative asset URLs and test from `/socket-rg-sp/`, not only `/`.
- Configure Pages to use GitHub Actions. Test on pull requests; upload the clean site artifact and deploy only from the trusted default branch using the [Pages workflow](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages). Link the live page from the install README after the parity, offline and memory checks pass. Keep the CLI available for machines that exceed browser limits.
