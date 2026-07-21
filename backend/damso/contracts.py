"""Stable local folder contracts shared by the macOS app and Python helpers.

This module intentionally has no network client and no dependency on the
previous vault.  It writes only inside a caller-provided recording directory.
"""

from __future__ import annotations

import json
import os
import re
import tempfile
from pathlib import Path
from typing import Any, Mapping


REQUIRED_RECORD_FILES = {
    "hint.json",
    "identification.json",
    "resolutions.yaml",
    "transcript.raw.json",
    "transcript.json",
    "transcript.md",
}

# "name_only" labels the transcript with a typed name without ever creating a
# peoples profile (people.py only acts on match/new/me).
SPEAKER_ACTIONS = {"match", "new", "me", "skip", "name_only"}
UNSAFE_STEM = re.compile(r"(^$|[\\/]|^\.{1,2}$)")


class ContractError(ValueError):
    """Raised before an invalid record can become canonical."""


def ensure_safe_stem(stem: str) -> str:
    if UNSAFE_STEM.search(stem):
        raise ContractError("recording stem must be one local directory name")
    return stem


def normalize_hint(value: Mapping[str, Any] | None) -> dict[str, Any]:
    value = value or {}
    participants = value.get("participants", [])
    domain_terms = value.get("domain_terms", [])
    if not isinstance(participants, list) or not all(isinstance(item, str) for item in participants):
        raise ContractError("participants must be a list of strings")
    if not isinstance(domain_terms, list) or not all(isinstance(item, str) for item in domain_terms):
        raise ContractError("domain_terms must be a list of strings")
    num_speakers = value.get("num_speakers")
    if num_speakers is not None and (not isinstance(num_speakers, int) or num_speakers < 1):
        raise ContractError("num_speakers must be a positive integer")
    topic = value.get("topic")
    if topic is not None and not isinstance(topic, str):
        raise ContractError("topic must be a string")
    return {
        "participants": [item.strip() for item in participants if item.strip()],
        "topic": topic.strip() if isinstance(topic, str) and topic.strip() else None,
        "domain_terms": [item.strip() for item in domain_terms if item.strip()],
        "num_speakers": num_speakers,
    }


def atomic_write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as temporary:
        json.dump(payload, temporary, ensure_ascii=False, indent=2, sort_keys=True)
        temporary.write("\n")
        temporary_path = Path(temporary.name)
    os.replace(temporary_path, path)


def atomic_write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as temporary:
        temporary.write(content)
        temporary_path = Path(temporary.name)
    os.replace(temporary_path, path)


def validate_transcript(payload: Mapping[str, Any]) -> dict[str, Any]:
    segments = payload.get("segments")
    speakers = payload.get("speakers")
    if not isinstance(segments, list) or not isinstance(speakers, list):
        raise ContractError("transcript requires speakers and segments")
    normalized_segments = []
    for segment in segments:
        if not isinstance(segment, Mapping):
            raise ContractError("each transcript segment must be an object")
        speaker = segment.get("speaker")
        start = segment.get("start")
        end = segment.get("end")
        text = segment.get("text")
        if not isinstance(speaker, str) or not isinstance(text, str):
            raise ContractError("segment speaker and text must be strings")
        if not isinstance(start, (float, int)) or not isinstance(end, (float, int)) or end < start:
            raise ContractError("segment timestamps are invalid")
        normalized_segments.append({"speaker": speaker, "start": round(float(start), 2), "end": round(float(end), 2), "text": text.strip()})
    normalized = {
        "source_file": str(payload.get("source_file", "audio")),
        "language": str(payload.get("language", "ko")),
        "model": str(payload.get("model", "large-v3")),
        "duration": round(float(payload.get("duration", 0)), 2),
        "speakers": [str(item) for item in speakers],
        "segments": normalized_segments,
    }
    generation_id = payload.get("generation_id")
    if generation_id is not None:
        if not isinstance(generation_id, str) or not generation_id.strip():
            raise ContractError("generation_id must be a non-empty string")
        normalized["generation_id"] = generation_id.strip()
    if "source_files" in payload:
        source_files = payload.get("source_files")
        if not isinstance(source_files, list) or not source_files or not all(isinstance(item, str) for item in source_files):
            raise ContractError("source_files must be a non-empty list of local basenames")
        normalized_sources: list[str] = []
        for item in source_files:
            if not item or item in {".", ".."} or "/" in item or "\\" in item:
                raise ContractError("source_files must contain local basenames only")
            if item not in normalized_sources:
                normalized_sources.append(item)
        normalized["source_files"] = normalized_sources
    return normalized


def transcript_markdown(transcript: Mapping[str, Any]) -> str:
    lines = ["# Transcript", ""]
    for segment in transcript["segments"]:
        lines.append(f"[{format_timestamp(segment['start'])}] {segment['speaker']}: {segment['text']}")
    return "\n".join(lines) + "\n"


def write_phase_one(recording_dir: Path, hint: Mapping[str, Any] | None, transcript: Mapping[str, Any], identification: Mapping[str, Any]) -> None:
    normalized_hint = normalize_hint(hint)
    normalized_transcript = validate_transcript(transcript)
    if not isinstance(identification.get("proposals", {}), Mapping):
        raise ContractError("identification proposals must be an object")
    transcript_generation = normalized_transcript.get("generation_id")
    identification_generation = identification.get("generation_id")
    if transcript_generation is not None or identification_generation is not None:
        if transcript_generation != identification_generation:
            raise ContractError("phase-one artifacts must share one generation_id")
    atomic_write_json(recording_dir / "hint.json", normalized_hint)
    atomic_write_json(recording_dir / "transcript.raw.json", normalized_transcript)
    atomic_write_json(recording_dir / "identification.json", dict(identification))
    atomic_write_text(recording_dir / "transcript.md", transcript_markdown(normalized_transcript))


def apply_resolutions(recording_dir: Path, resolutions: Mapping[str, Mapping[str, Any]]) -> dict[str, Any]:
    raw_path = recording_dir / "transcript.raw.json"
    if not raw_path.exists():
        raise ContractError("phase one transcript is required before applying resolutions")
    transcript = validate_transcript(json.loads(raw_path.read_text(encoding="utf-8")))
    transcript_speakers = {segment["speaker"] for segment in transcript["segments"]}
    unknown_speakers = set(resolutions) - transcript_speakers
    if unknown_speakers:
        raise ContractError("speaker resolutions must reference the current phase one transcript")
    normalized: dict[str, dict[str, str | None]] = {}
    for speaker, resolution in resolutions.items():
        action = resolution.get("action")
        name = resolution.get("name")
        if action not in SPEAKER_ACTIONS:
            raise ContractError(f"unsupported resolution action for {speaker}")
        if action != "skip" and (not isinstance(name, str) or not name.strip()):
            raise ContractError(f"a name is required for {speaker}")
        normalized[speaker] = {"action": action, "name": name.strip() if isinstance(name, str) else None}

    for segment in transcript["segments"]:
        resolution = normalized.get(segment["speaker"])
        if resolution and resolution["action"] != "skip":
            segment["speaker"] = resolution["name"]
    transcript["speakers"] = sorted({segment["speaker"] for segment in transcript["segments"]})
    atomic_write_json(recording_dir / "transcript.json", transcript)
    atomic_write_text(recording_dir / "transcript.md", transcript_markdown(transcript))
    atomic_write_text(recording_dir / "resolutions.yaml", resolutions_yaml(normalized))
    return transcript


def resolutions_yaml(resolutions: Mapping[str, Mapping[str, str | None]]) -> str:
    lines = ["speakers:"]
    for speaker in sorted(resolutions):
        value = resolutions[speaker]
        lines.append(f"  {speaker}:")
        lines.append(f"    action: {value['action']}")
        if value["name"]:
            lines.append("    name: " + json.dumps(value["name"], ensure_ascii=False))
    return "\n".join(lines) + "\n"


def required_files_present(recording_dir: Path) -> bool:
    return all((recording_dir / filename).is_file() for filename in REQUIRED_RECORD_FILES)


def format_timestamp(seconds: float) -> str:
    whole = max(0, int(seconds))
    return f"{whole // 60:02d}:{whole % 60:02d}"
