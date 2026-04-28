# che-dashboard-agent

A containerized AI coding assistant for the Eclipse Che Dashboard's Devfile Creator. Runs [Claude Code](https://claude.ai/claude-code) inside a [ttyd](https://github.com/tsl0922/ttyd) web terminal (xterm.js + WebSocket), embedded in the dashboard UI via an iframe.

## What it does

When a user creates a devfile in the Che Dashboard, they can start an AI agent that helps author and edit the devfile. The dashboard backend creates a dedicated Pod + ClusterIP Service for the agent (not a DevWorkspace). The agent communicates with the dashboard through a web terminal proxied over WebSocket.

The agent can also assist with troubleshooting DevWorkspace startup failures — diagnosing pod events, container logs, and patching DevWorkspace specs via the Kubernetes API.

## Repository Structure

| Path | Description |
|---|---|
| `dockerfiles/Dockerfile` | Multi-stage build: downloads Claude Code binary + ttyd + kubectl, produces a minimal scratch image |
| `scripts/collect-rootfs.sh` | Collects minimal rootfs for the scratch image (binaries, shared libs, glibc compat stubs, wrapper scripts) |
| `settings/settings.json` | Claude Code configuration (model selection) |
| `settings/claude.json` | Onboarding state: skips first-run wizard and startup tips |
| `skills/CLAUDE.md` | Agent system prompt: devfile format reference, Kubernetes API access, container args rules, image selection, troubleshooting |
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
make build TAG=next
make push TAG=next

# Or directly
podman build -f dockerfiles/Dockerfile -t quay.io/oorel/dashboard-agent:next .
podman push quay.io/oorel/dashboard-agent:next
```

CI builds are triggered on push to `main` via the [Next Build workflow](.github/workflows/next-build-multiarch.yml), producing multi-arch images (amd64 + arm64).

## Runtime Environment

- **Base image**: `scratch` (minimal — only binaries and shared libraries)
- **Terminal server**: [ttyd](https://github.com/tsl0922/ttyd) v1.7.7 (single static binary, ~5 MB)
- **Claude Code**: v2.1.119 (Bun standalone binary — must not be stripped)
- **kubectl**: latest stable (for Kubernetes API access)
- **Runtime deps**: bash, curl, git, jq, coreutils, procps (no Node.js, no Python)
- **glibc compat**: librt, libpthread, libdl, libm, libutil stubs (required by Bun runtime on glibc 2.34+)
- **User**: runs as UID 1001 (non-root)
- **OpenShift compatible**: handles arbitrary UIDs by redirecting `$HOME` to `/tmp/claude-home`
- **Entry point**: starts ttyd on port 8080 with bash shell, Claude Code on `$PATH`
- **Health check**: built-in Docker HEALTHCHECK on port 8080
- **Shell**: bash at `/bin/bash`, `/usr/bin/bash`, and `/bin/sh`

### Tools available inside the container

`cat`, `ls`, `grep`, `find`, `mkdir`, `rm`, `cp`, `mv`, `ln`, `chmod`, `chown`, `touch`, `pwd`, `echo`, `env`, `dirname`, `basename`, `head`, `tail`, `wc`, `sort`, `tr`, `sed`, `cut`, `tee`, `xargs`, `id`, `whoami`, `uname`, `readlink`, `curl`, `jq`, `git`, `ps`, `kill`, `kubectl`.

**Not available**: `python3`, `python`, `gh`, `wget`, `apt`, `yum`, `pip`, `npm`, `node`, `awk`, `perl`.

## Configuration

| File | Purpose |
|---|---|
| `settings/settings.json` | Claude Code model and environment settings |
| `settings/claude.json` | Onboarding state — skips first-run wizard and suppresses startup tips |
| `skills/CLAUDE.md` | Agent system prompt with devfile knowledge, container args rules, image selection logic, and Kubernetes API access patterns |

The `ANTHROPIC_API_KEY` environment variable must be available to the agent container (via a Kubernetes Secret labeled for DevWorkspace mounting, or the `env` array in the `ai-agent-registry` ConfigMap).

## Agent Skills (CLAUDE.md)

The agent system prompt includes:

- **Devfile format reference** — schema versions, components, commands, projects, endpoints, volumes
- **Container `args` rule** — every non-UDI container must have `args: [tail, '-f', /dev/null]` to prevent `CrashLoopBackOff`
- **Image selection logic** — use specific runtime images (Node, Python, Go, etc.) when user asks for a stack; default to UDI only when no stack is specified
- **Kubernetes API access** — direct ConfigMap CRUD via curl + user token, and dashboard REST API
- **DevWorkspace troubleshooting** — diagnosis workflow, common failure patterns, patching and restarting workspaces
- **Blocked commands** — `python3`, `python`, `gh` are not available; use `jq` for JSON manipulation
- **Shell environment** — documents available tools and bash location

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
          "id": "dashboard-agent",
          "name": "Dashboard Agent",
          "publisher": "Eclipse Che",
          "description": "AI agent powered by Claude Code for building and troubleshooting devfiles and DevWorkspaces",
          "icon": "",
          "docsUrl": "https://github.com/olexii4/che-dashboard-agent",
          "image": "quay.io/oorel/dashboard-agent",
          "tag": "next",
          "memoryLimit": "896Mi",
          "cpuLimit": "1",
          "terminalPort": 8080,
          "env": [],
          "initCommand": "claude --dangerously-skip-permissions --append-system-prompt \"CRITICAL RULES: 1) EVERY non-UDI container MUST have args: [tail, -f, /dev/null]. 2) NEVER use python3, awk, perl, node — use jq, sed, cut, curl.\""
        }
      ],
      "defaultAgentId": "dashboard-agent"
    }
EOF
```

### Pod Security Context

The dashboard backend automatically applies a hardened security context to agent pods:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1001
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  capabilities:
    drop: [ALL]
  seccompProfile:
    type: RuntimeDefault
```

The image writes only to `/tmp/claude-home` — this is handled via `emptyDir` volumes.

### 2. Set the API key

The `ANTHROPIC_API_KEY` must be available to the agent container. Create a Kubernetes Secret with the DevWorkspace mount annotation in the user namespace:

```bash
kubectl create secret generic anthropic-api-key \
  --from-literal=ANTHROPIC_API_KEY=sk-ant-... \
  -n <user-namespace>

kubectl annotate secret anthropic-api-key \
  controller.devfile.io/mount-as=env \
  -n <user-namespace>
```

The dashboard backend automatically discovers secrets with `controller.devfile.io/mount-as` annotations and mounts them into agent pods.

### 3. Agent Lifecycle

- **Heartbeat**: The dashboard sends heartbeat pings every 60 seconds. After 6 consecutive failures, the agent is stopped.
- **TTL cleanup**: Agent pods without a heartbeat for 20 minutes are automatically cleaned up by the backend.
- **Navigation cleanup**: The agent pod is stopped when the user navigates away from the Devfile Details page.
- **Max pods per user**: Limited to 3 concurrent agent pods per namespace.

## License

[EPL-2.0](LICENSE)
