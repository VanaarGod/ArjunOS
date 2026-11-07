# ArjunOS

A local-first AI assistant for macOS. It runs on your own models (Ollama, LM Studio and other OpenAI-compatible servers) and works offline. A native SwiftUI app talks to a small Python service on your Mac that handles models, tools, memory and safety.

> **Status: early and experimental.** The Python bridge and the in-page JavaScript are tested (576 Python tests, 18 Node tests). The Swift app has been written but **has not been compiled or run yet**, so expect build errors. macOS-specific pieces (sandbox, WebKit permissions, OCR, PDF reading) are unverified on a real Mac.

---

## Features

### Chat and models
- Streaming chat with local models, a model picker, conversation history, temporary chats and projects.
- File and image attachments. Long documents are excerpted by relevance to your question.
- Reasoning models show "Thinking...". Stuck replies are stopped after 90 seconds, and a dropped connection gets one quiet retry.

### Agents
Specialist agents for focused tasks.

<!-- TODO: list the agents and what's new compared to the original 8 -->

### Memory (Obsidian-based)
The assistant can recall what it has learned and can optionally use it automatically.

<!-- TODO: explain how the Obsidian vault is used: where it lives, what gets written, and whether you can edit notes by hand -->

### Pet
<!-- TODO: describe the pet: what it is, where it appears, and how it reacts -->

### Integrated browser
- A side pane with tabs, an address bar (anything that isn't a URL becomes a search), downloads and permission prompts.
- When you send a message, ArjunOS reads the live page: text, metadata, prices, specs, tables, links and your selection. PDFs are read with PDFKit, and image-heavy pages fall back to Vision OCR.
- Answers keep **"From this page"** separate from **"From other sources"**. Questions like "is this a good price?" trigger a web search automatically.
- Sign-in pages are never shared, and form fields and passwords are never read.

### Tools
- **Web search** (DuckDuckGo), after you consent. Results are treated as untrusted and cited like `[1]`.
- **Sandboxed terminal.** Every command needs your approval. Only a short list of commands is allowed (`node`, `ls`, `cat`, `pwd`, `echo`, `mkdir`, `touch`, `head`, `tail`, `wc`), and `sudo`, deleting, pipes and redirects are blocked. `node` runs under a macOS Seatbelt sandbox with no network, no deleting and no access to your home folder.
- **File creation.** "Create a markdown file about cats" writes the file into the workspace. It never overwrites an existing file, only allows plain-text types, and never runs the file.
- **MCP servers** for external tools, each gated by approval.

### Interface
- Liquid Glass on macOS 26, with a frosted fallback on older versions.
- A menu bar icon that changes with state: asleep, thinking, waiting for approval, done or error.

---

## Architecture

```
SwiftUI app (macOS 14+)  --HTTP + SSE-->  Python bridge (FastAPI, loopback only)
  chat, sidebar, browser                     |
  menu bar icon                              +--> local models (Ollama / OpenAI-compatible)
  WKWebView tabs                             +--> memory
                                             +--> web search
                                             +--> sandboxed terminal + file creation
                                             +--> MCP servers (approval-gated)
```

- The app starts the bridge itself on a random port with a minimal environment, so your shell secrets are not inherited. The bridge is protected by a bearer token and host checks.
- The bridge **refuses remote model endpoints**, so chat text and page content stay on your Mac.
- The model calls a tool by starting its reply with a tag: `<search>`, `<recall>`, `<shell>`, `<file name="...">` or `<tool name="...">`.

## Security model

| Risk | Protection |
|---|---|
| Model or web page instructing the terminal | Every command needs approval. The terminal and tools are switched off while a web page is in context. |
| Scripts deleting files or using the network | Seatbelt sandbox plus a list of allowed commands. |
| Prompt injection from web or search text | Content is fenced as untrusted data and screened for injection phrases. |
| Secrets in text the model can see | Secret patterns are redacted. |
| Data leaving the Mac | Remote model endpoints are refused. |
| File creation abuse | Workspace only, safe file types only, never overwrites. |

There is also an audit log and a security policy engine. See [`docs/`](docs/) for details.

---

## Getting started

**Requirements**
- macOS 14 or later (Liquid Glass needs macOS 26)
- Xcode / Swift toolchain
- Python 3
- A local model server such as [Ollama](https://ollama.com) or [LM Studio](https://lmstudio.ai)

**Build and run**
```bash
git clone https://github.com/VanaarGod/ArjunOS.git
cd ArjunOS
scripts/package.sh --open
```

**Run the tests**
```bash
scripts/test.sh
```

`scripts/` also includes `setup`, `build`, `doctor` and `gen_fixtures` helpers.

## Project layout

```
apps/macos/           SwiftUI app
  Sources/JarvisCore/   testable logic (bridge client, SSE, chat reducer, stores)
  Sources/JarvisOS/     the app (UI, design system, menu bar, browser)
  Tests/                Swift tests and Node/jsdom tests for page scripts
services/python/      Python bridge
  src/jarvis_bridge/    api, chat, inference, discovery, memory, mcp, agents, tools, security
  tests/
scripts/              setup, build, package, test, doctor
docs/                 architecture decisions, security, MCP notes
```

> The app is called **ArjunOS**, but internal names are still `JarvisOS` and `jarvis_bridge`, so existing data keeps working. App data lives in `~/Library/Application Support/JarvisOS/`.

## Roadmap

- **Kid-safe browsing mode** (in progress): URL, search and page classifier, approved-sites-only mode, parent PIN, settings screen.
- Voice input.
- Private browsing tabs.
- "Ask about selection" from the right-click menu.

## Known limitations

- Some popup sign-ins ("Sign in with Google/Apple") don't work, because popups open as ordinary tabs.
- Content inside frames from other sites can't be read.
- The page isn't re-read if you scroll while the AI is answering.

## License

<!-- TODO: choose a license -->
