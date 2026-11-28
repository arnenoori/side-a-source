import importlib.util
import os
from pathlib import Path
import pty
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]))
SPEC = importlib.util.spec_from_file_location('hosting', Path(__file__).parents[1] / 'hosting.py')
hosting = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(hosting)
BRIDGE_SPEC = importlib.util.spec_from_file_location('bridge', Path(__file__).parents[1] / 'sidea_bridge.py')
bridge = importlib.util.module_from_spec(BRIDGE_SPEC)
BRIDGE_SPEC.loader.exec_module(bridge)

TMUX = hosting.find_tmux()


class HostingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / 'Side A'
        (self.root / 'runtime').mkdir(parents=True)

    def tearDown(self):
        self.temp.cleanup()

    def test_sessions_under_a_pane_are_hosted_and_the_closest_keeps_it(self):
        parents = {200: 100, 300: 200, 100: 1, 400: 50, 50: 1}
        rows = [{'pid': 300}, {'pid': 200}, {'pid': 400}]
        hosting.match(rows, parents, {100: 'sa-app-1a2b'})
        self.assertEqual([r['hosted'] for r in rows], [None, 'sa-app-1a2b', None])
        self.assertEqual(hosting.match([{'pid': 200}], parents, {})[0]['hosted'], None)
        self.assertIsNone(hosting.hosted_by(7, {7: 8, 8: 7}, {100: 'x'}))

    def test_no_tmux_means_nothing_is_hosted_and_hosting_stays_off(self):
        (self.root / 'runtime/tmux-path').write_text('/usr/local/bin/tmux\n')
        with patch.object(hosting, 'find_tmux', return_value=None):
            self.assertEqual(hosting.install(self.root), {'tmux': None, 'running': False})
        self.assertFalse((self.root / 'runtime/tmux-path').exists())
        self.assertEqual(hosting.panes(self.root), {})
        launcher = self.root / 'runtime/sidea-tmux'
        self.assertEqual(launcher.stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.root / 'runtime/tmux.conf').stat().st_mode & 0o777, 0o600)
        failed = subprocess.run([str(launcher), 'ls'], capture_output=True, text=True, check=False)
        self.assertEqual((failed.returncode, failed.stderr.strip()), (69, 'Side A found no tmux 3.4 or later.'))

    def test_versions_below_3_4_are_refused(self):
        fake = Path(self.temp.name) / 'tmux'
        fake.write_text('#!/bin/sh\necho "tmux 3.3a"\n'); fake.chmod(0o755)
        self.assertEqual(hosting.version(str(fake)), (3, 3))
        with patch.object(hosting, 'CANDIDATES', [str(fake)]):
            self.assertIsNone(hosting.find_tmux())
        fake.write_text('#!/bin/sh\necho "tmux next-3.8"\n')
        with patch.object(hosting, 'CANDIDATES', [str(fake)]):
            self.assertEqual(hosting.find_tmux(), str(fake))

    def test_the_bundled_tmux_brings_its_own_terminfo_and_without_one_panes_are_screen(self):
        contents = Path(self.temp.name) / 'Side A.app/Contents'
        bundled = contents / 'Helpers/tmux'
        bundled.parent.mkdir(parents=True)
        bundled.write_text('#!/bin/sh\necho "tmux 3.7c"\n'); bundled.chmod(0o755)
        (contents / 'Resources/terminfo/74').mkdir(parents=True)
        (contents / 'Resources/terminfo/74/tmux-256color').write_bytes(b'\x1e\x02')
        with patch.object(hosting, 'server', return_value=(['/usr/bin/false'], {})):
            self.assertEqual(hosting.install(self.root, str(bundled))['tmux'], str(bundled))
        written = (self.root / 'runtime/tmux.conf').read_text()
        self.assertIn('default-terminal "tmux-256color"', written)
        self.assertTrue(written.endswith(f"set-environment -g TERMINFO_DIRS '{contents}/Resources/terminfo:'\n"))
        self.assertEqual((self.root / 'runtime/tmux-path').read_text(), f'{bundled}\n')
        with patch.object(hosting, 'SYSTEM_TERMINFO', [self.temp.name]):
            lacking = hosting.config(None)
        self.assertIn('default-terminal "screen-256color"', lacking)
        self.assertNotIn('TERMINFO_DIRS', lacking)
        with patch.object(hosting, 'SYSTEM_TERMINFO', [str(contents / 'Resources/terminfo')]):
            self.assertEqual(hosting.config(None), hosting.CONFIG)


@unittest.skipUnless(TMUX, 'tmux 3.4 or later is not installed')
class LauncherTests(unittest.TestCase):
    """Runs the real launcher against a private tmux server with a fake agent."""

    def setUp(self):
        # A short path: Unix socket paths are limited to about 100 bytes.
        self.temp = tempfile.TemporaryDirectory(prefix='sa', dir='/tmp')
        base = Path(self.temp.name)
        self.root = base / 'Side A'
        self.home = base / 'home'
        self.project = base / 'my App'
        self.bin = base / 'bin'
        for folder in (self.root / 'runtime', self.home, self.project, self.bin):
            folder.mkdir(parents=True)
        self.socket = str(base / 's')
        env = patch.dict(os.environ, {'SIDE_A_TMUX_SOCKET': self.socket}); env.start(); self.addCleanup(env.stop)
        self.out = base / 'out'
        for agent in ('claude', 'codex'):
            fake = self.bin / agent
            fake.write_text('#!/bin/zsh -f\n{ print -r -- "$SIDE_A_HOSTED|${SIDE_A_PIN:-}|${CODEX_HOME:-}|$PWD"; '
                            'for a in "$@"; do print -r -- "<$a>"; done } > %s/$SIDE_A_HOSTED.txt\n'
                            '[[ ${1:-} == --exit ]] && exit 3\nsleep 30\n' % self.out)
            fake.chmod(0o755)
        self.out.mkdir()
        (self.home / '.zshrc').write_text(f'export PATH={self.bin}:$PATH\n')
        self.assertEqual(hosting.install(self.root)['tmux'], TMUX)

    def tearDown(self):
        # Before the folder goes: the socket is in it.
        self.tmux('kill-server')
        self.temp.cleanup()

    def tmux(self, *args):
        return subprocess.run([TMUX, '-S', self.socket, *args], capture_output=True, text=True, check=False).stdout

    def run_launcher(self, *args, cwd=None, env=None):
        environment = {'HOME': str(self.home), 'PATH': '/usr/bin:/bin', 'USER': os.environ.get('USER', 'u'),
                       'SIDE_A_TMUX_SOCKET': self.socket, 'WARP_FOCUS_URL': 'warp://x', **(env or {})}
        return subprocess.run([str(self.root / 'runtime/sidea-tmux'), *args], capture_output=True, text=True,
                              cwd=cwd or self.project, env=environment, timeout=30, check=False)

    def wait_for(self, path, timeout=10):
        end = time.time() + timeout
        while time.time() < end:
            if path.exists() and path.read_text().strip():
                return path.read_text().splitlines()
            time.sleep(0.1)
        self.fail(f'{path.name} never appeared')

    def test_warm_starts_the_server_with_no_session_and_is_safe_to_repeat(self):
        self.assertNotEqual(subprocess.run([TMUX, '-S', self.socket, 'show', '-s', 'exit-empty'], capture_output=True, check=False).returncode, 0)
        for _ in range(2):
            warmed = self.run_launcher('warm')
            self.assertEqual((warmed.returncode, warmed.stdout), (0, ''), warmed.stderr)
        # Up, configured (a server without the config would exit when empty), and holding nothing.
        self.assertIn('exit-empty off', self.tmux('show', '-s', 'exit-empty'))
        self.assertEqual(self.tmux('list-sessions'), '')

    def test_host_passes_arguments_and_prompt_exactly_and_records_metadata(self):
        prompt = self.root / 'runtime/p.txt'
        prompt.write_text('Fix it; then "explain" $HOME\nsecond line')
        started = self.run_launcher('host', 'claude', '--detach', '--cwd', str(self.project), '--origin', 'mac',
                                    '--pin', 'long-jobs', '--session', 'S1', '--prompt-file', str(prompt),
                                    '--', '--resume', 'S1', 'semi;', "it's")
        self.assertEqual(started.returncode, 0, started.stderr)
        name = started.stdout.strip()
        self.assertRegex(name, r'^sa-my-app-[0-9a-f]{4}$')
        lines = self.wait_for(self.out / f'{name}.txt')
        self.assertEqual(lines[0], f'{name}|long-jobs||{self.project}')
        self.assertEqual(lines[1:], ['<--resume>', '<S1>', '<semi;>', "<it's>", '<-->', '<Fix it; then "explain" $HOME', 'second line>'])
        self.assertFalse(prompt.exists())
        self.assertFalse((self.root / f'runtime/hosted/{name}/prompt.txt').exists())
        meta = self.tmux('list-sessions', '-F', '#{@sidea_v}|#{@sidea_agent}|#{@sidea_cwd}|#{@sidea_origin}|#{@sidea_session}|#{@sidea_account}').strip()
        self.assertEqual(meta, f'1|claude|{self.project}|mac|S1|long-jobs')
        self.assertNotIn('WARP_FOCUS_URL', self.tmux('show-environment', '-g'))
        again = self.run_launcher('host', 'claude', '--detach', '--session', 'S1', '--', '--resume', 'S1')
        self.assertEqual(again.stdout.strip(), name, self.tmux('list-panes', '-a', '-F', '#{pane_dead} #{pane_dead_status} #{@sidea_session} #{session_name}') + again.stderr)
        self.assertEqual(len(self.tmux('list-sessions', '-F', '#{session_name}').split()), 1)

    def test_a_prompt_like_a_flag_comes_after_the_end_of_options(self):
        prompt = self.root / 'runtime/p.txt'
        prompt.write_text('--permission-mode=bypassPermissions')
        started = self.run_launcher('host', 'claude', '--detach', '--cwd', str(self.project), '--origin', 'phone', '--prompt-file', str(prompt), '--', '--model', 'opus')
        self.assertEqual(started.returncode, 0, started.stderr)
        lines = self.wait_for(self.out / f'{started.stdout.strip()}.txt')
        self.assertEqual(lines[1:], ['<--model>', '<opus>', '<-->', '<--permission-mode=bypassPermissions>'])

    def test_a_retried_start_returns_the_first_session(self):
        first = self.run_launcher('host', 'codex', '--detach', '--key', 'k-1', '--env', f'CODEX_HOME={self.home}/codex;', '--', 'hello')
        second = self.run_launcher('host', 'codex', '--detach', '--key', 'k-1', '--', 'hello')
        self.assertEqual(first.stdout, second.stdout)
        name = first.stdout.strip()
        self.assertEqual(self.wait_for(self.out / f'{name}.txt')[0], f'{name}||{self.home}/codex;|{self.project.resolve()}')
        other = self.run_launcher('host', 'codex', '--detach', '--key', 'k-2', '--', 'hello')
        self.assertNotEqual(other.stdout, first.stdout)

    def test_a_worktree_session_starts_in_its_own_checkout_with_the_ignored_env_files(self):
        repo = self.project
        git = lambda *a: subprocess.run(['git', '-C', str(repo), *a], capture_output=True, text=True, check=True).stdout
        git('init', '-q', '-b', 'main')
        (repo / 'apps/web').mkdir(parents=True)
        (repo / '.gitignore').write_text('.env*\n!.env.example\nnode_modules/\n')
        (repo / '.env.example').write_text('KEY=\n')
        (repo / 'apps/web/page.txt').write_text('hi\n')
        git('add', '-A'); git('-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-qm', 'init')
        (repo / '.env').write_text('KEY=root\n')
        (repo / 'apps/web/.env.local').write_text('KEY=web\n')
        (repo / 'node_modules').mkdir(); (repo / 'node_modules/.env').write_text('not copied\n')
        started = self.run_launcher('host', 'claude', '--detach', '--cwd', str(repo / 'apps/web'), '--worktree', 'HEAD', '--')
        self.assertEqual(started.returncode, 0, started.stderr)
        name = started.stdout.strip()
        tree = repo.resolve() / '.sidea-worktrees' / name
        self.assertEqual(self.wait_for(self.out / f'{name}.txt')[0], f'{name}|||{tree}/apps/web')
        self.assertEqual((tree / '.env').read_text(), 'KEY=root\n')
        self.assertEqual((tree / 'apps/web/.env.local').read_text(), 'KEY=web\n')
        self.assertFalse((tree / 'node_modules').exists())
        self.assertEqual(sorted((self.root / f'runtime/hosted/{name}/copied.txt').read_text().split()), ['.env', 'apps/web/.env.local'])
        self.assertEqual((self.root / f'runtime/hosted/{name}/copied-from').read_text().strip(), str(repo.resolve()))
        self.assertIn('/.sidea-worktrees/', (repo / '.git/info/exclude').read_text())
        self.assertEqual(git('status', '--porcelain'), '')
        # Checked out in the session's worktree ('+'), with no upstream (--no-track).
        self.assertEqual(git('branch', '--list', f'sidea/{name}').strip(), f'+ sidea/{name}')
        self.assertNotEqual(subprocess.run(['git', '-C', str(repo), 'config', '--get', f'branch.sidea/{name}.remote'], check=False).returncode, 0)
        meta = self.tmux('list-sessions', '-F', '#{@sidea_repo}|#{@sidea_worktree}|#{@sidea_branch}|#{@sidea_cwd}').strip()
        self.assertEqual(meta, f'{repo.resolve()}|{tree}|sidea/{name}|{tree}/apps/web')
        failed = self.run_launcher('host', 'claude', '--detach', '--cwd', str(self.home), '--worktree', 'HEAD', '--')
        self.assertEqual(failed.returncode, 65)
        self.assertIn('Not in a git repository', failed.stderr)
        self.assertEqual(len(self.tmux('list-sessions', '-F', '#{session_name}').split()), 1)

    def test_a_finished_agent_leaves_its_pane_with_the_status(self):
        name = self.run_launcher('host', 'claude', '--detach', '--', '--exit').stdout.strip()
        end = time.time() + 10
        while time.time() < end and self.tmux('list-panes', '-t', f'={name}:', '-F', '#{pane_dead}').strip() != '1':
            time.sleep(0.1)
        self.assertEqual(self.tmux('list-panes', '-t', f'={name}:', '-F', '#{pane_dead}|#{pane_dead_status}').strip(), '1|3')
        self.assertEqual(hosting.panes(self.root), {})

    def test_live_panes_are_found_for_matching(self):
        name = self.run_launcher('host', 'claude', '--detach').stdout.strip()
        self.wait_for(self.out / f'{name}.txt')
        found = hosting.panes(self.root)
        self.assertEqual(list(found.values()), [name])
        agent = int(subprocess.run(['pgrep', '-P', str(next(iter(found)))], capture_output=True, text=True, check=False).stdout.split()[0])
        self.assertEqual(hosting.match([{'pid': agent}], {agent: next(iter(found))}, found)[0]['hosted'], name)
        settings = lambda: (self.tmux('show', '-s', 'terminal-features'), self.tmux('show-hooks', '-g', 'pane-died'))
        self.assertTrue(hosting.install(self.root)['running'])
        once = settings()
        self.assertTrue(hosting.install(self.root)['running'])
        self.assertEqual(settings(), once)
        self.assertEqual((once[0].count('xterm-ghostty'), len(once[1].splitlines())), (1, 1), once)

    def test_attach_joins_the_only_session_in_this_folder_or_lists_them(self):
        listed = self.run_launcher('ls')
        self.assertEqual(listed.stdout.strip(), 'No hosted sessions.')
        name = self.run_launcher('host', 'claude', '--detach').stdout.strip()
        elsewhere = self.run_launcher('attach', cwd=self.home)
        self.assertEqual((elsewhere.returncode, elsewhere.stdout.split()[0]), (0, name))
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(self.project)
            os.execve(str(self.root / 'runtime/sidea-tmux'), ['sidea-tmux', 'attach'],
                      {'HOME': str(self.home), 'PATH': '/usr/bin:/bin', 'TERM': 'xterm-256color', 'LANG': 'en_US.UTF-8',
                       'SIDE_A_TMUX_SOCKET': self.socket, 'TMUX': '/elsewhere,1,0'})
        try:
            end = time.time() + 10
            while time.time() < end and not self.tmux('list-clients', '-F', '#{session_name}').strip():
                try:
                    os.read(fd, 65536)
                except OSError:
                    break
            self.assertEqual(self.tmux('list-clients', '-F', '#{session_name}').strip(), name)
        finally:
            os.kill(pid, 9); os.waitpid(pid, 0); os.close(fd)

    def fake_app(self, replies):
        """The app's socket (Sources/SideA/ShellControl.swift): each request answered from `replies`, then closed."""
        folder = self.root / 'runtime/cli'
        folder.mkdir(mode=0o700)
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(folder / 'app.sock'))
        listener.listen(4)
        listener.settimeout(0.2)
        done = threading.Event()
        asked = []

        def serve():
            while not done.is_set():
                try:
                    connection, _ = listener.accept()
                except socket.timeout:
                    continue
                with connection:
                    connection.settimeout(10)
                    line = connection.makefile('rb').readline().decode().rstrip('\n')
                    asked.append(line)
                    connection.sendall((replies.get(line, 'no Side A doesn\'t take that request.') + '\n').encode())
        serving = threading.Thread(target=serve)
        serving.start()
        self.addCleanup(listener.close)
        self.addCleanup(serving.join)
        self.addCleanup(done.set)
        return asked

    def test_sidea_reaches_a_linked_computers_session_through_the_app(self):
        remote = self.root / 'runtime/sidea-remote'
        remote.write_text('#!/bin/zsh -f\nprint -r -- "joined $1"\n')
        remote.chmod(0o700)
        target = 'sa-web-0001@Mac mini'
        closed = self.run_launcher('attach', target)
        self.assertEqual((closed.returncode, closed.stdout, closed.stderr), (69, '', "Side A isn't running. Open it, then try again.\n"))
        name = self.run_launcher('host', 'claude', '--detach').stdout.strip()
        alone = self.run_launcher('ls', '--all')
        self.assertEqual((alone.returncode, alone.stdout.split()[0], alone.stderr.strip()), (69, name, "Side A isn't running. Open it, then try again."))

        asked = self.fake_app({f'attach {target}': 'ok /x/linked/1a2b',
                               'attach sa-gone-0000@Mac mini': 'no No session called sa-gone-0000 is running on Mac mini.',
                               'list': "ok\nsa-web-0001@Mac mini  claude  /code/web\n! MacBook can't be reached."})
        joined = self.run_launcher('attach', target)
        self.assertEqual((joined.returncode, joined.stdout, joined.stderr), (0, 'joined /x/linked/1a2b\n', ''))
        gone = self.run_launcher('attach', 'sa-gone-0000@Mac mini')
        self.assertEqual((gone.returncode, gone.stdout, gone.stderr), (1, '', 'No session called sa-gone-0000 is running on Mac mini.\n'))
        listed = self.run_launcher('ls', '--all')
        self.assertEqual(listed.returncode, 0, listed.stderr)
        self.assertEqual(listed.stdout.splitlines()[1:], ['sa-web-0001@Mac mini  claude  /code/web'])
        self.assertTrue(listed.stdout.startswith(f'{name}  claude  '), listed.stdout)
        self.assertEqual(listed.stderr, "MacBook can't be reached.\n")
        # Plain ls, and attach without a computer, stay on this Mac.
        self.assertEqual(self.run_launcher('ls').stdout.split()[0], name)
        broken = self.run_launcher('attach', 'sa-web-0001\n@Mac mini')
        self.assertEqual((broken.returncode, broken.stderr), (64, "A name can't have a line break in it.\n"))
        self.assertEqual(asked, [f'attach {target}', 'attach sa-gone-0000@Mac mini', 'list'])


class HostTerminalTests(unittest.TestCase):
    """The opt-in claude and codex wrappers in ~/.zshrc."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        base = Path(self.temp.name)
        self.root = base / 'Side A'
        self.home = base / 'home'
        self.bin = base / 'bin'
        for folder in (self.root / 'runtime', self.home, self.bin):
            folder.mkdir(parents=True)
        home = patch.object(Path, 'home', return_value=self.home); home.start(); self.addCleanup(home.stop)
        (self.bin / 'claude').write_text('#!/bin/sh\necho "real claude $*"\n'); (self.bin / 'claude').chmod(0o755)
        (self.bin / 'codex').write_text('#!/bin/sh\necho "real codex $*"\n'); (self.bin / 'codex').chmod(0o755)
        host = self.root / 'runtime/sidea-tmux'
        host.write_text('#!/bin/sh\necho "hosted $*"\n'); host.chmod(0o755)

    def tearDown(self):
        self.temp.cleanup()

    def shell(self, script, terminal=True):
        """Runs an interactive zsh reading the test .zshrc, in a PTY when it should look like a terminal."""
        command = ['zsh', '-dic', script]
        env = {'HOME': str(self.home), 'ZDOTDIR': str(self.home), 'PATH': f'{self.bin}:/usr/bin:/bin', 'TERM': 'dumb'}
        if not terminal:
            return subprocess.run(command, capture_output=True, text=True, env=env, stdin=subprocess.DEVNULL, check=False).stdout
        pid, fd = pty.fork()
        if pid == 0:
            os.execve('/bin/zsh', command, env)
        out = b''
        while True:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
        os.waitpid(pid, 0); os.close(fd)
        return out.decode().replace('\r', '')

    def test_wrappers_host_only_interactive_tui_runs_and_keep_the_users_alias(self):
        rc = self.home / '.zshrc'
        rc.write_text("alias claude='claude --dangerously-skip-permissions'\n")
        bridge.set_shell(self.root, True)
        bridge.set_host_terminal(self.root, True)
        text = rc.read_text()
        self.assertLess(text.index(bridge.SHELL_MARK), text.index(bridge.HOST_MARK))
        self.assertTrue((self.root / 'runtime/host-terminal').exists())
        self.assertIn('real claude --dangerously-skip-permissions -p x', self.shell('claude -p x'))
        out = self.shell(f'cd {self.home}; claude --resume abc; codex resume 1; codex exec hi; claude mcp list; claude --version')
        self.assertIn(f'hosted host claude --cwd {self.home} --origin terminal -- --resume abc\n', out)
        self.assertIn(f'hosted host codex --cwd {self.home} --origin terminal -- resume 1', out)
        self.assertIn('real codex exec hi', out)
        self.assertIn('real claude --dangerously-skip-permissions mcp list', out)
        self.assertIn('real claude --dangerously-skip-permissions --version', out)
        self.assertIn('--origin terminal --pin studio --', self.shell('SIDE_A_PIN=studio claude'))
        for prefix in ('SIDE_A_HOSTED=sa-x-1 ', 'TMUX=/t,1,0 ', 'SIDE_A_NO_HOST=1 '):
            self.assertIn('real claude --dangerously-skip-permissions', self.shell(prefix + 'claude'))
        self.assertIn('real claude', self.shell('claude', terminal=False))
        self.assertIn('real claude', self.shell(f"rm '{self.root}/runtime/host-terminal'; claude"))
        bridge.set_host_terminal(self.root, False)
        self.assertNotIn(bridge.HOST_MARK, rc.read_text())
        self.assertIn(bridge.SHELL_MARK, rc.read_text())
        bridge.set_shell(self.root, False)
        self.assertEqual(rc.read_text(), "alias claude='claude --dangerously-skip-permissions'\n")

    def test_a_stale_wrapper_line_or_missing_flag_is_repaired(self):
        rc = self.home / '.zshrc'
        rc.write_text(f'{bridge.HOST_MARK}\nold line\n')
        self.assertTrue(bridge.host_terminal_installed(self.root))
        self.assertIn(bridge.host_snippet(self.root), rc.read_text())
        self.assertNotIn('old line', rc.read_text())
        self.assertTrue((self.root / 'runtime/host-terminal').exists())

    def test_sidea_attach_and_ls_go_through_the_launcher(self):
        bridge.set_shell(self.root, True)
        out = self.shell('sidea attach sa-app-1a2b; sidea ls; sidea', terminal=False)
        self.assertIn('hosted attach sa-app-1a2b', out)
        self.assertIn('hosted ls', out)
        self.assertIn('sidea attach [name] opens a hosted session', out)


if __name__ == '__main__':
    unittest.main()
