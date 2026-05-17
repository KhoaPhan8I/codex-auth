# Release and CI

This document describes the repository's CI, preview package publishing, and tag-driven release automation.

## Version Source of Truth

- The CLI binary version is defined in `src/version.zig`.
- The root npm package version in `package.json` must match `src/version.zig`.
- Release tags must use the same version with a leading `v`.
  - Example: `src/version.zig = 0.2.2-alpha.1`
  - Matching tag: `v0.2.2-alpha.1`

## Manual Release Checklist

1. Sync `main` and confirm CI is green before changing any versioned file.
   - Run `git fetch origin main --tags`.
   - Run `git switch main`.
   - Run `git pull --ff-only origin main`.
   - Confirm the latest completed `CI` run for `main` succeeded. If the latest `CI` run failed or is still in progress, stop and do not cut a release yet.
2. Decide the next version.
   - For a stable release, require the requester to provide the exact version. Do not infer stable versions automatically.
   - For a prerelease or test release, inspect the latest reachable release tag from `main`.
   - If the latest reachable tag is a stable tag such as `v0.2.2`, bump the patch version and start a new alpha line: `0.2.3-alpha.1`.
   - If the latest reachable tag is already an alpha prerelease such as `v0.2.3-alpha.1`, keep the same core version and bump the alpha suffix: `0.2.3-alpha.2`.
3. Update the local version files.
   - Update `src/version.zig`.
   - Update `package.json`.
   - Update every platform package version under `package.json.optionalDependencies` to the same version.
4. Validate the version change before committing.
   - Keep the version values aligned across `src/version.zig`, `package.json`, and the release tag you intend to create.
   - Run `npm run check:versions`.
   - Because `src/version.zig` changes, run `zig build run -- list` before release.
   - Host packaging smoke is Linux x64 only because it installs the `@loongphy/codex-auth-linux-x64` package. If your local host is not Linux x64, run this validation in Linux or rely on CI.
   - Run side-effecting packaging validation from an isolated directory under `/tmp/<task-name>` with `HOME=/tmp/<task-name>`.
   - Build the host release binary with `zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe`.
   - Create the host artifact tree:
     - `mkdir -p /tmp/<task-name>/artifacts/linux-x64/binary`
     - `cp zig-out/bin/codex-auth /tmp/<task-name>/artifacts/linux-x64/binary/codex-auth`
   - Run `npm run check:release-host -- --artifacts-dir /tmp/<task-name>/artifacts --output-dir /tmp/<task-name>/dist/npm --packed-dir /tmp/<task-name>/dist/packed --smoke-dir /tmp/<task-name>/dist/smoke`.
   - Run `npm run check:release-hygiene` before publishing any repo snapshot or release artifact.
   - For desktop Linux packages, run `npm run desktop:linux:package` on Linux.
   - For the Windows desktop installer, run `npm run desktop:windows:package` on Windows.
5. Commit and push `main`.
   - Commit with a release message such as `chore: release v0.2.3-alpha.1`.
   - Push the commit to `origin/main`.
6. Wait for the post-push `CI` run for that exact `main` commit.
   - Do not create the release tag until the latest `CI` run for the pushed release commit succeeds.
   - If that `CI` run fails or terminates unexpectedly before any release tag is pushed, fix the problem and push a new commit that keeps the same target version.
   - Re-run the validation steps, push `main`, and wait for `CI` again.
7. Create and push the release tag.
   - Create an annotated tag named `v<version>`.
   - Push that tag to `origin`.
   - The tag push triggers the release workflow in `.github/workflows/release.yml`.
   - After a release tag has been pushed, do not reuse that version number. If the tag-driven release workflow later fails and you need another attempt, prepare and publish a new version instead.

## npm Package Layout

- npm distribution uses one root package plus five platform packages.
- Root package: `@loongphy/codex-auth`
- Platform packages:
  - `@loongphy/codex-auth-linux-x64`
  - `@loongphy/codex-auth-darwin-x64`
  - `@loongphy/codex-auth-darwin-arm64`
  - `@loongphy/codex-auth-win32-x64`
  - `@loongphy/codex-auth-win32-arm64`
- The root package exposes the `codex-auth` command and depends on the platform packages through `optionalDependencies`.
- Each platform package declares `os` and `cpu`, so npm installs only the matching binary package for the current host platform.
- GitHub Release assets and npm packages currently target Linux x64, macOS x64, macOS ARM64, Windows x64, and Windows ARM64.
- Windows builds include both `codex-auth.exe` and `codex-auth-auto.exe`; the helper is used only by the managed auto-switch task.

## Desktop Package Layout

- Desktop app source lives under `apps/codex-auth-desktop`.
- Linux desktop release artifacts are `.rpm` and `.AppImage`.
- Windows desktop release artifact is an unsigned Windows 10 x64 NSIS `.exe` installer.
- Desktop packages bundle the matching `codex-auth` CLI binary under the app resource `bin/` directory.
- Desktop packages must not include developer data from `~/.codex`, `~/.local/share/io.loongphy.codexauthstudio`, or `~/.local/opt/codex-auth-studio`.

## CI Workflow

- Branch and pull request validation runs in `.github/workflows/ci.yml`.
- The `build-test` matrix runs on `ubuntu-latest`, `macos-latest`, and `windows-latest`.
- CI installs Zig `0.15.1` and runs `zig test src/main.zig -lc`.
- CI runs `check:release-hygiene` to block tracked local auth files and obvious token literals.
- CI also runs a Linux-only `package-host-smoke` job on `ubuntu-latest`.
- That job builds the Linux x64 release binary, stages a temporary `artifacts/linux-x64/binary/codex-auth` tree, and runs `npm run check:release-host`.
- The host smoke job validates version checks, npm staging, tarball packing, and smoke installation of the root package plus the Linux x64 package.
- CI runs desktop checks on Linux and Windows, including bundled CLI staging for each host.
- CI host smoke does not replace the full cross-platform packaging checks in preview and tag release workflows.

## Preview Packages for Pull Requests

- Pull request preview npm packages are published by `.github/workflows/preview-release.yml`.
- The workflow cross-builds the five platform binaries on Ubuntu and stages the same six npm package directories used by the tag release pipeline.
- The staged root preview package has its `optionalDependencies` rewritten to deterministic `pkg.pr.new` platform package URLs for the PR head SHA.
- Preview publishing then runs a single `pkg.pr.new` publish command across the root package and all five platform packages, so the preview install command keeps the same platform-selective behavior as the real npm release.
- The staged preview root package also gets a `codexAuthPreviewLabel` field like `pr-6 b6bfcf5`.
- The root CLI wrapper uses that field so `codex-auth --version` prints `codex-auth <version> (preview pr-6 b6bfcf5)` for preview installs only.
- `.github/workflows/preview-release.yml` uses `actions/setup-node@v6` with `node-version: lts/*` so preview publishing tracks the latest Node LTS line automatically.
- `pkg.pr.new` preview publishing requires the pkg.pr.new GitHub App to be installed on the repository before the workflow can publish previews or comment on PRs.

## Tag Release Workflow

- Tag pushes matching `v*` run `.github/workflows/release.yml`.
- The release workflow first validates the code with the same `build-test` matrix used by CI.
- It then cross-builds release assets for the five supported targets on Ubuntu.
- It builds desktop `.rpm` and AppImage artifacts on Ubuntu and the Windows x64 NSIS installer on Windows.
- The `publish-npm` job reuses `npm run check:release-host` with the downloaded release artifacts before any npm publish step.
- The GitHub Release includes CLI archives plus desktop `.rpm`, `.AppImage`, and `.exe` artifacts.
- Release notes are generated from git tags and commit history.
- GitHub releases are published automatically from the tag pipeline.
- Stable tags create normal GitHub releases.
- Prerelease tags such as `v0.2.0-rc.1`, `v0.2.0-beta.1`, and `v0.2.0-alpha.1` create GitHub releases marked as prereleases, not drafts.

## npm Publish Rules

- npm publishing is handled by the `publish-npm` job in `.github/workflows/release.yml`.
- npm publishing uses Trusted Publishing from GitHub Actions, so the publish job must run on a GitHub-hosted runner with `id-token: write`.
- `.github/workflows/release.yml` uses `actions/setup-node@v6` with Node `24` for the npm packaging and publish steps so the bundled npm CLI supports Trusted Publishing.
- The `setup-node` steps in `.github/workflows/release.yml` explicitly set `package-manager-cache: false` to avoid future automatic npm cache behavior changes in the release pipeline.
- npm provenance validation requires the package `repository.url` metadata to match the GitHub repository URL exactly: `https://github.com/Loongphy/codex-auth`
- Stable tags such as `v0.1.3` publish to npm dist-tag `latest`.
- Prerelease tags such as `v0.2.0-rc.1`, `v0.2.0-beta.1`, and `v0.2.0-alpha.1` publish to npm dist-tag `next`.
