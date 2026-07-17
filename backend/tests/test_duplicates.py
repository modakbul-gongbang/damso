import unittest

from damso.duplicates import detect_candidates, logical_merge


class DuplicateTests(unittest.TestCase):
    def test_only_overlapping_cross_source_meetings_become_candidates(self):
        candidates = detect_candidates(
            [
                {"stem": "local", "source": "local", "createdAt": "2026-07-14T10:00:00Z", "durationSeconds": 1200, "originalAudioFile": "microphone.caf"},
                {"stem": "plaud", "source": "plaud", "createdAt": "2026-07-14T10:01:00Z", "durationSeconds": 1180, "originalAudioFile": "audio.ogg"},
                {"stem": "later", "source": "plaud", "createdAt": "2026-07-14T12:00:00Z", "durationSeconds": 1200},
            ]
        )
        self.assertEqual([(item.first.stem, item.second.stem) for item in candidates], [("local", "plaud")])

    def test_logical_merge_retains_each_source_and_audio_reference(self):
        local = {"stem": "local", "source": "local", "createdAt": "2026-07-14T10:00:00Z", "durationSeconds": 1200, "originalAudioFile": "microphone.caf"}
        plaud = {"stem": "plaud", "source": "plaud", "createdAt": "2026-07-14T10:01:00Z", "durationSeconds": 1180, "originalAudioFile": "audio.ogg"}
        result = logical_merge(local, plaud)
        self.assertEqual(result["source"], "merged")
        self.assertEqual(result["mergedFrom"], ["local", "plaud"])
        self.assertEqual(result["sourceRecords"], [{"stem": "local", "source": "local", "audioFile": "microphone.caf"}, {"stem": "plaud", "source": "plaud", "audioFile": "audio.ogg"}])
