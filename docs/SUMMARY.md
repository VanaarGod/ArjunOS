# JARVIS OS — what has been built, how, and what is missing

*State as of 30 Oct 2026. Written to be honest about what is verified versus merely written.*

## 0. Reading this document

Every claim carries one of these labels:

| Label | Meaning |
|---|---|
| **Verified** | An automated test exercises the real code (real sockets, real subprocesses, real files). |
| **Mock** | Tested against a test double that imitates a third-party service (Ollama, DuckDuckGo, an MCP server), never the real thing. |
| **Observed** | You ran it on your Mac and showed me a screenshot or output. |
| **Unbuilt** | Written, but never compiled or run by me. Where you ran the app, the Swift compiled; I say so. |
| **Missing** | Not implemented. |

---

## 1. What JARVIS OS is today

A **local-first personal AI assistant for macOS**: a native SwiftUI app talking to a small Python "bridge" process over loopback. It chats with models you already run locally (Ollama, or any OpenAI-compatible server), and gives them a few carefully gated abilities: web search, memory, file reading, MCP tools. Nothing leaves your Mac except web searches you have allowed.

It is **not** the full "personal AI operating system" from the original brief. Roughly: the chat core, model discovery, safety layer, memory, MCP, web search, file attachments and the interface are real. Voice, scheduling, plugins/skills, a setup wizard, computer-use automation, knowledge-base indexing and cloud providers are not built (section 9).

### Observed on your machine
- The app builds, launches, and shows the glass UI (screenshots).
- It discovered Ollama and the model `qwen3.5:9b`, and chats with it.
- Web search works ("search for the best gpu" produced two visible searches with sources).
- Conversation history persists across restarts (Oct 27 / Oct 28 chats in the sidebar).
- The file-attach UI works (a chip with a warning appeared); PDF reading failed because the app's Python lacked `pypdf` and the scripts did not look for Python 3.14. You fixed it by installing `pypdf` into the Python 3.14 environment. The scripts now search 3.15 down to 3.11 (see section 11).
- The Python test suite passed on your Mac (183 tests at that time; the suite has since grown to 345).

---

## 2. Status at a glance

| Area | Status | Notes |
|---|---|---|
| Native app shell, navigation, glass UI | Observed | Dark-first; Liquid Glass on macOS 26+, frosted material on 14–25 |
| Chat with streaming | Observed | Real local model |
| Model discovery (Ollama + OpenAI-compatible) | Observed (Ollama) / Mock (others) | Loopback only |
| Web search (DuckDuckGo) | Observed | Parser tested against a synthetic page; works live per your screenshot |
| Memory ("remember …") | Verified; not yet reported by you | SQLite + FTS5 |
| Attach files (text, PDF, Word, Excel, images) | Verified (bridge); UI Observed to load | PDF path was blocked by the Python-environment issue, now resolved on your machine |
| Markdown + math rendering | Verified in jsdom; not yet seen by you in WebKit | KaTeX + marked, bundled |
| MCP servers (one JSON file each) | Verified with a real stdio server | UI written; you have not reported using it |
| Agents (9 roles, hierarchy, delegation limits) | Verified at API level | UI exists; no real multi-agent run observed |
| Safety layer (approvals, redaction, network guard…) | Verified | 56 dedicated tests plus others |
| Packaging (.app + .dmg) | Observed to build and run | Ad-hoc signed, not notarized |
| Voice (STT/TTS) | Missing | |
| Scheduler, plugins/skills, setup wizard, quick overlay, global shortcut | Missing | |
| Knowledge base / folder indexing | Missing | Attach files in chat instead |
| Cloud providers | Missing (deliberately blocked) | |

---

## 3. Architecture

```
┌──────────────────────────── macOS ────────────────────────────┐
│  Jarvis OS.app  (SwiftUI)                                      │
│   • UI, conversations (JSON files), Keychain wrapper           │
│   • starts/owns ONE child process, never anything else         │
│        │  http://127.0.0.1:<random port>   (loopback only)     │
│        │  Authorization: Bearer <random per-launch token>      │
│        ▼                                                       │
│  jarvis_bridge  (Python, FastAPI)                              │
│   discovery → providers → orchestrator → tools                 │
│   memory · MCP manager · agents · files · settings · audit     │
│        │                    │                    │             │
│        ▼                    ▼                    ▼             │
│  Ollama / OpenAI-   MCP servers (child     DuckDuckGo          │
│  compatible servers  processes or HTTPS)   (queries only,      │
│  (127.0.0.1)                                with consent)      │
└────────────────────────────────────────────────────────────────┘
```

**Why two languages.** Swift gives a native app; Python has the mature libraries (PDF parsing, SQLite FTS, MCP, HTTP). The seam is a versioned HTTP API (`/v1/...`).

**Process ownership.** The app starts the bridge with a minimal environment (it does not inherit your shell secrets), passes `--parent-pid`, and stops it on quit. If the app dies, the bridge notices within about 2 seconds, shuts down gracefully, and takes its MCP child processes with it (**Verified** with real processes).

### Life of one chat message
1. You type; the app sends the conversation (plus any attachments) to `POST /v1/chat`.
2. **Remember?** If you said "remember …", the model writes a short note, which is saved.
3. **Memory:** notes that genuinely match your question are offered to the model.
4. **Files:** attached text is split fairly across files and cut to the most relevant excerpts; images go only to vision models.
5. **Web search:** if you said "search for …" or the question is time-sensitive, a short query goes to DuckDuckGo (if you consented).
6. The model replies. If it starts its reply with a tool tag (`<search>`, `<recall>`, `<tool …>`), the bridge runs that tool, feeds back the result, and lets the model continue (max 3 rounds).
7. Everything the assistant did streams back as events (search, memory, files, tool calls, approvals) so the chat can show it.
8. The reply is rendered as markdown/math in a sandboxed web view.

---

## 4. Repository structure

```
jarvis-os/
├─ README.md  LICENSE (Apache-2.0)  NOTICE
├─ docs/
│   ├─ implementation-status.md     per-item verified/mock/unbuilt table
│   ├─ security.md                  threat model → control → code → test
│   ├─ mcp.md                       MCP file format and workflow
│   ├─ integration-matrix.md        candidate projects: license, decision
│   └─ architecture-decisions/      ADR-001 (superseded), ADR-002
├─ scripts/
│   ├─ setup.sh      build the Python environment (searches 3.15 → 3.11), verifies imports
│   ├─ doctor.sh     read-only environment report
│   ├─ test.sh       Python + renderer + Swift tests
│   ├─ package.sh    build Jarvis OS.app and the .dmg
│   ├─ build.sh  gen_fixtures.py  make_icon.py
├─ services/python/src/jarvis_bridge/            (~3,850 lines)
│   ├─ security/    redact, netguard, policy, audit, paths, shell, untrusted     558
│   ├─ discovery/   endpoint scanner and fingerprinting                          189
│   ├─ inference/   base contracts, Ollama + OpenAI-compatible providers, router 500
│   ├─ memory/      SQLite + FTS5 store                                          324
│   ├─ mcp/         client (stdio + HTTP), policy bridge, per-file manager       699
│   ├─ chat/        orchestrator (tools loop), attachment context                421
│   ├─ tools/       DuckDuckGo search + the "when to search" rules               175
│   ├─ files/       text/PDF/DOCX/XLSX extraction                                230
│   ├─ agents/      registry + runtime (9 roles)                                 244
│   ├─ api/         FastAPI server (v1)                                          439
│   └─ settings.py  persisted settings
├─ services/python/tests/                         345 tests, 13 files
├─ apps/macos/                                    (~2,860 lines Swift)
│   ├─ Package.swift
│   ├─ Sources/JarvisCore/   models, BridgeClient (+SSE), supervisor, Keychain,
│   │                        ConversationStore, ChatReducer          (827)
│   ├─ Sources/JarvisOS/     the SwiftUI app: AppModel, ChatScreen, Sidebar, Models,
│   │                        MCP, Memory, Agents, Settings, attachments,
│   │                        MarkdownView, DesignSystem            (2,033)
│   ├─ Tests/JarvisCoreTests/  40 tests (contract, client, reducer, store)
│   └─ Web/                  bundled marked + KaTeX + render.js (+ 20 Node tests)
└─ dist/                     (created by package.sh) Jarvis OS.app, .dmg
```

### Where your data lives
- `~/Library/Application Support/JarvisOS/state/` — `memory.db`, `agents.db`, `audit.db`, `settings.json`, `mcp/*.json`, `mcp_state.json`
- `~/Library/Application Support/JarvisOS/conversations/*.json` — one file per chat (attachments included)
- `~/Library/Application Support/JarvisOS/venv/` — the bridge's Python environment

Backup = copy that folder. Uninstall = delete it.

---

## 5. The pieces in detail

### 5.1 The app (SwiftUI)
- **Layout from your Dodaios screenshot:** a floating glass sidebar (search, New chat, Agents, Models, MCP Servers, Memory, Voice "soon", More → Knowledge/Tasks/System, date-grouped history, user footer with bridge status), a centered orb and greeting over a faint animated 0/1 field, and a glass composer.
- **Composer:** `+` menu (attach files, new chat, temporary chat that is never saved), model menu, "Ask before acting" label, send/stop, drag-and-drop with a visible drop zone, attachment chips with image thumbnails.
- **Activity chips under answers:** searches (expandable sources), tool calls, "Saved to memory" with **Undo**, "Used N memories", "Read N files" with excerpt disclosure, notices.
- **Inline approvals** for tool calls and a one-time **web-search permission** banner.
- **Menu bar item**; window forces itself frontmost (fixes the "can't type" problem of bare `swift run`).
- **Models screen:** "Connected to Ollama" banner, providers, models with capability chips (unknown capabilities show `?`, never a guess), default-model selection.
- **Auto-connect:** rescans loopback every 6 seconds; keeps your last-used model, else the first chat model (embedding models skipped).
- Text inputs share one neat glass style; **dark only** for now.

### 5.2 The bridge API
Loopback bind, per-launch 256-bit token, `Host` allow-list (DNS-rebinding defense), browser `Origin` rejected, 100 MB request ceiling. Endpoints (all under `/v1`): `health`, `providers` (+scan, add/remove), `models`, `chat` (SSE), `memory` (+search/confirm/delete/stats), `approvals`, `audit`, `agents` (+tree, models, run), `settings`, `tools/web_search/test`, `files/extract`, `mcp/servers` (list, save, import, delete, approve, connect, disconnect, trust).

### 5.3 Discovery and inference
- The scanner probes loopback only, with anonymous `GET`s, no prompts, no keys. A service is accepted **only** if it returns a correctly shaped response: Ollama via `/api/version` + `/api/tags`; OpenAI-compatible via a real `/v1/models` list. An open port, HTML, or JSON of the wrong shape is never classified (this was mutation-tested). Backoff, duplicate detection (`localhost` = `127.0.0.1`), no redirects.
- **Ollama provider:** NDJSON streaming, token usage, capabilities from `/api/show` (absent ⇒ unknown, not false). **OpenAI-compatible provider:** SSE, usage, auth, image parts.
- **Router:** profiles (fast, balanced, coding, vision, private-local, …); `private_local` can **never** fall back to a remote provider; required capabilities must be *verified*; failure explains each rejection. (Built and tested; the chat UI currently lets you pick the model directly rather than routing.)

### 5.4 Orchestrator (the heart)
Works with **any** model because it does not rely on native tool-calling. Rules decide the common cases (explicit "search …", time-sensitive wording, "remember …"); the model can also ask for tools by starting its reply with a tag. Tool output is fenced as untrusted data and **never parsed for tags**, so a web page or file cannot make the model run tools. Hard limits: 3 tool rounds, loop breaker for identical calls.

### 5.5 Web search
No API key: fetches DuckDuckGo's HTML results. Off until you consent. Only a short, redacted **query** is sent (never the chat). Host pinned, https only, no redirects, offline mode refuses, every search shown in the chat. Modes: automatic, only when you say "search", never. Settings has a **Test web search** button. Explicit-trigger rules avoid false positives ("binary search" does not trigger).

### 5.6 Memory
SQLite + FTS5. Say "remember that …": the model writes a short note (it must overlap with your words, otherwise your own words are saved), the note is saved as confirmed, and a chip offers **Undo**. Secrets (API keys etc.) are never saved. Retrieval ignores common words so unrelated notes do not leak into prompts; unconfirmed/imported memories are never used. Also built: categories, provenance, conflict linking, expiry, project and agent isolation, export/import (imports arrive *unverified*), re-index. Embeddings: hook exists, no embedding model wired.

### 5.7 MCP
**One JSON file per server** in `state/mcp/` (stdio: `command/args/env`; remote: `url/headers`). Add in the app, or drop a file in and press Reload; a pasted `{"mcpServers": …}` block is split into one file each (all-or-nothing). Nothing runs until you review the summary and warnings and approve **that file's exact contents**; editing command/args/env/url/headers revokes approval and disconnects. Approved servers reconnect on launch. Tools ask for approval on every call unless you switch on **Always allow** for that single tool. A server claiming "read-only" changes nothing. Supported: stdio and Streamable HTTP, pagination, cancellation, reconnect. Not supported: legacy HTTP+SSE, OAuth.

### 5.8 Agents
Nine built-in roles (JARVIS Core, Research, Coding, Analysis, Memory, Voice, Operator, Security, Scheduler) in a hierarchy, with model assignment stored separately from identity, fallbacks, delegation limits (depth, per-request task cap), timeouts, cancellation and operational traces. Persistent in SQLite. Tested at API level; there is no multi-agent workflow in the chat itself yet.

### 5.9 File attachments
- **Extraction:** text/code/CSV/JSON/HTML, PDF (pypdf), DOCX (headings, tables), XLSX (sheets, rows). Refused with a clear message: binary files, encrypted PDFs, legacy `.doc/.xls`, PowerPoint, RTF, archives, folders. Protections: 25 MB cap, zip-bomb limits, no XML DTDs, 45 s timeout.
- **Context budget:** a configurable character budget (6k–48k) is divided fairly across files; oversized files are reduced to the most relevant excerpts (SQLite BM25) and the chat says exactly how much was read. File text is fenced as untrusted and never stored in memory.
- **Images:** downscaled to JPEG (≤1568 px) in the app; sent only to models verified as vision-capable (dropped with a notice otherwise). Max 4 images per request.
- **Limits you should know:** scanned PDFs have no text (no OCR); figures inside PDFs are invisible to the model.

### 5.10 Markdown and math rendering
Each assistant message is rendered by a bundled page (marked + KaTeX, offline) inside a sandboxed web view: headings, lists, tables, code with Copy, `$x^2$`, `$$…$$`, `\( \)`, `\[ \]`, `\begin{align}`. Currency like `$1,200 … $600` is not mistaken for math. **Only real `~~double~~` tildes strike text**; the single-tilde "strikethrough" you saw came from Apple's parser treating `~$600 … ~$350` as one struck span. Security: raw HTML shown as text, remote images never fetched, only http(s)/mailto links, strict CSP, all other navigation blocked.

### 5.11 Security model (summary; full table in `docs/security.md`)
Assume model output, tool descriptions/results, MCP servers, files, web pages and local endpoints may be hostile.
- Every tool call passes one policy gate; unknown tools need approval; approvals are bound to the exact action, single-use, and expire in 5 minutes; standing grants can never cover approval-required tools.
- Secrets are redacted from logs, audit rows, errors and traces; child processes get a filtered environment.
- Network guard: loopback by default, link-local/metadata always blocked, every resolved address checked, no redirects.
- Shell: argv only, allow-list, no shells. Paths: resolve-then-contain, symlinks followed.
- The audit log records decisions and metadata, never prompts or file contents.

---

## 6. How it was verified

| Suite | Count | Where it ran |
|---|---|---|
| Python (pytest) | **345** | My sandbox (all pass); an earlier 183 passed on your Mac |
| Markdown/math renderer (Node + jsdom) | **20** | My sandbox |
| Swift (XCTest) | **40** written | **Not run by me.** `JarvisCore` and its test target built on your Mac earlier; I have not seen `swift test` results |

Method worth knowing:
- **Mutation checks.** For safety behaviors I deliberately broke the code and confirmed a test failed. Several first attempts did *not* fail, which exposed weak tests that I then strengthened.
- **Contract fixtures.** Swift decodes JSON generated from the real Python API; a Python test fails if the API shape drifts from the fixtures.
- **Real-process tests** for the lifecycle (bridge, MCP child, parent death) and real generated PDF/DOCX/XLSX files.
- **Honest limits:** jsdom does not enforce CSP; DuckDuckGo and Ollama were mocked in tests.

### Notable bugs found by testing or by you
- Token counts were being redacted as secrets (would have broken every chat in the app).
- Imported memories arrived as "confirmed" (memory-poisoning risk) — now unverified.
- A model-written memory could be unrelated to what you said — now must overlap.
- Spoofed/odd JSON classified as a valid model server; open port treated as valid; redirects followed — all fixed and mutation-checked.
- Single-tilde strikethrough in answers (your screenshot).
- `swift run` ignored keyboard focus (no app bundle).
- Setup scripts missed Python 3.14 (your PDF problem).

---

## 7. Key decisions (and why)
- **Removed Dodaios and OpenJarvis** (ADR-002): they were only ever tested against fakes and added configuration surface. They can still be used as ordinary OpenAI-compatible or MCP endpoints.
- **Python bridge + loopback HTTP** instead of embedding Python in Swift: simple, testable, and the Swift app stays usable when Python fails.
- **Text-tag tool protocol** instead of native tool-calling, so it works on any local model.
- **One JSON file per MCP server**, approval bound to its contents.
- **Piper (TTS) is GPL-3**: when added, it must run as a separate executable only.
- **Consent first** for anything that leaves the machine (web search).

---

## 8. Definition-of-done scorecard (original 20 items, adjusted for ADR-002)

| # | Item | State |
|---|---|---|
| 1 | Native app builds and launches | Observed |
| 2 | Navigation + persistent settings | Observed (UI); settings persist |
| 3–4 | Discover Ollama, list models | Observed |
| 5–6 | Real chat, streaming | Observed |
| 7 | History persists | Observed |
| 8 | OpenAI-compatible endpoint | Mock only |
| 9 | Provider failures shown clearly | Verified (bridge); UI Unbuilt for some states |
| 10–11 | Dodaios/OpenJarvis status and path | Dropped by decision |
| 12–13 | MCP connect/execute; blocked actions | Verified with a test server; not yet seen in the app |
| 14 | Memory store/retrieve | Verified; not yet reported |
| 15 | Speech provider | **Missing** |
| 16–17 | Bounded agents, visible status | Verified at API; thin in UI |
| 18 | Secrets safe, redacted | Redaction Verified; Keychain wrapper exists but is unused (no keyed providers) |
| 19 | Automated tests | Yes |
| 20 | Install/recovery docs | README, `doctor.sh`, setup verification |

---

## 9. What is missing

**From the original brief, not built**
1. **Voice:** microphone capture, push-to-talk, wake word, whisper.cpp speech-to-text, Piper/system text-to-speech, the voice orb states. (The UI shows "soon".)
2. **Scheduler / background routines:** reminders, cron-style tasks, morning briefing, task history.
3. **Knowledge base:** folder indexing, drag-a-folder, citations from indexed documents, re-indexing. (Attaching single files in chat works.)
4. **Plugin and skill system:** manifests, install/update, skill importers (Agent Skills, Claude Code, etc.).
5. **Setup wizard**, first-run hardware detection, **model recommendations**, download manager with consent.
6. **Computer use / automation:** Accessibility, AppleScript, browser automation (Playwright), shell sandbox/Docker.
7. **Cloud providers** (OpenAI, Anthropic, Gemini, OpenRouter) and the per-request remote-approval flow (the API refuses remote providers today).
8. **Native niceties:** global shortcut, quick overlay, search palette, launch at login, notifications, light mode, window restoration.
9. **Chat features:** regenerate, branching, per-message model override, export of whole conversations beyond markdown per chat, Markdown syntax highlighting in code blocks, pasting images from the clipboard.
10. **Observability:** CPU/GPU/energy metrics, token-cost dashboards, performance evaluation, learning from traces.
11. **Backup/restore**, encryption of memory at rest, Keychain-backed MCP secrets (they sit in owner-only `0600` JSON files).
12. **Embeddings / semantic memory** (hook exists, no model).
13. **Docs from the brief still unwritten:** `architecture.md`, `installation.md`, `configuration.md`, `privacy.md`, `memory.md`, `voice.md`, `plugins.md`, `troubleshooting.md`, SECURITY.md, CONTRIBUTING.md.

**Gaps within what exists**
- **PDF pages as images / OCR:** scanned PDFs and charts inside PDFs cannot be read (a vision model could, if pages were rendered to images — offered, not built).
- MCP: no legacy SSE transport, no OAuth for remote servers.
- Excel: first 8 sheets, 400 rows × 40 columns each; no PowerPoint, no legacy Office.
- Router profiles exist but the chat uses your selected model directly.
- Agents are not wired into the chat as an automatic team.

---

## 10. Known risks and caveats
- **Context windows.** Small local models can silently ignore the start of long prompts. The file budget (Settings → Files) is the only control; there is no per-model window detection.
- **Auto-search can over-trigger** on words like "news" or "today". It is always visible and can be limited to "only when I say search".
- **Small models may ignore the tool-tag protocol.** Rule-based triggers (search keyword, time-sensitive words, "remember") do not depend on it.
- **DuckDuckGo** may rate-limit or change its HTML; the app then reports an error rather than inventing results.
- **Each message uses its own web view.** Fine for normal use; untested on very long conversations.
- **Token usage** excludes a tool round that was cut off at its closing tag.
- **Plain-text storage:** conversations (with attachment text), memories and MCP credentials are not encrypted at rest; rely on FileVault.
- **pypdf is pure Python:** a pathological PDF can burn CPU until the 45 s timeout.
- **Ad-hoc signing:** not notarized; moving the app to another Mac may need right-click → Open.
- **Swift tests:** written but their pass/fail on your Mac is unknown to me.

---

## 11. Running it

```bash
rm -rf jarvis-os && tar -xzf jarvis-os.tar.gz && cd jarvis-os
chmod +x scripts/*.sh scripts/*.py
scripts/doctor.sh          # read-only: shows missing pieces (incl. pypdf)
scripts/setup.sh           # builds the Python environment, verifies imports
scripts/test.sh            # Python + renderer (+ Swift) tests
scripts/package.sh --open  # builds dist/Jarvis OS.app and the .dmg, launches it
```

**Python versions.** `setup.sh` and `doctor.sh` now try `python3.15, 3.14, 3.13, 3.12, 3.11, python3` (≥ 3.11 required). To force one: `PYTHON=/path/to/python3 scripts/setup.sh`.

**If PDFs fail:** Settings → Diagnostics now shows "PDF reading: ready/unavailable" and the Python the bridge uses. Fix with `"<that python>" -m pip install pypdf`, then **Restart bridge**.

**If the bridge banner is red:** run `scripts/setup.sh`, then Retry. **If a model is missing:** Models → Rescan. **Web search:** Settings → Test web search.

**Models and projectors.** A vision model needs its projector registered with the runtime that serves it (Ollama, llama.cpp or LM Studio); JARVIS OS then sees the `vision` capability. Dropping `mmproj-F32.gguf` loose into `~/.ollama/models/` does not register it.

---

## 12. Suggested next steps (in order of value)
1. **Confirm what you have not yet exercised:** a math answer and a table (renderer in real WebKit), remember → recall, an MCP server file end to end, a Word/Excel attachment. Report anything that looks off.
2. **PDF pages as images** (no OCR needed with a vision model) to cover scans and charts.
3. **Keychain-backed MCP secrets** and conversation export/regenerate (small, high daily value).
4. **Voice:** whisper.cpp + system speech first (Piper as a separate process later).
5. **Scheduler and a setup wizard.**
6. **Knowledge base** (folder indexing with citations), then **embeddings**.
7. **Cloud providers** with explicit per-request approval, if you want them.
8. The missing documents listed in section 9.13.

---

## 12. Floating assistant (pet + mini chat)

*Added after the sections above. Status: **Unbuilt-on-Mac** — the Swift is written but has never been compiled or run (no Swift toolchain was available). The logic in `JarvisCore/FloatingAssistant.swift` has Swift tests (`FloatingTests`) that have never been executed.*

**Display Mode** (Settings → Floating Assistant, saved across restarts):

| Mode | Pet | Chat |
|---|---|---|
| **Pet with Chat** (default) | shown | click the pet to open or close; stays open while you use other apps; opens beside the pet and moves with it; restored at launch if it was open |
| **Chat Only** | hidden | shown on its own; open and close with the shortcut |
| **Pet Only** | shown | never open at launch; click the pet to open; closes when you click elsewhere or press Esc, unless pinned |

**Also:** pet is draggable (click vs drag are told apart; snaps to screen edges; position saved per screen as a fraction so it survives resolution changes), 4 looks, 6 colours, size and idle-opacity sliders, corner presets and reset; mini chat is movable and resizable (size saved); global shortcut **⌃⌥J** (Carbon hot key, no Accessibility permission) re-recordable in Settings, must include Control or Command; pet and chat hide independently (pet right-click menu, menu bar popover, Assistant menu, Settings); right-click the pet for options.

**Same backend:** the mini chat is another view of `AppModel` — same conversation, model, memory, approvals, attachments and browser page awareness as the main window. Screen capture: an eye button in the mini chat (and a Settings toggle, off by default) attaches a ScreenCaptureKit capture of the window directly behind ArjunOS to each message, as an image sent to your vision model (`Floating/ScreenCapture.swift`). Browser page reading works as before.

**Files:** `Sources/JarvisCore/FloatingAssistant.swift` (settings, shortcut, policy, geometry), `Sources/JarvisOS/Floating/` (controller, hot key, pet, mini chat, settings UI).

**Unverified on a Mac:** non-activating panels taking keyboard input and ⌘C/⌘V in them, pet transparency click-through, shortcut registration, behaviour over full-screen apps and across Spaces, multi-display placement, drag feel.


---

## 13. Crew: boss + worker agents (adaptive to your RAM)

*Status: the Python side (`services/python/src/jarvis_bridge/orchestration/`) is tested: 46 new tests, full suite 622 passed, and deliberate breakages of the scheduler and failure ladder are caught. The Swift side (Crew screen, per-agent browsers) is written but has never been compiled or run.*

**What it does.** Give the boss a job (and files). It plans (JSON), each file goes to its own worker, workers write very detailed reports (long files are read in sections with an overview, scanned PDFs go to a vision model three pages at a time), and the boss writes the final answer. "Keep going in chat" opens a normal chat holding the answer and every full report.

**Memory modes** (chosen from free RAM, re-checked before every model load; shown live in a meter):

| Mode | When | What happens |
|---|---|---|
| Everyone awake | plenty of RAM | boss + up to N workers together |
| Boss + one | medium | boss stays loaded, workers take turns |
| One at a time | little | boss sleeps while workers work; wakes for a question (the small model is unloaded), then sleeps again |

It never goes above what you pick, drops to a safer mode mid-run if memory runs short (or battery/pressure), and refuses early with a clear message if even one model will not fit. A model stays awake until its space is actually needed, so a worker model is not reloaded between jobs. Models are loaded/unloaded through Ollama (`/api/ps`, `keep_alive`); servers that cannot unload (LM Studio etc.) are treated as always resident.

**Worker model choice:** automatic = the smallest installed chat model of at least ~1.5B parameters (a vision model for scans), or force one model for all, or per file.

**Team talk:** worker -> boss `<ask_boss>` (the boss wakes if asleep; if only you can decide it comes to you), worker -> everyone `<post key="...">` (a shared notes board plus the boss's conventions and glossary go into every worker prompt, so names, units and formats match), worker -> colleague `<ask_peer>` (answered from their finished report, no extra model load).

**When something fails:** boss gives new guidance and a stronger model is tried; if that fails the problem comes back to you (retry with new instructions, or skip) while other workers carry on.

**Per-agent browsers:** every worker has its own panel with its own browser (a separate, in-memory, not-signed-in store: it cannot see your logins). A worker can ask to open a page (`<browse>`, http/https only), and a page you open in its panel is what it reads next. Workers use the normal chat pipeline, so they have the usual tools and memory; as before, a page in context switches the terminal and external tools off for that worker.

**Limits to know:** one crew at a time; RAM numbers are estimates (file size x1.15 plus overhead); skills do not exist in the app yet; a worker holding a model slot while waiting for a tool approval can delay others in "one at a time" mode.


---

## 14. Obsidian: knowledge base and memory storage

*Status: the Python side (`services/python/src/jarvis_bridge/obsidian/`) is tested: 48 new tests, full suite 670 passed, and 8 deliberate breakages of the safety rules are all caught. The Swift side (Knowledge screen, Settings section, chips) is written but has never been compiled or run.*

**What it is.** An Obsidian vault is a folder of Markdown files, so this works with or without Obsidian running. Connect it from **Knowledge** (the old "soon" placeholder) or **Settings -> Obsidian**; the app lists the vaults Obsidian itself knows about, or you choose a folder.

**For every model, including crew workers (they all go through `run_chat`):**
- *Automatic:* notes that actually match the question are added to the prompt (heading-level sections, best match first, within a character budget; quiet for unrelated questions), fenced as untrusted data, secrets redacted, with a chip "Used N notes from Obsidian" you can click to open each one in Obsidian.
- *Tools:* `<vault>query</vault>` (search), `<note>title, path or [[link]]</note>` (read a whole note; aliases and wikilinks resolve), `<vaultnote name="..." tags="...">...</vaultnote>` (save a NEW note).
- *Search:* SQLite FTS5 (BM25) over heading sections, with title/alias/tag boosts and the link graph (backlinks, outgoing links). Rebuilt incrementally from file times; stored outside your vault.

**Memories live in the vault.** Every memory is a note in `ArjunOS/Memories/` (frontmatter id, category, status, tags). Two-way: edit a note and the memory follows; delete a note and the memory is deleted; drop a new note in and it becomes a memory; delete or change a memory in the app and its note follows. Sensitive memories and anything that looks like a secret are never written. If most notes vanish at once (cloud-sync hiccup, drive unplugged) nothing is deleted and you get a warning.

**Safety rules (enforced in code, with tests):** the assistant never edits your own notes; new notes go only in the `ArjunOS/` folder and never overwrite (a taken name gets a number); it appends only to notes it created; with a web page in context it cannot write notes at all; `.md` only; hidden folders (`.obsidian`, `.git`, `.trash`) are never read or written; symlinks are resolved so none can leave the vault; a vault root of `/` or your home folder is refused; text containing a secret is refused instead of written.

**Settings:** use Obsidian, auto-context, store memories, let the model create notes (each can be switched off). Settings fields are `obsidian_*`.

**Limits:** search is keyword-based (no embeddings yet), so a question phrased with none of a note's words can miss it; the vault is read on this Mac only (no Obsidian Sync or REST plugin involved); large vaults index in the background after connecting; the Memory screen does not yet show which memories are mirrored.


---

## 15. Crew upgrade: agent graph, multi-panel workspace, review, helpers, per-agent chat and terminal

*Status: Python side tested (703 passed in the full suite, 55 new tests for this round; the safety rules were mutation-checked earlier). Swift side written, never compiled here: the compiler has rejected earlier Swift of mine twice, so expect to paste errors again.*

**New in the Crew screen (setup column, memory meter, final answer and team activity are unchanged):**
- **Agent graph** (`Crew/CrewGraph.swift`): boss on top, workers below, helpers under the worker that started them. Status rings (working/queued/done/failed/needs you), asleep/awake badge, per-agent progress arc, hover details. Lines show who handed work to whom; a dot travels along a line when a question, answer, shared note or peer question is sent. Click = open chat, drag = rearrange, right-click = open as chat / browser / terminal / activity log.
- **Workspace** (`Crew/CrewWorkspace.swift`): up to 4 panels side by side. Each shows one agent as **Chat**, its own **Browser**, its own **Terminal**, its **Activity** log, or the shared **Team notes**.
- **Chat with any agent.** While an agent is working, your message is queued and it reads it at its next step (if it was writing its last answer, it gets one more step, so nothing is dropped). After it finished, it is a real follow-up chat: its model is woken through the same RAM governor (in one-at-a-time mode the boss goes to sleep so the worker can answer, and the reverse), with its report and its source files attached so questions are answered from the material. The boss can be asked about all reports and its final answer. The finished crew stays available for two hours.
- **Terminals.** Every agent has its own private workspace folder and its own sandboxed terminal (same allow-list, same OS sandbox, same approval prompt for the agent's commands). The panel shows what the agent ran and lets you run your own commands in that agent's folder (you are the approver of your own command). Worker approvals now reach you: the Crew screen shows the approval banner (before, a worker waiting for your OK just stalled).
- **Boss review.** After the workers finish, the boss reads each report against its job (reports treated as untrusted data), sends a weak one back once with feedback (the old report is kept if the retry fails), and can add workers for gaps. Switch it off with "The boss reviews the reports".
- **Dynamic workers.** The boss decides how many workers there are and can ask for a stronger model for hard parts (`size: large`). A worker can start up to 2 helpers (`<spawn>`) and gets their report back; helpers cannot start helpers; the crew never grows past its size limit; it works in one-at-a-time mode too (a waiting worker never holds the only model slot).
- **CPU and GPU.** The meter shows CPU load, the GPU name and how much of its memory models may use (on Apple Silicon the GPU gets a share of unified memory). The planner will not choose a plan whose models would not fit that share, and says so when the GPU, not RAM, is the limit.
- **Shared notes** are visible live (rules, terms, facts and who posted them).

**Not built:** skills (the app has none yet), and Python-side hardware numbers cannot be measured for Metal GPU load (only memory limits and CPU load).

---

## 16. Codex pets

The floating pet can use any Codex-format pet: a folder with `pet.json` (`id`, `displayName`, `description`, `spritesheetPath`) and a spritesheet (WebP or PNG) laid out as an 8 by 9 grid (standard sheet 1536 x 1872, 192 x 208 per frame). Rows are the animations: idle, running-right, running-left, waving, jumping, failed, waiting, running, review (frame counts 6, 8, 8, 4, 5, 8, 6, 6, 6, measured from a real sheet).

- **Where pets are read from:** `~/Library/Application Support/JarvisOS/pets` (created automatically; "Open pets folder" shows it) and `~/.codex/pets` (or `$CODEX_HOME/pets`). If an id exists in both, the app's own folder wins.
- **Settings -> Floating Assistant -> Pet:** a grid of every pet found (animated preview on the selected one) plus the built-in Classic pet; "Add pet…" takes a pet folder or a .zip and installs it; "Rescan"; a Size slider (40 to 260 pt, shows the number). The choice is saved.
- **How the pet moves:** running while the AI thinks, waiting while it needs your approval, failed on an error, a jump when you click or an answer arrives, "review" while an answer is unread, a wave when you hover, and it runs left or right as you drag it. Reduced motion shows still frames.
- **Safety:** a pet.json cannot make the app read another file (absolute paths, `..`, links leaving the folder, wrong extensions and oversized sheets are refused); zips are extracted to a scratch folder, links removed, size capped, then validated before anything is copied.
- Your uploaded `gojo-satoru` pet is included in `pets/gojo-satoru/`; use "Add pet…" with the folder or your zip.
