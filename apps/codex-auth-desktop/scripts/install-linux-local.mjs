import { chmod, copyFile, mkdir, rm } from "node:fs/promises";
import path from "node:path";
import {
  appRoot,
  assertFileExists,
  bundledCliPath,
  linuxInstallBinaryPath,
  linuxInstallBundledCliPath,
  linuxInstallIconPath,
  linuxInstallRoot,
  linuxLauncherPath,
  releaseDesktopBinaryPath,
  run,
  smokeLaunch,
  sourceIconPath,
  stageBundledCli,
  verifyLinuxLauncher,
  writeLinuxLauncher,
} from "./linux-common.mjs";

try {
  run("node", ["scripts/check-linux.mjs"], { cwd: appRoot });
  await stageBundledCli();
  run("npm", ["run", "tauri:build", "--", "--no-bundle"], { cwd: appRoot });

  await assertFileExists(releaseDesktopBinaryPath);
  await assertFileExists(bundledCliPath);
  await assertFileExists(sourceIconPath);

  await rm(linuxInstallRoot, { recursive: true, force: true });
  await mkdir(path.dirname(linuxInstallBinaryPath), { recursive: true });
  await mkdir(path.dirname(linuxInstallBundledCliPath), { recursive: true });
  await mkdir(path.dirname(linuxInstallIconPath), { recursive: true });

  await copyFile(releaseDesktopBinaryPath, linuxInstallBinaryPath);
  await copyFile(bundledCliPath, linuxInstallBundledCliPath);
  await copyFile(sourceIconPath, linuxInstallIconPath);
  await chmod(linuxInstallBinaryPath, 0o755);
  await chmod(linuxInstallBundledCliPath, 0o755);

  await writeLinuxLauncher();
  await verifyLinuxLauncher();

  await smokeLaunch(linuxInstallBinaryPath, {
    cwd: linuxInstallRoot,
    durationMs: 5000,
    pathEnv: "/usr/bin:/bin",
  });

  console.log(`Installed Codex Auth Studio to ${linuxInstallRoot}`);
  console.log(`Desktop launcher written to ${linuxLauncherPath}`);
} catch (error) {
  console.error(`Linux desktop install failed: ${error.message}`);
  process.exit(1);
}
