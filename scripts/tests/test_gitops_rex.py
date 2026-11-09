#!/usr/bin/env python3
"""Exercise Rex-only pulls and reload retries without host or stack mutations."""
import os
from pathlib import Path
import subprocess
import tempfile

SCRIPT = Path(__file__).resolve().parents[1] / 'gitops-sync.sh'


def run(*args, cwd, env=None, check=True):
    return subprocess.run(args, cwd=cwd, env=env, check=check,
                          text=True, capture_output=True)


with tempfile.TemporaryDirectory(prefix='gitops-rex-test-') as tmp:
    root = Path(tmp)
    remote = root / 'remote'
    remote.mkdir()
    run('git', 'init', '-b', 'main', cwd=remote)
    run('git', 'config', 'user.name', 'Test', cwd=remote)
    run('git', 'config', 'user.email', 'test@example.invalid', cwd=remote)
    run('git', 'config', 'commit.gpgsign', 'false', cwd=remote)
    scripts = remote / 'scripts'
    scripts.mkdir()
    # Isolate global failure markers and lock from any real host sync.
    source = SCRIPT.read_text().replace('/tmp/gitops-sync', str(root / 'sync'))
    (scripts / 'gitops-sync.sh').write_text(source)
    secrets = scripts / 'sync-secrets.sh'
    secrets.write_text('#!/bin/sh\nexit 99\n')
    secrets.chmod(0o755)
    configs = remote / 'coreos/os-configs'
    configs.mkdir(parents=True)
    target = root / 'installed-rex'
    unrelated = root / 'unrelated'
    (configs / 'manifest.conf').write_text(
        f'rex.service {target} 0644 rex\n'
        f'sysctl.conf {unrelated} 0644 sysctl\n')
    (configs / 'rex.service').write_text('old Rex unit\n')
    (configs / 'sysctl.conf').write_text('do not deploy\n')
    run('git', 'add', '.', cwd=remote)
    run('git', 'commit', '-m', 'initial', cwd=remote)
    checkout = root / 'checkout'
    run('git', 'clone', str(remote), str(checkout), cwd=root)
    run('git', 'update-ref', 'refs/gitops-sync/applied', 'HEAD', cwd=checkout)
    (configs / 'rex.service').write_text('new Rex unit\n')
    (configs / 'sysctl.conf').write_text('still do not deploy\n')
    run('git', 'commit', '-am', 'update configurations', cwd=remote)
    bin_dir = root / 'bin'
    bin_dir.mkdir()
    calls = root / 'calls'
    fail = root / 'fail-reload'
    sudo = bin_dir / 'sudo'
    sudo.write_text(f'''#!/usr/bin/env python3
import pathlib, shutil, sys
args = sys.argv[1:]
with open({str(calls)!r}, 'a') as log:
    log.write(' '.join(args) + '\\n')
if args[0] == 'install':
    shutil.copyfile(args[-2], args[-1])
elif args == ['/usr/local/sbin/rex-install.sh']:
    if pathlib.Path({str(fail)!r}).exists():
        sys.exit(1)
else:
    sys.exit('Unexpected host action: ' + repr(args))
''')
    sudo.chmod(0o755)
    hostname = bin_dir / 'hostname'
    hostname.write_text('#!/bin/sh\necho powder\n')
    hostname.chmod(0o755)
    env = os.environ | {'PATH': f'{bin_dir}:' + os.environ['PATH'],
                        'GITOPS_REPO_DIR': str(checkout), 'GITOPS_REX_ONLY': '1'}
    fail.touch()
    first = run('bash', str(checkout / 'scripts/gitops-sync.sh'),
                cwd=checkout, env=env, check=False)
    assert first.returncode == 1, first.stdout + first.stderr
    assert target.read_text() == 'new Rex unit\n'
    assert not unrelated.exists()
    fail.unlink()
    second = run('bash', str(checkout / 'scripts/gitops-sync.sh'),
                 cwd=checkout, env=env)
    applied = run('git', 'rev-parse', 'refs/gitops-sync/applied', cwd=checkout).stdout
    head = run('git', 'rev-parse', 'HEAD', cwd=checkout).stdout
    assert applied == head
    assert calls.read_text().count('/usr/local/sbin/rex-install.sh') == 2
    assert not unrelated.exists()
    assert not (checkout / 'docker/powder').exists()
    print('PASS: stackless Powder pulls Rex changes, skips unrelated configs, '
          'and retries failed reloads before advancing the applied ref')
