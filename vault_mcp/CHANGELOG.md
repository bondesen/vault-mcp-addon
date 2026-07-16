# Changelog

## 1.1.0 (2026-07-16)

**Fix: massiv RAM-læk** (5.58 GiB ved OOM-incident 16/7; 3.85 GiB igen ~12 timer efter genstart).

Root cause (verificeret i supergateway 3.4.3-kildekoden):

- Uden `--stateful` kørte supergateway i *stateless* mode: ny `npx → node → mcpvault`-proces for **hver eneste HTTP-request**, og transporten lukkes aldrig ved response-afslutning.
- `spawn(cmd, {shell: true})` + `child.kill()` dræber kun `sh`-wrapperen — node-børnebørnene blev forældreløse og beholdt hele vaulten i RAM.

Ændringer:

- `--stateful --sessionTimeout 1800000`: én mcpvault-proces pr. MCP-session (genbrugt på tværs af requests), reapes efter 30 min inaktivitet. Klienter med åben SSE-stream berøres ikke.
- `exec mcpvault /data/vault` direkte i stedet for `npx -y @bitbonsai/mcpvault`: to færre node-processer pr. spawn, og SIGTERM rammer nu selve mcpvault-processen.
- Orphan-reaper i run.sh: dræber forældreløse mcpvault-processer (PPid 1) hvert 5. minut som bagstopper.
- `--healthEndpoint /healthz` + Supervisor-watchdog i config.yaml.
- Pinnede versioner: `supergateway@3.4.3`, `@bitbonsai/mcpvault@0.11.0`.

## 1.0.0

- Første version: mcpvault bag supergateway (Streamable HTTP), git-synk, secret path-auth.
