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
import importlib.util
import json
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# JSON output helpers
# ---------------------------------------------------------------------------

def _emit(obj: dict) -> None:
    print(json.dumps(obj), flush=True)

def _progress(step: int, pct: int, msg: str) -> None:
    _emit({"type": "progress", "step": step, "pct": pct, "msg": msg})

def _done(midi_files: dict[str, str]) -> None:
    _emit({"type": "done", "midi_files": midi_files})

def _error(step: int, msg: str) -> None:
    _emit({"type": "error", "step": step, "msg": msg})
    sys.exit(1)


# ---------------------------------------------------------------------------
# Subprocess runner
# ---------------------------------------------------------------------------

def _run(cmd: list[str], step: int, step_name: str) -> None:
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


# ---------------------------------------------------------------------------
# Step 1 — Source separation (demucs)
# ---------------------------------------------------------------------------

def step1_demucs(input_mp3: Path, stems_dir: Path, model: str) -> Path:
    _progress(1, 0, f"Starting demucs  [model={model}]")

    cmd = [
        sys.executable, "-m", "demucs",
        "-n", model,
        "--out", str(stems_dir),
        str(input_mp3),
    ]
    _run(cmd, 1, "demucs")

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
) -> dict[str, str]:
    _progress(2, 0, "Starting basic-pitch…")

    basic_pitch_bin = shutil.which("basic-pitch")
    if not basic_pitch_bin:
        _error(2, "basic-pitch CLI not found in PATH.")

    wav_files = sorted(stem_folder.glob("*.wav"))
    if not wav_files:
        _error(2, f"No WAV files in '{stem_folder}'")

    total = len([w for w in wav_files if w.stem in selected_stems])
    done = 0
    midi_files: dict[str, str] = {}

    for wav in wav_files:
        stem_name = wav.stem
        if stem_name not in selected_stems:
            continue

        pct = int(done / max(total, 1) * 100)
        _progress(2, pct, f"Converting {wav.name} → MIDI…")

        stem_midi_dir = midi_dir / track_name / stem_name
        stem_midi_dir.mkdir(parents=True, exist_ok=True)

        _run([basic_pitch_bin, str(stem_midi_dir), str(wav)], 2, f"basic-pitch:{stem_name}")

        # basic-pitch names the output: {wav_stem}_basic_pitch.mid
        expected = stem_midi_dir / f"{stem_name}_basic_pitch.mid"
        if not expected.exists():
            candidates = list(stem_midi_dir.glob("*.mid"))
            if not candidates:
                _error(2, f"basic-pitch produced no MIDI for '{wav.name}'")
            expected = candidates[0]

        midi_files[stem_name] = str(expected)
        done += 1

    _progress(2, 100, f"MIDI done — {list(midi_files.keys())}")
    return midi_files


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

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
    stem_folder = step1_demucs(input_mp3, stems_dir, model)

    # Step 2
    midi_files = step2_basic_pitch(stem_folder, midi_dir, track_name, stems)

    _done(midi_files)


if __name__ == "__main__":
    main()
