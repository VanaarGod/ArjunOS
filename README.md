<div align="center">

# ArjunOS

**A local-first personal AI assistant for macOS.**
Native SwiftUI app · tested Python bridge · your models, your Mac, your data.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)
![Python 3.11+](https://img.shields.io/badge/Python-3.11%2B-3776AB?logo=python&logoColor=white)
![License Apache-2.0](https://img.shields.io/badge/License-Apache--2.0-blue)
![Status early](https://img.shields.io/badge/status-early-orange)

[Features](#features) · [Quick start](#quick-start) · [Settings](#settings) · [Crew](#crew) · [Architecture](#architecture) · [Security](#security-model) · [Development](#development) · [Docs](#documentation)

</div>

> **Status: early.** The chat core, safety layer, memory, MCP, web search, file reading and the interface are real and have been run on a Mac. Voice, scheduling, plugins, a setup wizard and cloud providers are **not built**. Read [`docs/implementation-status.md`](docs/implementation-status.md) before trusting any claim.

---

## Features

| | |
|---|---|
| 💬 **Local chat** | Streams from models you already run: Ollama, LM Studio, llama.cpp, vLLM, or any OpenAI-compatible server. Models are discovered automatically and a default is chosen for you. |
| 👥 **Crew** | A boss model splits a job (for example, several PDFs) between small worker models, each with its own browser panel. Free RAM decides who is awake. |
| 🌐 **Built-in browser** | Tabs, downloads, popups, camera/mic prompts. Ask about the page you have open; it is read as the primary source. |
| 🔎 **Web search** | DuckDuckGo, no key. Asks permission first; only a short query is ever sent, never your chat. |
| 🧠 **Memory** | Say "remember …". Notes live in local SQLite (FTS5), can be undone, and never store secrets. |
| 🔌 **MCP tools** | One JSON file per server. See [`docs/mcp.md`](docs/mcp.md). |
| 📎 **Attachments** | Text, code, CSV, JSON, HTML, PDF, Word, Excel, and images (vision models only). |
| 📚 **Obsidian** | Connect a vault so the model can search it and add notes to its own folder. It never edits your notes. |
| 🐾 **Floating assistant** | A pet and mini chat above your other windows, opened with a global shortcut. Supports Codex-format pets. |
| 🖥️ **Sandboxed terminal** | A short allow-list of commands, each run only after you approve it. |
| 📝 **Create files** | "Create a markdown file about cats" writes into the workspace folder and never overwrites. |
| 🧮 **Rich answers** | Markdown, tables, code with Copy, and math (KaTeX), all rendered offline. |

## Quick start

**Requirements:** macOS 14+, Xcode 15+ (or a Swift 5.9 toolchain), Python 3.11+. Optional: [Ollama](https://ollama.com) or another local model server.

```bash
git clone <this repo> && cd jarvis-os
scripts/doctor.sh        # read-only environment report
scripts/setup.sh         # creates the bridge virtualenv and installs it
cd apps/macos && swift run JarvisOS
```

Install a model yourself; ArjunOS never downloads weights on its own:

```bash
ollama pull llama3.2:3b
```

ArjunOS checks `127.0.0.1:11434` every few seconds, lists the models you have, and selects one automatically. Change it from the model menu in the composer.

### Build the app (.app + .dmg)

```bash
scripts/package.sh              # dist/ArjunOS.app and dist/ArjunOS-0.1.0.dmg
scripts/package.sh --open       # ...and launch it
scripts/package.sh --install    # ...and copy it to ~/Applications
```

The app is ad-hoc signed for local use, not notarized. If macOS blocks it on another Mac, right-click → Open. Prefer the packaged app over `swift run`: a bare executable is not a real app bundle, which can make keyboard input unreliable.

If the bridge fails to start the app stays usable and shows the reason (**Settings → Diagnostics → Restart**).

## Settings

Settings has a list on the left and **one page per feature** on the right. Every choice uses the same rows, switches and dropdowns.

| Group | Page | What it controls |
|---|---|---|
| Assistant | **General** | The assistant's display name. |
| | **Floating assistant** | Display mode, shortcut, screen sharing for the mini chat, pet look, size, opacity, position. |
| Abilities | **Web search** | Permission, when to search (Automatic / When I ask / Never), results per search, a test button. |
| | **Browser** | Reading the open page, how much page text the model gets, OCR, links, clearing browsing data. |
| | **Files** | Creating files, the workspace folder, how much attached-file text is read per answer. |
| | **Terminal** | The command sandbox, Node status, a sandbox self-test. |
| Knowledge | **Memory** | Whether saved memories are used in answers; jump to the Memory screen. |
| | **Obsidian** | Vault folder and what the model may read or write. |
| App | **Privacy** | Offline mode. |
| | **Diagnostics** | Bridge status and restart, Python path, PDF support, state folder. |

## Crew

Crew is the multi-model workspace. You give the **boss** a job; it hands each piece to a **worker**.

1. Attach files (drag them in) and say what you want.
2. The boss splits the work, one file per worker. Scanned PDFs are read with a vision model.
3. Workers can ask the boss questions, share facts with the team, read each other's reports and browse the web in their own panel.
4. If a worker gets stuck the boss tries to fix it; if that fails, you choose to retry with new instructions or skip it.
5. **Free RAM decides who is awake.** Plenty of memory: everyone runs together. Less: workers take turns. Very little: one model at a time.

Pick the boss and worker models inside Crew. Workers default to the smallest installed model that can do the job.

## Architecture

```
┌──────────────────────────── macOS ────────────────────────────┐
│  ArjunOS.app  (SwiftUI)                                        │
│   UI · conversations (JSON files) · Keychain wrapper           │
│        │  http://127.0.0.1:<random port>   (loopback only)     │
│        │  Authorization: Bearer <random per-launch token>      │
│        ▼                                                       │
│  jarvis_bridge  (Python, FastAPI)                              │
│   discovery → providers → orchestrator → tools                 │
│   memory · MCP · crew · files · settings · audit               │
│        ▼                    ▼                    ▼             │
│  Ollama / OpenAI-    MCP servers          DuckDuckGo           │
│  compatible (local)  (stdio or HTTPS)     (queries only)       │
└────────────────────────────────────────────────────────────────┘
```

Swift gives a native app; Python has mature libraries for PDFs, SQLite FTS and HTTP. The seam is a versioned local HTTP API (`/v1/...`). The app owns exactly one child process (the bridge), starts it with a minimal environment, and stops it on quit.

```
apps/macos/        Swift package: JarvisCore (models, client) + JarvisOS (UI) + tests
  Sources/JarvisOS/Settings/   the Settings pages and their shared components
  Sources/JarvisOS/Crew/       the Crew workspace
services/python/   the bridge (jarvis_bridge) and its tests
scripts/           doctor, setup, build, package, test, fixture generation
docs/              architecture decisions, security, MCP, status
```

## Performance

ArjunOS is built to stay quiet when you are not using it.

- **One web engine for all messages.** Rendered answers share a single WebKit process instead of starting one per message.
- **Calm streaming.** Replies are built off to the side and shown about 14 times a second, and the sidebar no longer redraws on every token.
- **Fast launch.** The chat list loads headers only (cached after the first launch). A chat's messages are read when you open it, and saved off the main thread. Searching message text runs in the background.
- **Background animation that sleeps.** The drifting background runs at 5 fps and stops when the window is hidden or covered, when ArjunOS is not frontmost, in Low Power Mode, or with Reduce Motion on.
- **Polite polling.** Engine discovery is quick only while no model is connected, relaxed once one is, and slower when the window is hidden. Opening the window triggers one immediate catch-up.
- **Browser reading backs off.** If a page keeps looking the same, background reads space out (4 s up to 32 s) and pause while the app is in the background. Sending a message always reads the page fresh.

## Security model

- **Loopback only.** The bridge listens on `127.0.0.1` with a per-launch bearer token. **Offline mode** makes it refuse every non-loopback endpoint.
- **One approval per action.** Approvals cover a single tool call with its exact arguments, expire after 5 minutes and can't be reused.
- **Terminal sandbox.** Commands are parsed into an argument list and never reach a shell. `node` also runs under macOS Seatbelt (no network, no spawning programs, no deleting files, no writing outside the workspace). Allowed: `node`, `ls`, `cat`, `pwd`, `echo`, `mkdir`, `touch`, `head`, `tail`, `wc`. Never allowed: `sudo`/`su`, `rm`, pipes, redirects, `&&`. Known gap: JavaScript can overwrite files *inside* the workspace.
- **Untrusted pages.** Page text is fenced as data, and while a page is in context the terminal and external tools are switched off.
- **Secrets stay out.** API keys and anything that looks like a secret are never saved to memory or mirrored to Obsidian.
- **Resilience.** Heartbeat every 5 s; a stalled reply is stopped after 90 s with a clear error.

Details: [`docs/security.md`](docs/security.md).

## Where your data lives

| What | Path |
|---|---|
| State (memory, audit) | `~/Library/Application Support/JarvisOS/state` |
| Conversations | `~/Library/Application Support/JarvisOS/conversations/*.json` |
| Workspace (created files, terminal) | `…/state/workspace` |
| Bridge virtualenv | `~/Library/Application Support/JarvisOS/venv` |

Back up by copying that folder. Uninstall by deleting it.

## Development

```bash
scripts/test.sh                              # everything that can run on this machine
cd services/python && python -m pytest -q    # bridge tests only
cd apps/macos && swift test                  # Swift tests
cd apps/macos/Web && npm test                # markdown / math renderer
```

`scripts/test.sh` also checks that the API contract fixtures are current (`scripts/gen_fixtures.py --check`). Parts that need Node or Swift are skipped with a message when those tools are missing.

## Documentation

| | |
|---|---|
| [`docs/implementation-status.md`](docs/implementation-status.md) | What is verified, mocked, unbuilt or missing |
| [`docs/security.md`](docs/security.md) | Threat model and safeguards |
| [`docs/mcp.md`](docs/mcp.md) | Adding MCP servers |
| [`docs/integration-matrix.md`](docs/integration-matrix.md) | Supported engines and tools |
| [`docs/architecture-decisions/`](docs/architecture-decisions) | ADRs |

## Roadmap

Not built yet: voice (speech-to-text and text-to-speech), scheduled jobs, plugins and skills, a first-run setup wizard, knowledge-base indexing of whole folders, and cloud providers (deliberately blocked today).

## License

[Apache-2.0](LICENSE). See [`NOTICE`](NOTICE) for third-party terms, including Piper's GPL.
