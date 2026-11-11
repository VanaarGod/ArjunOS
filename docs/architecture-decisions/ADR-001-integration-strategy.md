# ADR-001: Integration strategy for Dodaios, OpenJarvis and local engines

Status: **superseded by ADR-002** (Dodaios/OpenJarvis integrations removed) · Date: 2026-10-27 · Based on inspection of upstream `main` (shallow clones) on that date.

## Findings from reconnaissance
| Item | Dodaios 4.1.1 | OpenJarvis (hatch-vcs) |
|---|---|---|
| License | Apache-2.0 (+ NOTICE, TRADEMARK.md) | Apache-2.0 |
| Python | >=3.11,<3.15 | >=3.10,<3.14 |
| CLI | `dodaios` (formerly `personal-jarvis`) | `jarvis`, `openjarvis-eval` |
| Default port | 47821 (UI + `/api/*`) | 127.0.0.1:8000 (`jarvis serve`) |
| Supported programmatic surface | `/api/health`; Control API `/api/control/*`; **Agent MCP server** `/api/control/mcp/agents` (Streamable HTTP, 24 tools, `read`/`work`/`full` scoped revocable tokens) | OpenAI-compatible `/v1/chat/completions`, `/v1/models`, `/v1/info`, `/health`, approvals routes; Bearer via `OPENJARVIS_API_KEY` |
| Config | `dodaios.toml` / `jarvis.toml` + env cascade | TOML via `OPENJARVIS_CONFIG` (explicit path supported) |
| Telemetry | none identified | optional PostHog analytics, **default off**, consent prompt on init |
| Secrets | OS keyring item `personal-jarvis`/`jarvis_control_api_key` | env / config |

## Conflicts identified
1. **Port 8000**: OpenJarvis's default equals vLLM's conventional port. Discovery therefore fingerprints (`/v1/info` keys `model/agent/engine`, `owned_by: "openjarvis"`) rather than trusting the port.
2. **Executable names**: Dodaios historically used `jarvis`-family names; OpenJarvis owns `jarvis`. We never create or shadow either command.
3. **Config/env namespaces**: Dodaios reads `JARVIS__*`/`jarvis.toml`; OpenJarvis reads `OPENJARVIS_*`. We pass only explicit, minimal env to children.
4. **Databases**: each keeps its own store. We do **not** attempt to merge them; JARVIS OS memory is its own SQLite DB and the frameworks are consumed through APIs (see below).
5. **Piper**: `rhasspy/piper` last commit 2025-08 ("development moved") → `OHF-Voice/piper1-gpl` is **GPL-3.0**. Only subprocess use is acceptable for an Apache-2.0 app.

## Decision
- **Dodaios → via its documented Agent MCP surface**, consumed by JARVIS OS's own MCP client and policy bridge. No fork, no private imports. Scope `work` recommended; governance tools (`kill_switch`, `approval_resolve`, `ecosystem_import`) are policy-BLOCKED for agents; spending tools need per-action approval. The user pastes a scoped token (we never read Dodaios's Keychain item).
- **OpenJarvis → as an OpenAI-compatible provider + CLI-detected process**, started only from an app-managed config (`OPENJARVIS_CONFIG`) with `analytics.enabled=false`. If an instance is already running we adopt it as *external* and never launch a duplicate or stop it.
- **Ollama / LM Studio / llama.cpp / vLLM** → native Ollama adapter + generic OpenAI-compatible adapter; discovery is loopback-only GET fingerprinting.
- **Memory, router, policy, agent registry/runtime are native** (Python bridge): both frameworks have their own, and syncing three memory stores was rejected as the fragile option. Their retrieval/memory remain available *through* their own APIs when the user chooses to call them.
- **Swift ↔ Python**: loopback HTTP + per-launch random bearer token + Host/Origin checks (streaming via SSE). Unix sockets considered; HTTP chosen for URLSession streaming simplicity. Revisit if the token model proves insufficient.

## Rejected / deferred
OpenClaw & Hermes Agent (MIT, very active): **defer** — overlap with Dodaios's runtimes; adding more agents that control the same browser/memory/scheduler needs an arbitration model first. LiteLLM: **defer** (no proxy needed; MIT with enterprise-directory carve-out). Playwright: **defer** to the computer-use phase, kept separate from native automation.

## Consequences
Positive: upgradable independently, no upstream patches, one policy gate. Negative: Dodaios agent features require the user to run Dodaios and mint a token; features are limited to what its MCP surface exposes.
