"""Cross-language: the REAL extraction script (run in jsdom) -> the bridge's request model -> the prompt the model sees.
Skipped when Node or the jsdom test dependency is not installed (scripts/test.sh installs it)."""
import json, shutil, subprocess
from pathlib import Path
import pytest
from jarvis_bridge.api.server import PageIn
from jarvis_bridge.chat.pagecontext import build_page_block

DIR = Path(__file__).resolve().parents[3] / "apps" / "macos" / "Tests" / "PageScripts"
pytestmark = pytest.mark.skipif(shutil.which("node") is None or not (DIR / "node_modules" / "jsdom").exists(), reason="node/jsdom not installed")


def extracted() -> dict:
    out = subprocess.run(["node", "emit.mjs"], cwd=DIR, capture_output=True, text=True, timeout=60, check=True).stdout
    return json.loads(out)["payload"]


def test_the_scripts_output_is_accepted_by_the_bridge_request_model():
    p = PageIn(**extracted())                                         # every key the script emits must validate
    assert p.url.startswith("https://shop.example.com") and p.status == "ready" and p.tab_id == "tab-1"
    assert p.structured and p.prices and p.specs and p.tables and p.headings and p.links


def test_what_the_page_shows_reaches_the_prompt_and_what_it_hides_does_not():
    block = build_page_block(PageIn(**extracted()).model_dump(), "what is the battery life and price?", 16000)
    t = block.text
    assert block.attach and block.readable and block.use.has_structured and block.use.prices >= 2
    assert "offers.price=1599.00" in t and "$1,599.00" in t and "Up to 22 hours" in t and "Return policy" in t
    for hidden in ["HIDDEN-DISPLAY-NONE", "HIDDEN-ARIA", "HIDDEN-ATTR", "USER-TYPED-VALUE", "TEXTAREA-VALUE", "SCRIPT-BODY-MUST-NOT-APPEAR"]:
        assert hidden not in t, f"{hidden} leaked into the prompt"
