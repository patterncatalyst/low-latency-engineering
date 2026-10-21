"""Aligned percentile table in microseconds (no mean, by design)."""

from __future__ import annotations

from typing import Any

HEADERS = (
    "example",
    "language",
    "variant",
    "count",
    "dropped",
    "p50",
    "p90",
    "p99",
    "p99.9",
    "max",
)


def _us(ns: int) -> str:
    return f"{ns / 1000:.1f}"


def row_of(report: dict[str, Any]) -> tuple[str, ...]:
    p = report["percentiles"]
    return (
        report["example"],
        report["language"],
        report["variant"],
        str(report["count"]),
        str(report["dropped"]),
        _us(p["p50"]),
        _us(p["p90"]),
        _us(p["p99"]),
        _us(p["p99_9"]),
        _us(p["max"]),
    )


def format_rows(reports: list[dict[str, Any]], header: bool = False) -> str:
    rows = [row_of(r) for r in reports]
    if header:
        rows.insert(0, HEADERS)
    widths = [max(len(r[i]) for r in rows) for i in range(len(HEADERS))]
    lines = []
    for r in rows:
        cells = [
            c.ljust(w) if i < 3 else c.rjust(w)
            for i, (c, w) in enumerate(zip(r, widths, strict=True))
        ]
        lines.append("  ".join(cells).rstrip())
    return "\n".join(lines)
