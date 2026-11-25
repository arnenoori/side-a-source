import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]))
import hostos


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).parents[1] / f'{name}.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ClaudeFoldersTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name) / 'home'
        self.account = Path(self.temp.name) / 'accounts' / 'work'
        (self.account / 'sessions').mkdir(parents=True)
        (self.account / 'projects' / '-code-app').mkdir(parents=True)
        (self.home / '.claude' / 'sessions').mkdir(parents=True)
        self.list = Path(self.temp.name) / 'dirs.json'
        self.list.write_text(json.dumps([str(self.account), 'relative/ignored', 7]))
        env = patch.dict(os.environ, {'HOME': str(self.home), 'SIDEAD_CLAUDE_DIRS_FILE': str(self.list)})
        env.start()
        self.addCleanup(env.stop)

    def test_the_default_folder_comes_first_and_the_listed_ones_follow_without_junk(self):
        self.assertEqual(hostos.claude_dirs(), [self.home / '.claude', self.account])

    def test_without_a_list_only_the_default_folder_is_read(self):
        os.environ.pop('SIDEAD_CLAUDE_DIRS_FILE')
        self.assertEqual(hostos.claude_dirs(), [self.home / '.claude'])
        os.environ['SIDEAD_CLAUDE_DIRS_FILE'] = str(self.list) + '.missing'
        self.assertEqual(hostos.claude_dirs(), [self.home / '.claude'])

    def test_a_session_running_under_another_accounts_folder_is_live_and_its_transcript_is_found(self):
        sessions = load('sessions')
        (self.account / 'sessions' / f'{os.getpid()}.json').write_text(json.dumps({'pid': os.getpid(), 'sessionId': 'abc-123', 'cwd': '/code/app'}))
        (self.account / 'projects' / '-code-app' / 'abc-123.jsonl').write_text('{}\n')
        self.assertEqual([data['sessionId'] for data, _ in sessions.running_claude()], ['abc-123'])
        self.assertEqual(sessions.claude_transcript('abc-123'), self.account / 'projects' / '-code-app' / 'abc-123.jsonl')
        self.assertIn(self.account / 'projects' / '-code-app' / 'abc-123.jsonl', list(sessions.claude_files()))
        self.assertTrue(sessions.is_claude_path(self.account / 'projects' / '-code-app' / 'abc-123.jsonl'))


if __name__ == '__main__':
    unittest.main()
