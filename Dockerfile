# Audio-to-Sheet-Music Pipeline — Docker image
# Python 3.11 + FFmpeg + MuseScore 4.6.5 (AppImage, extracted) + uv deps
#
# Build:  docker compose build
# Run UI: docker compose up
# Run CLI: docker compose run --rm pipeline python pipeline.py --input /data/song.mp3
#
# NOTE: First pipeline run downloads ~300 MB of demucs model weights into the
#       model-cache volume.  Subsequent runs are fully offline.

FROM python:3.11-slim

# ── Environment ──────────────────────────────────────────────────────────────
ENV DEBIAN_FRONTEND=noninteractive \
    # Force UTF-8 I/O everywhere (prevents UnicodeEncodeError on emoji output)
    PYTHONUTF8=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    # Qt platform: offscreen — MuseScore 4.4+ --headless doesn't need a display
    # but Qt still tries to load a platform plugin; offscreen is the right choice.
    QT_QPA_PLATFORM=offscreen \
    # Silence Qt audio warnings in headless mode
    QT_LOGGING_RULES="*.debug=false;qt.qpa.*=false" \
    # Demucs / Torch model cache — mapped to a named volume so weights persist
    TORCH_HOME=/app/.cache/torch \
    XDG_CACHE_HOME=/app/.cache \
    # uv installs itself here; we add it to PATH
    PATH="/root/.local/bin:${PATH}"

# ── System packages ──────────────────────────────────────────────────────────
# FFmpeg      — audio decoding for demucs
# curl        — used by this Dockerfile to download binaries
# Qt6 runtime — required by MuseScore 4 even in --headless mode
# xvfb        — fallback virtual display for MuseScore <4.4
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        ffmpeg \
        # Qt6 / MuseScore runtime dependencies
        libglib2.0-0 \
        libnss3 \
        libnspr4 \
        libdbus-1-3 \
        libatk1.0-0 \
        libatk-bridge2.0-0 \
        libcups2 \
        libdrm2 \
        libxkbcommon0 \
        libxcomposite1 \
        libxdamage1 \
        libxfixes3 \
        libxrandr2 \
        libgbm1 \
        libasound2 \
        libgl1 \
        libegl1 \
        libopengl0 \
        libfontconfig1 \
        libfreetype6 \
        # Virtual display fallback (for MuseScore < 4.4)
        xvfb \
        xauth \
    && rm -rf /var/lib/apt/lists/*

# ── MuseScore 4.6.5 (AppImage, extracted — no FUSE required in Docker) ───────
ARG MSCORE_BUILD=4.6.5.253511702
ARG MSCORE_TAG=v4.6.5
ARG MSCORE_URL="https://github.com/musescore/MuseScore/releases/download/${MSCORE_TAG}/MuseScore-Studio-${MSCORE_BUILD}-x86_64.AppImage"

RUN echo "Downloading MuseScore ${MSCORE_BUILD}…" \
    && curl -fsSL "${MSCORE_URL}" -o /tmp/mscore.AppImage \
    # Extract AppImage without FUSE (--appimage-extract writes to ./squashfs-root)
    && chmod +x /tmp/mscore.AppImage \
    && cd /tmp && ./mscore.AppImage --appimage-extract \
    && mv /tmp/squashfs-root /opt/musescore \
    && rm  /tmp/mscore.AppImage \
    # Wrapper: AppRun sets APPDIR/LD_LIBRARY_PATH from its own location via readlink -f
    && printf '#!/bin/sh\nexec /opt/musescore/AppRun "$@"\n' \
         > /usr/local/bin/mscore4 \
    && chmod +x /usr/local/bin/mscore4 \
    # Smoke-test: binary must respond (exit codes vary; just check it runs)
    && mscore4 --version 2>&1 | grep -i 'musescore\|mscore\|4\.' \
    && echo "MuseScore OK"

# ── uv ───────────────────────────────────────────────────────────────────────
RUN curl -fsSL https://astral.sh/uv/install.sh | sh \
    && uv --version

# ── Python dependencies ──────────────────────────────────────────────────────
WORKDIR /app

# Copy dependency manifests first so this layer is cached when only code changes
COPY pyproject.toml uv.lock .python-version ./

# Install exactly what's in uv.lock; platform markers in the lock handle Linux/Windows differences.
RUN uv sync --frozen --no-dev

# Print resolved torch builds so Docker logs show whether +cu121 wheels were installed.
RUN uv run python - << 'EOF'
import torch, torchaudio
print(f"torch={torch.__version__}")
print(f"torchaudio={torchaudio.__version__}")
print(f"cuda_available={torch.cuda.is_available()}")
print(f"torch_cuda={torch.version.cuda}")
EOF

# ── Application code ─────────────────────────────────────────────────────────
COPY pipeline.py app.py ./

# ── Build-time preflight: fail fast if any tool is missing ───────────────────
RUN uv run python - << 'EOF'
import sys
from pipeline import preflight_check
try:
    tools = preflight_check(mscore_path=None, skip_musescore=False)
    for name, path in tools.items():
        print(f"  ✓ {name:<12} {path}")
    print("Preflight PASSED")
except RuntimeError as e:
    print(f"Preflight FAILED:\n{e}", file=sys.stderr)
    sys.exit(1)
EOF

# ── Runtime ───────────────────────────────────────────────────────────────────
VOLUME ["/app/output", "/app/.cache"]
EXPOSE 8501

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=5 \
    CMD curl -sf http://localhost:8501/_stcore/health || exit 1

# Default: Streamlit UI
# Override with: docker compose run --rm pipeline python pipeline.py ...
CMD ["uv", "run", "streamlit", "run", "app.py", \
     "--server.address", "0.0.0.0", \
     "--server.port", "8501", \
     "--server.headless", "true"]
