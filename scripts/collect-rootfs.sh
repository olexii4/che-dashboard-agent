#!/bin/bash
#
# Copyright (c) 2026 Red Hat, Inc.
# This program and the accompanying materials are made
# available under the terms of the Eclipse Public License 2.0
# which is available at https://www.eclipse.org/legal/epl-2.0/
#
# SPDX-License-Identifier: EPL-2.0
#
set -e

R=/rootfs
mkdir -p $R/{bin,usr/bin,usr/local/bin,etc/ssl,tmp,dev,proc,sys,root,home,var/tmp,opt/claude-skills}

copy_bin() {
  local src=$1 dst=$2
  [ -f "$src" ] || return 0
  cp -L "$src" "$dst"
  strip --strip-unneeded "$dst" 2>/dev/null || true
  ldd "$src" 2>/dev/null | grep -oE '/[^ ]+' | while read lib; do
    [ -f "$lib" ] || continue
    d=$(dirname "$lib")
    mkdir -p "$R$d"
    cp -Ln "$lib" "$R$lib" 2>/dev/null || true
  done
}

# ttyd (static binary, no shared libs needed)
copy_bin /usr/local/bin/ttyd $R/usr/local/bin/ttyd

# kubectl (static binary)
copy_bin /usr/local/bin/kubectl $R/usr/local/bin/kubectl

# Claude Code — Bun standalone executable; do NOT strip (stripping removes
# the appended application bytecode, leaving only the bare Bun runtime).
cp -L /usr/local/bin/claude $R/usr/local/bin/claude-bin
ldd /usr/local/bin/claude 2>/dev/null | grep -oE '/[^ ]+' | while read lib; do
  [ -f "$lib" ] || continue
  d=$(dirname "$lib")
  mkdir -p "$R$d"
  cp -Ln "$lib" "$R$lib" 2>/dev/null || true
done

# Bash
copy_bin /bin/bash $R/bin/bash
ln -sf bash $R/bin/sh
ln -sf /bin/bash $R/usr/bin/bash

# Coreutils and tools needed by Claude Code agent
for cmd in cat ls grep find mkdir rm cp mv ln chmod chown touch \
           pwd echo env dirname basename head tail wc sort tr \
           sed cut tee xargs id whoami uname readlink curl jq git; do
  for d in /bin /usr/bin; do
    if [ -f "$d/$cmd" ]; then
      mkdir -p "$R$d"
      copy_bin "$d/$cmd" "$R$d/$cmd"
      break
    fi
  done
done

# Git helper executables (only https — http is not needed)
if [ -d /usr/lib/git-core ]; then
  mkdir -p $R/usr/lib/git-core
  for helper in git git-remote-https; do
    if [ -f "/usr/lib/git-core/$helper" ]; then
      copy_bin "/usr/lib/git-core/$helper" "$R/usr/lib/git-core/$helper"
    fi
  done
fi

# procps
for cmd in ps kill; do
  for d in /bin /usr/bin; do
    if [ -f "$d/$cmd" ]; then
      mkdir -p "$R$d"
      copy_bin "$d/$cmd" "$R$d/$cmd"
      break
    fi
  done
done

# glibc compat stubs merged into libc.so.6 in glibc 2.34+ but still
# needed by binaries linked against older glibc (e.g. Bun/Claude Code)
for pattern in "librt.so*" "libpthread.so*" "libdl.so*" "libm.so*" "libutil.so*"; do
  find /lib* /usr/lib* -name "$pattern" 2>/dev/null | while read f; do
    d=$(dirname "$f")
    mkdir -p "$R$d"
    cp -Ln "$f" "$R$d/" 2>/dev/null || true
  done
done

# NSS libraries for DNS resolution
for pattern in "libnss_dns*" "libnss_files*" "libresolv*"; do
  find /lib* -name "$pattern" 2>/dev/null | while read f; do
    d=$(dirname "$f")
    mkdir -p "$R$d"
    cp -Ln "$f" "$R$d/" 2>/dev/null || true
  done
done

# SSL certificates
cp -rL /etc/ssl $R/etc/

# Minimal /etc — includes user 1001 for non-root operation
echo 'root:x:0:0:root:/root:/bin/bash' > $R/etc/passwd
echo 'agent:x:1001:0:agent:/tmp/claude-home:/bin/bash' >> $R/etc/passwd
echo 'nobody:x:65534:65534:nobody:/nonexistent:/bin/false' >> $R/etc/passwd
echo 'root:x:0:' > $R/etc/group
echo 'nobody:x:65534:' >> $R/etc/group
echo 'hosts: files dns' > $R/etc/nsswitch.conf

# Writable temp dirs
chmod 1777 $R/tmp $R/var/tmp

# Shared init script — used by both entrypoint and claude wrapper
cat > $R/usr/local/bin/init-claude.sh << 'INIT'
#!/bin/sh
CLAUDE_TMP_HOME="/tmp/claude-home"
if [ ! -w "$HOME" ]; then
  export HOME="$CLAUDE_TMP_HOME"
fi
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/plugins/marketplaces/claude-plugins-official" "$HOME/.local/bin"
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export CLAUDE_CODE_SKIP_PERMISSIONS_CONFIRMATION=1
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
cp /opt/claude-skills/CLAUDE.md "$HOME/CLAUDE.md" 2>/dev/null || true
cp /opt/claude-skills/CLAUDE.md "$HOME/.claude/CLAUDE.md" 2>/dev/null || true
cp /opt/claude-skills/settings.json "$HOME/.claude/settings.json" 2>/dev/null || true
cp /opt/claude-skills/claude.json "$HOME/.claude.json" 2>/dev/null || true
# Pre-install the che-dashboard-agent plugin from the embedded plugin directory
PLUGIN_SRC="/opt/claude-plugin/che-dashboard-agent"
PLUGIN_CACHE="$HOME/.claude/plugins/cache/che-dashboard-local/che-dashboard-agent/1.0.0"
if [ -d "$PLUGIN_SRC" ] && [ ! -d "$PLUGIN_CACHE" ]; then
  mkdir -p "$PLUGIN_CACHE"
  cp -r "$PLUGIN_SRC/." "$PLUGIN_CACHE/"
fi
if [ ! -f "$HOME/.claude/plugins/known_marketplaces.json" ]; then
  printf '{"claude-plugins-official":{"source":{"source":"github","repo":"anthropics/claude-plugins-official"},"installLocation":"%s/.claude/plugins/marketplaces/claude-plugins-official","lastUpdated":"2026-04-19T00:00:00.000Z"},"che-dashboard-local":{"source":{"source":"directory","path":"/opt/claude-plugin"},"installLocation":"%s/.claude/plugins/marketplaces/che-dashboard-local","lastUpdated":"2026-04-19T00:00:00.000Z"}}' \
    "$HOME" "$HOME" > "$HOME/.claude/plugins/known_marketplaces.json" 2>/dev/null || true
fi
if [ ! -f "$HOME/.claude/plugins/installed_plugins.json" ]; then
  printf '{"version":2,"plugins":{"che-dashboard-agent@che-dashboard-local":[{"scope":"user","installPath":"%s","version":"1.0.0","installedAt":"2026-04-19T00:00:00.000Z","lastUpdated":"2026-04-19T00:00:00.000Z"}]}}' \
    "$PLUGIN_CACHE" > "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null || true
fi
# Configure kubectl with the cluster API and user token
if [ -n "$KUBERNETES_API_URL" ]; then
  TOKEN_FILE="${CHE_USER_TOKEN_FILE:-/var/run/secrets/che/token/token}"
  KUBECONFIG="$HOME/.kube/config"
  export KUBECONFIG
  mkdir -p "$HOME/.kube"
  kubectl config set-cluster che --server="$KUBERNETES_API_URL" --insecure-skip-tls-verify=true >/dev/null 2>&1
  if [ -f "$TOKEN_FILE" ]; then
    kubectl config set-credentials che-user --token="$(cat "$TOKEN_FILE")" >/dev/null 2>&1
  fi
  kubectl config set-context che --cluster=che --user=che-user --namespace="${AGENT_NAMESPACE:-default}" >/dev/null 2>&1
  kubectl config use-context che >/dev/null 2>&1
fi
INIT
chmod +x $R/usr/local/bin/init-claude.sh

# Claude wrapper script
cat > $R/usr/local/bin/claude << 'WRAPPER'
#!/bin/sh
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/init-claude.sh"
exec "$SCRIPT_DIR/claude-bin" "$@"
WRAPPER
chmod +x $R/usr/local/bin/claude

# .bashrc
printf '# Claude Code agent shell\nexport CLAUDE_CODE_SKIP_PERMISSIONS_CONFIRMATION=1\n' \
  > $R/opt/claude-skills/.bashrc

# Entrypoint script — starts ttyd terminal server
cat > $R/usr/local/bin/entrypoint.sh << 'ENTRY'
#!/bin/sh
. /usr/local/bin/init-claude.sh
cp /opt/claude-skills/.bashrc "$HOME/.bashrc" 2>/dev/null || true
exec /usr/local/bin/ttyd -p 8080 -W bash
ENTRY
chmod +x $R/usr/local/bin/entrypoint.sh

echo "=== Rootfs stats ==="
du -sh $R
echo "Files: $(find $R -type f | wc -l)"
