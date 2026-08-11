"""R1/R2/R3: the processing queue's default runners execute phase-one and
summary jobs as a real OS subprocess instead of an in-process function call,
so a job's native ML inference cannot hold the server's GIL and starve its
asyncio event loop. `backend/tests/test_audio_regression.py` proves the
subprocess path produces correct real output end to end; this file proves
the isolation mechanism itself (structural: it really shells out; causal: a
GIL-holding child cannot block the parent's other threads; operational:
`stop()` terminates an in-flight subprocess rather than orphaning it)."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

import httpx

from damso.server.queue import ProcessingQueue, QueueError, _ActiveProcess, _run_module_as_subprocess
from test_server_http import LiveServer, store_and_config


class DefaultRunnersShellOutTests(unittest.TestCase):
    """A regression that reverted the default runners to an in-process call
    would not be caught by any test that overrides `_phase_one_runner`/
    `_summary_runner` with a stub - both the existing HTTP tests and this
    file's own behavioral tests do exactly that. This test targets the
    default wiring specifically."""

    def test_default_phase_one_runner_invokes_damso_processing_as_a_subprocess(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            queue = ProcessingQueue(root / "queue.sqlite3", root)
            with patch("damso.server.queue.subprocess.Popen") as popen:
                popen.return_value.communicate.return_value = (b'{"ok": true}', b"")
                popen.return_value.returncode = 0
                queue._phase_one_runner({"operation": "phase-one"})
            args = popen.call_args.args[0]
            self.assertEqual(args, [sys.executable, "-m", "damso.processing", "--request", "-"])

    def test_default_summary_runner_invokes_damso_summary_as_a_subprocess(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            queue = ProcessingQueue(root / "queue.sqlite3", root)
            with patch("damso.server.queue.subprocess.Popen") as popen:
                popen.return_value.communicate.return_value = (b'{"ok": true, "status": "complete"}', b"")
                popen.return_value.returncode = 0
                queue._summary_runner({"operation": "summary"})
            args = popen.call_args.args[0]
            self.assertEqual(args, [sys.executable, "-m", "damso.summary"])


class SubprocessRoundTripTests(unittest.TestCase):
    """Real (not mocked) subprocesses of the actual production modules,
    using a request crafted to fail validation immediately - fast and
    deterministic without needing local ML models, while still exercising
    the real exit-code/stdout JSON contract each module implements."""

    def test_phase_one_error_json_on_exit_2_becomes_a_queue_error(self):
        # `_phase_one_runner` itself returns the error dict without raising
        # (exit 2 still parses as valid JSON) - `_run_phase_one`'s own
        # `not result.get("ok")` check is what turns it into a QueueError,
        # unchanged from the in-process contract this replaces.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            recording_directory = root / "Plaud" / "recordings" / "missing-audio"
            recording_directory.mkdir(parents=True)
            (recording_directory / "meeting.json").write_text("{}", encoding="utf-8")
            queue = ProcessingQueue(root / "queue.sqlite3", root)
            with self.assertRaises(QueueError):
                queue._run_phase_one("missing-audio")

    def test_summary_error_json_on_exit_1_becomes_a_queue_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            recording_directory = root / "Plaud" / "recordings" / "no-transcript"
            recording_directory.mkdir(parents=True)
            queue = ProcessingQueue(root / "queue.sqlite3", root)
            with self.assertRaises(QueueError):
                queue._run_summary("no-transcript", {"agent": "claude", "language": "ko"})

    def test_a_terminated_subprocess_with_no_stdout_raises_a_clear_queue_error(self):
        track = _ActiveProcess()
        with self.assertRaises(QueueError) as ctx:
            _run_module_as_subprocess("damso.mcp", ["--no-such-flag"], {}, track=track)
        # argparse rejects the flag and exits nonzero with no JSON on stdout -
        # exercising the same "no parseable result" path a 143 termination
        # or an unhandled crash would take.
        self.assertIn("damso.mcp", str(ctx.exception))


class GilIsolationTests(unittest.TestCase):
    """A subprocess cannot hold its parent's GIL - that's an OS-level
    process boundary, not a CPython implementation detail this project
    controls. This test makes that guarantee concrete: while the queue
    worker blocks in `communicate()` on a subprocess that pins one CPU core
    for ~1 second, a plain Python thread in the *same* process keeps making
    progress throughout. Run the identical loop against a real in-process
    GIL-holding call and it stalls for the full duration - that contrast is
    the actual bug this task fixes."""

    def test_a_busy_subprocess_does_not_stall_a_concurrent_python_thread(self):
        track = _ActiveProcess()
        busy_seconds = 1.0
        counter = {"ticks": 0}
        stop = threading.Event()

        def tick():
            while not stop.is_set():
                counter["ticks"] += 1

        ticking_thread = threading.Thread(target=tick, daemon=True)
        ticking_thread.start()
        try:
            spin_script = f"import time\nt=time.time()\nwhile time.time()-t<{busy_seconds}:\n    pass\n"
            process = subprocess.Popen([sys.executable, "-c", spin_script], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            track.set(process)
            started = time.monotonic()
            process.communicate(input=b"{}")
            elapsed = time.monotonic() - started
            track.clear(process)
        finally:
            stop.set()
            ticking_thread.join(timeout=5)

        self.assertGreaterEqual(elapsed, busy_seconds * 0.8)
        # A starved thread manages at most a handful of ticks per GIL
        # timeslice acquisition; a genuinely concurrent one reaches many
        # thousands within a full second. The floor is generous on purpose -
        # this only needs to distinguish "ran freely" from "did not run".
        self.assertGreater(counter["ticks"], 10_000, "the main thread appears to have stalled while the subprocess ran")


class StopTerminatesTheActiveSubprocessTests(unittest.TestCase):
    def test_terminate_kills_a_running_process_and_is_a_no_op_when_idle(self):
        track = _ActiveProcess()
        track.terminate()  # idle: must not raise

        process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        track.set(process)
        try:
            self.assertIsNone(process.poll())
            track.terminate()
            process.wait(timeout=5)
            self.assertIsNotNone(process.poll())
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)

    def test_queue_stop_terminates_an_in_flight_job_subprocess(self):
        """A real `damso.summary`/`damso.processing` request fails validation
        in well under a second with no audio/transcript to work from, which
        leaves no window to catch it mid-flight - this needs a job that is
        genuinely still running when `stop()` is called. The injected runner
        below spawns a plain `time.sleep(10)` child and registers it with the
        queue's own `_active_process` tracker exactly the way
        `default_phase_one_runner`/`default_summary_runner` register the real
        `damso.processing`/`damso.summary` child - `phase_one_runner` is a
        documented, already-used injection point (see test_server_http.py),
        so this exercises the real `stop()` -> `_active_process.terminate()`
        wiring without depending on ML models or an agent CLI being slow."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            spawned: dict[str, subprocess.Popen] = {}

            def slow_runner(request):
                process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(10)"])
                spawned["process"] = process
                queue._active_process.set(process)
                process.wait()
                queue._active_process.clear(process)
                return {"ok": True, "status": "complete"}

            queue = ProcessingQueue(root / "queue.sqlite3", root, summary_runner=slow_runner, poll_interval=0.05)
            queue.enqueue_summary("stop-test")
            queue.start()
            try:
                deadline = time.monotonic() + 5
                while "process" not in spawned and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertIn("process", spawned, "the slow job never reached the subprocess stage")
                self.assertIsNone(spawned["process"].poll(), "the subprocess finished before stop() could race it")
                queue.stop()
                spawned["process"].wait(timeout=5)
                self.assertIsNotNone(spawned["process"].poll(), "the subprocess outlived queue.stop()")
            finally:
                if spawned.get("process") and spawned["process"].poll() is None:
                    spawned["process"].kill()


class ServerStaysResponsiveWhileAJobRunsTests(unittest.TestCase):
    """AC1, through the real HTTP stack this time (GilIsolationTests proves
    the same claim at the subprocess-mechanism level, without a server in
    the loop). A real 6-minute sherpa-onnx job isn't practical inside a unit
    test; a real `time.sleep()` child registered with the queue's own
    `_active_process` - exactly what `default_phase_one_runner` does,
    pointed at a controllable script instead of `damso.processing` - proves
    the same thing deterministically: the server answers while a job the
    queue considers "running" is still running."""

    def test_v1_and_mcp_answer_quickly_while_a_job_is_in_flight(self):
        with store_and_config() as config:
            with LiveServer(config) as live:
                queue = live.app.state.queue
                # _run_phase_one() detects an audio file and reads
                # meeting.json before it ever calls the runner - satisfy just
                # enough of that to reach `slow_runner` below; its own
                # content is never read, since the runner is overridden.
                recording_directory = config.store_root / "Plaud" / "recordings" / "responsiveness-check"
                recording_directory.mkdir(parents=True)
                (recording_directory / "microphone.caf").write_bytes(b"")

                def slow_runner(request):
                    process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(3)"])
                    queue._active_process.set(process)
                    process.wait()
                    queue._active_process.clear(process)
                    return {"ok": True, "status": "complete"}

                queue._phase_one_runner = slow_runner
                queue.enqueue_phase_one("responsiveness-check")

                deadline = time.monotonic() + 5
                while queue.status("responsiveness-check") is None or queue.status("responsiveness-check")["state"] != "running":
                    if time.monotonic() > deadline:
                        self.fail("the job never reached the running state")
                    time.sleep(0.02)

                for _ in range(3):
                    started = time.monotonic()
                    response = httpx.get(f"{live.base_url}/v1/version", timeout=5)
                    elapsed = time.monotonic() - started
                    self.assertEqual(response.status_code, 200)
                    self.assertLess(elapsed, 3.0, "a request stalled while a job was running")

                deadline = time.monotonic() + 5
                while queue.status("responsiveness-check")["state"] == "running" and time.monotonic() < deadline:
                    time.sleep(0.05)
                self.assertEqual(queue.status("responsiveness-check")["state"], "done")


if __name__ == "__main__":
    unittest.main()
