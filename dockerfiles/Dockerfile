# Copyright (c) 2026 Red Hat, Inc.
# This program and the accompanying materials are made
# available under the terms of the Eclipse Public License 2.0
# which is available at https://www.eclipse.org/legal/epl-2.0/
#
# SPDX-License-Identifier: EPL-2.0
#
# Contributors:
#   Red Hat, Inc. - initial API and implementation

# Stage 1: Build — download Claude Code + ttyd, collect minimal rootfs
FROM debian:bookworm-slim AS builder

ARG CLAUDE_CODE_VERSION=2.1.81
ARG TTYD_VERSION=1.7.7
ARG TARGETARCH

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      curl ca-certificates procps jq git binutils && \
    rm -rf /var/lib/apt/lists/*

# Download Claude Code native binary
RUN set -e && \
    case "${TARGETARCH}" in \
      amd64) PLATFORM="linux-x64" ;; \
      arm64) PLATFORM="linux-arm64" ;; \
      *) echo "Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
    esac && \
    curl -fsSL -o /usr/local/bin/claude \
      "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/${CLAUDE_CODE_VERSION}/${PLATFORM}/claude" && \
    chmod +x /usr/local/bin/claude

# Download ttyd static binary
RUN set -e && \
    case "${TARGETARCH}" in \
      amd64) TTYD_ARCH="x86_64" ;; \
      arm64) TTYD_ARCH="aarch64" ;; \
      *) echo "Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
    esac && \
    curl -fsSL -o /usr/local/bin/ttyd \
      "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${TTYD_ARCH}" && \
    chmod +x /usr/local/bin/ttyd

# Collect minimal rootfs — only binaries + shared libs needed at runtime
COPY scripts/collect-rootfs.sh /tmp/collect-rootfs.sh
RUN chmod +x /tmp/collect-rootfs.sh && bash /tmp/collect-rootfs.sh

# Stage 2: Minimal image from scratch
FROM scratch

COPY --from=builder /rootfs/ /

# Claude Code config files
COPY skills/CLAUDE.md /opt/claude-skills/CLAUDE.md
COPY settings/settings.json /opt/claude-skills/settings.json
COPY settings/claude.json /opt/claude-skills/claude.json

ENV PATH="/usr/local/bin:/usr/bin:/bin" \
    HOME="/tmp/claude-home" \
    LANG="C.UTF-8" \
    CLAUDE_CODE_SKIP_PERMISSIONS_CONFIRMATION="1"

USER 1001

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=2s --retries=3 \
  CMD curl -sf http://localhost:8080/ || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

LABEL org.opencontainers.image.description="Dashboard Agent: Claude Code with ttyd terminal for Eclipse Che" \
      org.opencontainers.image.source="https://github.com/olexii4/che-dashboard-agent"
