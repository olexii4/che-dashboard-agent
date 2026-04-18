# Repository Review: che-dashboard-agent

Analysis of the repository with improvement and minimization suggestions.

## Current State Summary

The repository produces a ~100-120 MB container image (compressed) that bundles Claude Code (native binary), ttyd (static binary), bash, git, curl, jq, and minimal shared libraries in a FROM-scratch image. The architecture is sound: two-stage build, minimal rootfs assembly, OpenShift-compatible.

## What's Done Well

1. **Scratch base image** — eliminates all unnecessary OS packages, reduces attack surface, minimizes image size
2. **Binary dependency tracking** — `collect-rootfs.sh` uses `ldd` to copy only required shared libraries
3. **OpenShift compatibility** — `$HOME` redirection handles arbitrary UIDs gracefully
4. **Config file separation** — `settings.json`, `claude.json`, `CLAUDE.md` are clearly separated and independently updatable
5. **CI multi-arch support** — GitHub Actions workflow builds for both amd64 and arm64 via QEMU
6. **`--bare` mode** — disables unnecessary Claude Code features (hooks, LSP, plugin sync, auto-memory) for a headless agent

## Improvement Suggestions

### 1. Image Size Reduction

**Current bottleneck:** The Claude Code native binary is the largest component (~80-90 MB). ttyd is ~5 MB. Everything else (bash, git, curl, coreutils, shared libs, SSL certs) is ~15-20 MB.

**Possible optimizations:**
- **Strip binaries:** Add `strip` to the builder stage and strip copied binaries. Saves ~5-10% on ELF binaries (git, bash, curl, coreutils). Does not apply to Claude Code (already stripped) or ttyd (static, already stripped).
  ```bash
  # In collect-rootfs.sh, after copying each binary:
  strip --strip-unneeded "$dst" 2>/dev/null || true
  ```
- **Reduce Git footprint:** The git-core helpers and templates add ~3-5 MB. If the agent only needs `git clone` and basic operations, skip `git-remote-http` (keep only `git-remote-https`) and skip templates.
- **SSL certificate pruning:** The full `/etc/ssl` directory is ~1.5 MB. If the agent only connects to known hosts (Kubernetes API, GitHub), a smaller CA bundle might suffice. However, this reduces flexibility.
- **Consolidate coreutils:** Many coreutils commands share the same binary (via multi-call). On Debian, each is a separate binary. Consider using BusyBox for coreutils instead — a single ~1 MB static binary replaces all of cat, ls, grep, find, mkdir, rm, etc. This would save ~8-10 MB.

### 2. Security Hardening

- **Non-root default:** The image currently runs as root. Add `USER 1001` after the scratch stage. The entrypoint already handles non-root via `$HOME` redirection.
- **Read-only rootfs:** Mark the rootfs as read-only where possible. The entrypoint writes to `/tmp/claude-home` already.
- **Drop capabilities:** If running on Kubernetes, the pod SecurityContext should drop all capabilities. This is a deployment concern (not image), but could be documented.

### 3. Configuration Improvements

- **Externalize CLAUDE.md version:** Currently the system prompt is baked into the image. Changes to the prompt require a new image build. Consider mounting it as a ConfigMap so it can be updated without rebuilding.
- **Claude Code version pinning:** The `CLAUDE_CODE_VERSION=2.1.81` is hardcoded. Add a CI matrix or argument to build with the latest stable version automatically.
- **Settings hot-reload:** `settings.json` and `claude.json` are copied once on first run. If mounted as volumes, the entrypoint should re-copy on each startup (or use symlinks).

### 4. Reliability

- **Health check:** Add a `HEALTHCHECK` instruction to the Dockerfile:
  ```dockerfile
  HEALTHCHECK --interval=30s --timeout=2s --retries=3 \
    CMD curl -sf http://localhost:8080/ || exit 1
  ```
  Note: This requires curl to be on `$PATH` inside the container (it already is).
- **Graceful shutdown:** ttyd handles SIGTERM correctly, but Claude Code processes spawned by ttyd may not. Consider a shutdown wrapper that sends SIGTERM to child processes.
- **Version validation:** The entrypoint could verify that `claude-bin --version` matches expected version on startup.

### 5. Code Quality

- **Remove stale references:** The `.dockerignore` still references `terminal-server/` (the old Node.js terminal server that was replaced by ttyd). The `openspec/` directory is empty.
- **Deduplicate init logic:** The Claude wrapper script and entrypoint script both perform the same config-file-copy logic (mkdir, copy CLAUDE.md, copy settings.json, copy claude.json, copy marketplace files). Extract this into a shared init script.
- **Version file:** Add a `VERSION` file or build-time label with the image version for debugging.

### 6. Developer Experience

- **Local development:** Add a `Makefile` or script for common operations:
  ```makefile
  build:
      podman build -f dockerfiles/Dockerfile -t dashboard-agent:dev .
  run:
      podman run -it --rm -e ANTHROPIC_API_KEY=$(cat ~/.anthropic-key) -p 8080:8080 dashboard-agent:dev
  ```
- **Test script:** A quick smoke test that builds the image and verifies ttyd starts and responds on port 8080.

## Minimization Summary

| Component | Current Size (est.) | Potential Savings | How |
|-----------|-------------------|-------------------|-----|
| Claude Code binary | ~85 MB | 0 | Already optimized by Anthropic |
| ttyd binary | ~5 MB | 0 | Already a static binary |
| Git + helpers | ~8 MB | ~3 MB | Remove git-remote-http, skip templates |
| Coreutils (30+ binaries) | ~10 MB | ~8 MB | Replace with BusyBox multi-call binary |
| curl + jq | ~3 MB | 0 | Needed for API access |
| Shared libs | ~8 MB | ~2 MB | Strip unneeded symbols |
| SSL certs | ~1.5 MB | ~0.5 MB | Prune to essential CAs only |
| **Total** | **~120 MB** | **~13.5 MB** | **~106 MB minimum** |

The Claude Code binary dominates the image size. The realistic floor is ~100-105 MB. The biggest single optimization would be replacing coreutils with BusyBox (~8 MB savings).

## Priority Ranking

1. **High impact, low effort:** Strip binaries, remove `openspec/`, remove `terminal-server/` reference
2. **High impact, medium effort:** BusyBox for coreutils, deduplicate init logic
3. **Medium impact, low effort:** Add `HEALTHCHECK`, add `USER 1001`, add Makefile
4. **Low impact, high effort:** SSL cert pruning, externalize CLAUDE.md as ConfigMap, CI auto-versioning
