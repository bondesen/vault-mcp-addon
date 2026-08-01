# Changelog

## 1.1.1 (2026-08-01)

**Fix: synken publicerede konflikter i stedet for at opdage dem.**

Hændelse 1/8-2026: `log.md` blev pushet til GitHub med `<<<<<<< Updated upstream` / `>>>>>>> Stashed changes` midt i filen.

Root cause: synk-løkken kørte

```
git pull --rebase --autostash
git add -A && git commit && git push
```

uden nogen kontrol imellem. Fejler autostash-pop'en (fordi arbejdstræet var beskidt da et fremmed commit kom ind), efterlader git konfliktmarkører i filen — og næste linje committer og pusher dem. Fejlen er lydløs og *fremadrettet*: hukommelsen bliver korrumperet, ikke blokeret.

Ændringer:

- **Konfliktmarkør-vagt:** før hver commit scannes sporede OG usporede `*.md` for `^<<<<<<< ` / `^>>>>>>> `. Findes der markører, stopper synken, larmer i add-on-loggen og skriver `/data/SYNC-BLOCKED`. Ingen commit, intet push, før markørerne er væk. `.obsidian/` udelades — minificeret plugin-JS indeholder lovligt `>>>>>>> `.
- **Mislykket pull afbryder nu rebase eksplicit** (`git rebase --abort`) i stedet for at falde igennem til commit/push med et halvt rebase-træ.
- Samme kontrol køres ved opstart, så en konflikt fra sidste kørsel ikke pushes ved genstart.

Designvalg: vagten **blokerer** frem for at forsøge automatisk oprydning. En blokeret synk er harmløs — indholdet ligger stadig på disken i `/data/vault` — mens et gæt på hvilken side af konflikten der var rigtig, kan smide skrevne noter væk uden spor.

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
