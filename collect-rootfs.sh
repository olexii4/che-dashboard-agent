#!/bin/bash
set -e

R=/rootfs
mkdir -p $R/{bin,usr/bin,usr/local/bin,usr/local/lib/node_modules,etc/ssl,tmp,dev,proc,sys,root,home,var/tmp,opt/claude-skills}

copy_bin() {
  local src=$1 dst=$2
  [ -f "$src" ] || return 0
  cp -L "$src" "$dst"
  ldd "$src" 2>/dev/null | grep -oE '/[^ ]+' | while read lib; do
    [ -f "$lib" ] || continue
    d=$(dirname "$lib")
    mkdir -p "$R$d"
    cp -Ln "$lib" "$R$lib" 2>/dev/null || true
  done
}

# Core binaries
copy_bin /usr/local/bin/node   $R/usr/local/bin/node
copy_bin /bin/bash             $R/bin/bash
ln -sf bash $R/bin/sh
copy_bin /usr/local/bin/claude $R/usr/local/bin/claude-bin

# Coreutils and tools needed by Claude Code agent
for cmd in cat ls grep find mkdir rm cp mv ln chmod chown touch \
           pwd echo env dirname basename head tail wc sort tr \
           sed cut tee xargs id whoami uname readlink curl jq; do
  for d in /bin /usr/bin; do
    if [ -f "$d/$cmd" ]; then
      mkdir -p "$R$d"
      copy_bin "$d/$cmd" "$R$d/$cmd"
      break
    fi
  done
done

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

# Gritty node_modules
cp -r /usr/local/lib/node_modules/gritty $R/usr/local/lib/node_modules/
ln -sf /usr/local/lib/node_modules/gritty/bin/gritty.js $R/usr/local/bin/gritty

# node-pty native addon shared lib deps
find $R/usr/local/lib/node_modules -name "*.node" | while read addon; do
  ldd "$addon" 2>/dev/null | grep -oE '/[^ ]+' | while read lib; do
    [ -f "$lib" ] || continue
    d=$(dirname "$lib")
    mkdir -p "$R$d"
    cp -Ln "$lib" "$R$lib" 2>/dev/null || true
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

# Minimal /etc
echo 'root:x:0:0:root:/root:/bin/bash' > $R/etc/passwd
echo 'nobody:x:65534:65534:nobody:/nonexistent:/bin/false' >> $R/etc/passwd
echo 'root:x:0:' > $R/etc/group
echo 'nobody:x:65534:' >> $R/etc/group
echo 'hosts: files dns' > $R/etc/nsswitch.conf

# Writable temp dirs
chmod 1777 $R/tmp $R/var/tmp

# Claude wrapper script
cat > $R/usr/local/bin/claude << 'WRAPPER'
#!/bin/sh
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_TMP_HOME="/tmp/claude-home"
if [ ! -w "$HOME" ]; then
  export HOME="$CLAUDE_TMP_HOME"
fi
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/plugins" "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$SCRIPT_DIR:$PATH"
if [ ! -f "$HOME/CLAUDE.md" ]; then
  cp /opt/claude-skills/CLAUDE.md "$HOME/CLAUDE.md" 2>/dev/null || true
fi
if [ ! -f "$HOME/.claude/settings.json" ]; then
  cp /opt/claude-skills/settings.json "$HOME/.claude/settings.json" 2>/dev/null || true
fi
if [ ! -f "$HOME/.claude.json" ]; then
  cp /opt/claude-skills/claude.json "$HOME/.claude.json" 2>/dev/null || true
fi
exec "$SCRIPT_DIR/claude-bin" "$@"
WRAPPER
chmod +x $R/usr/local/bin/claude

# .bashrc
printf '# Claude Code agent shell\nexport CLAUDE_CODE_SKIP_PERMISSIONS_CONFIRMATION=1\n' \
  > $R/opt/claude-skills/.bashrc

# Entrypoint script
cat > $R/usr/local/bin/entrypoint.sh << 'ENTRY'
#!/bin/sh
CLAUDE_TMP_HOME="/tmp/claude-home"
if [ ! -w "$HOME" ]; then
  export HOME="$CLAUDE_TMP_HOME"
fi
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/plugins" "$HOME/.local/bin"
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export CLAUDE_CODE_SKIP_PERMISSIONS_CONFIRMATION=1
cp /opt/claude-skills/.bashrc "$HOME/.bashrc" 2>/dev/null || true
if [ ! -f "$HOME/CLAUDE.md" ]; then
  cp /opt/claude-skills/CLAUDE.md "$HOME/CLAUDE.md" 2>/dev/null || true
fi
if [ ! -f "$HOME/.claude/settings.json" ]; then
  cp /opt/claude-skills/settings.json "$HOME/.claude/settings.json" 2>/dev/null || true
fi
if [ ! -f "$HOME/.claude.json" ]; then
  cp /opt/claude-skills/claude.json "$HOME/.claude.json" 2>/dev/null || true
fi
exec /usr/local/bin/node /usr/local/lib/node_modules/gritty/bin/gritty.js --port 8080 --command /bin/bash
ENTRY
chmod +x $R/usr/local/bin/entrypoint.sh

echo "=== Rootfs stats ==="
du -sh $R
echo "Files: $(find $R -type f | wc -l)"
