import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { BADGE, appStoreURL, availabilityHTML, testFlightURL } from '../src/remote-availability.mjs';
const read = path => readFileSync(new URL(path, import.meta.url), 'utf8');

test('Side A Remote offers the TestFlight beta until remote.json names its App Store link', () => {
  const beta = availabilityHTML({ appStoreURL: null, testFlightURL: 'https://testflight.apple.com/join/ABC123' });
  assert.match(beta, /<a class="remote-beta" href="https:\/\/testflight\.apple\.com\/join\/ABC123" data-remote-beta>/);
  assert.match(beta, /Join the beta on TestFlight/, 'a beta, not a promise of instant access');
  assert.doesNotMatch(beta, /apps\.apple\.com|Coming soon/);
  const soon = availabilityHTML({ appStoreURL: null });
  assert.match(soon, /Coming soon to iPhone/);
  assert.doesNotMatch(soon, /<a |apps\.apple\.com/, 'links nowhere yet');
  const url = 'https://apps.apple.com/us/app/side-a-remote/id1234567890';
  const live = availabilityHTML({ appStoreURL: url, testFlightURL: 'https://testflight.apple.com/join/ABC123' });
  assert.match(live, new RegExp(`href="${url}"`));
  assert.match(live, new RegExp(`src="\\./${BADGE}"`));
  assert.match(live, /alt="Download on the App Store"/);
  assert.doesNotMatch(live, /Coming soon/);
});

test('only a real App Store app link turns the badge on', () => {
  for (const bad of ['', 'https://apps.apple.com/', 'http://apps.apple.com/us/app/x/id1', 'https://example.com/us/app/x/id1', 'https://apps.apple.com/us/app/x/id1"><script>', true]) {
    assert.throws(() => appStoreURL({ appStoreURL: bad }), /apps\.apple\.com/, String(bad));
  }
  assert.equal(appStoreURL({}), null);
  for (const bad of ['', 'https://testflight.apple.com/', 'http://testflight.apple.com/join/ABC', 'https://example.com/join/ABC', 'https://testflight.apple.com/join/A"><b>']) {
    assert.throws(() => testFlightURL({ testFlightURL: bad }), /testflight\.apple\.com/, String(bad));
  }
  assert.equal(testFlightURL({}), null);
});

test('the page renders availability from the build and never ships a store link early', () => {
  const page = read('../index.html');
  assert.equal(page.match(/<!-- remote-availability -->/g).length, 1);
  assert.doesNotMatch(page, /apps\.apple\.com/);
  assert.match(page, /<a class="quiet-button" href="#remote">iPhone<\/a>/);
  const dist = new URL('../dist/index.html', import.meta.url);
  if (existsSync(dist)) {
    const built = readFileSync(dist, 'utf8');
    assert.doesNotMatch(built, /remote-availability -->/, 'the build fills the placeholder');
    assert.match(built, appStoreURL(JSON.parse(read('../src/remote.json'))) ? /data-remote-store/ : /data-remote-beta/);
  }
});

test('every phone screen has a tab, a picture in both formats, and words for screen readers', () => {
  const page = read('../index.html');
  const tabs = [...page.matchAll(/role="tab" id="rt-([a-z]+)" aria-controls="remote-screen"/g)].map(m => m[1]);
  const screens = [...page.matchAll(/<picture data-screen="([a-z]+)"/g)].map(m => m[1]);
  assert.deepEqual(tabs, screens);
  for (const name of screens) {
    for (const ext of ['avif', 'webp']) assert.ok(existsSync(new URL(`../public/remote/${name}.${ext}`, import.meta.url)), `${name}.${ext}`);
    assert.match(page, new RegExp(`<img src="\\./remote/${name}\\.webp" width="600" height="1305" alt="[^"]{20,}"`));
  }
});

test('the text pages build next to the home page and render availability with the way back to the top', () => {
  const config = read('../vite.config.ts');
  for (const page of ['privacy', 'remote', 'pair']) {
    assert.match(config, new RegExp(`${page}: '${page}/index\\.html'`), `${page} is a build input`);
    const html = read(`../${page}/index.html`);
    assert.match(html, /<script type="module" src="\/src\/doc\.ts"><\/script>/);
    assert.match(html, /<link rel="icon" type="image\/svg\+xml" href="\.\.\/favicon\.svg" \/>/);
    assert.doesNotMatch(html, /apps\.apple\.com/);
  }
  assert.match(availabilityHTML({ appStoreURL: 'https://apps.apple.com/us/app/side-a-remote/id1234567890' }, '../'), /src="\.\.\/remote\/app-store-badge\.svg"/);
  const pair = new URL('../dist/pair/index.html', import.meta.url);
  if (existsSync(pair)) {
    const built = readFileSync(pair, 'utf8');
    assert.doesNotMatch(built, /remote-availability -->/, 'the build fills the placeholder on subpages too');
    assert.match(built, /<h1>Finish pairing in Side A Remote<\/h1>[\s\S]*data-remote-beta/, '/pair falls back to the beta');
  }
  assert.match(read('../index.html'), /<a href="\.\/privacy\/">Full privacy policy<\/a>/);
  const sitemap = read('../public/sitemap.xml');
  for (const page of ['remote', 'privacy']) assert.match(sitemap, new RegExp(`https://getsidea\\.com/${page}/`));
  assert.doesNotMatch(sitemap, /\/pair/, 'the pairing page is only for links from a Mac');
});

test('/pair loads nothing that could record the pairing key in its fragment', () => {
  const pair = read('../pair/index.html');
  assert.match(pair, /connect-src 'none'/);
  assert.match(pair, /name="referrer" content="no-referrer"/);
  assert.match(pair, /name="robots" content="noindex"/);
  assert.equal(pair.match(/<script /g).length, 1, 'only the styles entry');
  const entry = read('../src/doc.ts');
  assert.doesNotMatch(entry.replace(/^\/\/.*$/gm, ''), /analytics|location|fetch|\.\/main|\.\/how/);
  assert.deepEqual([...entry.matchAll(/^import '([^']+)';$/gm)].map(m => m[1]), ['./style.css', './doc.css']);
});

test('universal links open the app for /pair only, served as JSON', () => {
  const aasa = JSON.parse(read('../public/.well-known/apple-app-site-association'));
  const [detail] = aasa.applinks.details;
  assert.deepEqual(detail.appIDs, ['NV46KL65S9.com.arnenoori.sidea.remote', 'NV46KL65S9.com.arnenoori.sidea.remote.dev']);
  assert.deepEqual(detail.components.map(c => c['/']), ['/pair', '/pair/']);
  const vercel = JSON.parse(read('../../vercel.json'));
  const rule = vercel.headers.find(r => r.source === '/.well-known/apple-app-site-association');
  assert.equal(rule.headers.find(h => h.key === 'Content-Type').value, 'application/json');
  assert.match(read('../public/_headers'), /\/\.well-known\/apple-app-site-association\n {2}Content-Type: application\/json/);
});

test('/pair without a slash, as phones open it, serves the pairing page and not the home page', () => {
  const vercel = JSON.parse(read('../../vercel.json'));
  assert.deepEqual(vercel.routes[0], { src: '^/(pair|remote|privacy)$', dest: '/$1/index.html' });
  assert.match(read('../vite.config.ts'), /appType: 'mpa'/);
});
