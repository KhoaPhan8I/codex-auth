import { spawnSync, spawn } from "node:child_process";
import {
  access,
  chmod,
  copyFile,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
export const appRoot = path.resolve(here, "..");
export const repoRoot = path.resolve(appRoot, "..", "..");
export const srcTauriRoot = path.join(appRoot, "src-tauri");
export const bundledResourcesRoot = path.join(srcTauriRoot, "resources");
export const bundledCliDir = path.join(bundledResourcesRoot, "bin");
export const bundledCliPath = path.join(
  bundledCliDir,
  process.platform === "win32" ? "codex-auth.exe" : "codex-auth",
);
export const bundledCliAutoPath = path.join(bundledCliDir, "codex-auth-auto.exe");
export const linuxBundledResourceDirName = "Codex Auth Studio";
export const releaseDesktopBinaryPath = path.join(
  srcTauriRoot,
  "target",
  "release",
  desktopBinaryName(),
);
export const debugDesktopBinaryPath = path.join(
  srcTauriRoot,
  "target",
  "debug",
  desktopBinaryName(),
);
export const debBundleDir = path.join(srcTauriRoot, "target", "release", "bundle", "deb");
export const rpmBundleDir = path.join(srcTauriRoot, "target", "release", "bundle", "rpm");
export const appImageBundleDir = path.join(
  srcTauriRoot,
  "target",
  "release",
  "bundle",
  "appimage",
);
export const nsisBundleDir = path.join(srcTauriRoot, "target", "release", "bundle", "nsis");
export const linuxInstallRoot = path.join(os.homedir(), ".local", "opt", "codex-auth-studio");
export const linuxInstallBinaryPath = path.join(linuxInstallRoot, "bin", "codex-auth-desktop");
export const linuxInstallBundledCliPath = path.join(
  linuxInstallRoot,
  "lib",
  linuxBundledResourceDirName,
  "bin",
  "codex-auth",
);
export const linuxInstallIconPath = path.join(
  linuxInstallRoot,
  "share",
  "icons",
  "codex-auth-studio.png",
);
export const linuxLauncherPath = path.join(
  os.homedir(),
  ".local",
  "share",
  "applications",
  "io.loongphy.codexauthstudio.desktop",
);
export const sourceIconPath = path.join(srcTauriRoot, "icons", "128x128.png");

export function ensureLinux() {
  if (process.platform !== "linux") {
    throw new Error("This Linux desktop flow only supports Linux.");
  }
}

export function ensureWindows() {
  if (process.platform !== "win32") {
    throw new Error("This Windows desktop flow only supports Windows.");
  }
}

export function ensureGraphicalSession() {
  if (!process.env.DISPLAY && !process.env.WAYLAND_DISPLAY) {
    throw new Error("No graphical Linux session detected.");
  }
}

export function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? repoRoot,
    env: options.env ?? process.env,
    stdio: options.stdio ?? "inherit",
    encoding: "utf8",
  });

  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    const rendered = [result.stdout, result.stderr].filter(Boolean).join("\n").trim();
    throw new Error(
      rendered || `\`${command} ${args.join(" ")}\` exited with status ${result.status}.`,
    );
  }
  return result;
}

export function desktopBinaryName(platform = process.platform) {
  return platform === "win32" ? "codex-auth-desktop.exe" : "codex-auth-desktop";
}

function bundledCliBuildSpec(platform = process.platform) {
  if (platform === "linux") {
    return {
      zigTarget: "x86_64-linux-gnu",
      primaryBinary: "codex-auth",
      binaryFiles: ["codex-auth"],
      executableMode: 0o755,
    };
  }
  if (platform === "win32") {
    return {
      zigTarget: "x86_64-windows-gnu",
      primaryBinary: "codex-auth.exe",
      binaryFiles: ["codex-auth.exe", "codex-auth-auto.exe"],
      executableMode: undefined,
    };
  }
  throw new Error(`Bundled desktop CLI staging is not supported on ${platform}.`);
}

export async function stageBundledCli(options = {}) {
  const platform = options.platform ?? process.platform;
  const spec = bundledCliBuildSpec(platform);
  const zigBinary = await resolveZigBinary();
  run(zigBinary, ["build", `-Dtarget=${spec.zigTarget}`, "-Doptimize=ReleaseSafe"], {
    cwd: repoRoot,
  });

  await rm(bundledCliDir, { recursive: true, force: true });
  await mkdir(bundledCliDir, { recursive: true });

  for (const binaryFile of spec.binaryFiles) {
    const sourcePath = path.join(repoRoot, "zig-out", "bin", binaryFile);
    const destinationPath = path.join(bundledCliDir, binaryFile);
    await access(sourcePath);
    await copyFile(sourcePath, destinationPath);
    if (spec.executableMode !== undefined) {
      await chmod(destinationPath, spec.executableMode);
    }
  }

  return path.join(bundledCliDir, spec.primaryBinary);
}

export async function assertFileExists(targetPath) {
  await access(targetPath);
  return targetPath;
}

export async function findDebArtifact() {
  return findNewestArtifact(debBundleDir, (entry) => entry.endsWith(".deb"), ".deb");
}

export async function findLinuxPackageArtifacts() {
  return {
    rpm: await findNewestArtifact(rpmBundleDir, (entry) => entry.endsWith(".rpm"), ".rpm"),
    appImage: await findNewestArtifact(
      appImageBundleDir,
      (entry) => entry.endsWith(".AppImage") || entry.endsWith(".appimage"),
      ".AppImage",
    ),
  };
}

export async function findWindowsPackageArtifact() {
  return findNewestArtifact(
    nsisBundleDir,
    (entry) => entry.endsWith(".exe") && !entry.endsWith("-setup.nsis.exe"),
    "NSIS .exe",
  );
}

async function findNewestArtifact(directory, predicate, label) {
  const entries = await readdirSafe(directory);
  const artifacts = entries.filter(predicate).map((entry) => path.join(directory, entry));
  if (artifacts.length === 0) {
    throw new Error(`No ${label} artifact found in ${directory}`);
  }

  const stats = await Promise.all(
    artifacts.map(async (artifactPath) => ({
      artifactPath,
      mtimeMs: (await stat(artifactPath)).mtimeMs,
    })),
  );
  stats.sort((left, right) => right.mtimeMs - left.mtimeMs);
  return stats[0].artifactPath;
}

export async function verifyDebArtifact(debPath) {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), "codex-auth-desktop-deb-"));
  try {
    run("ar", ["x", debPath], { cwd: tempRoot });
    const dataTarPath = path.join(tempRoot, "data.tar.gz");
    const listResult = run("tar", ["-tzf", dataTarPath], {
      cwd: tempRoot,
      stdio: "pipe",
    });
    const members = listResult.stdout
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean);

    const expectedMembers = [
      "usr/bin/codex-auth-desktop",
      `usr/lib/${linuxBundledResourceDirName}/bin/codex-auth`,
      "usr/share/applications/Codex Auth Studio.desktop",
    ];
    for (const member of expectedMembers) {
      if (!members.includes(member)) {
        throw new Error(`Deb artifact is missing ${member}`);
      }
    }
    if (!members.some((member) => member.endsWith("/apps/codex-auth-desktop.png"))) {
      throw new Error("Deb artifact is missing the desktop icon.");
    }
  } finally {
    await rm(tempRoot, { recursive: true, force: true });
  }
}

export async function verifyLinuxPackageArtifacts(artifacts) {
  await assertNonEmptyArtifact(artifacts.rpm, ".rpm");
  await assertNonEmptyArtifact(artifacts.appImage, ".AppImage");
}

export async function verifyWindowsPackageArtifact(artifactPath) {
  await assertNonEmptyArtifact(artifactPath, "NSIS .exe");
}

async function assertNonEmptyArtifact(artifactPath, label) {
  await assertFileExists(artifactPath);
  const artifactStat = await stat(artifactPath);
  if (artifactStat.size <= 1024) {
    throw new Error(`${label} artifact is unexpectedly small: ${artifactPath}`);
  }
}

export async function writeLinuxLauncher() {
  await mkdir(path.dirname(linuxLauncherPath), { recursive: true });
  const desktopEntry = [
    "[Desktop Entry]",
    "Type=Application",
    "Version=1.0",
    "Name=Codex Auth Studio",
    "Comment=Local desktop controller for codex-auth",
    `Exec=${linuxInstallBinaryPath}`,
    `TryExec=${linuxInstallBinaryPath}`,
    `Icon=${linuxInstallIconPath}`,
    "Terminal=false",
    "Categories=Utility;Development;",
    "StartupNotify=true",
    "StartupWMClass=Codex Auth Studio",
    "",
  ].join("\n");
  await writeFile(linuxLauncherPath, desktopEntry, "utf8");
}

export async function verifyLinuxLauncher() {
  const launcher = await readFile(linuxLauncherPath, "utf8");
  if (!launcher.includes(`Exec=${linuxInstallBinaryPath}`)) {
    throw new Error("Linux launcher does not point to the installed binary.");
  }
  if (!launcher.includes(`Icon=${linuxInstallIconPath}`)) {
    throw new Error("Linux launcher does not point to the installed icon.");
  }
}

export async function smokeLaunch(binaryPath, options = {}) {
  ensureLinux();
  ensureGraphicalSession();
  await assertFileExists(binaryPath);

  await new Promise((resolve, reject) => {
    const env = {
      ...process.env,
      PATH: options.pathEnv ?? process.env.PATH ?? "",
      ...options.env,
    };
    const child = spawn(binaryPath, [], {
      cwd: options.cwd ?? appRoot,
      env,
      stdio: "ignore",
    });

    let exited = false;
    let survivedUntilTimeout = false;
    let killTimer = null;

    const finish = (callback) => {
      if (killTimer !== null) {
        clearTimeout(killTimer);
        killTimer = null;
      }
      callback();
    };

    child.once("error", (error) => {
      exited = true;
      finish(() => reject(error));
    });

    child.once("exit", (code, signal) => {
      exited = true;
      finish(() => {
        if (survivedUntilTimeout) {
          resolve();
          return;
        }
        if (signal) {
          reject(new Error(`Desktop app exited early due to signal ${signal}.`));
          return;
        }
        reject(new Error(`Desktop app exited too early with code ${code ?? 0}.`));
      });
    });

    killTimer = setTimeout(() => {
      if (exited) {
        return;
      }
      survivedUntilTimeout = true;
      child.kill("SIGTERM");
      setTimeout(() => {
        if (!exited) {
          child.kill("SIGKILL");
        }
      }, 1000);
    }, options.durationMs ?? 5000);
  });
}

async function readdirSafe(directory) {
  try {
    return await readdir(directory);
  } catch {
    return [];
  }
}

async function resolveZigBinary() {
  const candidates = [];
  if (process.env.ZIG) {
    candidates.push(process.env.ZIG);
  }
  const zigExe = process.platform === "win32" ? "zig.exe" : "zig";
  const pathValue = process.env.PATH ?? "";
  for (const segment of pathValue.split(path.delimiter)) {
    if (!segment) {
      continue;
    }
    candidates.push(path.join(segment, zigExe));
  }
  if (process.platform === "linux") {
    candidates.push(path.join(os.homedir(), ".local", "zig", "zig-x86_64-linux-0.15.1", "zig"));
    candidates.push(path.join(os.homedir(), ".cargo", "bin", "zig"));
    candidates.push("/usr/local/bin/zig");
    candidates.push("/usr/bin/zig");
  }

  for (const candidate of candidates) {
    try {
      await access(candidate);
      return candidate;
    } catch {
      // Try the next Zig path.
    }
  }

  throw new Error("Could not find Zig. Set ZIG=/full/path/to/zig or install Zig in a standard location.");
}
