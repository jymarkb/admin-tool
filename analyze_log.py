#!/usr/bin/env python3
"""Analyzer for scanner_v3.1.lua character telemetry logs.

Log line format (emitted by scanner_v3.1.lua `say()`):
    HH:MM:SS #NNNN TAG<pad> payload

Usage:
    python3 analyze_log.py LOG [LOG ...]

Passing more than one log prints a side-by-side comparison table at the end.

NOTE ON FIELD SEMANTICS (read from the scanner source, not guessed):
  * CF=   is `posSpeed`  -> magnitude of (pos - lastPos)/dt, i.e. how fast the
           CFrame actually travelled. This is the teleport detector.
  * Phys= is `physSpeed` -> magnitude of root.AssemblyLinearVelocity.
  * Horiz= is the XZ component of AssemblyLinearVelocity.
  * dt=   is MISLABELLED in the scanner. It is NOT the frame delta. It is
           `t - lastLargeMoveT`, i.e. seconds since the previous LARGE_MOVE *or*
           ZERO_HORIZ event (both share one variable). Values of 0.000 mean two
           events fired on the same Heartbeat, not that no time passed.
  * hVar= is the variance of root.Position.Y over the last 30 samples.
"""

import re
import sys
import statistics as st
from collections import Counter
from datetime import datetime

LINE = re.compile(r"^(\d{2}:\d{2}:\d{2})\s+#(\d+)\s+([A-Z_]+)\s*(.*)$")

NUM = r"([-\d.]+)"
VEC = r"\(\s*([-\d.]+)\s*,\s*([-\d.]+)\s*,\s*([-\d.]+)\s*\)"

RE_LARGE = re.compile(
    rf"^{NUM} studs \| CF={NUM} Phys={NUM} Horiz={NUM} \| Pos={VEC} \| "
    rf"Y={NUM} H={NUM} \| Plat=(\w+) Anch=(\w+) Net=(\w+) \| Egg=(\w+) "
    rf"Zone=(\w+) \| Vel={VEC} \| dt={NUM} \| hVar={NUM}"
)
RE_ZERO = re.compile(
    rf"^Horiz={NUM} moved={NUM} \| CF={NUM} Phys={NUM} \| Vel={VEC} \| "
    rf"Y={NUM} H={NUM} \| Plat=(\w+) Egg=(\w+) \| dt={NUM} \| streak=(\d+)"
)
RE_BURST = re.compile(
    rf"^CF={NUM} >> Phys={NUM} Horiz={NUM} \| Y={NUM} H={NUM} \| "
    rf"Plat=(\w+) Egg=(\w+)"
)
RE_UNSTABLE = re.compile(rf"^hVar={NUM} \| Y={NUM} H={NUM} \| Pos={VEC}")
RE_ZONE = re.compile(rf"^(\S+) → (\S+) \| Pos={VEC} \| Holding=(\w+)")
RE_ANCHOR = re.compile(rf"^(true|false) → (true|false) \| Pos={VEC} Y={NUM}")
RE_DIRFLIP = re.compile(rf"^Dot={NUM} moved={NUM} \| Pos={VEC} \| Zone=(\w+)")
RE_HJUMP = re.compile(rf"^Y {NUM} → {NUM} \(Δ{NUM}\) \| H={NUM} \| Pos={VEC} \| Zone=(\w+)")
RE_FSTART = re.compile(rf"^AUTO \| Pos={VEC} \| Y={NUM} H={NUM} \| Egg=(\w+) Zone=(\w+)")
RE_FEND = re.compile(rf"^dur={NUM}s dist={NUM} \| Pos={VEC} \| Zone=(\w+)")
RE_EGG = re.compile(rf"^(\w+) → (\w+) \| Pos={VEC} \| Zone=(\w+)")
RE_HARD = re.compile(rf"^{NUM} studs \| → {VEC} \| Zone=(\w+) \| Egg=(\w+) \| Y={NUM} H={NUM} \| Anch=(\w+)")


def parse(path):
    rows = []
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            m = LINE.match(raw.rstrip("\n"))
            if not m:
                continue
            rows.append({"t": m.group(1), "seq": int(m.group(2)),
                         "tag": m.group(3), "pay": m.group(4).strip()})
    return rows


def secs(a, b):
    fmt = "%H:%M:%S"
    return (datetime.strptime(b, fmt) - datetime.strptime(a, fmt)).total_seconds()


def f(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def collect(rows):
    d = {k: [] for k in ("large", "zero", "burst", "unstable", "zone",
                         "anchor", "dirflip", "hjump", "fstart", "fend",
                         "egg", "hard")}
    positions = []
    for r in rows:
        tag, p = r["tag"], r["pay"]
        if tag == "LARGE_MOVE":
            m = RE_LARGE.match(p)
            if m:
                g = m.groups()
                d["large"].append({
                    "disp": f(g[0]), "cf": f(g[1]), "phys": f(g[2]), "horiz": f(g[3]),
                    "pos": tuple(f(x) for x in g[4:7]), "y": f(g[7]), "h": f(g[8]),
                    "plat": g[9], "anch": g[10], "net": g[11], "egg": g[12],
                    "zone": g[13], "vel": tuple(f(x) for x in g[14:17]),
                    "gap": f(g[17]), "hvar": f(g[18]), "t": r["t"]})
                positions.append(d["large"][-1]["pos"])
        elif tag == "ZERO_HORIZ":
            m = RE_ZERO.match(p)
            if m:
                g = m.groups()
                d["zero"].append({
                    "horiz": f(g[0]), "moved": f(g[1]), "cf": f(g[2]), "phys": f(g[3]),
                    "vel": tuple(f(x) for x in g[4:7]), "y": f(g[7]), "h": f(g[8]),
                    "plat": g[9], "egg": g[10], "gap": f(g[11]), "streak": int(g[12]),
                    "t": r["t"]})
        elif tag == "CFRAME_BURST":
            m = RE_BURST.match(p)
            if m:
                g = m.groups()
                d["burst"].append({"cf": f(g[0]), "phys": f(g[1]), "horiz": f(g[2]),
                                   "y": f(g[3]), "h": f(g[4]), "t": r["t"]})
        elif tag == "HEIGHT_UNSTABLE":
            m = RE_UNSTABLE.match(p)
            if m:
                g = m.groups()
                d["unstable"].append({"hvar": f(g[0]), "y": f(g[1]), "h": f(g[2]),
                                      "pos": tuple(f(x) for x in g[3:6]), "t": r["t"]})
        elif tag == "ZONE":
            m = RE_ZONE.match(p)
            if m:
                g = m.groups()
                d["zone"].append({"from": g[0], "to": g[1],
                                  "pos": tuple(f(x) for x in g[2:5]),
                                  "holding": g[5], "t": r["t"]})
        elif tag == "ANCHOR_FLIP":
            m = RE_ANCHOR.match(p)
            if m:
                g = m.groups()
                d["anchor"].append({"from": g[0], "to": g[1],
                                    "pos": tuple(f(x) for x in g[2:5]),
                                    "y": f(g[5]), "t": r["t"]})
        elif tag == "DIR_FLIP":
            m = RE_DIRFLIP.match(p)
            if m:
                g = m.groups()
                d["dirflip"].append({"dot": f(g[0]), "moved": f(g[1]),
                                     "pos": tuple(f(x) for x in g[2:5]),
                                     "zone": g[5], "t": r["t"]})
        elif tag == "HEIGHT_JUMP":
            m = RE_HJUMP.match(p)
            if m:
                g = m.groups()
                d["hjump"].append({"y0": f(g[0]), "y1": f(g[1]), "dy": f(g[2]),
                                   "h": f(g[3]), "pos": tuple(f(x) for x in g[4:7]),
                                   "zone": g[7], "t": r["t"]})
        elif tag == "FLIGHT_START":
            m = RE_FSTART.match(p)
            if m:
                g = m.groups()
                d["fstart"].append({"pos": tuple(f(x) for x in g[0:3]), "y": f(g[3]),
                                    "h": f(g[4]), "egg": g[5], "zone": g[6], "t": r["t"]})
        elif tag == "FLIGHT_END":
            m = RE_FEND.match(p)
            if m:
                g = m.groups()
                d["fend"].append({"dur": f(g[0]), "dist": f(g[1]),
                                  "pos": tuple(f(x) for x in g[2:5]),
                                  "zone": g[5], "t": r["t"]})
        elif tag == "EGG_STATE":
            m = RE_EGG.match(p)
            if m:
                g = m.groups()
                d["egg"].append({"from": g[0], "to": g[1],
                                 "pos": tuple(f(x) for x in g[2:5]),
                                 "zone": g[5], "t": r["t"]})
        elif tag == "HARD_SNAP":
            d["hard"].append({"pay": p, "t": r["t"]})
    return d, positions


def bar(n, mx, width=28):
    if mx <= 0:
        return ""
    return "#" * max(1, round(n / mx * width))


def median_or_none(xs):
    xs = [x for x in xs if x is not None]
    return st.median(xs) if xs else None


def report(path):
    rows = parse(path)
    if not rows:
        print(f"\n!! {path}: no parsable lines\n")
        return None
    d, positions = collect(rows)
    tags = Counter(r["tag"] for r in rows)
    t0, t1 = rows[0]["t"], rows[-1]["t"]
    dur = secs(t0, t1)

    print("=" * 72)
    print(f"FILE   {path}")
    print("=" * 72)
    print(f"window   {t0} → {t1}   ({dur:.1f} s)")
    print(f"events   {len(rows)}   ({len(rows) / dur:.1f} evt/s)" if dur else "")

    print("\n-- TAG HISTOGRAM " + "-" * 56)
    mx = max(tags.values())
    for tag, n in tags.most_common():
        print(f"  {tag:<18} {n:>5}  {bar(n, mx)}")

    # ---- verdict ------------------------------------------------------
    bursts = d["burst"]
    ratios = [b["cf"] / b["phys"] for b in bursts if b["phys"] and b["phys"] > 0]
    max_ratio = max(ratios) if ratios else 0
    streak_max = max((z["streak"] for z in d["zero"]), default=0)

    print("\n-- VERDICT " + "-" * 62)
    if bursts and (len(bursts) >= 5 or max_ratio > 5):
        print("  CFRAME HIJACK — position forced externally, physics starved.")
        print(f"    {len(bursts)} CFRAME_BURST events, peak CF/Phys ratio {max_ratio:.0f}x")
    elif d["fstart"]:
        print("  AUTO-FLIGHT DETECTED — ZERO_HORIZ streak crossed the "
              f"{4}-sample auto-flight threshold.")
    elif d["zero"] or d["unstable"]:
        print("  MOVEMENT ANOMALY — no bursts, but horizontal velocity dropped "
              "to zero while position kept moving.")
    else:
        print("  CLEAN — velocity-driven movement, no CFrame forcing detected.")
        print("    (CFRAME_BURST=0, ZERO_HORIZ=0, HEIGHT_UNSTABLE=0)")

    # ---- movement -----------------------------------------------------
    print("\n-- MOVEMENT " + "-" * 61)
    large = d["large"]
    if large:
        cf = [x["cf"] for x in large if x["cf"] is not None]
        ph = [x["phys"] for x in large if x["phys"] is not None]
        dm = [x["disp"] for x in large if x["disp"] is not None]
        print(f"  LARGE_MOVE  n={len(large)}"
              f"   displacement  min={min(dm):.1f} med={st.median(dm):.1f} max={max(dm):.1f} studs")
        print(f"              CF(actual)   min={min(cf):.0f} med={st.median(cf):.0f} max={max(cf):.0f}")
        print(f"              Phys(claim)  min={min(ph):.0f} med={st.median(ph):.0f} max={max(ph):.0f}")
        below = sum(1 for x in large if x["cf"] is not None and x["phys"]
                    and x["cf"] < x["phys"])
        print(f"              CF < Phys in {below}/{len(large)} events "
              "(heartbeat sampling lag, expected)")
    if bursts:
        print(f"  CFRAME_BURST n={len(bursts)}"
              f"   peak CF={max(b['cf'] for b in bursts):.0f} "
              f"vs Phys={min(b['phys'] for b in bursts):.0f}")
    if d["zero"]:
        print(f"  ZERO_HORIZ   n={len(d['zero'])}   longest streak={streak_max}"
              f"   Horiz med={median_or_none([z['horiz'] for z in d['zero']]):.2f}")
    if d["unstable"]:
        hv = [u["hvar"] for u in d["unstable"] if u["hvar"] is not None]
        print(f"  HEIGHT_UNSTABLE n={len(d['unstable'])}   hVar max={max(hv):.1f}")

    # ---- spatial ------------------------------------------------------
    if positions:
        xs = [p[0] for p in positions]
        ys = [p[1] for p in positions]
        zs = [p[2] for p in positions]
        print("\n-- SPATIAL " + "-" * 62)
        print(f"  X {min(xs):>9.1f} → {max(xs):>9.1f}   (span {max(xs)-min(xs):.0f})")
        print(f"  Y {min(ys):>9.1f} → {max(ys):>9.1f}   (span {max(ys)-min(ys):.0f})")
        print(f"  Z {min(zs):>9.1f} → {max(zs):>9.1f}   (span {max(zs)-min(zs):.0f})")

    # ---- zone ---------------------------------------------------------
    if d["zone"]:
        print("\n-- ZONE TRANSITIONS " + "-" * 52)
        for z in d["zone"]:
            print(f"  {z['t']}  {z['from']:>9} → {z['to']:<9} "
                  f"Pos=({z['pos'][0]:.1f}, {z['pos'][1]:.1f}, {z['pos'][2]:.1f})")

    # ---- anomalies ----------------------------------------------------
    print("\n-- ANOMALY DETAIL " + "-" * 55)
    if d["egg"]:
        for e in d["egg"]:
            print(f"  EGG_STATE   {e['t']}  {e['from']} → {e['to']}  zone={e['zone']}")
    if d["anchor"]:
        print(f"  ANCHOR_FLIP n={len(d['anchor'])}")
        for a in d["anchor"]:
            print(f"      {a['t']}  {a['from']:>5} → {a['to']:<5} "
                  f"Pos=({a['pos'][0]:.1f}, {a['pos'][1]:.1f}, {a['pos'][2]:.1f}) Y={a['y']:.1f}")
    if d["dirflip"]:
        for x in d["dirflip"]:
            print(f"  DIR_FLIP    {x['t']}  Dot={x['dot']:.2f} moved={x['moved']:.1f} "
                  f"zone={x['zone']}")
    if d["hjump"]:
        for x in d["hjump"]:
            print(f"  HEIGHT_JUMP {x['t']}  Y {x['y0']:.1f} → {x['y1']:.1f} "
                  f"(Δ{x['dy']:.1f})  H={x['h']:.1f}")
    if d["fstart"]:
        print(f"  FLIGHT_START n={len(d['fstart'])}")
        for x in d["fstart"]:
            print(f"      {x['t']}  Y={x['y']:.1f} H={x['h']:.1f} zone={x['zone']} egg={x['egg']}")
    if d["fend"]:
        for x in d["fend"]:
            print(f"  FLIGHT_END  {x['t']}  dur={x['dur']:.1f}s dist={x['dist']:.0f}")
    if d["hard"]:
        for x in d["hard"]:
            print(f"  HARD_SNAP   {x['t']}  {x['pay']}")
    if not any(d[k] for k in ("egg", "anchor", "dirflip", "hjump", "fstart", "hard")):
        print("  (no discrete anomalies)")

    return {"file": path, "dur": dur, "events": len(rows), "tags": tags,
            "burst": len(bursts), "zero": len(d["zero"]), "unstable": len(d["unstable"]),
            "large": len(large), "flight": len(d["fstart"]), "anchor": len(d["anchor"]),
            "streak_max": streak_max, "max_ratio": max_ratio}


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 1
    summary = []
    for p in argv[1:]:
        s = report(p)
        if s:
            summary.append(s)
        print()
    if len(summary) > 1:
        cols = ("large", "burst", "zero", "unstable", "flight", "anchor")
        print("=" * 72)
        print("COMPARISON")
        print("=" * 72)
        print(f"  {'file':<34}" + "".join(f"{c:>9}" for c in cols) + f"{'streak':>8}")
        for s in summary:
            name = s["file"].split("/")[-1]
            print(f"  {name:<34}" + "".join(f"{s[c]:>9}" for c in cols)
                  + f"{s['streak_max']:>8}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
