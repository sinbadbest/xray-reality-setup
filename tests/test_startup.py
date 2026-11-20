"""Run the installer's startup block with isolated command doubles.

No root access, network, package installation or real service changes are needed.
The ownership marker models the root configuration check and the xray service.
"""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
BASH = os.environ.get("XRAY_TEST_BASH") or shutil.which("bash")

HARNESS = r'''
set -euo pipefail
export MSYS_NO_PATHCONV=1
LOG_DIR="$PWD/log"
ERROR_LOG="$LOG_DIR/error.log"
CFG="$PWD/config.json"
tmp="$PWD/candidate.json"
XRAY=mock_xray
printf '{}\n' > "$tmp"
die() { echo "$*" >&2; exit 1; }
install() {
  if [[ "$1" == -d ]]; then
    command mkdir -p "${@: -1}"
  else
    command cp "${@: -2:1}" "${@: -1}"
  fi
}
chown() { printf '%s\n' "$1" > "${@: -1}.owner"; }
chmod() { printf '%s\n' "$1" > "${@: -1}.mode"; }
mock_xray() {
  if [[ "$CONFIG_INVALID" == 1 ]]; then
    echo 'invalid configuration' >&2
    return 1
  fi
  if [[ ! -e "$ERROR_LOG" ]]; then
    printf 'created during root config check\n' > "$ERROR_LOG"
    printf 'root:root\n' > "$ERROR_LOG.owner"
  fi
  printf 'Configuration OK.\n'
}
systemctl() {
  printf '%s\n' "$*" >> "$PWD/systemctl.calls"
  case "$1" in
    enable) return 0 ;;
    restart) [[ "$RESTART_FAIL" == 0 ]] ;;
    is-active)
      if [[ "$FORCE_INACTIVE" == 0 ]] &&
         [[ "$(cat "$ERROR_LOG.owner")" == xray:xray ]]; then
        echo active
      else
        echo failed
        return 3
      fi
      ;;
    status) echo 'MOCK_SERVICE_DIAGNOSTIC'; return 3 ;;
    *) echo "unexpected systemctl command: $*" >&2; return 1 ;;
  esac
}
journalctl() { echo 'MOCK_JOURNAL_DIAGNOSTIC'; }
sleep() { :; }
'''


@unittest.skipUnless(BASH, "bash is required")
class StartupTests(unittest.TestCase):
    def run_startup(self, owner=None, restart_fail=False, inactive=False,
                    invalid=False):
        source = (ROOT / "install.sh").read_text(encoding="utf-8")
        block = source.split("}' > \"$tmp\"\n", 1)[1].split(
            '\necho "== 5/7', 1
        )[0]
        # Redirect the production block's fixed log path into this sandbox.
        block = block.replace("/var/log/xray", "${LOG_DIR}")
        with tempfile.TemporaryDirectory(prefix="xray-startup-") as temp:
            work = Path(temp)
            log_dir = work / "log"
            log_dir.mkdir()
            log = log_dir / "error.log"
            if owner is not None:
                log.write_text("preserve existing log\n", encoding="utf-8")
                (log_dir / "error.log.owner").write_text(owner, encoding="utf-8")
            env = os.environ.copy()
            env.update(RESTART_FAIL=str(int(restart_fail)),
                       FORCE_INACTIVE=str(int(inactive)),
                       CONFIG_INVALID=str(int(invalid)))
            result = subprocess.run(
                [BASH, "--noprofile", "--norc", "-s"],
                input=HARNESS + "\n" + block,
                text=True, encoding="utf-8", capture_output=True,
                cwd=work, env=env, timeout=15,
            )
            def read(path):
                return path.read_text(encoding="utf-8") if path.exists() else ""
            return result, {
                "log": read(log),
                "owner": read(log_dir / "error.log.owner").strip(),
                "mode": read(log_dir / "error.log.mode").strip(),
                "calls": read(work / "systemctl.calls"),
            }

    def test_first_start_log_is_writable_by_service(self):
        result, files = self.run_startup()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(files["owner"], "xray:xray")
        self.assertEqual(files["mode"], "640")

    def test_repairs_root_owned_log_without_truncating_it(self):
        result, files = self.run_startup(owner="root:root")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(files["owner"], "xray:xray")
        self.assertEqual(files["log"], "preserve existing log\n")

    def test_repeat_run_preserves_existing_log(self):
        result, files = self.run_startup(owner="xray:xray")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(files["log"], "preserve existing log\n")

    def assert_startup_diagnostics(self, result):
        self.assertNotEqual(result.returncode, 0)
        output = result.stdout + result.stderr
        self.assertIn("MOCK_SERVICE_DIAGNOSTIC", output)
        self.assertIn("MOCK_JOURNAL_DIAGNOSTIC", output)
        self.assertIn("Xray", output)

    def test_restart_failure_prints_diagnostics(self):
        result, _ = self.run_startup(owner="xray:xray", restart_fail=True)
        self.assert_startup_diagnostics(result)

    def test_inactive_service_prints_diagnostics(self):
        result, _ = self.run_startup(owner="xray:xray", inactive=True)
        self.assert_startup_diagnostics(result)

    def test_invalid_config_never_restarts_service(self):
        result, files = self.run_startup(owner="xray:xray", invalid=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid configuration", result.stderr)
        self.assertNotIn("restart", files["calls"])


if __name__ == "__main__":
    unittest.main()
