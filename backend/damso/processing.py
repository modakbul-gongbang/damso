"""Local-only STT and diarization pipeline for the canonical folder contract.

The production adapters load mlx-whisper and sherpa-onnx lazily so the app can
remain usable for browsing and speaker review when local models are absent.
There is deliberately no hosted STT fallback in this module.
"""

from __future__ import annotations

import fcntl
import json
import os
import re
import signal
import shutil
import stat
import subprocess
import sys
import tempfile
import unicodedata
import uuid
import wave
from collections import defaultdict
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterator, Mapping, Protocol, Sequence

from .contracts import ContractError, apply_resolutions, atomic_write_json, ensure_safe_stem, normalize_hint, write_phase_one
from .model_setup import SHERPA_EMBEDDING_FILENAME, WHISPER_DIRECTORY_NAME, default_model_root
from .nme_sc import cluster_embeddings
from .people import VOICE_EMBEDDING_MODEL, append_person_note, apply_people_resolutions, compatible_voice_candidates, remove_person_alias, set_person_email


class ProcessingError(RuntimeError):
    pass


class ProcessingTerminated(BaseException):
    """Private control flow used to unwind one-shot processing on app exit."""


MAX_REQUEST_BYTES = 64 * 1024
COMBINED_AUDIO_FILENAME = "combined-audio.m4a"
PHASE_ONE_IN_PROGRESS_FILENAME = "phase-one.in-progress.json"
PHASE_ONE_COMPLETE_FILENAME = "phase-one.complete.json"
FRAGMENT_TOTAL_SECONDS_CAP = 60.0
FRAGMENT_SPEECH_RATIO = 0.05
MAX_WHISPER_WORKER_OUTPUT_BYTES = 16 * 1024 * 1024
OWNED_SUBPROCESS_TERMINATION_GRACE_SECONDS = 5.0

# Speaker embedding dominates diarization CPU. Measured on a 55 minute meeting,
# four threads cost 1046s of CPU for 307s of wall clock, while two cost 613s for
# 337s. Trading 30s of wall clock for 433s of CPU is the better deal for work
# that runs in the background while the user keeps using the Mac.
SHERPA_EMBEDDING_THREADS = 2

# sherpa-onnx's Python bindings only expose the fused segmentation+embedding+
# clustering call, with no way to get segment boundaries before clustering
# merges anything. A clustering threshold near zero is used as a boundary-only
# proxy instead: cutree_cdist (see fastcluster's hclust-cpp) walks merge
# heights ascending and stops at the first one >= threshold, so a threshold
# below any real cosine dissimilarity keeps every raw segment in its own
# cluster. Measured on a real 3-minute clip: threshold=0.0 gave 183 segments
# with 179 distinct labels, i.e. almost 1:1. A tiny positive epsilon avoids a
# floating-point tie landing exactly on zero.
RAW_BOUNDARY_CLUSTERING_THRESHOLD = 1e-6
MIN_NMESC_SEGMENT_SAMPLES = int(0.3 * 16_000)
NMESC_MAX_SPEAKERS_CAP = 20


class Transcriber(Protocol):
    def transcribe(self, audio_path: Path, hints: Mapping[str, Any]) -> list[dict[str, Any]]: ...


class Diarizer(Protocol):
    def diarize(self, audio_path: Path, num_speakers: int | None) -> list[dict[str, Any]]: ...


class SpeakerEmbedder(Protocol):
    def speaker_embeddings(self, audio_path: Path, intervals: Sequence[Mapping[str, Any]]) -> dict[str, list[float]]: ...


def begin_phase_one_attempt(recording_directory: Path) -> str:
    """Invalidate every older recovery candidate before expensive processing."""
    generation_id = uuid.uuid4().hex
    atomic_write_json(
        recording_directory / PHASE_ONE_IN_PROGRESS_FILENAME,
        {"generation_id": generation_id, "version": 1},
    )
    return generation_id


def captured_participant_names(recording_directory: Path) -> list[str]:
    """Read display names without making a malformed capture file fatal."""
    path = recording_directory / "participants.json"
    if not path.is_file() or path.is_symlink():
        return []
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return []
    entries = payload.get("participants") if isinstance(payload, Mapping) else None
    if not isinstance(entries, list):
        return []
    names: list[str] = []
    seen: set[str] = set()
    for entry in entries:
        if not isinstance(entry, Mapping) or not isinstance(entry.get("name"), str):
            continue
        name = entry["name"].strip()
        key = name.casefold()
        if name and key not in seen:
            seen.add(key)
            names.append(name)
    return names


def merge_participant_hints(hints: Mapping[str, Any] | None, captured_names: Sequence[str]) -> dict[str, Any]:
    """Normalize request hints and append captured names in stable order."""
    try:
        merged = normalize_hint(hints)
    except ContractError as error:
        raise ProcessingError(str(error)) from error
    participants: list[str] = []
    seen: set[str] = set()
    for raw_name in [*merged["participants"], *captured_names]:
        name = str(raw_name).strip()
        key = name.casefold()
        if name and key not in seen:
            seen.add(key)
            participants.append(name)
    merged["participants"] = participants
    return merged


def relabel_speaker_intervals(intervals: Sequence[Mapping[str, Any]]) -> list[dict[str, Any]]:
    """Copy, timeline-sort, and assign contiguous labels by first appearance."""
    ordered = sorted(
        (dict(interval) for interval in intervals),
        key=lambda interval: (float(interval["start"]), float(interval["end"]), str(interval["speaker"])),
    )
    labels: dict[str, str] = {}
    for interval in ordered:
        old = str(interval["speaker"])
        if old not in labels:
            labels[old] = f"SPEAKER_{len(labels):02d}"
        interval["speaker"] = labels[old]
    return ordered


def merge_tiny_speaker_fragments(intervals: Sequence[Mapping[str, Any]]) -> list[dict[str, Any]]:
    """Merge speaker labels whose total speaking time is a sliver of the meeting.

    Sherpa-onnx's clustering over-splits real speakers into short-lived extra
    labels far more often than it produces a genuinely brief real speaker, so
    this merges by total duration alone (regardless of any single turn's
    length): a speaker under the duration cap gets folded into whichever
    substantive neighbor talks around them most. An earlier version also
    required every one of a candidate's turns to be <=3 seconds, which made
    this nearly a no-op on real conversational audio (turns of 5-60s are
    normal) and left large over-segmentation uncorrected.
    """
    ordered = sorted(
        (dict(interval) for interval in intervals),
        key=lambda interval: (float(interval["start"]), float(interval["end"]), str(interval["speaker"])),
    )
    if not ordered:
        return []

    totals: dict[str, float] = defaultdict(float)
    for interval in ordered:
        speaker = str(interval["speaker"])
        duration = max(0.0, float(interval["end"]) - float(interval["start"]))
        totals[speaker] += duration
    total_speech = sum(totals.values())
    candidate_limit = min(FRAGMENT_TOTAL_SECONDS_CAP, total_speech * FRAGMENT_SPEECH_RATIO)
    candidates = {speaker for speaker, total in totals.items() if total < candidate_limit}
    substantive = set(totals) - candidates
    if not candidates or not substantive:
        return relabel_speaker_intervals(ordered)

    votes: dict[str, dict[str, float]] = {speaker: defaultdict(float) for speaker in candidates}
    for index, interval in enumerate(ordered):
        candidate = str(interval["speaker"])
        if candidate not in candidates:
            continue
        previous = next(
            (ordered[position] for position in range(index - 1, -1, -1) if str(ordered[position]["speaker"]) in substantive),
            None,
        )
        following = next(
            (ordered[position] for position in range(index + 1, len(ordered)) if str(ordered[position]["speaker"]) in substantive),
            None,
        )
        for neighbor in (previous, following):
            if neighbor is None:
                continue
            target = str(neighbor["speaker"])
            votes[candidate][target] += max(0.0, float(neighbor["end"]) - float(neighbor["start"]))

    remap: dict[str, str] = {}
    for candidate, candidate_votes in votes.items():
        if not candidate_votes:
            continue
        ordered_votes = sorted(candidate_votes.items(), key=lambda item: (-item[1], item[0]))
        if len(ordered_votes) == 1 or ordered_votes[0][1] > ordered_votes[1][1]:
            remap[candidate] = ordered_votes[0][0]
    for interval in ordered:
        speaker = str(interval["speaker"])
        interval["speaker"] = remap.get(speaker, speaker)
    return relabel_speaker_intervals(ordered)


def participant_retry_target(auto_speaker_count: int, participant_count: int) -> int | None:
    if participant_count < 1 or auto_speaker_count <= participant_count:
        return None
    if participant_count <= 2:
        return participant_count
    anomaly_threshold = max(participant_count * 2, participant_count + 2)
    return participant_count if auto_speaker_count >= anomaly_threshold else None


def diarize_with_policy(
    diarizer: Diarizer,
    audio_path: Path,
    explicit_num_speakers: int | None,
    participant_count: int,
) -> list[dict[str, Any]]:
    if explicit_num_speakers is not None:
        return relabel_speaker_intervals(diarizer.diarize(audio_path, explicit_num_speakers))
    intervals = merge_tiny_speaker_fragments(diarizer.diarize(audio_path, None))
    initial_count = len({str(item["speaker"]) for item in intervals})
    retry_target = participant_retry_target(initial_count, participant_count)
    if retry_target is not None:
        candidate = merge_tiny_speaker_fragments(diarizer.diarize(audio_path, retry_target))
        candidate_count = len({str(item["speaker"]) for item in candidate})
        if candidate and candidate_count <= retry_target and candidate_count < initial_count:
            intervals = candidate
    return relabel_speaker_intervals(intervals)


def validate_decodable_audio(
    audio_path: Path,
    field_name: str,
    ffmpeg: str = "ffmpeg",
    duration_seconds: float | None = 0.25,
) -> None:
    """Decode a bounded prefix so a broken explicit source gets a stable error."""
    command = [
        ffmpeg,
        "-hide_banner",
        "-loglevel",
        "error",
        "-xerror",
        "-i",
        str(audio_path),
        "-map",
        "0:a:0",
    ]
    if duration_seconds is not None:
        command.extend(["-t", str(duration_seconds)])
    command.extend(["-f", "null", "-"])
    try:
        run_owned_subprocess(
            command,
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise ProcessingError(f"{field_name} could not be decoded as local audio") from error


def combine_audio_sources(
    recording_directory: Path,
    microphone_path: Path,
    system_audio_path: Path,
    ffmpeg: str = "ffmpeg",
) -> Path:
    """Atomically create the bounded, local playback and processing mix."""
    if not shutil.which(ffmpeg):
        raise ProcessingError("ffmpeg is required to combine local recording sources.")
    destination = recording_directory / COMBINED_AUDIO_FILENAME
    if destination.is_symlink():
        raise ProcessingError("combined audio destination must not be a symbolic link")
    for source in (microphone_path, system_audio_path):
        if source == destination:
            raise ProcessingError("combined audio destination must not replace a raw audio source")
        try:
            destination_matches_source = destination.exists() and os.path.samefile(destination, source)
        except OSError as error:
            raise ProcessingError("combined audio destination could not be compared safely") from error
        if destination_matches_source:
            raise ProcessingError("combined audio destination must not replace a raw audio source")
    validate_decodable_audio(microphone_path, "audio_path", ffmpeg)
    validate_decodable_audio(system_audio_path, "system_audio_path", ffmpeg)
    with cleanup_aware_processing_scope():
        with tempfile.NamedTemporaryFile(
            prefix=".combined-audio-",
            suffix=".m4a",
            dir=recording_directory,
            delete=False,
        ) as temporary:
            temporary_path = Path(temporary.name)
        filter_graph = (
            "[0:a]aresample=16000:async=1:first_pts=0,"
            "aformat=sample_fmts=fltp:channel_layouts=mono,volume=0.5[mic];"
            "[1:a]aresample=16000:async=1:first_pts=0,"
            "aformat=sample_fmts=fltp:channel_layouts=mono,volume=0.5[system];"
            "[mic][system]amix=inputs=2:duration=longest:dropout_transition=0:normalize=0[mixed]"
        )
        try:
            run_owned_subprocess(
                [
                    ffmpeg,
                    "-y",
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-xerror",
                    "-i",
                    str(microphone_path),
                    "-i",
                    str(system_audio_path),
                    "-filter_complex",
                    filter_graph,
                    "-map",
                    "[mixed]",
                    "-vn",
                    "-ar",
                    "16000",
                    "-ac",
                    "1",
                    "-c:a",
                    "aac",
                    "-b:a",
                    "96k",
                    "-movflags",
                    "+faststart",
                    str(temporary_path),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            if not temporary_path.is_file() or temporary_path.stat().st_size == 0:
                raise ProcessingError("ffmpeg did not produce a usable combined audio file.")
            os.replace(temporary_path, destination)
        except subprocess.CalledProcessError as error:
            try:
                validate_decodable_audio(microphone_path, "audio_path", ffmpeg, duration_seconds=None)
                validate_decodable_audio(system_audio_path, "system_audio_path", ffmpeg, duration_seconds=None)
            except ProcessingError as source_error:
                raise source_error from error
            raise ProcessingError("The captured audio sources could not be combined locally.") from error
        except OSError as error:
            raise ProcessingError("The captured audio sources could not be combined locally.") from error
        finally:
            temporary_path.unlink(missing_ok=True)
    return destination


@dataclass(frozen=True)
class LocalModelConfig:
    mlx_whisper_model_directory: Path
    sherpa_model_directory: Path

    @classmethod
    def from_environment(cls, environment: Mapping[str, str] | None = None) -> "LocalModelConfig":
        environment = environment or os.environ
        root = default_model_root()
        whisper = environment.get("DAMSO_MLX_WHISPER_MODEL_DIR") or str(root / WHISPER_DIRECTORY_NAME)
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
MEANINGFUL_TEXT = re.compile(r"[가-힣0-9A-Za-z]")

# Whisper continues the style of initial_prompt. An unpunctuated bag of terms
# therefore teaches it to emit unpunctuated speech: measured on a 10 minute
# Korean meeting, a bare "topic term term" prompt dropped sentence enders to
# 3.8 per 1k hangul and produced 200 ellipses. This fully punctuated carrier
# restores them. Topic and terms are folded into whole sentences because a
# bare "주요 용어: a, b, c" list leaks verbatim into the first segment.
WHISPER_STYLE_CARRIER = (
    "다음은 한국어 회의 녹취록입니다. 모든 문장은 맞춤법과 구두점을 갖추어 적습니다. "
    "안녕하세요, 오늘 회의를 시작하겠습니다. 네, 그러면 먼저 진행 상황부터 공유드릴게요."
)


# Whisper truncates initial_prompt to the last 223 tokens. The carrier costs
# about 52 and Korean names average 6, so the whole people directory does not
# fit and is capped here rather than being silently cut off mid-list.
MAX_PROMPT_NAMES = 20
MAX_PROMPT_NAME_CHARS = 100
ARCHIVED_PEOPLE_DIRECTORY = "archive"


def name_variants(entry: str) -> list[str]:
    """Split a profile label such as "송주은(오뜨)" into the names people say."""
    label = unicodedata.normalize("NFC", str(entry)).strip()
    base, _, remainder = label.partition("(")
    candidates = [base.strip(), remainder.rstrip(")").strip()]
    # "나(이호연)" is the owner's own profile; the pronoun is never spoken as a name.
    return [candidate for candidate in candidates if candidate and candidate != "나"]


def known_people_names(peoples_directory: Path | None) -> list[str]:
    """List profile names, most recently touched first.

    macOS stores these directory names NFD-decomposed, so they are normalized
    here; skipping that silently breaks every comparison against typed text.
    """
    if peoples_directory is None or not peoples_directory.is_dir():
        return []
    entries: list[tuple[float, str]] = []
    try:
        for entry in peoples_directory.iterdir():
            if entry.name.startswith(".") or entry.name == ARCHIVED_PEOPLE_DIRECTORY:
                continue
            if not entry.is_dir() or entry.is_symlink():
                continue
            try:
                modified = entry.stat().st_mtime
            except OSError:
                continue
            entries.append((modified, entry.name))
    except OSError:
        return []
    entries.sort(key=lambda item: (-item[0], item[1]))
    return [name for _, name in entries]


def select_prompt_names(participants: Sequence[Any], known: Sequence[Any]) -> list[str]:
    """Prefer this meeting's participants, then recently seen people, to budget."""
    selected: list[str] = []
    seen: set[str] = set()
    used = 0
    for entry in [*participants, *known]:
        for name in name_variants(entry):
            key = name.casefold()
            if key in seen:
                continue
            if len(selected) >= MAX_PROMPT_NAMES or used + len(name) > MAX_PROMPT_NAME_CHARS:
                return selected
            seen.add(key)
            selected.append(name)
            used += len(name)
    return selected


def build_initial_prompt(
    topic: Any,
    domain_terms: Sequence[Any],
    names: Sequence[Any] = (),
) -> str:
    """Compose the punctuated style carrier with any caller-supplied context."""
    sentences = [WHISPER_STYLE_CARRIER]
    topic_text = str(topic or "").strip()
    if topic_text:
        sentences.append(f"이번 회의 주제는 {topic_text}입니다.")
    terms = [str(term).strip() for term in domain_terms if str(term).strip()]
    if terms:
        sentences.append(f"오늘은 {', '.join(terms)} 이야기를 나눕니다.")
    if names:
        # Deliberately vague about what each entry is: a profile label carries a
        # person's name, a nickname, or their company, and the point here is
        # lexical bias for the decoder rather than a factual claim.
        sentences.append(f"자주 언급되는 이름은 {', '.join(str(name) for name in names)}입니다.")
    return " ".join(sentences)


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


def normalize_mlx_segments(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        raise ProcessingError("mlx-whisper did not return transcript segments")
    normalized: list[dict[str, Any]] = []
    for segment in value:
        if not isinstance(segment, Mapping):
            raise ProcessingError("mlx-whisper returned an invalid transcript segment")
        text = str(segment.get("text", "")).strip()
        if not text or not MEANINGFUL_TEXT.search(text):
            # Whisper occasionally emits pure noise on low-energy stretches:
            # a lone "!" or a burst of an unrelated script. Nothing without a
            # Hangul or alphanumeric character carries meeting content.
            continue
        try:
            start = float(segment["start"])
            end = float(segment["end"])
        except (KeyError, TypeError, ValueError) as error:
            raise ProcessingError("mlx-whisper returned an invalid transcript segment") from error
        # Those same noise stretches also produce inverted spans, which would
        # give the player a negative duration to seek across.
        normalized.append({"start": start, "end": max(start, end), "text": text})
    return clean_transcribed_segments(normalized)


def mlx_whisper_segments(audio_path: Path, model_directory: Path, initial_prompt: str | None) -> list[dict[str, Any]]:
    try:
        import mlx_whisper
    except ImportError as error:
        raise ProcessingError("mlx-whisper is not installed in the configured Python environment.") from error
    result = mlx_whisper.transcribe(
        str(audio_path),
        path_or_hf_repo=str(model_directory),
        language="ko",
        initial_prompt=initial_prompt,
        word_timestamps=False,
    )
    if not isinstance(result, Mapping):
        raise ProcessingError("mlx-whisper did not return a transcript object")
    return normalize_mlx_segments(result.get("segments"))


def whisper_worker_output_descriptor(value: Any) -> int:
    """Accept only a new, writable, unlinked regular file inherited by the worker."""
    if isinstance(value, bool) or not isinstance(value, int) or value < 3:
        raise ProcessingError("whisper worker output descriptor is invalid")
    try:
        descriptor_status = os.fstat(value)
        descriptor_flags = fcntl.fcntl(value, fcntl.F_GETFL)
    except OSError as error:
        raise ProcessingError("whisper worker output descriptor is invalid") from error
    if (
        not stat.S_ISREG(descriptor_status.st_mode)
        or descriptor_status.st_nlink != 0
        or descriptor_status.st_size != 0
        or (descriptor_flags & os.O_ACCMODE) == os.O_RDONLY
    ):
        raise ProcessingError("whisper worker output descriptor is invalid")
    os.set_inheritable(value, False)
    return value


def write_whisper_worker_segments(output_descriptor: int, segments: Sequence[Mapping[str, Any]]) -> None:
    """Write a bounded transcript handoff that has no visible filesystem path."""
    encoder = json.JSONEncoder(ensure_ascii=False, sort_keys=True)
    completed = False
    try:
        os.ftruncate(output_descriptor, 0)
        os.lseek(output_descriptor, 0, os.SEEK_SET)
        total_bytes = 0
        for text_chunk in encoder.iterencode(segments):
            remaining_limit = MAX_WHISPER_WORKER_OUTPUT_BYTES - total_bytes - 1
            if len(text_chunk) > remaining_limit:
                raise ProcessingError("whisper worker transcript segments are too large")
            encoded_chunk = text_chunk.encode("utf-8")
            if len(encoded_chunk) > remaining_limit:
                raise ProcessingError("whisper worker transcript segments are too large")
            remaining = memoryview(encoded_chunk)
            while remaining:
                written = os.write(output_descriptor, remaining)
                if written <= 0:
                    raise OSError("whisper worker output write made no progress")
                remaining = remaining[written:]
            total_bytes += len(encoded_chunk)
        if total_bytes + 1 > MAX_WHISPER_WORKER_OUTPUT_BYTES:
            raise ProcessingError("whisper worker transcript segments are too large")
        if os.write(output_descriptor, b"\n") != 1:
            raise OSError("whisper worker output write made no progress")
        os.fsync(output_descriptor)
        completed = True
    except OSError as error:
        raise ProcessingError("whisper worker could not write transcript segments") from error
    finally:
        if not completed:
            try:
                os.ftruncate(output_descriptor, 0)
                os.lseek(output_descriptor, 0, os.SEEK_SET)
            except OSError:
                pass


def execute_whisper_worker(request: Mapping[str, Any]) -> None:
    output_descriptor = whisper_worker_output_descriptor(request.get("output_fd"))
    raw_audio_path = request.get("audio_path")
    raw_model_directory = request.get("model_directory")
    initial_prompt = request.get("initial_prompt")
    if not isinstance(raw_audio_path, str) or not isinstance(raw_model_directory, str):
        raise ProcessingError("whisper worker request is invalid")
    if initial_prompt is not None and not isinstance(initial_prompt, str):
        raise ProcessingError("whisper worker request is invalid")
    audio_candidate = Path(raw_audio_path)
    if audio_candidate.is_symlink():
        raise ProcessingError("whisper worker audio input is invalid")
    try:
        audio_path = audio_candidate.resolve(strict=True)
        model_directory = Path(raw_model_directory).resolve(strict=True)
    except OSError as error:
        raise ProcessingError("whisper worker input is unavailable") from error
    if not audio_path.is_file() or not model_directory.is_dir():
        raise ProcessingError("whisper worker input is unavailable")
    segments = mlx_whisper_segments(audio_path, model_directory, initial_prompt)
    write_whisper_worker_segments(output_descriptor, segments)


@contextmanager
def deferred_processing_termination_handlers(
    force_stop: Callable[[], None],
) -> Iterator[Callable[[], None]]:
    """Defer a spawn-time signal until the parent owns the child process handle."""
    selected_signals = (signal.SIGTERM, signal.SIGHUP)
    previous = {selected: signal.getsignal(selected) for selected in selected_signals}
    request_count = 0
    armed = False
    dispatched = False

    def interrupt_after_cleanup(_signum: int, _frame: Any) -> None:
        nonlocal request_count, dispatched
        request_count += 1
        if dispatched or request_count > 1:
            dispatched = True
            force_stop()
            raise ProcessingTerminated("local processing was terminated again")
        if armed:
            dispatched = True
            raise ProcessingTerminated("local processing was terminated")

    def arm() -> None:
        nonlocal armed, dispatched
        armed = True
        if request_count and not dispatched:
            dispatched = True
            raise ProcessingTerminated("local processing was terminated")

    try:
        for selected in selected_signals:
            signal.signal(selected, interrupt_after_cleanup)
        yield arm
    finally:
        for selected, handler in previous.items():
            signal.signal(selected, handler)


@contextmanager
def cleanup_aware_processing_scope() -> Iterator[None]:
    """Make the first exit signal unwind a temporary-resource scope."""
    with deferred_processing_termination_handlers(lambda: None) as arm:
        arm()
        yield


def force_terminate_owned_process(process: subprocess.Popen[Any]) -> None:
    """Kill and reap a child after a repeated termination request."""
    if process.poll() is None:
        try:
            process.kill()
        except ProcessLookupError:
            pass
    try:
        process.wait()
    except ChildProcessError:
        pass


def terminate_owned_process(process: subprocess.Popen[Any]) -> None:
    """Gracefully terminate an owned child, escalating and always reaping it."""
    if process.poll() is not None:
        try:
            process.wait()
        except ChildProcessError:
            pass
        return
    try:
        process.terminate()
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=OWNED_SUBPROCESS_TERMINATION_GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        force_terminate_owned_process(process)


def terminate_whisper_worker(process: subprocess.Popen[str]) -> None:
    """Compatibility wrapper for the one-shot Whisper worker lifecycle."""
    terminate_owned_process(process)


def run_owned_subprocess(
    command: Sequence[str],
    *,
    check: bool = False,
    capture_output: bool = False,
    text: bool = False,
) -> subprocess.CompletedProcess[Any]:
    """Run one child with cleanup-aware termination around spawn and wait only."""
    process: subprocess.Popen[Any] | None = None

    def force_stop() -> None:
        if process is not None:
            force_terminate_owned_process(process)

    stdout_target = subprocess.PIPE if capture_output else None
    stderr_target = subprocess.PIPE if capture_output else None
    with deferred_processing_termination_handlers(force_stop) as arm:
        process = subprocess.Popen(
            list(command),
            stdout=stdout_target,
            stderr=stderr_target,
            text=text,
        )
        try:
            arm()
            stdout, stderr = process.communicate()
        except BaseException:
            terminate_owned_process(process)
            raise
    completed = subprocess.CompletedProcess(list(command), process.returncode, stdout, stderr)
    if check:
        completed.check_returncode()
    return completed


class MLXWhisperTranscriber:
    def __init__(self, config: LocalModelConfig):
        self.config = config

    def transcribe(self, audio_path: Path, hints: Mapping[str, Any]) -> list[dict[str, Any]]:
        self.config.validate()
        initial_prompt = build_initial_prompt(
            hints.get("topic"),
            hints.get("domain_terms", []),
            select_prompt_names(hints.get("participants", []), hints.get("known_people", [])),
        )
        with tempfile.TemporaryFile(prefix="damso-whisper-worker-", mode="w+b") as output:
            output_descriptor = whisper_worker_output_descriptor(output.fileno())
            request = {
                "audio_path": str(audio_path),
                "model_directory": str(self.config.mlx_whisper_model_directory),
                "initial_prompt": initial_prompt,
                "output_fd": output_descriptor,
            }
            process: subprocess.Popen[str] | None = None

            def force_stop() -> None:
                if process is not None:
                    force_terminate_owned_process(process)

            with deferred_processing_termination_handlers(force_stop) as arm:
                try:
                    process = subprocess.Popen(
                        [sys.executable, "-m", "damso.processing", "--whisper-worker", "-"],
                        stdin=subprocess.PIPE,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        text=True,
                        close_fds=True,
                        pass_fds=(output_descriptor,),
                    )
                except OSError as error:
                    raise ProcessingError("mlx-whisper worker could not be launched") from error
                try:
                    arm()
                    process.communicate(json.dumps(request, ensure_ascii=False))
                except BaseException:
                    terminate_whisper_worker(process)
                    raise
            if process.returncode != 0:
                raise ProcessingError("mlx-whisper worker failed to transcribe local audio")
            try:
                output.seek(0)
                encoded_payload = output.read(MAX_WHISPER_WORKER_OUTPUT_BYTES + 1)
            except OSError as error:
                raise ProcessingError("mlx-whisper worker transcript segments could not be read") from error
            if not encoded_payload:
                raise ProcessingError("mlx-whisper worker did not produce transcript segments")
            if len(encoded_payload) > MAX_WHISPER_WORKER_OUTPUT_BYTES:
                raise ProcessingError("mlx-whisper worker transcript segments are too large")
            try:
                payload = json.loads(encoded_payload)
            except (UnicodeError, json.JSONDecodeError) as error:
                raise ProcessingError("mlx-whisper worker produced invalid transcript segments") from error
            return normalize_mlx_segments(payload)


class SherpaDiarizer:
    def __init__(self, config: LocalModelConfig, ffmpeg: str = "ffmpeg"):
        self.config = config
        self.ffmpeg = ffmpeg

    def diarize(self, audio_path: Path, num_speakers: int | None) -> list[dict[str, Any]]:
        self.config.validate()
        if not shutil.which(self.ffmpeg):
            raise ProcessingError("ffmpeg is required for local sherpa-onnx diarization.")
        try:
            from sherpa_onnx import (
                FastClusteringConfig,
                OfflineSpeakerDiarization,
                OfflineSpeakerDiarizationConfig,
                OfflineSpeakerSegmentationModelConfig,
                OfflineSpeakerSegmentationPyannoteModelConfig,
                SpeakerEmbeddingExtractor,
                SpeakerEmbeddingExtractorConfig,
            )
        except ImportError as error:
            raise ProcessingError("sherpa-onnx and numpy are required for local diarization.") from error

        waveform = self.waveform(audio_path)
        segmentation = OfflineSpeakerSegmentationModelConfig()
        segmentation.pyannote = OfflineSpeakerSegmentationPyannoteModelConfig(
            str(self.config.sherpa_model_directory / "sherpa-onnx-pyannote-segmentation-3-0" / "model.onnx")
        )
        embedding_config = SpeakerEmbeddingExtractorConfig(
            model=str(self.config.sherpa_model_directory / SHERPA_EMBEDDING_FILENAME),
            num_threads=SHERPA_EMBEDDING_THREADS,
            debug=False,
            provider="cpu",
        )

        # NME-SC only replaces the clustering decision when an oracle speaker
        # count is available (from the user's pre-recording speaker-count
        # prompt). Its own eigengap-based count *estimate* was validated
        # against two real recordings (one previously known-hard, one with a
        # known-good 2-speaker ground truth) and collapsed both to a single
        # speaker: the single-scale raw-segment affinity graph this pipeline
        # feeds it is sparser and noisier than the fixed-duration overlapping
        # multiscale windows NME-SC's g_p heuristic was tuned against in
        # NeMo, so a larger, fully-connected neighbor count always scores
        # better than the smaller one that actually splits along speakers.
        # Auto mode (no count given) keeps the existing AHC pass.
        if num_speakers is None:
            clustering = FastClusteringConfig(num_clusters=-1, threshold=0.95)
            config = OfflineSpeakerDiarizationConfig(
                segmentation=segmentation,
                embedding=embedding_config,
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

        boundary_config = OfflineSpeakerDiarizationConfig(
            segmentation=segmentation,
            embedding=embedding_config,
            clustering=FastClusteringConfig(num_clusters=-1, threshold=RAW_BOUNDARY_CLUSTERING_THRESHOLD),
            min_duration_on=0.3,
            min_duration_off=0.5,
        )
        if not boundary_config.validate():
            raise ProcessingError("sherpa-onnx configuration validation failed")
        boundary_diarizer = OfflineSpeakerDiarization(boundary_config)
        if boundary_diarizer.sample_rate != 16_000:
            raise ProcessingError("sherpa-onnx sample rate is incompatible with local input")
        raw_segments = boundary_diarizer.process(waveform).sort_by_start_time()
        intervals = [{"start": float(segment.start), "end": float(segment.end)} for segment in raw_segments]
        if not intervals:
            return []

        import numpy as np

        extractor = SpeakerEmbeddingExtractor(embedding_config)
        vectors: list[Any] = []
        embedded_indices: list[int] = []
        for index, interval in enumerate(intervals):
            start_sample = max(0, int(interval["start"] * 16_000))
            end_sample = min(len(waveform), int(interval["end"] * 16_000))
            if end_sample - start_sample < MIN_NMESC_SEGMENT_SAMPLES:
                continue
            stream = extractor.create_stream()
            stream.accept_waveform(16_000, waveform[start_sample:end_sample])
            stream.input_finished()
            if not extractor.is_ready(stream):
                continue
            vector = np.asarray(extractor.compute(stream), dtype=np.float32).reshape(-1)
            if vector.size != extractor.dim or not np.all(np.isfinite(vector)):
                continue
            vectors.append(vector)
            embedded_indices.append(index)
        if not vectors:
            return []

        labels = cluster_embeddings(
            np.stack(vectors),
            max_num_speakers=min(NMESC_MAX_SPEAKERS_CAP, len(vectors)),
            oracle_num_speakers=num_speakers,
        )
        label_by_index: dict[int, int] = dict(zip(embedded_indices, (int(label) for label in labels)))
        for index in range(len(intervals)):
            if index in label_by_index:
                continue
            neighbor = next((label_by_index[i] for i in range(index - 1, -1, -1) if i in label_by_index), None)
            if neighbor is None:
                neighbor = next(label_by_index[i] for i in range(index + 1, len(intervals)) if i in label_by_index)
            label_by_index[index] = neighbor

        return [
            {"start": interval["start"], "end": interval["end"], "speaker": f"SPEAKER_{label_by_index[index]:02d}"}
            for index, interval in enumerate(intervals)
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
                num_threads=SHERPA_EMBEDDING_THREADS,
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
        with cleanup_aware_processing_scope():
            with tempfile.TemporaryDirectory(prefix="damso-diarize-") as temporary:
                wav_path = Path(temporary) / "input.wav"
                run_owned_subprocess(
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

    def run_phase_one(
        self,
        recording_directory: Path,
        audio_path: Path,
        hints: Mapping[str, Any] | None = None,
        source_files: Sequence[Path] | None = None,
        generation_id: str | None = None,
    ) -> dict[str, Any]:
        if not audio_path.is_file():
            raise ProcessingError("audio input must be a local regular file")
        generation_id = generation_id or begin_phase_one_attempt(recording_directory)
        effective_hints = merge_participant_hints(hints, captured_participant_names(recording_directory))
        # Seeds the transcription prompt with names the user already knows so
        # Whisper spells them consistently. write_phase_one re-normalizes the
        # hint, so this in-memory key never reaches hint.json.
        effective_hints["known_people"] = known_people_names(canonical_peoples_for_recording(recording_directory))
        # Whisper runs in a one-shot child process. Its large Metal model is
        # fully reclaimed by the OS before Sherpa loads its native runtimes.
        # Overlapping the two stages is tempting but both arm SIGTERM/SIGHUP
        # handlers to reap their children, and Python only permits that on the
        # main thread, so neither can be moved onto a worker thread as-is.
        raw_segments = self.transcriber.transcribe(audio_path, effective_hints)
        intervals = diarize_with_policy(
            self.diarizer,
            audio_path,
            effective_hints.get("num_speakers"),
            len(effective_hints["participants"]),
        )
        embedding_method = getattr(self.diarizer, "speaker_embeddings", None)
        speaker_embeddings = embedding_method(audio_path, intervals) if callable(embedding_method) else {}
        transcript = {
            "generation_id": generation_id,
            "source_file": audio_path.name,
            "source_files": [source.name for source in (source_files or [audio_path])],
            "language": "ko",
            "model": WHISPER_DIRECTORY_NAME,
            "duration": max((float(segment["end"]) for segment in raw_segments), default=0.0),
            "segments": assign_speakers(raw_segments, intervals),
            "speakers": [],
        }
        transcript["speakers"] = sorted({segment["speaker"] for segment in transcript["segments"]})
        identification = identification_proposals(transcript, speaker_embeddings, canonical_peoples_for_recording(recording_directory))
        identification["generation_id"] = generation_id
        try:
            write_phase_one(recording_directory, effective_hints, transcript, identification)
            write_speaker_embeddings(recording_directory, speaker_embeddings)
            atomic_write_json(
                recording_directory / PHASE_ONE_COMPLETE_FILENAME,
                {"generation_id": generation_id, "version": 1},
            )
            (recording_directory / PHASE_ONE_IN_PROGRESS_FILENAME).unlink()
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
        audio_path = canonical_audio_path(recording_directory, request.get("audio_path"), field_name="audio_path")
        raw_system_audio_path = request.get("system_audio_path")
        system_audio_path = (
            canonical_audio_path(recording_directory, raw_system_audio_path, field_name="system_audio_path")
            if raw_system_audio_path is not None
            else legacy_system_audio_path(recording_directory, audio_path)
        )
        try:
            same_source = system_audio_path is not None and os.path.samefile(system_audio_path, audio_path)
        except OSError as error:
            raise ProcessingError("audio sources could not be compared safely") from error
        if same_source:
            raise ProcessingError("system_audio_path must identify a second local audio source")
        hints = request.get("hints", {})
        if not isinstance(hints, Mapping):
            raise ProcessingError("processing hints must be an object")
        generation_id = begin_phase_one_attempt(recording_directory)
        processing_audio_path = (
            combine_audio_sources(recording_directory, audio_path, system_audio_path)
            if system_audio_path is not None
            else audio_path
        )
        source_files = [audio_path, *([system_audio_path] if system_audio_path is not None else [])]
        config = LocalModelConfig.from_environment(environment)
        pipeline = LocalProcessingPipeline(MLXWhisperTranscriber(config), SherpaDiarizer(config))
        transcript = pipeline.run_phase_one(
            recording_directory,
            processing_audio_path,
            hints,
            source_files=source_files,
            generation_id=generation_id,
        )
        return {
            "ok": True,
            "operation": operation,
            "recording_stem": recording_directory.name,
            "stage": "speaker_review",
            "speaker_count": len(transcript["speakers"]),
            "processed_audio_file": processing_audio_path.name if system_audio_path is not None else None,
            "artifact_files": [
                *([processing_audio_path.name] if system_audio_path is not None else []),
                "hint.json",
                "transcript.raw.json",
                "identification.json",
                "speaker-embeddings.npz",
                "phase-one.complete.json",
                "transcript.md",
            ],
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


def canonical_audio_path(recording_directory: Path, raw_value: Any, field_name: str = "audio_path") -> Path:
    if not isinstance(raw_value, str) or not raw_value:
        raise ProcessingError(f"{field_name} is required")
    requested_path = Path(raw_value).expanduser()
    if requested_path.is_symlink():
        raise ProcessingError(f"{field_name} must not be a symbolic link")
    try:
        audio_path = requested_path.resolve(strict=True)
    except (FileNotFoundError, OSError) as error:
        raise ProcessingError(f"{field_name} must identify an existing local audio file") from error
    if not audio_path.is_file():
        raise ProcessingError(f"{field_name} must be a local regular file")
    try:
        canonical_directory = recording_directory.resolve(strict=True)
    except (FileNotFoundError, OSError) as error:
        raise ProcessingError("recording_directory must be an existing canonical record") from error
    if audio_path.parent != canonical_directory:
        raise ProcessingError(f"{field_name} must stay directly inside its canonical record")
    return audio_path


def legacy_system_audio_path(recording_directory: Path, audio_path: Path) -> Path | None:
    """Adopt the sibling written by pre-contract local Damso recordings."""
    metadata_path = recording_directory / "meeting.json"
    try:
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    if not isinstance(metadata, Mapping) or metadata.get("source") != "local":
        return None
    candidate = recording_directory / "system-audio.m4a"
    if candidate == audio_path or not candidate.exists():
        return None
    return canonical_audio_path(recording_directory, str(candidate), field_name="system_audio_path")


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


def isolate_request_process_group() -> None:
    """Make the request root a group leader so its late-spawned children are addressable."""
    if os.getpgrp() == os.getpid():
        return
    try:
        os.setpgid(0, 0)
    except OSError as error:
        raise ProcessingError("local processing process group could not be isolated") from error


def public_error(error: Exception) -> dict[str, str]:
    text = str(error).lower()
    if "system_audio_path" in text:
        return {
            "code": "captured_system_audio_unavailable",
            "next_action": "Restore the captured system audio inside this meeting folder, then retry local processing.",
        }
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
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--request", choices=["-"], help="Read one JSON request from stdin")
    mode.add_argument("--whisper-worker", choices=["-"], help=argparse.SUPPRESS)
    arguments = parser.parse_args()
    if arguments.whisper_worker:
        try:
            execute_whisper_worker(read_request())
        except Exception:
            return 2
        return 0
    try:
        isolate_request_process_group()
        result = execute_request(read_request())
    except ProcessingTerminated:
        return 143
    except Exception as error:
        print(json.dumps({"ok": False, "error": public_error(error)}, sort_keys=True), flush=True)
        return 2
    print(json.dumps(result, sort_keys=True), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
