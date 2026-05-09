# Devfile Creator Skill

This skill guides Claude Code to create, analyze, and update Devfile v2 configurations for Eclipse Che workspaces.

## What it does

- Reads and updates devfiles stored in the `devfile-creator-storage` Kubernetes ConfigMap via direct Kubernetes API or Dashboard REST API
- Analyzes Git repositories to detect tech stacks (Java, Node.js, Go, Python, Rust, etc.) by reading `package.json`, `pom.xml`, `go.mod`, and similar files
- Selects the best-matching container image for the detected language and version (UBI-based Red Hat images preferred over UDI)
- Generates correct `components`, `commands`, and `projects` sections following Devfile API v2.2.2
- Enforces the mandatory `args: [tail, '-f', /dev/null]` rule for every non-UDI container to prevent `CrashLoopBackOff`
- Produces properly named fields (`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`) and avoids `postStart`/`preStart` hooks that break workspaces

## Resources used to prepare this skill

- **Devfile API specification** (v2.2.2 and v2.3.0 schema, components, commands, projects, events, variables): https://github.com/devfile/api
- **Devfile Registry** (available stacks, sample devfiles for Node.js, Go, Python, Java, .NET, Angular): https://registry.devfile.io
- **Devfile Developer Images** (UBI9-based universal and base developer images): https://github.com/devfile/developer-images
- **VS Code Walkthrough Extension** (devfile user education and common authoring patterns): https://github.com/devfile/vscode-walkthrough-extension
- **Eclipse Che Documentation** (factory URLs, workspace storage, IDE selection, Che-specific attributes): https://github.com/eclipse-che/che-docs
