import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import struct
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import zlib

sys.path.insert(0, str(Path(__file__).parents[1]))
SPEC = importlib.util.spec_from_file_location('sessions', Path(__file__).parents[1] / 'sessions.py')
sessions = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sessions)


def png(width, height, seed=0):
    raw = b''.join(b'\x00' + bytes([seed % 256] * 3 * width) for _ in range(height))
    chunk = lambda kind, data: struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) + \
           chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')


def b64(data):
    return base64.b64encode(data).decode()


def sha1(data):
    return hashlib.sha1(data).hexdigest()


def user(uuid, content, at='2026-10-01T10:00:00Z', **extra):
    return {'type': 'user', 'uuid': uuid, 'timestamp': at, 'cwd': '/code/app', 'message': {'role': 'user', 'content': content}, **extra}


def reply(uuid, text='', tools=(), at='2026-10-01T10:00:01Z', **extra):
    content = ([{'type': 'text', 'text': text}] if text else []) + \
              [{'type': 'tool_use', 'id': call, 'name': name, 'input': value} for call, name, value in tools]
    return {'type': 'assistant', 'uuid': uuid, 'timestamp': at, 'message': {'id': 'm-' + uuid, 'model': 'claude-opus-5-5', 'content': content}, **extra}


def result(uuid, call, output='done', result=None, error=False, images=(), at='2026-10-01T10:00:02Z'):
    content = [{'type': 'text', 'text': output}] + [{'type': 'image', 'source': {'type': 'base64', 'data': b64(i), 'media_type': 'image/png'}} for i in images]
    entry = user(uuid, [{'type': 'tool_result', 'tool_use_id': call, 'content': content, 'is_error': error}], at)
    if result is not None:
        entry['toolUseResult'] = result
    return entry


def pasted(data):
    return {'type': 'image', 'source': {'type': 'base64', 'media_type': 'image/png', 'data': b64(data)}}


def item(kind, turn='t1', **fields):
    return {'type': 'event_msg', 'timestamp': '2026-10-09T10:00:05Z',
            'payload': {'type': 'item_completed', 'turn_id': turn, 'thread_id': 'thread-1', 'completed_at_ms': 1791560005000,
                        'item': {'type': kind, 'id': fields.pop('id', kind + '-1'), **fields}}}


def response(payload, at='2026-10-09T10:00:01Z'):
    return {'type': 'response_item', 'timestamp': at, 'payload': payload}


class RemoteTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name) / 'home'
        self.root = Path(self.temp.name) / 'SideA'
        self.project = self.home / '.claude/projects/-code-app'
        self.project.mkdir(parents=True)
        self.codex = self.home / '.codex/sessions/2026/10/09'
        self.codex.mkdir(parents=True)
        home = patch.object(Path, 'home', return_value=self.home); home.start(); self.addCleanup(home.stop)

    def tearDown(self):
        self.temp.cleanup()

    def write(self, sid, entries, mode='w', folder=None):
        path = (folder or self.project) / f'{sid}.jsonl'
        with open(path, mode) as stream:
            for entry in entries:
                stream.write(json.dumps(entry, separators=(',', ':')) + '\n')
        return path

    def rollout(self, thread, entries, mode='w', **meta):
        head = [] if mode == 'a' else [{'type': 'session_meta', 'timestamp': '2026-10-09T10:00:00Z',
                                        'payload': {'id': thread, 'cwd': '/code/api', 'source': 'cli', **meta}}]
        return self.write(f'rollout-2026-10-09-{thread}', head + entries, mode, self.codex)

    def page(self, sid, **options):
        return sessions.page(self.root, sid, **options)

    def tool(self, sid, name, **options):
        return next(t for m in self.page(sid, limit=200, **options)['messages'] for t in m['tools'] if t['name'] == name)

    def test_pages_have_stable_seq_and_cursors(self):
        self.write('s', [user(f'u{n}', f'Prompt {n}') for n in range(120)])
        newest = self.page('s')
        self.assertEqual([m['seq'] for m in newest['messages']], list(range(70, 120)))
        self.assertEqual((newest['count'], newest['has_more_after'], newest['reset']), (120, False, False))
        seen, cursor = [m['seq'] for m in newest['messages']], newest['before']
        while cursor:
            older = self.page('s', before=cursor)
            seen = [m['seq'] for m in older['messages']] + seen
            cursor = older['before']
        self.assertEqual(seen, list(range(120)))
        self.write('s', [reply('r1', 'Reply one'), reply('r2', 'Reply two')], 'a')
        later = self.page('s', after=newest['after'])
        self.assertEqual([(m['seq'], m['text']) for m in later['messages']], [(120, 'Reply one'), (121, 'Reply two')])
        self.assertEqual(later['replaced'], [])
        self.assertEqual([m['seq'] for m in self.page('s', before=later['after'], limit=3)['messages']], [118, 119, 120])
        self.assertEqual(self.page('s', after=later['after'])['messages'], [])
        with self.assertRaisesRegex(ValueError, 'Use one cursor'):
            self.page('s', before=newest['before'], after=newest['after'])
        with self.assertRaisesRegex(ValueError, 'Bad cursor'):
            self.page('s', after='nonsense')

    def test_a_result_rewrites_its_row_and_bumps_rev(self):
        self.write('s', [user('u0', 'Run the tests'), reply('a1', tools=[('toolu_1', 'Bash', {'command': 'swift test', 'run_in_background': True})])])
        first = self.page('s')
        self.assertEqual(first['messages'][-1]['tools'][0]['status'], 'running')
        self.write('s', [user('u1', 'Meanwhile, read the README'), result('r1', 'toolu_1', 'All 40 tests passed')], 'a')
        later = self.page('s', after=first['after'])
        self.assertEqual([m['text'] for m in later['messages']], ['Meanwhile, read the README'])
        self.assertEqual([m['seq'] for m in later['replaced']], [1])
        self.assertEqual(later['replaced'][0]['tools'][0]['status'], 'ok')
        self.assertEqual(later['replaced'][0]['tools'][0]['output'], 'All 40 tests passed')
        self.assertEqual(self.page('s', after=later['after'])['replaced'], [])

    def test_a_rewritten_transcript_gets_a_new_generation(self):
        self.write('s', [user('u0', 'First version')])
        first = self.page('s')
        self.write('s', [user('u9', 'Second version, longer'), user('u10', 'Another')])
        again = self.page('s', after=first['after'])
        self.assertTrue(again['reset'])
        self.assertNotEqual(again['generation'], first['generation'])
        self.assertEqual([m['text'] for m in again['messages']], ['Second version, longer', 'Another'])
        self.assertEqual(sessions.message(self.root, 's', 0, first['generation']), {'error': 'changed'})

    def test_default_show_is_unchanged(self):
        tools = [(f'toolu_{n}', 'Bash', {'command': f'echo {n}'}) for n in range(12)]
        self.write('s', [user('u0', 'Go'), reply('a1', 'Working on it', tools), result('r1', 'toolu_0'), user('u1', 'Thanks')])
        shown = sessions.show(self.root, 's')
        self.assertEqual(set(shown), {'session', 'messages', 'truncated', 'forks', 'parent', 'focus', 'later', 'inherited_before'})
        self.assertEqual([m['role'] for m in shown['messages']], ['user', 'assistant', 'tool', 'user'])
        self.assertEqual(shown['messages'][2], {'role': 'tool', 'text': '', 'tools': [f'Bash: echo {n}' for n in range(12)], 'uuid': 'a1',
                                                'ts': shown['messages'][2]['ts'], 'inherited': False, 'model': None})
        self.assertEqual(set(shown['messages'][0]), {'role', 'text', 'tools', 'uuid', 'ts', 'inherited', 'model'})
        # The remote rows split a long run of calls so no row grows past what the wire carries.
        self.assertEqual([len(m['tools']) for m in self.page('s')['messages'] if m['role'] == 'tools'], [8, 4])

    def test_tool_results_are_kept_and_cut(self):
        output = '\n'.join(f'line {n}' for n in range(10000))
        self.write('s', [user('u0', 'Build'), reply('a1', tools=[('toolu_1', 'Bash', {'command': 'make'}), ('toolu_2', 'Bash', {'command': 'false'})]),
                         result('r1', 'toolu_1', output, {'stdout': output, 'stderr': '', 'interrupted': False}),
                         result('r2', 'toolu_2', 'Exit code 1', error=True)])
        page = self.page('s')
        made, failed = page['messages'][-1]['tools']
        self.assertTrue(made['output_truncated'])
        self.assertTrue(made['output'].startswith('line 0\n') and made['output'].endswith('line 9999'))
        self.assertIn('\n…\n', made['output'])
        self.assertLessEqual(len(made['output']), 4000)
        self.assertEqual(failed['status'], 'failed')
        self.assertNotIn('src', made)
        whole = sessions.message(self.root, 's', page['messages'][-1]['seq'], page['generation'])
        self.assertEqual((whole['tools'][0]['output'], whole['tools'][0]['output_truncated']), (output, False))
        long = 'x' * 7000
        self.write('s', [reply('a2', long)], 'a')
        page = self.page('s')
        self.assertEqual((len(page['messages'][-1]['text']), page['messages'][-1]['text_truncated']), (6000, True))
        self.assertEqual(sessions.message(self.root, 's', page['messages'][-1]['seq'], page['generation'])['text'], long)

    def test_permission_denials_and_rejections_are_denied(self):
        self.write('s', [reply('a1', tools=[('toolu_1', 'Bash', {'command': 'rm -rf build'}), ('toolu_2', 'Edit', {'file_path': '/a', 'old_string': 'a', 'new_string': 'b'})]),
                         result('r1', 'toolu_1', 'Permission to use Bash has been denied.', error=True),
                         result('r2', 'toolu_2', "The user doesn't want to proceed with this tool use. The tool use was rejected.", 'User rejected tool use', error=True)])
        self.assertEqual([t['status'] for t in self.page('s')['messages'][0]['tools']], ['denied', 'denied'])

    def test_edit_diff_from_structured_patch(self):
        patch_ = [{'oldStart': 40, 'oldLines': 2, 'newStart': 40, 'newLines': 3, 'lines': [' let a = 1', '-let b = 2', '+let b = 3', '+let c = 4']}]
        original = 'secret whole file ' * 50
        self.write('s', [reply('a1', tools=[('toolu_1', 'Edit', {'file_path': '/code/app/Island.swift', 'old_string': 'let b = 2', 'new_string': 'let b = 3\nlet c = 4'})]),
                         result('r1', 'toolu_1', 'The file has been updated.', {'filePath': '/code/app/Island.swift', 'oldString': 'let b = 2',
                                'newString': 'let b = 3\nlet c = 4', 'originalFile': original, 'structuredPatch': patch_})])
        diff = self.tool('s', 'Edit')['diffs']
        self.assertEqual(diff, [{'path': '/code/app/Island.swift', 'old_path': None, 'change': 'modified', 'additions': 2, 'deletions': 1, 'truncated': False,
                                 'hunks': [{'old_start': 40, 'old_count': 2, 'new_start': 40, 'new_count': 3, 'lines': patch_[0]['lines']}]}])
        db = sqlite3.connect(self.root / 'runtime/sessions.db')
        self.assertFalse(any('secret whole file' in row[0] for row in db.execute('SELECT data FROM views')))
        db.close()

    def test_edit_diff_without_tool_use_result(self):
        self.write('s', [reply('a1', tools=[('toolu_1', 'Edit', {'file_path': '/a.swift', 'old_string': 'one\ntwo', 'new_string': 'three'}),
                                            ('toolu_2', 'MultiEdit', {'file_path': '/b.swift', 'edits': [{'old_string': 'x', 'new_string': 'y'}, {'old_string': 'p', 'new_string': 'q'}]})]),
                         result('r1', 'toolu_1', "The user doesn't want to proceed with this tool use.", 'User rejected tool use', error=True)])
        edit, multi = self.page('s')['messages'][0]['tools']
        self.assertEqual(edit['diffs'][0]['hunks'], [{'old_start': 0, 'old_count': 2, 'new_start': 0, 'new_count': 1, 'lines': ['-one', '-two', '+three']}])
        self.assertEqual((edit['diffs'][0]['additions'], edit['diffs'][0]['deletions']), (1, 2))
        self.assertEqual([h['lines'] for h in multi['diffs'][0]['hunks']], [['-x', '+y'], ['-p', '+q']])

    def test_a_turn_diff_is_the_edits_that_went_through_from_its_prompt_to_the_next(self):
        patch_ = lambda old, new: [{'oldStart': 1, 'oldLines': 1, 'newStart': 1, 'newLines': 1, 'lines': [f'-{old}', f'+{new}']}]
        edit = lambda call, path, old, new: (call, 'Edit', {'file_path': path, 'old_string': old, 'new_string': new})
        done = lambda uuid, call, path, old, new: result(uuid, call, 'The file has been updated.',
                                                         {'filePath': path, 'oldString': old, 'newString': new, 'structuredPatch': patch_(old, new)})
        self.write('s', [user('u1', 'Rename a to b'), reply('a1', tools=[edit('toolu_1', '/code/app/x.swift', 'a', 'b')]),
                         done('r1', 'toolu_1', '/code/app/x.swift', 'a', 'b'),
                         user('u2', 'Now c and d'),
                         reply('a2', tools=[edit('toolu_2', '/code/app/x.swift', 'b', 'c'), edit('toolu_3', '/code/app/x.swift', 'c', 'd'),
                                            edit('toolu_5', '/code/app/y.swift', 'p', 'q'), ('toolu_4', 'Bash', {'command': "sed -i '' s/q/r/ y.swift"})]),
                         done('r2', 'toolu_2', '/code/app/x.swift', 'b', 'c'), done('r3', 'toolu_3', '/code/app/x.swift', 'c', 'd'),
                         result('r5', 'toolu_5', "The user doesn't want to proceed with this tool use.", 'User rejected tool use', error=True),
                         result('r4', 'toolu_4', '')])
        newest = sessions.turn_diff(self.root, 's')
        # Two edits to one file stay two diffs, as each saw the file; the rejected edit and the shell change aren't there.
        self.assertEqual((newest['turn_id'], [d['hunks'][0]['lines'] for d in newest['files']], newest['running'], newest['omitted']),
                         ('u2', [['-b', '+c'], ['-c', '+d']], False, 0))
        self.assertEqual(newest['note'], "Edits made with Claude's file tools; shell changes aren't shown.")
        self.assertEqual([d['hunks'][0]['lines'] for d in sessions.turn_diff(self.root, 's', 'u1')['files']], [['-a', '+b']])
        with self.assertRaisesRegex(ValueError, "isn't in this conversation"):
            sessions.turn_diff(self.root, 's', 'a1')
        self.rollout('t', [item('userMessage', content=[{'type': 'text', 'text': 'hi'}])])
        with self.assertRaisesRegex(ValueError, 'Codex'):
            sessions.turn_diff(self.root, 't')

    def test_write_create_is_an_added_file(self):
        content = ''.join(f'row {n}\n' for n in range(3000))
        self.write('s', [reply('a1', tools=[('toolu_1', 'Write', {'file_path': '/new.txt', 'content': content})]),
                         result('r1', 'toolu_1', 'File created', {'type': 'create', 'filePath': '/new.txt', 'content': content, 'structuredPatch': []})])
        page = self.page('s')
        diff = page['messages'][0]['tools'][0]['diffs'][0]
        self.assertEqual((diff['change'], diff['additions'], diff['truncated']), ('added', 3000, True))
        self.assertEqual(sum(len(h['lines']) for h in diff['hunks']), 2000)
        self.assertEqual(diff['hunks'][0]['lines'][0], '+row 0')
        whole = sessions.message(self.root, 's', 0, page['generation'])['tools'][0]['diffs'][0]
        self.assertEqual((sum(len(h['lines']) for h in whole['hunks']), whole['truncated']), (3000, False))

    def test_rows_stay_small_however_large_the_tools(self):
        big = 'y' * 60000
        tools = [(f'toolu_{n}', 'Edit', {'file_path': f'/f{n}', 'old_string': big, 'new_string': big + 'z'}) for n in range(20)]
        self.write('s', [reply('a1', tools=tools)])
        for message in self.page('s')['messages']:
            self.assertLess(len(json.dumps(message)), 1 << 20)
            for tool in message['tools']:
                self.assertLessEqual(len(json.dumps(tool)), sessions.TOOL_BUDGET + 2000)

    def test_codex_file_change_diffs(self):
        changes = {'/code/api/upload.py': {'type': 'update', 'unified_diff': '@@ -1,2 +1,2 @@\n import os\n-old()\n+new()\n\\ No newline at end of file\n', 'move_path': None},
                   '/code/api/new.py': {'type': 'add', 'content': 'a = 1\nb = 2\n'},
                   '/code/api/a.py': {'type': 'update', 'unified_diff': '@@ -3 +3 @@\n-x\n+y\n', 'move_path': '/code/api/b.py'}}
        self.rollout('thread-1', [item('FileChange', changes=changes, status='completed')])
        diffs = {d['path']: d for d in self.tool('thread-1', 'apply_patch')['diffs']}
        self.assertEqual(diffs['/code/api/upload.py']['hunks'], [{'old_start': 1, 'old_count': 2, 'new_start': 1, 'new_count': 2,
                                                                   'lines': [' import os', '-old()', '+new()', '\\ No newline at end of file']}])
        self.assertEqual((diffs['/code/api/new.py']['change'], diffs['/code/api/new.py']['additions']), ('added', 2))
        self.assertEqual((diffs['/code/api/b.py']['change'], diffs['/code/api/b.py']['old_path']), ('renamed', '/code/api/a.py'))
        self.assertEqual(diffs['/code/api/b.py']['hunks'][0]['old_count'], 1)

    def test_codex_exec_groups_its_commands(self):
        self.rollout('thread-1', [
            {'type': 'event_msg', 'timestamp': '2026-10-09T10:00:01Z', 'payload': {'type': 'task_started', 'turn_id': 't1'}},
            response({'type': 'message', 'role': 'user', 'content': [{'type': 'input_text', 'text': 'Run the tests'}]}),
            response({'type': 'custom_tool_call', 'name': 'exec', 'call_id': 'call_1', 'input': 'run("pytest")'}),
            item('CommandExecution', id='cmd_1', command=['/bin/zsh', '-lc', 'pytest -k upload'], cwd='/code/api', exit_code=0, aggregated_output='1 passed', status='completed'),
            item('CommandExecution', id='cmd_2', command=['/bin/zsh', '-lc', 'ruff check'], cwd='/code/api', exit_code=1, aggregated_output='E501', status='failed'),
            response({'type': 'custom_tool_call_output', 'call_id': 'call_1', 'output': [{'type': 'input_text', 'text': 'finished'}]}),
            {'type': 'event_msg', 'timestamp': '2026-10-09T10:00:09Z', 'payload': {'type': 'task_complete', 'turn_id': 't1', 'error': {'message': 'Stream disconnected'}}},
            {'type': 'compacted', 'timestamp': '2026-10-09T10:00:10Z', 'payload': {'message': ''}}])
        messages = self.page('thread-1')['messages']
        self.assertEqual([m['role'] for m in messages], ['user', 'tools', 'error', 'compact'])
        exec_, first, second = messages[1]['tools']
        self.assertEqual((exec_['name'], exec_['group'], exec_['input'], exec_['status'], exec_['output']), ('exec', True, {'code': 'run("pytest")'}, 'ok', 'finished'))
        self.assertEqual([(t['input']['command'], t['status'], t['parent']) for t in (first, second)],
                         [('pytest -k upload', 'ok', 'call_1'), ('ruff check', 'failed', 'call_1')])
        self.assertEqual(messages[2]['text'], 'Stream disconnected')
        # The Mac's viewer still shows the exec call as one line.
        self.assertEqual(sessions.show(self.root, 'thread-1')['messages'][1]['tools'], ['exec: run("pytest")'])

    def test_a_command_written_after_its_exec_output_still_folds_under_it(self):
        self.rollout('thread-1', [
            response({'type': 'custom_tool_call', 'name': 'exec', 'call_id': 'call_1', 'input': 'go()'}),
            response({'type': 'custom_tool_call_output', 'call_id': 'call_1', 'output': 'ok'}),
            item('CommandExecution', id='cmd_late', command='ls', cwd='/code', exit_code=0, aggregated_output='', status='completed')])
        tools = self.page('thread-1')['messages'][0]['tools']
        self.assertEqual([(t['name'], t.get('parent'), t.get('group')) for t in tools], [('exec', None, True), ('exec_command', 'call_1', None)])

    def test_an_mcp_item_repeating_a_running_call_is_dropped(self):
        self.rollout('thread-1', [
            response({'type': 'function_call', 'name': 'js', 'call_id': 'call_2', 'arguments': '{"code": "1"}'}),
            item('McpToolCall', id='mcp_1', server='repl', tool='js', arguments='{"code": "1"}', result={'content': [{'type': 'text', 'text': '1'}]}, status='completed'),
            response({'type': 'function_call_output', 'call_id': 'call_2', 'output': '1'}),
            item('McpToolCall', id='mcp_2', server='repl', tool='eval', arguments='{}', result={'content': [{'type': 'text', 'text': '2'}]}, status='completed')])
        tools = self.page('thread-1')['messages'][0]['tools']
        self.assertEqual([(t['id'], t['name'], t['output']) for t in tools], [('call_2', 'js', '1'), ('mcp_2', 'mcp__repl__eval', '2')])

    def test_thinking_rows_with_durations(self):
        long = 'hmm ' * 2000
        thought = lambda uuid, text, at, kind='thinking': {'type': 'assistant', 'uuid': uuid, 'timestamp': at,
                                                         'message': {'id': 'm1', 'content': [{'type': kind, kind if kind == 'thinking' else 'data': text, 'signature': 'sig'}]}}
        self.write('s', [user('u0', 'Plan it', '2026-10-01T10:00:00Z'), thought('t1', long, '2026-10-01T10:00:12.500Z'),
                         reply('a1', 'Here is the plan', [('toolu_1', 'Bash', {'command': 'ls'})], '2026-10-01T10:00:13Z'),
                         thought('t2', '', '2026-10-01T10:00:15Z'), reply('a2', tools=[('toolu_2', 'Bash', {'command': 'pwd'})], at='2026-10-01T10:00:16Z'),
                         thought('t3', 'opaque', '2026-10-01T10:00:20Z', 'redacted_thinking')])
        page = self.page('s')
        thinking = [m for m in page['messages'] if m['role'] == 'thinking']
        self.assertEqual([(m['uuid'], len(m['text']), m['text_truncated'], m['duration_ms']) for m in thinking],
                         [('t1', 6000, True, 12500), ('t2', 0, False, 2000), ('t3', 0, False, 4000)])
        self.assertEqual(sessions.message(self.root, 's', thinking[0]['seq'], page['generation'])['text'], long)
        self.assertIsNone(page['messages'][0]['duration_ms'])
        # The viewer never sees thinking, and the calls on either side of it still read as one run.
        shown = sessions.show(self.root, 's')['messages']
        self.assertEqual([m['role'] for m in shown], ['user', 'assistant', 'tool'])
        self.assertEqual(shown[2]['tools'], ['Bash: ls', 'Bash: pwd'])
        self.rollout('thread-1', [{'type': 'event_msg', 'timestamp': '2026-10-09T10:00:04Z',
                                   'payload': {'type': 'item_completed', 'turn_id': 't1', 'started_at_ms': 1791560000000, 'completed_at_ms': 1791560003250,
                                               'item': {'type': 'Reasoning', 'id': 'rs_1', 'summary_text': ['Reading the tests', 'Then the fix'], 'raw_content': []}}},
                                  response({'type': 'reasoning', 'id': 'rs_1', 'summary': [], 'encrypted_content': 'x'})])
        codex = self.page('thread-1')['messages']
        self.assertEqual([(m['role'], m['text'], m['duration_ms'], m['ts']) for m in codex],
                         [('thinking', 'Reading the tests\n\nThen the fix', 3250, 1791560000.0)])

    def test_the_viewers_counts_leave_out_hidden_rows(self):
        entries = []
        for n in range(30):
            entries += [user(f'u{n}', f'Prompt {n}'),
                        {'type': 'assistant', 'uuid': f't{n}', 'timestamp': '2026-10-01T10:00:01Z', 'message': {'content': [{'type': 'thinking', 'thinking': ''}]}},
                        reply(f'a{n}', f'Answer {n}', [(f'toolu_{n}_{k}', 'Bash', {'command': f'echo {k}'}) for k in range(10)])]
        self.write('s', entries)
        whole = sessions.show(self.root, 's')
        # Each turn is a prompt, a reply and one line of ten calls, though Remote holds five rows for it.
        self.assertEqual((len(whole['messages']), whole['truncated'], whole['later']), (90, 0, 0))
        self.assertEqual(self.page('s')['count'], 150)
        newest = sessions.show(self.root, 's', limit=10)
        self.assertEqual((len(newest['messages']), newest['truncated'], newest['later']), (10, 80, 0))
        self.assertEqual(newest['messages'][0]['role'], 'tool')
        around = sessions.show(self.root, 's', limit=10, around='u2')
        self.assertEqual((around['focus'], around['truncated'], len(around['messages']), around['later']), ('u2', 0, 10, 80))
        self.assertEqual(around['messages'][6]['text'], 'Prompt 2')

    def test_todos_and_plans(self):
        todos = [{'content': 'Write tests', 'status': 'in_progress', 'activeForm': 'Writing tests'}]
        self.write('s', [reply('a1', tools=[('toolu_1', 'TodoWrite', {'todos': todos}), ('toolu_2', 'TaskCreate', {'subject': 'Ship it', 'activeForm': 'Shipping'}),
                                            ('toolu_3', 'TaskUpdate', {'taskId': '1', 'status': 'completed'}),
                                            ('toolu_4', 'ExitPlanMode', {'plan': '1. Do the thing', 'planFilePath': '/p.md'})]),
                         result('r1', 'toolu_1', 'ok', {'oldTodos': [], 'newTodos': [{**todos[0], 'status': 'completed'}]})])
        todo, create, update, plan = self.page('s')['messages'][0]['tools']
        self.assertEqual(todo['todos'], [{'content': 'Write tests', 'status': 'completed', 'active_form': 'Writing tests'}])
        self.assertEqual(create['todos'], [{'content': 'Ship it', 'status': 'pending', 'active_form': 'Shipping'}])
        self.assertEqual((update['todos'][0]['id'], update['todos'][0]['status']), ('1', 'completed'))
        self.assertEqual(plan['plan'], '1. Do the thing')
        self.rollout('thread-1', [response({'type': 'function_call', 'name': 'update_plan', 'call_id': 'c1',
                                            'arguments': json.dumps({'plan': [{'step': 'Read code', 'status': 'completed'}, {'step': 'Fix', 'status': 'pending'}]})})])
        self.assertEqual(self.tool('thread-1', 'update_plan')['todos'], [{'content': 'Read code', 'status': 'completed', 'active_form': None},
                                                                         {'content': 'Fix', 'status': 'pending', 'active_form': None}])

    def test_subagent_marker_and_transcript(self):
        self.write('s', [user('u0', 'Look around'), reply('a1', tools=[('toolu_9', 'Agent', {'description': 'Survey the bridge', 'prompt': 'Go', 'subagent_type': 'Explore'})]),
                         result('r1', 'toolu_9', 'Launched', {'agentId': 'abc123', 'status': 'async_launched', 'description': 'Survey the bridge'})])
        folder = self.project / 's/subagents'; folder.mkdir(parents=True)
        self.write('agent-abc123', [user('su0', 'Go', isSidechain=True), reply('sa1', 'Found three files', isSidechain=True)], folder=folder)
        (folder / 'agent-abc123.meta.json').write_text(json.dumps({'agentType': 'Explore', 'toolUseId': 'toolu_9'}))
        agent = self.tool('s', 'Agent')
        self.assertEqual((agent['subagent'], agent['agent_id']), ('Survey the bridge', 'abc123'))
        self.assertEqual([m['text'] for m in self.page('s')['messages']], ['Look around', None])
        sub = self.page('s', agent_id='abc123')
        self.assertEqual((sub['agent_id'], [m['text'] for m in sub['messages']]), ('abc123', ['Go', 'Found three files']))
        with self.assertRaises(ValueError):
            self.page('s', agent_id='../../etc')

    def test_queued_prompt_with_image_is_shown_and_indexed(self):
        image = png(3, 2, 7)
        queued = {'type': 'attachment', 'uuid': 'q1', 'timestamp': '2026-10-01T10:00:03Z',
                  'attachment': {'type': 'queued_command', 'commandMode': 'prompt', 'prompt': [{'type': 'text', 'text': 'Also fix the pelican'}, pasted(image)]}}
        notification = {'type': 'attachment', 'uuid': 'q2', 'attachment': {'type': 'queued_command', 'commandMode': 'task-notification', 'prompt': '<task-notification>x'}}
        # A follow-up from Side A that reached a busy session, as Claude Code 2.1.302 queues it.
        follow_up = {'type': 'attachment', 'uuid': 'q3', 'timestamp': '2026-10-01T10:00:04Z', 'attachment': {
            'type': 'queued_command', 'commandMode': 'task-notification',
            'prompt': '<task-notification>\n<summary>Stop hook feedback</summary>\n</task-notification>\n<system-reminder>\n'
                      'Stop hook blocking error from command "Stop": The user sent you this from Side A:\n\nAnd the heron\n\n</system-reminder>'}}
        self.write('s', [user('u0', 'Start'), queued, notification, follow_up])
        sessions.index(self.root)
        rows = self.page('s')['messages']
        self.assertEqual([(m['role'], m['text'], m['uuid']) for m in rows],
                         [('user', 'Start', 'u0'), ('user', 'Also fix the pelican', 'q1'), ('user', 'And the heron', 'q3')])
        self.assertEqual([s['id'] for s in sessions.search(self.root, 'heron')['sessions']], ['s'])
        self.assertEqual([(i['id'], i['source'], i['width'], i['height']) for i in rows[1]['images']], [(sha1(image), 'pasted', 3, 2)])
        self.assertEqual([s['id'] for s in sessions.search(self.root, 'pelican')['sessions']], ['s'])
        self.assertEqual(sessions.images(self.root, 's')['images'][0]['seq'], 1)

    def test_a_version_5_index_keeps_its_search_and_reads_conversations_again(self):
        self.write('s', [user('u0', 'Keep the okapi searchable')])
        sessions.index(self.root)
        self.page('s')
        db = sessions.connect(self.root)
        db.execute('PRAGMA user_version=5')
        db.commit()
        indexed = db.execute('SELECT count(*) FROM msgs').fetchone()[0]
        self.assertGreater(db.execute('SELECT count(*) FROM views').fetchone()[0], 0)
        db.close()
        db = sessions.connect(self.root)
        self.assertEqual(db.execute('PRAGMA user_version').fetchone()[0], sessions.VERSION)
        self.assertEqual((db.execute('SELECT count(*) FROM msgs').fetchone()[0], db.execute('SELECT count(*) FROM views').fetchone()[0]), (indexed, 0))
        db.close()
        self.assertEqual([s['id'] for s in sessions.search(self.root, 'okapi')['sessions']], ['s'])
        self.assertEqual([m['text'] for m in self.page('s')['messages']], ['Keep the okapi searchable'])

    def test_mains_version_5_index_gains_the_remote_tables(self):
        # main's version 5 has neither view revisions nor images, so the same number can't be trusted.
        self.write('s', [user('u0', 'Keep the tapir searchable')])
        sessions.index(self.root)
        db = sessions.connect(self.root)
        db.executescript("DROP TABLE views; DROP TABLE view_state; DROP TABLE images; "
                         "CREATE TABLE views(session TEXT, seq INTEGER, uuids TEXT, data TEXT, PRIMARY KEY(session, seq)) WITHOUT ROWID; "
                         "CREATE TABLE view_state(session TEXT PRIMARY KEY, path TEXT, offset INTEGER, head TEXT, count INTEGER, used REAL); "
                         "INSERT INTO views VALUES('s', 0, 'old', '{}'); PRAGMA user_version=5;")
        indexed = db.execute('SELECT count(*) FROM msgs').fetchone()[0]
        db.close()
        db = sessions.connect(self.root)
        self.assertEqual(db.execute('PRAGMA user_version').fetchone()[0], sessions.VERSION)
        self.assertIn('rev', {row[1] for row in db.execute('PRAGMA table_info(views)')})
        self.assertEqual((db.execute('SELECT count(*) FROM msgs').fetchone()[0], db.execute('SELECT count(*) FROM views').fetchone()[0]), (indexed, 0))
        db.close()
        self.assertEqual([m['text'] for m in self.page('s')['messages']], ['Keep the tapir searchable'])
        self.assertEqual(sessions.images(self.root, 's')['images'], [])

    def test_images_are_indexed_once_and_never_stored(self):
        shot, paste = png(4, 4, 1), png(5, 3, 2)
        read = result('r1', 'toolu_1', 'Read image', {'type': 'image', 'file': {'base64': b64(shot), 'type': 'image/png', 'dimensions': {'originalWidth': 4}}}, images=[shot])
        blob = {'type': 'api-request-blob', 'data': {'messages': [{'content': [{'type': 'image', 'source': {'type': 'base64', 'data': b64(shot)}}, pasted(paste)]}]}}
        self.write('s', [reply('a1', tools=[('toolu_1', 'Read', {'file_path': '/shots/home.png'})]), read, user('u1', [{'type': 'text', 'text': '[Image #1] this'}, pasted(paste)]), blob])
        sessions.index(self.root)
        db = sqlite3.connect(self.root / 'runtime/sessions.db')
        self.assertEqual(sorted(db.execute('SELECT id, source, tool FROM images').fetchall()), sorted([(sha1(shot), 'read', 'Read'), (sha1(paste), 'pasted', None)]))
        db.close()
        page = self.page('s')
        read_tool = page['messages'][0]['tools'][0]
        self.assertEqual([(i['id'], i['name'], i['source']) for i in read_tool['images']], [(sha1(shot), 'home.png', 'read')])
        self.assertEqual((page['messages'][1]['text'], page['messages'][1]['images'][0]['id']), ('[Image #1] this', sha1(paste)))
        stored = b''.join(path.read_bytes() for path in (self.root / 'runtime').glob('sessions.db*'))
        for data in (shot, paste):
            self.assertNotIn(b64(data).encode(), stored)

    def test_image_locator_points_at_the_bytes(self):
        image = png(64, 48, 3)
        path = self.write('s', [user('u0', [pasted(image)])])
        sessions.index(self.root)
        located = sessions.image(self.root, sha1(image))
        self.assertEqual((located['kind'], located['mime'], located['width'], located['height'], located['bytes']), ('inline', 'image/png', 64, 48, len(image)))
        with open(path, 'rb') as stream:
            stream.seek(located['data_offset'])
            self.assertEqual(base64.b64decode(stream.read(located['data_length'])), image)
        self.assertEqual(sessions.image(self.root, '0' * 40), {'error': 'gone'})
        # The file rewritten under the same name: the recheck finds the bytes moved or gone.
        self.write('s', [user('u9', 'No pictures now, and a longer line than before')])
        self.assertEqual(sessions.image(self.root, sha1(image), recheck=True), {'error': 'gone'})

    def test_parse_mode_when_key_order_differs(self):
        image = png(2, 2, 4)
        line = '{"type":"user","uuid":"u0","toolUseResult":{"x":1},"message":{"role":"user","content":[{"type":"image","source":{"type":"base64","data":"%s","media_type":"image/png"}}]}}\n' % b64(image)
        (self.project / 's.jsonl').write_text(line)
        sessions.index(self.root)
        located = sessions.image(self.root, sha1(image))
        self.assertEqual((located['kind'], located['block']), ('line', 0))
        with open(located['path'], 'rb') as stream:
            stream.seek(located['line_offset'])
            entry = json.loads(stream.read(located['line_length']))
        self.assertEqual(base64.b64decode(entry['message']['content'][located['block']]['source']['data']), image)

    def test_fork_copies_share_the_image_id(self):
        image = png(3, 3, 5)
        original = user('u0', [{'type': 'text', 'text': 'Look'}, pasted(image)])
        self.write('parent', [original])
        self.write('child', [{**original, 'forkedFrom': {'sessionId': 'parent', 'messageUuid': 'u0'}}, user('c1', 'Go on')])
        sessions.index(self.root)
        db = sqlite3.connect(self.root / 'runtime/sessions.db')
        self.assertEqual(sorted(db.execute('SELECT session, inherited, id FROM images').fetchall()),
                         [('child', 1, sha1(image)), ('parent', 0, sha1(image))])
        db.close()
        self.assertTrue(self.page('child')['messages'][0]['inherited'])

    def test_codex_images(self):
        shot, paste, viewed = (png(6, 6, n) + os.urandom(400) for n in range(3))
        view = Path(self.temp.name) / 'view.png'; view.write_bytes(viewed)
        notes = Path(self.temp.name) / 'notes.txt'; notes.write_text('not an image')
        url = lambda data: 'data:image/png;base64,' + b64(data)
        self.rollout('thread-1', [
            {'type': 'event_msg', 'timestamp': '2026-10-09T10:00:01Z', 'payload': {'type': 'task_started', 'turn_id': 't1'}},
            response({'type': 'message', 'role': 'user', 'content': [{'type': 'input_text', 'text': 'What is this?'}, {'type': 'input_image', 'image_url': url(paste)}]}),
            item('UserMessage', content=[{'type': 'local_image', 'path': '/tmp/gone/paste.png'}]),
            response({'type': 'function_call', 'name': 'screenshot', 'call_id': 'c1', 'arguments': '{}'}),
            response({'type': 'function_call_output', 'call_id': 'c1', 'output': [{'type': 'input_image', 'image_url': url(shot)}]}),
            item('ImageView', id='view_1', path=str(view)),
            item('ImageView', id='view_2', path='/nowhere/missing.png'),
            item('ImageView', id='view_3', path=str(notes))])
        sessions.index(self.root)
        db = sqlite3.connect(self.root / 'runtime/sessions.db')
        rows = {row[0]: row[1:] for row in db.execute('SELECT source, id, bytes, file FROM images WHERE file IS NULL OR file NOT LIKE "%notes%"')}
        self.assertEqual(rows['pasted'][0], sha1(paste))
        self.assertEqual(rows['screenshot'][0], sha1(shot))
        views = db.execute("SELECT id, bytes, file FROM images WHERE source='view' ORDER BY file").fetchall()
        db.close()
        self.assertNotIn('/tmp/gone/paste.png', [v[2] for v in views])
        self.assertIn((sha1(viewed), len(viewed), str(view)), views)
        self.assertIn((sha1('missing:/nowhere/missing.png'.encode()), None, '/nowhere/missing.png'), views)
        self.assertEqual(sessions.image(self.root, sha1(viewed))['kind'], 'file')
        self.assertEqual(sessions.image(self.root, sha1('missing:/nowhere/missing.png'.encode())), {'error': 'gone'})
        refused = [row for row in views if row[2] == str(notes)]
        self.assertEqual(sessions.image(self.root, refused[0][0]), {'error': 'gone'})
        messages = self.page('thread-1')['messages']
        self.assertEqual(messages[0]['images'][0]['id'], sha1(paste))
        self.assertEqual(self.tool('thread-1', 'screenshot')['images'][0]['source'], 'screenshot')

    def test_upgrade_from_4_keeps_the_index_and_backfills_images(self):
        image = png(9, 9, 6)
        self.write('s', [user('u0', [{'type': 'text', 'text': 'The zebra picture'}, pasted(image)])])
        sessions.index(self.root)
        db = sqlite3.connect(self.root / 'runtime/sessions.db')
        db.executescript('DROP TABLE views; DROP TABLE view_state; DROP TABLE images;'
                         'CREATE TABLE views(session TEXT, seq INTEGER, uuids TEXT, data TEXT, PRIMARY KEY(session, seq)) WITHOUT ROWID;'
                         'CREATE TABLE view_state(session TEXT PRIMARY KEY, path TEXT, offset INTEGER, head TEXT, count INTEGER, used REAL);')
        for path, state in db.execute('SELECT path, state FROM files').fetchall():
            state = json.loads(state); state.pop('img', None)
            db.execute('UPDATE files SET state=? WHERE path=?', (json.dumps(state), path))
        db.execute('PRAGMA user_version=4'); db.commit(); db.close()
        with patch.object(sessions, 'index_claude', side_effect=AssertionError('reindexed')):
            self.assertEqual([s['id'] for s in sessions.search(self.root, 'zebra')['sessions']], ['s'])
            done = sessions.index(self.root)
        self.assertEqual(done['images_remaining'], 0)
        db = sqlite3.connect(self.root / 'runtime/sessions.db')
        self.assertEqual(db.execute('PRAGMA user_version').fetchone()[0], sessions.VERSION)
        self.assertEqual(db.execute('SELECT id FROM images').fetchall(), [(sha1(image),)])
        db.close()
        self.assertEqual(self.page('s')['messages'][0]['images'][0]['id'], sha1(image))

    def test_large_image_lines_are_parsed_blanked(self):
        big = png(1200, 1000, 9) + os.urandom(4 << 20)
        self.write('s', [user('u0', [{'type': 'text', 'text': 'Huge one'}, pasted(big)])])
        loads = json.loads
        def small_only(text, *args, **kwargs):
            if len(text) > 1 << 20:
                raise AssertionError('parsed a large line whole')
            return loads(text, *args, **kwargs)
        with patch.object(sessions.json, 'loads', side_effect=small_only):
            sessions.index(self.root)
            page = self.page('s')
        self.assertEqual((page['messages'][0]['images'][0]['id'], page['messages'][0]['images'][0]['width']), (sha1(big), 1200))

    def test_live_codex_status(self):
        def turn(*events):
            return [{'type': 'event_msg', 'timestamp': '2026-10-09T10:00:0%dZ' % n, 'payload': payload} for n, payload in enumerate(events)]
        main = self.rollout('thread-1', turn({'type': 'task_started', 'turn_id': 't1', 'started_at': 1791560000}))
        child = self.rollout('thread-2', [], parent_thread_id='thread-1', source={'subagent': 'x'})
        # Only 100 is a session: an app server, a one-shot exec and a helper aren't, and 104, a Codex that 100
        # started (under its helper), is part of 100's session, even with the same rollouts open.
        args = {100: '/opt/homebrew/bin/codex --yolo', 101: '/opt/homebrew/bin/codex app-server', 102: 'codex exec hi',
                103: '/usr/bin/codex-code-mode-host', 104: '/opt/homebrew/bin/codex resume', 200: 'zsh'}
        tree = ({100: 50.0, 101: 1.0, 102: 1.0, 103: 1.0, 104: 1.0, 200: 1.0}, {200: [100], 100: [103], 103: [104]}, {100: 1791559000}, args)
        def live():
            with patch.object(sessions, 'process_tree', return_value=tree), patch.object(sessions, 'listening', return_value={}), \
                    patch.object(sessions, 'tmux_panes', return_value={}), \
                    patch.object(sessions, 'codex_open', side_effect=lambda pids: {pid: {'rollouts': [str(main), str(child)], 'cwd': '/code/api'} for pid in pids}):
                return sessions.live(self.root)['sessions']
        busy = live()
        self.assertEqual([(s['agent'], s['pid'], s['id'], s['status'], s['subagents'], s['since']) for s in busy],
                         [('codex', 100, 'thread-1', 'busy', 1, 1791560000.0)])
        self.rollout('thread-1', [response({'type': 'function_call', 'name': 'request_user_input', 'call_id': 'q1', 'arguments': '{}'})], 'a')
        self.assertEqual((live()[0]['status'], live()[0]['waitingFor']), ('waiting', 'question'))
        self.rollout('thread-1', turn({'type': 'task_complete', 'turn_id': 't1', 'completed_at': 1791560100}), 'a')
        self.assertEqual((live()[0]['status'], live()[0]['since']), ('idle', 1791560100.0))
        # A long rollout with no turn event in reach is unknown, never idle.
        self.rollout('thread-1', [response({'type': 'reasoning', 'summary': [], 'text': 'z' * 5000})] * 1000)
        self.assertEqual(live()[0]['status'], 'unknown')

    def test_live_codex_finds_a_closed_rollout_by_folder(self):
        today = self.home / '.codex/sessions' / time.strftime('%Y/%m/%d'); today.mkdir(parents=True, exist_ok=True)
        self.write('rollout-x-thread-9', [{'type': 'session_meta', 'payload': {'id': 'thread-9', 'cwd': '/code/web'}},
                                          {'type': 'event_msg', 'payload': {'type': 'task_complete', 'turn_id': 't', 'completed_at': 1791560100}}], folder=today)
        tree = ({100: 1.0}, {}, {100: int(time.time()) - 60}, {100: 'codex'})
        with patch.object(sessions, 'process_tree', return_value=tree), patch.object(sessions, 'listening', return_value={}), \
                patch.object(sessions, 'tmux_panes', return_value={100: 'side-a-1'}), \
                patch.object(sessions, 'codex_open', return_value={100: {'rollouts': [], 'cwd': '/code/web'}}):
            found = sessions.live(self.root)['sessions']
        self.assertEqual([(s['id'], s['status'], s['hosted']) for s in found], [('thread-9', 'idle', 'side-a-1')])

    def test_codex_health_reads_commands(self):
        command = lambda n, code: {'payload': {'type': 'item_completed', 'item': {'type': 'CommandExecution', 'command': ['bash', '-c', f'make {n}'], 'exit_code': code}}}
        found = sessions.codex_health([command(n, 2) for n in range(4)] + [{'payload': {'type': 'token_count', 'info': {'last_token_usage': {'input_tokens': 10, 'cached_input_tokens': 5}}}}], 'busy', 0)
        self.assertEqual((found['activity'], found['context'], found['flag']['kind']), ('Running make 3', 15, 'failing'))

    def test_thumbnail_sweep(self):
        image = png(2, 2, 8)
        self.write('s', [user('u0', [pasted(image)])])
        sessions.index(self.root)
        thumbs = self.root / 'runtime/thumbs'; thumbs.mkdir()
        orphan = thumbs / ('0' * 40 + '.jpg'); orphan.write_bytes(b'x')
        kept = thumbs / f'{sha1(image)}.jpg'; kept.write_bytes(b'y' * 100)
        db = sessions.connect(self.root)
        db.execute("INSERT INTO images(id, session, path, line_offset, line_length, block) VALUES(?, 's', '/x', 0, 1, 0)", ('1' * 40,))
        old = thumbs / ('1' * 40 + '.jpg'); old.write_bytes(b'z' * 100)
        os.utime(old, (time.time() - 100, time.time() - 100))
        sessions.sweep_thumbnails(self.root, db, cap=150)
        self.assertEqual(sorted(p.name for p in thumbs.glob('*.jpg')), [kept.name])
        orphan.write_bytes(b'x')
        sessions.sweep_thumbnails(self.root, db, cap=150)
        self.assertTrue(orphan.exists())  # swept less than an hour ago
        db.close()


if __name__ == '__main__':
    unittest.main()
