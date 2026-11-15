"""Offline transaction tests: real filesystem and tar, mocked npm/systemd/HTTP."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MANAGER = ROOT / 'install/mcphub-manage.sh'
MOCKS = r'''
source "$MANAGER"
APP_DIR="$FIXTURE/app"
BACKUP_DIR="$FIXTURE/backups"
install_release() {
  echo "install $1" >>"$FIXTURE/events"
  [[ "$SCENARIO" != install-failure ]] || return 1
  printf '%s\n' "$APP_DIR/releases/new"
}
systemctl() {
  echo "systemctl $*" >>"$FIXTURE/events"
  if [[ "$1" == stop && "$SCENARIO" == stop-failure ]]; then return 1; fi
  if [[ "$1" == start && "$(readlink "$APP_DIR/current")" == */new ]]; then
    echo migrated >"$APP_DIR/data/marker"
    echo migrated >"$APP_DIR/home/marker"
    [[ "$SCENARIO" != start-failure ]] || return 1
  fi
}
wait_ready() {
  echo health >>"$FIXTURE/events"
  if [[ "$SCENARIO" == health-failure && "$(readlink "$APP_DIR/current")" == */new ]]; then return 1; fi
}
tar() {
  if [[ "$SCENARIO" == backup-failure && "$1" == -czf ]]; then return 1; fi
  command tar "$@"
}
update_app "$TARGET"
'''

class Transactions(unittest.TestCase):
    def run_case(self, scenario, target='1.2.5'):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            app = root / 'app'
            for name in ['data', 'home', 'releases/old', 'releases/new']:
                (app / name).mkdir(parents=True)
            for name in ['data', 'home']:
                (app / name / 'marker').write_text('original\n')
            (app / 'releases/old/version').write_text('1.2.4\n')
            (app / 'releases/new/version').write_text('1.2.5\n')
            (app / 'current').symlink_to(app / 'releases/old')
            for name in ['.env', 'manage.sh']:
                (app / name).write_text('fixture\n')
            env = dict(os.environ, MANAGER=str(MANAGER), FIXTURE=folder,
                       SCENARIO=scenario, TARGET=target)
            result = subprocess.run(['bash', '-c', MOCKS], env=env, text=True,
                                    capture_output=True, timeout=10)
            return (result, (app / 'current').resolve().name,
                    [(app / n / 'marker').read_text() for n in ['data', 'home']],
                    (root / 'events').read_text() if (root / 'events').exists() else '',
                    len(list((root / 'backups').glob('*.tar.gz'))))

    def test_update(self):
        r, release, markers, events, backups = self.run_case('success')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(release, 'new')
        self.assertEqual(markers, ['migrated\n'] * 2)
        self.assertEqual(backups, 1)
        self.assertIn('systemctl stop', events)

    def test_failed_start_and_health_restore_release_and_data(self):
        for scenario in ['start-failure', 'health-failure']:
            with self.subTest(scenario=scenario):
                r, release, markers, _, backups = self.run_case(scenario)
                self.assertNotEqual(r.returncode, 0)
                self.assertEqual(release, 'old')
                self.assertEqual(markers, ['original\n'] * 2)
                self.assertEqual(backups, 1)
                self.assertIn('Previous release and data restored', r.stderr)

    def test_package_failure_does_not_stop_service(self):
        r, release, markers, events, _ = self.run_case('install-failure')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(release, 'old')
        self.assertEqual(markers, ['original\n'] * 2)
        self.assertNotIn('systemctl stop', events)

    def test_backup_failure_restarts_original(self):
        r, release, markers, events, _ = self.run_case('backup-failure')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(release, 'old')
        self.assertEqual(markers, ['original\n'] * 2)
        self.assertIn('systemctl start', events)

    def test_same_version_does_not_stop_or_backup(self):
        r, _, markers, events, backups = self.run_case('success', target='1.2.4')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(markers, ['original\n'] * 2)
        self.assertNotIn('systemctl stop', events)
        self.assertNotIn('install ', events)
        self.assertEqual(backups, 0)

    def test_invalid_version_rejected_before_install(self):
        r, _, _, events, _ = self.run_case('success', target='other/package@latest')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(events, '')

    def test_stop_failure_attempts_restart_without_deploying(self):
        r, release, markers, events, _ = self.run_case('stop-failure')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(release, 'old')
        self.assertEqual(markers, ['original\n'] * 2)
        self.assertIn('systemctl start', events)

    def test_health_requires_active_service(self):
        script = 'source "$MANAGER"; systemctl() { return 1; }; curl() { return 0; }; sleep() { :; }; wait_ready'
        r = subprocess.run(['bash', '-c', script], env=dict(os.environ, MANAGER=str(MANAGER)), capture_output=True, timeout=5)
        self.assertNotEqual(r.returncode, 0)

    def test_health_accepts_active_service_and_http_success(self):
        script = 'source "$MANAGER"; systemctl() { return 0; }; curl() { return 0; }; wait_ready'
        r = subprocess.run(['bash', '-c', script], env=dict(os.environ, MANAGER=str(MANAGER)), capture_output=True, timeout=5)
        self.assertEqual(r.returncode, 0)

    def test_real_package_install_failure_is_not_swallowed(self):
        # Command substitution disables errexit inside install_release. Explicit
        # failure propagation must prevent a half-built release being selected.
        script = 'source "$MANAGER"; APP_DIR="$FIXTURE"; npm() { return 42; }; install_release 1.2.4'
        with tempfile.TemporaryDirectory() as folder:
            (Path(folder) / 'releases').mkdir()
            env = dict(os.environ, MANAGER=str(MANAGER), FIXTURE=folder)
            r = subprocess.run(['bash', '-c', 'release=$(' + script + '); exit $?'], env=env, capture_output=True)
            self.assertEqual(r.returncode, 42)

if __name__ == '__main__':
    unittest.main()
