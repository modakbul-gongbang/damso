"""Local-only STT and diarization pipeline for the canonical folder contract.

The production adapters load mlx-whisper and sherpa-onnx lazily so the app can
remain usable for browsing and speaker review when local models are absent.
There is deliberately no hosted STT fallback in this module.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import wave
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping, Protocol, Sequence

from .contracts import ContractError, apply_resolutions, ensure_safe_stem, write_phase_one
from .model_setup import SHERPA_EMBEDDING_FILENAME, default_model_root
from .people import VOICE_EMBEDDING_MODEL, append_person_note, apply_people_resolutions, compatible_voice_candidates, remove_person_alias, set_person_email


class ProcessingError(RuntimeError):
    pass


MAX_REQUEST_BYTES = 64 * 1024


class Transcriber(Protocol):
    def transcribe(self, audio_path: Path, hints: Mapping[str, Any]) -> list[dict[str, Any]]: ...


class Diarizer(Protocol):
    def diarize(self, audio_path: Path, num_speakers: int | None) -> list[dict[str, Any]]: ...


class SpeakerEmbedder(Protocol):
    def speaker_embeddings(self, audio_path: Path, intervals: Sequence[Mapping[str, Any]]) -> dict[str, list[float]]: ...


@dataclass(frozen=True)
class LocalModelConfig:
    mlx_whisper_model_directory: Path
    sherpa_model_directory: Path

    @classmethod
    def from_environment(cls, environment: Mapping[str, str] | None = None) -> "LocalModelConfig":
        environment = environment or os.environ
        root = default_model_root()
        whisper = environment.get("DAMSO_MLX_WHISPER_MODEL_DIR") or str(root / "mlx-whisper-large-v3")
        sherpa = environment.get("DAMSO_SHERPA_MODEL_DIR") or str(root / "sherpa-diarization")
        return cls(Path(whisper).expanduser(), Path(sherpa).expanduser())

    def validate(self) -> None:
        required = [
            self.mlx_whisper_model_directory / "config.json",
            self.sherpa_model_directory / "sherpa-onnx-pyannote-segmentation-3-0" / "model.onnx",
            self.sherpa_model_directory / SHERPA_EMBEDDING_FILENAME,
        ]
        missing = [str(path) for path in required if not path.exists()]
        if missing:
            raise ProcessingError("Missing local processing models: " + ", ".join(missing))


# Whisper occasionally loops on a token or phrase ("아 아 아 ..." hundreds of
# times) before recovering. The cleanup is deterministic and local: it only
# collapses excessive consecutive repetition and never rewrites wording, so
# the transcript remains a faithful record.
MAX_CONSECUTIVE_PHRASE_REPEATS = 3
MAX_COLLAPSE_PHRASE_TOKENS = 8


def collapse_repetitions(text: str, max_repeats: int = MAX_CONSECUTIVE_PHRASE_REPEATS) -> str:
    tokens = text.split()
    if len(tokens) <= max_repeats:
        return " ".join(tokens)
    for _ in range(4):  # bounded stabilization passes
        changed = False
        for size in range(1, MAX_COLLAPSE_PHRASE_TOKENS + 1):
            collapsed: list[str] = []
            index = 0
            while index < len(tokens):
                phrase = tokens[index : index + size]
                if len(phrase) < size:
                    collapsed.extend(phrase)
                    break
                count = 1
                cursor = index + size
                while tokens[cursor : cursor + size] == phrase:
                    count += 1
                    cursor += size
                if count > max_repeats:
                    collapsed.extend(phrase * max_repeats)
                    changed = True
                else:
                    collapsed.extend(tokens[index:cursor])
                index = cursor
            tokens = collapsed
        if not changed:
            break
    return " ".join(tokens)


def clean_transcribed_segments(segments: list[dict[str, Any]], max_repeats: int = MAX_CONSECUTIVE_PHRASE_REPEATS) -> list[dict[str, Any]]:
    """Collapse in-segment repetition loops and runs of identical segments."""
    cleaned: list[dict[str, Any]] = []
    previous_text = None
    previous_run = 0
    for segment in segments:
        text = collapse_repetitions(str(segment.get("text", "")), max_repeats)
        if not text:
            continue
        if text == previous_text:
            previous_run += 1
            if previous_run >= max_repeats:
                continue
        else:
            previous_text = text
            previous_run = 1
        cleaned.append({**segment, "text": text})
    return cleaned


class MLXWhisperTranscriber:
    def __init__(self, config: LocalModelConfig):
        self.config = config

    def transcribe(self, audio_path: Path, hints: Mapping[str, Any]) -> list[dict[str, Any]]:
        self.config.validate()
        try:
            import mlx_whisper
        except ImportError as error:
            raise ProcessingError("mlx-whisper is not installed in the configured Python environment.") from error
        domain_terms = hints.get("domain_terms", [])
        topic = hints.get("topic")
        initial_prompt = " ".join([str(topic or ""), *[str(term) for term in domain_terms]]).strip() or None
        result = mlx_whisper.transcribe(
            str(audio_path),
            path_or_hf_repo=str(self.config.mlx_whisper_model_directory),
            language="ko",
            initial_prompt=initial_prompt,
            word_timestamps=False,
        )
        segments = result.get("segments")
        if not isinstance(segments, list):
            raise ProcessingError("mlx-whisper did not return transcript segments")
        return clean_transcribed_segments([
            {"start": float(segment["start"]), "end": float(segment["end"]), "text": str(segment["text"]).strip()}
            for segment in segments
            if str(segment.get("text", "")).strip()
        ])


class SherpaDiarizer:
    def __init__(self, config: LocalModelConfig, ffmpeg: str = "ffmpeg"):
        self.config = config
        self.ffmpeg = ffmpeg

    def diarize(self, audio_path: Path, num_speakers: int | None) -> list[dict[str, Any]]:
        self.config.validate()
        if not shutil.which(self.ffmpeg):
            raise ProcessingError("ffmpeg is required for local sherpa-onnx diarization.")
        try:
            import numpy as np
            from sherpa_onnx import (
                FastClusteringConfig,
                OfflineSpeakerDiarization,
                OfflineSpeakerDiarizationConfig,
                OfflineSpeakerSegmentationModelConfig,
                OfflineSpeakerSegmentationPyannoteModelConfig,
                SpeakerEmbeddingExtractorConfig,
            )
        except ImportError as error:
            raise ProcessingError("sherpa-onnx and numpy are required for local diarization.") from error

        waveform = self.waveform(audio_path)

        segmentation = OfflineSpeakerSegmentationModelConfig()
        segmentation.pyannote = OfflineSpeakerSegmentationPyannoteModelConfig(
            str(self.config.sherpa_model_directory / "sherpa-onnx-pyannote-segmentation-3-0" / "model.onnx")
        )
        embedding = SpeakerEmbeddingExtractorConfig(
            model=str(self.config.sherpa_model_directory / SHERPA_EMBEDDING_FILENAME), num_threads=4, debug=False, provider="cpu"
        )
        clustering = FastClusteringConfig(num_clusters=int(num_speakers or -1), threshold=0.95)
        config = OfflineSpeakerDiarizationConfig(
            segmentation=segmentation,
            embedding=embedding,
            clustering=clustering,
            min_duration_on=0.3,
            min_duration_off=0.5,
        )
        if not config.validate():
            raise ProcessingError("sherpa-onnx configuration validation failed")
        diarizer = OfflineSpeakerDiarization(config)
        if diarizer.sample_rate != 16_000:
            raise ProcessingError("sherpa-onnx sample rate is incompatible with local input")
        segments = diarizer.process(waveform).sort_by_start_time()
        return [
            {"start": float(segment.start), "end": float(segment.end), "speaker": f"SPEAKER_{int(segment.speaker):02d}"}
            for segment in segments
        ]

    def speaker_embeddings(self, audio_path: Path, intervals: Sequence[Mapping[str, Any]]) -> dict[str, list[float]]:
        self.config.validate()
        try:
            import numpy as np
            from sherpa_onnx import SpeakerEmbeddingExtractor, SpeakerEmbeddingExtractorConfig
        except ImportError as error:
            raise ProcessingError("sherpa-onnx and numpy are required for local speaker embeddings.") from error
        waveform = self.waveform(audio_path)
        extractor = SpeakerEmbeddingExtractor(
            SpeakerEmbeddingExtractorConfig(
                model=str(self.config.sherpa_model_directory / SHERPA_EMBEDDING_FILENAME),
                num_threads=4,
                debug=False,
                provider="cpu",
            )
        )
        samples_by_speaker: dict[str, list[tuple[int, int]]] = defaultdict(list)
        for interval in intervals:
            speaker = str(interval["speaker"])
            start = max(0, int(float(interval["start"]) * 16_000))
            end = min(len(waveform), int(float(interval["end"]) * 16_000))
            if end - start >= 16_000:
                samples_by_speaker[speaker].append((start, end))
        embeddings: dict[str, list[float]] = {}
        for speaker, samples in samples_by_speaker.items():
            start, end = max(samples, key=lambda item: item[1] - item[0])
            stream = extractor.create_stream()
            stream.accept_waveform(16_000, waveform[start:end])
            stream.input_finished()
            if not extractor.is_ready(stream):
                continue
            vector = np.asarray(extractor.compute(stream), dtype=np.float32).reshape(-1)
            if vector.size != extractor.dim or not np.all(np.isfinite(vector)):
                continue
            norm = float(np.linalg.norm(vector))
            if norm > 0.0:
                embeddings[speaker] = (vector / norm).tolist()
        return embeddings

    def waveform(self, audio_path: Path):
        if not shutil.which(self.ffmpeg):
            raise ProcessingError("ffmpeg is required for local sherpa-onnx diarization.")
        try:
            import numpy as np
        except ImportError as error:
            raise ProcessingError("numpy is required for local diarization.") from error
        with tempfile.TemporaryDirectory(prefix="damso-diarize-") as temporary:
            wav_path = Path(temporary) / "input.wav"
            subprocess.run(
                [self.ffmpeg, "-y", "-hide_banner", "-loglevel", "error", "-i", str(audio_path), "-ac", "1", "-ar", "16000", str(wav_path)],
                check=True,
                capture_output=True,
                text=True,
            )
            with wave.open(str(wav_path), "rb") as source:
                if source.getnchannels() != 1 or source.getframerate() != 16_000 or source.getsampwidth() != 2:
                    raise ProcessingError("ffmpeg did not produce expected 16kHz mono PCM audio")
                return np.frombuffer(source.readframes(source.getnframes()), dtype=np.int16).astype(np.float32) / 32768.0


class LocalProcessingPipeline:
    def __init__(self, transcriber: Transcriber, diarizer: Diarizer):
        self.transcriber = transcriber
        self.diarizer = diarizer

    def run_phase_one(self, recording_directory: Path, audio_path: Path, hints: Mapping[str, Any] | None = None) -> dict[str, Any]:
        if not audio_path.is_file():
            raise ProcessingError("audio input must be a local regular file")
        hints = hints or {}
        raw_segments = self.transcriber.transcribe(audio_path, hints)
        intervals = self.diarizer.diarize(audio_path, hints.get("num_speakers"))
        transcript = {
            "source_file": audio_path.name,
            "language": "ko",
            "model": "mlx-whisper-large-v3",
            "duration": max((float(segment["end"]) for segment in raw_segments), default=0.0),
            "segments": assign_speakers(raw_segments, intervals),
            "speakers": [],
        }
        transcript["speakers"] = sorted({segment["speaker"] for segment in transcript["segments"]})
        embedding_method = getattr(self.diarizer, "speaker_embeddings", None)
        speaker_embeddings = embedding_method(audio_path, intervals) if callable(embedding_method) else {}
        identification = identification_proposals(transcript, speaker_embeddings, canonical_peoples_for_recording(recording_directory))
        try:
            write_phase_one(recording_directory, hints, transcript, identification)
            write_speaker_embeddings(recording_directory, speaker_embeddings)
        except ContractError as error:
            raise ProcessingError(str(error)) from error
        return transcript


def execute_request(request: Mapping[str, Any], environment: Mapping[str, str] | None = None) -> dict[str, Any]:
    """Run one local processing operation through a narrow JSON-only boundary.

    Audio and transcript content are never returned over stdout. The app reads
    validated artifacts from the caller-owned canonical record directory instead.
    """
    operation = request.get("operation")
    if operation == "set-person-email":
        # Profile-only operation: runs from the People page with no meeting
        # context, so it validates the peoples directory on its own.
        peoples_directory = standalone_peoples_directory(request.get("peoples_directory"))
        name = request.get("name")
        email = request.get("email")
        if not isinstance(name, str) or not isinstance(email, str):
            raise ProcessingError("set-person-email requires a name and email string")
        try:
            set_person_email(peoples_directory, name, email)
        except ValueError as error:
            raise ProcessingError(str(error)) from error
        return {
            "ok": True,
            "operation": operation,
            "stage": "person_email_saved",
            "artifact_files": [],
        }
    if operation == "remove-person-alias":
        # Profile-only operation, mirroring set-person-email: runs from the
        # People page with no meeting context.
        peoples_directory = standalone_peoples_directory(request.get("peoples_directory"))
        name = request.get("name")
        alias = request.get("alias")
        if not isinstance(name, str) or not isinstance(alias, str):
            raise ProcessingError("remove-person-alias requires a name and alias string")
        try:
            remove_person_alias(peoples_directory, name, alias)
        except ValueError as error:
            raise ProcessingError(str(error)) from error
        return {
            "ok": True,
            "operation": operation,
            "stage": "person_alias_removed",
            "artifact_files": [],
        }
    recording_directory = canonical_recording_directory(request.get("recording_directory"))
    if operation == "phase-one":
        audio_path = canonical_audio_path(recording_directory, request.get("audio_path"))
        hints = request.get("hints", {})
        if not isinstance(hints, Mapping):
            raise ProcessingError("processing hints must be an object")
        config = LocalModelConfig.from_environment(environment)
        pipeline = LocalProcessingPipeline(MLXWhisperTranscriber(config), SherpaDiarizer(config))
        transcript = pipeline.run_phase_one(recording_directory, audio_path, hints)
        return {
            "ok": True,
            "operation": operation,
            "recording_stem": recording_directory.name,
            "stage": "speaker_review",
            "speaker_count": len(transcript["speakers"]),
            "artifact_files": ["hint.json", "transcript.raw.json", "identification.json", "speaker-embeddings.npz", "transcript.md"],
        }
    if operation == "apply-resolutions":
        resolutions = request.get("resolutions", {})
        if not isinstance(resolutions, Mapping):
            raise ProcessingError("speaker resolutions must be an object")
        peoples_directory = canonical_peoples_directory(recording_directory, request.get("peoples_directory"))
        meeting_date = request.get("meeting_date")
        if meeting_date is not None and not isinstance(meeting_date, str):
            raise ProcessingError("meeting_date must be an ISO date string when provided")
        transcript = apply_resolutions(recording_directory, resolutions)
        embedding_model, speaker_embeddings = read_speaker_embeddings(recording_directory)
        apply_people_resolutions(
            peoples_directory,
            resolutions,
            meeting_date=meeting_date,
            meeting_stem=recording_directory.name,
            speaker_embeddings=speaker_embeddings,
            speaker_embedding_model=embedding_model,
        )
        return {
            "ok": True,
            "operation": operation,
            "recording_stem": recording_directory.name,
            "stage": "ready_for_summary",
            "speaker_count": len(transcript["speakers"]),
            "artifact_files": ["resolutions.yaml", "transcript.json", "transcript.md"],
        }
    if operation == "refresh-candidates":
        # Stored candidates freeze at phase-one time; voice profiles keep
        # improving as more meetings are confirmed. Recompute the manual-review
        # candidates from the stored per-speaker embeddings against the
        # current peoples registry without touching any other artifact field.
        peoples_directory = canonical_peoples_directory(recording_directory, request.get("peoples_directory"))
        identification_path = recording_directory / "identification.json"
        if not identification_path.is_file():
            raise ProcessingError("identification.json is required before refreshing candidates")
        embedding_model, speaker_embeddings = read_speaker_embeddings(recording_directory)
        try:
            identification = json.loads(identification_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise ProcessingError("identification.json is unreadable") from error
        proposals = identification.get("proposals")
        if not isinstance(proposals, dict):
            raise ProcessingError("identification.json has no proposals")
        updated = 0
        if embedding_model == VOICE_EMBEDDING_MODEL:
            for speaker, proposal in proposals.items():
                embedding = speaker_embeddings.get(str(speaker))
                if embedding is None or not isinstance(proposal, dict):
                    continue
                proposal["candidates"] = [candidate.__dict__ for candidate in compatible_voice_candidates(peoples_directory, embedding)]
                updated += 1
            from .contracts import atomic_write_json

            atomic_write_json(identification_path, identification)
        return {
            "ok": True,
            "operation": operation,
            "recording_stem": recording_directory.name,
            "stage": "candidates_refreshed",
            "speaker_count": updated,
            "artifact_files": ["identification.json"],
        }
    if operation == "append-person-note":
        peoples_directory = canonical_peoples_directory(recording_directory, request.get("peoples_directory"))
        name = request.get("name")
        note = request.get("note")
        if not isinstance(name, str) or not isinstance(note, str):
            raise ProcessingError("append-person-note requires a name and note")
        meeting_date = request.get("meeting_date")
        if meeting_date is not None and not isinstance(meeting_date, str):
            raise ProcessingError("meeting_date must be an ISO date string when provided")
        try:
            append_person_note(peoples_directory, name, note, meeting_date)
        except ValueError as error:
            raise ProcessingError(str(error)) from error
        return {
            "ok": True,
            "operation": operation,
            "recording_stem": recording_directory.name,
            "stage": "person_note_saved",
            "artifact_files": [],
        }
    raise ProcessingError("unsupported processing operation")


def canonical_recording_directory(raw_value: Any) -> Path:
    if not isinstance(raw_value, str) or not raw_value:
        raise ProcessingError("recording_directory is required")
    directory = Path(raw_value).expanduser().resolve(strict=True)
    if not directory.is_dir() or directory.parent.name != "recordings" or directory.parent.parent.name != "Plaud":
        raise ProcessingError("recording_directory must be a canonical Plaud/recordings record")
    try:
        ensure_safe_stem(directory.name)
    except ContractError as error:
        raise ProcessingError(str(error)) from error
    return directory


def canonical_audio_path(recording_directory: Path, raw_value: Any) -> Path:
    if not isinstance(raw_value, str) or not raw_value:
        raise ProcessingError("audio_path is required")
    audio_path = Path(raw_value).expanduser().resolve(strict=True)
    if not audio_path.is_file():
        raise ProcessingError("audio_path must be a local regular file")
    try:
        audio_path.relative_to(recording_directory)
    except ValueError as error:
        raise ProcessingError("audio_path must stay inside its canonical record") from error
    return audio_path


def standalone_peoples_directory(raw_value: Any) -> Path:
    if not isinstance(raw_value, str) or not raw_value:
        raise ProcessingError("peoples_directory is required")
    peoples = Path(raw_value).expanduser().resolve(strict=True)
    if not peoples.is_dir() or peoples.name != "peoples" or peoples.parent.name != "Plaud":
        raise ProcessingError("peoples_directory must be a canonical Plaud/peoples directory")
    return peoples


def canonical_peoples_directory(recording_directory: Path, raw_value: Any) -> Path:
    if not isinstance(raw_value, str) or not raw_value:
        raise ProcessingError("peoples_directory is required")
    peoples = Path(raw_value).expanduser().resolve(strict=False)
    canonical = recording_directory.parent.parent / "peoples"
    if peoples != canonical:
        raise ProcessingError("peoples_directory must be the canonical store sibling")
    return canonical


def assign_speakers(segments: list[Mapping[str, Any]], intervals: list[Mapping[str, Any]]) -> list[dict[str, Any]]:
    assigned = []
    for segment in segments:
        start, end = float(segment["start"]), float(segment["end"])
        overlaps: dict[str, float] = defaultdict(float)
        for interval in intervals:
            overlap = max(0.0, min(end, float(interval["end"])) - max(start, float(interval["start"])))
            if overlap:
                overlaps[str(interval["speaker"])] += overlap
        if overlaps:
            speaker = max(overlaps, key=overlaps.get)
        elif intervals:
            midpoint = (start + end) / 2
            nearest = min(
                intervals,
                key=lambda interval: min(
                    abs(midpoint - float(interval["start"])),
                    abs(midpoint - float(interval["end"])),
                ),
            )
            speaker = str(nearest["speaker"])
        else:
            speaker = "UNKNOWN"
        assigned.append({"start": start, "end": end, "speaker": speaker, "text": str(segment["text"]).strip()})
    return merge_adjacent(assigned)


def merge_adjacent(segments: list[dict[str, Any]], maximum_gap: float = 1.5) -> list[dict[str, Any]]:
    if not segments:
        return []
    result = [dict(segments[0])]
    for segment in segments[1:]:
        previous = result[-1]
        if previous["speaker"] == segment["speaker"] and float(segment["start"]) - float(previous["end"]) < maximum_gap:
            previous["end"] = segment["end"]
            previous["text"] = f"{previous['text'].rstrip()} {str(segment['text']).lstrip()}".strip()
        else:
            result.append(dict(segment))
    return result


def identification_proposals(
    transcript: Mapping[str, Any],
    speaker_embeddings: Mapping[str, Sequence[float]] | None = None,
    peoples_directory: Path | None = None,
) -> dict[str, Any]:
    by_speaker: dict[str, list[Mapping[str, Any]]] = defaultdict(list)
    for segment in transcript.get("segments", []):
        by_speaker[str(segment["speaker"])].append(segment)
    proposals = {}
    for speaker, segments in by_speaker.items():
        ordered = sorted(segments, key=lambda item: float(item["end"]) - float(item["start"]), reverse=True)
        proposals[speaker] = {
            "total_seconds": round(sum(float(item["end"]) - float(item["start"]) for item in segments), 2),
            "segment_count": len(segments),
            "excerpts": [{"start": item["start"], "end": item["end"], "text": item["text"]} for item in ordered[:3]],
            "candidates": [candidate.__dict__ for candidate in compatible_voice_candidates(peoples_directory, speaker_embeddings[speaker])]
            if peoples_directory and speaker_embeddings and speaker in speaker_embeddings
            else [],
        }
    return {"embedding_model": VOICE_EMBEDDING_MODEL, "proposals": proposals, "version": 1}


def canonical_peoples_for_recording(recording_directory: Path) -> Path | None:
    if recording_directory.parent.name == "recordings" and recording_directory.parent.parent.name == "Plaud":
        return recording_directory.parent.parent / "peoples"
    return None


def write_speaker_embeddings(recording_directory: Path, embeddings: Mapping[str, Sequence[float]]) -> None:
    try:
        import numpy as np
    except ImportError as error:
        raise ProcessingError("numpy is required to write local speaker embeddings.") from error
    path = recording_directory / "speaker-embeddings.npz"
    payload = {speaker: np.asarray(vector, dtype=np.float32) for speaker, vector in embeddings.items()}
    payload["model"] = np.asarray(VOICE_EMBEDDING_MODEL)
    with tempfile.NamedTemporaryFile("wb", dir=recording_directory, delete=False) as temporary:
        np.savez_compressed(temporary, **payload)
        temporary_path = Path(temporary.name)
    os.replace(temporary_path, path)


def read_speaker_embeddings(recording_directory: Path) -> tuple[str | None, dict[str, list[float]]]:
    path = recording_directory / "speaker-embeddings.npz"
    if not path.is_file():
        return None, {}
    try:
        import numpy as np
        with np.load(path, allow_pickle=False) as payload:
            model = str(payload["model"].item()) if "model" in payload else None
            values = {
                key: np.asarray(payload[key], dtype=np.float32).reshape(-1).tolist()
                for key in payload.files
                if key != "model" and np.asarray(payload[key]).ndim == 1
            }
    except (OSError, ValueError, KeyError):
        return None, {}
    return model, values


def read_request() -> Mapping[str, Any]:
    payload = sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1)
    if len(payload) > MAX_REQUEST_BYTES:
        raise ProcessingError("processing request exceeds the local safety limit")
    try:
        request = json.loads(payload)
    except json.JSONDecodeError as error:
        raise ProcessingError("processing request must be JSON") from error
    if not isinstance(request, Mapping):
        raise ProcessingError("processing request must be an object")
    return request


def public_error(error: Exception) -> dict[str, str]:
    text = str(error).lower()
    if "model" in text or "ffmpeg" in text or "mlx-whisper" in text or "sherpa" in text:
        return {
            "code": "local_dependency_unavailable",
            "next_action": "Run diagnostics and configure the required local model and processing dependencies.",
        }
    if isinstance(error, FileNotFoundError) or "canonical" in text or "audio_path" in text or "recording_directory" in text or "peoples_directory" in text:
        return {
            "code": "invalid_local_processing_request",
            "next_action": "Retry from the Meeting Hub canonical record. No file outside that record was read or written.",
        }
    return {
        "code": "local_processing_failed",
        "next_action": "Review the local processing status and retry the failed stage after resolving the reported dependency.",
    }


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(description="Meeting Hub local processing boundary")
    parser.add_argument("--request", choices=["-"], required=True, help="Read one JSON request from stdin")
    parser.parse_args()
    try:
        result = execute_request(read_request())
    except Exception as error:
        print(json.dumps({"ok": False, "error": public_error(error)}, sort_keys=True), flush=True)
        return 2
    print(json.dumps(result, sort_keys=True), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
