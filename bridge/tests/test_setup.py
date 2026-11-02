import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]))
SPEC = importlib.util.spec_from_file_location('setup_overview', Path(__file__).parents[1] / 'setup.py')
setup = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(setup)

SECRET = 'sk-very-secret-value'


class SetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name) / 'home'
        self.root = Path(self.temp.name) / 'SideA'
        self.project = Path(self.temp.name) / 'code' / 'app'
        for folder in (self.home / '.claude', self.home / '.codex', self.root / 'runtime', self.project):
            folder.mkdir(parents=True)
        home = patch.object(Path, 'home', return_value=self.home); home.start(); self.addCleanup(home.stop)
        env = patch.dict(os.environ); env.start(); self.addCleanup(env.stop)
        os.environ.pop('CODEX_HOME', None)

    def tearDown(self):
        self.temp.cleanup()

    def write(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value if isinstance(value, str) else json.dumps(value))

    def sessions_db(self, *cwds):
        db = sqlite3.connect(self.root / 'runtime' / 'sessions.db')
        db.execute('CREATE TABLE sessions(id TEXT, cwd TEXT, last_ts REAL)')
        db.executemany('INSERT INTO sessions VALUES (?, ?, ?)', [(str(i), cwd, i) for i, cwd in enumerate(cwds)])
        db.commit(); db.close()

    def test_mcp_servers_from_every_scope_without_secrets(self):
        self.write(self.home / '.claude.json', {
            'mcpServers': {'docs': {'type': 'http', 'url': f'https://docs.example/mcp?token={SECRET}',
                                    'headers': {'Authorization': f'Bearer {SECRET}'}}},
            'projects': {'/code/web': {'mcpServers': {'sim': {'command': 'npx', 'args': ['sim', '--key', SECRET],
                                                              'env': {'API_KEY': SECRET}}}}}})
        self.write(self.project / '.mcp.json', {'mcpServers': {'local': {'type': 'sse', 'url': 'http://localhost:9/sse'}}})
        self.sessions_db(str(self.project), str(self.project), '/gone')
        self.write(self.home / '.codex/config.toml', '\n'.join([
            'model = "gpt"', '', '[mcp_servers.eraser]', 'command = "npx"', 'args = ["@eraser/mcp"]', 'enabled = false',
            '', '[mcp_servers.eraser.env]', f'ERASER_TOKEN = "{SECRET}"', '', '[mcp_servers.sentry]',
            'url = "https://mcp.sentry.dev/mcp"', f'env = {{ SENTRY_KEY = "{SECRET}" }}', '', '[profiles.fast]', 'model = "x"']))
        servers = {s['name']: s for s in setup.mcp_servers(self.root)}
        self.assertEqual(set(servers), {'docs', 'sim', 'local', 'eraser', 'sentry'})
        self.assertEqual((servers['docs']['scope'], servers['docs']['type'], servers['docs']['target']), ('user', 'http', 'https://docs.example'))
        self.assertEqual(servers['docs']['headers'], ['Authorization'])
        self.assertEqual((servers['sim']['type'], servers['sim']['target'], servers['sim']['env']), ('stdio', 'npx sim', ['API_KEY']))
        self.assertEqual(servers['local']['target'], 'http://localhost:9')
        self.assertEqual((servers['local']['scope'], servers['local']['type'], servers['local']['project']), ('project', 'sse', str(self.project)))
        self.assertEqual((servers['eraser']['scope'], servers['eraser']['env'], servers['eraser'].get('disabled')), ('codex', ['ERASER_TOKEN'], True))
        self.assertEqual((servers['sentry']['type'], servers['sentry']['env']), ('http', ['SENTRY_KEY']))
        output = json.dumps(setup.overview(self.root))
        self.assertNotIn(SECRET, output)
        self.assertNotIn('Bearer', output)

    def test_urls_show_only_scheme_host_and_port(self):
        cases = {f'https://user:{SECRET}@mcp.example.com/mcp': 'https://mcp.example.com',
                 f'https://mcp.example.com:8443/t/{SECRET}/sse': 'https://mcp.example.com:8443',
                 f'https://mcp.example.com/mcp#{SECRET}': 'https://mcp.example.com',
                 f'https://mcp.example.com/mcp?key={SECRET}': 'https://mcp.example.com',
                 'http://[::1]:9000/mcp': 'http://[::1]:9000',
                 f'mcp.example.com/{SECRET}': '', 'http://host:notaport/': ''}
        for url, shown in cases.items():
            self.assertEqual(setup.address(url), shown, url)
            self.assertEqual(setup.server('x', 'user', {'type': 'http', 'url': url})['target'], shown)

    def test_commands_show_only_the_program_and_a_script_name(self):
        cases = [({'command': f'/opt/{SECRET}/bin/server', 'args': ['--api-key', SECRET]}, 'server'),
                 ({'command': f'my-server --api-key {SECRET}'}, 'my-server'),
                 ({'command': 'npx', 'args': ['-y', '@acme/mcp-server@1.2', '--token', SECRET]}, 'npx mcp-server@1.2'),
                 ({'command': '/usr/bin/python3', 'args': [f'/home/{SECRET}/run.py', SECRET]}, 'python3 run.py'),
                 ({'command': 'uvx', 'args': ['--from', f'git+https://{SECRET}@github.com/x/y', 'y']}, 'uvx'),
                 ({'command': 'node', 'args': [f'https://example.com/{SECRET}']}, 'node'),
                 ({'command': f'API_KEY={SECRET} node server.js'}, 'node server.js'),
                 ({'command': f'env TOKEN={SECRET} /usr/local/bin/srv'}, 'srv')]
        for value, shown in cases:
            self.assertEqual(setup.server('x', 'user', value)['target'], shown, value)

    def test_hook_and_status_line_commands_never_show_arguments(self):
        self.write(self.home / '.claude/settings.json', {
            'hooks': {'Stop': [{'hooks': [{'type': 'command', 'command': f'curl -H "Authorization: Bearer {SECRET}" https://hooks.example.com/{SECRET}'},
                                          {'type': 'http', 'url': f'https://hooks.slack.com/services/{SECRET}'}]}],
                      'PostToolUse': [{'hooks': [{'type': 'command', 'command': f'bash -c "notify --key {SECRET}"'},
                                                 {'type': 'command', 'command': f'node ~/hooks/{SECRET}/notify.js --key {SECRET}'}]}]},
            'statusLine': {'type': 'command', 'command': f'WEBHOOK=https://x.example/{SECRET} ~/bin/status.sh --token {SECRET}'}})
        found = setup.hooks()
        self.assertEqual([h['command'] for h in found], ['curl', 'https://hooks.slack.com', 'bash', 'node notify.js', 'status.sh'])
        output = json.dumps(found)
        self.assertNotIn(SECRET, output)
        self.assertNotIn('Bearer', output)

    def test_tiny_toml_parser_matches_tomllib_shape(self):
        text = '[mcp_servers."my server"]\ncommand = "uvx" # runs it\nargs = ["a", "b"]\nenabled = true\n'
        tables = setup.toml_tables(text, 'mcp_servers')
        self.assertEqual(tables, {'my server': {'command': 'uvx', 'args': ['a', 'b'], 'enabled': True}})
        try:
            import tomllib
        except ImportError:  # 3.9, where the tiny parser is what runs
            return
        self.assertEqual(tables, tomllib.loads(text)['mcp_servers'])

    def test_missing_and_corrupt_files_give_empty_lists(self):
        self.write(self.home / '.claude.json', '{broken')
        self.write(self.home / '.claude/settings.json', '[]')
        self.assertEqual(setup.mcp_servers(self.root), [])
        self.assertEqual(setup.hooks(), [])
        self.assertEqual((setup.skills(), setup.agents()), ([], []))

    def test_hooks_mark_side_a_and_truncate(self):
        long = 'x' * 300
        self.write(self.home / '.claude/settings.json', {
            'hooks': {'PreToolUse': [{'matcher': 'Bash', 'hooks': [{'type': 'command', 'command': long}]}],
                      'StopFailure': [{'matcher': 'rate_limit', 'hooks': [{'type': 'command', 'command': 'touch x # side-a-limit'}]}]},
            'statusLine': {'type': 'command', 'command': '/bin/sh s.sh # side-a-live'}})
        self.write(self.home / '.claude/settings.local.json', {'hooks': {'Stop': [{'hooks': [{'type': 'command', 'command': 'say done'}]}]}})
        self.write(self.home / '.codex/hooks.json', {'hooks': {'PermissionRequest': [{'hooks': [{'command': '/bin/sh h.sh codex # side-a-island'}]}]}})
        found = setup.hooks()
        by_event = {h['event']: h for h in found}
        self.assertEqual(len(found), 5)
        self.assertEqual(len(by_event['PreToolUse']['command']), setup.COMMAND_LIMIT)
        self.assertIsNone(by_event['PreToolUse']['sideA'])
        self.assertEqual(by_event['StopFailure']['sideA'], 'Limit switch')
        self.assertEqual(by_event['statusLine']['sideA'], 'Live limits')
        self.assertEqual((by_event['PermissionRequest']['agent'], by_event['PermissionRequest']['sideA']), ('codex', 'Dynamic Island'))
        self.assertEqual(by_event['Stop']['file'], '~/.claude/settings.local.json')

    def test_skills_follow_symlinks_and_agents_use_frontmatter(self):
        shared = self.home / '.agents/skills/review'
        self.write(shared / 'SKILL.md', '---\nname: code-review\ndescription: Reviews\n---\nBody')
        (self.home / '.claude/skills').mkdir()
        (self.home / '.claude/skills/review').symlink_to(shared)
        self.write(self.home / '.claude/skills/plain/SKILL.md', 'No frontmatter')
        plugin = self.home / '.claude/plugins/cache/figma/1.0'
        self.write(plugin / 'skills/inspect/SKILL.md', '---\nname: inspect\n---\n')
        self.write(self.home / '.claude/plugins/installed_plugins.json', {'plugins': {'figma@official': [{'installPath': str(plugin)}],
                                                                                    'off@official': [{'installPath': str(plugin)}]}})
        self.write(self.home / '.claude/settings.json', {'enabledPlugins': {'figma@official': True, 'off@official': False}})
        self.write(self.home / '.claude/agents/helper.md', '---\nname: helper-agent\n---\n')
        names = [(s['name'], s['source']) for s in setup.skills()]
        self.assertEqual(sorted(names), [('code-review', 'claude'), ('inspect', 'figma'), ('plain', 'claude')])
        self.assertEqual(setup.agents(), [{'name': 'helper-agent'}])

    def test_tool_versions_and_missing_binaries(self):
        binary = self.home / '.local/bin/claude'
        self.write(binary, '#!/bin/sh\necho "2.1.300 (Claude Code)"\n'); binary.chmod(0o755)
        with patch.object(setup, 'find_binary', side_effect=lambda name: str(binary) if name == 'claude' else None):
            tools = {t['name']: t for t in setup.overview(self.root)['tools']}
        self.assertEqual(tools['claude']['version'], '2.1.300')
        self.assertEqual(tools['codex'], {'name': 'codex', 'path': None, 'version': None})

    def test_mcp_health_parses_claude_mcp_list(self):
        output = ('Checking MCP server health…\n\n'
                  'docs: https://docs.example/mcp (HTTP) - ✓ Connected\n'
                  'plugin:figma:figma: https://mcp.figma.com/mcp (HTTP) - ! Needs authentication\n'
                  'sim: npx sim - ✗ Failed to connect\n')
        self.assertEqual(setup.parse_mcp_list(output), {'docs': 'connected', 'plugin:figma:figma': 'needs-auth', 'sim': 'failed'})
        with patch.object(setup, 'find_binary', return_value='/bin/claude'), \
             patch.object(setup.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, output, '')) as run:
            self.assertEqual(setup.mcp_health()['servers']['docs'], 'connected')
        self.assertEqual(run.call_args.args[0], ['/bin/claude', 'mcp', 'list'])


if __name__ == '__main__':
    unittest.main()
