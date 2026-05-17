import {
  appImageBundleDir,
  appRoot,
  ensureLinux,
  findLinuxPackageArtifacts,
  repoRoot,
  run,
  stageBundledCli,
  verifyLinuxPackageArtifacts,
} from "./linux-common.mjs";
import { access, readFile, readdir, rm, stat } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import process from "node:process";

try {
  ensureLinux();
  run("node", ["scripts/check-linux.mjs"], { cwd: appRoot });
  await stageBundledCli();

  run("npm", ["run", "tauri:build", "--", "--bundles", "rpm"], {
    cwd: appRoot,
  });
  try {
    run("npm", ["run", "tauri:build", "--", "--bundles", "appimage"], {
      cwd: appRoot,
      env: appImageBuildEnv(),
    });
  } catch (appImageError) {
    console.warn(`Tauri AppImage bundling failed: ${appImageError.message}`);
    console.warn("Retrying AppImage bundling directly from the generated AppDir.");
    await buildAppImageFromGeneratedAppDir();
  }

  const artifacts = await findLinuxPackageArtifacts();
  await verifyLinuxPackageArtifacts(artifacts);
  console.log(`Linux desktop RPM verified at ${artifacts.rpm}`);
  console.log(`Linux desktop AppImage verified at ${artifacts.appImage}`);
} catch (error) {
  console.error(`Linux desktop package failed: ${error.message}`);
  process.exit(1);
}

async function buildAppImageFromGeneratedAppDir() {
  const appDir = await findNewestAppDir();
  const linuxDeployPath = await findLinuxDeployAppImage();
  const outputPath = await expectedAppImagePath(appDir);
  const cacheDirs = tauriCacheDirs();

  await rm(outputPath, { force: true });
  run(linuxDeployPath, ["--appdir", appDir, "--output", "appimage"], {
    cwd: repoRoot,
    env: {
      ...appImageBuildEnv(),
      PATH: prependPath(cacheDirs),
      LDAI_OUTPUT: outputPath,
      OUTPUT: outputPath,
    },
  });

  await access(outputPath);
  return outputPath;
}

function appImageBuildEnv() {
  return {
    ...process.env,
    APPIMAGE_EXTRACT_AND_RUN: process.env.APPIMAGE_EXTRACT_AND_RUN ?? "1",
    NO_STRIP: process.env.NO_STRIP ?? "1",
  };
}

async function findNewestAppDir() {
  const entries = await readdir(appImageBundleDir, { withFileTypes: true });
  const appDirs = entries
    .filter((entry) => entry.isDirectory() && entry.name.endsWith(".AppDir"))
    .map((entry) => path.join(appImageBundleDir, entry.name));
  if (appDirs.length === 0) {
    throw new Error(`No AppDir found in ${appImageBundleDir}`);
  }

  const stats = await Promise.all(
    appDirs.map(async (appDir) => ({
      appDir,
      mtimeMs: (await stat(appDir)).mtimeMs,
    })),
  );
  stats.sort((left, right) => right.mtimeMs - left.mtimeMs);
  return stats[0].appDir;
}

async function findLinuxDeployAppImage() {
  const candidates = [];
  if (process.env.LINUXDEPLOY) {
    candidates.push(process.env.LINUXDEPLOY);
  }
  for (const cacheDir of tauriCacheDirs()) {
    candidates.push(path.join(cacheDir, "linuxdeploy-x86_64.AppImage"));
    candidates.push(...(await linuxDeployCandidatesIn(cacheDir)));
  }

  for (const candidate of unique(candidates)) {
    try {
      await access(candidate);
      return candidate;
    } catch {
      // Try the next linuxdeploy path.
    }
  }

  throw new Error(
    "Could not find linuxdeploy. Run the Tauri AppImage build once or set LINUXDEPLOY=/full/path/to/linuxdeploy-x86_64.AppImage.",
  );
}

async function linuxDeployCandidatesIn(directory) {
  try {
    const entries = await readdir(directory);
    return entries
      .filter((entry) => entry.startsWith("linuxdeploy") && entry.endsWith(".AppImage"))
      .map((entry) => path.join(directory, entry));
  } catch {
    return [];
  }
}

async function expectedAppImagePath(appDir) {
  const configPath = path.join(appRoot, "src-tauri", "tauri.conf.json");
  const config = JSON.parse(await readFile(configPath, "utf8"));
  const productName = config.productName ?? path.basename(appDir, ".AppDir");
  const version = config.version ?? "0.0.0";
  return path.join(appImageBundleDir, `${productName}_${version}_${appImageArch()}.AppImage`);
}

function appImageArch() {
  if (process.arch === "x64") {
    return "amd64";
  }
  if (process.arch === "arm64") {
    return "aarch64";
  }
  return process.arch;
}

function tauriCacheDirs() {
  return unique([
    process.env.XDG_CACHE_HOME ? path.join(process.env.XDG_CACHE_HOME, "tauri") : undefined,
    path.join(os.homedir(), ".cache", "tauri"),
  ]);
}

function prependPath(paths) {
  return [...paths, process.env.PATH ?? ""].filter(Boolean).join(path.delimiter);
}

function unique(values) {
  return [...new Set(values.filter(Boolean))];
}
