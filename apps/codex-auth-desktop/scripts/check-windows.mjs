import { appRoot, ensureWindows, run, stageBundledCli } from "./linux-common.mjs";

try {
  ensureWindows();
  await stageBundledCli({ platform: "win32" });
  run("npm", ["run", "check"], { cwd: appRoot });
  run("npm", ["run", "tauri:build", "--", "--debug", "--no-bundle"], { cwd: appRoot });
  console.log("Windows desktop check passed.");
} catch (error) {
  console.error(`Windows desktop check failed: ${error.message}`);
  process.exit(1);
}
