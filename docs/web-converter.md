# Browser installer for Socket on BaseOS

The [web installer](https://mangosango.github.io/socket-rg-sp/) makes **one ZIP for a first-time frontend installation** on an RG SP. You need a card with BaseOS installed, your own supported Socket APK, and a desktop browser. You do not need an existing Socket installation, Docker, Python, or a separate emulator download. The hosted link requires this repository’s Pages deployment; local preview instructions are below.

## Install

1. Set up BaseOS for your RG SP using the [BaseOS installation guide](https://github.com/pvaibhav/BaseOS/wiki/BaseOS-Install-Guide). Use its visible `BASEOS` volume or your dedicated frontend card. Use one frontend per card. **Back up an existing card**; a different frontend’s `System/frontend` takes precedence over `System/launch_frontend.sh`.
2. Open the installer in a desktop browser. It downloads the public card runtime and conversion tools; wait for **Drop your Socket APK here**. Drop the file or activate the drop area. Under **Port options**, leave both groups blank to skip, or enter Wi-Fi and/or RetroAchievements credentials. Select **Continue**. Conversion runs on your computer and works offline once the page is ready. Starting another job may require reconnecting.
3. Download **`socket-baseos.zip`** and extract it on your computer. **Copy the extracted contents to the card root**, merging folders. Do not copy the unopened ZIP, nest its contents inside an extra folder, or replace the whole `System/` directory. The card should have both `System/launch_frontend.sh` and `System/socket/socket.pck`. This is a frontend install, not a disk image. Keep the result private: it includes assets from your copy of Socket.
4. Put your own unpacked games in `Games/GB/`, `Games/GBC/` or `Games/GBA/`. Eject the card and boot. On a fresh card, the launcher prepares the emulator and platform records; select **Scan** in the platform editor to populate the library. No desktop setup, account or network is required for this step.

**Included:** patched Linux AArch64 Godot and RetroArch, an mGBA libretro core covering GB/GBC/GBA, the launcher, device helpers, profiles, shaders, config examples, licenses and your locally converted Socket pack. BaseOS supplies the system loader, hardware drivers and shared system libraries. ROMs, proprietary BIOS files, and BaseOS itself are not included; normal mGBA play does not require an external BIOS. Optional credentials are stored in plain text in the personal download and on the card. Treat the ZIP as sensitive; installing it can overwrite the corresponding files in `Config/`. Existing saves and libraries are not part of the ZIP. Refreshing an existing install replaces shipped runtime files, so back up any manual customizations.

## Browser requirements

On the official **RG SP BaseOS v1.4.0** filesystem, the native engine, RetroArch, mGBA and device helpers resolved their shared libraries without a custom library path. Headless RetroArch ran generated GB, GBC and GBA games using the supplied core and no external BIOS. These checks exercise the OS ABI, not the physical display, audio or controls.

Use a desktop browser and allow enough RAM for a full APK, conversion buffers and the output ZIP. The public runtime download is about 36 MiB, plus about 13 MiB of browser tools. With a 0.10.1 APK, budget about 104 MiB for the installer ZIP and 163 MiB on the card before adding games. A 0.10.1 conversion with networking disabled passed in desktop Chrome and Playwright Firefox and WebKit: each download contained every public runtime entry unchanged plus a PCK identical to the CLI output. The worker rejects APKs over 256 MiB and limits expanded entry sizes and counts. [Socket versions](socket-versions.md) lists the shared patcher’s supported versions; not every version has an original APK available for browser testing. If your browser cannot convert the APK, use the [manual build](../README.md#build).

## Build and preview the public site

Maintainers need arm64 Linux Docker support, git and the [native build prerequisites](../README.md#requirements), plus Node.js 22.16 or newer, Python 3.14 and Emscripten **4.0.11** for the site. Build from a clean checkout. The slow step compiles the device runtime on the build machine, **not** in the user’s browser. A website build never needs a real APK, ROM or SD card.

```sh
python3 tools/build-card-runtime.py work/web-card-runtime.zip
npm ci --ignore-scripts --prefix web
# Activate the pinned emsdk before this step.
python3 tools/build-web.py work/site
python3 tests/check_web_site.py --require-source work/site
python3 -m http.server 8000 --bind 127.0.0.1 --directory work/site
```

Open `http://127.0.0.1:8000/`. Use a new site destination for each build. Serve **only** the generated directory, not the repository, `work/`, or `dist/`. The public `card-runtime.zip` is only a template: it has **no Socket PCK** and is not a standalone installer. Corresponding source is offered separately so users don’t have to copy it onto their cards.

## Validate and publish

CI tests with generated fixtures at the `/socket-rg-sp/` URL prefix. To check a release privately, generate a native PCK reference from the same APK using `tools/build-pack.sh`, then run:

```sh
npm ci --ignore-scripts --prefix tests/web
(cd tests/web && npx playwright install chromium)
node tests/web/smoke.mjs work/site /path/to/your.apk /path/to/reference.pck
```

The test disconnects the browser **after** the worker is ready, downloads the install ZIP, and verifies every runtime entry and its permissions against the public template, as well as the PCK’s SHA-256 against the native build. Do not put private inputs or generated installers in CI, releases or Pages artifacts.

To publish, select **Settings → Pages → Build and deployment → Source: GitHub Actions**. The [Pages workflow](../.github/workflows/pages.yml) tests pull requests; only a successful push to `main` can deploy. Use the URL reported by the deploy job.
