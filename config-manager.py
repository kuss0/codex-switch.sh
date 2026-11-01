#!/usr/bin/env python3
"""Activate profiles for plain `codex`, preserving unrelated user settings."""
import copy
import json
import os
from pathlib import Path
import re
import sys
import tempfile

try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        sys.exit('Python 3.11+ or the python3-tomli package is required.')

PROVIDER = 'codex_switch_active'
BEGIN = '# >>> codex-switch provider >>>'
END = '# <<< codex-switch provider <<<'


def atomic_write(path, text):
    fd, tmp = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            f.write(text)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def selection(text, values):
    """Edit only simple root selection keys; semantic validation guards ambiguity."""
    lines = text.splitlines(keepends=True)
    in_root = True
    out = []
    for line in lines:
        if re.match(r'^\s*\[', line):
            in_root = False
        if in_root and re.match(r'^\s*(?:model|model_provider|"model"|"model_provider"|\'model\'|\'model_provider\')\s*=', line):
            continue
        out.append(line)
    header = ''.join(f'{key} = {json.dumps(value, ensure_ascii=False)}\n' for key, value in values.items())
    return header + ''.join(out)


def configure(home, name=None):
    config = home / 'config.toml'
    state_path = home / '.codex-switch-selection.json'
    old = config.read_text() if config.exists() else ''
    parsed = tomllib.loads(old)
    state = json.loads(state_path.read_text()) if state_path.exists() else None
    expected = copy.deepcopy(parsed)
    if old.count(BEGIN) != old.count(END) or old.count(BEGIN) > 1:
        raise ValueError('Malformed managed provider block; config unchanged.')
    has_block = BEGIN in old
    if has_block and state is None:
        raise ValueError('Missing original selection state; config unchanged.')
    if not has_block and PROVIDER in parsed.get('model_providers', {}):
        raise ValueError('Reserved provider already exists; config unchanged.')
    text = re.sub(r'(?m)^' + re.escape(BEGIN) + r'\n[\s\S]*?^' + re.escape(END) + r'\n?', '', old)
    if name is None:
        if state is None:
            return
        values = state['selection']
        expected.get('model_providers', {}).pop(PROVIDER, None)
        if not expected.get('model_providers'):
            expected.pop('model_providers', None)
    else:
        if not re.fullmatch(r'[A-Za-z0-9_-]+', name):
            raise ValueError('Invalid profile name')
        profile = tomllib.loads((home / (name + '.config.toml')).read_text())
        provider = copy.deepcopy(profile['model_providers'][profile['model_provider']])
        token = (home / 'profile-secrets' / (name + '.env')).read_text().splitlines()
        if len(token) != 1 or not token[0].strip() or token[0].startswith('export '):
            raise ValueError('Token must be one nonempty plain-text line. Re-run add.')
        for key in ('env_key', 'experimental_bearer_token', 'auth', 'gateway_oauth'):
            provider.pop(key, None)
        provider['requires_openai_auth'] = False
        provider['experimental_bearer_token'] = token[0]
        if provider.get('wire_api') != 'responses':
            raise ValueError('This version of Codex requires wire_api = "responses".')
        if state is None:
            state = {'selection': {k: parsed[k] for k in ('model', 'model_provider') if k in parsed}}
        values = {'model': profile['model'], 'model_provider': PROVIDER}
        expected.setdefault('model_providers', {})[PROVIDER] = provider
        block = [BEGIN, f'[model_providers.{PROVIDER}]']
        for key, value in provider.items():
            if not isinstance(value, (str, bool)):
                raise ValueError('Unsupported profile provider field: ' + key)
            block.append(f'{key} = {json.dumps(value, ensure_ascii=False)}')
        text = text.rstrip() + '\n\n' + '\n'.join(block) + '\n' + END + '\n'
    for key in ('model', 'model_provider'):
        expected.pop(key, None)
    expected.update(values)
    text = selection(text, values)
    if tomllib.loads(text) != expected:
        raise ValueError('Cannot safely edit this TOML layout; config unchanged.')
    if name is not None and not state_path.exists():
        atomic_write(state_path, json.dumps(state) + '\n')
        backup = home / 'config.toml.before-codex-switch'
        if not backup.exists():
            atomic_write(backup, old)
    atomic_write(config, text)
    if name is not None:
        atomic_write(home / 'current-profile', name + '\n')
    else:
        state_path.unlink()
        (home / 'current-profile').unlink(missing_ok=True)


if __name__ == '__main__':
    try:
        configure(Path(sys.argv[1]), sys.argv[2] if len(sys.argv) > 2 else None)
    except (OSError, ValueError, KeyError) as exc:
        # Avoid parser errors that might include configuration/token contents.
        print('Error: cannot update Codex config (' + type(exc).__name__ + '). Check profile, token and TOML layout.', file=sys.stderr)
        sys.exit(1)
