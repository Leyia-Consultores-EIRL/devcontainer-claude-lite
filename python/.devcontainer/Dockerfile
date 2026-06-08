FROM fleet-devcontainer-base-python:1.0.0

ARG TZ
ENV TZ="$TZ"

# Chromium + Playwright deps for Chrome DevTools MCP
# (browser automation, screenshots, accessibility snapshots)
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
  sqlite3 \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Python: no virtualenv needed in container, install direct
ENV PIP_BREAK_SYSTEM_PACKAGES=1
ENV UV_SYSTEM_PYTHON=1
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/dev/.local/bin

# Chromium: skip Playwright download, use system binary
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
ENV PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium
ENV CHROME_PATH=/usr/bin/chromium
