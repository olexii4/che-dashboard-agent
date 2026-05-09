---
name: workspace-troubleshooting
description: "Diagnose and fix DevWorkspace startup failures in Eclipse Che. Use when a workspace fails to start, is stuck in Starting state, shows CrashLoopBackOff, ImagePullBackOff, OOMKilled, PVC issues, FailedScheduling, or any DevWorkspace condition failure."
---

# Workspace Troubleshooting

Diagnose and fix DevWorkspace startup failures using the Kubernetes API. Always read status first,
check pod events and logs, then propose a targeted fix with explicit user confirmation before applying
any patch or restart.

## Your Environment

When running inside an agent pod, the following environment variables are available:
- `AGENT_NAMESPACE` — the Kubernetes namespace you are running in (this is the user's namespace)
- `KUBERNETES_API_URL` — the Kubernetes API server URL (e.g., `https://api.crc.testing:6443`)
- `CHE_USER_TOKEN_FILE` — path to the file containing the user's authentication token (default: `/var/run/secrets/che/token/token`)

## ⚠️ MANDATORY — Validate API Responses Before Using `jq`

**ALWAYS store the `curl` response in a variable and validate it before piping to `jq`.** The K8s API may return HTML error pages, empty responses, or unexpected JSON structures that cause `jq` to fail with errors like `Cannot index string with string "phase"`.

```bash
# CORRECT — validate first
RESP=$(curl -sSk -H "Authorization: Bearer ${TOKEN}" "${K8S_API}/...")
if echo "$RESP" | jq -e '.kind' > /dev/null 2>&1; then
  echo "$RESP" | jq '.status.phase'
else
  echo "ERROR: unexpected API response:" >&2
  echo "$RESP" | head -5 >&2
fi

# WRONG — never do this
curl -sSk -H "Authorization: Bearer ${TOKEN}" "${K8S_API}/..." | jq '.status.phase'
```

## Diagnosis Workflow

1. **Get the DevWorkspace status and conditions:**
```bash
TOKEN="$(cat ${CHE_USER_TOKEN_FILE})"
K8S_API="${KUBERNETES_API_URL}"
NS="${AGENT_NAMESPACE}"
DW_NAME="<workspace-name>"

RESP=$(curl -sSk -H "Authorization: Bearer ${TOKEN}" \
  "${K8S_API}/apis/workspace.devfile.io/v1alpha2/namespaces/${NS}/devworkspaces/${DW_NAME}")
if echo "$RESP" | jq -e '.kind' > /dev/null 2>&1; then
  echo "$RESP" | jq '{phase: .status.phase, message: .status.message, conditions: .status.conditions}'
else
  echo "ERROR: unexpected response" >&2
  echo "$RESP" | head -5 >&2
fi
```

2. **Check pod status and events:**
```bash
# Find workspace pods
RESP=$(curl -sSk -H "Authorization: Bearer ${TOKEN}" \
  "${K8S_API}/api/v1/namespaces/${NS}/pods?labelSelector=controller.devfile.io/devworkspace_name=${DW_NAME}")
echo "$RESP" | jq -e '.kind' > /dev/null 2>&1 && \
  echo "$RESP" | jq '.items[] | {name: .metadata.name, phase: .status.phase, containerStatuses: .status.containerStatuses}'

# Get events for the workspace
RESP=$(curl -sSk -H "Authorization: Bearer ${TOKEN}" \
  "${K8S_API}/api/v1/namespaces/${NS}/events?fieldSelector=involvedObject.name=${DW_NAME}")
echo "$RESP" | jq -e '.kind' > /dev/null 2>&1 && \
  echo "$RESP" | jq '.items[] | {reason: .reason, message: .message, type: .type, lastTimestamp: .lastTimestamp}'
```

3. **Check container logs:**
```bash
POD_NAME="<pod-name-from-step-2>"
CONTAINER="<container-name>"

curl -sSk -H "Authorization: Bearer ${TOKEN}" \
  "${K8S_API}/api/v1/namespaces/${NS}/pods/${POD_NAME}/log?container=${CONTAINER}&tailLines=100"
```

## Common Failure Patterns and Fixes

| Symptom | Cause | Fix |
|---------|-------|-----|
| `OOMKilled` | Container exceeded memory limit | Increase `memoryLimit` in the devfile container spec |
| `ImagePullBackOff` | Container image not found or no pull credentials | Fix image URL or add pull secret |
| `CrashLoopBackOff` | Container process exits immediately | Check logs; add `args: [tail, '-f', /dev/null]` to all non-UDI containers. Otherwise fix `command`/`args` or image entrypoint |
| Status stuck at `Starting` | DWO controller waiting on conditions | Check conditions — often `StorageReady` or `DeploymentReady` |
| `FailedScheduling` | Insufficient cluster resources (CPU/memory) | Reduce resource requests in devfile |
| PVC `Pending` | No matching StorageClass or capacity | Switch to `ephemeral` storage or reduce volume size |
| Multiple workspaces fail with PVC | ReadWriteOnce PVC conflict | Only one workspace at a time can mount a per-user PVC |

## Patching a DevWorkspace Spec

To fix a DevWorkspace directly:
```bash
# Example: increase memory limit on the first container
curl -sSk -X PATCH -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/merge-patch+json" \
  "${K8S_API}/apis/workspace.devfile.io/v1alpha2/namespaces/${NS}/devworkspaces/${DW_NAME}" \
  -d '{"spec":{"template":{"components":[{"name":"tools","container":{"memoryLimit":"8Gi"}}]}}}'
```

## Restarting a DevWorkspace

**Do NOT use `sleep` between stop and start — `sleep` is not available in this container.** Use a polling loop with bash builtins to wait for the workspace to stop before starting it again.

```bash
# Stop
curl -sSk -X PATCH -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/merge-patch+json" \
  "${K8S_API}/apis/workspace.devfile.io/v1alpha2/namespaces/${NS}/devworkspaces/${DW_NAME}" \
  -d '{"spec":{"started":false}}'

# Wait for workspace to actually stop (poll until phase != Running/Starting)
for i in $(seq 1 30); do
  RESP=$(curl -sSk -H "Authorization: Bearer ${TOKEN}" \
    "${K8S_API}/apis/workspace.devfile.io/v1alpha2/namespaces/${NS}/devworkspaces/${DW_NAME}")
  PHASE=$(echo "$RESP" | jq -r '.status.phase // "Unknown"' 2>/dev/null)
  STARTED=$(echo "$RESP" | jq -r '.spec.started // "null"' 2>/dev/null)
  if [ "$STARTED" = "false" ] && [ "$PHASE" != "Starting" ] && [ "$PHASE" != "Running" ]; then
    echo "Workspace stopped (phase: ${PHASE})"
    break
  fi
  echo "Waiting for workspace to stop (phase: ${PHASE}, attempt ${i}/30)..."
  for j in $(seq 1 500000); do :; done
done

# Start
curl -sSk -X PATCH -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/merge-patch+json" \
  "${K8S_API}/apis/workspace.devfile.io/v1alpha2/namespaces/${NS}/devworkspaces/${DW_NAME}" \
  -d '{"spec":{"started":true}}'
```

## DevWorkspace Conditions Reference

The DevWorkspace controller tracks these conditions (in order of resolution):
1. **Started** — workspace spec accepted
2. **DevWorkspaceResolved** — devfile and plugins resolved
3. **StorageReady** — PVC bound and mounted
4. **RoutingReady** — ingress/route created
5. **ServiceAccountReady** — SA configured
6. **PullSecretsReady** — image pull secrets attached
7. **DeploymentReady** — all containers running

If the workspace is stuck, check which condition is `False` and investigate from there.

## CRITICAL Troubleshooting Rules

1. **Always read the DevWorkspace status and conditions first** before making changes.
2. **Check pod events and container logs** for the actual error message.
3. **⚠️ ALWAYS ask the user for confirmation before patching a DevWorkspace or restarting it.** Present your diagnosis and the exact change you plan to make, then wait for the user to approve. Example:
   ```
   I found the issue: the `nodejs` container is missing `args: [tail, '-f', /dev/null]`,
   which causes the container to exit immediately with CrashLoopBackOff.

   Proposed fix: add `args` to the `nodejs` container component.
   Shall I apply this patch and restart the workspace? (yes/no)
   ```
   Do NOT apply patches or restart workspaces without explicit user approval.
4. **Do NOT delete the DevWorkspace** unless the user explicitly asks — stopping and restarting preserves workspace data.
5. **Prefer minimal patches** — only change the field that needs fixing.
6. **After patching**, stop and restart the workspace for changes to take effect.
