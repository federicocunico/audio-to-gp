"""
Streamlit UI for the Audio-to-Sheet-Music pipeline.

Run with:
    uv run streamlit run app.py
"""

from __future__ import annotations

import base64
import logging
import tempfile
from pathlib import Path

import numpy as np
import plotly.graph_objects as go
import streamlit as st

# ── Page config ───────────────────────────────────────────────────────────────
st.set_page_config(
    page_title="Audio → Sheet Music",
    page_icon="🎵",
    layout="wide",
    initial_sidebar_state="expanded",
)

# ── Model → available stems ──────────────────────────────────────────────────
MODEL_STEMS: dict[str, list[str]] = {
    "htdemucs":    ["bass", "drums", "other", "vocals"],
    "htdemucs_6s": ["bass", "drums", "other", "vocals", "guitar", "piano"],
    "htdemucs_ft": ["bass", "drums", "other", "vocals"],
    "mdx_extra":   ["bass", "drums", "other", "vocals"],
    "mdx_extra_q": ["bass", "drums", "other", "vocals"],
}

# ── Session state defaults ────────────────────────────────────────────────────
_STATE_DEFAULTS: dict = {
    "pipeline_done": False,
    "pipeline_error": None,
    "log_lines": [],
    "track_name": None,
    "stem_wavs": {},   # stem_name → Path
    "midi_map": {},    # stem_name → Path
    "pdf_map": {},     # stem_name → Path
    "xml_map": {},     # stem_name → Path
    "gp_path": None,   # Path to combined .gp5 file
}

for _k, _v in _STATE_DEFAULTS.items():
    if _k not in st.session_state:
        st.session_state[_k] = _v


# ── Custom log handler ────────────────────────────────────────────────────────
class _SessionLogHandler(logging.Handler):
    """Appends formatted log records to st.session_state.log_lines."""

    def emit(self, record: logging.LogRecord) -> None:
        st.session_state.log_lines.append(self.format(record))


def _make_pipeline_logger() -> logging.Logger:
    """Return the pipeline logger wired to session state (replaces any prior handlers)."""
    logger = logging.getLogger("pipeline")
    logger.handlers.clear()
    logger.setLevel(logging.DEBUG)
    handler = _SessionLogHandler()
    handler.setFormatter(
        logging.Formatter("%(asctime)s [%(levelname)s] %(message)s", datefmt="%H:%M:%S")
    )
    logger.addHandler(handler)
    return logger


# ── Visualization helpers ─────────────────────────────────────────────────────

@st.cache_data(show_spinner=False)
def _waveform_fig(wav_str: str) -> go.Figure:
    import librosa  # noqa: PLC0415 – deferred heavy import

    y, sr = librosa.load(wav_str, sr=None, duration=90, mono=True)
    step = max(1, len(y) // 5000)
    times = np.arange(0, len(y), step) / sr
    amp = y[::step]

    fig = go.Figure(
        go.Scatter(
            x=times,
            y=amp,
            mode="lines",
            line=dict(color="#636EFA", width=0.7),
            name="waveform",
            hovertemplate="%{x:.2f}s<extra></extra>",
        )
    )
    fig.update_layout(
        height=160,
        margin=dict(l=0, r=0, t=28, b=0),
        title=dict(text="Waveform", font_size=13),
        xaxis_title="Time (s)",
        yaxis=dict(title="Amp", range=[-1.05, 1.05], zeroline=True, zerolinecolor="#555"),
        showlegend=False,
        plot_bgcolor="rgba(0,0,0,0)",
        paper_bgcolor="rgba(0,0,0,0)",
    )
    return fig


@st.cache_data(show_spinner=False)
def _spectrogram_fig(wav_str: str) -> go.Figure:
    import librosa  # noqa: PLC0415

    y, sr = librosa.load(wav_str, sr=None, duration=90, mono=True)
    S = librosa.feature.melspectrogram(y=y, sr=sr, n_mels=80, fmax=8000)
    S_db = librosa.power_to_db(S, ref=np.max)
    duration = len(y) / sr
    freqs = librosa.mel_frequencies(n_mels=80, fmax=8000).astype(int)

    fig = go.Figure(
        go.Heatmap(
            z=S_db,
            x=np.linspace(0, duration, S_db.shape[1]),
            y=freqs,
            colorscale="Viridis",
            showscale=False,
            zmin=-80,
            zmax=0,
            hovertemplate="Time: %{x:.2f}s<br>Freq: %{y} Hz<br>%{z:.1f} dB<extra></extra>",
        )
    )
    fig.update_layout(
        height=160,
        margin=dict(l=0, r=0, t=28, b=0),
        title=dict(text="Mel Spectrogram", font_size=13),
        xaxis_title="Time (s)",
        yaxis_title="Hz",
        plot_bgcolor="rgba(0,0,0,0)",
        paper_bgcolor="rgba(0,0,0,0)",
    )
    return fig


_NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]


def _pitch_label(midi_note: int) -> str:
    return f"{_NOTE_NAMES[midi_note % 12]}{midi_note // 12 - 1}"


@st.cache_data(show_spinner=False)
def _piano_roll_fig(midi_str: str, max_notes: int = 3000) -> go.Figure | None:
    import mido  # noqa: PLC0415

    mid = mido.MidiFile(midi_str)
    active: dict[int, tuple[float, int]] = {}
    notes: list[tuple[int, float, float, int]] = []
    t = 0.0

    # mido iteration merges all tracks; msg.time is delta seconds
    for msg in mid:
        t += msg.time
        if msg.type == "note_on" and msg.velocity > 0:
            active[msg.note] = (t, msg.velocity)
        elif msg.type == "note_off" or (msg.type == "note_on" and msg.velocity == 0):
            if msg.note in active:
                start, vel = active.pop(msg.note)
                if t > start:  # skip zero-length notes
                    notes.append((msg.note, start, t, vel))

    # close any still-open notes at end
    for pitch, (start, vel) in active.items():
        notes.append((pitch, start, t + 0.1, vel))

    if not notes:
        return None

    notes = notes[:max_notes]

    pitches    = [n[0] for n in notes]
    starts     = [n[1] for n in notes]
    durations  = [n[2] - n[1] for n in notes]
    velocities = [n[3] for n in notes]
    labels     = [_pitch_label(p) for p in pitches]

    lo = max(0,   min(pitches) - 2)
    hi = min(127, max(pitches) + 2)
    octave_ticks = [p for p in range(lo, hi + 1) if p % 12 == 0]

    fig = go.Figure(
        go.Bar(
            x=durations,
            y=pitches,
            base=starts,
            orientation="h",
            width=0.7,
            marker=dict(
                color=velocities,
                colorscale="Blues",
                cmin=0,
                cmax=127,
                colorbar=dict(title="Velocity", thickness=12, len=0.8),
            ),
            text=labels,
            hovertemplate=(
                "<b>%{text}</b><br>"
                "Start: %{base:.2f} s<br>"
                "Duration: %{x:.3f} s<br>"
                "Velocity: %{marker.color}<extra></extra>"
            ),
        )
    )
    fig.update_layout(
        height=max(220, min(500, (hi - lo) * 6)),
        margin=dict(l=0, r=0, t=28, b=0),
        title=dict(
            text=f"MIDI Piano Roll  ({len(notes):,} notes"
                 + (" — truncated" if len(notes) == max_notes else "") + ")",
            font_size=13,
        ),
        xaxis_title="Time (s)",
        yaxis=dict(
            title="Pitch",
            range=[lo - 0.5, hi + 0.5],
            tickvals=octave_ticks,
            ticktext=[_pitch_label(p) for p in octave_ticks],
        ),
        showlegend=False,
        bargap=0,
        bargroupgap=0,
        plot_bgcolor="rgba(0,0,0,0)",
        paper_bgcolor="rgba(0,0,0,0)",
    )
    return fig


def _midi_player_html(midi_bytes: bytes) -> str:
    """Return an HTML snippet with an html-midi-player web component."""
    b64 = base64.b64encode(midi_bytes).decode()
    src = f"data:audio/midi;base64,{b64}"
    return f"""<!DOCTYPE html>
<html><head>
  <script src="https://cdn.jsdelivr.net/combine/npm/tone@14/build/Tone.js,npm/@magenta/music@1.23.1/es6/core.js,npm/html-midi-player@1.5.0"></script>
  <style>
    body {{ margin: 0; background: transparent; overflow: hidden; }}
    midi-player {{ display: block; width: 100%; }}
  </style>
</head><body>
  <midi-player src="{src}" sound-font></midi-player>
</body></html>"""


def _pdf_embed_html(pdf_bytes: bytes) -> str:
    """Return an HTML snippet that renders a PDF via a browser blob URL."""
    b64 = base64.b64encode(pdf_bytes).decode()
    return f"""<!DOCTYPE html><html>
<head><style>body{{margin:0;padding:0;}}</style></head>
<body>
<iframe id="pf" style="width:100%;height:700px;border:none;border-radius:4px;" title="PDF Preview"></iframe>
<script>
const b64="{b64}";
const bin=atob(b64);const arr=new Uint8Array(bin.length);
for(let i=0;i<bin.length;i++)arr[i]=bin.charCodeAt(i);
const blob=new Blob([arr],{{type:'application/pdf'}});
document.getElementById('pf').src=URL.createObjectURL(blob);
</script>
</body></html>"""


# ── Stem result card ──────────────────────────────────────────────────────────

def _render_stem_card(
    stem_name: str,
    wav_path: Path | None,
    midi_path: Path | None,
    pdf_path: Path | None,
    xml_path: Path | None,
) -> None:

    # ── Waveform + Spectrogram ────────────────────────────────────────────────
    if wav_path and wav_path.exists():
        col_w, col_s = st.columns(2, gap="small")
        with col_w:
            with st.spinner("Rendering waveform…"):
                try:
                    st.plotly_chart(_waveform_fig(str(wav_path)), use_container_width=True)
                except Exception as exc:
                    st.warning(f"Waveform error: {exc}")
        with col_s:
            with st.spinner("Rendering spectrogram…"):
                try:
                    st.plotly_chart(_spectrogram_fig(str(wav_path)), use_container_width=True)
                except Exception as exc:
                    st.warning(f"Spectrogram error: {exc}")

        # Audio player
        st.audio(str(wav_path), format="audio/wav")
    else:
        st.info("WAV stem not found.")

    # ── MIDI Piano Roll ───────────────────────────────────────────────────────
    if midi_path and midi_path.exists():
        with st.spinner("Rendering piano roll…"):
            try:
                fig = _piano_roll_fig(str(midi_path))
                if fig:
                    st.plotly_chart(fig, use_container_width=True)
                else:
                    st.info("No MIDI notes found in this file.")
            except Exception as exc:
                st.warning(f"Piano roll error: {exc}")
        # ── MIDI interactive player ─────────────────────────────────────────────
        st.markdown("**MIDI Playback**")
        try:
            midi_html = _midi_player_html(midi_path.read_bytes())
            st.components.v1.html(midi_html, height=80)
        except Exception as exc:
            st.warning(f"MIDI player error: {exc}")
    elif midi_path is None:
        st.caption("MIDI not generated for this stem.")

    # ── Download buttons ──────────────────────────────────────────────────────
    st.markdown("**Downloads**")
    dl_items = [
        (wav_path,  "⬇ WAV",       "audio/wav",         f"{stem_name}.wav"),
        (midi_path, "⬇ MIDI",      "audio/midi",        f"{stem_name}.mid"),
        (pdf_path,  "⬇ PDF",       "application/pdf",   f"{stem_name}.pdf"),
        (xml_path,  "⬇ MusicXML",  "application/xml",   f"{stem_name}.musicxml"),
    ]
    available = [(p, lbl, mime, fname) for p, lbl, mime, fname in dl_items if p and p.exists()]
    if available:
        cols = st.columns(len(available))
        for col, (path, lbl, mime, fname) in zip(cols, available):
            with col:
                st.download_button(
                    lbl,
                    data=path.read_bytes(),
                    file_name=fname,
                    mime=mime,
                    use_container_width=True,
                )
    else:
        st.caption("No output files ready yet.")

    # ── PDF inline preview ────────────────────────────────────────────────────
    if pdf_path and pdf_path.exists():
        with st.expander("📄 Sheet Music PDF Preview", expanded=False):
            try:
                pdf_html = _pdf_embed_html(pdf_path.read_bytes())
                st.components.v1.html(pdf_html, height=730, scrolling=False)
            except Exception as exc:
                st.warning(f"PDF preview error: {exc}")


# ── Pipeline runner ───────────────────────────────────────────────────────────

def _run_pipeline(
    input_path: Path,
    output_dir: Path,
    model: str,
    selected_stems: list[str],
    mscore_path: str | None,
) -> None:
    """Run the full pipeline inline, driving Streamlit status widgets."""
    from pipeline import (  # noqa: PLC0415
        preflight_check,
        step1_demucs,
        step2_basic_pitch,
        step3_musescore,
        step4_guitar_pro,
    )

    # Reset state  (type(None)() is invalid, so handle None explicitly)
    for k, v in _STATE_DEFAULTS.items():
        st.session_state[k] = None if v is None else type(v)()

    logger = _make_pipeline_logger()

    stems_dir  = output_dir / "stems"
    midi_dir   = output_dir / "midi"
    sheets_dir = output_dir / "sheets"
    for d in (stems_dir, midi_dir, sheets_dir):
        d.mkdir(parents=True, exist_ok=True)

    track_name = input_path.stem
    st.session_state.track_name = track_name

    # ── Preflight ─────────────────────────────────────────────────────────────
    with st.status("Preflight: checking dependencies…", expanded=True) as _s:
        try:
            tools = preflight_check(mscore_path)
            for name, path in tools.items():
                st.write(f"✅ **{name}** → `{path}`")
            _s.update(label="✅ Preflight passed — all tools found", state="complete")
        except RuntimeError as exc:
            _s.update(label="❌ Preflight failed", state="error")
            st.error(str(exc))
            st.session_state.pipeline_error = str(exc)
            return

    # ── Step 1: Demucs ────────────────────────────────────────────────────────
    with st.status("Step 1 / 3 — Source separation (demucs)…", expanded=True) as _s:
        st.write(f"Model: `{model}` | Track: `{track_name}`")
        try:
            stem_folder = step1_demucs(input_path, stems_dir, model, logger)
            wav_files = sorted(stem_folder.glob("*.wav"))
            st.session_state.stem_wavs = {w.stem: w for w in wav_files}
            for w in wav_files:
                kb = w.stat().st_size // 1024
                st.write(f"🎵 `{w.name}` — {kb:,} KB")
            _s.update(
                label=f"✅ Step 1 complete — {len(wav_files)} stems extracted",
                state="complete",
            )
        except RuntimeError as exc:
            _s.update(label="❌ Step 1 failed", state="error")
            st.error(str(exc))
            st.session_state.pipeline_error = str(exc)
            return

    # ── Step 2: basic-pitch ───────────────────────────────────────────────────
    with st.status("Step 2 / 3 — Audio → MIDI (basic-pitch)…", expanded=True) as _s:
        _skipped = [s for s in MODEL_STEMS.get(model, []) if s not in selected_stems]
        if _skipped:
            st.caption(f"Skipping: {', '.join(_skipped)}")
        try:
            midi_results = step2_basic_pitch(
                stem_folder=stem_folder,
                midi_dir=midi_dir,
                track_name=track_name,
                selected_stems=selected_stems,
                basic_pitch_bin=tools["basic_pitch"],
                logger=logger,
            )
            midi_map: dict[str, Path] = {}
            for stem_name, mid_path in midi_results:
                kb = mid_path.stat().st_size // 1024
                st.write(f"🎹 `{mid_path.name}` — {kb:,} KB")
                midi_map[stem_name] = mid_path
            st.session_state.midi_map = midi_map
            _s.update(
                label=f"✅ Step 2 complete — {len(midi_results)} MIDI files created",
                state="complete",
            )
        except RuntimeError as exc:
            _s.update(label="❌ Step 2 failed", state="error")
            st.error(str(exc))
            st.session_state.pipeline_error = str(exc)
            return

    # ── Step 3: MuseScore ─────────────────────────────────────────────────────
    with st.status("Step 3 / 3 — Notation export (MuseScore)…", expanded=True) as _s:
        pdf_map: dict[str, Path] = {}
        xml_map: dict[str, Path] = {}
        try:
            step3_musescore(
                midi_results=midi_results,
                sheets_dir=sheets_dir,
                track_name=track_name,
                mscore_bin=tools["mscore"],
                logger=logger,
            )
            for stem_name, _ in midi_results:
                pdf = sheets_dir / f"{track_name}_{stem_name}.pdf"
                xml = sheets_dir / f"{track_name}_{stem_name}.musicxml"
                if pdf.exists():
                    pdf_map[stem_name] = pdf
                    st.write(f"📄 `{pdf.name}`")
                if xml.exists():
                    xml_map[stem_name] = xml
                    st.write(f"📋 `{xml.name}`")
            st.session_state.pdf_map = pdf_map
            st.session_state.xml_map = xml_map
            _s.update(
                label=f"✅ Step 3 complete — {len(pdf_map)} PDFs + {len(xml_map)} MusicXML files",
                state="complete",
            )
        except RuntimeError as exc:
            _s.update(label="❌ Step 3 failed (partial results may still be available)", state="error")
            st.warning(str(exc))
            st.session_state.pipeline_error = str(exc)
            # Don't return — stems and MIDI are still valid results

    # ── Step 4: Guitar Pro ────────────────────────────────────────────────────
    with st.status("Step 4 / 4 — Guitar Pro export (.gp5)…", expanded=True) as _s:
        try:
            gp_out = step4_guitar_pro(
                midi_results=midi_results,
                output_dir=output_dir / "guitar_pro",
                track_name=track_name,
                logger=logger,
                midi_dir=midi_dir,
            )
            if gp_out and gp_out.exists():
                kb = gp_out.stat().st_size // 1024
                st.write(f"🎸 `{gp_out.name}` — {kb:,} KB")
                st.session_state.gp_path = gp_out
                _s.update(
                    label=f"✅ Step 4 complete — {gp_out.name}",
                    state="complete",
                )
            else:
                _s.update(
                    label="⚠️ Step 4 skipped (guitarpro package not installed)",
                    state="complete",
                )
        except RuntimeError as exc:
            _s.update(label="⚠️ Step 4 failed (non-fatal)", state="error")
            st.warning(str(exc))

    st.session_state.pipeline_done = True


# ── Main UI ───────────────────────────────────────────────────────────────────

def main() -> None:
    st.title("🎵 Audio → Sheet Music")
    st.caption("MP3 → Stems (demucs) → MIDI (basic-pitch) → PDF / MusicXML (MuseScore)")

    # ── Sidebar ───────────────────────────────────────────────────────────────
    with st.sidebar:
        st.header("⚙️ Settings")

        model = st.selectbox(
            "Demucs model",
            list(MODEL_STEMS.keys()),
            index=0,
            help=(
                "**htdemucs** — default, 4 stems (bass/drums/other/vocals).  \n"
                "**htdemucs_6s** — 6 stems, adds *guitar* and *piano*.  \n"
                "**htdemucs_ft** — fine-tuned 4-stem, higher quality, slower.  \n"
                "**mdx_extra / mdx_extra_q** — alternative architecture."
            ),
        )

        _available = MODEL_STEMS[model]
        _default = [s for s in _available if s != "drums"]
        selected_stems: list[str] = st.multiselect(
            "Stems to process (MIDI + notation)",
            options=_available,
            default=_default,
            help=(
                "Choose which stems to convert to MIDI and sheet music.  \n"
                "*Drums* is excluded by default — basic-pitch is pitch-based "
                "and produces poor results on percussive audio.  \n"
                "**htdemucs\_6s** unlocks *guitar* and *piano* stems."
            ),
        )

        output_dir_str = st.text_input(
            "Output directory",
            value="./output",
            help="Root folder for stems/, midi/, and sheets/ subdirectories.",
        )

        mscore_override = st.text_input(
            "MuseScore binary path",
            value="",
            placeholder="Auto-detected",
            help="Leave blank for auto-detection. Override for non-standard installations.",
        )

        st.divider()
        st.markdown(
            "**Pipeline steps**\n"
            "1. `demucs` — source separation\n"
            "2. `basic-pitch` — audio → MIDI\n"
            "3. `MuseScore` — MIDI → PDF/MusicXML"
        )
        st.divider()
        st.markdown(
            "**Tips**\n"
            "- First run downloads ~300 MB of demucs model weights.\n"
            "- GPU (CUDA) dramatically speeds up demucs.\n"
            "- Processing a 4-min track on CPU takes ~5–15 min."
        )

    # ── File upload ───────────────────────────────────────────────────────────
    uploaded = st.file_uploader(
        "Upload an MP3 file",
        type=["mp3"],
        help="The filename (without extension) is used as the track name throughout the pipeline.",
    )

    if uploaded is None:
        st.info("👆 Upload an MP3 file to get started.")
        return

    st.audio(uploaded, format="audio/mp3")

    col_run, col_reset = st.columns([4, 1])
    with col_run:
        run_clicked = st.button(
            "▶  Run Pipeline",
            type="primary",
            use_container_width=True,
            disabled=st.session_state.pipeline_done,  # prevent accidental re-run
        )
    with col_reset:
        if st.button("↺ Reset", use_container_width=True):
            for k, v in _STATE_DEFAULTS.items():
                st.session_state[k] = None if v is None else type(v)()
            # Also clear viz caches so a new file gets fresh plots
            _waveform_fig.clear()
            _spectrogram_fig.clear()
            _piano_roll_fig.clear()
            st.rerun()

    # ── Execute ───────────────────────────────────────────────────────────────
    if run_clicked:
        # Save the uploaded file to a temp path named after the original file
        # so demucs uses the correct track name.
        tmp_dir = Path(tempfile.mkdtemp())
        input_path = tmp_dir / uploaded.name
        input_path.write_bytes(uploaded.getbuffer())

        _run_pipeline(
            input_path=input_path,
            output_dir=Path(output_dir_str).resolve(),
            model=model,
            selected_stems=selected_stems,
            mscore_path=mscore_override.strip() or None,
        )

    # ── Results ───────────────────────────────────────────────────────────────
    if st.session_state.pipeline_done:
        st.divider()
        st.header("📊 Results")

        stem_wavs: dict[str, Path] = st.session_state.stem_wavs
        midi_map:  dict[str, Path] = st.session_state.midi_map
        pdf_map:   dict[str, Path] = st.session_state.pdf_map
        xml_map:   dict[str, Path] = st.session_state.xml_map
        gp_path:   "Path | None"   = st.session_state.gp_path

        # ── Guitar Pro combined download ──────────────────────────────────────
        if gp_path and gp_path.exists():
            kb = gp_path.stat().st_size // 1024
            st.download_button(
                f"🎸 Download Guitar Pro file  ({kb:,} KB) — all tracks combined",
                data=gp_path.read_bytes(),
                file_name=gp_path.name,
                mime="application/octet-stream",
                type="primary",
                use_container_width=True,
            )
            st.divider()

        all_stems = sorted(set(list(stem_wavs) + list(midi_map)))

        if all_stems:
            tabs = st.tabs([s.capitalize() for s in all_stems])
            for tab, stem_name in zip(tabs, all_stems):
                with tab:
                    _render_stem_card(
                        stem_name=stem_name,
                        wav_path=stem_wavs.get(stem_name),
                        midi_path=midi_map.get(stem_name),
                        pdf_path=pdf_map.get(stem_name),
                        xml_path=xml_map.get(stem_name),
                    )
        else:
            st.warning("No results found. Check the pipeline log below.")

    # ── Log ───────────────────────────────────────────────────────────────────
    log_lines: list[str] = st.session_state.log_lines
    if log_lines:
        with st.expander(f"📋 Pipeline Log ({len(log_lines)} lines)", expanded=False):
            # Colour-code by level
            coloured = []
            for line in log_lines:
                if "[ERROR]" in line:
                    coloured.append(f"🔴 {line}")
                elif "[WARNING]" in line:
                    coloured.append(f"🟡 {line}")
                else:
                    coloured.append(f"   {line}")
            st.code("\n".join(coloured), language=None)


if __name__ == "__main__":
    main()
