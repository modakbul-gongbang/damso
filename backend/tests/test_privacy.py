import re
import unittest
from pathlib import Path


class PrivacyTests(unittest.TestCase):
    def test_workspace_has_no_user_absolute_paths_or_common_secret_values(self):
        root = Path(__file__).resolve().parents[2]
        forbidden_path = re.compile(r"/Users/[A-Za-z0-9._-]+")
        forbidden_secret = re.compile(r"(?:sk-[A-Za-z0-9_-]{16,}|session_token\s*[:=]\s*['\"][^'\"]+)", re.IGNORECASE)
        excluded = {".git", ".build", "__pycache__"}
        # SourceKit drops per-file index artifacts at the repository root while
        # a Swift file is being edited, and they embed the editing user's
        # absolute paths. .gitignore has ruled them out of the repository since
        # its first commit (the "/*.o" block), so they can never be published -
        # but this scan walks the filesystem, not the index, and would report
        # them all through any editing session. Anchored to the root exactly as
        # .gitignore anchors it, so a stray artifact inside a source directory
        # is still a violation.
        root_index_droppings = {".o", ".d", ".swiftdeps", ".swiftdeps~", ".swiftmodule"}
        violations = []
        for path in root.rglob("*"):
            relative = path.relative_to(root)
            if not path.is_file() or any(part in excluded for part in relative.parts) or relative.parts[:2] in {("agents", "implement"), ("agents", "gates")}:
                continue
            if len(relative.parts) == 1 and path.suffix in root_index_droppings:
                continue
            if path.suffix in {".png", ".jpg", ".jpeg", ".gif", ".pdf", ".npy"}:
                continue
            text = path.read_text(encoding="utf-8", errors="ignore")
            if forbidden_path.search(text) or forbidden_secret.search(text):
                violations.append(str(relative))
        self.assertEqual(violations, [])
