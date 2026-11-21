"""Isolated installer and real tmux lifecycle checks; no live tasks or credentials."""
import fcntl
import os
from pathlib import Path
import pty
import select
import shutil
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import unittest

REPO = Path(__file__).resolve().parent
TMUX = shutil.which('tmux')


def wait_for(predicate, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.03)
    raise AssertionError('Timed out waiting for the test task/client')


class Client:
    def __init__(self, command, env):
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 100, 0, 0))

        def setup():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        self.process = subprocess.Popen(command, env=env, stdin=slave, stdout=slave,
                                        stderr=slave, preexec_fn=setup)
        os.close(slave)
        self.output = bytearray()
        self.stop = threading.Event()

        def drain():
            while not self.stop.is_set():
                if select.select([self.master], [], [], 0.05)[0]:
                    try:
                        data = os.read(self.master, 65536)
                        if not data:
                            break
                        self.output.extend(data)
                    except OSError:
                        break

        self.thread = threading.Thread(target=drain, daemon=True)
        self.thread.start()

    def send(self, data):
        os.write(self.master, data)

    def close(self):
        if self.master is not None:
            self.stop.set()
            self.thread.join()
            os.close(self.master)
            self.master = None


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.bin = self.home / 'test-bin'
        self.bin.mkdir()
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('CODEX_', 'AI_SWITCH_', 'OPENAI_'))}
        self.env.update(HOME=str(self.home), CODEX_HOME=str(self.home / '.codex'),
                        PATH=str(self.bin) + ':' + os.environ['PATH'], AI_SWITCH_RAW_BASE=REPO.as_uri())

    def script(self, name, content):
        path = self.bin / name
        path.write_text('#!/bin/bash\n' + content)
        path.chmod(0o755)

    def install_functions(self, body, env=None):
        return subprocess.run(['bash', '-c', 'source <(sed \'$d\' "$1/install.sh"); ' + body,
                               'test', str(REPO)], env=env or self.env,
                              capture_output=True, text=True, timeout=15)

    def test_optional_tmux_defaults_to_no_and_accepts_explicit_opt_in(self):
        dispatch = self.home / 'dispatch'
        dispatch.mkdir()
        log = self.home / 'tmux-install-calls'
        (dispatch / 'codex-switch.sh').write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> ' + str(log) + '\n')
        (dispatch / 'codex-switch.sh').chmod(0o755)
        body = ('SHARE_DIR="$HOME/dispatch"; can_prompt() { return 0; }; '
                'prompt() { printf -v "$2" "%s" ""; }; maybe_install_tmux')
        result = self.install_functions(body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(log.exists())
        result = self.install_functions(body, dict(self.env, CODEX_SWITCH_INSTALL_TMUX='1'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(log.read_text(), 'tmux-install\n')

    def test_installer_requests_lts_and_official_latest_then_reports_actual_binary(self):
        log = self.home / 'calls'
        self.script('fnm', 'printf "fnm %s\\n" "$*" >> ' + str(log) + '\n')
        self.script('node', 'printf "v24.0.0\\n"\n')
        self.script('npm', 'printf "npm %s\\n" "$*" >> ' + str(log) +
                    '\nif [[ $1 == view ]]; then printf "9.9.9\\n"; fi\n')
        self.script('codex', 'printf "codex-cli 9.9.9\\n"\n')
        result = self.install_functions('install_node; install_clis')
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = log.read_text()
        self.assertIn('fnm install --lts --use', calls)
        self.assertIn('fnm default v24.0.0', calls)
        self.assertIn('npm install -g @openai/codex@latest --registry=https://registry.npmjs.org/', calls)
        self.assertIn(str(self.bin / 'codex'), result.stdout)
        self.assertIn('codex-cli 9.9.9', result.stdout)

    def test_upgrade_clears_stale_functions_and_preserves_custom_tmux_config(self):
        rc = self.home / '.bashrc'
        rc.write_text('# keep my settings\n# >>> ai-switch >>>\nsource /removed/old.sh\n# <<< ai-switch <<<\n')
        custom = self.home / '.tmux.conf'
        custom.write_text('set -g status on\n')
        result = self.install_functions('install_switcher')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(custom.read_text(), 'set -g status on\n')
        self.assertNotIn('source /removed/old.sh', rc.read_text())
        command = ('zz() { echo stale; }; zl() { :; }; zk() { :; }; '
                   'alias zz="zellij"; alias zl="zellij ls"; alias zk="killall zellij"; '
                   'source "$HOME/.bashrc"; '
                   'for n in zz zl zk; do ! declare -F "$n" && ! alias "$n" 2>/dev/null || exit 1; done; '
                   'test "$(type -t zz)" = file; codex-switch start --help')
        result = subprocess.run(['bash', '-c', command], env=self.env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('F12', result.stdout)


@unittest.skipUnless(TMUX, 'tmux unavailable')
class TmuxTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.bin = self.home / 'bin'
        self.bin.mkdir()
        self.socket = 'codex-switch-test-' + self.home.name
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('CODEX_', 'OPENAI_', 'AI_SWITCH_', 'ZELLIJ', 'TMUX'))}
        self.env.update(HOME=str(self.home), CODEX_HOME=str(self.home / '.codex'),
                        TERM='xterm-256color', PATH=str(self.bin) + ':' + os.environ['PATH'],
                        AI_SWITCH_RAW_BASE=REPO.as_uri())
        wrapper = self.bin / 'tmux'
        wrapper.write_text('#!/bin/bash\nexec ' + TMUX + ' -L ' + self.socket + ' "$@"\n')
        wrapper.chmod(0o755)
        probe = self.bin / 'codex'
        probe.write_text('#!' + sys.executable + '\n' + '''import os, pathlib, tty
r=pathlib.Path(''' + repr(str(self.home)) + ''')
with (r/'launches').open('a') as f: f.write(str(os.getpid())+'\\n')
tty.setraw(0)
for i in range(150): print(f'历史 {i:03d} 中文', end='\\r\\n')
print('\\x1b[?2004hREADY', end='\\r\\n', flush=True)
with (r/('keys-'+str(os.getpid()))).open('ab',buffering=0) as f:
 while True: f.write(os.read(0,4096))
''')
        probe.chmod(0o755)
        self.clients = []
        self.addCleanup(self.shutdown)

    def shutdown(self):
        subprocess.run([TMUX, '-L', self.socket, 'kill-server'],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for client in self.clients:
            client.close()
            try:
                client.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                client.process.kill()
                client.process.wait()

    def tmux(self, *args):
        return subprocess.check_output([TMUX, '-L', self.socket, *args], text=True)

    def client(self, *args, binary=None):
        client = Client(['bash', str(binary or REPO / 'zz.sh'), *args], self.env)
        self.clients.append(client)
        return client

    def launches(self):
        path = self.home / 'launches'
        return path.read_text().splitlines() if path.exists() else []

    def start(self, name):
        before = len(self.launches())
        client = self.client(name)
        wait_for(lambda: len(self.launches()) == before + 1)
        pid = self.launches()[-1]
        wait_for(lambda: (self.home / ('keys-' + pid)).exists())
        wait_for(lambda: bool(self.tmux('list-clients').strip()))
        return client, pid

    def detach(self, client):
        client.send(b'\x1b[24~')  # xterm F12
        self.assertEqual(client.process.wait(timeout=5), 0)
        client.close()

    def test_f12_disconnect_and_reconnect_preserve_process_input_and_history(self):
        client, pid = self.start('work')
        keys = self.home / ('keys-' + pid)
        payload = '中文输入'.encode() + b'\x10\x0e\x1b[200~' + '多行\n粘贴'.encode() + b'\x1b[201~'
        client.send(payload)
        wait_for(lambda: payload in keys.read_bytes())
        self.assertEqual(self.tmux('show-options', '-gv', 'status').strip(), 'off')
        self.detach(client)
        client = self.client()
        wait_for(lambda: bool(self.tmux('list-clients').strip()))
        client.close()  # PTY hangup, as with a dropped SSH connection
        client.process.wait(timeout=5)
        os.kill(int(pid), 0)
        client = self.client('work')
        wait_for(lambda: bool(self.tmux('list-clients').strip()))
        self.assertEqual(self.launches(), [pid])
        client.send('重连成功'.encode())
        wait_for(lambda: '重连成功'.encode() in keys.read_bytes())
        self.assertIn('历史 000 中文', self.tmux('capture-pane', '-p', '-S', '-'))
        self.detach(client)

    def test_exact_names_and_numbered_session_selection(self):
        first, _ = self.start('work-long')
        self.detach(first)
        second, _ = self.start('work')
        self.detach(second)
        self.assertEqual(len(self.launches()), 2)
        chooser = self.client()
        wait_for(lambda: '输入序号'.encode() in chooser.output)
        chooser.send(b'2\n')
        wait_for(lambda: self.tmux('list-clients', '-F', '#{client_session}').strip() == 'work-long')
        self.detach(chooser)

    def test_stop_requires_confirmation_and_only_ends_the_selected_task(self):
        first, _ = self.start('one')
        self.detach(first)
        second, survivor = self.start('two')
        self.detach(second)
        for answer in (b'n\n', b'y\n'):
            client = self.client('stop', 'one')
            wait_for(lambda: b'[y/N]' in client.output)
            client.send(answer)
            self.assertEqual(client.process.wait(timeout=5), 0)
            client.close()
            os.kill(int(survivor), 0)
        self.assertEqual(self.tmux('list-sessions', '-F', '#S').strip(), 'two')

    def test_uninstall_keeps_running_tasks_and_user_tmux_config(self):
        result = subprocess.run(['bash', '-c', 'source <(sed \'$d\' "$1/install.sh"); install_switcher',
                                 'test', str(REPO)], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        binary = self.home / '.local/bin/zz'
        custom = self.home / '.tmux.conf'
        custom.write_text('set -g status on\n')
        client = self.client('keep', binary=binary)
        wait_for(lambda: len(self.launches()) == 1)
        pid = self.launches()[0]
        self.detach(client)
        result = subprocess.run(['bash', str(REPO / 'uninstall.sh')], env=self.env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(binary.exists())
        self.assertFalse(binary.is_symlink())
        self.assertEqual(custom.read_text(), 'set -g status on\n')
        self.assertEqual(self.tmux('list-sessions', '-F', '#S').strip(), 'keep')
        os.kill(int(pid), 0)

    def test_missing_optional_tmux_does_not_install_anything(self):
        empty = self.home / 'empty-bin'
        empty.mkdir()
        result = subprocess.run(['/bin/bash', str(REPO / 'zz.sh')],
                                env=dict(self.env, PATH=str(empty)), capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('可选组件', result.stderr)
        self.assertEqual(self.launches(), [])


if __name__ == '__main__':
    unittest.main()
