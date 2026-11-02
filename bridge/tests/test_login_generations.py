import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import MagicMock, patch
import uuid

SPEC = importlib.util.spec_from_file_location('bridge', Path(__file__).parents[1] / 'sidea_bridge.py')
bridge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bridge)

HTTPError = bridge.urllib.error.HTTPError


def account(name):
    return dict(id=str(uuid.uuid4()), name=name, email=name.lower() + '@example.com', ready=True, allowAuto=True)


def login(who, n, expires=-3600):
    return {'claudeAiOauth': {'accessToken': f'{who}-at{n}', 'refreshToken': f'{who}-rt{n}', 'expiresAt': (time.time() + expires) * 1000}}


def refused(status, body):
    return HTTPError(bridge.TOKEN_URL, status, 'refused', {}, io.BytesIO(json.dumps(body).encode()))


GRANTED = {'access_token': 'fresh-at', 'refresh_token': 'fresh-rt', 'expires_in': 28800}


class Base(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        (self.root / 'runtime').mkdir()
        self.home = self.root / 'home'
        (self.home / '.claude').mkdir(parents=True)
        self.alpha, self.beta = account('Alpha'), account('Beta')
        self.config = {'accounts': [self.alpha, self.beta]}
        self.keychain = {}
        self.posts = []
        self.answers = []
        self.processes = {}
        reader = MagicMock(side_effect=lambda service: json.loads(json.dumps(self.keychain.get(service))))
        reader.cache_clear = lambda: None
        owner = lambda root, blob: '' if not (blob or {}).get('claudeAiOauth', {}).get('accessToken') \
            else blob['claudeAiOauth']['accessToken'].split('-')[0] + '@example.com'
        def post(url, body, headers=None, method='POST'):
            self.posts.append(body['refresh_token'])
            answer = self.answers.pop(0)
            if isinstance(answer, Exception):
                raise answer
            return answer
        def security(args, *rest, **kw):
            if args[:2] == ['security', 'delete-generic-password']:
                self.keychain.pop(args[-1], None)
            return subprocess.CompletedProcess(args, 0, '', '')
        stack = contextlib.ExitStack()
        self.addCleanup(stack.close)
        for item in (patch.object(bridge, 'read_secret', reader), patch.object(Path, 'home', return_value=self.home),
                     patch.object(bridge, 'write_secret', side_effect=lambda service, blob: self.keychain.__setitem__(service, blob)),
                     patch.object(bridge, 'token_email', side_effect=owner), patch.object(bridge, 'post_json', side_effect=post),
                     patch.object(bridge, 'slot_processes', side_effect=lambda root, config: self.processes if self.processes is not None else None),
                     patch.object(bridge, 'verify_idle_owner'), patch.object(bridge.subprocess, 'run', side_effect=security),
                     patch.object(bridge.time, 'sleep')):
            stack.enter_context(item)
        bridge.prepare_profile(self.root, self.alpha['id'])
        bridge.prepare_profile(self.root, self.beta['id'])
        self.slot = bridge.profile_service(self.root, self.alpha['id'])
        self.spare = bridge.profile_service(self.root, self.beta['id'])

    def renew(self):
        bridge.renew(self.root, self.config, self.alpha)

    def log(self):
        path = self.root / 'runtime' / 'autopilot.log'
        return path.read_text() if path.exists() else ''

    def token(self, service=None):
        return self.keychain[service or self.slot]['claudeAiOauth']['refreshToken']


class RefusalTests(Base):
    def test_invalid_grant_with_nothing_newer_ends_the_login_and_logs_why(self):
        self.keychain[self.slot] = login('alpha', 3)
        self.keychain[bridge.backup_service(self.alpha)] = login('alpha', 2, -7200)
        self.answers = [refused(400, {'error': 'invalid_grant', 'error_description': 'secret-looking words'})]
        with self.assertRaisesRegex(ValueError, 'Sign in to Alpha again; its login ended'):
            self.renew()
        # An older copy is never sent: a server that spots a reused token may end the whole login.
        self.assertEqual(self.posts, ['alpha-rt3'])
        line = self.log()
        self.assertIn('Alpha: renewal ended status=400 error=invalid_grant expired=60m session-running=no other-generations=1 newer=0', line)
        self.assertIn(f"slot={self.alpha['id'][:8]}", line)
        self.assertNotIn('secret-looking', line)
        self.assertNotIn('alpha-rt', line)
        self.assertNotIn('alpha-at', line)

    def test_a_403_or_another_code_is_not_a_login_ending(self):
        for status, body, code in [(403, {'error': {'type': 'permission_error'}}, 'permission_error'), (403, {}, 'none'),
                                   (400, {'error': 'invalid_request'}, 'invalid_request'), (401, {'error': 'Not A Code!'}, 'none'),
                                   (400, {'error': 'invalid_grant', 'error_uri': 'https://claude.ai/restricted'}, 'invalid_grant')]:
            with self.subTest(status=status, code=code, body=body):
                self.keychain[self.slot] = login('alpha', 3)
                self.answers = [refused(status, body)]
                with self.assertRaises(bridge.RenewalRefused) as caught:
                    self.renew()
                self.assertNotIn('Sign in', str(caught.exception))
                self.assertEqual(self.token(), 'alpha-rt3')
                self.assertIn(f'status={status} error={code}', self.log().splitlines()[-1])

    def test_an_unreadable_body_is_not_a_login_ending(self):
        self.keychain[self.slot] = login('alpha', 3)
        self.answers = [HTTPError(bridge.TOKEN_URL, 400, 'refused', {}, io.BytesIO(b'<html>blocked</html>'))]
        with self.assertRaisesRegex(ValueError, 'retrying later'):
            self.renew()

    def test_a_session_that_renewed_during_the_refusal_is_used_as_it_is(self):
        self.keychain[self.slot] = login('alpha', 3)
        def session_won(url, body, headers=None, method='POST'):
            self.posts.append(body['refresh_token'])
            self.keychain[self.slot] = login('alpha', 4, 3600)
            raise refused(400, {'error': 'invalid_grant'})
        with patch.object(bridge, 'post_json', side_effect=session_won):
            self.renew()
        self.assertEqual(self.posts, ['alpha-rt3'])
        self.assertEqual(self.token(), 'alpha-rt4')
        self.assertIn('recovered by=session', self.log())


class GenerationTests(Base):
    def test_a_newer_copy_in_an_idle_slot_is_tried_once_and_comes_home(self):
        self.keychain[self.slot] = login('alpha', 3)
        self.keychain[self.spare] = login('alpha', 5, -60)
        self.answers = [refused(400, {'error': 'invalid_grant'}), GRANTED]
        self.renew()
        self.assertEqual(self.posts, ['alpha-rt3', 'alpha-rt5'])
        self.assertEqual(self.token(), 'fresh-rt')
        self.assertNotIn(self.spare, self.keychain)
        self.assertIn(f"recovered by=slot {self.beta['id'][:8]}", self.log())

    def test_a_copy_a_running_session_reads_is_never_spent(self):
        self.keychain[self.slot] = login('alpha', 3)
        self.keychain[self.spare] = login('alpha', 5, -60)
        self.processes = {77: self.beta['id']}
        self.answers = [refused(400, {'error': 'invalid_grant'})]
        with self.assertRaisesRegex(ValueError, 'its login ended'):
            self.renew()
        self.assertEqual(self.posts, ['alpha-rt3'])
        self.assertEqual(self.token(self.spare), 'alpha-rt5')

    def test_when_sessions_cant_be_listed_no_slot_copy_is_spent(self):
        self.keychain[self.slot] = login('alpha', 3)
        self.keychain[self.spare] = login('alpha', 5, -60)
        self.processes = None
        self.answers = [refused(400, {'error': 'invalid_grant'})]
        with self.assertRaisesRegex(ValueError, 'its login ended'):
            self.renew()
        self.assertEqual(self.posts, ['alpha-rt3'])
        self.assertIn('session-running=unknown', self.log())

    def test_another_accounts_login_and_an_unconfirmed_slot_are_not_candidates(self):
        self.keychain[self.slot] = login('alpha', 3)
        self.keychain[self.spare] = login('beta', 9, 3600)
        self.keychain[bridge.GLOBAL_SERVICE] = {'claudeAiOauth': {'accessToken': '', 'refreshToken': 'who-knows', 'expiresAt': (time.time() + 3600) * 1000}}
        self.answers = [refused(400, {'error': 'invalid_grant'})]
        with self.assertRaisesRegex(ValueError, 'its login ended'):
            self.renew()
        self.assertEqual(self.posts, ['alpha-rt3'])

    def test_a_newer_copy_that_is_also_dead_ends_the_login_after_one_retry(self):
        self.keychain[self.slot] = login('alpha', 3)
        self.keychain[self.spare] = login('alpha', 5, -60)
        self.answers = [refused(400, {'error': 'invalid_grant'}), refused(400, {'error': 'invalid_grant'})]
        with self.assertRaisesRegex(ValueError, 'its login ended'):
            self.renew()
        self.assertEqual(len(self.posts), 2)
        self.assertIn('retry-failed from=slot', self.log())

    def test_a_slot_a_session_blanked_uses_a_copy_side_a_kept(self):
        # Claude Code empties the refresh token in the slot after invalid_grant.
        self.keychain[self.slot] = {'claudeAiOauth': {'accessToken': '', 'refreshToken': '', 'expiresAt': 0}}
        self.keychain[bridge.backup_service(self.alpha)] = login('alpha', 7, -60)
        self.answers = [GRANTED]
        self.renew()
        self.assertEqual(self.posts, ['alpha-rt7'])
        self.assertEqual(self.token(), 'fresh-rt')

    def test_a_blanked_slot_with_no_other_copy_says_so(self):
        self.keychain[self.slot] = {'claudeAiOauth': {'accessToken': '', 'refreshToken': '', 'expiresAt': 0}}
        with self.assertRaisesRegex(ValueError, 'its login ended'):
            self.renew()
        self.assertEqual(self.posts, [])
        self.assertIn('error=no_refresh_token', self.log())

    def test_a_dormant_copy_of_a_token_a_slot_still_holds_is_not_spent(self):
        self.keychain[self.slot] = login('alpha', 3)
        self.keychain[self.spare] = login('alpha', 5, -60)
        self.keychain[bridge.backup_service(self.alpha)] = login('alpha', 5, -30)
        self.processes = {77: self.beta['id']}
        self.answers = [refused(400, {'error': 'invalid_grant'})]
        with self.assertRaisesRegex(ValueError, 'its login ended'):
            self.renew()
        self.assertEqual(self.posts, ['alpha-rt3'])


class CopyOwnerTests(Base):
    def trade(self, blob):
        entry = {'id': 't1'}
        (self.root / 'runtime').mkdir(exist_ok=True)
        bridge.watch_path(self.root).write_text(json.dumps({'trades': [entry]}))
        self.keychain[bridge.watch_service(entry)] = {'logins': [blob]}

    @staticmethod
    def unowned(n):
        blob = login('alpha', n, -60)
        blob['claudeAiOauth']['accessToken'] = ''
        return blob

    def test_a_trade_copy_with_no_readable_owner_is_never_spent(self):
        self.keychain[self.slot] = login('alpha', 3)
        self.trade(self.unowned(5))
        self.answers = [refused(400, {'error': 'invalid_grant'})]
        with self.assertRaisesRegex(ValueError, 'its login ended'):
            self.renew()
        self.assertEqual(self.posts, ['alpha-rt3'])

    def test_a_trade_copy_of_this_account_is_still_spent(self):
        self.keychain[self.slot] = login('alpha', 3)
        self.trade(login('alpha', 5, -60))
        self.answers = [refused(400, {'error': 'invalid_grant'}), GRANTED]
        self.renew()
        self.assertEqual(self.posts, ['alpha-rt3', 'alpha-rt5'])

    def test_the_accounts_own_backup_may_have_no_readable_owner(self):
        self.keychain[self.slot] = login('alpha', 3)
        self.keychain[bridge.backup_service(self.alpha)] = self.unowned(5)
        self.answers = [refused(400, {'error': 'invalid_grant'}), GRANTED]
        self.renew()
        self.assertEqual(self.posts, ['alpha-rt3', 'alpha-rt5'])


class SlotUnderLockTests(Base):
    def retry(self, while_waiting):
        @contextlib.contextmanager
        def lock(folder):
            if folder == bridge.slot_selector(self.root, self.beta['id']):
                while_waiting()
            yield
        self.keychain[self.slot] = login('alpha', 3)
        self.keychain[self.spare] = login('alpha', 5, -60)
        self.answers = [refused(400, {'error': 'invalid_grant'}), GRANTED]
        with patch.object(bridge, 'claude_refresh_lock', lock), self.assertRaisesRegex(ValueError, 'retrying later'):
            self.renew()
        self.assertEqual(self.posts, ['alpha-rt3'])
        self.assertIn('retry-skipped', self.log())
        self.assertIn(self.spare, self.keychain)

    def test_a_token_that_changed_while_waiting_isnt_spent(self):
        self.retry(lambda: self.keychain.__setitem__(self.spare, login('alpha', 6, -60)))

    def test_a_slot_that_started_a_session_while_waiting_isnt_spent(self):
        self.retry(lambda: self.processes.__setitem__(77, self.beta['id']))


class SaveTests(Base):
    def test_a_keychain_that_refuses_the_save_keeps_the_rotated_token_in_the_backup(self):
        self.keychain[self.slot] = login('alpha', 3)
        self.answers = [GRANTED]
        def write(service, blob):
            if service == self.slot:
                raise bridge.KeychainBusy('no')
            self.keychain[service] = blob
        with patch.object(bridge, 'write_secret', side_effect=write):
            with self.assertRaisesRegex(bridge.KeychainBusy, 'retrying later'):
                self.renew()
        self.assertEqual(self.token(bridge.backup_service(self.alpha)), 'fresh-rt')
        self.assertIn('save-failed', self.log())
        # The next renewal spends the rescued token, not the one already rotated away.
        self.answers = [{**GRANTED, 'refresh_token': 'fresher-rt'}]
        self.renew()
        self.assertEqual(self.posts, ['alpha-rt3', 'fresh-rt'])
        self.assertEqual(self.token(), 'fresher-rt')

    def test_a_save_that_fails_once_is_retried(self):
        self.keychain[self.slot] = login('alpha', 3)
        self.answers = [GRANTED]
        calls = []
        def write(service, blob):
            calls.append(service)
            if len(calls) == 1:
                raise subprocess.TimeoutExpired('security', 15)
            self.keychain[service] = blob
        with patch.object(bridge, 'write_secret', side_effect=write):
            self.renew()
        self.assertEqual(self.token(), 'fresh-rt')

    def test_termination_during_a_renewal_waits_for_the_save(self):
        self.keychain[self.slot] = login('alpha', 3)
        self.answers = [GRANTED]
        real = bridge.save_renewal
        def signalled(*args):
            os.kill(os.getpid(), signal.SIGTERM)
            time.time()
            real(*args)
        previous = signal.signal(signal.SIGTERM, lambda *_: self.fail('not held'))
        self.addCleanup(signal.signal, signal.SIGTERM, previous)
        with patch.object(bridge, 'save_renewal', side_effect=signalled):
            with self.assertRaises(SystemExit) as stopped:
                self.renew()
        self.assertEqual(stopped.exception.code, 143)
        self.assertEqual(self.token(), 'fresh-rt')

    def test_an_answer_lost_on_the_way_is_logged_and_nothing_is_written(self):
        self.keychain[self.slot] = login('alpha', 3)
        self.answers = [bridge.urllib.error.URLError('timed out')]
        with self.assertRaises(OSError):
            self.renew()
        self.assertEqual(self.token(), 'alpha-rt3')
        self.assertIn('unanswered status=none error=URLError', self.log())


class KeychainTests(unittest.TestCase):
    def read(self, *results):
        bridge.read_secret.cache_clear()
        self.addCleanup(bridge.read_secret.cache_clear)
        with patch.object(bridge.subprocess, 'run', side_effect=results) as run, patch.object(bridge.time, 'sleep'):
            return bridge.read_secret(f'probe-{uuid.uuid4()}'), run

    def done(self, code, out=''):
        return subprocess.CompletedProcess([], code, out, '')

    def test_only_no_such_item_is_an_empty_slot(self):
        self.assertIsNone(self.read(self.done(44))[0])

    def test_a_keychain_error_is_not_an_empty_slot(self):
        for code in (36, 51, 1, -15):
            with self.subTest(code=code), self.assertRaisesRegex(bridge.KeychainBusy, f'exit {code}'):
                self.read(self.done(code), self.done(code))

    def test_a_read_is_retried_with_a_longer_limit(self):
        blob, run = self.read(subprocess.TimeoutExpired('security', 15), self.done(0, '{"claudeAiOauth":{}}'))
        self.assertEqual(blob, {'claudeAiOauth': {}})
        self.assertEqual([call.kwargs['timeout'] for call in run.call_args_list], [15, 45])
        with self.assertRaisesRegex(bridge.KeychainBusy, 'no answer in 45s'):
            self.read(subprocess.TimeoutExpired('security', 15), subprocess.TimeoutExpired('security', 45))

    def test_a_timed_out_save_never_shows_its_arguments(self):
        secret = 'a' * 3000
        with patch.object(bridge.subprocess, 'run', side_effect=subprocess.TimeoutExpired(['security', secret], 15)), patch.object(bridge.time, 'sleep'):
            with self.assertRaises(bridge.KeychainBusy) as caught:
                bridge.write_secret('item', {'claudeAiOauth': {'refreshToken': secret}})
        self.assertNotIn(secret[:20], str(caught.exception))
        self.assertNotIn(secret.encode().hex()[:20], str(caught.exception))


class RehomeTests(Base):
    def test_a_keychain_hiccup_never_puts_a_backup_over_a_live_login(self):
        self.alpha['email'] = 'alpha@example.com'
        self.keychain[self.slot] = login('alpha', 5, 3600)
        self.keychain[bridge.backup_service(self.alpha)] = login('alpha', 2, -7200)
        def flaky(service):
            if service == self.slot:
                raise bridge.KeychainBusy('The Keychain did not answer')
            return json.loads(json.dumps(self.keychain.get(service)))
        reader = MagicMock(side_effect=flaky)
        reader.cache_clear = lambda: None
        with patch.object(bridge, 'read_secret', reader), patch.object(bridge, 'mac_email', return_value=''):
            with self.assertRaises(bridge.KeychainBusy):
                bridge.rehome(self.root, {'accounts': [self.alpha]})
        self.assertEqual(self.token(), 'alpha-rt5')


class LockTests(unittest.TestCase):
    def test_both_of_claude_codes_locks_are_held_and_released(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(os.path.realpath(temp)) / 'slot'
            folder.mkdir()
            legacy = Path(f'{folder}.lock')
            with bridge.claude_refresh_lock(folder):
                self.assertTrue((folder / '.oauth_refresh.lock').is_dir())
                self.assertTrue(legacy.is_dir())
            self.assertFalse((folder / '.oauth_refresh.lock').exists())
            self.assertFalse(legacy.exists())

    def test_a_session_holding_the_older_lock_makes_side_a_wait_and_leaves_nothing_behind(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(os.path.realpath(temp)) / 'slot'
            folder.mkdir()
            legacy = Path(f'{folder}.lock')
            legacy.mkdir()
            with self.assertRaisesRegex(ValueError, 'refreshing a login'):
                with bridge.claude_refresh_lock(folder, timeout=0):
                    self.fail('held')
            self.assertFalse((folder / '.oauth_refresh.lock').exists())
            self.assertTrue(legacy.is_dir())


class ListingTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.config = {'accounts': []}
        sleeper = patch.object(bridge.time, 'sleep')
        sleeper.start()
        self.addCleanup(sleeper.stop)

    def listing(self, *pids):
        return subprocess.CompletedProcess([], 0, ''.join(f'{pid} /usr/local/bin/claude\n' for pid in pids), '')

    def test_a_slow_ps_gets_a_longer_limit_and_its_reason_is_kept(self):
        limits = []
        def slow(args, **kw):
            limits.append(kw['timeout'])
            if len(limits) == 1:
                raise subprocess.TimeoutExpired(args, kw['timeout'])
            return self.listing()
        with patch.object(bridge.subprocess, 'run', side_effect=slow):
            self.assertEqual(bridge.slot_processes(self.root, self.config), {})
        self.assertEqual(limits, list(bridge.PS_LIMITS))

        def stuck(args, **kw):
            raise subprocess.TimeoutExpired(args, kw['timeout'])
        with patch.object(bridge.subprocess, 'run', side_effect=stuck):
            self.assertIsNone(bridge.slot_processes(self.root, self.config))
        self.assertEqual(bridge.listing_problem, 'ps took over 40s')
        with patch.object(bridge.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', '')):
            self.assertIsNone(bridge.slot_processes(self.root, self.config))
        self.assertEqual(bridge.listing_problem, 'ps exit 1')

    def test_a_process_readable_on_the_second_try_is_counted(self):
        answers = iter([None, ('claude', {'CLAUDE_SECURESTORAGE_CONFIG_DIR': ''})])
        with patch.object(bridge.subprocess, 'run', return_value=self.listing(41)), patch.object(bridge, 'process_state', return_value='S'), \
             patch.object(bridge, 'process_environment', side_effect=lambda pid: next(answers)):
            self.assertEqual(bridge.slot_processes(self.root, self.config), {41: 'mac'})

    def test_a_process_exiting_or_a_zombie_is_not_unknown(self):
        for state in ('Z', 'Z+', 'SE', 'R+E', ''):
            with self.subTest(state=state), patch.object(bridge.subprocess, 'run', return_value=self.listing(41)), \
                    patch.object(bridge, 'process_state', return_value=state), patch.object(bridge, 'process_environment', return_value=None):
                self.assertEqual(bridge.slot_processes(self.root, self.config), {})

    def test_a_running_process_that_stays_unreadable_stops_trades_and_is_named(self):
        bridge.environment_failures[41] = 'Invalid argument'
        self.addCleanup(bridge.environment_failures.clear)
        with patch.object(bridge.subprocess, 'run', return_value=self.listing(40, 41)), patch.object(bridge, 'process_state', return_value='S+'), \
             patch.object(bridge, 'process_environment', side_effect=lambda pid: ('claude', {}) if pid == 40 else None):
            self.assertIsNone(bridge.slot_processes(self.root, self.config))
        self.assertEqual(bridge.listing_problem, 'process 41 (S+) unreadable: Invalid argument')

    def test_a_process_whose_state_cant_be_read_still_counts_as_unknown(self):
        with patch.object(bridge.subprocess, 'run', return_value=self.listing(41)), patch.object(bridge, 'process_state', return_value='unknown'), \
             patch.object(bridge, 'process_environment', return_value=None):
            self.assertIsNone(bridge.slot_processes(self.root, self.config))

    def test_a_listing_line_that_isnt_a_process_is_skipped(self):
        output = subprocess.CompletedProcess([], 0, 'ps: warning claude\n', '')
        with patch.object(bridge.subprocess, 'run', return_value=output):
            self.assertEqual(bridge.slot_processes(self.root, self.config), {})

    def test_a_real_zombie_is_refused_by_the_kernel_and_read_as_finished(self):
        pid = os.fork()
        if pid == 0:
            os._exit(0)
        self.addCleanup(lambda: os.waitpid(pid, 0))
        real_sleep = patch.object(bridge.time, 'sleep', side_effect=None)
        with real_sleep:
            for _ in range(200):
                if 'Z' in subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)], capture_output=True, text=True).stdout:
                    break
        self.assertIsNone(bridge.process_environment(pid))
        self.assertEqual(bridge.environment_failures[pid], 'Invalid argument')
        # Signal 0 still succeeds on a zombie, which is how one used to read as a running process.
        os.kill(pid, 0)
        self.assertTrue(bridge.finished(bridge.process_state(pid)))

    def test_a_trade_refuses_blind_and_says_why(self):
        alpha, beta = account('Alpha'), account('Beta')
        config = {'accounts': [alpha, beta]}
        keychain = {bridge.GLOBAL_SERVICE: login('alpha', 1, 3600), bridge.profile_service(self.root, beta['id']): login('beta', 1, 3600)}
        reader = MagicMock(side_effect=lambda service: keychain.get(service))
        reader.cache_clear = lambda: None
        owner = lambda root, blob: blob['claudeAiOauth']['accessToken'].split('-')[0] + '@example.com' if blob else ''
        home = self.root / 'home'
        (home / '.claude').mkdir(parents=True)
        def unlisted(root, config):
            bridge.listing_problem = 'ps took over 40s'
        with patch.object(bridge, 'read_secret', reader), patch.object(bridge, 'token_email', side_effect=owner), patch.object(Path, 'home', return_value=home), \
             patch.object(bridge, 'slot_processes', side_effect=unlisted), patch.object(bridge, 'write_secret') as writer:
            bridge.prepare_profile(self.root, beta['id'])
            with self.assertRaisesRegex(ValueError, r"couldn't be listed \(ps took over 40s\)"):
                bridge.swap(self.root, config, 'mac', beta)
            writer.assert_not_called()


class ActiveCommandTests(unittest.TestCase):
    def test_the_reason_reaches_the_app(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'config.json').write_text(json.dumps({'accounts': []}))
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            for name, script in (('ps', 'exit 3'), ('security', 'exit 44')):
                (bin_dir / name).write_text(f'#!/bin/sh\n{script}\n')
                (bin_dir / name).chmod(0o755)
            home = root / 'home'
            home.mkdir()
            env = {**os.environ, 'PATH': f"{bin_dir}{os.pathsep}{os.environ['PATH']}", 'HOME': str(home), 'CODEX_HOME': str(root / 'codex')}
            done = subprocess.run([sys.executable, str(Path(bridge.__file__)), '--root', str(root), 'active'], capture_output=True, text=True, timeout=120, env=env)
            self.assertEqual(done.returncode, 0, done.stderr)
            answer = json.loads(done.stdout)
            self.assertIsNone(answer['busy'])
            self.assertEqual(answer['busyProblem'], 'ps exit 3')


if __name__ == '__main__':
    unittest.main()
