import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
import uuid
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]))
import sidea_bridge as bridge
import codex_bridge as codex


class CodexTests(unittest.TestCase):
    def test_adopting_the_mac_codex_login_never_copies_it(self):
        import base64
        claims=base64.urlsafe_b64encode(json.dumps({'email':'a@example.com'}).encode()).decode().rstrip('=')
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)/'side-a'; home=Path(d)/'home'; (home/'.codex').mkdir(parents=True)
            (home/'.codex/auth.json').write_text(json.dumps({'tokens':{'id_token':'h.'+claims+'.s'}}))
            a={'id':str(uuid.uuid4()),'provider':'codex'}
            with patch.object(Path,'home',return_value=home):
                self.assertEqual(codex.adopt(root,a)['email'],'a@example.com')
            self.assertFalse((root/'profiles'/a['id']/'auth.json').exists())
    def test_the_mac_codex_login_is_read_where_codex_keeps_it(self):
        with tempfile.TemporaryDirectory() as d, patch('codex_bridge.RPC') as cls, patch.object(codex,'global_email',return_value='a@example.com'), \
             patch.object(codex,'codex_binary',return_value='codex'):
            cls.return_value.__enter__.return_value.call.return_value={'rateLimits':{}}
            codex.usage(Path(d),{'id':str(uuid.uuid4()),'email':'A@example.com'})
            command,env,_=cls.call_args[0]
            self.assertEqual(env['CODEX_HOME'],str(codex.global_home()))
            self.assertNotIn('cli_auth_credentials_store="file"',command)
            import base64
            token=lambda email:'h.'+base64.urlsafe_b64encode(json.dumps({'email':email}).encode()).decode().rstrip('=')+'.s'
            b={'id':str(uuid.uuid4()),'name':'B','email':'b@example.com'}
            auth=codex.prepare_profile(Path(d),b['id'])/'auth.json'
            auth.write_text(json.dumps({'tokens':{'id_token':token('b@example.com')}}))
            codex.usage(Path(d),b)
            command,env,_=cls.call_args[0]
            self.assertNotEqual(env['CODEX_HOME'],str(codex.global_home()))
            # Review: a profile holding another account's login (a 0.4 copy) was read and primed as B.
            auth.write_text(json.dumps({'tokens':{'id_token':token('a@example.com')}}))
            calls=cls.call_count
            for action in (codex.usage, codex.prime):
                with self.assertRaisesRegex(ValueError,'Sign in to B'): action(Path(d),b)
            self.assertEqual(cls.call_count,calls)

if __name__ == '__main__': unittest.main()
