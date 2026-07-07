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

# The shipped configuration is NEVER dimmed: its magenta must be the exact
# same colour in every chart (the star/bold still mark each chart's best).
FLAGSHIP = "#e6007e"

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
        # Bold + star mark each chart's best; bar colours are NEVER
        # dimmed — every configuration keeps its exact colour everywhere.
        is_best = (v == best)
        bold = ' font-weight="700"' if is_best else ''
        star = ' ★' if is_best else ''
        ty = round(y + BARH * 0.68)
        out.append(f'<text x="{LEFT-10}" y="{ty}" text-anchor="end"{bold}>{esc(label)}</text>')
        out.append(f'<rect x="{LEFT}" y="{y}" width="{bw}" height="{BARH}" rx="3" fill="{colour}"/>')
        val = f"{v:,.0f}" if v >= 100 else f"{v:.1f}"
        out.append(f'<text x="{LEFT+bw+8}" y="{ty}" fill="#202124"{bold}>{val}{star}</text>')
        y += BARH + GAP
    out.append('</svg>')
    with open(path, "w") as f:
        f.write("\n".join(out))
    print("wrote", path)

here = os.path.dirname(os.path.abspath(__file__))
def p(name): return os.path.join(here, name)


# ============ 2026-07 trio session (lean core added) + lab ============
# THE SHIPPED CONFIGURATION — the LEAN core (the rewrite without effects,
# branch lwt-lean-core) on the io_uring engine (multishot accept included:
# it is part of the engine, not an option) — is bright magenta and labeled
# "Lwt lean (io_uring)" in EVERY chart.
# Other colours = scheduler family; DARK shade = io_uring, LIGHT = epoll.
# FLAGSHIP (defined above chart()): Lwt lean (io_uring), THE shipped
# config, magenta — never dimmed.
LEAN_LIGHT = "#f3a6ce"   # lean core, epoll/libev: light pink
LEAN_STATIC= "#b0005e"   # lean core, io_uring + an optional client config
EFF_DARK   = "#1a73e8"   # effect core, io_uring (+ optional app config)
EFF_LIGHT  = "#a8c7fa"   # effect core, epoll/libev: light blue
CLA_DARK   = "#00796b"   # Lwt classic core, io_uring: dark blue-green (teal)
CLA_LIGHT  = "#b2dfdb"   # Lwt classic core, epoll: light blue-green
LAB        = "#78909c"   # lwt-effects-lab: ONE colour for all lab rows; each
                         # row is a DIFFERENT semantics-breaking experiment,
                         # named in its label ("lab: breaking <what>")
DIRECT     = "#6ea8dc"   # Lwt_direct (direct style on the rewritten core)
EIO        = "#e8710a"   # Eio (io_uring)
MIOU       = "#8430ce"   # Miou

# Data: the 2026-07 trio session (classic / effects / lean interleaved in
# the same windows, cool idle machine), matching the README tables: mins for
# the pinned micro-benches and ping-pong, medians over rounds for cohttp and
# the wrk2 suite. Rows not re-measured in that session keep their June value
# and say "(June)" in their label (lab, Miou echo, httpun-eio).
#
# UNIFORM ROW ORDER, bottom -> top: Lwt classic epoll, Lwt classic io_uring,
# Lwt effects epoll, Lwt effects io_uring, Lwt lean epoll, Lwt lean io_uring
# (the flagship caps the Lwt block), (Lwt_direct,) lab — then Eio, Miou.
# (Rows render top to bottom, so the lists below are written in REVERSE.)
# The cohttp-family charts show cohttp-lwt ONLY: cohttp-eio and httpcats are
# very different implementations — their numbers are quoted in the README
# text, not drawn as bars people would compare at a glance. The httpun chart
# keeps the Eio bar: there the protocol engine is identical (that is its
# whole point).

chart(p("swap-scheduling.svg"),
      "Scheduling - pure cooperative yielding",
      "1000 fibers x 1000 yields, no I/O", "ns per yield",
      [("Miou (ppoll)", 470, MIOU),
       ("Eio", 93, EIO),
       ("lab: breaking direct yield (June)", 59, LAB),
       ("Lwt_direct on lean core", 68, DIRECT),
       ("Lwt lean (pause)", 235, FLAGSHIP),
       ("Lwt effects (pause)", 243, EFF_DARK),
       ("Lwt classic (pause)", 248, CLA_LIGHT)],
      lower_better=True)

chart(p("swap-bind.svg"),
      "Monadic bind - resolved (the hot path)",
      "chain of 1000 binds over return x 1000 (Lwt-family only)", "ns per bind",
      [("lab: breaking suspending bind (June)", 9.5, LAB),
       ("Lwt lean", 4.9, FLAGSHIP),
       ("Lwt effects", 5.5, EFF_DARK),
       ("Lwt classic", 10.9, CLA_LIGHT)],
      lower_better=True)

chart(p("swap-bind-suspended.svg"),
      "Monadic bind - suspended, through Lwt_main.run",
      "chain of 1000 binds over pause x 1000; one engine lap per pause "
      "generation (classic Lwt semantics)", "ns per bind",
      [("lab: breaking suspending bind, no engine (June)", 96, LAB),
       ("Lwt lean", 1345, FLAGSHIP),
       ("Lwt effects", 1349, EFF_DARK),
       ("Lwt classic", 1392, CLA_LIGHT)],
      lower_better=True)

chart(p("swap-pingpong.svg"),
      "Ping-pong latency over a socketpair (1 byte)",
      "round-trip latency (bigarray rows for io_uring)", "us per round-trip",
      [("Miou (ppoll)", 21.9, MIOU),
       ("Eio (io_uring)", 6.7, EIO),
       ("lab: breaking direct + own ring (June)", 6.1, LAB),
       ("Lwt lean (io_uring)", 7.1, FLAGSHIP),
       ("Lwt lean (epoll)", 9.6, LEAN_LIGHT),
       ("Lwt effects (io_uring)", 7.0, EFF_DARK),
       ("Lwt effects (epoll)", 9.5, EFF_LIGHT),
       ("Lwt classic (io_uring)", 7.0, CLA_DARK),
       ("Lwt classic (epoll)", 9.6, CLA_LIGHT)],
      lower_better=True)

chart(p("swap-echo.svg"),
      "Echo TCP - 100 concurrent connections",
      "100 conn x 1000 msgs x 64 B; the io_uring rows and Eio are a "
      "statistical tie", "round-trips / second",
      [("Miou (ppoll)", 21200, MIOU),
       ("Eio (io_uring)", 91300, EIO),
       ("lab: breaking direct + own ring (June)", 108037, LAB),
       ("Lwt lean (io_uring)", 88600, FLAGSHIP),
       ("Lwt lean (epoll)", 68200, LEAN_LIGHT),
       ("Lwt effects (io_uring)", 89100, EFF_DARK),
       ("Lwt effects (epoll)", 66600, EFF_LIGHT),
       ("Lwt classic (io_uring)", 88400, CLA_DARK),
       ("Lwt classic (epoll)", 66000, CLA_LIGHT)],
      lower_better=False)

chart(p("swap-cohttp.svg"),
      "cohttp-lwt-unix, unmodified, recompiled against each core",
      "50 conn x 200 req, GET /, new connection per request, in-process "
      "client; medians of 3 rounds", "requests / second",
      [("Lwt lean (io_uring) + static resolver (client option)", 6351, LEAN_STATIC),
       ("Lwt lean (io_uring)", 5963, FLAGSHIP),
       ("Lwt lean (epoll)", 5004, LEAN_LIGHT),
       ("Lwt effects (io_uring) + static resolver (client option)", 6361, EFF_DARK),
       ("Lwt effects (io_uring)", 6045, EFF_DARK),
       ("Lwt effects (epoll)", 5035, EFF_LIGHT),
       ("Lwt classic (io_uring) + static resolver (client option)", 5732, CLA_DARK),
       ("Lwt classic (io_uring)", 5235, CLA_DARK),
       ("Lwt classic (epoll)", 4614, CLA_LIGHT)],
      lower_better=False)

# ============ realistic HTTP suite (README section 6) ============
# wrk2 over real TCP; 2026-07 trio session, interleaved. cohttp-lwt only on
# the charts; cohttp-eio and httpcats are quoted in the README text
# (different implementations, June windows).

chart(p("swap-http-saturation.svg"),
      "cohttp-lwt-unix under an external load generator - saturation",
      "GET /plaintext, wrk -t4 -c64 keep-alive, one core", "requests / second",
      [("Lwt lean (io_uring)", 42600, FLAGSHIP),
       ("Lwt lean (epoll)", 34000, LEAN_LIGHT),
       ("Lwt effects (io_uring)", 43000, EFF_DARK),
       ("Lwt effects (epoll)", 35000, EFF_LIGHT),
       ("Lwt classic (io_uring)", 44000, CLA_DARK),
       ("Lwt classic (epoll)", 36100, CLA_LIGHT)],
      lower_better=False)

chart(p("swap-http-p99.svg"),
      "cohttp-lwt-unix under an external load generator - tail latency",
      "GET / (2 KB), wrk2 at a fixed 20k req/s, p99 (median of 8 rounds; "
      "30-70 ms spikes hit every core in some rounds)", "ms",
      [("Lwt lean (io_uring)", 18.8, FLAGSHIP),
       ("Lwt lean (epoll)", 20.3, LEAN_LIGHT),
       ("Lwt effects (io_uring)", 18.6, EFF_DARK),
       ("Lwt effects (epoll)", 21.0, EFF_LIGHT),
       ("Lwt classic (io_uring)", 18.7, CLA_DARK),
       ("Lwt classic (epoll)", 19.8, CLA_LIGHT)],
      lower_better=True)

# httpun: one scheduler-agnostic protocol engine (the maintained httpaf
# fork), thin Gluten adapters, the request handler shared VERBATIM between
# the Lwt and Eio servers — the HTTP stack held constant, so the Eio bar
# BELONGS on this chart. Medians of 3 interleaved rounds (Lwt trio).
chart(p("swap-httpun-saturation.svg"),
      "httpun - same protocol engine, scheduler isolated",
      "GET /plaintext, wrk -t4 -c64 keep-alive, one core; handler shared "
      "verbatim between the Lwt and Eio servers", "requests / second",
      [("httpun-eio (gluten-eio adapter)", 35600, EIO),
       ("Lwt lean (io_uring)", 89300, FLAGSHIP),
       ("Lwt lean (epoll)", 75200, LEAN_LIGHT),
       ("Lwt effects (io_uring)", 93600, EFF_DARK),
       ("Lwt effects (epoll)", 77100, EFF_LIGHT),
       ("Lwt classic (io_uring)", 92600, CLA_DARK),
       ("Lwt classic (epoll)", 72800, CLA_LIGHT)],
      lower_better=False)
