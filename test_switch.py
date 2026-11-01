"""Offline regression tests: no real credentials or external model requests."""
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import tomllib
import unittest

REPO = Path(__file__).resolve().parent


class SwitchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.env = {k: v for k, v in os.environ.items() if k not in ('OPENAI_API_KEY', 'CODEX_SWITCH_API_KEY', 'CODEX_PROFILE', 'CODEX_SWITCH_PROFILE', 'CODEX_SWITCH_TOKEN_FILE')}
        self.env.update(CODEX_HOME=str(self.home), CODEX_SWITCH_TOKEN='offline-test-token', CODEX_SWITCH_MODEL='test-model', CODEX_SWITCH_BASE_URL='http://127.0.0.1:9/v1')
        self.original = 'model = "original"\nmodel_provider = "openai"\n# keep this comment\n[projects."/example"]\ntrust_level = "trusted"\n[mcp_servers.demo]\ncommand = "example"\n'
        (self.home / 'config.toml').write_text(self.original)

    def switch(self, *args, ok=True):
        result = subprocess.run(['bash', str(REPO / 'codex-switch.sh'), *args], env=self.env, capture_output=True, text=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def config(self):
        return tomllib.loads((self.home / 'config.toml').read_text())

    def test_switch_restore_and_preserve(self):
        self.switch('add', 'one')
        self.switch('use', 'one')
        data = self.config()
        provider = data['model_providers'][data['model_provider']]
        self.assertFalse(provider['requires_openai_auth'])
        self.assertEqual(provider['experimental_bearer_token'], 'offline-test-token')
        self.assertNotIn('env_key', provider)
        self.assertEqual(data['mcp_servers']['demo']['command'], 'example')
        self.assertIn('# keep this comment', (self.home / 'config.toml').read_text())
        self.assertEqual((self.home / 'config.toml').stat().st_mode & 0o777, 0o600)
        self.assertFalse((self.home / 'auth.json').exists())
        self.env['CODEX_SWITCH_TOKEN'] = 'second-test-token'
        self.switch('add', 'two')
        self.switch('use', 'two')
        self.switch('use', 'one')
        self.switch('remove', 'one')
        self.assertEqual(self.config(), tomllib.loads(self.original))
        self.assertFalse((self.home / 'current-profile').exists())

    def test_missing_secret_does_not_activate(self):
        self.switch('add', 'one')
        (self.home / 'profile-secrets/one.env').unlink()
        self.switch('use', 'one', ok=False)
        self.assertEqual((self.home / 'config.toml').read_text(), self.original)
        self.assertFalse((self.home / 'current-profile').exists())

    def test_legacy_profile_and_update(self):
        self.switch('add', 'one')
        path = self.home / 'one.config.toml'
        path.write_text(path.read_text().replace('env_key = "OPENAI_API_KEY"', 'env_key = "CODEX_SWITCH_API_KEY"'))
        self.switch('use', 'one')
        self.env['CODEX_SWITCH_TOKEN'] = 'updated-token'
        self.switch('add', 'one')
        self.assertEqual(self.config()['model_providers']['codex_switch_active']['experimental_bearer_token'], 'updated-token')

    def test_install_then_use_without_sourcing(self):
        env = dict(self.env, HOME=str(self.home), AI_SWITCH_RAW_BASE=REPO.as_uri(), AI_SWITCH_SHARE_DIR=str(self.home / '.local/share/ai-switch'), AI_SWITCH_BIN_DIR=str(self.home / '.local/bin'))
        # Run the real installation step, excluding package/Node installation.
        result = subprocess.run(['bash', '-c', 'source <(sed \'$d\' "$1/install.sh"); install_switcher', 'test', str(REPO)], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        binary = self.home / '.local/bin/codex-switch'
        for args in [('add', 'installed'), ('use', 'installed')]:
            result = subprocess.run([str(binary), *args], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.config()['model_provider'], 'codex_switch_active')
        self.assertTrue((self.home / '.local/share/ai-switch/config-manager.py').exists())

    def test_invalid_config_unchanged(self):
        (self.home / 'config.toml').write_text('model = [broken TOML\n')
        self.switch('add', 'one')
        self.switch('use', 'one', ok=False)
        self.assertEqual((self.home / 'config.toml').read_text(), 'model = [broken TOML\n')
        self.assertFalse((self.home / 'current-profile').exists())

    def test_plain_codex_http_auth(self):
        codex = os.environ.get('CODEX_TEST_BINARY') or shutil.which('codex')
        if not codex:
            self.skipTest('codex binary unavailable')
        received = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                received.append((self.path, self.headers.get('Authorization'), body.get('model')))
                response = {'id': 'resp_offline', 'object': 'response', 'status': 'completed', 'output': [{'id': 'msg_offline', 'type': 'message', 'status': 'completed', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'OFFLINE_OK', 'annotations': []}]}], 'usage': {'input_tokens': 1, 'output_tokens': 1, 'total_tokens': 2}}
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.end_headers()
                item = response['output'][0]
                events = [
                    {'type': 'response.created', 'response': {'id': 'resp_offline', 'status': 'in_progress', 'output': []}},
                    {'type': 'response.output_item.added', 'output_index': 0, 'item': dict(item, content=[])},
                    {'type': 'response.output_text.delta', 'item_id': 'msg_offline', 'output_index': 0, 'content_index': 0, 'delta': 'OFFLINE_OK'},
                    {'type': 'response.output_item.done', 'output_index': 0, 'item': item},
                    {'type': 'response.completed', 'response': response},
                ]
                for event in events:
                    self.wfile.write(('event: ' + event['type'] + '\ndata: ' + json.dumps(event) + '\n\n').encode())

            def log_message(self, *args):
                pass

        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.env['CODEX_SWITCH_BASE_URL'] = f'http://127.0.0.1:{server.server_port}/v1'
        self.switch('add', 'direct')
        self.switch('use', 'direct')
        # Brand-new process: no source, alias, --profile, auth.json or API-key env.
        env = {k: v for k, v in self.env.items() if not k.startswith('CODEX_SWITCH_')}
        result = subprocess.run([codex, 'exec', '--skip-git-repo-check', '-C', str(self.home), 'Say OFFLINE_OK'], env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=35)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(received, result.stderr)
        self.assertEqual(received[-1], ('/v1/responses', 'Bearer offline-test-token', 'test-model'))
        self.assertIn('OFFLINE_OK', result.stdout)


if __name__ == '__main__':
    unittest.main()
