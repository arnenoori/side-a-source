import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
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


def account(name='Personal', **extra):
    return dict(id=str(uuid.uuid4()), name=name, email=name.lower()+'@example.com', ready=True, allowAuto=True, **extra)


class BridgeTests(unittest.TestCase):
    def test_usage_percent_stays_within_the_cap_and_epoch_reads_seconds_or_milliseconds(self):
        self.assertEqual(bridge.percent(101.4), 100.0)
        self.assertEqual(bridge.percent(-2), 0.0)
        self.assertEqual(bridge.percent(None), 0.0)
        self.assertEqual(bridge.percent(float('nan')), 0.0)
        self.assertEqual(bridge.epoch(2_000_000_000_000), 2_000_000_000.0)
        self.assertEqual(bridge.epoch(2_000_000_000), 2_000_000_000.0)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        # Never touch the real ~/.claude refresh lock.
        env=patch.dict(os.environ,{'CLAUDE_CONFIG_DIR':str(self.root/'claude-home')}); env.start(); self.addCleanup(env.stop)
        # Never the claude this Mac happens to have.
        versions=patch.object(bridge,'claude_versions',return_value=[(2,1,303)]); versions.start(); self.addCleanup(versions.stop); self.versions_stop=versions.stop
    def tearDown(self):
        self.temp.cleanup()
    def test_failures_carry_a_code_the_account_name_cant_fake(self):
        sys.path.insert(0,str(Path(bridge.__file__).parent)); import codex_bridge
        self.assertEqual(bridge.failure_line(bridge.SignInAgain("Sign in to bridle again.")), "Side A[signin]: Sign in to bridle again.")
        self.assertEqual(bridge.failure_line(codex_bridge.SignInAgain("Sign in to dev429 again.")), "Side A[signin]: Sign in to dev429 again.")
        self.assertEqual(bridge.failure_line(bridge.LoginIdle("Login idle; its last reading still applies.")),
                         "Side A[idle]: Login idle; its last reading still applies.")
        self.assertEqual(bridge.failure_line(codex_bridge.RateLimited("Codex usage is rate-limited (429).")),
                         "Side A[rate-limited]: Codex usage is rate-limited (429).")
        self.assertEqual(bridge.failure_line(bridge.Unconfirmed("Can't confirm whose login this is yet; retrying later.")),
                         "Side A[unconfirmed]: Can't confirm whose login this is yet; retrying later.")
        self.assertEqual(bridge.failure_line(ValueError("idle 429")), "Side A: idle 429")
        self.assertEqual(bridge.failure_line(bridge.urllib.error.HTTPError("u", 500, "x", {}, None)), "Side A: HTTP Error 500: x")

    def test_only_a_429_from_the_usage_endpoint_is_a_rate_limit(self):
        blob = {"claudeAiOauth": {"accessToken": "t", "expiresAt": (time.time() + 3600) * 1000}}
        account = {"id": "a", "name": "idle 429", "email": "a@example.com"}
        for status, kind in [(429, bridge.RateLimited), (500, ValueError), (401, bridge.SignInAgain)]:
            error = bridge.urllib.error.HTTPError("u", status, "x", {}, None)
            with patch.object(bridge, "owned_login", return_value=blob), patch.object(bridge, "post_json", side_effect=error):
                with self.assertRaises(ValueError) as caught:
                    bridge.claude_usage(Path("/nonexistent"), {}, account)
            self.assertIs(type(caught.exception), kind)

    def test_corrupt_config_is_not_treated_as_empty(self):
        path = self.root / 'config.json'; path.write_text('{broken')
        with self.assertRaises(json.JSONDecodeError): bridge.read_json(path, {})
    def test_rejects_path_traversal(self):
        with self.assertRaises(ValueError): bridge.account_by_id({'accounts': []}, '../../secret')
        with self.assertRaises(ValueError): bridge.prepare_profile(self.root, '../../secret')
    def test_strips_all_credential_and_provider_overrides(self):
        with patch.dict(os.environ, {'ANTHROPIC_API_KEY': 'secret', 'CLAUDE_CODE_OAUTH_TOKEN': 'secret', 'CLAUDECODE':'1', 'CLAUDE_CODE_USE_BEDROCK':'1', 'AWS_PROFILE':'prod', 'CLAUDE_CONFIG_DIR':'wrong'}):
            env = bridge.clean_environment(self.root)
        self.assertEqual(env['CLAUDE_CONFIG_DIR'], str(self.root))
        for key in ('ANTHROPIC_API_KEY', 'CLAUDE_CODE_OAUTH_TOKEN', 'CLAUDECODE', 'AWS_PROFILE', 'CLAUDE_CODE_USE_BEDROCK'):
            self.assertNotIn(key, env)
    def test_profile_keychain_service_matches_cli_naming(self):
        # Observed in the Keychain for this real profile path with Claude Code 2.1.292.
        root=Path('/Users/arne/Library/Application Support/SideA')
        self.assertEqual(bridge.profile_service(root,'cf1157b7-6e79-4726-949f-4f7a4b92706a'),'Claude Code-credentials-16898129')
    def vault_patches(self, home, vault, owners):
        return [patch.object(Path,'home',return_value=home),
                patch.object(bridge,'read_secret',side_effect=lambda s: json.loads(json.dumps(vault.get(s)))),
                patch.object(bridge,'token_email',side_effect=lambda root,blob: owners.get(((blob or {}).get('claudeAiOauth') or {}).get('accessToken'),''))]
    def setup_pair(self):
        home=self.root/'home'; home.mkdir()
        a,b=account('Alpha'),account('Beta')
        for item in (a,b): bridge.prepare_profile(self.root,item['id'])
        login=lambda token,expires=3600:{'claudeAiOauth':{'accessToken':token,'refreshToken':'r-'+token,'expiresAt':(time.time()+expires)*1000}}
        return home,a,b,login
    def selector(self):
        return (self.root/'runtime/claude-selector').read_text().strip()
    def test_use_points_new_commands_at_the_accounts_own_login(self):
        home,a,b,login=self.setup_pair()
        vault={bridge.GLOBAL_SERVICE:login('alpha'), bridge.profile_service(self.root,b['id']):login('beta')}
        config={'accounts':[a,b]}
        with contextlib.ExitStack() as stack:
            for item in self.vault_patches(home,vault,{'alpha':a['email'],'beta':b['email']}): stack.enter_context(item)
            self.assertEqual(bridge.global_account(config,self.root),a)
            bridge.activate(self.root,config,b)
            self.assertEqual(self.selector(),str(bridge.profile_dir(self.root,b['id'])))
            self.assertEqual(bridge.global_account(config,self.root),b)
            bridge.activate(self.root,config,a)
            self.assertEqual(self.selector(),'')
        self.assertFalse((home/'.claude.json').exists())
    def test_a_failed_identity_lookup_keeps_the_chosen_account(self):
        # Review: a profile lookup failing after token rotation reset the selection to the Mac login.
        home,a,b,login=self.setup_pair()
        vault={bridge.GLOBAL_SERVICE:login('alpha'), bridge.profile_service(self.root,b['id']):login('beta')}
        config={'accounts':[a,b]}
        with contextlib.ExitStack() as stack:
            for item in self.vault_patches(home,vault,{'alpha':a['email'],'beta':b['email']}): stack.enter_context(item)
            bridge.activate(self.root,config,b)
        vault[bridge.profile_service(self.root,b['id'])]=login('beta-rotated')
        with contextlib.ExitStack() as stack:
            for item in self.vault_patches(home,vault,{'alpha':a['email']}): stack.enter_context(item)
            self.assertEqual(bridge.repair_selection(self.root,config)['id'],b['id'])
        self.assertEqual(self.selector(),str(bridge.profile_dir(self.root,b['id'])))
    def test_selection_follows_the_mac_login_when_it_changes(self):
        # Alpha (the Mac login) is selected; then the Mac signs in as Beta, whose profile slot is a stale copy.
        home,a,b,login=self.setup_pair()
        vault={bridge.GLOBAL_SERVICE:login('alpha'), bridge.profile_service(self.root,b['id']):login('beta-old')}
        owners={'alpha':a['email'],'beta-old':b['email'],'beta-new':b['email']}
        config={'accounts':[a,b]}
        with contextlib.ExitStack() as stack:
            for item in self.vault_patches(home,vault,owners): stack.enter_context(item)
            bridge.activate(self.root,config,b)
            vault[bridge.GLOBAL_SERVICE]=login('beta-new')
            # Beta's login now lives in the Mac item, so the old profile selection must not be used.
            self.assertEqual(bridge.repair_selection(self.root,config),b)
            self.assertEqual(self.selector(),'')
    def test_slots_holding_another_accounts_login_are_refused_everywhere(self):
        home,a,b,login=self.setup_pair()
        vault={bridge.GLOBAL_SERVICE:login('alpha'), bridge.profile_service(self.root,b['id']):login('alpha-copy')}
        owners={'alpha':a['email'],'alpha-copy':a['email']}
        config={'accounts':[a,b]}
        with contextlib.ExitStack() as stack:
            for item in self.vault_patches(home,vault,owners): stack.enter_context(item)
            post=stack.enter_context(patch.object(bridge,'post_json'))
            run=stack.enter_context(patch.object(bridge.subprocess,'run'))
            for action in (lambda: bridge.activate(self.root,config,b), lambda: bridge.claude_usage(self.root,config,b),
                           lambda: bridge.prime(self.root,config,b)):
                with self.assertRaisesRegex(ValueError,'Sign in to Beta'): action()
            post.assert_not_called(); run.assert_not_called()
        self.assertFalse((self.root/'runtime/claude-selector').exists())
    def test_unverified_login_is_never_used_and_no_mac_login_means_profile_slots(self):
        # Review: an unknown owner (profile lookup failing) was accepted as the account's,
        # and with no Mac login an email-less account was sent to the empty default item.
        home,a,b,login=self.setup_pair()
        vault={bridge.profile_service(self.root,b['id']):login('mystery')}
        config={'accounts':[a,b]}
        with contextlib.ExitStack() as stack:
            for item in self.vault_patches(home,vault,{}): stack.enter_context(item)
            post=stack.enter_context(patch.object(bridge,'post_json'))
            for action in (lambda: bridge.activate(self.root,config,b), lambda: bridge.claude_usage(self.root,config,b)):
                with self.assertRaisesRegex(ValueError,"confirm"): action()
            post.assert_not_called()
            self.assertEqual(bridge.home_service(self.root,dict(b,email='')),bridge.profile_service(self.root,b['id']))
    def test_usage_reads_without_refreshing_or_writing_a_login(self):
        home,a,b,login=self.setup_pair()
        vault={bridge.GLOBAL_SERVICE:login('alpha'), bridge.profile_service(self.root,b['id']):login('beta',expires=-5000)}
        owners={'alpha':a['email'],'beta':b['email']}
        config={'accounts':[a,b]}
        # Shape of the live response: legacy per-model keys are null; model caps arrive as scoped limits.
        usage={'five_hour':{'utilization':40,'resets_at':'2026-10-06T20:00:00Z'},'seven_day':{'utilization':10,'resets_at':None},
               'seven_day_opus':None,'limits':[{'kind':'session','percent':40,'scope':None},
               {'kind':'weekly_scoped','percent':3,'resets_at':'2026-10-11T00:00:00Z','scope':{'model':{'id':None,'display_name':'Fable'},'surface':None}}]}
        with contextlib.ExitStack() as stack:
            for item in self.vault_patches(home,vault,owners): stack.enter_context(item)
            post=stack.enter_context(patch.object(bridge,'post_json',return_value=usage))
            writer=stack.enter_context(patch.object(bridge,'write_secret'))
            result=bridge.claude_usage(self.root,config,a)
            self.assertEqual([(w['id'],w['percent']) for w in result['windows']],[('five_hour',40.0),('seven_day',10.0),('model:fable',3.0)])
            # Reading never renews: an expired login reports idle, and renewal is a separate, locked step.
            with self.assertRaisesRegex(ValueError,'idle'): bridge.claude_usage(self.root,config,b)
            self.assertEqual(post.call_count,1)
            # Review: a 401 returned empty windows, wiping the last reading with no backoff.
            post.side_effect=bridge.urllib.error.HTTPError(bridge.USAGE_URL,401,'',{},None)
            with self.assertRaisesRegex(ValueError,'Sign in to Alpha'): bridge.claude_usage(self.root,config,a)
            writer.assert_not_called()
    def test_shell_switch_survives_path_aliases_and_upgrades_the_old_function(self):
        home=self.root/'home'; home.mkdir(); rc=home/'.zshrc'
        fake=self.root/'bin'; fake.mkdir(); (fake/'claude').write_text('#!/bin/sh\necho "${CLAUDE_SECURESTORAGE_CONFIG_DIR-unset}|$*"\n'); (fake/'claude').chmod(0o755)
        # The installer's alias points at a path, which skipped the old `claude` function.
        mine=f"alias claude={fake}/claude\n"
        # Review: a dotfiles-managed (symlinked) .zshrc was replaced by a plain file.
        dotfiles=self.root/'dotfiles'; dotfiles.mkdir()
        (dotfiles/'zshrc').write_text(mine+"\n"+bridge.SHELL_MARK+"\nfunction claude { command claude \"$@\"; }\n")
        rc.symlink_to(dotfiles/'zshrc')
        with patch.object(Path,'home',return_value=home):
            self.assertTrue(bridge.shell_installed(self.root))
            bridge.set_shell(self.root,True)
            self.assertTrue(rc.is_symlink())
            self.assertEqual(rc.read_text().count(bridge.SHELL_MARK),1)
            self.assertNotIn('function claude',rc.read_text())
            selector=self.root/'runtime/claude-selector'; selector.parent.mkdir(parents=True,exist_ok=True)
            run=lambda: subprocess.run(['zsh','-fc',f"source {rc}; (( ${{preexec_functions[(I)_side_a_select]}} )) || exit 3; _side_a_select; eval 'claude --version'"],
                                       capture_output=True,text=True).stdout.strip()
            selector.write_text('/profiles/x\n')
            self.assertEqual(run(),'/profiles/x|--version')
            # From brandedDaniel's fork: `source ~/.zshrc && claude` ran before preexec existed and used
            # the Mac login. Also under `set -u`, with cat aliased to something that decorates output.
            sourced=subprocess.run(['zsh','-fc',f"set -u; alias cat='echo decorated'; source {rc} && {fake}/claude --version && sidea >/dev/null"],
                                   capture_output=True,text=True)
            self.assertEqual((sourced.stdout.strip(),sourced.returncode),('/profiles/x|--version',0))
            # Review: the Mac login must be selected explicitly (empty), or an exported
            # CLAUDE_CONFIG_DIR would pick that directory's login instead.
            selector.write_text('\n')
            self.assertEqual(run(),'|--version')
            # Review: shells opened before switching was turned off must stop following Side A.
            bridge.set_shell(self.root,False)
            self.assertFalse(selector.exists())
            self.assertEqual(subprocess.run(['zsh','-fc',f"PATH={fake}:$PATH; {bridge.shell_snippet(self.root).splitlines()[1]}; _side_a_select; claude --version"],
                                            capture_output=True,text=True).stdout.strip(),'unset|--version')
        self.assertEqual(rc.read_text(),mine)
    def test_limit_hook_is_silent_rate_limit_only_and_removable(self):
        home=self.root/'home'; (home/'.claude').mkdir(parents=True)
        mine={'matcher':'rate_limit','hooks':[{'type':'command','command':'notify-me'}]}
        bridge.atomic_json(home/'.claude/settings.json',{'model':'opus','hooks':{'StopFailure':[mine]}})
        with patch.object(Path,'home',return_value=home):
            bridge.set_limit_hook(self.root,True); bridge.set_limit_hook(self.root,True)
            added=bridge.read_json(home/'.claude/settings.json')['hooks']['StopFailure']
            self.assertEqual(len(added),2)
            self.assertEqual(added[1]['matcher'],'rate_limit')
            subprocess.run(added[1]['hooks'][0]['command'],shell=True,check=True)
            self.assertTrue(bridge.limit_marker(self.root).exists())
            bridge.set_limit_hook(self.root,False)
            self.assertEqual(bridge.read_json(home/'.claude/settings.json'),{'model':'opus','hooks':{'StopFailure':[mine]}})
    def test_settings_keep_their_text_and_are_not_rewritten_when_nothing_changes(self):
        home=self.root/'home'; (home/'.claude').mkdir(parents=True); (home/'.codex').mkdir()
        path=home/'.claude/settings.json'
        text='{\n    "statusLine": {"type": "command", "command": "echo café ✓"},\n    "env": {"GREETING": "こんにちは"}\n}\n'
        path.write_text(text,encoding='utf-8')
        with patch.object(Path,'home',return_value=home), patch.dict(os.environ,{'CODEX_HOME':''}):
            for off in (lambda: bridge.island_state(self.root,['claude','codex'],'off'), lambda: bridge.set_limit_hook(self.root,False),
                        lambda: bridge.set_inbox(self.root,False), lambda: bridge.set_live(self.root,False)):
                off()
                self.assertEqual(path.read_text(encoding='utf-8'),text)
            self.assertFalse((home/'.codex/hooks.json').exists())
            bridge.set_limit_hook(self.root,True)
            written=path.read_text(encoding='utf-8')
            self.assertIn('café ✓',written); self.assertIn('こんにちは',written); self.assertNotIn('\\u',written)
            bridge.set_limit_hook(self.root,False)
            self.assertEqual(json.loads(path.read_text(encoding='utf-8')),json.loads(text))
    def test_hook_edits_step_around_entries_they_dont_recognise(self):
        home=self.root/'home'; (home/'.claude').mkdir(parents=True)
        odd={'model':'opus','hooks':{'StopFailure':['not a group',{'matcher':'x'},{'hooks':'nope'},{'hooks':[7,{'command':None},{'type':'command','command':'mine'}]}],
                                      'SessionStart':[None]}}
        bridge.atomic_json(home/'.claude/settings.json',odd)
        with patch.object(Path,'home',return_value=home):
            self.assertFalse(bridge.limit_hook_installed()); self.assertFalse(bridge.inbox_installed()); self.assertFalse(bridge.island_installed('claude'))
            bridge.set_limit_hook(self.root,True)
            self.assertTrue(bridge.limit_hook_installed())
            bridge.set_limit_hook(self.root,False)
            self.assertEqual(bridge.read_json(home/'.claude/settings.json'),odd)
            for value in ([1,2],{'hooks':[1]},{'hooks':{'StopFailure':{'x':1}}}):
                bridge.atomic_json(home/'.claude/settings.json',value)
                self.assertFalse(bridge.limit_hook_installed())
                with self.assertRaisesRegex(ValueError,'left it unchanged'):
                    bridge.set_limit_hook(self.root,True)
                self.assertEqual(bridge.read_json(home/'.claude/settings.json'),value)
    def test_island_hook_installs_beside_the_users_hooks_for_both_clis_and_removes_cleanly(self):
        home=self.root/'home'; (home/'.claude').mkdir(parents=True); (home/'.codex').mkdir()
        mine={'matcher':'Bash','hooks':[{'type':'command','command':'my-guard'}]}
        bridge.atomic_json(home/'.claude/settings.json',{'model':'opus','hooks':{'PermissionRequest':[mine]}})
        with patch.object(Path,'home',return_value=home), patch.dict(os.environ,{'CODEX_HOME':''}):
            self.assertEqual(bridge.island_state(self.root,['claude','codex'],'on'),{'claude':True,'codex':True})
            bridge.island_state(self.root,['claude'],'on')
            groups=bridge.read_json(home/'.claude/settings.json')['hooks']['PermissionRequest']
            self.assertEqual(len(groups),2); self.assertEqual(groups[0],mine)
            hook=groups[1]['hooks'][0]
            self.assertEqual((hook['timeout'],groups[1]['matcher']),(bridge.ISLAND_TIMEOUT,'*'))
            self.assertNotIn('python',hook['command'])
            codex=bridge.read_json(home/'.codex/hooks.json')['hooks']['PermissionRequest'][0]['hooks'][0]
            self.assertTrue(codex['command'].split(' # ')[0].endswith(' codex'))
            self.assertTrue((self.root/'runtime/island_hook.py').exists())
            stop=bridge.read_json(home/'.claude/settings.json')['hooks']['Stop']
            self.assertEqual((len(stop),stop[0]['hooks'][0]['timeout'],stop[0]['hooks'][0]['asyncRewake']),(1,bridge.ISLAND_FOLLOW_UP,True))
            self.assertEqual(bridge.read_json(home/'.codex/hooks.json')['hooks']['Stop'][0]['hooks'][0],
                             {'type':'command','command':bridge.island_command(self.root,'codex'),'timeout':5})
            hooks=bridge.read_json(home/'.claude/settings.json')['hooks']
            self.assertEqual([hooks[e][0]['hooks'][0]['command'] for e in ('PreToolUse','PostToolUse','PostToolUseFailure')],
                             [bridge.island_command(self.root,'claude',bridge.island_mail_launcher(self.root))]*3)
            # A handler the user added to Side A's own group stays when the island goes off.
            settings=bridge.read_json(home/'.claude/settings.json')
            settings['hooks']['Stop'][0]['hooks'].append({'type':'command','command':'my-stop'})
            bridge.atomic_json(home/'.claude/settings.json',settings)
            bridge.island_state(self.root,['claude'],'off')
            self.assertEqual(bridge.read_json(home/'.claude/settings.json')['hooks']['Stop'],[{'hooks':[{'type':'command','command':'my-stop'}]}])
            bridge.island_state(self.root,['claude'],'on')
            settings=bridge.read_json(home/'.claude/settings.json'); settings['hooks']['Stop']=[g for g in settings['hooks']['Stop'] if g['hooks'][0]['command']!='my-stop']
            bridge.atomic_json(home/'.claude/settings.json',settings)
            codex_hooks=bridge.read_json(home/'.codex/hooks.json')['hooks']
            self.assertEqual([codex_hooks[e][0]['hooks'][0]['command'] for e in ('PreToolUse','PostToolUse')],
                             [bridge.island_command(self.root,'codex',bridge.island_mail_launcher(self.root,'codex'))]*2)
            self.assertNotIn('PostToolUseFailure',codex_hooks)
            # An install from before the mail hooks gains them on the next sync.
            settings=bridge.read_json(home/'.claude/settings.json'); del settings['hooks']['PostToolUse']
            bridge.atomic_json(home/'.claude/settings.json',settings)
            bridge.island_state(self.root,['claude'],'sync')
            self.assertIn('PostToolUse',bridge.read_json(home/'.claude/settings.json')['hooks'])
            self.assertEqual(bridge.island_state(self.root,['claude','codex'],'off'),{'claude':False,'codex':False})
            self.assertEqual(bridge.read_json(home/'.claude/settings.json'),{'model':'opus','hooks':{'PermissionRequest':[mine]}})
            self.assertEqual(bridge.read_json(home/'.codex/hooks.json'),{})
            # Turning Codex off never creates a hooks file that wasn't there.
            (home/'.codex/hooks.json').unlink(); bridge.island_state(self.root,['codex'],'off')
            self.assertFalse((home/'.codex/hooks.json').exists())
    def test_island_mail_reaches_a_working_session_at_its_next_tool_call(self):
        home=self.root/'home'; (home/'.claude').mkdir(parents=True)
        with patch.object(Path,'home',return_value=home):
            bridge.set_island(self.root,'claude',True)
            hooks=bridge.read_json(home/'.claude/settings.json')['hooks']
        def run(event,pid='4242'):
            command=hooks[event][0]['hooks'][0]['command']
            done=subprocess.run(['/bin/sh','-c',command],input=json.dumps({'hook_event_name':event,'tool_name':'Bash'}),
                                capture_output=True,text=True,timeout=20,env={**os.environ,'CLAUDE_PID':pid})
            return json.loads(done.stdout) if done.stdout else None
        mailbox=bridge.island_mail(self.root)/'4242.json'
        self.assertIsNone(run('PostToolUse'))
        mailbox.write_text(json.dumps({'kind':'note','text':'Use the staging database'}))
        self.assertIsNone(run('PreToolUse')); self.assertIsNone(run('PostToolUse','1'))
        note=run('PostToolUseFailure')['hookSpecificOutput']
        self.assertEqual(note['hookEventName'],'PostToolUseFailure')
        mailbox.write_text(json.dumps({'kind':'note','text':'Use the staging database'}))
        note=run('PostToolUse')['hookSpecificOutput']
        self.assertEqual(note['hookEventName'],'PostToolUse'); self.assertTrue(note['additionalContext'].endswith('Use the staging database'))
        self.assertFalse(mailbox.exists()); self.assertIsNone(run('PostToolUse'))
        mailbox.write_text(json.dumps({'kind':'stop'}))
        self.assertIsNone(run('PostToolUse'))
        stopped=run('PreToolUse')
        self.assertEqual((stopped['continue'],stopped['hookSpecificOutput']['permissionDecision']),(False,'deny'))
        # Tool calls of the same response are denied too; a stop older than its hold is cleared.
        self.assertEqual(run('PreToolUse'),stopped)
        mailbox.write_text(json.dumps({'kind':'stop','since':time.time()-60}))
        self.assertIsNone(run('PreToolUse')); self.assertFalse(mailbox.exists())
    def test_island_mail_gives_codex_notes_by_thread_id(self):
        home=self.root/'home'; (home/'.codex').mkdir(parents=True)
        with patch.object(Path,'home',return_value=home), patch.dict(os.environ,{'CODEX_HOME':str(home/'.codex')}):
            bridge.set_island(self.root,'codex',True)
            hooks=bridge.read_json(home/'.codex/hooks.json')['hooks']
        def run(event,thread='01a152eb-366a-7261-b816-a5b65dfad495'):
            done=subprocess.run(['/bin/sh','-c',hooks[event][0]['hooks'][0]['command']],capture_output=True,text=True,timeout=20,
                                input=json.dumps({'hook_event_name':event,'tool_name':'exec_command','session_id':thread}))
            return json.loads(done.stdout) if done.stdout else None
        mailbox=bridge.island_mail(self.root)/'codex'/'01a152eb-366a-7261-b816-a5b65dfad495.json'
        self.assertIsNone(run('PostToolUse'))
        mailbox.parent.mkdir(exist_ok=True); mailbox.write_text(json.dumps({'kind':'note','text':'Use the staging database'}))
        # Another thread's tool call leaves it, as does one with a session id that isn't a thread id.
        self.assertIsNone(run('PostToolUse','01a00000-0000-7000-8000-000000000000')); self.assertIsNone(run('PostToolUse','../x'))
        note=run('PostToolUse')['hookSpecificOutput']
        self.assertEqual(note['hookEventName'],'PostToolUse'); self.assertTrue(note['additionalContext'].endswith('Use the staging database'))
        self.assertFalse(mailbox.exists())
        # Codex 0.163 fails a hook that says continue:false and runs the tool anyway, so its stop is the deny alone.
        mailbox.write_text(json.dumps({'kind':'stop'}))
        self.assertEqual(run('PreToolUse'),{'hookSpecificOutput':{'hookEventName':'PreToolUse','permissionDecision':'deny',
                                                                 'permissionDecisionReason':'The user stopped this session from Side A.'}})
    def test_inbox_hooks_wake_a_session_with_its_message_and_the_newest_one_waits(self):
        home=self.root/'home'; (home/'.claude').mkdir(parents=True)
        mine={'hooks':[{'type':'command','command':'my-start'}]}
        bridge.atomic_json(home/'.claude/settings.json',{'hooks':{'SessionStart':[mine]}})
        with patch.object(Path,'home',return_value=home):
            bridge.set_island(self.root,'claude',True)
            bridge.set_inbox(self.root,True)
            settings=bridge.read_json(home/'.claude/settings.json')
            # Rewriting the island's hooks leaves the inbox's alone, and both sit beside the user's own.
            bridge.set_island(self.root,'claude',True)
            handlers=lambda value: {event:sorted(json.dumps(h,sort_keys=True) for g in groups for h in g['hooks']) for event,groups in value['hooks'].items()}
            self.assertEqual(handlers(bridge.read_json(home/'.claude/settings.json')),handlers(settings))
            self.assertTrue(bridge.inbox_installed())
            start=settings['hooks']['SessionStart']
            self.assertEqual(start[0],mine)
            handler=start[1]['hooks'][0]
            self.assertEqual((handler['asyncRewake'],handler['timeout']),(True,bridge.INBOX_TIMEOUT))
            self.assertEqual(sum(bridge.INBOX_MARK in h['command'] for g in settings['hooks']['Stop'] for h in g['hooks']),1)
        folder=self.root/'runtime/inbox'
        # A parent that stays put while the hooks run, as Claude Code does.
        parent=subprocess.Popen(['/bin/sh','-c','sleep 30'])
        self.addCleanup(parent.kill)
        def hook():
            return subprocess.Popen(['/bin/sh','-c',f'CLAUDE_PID={parent.pid} exec {handler["command"]}'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE,text=True)
        first=hook(); first.stdin.write('{"hook_event_name":"SessionStart"}'); first.stdin.close()
        for _ in range(100):
            if (folder/f'{parent.pid}.watcher').exists(): break
            time.sleep(0.05)
        second=hook(); second.stdin.write('{"hook_event_name":"Stop"}'); second.stdin.close()
        # The newer one takes over; the older leaves quietly.
        self.assertEqual(first.wait(5),0); first.stdout.close(); first.stderr.close()
        self.assertEqual((folder/f'{parent.pid}.watcher').read_text(),str(second.pid))
        (folder/f'{parent.pid}.json').write_text(json.dumps({'text':'  run the tests  ','id':'m1'}))
        second.wait(5); out,err=second.stdout.read(),second.stderr.read()
        second.stdout.close(); second.stderr.close()
        self.assertEqual((second.returncode,out),(2,''))
        self.assertEqual(err,'The user sent you this from Side A:\n\nrun the tests\n')
        self.assertEqual(json.loads((folder/f'{parent.pid}.delivered').read_text())['id'],'m1')
        self.assertFalse((folder/f'{parent.pid}.json').exists() or (folder/f'{parent.pid}.watcher').exists())
        # The transcript shows it as the user's message.
        sys.path.insert(0,str(Path(bridge.__file__).parent)); import sessions
        entry='<task-notification>\n<summary>Stop hook feedback</summary>\n</task-notification>\n<system-reminder>\nStop hook blocking error from command "Stop": '+err+'\n</system-reminder>'
        self.assertEqual(sessions.prompt_text(entry),'run the tests')
        self.assertEqual(sessions.prompt_text('<task-notification><summary>Background command finished</summary></task-notification>'),'')
        # Turning the island off takes the inbox with it.
        with patch.object(Path,'home',return_value=home):
            bridge.island_state(self.root,['claude'],'off')
            self.assertFalse(bridge.inbox_installed())
            self.assertEqual(bridge.read_json(home/'.claude/settings.json'),{'hooks':{'SessionStart':[mine]}})

    def test_an_inbox_hook_whose_session_died_leaves(self):
        # Its parent gone, the hook belongs to launchd and must not wait a day for a message nobody can read.
        script=Path(bridge.__file__).with_name('island_hook.py')
        sock=self.root/'runtime/island.sock'; (self.root/'runtime').mkdir()
        hook=subprocess.Popen(['/bin/sh','-c',f'{sys.executable} -I -S {script} {sock} claude inbox </dev/null & echo $!; sleep 0.5'],stdout=subprocess.PIPE,text=True)
        child=int(hook.stdout.readline())
        hook.wait(5)
        for _ in range(40):
            try: os.kill(child,0)
            except ProcessLookupError: break
            time.sleep(0.1)
        else:
            os.kill(child,9); self.fail('the orphaned inbox hook kept waiting')

    def test_island_launchers_step_aside_when_the_hook_script_is_gone(self):
        home=self.root/'home'; (home/'.claude').mkdir(parents=True)
        with patch.object(Path,'home',return_value=home):
            bridge.set_island(self.root,'claude',True)
            hooks=bridge.read_json(home/'.claude/settings.json')['hooks']
        (self.root/'runtime/island_hook.py').unlink(); (bridge.island_mail(self.root)/'4242.json').write_text('{"kind":"note","text":"x"}')
        stop={'hook_event_name':'Stop','session_id':'s','cwd':'/tmp','last_assistant_message':'Done.'}
        for event in ('Stop','PostToolUse'):
            done=subprocess.run(['/bin/sh','-c',hooks[event][0]['hooks'][0]['command']],input=json.dumps({**stop,'hook_event_name':event}),
                                capture_output=True,text=True,timeout=5,env={**os.environ,'CLAUDE_PID':'4242'})
            # Exit 2 would wake an idle session with Python's "can't open file" as its next instruction.
            self.assertEqual((event,done.returncode,done.stdout,done.stderr),(event,0,'',''))
    def test_island_hook_relays_the_islands_answer_and_steps_aside_without_side_a(self):
        import socket, threading
        home=self.root/'home'; (home/'.claude').mkdir(parents=True)
        with patch.object(Path,'home',return_value=home):
            bridge.set_island(self.root,'claude',True)
            command=bridge.read_json(home/'.claude/settings.json')['hooks']['PermissionRequest'][0]['hooks'][0]['command']
        request={'hook_event_name':'PermissionRequest','session_id':'s','cwd':'/tmp','tool_name':'Bash','tool_input':{'command':'ls'},
                 'permission_suggestions':[{'type':'addRules','rules':[{'toolName':'Bash','ruleContent':'ls'}],'behavior':'allow','destination':'localSettings'}]}
        run=lambda env={}: subprocess.run(['/bin/sh','-c',command],input=json.dumps(request),capture_output=True,text=True,timeout=20,env={**os.environ,**env})
        # No island: nothing printed, so Claude Code asks in the terminal.
        self.assertEqual((run().returncode,run().stdout),(0,''))
        server=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); server.bind(str(bridge.island_socket(self.root))); server.listen(4)
        self.addCleanup(server.close)
        seen=[]
        def answer(*replies):
            for reply in replies:
                connection,_=server.accept(); data=b''
                while not data.endswith(b'\n'): data+=connection.recv(65536)
                seen.append(json.loads(data))
                if reply is not None: connection.sendall(json.dumps(reply).encode()+b'\n')
                connection.close()
        thread=threading.Thread(target=answer,args=({'behavior':'allow','permissions':request['permission_suggestions']},
                                                    {'behavior':'deny','message':'Not now'},{'behavior':'ask'},None,
                                                    {'followUp':'Now open a PR'},{'cancel':True})); thread.start()
        allowed=json.loads(run({'CLAUDE_SECURESTORAGE_CONFIG_DIR':'/x/profiles/abc/','CLAUDE_PID':'4242','CLAUDE_CODE_ENTRYPOINT':'sdk-cli',
                                'SIDE_A_HOSTED':'sa-web-ab12','CODEX_HOME':'/x/profiles/def'}).stdout)['hookSpecificOutput']
        self.assertEqual(allowed['decision'],{'behavior':'allow','updatedPermissions':request['permission_suggestions']})
        self.assertEqual(json.loads(run({'CLAUDE_SECURESTORAGE_CONFIG_DIR':'','CLAUDE_CODE_ENTRYPOINT':'cli'}).stdout)['hookSpecificOutput']['decision'],{'behavior':'deny','message':'Not now'})
        self.assertEqual(run().stdout,''); self.assertEqual(run().stdout,'')
        # A finished turn is reported without waiting; one paused on background work isn't.
        stop={'hook_event_name':'Stop','session_id':'s','cwd':'/tmp','last_assistant_message':'Done.','background_tasks':[]}
        stop_run=lambda payload: subprocess.run(['/bin/sh','-c',command],input=json.dumps(payload),capture_output=True,text=True,timeout=5)
        woken=stop_run(stop); released=stop_run({**stop,'stop_hook_active':True}); paused=stop_run({**stop,'background_tasks':[{'id':'1'}]})
        # A follow-up wakes the idle session through asyncRewake: exit 2 with the request on stderr.
        # The turn a follow-up woke ends with stop_hook_active set, and still waits for the next one.
        self.assertEqual((woken.returncode,woken.stdout),(2,'')); self.assertIn('Now open a PR',woken.stderr)
        self.assertEqual((released.returncode,released.stderr,paused.returncode),(0,'',0))
        thread.join(5)
        self.assertEqual((seen[4]['request']['last_assistant_message'],seen[4]['wait']),('Done.',True)); self.assertEqual(len(seen),6)
        self.assertEqual((seen[0]['agent'],seen[0]['slot'],seen[0]['request']['tool_input']),('claude','abc',{'command':'ls'}))
        self.assertEqual((seen[0]['pid'],seen[0]['headless']),(4242,True))
        self.assertEqual((seen[1]['slot'],seen[1]['headless']),('mac',False))
        # The hosted name is forwarded; a Codex home only for Codex.
        self.assertEqual((seen[0]['hosted'],seen[0]['home'],seen[1].get('hosted')),('sa-web-ab12',None,None))
    def test_island_answers_become_the_hooks_decision(self):
        island_hook=self.hook()
        rule={'type':'addRules','rules':[{'toolName':'Bash','ruleContent':'ls'}],'behavior':'allow','destination':'session'}
        switch={'type':'setMode','mode':'acceptEdits','destination':'session'}
        cases=[
            # Rules, "Allow and switch mode" (alone or joining picked rules), and answered questions reach Claude Code as is.
            ({'behavior':'allow','permissions':[switch]},'claude',{'behavior':'allow','updatedPermissions':[switch]}),
            ({'behavior':'allow','mode':'acceptEdits','permissions':[rule]},'claude',{'behavior':'allow','updatedPermissions':[rule,switch]}),
            ({'behavior':'allow','input':{'questions':[],'answers':{'Q':'A'}}},'claude',{'behavior':'allow','updatedInput':{'questions':[],'answers':{'Q':'A'}}}),
            ({'behavior':'allow','mode':'../x'},'claude',{'behavior':'allow'}),
            ({'behavior':'deny','mode':'auto','interrupt':True},'claude',{'behavior':'deny','message':'Denied in Side A.','interrupt':True}),
            # Codex fails closed on updatedPermissions, so nothing beyond the behavior is ever sent to it.
            ({'behavior':'allow','permissions':[rule],'mode':'acceptEdits','input':{'q':1}},'codex',{'behavior':'allow'}),
            ({'behavior':'deny','message':'Not now','interrupt':True},'codex',{'behavior':'deny','message':'Not now'}),
        ]
        for answer,agent,decision in cases:
            with self.subTest(answer=answer,agent=agent):
                self.assertEqual(island_hook.output(answer,agent)['hookSpecificOutput']['decision'],decision)
        self.assertIsNone(island_hook.output({'behavior':'ask'},'claude'))
    def hook(self):
        sys.path.insert(0,str(Path(bridge.__file__).parent)); import island_hook
        return island_hook

    def run_hook(self, island_hook, request, agent='codex', answer=AssertionError('asked')):
        """main() on one request; `answer` is what the island replies, or an exception when it must not be asked."""
        out=MagicMock()
        ask=patch.object(island_hook,'ask',side_effect=answer) if isinstance(answer,Exception) else patch.object(island_hook,'ask',return_value=answer)
        with ask as asked, patch.object(sys,'stdin',MagicMock(read=lambda *_: json.dumps(request))), patch.object(sys,'stdout',out), \
             patch.object(island_hook,'managed_requirements',return_value=[]), patch.dict(os.environ,{'CODEX_HOME':str(self.root/'codex')}):
            island_hook.main([str(self.root/'runtime/island.sock'),agent])
        written=''.join(call.args[0] for call in out.write.call_args_list)
        return (json.loads(written) if written else None), asked

    def test_codex_calls_its_own_reviewer_decides_never_reach_the_island(self):
        island_hook=self.hook()
        rollout=self.root/'rollout.jsonl'
        line=lambda kind,payload: json.dumps({'type':kind,'payload':payload})
        settings=lambda who: line('event_msg',{'type':'thread_settings_applied','thread_settings':{'approvals_reviewer':who}})
        context=lambda who: line('turn_context',{'approval_policy':'on-request','approvals_reviewer':who})
        started=line('event_msg',{'type':'task_started','turn_id':'t2'})
        filler=line('response_item',{'type':'message','text':'x'*(island_hook.TAIL_CHUNK//3)})
        review=lambda *lines: (rollout.write_text('\n'.join(lines)+'\n'), island_hook.codex_review(str(rollout)))[1]
        self.assertEqual(review(context('user'),settings('auto_review'),filler,filler,filler,filler),('auto_review',False))
        self.assertEqual(review(settings('auto_review'),context('user'),filler),('user',False))
        self.assertEqual(review(filler),(None,False))
        self.assertEqual(island_hook.codex_review(None),(None,False)); self.assertEqual(island_hook.codex_review(str(self.root/'gone.jsonl')),(None,False))
        # A strict auto-review grant holds for the rest of its turn only.
        call=line('response_item',{'type':'function_call','name':'request_permissions','call_id':'c1','arguments':'{}'})
        grant=lambda strict: line('response_item',{'type':'function_call_output','call_id':'c1','output':json.dumps({'permissions':{},'scope':'turn','strict_auto_review':strict})})
        self.assertEqual(review(context('user'),started,call,grant(True),filler),('user',True))
        self.assertEqual(review(context('user'),started,call,grant(False)),('user',False))
        self.assertEqual(review(context('user'),call,grant(True),started),('user',False))
        request={'hook_event_name':'PermissionRequest','session_id':'t','cwd':'/r','tool_name':'Bash','tool_input':{'command':'ls'},
                 'transcript_path':str(rollout),'permission_mode':'default','model':'gpt-6'}
        rollout.write_text(context('auto_review')+'\n'); self.assertEqual(self.run_hook(island_hook,request)[0],None)
        rollout.write_text(context('user')+'\n'+started+'\n'+call+'\n'+grant(True)+'\n'); self.assertEqual(self.run_hook(island_hook,request)[0],None)
        rollout.write_text(context('user')+'\n')
        self.assertEqual(self.run_hook(island_hook,{**request,'permission_mode':'bypassPermissions'})[0],None)
        # A thread the user reviews is asked.
        self.assertEqual(self.run_hook(island_hook,request,answer={'behavior':'deny','message':'no'})[0]['hookSpecificOutput']['decision'],{'behavior':'deny','message':'no'})
        # An administrator's requirements send it to the reviewer too.
        with patch.object(island_hook,'managed_requirements',return_value=[{'allowed_approvals_reviewers':['auto_review']}]):
            self.assertTrue(island_hook.required_review('gpt-6'))
        with patch.object(island_hook,'managed_requirements',return_value=[{'auto_review':{'required_on_models':['gpt-6']}}]):
            self.assertTrue(island_hook.required_review('openai/gpt-6')); self.assertFalse(island_hook.required_review('gpt-5'))

    @unittest.skipUnless(importlib.util.find_spec('tomllib'),'tomllib is Python 3.11+; without it the island asks as before')
    def test_codex_apps_follow_their_own_reviewer(self):
        island_hook=self.hook()
        rollout=self.root/'rollout.jsonl'
        context=lambda who: json.dumps({'type':'turn_context','payload':{'approval_policy':'on-request','approvals_reviewer':who}})
        rollout.write_text(context('user')+'\n')
        request={'hook_event_name':'PermissionRequest','session_id':'t','cwd':'/r','tool_name':'Bash','tool_input':{'command':'ls'},
                 'transcript_path':str(rollout),'permission_mode':'default','model':'gpt-6'}
        # Codex Apps tools follow [apps] in config.toml.
        (self.root/'codex').mkdir(); (self.root/'codex/config.toml').write_text('[apps.gmail]\napprovals_reviewer = "auto_review"\n')
        self.assertEqual(island_hook.app_reviewer('mcp__codex_apps__gmail_send',str(self.root/'codex')),'auto_review')
        self.assertIsNone(island_hook.app_reviewer('mcp__codex_apps__drive_list',str(self.root/'codex')))
        self.assertIsNone(island_hook.app_reviewer('mcp__codex_apps__gmailer_send',str(self.root/'codex')))
        self.assertIsNone(island_hook.app_reviewer('mcp__github__create_issue',str(self.root/'codex')))
        self.assertEqual(self.run_hook(island_hook,{**request,'tool_name':'mcp__codex_apps__gmail_send','tool_input':{}})[0],None)
        (self.root/'codex/config.toml').write_text('[apps._default]\napprovals_reviewer = "auto_review"\n')
        self.assertEqual(island_hook.app_reviewer('mcp__codex_apps__drive_list',str(self.root/'codex')),'auto_review')
        # An app the user reviews is asked even in a thread Codex reviews.
        (self.root/'codex/config.toml').write_text('[apps.gmail]\napprovals_reviewer = "user"\n')
        rollout.write_text(context('auto_review')+'\n')
        self.assertEqual(self.run_hook(island_hook,{**request,'tool_name':'mcp__codex_apps__gmail_send','tool_input':{}},answer={'behavior':'deny','message':'no'})[0]['hookSpecificOutput']['decision']['behavior'],'deny')
        self.assertEqual(self.run_hook(island_hook,request)[0],None)

    def test_codex_session_approvals_from_side_a_answer_repeats_without_asking(self):
        island_hook=self.hook()
        rollout=self.root/'rollout.jsonl'; rollout.write_text(json.dumps({'type':'turn_context','payload':{'approvals_reviewer':'user'}})+'\n')
        base={'hook_event_name':'PermissionRequest','session_id':'thread-1','cwd':'/r','transcript_path':str(rollout),'permission_mode':'default','model':'m'}
        patch_of=lambda *lines: {**base,'tool_name':'apply_patch','tool_input':{'command':'\n'.join(['*** Begin Patch',*lines,'*** End Patch'])}}
        request=patch_of('*** Update File: a.py','*** Update File: b.py')
        allow={'hookSpecificOutput':{'hookEventName':'PermissionRequest','decision':{'behavior':'allow'}}}
        session={'behavior':'allow','permissions':[{'type':'codexSession'}]}
        # A plain Allow is once.
        self.assertEqual(self.run_hook(island_hook,request,answer={'behavior':'allow'})[0],allow)
        self.assertEqual(self.run_hook(island_hook,request,answer={'behavior':'ask'})[0],None)
        # This session: later patches to covered files pass; another file, folder or thread asks.
        self.assertEqual(self.run_hook(island_hook,request,answer=session)[0],allow)
        self.assertEqual(self.run_hook(island_hook,patch_of('*** Update File: a.py'))[0],allow)
        for other in (patch_of('*** Update File: a.py','*** Update File: c.py'),{**request,'cwd':'/other'},{**request,'session_id':'thread-2'}):
            self.assertEqual(self.run_hook(island_hook,other,answer={'behavior':'ask'})[0],None)
        # Never a delete, an indented header Codex would still read, or a command (its workdir isn't in the request).
        self.assertEqual(island_hook.approval_keys(patch_of('*** Delete File: a.py')),[])
        self.assertEqual(island_hook.approval_keys(patch_of('*** Update File: a.py','  *** Delete File: x.py')),[])
        self.assertEqual(island_hook.approval_keys(patch_of('*** Update File: a.py ')),[])
        self.assertEqual(island_hook.approval_keys({**base,'tool_name':'Bash','tool_input':{'command':'make test'}}),[])
        self.assertEqual(island_hook.approval_keys({**request,'cwd':'relative'}),[])
        self.assertEqual(self.run_hook(island_hook,patch_of('*** Update File: a.py','  *** Delete File: x.py'),answer={'behavior':'ask'})[0],None)
        # Grants answered at once both land.
        import threading
        later=[patch_of(f'*** Update File: p{n}.py') for n in range(8)]
        threads=[threading.Thread(target=island_hook.remember_approval,args=(str(self.root/'runtime/state'),r,session)) for r in later]
        [t.start() for t in threads]; [t.join() for t in threads]
        self.assertTrue(all(island_hook.approved(str(self.root/'runtime/state'),r) for r in later))
        # Approvals lapse.
        stored=self.root/'runtime/state/codex-approved/thread-1.json'
        data=json.loads(stored.read_text()); [entry.update(at=time.time()-island_hook.APPROVAL_TTL-1) for entry in data['keys']]; stored.write_text(json.dumps(data))
        self.assertEqual(self.run_hook(island_hook,request,answer={'behavior':'ask'})[0],None)
        self.assertEqual(island_hook.approvals_path(str(self.root),{'session_id':'../x'}),None)
        # Another thread's lapsed file goes when an approval is written.
        old=stored.parent/'thread-old.json'; old.write_text('{"keys":[]}'); os.utime(old,(0,0))
        self.run_hook(island_hook,request,answer=session)
        self.assertFalse(old.exists()); self.assertTrue(stored.exists())

    def test_claude_requests_settled_without_the_island_are_withdrawn(self):
        island_hook=self.hook()
        self.addCleanup(setattr,island_hook,'WATCH_POLL',island_hook.WATCH_POLL); island_hook.WATCH_POLL=0.05
        transcript=self.root/'s.jsonl'
        use=lambda id,command: json.dumps({'type':'assistant','message':{'content':[{'type':'tool_use','id':id,'name':'Bash','input':{'command':command}}]}})
        result=lambda id: json.dumps({'type':'user','message':{'content':[{'type':'tool_result','tool_use_id':id,'content':'ok'}]}})
        transcript.write_text('\n'.join([use('u1','ls'),result('u1'),use('u2','ls')])+'\n')
        request={'tool_name':'Bash','tool_input':{'command':'ls'},'transcript_path':str(transcript)}
        settled=island_hook.watch_transcript(request)
        self.assertFalse(settled()); self.assertFalse(settled())
        with transcript.open('a') as stream: stream.write(use('u3','pwd')+'\n')
        self.assertFalse(settled())
        with transcript.open('a') as stream: stream.write(result('u2')+'\n')
        self.assertTrue(settled())
        # A subagent's calls are in its own transcript.
        own=self.root/'s/subagents/agent-a1.jsonl'; own.parent.mkdir(parents=True); own.write_text(use('v1','ls')+'\n')
        self.assertEqual(island_hook.claude_transcript({**request,'agent_id':'a1'}),str(own))
        self.assertEqual(island_hook.claude_transcript({**request,'agent_id':'zz'}),str(transcript))
        self.assertIsNone(island_hook.watch_transcript({'tool_name':'Bash'}))
        # A call settled before the first poll still counts: the watch finds it when it's made.
        transcript.write_text(use('x1','ls')+'\n'); early=island_hook.watch_transcript(request)
        with transcript.open('a') as stream: stream.write(result('x1')+'\n')
        self.assertTrue(early())
        # Two calls alike waiting at once can't be told apart, so neither is withdrawn.
        transcript.write_text('\n'.join([use('w1','ls'),use('w2','ls')])+'\n')
        twin=island_hook.watch_transcript(request); self.assertFalse(twin())
        with transcript.open('a') as stream: stream.write(result('w1')+'\n')
        self.assertFalse(twin())
        # ask() gives up and closes when the check says so.
        import socket, threading
        sock=self.root/'w.sock'; server=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); server.bind(str(sock)); server.listen(1); self.addCleanup(server.close)
        closed=threading.Event()
        def hold():
            connection,_=server.accept(); connection.recv(65536)
            if connection.recv(1)==b'': closed.set()
            connection.close()
        threading.Thread(target=hold,daemon=True).start()
        calls=iter([False,True])
        self.assertIsNone(island_hook.ask(str(sock),{'v':1},lambda: next(calls)))
        self.assertTrue(closed.wait(5))

    def test_claude_hooks_record_the_mode_a_model_switch_and_background_work_for_the_row(self):
        home=self.root/'home'; (home/'.claude').mkdir(parents=True)
        with patch.object(Path,'home',return_value=home):
            bridge.set_island(self.root,'claude',True)
            hooks=bridge.read_json(home/'.claude/settings.json')['hooks']
            self.assertEqual(hooks['PostModelSwitch'],[{'hooks':[{'type':'command','command':bridge.island_command(self.root,'claude'),'timeout':30}]}])
            self.assertTrue(bridge.island_current('claude'))
            # An install from before PostModelSwitch gains it on the next sync.
            settings=bridge.read_json(home/'.claude/settings.json'); del settings['hooks']['PostModelSwitch']
            bridge.atomic_json(home/'.claude/settings.json',settings)
            self.assertFalse(bridge.island_current('claude'))
            # A Claude Code without PostModelSwitch, or one that won't say its version, never gets it; a downgrade loses it.
            bridge.set_island(self.root,'claude',True)
            for versions in ([(2,1,303),(2,1,200)],[None],[]):
                with patch.object(bridge,'claude_versions',return_value=versions):
                    self.assertFalse(bridge.island_current('claude'))
                    bridge.set_island(self.root,'claude',True)
                    self.assertNotIn('PostModelSwitch',bridge.read_json(home/'.claude/settings.json')['hooks'])
                    self.assertTrue(bridge.island_current('claude'))
                bridge.set_island(self.root,'claude',True)
            self.assertIn('PostModelSwitch',bridge.read_json(home/'.claude/settings.json')['hooks'])
        state=self.root/'runtime/state'
        def run(event,agent='claude',**payload):
            command=hooks[event][0]['hooks'][0]['command'] if agent=='claude' else bridge.island_command(self.root,'codex')
            done=subprocess.run(['/bin/sh','-c',command],input=json.dumps({'hook_event_name':event,'session_id':'s1','cwd':'/tmp',**payload}),
                                capture_output=True,text=True,timeout=20,env={**os.environ,'CLAUDE_PID':'4242'})
            self.assertEqual((done.returncode,done.stdout),(0,''))
        run('PostModelSwitch',from_model='claude-opus-5-5',to_model='claude-sonnet-5-5',source='command',permission_mode='plan',effort={'level':'high'})
        run('Stop',last_assistant_message='Started the dev server.',permission_mode='acceptEdits',
            background_tasks=[{'id':'b1','type':'shell','status':'running','description':'npm run dev','command':'npm run dev -- --port 3000'},'junk'])
        read=lambda kind: json.loads((state/f's1.{kind}.json').read_text())
        self.assertEqual(read('model'),{'model':'claude-sonnet-5-5'})
        self.assertEqual(read('hook'),{'mode':'acceptEdits','effort':None})
        self.assertEqual(read('tasks'),{'tasks':[{'id':'b1','type':'shell','status':'running','description':'npm run dev'}]})
        # A subagent's own model, a Codex session and an id that isn't one record nothing.
        run('PostModelSwitch',to_model='claude-haiku-5-5',agent_id='a1')
        run('PostModelSwitch',agent='codex',to_model='gpt-5.5',session_id='s2')
        run('PostModelSwitch',to_model='x',session_id='../escape')
        self.assertEqual(read('model'),{'model':'claude-sonnet-5-5'})
        self.assertEqual(sorted(p.name for p in state.iterdir()),['s1.hook.json','s1.model.json','s1.tasks.json'])
        sys.path.insert(0,str(Path(bridge.__file__).parent)); import sessions
        self.assertEqual(sessions.claude_settings(self.root,'s1'),{'model':'claude-sonnet-5-5','mode':'acceptEdits',
                         'backgroundTasks':[{'id':'b1','type':'shell','status':'running','description':'npm run dev'}]})
        # A Stop with nothing running clears the list.
        run('Stop',last_assistant_message='Done.')
        self.assertEqual(read('tasks'),{'tasks':[]})
    def test_claude_versions_are_read_from_the_installers_link_or_asked(self):
        home=self.root/'home'; versions=home/'.local/share/claude/versions'; versions.mkdir(parents=True); (home/'.local/bin').mkdir()
        (versions/'2.1.303').write_text('#!/bin/sh\nexit 1\n'); (versions/'2.1.303').chmod(0o755)
        (home/'.local/bin/claude').symlink_to(versions/'2.1.303')
        (home/'.npm-global/bin').mkdir(parents=True)
        (home/'.npm-global/bin/claude').write_text('#!/bin/sh\necho "2.1.180 (Claude Code)"\n'); (home/'.npm-global/bin/claude').chmod(0o755)
        self.versions_stop()
        with patch.object(Path,'home',return_value=home), patch.object(Path,'is_file',lambda p: str(p).startswith(str(home)) and os.path.isfile(p)):
            bridge.claude_versions.cache_clear()
            self.assertEqual(bridge.claude_versions(),[(2,1,303),(2,1,180)])
            self.assertFalse(bridge.model_switch_hook())
            bridge.claude_versions.cache_clear()
        bridge.claude_versions.cache_clear()
    def test_slot_models_read_each_sessions_latest_main_thread_reply(self):
        home=self.root/'home'; (home/'.claude/sessions').mkdir(parents=True); (home/'.claude/projects/p').mkdir(parents=True)
        ids=[str(uuid.uuid4()) for _ in range(3)]
        lines=lambda model,side: [json.dumps({'type':'assistant','message':{'model':model}}),
                                  json.dumps({'type':'assistant','isSidechain':True,'message':{'model':side}}),
                                  json.dumps({'type':'user','message':{'content':'x'*300000}})]
        (home/f'.claude/projects/p/{ids[0]}.jsonl').write_text('\n'.join(lines('claude-fable-5-1','claude-haiku-4-5'))+'\n')
        (home/f'.claude/projects/p/{ids[1]}.jsonl').write_text('\n'.join(lines('claude-opus-5-5','claude-haiku-4-5'))+'\n')
        for pid,session in zip((11,12,13),ids): bridge.atomic_json(home/f'.claude/sessions/{pid}.json',{'sessionId':session})
        with patch.object(Path,'home',return_value=home):
            # A tool result longer than the usual tail still finds the reply before it; a session with no transcript is unknown.
            self.assertEqual(bridge.slot_models({11:'mac',12:'p1',13:'p1'}),{'mac':['claude-fable-5-1'],'p1':['claude-opus-5-5',None]})
            os.utime(home/f'.claude/projects/p/{ids[0]}.jsonl',(time.time()-900,)*2)
            quiet=bridge.slot_quiet({11:'mac',12:'p1',13:'p1'})
            self.assertEqual((set(quiet),round(quiet['mac']/60)),({'mac','p1'},15)); self.assertLess(quiet['p1'],60)
    def test_live_statusline_keeps_the_users_line_and_saves_each_accounts_limits(self):
        home=self.root/'home'; (home/'.claude').mkdir(parents=True)
        mine={'type':'command','command':"printf 'mine:'; cat",'padding':2}
        bridge.atomic_json(home/'.claude/settings.json',{'model':'opus','statusLine':mine})
        other=account('Other'); config={'accounts':[other]}
        payload='{"model":{"id":"x"},"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":2000000000},"seven_day":{"used_percentage":40,"resets_at":2000500000}}}\n\n'
        with patch.object(Path,'home',return_value=home):
            bridge.set_live(self.root,True); bridge.set_live(self.root,True)
            line=bridge.read_json(home/'.claude/settings.json')['statusLine']
            self.assertEqual(line['padding'],2)
            run=lambda env: subprocess.run(['/bin/zsh','-c',line['command']],input=payload,capture_output=True,text=True,
                                           env={**os.environ,**env}).stdout
            # The user's statusline sees the input byte for byte.
            self.assertEqual(run({'CLAUDE_SECURESTORAGE_CONFIG_DIR':str(self.root/'profiles'/other['id'])+'/'}),'mine:'+payload)
            with patch.object(bridge,'mac_email',return_value=None):
                live=bridge.live_limits(self.root,config)
            self.assertEqual(live[other['id']]['windows'][0],{'id':'five_hour','label':'5-hour','percent':12.0,'resetsAt':2000000000.0})
            self.assertEqual(live[other['id']]['windows'][1]['percent'],40.0)
            # Each session keeps its own copy for its row, limits or not; an id that isn't one is never a file name.
            mine_line='{"session_id":"5b0e-s1","model":{"id":"claude-opus-5-5"},"effort":{"level":"high"}}'
            subprocess.run(['/bin/zsh','-c',line['command']],input=mine_line,capture_output=True,text=True)
            self.assertEqual((bridge.live_dir(self.root)/'s/5b0e-s1.json').read_text(),mine_line)
            for hostile in ('{"session_id":"../../x","a":1}','{"session_id":"a b","a":1}','{"model":{"id":"x"}}'):
                subprocess.run(['/bin/zsh','-c',line['command']],input=hostile,capture_output=True,text=True)
            self.assertEqual(sorted(p.name for p in (bridge.live_dir(self.root)/'s').iterdir()),['5b0e-s1.json'])
            self.assertFalse((self.root/'runtime/x.json').exists())
            # A session with no limits yet (or a broken file) adds nothing.
            run({'CLAUDE_SECURESTORAGE_CONFIG_DIR':''}); (bridge.live_dir(self.root)/'junk.json').write_text('[')
            with patch.object(bridge,'mac_email',return_value=None):
                self.assertEqual(set(bridge.live_limits(self.root,config)),{other['id']})
            bridge.set_live(self.root,False)
            self.assertEqual(bridge.read_json(home/'.claude/settings.json'),{'model':'opus','statusLine':mine})
            bridge.atomic_json(home/'.claude/settings.json',{})
            bridge.set_live(self.root,True)
            self.assertEqual(subprocess.run(['/bin/sh','-c',bridge.read_json(home/'.claude/settings.json')['statusLine']['command']],
                                            input=payload,capture_output=True,text=True).stdout,'')
            bridge.set_live(self.root,False)
            self.assertEqual(bridge.read_json(home/'.claude/settings.json'),{})
            # A statusline that only mentions the marker is the user's, never unwrapped or dropped.
            theirs={'type':'command','command':"printf '%s' 'printf EXECUTED # side-a-live'"}
            bridge.atomic_json(home/'.claude/settings.json',{'statusLine':theirs})
            bridge.set_live(self.root,True); bridge.set_live(self.root,False)
            self.assertEqual(bridge.read_json(home/'.claude/settings.json'),{'statusLine':theirs})
    def test_report_counts_each_response_once_per_day_and_project(self):
        folder=Path(self.temp.name)/'home/.claude/projects/p'; folder.mkdir(parents=True)
        line=lambda mid,ts,out:json.dumps({'timestamp':ts,'cwd':'/work/app','requestId':'r'+mid,'message':{'id':mid,'model':'m','usage':{'input_tokens':1,'output_tokens':out}}})
        (folder/'s.jsonl').write_text('\n'.join([line('a','2026-10-01T15:00:00Z',5),line('a','2026-10-01T15:00:00Z',5),line('b','2026-10-01T17:30:00Z',7)])+'\n')
        with patch.object(Path,'home',return_value=Path(self.temp.name)/'home'), patch.object(bridge.time,'time',return_value=(folder/'s.jsonl').stat().st_mtime):
            result=bridge.report(self.root,days=10000)
        self.assertEqual([(r['project'],r['input'],r['output']) for r in result['projects']],[('/work/app',2,12)])
        self.assertEqual(len(result['activity']),1)
        self.assertEqual(sum(result['activity'][0]['hours']),2)
        self.assertEqual([(r['date'],r['model'],r['output']) for r in result['dayModels']],[('2026-10-01','m',12)])
        # A live session appends: only new bytes are read (the earlier bytes, rewritten in place to the same
        # length, aren't read again), a response split across the seam counts once, and a half-written
        # last line waits for the next scan.
        text=(folder/'s.jsonl').read_text(); (folder/'s.jsonl').write_text(text.replace('"output_tokens": 5','"output_tokens": 8'))
        with open(folder/'s.jsonl','a') as stream:
            stream.write(line('b','2026-10-01T17:30:00Z',7)+'\n'+line('c','2026-10-01T18:00:00Z',9)+'\n'+line('d','2026-10-01T18:05:00Z',100)[:30])
        with patch.object(Path,'home',return_value=Path(self.temp.name)/'home'), patch.object(bridge.time,'time',return_value=(folder/'s.jsonl').stat().st_mtime):
            result=bridge.report(self.root,days=10000)
        self.assertEqual([(r['input'],r['output']) for r in result['projects']],[(3,21)])

    def test_codex_sessions_count_each_turn_once(self):
        # Codex logs a running total per token_count event, sometimes repeated; only the growth counts.
        folder=Path(self.temp.name)/'home/.codex/sessions/2026/10/01'; folder.mkdir(parents=True)
        tc=lambda ts,inp,cached,out:json.dumps({'timestamp':ts,'type':'event_msg','payload':{'type':'token_count','info':{'total_token_usage':{'input_tokens':inp,'cached_input_tokens':cached,'output_tokens':out}}}})
        lines=[json.dumps({'timestamp':'2026-10-01T15:00:00Z','type':'turn_context','payload':{'model':'gpt-6.1-sol','cwd':'/work/app'}}),
               tc('2026-10-01T15:00:05Z',100,40,10),tc('2026-10-01T15:00:05Z',100,40,10),tc('2026-10-01T15:01:00Z',250,140,30)]
        (folder/'rollout.jsonl').write_text('\n'.join(lines)+'\n')
        with patch.object(Path,'home',return_value=Path(self.temp.name)/'home'), patch.object(bridge.time,'time',return_value=(folder/'rollout.jsonl').stat().st_mtime):
            result=bridge.report(self.root,days=10000)
        self.assertEqual([(r['model'],r['input'],r['cacheRead'],r['output']) for r in result['models']],[('gpt-6.1-sol',110,140,30)])
        # After compaction the running total restarts lower; each turn's own usage still counts.
        tl=lambda ts,total,last:json.dumps({'timestamp':ts,'type':'event_msg','payload':{'type':'token_count','info':{'total_token_usage':total,'last_token_usage':last}}})
        with open(folder/'rollout.jsonl','a') as stream:
            stream.write(tl('2026-10-01T15:02:00Z',{'input_tokens':50,'output_tokens':5},{'input_tokens':50,'output_tokens':5})+'\n')
        with patch.object(Path,'home',return_value=Path(self.temp.name)/'home'), patch.object(bridge.time,'time',return_value=(folder/'rollout.jsonl').stat().st_mtime):
            result=bridge.report(self.root,days=10000)
        self.assertEqual([(r['input'],r['output']) for r in result['models']],[(160,35)])

    def test_codex_usage_includes_profile_sessions_once(self):
        sys.path.insert(0,str(Path(bridge.__file__).parent))
        home=Path(self.temp.name)/'home'
        tc=lambda out:json.dumps({'timestamp':'2026-10-01T15:00:05Z','type':'event_msg','payload':{'type':'token_count','info':{'total_token_usage':{'input_tokens':10,'output_tokens':out}}}})
        own=home/'.codex/sessions/2026/10/01'; own.mkdir(parents=True)
        (own/'rollout-a.jsonl').write_text(tc(3)+'\n')
        shared=self.root/'codex-conversations/sessions/2026/10/01'; shared.mkdir(parents=True)
        (shared/'rollout-b.jsonl').write_text(tc(4)+'\n')
        run=lambda root:bridge.report(root,days=10000)
        with patch.object(Path,'home',return_value=home), patch.object(bridge.time,'time',return_value=(shared/'rollout-b.jsonl').stat().st_mtime):
            self.assertEqual(sum(r['output'] for r in run(self.root)['days']),7)
            # A profile folder whose sessions link to ~/.codex/sessions holds the same rollouts.
            linked=Path(self.temp.name)/'linked'; (linked/'codex-conversations').mkdir(parents=True)
            (linked/'codex-conversations/sessions').symlink_to(home/'.codex/sessions')
            self.assertEqual(sum(r['output'] for r in run(linked)['days']),3)

    def test_two_macs_share_totals_through_sync_folder_without_logins(self):
        sync=Path(self.temp.name)/'icloud'
        line=lambda mid,out:json.dumps({'timestamp':'2026-10-01T15:00:00Z','cwd':'/w','requestId':mid,'message':{'id':mid,'model':'claude-fable-5-1','usage':{'output_tokens':out}}})
        macs=[]
        for name,out,email in (('a',5,'a@example.com'),('b',7,'b@example.com')):
            home=Path(self.temp.name)/name; folder=home/'.claude/projects/p'; folder.mkdir(parents=True)
            (folder/'s.jsonl').write_text(line(name,out)+'\n')
            root=home/'support'; root.mkdir()
            (root/'config.json').write_text(json.dumps({'accounts':[dict(account('Shared'),email='shared@example.com'),dict(account(name),email=email)]}))
            macs.append((home,root,folder/'s.jsonl'))
        def run(home,root,path):
            with patch.object(Path,'home',return_value=home), patch.object(bridge.time,'time',return_value=path.stat().st_mtime), \
                 patch.object(bridge,'machine_identity',return_value=(home.name,home.name)):
                return bridge.report(root,days=10000,sync=sync)
        run(*macs[0])
        # A broken or hostile file from the shared folder is skipped or bounded, never fatal.
        (sync/'machines/bad.json').write_text('{broken')
        (sync/'machines/odd.json').write_text(json.dumps({'updated':macs[0][2].stat().st_mtime,'totals':[1],'hours':{}}))
        (sync/'machines/huge.json').write_text(json.dumps({'updated':macs[0][2].stat().st_mtime,'totals':{},'hours':{'2026-10-01':[10**30]*24}}))
        result=run(*macs[1])
        self.assertEqual([r['output'] for r in result['days']],[12])
        self.assertEqual(result['activity'][0]['hours'][0],10**6)
        self.assertEqual(sorted(m['current'] for m in result['machines']),[False,False,True])
        # Only the account this Mac lacks is offered; the shared one is already here.
        self.assertEqual([(a['email'],a['provider']) for a in result['elsewhere']],[('a@example.com','claude')])
        for path in (sync/'machines').glob('[ab].json'):
            self.assertEqual(set(bridge.read_json(path)),{'name','updated','totals','hours','accounts'})
            self.assertNotIn('claudeAiOauth',path.read_text())

    def test_recent_model_is_the_newest_sessions_last_response(self):
        folder=Path(self.temp.name)/'home/.claude/projects/p'; folder.mkdir(parents=True)
        now=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())
        msg=lambda model,ts=now:json.dumps({'type':'assistant','timestamp':ts,'message':{'model':model}})
        # A large tool result after the last response still leaves the response findable.
        (folder/'s.jsonl').write_text('\n'.join([msg('claude-opus-5-5'),msg('claude-fable-5-1'),msg('<synthetic>'),json.dumps({'type':'user','x':'y'*600000})])+'\n')
        with patch.object(Path,'home',return_value=Path(self.temp.name)/'home'):
            self.assertEqual(bridge.recent_model(),'claude-fable-5-1')
            # A recently touched file whose last response is old does not count.
            (folder/'s.jsonl').write_text(msg('claude-fable-5-1','2026-01-01T00:00:00Z')+'\n')
            self.assertIsNone(bridge.recent_model())
            os.utime(folder/'s.jsonl',(time.time()-7200,time.time()-7200))
            self.assertIsNone(bridge.recent_model())

    def test_an_idle_unverified_login_can_be_woken_but_only_as_its_own_account(self):
        # An expired login can't be looked up, so requiring a lookup before waking it deadlocked:
        # it never refreshed and the account read "Reading..." forever.
        a=account('Alpha'); blob={'claudeAiOauth':{'accessToken':'t','expiresAt':1}}
        ran=[]
        with patch.object(bridge,'read_secret',return_value=blob), patch.object(bridge,'mac_email',return_value=''), \
             patch.object(bridge,'claude_binary',return_value='claude'), \
             patch.object(bridge.subprocess,'run',side_effect=lambda *x,**k: ran.append(x[0]) or subprocess.CompletedProcess(x[0],0)):
            with patch.object(bridge,'auth_status',return_value={'email':'ALPHA@example.com'}):
                bridge.prime(self.root,{'accounts':[a]},a)
            self.assertEqual(len(ran),1)
            with patch.object(bridge,'auth_status',return_value={'email':'other@example.com'}):
                with self.assertRaisesRegex(ValueError,'Sign in to Alpha'): bridge.prime(self.root,{'accounts':[a]},a)
            self.assertEqual(len(ran),1)

    def test_one_terminal_can_stay_on_an_account_while_the_rest_follow_side_a(self):
        root=self.root/'Side A'; (root/'runtime').mkdir(parents=True)
        (root/'runtime/claude-selector').write_text('/profiles/default\n')
        a=account('Long Jobs'); b=account('Studio')
        with patch.object(bridge,'read_secret',return_value=None), patch.object(bridge,'mac_email',return_value=''):
            bridge.write_pins(root,{'accounts':[a,b]})
        self.assertEqual(sorted(p.name for p in bridge.pins_path(root).iterdir()),['long-jobs','studio'])
        script=bridge.shell_snippet(root).split('\n',1)[1]+'''
show() { _side_a_select; echo "${CLAUDE_SECURESTORAGE_CONFIG_DIR:-unset}"; }
sidea use Long-Jobs >/dev/null; show
sidea auto >/dev/null; show
sidea use nobody >/dev/null; show
export SIDE_A_PIN=studio; rm '%s'/studio; show
''' % bridge.pins_path(root)
        out=subprocess.run(['zsh','-fc',script],capture_output=True,text=True,check=True).stdout.splitlines()
        pinned=str(bridge.profile_dir(root,a['id']))
        # Pinned, back to Side A's choice, an unknown name changes nothing, a removed account falls back.
        self.assertEqual(out,[pinned,'/profiles/default','/profiles/default','/profiles/default'])

    def test_paid_usage_reads_in_dollars_from_the_live_shape(self):
        # Shapes as the usage endpoint returned them: spend in minor units, extra_usage in cents.
        capped={'extra_usage':{'is_enabled':False,'monthly_limit':1000,'used_credits':0.0,'currency':'USD'},
                'spend':{'used':{'amount_minor':0,'currency':'USD','exponent':2},'limit':{'amount_minor':1000,'currency':'USD','exponent':2},'enabled':False}}
        self.assertEqual(bridge.extra_usage(capped),{'enabled':False,'used':0.0,'limit':10.0,'currency':'USD'})
        billing={'spend':{'used':{'amount_minor':320,'currency':'USD','exponent':2},'limit':None,'enabled':True}}
        self.assertEqual(bridge.extra_usage(billing),{'enabled':True,'used':3.2,'limit':None,'currency':'USD'})
        self.assertEqual(bridge.extra_usage({'extra_usage':{'is_enabled':True,'used_credits':250,'monthly_limit':None}})['used'],2.5)

    def test_side_a_waits_for_claude_codes_refresh_lock_and_releases_it(self):
        # A wake refreshing at the same moment as an open session can get a login revoked.
        lock=self.root/'claude-home/.oauth_refresh.lock'; lock.mkdir(parents=True)
        with self.assertRaisesRegex(ValueError,'refreshing a login'):
            with bridge.claude_refresh_lock(self.root/'claude-home',timeout=0.1): pass
        self.assertTrue(lock.exists())  # someone else's live lock is left alone
        old=time.time()-120; os.utime(lock,(old,old))
        with bridge.claude_refresh_lock(self.root/'claude-home',timeout=0.1):
            self.assertTrue(lock.exists())  # a stale lock is taken over, and held while claude runs
        self.assertFalse(lock.exists())

    @patch.object(bridge.time,'sleep')  # a retried swap waits between tries; the test needn't
    def test_swapping_moves_logins_between_items_and_a_crash_finishes_forward(self, _):
        a=account('Alpha'); b=account('Beta'); config={'accounts':[a,b]}
        login=lambda who,n=1,exp=3600: {'claudeAiOauth':{'accessToken':f'{who}-at{n}','refreshToken':f'{who}-rt{n}','expiresAt':(time.time()+exp)*1000},'organizationUuid':who+'-org'}
        mac=bridge.GLOBAL_SERVICE; beta=bridge.profile_service(self.root,b['id'])
        keychain={mac:{**login('alpha'),'mcpOAuth':{'srv':'mac-mcp'}}, beta:login('beta')}
        owner=lambda root,blob: ((blob or {}).get('claudeAiOauth') or {}).get('accessToken','').split('-')[0]+'@example.com' if blob else ''
        reader=MagicMock(side_effect=lambda svc: keychain.get(svc)); reader.cache_clear=lambda: None
        writes=[]; fail=[False]
        def write(svc,blob):
            writes.append(svc)
            if fail[0] and svc==beta and (fail[0] is True or blob!=keychain.get(svc)): raise ValueError('keychain refused')
            keychain[svc]=blob
        real_run=subprocess.run
        def run(args,*rest,**kw):
            if args[:2]==['security','delete-generic-password']: keychain.pop(args[-1],None); return subprocess.CompletedProcess(args,0)
            return real_run(args,*rest,**kw)
        home=self.root/'home'; (home/'.claude').mkdir(parents=True)
        tokens=lambda: sorted(x['claudeAiOauth']['refreshToken'] for k,x in keychain.items() if k!=bridge.SWAP_JOURNAL and not k.startswith(bridge.TRADE_WATCH))
        with patch.object(bridge,'read_secret',reader), patch.object(bridge,'write_secret',side_effect=write), \
             patch.object(bridge,'token_email',side_effect=owner), patch.object(bridge,'mac_email',side_effect=lambda root: owner(root,keychain[mac])), \
             patch.object(bridge.subprocess,'run',side_effect=run), patch.object(Path,'home',return_value=home), \
             patch.object(bridge,'slot_processes',return_value={}):
            # The keychain fails after the Mac item took Beta's login: the journal still holds Alpha.
            fail[0]=True
            with self.assertRaises(ValueError): bridge.swap(self.root,config,'mac',b)
            self.assertIn(bridge.SWAP_JOURNAL,keychain)
            # Meanwhile a session renews Beta in its old item; finishing uses that newest copy, never the spent one.
            keychain[beta]={'claudeAiOauth':{'accessToken':'nobody','refreshToken':'beta-rt2','expiresAt':(time.time()+7200)*1000}}
            fail[0]=False
            with bridge.selection_lock(self.root), bridge.selection_lock(self.root,'renew.lock'): bridge.finish_swap(self.root)
            self.assertNotIn(bridge.SWAP_JOURNAL,keychain)
            self.assertEqual(keychain[mac]['claudeAiOauth']['refreshToken'],'beta-rt2')
            self.assertEqual(keychain[mac]['mcpOAuth'],{'srv':'mac-mcp'})
            self.assertEqual(keychain[beta]['claudeAiOauth']['refreshToken'],'alpha-rt1'); self.assertNotIn('mcpOAuth',keychain[beta])
            self.assertEqual(tokens(),['alpha-rt1','beta-rt2'])
            keychain[mac]['claudeAiOauth']['accessToken']='beta-at2'  # its owner is looked up later
            self.assertEqual((bridge.home_service(self.root,a),bridge.home_service(self.root,b)),(beta,mac))
            self.assertEqual(bridge.selector_for(self.root,b),'')
            self.assertEqual(bridge.owned_login(self.root,a)['claudeAiOauth']['accessToken'],'alpha-at1')
            self.assertFalse((home/'.claude/.oauth_refresh.lock').exists())
            # A statusline that was mid-write during the trade keeps its old time and is not credited to Beta.
            bridge.live_dir(self.root).mkdir(parents=True,exist_ok=True)
            stale=bridge.live_dir(self.root)/'mac.json'; stale.write_text(json.dumps({'rate_limits':{'five_hour':{'used_percentage':99,'resets_at':2000000000}}}))
            os.utime(stale,(time.time()-5,time.time()-5))
            self.assertEqual(bridge.live_limits(self.root,config),{})
            # Trading back restores the first layout with no map left behind.
            bridge.swap(self.root,config,'mac',a)
            self.assertEqual((keychain[mac]['claudeAiOauth']['refreshToken'],keychain[beta]['claudeAiOauth']['refreshToken']),('alpha-rt1','beta-rt2'))
            self.assertEqual(bridge.read_json(bridge.homes_path(self.root)),{})
            # Beta's own sessions block a trade, unless the app asks to share: they continue on Alpha's login.
            with patch.object(bridge,'slot_processes',return_value={77:b['id']}):
                with self.assertRaisesRegex(ValueError,'using that account'): bridge.swap(self.root,config,'mac',b)
                # Checked again right before the writes: a Fable session (or an unknown one) started meanwhile stops the share.
                for model in ('claude-fable-5-1',None):
                    with patch.object(bridge,'slot_models',return_value={b['id']:[model]}):
                        with self.assertRaisesRegex(ValueError,'Fable'): bridge.swap(self.root,config,'mac',b,share=True)
                with patch.object(bridge,'slot_models',return_value={b['id']:['claude-opus-5-5']}), patch.object(bridge.time,'sleep'):
                    # Between two running logins, a trade that can't finish is undone: each keeps its own login.
                    before=dict(keychain); fail[0]='change'
                    with self.assertRaisesRegex(ValueError,'keychain refused'): bridge.swap(self.root,config,'mac',b,share=True)
                    logins=lambda items: {k:v['claudeAiOauth']['refreshToken'] for k,v in items.items() if not k.startswith(bridge.TRADE_WATCH)}
                    self.assertEqual(logins(keychain),logins(before))
                    self.assertNotIn(bridge.SWAP_JOURNAL,keychain)
                    # A Keychain that refuses every write stops the trade before anything moves.
                    fail[0]=True; writes.clear()
                    with self.assertRaisesRegex(ValueError,'keychain refused'): bridge.swap(self.root,config,'mac',b,share=True)
                    self.assertNotIn(bridge.SWAP_JOURNAL,writes)
                    # If even the undo can't write, the refresh locks stay so neither session refreshes the shared login.
                    calls=[0]
                    def flaky(svc,blob):
                        calls[0]+=1
                        moving=calls[0]>3 and (svc==beta or blob['claudeAiOauth']['refreshToken'].startswith('alpha'))
                        if moving: raise ValueError('keychain refused')
                        keychain[svc]=blob
                    with patch.object(bridge,'write_secret',side_effect=flaky):
                        with self.assertRaises(bridge.TradeStuck): bridge.swap(self.root,config,'mac',b,share=True)
                    self.assertTrue((home/'.claude/.oauth_refresh.lock').is_dir())
                    (home/'.claude/.oauth_refresh.lock').rmdir()
                    for lock in self.root.glob('**/.oauth_refresh.lock'): lock.rmdir()
                    for lock in [home/'.claude.lock',*self.root.glob('profiles/*.lock')]: lock.rmdir()
                    fail[0]=False
                    bridge.finish_swap(self.root)
                    self.assertNotIn(bridge.SWAP_JOURNAL,keychain)
            self.assertEqual((keychain[mac]['claudeAiOauth']['refreshToken'],keychain[beta]['claudeAiOauth']['refreshToken']),('beta-rt2','alpha-rt1'))
            bridge.swap(self.root,config,'mac',a)
            # The Mac item signed in to someone else: Beta's own profile holds Alpha, so Beta takes Alpha's empty slot.
            bridge.swap(self.root,config,'mac',b); keychain[mac]=login('carol')
            self.assertEqual((bridge.home_slot(self.root,a),bridge.home_slot(self.root,b)),(b['id'],a['id']))
    def test_a_trade_a_session_undid_is_put_right(self):
        a=account('Alpha'); b=account('Beta'); config={'accounts':[a,b]}
        login=lambda who,n=1,exp=3600: {'claudeAiOauth':{'accessToken':f'{who}-at{n}','refreshToken':f'{who}-rt{n}','expiresAt':(time.time()+exp)*1000}}
        slot_a,slot_b=bridge.profile_service(self.root,a['id']),bridge.profile_service(self.root,b['id'])
        keychain={slot_a:login('alpha'),slot_b:login('beta')}
        owner=lambda root,blob: ((blob or {}).get('claudeAiOauth') or {}).get('accessToken','').split('-')[0]+'@example.com' if blob else ''
        reader=MagicMock(side_effect=lambda svc: json.loads(json.dumps(keychain.get(svc)))); reader.cache_clear=lambda: None
        def run(args,*rest,**kw):
            if args[:2]==['security','delete-generic-password']: keychain.pop(args[-1],None)
            return subprocess.CompletedProcess(args,0)
        def write(svc,blob): keychain[svc]=blob
        busy={77:a['id']}
        watched=lambda: [k for k in keychain if k.startswith(bridge.TRADE_WATCH)]
        refresh=lambda svc: keychain[svc]['claudeAiOauth']['refreshToken']
        home=self.root/'home'; (home/'.claude').mkdir(parents=True)
        with patch.object(bridge,'read_secret',reader), patch.object(bridge,'write_secret',side_effect=write), \
             patch.object(bridge,'token_email',side_effect=owner), patch.object(bridge,'mac_email',return_value='nobody@example.com'), \
             patch.object(bridge.subprocess,'run',side_effect=run), patch.object(Path,'home',return_value=home), \
             patch.object(bridge,'slot_processes',side_effect=lambda root,config: dict(busy)):
            # Alpha's sessions move to Beta's login; Alpha goes to Beta's idle slot.
            bridge.swap(self.root,config,a['id'],b)
            self.assertEqual((bridge.home_slot(self.root,a),bridge.home_slot(self.root,b)),(b['id'],a['id']))
            self.assertEqual(len(watched()),1)
            # Sessions renew Beta in its new slot: the kept copy follows, so a put-back Beta is never a spent one.
            keychain[slot_a]=login('beta',2,5000)
            self.assertEqual(bridge.heal_trades(self.root,config),[])
            self.assertEqual(keychain[watched()[0]]['logins'][1]['claudeAiOauth']['refreshToken'],'beta-rt2')
            # A stale Alpha saved without renewing is older than the one the trade left: nothing moves.
            keychain[slot_a]=login('alpha',0,600)
            self.assertEqual(bridge.heal_trades(self.root,config),[])
            # A session that kept Alpha in memory renews it and saves it over Beta's login.
            keychain[slot_a]=login('alpha',2,7200)
            # A session started on Beta's old slot since then runs on Alpha there; nothing moves under it.
            busy[78]=b['id']
            self.assertEqual(bridge.heal_trades(self.root,config),[])
            del busy[78]
            healed=bridge.heal_trades(self.root,config)
            self.assertEqual(len(healed),1); self.assertIn("Beta's login put back",healed[0])
            self.assertEqual((refresh(slot_a),refresh(slot_b)),('alpha-rt2','beta-rt2'))
            self.assertEqual((bridge.home_slot(self.root,a),bridge.home_slot(self.root,b)),(a['id'],b['id']))
            self.assertEqual(watched(),[])
            # The copy the trade left was renewed since, so it may be the live one: it is never replaced.
            bridge.swap(self.root,config,a['id'],b)
            keychain[slot_b]=login('alpha',3,6000)
            self.assertEqual(bridge.heal_trades(self.root,config),[])
            keychain[slot_b]=login('alpha',4,6000); keychain[slot_a]=login('alpha',5,7200)
            self.assertEqual(bridge.heal_trades(self.root,config),[])
            self.assertEqual(refresh(slot_b),'alpha-rt4')
            # A trade left alone is no longer watched after an hour.
            index=bridge.read_json(bridge.watch_path(self.root)); index['trades'][0]['at']-=bridge.WATCH_SECONDS
            bridge.atomic_json(bridge.watch_path(self.root),index)
            self.assertEqual(bridge.heal_trades(self.root,config),[])
            self.assertEqual(watched(),[]); self.assertEqual(bridge.read_json(bridge.watch_path(self.root)),{'trades':[]})
    def test_a_redrawn_idle_statusline_is_as_old_as_its_last_reply(self):
        other=account('Other'); config={'accounts':[other]}
        transcript=self.root/'t.jsonl'; transcript.write_text('{}\n')
        os.utime(transcript,(time.time()-7200,time.time()-7200))
        folder=bridge.live_dir(self.root); folder.mkdir(parents=True)
        (folder/f"{other['id']}.json").write_text(json.dumps({'transcript_path':str(transcript),
            'rate_limits':{'five_hour':{'used_percentage':33,'resets_at':2000000000}}}))
        with patch.object(bridge,'mac_email',return_value=None):
            live=bridge.live_limits(self.root,config)
        self.assertAlmostEqual(live[other['id']]['at'],time.time()-7200,delta=5)
    def test_signing_in_over_a_stray_copy_of_another_accounts_login(self):
        a=account('Alpha'); d=account('Dallas'); config={'accounts':[a,d]}
        login=lambda who,n,exp: {'claudeAiOauth':{'accessToken':f'{who}-at{n}','refreshToken':f'{who}-rt{n}','expiresAt':(time.time()+exp)*1000}}
        slot_a,slot_d=bridge.profile_service(self.root,a['id']),bridge.profile_service(self.root,d['id'])
        owner=lambda root,blob: ((blob or {}).get('claudeAiOauth') or {}).get('accessToken','').split('-')[0]+'@example.com' if blob else ''
        keychain={slot_a:login('dallas',1,-3600),slot_d:login('dallas',2,7200)}
        reader=MagicMock(side_effect=lambda svc: keychain.get(svc)); reader.cache_clear=lambda: None
        with patch.object(bridge,'read_secret',reader), patch.object(bridge,'token_email',side_effect=owner), \
             patch.object(bridge,'mac_email',return_value='nobody@example.com'):
            # Dallas's own home holds a newer copy, so the stray one in Alpha's slot is signed in over.
            self.assertEqual(bridge.sign_in_slot(self.root,config,a),a['id'])
            # The stray copy is the newer one: it may be Dallas's only good login, so it stays.
            keychain[slot_a]=login('dallas',3,9000)
            with self.assertRaisesRegex(ValueError,"holds Dallas's login"): bridge.sign_in_slot(self.root,config,a)
            # Another account's login in its own home always blocks.
            keychain[slot_a]=login('alpha',1,8000); keychain[slot_d]=login('alpha',2,7200)
            self.assertEqual(bridge.sign_in_slot(self.root,config,d),d['id'])
            bridge.atomic_json(bridge.homes_path(self.root),{a['id']:d['id']})
            keychain[slot_d]=login('alpha',4,7200)
            with self.assertRaisesRegex(ValueError,"holds Alpha's login"): bridge.sign_in_slot(self.root,config,d)
    def test_busy_slots_follow_claude_codes_storage_rule(self):
        a=account('Alpha'); b=account('Beta'); config={'accounts':[a,b]}
        prof=lambda acct: str(bridge.profile_dir(self.root,acct['id']))
        listing='11 /usr/local/bin/claude\n12 /Users/x/.local/share/claude/versions/2.1.294\n13 /usr/bin/node\n14 claude\n'
        envs={11:('claude',{'CLAUDE_SECURESTORAGE_CONFIG_DIR':prof(b)}),
              # A prompt mentioning the variable is argv, not environment: only the real value counts.
              12:('claude',{'CLAUDE_SECURESTORAGE_CONFIG_DIR':''}),
              13:('node',{'CLAUDE_SECURESTORAGE_CONFIG_DIR':prof(a)}), 14:None}
        with patch.object(bridge.subprocess,'run',return_value=subprocess.CompletedProcess([],0,listing,'')), \
             patch.object(bridge,'process_environment',side_effect=lambda pid: envs[pid]):
            self.assertEqual(bridge.busy_slots(self.root,config),{b['id'],'mac'})
            self.assertEqual(bridge.slot_processes(self.root,config),{11:b['id'],12:'mac'})
        with patch.object(bridge.subprocess,'run',side_effect=OSError):
            self.assertIsNone(bridge.busy_slots(self.root,config))
        # The real kernel read: a child's environment comes back exactly, even with argv that mimics it.
        child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(5)','CLAUDE_SECURESTORAGE_CONFIG_DIR=/fake'],env={'CLAUDE_SECURESTORAGE_CONFIG_DIR':'/real dir'})
        try:
            time.sleep(0.2)
            self.assertEqual(bridge.process_environment(child.pid)[1].get('CLAUDE_SECURESTORAGE_CONFIG_DIR'),'/real dir')
        finally:
            child.kill(); child.wait()
    def test_a_sessions_own_limit_error_names_the_full_account(self):
        a=account('Alpha'); b=account('Beta'); config={'accounts':[a,b]}
        home=self.root/'home'; sessions=home/'.claude/sessions'; sessions.mkdir(parents=True)
        project=home/'.claude/projects/-Users-x-app'; project.mkdir(parents=True)
        def session(pid,lines):
            sid=str(uuid.uuid4())
            (sessions/f'{pid}.json').write_text(json.dumps({'pid':pid,'sessionId':sid,'status':'idle'}))
            (project/f'{sid}.jsonl').write_text(''.join(json.dumps(line)+'\n' for line in lines))
            return sid
        error=lambda text,at: {'type':'assistant','isApiErrorMessage':True,'error':'rate_limit','timestamp':at,
                               'message':{'model':'<synthetic>','content':[{'type':'text','text':text}]}}
        reply={'type':'assistant','timestamp':'2026-10-09T10:00:00Z','message':{'model':'claude-opus-5-5','content':[]}}
        # Real wording: a spent monthly cap names the plan limit after it.
        stopped=session(11,[reply,error("You've hit your monthly spend limit · raise it at claude.ai/settings/usage · your weekly limit resets Oct 10 at 5pm",'2026-10-09T10:05:00Z'),
                    {'type':'user','message':{'content':'continue'}}])
        session(12,[error("You've hit your session limit · resets 1pm",'2026-10-09T09:00:00Z'),reply])  # answered since
        session(13,[error("You've reached your Fable limit",'2026-10-09T10:10:00Z')])
        owners={'mac':a,b['id']:b}
        with patch.object(Path,'home',return_value=home), patch.object(bridge,'slot_owner',side_effect=lambda r,c,slot: owners.get(slot)):
            at=bridge.epoch('2026-10-09T10:05:00Z')
            self.assertEqual(bridge.limit_errors(self.root,config,{11:'mac',12:b['id']}),{a['id']:{'limit':'seven_day','at':at,'sessions':[stopped]}})
            self.assertEqual(bridge.limit_errors(self.root,config,{11:'mac',13:'mac'})[a['id']]['limit'],'model:fable')
            # A trade after the error moved that login away: the slot's new owner is not blamed.
            bridge.atomic_json(bridge.swapped_path(self.root),{'mac':at+1})
            self.assertEqual(bridge.limit_errors(self.root,config,{11:'mac'}),{})
            self.assertEqual(bridge.limit_errors(self.root,config,None),{})
    def test_recovery_keeps_a_login_renewed_before_any_write(self):
        a=account('Alpha'); b=account('Beta')
        mac=bridge.GLOBAL_SERVICE; beta=bridge.profile_service(self.root,b['id'])
        login=lambda who,n,exp: {'claudeAiOauth':{'accessToken':f'{who}-at{n}','refreshToken':f'{who}-rt{n}','expiresAt':(time.time()+exp)*1000}}
        journal={'slots':['mac',b['id']],'moves':{b['id']:'mac',a['id']:b['id']},'logins':[login('alpha',1,60),login('beta',1,60)]}
        # Alpha renewed in the Mac item after the journal was saved; its new token's owner is unknown.
        keychain={bridge.SWAP_JOURNAL:journal, mac:{'claudeAiOauth':{'accessToken':'nobody','refreshToken':'alpha-rt2','expiresAt':(time.time()+9000)*1000}}, beta:login('beta',1,60)}
        owner=lambda root,blob: ((blob or {}).get('claudeAiOauth') or {}).get('accessToken','').split('-')[0]+'@example.com' if blob else ''
        reader=MagicMock(side_effect=lambda svc: keychain.get(svc)); reader.cache_clear=lambda: None
        def run(args,*rest,**kw):
            keychain.pop(args[-1],None); return subprocess.CompletedProcess(args,0)
        home=self.root/'home'; (home/'.claude').mkdir(parents=True)
        with patch.object(bridge,'read_secret',reader), patch.object(bridge,'write_secret',side_effect=lambda svc,blob: keychain.__setitem__(svc,blob)), \
             patch.object(bridge,'token_email',side_effect=owner), patch.object(bridge.subprocess,'run',side_effect=run), patch.object(Path,'home',return_value=home):
            with bridge.selection_lock(self.root), bridge.selection_lock(self.root,'renew.lock'): bridge.finish_swap(self.root)
        self.assertEqual((keychain[mac]['claudeAiOauth']['refreshToken'],keychain[beta]['claudeAiOauth']['refreshToken']),('beta-rt1','alpha-rt2'))
    def test_pool_mode_sends_unpinned_terminals_through_the_running_app(self):
        line=bridge.shell_snippet(self.root).splitlines()[1]
        runtime=self.root/'runtime'; runtime.mkdir(parents=True,exist_ok=True)
        (runtime/'claude-selector').write_text('/profile\n')
        pins=bridge.pins_path(self.root); pins.mkdir(); (pins/'work').write_text('/work\n')
        show='print -r -- "${ANTHROPIC_BASE_URL:-none} ${ANTHROPIC_AUTH_TOKEN:-none} ${SIDE_A_POOL:-none} ${CLAUDE_SECURESTORAGE_CONFIG_DIR:-none}"'
        run=lambda script: subprocess.run(['zsh','-fc',f"{line}; {script}"],capture_output=True,text=True).stdout.split('\n')
        bridge.pool_path(self.root).write_text(f"http://127.0.0.1:47317 k3y {os.getpid()}\n")
        claude='"claude -c" "claude -c" "claude --dangerously-skip-permissions -c"'
        self.assertEqual(run(f"_side_a_select {claude}; {show}")[0],'http://127.0.0.1:47317 k3y 1 none')
        self.assertEqual(run(f"_side_a_select 'c' 'c' '/opt/bin/claude --resume'; {show}")[0],'http://127.0.0.1:47317 k3y 1 none')
        self.assertEqual(run(f"_side_a_select {claude}; SIDE_A_PIN=work; _side_a_select {claude}; {show}")[0],'none none none /work')
        # Every other command, an SDK script above all, runs without the key.
        self.assertEqual(run(f"_side_a_select {claude}; _side_a_select 'python3 x.py' 'python3 x.py' 'python3 x.py'; {show}")[0],'none none none /profile')
        self.assertEqual(run(f"_side_a_select 'claudette' 'claudette' 'claudette'; {show}")[0],'none none none /profile')
        # A base URL or token of the user's own stays, and claude uses it instead of the pool.
        self.assertEqual(run(f"export ANTHROPIC_BASE_URL=https://gw; _side_a_select {claude}; {show}")[0],'https://gw none none /profile')
        # Even after Side A's own values were in place (sourcing sets them), the user's export wins.
        self.assertEqual(run(f"_side_a_select; export ANTHROPIC_BASE_URL=https://gw; _side_a_select {claude}; {show}")[0],'https://gw none none /profile')
        self.assertEqual(run(f"_side_a_select; export ANTHROPIC_BASE_URL=https://gw; _side_a_select ls ls ls; {show}")[0],'https://gw none none /profile')
        self.assertEqual(run(f"set -u; _side_a_select; {show}")[0],'http://127.0.0.1:47317 k3y 1 none')
        # The app quit without removing its file: commands go back to the selected login.
        dead=subprocess.Popen(['true']); dead.wait()
        bridge.pool_path(self.root).write_text(f"http://127.0.0.1:47317 k3y {dead.pid}\n")
        self.assertEqual(run(f"export ANTHROPIC_BASE_URL=x ANTHROPIC_AUTH_TOKEN=y SIDE_A_POOL=1; _side_a_url=x _side_a_key=y; _side_a_select {claude}; {show}")[0],'none none none /profile')
        self.assertEqual(run(f"export ANTHROPIC_BASE_URL=mine; _side_a_select {claude}; {show}")[0],'mine none none /profile')
    def test_codex_uses_the_pool_home_only_for_codex_and_only_while_it_exists(self):
        line=bridge.shell_snippet(self.root).splitlines()[1]
        runtime=self.root/'runtime'; runtime.mkdir(parents=True,exist_ok=True)
        (runtime/'claude-selector').write_text('/profile\n')
        bridge.pool_path(self.root).write_text(f"http://127.0.0.1:47317 k3y {os.getpid()}\n")
        show='print -r -- "${CODEX_HOME:-none} ${SIDE_A_POOL_KEY:-none} ${ANTHROPIC_AUTH_TOKEN:-none}"'
        run=lambda script: subprocess.run(['zsh','-fc',f"{line}; {script}"],capture_output=True,text=True).stdout.split('\n')[0]
        home=runtime/'codex-pool'
        self.assertEqual(run(f"_side_a_select codex codex codex; {show}"),'none none none')
        home.mkdir(); (home/'config.toml').write_text('')
        self.assertEqual(run(f"_side_a_select 'codex exec x' c c; {show}"),f'{home} k3y none')
        self.assertEqual(run(f"_side_a_select codex codex codex; _side_a_select ls ls ls; {show}"),'none none none')
        # A login made here must land in ~/.codex, even through an alias and right after a pooled run.
        self.assertEqual(run(f"_side_a_select 'codex login' 'codex --yolo login' 'codex --yolo login'; {show}"),'none none none')
        self.assertEqual(run(f"_side_a_select codex codex codex; _side_a_select 'codex login' 'codex login' 'codex login'; {show}"),'none none none')
        self.assertEqual(run(f"export CODEX_HOME=/mine; _side_a_select codex codex codex; {show}"),'/mine none none')
        self.assertEqual(run(f"_side_a_select claude claude claude; {show}"),'none none k3y')

    def test_codex_pool_config_handles_arrays_profiles_and_old_python(self):
        import codex_bridge
        source='notify = [\n  ["a"],\n]\n"model_provider" = "x"\nprofile = "p"\n\n[profiles.p]\nmodel_provider = "x"\nmodel = "m"\n'
        text=codex_bridge.pool_config(source,'http://x','/h')
        self.assertEqual(text.count('model_provider ='),1)
        self.assertIn('notify = [',text); self.assertIn('model = "m"',text)
        with patch.dict(sys.modules,{'tomllib':None}):
            self.assertIn('[model_providers.sidea]',codex_bridge.pool_config('model = "m"\n','http://x','/h'))

    @unittest.skipIf(sys.version_info < (3,11),'needs tomllib')
    def test_codex_pool_home_follows_the_users_config_and_holds_no_login(self):
        import codex_bridge, tomllib
        source=self.root/'dot-codex'; (source/'sessions').mkdir(parents=True)
        (source/'auth.json').write_text('{"secret":1}'); (source/'state_5.sqlite').write_text(''); (source/'ipc').mkdir()
        (source/'config.toml').write_text('model = "m"\nmodel_provider = "openai"\n\n[features]\nx = true\n')
        home=codex_bridge.sync_pool_home(self.root,'http://127.0.0.1:9',source=source)
        config=tomllib.loads(Path(home,'config.toml').read_text())
        self.assertEqual(config['model'],'m'); self.assertEqual(config['model_provider'],'sidea'); self.assertTrue(config['features']['x'])
        self.assertEqual(config['sqlite_home'],str(source))
        self.assertEqual(config['model_providers']['sidea']['base_url'],'http://127.0.0.1:9/codex')
        self.assertEqual(config['model_providers']['sidea']['env_key'],'SIDE_A_POOL_KEY')
        for private in ('auth.json','state_5.sqlite','ipc'): self.assertFalse(Path(home,private).exists())
        self.assertEqual(Path(home,'sessions').resolve(),(source/'sessions').resolve())
        (source/'config.toml').write_text('model = "n"\n')
        os.utime(source/'config.toml',(1,1))
        codex_bridge.refresh_pool_homes(self.root,source=source)
        self.assertEqual(tomllib.loads(Path(home,'config.toml').read_text())['model'],'n')
        # A config that can't be parsed still yields a working provider, not a broken file.
        self.assertIn('model_providers',tomllib.loads(codex_bridge.pool_config('not toml [','http://x',source)))
        codex_bridge.sync_pool_home(self.root,None,source=source)
        self.assertFalse(Path(home,'config.toml').exists())

    def test_the_macs_codex_login_is_never_renewed_by_the_pool(self):
        import codex_bridge, base64, json as j
        jwt=lambda exp: 'a.'+base64.urlsafe_b64encode(j.dumps({'exp':exp}).encode()).decode().rstrip('=')+'.c'
        account={'id':'x','name':'Mac','email':'m@x','provider':'codex'}
        with patch.object(codex_bridge,'owned'),patch.object(codex_bridge,'invocation',return_value=(['codex'],{'CODEX_HOME':str(self.root)})),\
             patch.object(codex_bridge,'read_auth',return_value={'tokens':{'access_token':jwt(1),'account_id':'w'}}),\
             patch.object(codex_bridge,'RPC') as rpc:
            with patch.object(codex_bridge,'is_mac_login',return_value=True):
                with self.assertRaisesRegex(ValueError,'open Codex once'): codex_bridge.pool_token(self.root,account)
            rpc.assert_not_called()
            with patch.object(codex_bridge,'is_mac_login',return_value=False):
                with self.assertRaisesRegex(ValueError,'Sign in'): codex_bridge.pool_token(self.root,account)
            rpc.assert_called_once()

    def test_ultra_counts_as_the_biggest_plan(self):
        self.assertEqual(bridge.plan_capacity({'subscriptionType':'ultra'}),20.0)
        self.assertEqual(bridge.plan_capacity({'rateLimitTier':'default_claude_max_20x'}),20.0)
        self.assertEqual(bridge.plan_capacity({'subscriptionType':'max'}),5.0)
        self.assertEqual(bridge.plan_capacity({'subscriptionType':'pro'}),1.0)

    def test_a_mac_that_joined_another_macs_pool_uses_it_while_it_answers(self):
        import socket
        snippet=bridge.shell_snippet(self.root)
        runtime=self.root/'runtime'; runtime.mkdir(parents=True,exist_ok=True)
        (runtime/'claude-selector').write_text('/profile\n')
        show='print -r -- "${ANTHROPIC_BASE_URL:-none} ${ANTHROPIC_AUTH_TOKEN:-none} ${CLAUDE_SECURESTORAGE_CONFIG_DIR:-none}"'
        run=lambda script: subprocess.run(['zsh','-fc',f"{snippet.splitlines()[1]}; {script}"],capture_output=True,text=True).stdout.splitlines()
        hub=socket.socket(); hub.bind(('127.0.0.1',0)); hub.listen(); port=hub.getsockname()[1]
        claude='claude claude claude'
        self.assertEqual(run(f"sidea pool join http://127.0.0.1:{port} sh4re")[0],"claude and codex here now use that Mac's pool while it's reachable.")
        self.assertEqual(stat.S_IMODE(os.stat(bridge.remote_pool_path(self.root)).st_mode),0o600)
        self.assertEqual(run(f"_side_a_select {claude}; {show}")[0],f'http://127.0.0.1:{port} sh4re none')
        self.assertEqual(run(f"_side_a_select ls ls ls; {show}")[0],'none none /profile')
        # This Mac's own pool, while it runs, comes first.
        bridge.pool_path(self.root).write_text(f"http://127.0.0.1:47317 l0cal {os.getpid()}\n")
        self.assertEqual(run(f"_side_a_select {claude}; {show}")[0],'http://127.0.0.1:47317 l0cal none')
        bridge.pool_path(self.root).unlink()
        # The other Mac asleep or gone: claude uses this Mac's login rather than hang.
        hub.close()
        self.assertEqual(run(f"_side_a_select {claude}; {show}")[0],'none none /profile')
        self.assertEqual(run("sidea pool join ftp://x k")[0][:5],'sidea')
        self.assertEqual(run("sidea pool leave")[0],"claude and codex here use this Mac's own logins again.")
        self.assertFalse(bridge.remote_pool_path(self.root).exists())
    def test_pool_sessions_hold_no_login_so_trades_ignore_them(self):
        a=account('Alpha'); config={'accounts':[a]}
        listing='11 claude\n12 claude\n'
        envs={11:('claude',{'SIDE_A_POOL':'1'}),12:('claude',{})}
        with patch.object(bridge.subprocess,'run',return_value=subprocess.CompletedProcess([],0,listing,'')), \
             patch.object(bridge,'process_environment',side_effect=lambda pid: envs[pid]):
            self.assertEqual(bridge.slot_processes(self.root,config),{12:'mac'})
    def test_pool_token_renews_first_and_refuses_another_accounts_login(self):
        a,b=account('Alpha'),account('Beta'); config={'accounts':[a,b]}
        keychain,login=self.rehome_keychain()
        bridge.prepare_profile(self.root,a['id'])
        keychain[bridge.profile_service(self.root,a['id'])]=login('alpha',1)
        with patch.object(bridge,'renew') as renewed:
            self.assertEqual(bridge.pool_token(self.root,config,a)['accessToken'],'alpha-at1')
            renewed.assert_called_once()
            keychain[bridge.profile_service(self.root,a['id'])]=login('beta',1)
            with self.assertRaisesRegex(ValueError,"now beta@example.com"): bridge.pool_token(self.root,config,a)
    def rehome_keychain(self):
        keychain={}
        def security(args,*rest,**kw):
            if args[:2]==['security','delete-generic-password']: keychain.pop(args[-1],None)
            return subprocess.CompletedProcess(args,0,'','')
        login=lambda who,n,exp=3600: {'claudeAiOauth':{'accessToken':f'{who}-at{n}','refreshToken':f'{who}-rt{n}','expiresAt':(time.time()+exp)*1000}}
        # A token named unknown-… has an owner the profile endpoint can't name yet; others are cached.
        owner=lambda root,blob: '' if not blob or blob['claudeAiOauth']['accessToken'].startswith('unknown') else blob['claudeAiOauth']['accessToken'].split('-')[0]+'@example.com'
        reader=MagicMock(side_effect=lambda svc: json.loads(json.dumps(keychain.get(svc)))); reader.cache_clear=lambda: None
        home=self.root/'home'; (home/'.claude').mkdir(parents=True)
        stack=contextlib.ExitStack()
        for item in (patch.object(bridge,'read_secret',reader), patch.object(Path,'home',return_value=home),
                     patch.object(bridge,'write_secret',side_effect=lambda svc,blob: keychain.__setitem__(svc,blob)),
                     patch.object(bridge,'token_email',side_effect=owner),
                     patch.object(bridge,'slot_processes',return_value={}),
                     patch.object(bridge.subprocess,'run',side_effect=security)):
            stack.enter_context(item)
        self.addCleanup(stack.close)
        return keychain,login
    def test_rehome_untangles_accounts_pointing_at_each_others_logins(self):
        # The state a Mac reached: two accounts on one slot, each slot holding someone else's login.
        names=['Ai','Golf','Noori','Nerds','Dallas','Arne','Agn']
        ai,golf,noori,nerds,dallas,arne,agn=accts=[account(n) for n in names]; config={'accounts':accts}
        keychain,login=self.rehome_keychain()
        slot=lambda a: bridge.profile_service(self.root,a['id'])
        keychain[bridge.GLOBAL_SERVICE]=login('ai',1)
        keychain[slot(ai)]=login('dallas',1,-60)
        keychain[slot(golf)]=login('ai',1)
        keychain[slot(noori)]=login('arne',1)
        keychain[slot(nerds)]=login('unknown',1,-60)
        for a in accts: bridge.prepare_profile(self.root,a['id'])
        bridge.atomic_json(bridge.homes_path(self.root),{dallas['id']:golf['id'],noori['id']:ai['id'],golf['id']:ai['id']})
        with self.assertRaisesRegex(ValueError,'after Side A frees it'): bridge.sign_in_slot(self.root,config,noori)
        lines=bridge.rehome(self.root,config)
        homes={a['name']:bridge.home_slot(self.root,a) for a in accts}
        self.assertEqual(homes['Ai'],'mac')
        self.assertEqual(homes['Arne'],noori['id'])
        self.assertEqual(homes['Nerds'],nerds['id'])
        self.assertEqual(len(set(homes.values())),len(accts))
        self.assertTrue(all(slot=='mac' or bridge.profile_dir(self.root,slot).is_dir() for slot in homes.values()))
        self.assertIn('Arne found its login in another slot.',lines)
        # Golf's old item held a second copy of Ai's login (the Mac's): nobody reads it, so it went.
        self.assertNotIn(slot(golf),keychain)
        # A separate sign-in of the same account is its own grant, not a copy: it stays.
        keychain[slot(golf)]=login('ai',2); bridge.rehome(self.root,config)
        self.assertIn(slot(golf),keychain)
        for a in accts:
            self.assertEqual(bridge.sign_in_slot(self.root,config,a),bridge.home_slot(self.root,a))
        self.assertEqual(bridge.rehome(self.root,config),[])
    def test_rehome_puts_back_a_login_a_login_command_overwrote(self):
        a,b=account('Alpha'),account('Beta'); config={'accounts':[a,b]}
        keychain,login=self.rehome_keychain()
        alpha=bridge.profile_service(self.root,a['id'])
        keychain[bridge.GLOBAL_SERVICE]=login('other',1); keychain[alpha]=login('alpha',1)
        for item in (a,b): bridge.prepare_profile(self.root,item['id'])
        self.assertEqual(bridge.rehome(self.root,config),[])
        self.assertEqual(keychain[bridge.backup_service(a)]['claudeAiOauth']['refreshToken'],'alpha-rt1')
        # /login typed in a session on Alpha's slot signs it in to Beta.
        keychain[alpha]=login('beta',1)
        lines=bridge.rehome(self.root,config)
        self.assertEqual(lines,['Beta found its login in another slot.',"Alpha's login was overwritten; Side A put back its last one."])
        self.assertEqual(bridge.home_slot(self.root,b),a['id'])
        moved=bridge.home_slot(self.root,a)
        self.assertNotIn(moved,(a['id'],'mac'))
        self.assertEqual(keychain[bridge.profile_service(self.root,moved)]['claudeAiOauth']['refreshToken'],'alpha-rt1')
        self.assertEqual(bridge.owned_login(self.root,a)['claudeAiOauth']['refreshToken'],'alpha-rt1')
        # A login still held somewhere is never copied back.
        self.assertEqual(bridge.rehome(self.root,config),[])
    def test_rehome_leaves_a_signed_out_account_signed_out(self):
        a=account('Alpha'); config={'accounts':[a]}
        keychain,login=self.rehome_keychain()
        alpha=bridge.profile_service(self.root,a['id'])
        bridge.prepare_profile(self.root,a['id'])
        keychain[alpha]=login('alpha',1)
        bridge.rehome(self.root,config)
        self.assertIn(bridge.backup_service(a),keychain)
        # Sign out: the item goes and the account isn't ready; its backup must not come back.
        del keychain[alpha]; a['ready']=False
        self.assertEqual(bridge.rehome(self.root,config),[])
        self.assertNotIn(alpha,keychain)
        bridge.forget_backup(a)
        self.assertNotIn(bridge.backup_service(a),keychain)
    def test_rehome_never_restores_a_login_a_trade_still_holds(self):
        a,b=account('Alpha'),account('Beta'); config={'accounts':[a,b]}
        keychain,login=self.rehome_keychain()
        alpha=bridge.profile_service(self.root,a['id'])
        for item in (a,b): bridge.prepare_profile(self.root,item['id'])
        keychain[alpha]=login('alpha',1); keychain[bridge.GLOBAL_SERVICE]=login('other',1)
        bridge.rehome(self.root,config)
        # A trade's watch keeps Alpha's login while a session wrote Beta's over Alpha's item.
        entry={'id':'w1','at':time.time(),'slots':[a['id'],'mac'],'homes':{}}
        bridge.atomic_json(bridge.watch_path(self.root),{'trades':[entry]})
        keychain[bridge.watch_service(entry)]={'logins':[login('alpha',1)]}
        keychain[alpha]=login('beta',1)
        lines=bridge.rehome(self.root,config)
        self.assertNotIn("Alpha's login was overwritten; Side A put back its last one.",lines)
        self.assertEqual([s for s,v in keychain.items() if s.startswith('Claude') and v['claudeAiOauth']['refreshToken']=='alpha-rt1'],[])
    def test_the_pool_renews_a_refused_token_unless_a_session_already_did(self):
        a=account('Alpha'); config={'accounts':[a]}
        keychain,login=self.rehome_keychain()
        bridge.prepare_profile(self.root,a['id'])
        service=bridge.profile_service(self.root,a['id'])
        keychain[service]=login('alpha',1)
        refused=bridge.token_hash(keychain[service])
        def renewed(root,account,svc,due,config=None):
            if due(keychain[svc]): keychain[svc]=login('alpha',2)
        with patch.object(bridge,'_renew',side_effect=renewed), patch.object(bridge,'verify_idle_owner'):
            self.assertEqual(bridge.pool_token(self.root,config,a)['accessToken'],'alpha-at1')
            got=bridge.pool_token(self.root,config,a,refused=refused)
            self.assertEqual(got['accessToken'],'alpha-at2')
            self.assertEqual(got['hash'],bridge.token_hash(keychain[service]))
            # A hash of a token since replaced renews nothing.
            self.assertEqual(bridge.pool_token(self.root,config,a,refused=refused)['accessToken'],'alpha-at2')
        keychain[service]=login('alpha',3,200)
        with patch.object(bridge,'_renew',side_effect=renewed), patch.object(bridge,'verify_idle_owner'):
            self.assertEqual(bridge.pool_token(self.root,config,a)['accessToken'],'alpha-at2')
    def test_a_second_sign_in_moves_without_becoming_the_accounts_home(self):
        a=account('Alpha'); b=account('Beta'); config={'accounts':[a,b]}
        login=lambda who,n: {'claudeAiOauth':{'accessToken':f'{who}-at{n}','refreshToken':f'{who}-rt{n}','expiresAt':(time.time()+3600)*1000}}
        mac=bridge.GLOBAL_SERVICE; alpha=bridge.profile_service(self.root,a['id']); beta=bridge.profile_service(self.root,b['id'])
        # Alpha is the Mac login and also signed in separately in its own profile, where sessions run.
        keychain={mac:login('alpha',1), alpha:login('alpha',2), beta:login('beta',1)}
        owner=lambda root,blob: ((blob or {}).get('claudeAiOauth') or {}).get('accessToken','').split('-')[0]+'@example.com' if blob else ''
        reader=MagicMock(side_effect=lambda svc: keychain.get(svc)); reader.cache_clear=lambda: None
        def run(args,*rest,**kw):
            keychain.pop(args[-1],None); return subprocess.CompletedProcess(args,0)
        home=self.root/'home'; (home/'.claude').mkdir(parents=True)
        with patch.object(bridge,'read_secret',reader), patch.object(bridge,'write_secret',side_effect=lambda svc,blob: keychain.__setitem__(svc,blob)), \
             patch.object(bridge,'token_email',side_effect=owner), patch.object(bridge,'mac_email',side_effect=lambda root: owner(root,keychain[mac])), \
             patch.object(bridge.subprocess,'run',side_effect=run), patch.object(Path,'home',return_value=home), \
             patch.object(bridge,'slot_processes',return_value={}):
            # A session started on Beta, or Beta signing in, blocks the trade: nothing lands on them.
            with patch.object(bridge,'slot_processes',return_value={77:b['id']}):
                with self.assertRaisesRegex(ValueError,'using that account'): bridge.swap(self.root,config,a['id'],b)
            bridge.signing_in_path(self.root,b['id']).write_text(str(os.getpid()))
            with self.assertRaisesRegex(ValueError,'signing in'): bridge.swap(self.root,config,a['id'],b)
            bridge.signing_in_path(self.root,b['id']).unlink()
            self.assertEqual(keychain[alpha]['claudeAiOauth']['refreshToken'],'alpha-rt2')
            bridge.swap(self.root,config,a['id'],b)
            self.assertEqual((keychain[alpha]['claudeAiOauth']['refreshToken'],keychain[beta]['claudeAiOauth']['refreshToken']),('beta-rt1','alpha-rt2'))
            # Alpha stays the Mac login; Beta now lives in Alpha's profile.
            self.assertEqual((bridge.home_slot(self.root,a),bridge.home_slot(self.root,b)),('mac',a['id']))
            self.assertEqual(keychain[mac]['claudeAiOauth']['refreshToken'],'alpha-rt1')
    def test_renewing_an_expired_login_spends_its_refresh_token_once_and_keeps_the_rest(self):
        a=account('Alpha'); login=lambda: {'claudeAiOauth':{'accessToken':'old','refreshToken':'r1','expiresAt':1,'scopes':['user:inference','user:profile'],'subscriptionType':'max'}}
        old=login()
        store={'blob':old}; posts=[]; fresh=lambda: {'claudeAiOauth':{**old['claudeAiOauth'],'accessToken':'session','expiresAt':(time.time()+3600)*1000}}
        def post(url,body,headers=None,method='POST'):
            posts.append(body); return {'access_token':'new','refresh_token':'r2','expires_in':28800}
        with patch.object(bridge,'mac_email',return_value=''), patch.object(bridge,'auth_status',return_value={'email':'alpha@example.com'}), \
             patch.object(bridge,'read_secret',side_effect=lambda svc: store['blob']) as reader, \
             patch.object(bridge,'write_secret',side_effect=lambda svc,blob: store.update(blob=blob)), patch.object(bridge,'post_json',side_effect=post):
            reader.cache_clear=lambda: None
            bridge.renew(self.root,{'accounts':[a]},a)
            self.assertEqual(posts[0]['refresh_token'],'r1'); self.assertEqual(posts[0]['client_id'],bridge.CLIENT_ID)
            renewed=store['blob']['claudeAiOauth']
            self.assertEqual((renewed['accessToken'],renewed['refreshToken'],renewed['subscriptionType']),('new','r2','max'))
            # A session that renewed it while Side A waited for the lock wins: nothing is spent twice.
            store['blob']=login(); seen=iter([login(),login(),fresh()])  # before the lock, then inside it
            with patch.object(bridge,'read_secret',side_effect=lambda svc: next(seen,store['blob'])) as again:
                again.cache_clear=lambda: None
                bridge.renew(self.root,{'accounts':[a]},a)
            self.assertEqual(len(posts),1)
        dead=bridge.urllib.error.HTTPError(bridge.TOKEN_URL,400,'Bad Request',{},io.BytesIO(b'{"error":"invalid_grant"}'))
        with patch.object(bridge,'mac_email',return_value=''), patch.object(bridge,'auth_status',return_value={'email':'alpha@example.com'}), \
             patch.object(bridge,'read_secret',return_value=login()) as reader, patch.object(bridge,'post_json',side_effect=dead), patch.object(bridge,'write_secret') as writer:
            reader.cache_clear=lambda: None
            with self.assertRaisesRegex(ValueError,'Sign in to Alpha again'): bridge.renew(self.root,{'accounts':[a]},a)
            writer.assert_not_called()

    def test_sessions_serve_answers_an_unexpected_error_and_keeps_serving(self):
        failures=iter([AttributeError("'str' object has no attribute 'get'"),IndexError('list index out of range'),None])
        def run(root,args):
            error=next(failures)
            if error: raise error
            return {'ok':args.text}
        stdin=io.StringIO(''.join(json.dumps({'id':n,'args':['show','s1']})+'\n' for n in range(3)))
        stdout=io.StringIO()
        with patch.object(bridge,'run_sessions',side_effect=run), patch.object(sys,'stdin',stdin), patch.object(sys,'stdout',stdout):
            bridge.serve_sessions(self.root,bridge.build_parser().sessions)
        replies=[json.loads(line) for line in stdout.getvalue().splitlines()]
        self.assertEqual([(r['id'],r.get('error'),r.get('result')) for r in replies],
                         [(0,"'str' object has no attribute 'get'",None),(1,'list index out of range',None),(2,None,{'ok':'s1'})])
    def test_sessions_serve_takes_the_id_after_options_on_the_system_python_too(self):
        home=self.root/'home'; project=home/'.claude/projects/-code-app'; project.mkdir(parents=True)
        lines=[{'type':'user','uuid':'u1','timestamp':'2026-10-01T10:00:00Z','cwd':'/code/app','message':{'content':'Add search'}},
               {'type':'assistant','uuid':'a1','timestamp':'2026-10-01T10:00:01Z','message':{'content':[{'type':'text','text':'x'*7000}]}}]
        (project/'s1.jsonl').write_text(''.join(json.dumps(line)+'\n' for line in lines))
        requests=[['show','--limit','150','--around','u1','--','s1'],['show','--limit','5','--','s1'],['show','s1','--limit','5'],['search','--days','30','--','search'],
                  ['show','--format','remote','--limit','5','--','s1'],['images','--limit','5','--','s1'],['image','0'*40]]
        stdin=''.join(json.dumps({'id':n,'args':args})+'\n' for n,args in enumerate(requests+[['show','s1','--format','remote','--after','zz']]))
        # macOS's /usr/bin/python3 is 3.9, which the app accepts and whose argparse put the id after options out of reach.
        for python in dict.fromkeys([sys.executable]+[p for p in ['/usr/bin/python3'] if os.path.exists(p)]):
            with self.subTest(python=python):
                def serve(stdin):
                    done=subprocess.run([python,str(Path(bridge.__file__)),'--root',str(self.root/'SideA'),'sessions','serve'],input=stdin,
                                        capture_output=True,text=True,timeout=60,env={**os.environ,'HOME':str(home)})
                    return [json.loads(line) for line in done.stdout.splitlines()],done.stderr
                replies,stderr=serve(stdin)
                # A failed request answers with its error and the loop keeps serving.
                self.assertEqual([r.get('error') for r in replies],[None]*len(requests)+['Bad cursor'],stderr)
                self.assertEqual([m['uuid'] for m in replies[0]['result']['messages']],['u1','a1'])
                self.assertEqual(replies[6]['result'],{'error':'gone'})
                generation=replies[4]['result']['generation']
                whole,stderr=serve(json.dumps({'id':9,'args':['message','s1','--seq','1','--generation',generation]})+'\n')
                self.assertEqual(len(whole[0]['result']['text']),7000,stderr)

if __name__ == '__main__': unittest.main()
