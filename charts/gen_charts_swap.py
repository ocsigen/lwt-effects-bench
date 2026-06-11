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


# ============ 2026-06-11 campaign: the in-place core swap ============
# GREY = classic Lwt core, BLUE = effect-based core (the SAME lwt package,
# recompiled — drop-in), ORANGE = Eio, PURPLE = Miou, GREEN = direct style.

# 1. Scheduling: 1000 fibers x 1000 yields (pause storm)
chart(p("swap-scheduling.svg"),
      "Scheduling — pure cooperative yielding",
      "1000 fibers × 1000 yields, no I/O", "ns per yield",
      [("Miou", 534, PURPLE),
       ("Lwt (effect core)", 407, BLUE),
       ("Lwt (classic core)", 333, GREY),
       ("Lwt_direct (effect core)", 196, GREEN),
       ("Eio", 120, ORANGE)],
      lower_better=True)

# 2. Monadic bind on a pending promise (the server-loop pattern)
chart(p("swap-bind.svg"),
      "Monadic bind on a pending promise",
      "chain of 1000 binds over pause × 1000 (Lwt-family only)", "ns per bind",
      [("Lwt (classic core)", 1700, GREY),
       ("Lwt (effect core)", 118, BLUE)],
      lower_better=True)

# 3. Ping-pong latency, 1-byte payload
chart(p("swap-pingpong.svg"),
      "Ping-pong latency over a socketpair (1 byte)",
      "round-trip latency (bigarray rows for io_uring)", "µs per round-trip",
      [("Miou", 27.4, PURPLE),
       ("Lwt (effect core, epoll)", 11.6, BLUE),
       ("Lwt (classic core, epoll)", 10.8, GREY),
       ("Lwt (effect core, io_uring)", 8.1, BLUE),
       ("Eio (io_uring)", 7.9, ORANGE),
       ("Lwt (classic core, io_uring)", 7.8, GREY)],
      lower_better=True)

# 4. Echo TCP throughput, 100 connections
chart(p("swap-echo.svg"),
      "Echo TCP — 100 concurrent connections",
      "100 conn × 1000 msgs × 64 B", "round-trips / second",
      [("Eio (io_uring)", 56181, ORANGE),
       ("Lwt (effect core, io_uring)", 51279, BLUE),
       ("Lwt (classic core, io_uring)", 49914, GREY),
       ("Lwt (classic core, epoll)", 43967, GREY),
       ("Lwt (effect core, epoll)", 43330, BLUE),
       ("Miou", 17205, PURPLE)],
      lower_better=False)

# 5. cohttp: the UNMODIFIED cohttp-lwt-unix, recompiled
chart(p("swap-cohttp.svg"),
      "cohttp — unmodified cohttp-lwt-unix, recompiled",
      "50 conn × 200 req, GET /, new connection per request", "requests / second",
      [("cohttp-eio", 7935, ORANGE),
       ("cohttp-lwt (effect core, io_uring)", 5864, BLUE),
       ("cohttp-lwt (classic core, io_uring)", 4999, GREY),
       ("cohttp-lwt (classic core, epoll)", 4829, GREY),
       ("cohttp-lwt (effect core, epoll)", 4692, BLUE)],
      lower_better=False)
