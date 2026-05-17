import { bundledCliPath, stageBundledCli } from "./linux-common.mjs";

try {
  const stagedPath = await stageBundledCli();
  console.log(`Bundled codex-auth staged at ${stagedPath ?? bundledCliPath}`);
} catch (error) {
  console.error(`Failed to stage bundled codex-auth: ${error.message}`);
  process.exit(1);
}
