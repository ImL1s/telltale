from __future__ import annotations

import argparse
import importlib.util
import os
from pathlib import Path
import signal
import sys
import tempfile
import unittest
from unittest import mock


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "test_target_guarded_command",
    HERE / "guarded_command.py",
)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("could not load guarded command")
GUARDED = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = GUARDED
SPEC.loader.exec_module(GUARDED)


class GuardedCommandTest(unittest.TestCase):
    def _run(
        self,
        *,
        guard_exit: bool = False,
        contain_error: bool = False,
        interrupt_after_launch: bool = False,
    ):
        temporary = tempfile.TemporaryDirectory(prefix="guarded-command.")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name).resolve()
        authority_path = root / "authority.json"
        authority_path.write_text("{}\n", encoding="utf-8")
        scope_path = root / "scope.json"
        args = argparse.Namespace(
            guard_pid=900,
            guard_ready=root / "ready.json",
            guard_result=root / "guard-result.json",
            guard_nonce="a" * 32,
            log=root / "command.log",
            result=root / "result.json",
            label="guarded",
            cwd=root,
            term_ms=100,
            kill_ms=100,
            scope_authority=authority_path,
            scope_reference_authority=[root / "reference.json"],
            scope_evidence=scope_path,
            scope_owner_root_pid=os.getppid(),
            scope_wrapper=root / "wrapper.zsh",
            scope_wrapper_sha256="b" * 64,
            scope_freeze_ms=100,
            scope_term_ms=100,
            scope_kill_ms=100,
            command=["unused"],
        )
        queue = mock.Mock()
        queue.control.side_effect = [[object()]] if guard_exit else [[], []]
        child = mock.Mock(pid=321)
        authority = {"leader": {}, "supervisor": {}}
        scoped = mock.Mock()
        scoped.launch_authorized_child.return_value = (child, authority)
        scoped.observe_child_exit.return_value = None if guard_exit else 0
        events: list[str] = []
        scoped.reap_child.side_effect = lambda *_args, **_kwargs: (
            events.append("reap") or 0
        )
        scoped.contain_failure_reap.side_effect = lambda *_args, **_kwargs: (
            events.append("failure-reap") or 0
        )
        scope = {
            "status": "quiescent",
            "stoppedProcesses": [],
            "termSentProcesses": [],
            "killSentProcesses": [],
        }
        process_scope = mock.Mock()

        def contain(*_args, **_kwargs):
            events.append("contain")
            if contain_error:
                raise RuntimeError("contain failed")
            scope_path.write_text("{}\n", encoding="utf-8")
            return scope

        process_scope.contain_and_write.side_effect = contain
        descriptor = os.open(args.log, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        handlers = {}

        def install(signum, handler):
            if callable(handler):
                handlers[signum] = handler
            return signal.SIG_DFL

        def mask(how, _signals):
            if interrupt_after_launch and how == signal.SIG_SETMASK:
                handlers[signal.SIGTERM](signal.SIGTERM, None)
            return set()

        with (
            mock.patch.object(GUARDED, "parse_args", return_value=args),
            mock.patch.object(GUARDED, "validate_cwd", return_value=root),
            mock.patch.object(GUARDED, "validate_guard", return_value=queue),
            mock.patch.object(
                GUARDED, "require_new_owned_file", return_value=descriptor
            ),
            mock.patch.object(
                GUARDED, "load_scoped_command_helper", return_value=scoped
            ),
            mock.patch.object(
                GUARDED, "load_process_scope_helper", return_value=process_scope
            ),
            mock.patch.object(GUARDED, "write_result"),
            mock.patch.object(GUARDED.signal, "signal", side_effect=install),
            mock.patch.object(GUARDED.signal, "pthread_sigmask", side_effect=mask),
        ):
            exit_code = GUARDED.main()
        return exit_code, events, child, scoped, process_scope, args

    def test_natural_exit_is_observed_then_contained_before_single_reap(self):
        exit_code, events, child, scoped, process_scope, args = self._run()
        self.assertEqual(exit_code, 0)
        self.assertEqual(events, ["contain", "reap"])
        child.poll.assert_not_called()
        child.wait.assert_not_called()
        scoped.reap_child.assert_called_once()
        self.assertEqual(
            process_scope.contain_and_write.call_args.kwargs[
                "reference_authority_paths"
            ],
            args.scope_reference_authority,
        )

    def test_guard_exit_live_child_is_contained_before_single_reap(self):
        exit_code, events, child, scoped, _process_scope, _args = self._run(
            guard_exit=True
        )
        self.assertEqual(exit_code, 70)
        self.assertEqual(events, ["contain", "reap"])
        child.poll.assert_not_called()
        child.wait.assert_not_called()
        scoped.observe_child_exit.assert_called_once_with(child, nohang=True)

    def test_containment_error_uses_bounded_exact_failure_reap(self):
        exit_code, events, child, scoped, _process_scope, _args = self._run(
            contain_error=True
        )
        self.assertEqual(exit_code, 72)
        self.assertEqual(events, ["contain", "failure-reap"])
        child.poll.assert_not_called()
        child.wait.assert_not_called()
        scoped.reap_child.assert_not_called()
        scoped.contain_failure_reap.assert_called_once()

    def test_supervisor_signal_after_launch_contains_before_single_reap(self):
        exit_code, events, child, scoped, _process_scope, _args = self._run(
            interrupt_after_launch=True
        )
        self.assertEqual(exit_code, 128 + signal.SIGTERM)
        self.assertEqual(events, ["contain", "reap"])
        child.poll.assert_not_called()
        child.wait.assert_not_called()
        scoped.reap_child.assert_called_once()


if __name__ == "__main__":
    unittest.main()
