"""User-initiated local model provisioning for Meeting Hub.

This module downloads only fixed public model artifacts and installs only the
local-processing Python dependencies. It never receives or uploads meeting
audio, transcripts, Plaud sessions, credentials, or arbitrary URLs.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Sequence


WHISPER_REPOSITORY = "mlx-community/whisper-large-v3-mlx"
SHERPA_SEGMENTATION_ARCHIVE = "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2"
SHERPA_EMBEDDING_URL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx"
SHERPA_EMBEDDING_FILENAME = "3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx"
PYTHON_DEPENDENCIES = (
    "mlx-whisper==0.4.3",
    "sherpa-onnx==1.13.4",
    "sherpa-onnx-bin==1.13.4",
    "huggingface-hub>=1.7,<2",
)


class ModelSetupError(RuntimeError):
    """A stable, non-sensitive local provisioning error."""


@dataclass(frozen=True)
class LocalModelPaths:
    root: Path

    @property
    def whisper_directory(self) -> Path:
        return self.root / "mlx-whisper-large-v3"

    @property
    def sherpa_directory(self) -> Path:
        return self.root / "sherpa-diarization"

    @property
    def sherpa_segmentation_model(self) -> Path:
        return self.sherpa_directory / "sherpa-onnx-pyannote-segmentation-3-0" / "model.onnx"

    @property
    def sherpa_embedding_model(self) -> Path:
        return self.sherpa_directory / SHERPA_EMBEDDING_FILENAME


def default_model_root() -> Path:
    return Path.home() / "Library" / "Application Support" / "Damso" / "Models"


def model_paths(root: str | Path | None = None) -> LocalModelPaths:
    selected = Path(root).expanduser() if root else default_model_root()
    return LocalModelPaths(selected.resolve())


def readiness(paths: LocalModelPaths) -> dict[str, object]:
    whisper_ready = paths.whisper_directory.is_dir() and (paths.whisper_directory / "config.json").is_file()
    sherpa_ready = paths.sherpa_segmentation_model.is_file() and paths.sherpa_embedding_model.is_file()
    return {
        "ok": whisper_ready and sherpa_ready,
        "whisper_ready": whisper_ready,
        "sherpa_ready": sherpa_ready,
        "model_root_kind": "default" if paths.root == default_model_root() else "custom",
    }


def install(
    paths: LocalModelPaths,
    *,
    command_runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
    snapshot_downloader: Callable[..., str] | None = None,
    url_opener: Callable[..., object] = urllib.request.urlopen,
) -> dict[str, object]:
    """Install fixed local prerequisites and model files into one owned root."""
    install_python_dependencies(command_runner)
    download_whisper_model(paths, snapshot_downloader)
    download_sherpa_models(paths, url_opener)
    result = readiness(paths)
    if not result["ok"]:
        raise ModelSetupError("model_install_incomplete")
    return result


def install_python_dependencies(command_runner: Callable[..., subprocess.CompletedProcess[str]]) -> None:
    command = [sys.executable, "-m", "pip", "install", "--disable-pip-version-check", "--user", *PYTHON_DEPENDENCIES]
    completed = command_runner(command, check=False, capture_output=True, text=True)
    if completed.returncode != 0:
        raise ModelSetupError("local_processing_dependency_install_failed")


def download_whisper_model(paths: LocalModelPaths, snapshot_downloader: Callable[..., str] | None) -> None:
    if (paths.whisper_directory / "config.json").is_file():
        return
    if snapshot_downloader is None:
        try:
            from huggingface_hub import snapshot_download
        except ImportError as error:
            raise ModelSetupError("huggingface_download_runtime_missing") from error
        snapshot_downloader = snapshot_download
    paths.whisper_directory.mkdir(parents=True, exist_ok=True)
    try:
        snapshot_downloader(repo_id=WHISPER_REPOSITORY, local_dir=str(paths.whisper_directory), token=False)
    except Exception as error:  # The UI only needs a stable error code, never provider output.
        raise ModelSetupError("whisper_model_download_failed") from error


def download_sherpa_models(paths: LocalModelPaths, url_opener: Callable[..., object]) -> None:
    if paths.sherpa_segmentation_model.is_file() and paths.sherpa_embedding_model.is_file():
        return
    paths.sherpa_directory.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="damso-model-setup-") as temporary:
        temporary_root = Path(temporary)
        archive = temporary_root / "segmentation.tar.bz2"
        embedding = temporary_root / SHERPA_EMBEDDING_FILENAME
        download_fixed_file(SHERPA_SEGMENTATION_ARCHIVE, archive, url_opener)
        download_fixed_file(SHERPA_EMBEDDING_URL, embedding, url_opener)
        extract_archive_safely(archive, temporary_root)
        extracted = temporary_root / "sherpa-onnx-pyannote-segmentation-3-0"
        if not (extracted / "model.onnx").is_file() or not embedding.is_file():
            raise ModelSetupError("sherpa_model_download_incomplete")
        destination = paths.sherpa_directory / extracted.name
        if destination.exists():
            shutil.rmtree(destination)
        shutil.move(str(extracted), str(destination))
        shutil.move(str(embedding), str(paths.sherpa_embedding_model))


def download_fixed_file(url: str, target: Path, url_opener: Callable[..., object]) -> None:
    try:
        with url_opener(url, timeout=60) as response, target.open("wb") as output:
            shutil.copyfileobj(response, output)
    except Exception as error:
        raise ModelSetupError("fixed_model_download_failed") from error


def extract_archive_safely(archive: Path, destination: Path) -> None:
    try:
        with tarfile.open(archive, "r:bz2") as bundle:
            members = bundle.getmembers()
            for member in members:
                candidate = (destination / member.name).resolve()
                if candidate != destination.resolve() and destination.resolve() not in candidate.parents:
                    raise ModelSetupError("unsafe_model_archive")
            bundle.extractall(destination, members=members, filter="data")
    except ModelSetupError:
        raise
    except (OSError, tarfile.TarError) as error:
        raise ModelSetupError("sherpa_model_archive_invalid") from error


def emit(payload: dict[str, object]) -> None:
    print(json.dumps(payload, sort_keys=True))


def main(arguments: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Meeting Hub local model setup")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--status", action="store_true")
    mode.add_argument("--install", action="store_true")
    parser.add_argument("--model-root")
    args = parser.parse_args(arguments)
    paths = model_paths(args.model_root)
    try:
        result = install(paths) if args.install else readiness(paths)
        emit(result)
        return 0 if result["ok"] else 1
    except ModelSetupError as error:
        emit({"ok": False, "error_code": str(error)})
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
