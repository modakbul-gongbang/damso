"""Privacy-safe local-model verification for dual-source recordings.

The probe always processes a disposable canonical store. Real meeting audio is
read only, copied into that store, and represented in stdout only by aggregate
counts and booleans. Transcript text, participant names, and source paths are
never emitted.
"""

from __future__ import annotations

import argparse
import array
import contextlib
import hashlib
import json
import math
import os
import signal
import shutil
import subprocess
import sys
import tempfile
import traceback
from pathlib import Path
from typing import Any, Iterator, Mapping, Sequence

from damso.processing import execute_request


MICROPHONE_FILENAME = "microphone.caf"
SYSTEM_FILENAME = "system-audio.m4a"
COMBINED_FILENAME = "combined-audio.m4a"
MICROPHONE_MARKER = "사과"
SYSTEM_MARKER = "바나나"
SAMPLE_RATE = 16_000
ENERGY_WINDOW_SECONDS = 0.5
PROCESS_TERMINATION_GRACE_SECONDS = 5.0


class ProbeError(RuntimeError):
    """A stable failure that is safe to print in a verification log."""


def unexpected_error_code(error: Exception) -> str:
    """Describe an unexpected failure without exposing its message or data."""
    frames = traceback.extract_tb(error.__traceback__)
    function_name = frames[-1].name if frames else "unknown"
    safe_function_name = "".join(
        character if character.isalnum() or character == "_" else "_"
        for character in function_name
    )
    return f"live_recording_probe_failed_{type(error).__name__}_{safe_function_name}"


@contextlib.contextmanager
def cleanup_aware_signal_handlers() -> Iterator[None]:
    """Turn normal termination signals into exceptions so temp cleanup runs."""
    previous: dict[signal.Signals, Any] = {}

    def terminate_after_cleanup(_signum: int, _frame: Any) -> None:
        raise ProbeError("probe_terminated")

    for selected in (signal.SIGTERM, signal.SIGHUP):
        previous[selected] = signal.getsignal(selected)
        signal.signal(selected, terminate_after_cleanup)
    try:
        yield
    finally:
        for selected, handler in previous.items():
            signal.signal(selected, handler)


def run_checked(command: Sequence[str], error_code: str) -> None:
    try:
        subprocess.run(command, check=True, capture_output=True, text=True)
    except (OSError, subprocess.CalledProcessError) as error:
        raise ProbeError(error_code) from error


def hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def regular_child(directory: Path, file_name: str, error_code: str) -> Path:
    if not file_name or file_name in {".", ".."} or Path(file_name).name != file_name:
        raise ProbeError(error_code)
    candidate = directory / file_name
    if candidate.is_symlink() or not candidate.is_file():
        raise ProbeError(error_code)
    try:
        resolved_directory = directory.resolve(strict=True)
        resolved_candidate = candidate.resolve(strict=True)
    except OSError as error:
        raise ProbeError(error_code) from error
    if resolved_candidate.parent != resolved_directory:
        raise ProbeError(error_code)
    return resolved_candidate


def read_json_object(path: Path, error_code: str) -> Mapping[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ProbeError(error_code) from error
    if not isinstance(payload, Mapping):
        raise ProbeError(error_code)
    return payload


def resolve_recording_directory(raw_source: str) -> Path:
    """Resolve a configured source without requiring its absolute path in logs."""
    try:
        return Path(os.path.expandvars(raw_source)).expanduser().resolve(strict=True)
    except OSError as error:
        raise ProbeError("test_recording_unavailable") from error


def participant_count(source_directory: Path) -> int:
    path = source_directory / "participants.json"
    if path.is_symlink() or not path.is_file():
        return 0
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return 0
    entries = payload.get("participants") if isinstance(payload, Mapping) else None
    if not isinstance(entries, list):
        return 0
    names: set[str] = set()
    for entry in entries:
        if not isinstance(entry, Mapping) or not isinstance(entry.get("name"), str):
            continue
        name = entry["name"].strip().casefold()
        if name:
            names.add(name)
    return len(names)


def ffprobe_duration(path: Path) -> float:
    try:
        completed = subprocess.run(
            [
                "ffprobe",
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                str(path),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        value = float(completed.stdout.strip())
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        raise ProbeError("audio_duration_unavailable") from error
    if not math.isfinite(value) or value <= 0:
        raise ProbeError("audio_duration_unavailable")
    return value


def synthesize_track(voice: str, sentence: str, destination: Path) -> None:
    run_checked(
        ["say", "-v", voice, "-r", "145", "-o", str(destination), sentence],
        "synthetic_speech_generation_failed",
    )


def pad_track(source: Path, destination: Path, delay_seconds: float, duration_seconds: float, codec: str) -> None:
    delay_milliseconds = max(0, round(delay_seconds * 1000))
    command = [
        "ffmpeg",
        "-y",
        "-hide_banner",
        "-loglevel",
        "error",
        "-i",
        str(source),
        "-af",
        f"adelay={delay_milliseconds}:all=1,apad,atrim=0:{duration_seconds:.3f}",
        "-ar",
        "48000",
        "-ac",
        "1" if destination.suffix == ".caf" else "2",
        "-c:a",
        codec,
    ]
    if codec == "aac":
        command.extend(["-b:a", "128k"])
    command.append(str(destination))
    run_checked(command, "synthetic_audio_encoding_failed")


def create_synthetic_sources(recording_directory: Path) -> tuple[Path, Path]:
    microphone_voice = recording_directory / ".microphone.aiff"
    system_voice = recording_directory / ".system.aiff"
    microphone_sentence = "마이크 확인입니다. 오늘의 과일은 사과입니다. 사과 소리를 분명히 기록합니다."
    system_sentence = "시스템 확인입니다. 오늘의 과일은 바나나입니다. 바나나 소리를 분명히 기록합니다."
    synthesize_track("Yuna", microphone_sentence, microphone_voice)
    synthesize_track("Grandpa (Korean (South Korea))", system_sentence, system_voice)
    microphone_duration = ffprobe_duration(microphone_voice)
    system_duration = ffprobe_duration(system_voice)
    system_delay = microphone_duration + 2.0
    total_duration = system_delay + system_duration + 1.0
    microphone = recording_directory / MICROPHONE_FILENAME
    system = recording_directory / SYSTEM_FILENAME
    pad_track(microphone_voice, microphone, 0.5, total_duration, "pcm_s16le")
    pad_track(system_voice, system, system_delay, total_duration, "aac")
    microphone_voice.unlink(missing_ok=True)
    system_voice.unlink(missing_ok=True)
    return microphone, system


def copy_or_trim(source: Path, destination: Path, seconds: int) -> None:
    if seconds == 0:
        try:
            shutil.copyfile(source, destination)
        except OSError as error:
            raise ProbeError("recording_copy_failed") from error
        return
    command = [
        "ffmpeg",
        "-y",
        "-hide_banner",
        "-loglevel",
        "error",
        "-i",
        str(source),
        "-t",
        str(seconds),
        "-map",
        "0:a:0",
        "-c:a",
        "copy",
    ]
    command.append(str(destination))
    run_checked(command, "recording_trim_failed")


def real_sources(source_directory: Path, recording_directory: Path, seconds: int) -> tuple[Path, Path, dict[str, str]]:
    metadata = read_json_object(source_directory / "meeting.json", "recording_metadata_unavailable")
    raw_microphone_name = metadata.get("originalAudioFile", MICROPHONE_FILENAME)
    raw_system_name = metadata.get("systemAudioFile")
    if raw_system_name is None and metadata.get("source") == "local":
        raw_system_name = SYSTEM_FILENAME
    if not isinstance(raw_microphone_name, str) or not isinstance(raw_system_name, str):
        raise ProbeError("recording_audio_metadata_invalid")
    source_microphone = regular_child(source_directory, raw_microphone_name, "recording_microphone_unavailable")
    source_system = regular_child(source_directory, raw_system_name, "recording_system_audio_unavailable")
    try:
        same_source = os.path.samefile(source_microphone, source_system)
    except OSError as error:
        raise ProbeError("recording_audio_metadata_invalid") from error
    if same_source:
        raise ProbeError("recording_audio_metadata_invalid")
    original_hashes = {
        source_microphone.name: hash_file(source_microphone),
        source_system.name: hash_file(source_system),
    }
    microphone = recording_directory / MICROPHONE_FILENAME
    system = recording_directory / SYSTEM_FILENAME
    copy_or_trim(source_microphone, microphone, seconds)
    copy_or_trim(source_system, system, seconds)
    return microphone, system, original_hashes


def write_sanitized_metadata(recording_directory: Path, captured_participant_count: int) -> None:
    metadata = {
        "source": "local",
        "originalAudioFile": MICROPHONE_FILENAME,
        "systemAudioFile": SYSTEM_FILENAME,
    }
    (recording_directory / "meeting.json").write_text(
        json.dumps(metadata, ensure_ascii=False, sort_keys=True),
        encoding="utf-8",
    )
    participants = {
        "participants": [
            {"name": f"Synthetic participant {index + 1}"}
            for index in range(captured_participant_count)
        ]
    }
    (recording_directory / "participants.json").write_text(
        json.dumps(participants, ensure_ascii=False, sort_keys=True),
        encoding="utf-8",
    )


def terminate_process(process: subprocess.Popen[Any]) -> None:
    """Bound a probe child shutdown and always reap it before unwinding."""
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=PROCESS_TERMINATION_GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def rms_windows(path: Path) -> list[float]:
    process: subprocess.Popen[Any] | None = None
    try:
        try:
            process = subprocess.Popen(
                [
                    "ffmpeg",
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-i",
                    str(path),
                    "-f",
                    "s16le",
                    "-ac",
                    "1",
                    "-ar",
                    str(SAMPLE_RATE),
                    "pipe:1",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
            )
        except OSError as error:
            raise ProbeError("audio_energy_probe_failed") from error
        if process.stdout is None:
            raise ProbeError("audio_energy_probe_failed")
        bytes_per_window = int(SAMPLE_RATE * ENERGY_WINDOW_SECONDS) * 2
        result: list[float] = []
        try:
            while True:
                payload = process.stdout.read(bytes_per_window)
                if not payload:
                    break
                usable_length = len(payload) - (len(payload) % 2)
                samples = array.array("h", payload[:usable_length])
                if sys.byteorder != "little":
                    samples.byteswap()
                if samples:
                    energy = math.sqrt(sum(value * value for value in samples) / len(samples)) / 32768.0
                    result.append(energy)
        finally:
            process.stdout.close()
        if process.wait() != 0 or not result:
            raise ProbeError("audio_energy_probe_failed")
        return result
    except BaseException:
        if process is not None:
            terminate_process(process)
        raise


def percentile(values: Sequence[float], ratio: float) -> float:
    ordered = sorted(values)
    position = min(len(ordered) - 1, max(0, int((len(ordered) - 1) * ratio)))
    return ordered[position]


def activity_threshold(values: Sequence[float]) -> float:
    floor_db = 20.0 * math.log10(max(percentile(values, 0.1), 1e-9))
    threshold_db = min(-35.0, max(-50.0, floor_db + 12.0))
    return 10.0 ** (threshold_db / 20.0)


def isolated_activity_windows(active_energy: Sequence[float], quiet_energy: Sequence[float]) -> list[tuple[float, float]]:
    active_threshold = activity_threshold(active_energy)
    quiet_threshold = activity_threshold(quiet_energy)
    active_indexes = [
        index
        for index, (active_rms, quiet_rms) in enumerate(zip(active_energy, quiet_energy))
        if active_rms >= active_threshold and quiet_rms < quiet_threshold
    ]
    windows: list[tuple[float, float]] = []
    for run in contiguous_runs(active_indexes):
        if len(run) < 2:
            continue
        windows.append((run[0] * ENERGY_WINDOW_SECONDS, (run[-1] + 1) * ENERGY_WINDOW_SECONDS))
    return windows


def contiguous_runs(indexes: Sequence[int]) -> list[list[int]]:
    runs: list[list[int]] = []
    for index in indexes:
        if runs and runs[-1][-1] + 1 == index:
            runs[-1].append(index)
        else:
            runs.append([index])
    return runs


def source_activity_windows(microphone: Path, system: Path) -> tuple[list[tuple[float, float]], list[tuple[float, float]]]:
    microphone_energy = rms_windows(microphone)
    system_energy = rms_windows(system)
    return (
        isolated_activity_windows(microphone_energy, system_energy),
        isolated_activity_windows(system_energy, microphone_energy),
    )


def overlapping_segment_count(segments: Sequence[Mapping[str, Any]], windows: Sequence[tuple[float, float]]) -> int:
    count = 0
    for segment in segments:
        start = float(segment["start"])
        end = float(segment["end"])
        required_overlap = min(0.5, max(0.1, max(0.0, end - start) * 0.25))
        if any(
            max(0.0, min(end, window_end) - max(start, window_start)) >= required_overlap
            for window_start, window_end in windows
        ):
            count += 1
    return count


def marker_detected(
    segments: Sequence[Mapping[str, Any]],
    marker: str,
    windows: Sequence[tuple[float, float]],
) -> bool:
    matching = [segment for segment in segments if marker in str(segment.get("text", ""))]
    return overlapping_segment_count(matching, windows) > 0


def speaker_seconds(segments: Sequence[Mapping[str, Any]]) -> list[float]:
    totals: dict[str, float] = {}
    for segment in segments:
        speaker = str(segment["speaker"])
        totals[speaker] = totals.get(speaker, 0.0) + max(0.0, float(segment["end"]) - float(segment["start"]))
    return sorted(round(value, 2) for value in totals.values())


@contextlib.contextmanager
def silence_process_output() -> Iterator[None]:
    """Prevent model or native-library output from entering privacy evidence."""
    sys.stdout.flush()
    sys.stderr.flush()
    saved_stdout = os.dup(1)
    saved_stderr = os.dup(2)
    try:
        with open(os.devnull, "w", encoding="utf-8") as sink:
            os.dup2(sink.fileno(), 1)
            os.dup2(sink.fileno(), 2)
            yield
    finally:
        sys.stdout.flush()
        sys.stderr.flush()
        os.dup2(saved_stdout, 1)
        os.dup2(saved_stderr, 2)
        os.close(saved_stdout)
        os.close(saved_stderr)


def run_pipeline(
    recording_directory: Path,
    microphone: Path,
    system: Path,
    *,
    explicit_speakers: int | None,
) -> tuple[dict[str, Any], Mapping[str, Any]]:
    hints: dict[str, Any] = {}
    if explicit_speakers is not None:
        hints["num_speakers"] = explicit_speakers
    request = {
        "operation": "phase-one",
        "recording_directory": str(recording_directory),
        "audio_path": str(microphone),
        "system_audio_path": str(system),
        "hints": hints,
    }
    with silence_process_output():
        response = execute_request(request)
    transcript = read_json_object(recording_directory / "transcript.raw.json", "probe_transcript_unavailable")
    return response, transcript


def validate_report(report: Mapping[str, Any], synthetic: bool) -> None:
    checks = [
        report.get("source_count") == 2,
        report.get("source_basenames") == sorted([MICROPHONE_FILENAME, SYSTEM_FILENAME]),
        report.get("provenance_uses_combined_audio") is True,
        report.get("processed_audio_basename") == COMBINED_FILENAME,
        report.get("processed_audio_present") is True,
        report.get("response_speaker_count") == 2,
        report.get("speaker_count") == 2,
        len(report.get("speaker_seconds", [])) == 2,
        all(float(value) > 0 for value in report.get("speaker_seconds", [])),
        report.get("unknown_speaker_absent") is True,
        int(report.get("segment_count", 0)) > 0,
        int(report.get("remote_only_window_count", 0)) > 0,
        int(report.get("remote_only_transcript_segment_count", 0)) > 0,
        report.get("source_hashes_unchanged") is True,
    ]
    if synthetic:
        checks.extend(
            [
                report.get("microphone_marker_detected") is True,
                report.get("system_marker_detected") is True,
            ]
        )
    if not all(checks):
        raise ProbeError("aggregate_acceptance_failed")


def execute_probe(args: argparse.Namespace) -> dict[str, Any]:
    synthetic = bool(args.synthetic)
    source_directory: Path | None = None
    original_hashes: dict[str, str] = {}
    if not synthetic:
        raw_source = os.environ.get("DAMSO_TEST_RECORDING")
        if not raw_source:
            raise ProbeError("test_recording_not_configured")
        source_directory = resolve_recording_directory(raw_source)
        if not source_directory.is_dir():
            raise ProbeError("test_recording_unavailable")

    temporary_path: Path | None = None
    report: dict[str, Any]
    with tempfile.TemporaryDirectory(prefix="damso-live-recording-") as temporary:
        temporary_path = Path(temporary)
        recording_directory = temporary_path / "Plaud" / "recordings" / (
            "probe-synthetic" if synthetic else "probe-local-recording"
        )
        recording_directory.mkdir(parents=True)
        (temporary_path / "Plaud" / "peoples").mkdir()
        if synthetic:
            microphone, system = create_synthetic_sources(recording_directory)
            captured_count = 0
        else:
            if source_directory is None or args.seconds is None:
                raise ProbeError("test_recording_not_configured")
            captured_count = participant_count(source_directory)
            if captured_count != 2:
                raise ProbeError("expected_two_participant_roster")
            microphone, system, original_hashes = real_sources(
                source_directory,
                recording_directory,
                args.seconds,
            )
        write_sanitized_metadata(recording_directory, captured_count)
        working_hashes_before = {microphone.name: hash_file(microphone), system.name: hash_file(system)}
        microphone_windows, remote_windows = source_activity_windows(microphone, system)
        response, transcript = run_pipeline(
            recording_directory,
            microphone,
            system,
            explicit_speakers=2 if synthetic else None,
        )
        segments = transcript.get("segments")
        sources = transcript.get("source_files")
        if not isinstance(segments, list) or not all(isinstance(item, Mapping) for item in segments):
            raise ProbeError("probe_transcript_invalid")
        if not isinstance(sources, list) or not all(isinstance(item, str) for item in sources):
            raise ProbeError("probe_provenance_invalid")
        if any(Path(item).name != item for item in sources):
            raise ProbeError("probe_provenance_invalid")
        working_hashes_after = {microphone.name: hash_file(microphone), system.name: hash_file(system)}
        source_hashes_unchanged = working_hashes_before == working_hashes_after
        if source_directory is not None:
            metadata = read_json_object(source_directory / "meeting.json", "recording_metadata_unavailable")
            raw_microphone_name = metadata.get("originalAudioFile", MICROPHONE_FILENAME)
            raw_system_name = metadata.get("systemAudioFile")
            if raw_system_name is None and metadata.get("source") == "local":
                raw_system_name = SYSTEM_FILENAME
            if not isinstance(raw_microphone_name, str) or not isinstance(raw_system_name, str):
                raise ProbeError("recording_audio_metadata_invalid")
            source_microphone = regular_child(source_directory, raw_microphone_name, "recording_microphone_unavailable")
            source_system = regular_child(source_directory, raw_system_name, "recording_system_audio_unavailable")
            source_hashes_unchanged = source_hashes_unchanged and original_hashes == {
                source_microphone.name: hash_file(source_microphone),
                source_system.name: hash_file(source_system),
            }
        processed_audio = recording_directory / COMBINED_FILENAME
        processed_audio_present = (
            processed_audio.is_file()
            and not processed_audio.is_symlink()
            and processed_audio.stat().st_size > 0
        )
        unique_speakers = {str(segment["speaker"]) for segment in segments}
        report = {
            "ok": True,
            "mode": "synthetic" if synthetic else ("full" if args.seconds == 0 else "sample"),
            "duration_seconds": round(ffprobe_duration(recording_directory / COMBINED_FILENAME), 2),
            "source_basenames": sorted(sources),
            "source_count": len(sources),
            "provenance_uses_combined_audio": transcript.get("source_file") == COMBINED_FILENAME,
            "processed_audio_basename": response.get("processed_audio_file"),
            "processed_audio_present": processed_audio_present,
            "response_speaker_count": response.get("speaker_count"),
            "segment_count": len(segments),
            "speaker_count": len(unique_speakers),
            "speaker_seconds": speaker_seconds(segments),
            "remote_only_window_count": len(remote_windows),
            "remote_only_seconds": round(sum(end - start for start, end in remote_windows), 2),
            "remote_only_transcript_segment_count": overlapping_segment_count(segments, remote_windows),
            "source_hashes_unchanged": source_hashes_unchanged,
            "unknown_speaker_absent": "UNKNOWN" not in unique_speakers,
        }
        if synthetic:
            report["microphone_marker_detected"] = marker_detected(segments, MICROPHONE_MARKER, microphone_windows)
            report["system_marker_detected"] = marker_detected(segments, SYSTEM_MARKER, remote_windows)
        validate_report(report, synthetic)
    report["temp_cleaned"] = temporary_path is not None and not temporary_path.exists()
    if not report["temp_cleaned"]:
        raise ProbeError("temporary_store_cleanup_failed")
    return report


def parse_arguments(arguments: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Privacy-safe dual-track local recording probe")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--synthetic", action="store_true")
    mode.add_argument("--seconds", type=int)
    args = parser.parse_args(arguments)
    if args.seconds is not None and args.seconds < 0:
        parser.error("--seconds must be zero or positive")
    return args


def main(arguments: Sequence[str] | None = None) -> int:
    try:
        with cleanup_aware_signal_handlers():
            report = execute_probe(parse_arguments(arguments))
    except ProbeError as error:
        print(json.dumps({"ok": False, "error_code": str(error)}, sort_keys=True))
        return 2
    except KeyboardInterrupt:
        print(json.dumps({"ok": False, "error_code": "probe_interrupted"}, sort_keys=True))
        return 130
    except Exception as error:
        print(json.dumps({"ok": False, "error_code": unexpected_error_code(error)}, sort_keys=True))
        return 3
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
