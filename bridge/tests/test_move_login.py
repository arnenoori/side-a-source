import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch
import uuid

sys.path.insert(0, str(Path(__file__).parents[1]))
import move_login

common = move_login.common


def claude_login(who):
    return {'claudeAiOauth': {'accessToken': f'{who}-at', 'refreshToken': f'{who}-rt', 'expiresAt': 4102444800000}, 'mcpOAuth': {}}


class MoveLoginTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        (self.root / 'runtime').mkdir()
        self.work = dict(id=str(uuid.uuid4()), name='Work', email='work@example.com', ready=True, allowAuto=True)
        self.own = dict(id=str(uuid.uuid4()), name='Own', email='own@example.com', ready=True, allowAuto=True)
        self.codex = dict(id=str(uuid.uuid4()), name='Codex', email='codex@example.com', ready=True, allowAuto=True, provider='codex')
        (self.root / 'config.json').write_text(json.dumps({'accounts': [self.work, self.own, self.codex]}))
        self.keychain = {common.GLOBAL_SERVICE: claude_login('own'), common.profile_service(self.root, self.work['id']): claude_login('work'),
                         common.backup_service(self.work): claude_login('work')}
        reader = MagicMock(side_effect=lambda service: json.loads(json.dumps(self.keychain.get(service))))
        reader.cache_clear = lambda: None
        owner = lambda root, blob: '' if not (blob or {}).get('claudeAiOauth') else blob['claudeAiOauth']['accessToken'].split('-')[0] + '@example.com'

        def security(command, **_):
            if command[:2] == ['security', 'delete-generic-password']:
                self.keychain.pop(command[command.index('-s') + 1], None)
            return MagicMock(returncode=0, stdout='', stderr='')
        for target, name, value in ((common, 'read_secret', reader), (common, 'token_email', owner),
                                    (common, 'write_secret', MagicMock(side_effect=self.keychain.__setitem__)),
                                    (move_login.subprocess, 'run', MagicMock(side_effect=security)),
                                    (common.subprocess, 'run', MagicMock(side_effect=security)),
                                    (move_login.codex_bridge, 'global_email', lambda: 'someone@example.com')):
            patcher = patch.object(target, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def ask(self, action, account, **more):
        return move_login.run({'root': str(self.root), 'action': action, 'account': account['id'], **more})

    def test_a_held_login_is_out_of_its_slot_and_comes_back_on_restore(self):
        slot = common.profile_service(self.root, self.work['id'])
        sent = self.ask('login-hold', self.work)
        self.assertEqual(sent['login'], claude_login('work'))
        self.assertEqual((sent['provider'], sent['email']), ('claude', 'work@example.com'))
        self.assertNotIn(slot, self.keychain)
        # The next repair would put a backup straight back into the empty slot.
        self.assertNotIn(common.backup_service(self.work), self.keychain)
        self.assertEqual(self.ask('login-restore', self.work), {'restored': True})
        self.assertEqual(self.keychain[slot], claude_login('work'))
        self.assertNotIn(move_login.held_service(self.work), self.keychain)
        self.assertEqual(self.ask('login-restore', self.work), {'restored': False})

    def test_a_released_login_is_nowhere_on_the_sender(self):
        self.ask('login-hold', self.work)
        self.ask('login-release', self.work)
        self.assertEqual(set(self.keychain), {common.GLOBAL_SERVICE})

    def test_the_computers_own_login_never_leaves(self):
        self.assertFalse(self.ask('login-can', self.own)['can'])
        self.assertIn('own Claude Code login', self.ask('login-hold', self.own)['refused'])
        self.assertEqual(self.keychain[common.GLOBAL_SERVICE], claude_login('own'))
        self.assertTrue(self.ask('login-can', self.work)['can'])

    def test_a_login_that_arrives_is_stored_in_the_accounts_slot_and_can_be_removed(self):
        other = Path(tempfile.mkdtemp())
        arrived = dict(id=str(uuid.uuid4()), name='Work', email='work@example.com', ready=False, allowAuto=True)
        (other / 'config.json').write_text(json.dumps({'accounts': [arrived]}))
        (other / 'runtime').mkdir()
        self.assertEqual(move_login.run({'root': str(other), 'action': 'login-receive', 'account': arrived['id'], 'login': claude_login('work')}),
                         {'stored': True})
        self.assertEqual(self.keychain[common.profile_service(other, arrived['id'])], claude_login('work'))
        self.assertTrue((other / 'profiles' / arrived['id']).is_dir())
        move_login.run({'root': str(other), 'action': 'login-remove', 'account': arrived['id']})
        self.assertNotIn(common.profile_service(other, arrived['id']), self.keychain)
        self.assertIn('refused', move_login.run({'root': str(other), 'action': 'login-receive', 'account': arrived['id'], 'login': {'tokens': {}}}))

    def arrival(self, owner):
        """A computer that has the account but not its login, receiving a login the profile endpoint says is `owner`'s."""
        other = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, other, ignore_errors=True)
        arrived = dict(id=str(uuid.uuid4()), name='Work', email='work@example.com', ready=False, allowAuto=True)
        (other / 'config.json').write_text(json.dumps({'accounts': [arrived]}))
        (other / 'runtime').mkdir()
        looked_up, elsewhere = [], common.token_email

        def lookup(root, blob):
            if blob != claude_login('arriving'):
                return elsewhere(root, blob)
            looked_up.append(blob)
            return owner
        with patch.object(common, 'token_email', lookup):
            answer = move_login.run({'root': str(other), 'action': 'login-receive', 'account': arrived['id'], 'login': claude_login('arriving')})
        return answer, common.profile_service(other, arrived['id']), looked_up

    def test_a_login_another_account_owns_is_refused_and_nothing_is_stored(self):
        answer, slot, looked_up = self.arrival('someone@example.com')
        self.assertEqual(answer, {'refused': 'That login belongs to another account.'})
        self.assertNotIn(slot, self.keychain)
        # Asked of the login itself, not of the name the sender gave it.
        self.assertEqual(looked_up, [claude_login('arriving')])

    def test_a_login_whose_owner_cannot_be_confirmed_is_not_stored(self):
        # The profile endpoint didn't answer (offline), or the access token has expired: no answer is no yes.
        answer, slot, _ = self.arrival('')
        self.assertIn("couldn't confirm", answer['refused'])
        self.assertNotIn(slot, self.keychain)

    def test_a_confirmed_login_is_stored(self):
        answer, slot, _ = self.arrival('work@example.com')
        self.assertEqual(answer, {'stored': True})
        self.assertEqual(self.keychain[slot], claude_login('arriving'))

    def test_a_codex_login_moves_as_its_file(self):
        claims = move_login.codex_bridge.base64.urlsafe_b64encode(json.dumps({'email': 'codex@example.com'}).encode()).decode().rstrip('=')
        login = {'tokens': {'id_token': f'h.{claims}.s', 'access_token': 'a', 'refresh_token': 'r', 'account_id': 'x'}}
        path = move_login.codex_file(self.root, self.codex)
        path.write_text(json.dumps(login))
        self.assertTrue(self.ask('login-can', self.codex)['can'])
        self.assertEqual(self.ask('login-hold', self.codex)['login'], login)
        self.assertFalse(path.exists())
        self.assertEqual(self.ask('login-restore', self.codex), {'restored': True})
        self.assertEqual(json.loads(path.read_text()), login)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.ask('login-hold', self.codex)
        self.ask('login-release', self.codex)
        self.assertFalse(path.exists() or move_login.held_file(self.root, self.codex).exists())
        wrong = {'tokens': {'id_token': 'h.e30.s'}}
        self.assertIn('another account', self.ask('login-receive', self.codex, login=wrong)['refused'])
        self.assertEqual(self.ask('login-receive', self.codex, login=login), {'stored': True})

    def test_removing_a_login_never_deletes_the_computers_own(self):
        self.ask('login-remove', self.own)
        self.assertEqual(self.keychain[common.GLOBAL_SERVICE], claude_login('own'))

    def test_an_account_this_computer_does_not_have_is_refused(self):
        self.assertIn('refused', move_login.run({'root': str(self.root), 'action': 'login-hold', 'account': str(uuid.uuid4())}))


if __name__ == '__main__':
    unittest.main()
