import subprocess, sys
from pathlib import Path

def test_swift_contract_fixtures_match_live_api():
    """The Swift tests decode these files. If the API shape changes, regenerate: python scripts/gen_fixtures.py"""
    script = Path(__file__).resolve().parents[3] / "scripts" / "gen_fixtures.py"
    r = subprocess.run([sys.executable, str(script), "--check"], capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stdout + r.stderr
