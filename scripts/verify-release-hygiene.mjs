import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const repoRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const extraPaths = parseArgs(process.argv.slice(2));

const sensitivePathPatterns = [
  { label: "Codex auth file", pattern: /(^|\/)auth\.json(?:\.|$)/ },
  { label: "Codex account snapshot", pattern: /(^|\/)[^/]+\.auth\.json(?:\.|$)/ },
  { label: "Codex account registry", pattern: /(^|\/)registry\.json(?:\.|$)/ },
  { label: "environment file", pattern: /(^|\/)\.env(?:\.|$)/ },
  { label: "local Codex home", pattern: /(^|\/)\.codex(?:\/|$)/ },
  {
    label: "Codex Auth Studio user data",
    pattern: /(^|\/)(?:\.local\/share\/)?io\.loongphy\.codexauthstudio(?:\/|$)/,
  },
];

const secretContentPatterns = [
  { label: "OpenAI API key", pattern: /sk-[A-Za-z0-9_-]{20,}/ },
  {
    label: "literal access token",
    pattern: /"access_token"\s*:\s*"[A-Za-z0-9._~+/=-]{40,}"/,
  },
  {
    label: "literal refresh token",
    pattern: /"refresh_token"\s*:\s*"[A-Za-z0-9._~+/=-]{40,}"/,
  },
  {
    label: "literal id token",
    pattern: /"id_token"\s*:\s*"eyJ[A-Za-z0-9._~+/=-]{40,}"/,
  },
  {
    label: "OPENAI_API_KEY assignment",
    pattern: /OPENAI_API_KEY\s*=\s*["']?(?!null\b|example\b|your_|YOUR_|<)[A-Za-z0-9._-]{20,}/i,
  },
];

const failures = [];
const sourceFiles = [...gitFiles(["ls-files", "-z"]), ...gitFiles(["ls-files", "--others", "--exclude-standard", "-z"])];
const filesToScan = new Set(sourceFiles);

for (const extraPath of extraPaths) {
  for (const filePath of collectFiles(extraPath)) {
    filesToScan.add(filePath);
  }
}

for (const filePath of filesToScan) {
  const relativePath = normalizeRelative(filePath);
  checkSensitivePath(relativePath);
  checkSensitiveContents(filePath, relativePath);
}

if (failures.length > 0) {
  console.error("Release hygiene check failed. Potentially sensitive files or literals were found:");
  for (const failure of failures) {
    console.error(`- ${failure}`);
  }
  process.exit(1);
}

console.log(`Release hygiene check passed for ${filesToScan.size} files.`);

function parseArgs(args) {
  const paths = [];
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (arg === "--path") {
      const value = args[i + 1];
      if (!value) {
        throw new Error("Missing value for --path");
      }
      paths.push(path.resolve(repoRoot, value));
      i += 1;
      continue;
    }
    throw new Error(`Unknown argument: ${arg}`);
  }
  return paths;
}

function gitFiles(args) {
  const result = spawnSync("git", args, {
    cwd: repoRoot,
    encoding: "buffer",
  });
  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    throw new Error(result.stderr.toString("utf8").trim() || "git ls-files failed");
  }
  return result.stdout
    .toString("utf8")
    .split("\0")
    .filter(Boolean)
    .map((filePath) => path.join(repoRoot, filePath));
}

function collectFiles(targetPath) {
  if (!fs.existsSync(targetPath)) {
    throw new Error(`Hygiene path does not exist: ${targetPath}`);
  }

  const stat = fs.statSync(targetPath);
  if (stat.isFile()) {
    return [targetPath];
  }
  if (!stat.isDirectory()) {
    return [];
  }

  const files = [];
  const stack = [targetPath];
  while (stack.length > 0) {
    const directory = stack.pop();
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const entryPath = path.join(directory, entry.name);
      if (entry.isDirectory()) {
        if (entry.name === ".git" || entry.name === "node_modules" || entry.name === "target") {
          continue;
        }
        stack.push(entryPath);
      } else if (entry.isFile()) {
        files.push(entryPath);
      }
    }
  }
  return files;
}

function normalizeRelative(filePath) {
  return path.relative(repoRoot, filePath).split(path.sep).join("/");
}

function checkSensitivePath(relativePath) {
  for (const { label, pattern } of sensitivePathPatterns) {
    if (pattern.test(relativePath)) {
      failures.push(`${relativePath}: ${label}`);
    }
  }
}

function checkSensitiveContents(filePath, relativePath) {
  let stat;
  try {
    stat = fs.statSync(filePath);
  } catch {
    return;
  }
  if (stat.size > 5 * 1024 * 1024) {
    return;
  }

  const data = fs.readFileSync(filePath);
  if (isProbablyBinary(data)) {
    return;
  }
  const text = data.toString("utf8");
  for (const { label, pattern } of secretContentPatterns) {
    if (pattern.test(text)) {
      failures.push(`${relativePath}: ${label}`);
    }
  }
}

function isProbablyBinary(buffer) {
  const limit = Math.min(buffer.length, 4096);
  for (let i = 0; i < limit; i += 1) {
    if (buffer[i] === 0) {
      return true;
    }
  }
  return false;
}
