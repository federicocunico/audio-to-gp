# Audio to Guitar Pro

Convert any MP3 into a Guitar Pro 5 (.gp5) file using AI source separation (demucs) and automatic MIDI transcription (basic-pitch).

## How it works

1. **Source separation** — demucs splits the MP3 into stems (bass, drums, guitar, other, vocals, piano)
2. **MIDI transcription** — basic-pitch converts each WAV stem to a MIDI file
3. **GP5 export** — all stems are assembled into a single Guitar Pro 5 file, one track per stem

Two models are available:
- `htdemucs_ft` — 4 stems (bass, drums, other, vocals)
- `htdemucs_6s` — 6 stems (bass, drums, guitar, other, piano, vocals)

All Python dependencies (torch, demucs, basic-pitch, onnxruntime) are downloaded automatically on first launch. No manual Python setup is needed.

## Download

Pre-built binaries are available on the [Releases](../../releases) page:

| Platform | File |
|----------|------|
| macOS (Apple Silicon + Intel) | `audio-to-gp-macos-vX.Y.Z.zip` |
| Windows 10/11 (x64) | `audio-to-gp-windows-vX.Y.Z.zip` |

### macOS

1. Download and unzip `audio-to-gp-macos-vX.Y.Z.zip`
2. Move `audio to gp flutter.app` to `/Applications`
3. On first launch, macOS will warn about an unidentified developer — right-click the app and choose **Open**, then click **Open** in the dialog
4. The app will download Python dependencies on first launch (~3 GB); this takes 10–20 minutes

### Windows

1. Download and unzip `audio-to-gp-windows-vX.Y.Z.zip`
2. Run `audio_to_gp_flutter.exe`
3. On first launch, Windows Defender SmartScreen may warn about an unknown publisher — click **More info → Run anyway**
4. The app will download Python dependencies on first launch (~3 GB); this takes 10–20 minutes

## System requirements

| | macOS | Windows |
|---|---|---|
| OS | 10.15 Catalina or later | Windows 10 or later |
| Architecture | Apple Silicon (arm64) or Intel (x86_64) | x64 |
| RAM | 8 GB minimum, 16 GB recommended | 8 GB minimum, 16 GB recommended |
| Disk | ~5 GB free (Python + models) | ~5 GB free (Python + models) |
| GPU | Optional — CPU works, GPU speeds up demucs | Optional — NVIDIA CUDA GPU speeds up demucs |

## Building from source

### Prerequisites

- [Flutter](https://docs.flutter.dev/get-started/install) stable channel
- macOS: Xcode 14+ with command line tools (`xcode-select --install`)
- Windows: Visual Studio 2022 with "Desktop development with C++" workload

### Steps

```bash
git clone https://github.com/<owner>/audio-to-gp
cd audio-to-gp
flutter pub get
flutter build macos --release   # or: flutter build windows --release
```

The built app is in `build/macos/Build/Products/Release/` (macOS) or `build\windows\x64\runner\Release\` (Windows).

## Running tests

### Unit and integration tests (no GPU needed)

```bash
flutter test test/unit/
```

### End-to-end pipeline tests

Requires tools to be installed (run the app once to trigger setup, or set env vars pointing to an existing install):

```bash
# Copy the test fixture
cp coronaria-che-esplode.mp3 test/fixtures/

# Point to installed tools
TOOLS="$HOME/Library/Application Support/com.example.audioToGpFlutter/audio-to-gp/tools"  # macOS
export AUDIO_TO_GP_TOOLS_DIR="$TOOLS"
export PYTHON_EXE="$TOOLS/.venv/bin/python3"
export UV_EXE="$TOOLS/uv/uv"
export FFMPEG_EXE="/opt/homebrew/bin/ffmpeg"   # or wherever ffmpeg is

flutter test test/integration/pipeline_e2e_test.dart --timeout=none
```

> Each model run takes 5–20 minutes on CPU, ~2–5 minutes on a GPU.

## License

MIT
