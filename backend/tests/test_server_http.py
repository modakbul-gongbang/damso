"""Loopback runtime integration tests for the HTTP server (V3): a real
uvicorn process on a real socket, exercised over real HTTP - not FastAPI's
in-process TestClient - because R1/R2/D-08's token contract can only fail
the way a real client would see it (connection refused, 401) when there is
an actual socket in the loop. The server speaks plain HTTP only (ADR 0003);
transport privacy is the trusted private network's job.
"""

from __future__ import annotations

import contextlib
import io
import json
import socket
import tarfile
import tempfile
import threading
import time
import unittest
from pathlib import Path

import httpx
import uvicorn

from damso.server.app import create_app
from damso.server.config import ServerConfig
from damso.server.credentials import generate as generate_credentials


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class LiveServer:
    """Runs `create_app()` under real uvicorn in a background thread."""

    def __init__(self, config: ServerConfig):
        self.config = config
        self.app = create_app(config)
        self.app.state.queue._phase_one_runner = lambda request: {
            "ok": True,
            "recording_stem": Path(request["recording_directory"]).name,
        }
        self.app.state.queue._summary_runner = lambda request: {"ok": True, "status": "complete"}
        self._uvicorn_config = uvicorn.Config(self.app, host=config.host, port=config.port, log_level="warning")
        self.server = uvicorn.Server(self._uvicorn_config)
        self._thread = threading.Thread(target=self.server.run, daemon=True)

    def __enter__(self) -> "LiveServer":
        self._thread.start()
        deadline = time.time() + 10
        while not self.server.started and time.time() < deadline:
            time.sleep(0.05)
        if not self.server.started:
            raise RuntimeError("server did not start in time")
        return self

    def __exit__(self, *exc_info) -> None:
        self.server.should_exit = True
        self._thread.join(timeout=10)

    @property
    def base_url(self) -> str:
        return f"http://{self.config.host}:{self.config.port}"


def make_record_archive(stem: str, *, audio: bytes = b"FAKE-AUDIO-BYTES", apple_double_debris: bool = False) -> bytes:
    record = {
        "schemaVersion": 1,
        "stem": stem,
        "id": "x",
        "createdAt": "2026-08-10T00:00:00Z",
        "source": "local",
        "title": "t",
        "stage": "captured",
        "completedStages": [],
        "sensitive": False,
        "hints": {"participants": [], "domainTerms": []},
        "resolutions": [],
    }
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        data = json.dumps(record).encode()
        info = tarfile.TarInfo("meeting.json")
        info.size = len(data)
        tar.addfile(info, io.BytesIO(data))
        info2 = tarfile.TarInfo("microphone.caf")
        info2.size = len(audio)
        tar.addfile(info2, io.BytesIO(audio))
        if apple_double_debris:
            # What macOS archivers actually smuggle in: AppleDouble
            # resource-fork sidecars and Finder metadata.
            for name in ("._meeting.json", "._microphone.caf", "._system-audio.m4a", ".DS_Store"):
                debris = tarfile.TarInfo(name)
                debris.size = 4
                tar.addfile(debris, io.BytesIO(b"junk"))
    buf.seek(0)
    return buf.read()


@contextlib.contextmanager
def store_and_config(*, host: str = "127.0.0.1"):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "store"
        (root / "Plaud" / "recordings").mkdir(parents=True)
        credentials_dir = Path(tmp) / "creds"
        if host != "127.0.0.1":
            generate_credentials(credentials_dir)
        yield ServerConfig(store_root=root, host=host, port=free_port(), credentials_dir=credentials_dir)


class LoopbackTests(unittest.TestCase):
    def test_health_and_version_reachable_without_a_token(self):
        with store_and_config() as config:
            with LiveServer(config) as live:
                response = httpx.get(f"{live.base_url}/v1/health", timeout=5)
                self.assertEqual(response.status_code, 200)
                response = httpx.get(f"{live.base_url}/v1/version", timeout=5)
                self.assertEqual(response.status_code, 200)
                self.assertEqual(response.json()["protocolVersion"], 1)

    def test_loopback_write_succeeds_without_a_token(self):
        with store_and_config() as config:
            with LiveServer(config) as live:
                archive = make_record_archive("loopback-1")
                response = httpx.post(f"{live.base_url}/v1/recordings", content=archive, timeout=10)
                self.assertEqual(response.status_code, 201)

    def test_end_to_end_upload_processes_and_becomes_readable(self):
        with store_and_config() as config:
            with LiveServer(config) as live:
                archive = make_record_archive("flow-1")
                response = httpx.post(f"{live.base_url}/v1/recordings", content=archive, timeout=10)
                self.assertEqual(response.status_code, 201)

                deadline = time.time() + 5
                status = {}
                while time.time() < deadline:
                    status = httpx.get(f"{live.base_url}/v1/recordings/flow-1/status", timeout=5).json()
                    if status.get("state") == "done":
                        break
                    time.sleep(0.1)
                self.assertEqual(status.get("state"), "done")

                metadata = httpx.get(f"{live.base_url}/v1/recordings/flow-1/files/meeting.json", timeout=5)
                self.assertEqual(metadata.status_code, 200)
                self.assertEqual(metadata.json()["stem"], "flow-1")

                audio = httpx.get(f"{live.base_url}/v1/recordings/flow-1/files/microphone.caf", timeout=5)
                self.assertEqual(audio.status_code, 200)
                self.assertEqual(audio.content, b"FAKE-AUDIO-BYTES")

    def test_every_operation_survives_being_run_a_second_time(self):
        """The retry/idempotency lifecycle, end to end against a real server:
        every client-visible operation runs TWICE. The SSH era had no retries
        (one-shot CLI runs on one machine), so the HTTP migration's re-run
        edges each shipped untested and each failed in production the first
        time a real user pressed a button again - requeue-after-success,
        delete-after-delete, and re-upload-after-delete were all found this
        way. This test is the standing guard for that whole class."""
        with store_and_config() as config:
            with LiveServer(config) as live:
                stem = "lifecycle-1"
                directory = config.store_root / "Plaud" / "recordings" / stem
                archive = make_record_archive(stem)

                def wait_for(state: str) -> dict:
                    deadline = time.time() + 5
                    status = {}
                    while time.time() < deadline:
                        status = httpx.get(f"{live.base_url}/v1/recordings/{stem}/status", timeout=5).json()
                        if status.get("state") == state:
                            return status
                        time.sleep(0.1)
                    raise AssertionError(f"never reached {state}: {status}")

                # Upload, process.
                self.assertEqual(httpx.post(f"{live.base_url}/v1/recordings", content=archive, timeout=10).status_code, 201)
                wait_for("done")
                # Re-upload of a live recording stays refused (it would
                # clobber committed artifacts), and refusal changes nothing.
                self.assertEqual(httpx.post(f"{live.base_url}/v1/recordings", content=archive, timeout=10).status_code, 409)
                self.assertTrue((directory / "meeting.json").is_file())

                # Reprocess after success (requeue with no failed job).
                self.assertEqual(httpx.post(f"{live.base_url}/v1/recordings/{stem}/requeue", timeout=5).status_code, 200)
                wait_for("done")

                # Summary, then summary again.
                for _ in range(2):
                    self.assertEqual(
                        httpx.post(f"{live.base_url}/v1/recordings/{stem}/summary", json={"agent": "claude", "language": "ko"}, timeout=5).status_code,
                        200,
                    )
                    wait_for("done")

                # Delete, then delete again.
                for _ in range(2):
                    response = httpx.post(
                        f"{live.base_url}/v1/rpc",
                        headers={"X-Damso-Protocol-Version": "1"},
                        json={"operation": "delete-record", "recording_directory": str(directory)},
                        timeout=5,
                    )
                    self.assertEqual(response.status_code, 200)
                    self.assertTrue(response.json().get("ok"), response.json())
                self.assertFalse(directory.exists())

                # Re-upload after delete starts a fresh lifecycle.
                self.assertEqual(httpx.post(f"{live.base_url}/v1/recordings", content=archive, timeout=10).status_code, 201)
                wait_for("done")
                self.assertTrue((directory / "meeting.json").is_file())

    def test_audio_detection_ignores_the_combined_mix_and_hidden_files(self):
        """`combined-audio.m4a` is phase-one's own output, not a source track,
        and AppleDouble sidecars are metadata - counting either made a normal
        two-track recording fail with "more than two audio files found"
        (confirmed twice via real runs: once on first upload with `._` debris,
        once on retry after a successful run had written the combined mix)."""
        from damso.server.queue import _detect_audio_files

        with tempfile.TemporaryDirectory() as tmp:
            recording = Path(tmp)
            (recording / "microphone.caf").write_bytes(b"mic")
            (recording / "system-audio.m4a").write_bytes(b"system")
            (recording / "combined-audio.m4a").write_bytes(b"mix")
            (recording / "._microphone.caf").write_bytes(b"junk")

            audio, system_audio = _detect_audio_files(recording)

            self.assertEqual(audio.name, "microphone.caf")
            self.assertEqual(system_audio.name, "system-audio.m4a")

    def test_upload_with_appledouble_debris_still_processes_and_strips_it(self):
        """macOS archivers add resource-fork sidecars ("._microphone.caf") and
        Finder metadata to the tar; extracted literally they masquerade as
        extra audio files - a real upload from the Mac client failed phase-one
        with "more than two audio files found" for a normal two-track
        recording. The server must drop them at extraction."""
        with store_and_config() as config:
            with LiveServer(config) as live:
                archive = make_record_archive("debris-1", apple_double_debris=True)
                response = httpx.post(f"{live.base_url}/v1/recordings", content=archive, timeout=10)
                self.assertEqual(response.status_code, 201)

                deadline = time.time() + 5
                status = {}
                while time.time() < deadline:
                    status = httpx.get(f"{live.base_url}/v1/recordings/debris-1/status", timeout=5).json()
                    if status.get("state") in {"done", "failed"}:
                        break
                    time.sleep(0.1)
                self.assertEqual(status.get("state"), "done", status)

                committed = config.store_root / "Plaud" / "recordings" / "debris-1"
                names = {entry.name for entry in committed.iterdir()}
                self.assertNotIn("._microphone.caf", names)
                self.assertNotIn(".DS_Store", names)
                self.assertIn("microphone.caf", names)

    def test_incomplete_upload_never_commits_a_partial_recording(self):
        with store_and_config() as config:
            with LiveServer(config) as live:
                archive = make_record_archive("broken-1")
                truncated = archive[: len(archive) // 2]
                response = httpx.post(f"{live.base_url}/v1/recordings", content=truncated, timeout=10)
                self.assertEqual(response.status_code, 422)

                missing = httpx.get(f"{live.base_url}/v1/recordings/broken-1/status", timeout=5)
                self.assertEqual(missing.status_code, 404)
                staging = config.store_root / ".staging"
                self.assertEqual(list(staging.iterdir()) if staging.is_dir() else [], [])

    def test_retry_after_incomplete_upload_succeeds_with_a_full_archive(self):
        with store_and_config() as config:
            with LiveServer(config) as live:
                archive = make_record_archive("retry-1")
                truncated = archive[: len(archive) // 2]
                first = httpx.post(f"{live.base_url}/v1/recordings", content=truncated, timeout=10)
                self.assertEqual(first.status_code, 422)
                second = httpx.post(f"{live.base_url}/v1/recordings", content=archive, timeout=10)
                self.assertEqual(second.status_code, 201)

    def test_failed_job_requires_explicit_requeue(self):
        with store_and_config() as config:
            with LiveServer(config) as live:
                live.app.state.queue._phase_one_runner = lambda request: {"ok": False, "error": {"message": "boom"}}
                archive = make_record_archive("fail-1")
                httpx.post(f"{live.base_url}/v1/recordings", content=archive, timeout=10)

                deadline = time.time() + 5
                status = {}
                while time.time() < deadline:
                    status = httpx.get(f"{live.base_url}/v1/recordings/fail-1/status", timeout=5).json()
                    if status.get("state") == "failed":
                        break
                    time.sleep(0.1)
                self.assertEqual(status.get("state"), "failed")

                no_op_requeue = httpx.post(f"{live.base_url}/v1/recordings/does-not-exist/requeue", timeout=5)
                self.assertEqual(no_op_requeue.status_code, 404)

                live.app.state.queue._phase_one_runner = lambda request: {
                    "ok": True,
                    "recording_stem": Path(request["recording_directory"]).name,
                }
                requeued = httpx.post(f"{live.base_url}/v1/recordings/fail-1/requeue", timeout=5)
                self.assertEqual(requeued.status_code, 200)

                deadline = time.time() + 5
                while time.time() < deadline:
                    status = httpx.get(f"{live.base_url}/v1/recordings/fail-1/status", timeout=5).json()
                    if status.get("state") == "done":
                        break
                    time.sleep(0.1)
                self.assertEqual(status.get("state"), "done")

                # Retry after success enqueues a FRESH phase-one instead of
                # 404ing: the client's "Retry processing" resets the record
                # before calling this, so its latest job is typically a
                # successful one, and a 404 here stranded the already-reset
                # record with no way forward (found via a real two-machine
                # run against a record whose latest job was a done summary).
                fresh = httpx.post(f"{live.base_url}/v1/recordings/fail-1/requeue", timeout=5)
                self.assertEqual(fresh.status_code, 200)
                deadline = time.time() + 5
                while time.time() < deadline:
                    status = httpx.get(f"{live.base_url}/v1/recordings/fail-1/status", timeout=5).json()
                    if status.get("state") == "done":
                        break
                    time.sleep(0.1)
                self.assertEqual(status.get("state"), "done")

    def test_summary_job_reporting_a_failed_status_is_marked_failed_not_done(self):
        """`damso.summary` reports outcomes in `status` while `ok: True` only
        means "the request was processed" (SSH-era contract:
        agent_cli_missing comes back as `ok: True, status: "failed"`). The
        queue used to check `ok` alone, so a summary that never ran was
        marked done and the client showed a completed stage with a stale
        summary.json (found via a real two-machine run where the service's
        launchd PATH had no claude CLI)."""
        with store_and_config() as config:
            with LiveServer(config) as live:
                live.app.state.queue._summary_runner = lambda request: {
                    "ok": True,
                    "status": "failed",
                    "error_code": "agent_cli_missing",
                }
                archive = make_record_archive("summary-fail-1")
                upload = httpx.post(f"{live.base_url}/v1/recordings", content=archive, timeout=10)
                self.assertEqual(upload.status_code, 201)
                deadline = time.time() + 5
                while time.time() < deadline:
                    if httpx.get(f"{live.base_url}/v1/recordings/summary-fail-1/status", timeout=5).json().get("state") == "done":
                        break
                    time.sleep(0.1)

                trigger = httpx.post(
                    f"{live.base_url}/v1/recordings/summary-fail-1/summary",
                    json={"agent": "claude", "language": "ko"},
                    timeout=5,
                )
                self.assertEqual(trigger.status_code, 200)

                deadline = time.time() + 5
                status = {}
                while time.time() < deadline:
                    status = httpx.get(f"{live.base_url}/v1/recordings/summary-fail-1/status", timeout=5).json()
                    if status.get("kind") == "summary" and status.get("state") in {"done", "failed"}:
                        break
                    time.sleep(0.1)
                self.assertEqual(status.get("state"), "failed", status)
                self.assertEqual(status.get("error"), "agent_cli_missing", status)

    def test_rpc_dispatch_accepts_the_header_only_protocol_version_the_real_client_sends(self):
        """D-16: the Swift client negotiates the protocol version via the
        X-Damso-Protocol-Version header and deliberately omits the SSH-era
        in-body `protocol_version` field, but `serve.dispatch` still enforces
        that field - a mismatch that made every dispatch-routed operation
        (delete-record, update-record, people ops) fail inside an HTTP 200
        while the access log looked healthy. Found via a real two-machine
        test, not caught here before because nothing exercised /v1/rpc over
        HTTP at all."""
        with store_and_config() as config:
            with LiveServer(config) as live:
                archive = make_record_archive("rpc-1")
                upload = httpx.post(f"{live.base_url}/v1/recordings", content=archive, timeout=10)
                self.assertEqual(upload.status_code, 201)

                record = httpx.get(f"{live.base_url}/v1/recordings/rpc-1/files/meeting.json", timeout=5).json()
                response = httpx.post(
                    f"{live.base_url}/v1/rpc",
                    headers={"X-Damso-Protocol-Version": "1"},
                    json={
                        "operation": "update-record",
                        "recording_directory": str(config.store_root / "Plaud" / "recordings" / "rpc-1"),
                        "record": record,
                    },
                    timeout=5,
                )
                self.assertEqual(response.status_code, 200)
                body = response.json()
                self.assertNotIn("error", body, body)
                self.assertTrue(body.get("ok"), body)

                delete = httpx.post(
                    f"{live.base_url}/v1/rpc",
                    headers={"X-Damso-Protocol-Version": "1"},
                    json={
                        "operation": "delete-record",
                        "recording_directory": str(config.store_root / "Plaud" / "recordings" / "rpc-1"),
                    },
                    timeout=5,
                )
                self.assertEqual(delete.status_code, 200)
                self.assertTrue(delete.json().get("ok"), delete.json())
                self.assertFalse((config.store_root / "Plaud" / "recordings" / "rpc-1").exists())

    def test_version_mismatch_is_rejected(self):
        with store_and_config() as config:
            with LiveServer(config) as live:
                response = httpx.get(
                    f"{live.base_url}/v1/changes",
                    headers={"X-Damso-Protocol-Version": "999"},
                    timeout=5,
                )
                self.assertEqual(response.status_code, 409)

    def test_malformed_version_header_is_a_client_error_not_a_crash(self):
        """The header was parsed with a bare `int()`, so any non-numeric value
        raised out of the middleware and became a 500 with a stack trace. Found
        in the server's error log after a probe sent `../../etc`."""
        with store_and_config() as config:
            with LiveServer(config) as live:
                for junk in ("../../etc", "", "1.0", "v1"):
                    response = httpx.get(
                        f"{live.base_url}/v1/changes",
                        headers={"X-Damso-Protocol-Version": junk},
                        timeout=5,
                    )
                    self.assertEqual(response.status_code, 400, junk)

    def test_mcp_endpoint_serves_tool_list(self):
        with store_and_config() as config:
            with LiveServer(config) as live:
                response = httpx.post(
                    f"{live.base_url}/mcp",
                    json={"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
                    timeout=5,
                )
                self.assertEqual(response.status_code, 200)
                tool_names = {tool["name"] for tool in response.json()["result"]["tools"]}
                self.assertEqual(tool_names, {"search_meetings", "get_meeting", "get_speaker", "search_people"})


class RemoteAuthTests(unittest.TestCase):
    """Non-loopback bind: the bearer-token boundary D-08 actually enforces
    over plain HTTP (ADR 0003)."""

    def test_non_loopback_bind_requires_a_token(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "store"
            (root / "Plaud" / "recordings").mkdir(parents=True)
            credentials_dir = Path(tmp) / "creds"
            credentials = generate_credentials(credentials_dir)
            # 0.0.0.0 exercises the non-loopback auth path without requiring
            # a second real network interface; the client still connects via
            # 127.0.0.1, matching how the loopback vs. remote branch is
            # decided (host string, not the interface actually reached).
            config = ServerConfig(store_root=root, host="0.0.0.0", port=free_port(), credentials_dir=credentials_dir)
            with LiveServer(config):
                base = f"http://127.0.0.1:{config.port}"

                no_token = httpx.get(f"{base}/v1/changes", timeout=5)
                self.assertEqual(no_token.status_code, 401)

                wrong_token = httpx.get(f"{base}/v1/changes", headers={"Authorization": "Bearer wrong"}, timeout=5)
                self.assertEqual(wrong_token.status_code, 401)

                ok = httpx.get(f"{base}/v1/changes", headers={"Authorization": f"Bearer {credentials.token}"}, timeout=5)
                self.assertEqual(ok.status_code, 200)

                health = httpx.get(f"{base}/v1/health", timeout=5)
                self.assertEqual(health.status_code, 200)

    def test_schema_endpoints_are_not_public_on_a_remote_bind(self):
        """`/docs` and `/openapi.json` were once exempt from auth alongside
        health and version, which published every route to anyone who could
        reach the port. Only the two pairing probes are exempt now; the schema
        needs the same token as the data it describes."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "store"
            (root / "Plaud" / "recordings").mkdir(parents=True)
            credentials_dir = Path(tmp) / "creds"
            credentials = generate_credentials(credentials_dir)
            config = ServerConfig(store_root=root, host="0.0.0.0", port=free_port(), credentials_dir=credentials_dir)
            with LiveServer(config):
                base = f"http://127.0.0.1:{config.port}"

                for path in ("/openapi.json", "/docs"):
                    anonymous = httpx.get(f"{base}{path}", timeout=5)
                    self.assertEqual(anonymous.status_code, 401, path)

                authorized = httpx.get(
                    f"{base}/openapi.json",
                    headers={"Authorization": f"Bearer {credentials.token}"},
                    timeout=5,
                )
                self.assertEqual(authorized.status_code, 200)

    def test_regenerating_credentials_invalidates_the_previous_token(self):
        """AC8/D-24: the only recovery path for a leaked or lost token is
        `damso-server-credentials regenerate`, and it must take effect
        immediately - a still-running server process picks up the new
        credentials from disk on its next request, not just on restart,
        because leaving a live process trusting a revoked token is exactly
        the window a regenerate is meant to close."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "store"
            (root / "Plaud" / "recordings").mkdir(parents=True)
            credentials_dir = Path(tmp) / "creds"
            old_token = generate_credentials(credentials_dir).token
            config = ServerConfig(store_root=root, host="0.0.0.0", port=free_port(), credentials_dir=credentials_dir)
            with LiveServer(config):
                generate_credentials(credentials_dir)  # regenerate while the server is already running

                base = f"http://127.0.0.1:{config.port}"
                stale = httpx.get(f"{base}/v1/changes", headers={"Authorization": f"Bearer {old_token}"}, timeout=5)
                self.assertEqual(stale.status_code, 401)

    def test_https_client_fails_cleanly_against_the_plain_http_server(self):
        """R8/AC1: a legacy HTTPS-era client (or any client that assumes TLS)
        must fail outright - no silent downgrade path exists on either side,
        so the re-pairing notice in the app is the only way forward."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "store"
            (root / "Plaud" / "recordings").mkdir(parents=True)
            credentials_dir = Path(tmp) / "creds"
            generate_credentials(credentials_dir)
            config = ServerConfig(store_root=root, host="0.0.0.0", port=free_port(), credentials_dir=credentials_dir)
            with LiveServer(config):
                with self.assertRaises(httpx.HTTPError):
                    httpx.get(f"https://127.0.0.1:{config.port}/v1/health", timeout=5)


if __name__ == "__main__":
    unittest.main()
