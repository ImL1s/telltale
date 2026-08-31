import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


HERE = Path(__file__).resolve().parent
HELPER = HERE / "adb_state_guard.sh"


FAKE_ADB = r"""#!/bin/zsh -f
print -r -- "$*" >> "$FAKE_ADB_LOG"
[[ "$1" == -s && "$2" == "$FAKE_SERIAL" ]] || exit 90
shift 2
case "$1" in
  get-state)
    if [[ -e "$FAKE_REMOVED" && -n ${FAKE_POST_UNINSTALL_STATE_RC:-} ]]; then
      print -rn -- "${FAKE_POST_UNINSTALL_STATE_OUTPUT-}"
      exit "$FAKE_POST_UNINSTALL_STATE_RC"
    fi
    print -r -- "${FAKE_STATE_OUTPUT:-device}"
    exit ${FAKE_STATE_RC:-0}
    ;;
  uninstall)
    print -r -- "${FAKE_UNINSTALL_OUTPUT:-Success}"
    if [[ ${FAKE_UNINSTALL_RC:-0} == 0 && ${FAKE_UNINSTALL_OUTPUT:-Success} == Success ]]; then
      : > "$FAKE_REMOVED"
    fi
    exit ${FAKE_UNINSTALL_RC:-0}
    ;;
  shell)
    shift
    if [[ "$1" == *'__TELLTALE_PSS_SAMPLE_V1_BEGIN__'* ]]; then
      if [[ -n ${FAKE_PSS_TRANSPORT_RC:-} ]]; then
        print -u2 -- "${FAKE_PSS_TRANSPORT_ERROR:-device not found}"
        exit "$FAKE_PSS_TRANSPORT_RC"
      fi
      if [[ ${FAKE_PSS_EXECUTE_COMMAND:-0} == 1 ]]; then
        PATH="${FAKE_REMOTE_PATH:-$FAKE_REMOTE_BIN:/usr/bin:/bin}" /bin/sh -c "$1"
        exit $?
      fi
      print -r -- '__TELLTALE_PSS_SAMPLE_V1_BEGIN__'
      print -r -- "start_rc=${FAKE_PSS_START_RC:-0}"
      print -r -- "start_ns=${FAKE_PSS_START_NS:-1700000000000000000}"
      print -r -- "pid_rc=${FAKE_PSS_PID_RC:-0}"
      print -r -- "pid=${FAKE_PSS_PID-123}"
      print -r -- "meminfo_rc=${FAKE_PSS_MEMINFO_RC:-0}"
      print -r -- "pss_count=${FAKE_PSS_COUNT:-1}"
      print -r -- "pss_kb=${FAKE_PSS_KB-54321}"
      print -r -- "end_rc=${FAKE_PSS_END_RC:-0}"
      print -r -- "end_ns=${FAKE_PSS_END_NS:-1700000000500000000}"
      print -r -- '__TELLTALE_PSS_SAMPLE_V1_END__'
      exit 0
    fi
    if [[ "$1" == pidof\ *'; remote_rc=$?;'* ]]; then
      if [[ -n ${FAKE_PID_TRANSPORT_RC:-} ]]; then
        print -u2 -- "${FAKE_PID_TRANSPORT_ERROR:-device not found}"
        exit "$FAKE_PID_TRANSPORT_RC"
      fi
      package=${${1#pidof }%%;*}
      if [[ "$package" == "$FAKE_RIG" ]]; then
        if [[ -e "$FAKE_REMOVED" ]]; then
          pid_output=
          pid_rc=1
        elif [[ -e "$FAKE_STOPPED" ]]; then
          pid_output=${FAKE_POST_FORCE_PID_OUTPUT-}
          pid_rc=${FAKE_POST_FORCE_PID_RC:-1}
        else
          pid_output=${FAKE_RIG_PID_OUTPUT-}
          pid_rc=${FAKE_RIG_PID_RC:-1}
        fi
      elif [[ "$package" == "$FAKE_FIELD" ]]; then
        pid_output=${FAKE_FIELD_PID_OUTPUT:-222}
        pid_rc=${FAKE_FIELD_PID_RC:-0}
      else
        exit 81
      fi
      print -rn -- "$pid_output"
      printf '\n__TELLTALE_PIDOF_RC__=%s\n' "$pid_rc"
      exit 0
    fi
    if [[ "$1" == pm\ path\ *'; remote_rc=$?;'* ]]; then
      if [[ -n ${FAKE_PM_TRANSPORT_RC:-} ]]; then
        print -u2 -- "${FAKE_PM_TRANSPORT_ERROR:-error: device not found}"
        exit "$FAKE_PM_TRANSPORT_RC"
      fi
      package=${${1#pm path }%% *}
      if [[ "$package" == "$FAKE_RIG" ]]; then
        if [[ -e "$FAKE_REMOVED" ]]; then
          path_output=
          path_error=
          path_rc=1
        else
          path_output=${FAKE_RIG_PATH_OUTPUT-package:/data/app/rig/base.apk}
          path_error=${FAKE_RIG_PATH_ERROR-}
          path_rc=${FAKE_RIG_PATH_RC:-0}
        fi
      elif [[ "$package" == "$FAKE_FIELD" ]]; then
        path_output=${FAKE_FIELD_PATH_OUTPUT:-package:/data/app/field/base.apk}
        path_error=${FAKE_FIELD_PATH_ERROR-}
        path_rc=${FAKE_FIELD_PATH_RC:-0}
      else
        exit 81
      fi
      print -rn -- "$path_output"
      print -rn -- "$path_error"
      printf '\n__TELLTALE_PM_PATH_RC__=%s\n' "$path_rc"
      exit 0
    fi
    case "$1 $2" in
      "pidof $FAKE_RIG")
        [[ -e "$FAKE_REMOVED" ]] && exit 1
        if [[ -e "$FAKE_STOPPED" ]]; then
          print -rn -- "${FAKE_POST_FORCE_PID_OUTPUT-}"
          exit ${FAKE_POST_FORCE_PID_RC:-1}
        fi
        print -rn -- "${FAKE_RIG_PID_OUTPUT-}"
        exit ${FAKE_RIG_PID_RC:-1}
        ;;
      "pidof $FAKE_FIELD")
        print -rn -- "${FAKE_FIELD_PID_OUTPUT:-222}"
        exit ${FAKE_FIELD_PID_RC:-0}
        ;;
      "pm path")
        if [[ "$3" == "$FAKE_RIG" ]]; then
          [[ -e "$FAKE_REMOVED" ]] && exit 0
          print -rn -- "${FAKE_RIG_PATH_OUTPUT-package:/data/app/rig/base.apk}"
          exit ${FAKE_RIG_PATH_RC:-0}
        fi
        print -rn -- "${FAKE_FIELD_PATH_OUTPUT:-package:/data/app/field/base.apk}"
        exit ${FAKE_FIELD_PATH_RC:-0}
        ;;
      "settings get")
        key=$4
        case "$key" in
          font_scale) print -r -- "${FAKE_FONT_SCALE:-1.0}" ;;
          accelerometer_rotation) print -r -- "${FAKE_ACCELEROMETER_ROTATION:-1}" ;;
          user_rotation) print -r -- "${FAKE_USER_ROTATION:-0}" ;;
          *) exit 80 ;;
        esac
        exit ${FAKE_SETTINGS_RC:-0}
        ;;
      "am force-stop")
        print -rn -- "${FAKE_FORCE_OUTPUT-}"
        if [[ ${FAKE_FORCE_RC:-0} == 0 ]]; then
          export FAKE_RIG_PID_RC=1
          export FAKE_RIG_PID_OUTPUT=
          print -r -- stopped > "$FAKE_STOPPED"
        fi
        exit ${FAKE_FORCE_RC:-0}
        ;;
    esac
    exit 79
    ;;
esac
exit 78
"""


class AdbStateGuardTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=HERE)
        self.root = Path(self.temporary.name)
        self.adb = self.root / "adb"
        self.adb.write_text(FAKE_ADB, encoding="utf-8")
        self.adb.chmod(0o700)
        self.remote_bin = self.root / "remote-bin"
        self.remote_bin.mkdir()
        (self.remote_bin / "date").write_text(
            "#!/bin/sh\n"
            'count=$(cat "$FAKE_REMOTE_DATE_COUNT" 2>/dev/null || printf 0)\n'
            'if [ "$count" -eq 0 ]; then printf "%s\\n" "$FAKE_PSS_START_NS"; '
            'else printf "%s\\n" "$FAKE_PSS_END_NS"; fi\n'
            'printf "%s\\n" "$((count + 1))" > "$FAKE_REMOTE_DATE_COUNT"\n',
            encoding="utf-8",
        )
        (self.remote_bin / "pidof").write_text(
            "#!/bin/sh\n"
            'printf "%s" "${FAKE_PSS_PID-123}"\n'
            'exit "${FAKE_PSS_PID_RC:-0}"\n',
            encoding="utf-8",
        )
        (self.remote_bin / "dumpsys").write_text(
            "#!/bin/sh\n"
            'cat "$FAKE_MEMINFO_FIXTURE"\n'
            'exit "${FAKE_PSS_MEMINFO_RC:-0}"\n',
            encoding="utf-8",
        )
        (self.remote_bin / "cat").write_text(
            '#!/bin/sh\nexec /bin/cat "$@"\n',
            encoding="utf-8",
        )
        (self.remote_bin / "sed").write_text(
            '#!/bin/sh\nexec /usr/bin/sed "$@"\n',
            encoding="utf-8",
        )
        for executable in self.remote_bin.iterdir():
            executable.chmod(0o700)
        self.env = os.environ.copy()
        self.env.update(
            {
                "ADB": str(self.adb),
                "SERIAL": "serial-1",
                "PACKAGE": "rig.package",
                "FIELD_PACKAGE": "field.package",
                "FAKE_SERIAL": "serial-1",
                "FAKE_RIG": "rig.package",
                "FAKE_FIELD": "field.package",
                "FAKE_ADB_LOG": str(self.root / "adb.log"),
                "FAKE_REMOVED": str(self.root / "removed"),
                "FAKE_STOPPED": str(self.root / "stopped"),
                "FAKE_REMOTE_BIN": str(self.remote_bin),
                "FAKE_REMOTE_DATE_COUNT": str(self.root / "date-count"),
                "FAKE_PSS_START_NS": "1700000000000000000",
                "FAKE_PSS_END_NS": "1700000000500000000",
            }
        )

    def tearDown(self):
        self.temporary.cleanup()

    def run_zsh(self, body, **overrides):
        env = self.env | {key: str(value) for key, value in overrides.items()}
        script = f'source "{HELPER}"\n' + textwrap.dedent(body)
        return subprocess.run(
            ["/bin/zsh", "-f", "-c", script],
            env=env,
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )

    def test_online_requires_rc_zero_and_exact_device(self):
        self.assertEqual(self.run_zsh("gate_c_adb_require_online").returncode, 0)
        for overrides in (
            {"FAKE_STATE_RC": 1, "FAKE_STATE_OUTPUT": ""},
            {"FAKE_STATE_RC": 1, "FAKE_STATE_OUTPUT": "device"},
            {"FAKE_STATE_OUTPUT": "offline"},
            {"FAKE_STATE_OUTPUT": "device\nextra"},
        ):
            with self.subTest(overrides=overrides):
                self.assertNotEqual(
                    self.run_zsh("gate_c_adb_require_online", **overrides).returncode,
                    0,
                )

    def test_shell_capture_preserves_transport_failure(self):
        result = self.run_zsh(
            "gate_c_adb_shell_capture settings get system font_scale",
            FAKE_SETTINGS_RC=27,
            FAKE_FONT_SCALE="",
        )
        self.assertEqual(result.returncode, 27)

    def test_pidof_accepts_only_rc_one_blank_or_numeric_success(self):
        blank = self.run_zsh(
            "gate_c_adb_optional_pidof rig.package",
            FAKE_RIG_PID_RC=1,
            FAKE_RIG_PID_OUTPUT="",
        )
        self.assertEqual(blank.returncode, 0)
        self.assertEqual(blank.stdout, "")
        numeric = self.run_zsh(
            "gate_c_adb_optional_pidof rig.package",
            FAKE_RIG_PID_RC=0,
            FAKE_RIG_PID_OUTPUT="123 456",
        )
        self.assertEqual(numeric.returncode, 0)
        self.assertEqual(numeric.stdout, "123 456\n")
        for overrides in (
            {"FAKE_RIG_PID_RC": 1, "FAKE_RIG_PID_OUTPUT": "123"},
            {"FAKE_RIG_PID_RC": 0, "FAKE_RIG_PID_OUTPUT": ""},
            {"FAKE_RIG_PID_RC": 0, "FAKE_RIG_PID_OUTPUT": "abc"},
            {"FAKE_RIG_PID_RC": 2, "FAKE_RIG_PID_OUTPUT": ""},
            {
                "FAKE_PID_TRANSPORT_RC": 1,
                "FAKE_PID_TRANSPORT_ERROR": "error: device not found",
            },
            {"FAKE_STATE_RC": 1, "FAKE_STATE_OUTPUT": ""},
        ):
            with self.subTest(overrides=overrides):
                self.assertNotEqual(
                    self.run_zsh(
                        "gate_c_adb_optional_pidof rig.package", **overrides
                    ).returncode,
                    0,
                )

    def test_required_single_pid_rejects_absent_or_multiple_processes(self):
        single = self.run_zsh(
            "gate_c_adb_required_single_pid rig.package",
            FAKE_RIG_PID_RC=0,
            FAKE_RIG_PID_OUTPUT="123",
        )
        self.assertEqual(single.returncode, 0, single.stderr)
        self.assertEqual(single.stdout, "123\n")
        for overrides in (
            {"FAKE_RIG_PID_RC": 1, "FAKE_RIG_PID_OUTPUT": ""},
            {"FAKE_RIG_PID_RC": 0, "FAKE_RIG_PID_OUTPUT": "123 456"},
            {"FAKE_PID_TRANSPORT_RC": 1},
        ):
            with self.subTest(overrides=overrides):
                self.assertNotEqual(
                    self.run_zsh(
                        "gate_c_adb_required_single_pid rig.package", **overrides
                    ).returncode,
                    0,
                )

    def test_total_pss_sample_uses_one_fresh_state_and_one_shell_transaction(self):
        result = self.run_zsh("gate_c_adb_total_pss_sample rig.package")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout,
            "1700000000000000\t1700000000500000\t123\t54321\n",
        )
        log = (self.root / "adb.log").read_text(encoding="utf-8")
        self.assertEqual(log.count("-s serial-1 get-state\n"), 1)
        self.assertEqual(log.count("-s serial-1 shell "), 1)
        self.assertIn("__TELLTALE_PSS_SAMPLE_V1_BEGIN__", log)

    def test_total_pss_sample_executes_remote_parser_on_standard_meminfo(self):
        fixture = self.root / "meminfo.txt"
        fixture.write_text(
            """Applications Memory Usage (in Kilobytes):
Uptime: 123 Realtime: 456

                   Pss  Private  Private  SwapPss      Rss     Heap     Heap     Heap
                 Total    Dirty    Clean    Dirty    Total     Size    Alloc     Free
                ------   ------   ------   ------   ------   ------   ------   ------
  Native Heap     1000      900        0        0     1100     2048     1024     1024
        TOTAL     54321    40000     1000       12    60000     4096     2048     2048

 App Summary
                       Pss(KB)                        Rss(KB)
                        ------                         ------
           TOTAL PSS:    54321              TOTAL RSS:    60000       TOTAL SWAP PSS:       12
""",
            encoding="utf-8",
        )
        result = self.run_zsh(
            "gate_c_adb_total_pss_sample rig.package 123",
            FAKE_PSS_EXECUTE_COMMAND=1,
            FAKE_MEMINFO_FIXTURE=fixture,
            FAKE_PSS_PID=123,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout,
            "1700000000000000\t1700000000500000\t123\t54321\n",
        )

    def test_total_pss_sample_remote_parser_does_not_require_awk(self):
        fixture = self.root / "meminfo-no-awk.txt"
        fixture.write_text(
            "        TOTAL     54321    40000     1000\n"
            "           TOTAL PSS:    54321              TOTAL RSS:    60000\n",
            encoding="utf-8",
        )
        result = self.run_zsh(
            "gate_c_adb_total_pss_sample rig.package 123",
            FAKE_PSS_EXECUTE_COMMAND=1,
            FAKE_MEMINFO_FIXTURE=fixture,
            FAKE_PSS_PID=123,
            FAKE_REMOTE_PATH=self.remote_bin,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout,
            "1700000000000000\t1700000000500000\t123\t54321\n",
        )

    def test_total_pss_sample_remote_parser_requires_matching_totals(self):
        fixture = self.root / "meminfo-mismatch.txt"
        fixture.write_text(
            "        TOTAL     54320    40000     1000\n"
            "           TOTAL PSS:    54321              TOTAL RSS:    60000\n",
            encoding="utf-8",
        )
        result = self.run_zsh(
            "gate_c_adb_total_pss_sample rig.package 123",
            FAKE_PSS_EXECUTE_COMMAND=1,
            FAKE_MEMINFO_FIXTURE=fixture,
            FAKE_PSS_PID=123,
        )
        self.assertNotEqual(result.returncode, 0)

    def test_total_pss_sample_remote_parser_accepts_each_canonical_layout(self):
        for name, contents in (
            ("summary", "           TOTAL PSS:    54321   TOTAL RSS: 60000\n"),
            ("table", "        TOTAL     54321    40000     1000\n"),
        ):
            with self.subTest(layout=name):
                fixture = self.root / f"meminfo-{name}.txt"
                fixture.write_text(contents, encoding="utf-8")
                (self.root / "date-count").unlink(missing_ok=True)
                result = self.run_zsh(
                    "gate_c_adb_total_pss_sample rig.package 123",
                    FAKE_PSS_EXECUTE_COMMAND=1,
                    FAKE_MEMINFO_FIXTURE=fixture,
                    FAKE_PSS_PID=123,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(result.stdout.endswith("\t123\t54321\n"))

    def test_total_pss_sample_accepts_only_canonical_absence(self):
        absent = self.run_zsh(
            "gate_c_adb_total_pss_sample rig.package",
            FAKE_PSS_PID_RC=1,
            FAKE_PSS_PID="",
            FAKE_PSS_MEMINFO_RC=125,
            FAKE_PSS_COUNT=0,
            FAKE_PSS_KB="",
        )
        self.assertEqual(absent.returncode, 0, absent.stderr)
        self.assertEqual(absent.stdout, "")

        bound_absent = self.run_zsh(
            "gate_c_adb_total_pss_sample rig.package 123",
            FAKE_PSS_PID_RC=1,
            FAKE_PSS_PID="",
            FAKE_PSS_MEMINFO_RC=125,
            FAKE_PSS_COUNT=0,
            FAKE_PSS_KB="",
        )
        self.assertNotEqual(bound_absent.returncode, 0)

        for overrides in (
            {
                "FAKE_PSS_PID_RC": 1,
                "FAKE_PSS_PID": 123,
                "FAKE_PSS_MEMINFO_RC": 125,
                "FAKE_PSS_COUNT": 0,
                "FAKE_PSS_KB": "",
            },
            {
                "FAKE_PSS_PID_RC": 1,
                "FAKE_PSS_PID": "",
                "FAKE_PSS_MEMINFO_RC": 0,
                "FAKE_PSS_COUNT": 0,
                "FAKE_PSS_KB": "",
            },
        ):
            with self.subTest(overrides=overrides):
                self.assertNotEqual(
                    self.run_zsh(
                        "gate_c_adb_total_pss_sample rig.package", **overrides
                    ).returncode,
                    0,
                )

    def test_total_pss_sample_rejects_pid_instability_and_multiple_processes(self):
        changed = self.run_zsh(
            "gate_c_adb_total_pss_sample rig.package 122",
            FAKE_PSS_PID=123,
        )
        self.assertNotEqual(changed.returncode, 0)
        multiple = self.run_zsh(
            "gate_c_adb_total_pss_sample rig.package",
            FAKE_PSS_PID="123 456",
        )
        self.assertNotEqual(multiple.returncode, 0)

    def test_total_pss_sample_preserves_transport_and_remote_failures(self):
        transport = self.run_zsh(
            "gate_c_adb_total_pss_sample rig.package",
            FAKE_PSS_TRANSPORT_RC=27,
        )
        self.assertEqual(transport.returncode, 27)
        for overrides in (
            {"FAKE_STATE_RC": 29, "FAKE_STATE_OUTPUT": ""},
            {"FAKE_PSS_START_RC": 3},
            {"FAKE_PSS_MEMINFO_RC": 4},
            {"FAKE_PSS_END_RC": 5},
        ):
            with self.subTest(overrides=overrides):
                self.assertNotEqual(
                    self.run_zsh(
                        "gate_c_adb_total_pss_sample rig.package", **overrides
                    ).returncode,
                    0,
                )

    def test_total_pss_sample_rejects_invalid_timing_or_pss(self):
        for overrides in (
            {"FAKE_PSS_START_NS": "not-a-time"},
            {
                "FAKE_PSS_START_NS": 1700000001000000000,
                "FAKE_PSS_END_NS": 1700000000000000000,
            },
            {
                "FAKE_PSS_START_NS": 1700000000000000000,
                "FAKE_PSS_END_NS": 1700000001000000001,
            },
            {"FAKE_PSS_COUNT": 0, "FAKE_PSS_KB": ""},
            {"FAKE_PSS_COUNT": 2},
            {"FAKE_PSS_KB": "not-pss"},
            {"FAKE_PSS_KB": 0},
        ):
            with self.subTest(overrides=overrides):
                self.assertNotEqual(
                    self.run_zsh(
                        "gate_c_adb_total_pss_sample rig.package", **overrides
                    ).returncode,
                    0,
                )

    def test_pm_path_is_checked_and_canonical(self):
        result = self.run_zsh(
            "gate_c_adb_pm_path_capture rig.package",
            FAKE_RIG_PATH_OUTPUT="package:/z.apk\npackage:/a.apk",
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "package:/a.apk;package:/z.apk\n")
        for overrides in (
            {"FAKE_RIG_PATH_RC": 7, "FAKE_RIG_PATH_OUTPUT": ""},
            {"FAKE_RIG_PATH_OUTPUT": ""},
            {"FAKE_RIG_PATH_OUTPUT": "Error: unknown package"},
            {"FAKE_STATE_RC": 1, "FAKE_RIG_PATH_OUTPUT": ""},
        ):
            with self.subTest(overrides=overrides):
                self.assertNotEqual(
                    self.run_zsh(
                        "gate_c_adb_pm_path_capture rig.package", **overrides
                    ).returncode,
                    0,
                )

    def test_optional_pm_path_accepts_only_remote_absent_status_with_blank_output(self):
        absent = self.run_zsh(
            "gate_c_adb_optional_pm_path rig.package",
            FAKE_RIG_PATH_RC=1,
            FAKE_RIG_PATH_OUTPUT="",
        )
        self.assertEqual(absent.returncode, 0, absent.stderr)
        self.assertEqual(absent.stdout, "")

        for command, overrides in (
            (
                "gate_c_adb_pm_path_capture rig.package",
                {"FAKE_RIG_PATH_RC": 1, "FAKE_RIG_PATH_OUTPUT": ""},
            ),
            (
                "gate_c_adb_optional_pm_path rig.package",
                {"FAKE_RIG_PATH_RC": 0, "FAKE_RIG_PATH_OUTPUT": ""},
            ),
            (
                "gate_c_adb_optional_pm_path rig.package",
                {"FAKE_RIG_PATH_RC": 1, "FAKE_RIG_PATH_OUTPUT": "unexpected"},
            ),
        ):
            with self.subTest(command=command, overrides=overrides):
                self.assertNotEqual(
                    self.run_zsh(command, **overrides).returncode,
                    0,
                )

    def test_optional_pm_path_rejects_remote_stderr_and_transport_failure(self):
        remote_error = self.run_zsh(
            "gate_c_adb_optional_pm_path rig.package",
            FAKE_RIG_PATH_RC=1,
            FAKE_RIG_PATH_OUTPUT="",
            FAKE_RIG_PATH_ERROR="Error: package manager unavailable",
        )
        self.assertNotEqual(remote_error.returncode, 0)

        transport_error = self.run_zsh(
            "gate_c_adb_optional_pm_path rig.package",
            FAKE_PM_TRANSPORT_RC=27,
            FAKE_PM_TRANSPORT_ERROR="error: device not found",
        )
        self.assertEqual(transport_error.returncode, 27)
        self.assertIn("error: device not found", transport_error.stderr)

    def test_settings_reject_failed_or_invalid_values(self):
        valid = self.run_zsh("gate_c_adb_settings_capture")
        self.assertEqual(valid.returncode, 0)
        self.assertIn("font_scale=1.0", valid.stdout)
        for overrides in (
            {"FAKE_SETTINGS_RC": 9},
            {"FAKE_FONT_SCALE": "null"},
            {"FAKE_ACCELEROMETER_ROTATION": 2},
            {"FAKE_USER_ROTATION": 4},
        ):
            with self.subTest(overrides=overrides):
                self.assertNotEqual(
                    self.run_zsh("gate_c_adb_settings_capture", **overrides).returncode,
                    0,
                )

    def test_snapshot_is_atomic_and_has_no_false_success(self):
        target = self.root / "snapshot.txt"
        result = self.run_zsh(f'gate_c_adb_snapshot "{target}"')
        self.assertEqual(result.returncode, 0, result.stderr)
        contents = target.read_text(encoding="utf-8")
        self.assertIn("rig_path=package:/data/app/rig/base.apk", contents)
        self.assertIn("field_pid=222", contents)
        self.assertFalse(list(self.root.glob("snapshot.txt.tmp.*")))

        failed = self.root / "failed.txt"
        result = self.run_zsh(f'gate_c_adb_snapshot "{failed}"', FAKE_FIELD_PATH_RC=17)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(failed.exists())
        self.assertFalse(list(self.root.glob("failed.txt.tmp.*")))

    def test_remove_installed_live_package_checks_every_transition(self):
        target = self.root / "removed.txt"
        result = self.run_zsh(
            f'gate_c_adb_remove_rig_package "{target}"',
            FAKE_RIG_PID_RC=0,
            FAKE_RIG_PID_OUTPUT=123,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("force_stop=success", target.read_text(encoding="utf-8"))
        self.assertIn("uninstall=success", target.read_text(encoding="utf-8"))
        log = (self.root / "adb.log").read_text(encoding="utf-8")
        self.assertIn("shell am force-stop rig.package", log)
        self.assertIn("uninstall rig.package", log)

    def test_remove_not_installed_does_not_mutate(self):
        target = self.root / "absent.txt"
        result = self.run_zsh(
            f'gate_c_adb_remove_rig_package "{target}"',
            FAKE_RIG_PATH_OUTPUT="",
            FAKE_RIG_PATH_RC=1,
            FAKE_RIG_PID_RC=1,
            FAKE_RIG_PID_OUTPUT="",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        contents = target.read_text(encoding="utf-8")
        self.assertIn("force_stop=not-needed", contents)
        self.assertIn("uninstall=not-needed", contents)
        log = (self.root / "adb.log").read_text(encoding="utf-8")
        self.assertNotIn("force-stop", log)
        self.assertNotIn("uninstall", log)

    def test_remove_failure_never_writes_success_evidence(self):
        cases = (
            {"FAKE_RIG_PID_RC": 0, "FAKE_RIG_PID_OUTPUT": 123, "FAKE_FORCE_RC": 8},
            {"FAKE_UNINSTALL_RC": 8, "FAKE_UNINSTALL_OUTPUT": "Failure"},
            {"FAKE_UNINSTALL_OUTPUT": "Success\nextra"},
            {"FAKE_STATE_RC": 1, "FAKE_STATE_OUTPUT": ""},
            {
                "FAKE_POST_UNINSTALL_STATE_RC": 31,
                "FAKE_POST_UNINSTALL_STATE_OUTPUT": "",
            },
            {
                "FAKE_RIG_PID_RC": 0,
                "FAKE_RIG_PID_OUTPUT": 123,
                "FAKE_POST_FORCE_PID_RC": 32,
                "FAKE_POST_FORCE_PID_OUTPUT": "",
            },
        )
        for index, overrides in enumerate(cases):
            target = self.root / f"failed-remove-{index}.txt"
            with self.subTest(overrides=overrides):
                (self.root / "removed").unlink(missing_ok=True)
                (self.root / "stopped").unlink(missing_ok=True)
                result = self.run_zsh(
                    f'gate_c_adb_remove_rig_package "{target}"', **overrides
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(target.exists())
                self.assertFalse(list(self.root.glob(f"{target.name}.tmp.*")))


if __name__ == "__main__":
    unittest.main()
