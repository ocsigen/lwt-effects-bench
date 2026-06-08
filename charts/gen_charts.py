#!/usr/bin/env python3
# Generate horizontal-bar SVG charts for the benchmark README.
# No dependencies: emits SVG by hand so the charts render inline on GitHub and
# stay reproducible (data + generator are versioned).

import os

# Colours per "family"
GREY   = "#9aa0a6"   # Lwt classic
BLUE   = "#1a73e8"   # Lwt_effects (Compat, monadic — the drop-in model)
GREEN  = "#188038"   # Lwt_effects (direct)
ORANGE = "#e8710a"   # Eio
PURPLE = "#8430ce"   # Miou

W = 760
LEFT = 250          # label column
RIGHT = 70          # value column
BARH = 26
GAP = 12
PADTOP = 54
PADBOT = 16

def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

def chart(path, title, subtitle, unit, rows, lower_better):
    # rows: list of (label, value, colour)
    n = len(rows)
    h = PADTOP + n * (BARH + GAP) - GAP + PADBOT
    bararea = W - LEFT - RIGHT
    vmax = max(v for _, v, _ in rows)
    best = min(v for _, v, _ in rows) if lower_better else max(v for _, v, _ in rows)
    out = []
    out.append(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{h}" '
               f'font-family="-apple-system,Segoe UI,Roboto,sans-serif" font-size="13">')
    out.append(f'<rect width="{W}" height="{h}" fill="white"/>')
    out.append(f'<text x="16" y="24" font-size="16" font-weight="700">{esc(title)}</text>')
    arrow = "lower is better ↓" if lower_better else "higher is better ↑"
    out.append(f'<text x="16" y="42" fill="#5f6368">{esc(subtitle)} — {arrow} ({esc(unit)})</text>')
    y = PADTOP
    for label, v, colour in rows:
        bw = max(2, round(bararea * v / vmax))
        is_best = (v == best)
        bold = ' font-weight="700"' if is_best else ''
        dim = '' if is_best else ' opacity="0.72"'
        star = ' ★' if is_best else ''
        ty = round(y + BARH * 0.68)
        out.append(f'<text x="{LEFT-10}" y="{ty}" text-anchor="end"{bold}>{esc(label)}</text>')
        out.append(f'<rect x="{LEFT}" y="{y}" width="{bw}" height="{BARH}" rx="3" fill="{colour}"{dim}/>')
        val = f"{v:,.0f}" if v >= 100 else f"{v:.1f}"
        out.append(f'<text x="{LEFT+bw+8}" y="{ty}" fill="#202124"{bold}>{val}{star}</text>')
        y += BARH + GAP
    out.append('</svg>')
    with open(path, "w") as f:
        f.write("\n".join(out))
    print("wrote", path)

here = os.path.dirname(os.path.abspath(__file__))
def p(name): return os.path.join(here, name)

# 1. Scheduling: 1000 fibers x 1000 yields
chart(p("scheduling.svg"),
      "Scheduling — pure cooperative yielding",
      "1000 fibers × 1000 yields, no I/O", "ns per yield",
      [("Miou", 423, PURPLE),
       ("Lwt", 247, GREY),
       ("Eio", 92, ORANGE),
       ("Lwt_effects", 52, GREEN)],
      lower_better=True)

# 2. Monadic bind over a pending promise
chart(p("bind.svg"),
      "Monadic bind on a pending promise",
      "1000 binds over pause × 1000 (Lwt-family only)", "ns per bind",
      [("Lwt", 1430, GREY),
       ("Lwt_effects (effect bind)", 107, GREEN),
       ("Lwt_effects (Compat / mbind)", 87, BLUE)],
      lower_better=True)

# 3. Ping-pong latency, 1-byte payload
chart(p("pingpong.svg"),
      "Ping-pong latency over a socketpair (1 byte)",
      "round-trip latency", "µs per round-trip",
      [("Miou", 23.5, PURPLE),
       ("Lwt_effects Compat (epoll)", 11.6, BLUE),
       ("Lwt_effects direct (epoll)", 11.0, GREEN),
       ("Lwt (epoll)", 10.2, GREY),
       ("Lwt_effects Compat (io_uring)", 7.4, BLUE),
       ("Eio (io_uring)", 6.9, ORANGE),
       ("Lwt_effects direct (io_uring)", 6.1, GREEN)],
      lower_better=True)

# 4. Echo TCP throughput, 100 connections
chart(p("echo.svg"),
      "Echo TCP — 100 concurrent connections",
      "100 conn × 1000 msgs × 64 B", "round-trips / second",
      [("Lwt_effects direct (io_uring)", 107000, GREEN),
       ("Lwt_effects Compat (io_uring)", 94000, BLUE),
       ("Eio (io_uring)", 92000, ORANGE),
       ("Lwt_effects direct (epoll)", 70000, GREEN),
       ("Lwt (epoll)", 67000, GREY),
       ("Lwt_effects Compat (epoll)", 62000, BLUE),
       ("Miou", 20000, PURPLE)],
      lower_better=False)

# 5. cohttp HTTP throughput, new-connection-per-request
chart(p("cohttp.svg"),
      "cohttp HTTP — same connection model (new conn / request)",
      "50 conn × 200 req, GET /", "requests / second",
      [("cohttp / Lwt_effects (native)", 11698, BLUE),
       ("cohttp-eio", 8604, ORANGE),
       ("cohttp-lwt (Lwt_effects interop)", 5678, GREY),
       ("cohttp-lwt (Lwt_main)", 5611, GREY)],
      lower_better=False)
