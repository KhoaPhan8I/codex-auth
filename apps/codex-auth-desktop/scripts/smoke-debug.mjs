import { spawn } from "node:child_process";
import { access } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const appRoot = path.resolve(here, "..");
const binaryName = process.platform === "win32" ? "codex-auth-desktop.exe" : "codex-auth-desktop";
const binaryPath = path.join(appRoot, "src-tauri", "target", "debug", binaryName);
const smokeMs = Number.parseInt(process.env.CODEX_AUTH_DESKTOP_SMOKE_MS ?? "5000", 10);

if (process.platform === "linux" && !process.env.DISPLAY && !process.env.WAYLAND_DISPLAY) {
  console.log("Skipping desktop smoke: no display session detected.");
  process.exit(0);
}

try {
  await access(binaryPath);
} catch {
  console.error(`Desktop smoke failed: missing debug binary at ${binaryPath}`);
  console.error("Run `npm run tauri:build -- --debug --no-bundle` first.");
  process.exit(1);
}

await runSmoke(binaryPath, smokeMs);

async function runSmoke(command, aliveMs) {
  let stdout = "";
  let stderr = "";
  let finished = false;

  const child = spawn(command, {
    cwd: appRoot,
    env: process.env,
    stdio: ["ignore", "pipe", "pipe"],
  });

  child.stdout?.setEncoding("utf8");
  child.stderr?.setEncoding("utf8");
  child.stdout?.on("data", (chunk) => {
    stdout += chunk;
  });
  child.stderr?.on("data", (chunk) => {
    stderr += chunk;
  });

  const outcome = await new Promise((resolve, reject) => {
    const aliveTimer = setTimeout(() => {
      finished = true;
      resolve({ kind: "alive" });
    }, aliveMs);

    child.once("error", (error) => {
      clearTimeout(aliveTimer);
      reject(error);
    });

    child.once("exit", (code, signal) => {
      clearTimeout(aliveTimer);
      if (finished) {
        return;
      }
      resolve({ kind: "exit", code, signal });
    });
  });

  if (outcome.kind === "alive") {
    await terminateChild(child);
    console.log(`Desktop smoke passed: app stayed alive for ${aliveMs}ms.`);
    return;
  }

  const details = [
    `Desktop smoke failed: app exited early with code=${String(outcome.code)} signal=${String(outcome.signal)}`,
    stdout.trim() ? `stdout:\n${stdout.trim()}` : "",
    stderr.trim() ? `stderr:\n${stderr.trim()}` : "",
  ]
    .filter(Boolean)
    .join("\n\n");
  throw new Error(details);
}

async function terminateChild(child) {
  if (hasExited(child)) {
    return;
  }

  child.kill("SIGTERM");
  const exited = await waitForExit(child, 2000);
  if (exited) {
    return;
  }

  child.kill("SIGKILL");
  const forceExited = await waitForExit(child, 2000);
  if (!forceExited) {
    throw new Error("Desktop smoke failed: app did not exit after SIGTERM/SIGKILL cleanup.");
  }
}

function waitForExit(child, timeoutMs) {
  return new Promise((resolve) => {
    if (hasExited(child)) {
      resolve(true);
      return;
    }

    const timer = setTimeout(() => {
      cleanup();
      resolve(false);
    }, timeoutMs);

    const onExit = () => {
      cleanup();
      resolve(true);
    };

    const cleanup = () => {
      clearTimeout(timer);
      child.removeListener("exit", onExit);
    };

    child.once("exit", onExit);
  });
}

function hasExited(child) {
  return child.exitCode !== null || child.signalCode !== null;
}
