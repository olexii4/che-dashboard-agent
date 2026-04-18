# Repository File Reference

Detailed description of every file in the che-dashboard-agent repository and its purpose.

## Core Files

### `CLAUDE.md`

The agent's system prompt. This file is copied into the container at `/opt/claude-skills/CLAUDE.md` and loaded via the `--append-system-prompt-file` flag when Claude Code starts. It contains:

- **Kubernetes ConfigMap access patterns** — how the agent reads and writes devfiles stored in the `devfile-creator-storage` ConfigMap using both direct Kubernetes API (`curl` + bearer token) and the Dashboard REST API
- **Environment variables** — `AGENT_NAMESPACE`, `KUBERNETES_API_URL`, `CHE_USER_TOKEN_FILE` that are injected into the agent pod by the dashboard backend
- **Devfile v2 format reference** — complete schema documentation for `schemaVersion: 2.2.2` and `2.3.0`, covering metadata, components (container, volume, kubernetes), commands (exec, apply, composite), projects, and events
- **12 critical rules** — constraints the agent must follow when generating devfiles (e.g., never add postStart events, use UBI images, set mountSources, use `${PROJECT_SOURCE}`)
- **7 real-world examples** — Node.js monorepo, CLI tool, VS Code extension, OpenWRT multi-container, Go, Python, Java/Spring Boot

This file is the single most important piece of the agent's behavior. Changes here directly affect what the AI generates.

### `LICENSE`

Eclipse Public License v2.0 (EPL-2.0). Required for all Eclipse Foundation projects.

## `dockerfiles/`

### `dockerfiles/Dockerfile`

Multi-stage Docker build that produces a minimal container image:

**Stage 1 (builder)** — Debian bookworm-slim base:
- Downloads the Claude Code native binary (version controlled via `CLAUDE_CODE_VERSION` build arg)
- Downloads the ttyd static binary (version controlled via `TTYD_VERSION` build arg)
- Handles multi-arch builds via `TARGETARCH` (amd64 → linux-x64, arm64 → linux-arm64)
- Runs `scripts/collect-rootfs.sh` to assemble a minimal filesystem

**Stage 2** — FROM scratch (empty base):
- Copies the assembled rootfs from stage 1
- Copies `CLAUDE.md`, `settings/claude/settings.json`, and `settings/claude/claude.json` into `/opt/claude-skills/`
- Sets `PATH`, `HOME`, `LANG`, and `CLAUDE_CODE_SKIP_PERMISSIONS_CONFIRMATION`
- Exposes port 8080 for ttyd
- Entrypoint: `/usr/local/bin/entrypoint.sh`

The scratch base ensures the image contains only what's explicitly included — no package manager, no extra utilities, no attack surface.

## `scripts/`

### `scripts/collect-rootfs.sh`

Shell script that runs during the Docker build (stage 1) to assemble the minimal rootfs. This is the most complex file in the repo.

**What it does:**
1. Creates the directory skeleton (`/bin`, `/usr/bin`, `/etc/ssl`, `/tmp`, etc.)
2. Copies each required binary and its shared library dependencies (via `ldd`)
3. Copies Git helper executables (`git-remote-https`, etc.) and templates
4. Copies NSS libraries for DNS resolution
5. Copies SSL certificates
6. Creates minimal `/etc/passwd`, `/etc/group`, `/etc/nsswitch.conf`
7. Creates the **Claude wrapper script** at `/usr/local/bin/claude` — handles `$HOME` redirection for OpenShift (arbitrary UIDs), copies config files on first run, pre-populates marketplace state to prevent startup warnings
8. Creates the **entrypoint script** at `/usr/local/bin/entrypoint.sh` — sets up the environment and starts `ttyd -p 8080 -W bash`

**Binaries included:** ttyd, claude-bin, bash, cat, ls, grep, find, mkdir, rm, cp, mv, ln, chmod, chown, touch, pwd, echo, env, dirname, basename, head, tail, wc, sort, tr, sed, cut, tee, xargs, id, whoami, uname, readlink, curl, jq, git, ps, kill.

## `settings/claude/`

### `settings/claude/settings.json`

Claude Code runtime configuration. Copied to `~/.claude/settings.json` on first run.

| Key | Value | Purpose |
|-----|-------|---------|
| `model` | `claude-opus-4-6` | Selects the Claude model |
| `hasCompletedOnboarding` | `true` | Skips the first-run setup wizard |
| `skipDangerousModePermissionPrompt` | `true` | Suppresses the dangerous-mode confirmation prompt |

### `settings/claude/claude.json`

Claude Code onboarding state. Copied to `~/.claude.json` on first run.

Pre-configures the onboarding as complete so the agent starts immediately without interactive prompts. Also sets up a project-level trust configuration for the root directory (`/`) so Claude Code doesn't show workspace trust dialogs.

## `templates/`

### `templates/devfile.yaml`

DevWorkspace template for the agent pod. Not used by the Docker image — this is a reference for deploying the agent as a DevWorkspace (the dashboard backend creates agent pods directly instead).

Key fields:
- `che.eclipse.org/workspace-type: agent` — labels the workspace so the dashboard UI can distinguish agents from user workspaces
- `controller.devfile.io/storage-type: ephemeral` — no persistent volumes
- `mountSources: false` — agent doesn't need project sources
- `ANTHROPIC_API_KEY` — must be set at runtime

## `skills/claude/`

### `skills/claude/CLAUDE.md`

A simplified version of the main `CLAUDE.md`, focused on devfile generation patterns. Contains:
- Schema reference (2.2.2)
- Common patterns (Node.js, DB sidecar, microservices)
- Recommended container images table

This is a skill definition for Claude Code's skill system. It's not currently used in the container image but serves as reference material.

## `docs/`

### `docs/repo-files.md`

This file. Detailed description of every file in the repository.

### `docs/repo-review.md`

Analysis of the repository with improvement and minimization suggestions.

## `.github/workflows/`

### `.github/workflows/next-build-multiarch.yml`

GitHub Actions workflow for CI/CD:
- **Triggers:** Manual dispatch or push to `main`
- **Target:** `quay.io/oorel/dashboard-agent:next`
- **Platforms:** linux/amd64, linux/arm64 (via QEMU + Docker Buildx)
- **Secrets:** `QUAY_USERNAME`, `QUAY_PASSWORD` for registry authentication

## `.cursor/rules/`

### `.cursor/rules/che-dashboard-agent-dev.mdc`

Development conventions for the Cursor IDE:
- Commit message format and mandatory trailers
- Pre-push validation checklist
- Image build commands
- Analysis document naming conventions

### `.cursor/rules/redhat-compliance-and-responsible-ai.mdc`

Red Hat compliance rules:
- Copyright and licensing requirements (EPL-2.0 compatibility)
- AI contribution marking (`// Generated by {AGENT_NAME}`, `Assisted-by:` trailers)

## Root Config Files

### `.dockerignore`

Excludes non-essential files from the Docker build context: `.git`, `.github`, `.idea`, `.cursor`, all `.md` files except `CLAUDE.md`, `LICENSE`, `docs/`, `templates/`, `openspec/`, `skills/`, `terminal-server/`.
