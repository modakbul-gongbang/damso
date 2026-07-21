"""One-time adoption of older Obsidian-vault records into the canonical layout.

Older exports stored only a resolved ``transcript.json`` (segments already
carry the identified person name, plus an ``identified`` map of
``SPEAKER_XX -> name``) and an optional ``resolutions.yaml``.  They lack the
``transcript.raw.json`` and ``identification.json`` the current app reads, so
the app treats them as never transcribed.

This module reconstructs the missing phase-one artifacts from what the record
already contains, without touching the audio or the resolved transcript, and
returns the resolution list to write into ``meeting.json``.  It is idempotent:
a record that already has ``transcript.raw.json`` is left alone.
"""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Mapping

import yaml

from . import contracts

SPEAKER_LABEL = re.compile(r"^(SPEAKER_\d+|UNKNOWN)$")
# The vault owner's short name as it appears in legacy exports. Legacy records
# identified the owner by this literal name; setting it lets adoption map those
# segments to the canonical "me" person. Empty means no owner-name mapping.
ME_NAME = os.environ.get("DAMSO_OWNER_NAME", "")
ME_PERSON = "나"


@dataclass
class ReconcileResult:
    stem: str
    status: str  # "reconciled" | "skipped" | "error"
    detail: str = ""
    resolutions: list[dict[str, Any]] = field(default_factory=list)


def _reverse_identified(identified: Mapping[str, str]) -> dict[str, str]:
    """name -> SPEAKER_XX, lowest speaker index winning a name collision."""
    reverse: dict[str, str] = {}
    for speaker in sorted(identified):
        name = identified[speaker]
        reverse.setdefault(name, speaker)
    return reverse


def _raw_label(segment_speaker: str, reverse: Mapping[str, str]) -> str:
    if SPEAKER_LABEL.match(segment_speaker):
        return segment_speaker
    return reverse.get(segment_speaker, segment_speaker)


def _load_yaml_resolutions(path: Path) -> dict[str, dict[str, str | None]]:
    if not path.exists():
        return {}
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    speakers = data.get("speakers") or {}
    result: dict[str, dict[str, str | None]] = {}
    for speaker, value in speakers.items():
        if not isinstance(value, Mapping):
            continue
        result[str(speaker)] = {
            "action": str(value.get("action") or "skip"),
            "name": (str(value["name"]).strip() if value.get("name") else None),
        }
    return result


def _meeting_resolution(speaker: str, action: str, name: str | None) -> dict[str, Any]:
    """Match the schema the app already wrote for previously imported records:
    action "me" links to the person "나"; other named actions carry the name;
    "skip" carries no person."""
    if action == "skip":
        return {"action": "skip", "speaker": speaker}
    is_me = action == "me" or (bool(ME_NAME) and name == ME_NAME)
    person = ME_PERSON if is_me else name
    resolved_action = "me" if is_me else action
    return {"action": resolved_action, "personName": person, "speaker": speaker}


def synthesize_excerpts(
    segments: list[Mapping[str, Any]],
    speaker: str,
    *,
    k: int = 2,
    min_seconds: float = 1.5,
) -> list[dict[str, Any]]:
    """Pick a speaker's most substantial segments as playable voice samples.

    Older records carry no excerpt timestamps, so the "play speaker sample"
    button has nothing to play. The raw transcript already has per-segment
    timing, so the longest few segments (which are container-independent
    offsets into the same recording) reconstruct usable samples.
    """
    owned = [
        s for s in segments
        if str(s.get("speaker")) == speaker
        and float(s.get("end", 0)) - float(s.get("start", 0)) >= min_seconds
    ]
    owned.sort(key=lambda s: float(s.get("end", 0)) - float(s.get("start", 0)), reverse=True)
    chosen = sorted(owned[:k], key=lambda s: float(s.get("start", 0)))
    return [
        {"start": round(float(s["start"]), 2), "end": round(float(s["end"]), 2), "text": str(s.get("text", "")).strip()}
        for s in chosen
    ]


def backfill_excerpts(record_dir: Path) -> ReconcileResult:
    """Fill empty proposal excerpts in an existing identification.json from the
    raw transcript. Idempotent: proposals that already have excerpts are left
    untouched, and a record with no raw transcript is skipped."""
    stem = record_dir.name
    raw_path = record_dir / "transcript.raw.json"
    ident_path = record_dir / "identification.json"
    if not raw_path.exists() or not ident_path.exists():
        return ReconcileResult(stem, "skipped", "no transcript or identification")
    transcript = json.loads(raw_path.read_text(encoding="utf-8"))
    segments = transcript.get("segments") or []
    identification = json.loads(ident_path.read_text(encoding="utf-8"))
    proposals = identification.get("proposals")
    if not isinstance(proposals, dict):
        return ReconcileResult(stem, "skipped", "no proposals")

    changed = 0
    for speaker, proposal in proposals.items():
        if not isinstance(proposal, dict):
            continue
        if proposal.get("excerpts"):
            continue
        excerpts = synthesize_excerpts(segments, speaker)
        if excerpts:
            proposal["excerpts"] = excerpts
            changed += 1
    if changed:
        contracts.atomic_write_json(ident_path, identification)
    return ReconcileResult(stem, "reconciled" if changed else "skipped", f"{changed} speakers got samples")


def reconcile_record(record_dir: Path) -> ReconcileResult:
    stem = record_dir.name
    raw_path = record_dir / "transcript.raw.json"
    transcript_path = record_dir / "transcript.json"

    if raw_path.exists():
        return ReconcileResult(stem, "skipped", "transcript.raw.json already present")
    if not transcript_path.exists():
        return ReconcileResult(stem, "error", "no transcript.json to adopt")

    transcript = json.loads(transcript_path.read_text(encoding="utf-8"))
    segments = transcript.get("segments")
    if not isinstance(segments, list) or not segments:
        return ReconcileResult(stem, "error", "transcript.json has no segments")

    identified = {str(k): str(v) for k, v in (transcript.get("identified") or {}).items()}
    reverse = _reverse_identified(identified)

    raw_segments = []
    for segment in segments:
        start = float(segment.get("start", 0.0) or 0.0)
        end = float(segment.get("end", start) or start)
        # Legacy exports occasionally carry end < start; clamp so the segment
        # (and its text) survives the canonical transcript validator.
        raw_segments.append(
            {
                "speaker": _raw_label(str(segment.get("speaker", "UNKNOWN")), reverse),
                "start": start,
                "end": max(start, end),
                "text": str(segment.get("text", "")),
            }
        )
    raw_labels = sorted({segment["speaker"] for segment in raw_segments})

    raw_payload = {
        "source_file": str(transcript.get("source_file", "audio")),
        "language": str(transcript.get("language", "ko")),
        "model": str(transcript.get("model", "large-v3")),
        "duration": float(transcript.get("duration", raw_segments[-1]["end"])),
        "speakers": raw_labels,
        "segments": raw_segments,
    }
    if "source_files" in transcript:
        raw_payload["source_files"] = transcript["source_files"]
    normalized_raw = contracts.validate_transcript(raw_payload)
    contracts.atomic_write_json(raw_path, normalized_raw)

    # identification.json: minimal, decoder-tolerant. The identified name (if
    # any) becomes the sole high-confidence candidate for its speaker.
    proposals: dict[str, Any] = {}
    for label in raw_labels:
        name = identified.get(label)
        proposals[label] = {
            "candidates": [{"name": name, "voice_score": 1.0}] if name else [],
            "excerpts": synthesize_excerpts(normalized_raw["segments"], label),
        }
    contracts.atomic_write_json(
        record_dir / "identification.json",
        {"version": 1, "source_file": raw_payload["source_file"], "proposals": proposals},
    )

    # Resolutions: prefer the record's own resolutions.yaml; otherwise derive
    # them from the identified map. Any raw label left uncovered is skipped.
    yaml_res = _load_yaml_resolutions(record_dir / "resolutions.yaml")
    meeting_resolutions: list[dict[str, Any]] = []
    for label in raw_labels:
        if label in yaml_res:
            entry = yaml_res[label]
            meeting_resolutions.append(_meeting_resolution(label, entry["action"], entry["name"]))
        elif label in identified:
            meeting_resolutions.append(_meeting_resolution(label, "match", identified[label]))
        else:
            meeting_resolutions.append({"action": "skip", "speaker": label})

    return ReconcileResult(stem, "reconciled", f"{len(raw_labels)} speakers", meeting_resolutions)
