# Candidate matrix (license/maintenance read from upstream repos, 2026-10-27)

Dodaios and OpenJarvis were evaluated, integrated for a while, then removed: see ADR-002.

| Candidate | License | Last upstream commit | Unique value | Overlap | Security notes | Method | Decision |
|---|---|---|---|---|---|---|---|
| Ollama / LM Studio / llama.cpp / vLLM | various | – | local inference | – | loopback by default | Ollama adapter + OpenAI-compatible adapter | **Integrated (verified vs mocks)** |
| DuckDuckGo HTML results | n/a (site terms) | – | keyless web search | – | query-only egress, consent-gated | built-in tool | **Integrated (parser verified vs a synthetic page only)** |
| whisper.cpp | MIT | 2026-10-19 | local STT | none | models are separate downloads | subprocess | **Planned** |
| Piper (piper1-gpl) | **GPL-3.0** | 2026-10-23 | local TTS | macOS voices | GPL: subprocess only; voice-model licenses vary | subprocess | **Planned; subprocess-only** |
| LiteLLM | MIT (+enterprise dir) | 2026-10-26 | provider routing | own router | proxy = extra attack surface | – | **Defer** |
| Playwright | Apache-2.0 | 2026-10-26 | browser automation | – | needs sandbox | subprocess | **Defer** |
| OpenClaw | MIT | 2026-10-26 | channels/skills | – | broad host access | – | **Defer** |
| Hermes Agent | MIT | 2026-10-26 | persistent agents | – | – | – | **Defer** |
