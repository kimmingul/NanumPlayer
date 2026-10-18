// Internal link checker for the built site (run `npm run build` first).
// Verifies that every internal href/src in dist/ points to an existing file, and that every #fragment
// exists as an id in the target page. External (http/https/mailto) links are not fetched.
import { readdirSync, readFileSync, statSync, existsSync } from 'node:fs';
import { join, posix, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../dist/', import.meta.url));
const BASE = '/NanumPlayer/';

function* walk(dir) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) yield* walk(p);
    else yield p;
  }
}

const htmlFiles = [...walk(root)].filter((p) => p.endsWith('.html'));
const idCache = new Map();
const idsOf = (file) => {
  if (!idCache.has(file)) {
    const html = readFileSync(file, 'utf8');
    idCache.set(file, new Set([...html.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1])));
  }
  return idCache.get(file);
};

const toUrl = (file) => '/' + relative(root, file).split(sep).join('/');
const problems = [];
let checked = 0;

for (const file of htmlFiles) {
  // The 404 page is served for any missing URL; its canonical/hreflang URLs point at routes that do not exist.
  if (/[\\/]404(\.html|[\\/]index\.html)$/.test(file)) continue;
  const html = readFileSync(file, 'utf8');
  const pageUrl = BASE.slice(0, -1) + toUrl(file).replace(/index\.html$/, '');
  // meta content="..." is only checked when it is a URL on our own origin (og:image, og:url, ...).
  const attrs = [
    ...[...html.matchAll(/\s(?:href|src)="([^"]*)"/g)].map((m) => m[1]),
    ...[...html.matchAll(/\scontent="(https:\/\/kimmingul\.github\.io\/[^"]*)"/g)].map((m) => m[1]),
  ];
  const srcsets = [...html.matchAll(/\ssrcset="([^"]*)"/g)].flatMap((m) =>
    m[1].split(',').map((s) => s.trim().split(/\s+/)[0]),
  );
  for (let ref of [...attrs, ...srcsets]) {
    ref = ref.replaceAll('&#38;', '&').replaceAll('&amp;', '&');
    if (!ref || /^(https?:|mailto:|tel:|data:|javascript:)/.test(ref)) {
      // Absolute URLs on our own origin are checked too.
      const own = ref.match(/^https:\/\/kimmingul\.github\.io(\/NanumPlayer\/[^\s]*)$/);
      if (!own) continue;
      ref = own[1];
    } else if (!(ref.startsWith('/') || ref.startsWith('#') || ref.startsWith('.') || /^[\w-]+[/.]/.test(ref))) {
      continue; // plain text content attribute (e.g. meta description)
    }
    if (ref.startsWith('//')) continue;
    const [pathPart, fragment] = ref.split('#');
    let target;
    if (pathPart === '') target = pageUrl;
    else if (pathPart.startsWith('/')) target = pathPart;
    else target = posix.resolve(pageUrl, pathPart) + (pathPart.endsWith('/') ? '/' : '');
    if (!target.startsWith(BASE)) {
      if (pathPart.startsWith('/')) problems.push(`${toUrl(file)}: link outside base path: ${ref}`);
      continue;
    }
    target = decodeURI(target.split('?')[0]);
    const rel = target.slice(BASE.length);
    let candidate = join(root, rel);
    if (target.endsWith('/')) candidate = join(candidate, 'index.html');
    checked++;
    if (!existsSync(candidate) || statSync(candidate).isDirectory()) {
      problems.push(`${toUrl(file)}: missing target ${ref}`);
      continue;
    }
    if (fragment && candidate.endsWith('.html')) {
      const id = decodeURIComponent(fragment);
      if (!idsOf(candidate).has(id)) problems.push(`${toUrl(file)}: missing anchor ${ref}`);
    }
  }
}

console.log(`Checked ${checked} internal references in ${htmlFiles.length} pages.`);
if (problems.length) {
  console.error(`${problems.length} problem(s):`);
  for (const p of [...new Set(problems)]) console.error('  ' + p);
  process.exit(1);
}
console.log('No broken internal links.');
