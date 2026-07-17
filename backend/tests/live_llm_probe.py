"""Explicit, redacted live verification for both agent CLI boundaries.

This probe never opens recordings or sends user data. It is opt-in through
the Makefile gate because it consumes one subscription request per available
agent. Only synthetic fixture text is transmitted, and only redacted counts
are printed.
"""

from __future__ import annotations

import json
import shutil
import tempfile
from pathlib import Path

from damso.agent_boundary import SUMMARY_SCHEMA, make_boundary

FIXTURE_TRANSCRIPT = {
    "segments": [
        {"speaker": "Speaker 1", "text": "We will verify the synthetic release checklist tomorrow."},
        {"speaker": "Speaker 2", "text": "I will prepare the checklist."},
    ]
}


def probe(agent: str, root: Path) -> dict[str, object]:
    boundary = make_boundary(agent, root)
    with tempfile.TemporaryDirectory(prefix="damso-live-command-") as command_directory:
        command = boundary._command(Path(command_directory), SUMMARY_SCHEMA)
        profile = Path(command_directory, "agent.sb").read_text(encoding="utf-8")
    if str(root.resolve()) not in profile:
        raise SystemExit(f"meeting store is not denied by the {agent} sandbox profile")
    if agent == "claude" and command[command.index("--tools") + 1] != "":
        raise SystemExit("Claude Code tools are not disabled")
    if agent == "codex" and command[command.index("--sandbox") + 1] != "read-only":
        raise SystemExit("Codex sandbox is not read-only")

    result = boundary.run_summary(FIXTURE_TRANSCRIPT, language="en")
    if result.status != "complete" or result.summary is None:
        raise SystemExit(f"live {agent} boundary did not return a structured summary: {result.error_code}")
    return {
        "agent": agent,
        "status": result.status,
        "title_present": bool(result.summary["title"].strip()),
        "action_item_count": len(result.summary["action_items"]),
        "key_point_count": len(result.summary["key_points"]),
        "person_note_count": len(result.summary["person_notes"]),
        "summary_keys": sorted(result.summary),
        "storage_profile_present": True,
    }


def main() -> int:
    agents = [name for name in ("claude", "codex") if shutil.which(name)]
    if not agents:
        raise SystemExit("no agent CLI (claude or codex) is available for the live probe")
    reports = []
    with tempfile.TemporaryDirectory(prefix="damso-live-llm-") as temporary:
        root = Path(temporary) / "store"
        root.mkdir()
        for agent in agents:
            reports.append(probe(agent, root))
    print(json.dumps({"probes": reports}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
