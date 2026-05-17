# Codex Auth Studio

Small local desktop UI for `codex-auth`.

## Quick Start

This app is set up for local development and release packaging from this repo.

```bash
npm run desktop:install
npm run desktop:test
npm run desktop:check
npm run desktop:audit
npm run desktop:run
npm run desktop:linux:check
npm run desktop:linux:package
npm run desktop:linux:install
npm run desktop:linux:uninstall
npm run desktop:windows:check
npm run desktop:windows:package
```

- `npm run desktop:test`: frontend logic regression tests
- `npm run desktop:check`: frontend tests + TypeScript build + Rust unit tests + `cargo check`
- `npm run desktop:audit`: full desktop audit, including a debug Tauri build and a short smoke launch that fails if the app exits too early
- `npm run desktop:run`: launches the existing local debug binary without a dev server or bundle step
- `npm run desktop:linux:check`: stages a bundled `codex-auth`, runs the desktop checks, builds the debug app, and smoke-launches it
- `npm run desktop:linux:package`: runs the Linux check, builds `.rpm` and AppImage packages, and verifies both artifacts
- `npm run desktop:linux:install`: runs the Linux check, builds a release binary, installs the app for the current user under `~/.local/opt/codex-auth-studio/`, and writes a desktop launcher to `~/.local/share/applications/io.loongphy.codexauthstudio.desktop`
- `npm run desktop:linux:uninstall`: removes the user-local Linux install and launcher
- `npm run desktop:windows:check`: stages bundled Windows CLI binaries, runs desktop checks, and builds the debug Windows app
- `npm run desktop:windows:package`: runs the Windows check and builds a Windows 10 x64 NSIS `.exe` installer

`desktop:run` expects the debug binary to already exist. If you have not built it yet, run `npm run desktop:audit` first.

## App-Local Commands

If you are already inside `apps/codex-auth-desktop`, the equivalent commands are:

```bash
npm install
npm run test:ui
npm run check
npm run audit
npm run run:local
npm run linux:check
npm run linux:package
npm run linux:install
npm run linux:uninstall
npm run windows:check
npm run windows:package
npm run tauri:dev
```

- `npm run run:local`: launches the existing debug binary from `src-tauri/target/debug/`
- `npm run linux:check`: stages the bundled CLI, then runs the Linux-focused preflight
- `npm run linux:package`: builds and verifies Fedora/Linux `.rpm` and AppImage artifacts
- `npm run linux:install`: installs the app locally for the current Linux user
- `npm run linux:uninstall`: removes the local Linux install
- `npm run windows:check`: stages bundled `codex-auth.exe` and `codex-auth-auto.exe`, then checks the Windows app
- `npm run windows:package`: builds and verifies the Windows NSIS installer
- `npm run tauri:dev`: starts the Vite dev server and Tauri dev window for UI work

## Release Artifacts

GitHub Releases attach these desktop artifacts for end users:

- Fedora/Linux: `.rpm`
- Portable Linux: `.AppImage`
- Windows 10 x64: NSIS `.exe` installer

The Windows installer is currently unsigned, so Windows may show a SmartScreen warning.

## What It Does

- Reads `~/.codex/accounts/registry.json` for account cards and quota snapshots
- Calls `codex-auth` for real actions like `switch`, `switch --best`, `warm`, and auto-switch config changes
- Auto-refreshes the dashboard every 10 seconds while the window is visible
- Shows a local login panel that runs `codex-auth login`, streams the output, and exposes the detected login URL
- Bundles `codex-auth` with Linux and Windows desktop packages so launcher environments do not depend on shell `PATH`
- Still falls back to `PATH` and common install locations like `~/.npm-global/bin`
- Lets you save or clear a local binary override in the `CLI Runtime` panel when launcher environments do not inherit your shell PATH

If you already know the exact binary path, you can still launch the app with `CODEX_AUTH_BIN=/full/path/to/codex-auth`. Saved overrides inside the app take precedence over that environment variable.

Release packages never include developer account data from `~/.codex`, WebKit/cache data from `~/.local/share/io.loongphy.codexauthstudio`, or local installs from `~/.local/opt/codex-auth-studio`.

## Notes

- On Linux, `desktop:run` needs a graphical session (`DISPLAY` or `WAYLAND_DISPLAY`).
- `desktop:linux:install` also needs a graphical session because it smoke-launches the installed app before finishing.
- If the app cannot find `codex-auth`, use the `CLI Runtime` panel to save an override path.
- `desktop:windows:package` must run on Windows.
- If you want to debug startup/runtime issues, `npm run desktop:audit` is the quickest full check.
