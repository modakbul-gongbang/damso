import io
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

from damso import model_setup


class ModelSetupTests(unittest.TestCase):
    def test_readiness_requires_both_fixed_model_contracts(self):
        with tempfile.TemporaryDirectory() as temporary:
            paths = model_setup.model_paths(temporary)
            paths.whisper_directory.mkdir(parents=True)
            (paths.whisper_directory / "config.json").write_text("{}", encoding="utf-8")
            paths.sherpa_segmentation_model.parent.mkdir(parents=True)
            paths.sherpa_segmentation_model.write_bytes(b"segmentation")
            paths.sherpa_embedding_model.write_bytes(b"embedding")

            self.assertEqual(model_setup.readiness(paths), {
                "ok": True,
                "whisper_ready": True,
                "sherpa_ready": True,
                "model_root_kind": "custom",
            })

    def test_install_uses_pinned_dependencies_and_fixed_sources(self):
        commands = []
        downloaded = []
        with tempfile.TemporaryDirectory() as temporary:
            paths = model_setup.model_paths(temporary)

            def runner(command, **_):
                commands.append(command)
                return subprocess.CompletedProcess(command, 0, "", "")

            def snapshot_downloader(**kwargs):
                downloaded.append(kwargs["repo_id"])
                target = Path(kwargs["local_dir"])
                target.mkdir(parents=True, exist_ok=True)
                (target / "config.json").write_text("{}", encoding="utf-8")
                return str(target)

            archive_bytes = io.BytesIO()
            with tarfile.open(fileobj=archive_bytes, mode="w:bz2") as bundle:
                payload = b"segmentation"
                info = tarfile.TarInfo("sherpa-onnx-pyannote-segmentation-3-0/model.onnx")
                info.size = len(payload)
                bundle.addfile(info, io.BytesIO(payload))
            archive_payload = archive_bytes.getvalue()

            class Response(io.BytesIO):
                def __enter__(self):
                    return self

                def __exit__(self, *_):
                    self.close()

            def opener(url, **_):
                self.assertIn(url, {model_setup.SHERPA_SEGMENTATION_ARCHIVE, model_setup.SHERPA_EMBEDDING_URL})
                return Response(archive_payload if url == model_setup.SHERPA_SEGMENTATION_ARCHIVE else b"embedding")

            result = model_setup.install(paths, command_runner=runner, snapshot_downloader=snapshot_downloader, url_opener=opener)

        self.assertTrue(result["ok"])
        self.assertEqual(downloaded, [model_setup.WHISPER_REPOSITORY])
        self.assertEqual(commands[0][-len(model_setup.PYTHON_DEPENDENCIES):], list(model_setup.PYTHON_DEPENDENCIES))
        self.assertNotIn("audio", " ".join(commands[0]).lower())

    def test_archive_rejects_path_traversal(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "unsafe.tar.bz2"
            with tarfile.open(archive, "w:bz2") as bundle:
                payload = b"unsafe"
                info = tarfile.TarInfo("../outside")
                info.size = len(payload)
                bundle.addfile(info, io.BytesIO(payload))
            with self.assertRaisesRegex(model_setup.ModelSetupError, "unsafe_model_archive"):
                model_setup.extract_archive_safely(archive, root / "extract")


if __name__ == "__main__":
    unittest.main()
