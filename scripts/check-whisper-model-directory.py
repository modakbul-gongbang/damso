#!/usr/bin/env python3
"""Fail when the Whisper model repository and its local directory disagree.

download_whisper_model() skips a directory that already contains config.json,
so changing WHISPER_REPOSITORY without changing WHISPER_DIRECTORY_NAME leaves
every existing install on the old model with no error. Pinning the directory to
"mlx-" + the repository slug makes the two impossible to change independently.
"""
import re
import sys
from pathlib import Path

source = Path("backend/damso/model_setup.py").read_text(encoding="utf-8")
repository = re.search(r'WHISPER_REPOSITORY = "([^"]+)"', source).group(1)
directory = re.search(r'WHISPER_DIRECTORY_NAME = "([^"]+)"', source).group(1)
expected = "mlx-" + repository.split("/")[-1]

if directory != expected:
    sys.exit(
        f"WHISPER_DIRECTORY_NAME is {directory!r} but WHISPER_REPOSITORY "
        f"({repository}) requires {expected!r}. An install that already holds "
        f"config.json in the old directory would silently keep the old model."
    )
print(f"ok: {repository} -> {directory}")
