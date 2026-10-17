#!/usr/bin/env bash
# Exercise the real Bash dispatcher without reading live credentials or APIs.
set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "${SCRIPT_DIR}" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
names = {'claude', 'codex', 'qwen', 'grok', 'kimi', 'cursor', 'agy',
         'opencode', 'cyberstrike', 'hermes', 'openclaw', 'gh'}
passed = 0
with tempfile.TemporaryDirectory(prefix='kimo-quota-smoke-') as temp:
    directory = Path(temp)
    binary_dir = directory / 'bin'
    binary_dir.mkdir()
    config = directory / 'config'
    config.write_text('')
    calls = directory / 'calls'
    stub = '#!/bin/sh\nprintf "%s\\n" "$0" >> "$KIMO_QUOTA_TEST_CALLS"\nexit 1\n'
    for name in names | {'cursor-agent', 'agent', 'curl', 'bl'}:
        path = binary_dir / name
        path.write_text(stub)
        path.chmod(0o755)
    # Do not inherit account keys, proxies, project settings, or provider config.
    # HOME is the harness's throwaway home: without it kimo falls back to /root.
    env = {'PATH': str(binary_dir) + ':' + os.environ['PATH'], 'HOME': os.environ['HOME'],
           'KIMO_CONFIG_FILE': str(config),
           'KIMO_NO_AUTOSCAN': '1', 'KIMO_ENFORCE_PATH': '0', 'KIMO_QUOTA_HOME': temp,
           'XDG_CONFIG_HOME': temp, 'KIMO_QUOTA_TEST_CALLS': str(calls), 'NO_COLOR': '1'}

    def run(*arguments):
        return subprocess.run([str(root / 'kimo'), *arguments], env=env,
                              capture_output=True, text=True, timeout=10)

    def check(condition, message):
        global passed
        if not condition:
            raise AssertionError(message)
        passed += 1
        print('  [pass] ' + message)

    def dashboard(*arguments):
        result = run(*arguments, '--offline', '--json')
        check(result.returncode == 0, 'command succeeds: ' + ' '.join(arguments))
        return json.loads(result.stdout)

    for alias in ('quota', 'quotas', 'quote'):
        result = run(alias, '--help')
        check(result.returncode == 0 and 'kimo quota' in result.stdout, alias + ' help')
    data = dashboard('quota')
    check(set(data['clis']) == names, 'every supported CLI appears')
    check(set(data['providers']) == {'ollama', 'gemini', 'freetier', 'openrouter', 'web'}, 'existing providers preserved')
    check(all(row['installed'] and row['status'] == 'offline' for row in data['clis'].values()), 'offline installation detection')
    for name in sorted(names):
        data = dashboard('quota', name)
        check(set(data['clis']) == {name} and not data['providers'], 'CLI selection: ' + name)
    data = dashboard('quotas', '--cli', 'all')
    check(set(data['clis']) == names and not data['providers'], '--cli all filters to CLIs')
    data = dashboard('quota', 'kimi', '--no-refresh')
    check(set(data['clis']) == {'kimi'} and data['clis']['kimi']['status'] == 'offline', '--no-refresh passes through dispatcher')
    data = dashboard('quota', 'claude', '--no-refresh')
    check(set(data['clis']) == {'claude'} and data['clis']['claude']['status'] == 'offline', '--no-refresh works for Claude selection')
    data = dashboard('quota', '--provider', 'ollama')
    check(set(data['providers']) == {'ollama'} and not data['clis'], 'provider filter preserved')
    data = dashboard('--remote', 'quota')
    check(set(data['clis']) == names, '--remote --offline remains offline')
    data = dashboard('--host', 'http://127.0.0.1:12345', 'quota', '--model', 'pro')
    check(set(data['clis']) == names, '--host and model filtering')
    for options in (('--provider', 'invalid'), ('--cli', 'invalid'), ('--timeout', '0'),
                    ('--timeout', 'nan'), ('--timeout', '61'), ('--cli',), ('--unknown',),
                    ('--provider', 'ollama', '--cli', 'codex')):
        result = run('quota', '--offline', *options)
        check(result.returncode != 0 and 'Traceback' not in result.stderr, 'invalid arguments rejected: ' + ' '.join(options))
    result = run('quota', '--offline')
    check('UNIFIED QUOTA & USAGE DASHBOARD' in result.stdout and '\x1b' not in result.stdout, 'plain text dashboard')
    check(not calls.exists(), 'offline and help run no curl or native CLI commands')
print(f'Quota smoke tests: {passed} passed')
PY
