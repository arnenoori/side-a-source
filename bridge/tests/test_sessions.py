import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]))
SPEC = importlib.util.spec_from_file_location('sessions', Path(__file__).parents[1] / 'sessions.py')
sessions = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sessions)


def user(uuid, text, at, **extra):
    return {'type': 'user', 'uuid': uuid, 'timestamp': at, 'cwd': '/code/app', 'gitBranch': 'main', 'message': {'content': text}, **extra}


def reply(uuid, text, at, tools=(), **extra):
    content = [{'type': 'text', 'text': text}] + [{'type': 'tool_use', 'name': name, 'input': value} for name, value in tools]
    return {'type': 'assistant', 'uuid': uuid, 'timestamp': at, 'message': {'id': 'm-' + uuid, 'model': 'claude-opus-5-5', 'content': content,
            'usage': {'input_tokens': 10, 'output_tokens': 5}}, **extra}


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name) / 'home'
        self.root = Path(self.temp.name) / 'SideA'
        self.project = self.home / '.claude/projects/-code-app'
        self.project.mkdir(parents=True)
        home = patch.object(Path, 'home', return_value=self.home); home.start(); self.addCleanup(home.stop)

    def tearDown(self):
        self.temp.cleanup()

    def write(self, sid, entries, mode='w'):
        with open(self.project / f'{sid}.jsonl', mode) as stream:
            for entry in entries:
                stream.write(json.dumps(entry) + '\n')

    def test_indexes_once_titles_by_priority_and_forks_point_at_their_parent(self):
        parent = [user('u1', 'Make the menu bar gauge show Fable limits', '2026-10-01T10:00:00Z'),
                  reply('a1', 'Reading the Keychain trade code first.', '2026-10-01T10:01:00Z', [('Bash', {'command': 'git log --oneline'})]),
                  {'type': 'ai-title', 'aiTitle': 'Fable gauge'},
                  user('u2', 'Now add search', '2026-10-01T10:05:00Z'),
                  user('meta', 'Caveat: the messages below were generated', '2026-10-01T10:05:01Z', isMeta=True),
                  user('cmd', '<command-name>/model</command-name><command-args>opus</command-args>', '2026-10-01T10:05:02Z')]
        self.write('parent', parent)
        # A fork copies the parent's history, each copy keeping its own uuid.
        copies = [{**entry, 'forkedFrom': {'sessionId': 'parent', 'messageUuid': entry['uuid']}} for entry in parent[:2]]
        self.write('child', copies + [user('c1', 'Try a trigram index instead', '2026-10-02T09:00:00Z'),
                                      {'type': 'custom-title', 'customTitle': 'Trigram experiment'},
                                      {'type': 'ai-title', 'aiTitle': 'Search work'}])
        self.assertEqual(sessions.index(self.root)['sessions'], 2)
        listed = {s['id']: s for s in sessions.recent(self.root)['sessions']}
        self.assertEqual((listed['parent']['title'], listed['child']['title']), ('Fable gauge', 'Trigram experiment'))
        self.assertEqual((listed['child']['forked_from'], listed['child']['fork_point']), ('parent', 'a1'))
        self.assertEqual(listed['parent']['prompts'], 3)
        self.assertEqual(listed['parent']['tokens'], 15)
        self.assertEqual([s['id'] for s in sessions.search(self.root, 'keychain trade')['sessions']], ['parent'])
        self.assertEqual([s['id'] for s in sessions.search(self.root, '/model opus')['sessions']], ['parent'])
        self.assertEqual(sessions.search(self.root, 'Caveat')['sessions'], [])
        hit = sessions.search(self.root, 'git log')['sessions'][0]['snippets'][0]
        self.assertEqual((hit['role'], hit['uuid']), ('tool', 'a1'))
        self.assertIn('\x02git\x03', hit['text'])

        self.write('parent', [reply('a2', 'Added an FTS5 index', '2026-10-01T10:06:00Z'),
                              {'type': 'cost-state', 'totalCostUSD': 1.25, 'modelUsage': {'opus': {'inputTokens': 100, 'outputTokens': 20}}}], 'a')
        self.assertEqual(sessions.index(self.root)['indexed'], 1)
        listed = {s['id']: s for s in sessions.recent(self.root)['sessions']}
        self.assertEqual((listed['parent']['cost'], listed['parent']['tokens'], listed['parent']['messages']), (1.25, 120, 5))
        self.assertEqual(len(sessions.search(self.root, 'FTS5')['sessions']), 1)
        self.assertEqual(sessions.search(self.root, 'Fable gauge')['sessions'][0]['id'], 'parent')

        shown = sessions.show(self.root, 'child')
        self.assertEqual(shown['parent']['title'], 'Fable gauge')
        self.assertEqual([(m['role'], m['inherited']) for m in shown['messages']],
                         [('user', True), ('assistant', True), ('tool', True), ('user', False)])
        self.assertEqual([f['id'] for f in sessions.show(self.root, 'parent')['forks']], ['child'])

        self.assertEqual(sessions.search(self.root, 'trigram', project='/elsewhere')['sessions'], [])
        self.assertEqual([s['id'] for s in sessions.search(self.root, 'a trigram')['sessions']], ['child'])
        self.assertEqual(sessions.search(self.root, 'NEAR("x" OR')['sessions'], [])

        self.write('job', [user('j1', 'Review the trigram diff', '2026-10-03T09:00:00Z', entrypoint='sdk-cli')])
        sessions.index(self.root)
        self.assertNotIn('job', [s['id'] for s in sessions.recent(self.root)['sessions']])
        self.assertEqual([s['id'] for s in sessions.search(self.root, 'trigram diff', automated=True)['sessions']], ['job'])
        os.unlink(self.project / 'job.jsonl')

        os.unlink(self.project / 'child.jsonl')
        sessions.index(self.root)
        self.assertEqual([s['id'] for s in sessions.recent(self.root)['sessions']], ['parent'])

    def test_codex_sessions_use_codexs_own_title_and_skip_injected_instructions(self):
        folder = self.home / '.codex/sessions/2026/10/09'; folder.mkdir(parents=True)
        lines = [{'type': 'session_meta', 'timestamp': '2026-10-09T10:00:00Z', 'payload': {'id': 'thread-1', 'cwd': '/code/api', 'source': 'cli', 'git': {'branch': 'dev'}}},
                 {'type': 'response_item', 'timestamp': '2026-10-09T10:00:01Z', 'payload': {'type': 'message', 'role': 'user', 'content': [{'type': 'input_text', 'text': '# AGENTS.md instructions for /code/api'}]}},
                 {'type': 'response_item', 'timestamp': '2026-10-09T10:00:02Z', 'payload': {'type': 'message', 'role': 'user', 'content': [{'type': 'input_text', 'text': 'Fix the flaky upload test'}]}},
                 {'type': 'response_item', 'timestamp': '2026-10-09T10:00:03Z', 'payload': {'type': 'function_call', 'name': 'shell', 'arguments': '{"command": "pytest -k upload"}', 'call_id': 'c1'}}]
        (folder / 'rollout-2026-10-09-thread-1.jsonl').write_text(''.join(json.dumps(l) + '\n' for l in lines))
        with patch.object(sessions, 'codex_threads', return_value={'thread-1': {'title': 'Flaky upload', 'tokens': 900, 'branch': 'dev'}}):
            sessions.index(self.root)
        found = sessions.recent(self.root, agent='codex')['sessions'][0]
        self.assertEqual((found['title'], found['tokens'], found['prompts'], found['cwd']), ('Flaky upload', 900, 1, '/code/api'))
        self.assertEqual(sessions.search(self.root, 'AGENTS.md')['sessions'], [])
        self.assertEqual(sessions.search(self.root, 'pytest')['sessions'][0]['snippets'][0]['role'], 'tool')
        self.assertEqual([m['role'] for m in sessions.show(self.root, 'thread-1')['messages']], ['user', 'tool'])

    def test_live_lists_running_sessions_waiting_first(self):
        registry = self.home / '.claude/sessions'; registry.mkdir(parents=True)
        running = [subprocess.Popen(['sleep', '60']) for _ in range(4)]
        for process in running:
            self.addCleanup(process.wait); self.addCleanup(process.kill)
        # Waiting, then working, then idle; within each, the newest change first.
        rows = [('idle', 's-idle', 1791560900000), ('busy', 's-busy', 1791560100000),
                ('waiting', 's-older', 1791560000000), ('waiting', 's-newer', 1791560500000)]
        for process, (status, sid, at) in zip(running, rows):
            (registry / f'{process.pid}.json').write_text(json.dumps({'pid': process.pid, 'sessionId': sid, 'cwd': '/code/app', 'status': status,
                                                                      'waitingFor': 'permission' if status == 'waiting' else None, 'statusUpdatedAt': at}))
        (registry / '999999.json').write_text(json.dumps({'pid': 999999, 'sessionId': 's2', 'status': 'busy'}))  # exited
        (registry / 'broken.json').write_text('{')
        with patch.object(sessions, 'live_codex', return_value=[]):  # Codex running on this Mac is found by its processes
            live = sessions.live(self.root)['sessions']
        self.assertEqual([(s['id'], s['status'], s['waitingFor']) for s in live],
                         [('s-newer', 'waiting', 'permission'), ('s-older', 'waiting', 'permission'), ('s-busy', 'busy', None), ('s-idle', 'idle', None)])

    def test_a_live_claude_row_has_the_settings_its_statusline_hooks_and_transcript_report(self):
        registry = self.home / '.claude/sessions'; registry.mkdir(parents=True)
        me = os.getpid()
        (registry / f'{me}.json').write_text(json.dumps({'pid': me, 'sessionId': 's1', 'cwd': '/code/app', 'status': 'busy'}))
        self.write('s1', [{'type': 'permission-mode', 'permissionMode': 'default', 'sessionId': 's1'},
                          {'type': 'system', 'subtype': 'compact_boundary', 'uuid': 'c1', 'timestamp': '2026-10-01T09:59:00Z'},
                          user('u1', 'Plan the gauge', '2026-10-01T10:00:00Z', permissionMode='plan'),
                          # A tool result is no prompt, so the turn stays u1's.
                          user('r1', [{'type': 'tool_result', 'tool_use_id': 't1', 'content': 'ok'}], '2026-10-01T10:00:02Z')])
        line = {'session_id': 's1', 'model': {'id': 'claude-opus-5-5', 'display_name': 'Opus'}, 'effort': {'level': 'high'}, 'fast_mode': False,
                'context_window': {'used_percentage': 37, 'context_window_size': 1000000}, 'cost': {'total_cost_usd': 1.25}}
        saved = self.root / 'runtime/live/s'; saved.mkdir(parents=True)
        (saved / 's1.json').write_text(json.dumps(line))
        state = self.root / 'runtime/state'; state.mkdir(parents=True)
        (state / 's1.tasks.json').write_text(json.dumps({'tasks': [{'id': 'b1', 'type': 'shell', 'status': 'running', 'description': 'npm run dev'}]}))
        (saved / '.s1.123').write_text('{')  # a statusline stopped mid-write
        (state / 'gone.hook.json').write_text('{}')
        (state / 'ended.tasks.json').write_text(json.dumps({'tasks': [{'id': 'b9', 'status': 'running'}]}))  # its session quit
        old = time.time() - 8 * 86400
        os.utime(saved / '.s1.123', (old, old)); os.utime(state / 'gone.hook.json', (old, old))
        live = lambda: next(s for s in sessions.live(self.root)['sessions'] if s['id'] == 's1')
        with patch.object(sessions, 'live_codex', return_value=[]):
            row = live()
            self.assertEqual({key: row.get(key) for key in ('model', 'effort', 'fast', 'mode', 'contextPercent', 'cost', 'backgroundTasks')},
                             {'model': 'claude-opus-5-5', 'effort': 'high', 'fast': False, 'mode': 'plan', 'contextPercent': 37, 'cost': 1.25,
                              'backgroundTasks': [{'id': 'b1', 'type': 'shell', 'status': 'running', 'description': 'npm run dev'}]})
            self.assertEqual((row['turnID'], row['compactedAt']), ('u1', sessions.epoch('2026-10-01T09:59:00Z')))
            # A turn longer than the tail: its prompt is the newest user row the viewer cached.
            sessions.page(self.root, 's1')
            with patch.object(sessions, 'TAIL', 40):
                self.assertEqual(live()['turnID'], 'u1')
            self.assertEqual(sorted(p.name for p in saved.iterdir()) + sorted(p.name for p in state.iterdir()), ['s1.json', 's1.tasks.json'])
            # A hook or a model switch newer than the statusline and the transcript wins; an older one doesn't.
            later = time.time() + 5
            (state / 's1.hook.json').write_text(json.dumps({'mode': 'acceptEdits', 'effort': 'max'}))
            (state / 's1.model.json').write_text(json.dumps({'model': 'claude-sonnet-5-5'}))
            for name in ('s1.hook.json', 's1.model.json'):
                os.utime(state / name, (later, later))
            self.assertEqual((live()['mode'], live()['effort'], live()['model']), ('acceptEdits', 'max', 'claude-sonnet-5-5'))
            os.utime(state / 's1.hook.json', (old + 2 * 86400, old + 2 * 86400))
            self.assertEqual((live()['mode'], live()['effort']), ('plan', 'high'))

    def test_live_names_the_hosted_session_a_process_runs_under(self):
        import hosting
        registry = self.home / '.claude/sessions'; registry.mkdir(parents=True)
        me = os.getpid()
        (registry / f'{me}.json').write_text(json.dumps({'pid': me, 'sessionId': 's1', 'status': 'idle'}))
        tree = ({me: 1.0, 500: 1.0, 1: 1.0}, {1: [500], 500: [me]}, {})
        with patch.object(sessions, 'process_tree', return_value=tree), patch.object(sessions, 'listening', return_value={}):
            with patch.object(hosting, 'panes', return_value={500: 'sa-app-1a2b'}):
                self.assertEqual(sessions.live(self.root)['sessions'][0]['hosted'], 'sa-app-1a2b')
            # No tmux server, or no tmux at all: nothing is hosted.
            with patch.object(hosting, 'panes', return_value={}):
                self.assertIsNone(sessions.live(self.root)['sessions'][0]['hosted'])

    def test_a_sessions_footprint_counts_everything_it_started(self):
        memory = {10: 300.0, 11: 120.0, 12: 80.0, 13: 999.0, 14: 5.0}
        children = {10: [11, 14], 11: [12], 1: [10, 13]}
        self.assertEqual(sessions.footprint(10, memory, children), (505, 4))
        self.assertEqual(sessions.footprint(99, memory, children), (0, 0))
        me = os.getpid()
        registry = self.home / '.claude/sessions'; registry.mkdir(parents=True)
        (registry / f'{me}.json').write_text(json.dumps({'pid': me, 'sessionId': 's1', 'status': 'idle'}))
        found = sessions.live(self.root)['sessions'][0]
        self.assertGreater(found['memory'], 0); self.assertGreaterEqual(found['processes'], 1); self.assertIsInstance(found['ports'], list)
        self.assertTrue(time.time() - 86400 < found['started'] <= time.time() + 1)

    def test_pid_0_and_launchd_are_never_listed_or_walked(self):
        memory = {0: 1.0, 1: 1.0, 10: 300.0}
        children = {0: [1], 1: [10]}
        self.assertEqual((sessions.descendants(0, memory, children), sessions.descendants(1, memory, children)), (set(), set()))
        registry = self.home / '.claude/sessions'; registry.mkdir(parents=True)
        for pid in (0, 1, -1):
            (registry / f'{pid}.json').write_text(json.dumps({'pid': pid, 'sessionId': f's{pid}', 'status': 'idle'}))
        with patch.object(sessions, 'process_tree', return_value=(memory, children, {})), patch.object(sessions, 'listening', return_value={}):
            self.assertEqual(sessions.live(self.root)['sessions'], [])

    def test_listening_ports_come_from_lsof_fields(self):
        output = 'p501\ncnode\nf22\nn*:3000\nf23\nn[::1]:3000\nf24\nn127.0.0.1:9229\np777\ncpython3\nn*:8000\npbad\nn*:1\n'
        self.assertEqual(sessions.parse_listening(output), {
            501: [{'port': 3000, 'pid': 501, 'command': 'node'}, {'port': 9229, 'pid': 501, 'command': 'node'}],
            777: [{'port': 8000, 'pid': 777, 'command': 'python3'}]})
        self.assertEqual(sessions.parse_listening(''), {})
        self.assertEqual(sessions.descendants(10, {10: 1.0, 11: 1.0, 12: 1.0}, {10: [11]}), {10, 11})

    def test_health_names_the_current_step_and_flags_what_needs_a_look(self):
        def call(name, value, tokens=1000):
            return {'type': 'assistant', 'message': {'usage': {'input_tokens': 5, 'cache_read_input_tokens': tokens},
                                                     'content': [{'type': 'tool_use', 'name': name, 'input': value}]}}
        def result(error=False):
            return {'type': 'user', 'message': {'content': [{'type': 'tool_result', 'is_error': error, 'content': 'x'}]}}
        path = self.project / 'h.jsonl'
        def health(lines, status='busy', quiet=0):
            path.write_text(''.join(json.dumps(l) + '\n' for l in lines))
            os.utime(path, (time.time() - quiet, time.time() - quiet))
            return sessions.health(path, status)
        working = health([call('Edit', {'file_path': '/code/app/Island.swift'}), result()])
        self.assertEqual((working['activity'], working['context'], working['flag']), ('Editing Island.swift', 1005, None))
        self.assertEqual(health([call('Bash', {'command': 'swift  build'})], 'idle')['activity'], None)
        self.assertEqual(health([call('Bash', {'command': 'swift  build'})])['activity'], 'Running swift build')
        self.assertEqual(health([call('Read', {'file_path': '/a'})], quiet=900)['flag'], {'kind': 'stuck', 'text': 'No progress for 15 min'})
        self.assertEqual(health([call('Bash', {'command': 'make'}), result(True)] * 3)['flag']['kind'], 'loop')
        failing = [l for n in range(4) for l in (call('Bash', {'command': f'make {n}'}), result(True))]
        self.assertEqual(health(failing)['flag'], {'kind': 'failing', 'text': '4 failed steps in a row'})
        self.assertEqual(health(failing + [{'type': 'user', 'message': {'content': 'Try another way'}}])['flag'], None)
        self.assertEqual(health([call('Read', {'file_path': '/a'}, 180_000)], 'idle')['flag'], {'kind': 'bloated', 'text': 'Context is 180k tokens'})

    def test_indexes_only_the_named_files_and_rereads_a_grown_transcript(self):
        self.write('old', [user('o1', 'Older conversation', '2026-10-01T10:00:00Z')])
        sessions.index(self.root)
        self.write('new', [user('n1', 'Brand new chat from the terminal', '2026-10-09T10:00:00Z')])
        self.write('other', [user('x1', 'Not named, so not indexed yet', '2026-10-09T10:00:00Z')])
        self.assertEqual(sessions.index(self.root, paths=[str(self.project / 'new.jsonl')])['indexed'], 1)
        self.assertEqual({s['id'] for s in sessions.recent(self.root)['sessions']}, {'old', 'new'})
        self.assertEqual([s['id'] for s in sessions.recent(self.root, limit=1, pinned=['old', 'gone'])['pinned']], ['old'])
        self.assertEqual([s['id'] for s in sessions.recent(self.root, only=['old'])['sessions']], ['old'])
        self.assertEqual(sessions.recent(self.root, only=[])['sessions'], [])
        self.assertEqual(len(sessions.show(self.root, 'new')['messages']), 1)
        self.write('new', [reply('r1', 'Replying now', '2026-10-09T10:00:05Z')], 'a')
        self.assertEqual([m['role'] for m in sessions.show(self.root, 'new')['messages']], ['user', 'assistant'])
        os.unlink(self.project / 'new.jsonl')
        sessions.index(self.root, paths=[str(self.project / 'new.jsonl')])
        self.assertEqual({s['id'] for s in sessions.recent(self.root)['sessions']}, {'old'})

    def test_an_index_from_before_the_row_map_is_upgraded_in_place(self):
        self.write('s', [user('u1', 'Upgrade keeps the zebra searchable', '2026-10-01T10:00:00Z')])
        sessions.index(self.root)
        db = sessions.connect(self.root)
        db.execute('DELETE FROM rows')
        db.execute('PRAGMA user_version=3')
        db.commit(); db.close()
        self.assertEqual([s['id'] for s in sessions.search(self.root, 'zebra')['sessions']], ['s'])
        os.unlink(self.project / 's.jsonl')
        sessions.index(self.root)
        self.assertEqual(sessions.search(self.root, 'zebra')['sessions'], [])

    def test_a_follow_up_sent_from_side_a_reads_as_the_users_message(self):
        # As Claude Code 2.1.302 writes an asyncRewake Stop hook's stderr; other task notifications stay hidden.
        feedback = ('<task-notification>\n<summary>Stop hook feedback</summary>\n</task-notification>\n<system-reminder>\n'
                    'Stop hook blocking error from command "/bin/sh /x/island-hook.sh claude # side-a-island": '
                    "The user sent you their next request from Side A's island:\n\nNow open a PR\nfor it\n\n</system-reminder>")
        background = '<task-notification>\n<summary>Background command "sleep" completed (exit code 0)</summary>\n</task-notification>'
        self.write('follow', [user('u0', 'Fix the bug', '2026-10-01T10:00:00Z'), reply('a0', 'Fixed.', '2026-10-01T10:01:00Z'),
                              user('u1', feedback, '2026-10-01T10:02:00Z'), user('u2', background, '2026-10-01T10:02:30Z'),
                              reply('a1', 'Opened #12.', '2026-10-01T10:03:00Z')])
        sessions.index(self.root)
        shown = [(m['role'], m['text']) for m in sessions.show(self.root, 'follow', limit=50)['messages']]
        self.assertEqual(shown, [('user', 'Fix the bug'), ('assistant', 'Fixed.'), ('user', 'Now open a PR\nfor it'), ('assistant', 'Opened #12.')])

    def test_a_follow_up_that_reaches_a_busy_session_reads_as_the_users_message(self):
        # Claude Code 2.1.302 queues it as an attachment while Claude works; other queued notifications stay hidden.
        def queued(uuid, prompt, at):
            return {'type': 'attachment', 'uuid': uuid, 'timestamp': at, 'attachment': {
                'type': 'queued_command', 'prompt': prompt, 'commandMode': 'task-notification',
                'origin': {'kind': 'task-notification', 'producer': 'session-task'}}}
        feedback = ('<task-notification>\n<summary>Stop hook feedback</summary>\n</task-notification>\n<system-reminder>\n'
                    'Stop hook blocking error from command "/bin/sh /x/island-hook.sh claude # side-a-island": '
                    "The user sent you their next request from Side A's island:\n\nAlso add a test\n\n</system-reminder>")
        background = '<task-notification>\n<summary>Background command "sleep" completed (exit code 0)</summary>\n</task-notification>'
        self.write('busy', [user('u0', 'Fix the bug', '2026-10-01T10:00:00Z'),
                            queued('q1', feedback, '2026-10-01T10:00:30Z'), queued('q2', background, '2026-10-01T10:00:40Z'),
                            {'type': 'attachment', 'uuid': 'x1', 'timestamp': '2026-10-01T10:00:45Z', 'attachment': {'type': 'todo_reminder'}},
                            reply('a1', 'Fixed, with a test.', '2026-10-01T10:01:00Z')])
        sessions.index(self.root)
        shown = [(m['role'], m['text'], m['uuid']) for m in sessions.show(self.root, 'busy', limit=50)['messages']]
        self.assertEqual(shown, [('user', 'Fix the bug', 'u0'), ('user', 'Also add a test', 'q1'), ('assistant', 'Fixed, with a test.', 'a1')])

    def test_a_conversation_opens_from_the_index_and_around_a_search_hit(self):
        entries = [user('u0', 'Start the long one', '2026-10-01T10:00:00Z')]
        for n in range(1, 120):
            entries.append(reply(f'a{n}', f'Step {n}', '2026-10-01T10:01:00Z', tools=[('Bash', {'command': f'echo {n}'})]))
        entries.append(reply('hit', 'Found the walrus', '2026-10-01T10:02:00Z', tools=[('Read', {'file_path': '/a'})]))
        entries.append(reply('merged', '', '2026-10-01T10:02:01Z', tools=[('Grep', {'pattern': 'walrus'})]))
        entries += [user(f'tail{n}', f'More {n}', '2026-10-01T10:03:00Z') for n in range(80)]
        self.write('long', entries)
        sessions.index(self.root)
        newest = sessions.show(self.root, 'long', limit=50)
        self.assertEqual(len(newest['messages']), 50)
        self.assertGreater(newest['truncated'], 0)

        # Reopening reads the saved messages; the transcript isn't parsed again.
        with patch.object(sessions, 'read_messages', side_effect=AssertionError('re-parsed')):
            self.assertEqual(sessions.show(self.root, 'long', limit=50)['messages'], newest['messages'])

        around = sessions.show(self.root, 'long', limit=50, around='hit')
        uuids = [m['uuid'] for m in around['messages']]
        self.assertIn('hit', uuids)
        self.assertEqual(around['focus'], 'hit')
        self.assertEqual(uuids.index('hit'), 40)
        self.assertEqual(len(uuids), 50)
        self.assertEqual(around['truncated'] + len(uuids) + around['later'], newest['truncated'] + len(newest['messages']))
        # A hit in a tool call merged into the line before it lands on that line.
        merged = sessions.show(self.root, 'long', limit=50, around='merged')
        self.assertEqual(merged['focus'], 'hit')
        self.assertIn('Grep', ' '.join(t for m in merged['messages'] if m['uuid'] == merged['focus'] for t in m['tools']))

    def test_a_transcript_rewritten_in_place_is_rebuilt_not_appended_to(self):
        self.write('r', [user('u1', 'First version', '2026-10-01T10:00:00Z')])
        sessions.index(self.root)
        self.assertEqual([m['text'] for m in sessions.show(self.root, 'r')['messages']], ['First version'])
        self.write('r', [user('u9', 'Second version, a little longer', '2026-10-01T10:00:00Z'),
                         user('u10', 'And another line', '2026-10-01T10:01:00Z')])
        self.assertEqual([m['text'] for m in sessions.show(self.root, 'r')['messages']],
                         ['Second version, a little longer', 'And another line'])
        self.write('r', [reply('a1', 'Appended', '2026-10-01T10:02:00Z')], mode='a')
        self.assertEqual(sessions.show(self.root, 'r')['messages'][-1]['text'], 'Appended')


class RenameLiveTests(unittest.TestCase):
    """A rename reaches a running Claude through the inbox socket its registry names; a fake inbox stands in."""

    def setUp(self):
        # A Unix socket path is capped near 104 bytes, past the length of a macOS temporary folder.
        self.temp = tempfile.mkdtemp(prefix='sa-', dir='/tmp')
        self.addCleanup(shutil.rmtree, self.temp, True)
        self.home = Path(self.temp) / 'h'
        self.registry = self.home / '.claude/sessions'
        self.registry.mkdir(parents=True)
        home = patch.object(Path, 'home', return_value=self.home); home.start(); self.addCleanup(home.stop)

    def record(self, sid, pid=None, sock=None, key=None):
        pid = pid or os.getpid()
        data = {'pid': pid, 'sessionId': sid, 'name': 'old', **({'messagingSocketPath': sock} if sock else {})}
        (self.registry / f'{pid}.json').write_text(json.dumps(data))
        if key:
            name = f'{pid}.{hashlib.sha256(sock.encode()).hexdigest()}.key'
            (self.registry / name).write_text(json.dumps({'peerToken': key, 'pidDomain': 'darwin'}))

    def inbox(self):
        """Listens like Claude: reads lines until the sender closes, then closes its end."""
        path = os.path.join(self.temp, 'in.sock')
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(path)
        server.listen(1)
        self.addCleanup(server.close)
        got = []

        def serve():
            connection, _ = server.accept()
            data = b''
            while chunk := connection.recv(4096):
                data += chunk
            got.extend(json.loads(line) for line in data.decode().splitlines() if line.strip())
            connection.close()
        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        return path, got, thread

    def test_a_live_session_gets_the_auth_line_and_a_rename_bound_to_its_conversation(self):
        path, got, thread = self.inbox()
        self.record('s1', sock=path, key='tok')
        self.assertEqual(sessions.rename_live('s1', '  Fix the\n gauge  '), {'renamed': True})
        thread.join(2)
        self.assertEqual(got, [{'type': 'auth', 'token': 'tok'},
                               {'type': 'control', 'action': 'rename', 'name': 'Fix the gauge', 'session_id': 's1'}])

    def test_the_bridge_command_takes_a_title_that_starts_with_a_dash(self):
        # The app's own request, through `sessions serve`: Python 3.9's plain parse_args rejects its `--`.
        path, got, thread = self.inbox()
        self.record('s1', sock=path)
        bridge = Path(__file__).parents[1] / 'sidea_bridge.py'
        request = json.dumps({'id': 1, 'args': ['rename', '--name=-v2 plan', '--', 's1']}) + '\n'
        done = subprocess.run([sys.executable, str(bridge), '--root', os.path.join(self.temp, 'root'), 'sessions', 'serve'],
                              input=request, env={**os.environ, 'HOME': str(self.home)}, capture_output=True, text=True, timeout=20)
        self.assertEqual(json.loads(done.stdout.splitlines()[0]).get('result'), {'renamed': True}, done.stdout + done.stderr)
        thread.join(2)
        self.assertEqual(got[-1]['name'], '-v2 plan')

    def test_without_a_published_key_it_sends_the_rename_alone(self):
        path, got, thread = self.inbox()
        self.record('s1', sock=path)
        self.assertTrue(sessions.rename_live('s1', 'Title')['renamed'])
        thread.join(2)
        self.assertEqual([line['type'] for line in got], ['control'])

    def test_falls_back_when_there_is_no_inbox_to_reach(self):
        # An older Claude has no socket in its record; Codex and closed sessions have no record at all.
        self.record('old')
        self.assertEqual(sessions.rename_live('old', 'Title'), {'renamed': False, 'reason': 'no-inbox'})
        self.assertEqual(sessions.rename_live('codex-thread', 'Title'), {'renamed': False, 'reason': 'not-running'})
        self.assertEqual(sessions.rename_live('old', '   '), {'renamed': False, 'reason': 'empty'})

    def test_a_record_of_a_dead_process_is_not_running(self):
        dead = subprocess.Popen(['true'])
        dead.wait()
        self.record('gone', pid=dead.pid, sock=os.path.join(self.temp, 'gone.sock'))
        self.assertEqual(sessions.rename_live('gone', 'Title')['reason'], 'not-running')

    def test_refuses_a_path_that_is_not_a_socket_and_a_socket_nobody_answers(self):
        plain = os.path.join(self.temp, 'plain.sock')
        Path(plain).write_text('')
        self.record('s1', sock=plain)
        self.assertEqual(sessions.rename_live('s1', 'Title')['reason'], 'no-inbox')
        stale = os.path.join(self.temp, 'stale.sock')
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(stale)
        listener.close()
        self.record('s1', sock=stale)
        self.assertEqual(sessions.rename_live('s1', 'Title')['reason'], 'unreachable')
