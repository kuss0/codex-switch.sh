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
import tomllib
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

    def test_each_menu_choice_and_flag_runs_only_its_selected_steps(self):
        stubs = '''
install_packages() { echo packages >> "$HOME/calls"; }
install_node() { echo node >> "$HOME/calls"; }
install_clis() { echo codex >> "$HOME/calls"; }
install_switcher() { echo "switcher $*" >> "$HOME/calls"; }
maybe_install_tmux() { echo "tmux ${CODEX_SWITCH_INSTALL_TMUX:-}" >> "$HOME/calls"; }
maybe_create_profiles() { echo configure >> "$HOME/calls"; }
can_prompt() { return 0; }
prompt() { printf -v "$2" '%s' "$TEST_CHOICE"; }
'''
        installation = ['packages', 'node', 'codex']
        cases = [
            ('1', '--codex-only', installation),
            ('2', '--configure-only', ['switcher ', 'configure']),
            ('3', '--install-configure', installation + ['switcher ', 'configure']),
            ('4', '--all', installation + ['switcher ', 'tmux 1', 'configure']),
            ('5', '--tmux-only', ['switcher --no-config', 'tmux 1']),
            ('', '--install-configure', installation + ['switcher ', 'configure']),
            ('0', '', []),
        ]
        log = self.home / 'calls'
        for choice, flag, expected in cases:
            commands = ['main']
            if flag:
                commands.append('main ' + flag)
            for command in commands:
                with self.subTest(choice=choice, command=command):
                    log.unlink(missing_ok=True)
                    env = dict(self.env, TEST_CHOICE=choice, CODEX_SWITCH_INSTALL_TMUX='0')
                    result = self.install_functions(stubs + command, env)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(log.read_text().splitlines() if log.exists() else [], expected)
                    if expected:
                        self.assertIn('source ~/.bashrc\nhash -r', result.stdout)

    def test_menu_reprompts_invalid_choice_and_cancels_on_eof(self):
        result = self.install_functions('''
can_prompt() { return 0; }
prompt() { read -r "$2"; }
install_switcher() { echo unexpected-install; }
main <<< $'invalid\\n0'
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('请输入 0 到 5', result.stdout)
        self.assertNotIn('unexpected-install', result.stdout)
        result = self.install_functions('can_prompt() { return 0; }; main </dev/null')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.home / '.local').exists())

    def test_tmux_only_does_not_create_or_replace_codex_configuration(self):
        self.script('tmux', 'printf "tmux 3.5a\\n"\n')
        for command in ('fnm', 'node', 'npm', 'apt-get', 'dnf', 'yum', 'apk'):
            self.script(command, 'echo unexpected-package-install >&2\nexit 83\n')
        config = self.home / '.codex/config.toml'
        for existing in (False, True):
            with self.subTest(existing=existing):
                if existing:
                    config.parent.mkdir()
                    config.write_text('model = "personal-model"\n# personal configuration\n')
                before = config.read_bytes() if existing else None
                result = subprocess.run(['bash', str(REPO / 'install.sh'), '--tmux-only'],
                                        env=self.env, capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn('unexpected-package-install', result.stderr)
                if existing:
                    self.assertEqual(config.read_bytes(), before)
                    self.assertEqual(list(config.parent.iterdir()), [config])
                else:
                    self.assertFalse(config.parent.exists())
                result = subprocess.run(['bash', '-c', 'source "$HOME/.bashrc"; hash -r; zz --help'],
                                        env=self.env, capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('F12', result.stdout)

    def test_piped_installer_reads_menu_and_visible_key_from_terminal(self):
        command = ['bash', '-c', 'cat "$1/install.sh" | bash', 'test', str(REPO)]
        client = Client(command, self.env)
        position = 0

        def answer(prompt, value):
            nonlocal position
            marker = prompt.encode()
            wait_for(lambda: client.output.find(marker, position) >= 0)
            position = client.output.find(marker, position) + len(marker)
            client.send((value + '\n').encode())

        try:
            answer('选择 [0-5，默认 3]: ', '2')
            answer('Codex 配置名称 [default]: ', '')
            answer('API 地址 [https://cpa.openi.eu.org/v1]: ', '')
            answer('API Key（可见输入）: ', 'visible-install-test-key')
            client.process.wait(timeout=15)
            self.assertEqual(client.process.returncode, 0, client.output.decode(errors='replace'))
            data = tomllib.loads((self.home / '.codex/config.toml').read_text())
            provider = data['model_providers'][data['model_provider']]
            self.assertEqual(provider['base_url'], 'https://cpa.openi.eu.org/v1')
            self.assertEqual(provider['experimental_bearer_token'], 'visible-install-test-key')
            self.assertIn(b'visible-install-test-key', client.output)
            self.assertNotIn('model', data)
        finally:
            if client.process.poll() is None:
                client.process.kill()
                client.process.wait()
            client.close()

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

    def test_failed_or_invalid_download_preserves_the_installed_version(self):
        result = self.install_functions('install_switcher')
        self.assertEqual(result.returncode, 0, result.stderr)
        share = self.home / '.local/share/ai-switch'
        paths = [share / name for name in ('ai-switch.sh', 'codex-switch.sh', 'zz.sh', 'tmux.conf')]
        paths.append(self.home / '.bashrc')
        original = {path: path.read_bytes() for path in paths}
        for failure in ('return 22', 'printf "if then\\n" > "$2"', ': > "$2"'):
            with self.subTest(failure=failure):
                body = ('download_to_file() { case "$1" in */zz.sh) ' + failure + ' ;; '
                        '*) cp "${1#file://}" "$2"; '
                        'printf "\\n# staged replacement\\n" >> "$2" ;; esac; }; '
                        'install_switcher')
                result = self.install_functions(body)
                self.assertNotEqual(result.returncode, 0)
                for path, content in original.items():
                    self.assertEqual(path.read_bytes(), content, str(path))
                self.assertEqual(list(share.glob('.install.*')), [])

    def test_foreign_zz_commands_and_links_are_backed_up_once(self):
        binary = self.home / '.local/bin/zz'
        binary.parent.mkdir(parents=True)
        foreign = binary.parent / 'original-zz'
        foreign.write_text('#!/bin/bash\necho original\n')
        foreign.chmod(0o755)
        share = self.home / '.local/share/ai-switch'
        for kind in ('standalone', 'relative-link', 'dangling-link', 'directory-link'):
            with self.subTest(kind=kind):
                if binary.is_symlink():
                    binary.unlink()
                if kind == 'standalone':
                    binary.write_bytes(foreign.read_bytes())
                    binary.chmod(0o755)
                elif kind == 'relative-link':
                    binary.symlink_to('original-zz')
                elif kind == 'dangling-link':
                    binary.symlink_to('missing-zz')
                else:
                    target = self.home / 'foreign-directory'
                    target.mkdir()
                    binary.symlink_to(target, target_is_directory=True)
                link_target = os.readlink(binary) if binary.is_symlink() else None
                previous = set((share / 'install-backups').glob('zz.*'))
                result = self.install_functions('install_switcher')
                self.assertEqual(result.returncode, 0, result.stderr)
                current = set((share / 'install-backups').glob('zz.*'))
                added = current - previous
                self.assertEqual(len(added), 1)
                backup = added.pop() / 'zz'
                if link_target is None:
                    self.assertEqual(backup.read_bytes(), foreign.read_bytes())
                    self.assertEqual(backup.stat().st_mode & 0o777, 0o755)
                else:
                    self.assertTrue(backup.is_symlink())
                    self.assertEqual(os.readlink(backup), link_target)
                self.assertEqual(os.readlink(binary), str(share / 'zz.sh'))
                result = self.install_functions('install_switcher')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(set((share / 'install-backups').glob('zz.*')), current)

    def test_custom_install_directories_with_spaces_and_uninstall(self):
        share = self.home / 'custom share'
        binaries = self.home / 'custom bin'
        env = dict(self.env, AI_SWITCH_SHARE_DIR=str(share), AI_SWITCH_BIN_DIR=str(binaries))
        result = subprocess.run(['bash', str(REPO / 'install.sh'), '--switcher-only'],
                                env=env, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((share / 'tmux.conf').read_bytes(), (REPO / 'tmux.conf').read_bytes())
        self.assertEqual((share / 'tmux.conf').stat().st_mode & 0o777, 0o600)
        self.assertEqual((share / 'zz.sh').stat().st_mode & 0o777, 0o700)
        result = subprocess.run(['bash', '-c', 'source "$HOME/.bashrc"; codex-switch start --help'],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('zz reload', result.stdout)
        result = subprocess.run(['bash', str(REPO / 'uninstall.sh')],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ('zz', 'codex-switch', 'ai-switch'):
            self.assertFalse((binaries / name).is_symlink())
        self.assertFalse((share / 'zz.sh').exists())
        self.assertFalse((share / 'tmux.conf').exists())
        self.assertTrue((self.home / '.codex/config.toml').exists())


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
        self.assertEqual(self.tmux('show-options', '-gv', 'status').strip(), 'on')
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

    def test_status_bar_mouse_click_selects_window(self):
        client, pid = self.start('work')
        first = self.tmux('list-windows', '-t', '=work', '-f', '#{window_active}',
                          '-F', '#{window_id}').strip()
        self.tmux('rename-window', '-t', first, 'first')
        self.tmux('set-window-option', '-t', first, 'automatic-rename', 'off')
        second = self.tmux('new-window', '-d', '-t', '=work', '-n', 'second',
                           '-P', '-F', '#{window_id}', 'sleep 60').strip()
        self.assertIn('select-window -t =', self.tmux('list-keys', '-T', 'root', 'MouseDown1Status'))
        self.assertEqual(self.tmux('show-options', '-gv', 'mouse').strip(), 'on')
        # Wait for the status bar before clicking its labels on terminal row 30.
        wait_for(lambda: b'1 second' in client.output)
        client.send(b'\x1b[<0;22;30M\x1b[<0;22;30m')
        wait_for(lambda: self.tmux('list-windows', '-t', '=work', '-f', '#{window_active}',
                                   '-F', '#{window_id}').strip() == second)
        # Keep the return click separate from tmux's double-click gesture.
        time.sleep(0.5)
        client.send(b'\x1b[<0;13;30M\x1b[<0;13;30m')
        wait_for(lambda: self.tmux('list-windows', '-t', '=work', '-f', '#{window_active}',
                                   '-F', '#{window_id}').strip() == first)
        os.kill(int(pid), 0)
        self.assertEqual(self.launches(), [pid])
        self.detach(client)

    def test_upgrade_and_repeated_reload_keep_the_running_task(self):
        client, pid = self.start('work')
        self.tmux('set-option', '-g', 'status', 'off')
        result = subprocess.run(['bash', str(REPO / 'install.sh'), '--switcher-only'],
                                env=self.env, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.tmux('show-options', '-gv', 'status').strip(), 'off')
        binary = self.home / '.local/bin/zz'
        features = []
        for _ in range(3):
            result = subprocess.run([str(binary), 'reload'], env=self.env,
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.tmux('show-options', '-gv', 'status').strip(), 'on')
            self.assertEqual(self.tmux('show-options', '-gv', 'status-right').strip(), '')
            self.assertIn('bg=#008000,fg=#ffffff,bold',
                          self.tmux('show-window-options', '-gv', 'window-status-current-style'))
            if self.tmux('display-message', '-p', '#{>=:#{version},3.2}').strip() == '1':
                features.append(self.tmux('show-options', '-s', 'terminal-features'))
        if features:
            self.assertEqual(len(set(features)), 1)
            self.assertEqual(features[-1].count('xterm*:RGB'), 1)
        os.kill(int(pid), 0)
        self.assertEqual(self.launches(), [pid])
        self.assertIn('历史 000 中文', self.tmux('capture-pane', '-p', '-S', '-'))
        client.send('热加载成功'.encode())
        keys = self.home / ('keys-' + pid)
        wait_for(lambda: '热加载成功'.encode() in keys.read_bytes())
        self.detach(client)

    def test_reload_without_server_does_not_start_tasks(self):
        result = subprocess.run(['bash', str(REPO / 'zz.sh'), 'reload'], env=self.env,
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('下次 zz', result.stdout)
        self.assertEqual(self.launches(), [])
        result = subprocess.run([TMUX, '-L', self.socket, '-N', 'list-sessions'],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)

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
