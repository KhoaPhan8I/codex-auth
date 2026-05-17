import { spawn } from "node:child_process";
import { access } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const appRoot = path.resolve(here, "..");
const binaryName = process.platform === "win32" ? "codex-auth-desktop.exe" : "codex-auth-desktop";
const binaryPath = path.join(appRoot, "src-tauri", "target", "debug", binaryName);

if (process.platform === "linux" && !process.env.DISPLAY && !process.env.WAYLAND_DISPLAY) {
  console.error("Desktop run failed: no graphical Linux session detected.");
  console.error("Open a desktop session first, then rerun `npm run desktop:run`.");
  process.exit(1);
}

try {
  await access(binaryPath);
} catch {
  console.error(`Desktop run failed: missing debug binary at ${binaryPath}`);
  console.error("Build it first with `npm run desktop:audit` from the repo root,");
  console.error("or `npm run tauri:build -- --debug --no-bundle` inside apps/codex-auth-desktop.");
  process.exit(1);
}

const child = spawn(binaryPath, {
  cwd: appRoot,
  env: process.env,
  stdio: "inherit",
});

child.once("error", (error) => {
  console.error(`Desktop run failed: ${error.message}`);
  process.exit(1);
});

child.once("exit", (code, signal) => {
  if (signal) {
    process.exit(1);
  }
  process.exit(code ?? 0);
});
