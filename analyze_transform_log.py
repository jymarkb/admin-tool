#!/usr/bin/env python3
"""Analyzer for the TRANSFORM_JUMP telemetry format.

Line format:
    [HH:MM:SS.mmm] TAG | field | field | ...

Events:
    TRANSFORM_JUMP | src= | phase= | state= | dt= | dP=(x,y,z) | dist= |
                     pSpd= | vel=(x,y,z) | vMag= | vRatio= | [pred= |
                     kRatio= | ang=(x,y,z) |] pos=(x,y,z)
    LARGE_MOVE     | same shape as TRANSFORM_JUMP
    SPEED          | phase= | <vMag> s/s | vel= | pos= | dP= | pSpeed= | state=
    STATE          | phase= | <Old> -> <New> | speed= | [vel=] | pos= | hp= |
                     floor= | nc= | [platformStand= | autoRotate=]

Field semantics (verified against the numbers, see --verify):
    dt      seconds since the previous logged sample in the same series
    dP      position delta over that interval
    dist    |dP|
    pSpd    dist / dt          <- position speed
    vel     AssemblyLinearVelocity at sample time
    vMag    |vel|
    vRatio  pSpd / vMag        <- the log's own "is this a teleport" metric

CRITICAL CAVEAT, and the reason this tool exists:
    vRatio is numerically unstable at both ends.
      * tiny dt  -> pSpd inflated -> false positives on ordinary walking
      * vMag = 0 -> vRatio divides by zero and prints six-figure values
      * long dt  -> pSpd diluted across idle time -> false negatives
    The robust detector is horizontal displacement with zero horizontal
    velocity, which this tool reports separately as HIJACK events.
"""

import re
import sys
import statistics as st
from datetime import datetime

LINE = re.compile(r"^\[(\d{2}:\d{2}:\d{2}\.\d+)\]\s+([A-Z_]+)\s*\|\s*(.*)$")
NUM = r"([-\d.]+)"
VEC = r"\(\s*([-\d.]+)\s*,\s*([-\d.]+)\s*,\s*([-\d.]+)\s*\)"

LANDING = (612.2, 70.7, -325.0)   # admin_v6_escape.lua FOREST_LANDING (612.0, 71.0, -325.0)
CRUISE_Y = 112.5                  # admin_v6_escape.lua CRUISE_Y
TSFMT = "%H:%M:%S.%f"


def parse(path):
    rows = []
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            m = LINE.match(raw.strip())
            if not m:
                continue
            t, tag, rest = m.group(1), m.group(2), m.group(3)
            d = {"_t": t, "_tag": tag, "_bare": []}
            for part in rest.split(" | "):
                part = part.strip()
                if not part:
                    continue
                if "=" in part:
                    k, v = part.split("=", 1)
                    d[k.strip()] = v.strip()
                else:
                    d["_bare"].append(part)
            rows.append(d)
    return rows


def vec(s):
    if not s:
        return None
    m = re.match(rf"^{VEC}$", s.strip())
    if not m:
        return None
    return tuple(float(x) for x in m.groups())


def num(s):
    if s is None:
        return None
    m = re.match(rf"^{NUM}x?$", s.strip())
    return float(m.group(1)) if m else None


def tsec(t, base):
    return (datetime.strptime(t, TSFMT) - datetime.strptime(base, TSFMT)).total_seconds()


def hmag(v):
    return (v[0] ** 2 + v[2] ** 2) ** 0.5 if v else 0.0


def summarize(path, verify=False):
    rows = parse(path)
    if not rows:
        print(f"!! {path}: nothing parsed")
        return None

    base = rows[0]["_t"]
    dur = tsec(rows[-1]["_t"], base)

    print("=" * 78)
    print(f"FILE  {path}")
    print("=" * 78)
    print(f"  window  {rows[0]['_t']} → {rows[-1]['_t']}   ({dur:.2f} s)")
    print(f"  events  {len(rows)}")

    from collections import Counter
    cnt = Counter(r["_tag"] for r in rows)
    print("\n  -- EVENT COUNTS " + "-" * 58)
    for tag, n in cnt.most_common():
        print(f"    {tag:<16}{n:>5}")

    jumps = [r for r in rows if r["_tag"] in ("TRANSFORM_JUMP", "LARGE_MOVE")]

    # ---- HIJACK detection: horizontal movement with zero horizontal velocity
    hij = []
    for r in jumps:
        dp = vec(r.get("dP"))
        v = vec(r.get("vel"))
        if dp is None:
            continue
        hd, hv = hmag(dp), hmag(v)
        if hd >= 20 and hv < 1.0:
            hij.append({"t": r["_t"], "hd": hd, "hv": hv,
                        "pos": vec(r.get("pos")), "vMag": num(r.get("vMag")),
                        "tag": r["_tag"]})
    total_h = sum(h["hd"] for h in hij)

    print("\n  -- HIJACK EVENTS (horizontal move >=20 studs, horizontal vel <1.0) "
          + "-" * 20)
    if hij:
        print(f"    n={len(hij)}   total horizontal distance={total_h:.0f} studs")
        print(f"    largest single frame = {max(h['hd'] for h in hij):.1f} studs")
        for h in sorted(hij, key=lambda x: -x["hd"])[:6]:
            p = h["pos"]
            print(f"      {h['t']}  {h['hd']:>7.1f} studs  hVel={h['hv']:.1f}  "
                  f"vMag={h['vMag']:.1f}  pos=({p[0]:.1f}, {p[1]:.1f}, {p[2]:.1f})")
    else:
        print("    none")

    # ---- vRatio reliability
    vr = [(num(r.get("vRatio")), num(r.get("dt")), num(r.get("pSpd")),
           num(r.get("vMag"))) for r in jumps]
    vr = [x for x in vr if x[0] is not None]
    print("\n  -- vRatio RELIABILITY " + "-" * 52)
    if vr:
        zero_v = [x for x in vr if x[3] is not None and x[3] == 0]
        tiny_dt = [x for x in vr if x[1] is not None and x[1] < 0.005]
        print(f"    samples                    {len(vr)}")
        print(f"    vMag == 0 (divide by zero) {len(zero_v)}"
              + (f"   → vRatio up to {max(x[0] for x in zero_v):,.0f}x" if zero_v else ""))
        print(f"    dt < 5 ms (inflated)       {len(tiny_dt)}"
              + (f"   → e.g. {tiny_dt[0][0]:.1f}x at dt={tiny_dt[0][1]:.5f}"
                 if tiny_dt else ""))
        big_dt = [x for x in vr if x[1] is not None and x[1] > 1.0]
        if big_dt:
            print(f"    dt > 1 s (diluted)         {len(big_dt)}"
                  f"   → max dt={max(x[1] for x in big_dt):.3f}s")

    # ---- trajectory
    pts = []
    for r in jumps:
        p = vec(r.get("pos"))
        if p and (not pts or pts[-1][1] != p):
            pts.append((r["_t"], p, r["_tag"]))
    if pts:
        xs = [p[1][0] for p in pts]
        ys = [p[1][1] for p in pts]
        zs = [p[1][2] for p in pts]
        print("\n  -- TRAJECTORY " + "-" * 60)
        print(f"    samples   {len(pts)}")
        print(f"    X {min(xs):>9.1f} → {max(xs):>9.1f}   span {max(xs)-min(xs):>8.0f}")
        print(f"    Y {min(ys):>9.1f} → {max(ys):>9.1f}   span {max(ys)-min(ys):>8.1f}")
        print(f"    Z {min(zs):>9.1f} → {max(zs):>9.1f}   span {max(zs)-min(zs):>8.1f}")
        print(f"    final pos = ({pts[-1][1][0]:.1f}, {pts[-1][1][1]:.1f}, {pts[-1][1][2]:.1f})")

        # convergence toward the landing point (X only, that is the dominant axis)
        ratios, prev = [], None
        for _, p, _ in pts:
            if prev is not None:
                d0, d1 = prev[0] - LANDING[0], p[0] - LANDING[0]
                if abs(d0) > 1.0 and abs(d1) > 0.5:
                    ratios.append(d1 / d0)
            prev = p
        inner = [r for r in ratios if 0.0 < r < 1.0]
        if len(inner) >= 5:
            print(f"\n  -- CONVERGENCE toward X={LANDING[0]} " + "-" * 40)
            print(f"    per-step ratio (x-612.2)/(x_prev-612.2): "
                  f"median={st.median(inner):.4f}  n={len(inner)}")
            print(f"    → constant-ratio lerp? spread "
                  f"min={min(inner):.4f} max={max(inner):.4f}")

        # altitude band
        cr = [p for _, p, _ in pts if abs(p[1] - CRUISE_Y) < 1.0]
        if cr:
            print(f"\n    samples on cruise altitude Y≈{CRUISE_Y}: {len(cr)}/{len(pts)}")
            print(f"    → matches admin_v6_escape.lua CRUISE_Y = {CRUISE_Y}")

    # ---- humanoid state transitions
    sts = []
    for r in rows:
        if r["_tag"] == "STATE":
            for b in r["_bare"]:
                if "->" in b:
                    a, c = [x.strip().replace("Enum.HumanoidStateType.", "")
                            for x in b.split("->")]
                    sts.append((r["_t"], a, c))
    if sts:
        print("\n  -- STATE TRANSITIONS " + "-" * 55)
        for t, a, c in sts:
            print(f"    {t}  {a} → {c}")

    if verify:
        print("\n  -- VERIFY pSpd == dist/dt " + "-" * 52)
        bad = 0
        for r in jumps:
            d, dt, ps = num(r.get("dist")), num(r.get("dt")), num(r.get("pSpd"))
            if None in (d, dt, ps) or dt == 0:
                continue
            calc = d / dt
            if abs(calc - ps) > max(1.0, 0.02 * ps):
                bad += 1
        print(f"    mismatches: {bad}/{len(jumps)}")
        print("    -- VERIFY vRatio == pSpd/vMag " + "-" * 44)
        bad = 0
        for r in jumps:
            ps, vm, vr = num(r.get("pSpd")), num(r.get("vMag")), num(r.get("vRatio"))
            if None in (ps, vm, vr) or vm == 0:
                continue
            calc = ps / vm
            if abs(calc - vr) > max(1.0, 0.02 * vr):
                bad += 1
        print(f"    mismatches: {bad}/{len(jumps)}")

    nc_vals = sorted({r.get("nc") for r in rows if r.get("nc")})
    floor_vals = sorted({r.get("floor") for r in rows if r.get("floor")})
    print("\n  -- ENVIRONMENT " + "-" * 61)
    print(f"    nc     {', '.join(nc_vals) if nc_vals else '-'}")
    print(f"    floor  {', '.join(f.replace('Enum.Material.','') for f in floor_vals) if floor_vals else '-'}")
    has_new = any("pred" in r for r in rows)
    print(f"    pred/kRatio/ang fields present: {has_new}")

    return {"file": path, "dur": dur, "n": len(rows), "hij": len(hij),
            "hij_studs": total_h, "max_hij": max((h["hd"] for h in hij), default=0),
            "x0": max(xs) if pts else 0, "tags": cnt}


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    verify = "--verify" in argv
    if not args:
        print(__doc__)
        return 1
    out = []
    for p in args:
        s = summarize(p, verify=verify)
        if s:
            out.append(s)
        print()
    if len(out) > 1:
        print("=" * 78)
        print("COMPARISON")
        print("=" * 78)
        print(f"  {'file':<18}{'dur(s)':>8}{'events':>8}{'hijack':>8}"
              f"{'hij studs':>11}{'max frame':>11}{'startX':>9}")
        for s in out:
            print(f"  {s['file'].split('/')[-1]:<18}{s['dur']:>8.2f}{s['n']:>8}"
                  f"{s['hij']:>8}{s['hij_studs']:>11.0f}{s['max_hij']:>11.1f}{s['x0']:>9.0f}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
