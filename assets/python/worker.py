#!/usr/bin/env python3
"""
Audio-to-GP worker — Steps 1 + 2 only.
  Step 1: demucs source separation  (MP3 → WAV stems)
  Step 2: basic-pitch MIDI export    (WAV stems → MIDI)

All progress/result output is emitted as JSON lines on stdout so the
Flutter app can parse them.  Stderr is left for raw demucs/basic-pitch
subprocess output (Flutter forwards it to the log panel).

Usage:
  python worker.py \\
    --input song.mp3 \\
    --output-dir ./output \\
    --model htdemucs_ft \\
    --stems bass,drums,other,vocals

Output lines (stdout, one JSON object per line):
  {"type":"progress","step":1,"pct":0,"msg":"Starting demucs..."}
  {"type":"progress","step":1,"pct":100,"msg":"Stems written to: ..."}
  {"type":"progress","step":2,"pct":50,"msg":"Converting bass..."}
  {"type":"done","midi_files":{"bass":"/abs/path/bass_basic_pitch.mid",...}}
  {"type":"error","step":1,"msg":"demucs failed: ..."}
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import subprocess
import sys
import threading
from collections import defaultdict
from pathlib import Path

# Silence TensorFlow C++ runtime messages and oneDNN info before any ML
# library is imported.  These must be set before 'import tensorflow'.
os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "3")
os.environ.setdefault("TF_ENABLE_ONEDNN_OPTS", "0")
os.environ.setdefault("PYTHONWARNINGS", "ignore")


# ---------------------------------------------------------------------------
# JSON output helpers
# ---------------------------------------------------------------------------

def _emit(obj: dict) -> None:
    print(json.dumps(obj), flush=True)

def _progress(step: int, pct: int, msg: str) -> None:
    _emit({"type": "progress", "step": step, "pct": pct, "msg": msg})

def _done(midi_files: dict[str, str], gp5_path: str | None = None) -> None:
    obj: dict = {"type": "done", "midi_files": midi_files}
    if gp5_path is not None:
        obj["gp5_path"] = gp5_path
    _emit(obj)

def _error(step: int, msg: str) -> None:
    _emit({"type": "error", "step": step, "msg": msg})
    sys.exit(1)


# ---------------------------------------------------------------------------
# Device detection
# ---------------------------------------------------------------------------

def _detect_device() -> tuple[bool, str]:
    """Return (cuda_available, device_string) using torch."""
    try:
        import torch
        if torch.cuda.is_available():
            name = torch.cuda.get_device_name(0)
            return True, f"cuda  ({name})"
        return False, "cpu"
    except Exception as exc:
        return False, f"cpu  (torch error: {exc})"


# ---------------------------------------------------------------------------
# Subprocess runners
# ---------------------------------------------------------------------------

def _run(cmd: list[str], step: int, step_name: str) -> None:
    """Run cmd, capture stdout+stderr; raise on non-zero exit."""
    env = os.environ.copy()
    env["PYTHONUTF8"] = "1"
    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        env=env,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        _error(step, f"{step_name} failed (exit {result.returncode}): {detail[:500]}")


_TQDM_PCT_RE = re.compile(r'(\d{1,3})%\|')


def _run_demucs(
    cmd: list[str],
    step: int,
    step_name: str,
    pct_start: int = 5,
    pct_end: int = 95,
) -> None:
    """Run demucs, stream stderr for tqdm progress, emit step events."""
    env = os.environ.copy()
    env["PYTHONUTF8"] = "1"
    # Force tqdm to write output even when stderr is a pipe.
    env["TQDM_DISABLE"] = "0"
    env["TQDM_MININTERVAL"] = "2"   # emit at most one update per 2 s
    env["TQDM_NCOLS"] = "60"        # fixed width → simpler output

    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        env=env,
    )

    stderr_lines: list[str] = []

    def _read_stderr() -> None:
        assert proc.stderr is not None
        for raw in proc.stderr:
            # tqdm overwrites lines with \r; split on both \r and \n
            for part in re.split(r'[\r\n]+', raw):
                part = part.strip()
                if not part:
                    continue
                stderr_lines.append(part)
                m = _TQDM_PCT_RE.search(part)
                if m:
                    raw_pct = int(m.group(1))
                    scaled = pct_start + int((pct_end - pct_start) * raw_pct / 100)
                    _progress(step, scaled, part)

    t = threading.Thread(target=_read_stderr, daemon=True)
    t.start()

    # Consume stdout so the process is not blocked by a full pipe buffer.
    stdout_out = proc.stdout.read() if proc.stdout else ""
    proc.wait()
    t.join(timeout=15)

    if proc.returncode != 0:
        detail = "\n".join(stderr_lines[-15:]) or stdout_out
        _error(step, f"{step_name} failed (exit {proc.returncode}): {detail[:500]}")


# ---------------------------------------------------------------------------
# Step 1 — Source separation (demucs)
# ---------------------------------------------------------------------------

def step1_demucs(input_mp3: Path, stems_dir: Path, model: str, cuda: bool) -> Path:
    device = "cuda" if cuda else "cpu"
    _progress(1, 0, f"Starting demucs  [model={model}  device={device}]")

    cmd = [
        sys.executable, "-m", "demucs",
        "-n", model,
        "-d", device,          # explicit device — never falls back silently
        "--out", str(stems_dir),
        str(input_mp3),
    ]
    # Use streaming runner so tqdm ▶ Flutter progress bar in real time.
    _run_demucs(cmd, 1, "demucs", pct_start=5, pct_end=95)

    stem_folder = stems_dir / model / input_mp3.stem
    if not stem_folder.exists():
        _error(1, f"Expected demucs output at '{stem_folder}' but not found.")

    wavs = sorted(stem_folder.glob("*.wav"))
    _progress(1, 100, f"Stems written to {stem_folder} — {[w.stem for w in wavs]}")
    return stem_folder


# ---------------------------------------------------------------------------
# Step 2 — Audio → MIDI (basic-pitch)
# ---------------------------------------------------------------------------

def step2_basic_pitch(
    stem_folder: Path,
    midi_dir: Path,
    track_name: str,
    selected_stems: list[str],
    cuda: bool,
) -> dict[str, str]:
    _progress(2, 0, "Starting basic-pitch…")

    # Import once so the ONNX model is loaded only once across all stems.
    # Suppress basic-pitch optional-backend warnings (coremltools, tflite)
    # and TF startup noise before importing.
    import logging as _logging
    import warnings as _warnings
    _warnings.filterwarnings("ignore")          # Python warnings module
    _logging.getLogger().setLevel(_logging.ERROR)  # root logger (coremltools etc.)
    _logging.getLogger("basic_pitch").setLevel(_logging.ERROR)
    for _noisy in ("absl", "tensorflow", "tflite_runtime", "coremltools"):
        _logging.getLogger(_noisy).setLevel(_logging.ERROR)
    try:
        import onnxruntime as ort
        from basic_pitch.inference import Model, predict
        from basic_pitch import ICASSP_2022_MODEL_PATH
        import pretty_midi  # noqa: F401 — verify importable
    except ImportError as exc:
        _error(2, f"basic-pitch / onnxruntime import failed: {exc} — re-run setup.")

    # Build the ONNX InferenceSession with explicit providers.
    # CUDAExecutionProvider is only available when onnxruntime-gpu is installed.
    available_providers = ort.get_available_providers()
    if cuda and "CUDAExecutionProvider" in available_providers:
        providers = ["CUDAExecutionProvider", "CPUExecutionProvider"]
        device_label = "CUDA"
    else:
        providers = ["CPUExecutionProvider"]
        device_label = "CPU"
        if cuda:
            _progress(2, 2, (
                "Warning: onnxruntime-gpu not available — "
                "basic-pitch will run on CPU. Re-run setup to fix."
            ))

    # ICASSP_2022_MODEL_PATH points to a TF SavedModel directory (e.g. .../nmp).
    # The ONNX file ships alongside it as nmp.onnx — append the extension.
    onnx_model_path = Path(str(ICASSP_2022_MODEL_PATH) + '.onnx')
    if not onnx_model_path.exists():
        # Fallback: look inside the directory for any .onnx file.
        candidates = list(Path(str(ICASSP_2022_MODEL_PATH)).parent.glob('*.onnx'))
        if not candidates:
            _error(2, (
                f"ONNX model not found at {onnx_model_path}. "
                "Reinstall with: uv pip install basic-pitch"
            ))
        onnx_model_path = candidates[0]

    _progress(2, 3, f"basic-pitch using {device_label} — loading ONNX model…")

    # Construct the Model object with our chosen providers, bypassing the
    # auto-detection in Model.__init__ which may default to TensorFlow.
    bp_model = Model.__new__(Model)
    bp_model.model_type = Model.MODEL_TYPES.ONNX
    bp_model.model = ort.InferenceSession(
        str(onnx_model_path), providers=providers
    )

    wav_files = sorted(stem_folder.glob("*.wav"))
    if not wav_files:
        _error(2, f"No WAV files in '{stem_folder}'")

    selected = [w for w in wav_files if w.stem in selected_stems]
    total = len(selected)
    midi_files: dict[str, str] = {}

    for idx, wav in enumerate(selected):
        stem_name = wav.stem
        pct = int(idx / max(total, 1) * 90) + 5  # 5–95 %
        _progress(2, pct, f"Converting {wav.name} → MIDI  [{device_label}]…")

        stem_midi_dir = midi_dir / track_name / stem_name
        stem_midi_dir.mkdir(parents=True, exist_ok=True)

        expected = stem_midi_dir / f"{stem_name}_basic_pitch.mid"
        if expected.exists():
            expected.unlink()  # avoid IOError from predict_and_save duplicate check

        try:
            _, midi_data, _ = predict(wav, bp_model)
            midi_data.write(str(expected))
        except Exception as exc:
            _error(2, f"basic-pitch failed for '{wav.name}': {exc}")

        if not expected.exists():
            _error(2, f"basic-pitch produced no MIDI for '{wav.name}'")

        midi_files[stem_name] = str(expected)

    _progress(2, 100, f"MIDI done — {list(midi_files.keys())}")
    return midi_files

# ---------------------------------------------------------------------------
# Step 3 — MIDI → Guitar Pro 5 (PyGuitarPro)
# ---------------------------------------------------------------------------

def step3_guitar_pro(
    midi_files: dict[str, str],
    output_dir: Path,
    track_name: str,
    model: str,
) -> str:
    """Convert MIDI stems to a .gp5 file via PyGuitarPro."""
    _progress(3, 0, "Building Guitar Pro file (PyGuitarPro)…")

    try:
        import guitarpro
        from guitarpro import models as gp
        import pretty_midi
    except ImportError as exc:
        _error(3, f"guitarpro / pretty_midi import failed: {exc} — re-run setup.")
        raise  # unreachable; satisfies type-checker

    QUARTER: int = gp.Duration().quarterTime   # 960
    GRID: int    = QUARTER // 4             # 240  (16th note)
    MEASURE: int = QUARTER * 4             # 3840 (4/4 bar)

    DUR_TABLE: list[tuple[int, int]] = [
        (MEASURE,       1),   # whole
        (QUARTER * 2,   2),   # half
        (QUARTER,       4),   # quarter
        (QUARTER // 2,  8),   # eighth
        (GRID,         16),   # sixteenth
    ]

    _GP_VELS = [15, 30, 45, 60, 75, 90, 105, 120]

    STEM_ORDER = ['bass', 'drums', 'guitar', 'piano', 'other', 'vocals']
    STEM_CFG: dict[str, dict] = {
        'bass':   {'name': 'Bass',   'strings': [43, 38, 33, 28],             'ch': 2,  'eff': 3,  'prog': 33, 'drums': False},
        'drums':  {'name': 'Drums',  'strings': [64, 59, 55, 50, 47, 43, 38], 'ch': 10, 'eff': 10, 'prog': 0,  'drums': True},
        'guitar': {'name': 'Guitar', 'strings': [64, 59, 55, 50, 45, 40],    'ch': 4,  'eff': 5,  'prog': 25, 'drums': False},
        'piano':  {'name': 'Piano',  'strings': [64, 59, 55, 50, 45, 40],    'ch': 6,  'eff': 7,  'prog': 0,  'drums': False},
        'other':  {'name': 'Other',  'strings': [64, 59, 55, 50, 45, 40],    'ch': 8,  'eff': 9,  'prog': 25, 'drums': False},
        'vocals': {'name': 'Vocals', 'strings': [64, 59, 55, 50, 45, 40],    'ch': 12, 'eff': 13, 'prog': 52, 'drums': False},
    }

    def _q(tick: int) -> int:
        return round(tick / GRID) * GRID

    def _pitch_to_tab(pitch: int, open_strs: list[int]) -> tuple[int, int] | None:
        best: tuple[int, int] | None = None
        for i, op in enumerate(open_strs):
            fret = pitch - op
            if 0 <= fret <= 22:
                if best is None or fret < best[1]:
                    best = (i + 1, fret)
        return best

    def _snap_vel(v: int) -> int:
        return min(_GP_VELS, key=lambda x: abs(x - v))

    def _rest_beats(voice: object, frm: int, to: int) -> list:
        rests, remaining, cur = [], to - frm, frm
        for dt, dv in DUR_TABLE:
            while remaining >= dt:
                b = gp.Beat(voice=voice, start=cur)
                b.status = gp.BeatStatus.rest
                b.duration = gp.Duration(value=dv)
                rests.append(b)
                cur += dt
                remaining -= dt
        return rests

    # --- Parse MIDI files ---
    sorted_stems = sorted(
        midi_files.keys(),
        key=lambda s: STEM_ORDER.index(s) if s in STEM_ORDER else 99,
    )
    global_bpm = 120
    max_gp_tick = QUARTER  # minimum 1 measure
    stem_events: dict[str, list[tuple[int, int, int, int]]] = {}

    for stem_name in sorted_stems:
        try:
            pm = pretty_midi.PrettyMIDI(midi_files[stem_name])
        except Exception as exc:
            _error(3, f"Failed to read MIDI for '{stem_name}': {exc}")
            raise

        tc_times, tc_tempos = pm.get_tempo_changes()
        if len(tc_tempos) > 0:
            global_bpm = max(40, min(300, int(round(tc_tempos[0]))))

        ppq = pm.resolution
        events: list[tuple[int, int, int, int]] = []
        for inst in pm.instruments:
            for note in inst.notes:
                raw_s = pm.time_to_tick(note.start)
                raw_e = pm.time_to_tick(note.end)
                gp_s = round(raw_s * QUARTER / ppq) + QUARTER
                gp_e = round(raw_e * QUARTER / ppq) + QUARTER
                qs = _q(gp_s)
                qe = max(_q(gp_e), qs + GRID)
                events.append((qs, qe, note.pitch, note.velocity))
                if qe > max_gp_tick:
                    max_gp_tick = qe
        stem_events[stem_name] = sorted(events)

    song_ticks = max_gp_tick - QUARTER
    n_measures = min(max(1, math.ceil(song_ticks / MEASURE)), 4096)

    # --- Build Song ---
    song = gp.Song()
    song.title = track_name
    song.tempo = global_bpm

    song.measureHeaders = []
    for i in range(n_measures):
        mh = gp.MeasureHeader()
        mh.number = i + 1
        mh.start = QUARTER + i * MEASURE
        mh.timeSignature.numerator = 4
        mh.timeSignature.denominator = gp.Duration(value=4)
        song.measureHeaders.append(mh)

    song.tracks = []
    for ti, stem_name in enumerate(sorted_stems):
        cfg = STEM_CFG.get(stem_name, STEM_CFG['other'])
        open_strs: list[int] = cfg['strings']

        gp_strings = [gp.GuitarString(number=i + 1, value=p) for i, p in enumerate(open_strs)]
        track = gp.Track(
            song=song,
            number=ti + 1,
            strings=gp_strings,
            name=cfg['name'],
            isPercussionTrack=cfg['drums'],
        )
        track.channel.channel       = cfg['ch']
        track.channel.effectChannel = cfg['eff']
        track.channel.instrument    = cfg['prog']
        track.channel.volume  = 13
        track.channel.balance = 8
        track.fretCount = 24

        events = stem_events.get(stem_name, [])
        by_pos: dict[int, list[tuple[int, int, int]]] = defaultdict(list)
        for (qs, qe, pitch, vel) in events:
            by_pos[qs].append((qe, pitch, vel))

        # Track is auto-populated with measures from song.measureHeaders;
        # iterate by index instead of creating new Measure objects.
        for mi, mh in enumerate(song.measureHeaders):
            measure = track.measures[mi]
            voice   = measure.voices[0]
            m_start = mh.start
            m_end   = m_start + MEASURE

            cursor   = m_start
            pos_list = sorted(p for p in by_pos if m_start <= p < m_end)
            beats: list = []

            for ki, pos in enumerate(pos_list):
                if pos > cursor:
                    beats.extend(_rest_beats(voice, cursor, pos))
                    cursor = pos

                next_pos = pos_list[ki + 1] if ki + 1 < len(pos_list) else m_end
                max_dur  = min(next_pos - pos, m_end - pos)
                dur_ticks, dur_val = GRID, 16
                for dt, dv in DUR_TABLE:
                    if max_dur >= dt:
                        dur_ticks, dur_val = dt, dv
                        break

                beat = gp.Beat(voice=voice, start=pos)
                beat.duration = gp.Duration(value=dur_val)
                beat.status   = gp.BeatStatus.normal

                used_strs: set[int] = set()
                for (_, pitch, vel) in by_pos[pos]:
                    tab = _pitch_to_tab(pitch, open_strs)
                    if tab is None:
                        continue
                    s_num, fret = tab
                    if s_num in used_strs:
                        continue
                    used_strs.add(s_num)
                    note = gp.Note(
                        beat=beat, string=s_num, value=fret,
                        velocity=_snap_vel(vel), type=gp.NoteType.normal,
                    )
                    beat.notes.append(note)

                if not beat.notes:
                    beat.status = gp.BeatStatus.rest
                beats.append(beat)
                cursor = pos + dur_ticks

            if cursor < m_end:
                beats.extend(_rest_beats(voice, cursor, m_end))

            if not beats:
                b = gp.Beat(voice=voice, start=m_start)
                b.status   = gp.BeatStatus.rest
                b.duration = gp.Duration(value=1)
                beats.append(b)

            voice.beats = beats

            # Voice 1: single whole-measure rest (required by GP5 format)
            voice1 = measure.voices[1]
            r = gp.Beat(voice=voice1, start=m_start)
            r.status   = gp.BeatStatus.rest
            r.duration = gp.Duration(value=1)
            voice1.beats = [r]

            # measure already lives in track.measures — no append needed

        song.tracks.append(track)
        _progress(3, 10 + int(80 * (ti + 1) / max(len(sorted_stems), 1)),
                  f"Track '{cfg['name']}' built")

    gp_dir = output_dir / 'guitar_pro'
    gp_dir.mkdir(parents=True, exist_ok=True)
    gp_path = gp_dir / f"{track_name}_{model}.gp5"
    try:
        guitarpro.write(song, str(gp_path))
    except Exception as exc:
        _error(3, f"guitarpro.write failed: {exc}")
        raise
    _progress(3, 100, f"GP5 written → {gp_path}")
    return str(gp_path)


def main() -> None:
    parser = argparse.ArgumentParser(description="Audio-to-GP worker (steps 1+2)")
    parser.add_argument("--input",      required=True, help="Path to .mp3 file")
    parser.add_argument("--output-dir", required=True, help="Root output directory")
    parser.add_argument("--model",      required=True, help="Demucs model name")
    parser.add_argument(
        "--stems",
        required=True,
        help="Comma-separated stems to process (e.g. bass,drums,other,vocals)",
    )
    args = parser.parse_args()

    cuda, device_label = _detect_device()
    _progress(0, 0, f"Worker started — device: {device_label}")

    input_mp3  = Path(args.input).resolve()
    output_dir = Path(args.output_dir).resolve()
    model      = args.model
    stems      = [s.strip() for s in args.stems.split(",") if s.strip()]

    if not input_mp3.exists():
        _error(0, f"Input file not found: {input_mp3}")

    stems_dir = output_dir / "stems"
    midi_dir  = output_dir / "midi"
    stems_dir.mkdir(parents=True, exist_ok=True)
    midi_dir.mkdir(parents=True, exist_ok=True)

    track_name = input_mp3.stem

    # Step 1
    stem_folder = step1_demucs(input_mp3, stems_dir, model, cuda)

    # Step 2
    midi_files = step2_basic_pitch(stem_folder, midi_dir, track_name, stems, cuda)

    # Step 3
    gp5_path = step3_guitar_pro(midi_files, output_dir, track_name, model)

    _done(midi_files, gp5_path=gp5_path)


if __name__ == "__main__":
    main()
