import { rm } from "node:fs/promises";
import { linuxInstallRoot, linuxLauncherPath } from "./linux-common.mjs";

try {
  await rm(linuxLauncherPath, { force: true });
  await rm(linuxInstallRoot, { recursive: true, force: true });
  console.log("Removed the local Linux Codex Auth Studio install.");
} catch (error) {
  console.error(`Linux desktop uninstall failed: ${error.message}`);
  process.exit(1);
}
