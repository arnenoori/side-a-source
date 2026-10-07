import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
const root = new URL('../public/', import.meta.url);
const origin = 'https://getsidea.com';
async function output(path, value) {
  const url = new URL(path, root);
  await mkdir(new URL('.', url), { recursive: true });
  await writeFile(url, typeof value === 'string' ? value : JSON.stringify(value, null, 2) + '\n');
}
const skillURL = '/.well-known/agent-skills/side-a-setup/SKILL.md';
const skill = await readFile(new URL(`.${skillURL}`, root), 'utf8');
await output('.well-known/agent-skills/index.json', {
  $schema: 'https://schemas.agentskills.io/discovery/0.2.0/schema.json',
  skills: [{ name: 'side-a-setup', type: 'skill-md', description: 'Check Side A downloads and help set up Claude Code or Codex accounts in Side A on a Mac.', url: skillURL, digest: `sha256:${createHash('sha256').update(skill).digest('hex')}` }],
});
const catalog = {
  specVersion: '1.0', host: { displayName: 'Side A', url: origin },
  entries: [{ identifier: 'urn:air:getsidea.com:skill:side-a-setup', displayName: 'Side A setup', type: 'text/markdown', url: origin + skillURL, description: 'Requirements, official download checks, and account setup guidance for Side A.', representativeQueries: ['How do I set up Side A on my Mac?', 'Is Side A available to download for Claude Code or Codex?'] }],
};
await output('.well-known/ai-catalog.json', catalog);
await output('.well-known/ard.json', catalog);
