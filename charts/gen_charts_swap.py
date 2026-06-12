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
# Colour = scheduler family; DARK shade = io_uring, LIGHT shade = epoll.
# The flagship (effect core + io_uring) is the most saturated bar.
EFF_DARK   = "#1a73e8"   # Lwt effect core, io_uring: vivid blue <- the one we want
EFF_LIGHT  = "#a8c7fa"   # Lwt effect core, epoll: light blue
CLA_DARK   = "#00796b"   # Lwt classic core, io_uring: dark blue-green (teal)
CLA_LIGHT  = "#b2dfdb"   # Lwt classic core, epoll: light blue-green
LAB_DARK   = "#455a64"   # lwt-effects-lab (semantics-breaking): dark blue-grey
LAB_LIGHT  = "#78909c"   # lwt-effects-lab, epoll / no engine: blue-grey
DIRECT     = "#6ea8dc"   # Lwt_direct (direct style on the effect core)
EIO        = "#e8710a"   # Eio (io_uring)
MIOU       = "#8430ce"   # Miou

chart(p("swap-scheduling.svg"),
      "Scheduling - pure cooperative yielding",
      "1000 fibers x 1000 yields, no I/O", "ns per yield",
      [("Miou (ppoll)", 409, MIOU),
       ("Lwt classic (pause)", 225, CLA_LIGHT),
       ("Lwt effect core (pause)", 207, EFF_LIGHT),
       ("Lwt_direct on effect core", 72, DIRECT),
       ("Eio", 86, EIO),
       ("lab: breaking direct yield", 59, LAB_LIGHT)],
      lower_better=True)

chart(p("swap-bind.svg"),
      "Monadic bind on a pending promise",
      "chain of 1000 binds over pause x 1000 (Lwt-family only)", "ns per bind",
      [("Lwt classic core", 1282, CLA_LIGHT),
       ("lab: breaking effect bind", 96, LAB_LIGHT),
       ("Lwt effect core", 87, EFF_LIGHT)],
      lower_better=True)

chart(p("swap-pingpong.svg"),
      "Ping-pong latency over a socketpair (1 byte)",
      "round-trip latency (bigarray rows for io_uring)", "us per round-trip",
      [("Miou (ppoll)", 21.8, MIOU),
       ("Lwt classic (epoll)", 9.5, CLA_LIGHT),
       ("Lwt effect core (epoll)", 9.2, EFF_LIGHT),
       ("Lwt classic (io_uring)", 6.5, CLA_DARK),
       ("Lwt effect core (io_uring)", 6.5, EFF_DARK),
       ("Eio (io_uring)", 6.4, EIO),
       ("lab: breaking + own ring", 6.1, LAB_DARK)],
      lower_better=True)

chart(p("swap-echo.svg"),
      "Echo TCP - 100 concurrent connections",
      "100 conn x 1000 msgs x 64 B", "round-trips / second",
      [("lab: breaking + own ring", 108037, LAB_DARK),
       ("Lwt classic (io_uring)", 96187, CLA_DARK),
       ("Lwt effect core (io_uring)", 95302, EFF_DARK),
       ("Eio (io_uring)", 87750, EIO),
       ("Lwt effect core (epoll)", 77422, EFF_LIGHT),
       ("Lwt classic (epoll)", 73145, CLA_LIGHT),
       ("Miou (ppoll)", 21898, MIOU)],
      lower_better=False)

chart(p("swap-cohttp.svg"),
      "cohttp - unmodified cohttp-lwt-unix, recompiled",
      "50 conn x 200 req, GET /, new connection per request", "requests / second",
      [("cohttp-eio", 9368, EIO),
       ("Lwt effect core (io_uring, multishot + static resolver)", 7978, EFF_DARK),
       ("Lwt classic (io_uring, static resolver)", 7766, CLA_DARK),
       ("Lwt effect core (io_uring, multishot)", 7975, EFF_DARK),
       ("Lwt classic (io_uring)", 7172, CLA_DARK),
       ("Lwt effect core (epoll)", 6957, EFF_LIGHT),
       ("Lwt classic (epoll)", 6403, CLA_LIGHT)],
      lower_better=False)
