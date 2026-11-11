# Security model

## Assumptions (all treated as hostile until validated)
Model output; tool descriptions/annotations; tool results; MCP servers; plugins; imported skills; local endpoints; documents; remote providers.

## Controls and where they are tested
| Threat | Control | Code | Tests |
|---|---|---|---|
| Tool lies about being read-only | Risk comes only from the user registry; MCP annotations ignored; unknown ⇒ approval | `security/policy.py`, `mcp/bridge.py` | `test_mcp::test_mcp_tools_default_to_approval_required_even_if_server_says_readonly` |
| Approval reuse / confused deputy | Approval bound to SHA-256 of (tool,target,args), single-use, 5-min TTL | `PolicyEngine.authorize/resolve` | `test_security::test_approval_is_bound_single_use_and_action_specific` |
| Prompt injection via tool output/docs | Output fenced with per-call random nonce, flagged by heuristics, never grants permissions | `security/untrusted.py` | `test_security::test_fence_*`, `test_mcp::test_malicious_result_*` |
| Agent loops / runaway delegation | per-task budgets, identical-call breaker, depth + per-root task caps | `ExecutionBudget`, `AgentRuntime` | `test_security::test_loop_*`, `test_agents::test_delegation_*` |
| SSRF / metadata / LAN | `validate_endpoint`: loopback default, link-local always blocked, all resolved IPs checked (rebinding), https for remote, no URL creds, no redirects | `security/netguard.py`, `inference/http.py` | `test_security` (netguard), `test_discovery_*redirect*` |
| Malformed/hostile engines | Protocol-shape validation; open port ≠ valid service | `discovery/scanner.py` | `test_valid_json_of_wrong_shape_is_not_classified` (mutation-verified) |
| Shell injection | argv-only, allowlist, no shells/`env`/`sudo`, env filtered, cwd confined | `security/shell.py` | `test_security` (shell) |
| Path traversal / symlink escape | resolve-then-contain, sensitive dirs denied | `security/paths.py` | `test_path_traversal_and_symlink_escape` |
| Secret leakage | redaction in logs, audit, errors, traces; env filtering for children; secrets only in Keychain (Swift) | `security/redact.py`, `KeychainStore.swift` | `test_security` (redaction), `test_adapters::test_start_owns_process_*` |
| Memory poisoning | imports/web/tool content `unverified`; agents cannot self-confirm preferences | `memory/store.py` | `test_router_memory::test_export_*`, `test_agent_cannot_self_confirm_a_preference` |
| Local API abuse | loopback bind, per-launch 256-bit token, Host allowlist, Origin rejected | `api/server.py` | `test_api::test_auth_host_and_origin_guards` |
| Compromised plugin | per-plugin disable without touching others | `PolicyEngine.disable_plugin` | `test_disable_one_plugin_isolates_it_only` |

| Web search leaks data | consent-gated (off until allowed), only a short redacted query is sent, pinned host, https, no redirects, offline refuses, every search shown in chat | `tools/websearch.py`, `chat/orchestrator.py` | `test_websearch`, `test_orchestrator` (consent/redirect/redaction mutation-checked) |
| Tool tags smuggled in via search results/tool output | tags are parsed only from the model's own output; tool output is fenced and never parsed | `chat/orchestrator.py` | `test_search_results_containing_tags_are_never_executed` |
| Hallucinated or secret memories | model-written notes must overlap the user's words (else fallback to their text); secret-shaped text is never saved; saved notes are visible with Undo | `chat/orchestrator.py` | `test_memory_falls_back...`, `test_secrets_are_never_written_to_memory` |
| MCP file swapped after approval | approval = hash of runtime contents; any change revokes and disconnects | `mcp/manager.py` | `test_approval_survives_restart_but_not_a_file_swap` |
| Orphaned MCP processes | graceful shutdown on app exit and when the parent dies | `api/server.py` | `test_lifecycle_e2e` (real processes) |
| Hostile markdown in a model reply (XSS, image beacons, javascript: links) | raw HTML escaped, remote images never fetched (shown as links), only http(s)/mailto links, strict CSP (`default-src 'none'`, bundled scripts only, no network), all navigation blocked except user-clicked links which open in the browser | `apps/macos/Web/render.js`, `chat.html`, `MarkdownView.swift` | `Web/test/render.test.mjs` (jsdom; 5 security tests mutation-checked). **CSP enforcement itself is only asserted textually; jsdom doesn't enforce it** |
| Hostile or oversized uploads | 25 MB cap, binary sniffing, zip-bomb limits, no DTDs in Office XML, encrypted PDFs refused, work done in a thread with a 45 s timeout, global 100 MB request ceiling, bytes uploaded (never paths) | `files/extract.py`, `api/server.py` | `test_extract.py` (mutation-checked), `test_api.py` |
| Instructions hidden inside an attached file | file text is fenced as untrusted data, flagged by heuristics, never parsed for tool tags; never written to memory | `chat/attachments.py`, `chat/orchestrator.py` | `test_attachments.py` |
| Images sent to a model that can't use them | vision capability checked; images dropped with a visible notice; undetermined capability is disclosed | `chat/orchestrator.py` | `test_attachments.py`, `test_api.py` |

## Known gaps (not yet mitigated)
- No OS-level sandbox for plugin/skill code; Docker sandbox not implemented.
- Injection detection is heuristic; the real defence is the policy gate, not detection.
- Bridge token is passed by environment to a child we start; a same-user malicious process could read it from `ps -E`-class tooling. Unix-domain sockets with peer-credential checks are the planned hardening.
- Audit log is append-only by convention, not tamper-evident.
- pypdf is pure Python: a pathological PDF can burn CPU until the 45 s timeout (the worker thread cannot be killed).
- Attached file text is stored in plain text inside saved conversations (rely on FileVault).
- Sensitive-memory encryption at rest is not implemented (SQLite is plaintext; rely on FileVault).
- MCP env values/headers live in owner-only JSON files (0600), not the Keychain.
- A search query is model/rule-derived from your prompt; it is redacted for secret-shaped strings but could still contain personal details. It is always shown in the chat, and you can set web search to "Only when I say search" or off.
