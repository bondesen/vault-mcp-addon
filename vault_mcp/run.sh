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
# BatchMode=yes (1.1.2): en SSH-prompt (host-key/auth) i en container uden TTY
# hænger for evigt og trak historisk hele MCP-processen med sig (se hændelse-
# 2026-08-12-noten, Fejl 3). Med BatchMode fejler den kontant i stedet.
export GIT_SSH_COMMAND="ssh -i /data/ssh/id_vault -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/data/ssh/known_hosts -o BatchMode=yes -o ConnectTimeout=10"

# ── Konfliktmarkør-vagt (1.1.1) ─────────────────────────────────────────────
# BAGGRUND (1/8-2026): 'git pull --rebase --autostash' efterlader konflikt-
# markører i arbejdstræet når autostash-pop'en fejler. Den gamle synk-løkke
# kørte derefter 'git add -A && git commit && git push' UDEN kontrol — en
# konflikt blev altså ikke opdaget, den blev PUBLICERET. Det skete for log.md
# og nåede GitHub, før det blev fanget i hånden.
#
# Vagten scanner sporede OG usporede markdown-filer for konfliktmarkører i
# starten af en linje. .obsidian/ udelades (plugin-kildekode indeholder
# lovligt '>>>>>>> ' i minificeret JS, og mappen er ikke vault-indhold).
# Findes der markører: STOP synken, larm i loggen, og rør ikke repoet igen
# før mennesket har ryddet op. En blokeret synk er harmløs — data ligger
# stadig på disken; en publiceret konflikt korrumperer hukommelsen.
konflikt_filer() {
  git -C /data/vault grep -I -l --untracked -E '^(<<<<<<< |>>>>>>> )' -- '*.md' 2>/dev/null \
    | grep -v '^\.obsidian/' || true
}

synk_blokeret() {
  local f
  f=$(konflikt_filer)
  if [ -n "$f" ]; then
    echo "[vault-mcp] SYNK BLOKERET: konfliktmarkører fundet — committer og pusher IKKE." >&2
    echo "$f" | sed 's/^/[vault-mcp]   /' >&2
    echo "[vault-mcp] Ryd op i /data/vault (fjern markørerne), så genoptages synken automatisk." >&2
    date -Iseconds > /data/SYNC-BLOCKED
    return 0
  fi
  rm -f /data/SYNC-BLOCKED
  return 1
}

# ── Utracked/ændret indhold før pull (1.1.2) ─────────────────────────────────
# BAGGRUND (23/8-2026): MCP-skrivninger (write_note/patch_note) rammer disken
# med det samme, men bliver først committet ved næste synk-cyklus. Kommer der
# i mellemtiden et remote-commit der rører SAMME sti (fx en anden skribent på
# .30), nægter git at pulle overhovedet:
#
#   error: The following untracked working tree files would be overwritten
#   by merge. Please move or remove them before you merge.
#
# Fordi dette historisk kunne ramme opstarts-pull'et (som kun kører ÉN gang,
# ikke i baggrundsløkken), sad synken permanent fast efter en genstart, uden
# retry, indtil et menneske SSH'ede ind og flyttede filen manuelt.
#
# Fix: commit alt lokalt (tracked + untracked) FØR hver pull, så stien altid
# er tracked når git rebaser. Tre udfald, alle uden manuel indgriben for at
# holde synken kørende:
#   - Ingen reel indholdskollision → stille, automatisk rebase/fast-forward.
#   - Identisk indhold begge steder → "Already up to date", ingen konflikt.
#   - Reel indholdsdivergens (to skribenter, samme sti, forskelligt indhold)
#     → normal add/add-konflikt under rebase. Løkkens eksisterende
#     "pull fejlede → rebase --abort" fanger den: synken springer roligt
#     denne runde over og prøver igen om ${SYNC_MIN} minutter. Det er
#     bevidst IKKE auto-løst — at gætte hvilken side der vinder kan smide en
#     skrevet note væk uden spor (samme designvalg som 1.1.1-vagten ovenfor).
#     Verificeret i sandkasse-test 23/8-2026 (se PR).
commit_lokale_ændringer() {
  git -C /data/vault add -A
  if ! git -C /data/vault diff --cached --quiet; then
    git -C /data/vault commit -m "auto-commit før synk $(date +%F' '%H:%M)" --quiet
  fi
}

# ── Redningsgren (1.1.3, 3/10-2026) ─────────────────────────────────────────
# Fejler pull/rebase (indholdskonflikt med GitHub), skubbes den lokale historik til
# grenen 'ha-ikke-synket' på GitHub, så intet KUN ligger i add-on'et, og så fejlen
# kan ses udefra (git branch -r) i stedet for kun i add-on-loggen.
# Baggrund: 16/8 → 2/10-2026 levede HA-kopien og GitHub hver sit liv i 1½ måned,
# fordi hver runde blot afbrød rebasen og prøvede igen 15 minutter senere.
# Fletning sker manuelt (fx fra .30); derefter fast-forwarder næste runde af sig selv.
skub_til_redningsgren() {
  if git -C /data/vault push --force --quiet origin HEAD:refs/heads/ha-ikke-synket; then
    echo "[vault-mcp] lokal historik skubbet til grenen 'ha-ikke-synket' på GitHub — skal flettes ind i main" >&2
  else
    echo "[vault-mcp] kunne heller ikke skubbe til grenen 'ha-ikke-synket'" >&2
  fi
  date -Iseconds > /data/SYNC-DIVERGED
}

# ── Klon/opdatér vault ──────────────────────────────────────────────────────
if [ ! -d /data/vault/.git ]; then
  echo "[vault-mcp] Kloner $GIT_URL ..."
  git clone "$GIT_URL" /data/vault
  git -C /data/vault config user.name "$GIT_NAME"
  git -C /data/vault config user.email "$GIT_EMAIL"
else
  git -C /data/vault config user.name "$GIT_NAME"
  git -C /data/vault config user.email "$GIT_EMAIL"
  commit_lokale_ændringer
  git -C /data/vault pull --rebase --autostash || {
    echo "[vault-mcp] ADVARSEL: pull fejlede ved opstart — afbryder evt. halv rebase" >&2
    git -C /data/vault rebase --abort 2>/dev/null || true
    skub_til_redningsgren
  }
fi
synk_blokeret && echo "[vault-mcp] ADVARSEL: konflikt allerede til stede ved opstart — synk starter blokeret." >&2

# ── Baggrunds-synk ───────────────────────────────────────────────────────────
(
  while true; do
    sleep "$((SYNC_MIN * 60))"
    cd /data/vault || continue
    commit_lokale_ændringer
    if ! git pull --rebase --autostash --quiet; then
      echo "[vault-mcp] synk: pull/rebase fejlede — afbryder rebase og springer denne runde over" >&2
      git rebase --abort 2>/dev/null || true
      skub_til_redningsgren
      continue
    fi
    rm -f /data/SYNC-DIVERGED
    synk_blokeret && continue
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
echo "[vault-mcp] Starter: port 8100, endpoint /<secret>/mcp, synk hvert ${SYNC_MIN}. minut, stateful sessions (timeout 30 min), konfliktmarkør-vagt aktiv"
exec supergateway \
  --stdio "exec mcpvault /data/vault" \
  --outputTransport streamableHttp \
  --stateful \
  --sessionTimeout 1800000 \
  --port 8100 \
  --streamableHttpPath "/${SECRET_PATH}/mcp" \
  --healthEndpoint /healthz \
  --logLevel info
