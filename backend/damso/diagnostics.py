"""Local runtime diagnostics without collecting personal meeting content."""

from __future__ import annotations

import json
import os
import shutil
import sys
import argparse
import importlib.util
import re
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterable

from .model_setup import SHERPA_EMBEDDING_FILENAME, default_model_root


@dataclass(frozen=True)
class DiagnosticItem:
    identifier: str
    status: str
    detail: str
    next_action: str


def diagnose(storage_root: Path, environment: dict[str, str] | None = None) -> list[DiagnosticItem]:
    environment = environment or dict(os.environ)
    items = [python_runtime(), command_runtime("ffmpeg"), command_runtime("chromux"), command_runtime("sandbox-exec"), module_runtime("mlx_whisper", "mlx_whisper_runtime"), module_runtime("sherpa_onnx", "sherpa_onnx_runtime")]
    items.extend(agent_runtime())
    items.append(storage_runtime(storage_root))
    items.extend(model_runtime(environment))
    return items


def python_runtime() -> DiagnosticItem:
    current = f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}" 
    if sys.version_info >= (3, 11):
        return DiagnosticItem("python", "ready", f"Python {current} is available.", "")
    return DiagnosticItem("python", "blocked", f"Python {current} is too old.", "Install Python 3.11 or newer and recreate the virtual environment.")


def command_runtime(name: str) -> DiagnosticItem:
    path = shutil.which(name)
    if path:
        return DiagnosticItem(name, "ready", f"Found {name} at a configured PATH location.", "")
    actions = {
        "chromux": "Install chromux and sign in before enabling Plaud sync.",
        "ffmpeg": "Install ffmpeg before enabling local sherpa-onnx diarization.",
        "sandbox-exec": "Use a supported macOS runtime with sandbox-exec before enabling agent CLI summaries.",
    }
    return DiagnosticItem(name, "blocked", f"{name} was not found on PATH.", actions[name])


def agent_runtime() -> list[DiagnosticItem]:
    """Summaries need whichever agent CLI is selected in Settings, so a single
    missing agent is a warning and only the absence of both blocks."""
    items = []
    found = {}
    for name in ("claude", "codex"):
        path = shutil.which(name)
        found[name] = bool(path)
        if path:
            items.append(DiagnosticItem(name, "ready", f"Found {name} at a configured PATH location.", ""))
        else:
            items.append(DiagnosticItem(name, "warning", f"{name} was not found on PATH.", f"Install and sign in to the {name} CLI if it is your selected summary agent."))
    if not any(found.values()):
        items.append(DiagnosticItem("agent_cli", "blocked", "No summary agent CLI (claude or codex) was found on PATH.", "Install and sign in to Claude Code or Codex before automatic summaries can run."))
    return items


def storage_runtime(root: Path) -> DiagnosticItem:
    try:
        root.mkdir(parents=True, exist_ok=True)
        probe = root / ".damso-diagnostic-probe"
        probe.write_text("ok", encoding="utf-8")
        probe.unlink()
        free = shutil.disk_usage(root).free
    except OSError as error:
        return DiagnosticItem("storage", "blocked", f"Storage root is unavailable: {error.strerror or error}", "Choose a writable local storage root. No fallback path will be used.")
    if free < 2 * 1024**3:
        return DiagnosticItem("storage", "warning", "Storage root has less than 2 GiB free.", "Free space before recording or processing audio.")
    return DiagnosticItem("storage", "ready", "Storage root is writable and has sufficient free space.", "")


def module_runtime(module: str, identifier: str) -> DiagnosticItem:
    if importlib.util.find_spec(module):
        return DiagnosticItem(identifier, "ready", f"{module} is available in the configured Python runtime.", "")
    return DiagnosticItem(identifier, "blocked", f"{module} is not installed in the configured Python runtime.", "Use the explicit Local Processing Models install action in Meeting Hub Settings.")


def model_runtime(environment: dict[str, str]) -> list[DiagnosticItem]:
    root = default_model_root()
    models = [
        ("mlx_whisper_model", Path(environment.get("DAMSO_MLX_WHISPER_MODEL_DIR", root / "mlx-whisper-large-v3")), "config.json", "Use the explicit Local Processing Models install action in Meeting Hub Settings."),
        ("sherpa_model", Path(environment.get("DAMSO_SHERPA_MODEL_DIR", root / "sherpa-diarization")), f"sherpa-onnx-pyannote-segmentation-3-0/model.onnx|{SHERPA_EMBEDDING_FILENAME}", "Use the explicit Local Processing Models install action in Meeting Hub Settings."),
    ]
    result = []
    for identifier, directory, expected, action in models:
        candidates = expected.split("|")
        ready = directory.is_dir() and all((directory / item).is_file() for item in candidates)
        if ready:
            result.append(DiagnosticItem(identifier, "ready", f"The required {identifier} files are available in a local model directory.", ""))
        else:
            result.append(DiagnosticItem(identifier, "blocked", f"The required {identifier} files are unavailable in a local model directory.", action))
    return result


def export_redacted(items: Iterable[DiagnosticItem]) -> str:
    payload = []
    for item in items:
        value = asdict(item)
        value["detail"] = redact(value["detail"])
        value["next_action"] = redact(value["next_action"])
        payload.append(value)
    return json.dumps({"diagnostics": payload}, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def redact(value: str) -> str:
    redacted = value.replace(str(Path.home()), "~")
    redacted = re.sub(r"(?i)\b(authorization|token|cookie|session|password|api[ _-]?key)\s*[:=]\s*(?:bearer\s+)?(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)", r"\1=<redacted>", redacted)
    redacted = re.sub(r"(?i)\bbearer\s+(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)", "Bearer <redacted>", redacted)
    redacted = re.sub(r"(?i)\bsk-[a-z0-9_-]+\b", "<redacted>", redacted)
    redacted = re.sub(r"(?i)file://[^\s,;]+", "<file-url>", redacted)
    return re.sub(r"/(?:Users|private|Volumes|var|tmp|Library)/[^\s,;]+", "<path>", redacted)


def main() -> int:
    parser = argparse.ArgumentParser(description="Meeting Hub local runtime diagnostics")
    parser.add_argument("--root", type=Path, required=True, help="Configured canonical storage root")
    parser.add_argument("--json", action="store_true", help="Emit a redacted JSON report")
    args = parser.parse_args()
    items = diagnose(args.root)
    if args.json:
        print(export_redacted(items), end="")
    else:
        for item in items:
            print(f"{item.status.upper():7} {item.identifier}: {item.detail}")
            if item.next_action:
                print(f"        Next action: {item.next_action}")
    # Warnings (for example one missing optional agent CLI or low disk space)
    # are surfaced but only a blocked required dependency fails setup.
    return 0 if all(item.status != "blocked" for item in items) else 1


if __name__ == "__main__":
    raise SystemExit(main())
