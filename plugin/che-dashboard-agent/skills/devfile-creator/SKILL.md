---
name: devfile-creator
description: "Create and edit devfiles for Eclipse Che workspaces. Use when users ask to create a devfile, configure workspace components/commands/projects, analyze a Git repository to detect its tech stack, choose container images, or set up development environment configuration."
---

# Devfile Creator

Help users create and edit devfiles for Eclipse Che workspaces. Access the user's devfiles from
Kubernetes, analyze project repositories to detect tech stacks, generate correct devfile YAML, and
update the stored devfile via the API.

When first greeting the user, always offer these common actions as examples:
- Add components (containers, volumes) for a specific tech stack
- Add a `projects` section to clone a Git repository into the workspace
- Generate a full devfile from a Git URL (provide the URL and I'll analyze the repo)
- Add commands (build, run, test, debug)
- Troubleshoot a workspace startup issue

## How to Access and Edit Devfiles

User devfiles are stored in a Kubernetes ConfigMap named `devfile-creator-storage` in the user's
namespace. Each devfile is a key-value pair where the key is a UUID and the value is the raw YAML
content.

### Your Environment

When running inside an agent pod, the following environment variables are available:
- `AGENT_NAMESPACE` — the Kubernetes namespace you are running in (this is the user's namespace)
- `KUBERNETES_API_URL` — the Kubernetes API server URL (e.g., `https://api.crc.testing:6443`)
- `CHE_USER_TOKEN_FILE` — path to the file containing the user's authentication token (default: `/var/run/secrets/che/token/token`)

### Method 1: Direct Kubernetes Access (Preferred)

You can read and modify devfiles directly from the ConfigMap using `curl` with the user's token:

```bash
# Set variables
NAMESPACE="${AGENT_NAMESPACE}"
TOKEN="$(cat ${CHE_USER_TOKEN_FILE})"
K8S_API="${KUBERNETES_API_URL}"
CM_NAME="devfile-creator-storage"

# List all devfiles (each key in .data is a UUID, each value is YAML content)
curl -sSk -H "Authorization: Bearer ${TOKEN}" \
  "${K8S_API}/api/v1/namespaces/${NAMESPACE}/configmaps/${CM_NAME}" | jq '.data'

# Read a specific devfile by its UUID key
curl -sSk -H "Authorization: Bearer ${TOKEN}" \
  "${K8S_API}/api/v1/namespaces/${NAMESPACE}/configmaps/${CM_NAME}" | jq -r '.data["<UUID>"]'

# Update a specific devfile (JSON merge patch — set the key to new YAML content)
curl -sSk -X PATCH -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/merge-patch+json" \
  "${K8S_API}/api/v1/namespaces/${NAMESPACE}/configmaps/${CM_NAME}" \
  -d '{"data":{"<UUID>":"<new YAML content>"}}'

# Delete a specific devfile (JSON merge patch — set the key to null)
curl -sSk -X PATCH -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/merge-patch+json" \
  "${K8S_API}/api/v1/namespaces/${NAMESPACE}/configmaps/${CM_NAME}" \
  -d '{"data":{"<UUID>":null}}'
```

### Method 2: Dashboard REST API

The dashboard backend also exposes a REST API. The dashboard service is available inside the cluster at `http://che-dashboard.eclipse-che.svc:8080`:

```bash
DASHBOARD_URL="http://che-dashboard.eclipse-che.svc:8080"
NAMESPACE="${AGENT_NAMESPACE}"

# List all devfiles (returns JSON with .devfiles array)
curl -sS "${DASHBOARD_URL}/dashboard/api/devfiles/namespace/${NAMESPACE}"

# Create a new devfile
curl -sS -X POST -H "Content-Type: application/json" \
  "${DASHBOARD_URL}/dashboard/api/devfiles/namespace/${NAMESPACE}" \
  -d '{"content":"<YAML content>"}'

# Update a devfile
curl -sS -X PUT -H "Content-Type: application/json" \
  "${DASHBOARD_URL}/dashboard/api/devfiles/namespace/${NAMESPACE}/<UUID>" \
  -d '{"content":"<YAML content>"}'

# Delete a devfile
curl -sS -X DELETE \
  "${DASHBOARD_URL}/dashboard/api/devfiles/namespace/${NAMESPACE}/<UUID>"
```

### Workflow for Editing a Devfile

1. First, list all devfiles to find the one the user is working with
2. Read the devfile content by its UUID
3. Make the requested changes to the YAML
4. Update the devfile via the API (the dashboard UI will auto-refresh)

**Important:** When updating a devfile, send the complete YAML content — partial updates are not supported. Always preserve fields you did not change.

## Devfile Format (Devfile API v2)

Devfiles follow the [Devfile API](https://github.com/devfile/api) specification. The current version is **2.2.2** (`schemaVersion: 2.2.2`). Version **2.3.0** is also supported.

### Minimal Devfile

```yaml
schemaVersion: 2.2.2
metadata:
  name: my-project
```

### Key Sections

#### metadata
```yaml
metadata:
  name: my-project          # required, workspace display name
  generateName: my-project-  # alternative to name, generates unique name
  version: 1.0.0            # optional
  description: "..."        # optional
```

#### components
Components define the containers, volumes, and Kubernetes resources for the workspace.

**Container component** (most common):
```yaml
components:
  - name: tools
    container:
      image: quay.io/devfile/universal-developer-image:ubi9-latest
      memoryLimit: 4Gi
      memoryRequest: 512Mi
      cpuLimit: '2'
      cpuRequest: 500m
      mountSources: true     # mount project sources at /projects
      endpoints:
        - name: http
          targetPort: 8080
          exposure: public
      env:
        - name: NODE_ENV
          value: development
```

#### Container `args` Field

The `args` field overrides the container image's default `CMD`. This is essential when using images that don't have a long-running entrypoint — without it, the container exits immediately and Kubernetes reports `CrashLoopBackOff`.

**Rule: ALWAYS add `args` to every container component EXCEPT `quay.io/devfile/universal-developer-image`.**

This includes:
- Standard OS images: `debian`, `ubuntu`, `alpine`, `fedora`, `centos`, `busybox`
- Language runtimes from Docker Hub: `node`, `python`, `golang`, `ruby`, `rust`
- Database / service images: `mysql`, `postgres`, `redis`, `mongo`, `mariadb`, etc.
- Any other third-party or custom image

**The ONLY exception — do NOT add `args`:**
- `quay.io/devfile/universal-developer-image` — already has a long-running entrypoint built for Che

**The standard pattern** to keep a container alive:
```yaml
args:
  - tail
  - '-f'
  - /dev/null
```

**Full example — Debian container:**
```yaml
components:
  - name: runtime
    container:
      image: docker.io/debian:bookworm
      args:
        - tail
        - '-f'
        - /dev/null
      memoryLimit: 2Gi
      mountSources: true
```

**Full example — Node.js from Docker Hub:**
```yaml
components:
  - name: node
    container:
      image: docker.io/node:22-slim
      args:
        - tail
        - '-f'
        - /dev/null
      memoryLimit: 4Gi
      mountSources: true
      endpoints:
        - name: http
          targetPort: 3000
          exposure: public
```

**Full example — Python from Docker Hub:**
```yaml
components:
  - name: python
    container:
      image: docker.io/python:3.12-slim
      args:
        - tail
        - '-f'
        - /dev/null
      memoryLimit: 2Gi
      mountSources: true
```

**Important notes:**
- Each argument is a separate list item in YAML. Do NOT write `args: ['tail', '-f', '/dev/null']` — use the multi-line list format shown above.
- The `-f` argument must be quoted (`'-f'`) in YAML because it starts with a dash.
- The `command` field overrides `ENTRYPOINT`. Usually you only need `args` (which overrides `CMD`). Use `command` only if you need to replace the entrypoint entirely.

**Volume component**:
```yaml
components:
  - name: m2-cache
    volume:
      size: 1Gi
```

**Kubernetes component** (deploy K8s resources):
```yaml
components:
  - name: postgres
    kubernetes:
      inlined: |
        apiVersion: apps/v1
        kind: Deployment
        ...
```

#### commands
Commands define actions that can be executed in containers.

```yaml
commands:
  - id: build
    exec:
      label: "Build"
      component: tools       # must match a container component name
      workingDir: ${PROJECT_SOURCE}
      commandLine: "npm run build"
      group:
        kind: build
        isDefault: true

  - id: run
    exec:
      label: "Run"
      component: tools
      workingDir: ${PROJECT_SOURCE}
      commandLine: "npm start"
      group:
        kind: run
        isDefault: true
```

#### projects
Projects define Git repositories to clone into the workspace.

```yaml
projects:
  - name: my-app
    git:
      remotes:
        origin: https://github.com/user/my-app.git
      checkoutFrom:
        revision: main
```

### Eclipse Che Specific Attributes

```yaml
# Storage type (ephemeral = no persistent volumes)
attributes:
  controller.devfile.io/storage-type: ephemeral
```

### Common Container Images

- `quay.io/devfile/universal-developer-image:ubi9-latest` — full dev environment (Node, Python, Go, Java, etc.)
- `registry.access.redhat.com/ubi9/nodejs-20:latest` — Node.js 20
- `registry.access.redhat.com/ubi9/python-312:latest` — Python 3.12
- `registry.access.redhat.com/ubi9/go-toolset:latest` — Go
- `registry.access.redhat.com/ubi9/openjdk-21:latest` — Java 21

### How to Analyze a Project and Generate Commands

**Before generating a devfile, ALWAYS analyze the project repository** to determine the correct tech stack, commands, and container images. Use the GitHub REST API or `git` to read key files.

#### Step 1: Identify the tech stack by reading project files

**ALWAYS list the repository structure first** before fetching any specific file. Projects often keep
source code in a subdirectory (e.g., `src/`, `app/`, `discord-bot/`), so blindly fetching
`/package.json` from the root will return 404. Discover the actual layout first.

```bash
# 1. Get repo metadata (language hint, default branch)
curl -sSL "https://api.github.com/repos/<owner>/<repo>" | jq '{language, default_branch, description}'

# 2. List root directory to understand the project layout
curl -sSL "https://api.github.com/repos/<owner>/<repo>/contents/" | jq -r '.[].name'

# 3. If project files are not at root, inspect subdirectories that look like source roots
curl -sSL "https://api.github.com/repos/<owner>/<repo>/contents/<subdir>" | jq -r '.[].name'

# 4. Fetch the manifest file from the correct path
curl -sSL "https://raw.githubusercontent.com/<owner>/<repo>/<branch>/<path>/package.json" | jq '.'
```

**What to look for (and where):**
- `package.json` → Node.js project. Check `scripts` for available commands, `dependencies` for framework. May be in a subdirectory.
- `pom.xml` or `build.gradle` → Java project. May be nested under a Maven module directory.
- `go.mod` → Go project
- `requirements.txt` / `pyproject.toml` / `setup.py` → Python project
- `Cargo.toml` → Rust project
- `Gemfile` → Ruby project

**If none of the well-known files are at the repo root**, list subdirectories one level deep and check each that looks like a source root before concluding the tech stack is unknown.

#### Step 2: Generate correct commands based on project analysis

**CRITICAL: NEVER use bare framework CLI names as commands.** Framework CLIs (`remix`, `next`, `vite`, `webpack`, `tsc`, `jest`, `prisma`, `drizzle`, etc.) are **local project dependencies**, NOT global binaries. They will fail with `command not found`.

**Node.js command rules:**

| Wrong (will fail) | Correct |
|---|---|
| `remix build` | `npx remix build` or `npm run build` |
| `remix dev` | `npx remix dev` or `npm run dev` |
| `next build` | `npx next build` or `npm run build` |
| `next dev` | `npx next dev` or `npm run dev` |
| `vite build` | `npx vite build` or `npm run build` |
| `tsc` | `npx tsc` or `npm run typecheck` |
| `jest` | `npx jest` or `npm test` |
| `webpack` | `npx webpack` or `npm run build` |
| `prisma migrate` | `npx prisma migrate dev` |

**Best practice: always prefer `npm run <script>` over `npx <tool>`** — the project's `package.json` scripts already know the correct flags and options. Read the `scripts` section of `package.json` to find available script names.

**Example — reading package.json to generate commands:**
If `package.json` has:
```json
{
  "scripts": {
    "dev": "remix vite:dev",
    "build": "remix vite:build",
    "start": "remix-serve ./build/server/index.js",
    "typecheck": "tsc"
  }
}
```
Then the devfile commands should be:
```yaml
commands:
  - id: install
    exec:
      component: tools
      commandLine: npm install
      workingDir: ${PROJECT_SOURCE}
      group:
        kind: build
  - id: build
    exec:
      component: tools
      commandLine: npm run build
      workingDir: ${PROJECT_SOURCE}
      group:
        kind: build
        isDefault: true
  - id: run
    exec:
      component: tools
      commandLine: npm run dev
      workingDir: ${PROJECT_SOURCE}
      group:
        kind: run
        isDefault: true
  - id: start-prod
    exec:
      component: tools
      commandLine: npm run start
      workingDir: ${PROJECT_SOURCE}
      group:
        kind: run
```

**Java command rules:**
- Use `mvn` or `gradle` commands directly (they are global tools in dev images)
- Example: `mvn clean package -DskipTests`, `mvn spring-boot:run`, `gradle build`
- **Detect Java version**: Read `maven.compiler.source` or `maven.compiler.target` from `pom.xml` (or `sourceCompatibility` from `build.gradle`) to determine the required JDK version. This is CRITICAL — using the wrong JDK version causes `invalid target release` errors.

**Go command rules:**
- Use `go` commands directly: `go build ./...`, `go run .`, `go test ./...`

**Python command rules:**
- Use `pip install -r requirements.txt`, `python app.py`, `python -m pytest`

#### Step 3: Choose the right container image for the tech stack

| Project type | Recommended image | Notes |
|---|---|---|
| Java 21 | `registry.access.redhat.com/ubi9/openjdk-21:latest` (needs `args`) | Has JDK 21 + Maven. Detect from `pom.xml` `maven.compiler.source` |
| Java 17 | `registry.access.redhat.com/ubi9/openjdk-17:latest` (needs `args`) | Has JDK 17 + Maven |
| Java 11 | `registry.access.redhat.com/ubi8/openjdk-11:latest` (needs `args`) | Has JDK 11 + Maven |
| Node.js 20+ | `registry.access.redhat.com/ubi9/nodejs-20:latest` (needs `args`) | Lightweight Node.js |
| Node.js (any) | `docker.io/node:22-slim` (needs `args`) | Specific Node.js version |
| Go | `registry.access.redhat.com/ubi9/go-toolset:latest` (needs `args`) | Go toolchain |
| Python 3.12 | `registry.access.redhat.com/ubi9/python-312:latest` (needs `args`) | Python + pip |
| Python (any) | `docker.io/python:3.12-slim` (needs `args`) | Specific Python version |
| Multi-language / unknown (last resort) | `quay.io/devfile/universal-developer-image:ubi9-latest` | Only when stack cannot be detected, no `args` needed |
| Database sidecar (MySQL) | `docker.io/library/mysql:8.0` (needs `args`) | Sidecar only |
| Database sidecar (PostgreSQL) | `docker.io/postgres:16-alpine` (needs `args`) | Sidecar only |
| Database sidecar (Redis) | `docker.io/redis:7-alpine` (needs `args`) | Sidecar only |

**Image selection rules:**
- **ALWAYS choose the best matching specific image** for the detected tech stack.
- **For Java projects**: read `maven.compiler.source` / `maven.compiler.target` from `pom.xml`. Use `ubi9/openjdk-21` for Java 21, `ubi9/openjdk-17` for Java 17, etc. UDI only has Java 11 — Java 17+ projects WILL FAIL with UDI.
- **For Node.js projects**: use `ubi9/nodejs-20` or `docker.io/node:<version>-slim`.
- **For Go projects**: use `ubi9/go-toolset`.
- **For Python projects**: use `ubi9/python-312` or `docker.io/python:<version>-slim`.
- **Use UDI (`quay.io/devfile/universal-developer-image:ubi9-latest`) ONLY** as a last resort when the tech stack truly cannot be determined from project files.
- Prefer `ubi9` over `ubi8` variants.

### CRITICAL Rules

1. **NEVER use `python3`, `python`, `awk`, `perl`, `node`, `npm`, `gh`, `wget`.** Use `jq` for JSON, `sed`/`cut`/`tr` for text processing, `curl` for HTTP.
2. **NEVER add `events.postStart` or `events.preStart` unless the user explicitly asks for it.** PostStart hooks run as Kubernetes lifecycle hooks and will **fail the entire workspace** if the command exits non-zero. Commands that depend on project sources will fail because the project may not be cloned yet when the postStart hook runs.
3. Always use `schemaVersion: 2.2.2` (latest stable) unless the user requests 2.3.0.
4. Set `mountSources: true` on the main dev container so project files are available at `/projects`.
5. Use `${PROJECT_SOURCE}` variable for `workingDir` in commands (resolves to the project directory).
6. Set reasonable `memoryLimit` and `cpuLimit` for containers.
7. Define `build` and `run` command groups with `isDefault: true`.
8. Use `endpoints` for any ports that need to be accessible.
9. Use `volume` components for caches (Maven, npm, pip) that should persist.
10. **NEVER use this agent's own image or terminal images in generated devfiles.**
11. **You MUST add `args: [tail, '-f', /dev/null]` to every container EXCEPT UDI.** Without `args`, containers exit immediately and cause `CrashLoopBackOff`.
12. **All `name` fields MUST match `^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`.** Lowercase letters, digits, and hyphens only; must start and end with a letter or digit. Convert names like `Angular_Tutorial_App` → `angular-tutorial-app`.

## Real-World Devfile Examples

### Example 1: Node.js / TypeScript Project (che-dashboard)

```yaml
schemaVersion: 2.2.2
metadata:
  name: che-dashboard
components:
  - name: tools
    container:
      image: quay.io/devfile/universal-developer-image:ubi9-latest
      memoryLimit: 10G
      memoryRequest: 512Mi
      cpuRequest: 1000m
      cpuLimit: 5000m
      mountSources: true
      endpoints:
        - exposure: public
          name: local-server
          protocol: https
          targetPort: 8080
          path: /
        - exposure: public
          name: bundle-analyzer
          path: /
          protocol: https
          targetPort: 8888
      env:
        - name: KUBEDOCK_ENABLED
          value: "true"
commands:
  - id: installdependencies
    exec:
      label: "Install dependencies"
      component: tools
      workingDir: ${PROJECT_SOURCE}
      commandLine: "yarn install"
      group:
        kind: build
        isDefault: true
  - id: build
    exec:
      label: "Build"
      component: tools
      workingDir: ${PROJECT_SOURCE}
      commandLine: "yarn install && yarn build"
      group:
        kind: build
  - id: runtests
    exec:
      label: "Test"
      component: tools
      workingDir: ${PROJECT_SOURCE}
      commandLine: "yarn test"
      group:
        kind: test
```

### Example 2: Node.js CLI Project (chectl)

```yaml
schemaVersion: 2.3.0
metadata:
  name: chectl-dev
components:
  - name: tools
    container:
      image: quay.io/devfile/universal-developer-image:ubi9-latest
      cpuLimit: 500m
      cpuRequest: 500m
      memoryLimit: 5G
      memoryRequest: 1G
      env:
        - name: NODEJS_VERSION
          value: "22.11.0"
commands:
  - id: 1-build-env
    exec:
      label: "Install node and setup yarn"
      component: tools
      workingDir: ${PROJECT_SOURCE}
      commandLine: >-
        nvm install $NODEJS_VERSION && nvm use v$NODEJS_VERSION && npm i npm@10 -g && corepack enable
      group:
        kind: build
  - id: 2-install-dependencies
    exec:
      label: "Install dependencies"
      component: tools
      workingDir: ${PROJECT_SOURCE}
      commandLine: >-
        nvm use v$NODEJS_VERSION && yarn install
      group:
        kind: build
  - id: 3-build
    exec:
      label: "Build"
      component: tools
      workingDir: ${PROJECT_SOURCE}
      commandLine: >-
        nvm use v$NODEJS_VERSION && yarn install && yarn pack-binaries --targets=linux-x64
      group:
        kind: build
  - id: 4-test
    exec:
      label: "Test"
      component: tools
      workingDir: ${PROJECT_SOURCE}
      commandLine: nvm use v$NODEJS_VERSION && yarn install && yarn test
      group:
        kind: test
        isDefault: true
  - id: 5-run
    exec:
      label: "Run"
      component: tools
      workingDir: ${PROJECT_SOURCE}
      commandLine: ./bin/run --help
      group:
        kind: run
        isDefault: true
```

### Example 3: VS Code Extension Development (che-code)

```yaml
schemaVersion: 2.2.2
metadata:
  name: che-code
components:
  - name: dev
    container:
      image: quay.io/che-incubator/che-code-dev:insiders
      memoryLimit: 12Gi
      memoryRequest: 512Mi
      cpuRequest: 500m
      cpuLimit: 3500m
      endpoints:
        - exposure: public
          name: dev
          protocol: http
          targetPort: 8000
      env:
        - name: KUBEDOCK_ENABLED
          value: "true"
  - name: projects
    volume:
      size: 10Gi
commands:
  - id: npm-install
    exec:
      label: "Install dependencies"
      component: dev
      workingDir: ${PROJECTS_ROOT}/che-code
      commandLine: npm install
      group:
        kind: build
  - id: npm-build
    exec:
      label: "Build (watch mode)"
      component: dev
      workingDir: ${PROJECTS_ROOT}/che-code
      commandLine: npm run watch
      group:
        kind: build
        isDefault: true
  - id: npm-run
    exec:
      label: "Run server on port 8000"
      component: dev
      workingDir: ${PROJECTS_ROOT}/che-code
      commandLine: npm run server
      group:
        kind: run
        isDefault: true
```

### Example 4: Multi-Container Project (OpenWRT Embedded Development)

```yaml
schemaVersion: 2.2.2
metadata:
  generateName: openwrt-helloworld
attributes:
  controller.devfile.io/storage-type: ephemeral
projects:
  - name: openwrt-helloworld
    git:
      remotes:
        origin: https://github.com/che-incubator/openwrt-helloworld-package.git
  - name: openwrt
    zip:
      location: https://github.com/openwrt/openwrt/archive/refs/tags/v21.02.3.zip
components:
  - name: runtime
    container:
      image: quay.io/che-incubator/openwrt-builder:latest
      memoryLimit: 6656Mi
      memoryRequest: 512Mi
      cpuLimit: 10000m
      cpuRequest: 1000m
      mountSources: true
      endpoints:
        - exposure: public
          name: file-server
          protocol: https
          targetPort: 8080
          path: /bin/targets
  - name: qemu
    container:
      image: quay.io/che-incubator/openwrt-runner:latest
      memoryLimit: 1536Mi
      memoryRequest: 256Mi
      cpuLimit: 1500m
      cpuRequest: 500m
      mountSources: true
      endpoints:
        - exposure: public
          name: luci
          protocol: https
          targetPort: 30080
        - exposure: internal
          name: ssh
          protocol: tcp
          targetPort: 30022
commands:
  - id: build
    exec:
      label: "Build helloworld package"
      component: runtime
      workingDir: ${PROJECTS_ROOT}/openwrt
      commandLine: make package/helloworld/compile V=s CONFIG_DEBUG=y
      group:
        kind: build
        isDefault: true
  - id: qemustart
    exec:
      label: "Run OpenWRT in QEMU VM"
      component: qemu
      workingDir: ${PROJECTS_ROOT}
      commandLine: /usr/local/bin/prepare-and-run-vm.sh
      group:
        kind: run
        isDefault: true
```

### Example 5: Simple Go Project

```yaml
schemaVersion: 2.2.2
metadata:
  name: go-web-server
components:
  - name: tools
    container:
      image: quay.io/devfile/universal-developer-image:ubi9-latest
      memoryLimit: 4Gi
      memoryRequest: 512Mi
      cpuRequest: 500m
      cpuLimit: 2000m
      mountSources: true
      endpoints:
        - name: http
          targetPort: 8080
          exposure: public
projects:
  - name: go-web-server
    git:
      remotes:
        origin: https://github.com/user/go-web-server.git
commands:
  - id: build
    exec:
      label: "Build"
      component: tools
      workingDir: ${PROJECT_SOURCE}
      commandLine: go build -o server .
      group:
        kind: build
        isDefault: true
  - id: run
    exec:
      label: "Run"
      component: tools
      workingDir: ${PROJECT_SOURCE}
      commandLine: go run .
      group:
        kind: run
        isDefault: true
  - id: test
    exec:
      label: "Test"
      component: tools
      workingDir: ${PROJECT_SOURCE}
      commandLine: go test ./...
      group:
        kind: test
        isDefault: true
```

### Example 6: Python Web Application

```yaml
schemaVersion: 2.2.2
metadata:
  name: python-web-app
components:
  - name: tools
    container:
      image: quay.io/devfile/universal-developer-image:ubi9-latest
      memoryLimit: 4Gi
      memoryRequest: 512Mi
      cpuRequest: 500m
      cpuLimit: 2000m
      mountSources: true
      endpoints:
        - name: http
          targetPort: 5000
          exposure: public
projects:
  - name: python-web-app
    git:
      remotes:
        origin: https://github.com/user/python-web-app.git
commands:
  - id: install
    exec:
      label: "Install dependencies"
      component: tools
      workingDir: ${PROJECT_SOURCE}
      commandLine: pip install -r requirements.txt
      group:
        kind: build
        isDefault: true
  - id: run
    exec:
      label: "Run"
      component: tools
      workingDir: ${PROJECT_SOURCE}
      commandLine: python app.py
      group:
        kind: run
        isDefault: true
  - id: test
    exec:
      label: "Test"
      component: tools
      workingDir: ${PROJECT_SOURCE}
      commandLine: pytest
      group:
        kind: test
        isDefault: true
```

### Example 7: Java / Spring Boot Project

```yaml
schemaVersion: 2.2.2
metadata:
  name: spring-boot-app
components:
  - name: tools
    container:
      image: quay.io/devfile/universal-developer-image:ubi9-latest
      memoryLimit: 6Gi
      memoryRequest: 1Gi
      cpuRequest: 500m
      cpuLimit: 2000m
      mountSources: true
      endpoints:
        - name: http
          targetPort: 8080
          exposure: public
  - name: m2-cache
    volume:
      size: 2Gi
projects:
  - name: spring-boot-app
    git:
      remotes:
        origin: https://github.com/user/spring-boot-app.git
commands:
  - id: build
    exec:
      label: "Build"
      component: tools
      workingDir: ${PROJECT_SOURCE}
      commandLine: mvn clean package -DskipTests
      group:
        kind: build
        isDefault: true
  - id: run
    exec:
      label: "Run"
      component: tools
      workingDir: ${PROJECT_SOURCE}
      commandLine: mvn spring-boot:run
      group:
        kind: run
        isDefault: true
  - id: test
    exec:
      label: "Test"
      component: tools
      workingDir: ${PROJECT_SOURCE}
      commandLine: mvn test
      group:
        kind: test
        isDefault: true
```

### Example 8: Debian / Ubuntu with `args` (Standard OS Image)

```yaml
schemaVersion: 2.3.0
metadata:
  name: debian-dev
components:
  - name: runtime
    container:
      image: docker.io/debian:bookworm
      args:
        - tail
        - '-f'
        - /dev/null
      memoryLimit: 2Gi
      memoryRequest: 256Mi
      cpuRequest: 500m
      cpuLimit: 2000m
      mountSources: true
commands:
  - id: install-tools
    exec:
      label: "Install build tools"
      component: runtime
      workingDir: ${PROJECT_SOURCE}
      commandLine: apt-get update && apt-get install -y build-essential
      group:
        kind: build
        isDefault: true
```

### Example 9: Docker Hub Node.js with `args`

```yaml
schemaVersion: 2.2.2
metadata:
  name: node-docker-hub
components:
  - name: node
    container:
      image: docker.io/node:22-slim
      args:
        - tail
        - '-f'
        - /dev/null
      memoryLimit: 4Gi
      memoryRequest: 512Mi
      cpuRequest: 500m
      cpuLimit: 2000m
      mountSources: true
      endpoints:
        - name: http
          targetPort: 3000
          exposure: public
projects:
  - name: my-app
    git:
      remotes:
        origin: https://github.com/user/my-app.git
commands:
  - id: install
    exec:
      label: "Install dependencies"
      component: node
      workingDir: ${PROJECT_SOURCE}
      commandLine: npm install
      group:
        kind: build
        isDefault: true
  - id: run
    exec:
      label: "Run"
      component: node
      workingDir: ${PROJECT_SOURCE}
      commandLine: npm start
      group:
        kind: run
        isDefault: true
```

### Example 10: Multi-Container with Mixed Image Types

```yaml
schemaVersion: 2.2.2
metadata:
  name: fullstack-app
components:
  - name: tools
    container:
      image: quay.io/devfile/universal-developer-image:ubi9-latest
      memoryLimit: 4Gi
      mountSources: true
      endpoints:
        - name: frontend
          targetPort: 3000
          exposure: public
        - name: backend
          targetPort: 8080
          exposure: public
  - name: db
    container:
      image: docker.io/postgres:16-alpine
      args:
        - tail
        - '-f'
        - /dev/null
      memoryLimit: 512Mi
      env:
        - name: POSTGRES_USER
          value: dev
        - name: POSTGRES_PASSWORD
          value: dev
        - name: POSTGRES_DB
          value: app
      endpoints:
        - name: postgres
          targetPort: 5432
          exposure: internal
```
