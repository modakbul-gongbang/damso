import re
import unittest
from pathlib import Path


class PrivacyTests(unittest.TestCase):
    def test_workspace_has_no_user_absolute_paths_or_common_secret_values(self):
        root = Path(__file__).resolve().parents[2]
        forbidden_path = re.compile(r"/Users/[A-Za-z0-9._-]+")
        forbidden_secret = re.compile(r"(?:sk-[A-Za-z0-9_-]{16,}|session_token\s*[:=]\s*['\"][^'\"]+)", re.IGNORECASE)
        excluded = {".git", ".build", "__pycache__"}
        violations = []
        for path in root.rglob("*"):
            relative = path.relative_to(root)
            if not path.is_file() or any(part in excluded for part in relative.parts) or relative.parts[:2] in {("agents", "implement"), ("agents", "gates")}:
                continue
            if path.suffix in {".png", ".jpg", ".jpeg", ".gif", ".pdf", ".npy"}:
                continue
            text = path.read_text(encoding="utf-8", errors="ignore")
            if forbidden_path.search(text) or forbidden_secret.search(text):
                violations.append(str(relative))
        self.assertEqual(violations, [])
