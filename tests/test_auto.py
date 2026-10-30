"""Sandboxed command mocks; no router, network, or real credentials required."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'TS_client_install_auto.sh'
SH = os.environ.get('TEST_SH', 'sh')


class AutoTests(unittest.TestCase):
    def run_case(self, mode='success', key='tskey-auth-TEST_ONLY_123'):
        with tempfile.TemporaryDirectory(prefix='ts-auto-', dir=SOURCE.parent) as directory:
            root = Path(directory)
            shell_root = root.as_posix()
            if os.name == 'nt':
                shell_root = '/' + shell_root[0].lower() + shell_root[2:]
            for name in ('etc/init.d', 'etc/config', 'etc/tailscale', 'etc/hotplug.d/iface', 'tmp', 'bin', 'proc'):
                (root / name).mkdir(parents=True, exist_ok=True)
            (root / 'etc/openwrt_release').touch()
            (root / 'etc/tailscale/tailscaled.state').write_text('test-state')
            (root / 'input').write_text(key + '\n')
            (root / 'proc/mounts').write_text(f'tmpfs {shell_root}/tmp tmpfs rw 0 0\n')
            init = root / 'etc/init.d/tailscale'
            init.write_text('#!/bin/sh\n# test service\nif false; then\n  procd_append_param command --state "$state_file"\nfi\nexit 0\n')
            init.chmod(0o755)
            scripts = {
                'id': 'echo 0',
                'sleep': 'exit 0',
                'timeout': 'shift; exec "$@"',
                'stty': '[ "$1" != -g ] || echo saved',
                'pidof': 'echo 123',
                'wget': 'exit 99',
                'sha256sum': 'exit 99',
                'tailscaled': 'exit 0',
                'jsonfilter': '''case "$*" in
*BackendState*) if [ -f "$TEST_ROOT/authorized" ] || [ "$MODE" = running ]; then echo Running; else echo NeedsLogin; fi ;;
*ControlURL*) if [ "$MODE" = foreign ]; then echo https://example.invalid; else echo https://login.tailscale.com; fi ;;
esac''',
                'tailscale': '''case "$1" in
version) [ "$MODE" != version_fail ] ;;
status) [ "$MODE" != daemon_fail ] && echo '{}' ;;
debug) echo '{}' ;;
set) exit 0 ;;
up)
  for arg do
    case "$arg" in
      --auth-key=file:*) file=${arg#--auth-key=file:} ;;
      *tskey-*) exit 88 ;;
    esac
  done
  [ -s "$file" ] || exit 89
  [ "$(cat "$file")" = "$EXPECTED_KEY" ] || exit 90
  [ "$(ls -ld "$(dirname "$file")" | cut -c2-10)" = rwx------ ] || exit 91
  [ "$(ls -l "$file" | cut -c2-10)" = rw------- ] || exit 92
  if [ "$MODE" = auth_fail ]; then cat "$file" >&2; exit 1; fi
  touch "$TEST_ROOT/authorized" ;;
ip) if [ "$MODE" = bad_ip ]; then echo 192.168.1.1; else echo 100.90.80.70; fi ;;
esac''',
            }
            for name, body in scripts.items():
                file = root / 'bin' / name
                file.write_text('#!/bin/sh\n' + body + '\n')
                file.chmod(0o755)
            text = SOURCE.read_text(encoding='utf-8')
            text = text.replace('PATH=/usr/sbin:/usr/bin:/sbin:/bin', f'PATH="{shell_root}/bin:/usr/bin:/bin:$PATH"')
            for prefix in ('/etc/', '/tmp/', '/proc/'):
                text = text.replace(prefix, shell_root + prefix)
            text = text.replace('$2 == "/tmp"', f'$2 == "{shell_root}/tmp"')
            # Simulate the terminal only; production still uses the controlling TTY.
            text = text.replace('exec 3<>/dev/tty', f'exec 3>"{shell_root}/terminal" 4<"{shell_root}/input"')
            text = text.replace('read -r key <&3', 'read -r key <&4')
            script = root / 'test.sh'
            script.write_text(text, encoding='utf-8', newline='\n')
            env = dict(os.environ, MODE=mode, TEST_ROOT=shell_root, EXPECTED_KEY=key, NO_COLOR='1')
            result = subprocess.run([SH, str(script)], env=env, capture_output=True, timeout=30)
            output = (result.stdout + result.stderr).decode('utf-8', errors='replace')
            if key:
                self.assertNotIn(key, output)
            self.assertFalse(list((root / 'tmp').glob('TS_client_install_auto*')), output)
            self.assertIn('КОНЕЦ', output)
            return result.returncode, output

    def test_authentication(self):
        rc, output = self.run_case()
        self.assertEqual(rc, 0, output)
        self.assertIn('100.90.80.70', output)

    def test_running_without_key(self):
        rc, output = self.run_case('running', '')
        self.assertEqual(rc, 0, output)

    def test_failures_are_private_and_cleaned(self):
        for mode in ('foreign', 'auth_fail', 'version_fail', 'daemon_fail', 'bad_ip'):
            with self.subTest(mode=mode):
                rc, output = self.run_case(mode)
                self.assertNotEqual(rc, 0, output)

    def test_invalid_key(self):
        rc, output = self.run_case(key='invalid_key')
        self.assertNotEqual(rc, 0, output)


if __name__ == '__main__':
    unittest.main()
