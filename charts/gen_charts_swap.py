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


# ============ corrected campaign + multishot accept + lab ============
# THE SHIPPED CONFIGURATION — the effect core on the io_uring engine
# (multishot accept included: it is part of the engine, not an option) —
# is bright magenta and labeled "Lwt effects (io_uring)" in EVERY chart.
# Other colours = scheduler family; DARK shade = io_uring, LIGHT = epoll.
FLAGSHIP   = "#e6007e"   # Lwt effects (io_uring): THE shipped config, magenta
EFF_DARK   = "#1a73e8"   # effect core, io_uring + an optional app config
EFF_LIGHT  = "#a8c7fa"   # effect core, epoll/libev: light blue
CLA_DARK   = "#00796b"   # Lwt classic core, io_uring: dark blue-green (teal)
CLA_LIGHT  = "#b2dfdb"   # Lwt classic core, epoll: light blue-green
LAB_DARK   = "#455a64"   # lwt-effects-lab (semantics-breaking): dark blue-grey
LAB_LIGHT  = "#78909c"   # lwt-effects-lab, epoll / no engine: blue-grey
DIRECT     = "#6ea8dc"   # Lwt_direct (direct style on the effect core)
EIO        = "#e8710a"   # Eio (io_uring)
MIOU       = "#8430ce"   # Miou

# Data: re-measured 2026-06-12 evening with the FINAL core (waiter-leak fix
# 856e73f18 + pause-cadence conformance 7c7f9a438), 2-3 interleaved rounds,
# cool machine; midpoints of rounds (mins for pingpong, best-of-3 for cohttp),
# matching the README tables.
#
# UNIFORM ROW ORDER, bottom -> top: Lwt classic epoll, Lwt classic io_uring,
# Lwt effect epoll, Lwt effect io_uring, (Lwt_direct,) lab — the lab rows
# stay grouped with the Lwt family, capping its block — then Eio, Miou.
# (Rows render top to bottom, so the lists below are written in REVERSE.)
# The cohttp-family charts show cohttp-lwt ONLY: cohttp-eio and httpcats are
# very different implementations — their numbers are quoted in the README
# text, not drawn as bars people would compare at a glance. The httpun chart
# keeps the Eio bar: there the protocol engine is identical (that is its
# whole point).

chart(p("swap-scheduling.svg"),
      "Scheduling - pure cooperative yielding",
      "1000 fibers x 1000 yields, no I/O", "ns per yield",
      [("Miou (ppoll)", 425, MIOU),
       ("Eio", 88, EIO),
       ("lab: breaking direct yield", 59, LAB_LIGHT),
       ("Lwt_direct on effect core", 72, DIRECT),
       ("Lwt effects (pause)", 230, FLAGSHIP),
       ("Lwt classic (pause)", 245, CLA_LIGHT)],
      lower_better=True)

chart(p("swap-bind.svg"),
      "Monadic bind - resolved (the hot path)",
      "chain of 1000 binds over return x 1000 (Lwt-family only)", "ns per bind",
      [("lab: breaking effect bind", 9.5, LAB_LIGHT),
       ("Lwt effects", 5.2, FLAGSHIP),
       ("Lwt classic core", 11.0, CLA_LIGHT)],
      lower_better=True)

chart(p("swap-bind-suspended.svg"),
      "Monadic bind - suspended, through Lwt_main.run",
      "chain of 1000 binds over pause x 1000; one engine lap per pause "
      "generation (classic Lwt semantics)", "ns per bind",
      [("lab: own scheduler, no engine to run", 96, LAB_LIGHT),
       ("Lwt effects", 1273, FLAGSHIP),
       ("Lwt classic core", 1417, CLA_LIGHT)],
      lower_better=True)

chart(p("swap-pingpong.svg"),
      "Ping-pong latency over a socketpair (1 byte)",
      "round-trip latency (bigarray rows for io_uring)", "us per round-trip",
      [("Miou (ppoll)", 22.8, MIOU),
       ("Eio (io_uring)", 6.4, EIO),
       ("lab: breaking + own ring", 6.1, LAB_DARK),
       ("Lwt effects (io_uring)", 7.3, FLAGSHIP),
       ("Lwt effects (epoll)", 9.6, EFF_LIGHT),
       ("Lwt classic (io_uring)", 7.4, CLA_DARK),
       ("Lwt classic (epoll)", 9.9, CLA_LIGHT)],
      lower_better=True)

chart(p("swap-echo.svg"),
      "Echo TCP - 100 concurrent connections",
      "100 conn x 1000 msgs x 64 B; the three io_uring rows are a "
      "statistical tie", "round-trips / second",
      [("Miou (ppoll)", 21500, MIOU),
       ("Eio (io_uring)", 97100, EIO),
       ("lab: breaking + own ring", 108037, LAB_DARK),
       ("Lwt effects (io_uring)", 95500, FLAGSHIP),
       ("Lwt effects (epoll)", 70400, EFF_LIGHT),
       ("Lwt classic (io_uring)", 92600, CLA_DARK),
       ("Lwt classic (epoll)", 71300, CLA_LIGHT)],
      lower_better=False)

chart(p("swap-cohttp.svg"),
      "cohttp-lwt-unix, unmodified, recompiled against each core",
      "50 conn x 200 req, GET /, new connection per request, in-process "
      "client", "requests / second",
      [("Lwt effects (io_uring) + static resolver (client option)", 8174, EFF_DARK),
       ("Lwt effects (io_uring)", 7486, FLAGSHIP),
       ("Lwt effects (epoll)", 6557, EFF_LIGHT),
       ("Lwt classic (io_uring) + static resolver (client option)", 7671, CLA_DARK),
       ("Lwt classic (io_uring)", 6964, CLA_DARK),
       ("Lwt classic (epoll)", 6105, CLA_LIGHT)],
      lower_better=False)

# ============ realistic HTTP suite (README section 6) ============
# wrk2 over real TCP; post-leak-fix interleaved runs (results/retro2-*,
# plain2-*). cohttp-lwt only on the charts; cohttp-eio and httpcats are
# quoted in the README text (different implementations).

chart(p("swap-http-saturation.svg"),
      "cohttp-lwt-unix under an external load generator - saturation",
      "GET /plaintext, wrk -t4 -c64 keep-alive, one core", "requests / second",
      [("Lwt effects (io_uring)", 43100, FLAGSHIP),
       ("Lwt effects (libev)", 34999, EFF_LIGHT),
       ("Lwt classic (io_uring)", 45018, CLA_DARK),
       ("Lwt classic (libev)", 35482, CLA_LIGHT)],
      lower_better=False)

chart(p("swap-http-p99.svg"),
      "cohttp-lwt-unix under an external load generator - tail latency",
      "GET / (2 KB), wrk2 at a fixed 20k req/s, p99 (median over rounds)", "ms",
      [("Lwt effects (io_uring)", 17.3, FLAGSHIP),
       ("Lwt effects (libev)", 18.5, EFF_LIGHT),
       ("Lwt classic (io_uring)", 13.1, CLA_DARK),
       ("Lwt classic (libev)", 16.4, CLA_LIGHT)],
      lower_better=True)

# httpun: one scheduler-agnostic protocol engine (the maintained httpaf
# fork), thin Gluten adapters, the request handler shared VERBATIM between
# the Lwt and Eio servers — the HTTP stack held constant, so the Eio bar
# BELONGS on this chart. Midpoints of two interleaved rounds.
chart(p("swap-httpun-saturation.svg"),
      "httpun - same protocol engine, scheduler isolated",
      "GET /plaintext, wrk -t4 -c64 keep-alive, one core; handler shared "
      "verbatim between the Lwt and Eio servers", "requests / second",
      [("httpun-eio (gluten-eio adapter)", 34700, EIO),
       ("Lwt effects (io_uring)", 89100, FLAGSHIP),
       ("Lwt effects (libev)", 67500, EFF_LIGHT),
       ("Lwt classic (io_uring)", 99100, CLA_DARK),
       ("Lwt classic (libev)", 68900, CLA_LIGHT)],
      lower_better=False)
