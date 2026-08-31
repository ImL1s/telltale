import os
import pathlib
import py_compile
import shutil
import subprocess
import sys
import tempfile
import unittest


HERE = pathlib.Path(__file__).resolve().parent


class PythonIsolationTest(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "darwin", "Darwin libproc is required")
    def test_darwin_kernel_runtime_can_be_invoked_as_exact_python_executable(self):
        probe = r"""
import ctypes
import json
import os
import pathlib
import sys

libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
libproc.proc_pidpath.restype = ctypes.c_int
buffer = ctypes.create_string_buffer(4096)
length = libproc.proc_pidpath(os.getpid(), buffer, len(buffer))
if length <= 0:
    raise OSError(ctypes.get_errno(), "proc_pidpath failed")
print(json.dumps({
    "runtime": os.fsdecode(buffer.value),
    "executable": str(pathlib.Path(sys.executable).resolve(strict=True)),
    "basePrefix": str(pathlib.Path(sys.base_prefix).resolve(strict=True)),
    "isolated": sys.flags.isolated,
    "noSite": sys.flags.no_site,
    "dontWriteBytecode": sys.flags.dont_write_bytecode,
}, sort_keys=True))
"""
        discovered = subprocess.run(
            [sys.executable, "-I", "-S", "-B", "-c", probe],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        self.assertEqual(discovered.returncode, 0, discovered.stderr)
        first = __import__("json").loads(discovered.stdout)
        runtime = pathlib.Path(first["runtime"]).resolve(strict=True)

        normalized = subprocess.run(
            [str(runtime), "-I", "-S", "-B", "-c", probe],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        self.assertEqual(normalized.returncode, 0, normalized.stderr)
        second = __import__("json").loads(normalized.stdout)
        self.assertEqual(second["runtime"], str(runtime))
        self.assertEqual(second["executable"], str(runtime))
        self.assertEqual(second["basePrefix"], first["basePrefix"])
        self.assertEqual(
            (second["isolated"], second["noSite"], second["dontWriteBytecode"]),
            (1, 1, 1),
        )

    def test_runner_normalizes_python_before_first_seal_or_guard(self):
        runner = (HERE / "run.sh").read_text(encoding="utf-8")

        discovery = runner.index("PYTHON_LAUNCHER_COMMAND=$(command -v python3")
        launcher = runner.index("PYTHON_LAUNCHER=${PYTHON_LAUNCHER_COMMAND:A}")
        runtime_probe = runner.index(
            'PYTHON_RUNTIME_COMMAND=$("$PYTHON_LAUNCHER" -I -S -B -',
        )
        proc_pidpath = runner.index("proc_pidpath(os.getpid()", runtime_probe)
        normalization = runner.index("PYTHON=${PYTHON_RUNTIME_COMMAND:A}")
        runtime_validation = runner.index(
            'PYTHON_RUNTIME_ROOT=$("$PYTHON" -I -S -B - "$PYTHON"',
        )
        executable_seal = runner.index("PYTHON_SHA256=", runtime_validation)
        evidence_seal = runner.index("python-executable.pre.sha256", executable_seal)
        first_guard = runner.index("source_tree_guard.py", evidence_seal)

        self.assertLess(discovery, launcher)
        self.assertLess(launcher, runtime_probe)
        self.assertLess(runtime_probe, proc_pidpath)
        self.assertLess(proc_pidpath, normalization)
        self.assertLess(normalization, runtime_validation)
        self.assertLess(runtime_validation, executable_seal)
        self.assertLess(executable_seal, evidence_seal)
        self.assertLess(evidence_seal, first_guard)
        validation = runner[runtime_validation:executable_seal]
        self.assertIn("pathlib.Path(sys.executable).resolve(strict=True)", validation)
        self.assertIn("proc_pidpath(os.getpid()", validation)
        self.assertIn("actual != expected or kernel != expected", validation)
        self.assertNotIn("samefile", validation)

    def test_isolated_python_ignores_cwd_module_shadow(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            marker = root / "poison-imported"
            (root / "json.py").write_text(
                f"from pathlib import Path\nPath({str(marker)!r}).touch()\n",
                encoding="utf-8",
            )

            completed = subprocess.run(
                [
                    sys.executable,
                    "-I",
                    "-S",
                    "-B",
                    "-c",
                    "import json; print(json.__file__)",
                ],
                cwd=root,
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertFalse(marker.exists())
            self.assertNotEqual(
                pathlib.Path(completed.stdout.strip()), root / "json.py"
            )

    def test_source_guard_ignores_helper_directory_module_shadow(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            helper = root / "helper"
            helper.mkdir()
            for name in ("source_tree_guard.py", "tree_manifest.py"):
                shutil.copy2(HERE / name, helper / name)
            marker = root / "poison-imported"
            for name in ("json.py", "pathlib.py"):
                (helper / name).write_text(
                    f"open({str(marker)!r}, 'w').close()\n"
                    "raise RuntimeError('poison module imported')\n",
                    encoding="utf-8",
                )

            completed = subprocess.run(
                [
                    sys.executable,
                    "-I",
                    "-S",
                    "-B",
                    str(helper / "source_tree_guard.py"),
                    "--help",
                ],
                cwd=root,
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("--expected-flutter-root", completed.stdout)
            self.assertFalse(marker.exists())
            self.assertFalse((helper / "__pycache__").exists())

    def test_source_guard_never_executes_timestamp_valid_stale_helper_bytecode(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            helper = root / "helper"
            helper.mkdir()
            shutil.copy2(HERE / "source_tree_guard.py", helper / "source_tree_guard.py")
            manifest = helper / "tree_manifest.py"
            marker = root / "stale-bytecode-executed"
            evil = (
                "import pathlib\n"
                f"pathlib.Path({str(marker)!r}).touch()\n"
                "EXCLUDED_DOCUMENTATION = set()\n"
            )
            good = "EXCLUDED_DOCUMENTATION = set()\n"
            good = good.rstrip("\n").ljust(len(evil) - 1) + "\n"
            self.assertEqual(len(good.encode()), len(evil.encode()))
            fixed_ns = 1_700_000_000_123_456_789
            manifest.write_text(evil, encoding="utf-8")
            os.utime(manifest, ns=(fixed_ns, fixed_ns))
            py_compile.compile(str(manifest), doraise=True)
            manifest.write_text(good, encoding="utf-8")
            os.utime(manifest, ns=(fixed_ns, fixed_ns))

            completed = subprocess.run(
                [
                    sys.executable,
                    "-I",
                    "-S",
                    "-B",
                    str(helper / "source_tree_guard.py"),
                    "--help",
                ],
                cwd=root,
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertFalse(marker.exists())

    def test_runner_never_invokes_unisolated_python(self):
        runner = (HERE / "run.sh").read_text(encoding="utf-8")
        bounded_reap = (HERE / "bounded_reap.sh").read_text(encoding="utf-8")

        self.assertNotIn("PYTHONPYCACHEPREFIX", runner)
        self.assertNotRegex(runner, r"(?m)^\s*python3(?:\s|$)")
        self.assertNotRegex(bounded_reap, r"(?m)^\s*python3(?:\s|$)")
        self.assertIn('"$PYTHON" -I -S -B', runner)
        self.assertIn('"$python" -I -S -B -c', bounded_reap)
        source_guard = (HERE / "source_tree_guard.py").read_text(encoding="utf-8")
        self.assertIn('compile(source_bytes, str(source), "exec"', source_guard)
        self.assertNotIn("spec_from_file_location", source_guard)


if __name__ == "__main__":
    unittest.main()
