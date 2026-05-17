import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import {
  ensureDir,
  platformPackages,
  readRootPackage,
  repoRoot
} from "./metadata.mjs";

const hostPackage = platformPackages.find((pkg) => pkg.id === "linux-x64");

function fail(message) {
  console.error(message);
  process.exit(1);
}

function parseArgs(argv) {
  const options = {
    artifactsDir: path.resolve("artifacts"),
    outputDir: path.resolve("dist", "npm"),
    packedDir: path.resolve("dist", "packed"),
    smokeDir: path.resolve("dist", "smoke"),
    stagePlatformIds: [hostPackage?.id ?? "linux-x64"],
    tag: ""
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const nextValue = argv[i + 1];
    if ((arg === "--artifacts-dir" || arg === "--output-dir" || arg === "--packed-dir" || arg === "--smoke-dir" || arg === "--stage-platform" || arg === "--tag") && nextValue === undefined) {
      throw new Error(`Missing value for ${arg}`);
    }

    if (arg === "--artifacts-dir") {
      options.artifactsDir = path.resolve(nextValue);
      i += 1;
    } else if (arg === "--output-dir") {
      options.outputDir = path.resolve(nextValue);
      i += 1;
    } else if (arg === "--packed-dir") {
      options.packedDir = path.resolve(nextValue);
      i += 1;
    } else if (arg === "--smoke-dir") {
      options.smokeDir = path.resolve(nextValue);
      i += 1;
    } else if (arg === "--stage-platform") {
      options.stagePlatformIds.push(nextValue);
      i += 1;
    } else if (arg === "--tag") {
      options.tag = nextValue;
      i += 1;
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  options.stagePlatformIds = Array.from(new Set(options.stagePlatformIds));
  return options;
}

function npmCommand() {
  return process.platform === "win32" ? "npm.cmd" : "npm";
}

function formatCommand(command, args) {
  return [command, ...args].join(" ");
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? repoRoot,
    env: process.env,
    stdio: options.capture ? ["ignore", "pipe", "pipe"] : "inherit",
    encoding: options.capture ? "utf8" : undefined
  });

  if (options.capture) {
    if (result.stdout) process.stdout.write(result.stdout);
    if (result.stderr) process.stderr.write(result.stderr);
  }

  if (result.error) {
    fail(`Failed to run ${formatCommand(command, args)}: ${result.error.message}`);
  }

  if (result.status !== 0) {
    fail(`Command failed (${result.status}): ${formatCommand(command, args)}`);
  }

  return result;
}

function pack(packageDir, packedDir) {
  ensureDir(packedDir);
  const result = run(npmCommand(), ["pack", packageDir, "--pack-destination", packedDir], { capture: true });
  const tarballName = result.stdout
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .at(-1);

  if (!tarballName) {
    fail(`Unable to determine tarball name from npm pack output for ${packageDir}`);
  }

  return path.join(packedDir, tarballName);
}

function writeSmokePackage(smokeDir) {
  ensureDir(smokeDir);
  fs.writeFileSync(
    path.join(smokeDir, "package.json"),
    `${JSON.stringify({ name: "codex-auth-release-host-smoke", private: true }, null, 2)}\n`
  );
}

if (!hostPackage) {
  fail("Missing linux-x64 package metadata");
}

if (process.platform !== "linux" || process.arch !== "x64") {
  fail("Host packaging smoke requires a linux x64 host because it installs the linux-x64 package.");
}

const options = parseArgs(process.argv.slice(2));
const rootPackage = readRootPackage();
const checkVersionsScript = path.join(repoRoot, "scripts", "npm", "check-versions.mjs");
const stagePackagesScript = path.join(repoRoot, "scripts", "npm", "stage-packages.mjs");

run(process.execPath, [checkVersionsScript, options.tag]);

const stageArgs = [stagePackagesScript, "--artifacts-dir", options.artifactsDir, "--output-dir", options.outputDir];
for (const platformId of options.stagePlatformIds) {
  stageArgs.push("--platform", platformId);
}
run(process.execPath, stageArgs);

fs.rmSync(options.packedDir, { recursive: true, force: true });
fs.rmSync(options.smokeDir, { recursive: true, force: true });

const rootTarball = pack(path.join(options.outputDir, "root"), options.packedDir);
const hostTarball = pack(path.join(options.outputDir, hostPackage.packageDirName), options.packedDir);

writeSmokePackage(options.smokeDir);
run(npmCommand(), ["install", "--no-package-lock", rootTarball, hostTarball], { cwd: options.smokeDir });
run(path.join(options.smokeDir, "node_modules", ".bin", "codex-auth"), ["--version"], { cwd: options.smokeDir });

console.log(`Host release smoke passed for ${rootPackage.version}`);
