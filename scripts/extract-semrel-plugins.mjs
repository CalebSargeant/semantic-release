// Print the npm package names of every plugin declared in the consumer's
// semantic-release configuration, one per line, to stdout.
//
// semantic-release resolves plugins relative to its own install location, so
// any non-bundled plugin a consumer configures (e.g. @semantic-release/changelog,
// @semantic-release/git) must be installed into the SAME node_modules as
// semantic-release itself. This script lets the installer derive that plugin
// set from config instead of relying on a hard-coded list that drifts.
//
// Config discovery mirrors semantic-release/cosmiconfig for the JSON-shaped
// sources we can parse statically: the "release" key in package.json, plus
// `.releaserc` and `.releaserc.json`. YAML/JS configs are skipped here — the
// installer still ships a baseline plugin set that covers the common cases.
//
// Run from the consumer's working directory: `node extract-semrel-plugins.mjs`.
import { readFileSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';

const cwd = process.cwd();

/** Pull the package name out of each `plugins` entry (string or [name, opts]). */
function pluginsFrom(config) {
  if (!config || !Array.isArray(config.plugins)) return [];
  return config.plugins
    .map((entry) => (Array.isArray(entry) ? entry[0] : entry))
    .filter((name) => typeof name === 'string');
}

/**
 * Pull shareable-config names out of `extends` (a string or an array).
 *
 * `extends` needs installing for exactly the same reason `plugins` does, and
 * missing it has one specific consequence: `semantic-release-monorepo` — the
 * standard way to scope an npm release to one package of a repo — is consumed
 * as `"extends": "semantic-release-monorepo"` and never appears under
 * `plugins`. Without this it is never installed, and the run dies with
 * MODULE_NOT_FOUND at config load, before any release logic executes.
 */
function extendsFrom(config) {
  if (!config || !config.extends) return [];
  const raw = Array.isArray(config.extends) ? config.extends : [config.extends];
  return raw.filter((name) => typeof name === 'string');
}

function parseJsonFile(path) {
  try {
    if (!existsSync(path)) return null;
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch {
    // Non-JSON (.releaserc may be YAML) or malformed — ignore and fall back
    // to the installer's baseline set.
    return null;
  }
}

const names = new Set();

// package.json "release" key.
const pkg = parseJsonFile(resolve(cwd, 'package.json'));
if (pkg) for (const name of [...pluginsFrom(pkg.release), ...extendsFrom(pkg.release)]) names.add(name);

// Dedicated config files, in cosmiconfig precedence order.
for (const file of ['.releaserc', '.releaserc.json']) {
  const cfg = parseJsonFile(resolve(cwd, file));
  if (cfg) for (const name of [...pluginsFrom(cfg), ...extendsFrom(cfg)]) names.add(name);
}

for (const name of names) {
  // Only emit real npm package names; skip local plugin paths, which are
  // resolved from disk and must not be passed to `npm install`.
  if (name.startsWith('.') || name.startsWith('/')) continue;
  console.log(name);
}
