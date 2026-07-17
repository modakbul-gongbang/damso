"""Non-destructive local and Plaud duplicate candidate detection."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Iterable, Mapping


@dataclass(frozen=True)
class MeetingFingerprint:
    stem: str
    source: str
    captured_at: datetime
    duration_seconds: float
    audio_file: str | None


@dataclass(frozen=True)
class DuplicateCandidate:
    first: MeetingFingerprint
    second: MeetingFingerprint
    start_delta_seconds: float
    duration_delta_seconds: float


def detect_candidates(records: Iterable[Mapping[str, Any]]) -> list[DuplicateCandidate]:
    fingerprints = [fingerprint(record) for record in records]
    candidates = []
    for index, first in enumerate(fingerprints):
        for second in fingerprints[index + 1 :]:
            if first.source == second.source:
                continue
            start_delta = abs((first.captured_at - second.captured_at).total_seconds())
            duration_delta = abs(first.duration_seconds - second.duration_seconds)
            time_tolerance = max(90.0, min(first.duration_seconds, second.duration_seconds) * 0.25)
            duration_tolerance = max(90.0, max(first.duration_seconds, second.duration_seconds) * 0.25)
            if start_delta <= time_tolerance and duration_delta <= duration_tolerance:
                candidates.append(DuplicateCandidate(first, second, start_delta, duration_delta))
    return sorted(candidates, key=lambda item: (item.start_delta_seconds, item.duration_delta_seconds, item.first.stem, item.second.stem))


def logical_merge(primary: Mapping[str, Any], secondary: Mapping[str, Any]) -> dict[str, Any]:
    """Return metadata for one canonical meeting without changing either source record.

    The caller commits the returned metadata as a separate logical meeting only
    after user confirmation.  Every original stem and audio file remains listed.
    """
    first = fingerprint(primary)
    second = fingerprint(secondary)
    if first.stem == second.stem:
        raise ValueError("a logical merge requires two different records")
    merged = dict(primary)
    existing = list(merged.get("sourceRecords", []))
    existing.extend([source_reference(first), source_reference(second)])
    unique = {item["stem"]: item for item in existing}
    merged["sourceRecords"] = [unique[stem] for stem in sorted(unique)]
    merged["source"] = "merged"
    merged["mergedFrom"] = [first.stem, second.stem]
    return merged


def fingerprint(record: Mapping[str, Any]) -> MeetingFingerprint:
    stem = str(record.get("stem", "")).strip()
    source = str(record.get("source", "")).strip()
    if not stem or source not in {"local", "plaud"}:
        raise ValueError("record requires a stem and local or plaud source")
    created = record.get("createdAt")
    if not isinstance(created, str):
        raise ValueError("record requires ISO 8601 createdAt")
    captured_at = datetime.fromisoformat(created.replace("Z", "+00:00")).astimezone(timezone.utc)
    duration = float(record.get("durationSeconds") or 0)
    if duration < 0:
        raise ValueError("durationSeconds must be non-negative")
    audio_file = record.get("originalAudioFile")
    return MeetingFingerprint(stem, source, captured_at, duration, str(audio_file) if audio_file else None)


def source_reference(value: MeetingFingerprint) -> dict[str, str | None]:
    return {"stem": value.stem, "source": value.source, "audioFile": value.audio_file}
