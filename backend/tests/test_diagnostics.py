import json
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

from damso.diagnostics import diagnose, export_redacted, module_runtime, redact


class DiagnosticsTests(unittest.TestCase):
    def test_diagnostics_reports_missing_models_and_redacts_home(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "store"
            items = diagnose(root, {"DAMSO_MLX_WHISPER_MODEL_DIR": "/missing", "DAMSO_SHERPA_MODEL_DIR": "/missing"})
        by_identifier = {item.identifier: item for item in items}
        self.assertEqual(by_identifier["storage"].status, "ready")
        self.assertEqual(by_identifier["mlx_whisper_model"].status, "blocked")
        exported = json.loads(export_redacted(items))
        self.assertIn("diagnostics", exported)
        self.assertNotIn(str(Path.home()), json.dumps(exported))

    def test_module_runtime_offers_the_explicit_settings_action_when_missing(self):
        with patch("damso.diagnostics.importlib.util.find_spec", return_value=None):
            item = module_runtime("mlx_whisper", "mlx_whisper_runtime")
        self.assertEqual(item.status, "blocked")
        self.assertIn("Settings", item.next_action)

    def test_redaction_removes_session_values_and_machine_paths(self):
        value = "Authorization: Bearer secret-value cookie=session-value key=sk-test-token file:///private/tmp/meeting.json root=/Volumes/External/Damso"
        redacted = redact(value)
        self.assertNotIn("secret-value", redacted)
        self.assertNotIn("session-value", redacted)
        self.assertNotIn("sk-test-token", redacted)
        self.assertNotIn("/private/tmp/meeting.json", redacted)
        self.assertNotIn("/Volumes/External/Damso", redacted)
        self.assertIn("authorization=<redacted>", redacted.lower())
