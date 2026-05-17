import {
  appRoot,
  ensureWindows,
  findWindowsPackageArtifact,
  run,
  stageBundledCli,
  verifyWindowsPackageArtifact,
} from "./linux-common.mjs";

try {
  ensureWindows();
  run("node", ["scripts/check-windows.mjs"], { cwd: appRoot });
  await stageBundledCli({ platform: "win32" });
  run("npm", ["run", "tauri:build", "--", "--bundles", "nsis"], { cwd: appRoot });
  const installerPath = await findWindowsPackageArtifact();
  await verifyWindowsPackageArtifact(installerPath);
  console.log(`Windows desktop installer verified at ${installerPath}`);
} catch (error) {
  console.error(`Windows desktop package failed: ${error.message}`);
  process.exit(1);
}
