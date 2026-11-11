import pytest
from jarvis_bridge.discovery.scanner import EndpointScanner, canonical_key
from jarvis_bridge.security.netguard import EndpointRejected, NetPolicy
from jarvis_bridge.inference.base import ChatMessage, ErrorKind, ProviderError, collect
from jarvis_bridge.inference.ollama import OllamaProvider
from jarvis_bridge.inference.openai_compat import OpenAICompatProvider
from mockservers import serve, fake_ollama, fake_openai, dumb_http, redirector, free_port, wrong_shape_json


def scanner(*urls, **kw):
    return EndpointScanner(candidates=[("t", u) for u in urls], **kw)


# ---------------- discovery ----------------
async def test_discovers_ollama_and_lists_models():
    with serve(fake_ollama()) as p:
        s = scanner(f"http://127.0.0.1:{p}")
        ev = await s.scan_once()
        ep = s.endpoints()[0]
        assert ep.usable and ep.kind == "ollama" and ep.version == "0.99.0-mock"
        assert ep.models == ["llama3.2:3b", "qwen2.5-coder:7b"] and ep.latency_ms is not None
        assert [e.type for e in ev] == ["endpoint_up"]

async def test_discovers_generic_openai_compat():
    with serve(fake_openai(("m1", "m2"))) as p:
        s = scanner(f"http://127.0.0.1:{p}/v1"); await s.scan_once()
        ep = s.endpoints()[0]
        assert ep.usable and ep.kind == "openai_compat" and ep.models == ["m1", "m2"]

async def test_open_port_that_is_not_an_inference_api_is_not_classified():
    with serve(dumb_http()) as p:
        s = scanner(f"http://127.0.0.1:{p}/v1"); await s.scan_once()
        ep = s.endpoints()[0]
        assert not ep.usable and ep.status == "unrecognized" and ep.models == []

async def test_closed_port_unreachable_with_backoff_and_manual_rescan():
    t = [1000.0]; s = scanner(f"http://127.0.0.1:{free_port()}", clock=lambda: t[0])
    await s.scan_once(); ep = s.endpoints()[0]
    assert ep.status == "unreachable" and ep.failures == 1
    first_next = ep.next_probe_at; assert first_next > t[0]
    await s.scan_once(); assert ep.failures == 1                  # skipped: still in backoff
    await s.scan_once(manual=True); assert ep.failures == 2       # manual rescan ignores backoff
    assert ep.next_probe_at - t[0] > first_next - t[0]            # backoff grew

async def test_auth_required_endpoint_is_not_validated_and_gets_no_key():
    with serve(fake_openai(api_key="sekret")) as p:
        s = scanner(f"http://127.0.0.1:{p}/v1"); await s.scan_once()
        ep = s.endpoints()[0]
        assert ep.status == "auth_required" and not ep.usable and "API key" in ep.last_error

async def test_redirects_are_never_followed():
    # The redirect target is a REAL, valid endpoint: following it would validate. It must not be followed.
    with serve(fake_openai()) as real:
        with serve(redirector(f"http://127.0.0.1:{real}/v1/models")) as p:
            s = scanner(f"http://127.0.0.1:{p}/v1"); await s.scan_once()
            assert not s.endpoints()[0].usable

async def test_provider_does_not_follow_redirects():
    with serve(fake_openai()) as real:
        with serve(redirector(f"http://127.0.0.1:{real}/v1/models")) as p:
            o = OpenAICompatProvider(f"http://127.0.0.1:{p}/v1", provider_id="x")
            assert not (await o.health()).ok

@pytest.mark.parametrize("body", [{"data": "oops"}, {"object": "list"}, {"data": [1, 2, 3]}, [], {"data": None}])
async def test_valid_json_of_wrong_shape_is_not_classified(body):
    with serve(wrong_shape_json(body)) as p:
        s = scanner(f"http://127.0.0.1:{p}/v1"); await s.scan_once()
        ep = s.endpoints()[0]
        assert not ep.usable, f"{body!r} must not validate (got kind={ep.kind}, status={ep.status})"

async def test_model_added_removed_and_endpoint_down_events():
    app = fake_ollama(("a",))
    with serve(app) as p:
        s = scanner(f"http://127.0.0.1:{p}"); await s.scan_once()
        app.state.s["models"] = ["b"]
        ev = await s.scan_once(manual=True)
        assert {(e.type, e.detail) for e in ev} == {("model_added", "b"), ("model_removed", "a")}
    ev = await s.scan_once(manual=True)
    assert [e.type for e in ev] == ["endpoint_down"]

async def test_duplicate_detection_localhost_vs_127():
    assert canonical_key("http://localhost:11434") == canonical_key("http://127.0.0.1:11434/v1")
    s = scanner("http://127.0.0.1:11434", "http://localhost:11434/v1")
    assert len(s.endpoints()) == 1

def test_default_scanner_only_targets_loopback():
    s = EndpointScanner()
    assert s.endpoints() and all(e.key.startswith("127.0.0.1:") for e in s.endpoints())

def test_user_endpoint_policy_enforced_and_removable():
    s = scanner()
    with pytest.raises(EndpointRejected): s.add_user_endpoint("http://192.168.1.9:8000/v1")      # LAN off by default
    with pytest.raises(EndpointRejected): s.add_user_endpoint("http://169.254.169.254/v1")
    ep = s.add_user_endpoint("http://127.0.0.1:9999/v1"); assert ep.owner == "user"
    assert s.remove(ep.key) and not s.endpoints()

async def test_scan_survives_garbage_responses():
    from fastapi import FastAPI, Response
    app = FastAPI()
    @app.get("/{p:path}")
    def g(p: str): return Response("\x00\xff not json", media_type="application/json")
    with serve(app) as port:
        s = scanner(f"http://127.0.0.1:{port}"); await s.scan_once()
        assert not s.endpoints()[0].usable                       # no crash, not classified


# ---------------- Ollama provider ----------------
async def test_ollama_health_models_capabilities():
    with serve(fake_ollama()) as p:
        o = OllamaProvider(f"http://127.0.0.1:{p}")
        h = await o.health(); assert h.ok and h.version == "0.99.0-mock" and h.latency_ms > 0
        ms = {m.id: m for m in await o.list_models()}
        assert ms["llama3.2:3b"].capabilities.tools is True
        assert ms["qwen2.5-coder:7b"].capabilities.tools is False       # declared absent
        assert ms["llama3.2:3b"].context_length == 8192 and ms["llama3.2:3b"].quantization == "Q4_K_M"
        await o.aclose()

async def test_ollama_streaming_chat_with_usage():
    with serve(fake_ollama()) as p:
        o = OllamaProvider(f"http://127.0.0.1:{p}")
        chunks = [c.delta async for c in o.chat_stream("llama3.2:3b", [ChatMessage("user", "hi")])]
        assert [c for c in chunks if c] == ["Hello", " from", " mock", " Ollama"]
        text, last = await collect(o.chat_stream("llama3.2:3b", [ChatMessage("user", "hi")]))
        assert text == "Hello from mock Ollama" and last.done and (last.prompt_tokens, last.completion_tokens) == (7, 4)

async def test_ollama_missing_model_is_a_typed_error():
    with serve(fake_ollama()) as p:
        o = OllamaProvider(f"http://127.0.0.1:{p}")
        with pytest.raises(ProviderError) as ei:
            async for _ in o.chat_stream("nope", [ChatMessage("user", "x")]): pass
        assert ei.value.kind is ErrorKind.NOT_FOUND and "nope" in str(ei.value)

async def test_ollama_not_running_reports_unreachable_not_crash():
    o = OllamaProvider(f"http://127.0.0.1:{free_port()}")
    h = await o.health()
    assert not h.ok and h.error["kind"] == "unreachable"
    with pytest.raises(ProviderError) as ei: await o.list_models()
    assert ei.value.kind is ErrorKind.UNREACHABLE

async def test_ollama_stream_cancellation():
    import asyncio
    with serve(fake_ollama()) as p:
        o = OllamaProvider(f"http://127.0.0.1:{p}")
        async def first_only():
            async for c in o.chat_stream("llama3.2:3b", [ChatMessage("user", "x")]):
                return c.delta
        assert await asyncio.wait_for(first_only(), 5) == "Hello"      # abandoning the stream is clean

async def test_provider_refuses_policy_violating_url():
    with pytest.raises(ProviderError) as ei: OllamaProvider("http://169.254.169.254")
    assert ei.value.kind is ErrorKind.REJECTED


# ---------------- OpenAI-compatible provider ----------------
async def test_openai_compat_models_stream_usage():
    with serve(fake_openai(("m1",))) as p:
        o = OpenAICompatProvider(f"http://127.0.0.1:{p}/v1", provider_id="lmstudio")
        assert (await o.health()).ok
        assert [m.id for m in await o.list_models()] == ["m1"]
        assert (await o.list_models())[0].capabilities.tools is None     # unknown, never assumed
        text, last = await collect(o.chat_stream("m1", [ChatMessage("user", "hi")]))
        assert text == "Hi there" and last.done and (last.prompt_tokens, last.completion_tokens) == (5, 2)

async def test_openai_compat_auth_failure_and_success():
    with serve(fake_openai(api_key="k-12345678")) as p:
        bad = OpenAICompatProvider(f"http://127.0.0.1:{p}/v1", provider_id="x", api_key="wrong")
        h = await bad.health(); assert not h.ok and h.error["kind"] == "auth"
        good = OpenAICompatProvider(f"http://127.0.0.1:{p}/v1", provider_id="x", api_key="k-12345678")
        assert (await good.health()).ok

async def test_truncated_stream_without_done_is_a_protocol_error():
    with serve(fake_openai(stream_ok=False)) as p:
        o = OpenAICompatProvider(f"http://127.0.0.1:{p}/v1", provider_id="x")
        with pytest.raises(ProviderError) as ei: await collect(o.chat_stream("local-model", [ChatMessage("user", "hi")]))
        assert ei.value.kind is ErrorKind.PROTOCOL

async def test_health_false_when_200_is_not_a_model_list():
    with serve(dumb_http()) as p:
        o = OpenAICompatProvider(f"http://127.0.0.1:{p}/v1", provider_id="x")
        assert not (await o.health()).ok

async def test_probe_chat_explicit_test():
    with serve(fake_openai()) as p:
        o = OpenAICompatProvider(f"http://127.0.0.1:{p}/v1", provider_id="x")
        assert (await o.probe_chat("local-model")).ok

async def test_api_key_not_leaked_in_error_text():
    with serve(fake_openai(api_key="k-secret-12345678")) as p:
        o = OpenAICompatProvider(f"http://127.0.0.1:{p}/v1", provider_id="x", api_key="k-wrong-1234567890")
        h = await o.health()
        assert "k-wrong" not in str(h.error) and "k-wrong" not in h.detail
