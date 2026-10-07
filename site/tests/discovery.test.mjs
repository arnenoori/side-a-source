import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { createAgentTools } from '../src/agent-tools.mjs';
import { latestDownloadableRelease } from '../src/release.mjs';
const publicRoot = new URL('../public/', import.meta.url);
execFileSync(process.execPath, [new URL('../scripts/prepare-discovery.mjs', import.meta.url).pathname]);
const json = async path => JSON.parse(await readFile(new URL(path, publicRoot), 'utf8'));
test('published discovery points to real local artifacts and hashes the exact skill bytes', async () => {
  const index = await json('.well-known/agent-skills/index.json');
  for (const skill of index.skills) {
    const bytes = await readFile(new URL('.' + skill.url, publicRoot));
    assert.equal(skill.digest, `sha256:${createHash('sha256').update(bytes).digest('hex')}`);
  }
  for (const entry of (await json('.well-known/ard.json')).entries) {
    assert.equal('data' in entry, false);
    assert.match(entry.identifier, /^urn:air:getsidea.com:/);
    await readFile(new URL('.' + new URL(entry.url).pathname, publicRoot));
    assert.ok(entry.representativeQueries.length >= 2);
  }
});
test('public API catalog and OpenAPI describe the real unauthenticated product endpoint', async () => {
  const catalog = await json('.well-known/api-catalog');
  assert.equal(catalog.linkset[0].anchor, 'https://getsidea.com/product.json');
  const spec = await json('openapi.json');
  assert.deepEqual(spec.paths['/product.json'].get.security, []);
  const product = await json('product.json');
  for (const required of spec.paths['/product.json'].get.responses[200].content['application/json'].schema.required) assert.ok(required in product);
});
test('agent download check distinguishes no release from network failure', async () => {
  const tool = createAgentTools(async () => ({ ok: true, json: async () => [] }))[1];
  assert.equal(JSON.parse((await tool.execute()).content[0].text).status, 'coming-soon');
  const failed = createAgentTools(async () => { throw new Error('offline'); })[1];
  assert.equal(JSON.parse((await failed.execute()).content[0].text).status, 'unknown');
});
test('release list cannot turn drafts, incomplete data, or malformed responses into downloads', () => {
  assert.equal(latestDownloadableRelease(null), null);
  assert.equal(latestDownloadableRelease({ assets: [] }), null);
  assert.equal(latestDownloadableRelease([{ draft: true }, { tag_name: 'v1.0.0' }]), null);
});
test('agent information is read-only and includes the real limitations', async () => {
  const info = JSON.parse((await createAgentTools()[0].execute()).content[0].text);
  assert.ok(info.limitations.some(item => item.includes('experimental')));
  assert.equal(info.author.url, 'https://arne.ai');
});
