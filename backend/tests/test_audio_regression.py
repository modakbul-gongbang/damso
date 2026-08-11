"""V4 (AC9): a real-audio regression test for the new upload -> queue ->
phase-one path, using actual mlx-whisper + sherpa-onnx inference - the same
`processing.execute_request` the SSH-era client used to invoke directly,
now reached through `ProcessingQueue` instead (D-21, A-02).

The recording is synthesized with macOS `say` rather than a real meeting:
sensitive audio cannot live in this repository, and a TTS clip is still a
real waveform that exercises decode -> transcribe -> diarize end to end,
unlike a byte-literal fixture. Summary generation (the agent-CLI step) is
intentionally out of scope here - AC9 stops at phase-one, and invoking a
real agent CLI is a cost-bearing live call gated the same way
`verify-live-llm` already gates it elsewhere in this suite.

Skips (does not fail) when `say`, `ffmpeg`, or the local Whisper/sherpa
models are unavailable, since this suite must also run on a plain
`local-processing`-less checkout.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

from damso import model_setup
from damso.server.queue import ProcessingQueue

FIXTURE_DIR = Path(__file__).parent / "fixtures"
BASELINE_PATH = FIXTURE_DIR / "audio_regression_baseline.json"

# Generous: this machine's TTS clip is a few seconds long and the point is
# catching a gross regression (a broken pipeline path, a stuck loop), not
# reproducing the 55-minute real-meeting benchmark (that's H2, by design -
# PRD Risks: "실음성 회귀의 처리 시간 기준선은 첫 실행에서 수립됨").
REGRESSION_MULTIPLIER = 4.0


def _tooling_available() -> bool:
    if shutil.which("say") is None or shutil.which("ffmpeg") is None:
        return False
    paths = model_setup.model_paths()
    status = model_setup.readiness(paths)
    return bool(status.get("whisper_ready")) and bool(status.get("sherpa_ready"))


@unittest.skipUnless(_tooling_available(), "requires macOS `say`, ffmpeg, and installed local models")
class RealAudioPhaseOneRegressionTests(unittest.TestCase):
    def test_upload_queue_produces_a_real_transcript_within_the_time_baseline(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            recording_directory = root / "Plaud" / "recordings" / "regression-1"
            recording_directory.mkdir(parents=True)
            audio_path = recording_directory / "microphone.caf"
            _synthesize_two_speaker_clip(audio_path)

            record = {
                "schemaVersion": 1,
                "stem": "regression-1",
                "id": "regression",
                "createdAt": "2026-08-10T00:00:00Z",
                "source": "local",
                "title": "Regression fixture",
                "stage": "captured",
                "completedStages": [],
                "sensitive": False,
                "hints": {"participants": [], "domainTerms": []},
                "resolutions": [],
            }
            (recording_directory / "meeting.json").write_text(json.dumps(record), encoding="utf-8")

            queue = ProcessingQueue(root / ".processing-queue.sqlite3", root)
            started = time.monotonic()
            queue._run_phase_one("regression-1")
            elapsed = time.monotonic() - started

            transcript_path = recording_directory / "transcript.raw.json"
            self.assertTrue(transcript_path.is_file())
            transcript = json.loads(transcript_path.read_text(encoding="utf-8"))
            self.assertGreater(len(transcript["segments"]), 0)
            self.assertGreaterEqual(len(transcript["speakers"]), 1)
            for artifact in ("identification.json", "transcript.md"):
                self.assertTrue((recording_directory / artifact).is_file(), f"missing {artifact}")

            _check_against_baseline(elapsed)


def _synthesize_two_speaker_clip(destination: Path) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        first = tmp_path / "a.aiff"
        second = tmp_path / "b.aiff"
        subprocess.run(["say", "-v", "Yuna", "-o", str(first), "안녕하세요 오늘 회의를 시작하겠습니다"], check=True)
        subprocess.run(["say", "-v", "Sinji", "-o", str(second), "네 알겠습니다 준비됐습니다"], check=True)
        concat_list = tmp_path / "list.txt"
        concat_list.write_text(f"file '{first}'\nfile '{second}'\n", encoding="utf-8")
        subprocess.run(
            [
                "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
                "-f", "concat", "-safe", "0", "-i", str(concat_list),
                "-ar", "16000", "-ac", "1", str(destination),
            ],
            check=True,
        )


def _check_against_baseline(elapsed_seconds: float) -> None:
    FIXTURE_DIR.mkdir(parents=True, exist_ok=True)
    if not BASELINE_PATH.is_file():
        BASELINE_PATH.write_text(json.dumps({"phaseOneSeconds": round(elapsed_seconds, 2)}, indent=2) + "\n", encoding="utf-8")
        return
    baseline = json.loads(BASELINE_PATH.read_text(encoding="utf-8"))
    limit = baseline["phaseOneSeconds"] * REGRESSION_MULTIPLIER
    assert elapsed_seconds <= limit, (
        f"phase-one took {elapsed_seconds:.2f}s, more than {REGRESSION_MULTIPLIER}x the "
        f"{baseline['phaseOneSeconds']:.2f}s baseline - investigate before trusting this as noise"
    )


if __name__ == "__main__":
    unittest.main()
