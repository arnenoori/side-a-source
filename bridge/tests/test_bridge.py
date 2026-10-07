import contextlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid

SPEC = importlib.util.spec_from_file_location('bridge', Path(__file__).parents[1] / 'sidea_bridge.py')
bridge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bridge)


def account(name='Personal', **extra):
    return dict(id=str(uuid.uuid4()), name=name, email=name.lower()+'@example.com', ready=True, allowAuto=True, **extra)


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
    def tearDown(self):
        self.temp.cleanup()
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
            result=bridge.claude_usage(self.root,config,a)
            self.assertEqual([(w['id'],w['percent']) for w in result['windows']],[('five_hour',40.0),('seven_day',10.0),('model:fable',3.0)])
            # An expired login has not been used since it expired; it is never refreshed.
            with self.assertRaisesRegex(ValueError,'idle'): bridge.claude_usage(self.root,config,b)
            self.assertEqual(post.call_count,1)
            # Review: a 401 returned empty windows, wiping the last reading with no backoff.
            post.side_effect=bridge.urllib.error.HTTPError(bridge.USAGE_URL,401,'',{},None)
            with self.assertRaisesRegex(ValueError,'Sign in to Alpha'): bridge.claude_usage(self.root,config,a)
        self.assertFalse(hasattr(bridge,'write_secret'))
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
        # A live session appends: only new bytes are read, a response split across the seam
        # counts once, and a half-written last line waits for the next scan.
        with open(folder/'s.jsonl','a') as stream:
            stream.write(line('b','2026-10-01T17:30:00Z',7)+'\n'+line('c','2026-10-01T18:00:00Z',9)+'\n'+line('d','2026-10-01T18:05:00Z',100)[:30])
        with patch.object(Path,'home',return_value=Path(self.temp.name)/'home'), patch.object(bridge.time,'time',return_value=(folder/'s.jsonl').stat().st_mtime), \
             patch.object(bridge,'json',wraps=json) as spy:
            result=bridge.report(self.root,days=10000)
        self.assertEqual([(r['input'],r['output']) for r in result['projects']],[(3,21)])
        self.assertEqual(sum(1 for c in spy.loads.call_args_list if 'usage' in str(c)),2)

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

if __name__ == '__main__': unittest.main()
