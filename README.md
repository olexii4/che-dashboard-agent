# che-dashboard-agent

A containerized AI coding assistant for the Eclipse Che Dashboard's Devfile Creator. Runs [Claude Code](https://claude.ai/claude-code) inside a [gritty](https://github.com/cloudcmd/gritty) terminal (xterm.js + node-pty + socket.io), embedded in the dashboard UI via an iframe.

## What it does

When a user creates a devfile in the Che Dashboard, they can start an AI agent that helps author and edit the devfile. The agent runs as a headless DevWorkspace (no IDE editor) and communicates with the dashboard through a reverse-proxied terminal.

## Repository Structure

| Path | Description |
|---|---|
| `Dockerfile` | Multi-stage build: downloads Claude Code binary, installs gritty, produces a UBI10-minimal runtime image |
| `CLAUDE.md` | Agent skill instructions: how to read/write devfiles from the Kubernetes ConfigMap, devfile v2 format reference, best practices |
| `devfile.yaml` | DevWorkspace template: ephemeral workspace with `che.eclipse.org/workspace-type: agent` label, internal WebSocket endpoint on port 8080 |
| `settings.json` | Claude Code configuration (model selection) |
| `claude.json` | Onboarding state: skips the first-run wizard |
| `skills/claude/` | Devfile assistant skill: schema reference, common patterns, recommended images |
| `terminal-server/` | Alternative WebSocket terminal server (node-pty + ws) with output batching and flow control |
| `.cursor/rules/` | Cursor IDE rules for development conventions |

## Architecture

```
Dashboard UI (iframe)
    |
    v  HTTP proxy (same-origin)
Dashboard Backend (devfileCreator.ts)
    |
    v  in-cluster HTTP/socket.io
Gritty (port 8080)
    |
    v  node-pty
Claude Code CLI (/usr/local/bin/claude)
    |
    v  Kubernetes API (service account token)
ConfigMap "devfile-creator-storage"
```

## Build and Push

```bash
podman build -t quay.io/oorel/dashboard-agent:next .
podman push quay.io/oorel/dashboard-agent:next
```

CI builds are triggered on push to `main` via the [Next Build workflow](.github/workflows/next-build-multiarch.yml), producing multi-arch images (amd64 + arm64).

## Runtime Environment

- **Base image**: `registry.access.redhat.com/ubi10/ubi-minimal:10.0`
- **Runtime deps**: bash, Node.js, jq, python3
- **OpenShift compatible**: handles arbitrary UIDs by redirecting `$HOME` to `/tmp/claude-home`
- **Entry point**: starts gritty on port 8080 with bash shell, Claude Code on `$PATH`

## Configuration

| File | Purpose |
|---|---|
| `settings.json` | Claude Code model and environment settings |
| `claude.json` | Onboarding state to skip first-run wizard |
| `CLAUDE.md` | Agent system prompt with devfile knowledge and Kubernetes API access patterns |

The `ANTHROPIC_API_KEY` environment variable must be set in the DevWorkspace (via the `devfile.yaml` or a Kubernetes Secret).

## License

[EPL-2.0](LICENSE)
