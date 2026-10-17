"""Render the autoscaling and chaos measurements into README.md between the RESULTS markers.

    python scripts/render_results.py --write     # latest load/results/hpa-*.json and chaos/results/*.json
    python scripts/render_results.py --check     # exit 1 if either is missing
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def latest(pattern: str) -> dict | None:
    files = sorted(ROOT.glob(pattern))
    return json.loads(files[-1].read_text(encoding="utf-8")) if files else None


def fmt(value, unit="") -> str:
    return "n/a" if value is None else f"{value}{unit}"


def section(hpa: dict | None, chaos: dict | None, k6: dict | None = None) -> str:
    lines = []
    if hpa:
        lines.append(
            "- **Autoscaling (k6 ramp 5 -> 60 requests/s of uncached hybrid searches through the ingress; HPA on CPU and "
            "on requests/s per pod from prometheus-adapter):** "
            f"baseline {fmt(hpa['baseline_ready_replicas'])} ready replicas; the HPA raised its target "
            f"{fmt(hpa['hpa_desired_increase_at_s'], ' s')} after the test started "
            f"(load step at {fmt(hpa['load_step_at_s'], ' s')}), the first new replica was ready "
            f"**{fmt(hpa['reaction_s_from_load_step_to_new_replica_ready'], ' s')} after the load step**, "
            f"peak {fmt(hpa['peak_ready_replicas'])} ready replicas."
            + (
                f" k6 saw {k6['requests']:,} requests, {100 * k6['failed_share']:.2f}% failed, p50 {k6['search_ms']['med']:.0f} ms, "
                f"p95 {k6['search_ms']['p(95)']:.0f} ms, p99 {k6['search_ms']['p(99)']:.0f} ms over the whole ramp, "
                "the tail being the minute before the new replicas were ready."
                if k6
                else ""
            )
        )
    if chaos:
        lines.append(
            "- **Chaos (an uncached BM25 search every 0.5 s through the ingress while the platform is attacked; "
            "outage = first failed to first successful probe):**"
        )
        lines.append("")
        lines.append("  | experiment | probes | failed | first failure after action | outage | recovered after action |")
        lines.append("  |---|---|---|---|---|---|")
        for r in chaos.get("results", []):
            lines.append(
                f"  | {r['experiment']} | {r['probes']} | {r['failed_probes']} | {fmt(r['first_failure_s_after_action'], ' s')} "
                f"| **{fmt(r['outage_s'], ' s')}** | {fmt(r['recovery_s_after_action'], ' s')} |"
            )
        lines.append("")
        lines.append("  The timeline and what each number means for the design are in `docs/POSTMORTEM.md`.")
    return "\n".join(lines) or "_No results yet: run `make bootstrap`, then `make load` and `make chaos`._"


def main() -> int:
    hpa, chaos = latest("load/results/hpa-2*.json"), latest("chaos/results/*.json")
    k6 = latest("load/results/hpa-load.json")
    if "--check" in sys.argv:
        missing = [n for n, v in (("load/results/hpa-2*.json", hpa), ("chaos/results/*.json", chaos)) if v is None]
        print("missing: " + ", ".join(missing) if missing else "results present")
        return 1 if missing else 0
    text = section(hpa, chaos, k6)
    if "--write" in sys.argv:
        readme = ROOT / "README.md"
        content = readme.read_text(encoding="utf-8")
        start, end = "<!-- RESULTS -->", "<!-- /RESULTS -->"
        before, rest = content.split(start, 1)
        _, after = rest.split(end, 1)
        readme.write_text(before + start + "\n" + text + "\n" + end + after, encoding="utf-8", newline="\n")
        print("wrote README.md")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
