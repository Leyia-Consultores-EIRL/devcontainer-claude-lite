FROM fleet-devcontainer-base-node:1.0.0

ARG TZ
ENV TZ="$TZ"

USER root

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
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# pnpm via corepack
ENV COREPACK_ENABLE_AUTO_PIN=0
ENV COREPACK_ENABLE_STRICT=0
RUN corepack enable && corepack prepare pnpm@latest --activate

# Node/npm globals
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
RUN mkdir -p /usr/local/share/npm-global

USER dev

ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/share/npm-global/bin

# Chromium: skip Playwright download, use system binary
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
ENV PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium
ENV CHROME_PATH=/usr/bin/chromium
