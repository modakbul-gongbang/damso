"""Deterministic machine-managed fields for Plaud/peoples profiles.

Natural-language profile body and the Notes section are preserved verbatim.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import re
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping, Sequence

from .contracts import atomic_write_text


FRONTMATTER = re.compile(r"\A---\n(?P<fields>.*?)\n---\n?(?P<body>.*)\Z", re.DOTALL)
VOICE_EMBEDDING_MODEL = "sherpa-onnx/3dspeaker-speech-eres2net-base-sv-zh-cn-3dspeaker-16k"


@dataclass(frozen=True)
class VoiceCandidate:
    name: str
    voice_score: float


def slugify(name: str) -> str:
    value = re.sub(r"\s+", "-", name.strip())
    value = re.sub(r"[/\\:*?\"<>|]", "_", value)
    return value or "unknown"


def apply_people_resolutions(
    peoples_directory: Path,
    resolutions: Mapping[str, Mapping[str, Any]],
    meeting_date: str | None = None,
    meeting_stem: str | None = None,
    speaker_embeddings: Mapping[str, Sequence[float]] | None = None,
    speaker_embedding_model: str | None = None,
) -> None:
    date = meeting_date or dt.date.today().isoformat()
    for speaker, resolution in resolutions.items():
        action = resolution.get("action")
        name = resolution.get("name")
        if action not in {"match", "new", "me"} or not isinstance(name, str) or not name.strip():
            continue
        directory = peoples_directory.parent / "me" if action == "me" else peoples_directory / slugify(name)
        profile = directory / "profile.md"
        fields, body = read_profile(profile, name.strip(), date)
        fields["name"] = name.strip()
        alias = resolution.get("alias")
        if isinstance(alias, str):
            merge_alias(fields, alias)
        fields["last_seen"] = date
        fields.setdefault("first_seen", date)
        known_stems = fields.get("meeting_stems", [])
        if not isinstance(known_stems, list) or not all(isinstance(stem, str) for stem in known_stems):
            known_stems = []
        if meeting_stem and meeting_stem not in known_stems:
            known_stems.append(meeting_stem)
            fields["meeting_stems"] = sorted(known_stems)
            fields["meeting_count"] = max(int(fields.get("meeting_count", 0)) + 1, len(known_stems))
        elif not meeting_stem:
            fields["meeting_count"] = int(fields.get("meeting_count", 0)) + 1
        embedding = (speaker_embeddings or {}).get(str(speaker))
        if embedding is not None and speaker_embedding_model == VOICE_EMBEDDING_MODEL:
            fields["voice_model"] = VOICE_EMBEDDING_MODEL
            fields["voice_samples"] = write_voice_embedding(directory / "voice.npy", embedding)
        write_profile(profile, fields, body)


def merge_alias(fields: dict[str, Any], alias: str) -> bool:
    """Accumulate one display-name alias with exact-match dedup.

    The primary name never becomes its own alias; nothing is normalized so
    the user sees exactly the captured display name.
    """
    cleaned = alias.strip()
    if not cleaned or cleaned == str(fields.get("name") or "").strip():
        return False
    aliases = fields.get("aliases")
    if not isinstance(aliases, list) or not all(isinstance(item, str) for item in aliases):
        aliases = []
    if cleaned in aliases:
        return False
    aliases.append(cleaned)
    fields["aliases"] = aliases
    return True


def remove_person_alias(peoples_directory: Path, name: str, alias: str) -> None:
    """Remove one exact alias from the profile frontmatter (user-initiated)."""
    cleaned_name = name.strip()
    cleaned_alias = alias.strip()
    if not cleaned_name or not cleaned_alias:
        raise ValueError("removing an alias requires a name and alias")
    directory = peoples_directory / slugify(cleaned_name)
    profile = directory / "profile.md"
    if not profile.is_file():
        raise ValueError("no profile exists for this person")
    fields, body = read_profile(profile, cleaned_name, dt.date.today().isoformat())
    aliases = fields.get("aliases")
    if not isinstance(aliases, list):
        return
    fields["aliases"] = [item for item in aliases if item != cleaned_alias]
    write_profile(profile, fields, body)


def set_person_email(peoples_directory: Path, name: str, email: str) -> None:
    """Set or clear the optional contact email in the profile frontmatter."""
    cleaned_name = name.strip()
    if not cleaned_name:
        raise ValueError("a person email update requires a name")
    cleaned_email = email.strip()
    if cleaned_email and ("@" not in cleaned_email or " " in cleaned_email or len(cleaned_email) > 254):
        raise ValueError("email must look like a plain address")
    directory = peoples_directory / slugify(cleaned_name)
    profile = directory / "profile.md"
    fields, body = read_profile(profile, cleaned_name, dt.date.today().isoformat())
    fields.setdefault("name", cleaned_name)
    if cleaned_email:
        fields["email"] = cleaned_email
    else:
        fields.pop("email", None)
    write_profile(profile, fields, body)


def append_person_note(peoples_directory: Path, name: str, note: str, meeting_date: str | None = None) -> None:
    """Append one user-accepted note line under the profile's Notes section.

    Only the caller-confirmed text is written; nothing is inferred here. The
    natural-language body outside the Notes section stays verbatim.
    """
    cleaned_name = name.strip()
    cleaned_note = " ".join(note.split())
    if not cleaned_name or not cleaned_note:
        raise ValueError("a person note requires a name and note text")
    date = meeting_date or dt.date.today().isoformat()
    directory = peoples_directory / slugify(cleaned_name)
    profile = directory / "profile.md"
    fields, body = read_profile(profile, cleaned_name, date)
    fields.setdefault("name", cleaned_name)
    line = f"- ({date}) {cleaned_note}"
    if "## Notes" in body:
        head, _, tail = body.partition("## Notes")
        tail = tail.rstrip("\n")
        body = f"{head}## Notes{tail}\n{line}\n"
    else:
        body = body.rstrip("\n") + f"\n\n## Notes\n{line}\n"
    write_profile(profile, fields, body)


# Cosine similarity below this level is indistinguishable from noise for the
# 3D-Speaker embedding space; surfacing such candidates (including negative
# scores) only misleads the manual review.
MINIMUM_CANDIDATE_SCORE = 0.25


def compatible_voice_candidates(peoples_directory: Path, embedding: Sequence[float], maximum: int = 3,
                                minimum_score: float = MINIMUM_CANDIDATE_SCORE) -> list[VoiceCandidate]:
    """Return manual-review candidates only from profiles made by this exact model.

    Older `voice.npy` files without a model provenance marker are intentionally
    ignored. Equal vector dimensions do not establish comparable embedding
    spaces, so surfacing those as recommendations would be unsafe.
    """
    try:
        import numpy as np
    except ImportError:
        return []
    query = normalized_embedding(embedding)
    if query is None or not peoples_directory.is_dir():
        return []
    directories = [item for item in peoples_directory.iterdir() if item.is_dir()]
    me_directory = peoples_directory.parent / "me"
    if me_directory.is_dir():
        directories.append(me_directory)
    candidates: list[VoiceCandidate] = []
    for directory in sorted(set(directories), key=lambda item: item.name):
        fields, _ = read_profile(directory / "profile.md", directory.name, dt.date.today().isoformat())
        if fields.get("voice_model") != VOICE_EMBEDDING_MODEL:
            continue
        saved = read_voice_embedding(directory / "voice.npy")
        if saved is None or saved.shape != query.shape:
            continue
        score = round(float(np.dot(query, saved)), 4)
        if score < minimum_score:
            continue
        candidates.append(VoiceCandidate(name=str(fields.get("name") or directory.name), voice_score=score))
    return sorted(candidates, key=lambda item: (-item.voice_score, item.name))[:maximum]


def write_voice_embedding(path: Path, embedding: Sequence[float]) -> int:
    """Atomically store a normalized compatible voice vector and sample count."""
    try:
        import numpy as np
    except ImportError as error:
        raise RuntimeError("numpy is required to store local voice embeddings") from error
    value = normalized_embedding(embedding)
    if value is None:
        raise ValueError("voice embedding must be a finite one-dimensional vector")
    existing = read_voice_embedding(path)
    samples = 1
    if existing is not None and existing.shape == value.shape:
        value = normalized_embedding(existing + value)
        if value is None:
            raise ValueError("combined voice embedding is invalid")
        samples = 2
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("wb", dir=path.parent, delete=False) as temporary:
        np.save(temporary, value.astype(np.float32))
        temporary_path = Path(temporary.name)
    os.replace(temporary_path, path)
    return samples


def read_voice_embedding(path: Path):
    try:
        import numpy as np
    except ImportError:
        return None
    if not path.is_file():
        return None
    try:
        return normalized_embedding(np.load(path, allow_pickle=False))
    except (OSError, ValueError):
        return None


def normalized_embedding(value: Sequence[float]):
    try:
        import numpy as np
    except ImportError:
        return None
    result = np.asarray(value, dtype=np.float32)
    if result.ndim != 1 or result.size == 0 or not np.all(np.isfinite(result)):
        return None
    norm = float(np.linalg.norm(result))
    if norm <= 0.0:
        return None
    return result / norm


def read_profile(path: Path, name: str, meeting_date: str) -> tuple[dict[str, Any], str]:
    if not path.is_file():
        return (
            {"name": name, "aliases": [], "relation": None, "role": None, "first_seen": meeting_date, "last_seen": meeting_date, "meeting_count": 0, "voice_samples": 0, "tags": []},
            "## Description\n\n## Meetings\n\n## Notes\n",
        )
    match = FRONTMATTER.match(path.read_text(encoding="utf-8"))
    if not match:
        return ({"name": name, "meeting_count": 0, "voice_samples": 0}, path.read_text(encoding="utf-8"))
    fields = {}
    for line in match.group("fields").splitlines():
        key, separator, raw_value = line.partition(": ")
        if not separator:
            continue
        try:
            fields[key] = json.loads(raw_value)
        except json.JSONDecodeError:
            fields[key] = raw_value
    return fields, match.group("body")


def write_profile(path: Path, fields: Mapping[str, Any], body: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    field_lines = [f"{key}: {json.dumps(value, ensure_ascii=False)}" for key, value in fields.items()]
    atomic_write_text(path, "---\n" + "\n".join(field_lines) + "\n---\n" + body.lstrip("\n"))
