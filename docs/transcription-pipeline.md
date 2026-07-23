# Local transcription pipeline

How phase one spends its time, what the tuning knobs actually do, and which
optimizations were measured and rejected. Every number here came from the same
55 minute Korean meeting (3303s of audio) on an M4 Pro with 10 performance and
4 efficiency cores, measured through the production code path.

## Where the time goes

| Stage | Wall | CPU | Runs on |
| --- | --- | --- | --- |
| Transcription (mlx-whisper large-v3-turbo) | 134s | 32s | GPU (Metal) |
| Diarization (sherpa-onnx) | 337s | 613s | CPU |
| Total phase one | 471s | 645s | |

**Diarization is the dominant cost and the place to optimize next.** It costs
2.5x the wall clock and 19x the CPU of transcription. Transcription already runs
on the GPU through MLX; there is no "move it to the GPU" win left there.

Within diarization the cost splits between the pyannote segmentation pass and
speaker-embedding extraction, both through onnxruntime on CPU. The audio is
decoded from `combined-audio.m4a` to 16 kHz mono PCM once per `waveform()` call,
and `waveform()` is called twice per run (once for `diarize`, once for
`speaker_embeddings`).

## Whisper's initial_prompt conditions style, not just vocabulary

This is the least obvious thing in the pipeline and the easiest to get wrong.

Whisper continues the *style* of `initial_prompt`. Feeding it an unpunctuated
bag of terms teaches it to emit unpunctuated speech:

| Prompt | Sentence enders per 1k hangul | Commas | Ellipsis runs |
| --- | --- | --- | --- |
| Unpunctuated term list (`"주제 용어1 용어2"`) | 3.8 | 0 | 200 |
| No prompt at all | 18.2 | 2 | 28 |
| Punctuated Korean sentences | 28.5 | 128 | 37 |
| Punctuated sentences + seeded names | 28.0 | 40 | 39 |

An unpunctuated prompt is **worse than passing no prompt at all**. The prompt is
built by `build_initial_prompt()` in `backend/damso/processing.py`, which always
opens with `WHISPER_STYLE_CARRIER` (fully punctuated Korean) and folds topic,
domain terms, and names into whole sentences.

Three constraints on that prompt:

- **223 token budget.** Whisper truncates `initial_prompt` to the last
  `n_ctx // 2 - 1` tokens. The carrier costs about 52 tokens and Korean names
  average about 6, so the full 51-name people directory (345 tokens) does not
  fit. `MAX_PROMPT_NAMES` and `MAX_PROMPT_NAME_CHARS` cap the list; the shipping
  prompt measures 148 tokens.
- **List syntax leaks.** A prompt ending in `"주요 용어: a, b, c"` reproduces
  verbatim as the first transcript segment (`"주요 용어, 링크드인, 수정에서..."`).
  Whole sentences do not leak. Any new prompt content must be checked for this.
- **Conditioning decays over long audio.** `initial_prompt` conditions the first
  30s window; after that `condition_on_previous_text` carries the model's own
  output forward. A prompt that fixed punctuation on a 10 minute clip (48.9
  enders per 1k) measured only 20.0 across the full 55 minutes. Always validate
  prompt changes on full-length audio, never on a short clip.

Transcription is deterministic for a fixed prompt and fixed audio: three
identical runs produced byte-identical statistics. Differences between runs are
always explained by a different input, not by sampling noise.

## Seeding names from the people directory

`known_people_names()` reads `Plaud/peoples/` most-recently-touched first, and
`select_prompt_names()` puts this meeting's participants ahead of everyone else.

This fixes names the user already has profiles for. On the test recording turbo
wrote `재규님` where both large-v3 and the previously shipped transcript wrote
`제규님`; the people directory contains `이재규`, so turbo was right and large-v3
was wrong. Model agreement is not ground truth when both models share a bias.

**It does not fix names absent from the directory.** Turbo collapsed two people
mentioned only in passing, `지호님` and `주헌님`, into a single `주원님`. Neither
has a profile. This is the known residual weakness of the turbo swap.

Second-order effect worth knowing: a profile name that was never spoken can be
biased into a transcript. Names are passed in memory only; `write_phase_one`
re-normalizes the hint, so `hint.json` never records them.

## macOS stores those directory names in NFD

`Plaud/peoples/` entries come off the filesystem decomposed. `이재규` read from
`iterdir()` does not equal `이재규` typed as NFC, and every substring comparison
silently fails. `name_variants()` normalizes to NFC before anything else.

This bites any code that compares a filesystem name against text from a
transcript, a profile, or a literal.

## Swapping the Whisper model requires renaming its directory

`download_whisper_model()` skips a directory that already contains
`config.json`. Changing `WHISPER_REPOSITORY` without changing
`WHISPER_DIRECTORY_NAME` leaves every existing install on the old model forever,
with no error. Both constants live in `backend/damso/model_setup.py` and must
change together; `INV-whisper-model-directory` enforces it.

The old directory is orphaned rather than deleted, which doubles as the rollback
path: reverting the constants restores the previous model with no re-download.

## Speaker clustering: NME-SC works only with a known speaker count

`sherpa-onnx`'s `FastClusteringConfig.num_clusters` is not a "disable merging"
knob. Passing a count above the segment count does not produce singleton
clusters; it collapses everything into one. The vendored clustering library
(`hclust-cpp`, same code as https://github.com/cdalitz/hclust-cpp) has
`cutree_k`'s `if (nclust > n || nclust < 2) { all labels = 0 }`, confirmed by
reading the source directly. Measured: `num_clusters=1000` and `100000`
against 15-45 real segments both gave exactly 1 speaker.

A clustering `threshold` near zero, not `num_clusters`, is the working proxy
for per-segment boundaries when a raw, unclustered timeline is needed:
`FastClusteringConfig(threshold=1e-6)` gave 183 segments and 179 distinct
labels on a 3-minute real clip, essentially one label per segment.
`cutree_cdist` walks merge heights ascending and stops at the first one
`>= threshold`; real cosine dissimilarities are never that close to zero, so
almost nothing merges.

`backend/damso/nme_sc.py` ports NME-SC (Park et al., 2019, via NVIDIA NeMo's
`offline_clustering.py`) as pure numpy with no new dependency. It replaces
`FastClusteringConfig`'s AHC decision in `SherpaDiarizer.diarize()`, but only
when an oracle speaker count is supplied from the app's pre-recording
speaker-count prompt. Validated end to end on two real recordings: an 11:34
mic-only recording previously stuck at 15 speakers under the
merge-duration heuristic dropped to exactly 2, balanced 2824s/2354s with
coherent turn-taking, given `num_speakers=2`.

Auto mode (no count given) keeps the original AHC plus
`merge_tiny_speaker_fragments` path unchanged. NME-SC's own eigengap
speaker-count *estimate* collapsed to 1 speaker on both that hard recording
and a separate, known-good 2-speaker recording. Not a coding bug: NeMo's
`g_p` selection criterion is tuned against dense, fixed-duration overlapping
multiscale windows (hundreds of redundant points per speaker); this pipeline
feeds it sparse raw VAD-based segments (roughly 60 segments per speaker for a
5-minute 2-speaker clip), and at that density a larger, fully-connected
neighbor graph always scores better than the smaller disconnected one that
actually reveals two speakers. Revisiting auto-K would need NeMo's multiscale
windowing or a more robust component-count estimator; not attempted.

The oracle path costs roughly double the original single-pass diarization: a
near-zero-threshold pass for raw boundaries, then a second full
embedding-extraction pass over every raw segment before NME-SC re-clusters
them. Measured on the full 102-minute 11:34 recording: 1160s versus the
roughly 625s a single AHC pass takes at that length.

## Measured dead ends

Do not spend time re-testing these.

**CoreML execution provider for sherpa-onnx.** The bundled onnxruntime does have
the CoreML EP compiled in, and `provider="coreml"` is accepted. On a 10 minute
clip: segmentation 61.4s versus 63.1s on CPU (no gain), embedding 187.9s versus
63.1s (**three times slower**). The CoreML EP requires static input shapes, and
the ERes2Net embedding model takes variable-length input, so it falls back per
node. Diarization has no GPU/ANE path worth taking.

**Raising segmentation thread count.** Going from 1 to 10 threads moved wall
clock only 62.3s to 55.7s (10%) while CPU rose 217s to 250s. The intuition that
the single-threaded segmentation pass was the bottleneck was wrong.

**Raising embedding thread count.** 8 threads cut wall clock 55.8s to 51.7s but
nearly doubled CPU, 241s to 411s. The pipeline went the other way instead:
`SHERPA_EMBEDDING_THREADS = 2` costs 613s of CPU for 337s of wall clock where
4 threads cost 1046s for 307s. Background work should buy CPU with wall clock.

**VAD silence removal.** Energy VAD cut 679s of the 3303s (20.6%) and the
timestamp remapping was verified correct (anchor phrases landed within 1-2s, no
drift). But it bought only 10% of wall clock, because diarization is the binding
constraint and only its input shrinks, and it cost 1511 ellipsis runs from the
stitched-together chunks. Not worth it at this silence ratio.

**Threading transcription and diarization together.** They are independent until
speaker assignment, one is GPU-bound and the other CPU-bound, and overlapping
them measured a real 20% wall-clock gain. It still cannot be done with threads:

```
ValueError: signal only works in main thread of the main interpreter
```

Both stages arm `SIGTERM`/`SIGHUP` handlers to reap their child processes
(`deferred_processing_termination_handlers`, used directly by
`MLXWhisperTranscriber.transcribe` and via `cleanup_aware_processing_scope` by
`SherpaDiarizer.waveform`). Python only permits `signal.signal` on the main
thread, so whichever stage moves to a worker thread loses child-process cleanup
on app exit, which is exactly what `ProcessingOrphanSweeperTests` guards.

The design that would work uses no threads at all: split the Whisper worker into
`start()` and `collect()`, spawn the child process, run diarization inline on the
main thread while it works, then collect. That touches process-termination
semantics and belongs in its own change.

**Unit tests with a fake transcriber do not exercise this.** The threading
attempt passed 153 backend tests and 189 Swift tests because the pipeline tests
inject a `FakeTranscriber`. It failed instantly on the first real
`phase-one` run. Any change to how transcription or diarization is invoked needs
an end-to-end run against real audio, not just the suite.

## Timeline

How the current configuration was reached, in order. Kept because most of the
value is in the rejected branches.

| # | Question | What was measured | Outcome |
| --- | --- | --- | --- |
| 1 | Can the UI show a transcription percentage? | No progress signal exists anywhere: `mlx_whisper.transcribe` is called without `verbose`, the worker's stdout/stderr are `DEVNULL`, the transcript is written once at the end, and Swift uses `waitUntilExit()` | Not built. Would need a second progress channel plus a duration probe |
| 2 | Would using the GPU make transcription faster? | mlx-whisper already runs on Metal. On a 10 minute clip transcription used 33s of CPU against diarization's 217s | Premise was wrong; the CPU load was never transcription |
| 3 | Is single-threaded segmentation the bottleneck? | Thread sweep 1 to 10: wall 62.3s to 55.7s, CPU 217s to 250s | Rejected. Wrong hypothesis |
| 4 | Does CoreML help diarization? | Segmentation 61.4s vs 63.1s, embedding 187.9s vs 63.1s | Rejected. Measured dead end |
| 5 | Is large-v3-turbo faster? | 10 minute clip: 20.9s vs 54.6s wall, 4.8s vs 33s CPU | Adopted, pending quality check |
| 6 | Full-length A/B of turbo, parallelism, and VAD | baseline 802s/1371s, turbo+parallel 359s/706s, plus VAD 322s/615s | Turbo kept, VAD rejected at 10% gain for 1511 ellipses |
| 7 | Did turbo really avoid large-v3's repetition loops? | The harness had omitted the production `clean_transcribed_segments` pass, and pinned speaker count differed | Harness defect. Re-run under production conditions |
| 8 | Which of turbo, parallelism, or thread count saved the CPU? | large-v3 parallel emb2 = 553s/1261s against turbo parallel emb2 = 359s/706s | Turbo was 44% of the CPU saving; thread tuning only 8% |
| 9 | Does a punctuated prompt fix turbo's punctuation? | 10 minute clip 3.8 to 48.9 enders per 1k; full 55 minutes only 20.0 | Partial. Conditioning decays over long audio |
| 10 | Does seeding people-directory names help? | Full length: 28.0 enders per 1k, ellipses 436 to 39, `재규님` correct | Adopted. Fixed punctuation as a side effect |
| 11 | Is turbo's name accuracy acceptable? | Consensus-of-two-models heuristic said no; the people directory disproved it for `재규님` | Adopted with a documented residual gap for unprofiled names |
| 12 | Does the parallel path survive a real run? | `ValueError: signal only works in main thread` on the first end-to-end `phase-one` | Reverted. Deferred to a start/collect redesign |

Net result: 802s to 471s of wall clock and 1371s to 645s of CPU, with sentence
punctuation improving from 26.7 to 28.0 enders per 1k rather than regressing.
