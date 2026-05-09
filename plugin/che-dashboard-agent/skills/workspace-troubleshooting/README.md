# Workspace Troubleshooting Skill

This skill guides Claude Code to diagnose and fix DevWorkspace startup failures in Eclipse Che.

## What it does

- Reads DevWorkspace status, phase, conditions, and message via the Kubernetes API
- Finds workspace pods by label selector and inspects container statuses and events
- Tails container logs to surface the actual error message
- Identifies common failure patterns: `CrashLoopBackOff`, `OOMKilled`, `ImagePullBackOff`, `FailedScheduling`, stuck `Starting` state, PVC conflicts
- Proposes a targeted, minimal patch and waits for explicit user approval before applying it
- Handles safe workspace stop/restart using a bash polling loop (no `sleep` binary available in the agent container)
- Never deletes a DevWorkspace without explicit user instruction

## Resources used to prepare this skill

- **DevWorkspace Operator** (CRD structure, status conditions, phase lifecycle, patch semantics): https://github.com/devfile/devworkspace-operator
- **Eclipse Che Documentation** (workspace troubleshooting guides, storage types, routing): https://github.com/eclipse-che/che-docs
- **Kubernetes API Reference** (pods, events, logs, merge-patch+json): https://kubernetes.io/docs/reference/
