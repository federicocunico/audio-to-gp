#!/usr/bin/env python3
"""
Audio-to-Sheet-Music Pipeline
MP3 → Stems (demucs) → MIDI (basic-pitch) → PDF/MusicXML (MuseScore)

Usage:
    uv run python pipeline.py --input song.mp3
    uv run python pipeline.py --input song.mp3 --output-dir ./my_output --include-drums
"""

import argparse
import importlib.util
import logging
import platform
import shutil
import subprocess
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def setup_logging(output_dir: Path) -> logging.Logger:
    log_file = output_dir / "pipeline.log"
    logger = logging.getLogger("pipeline")
    logger.setLevel(logging.DEBUG)
    fmt = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s", datefmt="%H:%M:%S")

    ch = logging.StreamHandler(sys.stdout)
    ch.setLevel(logging.INFO)
    ch.setFormatter(fmt)
    logger.addHandler(ch)

    fh = logging.FileHandler(log_file, encoding="utf-8")
    fh.setLevel(logging.DEBUG)
    fh.setFormatter(fmt)
    logger.addHandler(fh)

    return logger


# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

def find_mscore(user_path: str | None) -> str:
    """Return the MuseScore binary path or raise RuntimeError."""
    if user_path:
        if not Path(user_path).exists():
            raise RuntimeError(f"MuseScore binary not found at: {user_path}")
        return user_path

    # Check $PATH first (covers custom installs and Linux distro packages)
    for name in ["MuseScore4", "mscore4", "mscore"]:
        found = shutil.which(name)
        if found:
            return found

    # Fall back to well-known default locations
    system = platform.system()
    candidates: list[str] = []
    if system == "Windows":
        candidates = [
            r"C:\Program Files\MuseScore 4\bin\MuseScore4.exe",
            r"C:\Program Files\MuseScore4\bin\MuseScore4.exe",
        ]
    elif system == "Darwin":
        candidates = [
            "/Applications/MuseScore 4.app/Contents/MacOS/mscore",
            "/Applications/MuseScore4.app/Contents/MacOS/mscore",
        ]

    for path in candidates:
        if Path(path).exists():
            return path

    raise RuntimeError(
        "MuseScore binary not found. Install MuseScore 4, or pass --mscore-path "
        "to specify its location."
    )


def preflight_check(mscore_path: str | None, skip_musescore: bool = False) -> dict:
    """Verify all required external tools are present. Returns resolved tool paths."""
    errors: list[str] = []

    # FFmpeg
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        errors.append("ffmpeg not found in PATH. Install FFmpeg and ensure it is on PATH.")

    # demucs (Python package)
    if importlib.util.find_spec("demucs") is None:
        errors.append(
            "demucs Python package not installed. Run: uv sync  (or pip install demucs)"
        )

    # basic-pitch (CLI binary installed by the package)
    basic_pitch_bin = shutil.which("basic-pitch")
    if not basic_pitch_bin:
        errors.append(
            "basic-pitch CLI not found in PATH. Run: uv sync  (or pip install basic-pitch)"
        )

    # MuseScore
    mscore_bin: str | None = None
    if not skip_musescore:
        try:
            mscore_bin = find_mscore(mscore_path)
        except RuntimeError as exc:
            errors.append(str(exc))

    if errors:
        raise RuntimeError(
            "Preflight checks failed:\n" + "\n".join(f"  • {e}" for e in errors)
        )

    return {"ffmpeg": ffmpeg, "basic_pitch": basic_pitch_bin, "mscore": mscore_bin}


# ---------------------------------------------------------------------------
# MuseScore headless helpers
# ---------------------------------------------------------------------------

def _mscore_supports_headless(mscore_bin: str) -> bool:
    """Return True if the binary supports --headless (MuseScore 4.4+)."""
    try:
        result = subprocess.run(
            [mscore_bin, "--help"],
            capture_output=True,
            text=True,
            timeout=15,
        )
        return "--headless" in (result.stdout + result.stderr)
    except Exception:
        return False


def _build_mscore_cmd(
    mscore_bin: str, input_mid: Path, output_file: Path
) -> list[str]:
    """Build the MuseScore CLI command with platform-appropriate headless flags."""
    system = platform.system()

    if system == "Linux":
        if _mscore_supports_headless(mscore_bin):
            return [mscore_bin, "--headless", "-o", str(output_file), str(input_mid)]
        if shutil.which("xvfb-run"):
            if not shutil.which("xauth"):
                raise RuntimeError(
                    "On Linux, xvfb-run requires xauth but it was not found.\n"
                    "Install xauth:  sudo apt install xauth"
                )
            return ["xvfb-run", "-a", mscore_bin, "-o", str(output_file), str(input_mid)]
        raise RuntimeError(
            "On Linux, MuseScore requires either --headless support (v4.4+) or xvfb-run.\n"
            "Install xvfb:  sudo apt install xvfb"
        )

    # Windows and macOS: native headless support
    return [mscore_bin, "-o", str(output_file), str(input_mid)]


# ---------------------------------------------------------------------------
# Subprocess runner
# ---------------------------------------------------------------------------

def run_subprocess(cmd: list[str], step_name: str, logger: logging.Logger) -> None:
    """Run a subprocess; raise RuntimeError with context on non-zero exit."""
    import os
    env = os.environ.copy()
    env["PYTHONUTF8"] = "1"   # prevent UnicodeEncodeError on Windows cp1252 consoles

    logger.debug("CMD: %s", " ".join(cmd))
    result = subprocess.run(
        cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", env=env
    )
    if result.stdout:
        logger.debug("stdout:\n%s", result.stdout.strip())
    if result.returncode != 0:
        logger.error("[%s] FAILED (exit %d)", step_name, result.returncode)
        if result.stderr:
            logger.error("stderr:\n%s", result.stderr.strip())
        raise RuntimeError(
            f"Step '{step_name}' failed with exit code {result.returncode}. "
            "See pipeline.log for details."
        )


# ---------------------------------------------------------------------------
# Step 1 — Source separation (demucs)
# ---------------------------------------------------------------------------

def step1_demucs(
    input_mp3: Path,
    stems_dir: Path,
    model: str,
    logger: logging.Logger,
) -> Path:
    """
    Run demucs on input_mp3.
    Returns the path to the folder containing the separated WAV stems.
    """
    logger.info("=" * 60)
    logger.info("STEP 1 — Source separation  [demucs model: %s]", model)
    logger.info("=" * 60)

    cmd = [
        sys.executable, "-m", "demucs",
        "-n", model,
        "--out", str(stems_dir),
        str(input_mp3),
    ]
    run_subprocess(cmd, "demucs", logger)

    stem_folder = stems_dir / model / input_mp3.stem
    if not stem_folder.exists():
        raise RuntimeError(
            f"Expected demucs output at '{stem_folder}' but it was not found. "
            "Check that the model name is correct."
        )

    wav_files = list(stem_folder.glob("*.wav"))
    logger.info("Stems written to: %s", stem_folder)
    logger.info("Found stems: %s", ", ".join(f.stem for f in sorted(wav_files)))
    return stem_folder


# ---------------------------------------------------------------------------
# Step 2 — Audio-to-MIDI (basic-pitch)
# ---------------------------------------------------------------------------

def step2_basic_pitch(
    stem_folder: Path,
    midi_dir: Path,
    track_name: str,
    selected_stems: list[str] | None,
    basic_pitch_bin: str,
    logger: logging.Logger,
) -> list[tuple[str, Path]]:
    """
    Run basic-pitch on each stem WAV file.
    ``selected_stems`` limits which stems are processed; None means all.
    Returns a list of (stem_name, midi_path) tuples.
    """
    logger.info("=" * 60)
    logger.info("STEP 2 — Audio-to-MIDI  [basic-pitch]")
    logger.info("=" * 60)

    wav_files = sorted(stem_folder.glob("*.wav"))
    if not wav_files:
        raise RuntimeError(f"No WAV files found in '{stem_folder}'")

    # Each stem gets its own subdirectory so basic-pitch outputs don't collide
    midi_results: list[tuple[str, Path]] = []

    for wav in wav_files:
        stem_name = wav.stem  # e.g. "bass", "drums", "vocals", "other"

        if selected_stems is not None and stem_name not in selected_stems:
            logger.info("  Skipping '%s' stem (not in selected stems)", stem_name)
            continue

        logger.info("  Converting '%s' → MIDI …", wav.name)

        stem_midi_dir = midi_dir / track_name / stem_name
        stem_midi_dir.mkdir(parents=True, exist_ok=True)

        cmd = [basic_pitch_bin, str(stem_midi_dir), str(wav)]
        run_subprocess(cmd, f"basic-pitch:{stem_name}", logger)

        # basic-pitch names the file: {wav_stem}_basic_pitch.mid
        expected_mid = stem_midi_dir / f"{stem_name}_basic_pitch.mid"
        if not expected_mid.exists():
            # Fallback: grab any .mid in the output dir
            candidates = list(stem_midi_dir.glob("*.mid"))
            if not candidates:
                raise RuntimeError(
                    f"basic-pitch produced no MIDI file for '{wav.name}'"
                )
            expected_mid = candidates[0]
            logger.warning(
                "  Unexpected basic-pitch output name; using '%s'", expected_mid.name
            )

        logger.info("  → %s", expected_mid)
        midi_results.append((stem_name, expected_mid))

    return midi_results


# ---------------------------------------------------------------------------
# Step 3 — Notation export (MuseScore)
# ---------------------------------------------------------------------------

def step3_musescore(
    midi_results: list[tuple[str, Path]],
    sheets_dir: Path,
    track_name: str,
    mscore_bin: str,
    logger: logging.Logger,
) -> None:
    """Convert each MIDI file to PDF and MusicXML using MuseScore."""
    logger.info("=" * 60)
    logger.info("STEP 3 — Notation export  [MuseScore]")
    logger.info("=" * 60)

    for stem_name, mid_path in midi_results:
        base_name = f"{track_name}_{stem_name}"
        for ext in (".pdf", ".musicxml"):
            out_file = sheets_dir / (base_name + ext)
            logger.info("  %s → %s …", mid_path.name, out_file.name)
            cmd = _build_mscore_cmd(mscore_bin, mid_path, out_file)
            run_subprocess(cmd, f"mscore:{stem_name}{ext}", logger)
            logger.info("  → %s", out_file)


# ---------------------------------------------------------------------------
# Step 4 — Guitar Pro export
# ---------------------------------------------------------------------------

def step4_guitar_pro(
    midi_results: list[tuple[str, Path]],
    output_dir: Path,
    track_name: str,
    logger: logging.Logger,
    midi_dir: Path | None = None,
) -> "Path | None":
    """
    Merge all stem MIDI files into a single Guitar Pro 5 (.gp5) file with
    one track per stem.  Requires the optional 'guitarpro' package.
    Returns the path to the .gp5 file, or None on failure.
    """
    try:
        import guitarpro as gp  # noqa: PLC0415
    except ImportError:
        logger.warning(
            "guitarpro package not installed – skipping GP export. "
            "Add 'guitarpro' to pyproject.toml deps and run: uv sync"
        )
        return None

    import mido  # noqa: PLC0415

    logger.info("=" * 60)
    logger.info("STEP 4 — Guitar Pro 5 export  [guitarpro]")
    logger.info("=" * 60)

    # Merge in any previously-generated MIDIs sitting in midi_dir that are
    # not already covered by the current run (e.g. stems from an earlier run
    # with a different model or selection).
    midi_results = list(midi_results)  # mutable copy
    if midi_dir is not None:
        known = {s for s, _ in midi_results}
        track_midi_dir = midi_dir / track_name
        if track_midi_dir.is_dir():
            for mid_file in sorted(track_midi_dir.glob("*/*_basic_pitch.mid")):
                stem = mid_file.parent.name
                if stem not in known:
                    midi_results.append((stem, mid_file))
                    known.add(stem)
                    logger.info("  + Including existing MIDI for '%s': %s", stem, mid_file.name)

    if not midi_results:
        logger.warning("  No MIDI files to export — skipping GP step")
        return None

    QUARTER = 960          # GP ticks per quarter note (Duration(value=4).time)
    GRID    = QUARTER // 4  # 240 – 16th-note quantise grid
    MEASURE = 4 * QUARTER  # 3840 – 4/4 bar length in GP ticks

    # Ordered largest-first for greedy fill-gaps
    _DUR_TABLE: list[tuple[int, int]] = [
        (3840, 1), (1920, 2), (960, 4), (480, 8), (240, 16),
    ]

    # Piano strings: 6 strings spanning A0(21)–E6(87), covering full piano range.
    # _pitch_to_tab will find the lowest-fret position on these virtual strings.
    _PIANO_STRINGS: list[int] = [87, 72, 57, 43, 28, 21]

    # Per-stem instrument config  (instrument = General MIDI program number).
    # "ch" is omitted — channels are assigned dynamically per track index.
    _CFG: dict[str, dict] = {
        "bass":   {"name": "Bass",   "instrument": 33,
                   "strings": [43, 38, 33, 28]},           # G D A E (4-string)
        "other":  {"name": "Other",  "instrument":  0,
                   "strings": _PIANO_STRINGS},              # piano voicing
        "vocals": {"name": "Vocals", "instrument": 73,
                   "strings": _PIANO_STRINGS},
        "guitar": {"name": "Guitar", "instrument": 25,
                   "strings": [64, 59, 55, 50, 45, 40]},   # e B G D A E
        "piano":  {"name": "Piano",  "instrument":  0,
                   "strings": _PIANO_STRINGS},
    }
    # Default: piano voicing for any stem not in _CFG (drums, custom models, …)
    _DEF: dict = {"name": "Piano", "instrument": 0,
                  "strings": _PIANO_STRINGS}

    def _alloc_ch(idx: int) -> int:
        """Assign a MIDI channel (1-based), skipping channel 10 (percussion)."""
        ch = (idx % 15) + 1
        return ch + 1 if ch >= 10 else ch

    # ── helpers ───────────────────────────────────────────────────────────────

    def _quantise(tick: int) -> int:
        return round(tick / GRID) * GRID

    def _pitch_to_tab(
        pitch: int, open_strings: list[int]
    ) -> "tuple[int, int] | None":
        """(1-based string, fret) at the lowest available fret."""
        best: "tuple[int, int] | None" = None
        for i, op in enumerate(open_strings):
            fret = pitch - op
            if 0 <= fret <= 22:
                if best is None or fret < best[1]:
                    best = (i + 1, fret)
        return best

    def _fill_rests(voice: object, cursor: int, target: int) -> int:
        remaining = target - cursor
        for dt, dv in _DUR_TABLE:
            while remaining >= dt:
                b = gp.Beat(voice, status=gp.BeatStatus.rest,
                            duration=gp.Duration(value=dv))
                b.start = cursor
                voice.beats.append(b)
                cursor    += dt
                remaining -= dt
        return cursor

    def _parse_midi(
        midi_path: Path,
    ) -> "tuple[int, list[tuple[int, int, int, int]]]":
        """
        Returns (bpm, events) where events are
        (gp_start, gp_end, pitch, velocity) in absolute GP ticks
        (first measure starts at QUARTER=960).
        """
        mid      = mido.MidiFile(midi_path)
        ppq      = mid.ticks_per_beat
        tempo_us = 500_000  # 120 BPM default
        active: dict[int, tuple[int, int]] = {}
        events:  list[tuple[int, int, int, int]] = []
        abs_tick = 0
        for msg in mido.merge_tracks(mid.tracks):
            abs_tick += msg.time
            if msg.type == "set_tempo":
                tempo_us = msg.tempo
            elif msg.type == "note_on" and msg.velocity > 0:
                active[msg.note] = (abs_tick, msg.velocity)
            elif msg.type == "note_off" or (
                msg.type == "note_on" and msg.velocity == 0
            ):
                if msg.note in active:
                    s, vel = active.pop(msg.note)
                    gp_s = s        * QUARTER // ppq + QUARTER
                    gp_e = abs_tick * QUARTER // ppq + QUARTER
                    if gp_e > gp_s:
                        events.append((gp_s, gp_e, msg.note, vel))
        bpm = max(1, round(60_000_000 / tempo_us))
        return bpm, sorted(events)

    # ── parse ─────────────────────────────────────────────────────────────────

    all_events: dict[str, tuple[int, list]] = {}
    max_gp_tick  = QUARTER   # at least 1 measure
    detected_bpm = 120

    for stem_name, midi_path in midi_results:
        bpm, evts = _parse_midi(midi_path)
        all_events[stem_name] = (bpm, evts)
        detected_bpm = bpm
        if evts:
            max_gp_tick = max(max_gp_tick, max(e for _, e, _, _ in evts))

    song_length = max_gp_tick - QUARTER
    n_measures  = max(1, -(-song_length // MEASURE))  # ceiling division
    logger.info("  BPM: %d | Measures: %d", detected_bpm, n_measures)

    # ── Song ──────────────────────────────────────────────────────────────────

    song       = gp.Song()
    song.title = track_name
    song.tempo = detected_bpm
    # Song() starts with 1 default track and 1 default measure header —
    # clear both before installing our own structure.
    song.tracks.clear()
    song.measureHeaders.clear()

    headers: list = []
    for i in range(n_measures):
        h = gp.MeasureHeader()
        h.number = i + 1
        h.start  = QUARTER + i * MEASURE
        h.timeSignature.numerator   = 4
        h.timeSignature.denominator = gp.Duration(value=4)
        # MeasureHeader has no .tempo in guitarpro 0.11; tempo lives on Song
        headers.append(h)
    song.measureHeaders = headers

    # ── one Track per stem ────────────────────────────────────────────────────

    for t_idx, (stem_name, _) in enumerate(midi_results):
        cfg     = _CFG.get(stem_name, _DEF)
        strings = [gp.GuitarString(i + 1, p) for i, p in enumerate(cfg["strings"])]

        ch = _alloc_ch(t_idx)
        track      = gp.Track(song, number=t_idx + 1, strings=strings, measures=[])
        track.name = cfg.get("name", stem_name.capitalize())
        track.channel = gp.MidiChannel(
            channel=ch, effectChannel=ch,
            instrument=cfg["instrument"], volume=127, balance=64,
        )

        _bpm, raw_events = all_events[stem_name]

        # Quantise to 16th-note grid
        q_events: list[tuple[int, int, int, int]] = []
        for s, e, p, v in raw_events:
            qs = _quantise(s)
            qe = max(qs + GRID, _quantise(e))
            q_events.append((qs, qe, p, v))

        for header in headers:
            m_start = header.start
            m_end   = m_start + MEASURE

            m_evts = [(s, e, p, v) for s, e, p, v in q_events
                      if m_start <= s < m_end]

            measure = gp.Measure(track, header)
            # Measure auto-creates 2 voices; use voice 0
            voice   = measure.voices[0]

            cursor = m_start

            by_pos: dict[int, list] = {}
            for s, e, p, v in m_evts:
                by_pos.setdefault(s, []).append((e, p, v))

            sorted_pos = sorted(by_pos)
            for k, pos in enumerate(sorted_pos):
                if pos > cursor:
                    cursor = _fill_rests(voice, cursor, pos)

                # Duration capped by next event / measure boundary
                next_pos  = sorted_pos[k + 1] if k + 1 < len(sorted_pos) else m_end
                max_dur   = min(next_pos - pos, m_end - pos)
                dur_ticks = GRID
                dur_val   = 16
                for dt, dv in _DUR_TABLE:
                    if max_dur >= dt:
                        dur_ticks = dt
                        dur_val   = dv
                        break

                beat = gp.Beat(voice, duration=gp.Duration(value=dur_val))
                beat.start = pos

                used_strings: set[int] = set()
                for _e, pitch, vel in by_pos[pos]:
                    tab = _pitch_to_tab(pitch, cfg["strings"])
                    if tab is None:
                        continue
                    sn, fret = tab
                    if sn in used_strings:
                        continue  # skip duplicate string — would corrupt the stream
                    used_strings.add(sn)
                    # Note first arg is the parent beat (required in 0.11)
                    note = gp.Note(beat, value=fret, string=sn,
                                   type=gp.NoteType.normal)
                    note.velocity = vel
                    beat.notes.append(note)

                beat.status = gp.BeatStatus.normal if beat.notes else gp.BeatStatus.rest
                voice.beats.append(beat)
                cursor = pos + dur_ticks

            if cursor < m_end:
                _fill_rests(voice, cursor, m_end)

            track.measures.append(measure)

        song.tracks.append(track)

    # ── write ─────────────────────────────────────────────────────────────────

    output_dir.mkdir(parents=True, exist_ok=True)
    gp_path = output_dir / f"{track_name}.gp5"
    try:
        gp.write(song, str(gp_path))
    except Exception as exc:
        logger.error("guitarpro write failed: %s", exc)
        raise RuntimeError(f"Guitar Pro export failed: {exc}") from exc

    logger.info("  → %s", gp_path)
    return gp_path


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Headless Audio-to-Sheet-Music pipeline\n"
            "MP3 → Stems (demucs) → MIDI (basic-pitch) → PDF/MusicXML (MuseScore)"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--input", "-i",
        required=True,
        metavar="MP3_FILE",
        help="Path to the input .mp3 file",
    )
    parser.add_argument(
        "--output-dir", "-o",
        default="./output",
        metavar="DIR",
        help="Root output directory (default: ./output)",
    )
    parser.add_argument(
        "--model",
        default="htdemucs",
        metavar="MODEL",
        help="Demucs separation model (default: htdemucs)",
    )
    parser.add_argument(
        "--mscore-path",
        default=None,
        metavar="PATH",
        help="Path to MuseScore binary (auto-detected if omitted)",
    )
    parser.add_argument(
        "--stems",
        default=None,
        metavar="STEM1,STEM2",
        help=(
            "Comma-separated stems to include in MIDI/notation export "
            "(e.g. bass,vocals,guitar). Overrides --include-drums. "
            "Available stems depend on the demucs model."
        ),
    )
    parser.add_argument(
        "--include-drums",
        action="store_true",
        default=False,
        help=(
            "Include drums stem when --stems is not specified. "
            "Not recommended: basic-pitch produces poor results on percussive audio."
        ),
    )
    parser.add_argument(
        "--skip-musescore",
        action="store_true",
        default=False,
        help="Skip Step 3 (MuseScore notation export). Useful for testing Steps 1-2 only.",
    )
    parser.add_argument(
        "--skip-guitar-pro",
        action="store_true",
        default=False,
        help="Skip Step 4 (Guitar Pro .gp5 export). Requires the guitarpro package.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    input_mp3 = Path(args.input).resolve()
    if not input_mp3.exists():
        print(f"ERROR: Input file not found: {input_mp3}", file=sys.stderr)
        sys.exit(1)
    if input_mp3.suffix.lower() != ".mp3":
        print(f"WARNING: Input file does not have a .mp3 extension: {input_mp3.name}")

    output_dir = Path(args.output_dir).resolve()
    stems_dir = output_dir / "stems"
    midi_dir = output_dir / "midi"
    sheets_dir = output_dir / "sheets"

    for d in (output_dir, stems_dir, midi_dir, sheets_dir):
        d.mkdir(parents=True, exist_ok=True)

    logger = setup_logging(output_dir)

    track_name = input_mp3.stem
    logger.info("Audio-to-Sheet-Music Pipeline starting")
    logger.info("  Input     : %s", input_mp3)
    logger.info("  Track     : %s", track_name)
    logger.info("  Output    : %s", output_dir)
    logger.info("  Model     : %s", args.model)
    if args.stems:
        _cli_stems: list[str] | None = [s.strip() for s in args.stems.split(",") if s.strip()]
        logger.info("  Stems     : %s", ", ".join(_cli_stems))
    else:
        _cli_stems = None
        logger.info(
            "  Drums     : %s",
            "included" if args.include_drums else "skipped  (pass --include-drums or --stems)",
        )
    if args.skip_musescore:
        logger.info("  MuseScore : SKIPPED (--skip-musescore)")

    # --- preflight ---
    logger.info("Running preflight checks …")
    try:
        tools = preflight_check(
            mscore_path=args.mscore_path,
            skip_musescore=args.skip_musescore,
        )
    except RuntimeError as exc:
        logger.error(str(exc))
        sys.exit(1)
    logger.info(
        "Preflight OK  [ffmpeg=%s | basic-pitch=%s | mscore=%s]",
        tools["ffmpeg"],
        tools["basic_pitch"],
        tools["mscore"],
    )

    # --- step 1: demucs ---
    try:
        stem_folder = step1_demucs(input_mp3, stems_dir, args.model, logger)
    except RuntimeError as exc:
        logger.error("Pipeline aborted at Step 1: %s", exc)
        sys.exit(1)

    # --- step 2: basic-pitch ---
    # Resolve selected_stems: --stems wins; otherwise use --include-drums logic
    if _cli_stems is not None:
        _selected_stems: list[str] | None = _cli_stems
    elif not args.include_drums:
        _all = [w.stem for w in sorted(stem_folder.glob("*.wav"))]
        _selected_stems = [s for s in _all if s != "drums"]
    else:
        _selected_stems = None  # all stems
    try:
        midi_results = step2_basic_pitch(
            stem_folder=stem_folder,
            midi_dir=midi_dir,
            track_name=track_name,
            selected_stems=_selected_stems,
            basic_pitch_bin=tools["basic_pitch"],
            logger=logger,
        )
    except RuntimeError as exc:
        logger.error("Pipeline aborted at Step 2: %s", exc)
        sys.exit(1)

    # --- step 3: MuseScore ---
    if args.skip_musescore:
        logger.info("Skipping Step 3 (--skip-musescore)")
    else:
        try:
            step3_musescore(
                midi_results=midi_results,
                sheets_dir=sheets_dir,
                track_name=track_name,
                mscore_bin=tools["mscore"],
                logger=logger,
            )
        except RuntimeError as exc:
            logger.error("Pipeline aborted at Step 3: %s", exc)
            sys.exit(1)

    # --- step 4: Guitar Pro export ---
    if args.skip_guitar_pro:
        logger.info("Skipping Step 4 (--skip-guitar-pro)")
    else:
        try:
            gp_out = step4_guitar_pro(
                midi_results=midi_results,
                output_dir=output_dir / "guitar_pro",
                track_name=track_name,
                midi_dir=midi_dir,
                logger=logger,
            )
            if gp_out:
                logger.info("  GP5  → %s", gp_out)
        except RuntimeError as exc:
            logger.error("Step 4 failed (non-fatal, pipeline still succeeded): %s", exc)

    logger.info("=" * 60)
    logger.info("Pipeline complete!")
    logger.info("  Stems   → %s", stems_dir)
    logger.info("  MIDI    → %s", midi_dir)
    logger.info("  Sheets  → %s", sheets_dir)
    logger.info("  Log     → %s", output_dir / "pipeline.log")
    logger.info("=" * 60)


if __name__ == "__main__":
    main()
