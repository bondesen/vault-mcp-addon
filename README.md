# Vault MCP — Home Assistant add-on

Eksponerer en Obsidian-vault (git-repo) som MCP-server på LAN via Streamable HTTP,
så VS Code, GitHub Copilot og andre MCP-klienter kan læse/skrive noter 24/7 —
uafhaengigt af om andre maskiner sover. Bygget på [@bitbonsai/mcpvault](https://github.com/bitbonsai/mcpvault)
(direkte filadgang, ingen Obsidian-app) bag [supergateway](https://github.com/supercorp-ai/supergateway)
(stdio → Streamable HTTP). Egen klon + git-synk mod GitHub.

## Installation

1. Indsæt dette repo som add-on-repository i HA: Indstillinger → Apps → ⋮ → Repositories →
   `https://github.com/bondesen/vault-mcp-addon`
2. Installér **Vault MCP**.

## Konfiguration (FØR start)

### deploy_key (base64)

Add-on'et skal bruge en deploy key med skriveadgang til vault-repoet:

```bash
ssh-keygen -t ed25519 -N "" -C "vault-mcp-addon" -f /tmp/vault_mcp_key
cat /tmp/vault_mcp_key.pub    # → GitHub → vault-repo → Settings → Deploy keys → Add (Allow write access)
base64 < /tmp/vault_mcp_key | tr -d '\n'   # → indsæt som deploy_key i add-on-config
rm /tmp/vault_mcp_key /tmp/vault_mcp_key.pub
```

### secret_path

```bash
openssl rand -hex 16   # → indsæt som secret_path
```

Endpointet bliver: `http://<HA-IP>:8100/<secret_path>/mcp`

**Add-on'et nægter at starte** hvis deploy_key eller secret_path mangler, eller hvis
secret_path er under 16 tegn — ingen åbne endpoints ved en fejl.

## Klient-eksempler

**VS Code** (`mcp.json` — bemærk `servers`):
```json
{ "servers": { "vault": { "type": "http", "url": "http://192.168.1.10:8100/<secret_path>/mcp" } } }
```

**GitHub Copilot** (`mcpServers`):
```json
{ "mcpServers": { "vault": { "type": "http", "url": "http://192.168.1.10:8100/<secret_path>/mcp" } } }
```

(Klient-formater varierer — nogle bruger `url`-nøglen direkte, andre kræver `type`.)

## Sikkerhed

- KUN LAN: port-forward ALDRIG 8100. Auth er secret-path (samme model som ha-mcp).
- Deploy key er scoped til ét repo. Trafikken er HTTP på eget LAN — accepteret trussel.
- Synk: pull/commit/push hvert N minutter (option), rebase+autostash — markdown-konflikter
  er sjældne og løses i git.

## Versionsdisciplin

HA cacher images pr. config.yaml-version — **bump `version` ved ENHVER ændring**, ellers
rebuilder Supervisor ikke.
