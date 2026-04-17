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

## Patching Eclipse Che with the Dashboard Agent

The dashboard agent requires a patched [che-dashboard](https://github.com/eclipse-che/che-dashboard) that includes the Devfile Creator feature (branch `devfile_creator`). Both the dashboard and the agent DevWorkspace template must be deployed to the cluster.

### 1. Build and push images

```bash
# Dashboard agent
podman build -t quay.io/oorel/dashboard-agent:latest .
podman push quay.io/oorel/dashboard-agent:latest

# Patched che-dashboard (from the che-dashboard repo, branch devfile_creator)
cd /path/to/che-dashboard
podman build -f build/dockerfiles/Dockerfile -t quay.io/oorel/che-dashboard:devfile-creator .
podman push quay.io/oorel/che-dashboard:devfile-creator
```

### 2. Patch the CheCluster to use the custom dashboard image

```bash
kubectl patch -n eclipse-che checluster/eclipse-che --type=json \
  -p='[{"op":"replace","path":"/spec/components/dashboard/deployment","value":{"containers":[{"image":"quay.io/oorel/che-dashboard:devfile-creator","name":"che-dashboard"}]}}]'

oc rollout status deployment/che-dashboard -n eclipse-che --timeout=120s
```

Or update the deployment directly:

```bash
oc set image deployment/che-dashboard -n eclipse-che \
  che-dashboard=quay.io/oorel/che-dashboard:devfile-creator

oc rollout status deployment/che-dashboard -n eclipse-che --timeout=120s
```

### 3. Create the AI Agent Registry ConfigMap

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
          "tag": "v19",
          "memoryLimit": "2Gi",
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

To add more agents (e.g. Gemini CLI), append entries to the `agents` array in `registry.json`. Each agent needs its own container image with a gritty terminal server on the specified `terminalPort`.

To remove all AI agent features from the dashboard, delete the ConfigMap:

```bash
kubectl delete configmap ai-agent-registry -n eclipse-che
```

### 4. Set the API key

The `ANTHROPIC_API_KEY` must be available to the agent container. You can provide it via a Kubernetes Secret mounted into the user namespace, or add it directly to the agent's `env` array in the ConfigMap (not recommended for production).

### 5. Verify

Open the Che Dashboard, navigate to **Devfiles**, create or open a devfile, and click **Start Agent**. The dashboard reads the ConfigMap at startup and shows the agent panel only when agents are registered. The agent terminal should appear in the right panel with Claude Code ready to assist.

## License

[EPL-2.0](LICENSE)
