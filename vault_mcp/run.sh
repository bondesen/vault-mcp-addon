#!/usr/bin/env bash
set -euo pipefail

OPTS=/data/options.json
GIT_URL=$(jq -r '.git_url' "$OPTS")
DEPLOY_KEY_B64=$(jq -r '.deploy_key' "$OPTS")
SECRET_PATH=$(jq -r '.secret_path' "$OPTS")
SYNC_MIN=$(jq -r '.sync_interval_minutes' "$OPTS")
GIT_NAME=$(jq -r '.git_user_name' "$OPTS")
GIT_EMAIL=$(jq -r '.git_user_email' "$OPTS")

# ── Sikkerhedsvagter: nægt at starte halvt konfigureret ─────────────────────
if [ -z "$DEPLOY_KEY_B64" ] || [ "$DEPLOY_KEY_B64" = "null" ]; then
  echo "[vault-mcp] FEJL: deploy_key er tom. Se README. Nægter at starte." >&2
  exit 1
fi
if [ -z "$SECRET_PATH" ] || [ "$SECRET_PATH" = "null" ] || [ "${#SECRET_PATH}" -lt 16 ]; then
  echo "[vault-mcp] FEJL: secret_path mangler eller er under 16 tegn. Nægter at starte." >&2
  exit 1
fi
case "$SECRET_PATH" in */*|*\ *) echo "[vault-mcp] FEJL: secret_path må ikke indeholde / eller mellemrum." >&2; exit 1;; esac

# ── SSH-nøgle ────────────────────────────────────────────────────────────────
mkdir -p /data/ssh
echo "$DEPLOY_KEY_B64" | base64 -d > /data/ssh/id_vault
chmod 600 /data/ssh/id_vault
export GIT_SSH_COMMAND="ssh -i /data/ssh/id_vault -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/data/ssh/known_hosts"

# ── Klon/opdatér vault ──────────────────────────────────────────────────────
if [ ! -d /data/vault/.git ]; then
  echo "[vault-mcp] Kloner $GIT_URL ..."
  git clone "$GIT_URL" /data/vault
else
  git -C /data/vault pull --rebase --autostash || echo "[vault-mcp] ADVARSEL: pull fejlede ved opstart" >&2
fi
git -C /data/vault config user.name "$GIT_NAME"
git -C /data/vault config user.email "$GIT_EMAIL"

# ── Baggrunds-synk ───────────────────────────────────────────────────────────
(
  while true; do
    sleep "$((SYNC_MIN * 60))"
    cd /data/vault || continue
    git pull --rebase --autostash --quiet || echo "[vault-mcp] synk: pull fejlede" >&2
    if [ -n "$(git status --porcelain)" ]; then
      git add -A
      git commit -m "auto-synk fra vault-mcp $(date +%F' '%H:%M)" --quiet || true
    fi
    git push --quiet || echo "[vault-mcp] synk: push fejlede" >&2
  done
) &

# ── Orphan-reaper (bagstopper mod RAM-læk) ───────────────────────────────────
# supergateway spawner mcpvault via 'sh -c'. Skulle en mcpvault-proces blive
# forældreløs (PPid 1) — fx hvis kill kun rammer wrapperen — dræbes den her.
# supergateways egen cmdline indeholder også 'mcpvault', så den ekskluderes
# eksplicit. Kører hvert 5. minut.
(
  while true; do
    sleep 300
    for status in /proc/[0-9]*/status; do
      pid="${status#/proc/}"; pid="${pid%/status}"
      ppid=$(sed -n 's/^PPid:[[:space:]]*//p' "$status" 2>/dev/null) || continue
      [ "$ppid" = "1" ] || continue
      cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || continue
      case "$cmdline" in
        *supergateway*) continue ;;
        *mcpvault*)
          echo "[vault-mcp] Reaper: dræber forældreløs mcpvault-proces $pid: $cmdline" >&2
          kill -9 "$pid" 2>/dev/null || true
          ;;
      esac
    done
  done
) &

# ── MCP-server bag secret path ───────────────────────────────────────────────
# VIGTIGT (RAM-læk-fix, 2026-07-16):
# - --stateful: uden denne kører supergateway stateless og spawner en ny
#   mcpvault-proces PR. REQUEST — de blev aldrig ryddet op → GiB-læk.
# - --sessionTimeout: reap sessioner (og deres child-proces) efter 30 min
#   uden aktivitet. Klienter med åben SSE-stream holdes i live.
# - 'exec mcpvault' direkte (IKKE 'npx -y ...'): npx lagde to ekstra node-
#   processer oven i pr. spawn, og child.kill() ramte kun sh-wrapperen.
#   exec erstatter sh, så SIGTERM rammer selve mcpvault.
echo "[vault-mcp] Starter: port 8100, endpoint /<secret>/mcp, synk hvert ${SYNC_MIN}. minut, stateful sessions (timeout 30 min)"
exec supergateway \
  --stdio "exec mcpvault /data/vault" \
  --outputTransport streamableHttp \
  --stateful \
  --sessionTimeout 1800000 \
  --port 8100 \
  --streamableHttpPath "/${SECRET_PATH}/mcp" \
  --healthEndpoint /healthz \
  --logLevel info
