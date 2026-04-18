# che-dashboard-agent

A containerized AI coding assistant for the Eclipse Che Dashboard's Devfile Creator. Runs [Claude Code](https://claude.ai/claude-code) inside a [ttyd](https://github.com/tsl0922/ttyd) web terminal (xterm.js + WebSocket), embedded in the dashboard UI via an iframe.

## What it does

When a user creates a devfile in the Che Dashboard, they can start an AI agent that helps author and edit the devfile. The dashboard backend creates a dedicated Pod + ClusterIP Service for the agent (not a DevWorkspace) with a heartbeat-based TTL (20 min). The agent communicates with the dashboard through a web terminal proxied over WebSocket.

## Repository Structure

| Path | Description |
|---|---|
| `dockerfiles/Dockerfile` | Multi-stage build: downloads Claude Code binary + ttyd, produces a minimal scratch image |
| `scripts/collect-rootfs.sh` | Collects minimal rootfs for the scratch image (binaries, shared libs, wrapper scripts) |
| `settings/settings.json` | Claude Code configuration (model selection) |
| `settings/claude.json` | Onboarding state: skips the first-run wizard |
| `skills/CLAUDE.md` | Agent system prompt: devfile format reference, Kubernetes API access, best practices |
| `devfile.yaml` | Reference devfile for standalone testing (not used by the dashboard backend) |
| `Makefile` | Build, push, run, and smoke-test targets |

## Architecture

```
Dashboard UI (iframe)
    |
    v  HTTP proxy (in-cluster)
Dashboard Backend (agents.ts)
    |
    v  in-cluster WebSocket
ttyd (port 8080)
    |
    v  PTY
Claude Code CLI (/usr/local/bin/claude)
    |
    v  Kubernetes API (user token)
ConfigMap "devfile-creator-storage"
```

## Build and Push

```bash
# Using make
make build TAG=v22
make push TAG=v22

# Or directly
podman build -f dockerfiles/Dockerfile -t quay.io/oorel/dashboard-agent:next .
podman push quay.io/oorel/dashboard-agent:next
```

CI builds are triggered on push to `main` via the [Next Build workflow](.github/workflows/next-build-multiarch.yml), producing multi-arch images (amd64 + arm64).

## Runtime Environment

- **Base image**: `scratch` (minimal — only binaries and shared libraries)
- **Terminal server**: [ttyd](https://github.com/tsl0922/ttyd) v1.7.7 (single static binary, ~5 MB)
- **Runtime deps**: bash, curl, git, jq (no Node.js required)
- **User**: runs as UID 1001 (non-root)
- **OpenShift compatible**: handles arbitrary UIDs by redirecting `$HOME` to `/tmp/claude-home`
- **Entry point**: starts ttyd on port 8080 with bash shell, Claude Code on `$PATH`
- **Health check**: built-in Docker HEALTHCHECK on port 8080

## Configuration

| File | Purpose |
|---|---|
| `settings/settings.json` | Claude Code model and environment settings |
| `settings/claude.json` | Onboarding state to skip first-run wizard |
| `skills/CLAUDE.md` | Agent system prompt with devfile knowledge and Kubernetes API access patterns |

The `ANTHROPIC_API_KEY` environment variable must be available to the agent container (via a Kubernetes Secret labeled for DevWorkspace mounting, or the `env` array in the `ai-agent-registry` ConfigMap).

## Patching Eclipse Che with the Dashboard Agent

### 1. Create the AI Agent Registry ConfigMap

The dashboard reads agent definitions from a ConfigMap in the Che namespace. Without this ConfigMap, the agent UI is hidden entirely.

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: ai-agent-registry
  namespace: eclipse-che
  labels:
    app.kubernetes.io/component: ai-agent-registry
    app.kubernetes.io/part-of: che.eclipse.org
data:
  registry.json: |
    {
      "agents": [
        {
          "id": "anthropic/claude-code",
          "name": "Claude Code",
          "publisher": "Anthropic",
          "description": "AI coding assistant with terminal — autonomous coding, debugging, and devfile generation.",
          "icon": "https://cdn.jsdelivr.net/npm/@lobehub/icons-static-svg@latest/icons/claudecode-color.svg",
          "docsUrl": "https://docs.anthropic.com/claude-code",
          "image": "quay.io/oorel/dashboard-agent",
          "tag": "next",
          "memoryLimit": "256Mi",
          "cpuLimit": "1",
          "terminalPort": 8080,
          "env": [
            { "name": "CLAUDE_CODE_SKIP_PERMISSIONS_CONFIRMATION", "value": "1" }
          ],
          "initCommand": "claude --bare --dangerously-skip-permissions --append-system-prompt-file \"$HOME/CLAUDE.md\""
        }
      ],
      "defaultAgentId": "anthropic/claude-code"
    }
EOF
```

### Pod Security Context (recommended)

For production deployments, configure the agent pod to drop all capabilities:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1001
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  capabilities:
    drop: [ALL]
```

The image writes only to `/tmp/claude-home` — mount it as `emptyDir` if using a read-only root filesystem.

### 2. Set the API key

The `ANTHROPIC_API_KEY` must be available to the agent container. You can provide it via a Kubernetes Secret mounted into the user namespace, or add it directly to the agent's `env` array in the ConfigMap (not recommended for production).

### 3. Verify

Open the Che Dashboard, navigate to **Devfiles**, create or open a devfile, and click **Start Agent**. The dashboard reads the ConfigMap at startup and shows the agent panel only when agents are registered. The agent terminal should appear in the right panel with Claude Code ready to assist.

## License

[EPL-2.0](LICENSE)
