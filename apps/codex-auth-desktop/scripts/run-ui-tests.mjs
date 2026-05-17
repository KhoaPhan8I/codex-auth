import { rm } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";

const here = path.dirname(fileURLToPath(import.meta.url));
const appRoot = path.resolve(here, "..");
const outDir = path.join(appRoot, ".ui-test-dist");

await rm(outDir, { recursive: true, force: true });
await runCommand("npx", ["tsc", "-p", "tsconfig.ui-tests.json"], appRoot);
await runCommand("node", ["--test", path.join(".ui-test-dist", "ui_logic.test.js")], appRoot);

async function runCommand(command, args, cwd) {
  await new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd,
      env: process.env,
      stdio: "inherit",
      shell: process.platform === "win32",
    });

    child.once("error", reject);
    child.once("exit", (code, signal) => {
      if (code === 0) {
        resolve(undefined);
        return;
      }
      reject(
        new Error(
          `Command failed: ${command} ${args.join(" ")} (code=${String(code)} signal=${String(signal)})`,
        ),
      );
    });
  });
}
