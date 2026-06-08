FROM fleet-devcontainer-base-python:1.0.0

ARG TZ
ENV TZ="$TZ"

USER root

# Chromium + Playwright deps + native build deps for crates
# (browser automation, screenshots; cpal, ALSA, Pillow, ring compilations)
RUN apt-get update && apt-get install -y --no-install-recommends \
  chromium \
  libnss3 \
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
  libpango-1.0-0 \
  libcairo2 \
  libasound2 \
  libatspi2.0-0 \
  libxshmfence1 \
  fonts-liberation \
  pkg-config \
  libssl-dev \
  libasound2-dev \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# OPTIONAL: audio processing libs (ffmpeg, libsndfile1, libsox-fmt-all).
# Adds ~85 MB to the image. Uncomment the RUN block below if your project
# uses pydub / soundfile / symphonia / sox. The first consumer
# (audio-a-texto) needs them; generic Python+Rust projects don't.
#
# USER root
# RUN apt-get update && apt-get install -y --no-install-recommends \
#   ffmpeg \
#   libsndfile1 \
#   libsox-fmt-all \
#   && apt-get clean && rm -rf /var/lib/apt/lists/*
# USER dev

USER dev

# Rust toolchain (rustup + stable)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable && \
  . "$HOME/.cargo/env" && \
  rustup component add clippy rustfmt rust-analyzer

# Python: no virtualenv needed in container
ENV PIP_BREAK_SYSTEM_PACKAGES=1
ENV UV_SYSTEM_PYTHON=1
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/dev/.cargo/bin:/home/dev/.local/bin

# Chromium
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
ENV PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium
ENV CHROME_PATH=/usr/bin/chromium

# Python env
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1

# Persistent caches for HuggingFace / Torch models (mounted as named volumes)
ENV HF_HOME=/home/dev/.cache/huggingface
ENV TORCH_HOME=/home/dev/.cache/torch
