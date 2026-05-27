import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const manifestPath = path.join(root, 'manifest.json');
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));

const errors = [];
const expectedMatches = new Set([
  'https://read.amazon.co.jp/*',
  'https://read.kindle.co.jp/*',
  'https://comic.naver.com/*',
  'https://m.comic.naver.com/*',
]);

function fail(message) {
  errors.push(message);
}

if (manifest.manifest_version !== 3) fail('manifest_version must be 3');
if (!manifest.background?.service_worker) fail('background service_worker is required');
if (manifest.background?.type !== 'module') fail('background service_worker should be a module');
if (!Array.isArray(manifest.content_scripts) || manifest.content_scripts.length !== 1) {
  fail('exactly one bootstrap content script declaration is expected');
}

const contentScript = manifest.content_scripts?.[0];
if (contentScript) {
  for (const match of expectedMatches) {
    if (!contentScript.matches?.includes(match)) fail(`missing content script match: ${match}`);
  }
  for (const match of contentScript.matches ?? []) {
    if (!expectedMatches.has(match)) fail(`unexpected content script match: ${match}`);
  }
}

const forbiddenPermissions = new Set(['tabs', 'webRequest', 'webRequestBlocking', '<all_urls>']);
for (const permission of manifest.permissions ?? []) {
  if (forbiddenPermissions.has(permission)) fail(`forbidden permission: ${permission}`);
}
for (const resource of manifest.web_accessible_resources ?? []) {
  if (resource.resources?.includes('*')) fail('web_accessible_resources must not expose *');
}

const requiredFiles = [
  manifest.background.service_worker,
  manifest.options_page,
  ...(contentScript?.js ?? []),
];
for (const rel of requiredFiles) {
  if (!fs.existsSync(path.join(root, rel))) fail(`referenced file does not exist: ${rel}`);
}

if (errors.length) {
  console.error(errors.map((error) => `- ${error}`).join('\n'));
  process.exit(1);
}

console.log('Extension manifest validation passed.');
