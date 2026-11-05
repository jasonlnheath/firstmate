#!/usr/bin/env python3
"""Render the durable-watcher benchmark comparison table.

Reads two evidence files written by bin/fm-durable-watch-bench.sh and prints a
plain comparison table: metric rows with baseline, durable, and delta columns.
Runs without any backend so a recorded run can be re-reported later.
"""

import json
import sys


def load(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def totals(ev: dict) -> dict:
    per = ev.get("perCycle", [])
    return {
        "input": sum(c["tokens"]["input"] for c in per),
        "cacheRead": sum(c["tokens"]["cacheRead"] for c in per),
        "totalTokens": sum(c["tokens"]["totalTokens"] for c in per),
        "wallMs": sum(c["wallMs"] for c in per),
    }


def fmt(x: float) -> str:
    return f"{x:.1f}"


def delta_str(baseline: float, durable: float) -> str:
    d = durable - baseline
    sign = "+" if d > 0 else ""
    return f"{sign}{d:.1f}"


def restart_avg(ev: dict) -> float | None:
    rs = ev.get("restarts", [])
    if not rs:
        return None
    return sum(r["recoveryMs"] for r in rs) / len(rs)


def main() -> int:
    base = load(sys.argv[1])
    dur = load(sys.argv[2])
    tb, td = totals(base), totals(dur)
    n = base.get("cycles", len(base.get("perCycle", [])))
    cycles = max(n, 1)

    mode = dur.get("mode", "unknown")
    provider = dur.get("provider", "unknown")
    model = dur.get("model", "unknown")
    print(f"mode: {mode} provider: {provider} model: {model} cycles: {cycles}")
    if provider == "faux":
        print("note: faux token counts are synthetic; they measure structure, not cost")

    header = f"{'metric':<34}{'baseline':>14}{'durable':>14}{'delta':>14}"
    print(header)
    print("-" * len(header))

    rows = [
        ("tokens/cycle (input)", tb["input"] / cycles, td["input"] / cycles),
        ("tokens/cycle (cacheRead)", tb["cacheRead"] / cycles, td["cacheRead"] / cycles),
        ("tokens/cycle (total)", tb["totalTokens"] / cycles, td["totalTokens"] / cycles),
        ("wall time/cycle (ms)", tb["wallMs"] / cycles, td["wallMs"] / cycles),
    ]
    for name, bv, dv in rows:
        print(f"{name:<34}{fmt(bv):>14}{fmt(dv):>14}{delta_str(bv, dv):>14}")

    fe_b = base.get("finalActiveEntries", 0)
    fe_d = dur.get("finalActiveEntries", 0)
    print(f"{'context growth (final entries)':<34}{fe_b:>14}{fe_d:>14}{fe_d - fe_b:>14}")

    rb, rd = restart_avg(base), restart_avg(dur)
    rb_s = "n/a" if rb is None else fmt(rb)
    rd_s = "n/a" if rd is None else fmt(rd)
    if rb is None or rd is None:
        d_s = "n/a"
    else:
        d_s = delta_str(rb, rd)
    print(f"{'restart recovery (ms avg)':<34}{rb_s:>14}{rd_s:>14}{d_s:>14}")

    sb = base.get("steers", {})
    sd = dur.get("steers", {})

    def delivery(s: dict) -> str:
        return f"{s.get('answered', 0)}/{s.get('submitted', 0)} ({s.get('missed', 0)} missed)"

    print(f"{'steer delivery':<34}{delivery(sb):>14}{delivery(sd):>14}{'':>14}")
    print(
        f"totals: tokens baseline={tb['totalTokens']} durable={td['totalTokens']} "
        f"delta={td['totalTokens'] - tb['totalTokens']} | "
        f"wall baseline={tb['wallMs']}ms durable={td['wallMs']}ms "
        f"delta={td['wallMs'] - tb['wallMs']}ms"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
