# ADR-002: Remove the Dodaios/OpenJarvis integrations; one JSON file per MCP server

Status: accepted · Supersedes the Dodaios/OpenJarvis parts of ADR-001.

## Context
The Dodaios and OpenJarvis adapters were tested only against test doubles, added a second configuration surface
(tokens, scopes, managed processes) and a "Plugins" idea the app could not actually deliver. The owner asked for a simpler
product: local models + MCP + a few built-in tools.

## Decision
- Delete both adapters, their process manager, tests, API endpoint, UI cards and fixtures. JARVIS OS talks to model engines
  (Ollama and OpenAI-compatible servers) and to MCP servers directly. Anyone who runs Dodaios or OpenJarvis can still add them as an
  OpenAI-compatible endpoint, or Dodaios' MCP URL as an ordinary MCP server file; nothing is special-cased.
- MCP: **one JSON file per server** in `<state>/mcp/<name>.json` (stdio: `command/args/env`; remote: `url/headers`).
  Approval is bound to the file's runtime contents (a SHA-256 of command/args/env/cwd/url/headers); editing them revokes approval and
  disconnects. Files are written atomically and owner-only. Names are normalized (no path traversal). A pasted `{"mcpServers": {...}}`
  block is split into one file per server, atomically (all or nothing).
- Models use tools through a plain-text tag protocol (`<search>`, `<recall>`, `<tool name=...>`) driven by the bridge, so it works on
  any local model, not only those with native tool-calling. The bridge also triggers some searches itself (explicit "search ..." and
  time-sensitive questions) and writes memories when the user says "remember".

## Consequences
+ Less surface area, nothing to keep in sync with two fast-moving upstream projects. 
- Small models may follow the tag protocol unreliably; rule-based triggers cover the common cases. Model behavior against real
  models is unverified (see implementation-status.md).
- MCP credentials live in owner-only JSON files, not the Keychain (planned).
