# Audio-to-Sheet-Music Pipeline

Headless CLI pipeline: **MP3 → Stems → MIDI → PDF/MusicXML**

```
input.mp3
  │
  ▼  demucs (source separation)
output/stems/htdemucs/{track}/  bass.wav  drums.wav  vocals.wav  other.wav
  │
  ▼  basic-pitch (audio → MIDI)
output/midi/{track}/{stem}/  {stem}_basic_pitch.mid
  │
  ▼  MuseScore 4 (MIDI → notation)
output/sheets/  {track}_{stem}.pdf  {track}_{stem}.musicxml
```


Run with
```
uv run streamlit run app.py
```

---

## 1. System Dependencies

### FFmpeg

| OS | Command |
|---|---|
| Windows | `winget install Gyan.FFmpeg` |
| macOS | `brew install ffmpeg` |
| Linux (Debian/Ubuntu) | `sudo apt install ffmpeg` |

Verify: `ffmpeg -version`

### MuseScore 4

| OS | Command |
|---|---|
| Windows | `winget install Musescore.Musescore` |
| macOS | `brew install --cask musescore` |
| Linux | Download AppImage from [musescore.org](https://musescore.org/en/download), make it executable and add it to `$PATH` as `mscore4` |

Verify: `MuseScore4 --version` (Windows) / `mscore4 --version` (Linux/macOS)

**Linux only — virtual display fallback:**
If your MuseScore version is older than 4.4 (which added `--headless`), install `xvfb`:
```bash
sudo apt install xvfb
```

### uv (Python package manager)

```bash
# Windows (PowerShell)
powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"

# macOS / Linux
curl -LsSf https://astral.sh/uv/install.sh | sh
```

---

## 2. Python Environment

```bash
cd audio-to-gp
uv sync
```

This creates a virtual environment and installs `demucs` and `basic-pitch`.

> **Note:** `demucs` downloads model weights (~300 MB) on first run. An internet connection is required for that first execution.

---

## 3. Run the Pipeline

```bash
uv run python pipeline.py --input path/to/song.mp3
```

All output lands in `./output/` by default:

```
output/
├── pipeline.log          # Full execution log
├── stems/                # Separated WAV files (demucs output)
├── midi/                 # Per-stem MIDI files (basic-pitch output)
└── sheets/               # PDF and MusicXML scores (MuseScore output)
```

### Options

| Flag | Default | Description |
|---|---|---|
| `--input`, `-i` | *(required)* | Path to the input `.mp3` file |
| `--output-dir`, `-o` | `./output` | Root directory for all output |
| `--model` | `htdemucs` | Demucs model (`htdemucs`, `htdemucs_ft`, `mdx_extra`, etc.) |
| `--mscore-path` | *(auto-detected)* | Path to MuseScore binary if not on `$PATH` |
| `--include-drums` | *(off)* | Also convert the drums stem to MIDI/notation (not recommended — basic-pitch is pitch-based) |

### Examples

```bash
# Standard run
uv run python pipeline.py --input my_song.mp3

# Custom output location + fine-tuned model
uv run python pipeline.py --input my_song.mp3 --output-dir ./my_song_out --model htdemucs_ft

# Non-standard MuseScore install path (Windows example)
uv run python pipeline.py --input my_song.mp3 --mscore-path "D:\Apps\MuseScore4\bin\MuseScore4.exe"

# Include drums in notation export
uv run python pipeline.py --input my_song.mp3 --include-drums
```

---

## 4. Notes & Caveats

- **Drums notation:** `basic-pitch` uses pitch detection and is not designed for percussive audio. The drums stem is skipped by default; the `--include-drums` flag overrides this.
- **Processing time:** `demucs` is GPU-accelerated if CUDA is available; otherwise it runs on CPU and can take several minutes for a typical 3–5 minute track.
- **MuseScore on Linux containers/CI:** The `xvfb-run` wrapper handles headless rendering for MuseScore < 4.4. If running in Docker, install `xvfb` in the image or use MuseScore 4.4+ with native `--headless`.

---

## 5. License

All tools used are open source:

| Tool | License |
|---|---|
| [demucs](https://github.com/facebookresearch/demucs) | MIT |
| [basic-pitch](https://github.com/spotify/basic-pitch) | Apache 2.0 |
| [MuseScore](https://github.com/musescore/MuseScore) | GPL v3 |
| [FFmpeg](https://ffmpeg.org/) | LGPL / GPL |
