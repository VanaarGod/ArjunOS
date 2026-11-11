"""MOCK inference engines served over real localhost TCP. These are test doubles, NOT live Ollama/LM Studio."""
from __future__ import annotations
import asyncio, json, socket, threading, time
from contextlib import contextmanager
import uvicorn
from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse, StreamingResponse, HTMLResponse


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0)); return s.getsockname()[1]


@contextmanager
def serve(app: FastAPI):
    port = free_port()
    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port, log_level="error"))
    th = threading.Thread(target=server.run, daemon=True); th.start()
    for _ in range(100):
        if server.started: break
        time.sleep(0.05)
    assert server.started, "mock server failed to start"
    try:
        yield port
    finally:
        server.should_exit = True; th.join(timeout=5)


def fake_ollama(models=("llama3.2:3b", "qwen2.5-coder:7b")) -> FastAPI:
    app = FastAPI(); state = {"models": list(models)}; app.state.s = state
    caps = {"llama3.2:3b": ["completion", "tools"], "qwen2.5-coder:7b": ["completion"], "llava:7b": ["completion", "vision"]}

    @app.get("/api/version")
    def version(): return {"version": "0.99.0-mock"}

    @app.get("/api/tags")
    def tags():
        return {"models": [{"name": m, "model": m, "size": 2_000_000_000,
                            "details": {"family": "llama", "parameter_size": "3B", "quantization_level": "Q4_K_M"}}
                           for m in state["models"]]}

    @app.post("/api/show")
    async def show(req: Request):
        m = (await req.json()).get("model")
        if m not in state["models"]: return JSONResponse({"error": "model not found"}, 404)
        return {"capabilities": caps.get(m, ["completion"]), "model_info": {"llama.context_length": 8192}}

    @app.post("/api/chat")
    async def chat(req: Request):
        b = await req.json()
        state.setdefault("chats", []).append(b)               # lets tests assert exactly what the model received
        if b["model"] not in state["models"]:
            return JSONResponse({"error": f"model '{b['model']}' not found"}, 404)
        async def gen():
            for w in ["Hello", " from", " mock", " Ollama"]:
                yield json.dumps({"message": {"role": "assistant", "content": w}, "done": False}) + "\n"
                await asyncio.sleep(0.01)
            yield json.dumps({"message": {"content": ""}, "done": True, "done_reason": "stop",
                              "prompt_eval_count": 7, "eval_count": 4}) + "\n"
        return StreamingResponse(gen(), media_type="application/x-ndjson")
    return app


def fake_openai(models=("local-model",), *, api_key: str | None = None, owned_by="mock", info=False, stream_ok=True) -> FastAPI:
    app = FastAPI()
    def auth(req: Request):
        return api_key is None or req.headers.get("authorization") == f"Bearer {api_key}"

    @app.get("/v1/models")
    def lst(req: Request):
        if not auth(req): return JSONResponse({"error": "unauthorized"}, 401)
        return {"object": "list", "data": [{"id": m, "object": "model", "owned_by": owned_by} for m in models]}

    if info:
        @app.get("/v1/info")
        def inf(): return {"model": models[0], "agent": "simple", "engine": "ollama"}

    @app.post("/v1/chat/completions")
    async def chat(req: Request):
        if not auth(req): return JSONResponse({"error": "unauthorized"}, 401)
        async def gen():
            for w in ["Hi", " there"]:
                yield "data: " + json.dumps({"choices": [{"delta": {"content": w}}]}) + "\n\n"
                await asyncio.sleep(0.01)
            yield "data: " + json.dumps({"choices": [{"delta": {}, "finish_reason": "stop"}]}) + "\n\n"
            yield "data: " + json.dumps({"choices": [], "usage": {"prompt_tokens": 5, "completion_tokens": 2}}) + "\n\n"
            if stream_ok: yield "data: [DONE]\n\n"
        return StreamingResponse(gen(), media_type="text/event-stream")
    return app


def dumb_http() -> FastAPI:
    """Something listening on a port that is NOT an inference API (answers 200 HTML to everything)."""
    app = FastAPI()
    @app.get("/{p:path}")
    def any_(p: str): return HTMLResponse("<html>welcome to my dev server</html>")
    return app


def redirector(target: str) -> FastAPI:
    app = FastAPI()
    @app.get("/{p:path}")
    def r(p: str): return Response(status_code=302, headers={"Location": target})
    return app


def wrong_shape_json(body) -> FastAPI:
    """Answers 200 + valid JSON of the WRONG shape on every route (protocol-shape validation test)."""
    app = FastAPI()
    @app.get("/{p:path}")
    def any_(p: str): return JSONResponse(body)
    return app
