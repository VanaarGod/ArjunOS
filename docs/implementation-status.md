# Implementation status

Legend — **Verified**: automated test run against real code over real sockets/processes · **Mock**: tested against a test double, not the real third-party service · **Unbuilt**: written, never compiled/run · **Missing**.

Last Python run: `343 passed in 21.98s`. Last renderer run (Node + jsdom): `# pass 20 # fail 0`. Swift: the core layer (`JarvisCore`) compiled on the author's Mac earlier; **everything added since (reducer, new models/client calls, the whole redesigned UI, MCP screen, settings) has only been syntax-checked** with tree-sitter, not type-checked or run.

## Python bridge (`services/python`)
| Area | State | Evidence / limits |
|---|---|---|
| Secret redaction, audit log, network guard, policy engine, path/shell/untrusted guards | Verified | adversarial tests; redaction no longer masks token *counts* |
| Endpoint discovery & fingerprinting | **Mock** | real HTTP vs mock Ollama/OpenAI servers; not live Ollama/LM Studio. Safety tests mutation-checked |
| Ollama + OpenAI-compatible providers (streaming, usage, auth) | **Mock** | |
| Model router, memory store (FTS5, provenance, conflicts, isolation, stopword-gated retrieval) | Verified | no real embedding model wired; no encryption at rest |
| MCP client (stdio + Streamable HTTP, cancel, pagination, lifecycle) | Verified/Mock | real stdio test server; HTTP is a mock; no legacy SSE, no OAuth |
| **MCP per-file manager** (files, approval-bound-to-contents, trust, live approval wait) | Verified | real stdio server; security properties mutation-checked |
| **Chat orchestrator** (rule-triggered search, model-requested tags, remember, recall, MCP calls, round limits) | Verified vs a **scripted fake model** | behavior with real small models is **unverified** |
| **DuckDuckGo search** (consent, redaction, host pin, redirects, offline) | Verified vs a **synthetic** page | **never run against the live site**; markup/rate-limit changes will surface as a clear error. Use Settings → Test web search |
| Settings store, consent flow | Verified | |
| Agents (9 roles, hierarchy, assignment, delegation limits, traces) | Verified | fake streamer; one mock-Ollama run via API |
| Local API v1, parent-death shutdown, startup reconnect | Verified | incl. a real-process test: approved MCP server reconnects on launch; no orphaned child after the parent dies |
| Scheduler, plugin/skills manager, STT/TTS, embeddings, browser/computer use, hardware profiling, cost telemetry | **Missing** | |

## Markdown / math renderer (`apps/macos/Web`)
| Area | State | Evidence / limits |
|---|---|---|
| marked + KaTeX + `render.js`: tables, headings, lists, code + Copy, `$..$` `$$..$$` `\(..\)` `\[..\]` `\begin{align}`, currency not mistaken for math, single `~` never strikes text, streaming-safe | Verified (real libraries in jsdom) | 20 tests; rendering in a *real WebKit view* is **unverified** |
| Security: raw HTML escaped, remote images blocked, only http(s)/mailto links, strict CSP, navigation blocked | Verified for the JS; CSP/navigation **not enforced by jsdom** | CSP text asserted; WKWebView policy code is Unbuilt |

## File attachments
| Area | State | Evidence / limits |
|---|---|---|
| Extraction: text/code/HTML, PDF (pypdf), DOCX, XLSX; binary/encrypted/zip-bomb/DTD refusal; truncation reporting | Verified with generated real files (hand-built PDF, DOCX, XLSX, encrypted PDF) | 34 tests, mutation-checked. Not tested on messy real-world files (complex layouts, odd encodings) |
| Budgeted context: fair split across files, relevance excerpts (FTS5), "read in full / excerpts" disclosure, history files kept, fenced as untrusted | Verified | 18 tests, mutation-checked; answer quality with real models unverified |
| Images: vision gating (dropped with notice when unsupported), Ollama `images` + OpenAI-style parts | Verified vs mock Ollama; OpenAI-style image parts untested against a real server | |
| Upload API (415/422/413, audit without content) | Verified | |
| Swift: attach button, drag-and-drop, chips, image downscaling (ImageIO), sent-message chips | Unbuilt; core encoding/decoding + reducer tests written | |
| OCR for scans, PowerPoint, legacy Office, paste-image-from-clipboard, folders | **Missing** | |

## Swift app (`apps/macos`) — Unbuilt unless stated
| Area | State |
|---|---|
| JarvisCore: models, BridgeClient (+SSE), supervisor, Keychain, ConversationStore | compiled earlier; additions unbuilt |
| ChatReducer (event → message activity) | Unbuilt; unit tests written (+ contract tests decoding real API fixtures) |
| UI: glass sidebar/history, greeting + binary field, glass composer, activity chips (search sources, memory saved + Undo, tool calls), consent banner, inline approvals, Models, Agents, MCP Servers (one card per file, editor sheet), Memory, Tasks, System, Settings (web search, memory) | Unbuilt, syntax-checked only |
| Packaging (`scripts/package.sh`: .app, bundled bridge, icon, ad-hoc signature, DMG) | script only `bash -n` checked; icon generator visually verified |
| Voice, Knowledge | honest "not implemented" screens |
| Global shortcut, quick overlay, palette, launch-at-login, setup wizard, notifications, drag-and-drop, light mode, attachments | **Missing** |

## Known defects / risks
- Whether small local models follow the `<search>`/`<recall>`/`<tool>` tag protocol is untested; rule-based triggers (explicit "search", time-sensitive words, "remember") do not depend on it.
- The auto-search heuristic can fire on questions that don't need it (e.g. any prompt containing "news" or "today"); it is always visible and can be limited to "only when I say search".
- DuckDuckGo may rate-limit or change its HTML; the app reports it rather than inventing results.
- Token usage excludes a tool round that was cut off at the closing tag.
- MCP credentials sit in owner-only JSON files (0600), not the Keychain.
- SwiftUI/Liquid Glass/WebKit code was never type-checked here: expect first-compile fixes.
- The chat renders each assistant message in its own web view; very long conversations rely on lazy loading plus a height cache. Untested at scale.
- Context window: local models may silently drop the start of long prompts. The file budget (Settings → Files) is the control; there is no per-model window detection yet.

## Next steps
1. Compile and run on a Mac; fix errors. 2. Run against your real Ollama model; check the tag protocol and the search \"Test\" button against live DuckDuckGo. 3. Keychain-backed MCP secrets. 4. whisper.cpp / Piper subprocess providers. 5. Scheduler. 6. Setup wizard, global shortcut, launch-at-login.
