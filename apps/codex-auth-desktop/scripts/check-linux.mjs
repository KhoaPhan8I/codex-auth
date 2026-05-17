import { appRoot, ensureLinux, run, stageBundledCli } from "./linux-common.mjs";

try {
  ensureLinux();
  await stageBundledCli();
  run("npm", ["run", "check"], { cwd: appRoot });
  run("npm", ["run", "tauri:build", "--", "--debug", "--no-bundle"], { cwd: appRoot });
  run("node", ["scripts/smoke-debug.mjs"], { cwd: appRoot });
  console.log("Linux desktop check passed.");
} catch (error) {
  console.error(`Linux desktop check failed: ${error.message}`);
  process.exit(1);
}
