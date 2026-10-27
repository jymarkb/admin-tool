#!/usr/bin/env python3
"""
Trigger Race Benchmark: which auto-bat logic actually LANDS hits on the server.

Compares the trigger paths that exist in this repo today (plus one proposed
unified path) against the server-side swing cooldown rules, at a realistic
network latency (default 68 ms round trip).

Client logics
-------------
  1. paced_rotation   farmer/auto-bat.lua  (default "Paced" mode)
                      round-robin + EquipTool (1 frame) + task.wait(0.6/N)
  2. turbo_rotation   farmer/auto-bat.lua  ("Turbo" mode)
                      round-robin + EquipTool (1 frame) + task.wait() per fire
  3. blind_target_fire farmer/auto-bat-target.lua
                      fires RE/BatSwing immediately on click, NEVER equips
  4. stamped_swap     proposed unified path
                      cached inventory, equip overlapped with the cooldown
                      window, fire lands exactly on the ready instant

Server cooldown rules (we do not know the real one; all three are measured)
--------------------------------------------------------------------------
  per_weapon         0.60 s cooldown tracked separately for each weapon
  global_strict      0.60 s global cooldown, swapping does NOT reset it
  global_swap_negate 0.60 s global cooldown, but a weapon swap negates the
                     remaining cooldown (the behaviour reported in game)

Latency model
-------------
A fire sent by the client at t is validated by the server at t + ping/2.
Swap + swing travel on the same ordered channel, so a swap issued at or
before the swing is seen first (this is why an equip frame is still kept in
stamped_swap: it stays correct even if equips replicate out of band).

Definition of "accepted": the server took the swing. The client gets no
hit/damage push event today, so it cannot tell - every rejected swing is
pure wasted packets, which is exactly what the waste columns measure.

Usage:
    python3 farmer/test_auto_bat_trigger_race.py
    python3 farmer/test_auto_bat_trigger_race.py --ping 68 --duration 60
"""

import argparse
import math
import unittest

FRAME = 1.0 / 60.0          # Roblox 60 FPS frame budget
COOLDOWN = 0.60             # server swing cooldown (seconds)
EPSILON = 1e-6

# 5 configured weapons in farmer/auto-bat.lua
WEAPONS = ["Titan Axe", "Scramble Sword", "Pumpkin Scythe",
           "The Scrambler", "Cricket's Banjo"]

RULES = ("per_weapon", "global_strict", "global_swap_negate")

# Human click rate used to model the click-driven target UI (~8 clicks/s)
CLICK_RATE = 8.0


def quantize(dt):
    """task.wait(dt) yields at least one frame and resolves on a frame tick."""
    frames = max(1, math.ceil(dt / FRAME - 1e-9))
    return frames * FRAME


class ServerSim:
    """Server-side cooldown validation at arrival time (fire time + one-way)."""

    def __init__(self, rule, one_way, cooldown=COOLDOWN):
        if rule not in RULES:
            raise ValueError(rule)
        self.rule = rule
        self.one_way = one_way
        self.cooldown = cooldown
        self.last_accept = -1e9
        self.last_accept_weapon = None
        self.last_accept_by_weapon = {}
        self.accepted = 0
        self.rejected = 0

    def submit(self, fire_time, weapon):
        arrival = fire_time + self.one_way
        if self.rule == "per_weapon":
            ok = (arrival - self.last_accept_by_weapon.get(weapon, -1e9)) >= self.cooldown - EPSILON
        elif self.rule == "global_strict":
            ok = (arrival - self.last_accept) >= self.cooldown - EPSILON
        else:  # global_swap_negate
            ok = ((arrival - self.last_accept) >= self.cooldown - EPSILON
                  or weapon != self.last_accept_weapon)

        if ok:
            self.accepted += 1
            self.last_accept = arrival
            self.last_accept_weapon = weapon
            self.last_accept_by_weapon[weapon] = arrival
        else:
            self.rejected += 1
        return ok


# ---------------------------------------------------------------------------
# Client logics -> timeline of (fire_time, weapon, swapped)
# ---------------------------------------------------------------------------

def paced_rotation(duration, weapons):
    """Current auto-bat.lua default mode: fixed interval = 0.6 / #weapons."""
    n = len(weapons)
    pace = COOLDOWN / n
    events = []
    t = 0.0
    idx = 0
    held = None
    while t < duration:
        weapon = weapons[idx % n]
        start = t
        swapped = False
        if weapon != held:                  # equipToolFast -> task.wait()
            t = start + FRAME
            swapped = True
        held = weapon
        events.append((t, weapon, swapped))
        elapsed = t - start
        wait = pace - elapsed
        t = t + quantize(wait) if wait > 0.002 else t + FRAME
        idx += 1
    return events


def turbo_rotation(duration, weapons):
    """Current auto-bat.lua turbo mode: equip frame + fire + task.wait()."""
    n = len(weapons)
    events = []
    t = 0.0
    idx = 0
    held = None
    while t < duration:
        weapon = weapons[idx % n]
        if weapon != held:
            t += FRAME                      # equipToolFast -> task.wait()
            held = weapon
        events.append((t, weapon, True))
        t += FRAME                          # task.wait() pacing
        idx += 1
    return events


def blind_target_fire(duration, weapons):
    """auto-bat-target.lua: click -> FireServer, no equip, no pacing."""
    events = []
    t = 0.0
    weapon = weapons[0]                     # whatever happens to be held
    while t < duration:
        events.append((t, weapon, False))
        t += quantize(1.0 / CLICK_RATE)
    return events


def stamped_swap(duration, weapons, assume_per_weapon=True):
    """
    Proposed unified path.

    - inventory cached (no per-swing rescans)
    - weapon chosen by the earliest ready stamp
    - the equip frame is spent DURING the idle window, so the fire packet
      leaves exactly on the ready instant instead of one frame after it
    - under a global cooldown assumption, a swap is issued with the fire
      because swapping negates the global cooldown
    """
    n = len(weapons)
    events = []
    stamps = {w: -1e9 for w in weapons}
    t = 0.0
    held = None
    idx = 0
    while t < duration:
        if assume_per_weapon:
            weapon = min(weapons, key=lambda w: stamps[w])
            ready = stamps[weapon] + COOLDOWN
        else:
            weapon = weapons[idx % n]
            ready = max(stamps.values()) + COOLDOWN

        # Overlap the equip frame with the wait instead of stacking on top of it.
        equip_at = max(t, ready - FRAME)
        if equip_at > t:
            t = equip_at
        swapped = False
        if weapon != held:
            t += FRAME
            swapped = True
            held = weapon
        fire_at = max(t, ready)
        t = fire_at
        events.append((t, weapon, swapped))
        stamps[weapon] = fire_at
        idx += 1
    return events


def stamped_swap_fast(duration, weapons):
    """
    Proposed unified path for the swap-negates-cooldown server rule.

    Same proven shape as turbo (equip frame -> fire -> one wait frame, so the
    swap is always seen before the swing) but with a cached inventory, a single
    fire path and no per-swing rescans. This is the floor of the cycle cost:
    2 frames = 33.3 ms per swing = 30 swings/s.
    """
    n = len(weapons)
    events = []
    t = 0.0
    idx = 0
    held = None
    while t < duration:
        weapon = weapons[idx % n]
        swapped = False
        if weapon != held:
            t += FRAME                      # equip, then fire this same frame
            swapped = True
            held = weapon
        events.append((t, weapon, swapped))
        t += FRAME                          # single wait frame before the next swap
        idx += 1
    return events


CLIENTS = {
    "paced_rotation": lambda d: paced_rotation(d, WEAPONS),
    "turbo_rotation": lambda d: turbo_rotation(d, WEAPONS),
    "blind_target_fire": lambda d: blind_target_fire(d, WEAPONS),
    "stamped_swap": lambda d: stamped_swap(d, WEAPONS),
    "stamped_swap_fast": lambda d: stamped_swap_fast(d, WEAPONS),
}

# getActiveTools() inside the swing loop costs ~10 GetChildren() allocations
# per fire (5 weapons x Character + Backpack). Cached logic does zero.
RESCANS_PER_FIRE = {
    "paced_rotation": 10,
    "turbo_rotation": 10,
    "blind_target_fire": 0,
    "stamped_swap": 0,
    "stamped_swap_fast": 0,
}


def run(client, rule, duration=60.0, ping_ms=68.0):
    one_way = ping_ms / 2000.0
    events = CLIENTS[client](duration)
    server = ServerSim(rule, one_way)
    accepted_times = []
    for fire_time, weapon, _swapped in events:
        # only count swings whose validation lands inside the measured window
        if fire_time + one_way > duration:
            break
        if server.submit(fire_time, weapon):
            accepted_times.append(fire_time + one_way)
    events = events[:server.accepted + server.rejected]

    attempted = len(events)
    gaps = [(b - a) * 1000.0 for a, b in zip(accepted_times, accepted_times[1:])]
    return {
        "client": client,
        "rule": rule,
        "fires": attempted,
        "accepted": server.accepted,
        "rejected": server.rejected,
        "waste_pct": (server.rejected / attempted * 100.0) if attempted else 0.0,
        "hits_per_sec": server.accepted / duration,
        "fires_per_sec": attempted / duration,
        "accept_rate_pct": (server.accepted / attempted * 100.0) if attempted else 0.0,
        "median_gap_ms": median(gaps) if gaps else 0.0,
        "rescans_per_sec": RESCANS_PER_FIRE[client] * attempted / duration,
    }


def median(values):
    s = sorted(values)
    n = len(s)
    if n == 0:
        return 0.0
    mid = n // 2
    return s[mid] if n % 2 else (s[mid - 1] + s[mid]) / 2.0


def reset_to_first_hit(rule, ping_ms, client, duration=60.0):
    """Time from 'press start' to the first server-accepted hit."""
    one_way = ping_ms / 2000.0
    server = ServerSim(rule, one_way)
    for fire_time, weapon, _ in CLIENTS[client](duration):
        if fire_time + one_way > duration:
            break
        if server.submit(fire_time, weapon):
            return (fire_time + one_way) * 1000.0
    return float("nan")


def report(ping_ms, duration):
    print("=" * 96)
    print(f"AUTO-BAT TRIGGER RACE  |  ping {ping_ms:.0f} ms (one-way {ping_ms/2:.0f} ms)"
          f"  |  cooldown {COOLDOWN:.2f} s  |  {len(WEAPONS)} weapons  |  {duration:.0f} s run")
    print("=" * 96)

    results = {}
    for rule in RULES:
        print(f"\n--- SERVER RULE: {rule} ---")
        print(f"{'client':<20} {'fires/s':>8} {'hits/s':>7} {'accept':>7} {'waste':>7}"
              f" {'gap(med)':>9} {'1st hit':>8} {'scan/s':>7}")
        print("-" * 96)
        for client in CLIENTS:
            r = run(client, rule, duration, ping_ms)
            results[(client, rule)] = r
            first = reset_to_first_hit(rule, ping_ms, client)
            print(f"{client:<20} {r['fires_per_sec']:>8.2f} {r['hits_per_sec']:>7.2f} "
                  f"{r['accept_rate_pct']:>6.1f}% {r['waste_pct']:>6.1f}% "
                  f"{r['median_gap_ms']:>8.0f}ms {first:>7.0f}ms {r['rescans_per_sec']:>7.0f}")

    print("\n" + "=" * 96)
    print("VERDICT (accepted hits/sec per client logic under each server rule)")
    print("=" * 96)
    header = f"{'client':<20}" + "".join(f"{r:>20}" for r in RULES)
    print(header)
    print("-" * 96)
    for client in CLIENTS:
        row = f"{client:<20}"
        for rule in RULES:
            row += f"{results[(client, rule)]['hits_per_sec']:>20.2f}"
        print(row)

    print("\nbest per rule:")
    for rule in RULES:
        best = max(CLIENTS, key=lambda c: results[(c, rule)]["hits_per_sec"])
        r = results[(best, rule)]
        print(f"  {rule:<20} -> {best:<20} {r['hits_per_sec']:.2f} hits/s "
              f"({r['waste_pct']:.0f}% waste, {r['rescans_per_sec']:.0f} rescans/s)")

    print("\nnotes:")
    print("  * blind_target_fire models the target UI's click path: no equip, no pacing.")
    print("  * 'waste' = swings the server threw away; the client has no hit push event,")
    print("    so the loop cannot learn from them.")
    print("  * gap = median time between consecutive accepted hits (lower is better).")

    print("\n" + "=" * 96)
    print("LATENCY SENSITIVITY (ping affects first-hit delay; throughput only shifts if")
    print("the server buckets arrival times near the cooldown edge)")
    print("=" * 96)
    print(f"{'ping':>6}  " + "".join(f"{c:>19}" for c in CLIENTS))
    print("-" * 96)
    for ping in (30.0, 68.0, 100.0, 150.0):
        row = f"{ping:>6.0f}  "
        for client in CLIENTS:
            r = run(client, "global_swap_negate", duration, ping)
            row += f"{r['hits_per_sec']:>12.2f} hits/s"
        print(row)
    return results


class TestTriggerRaceModel(unittest.TestCase):
    """Invariants of the simulation itself."""

    def test_01_accepted_plus_rejected_equals_fires(self):
        for client in CLIENTS:
            for rule in RULES:
                r = run(client, rule, duration=20.0)
                self.assertEqual(r["accepted"] + r["rejected"], r["fires"])

    def test_02_swap_negate_accepts_every_swap(self):
        """If a swap negates the cooldown, a swap+fire pair is never rejected."""
        r = run("turbo_rotation", "global_swap_negate", duration=20.0)
        self.assertEqual(r["rejected"], 0)

    def test_03_strict_global_cooldown_caps_throughput(self):
        """Under a strict global cooldown no logic can exceed 1/0.6 hits per second."""
        for client in CLIENTS:
            r = run(client, "global_strict", duration=60.0)
            self.assertLessEqual(r["hits_per_sec"], 1.0 / COOLDOWN + 1e-3)

    def test_04_paced_rotation_loses_a_frame_per_swing(self):
        """Documented defect: equip frame + quantized wait => ~7.5 hits/s, not 8.33."""
        r = run("paced_rotation", "per_weapon", duration=60.0)
        self.assertAlmostEqual(r["hits_per_sec"], 7.5, delta=0.15)

    def test_05_stamped_swap_beats_paced_rotation(self):
        r_paced = run("paced_rotation", "per_weapon", duration=60.0)
        r_stamped = run("stamped_swap", "per_weapon", duration=60.0)
        self.assertGreater(r_stamped["hits_per_sec"], r_paced["hits_per_sec"])
        self.assertEqual(r_stamped["rescans_per_sec"], 0)

    def test_06_quantize_yields_at_least_one_frame(self):
        self.assertEqual(quantize(0.0), FRAME)
        self.assertEqual(quantize(0.001), FRAME)
        self.assertEqual(quantize(0.016), FRAME)      # under one frame -> 1 frame
        self.assertEqual(quantize(0.017), 2 * FRAME)  # just over -> 2 frames


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--ping", type=float, default=68.0)
    parser.add_argument("--duration", type=float, default=60.0)
    parser.add_argument("--test", action="store_true", help="run model invariants and exit")
    args = parser.parse_args()

    if args.test:
        unittest.main(argv=["x", "-v"], exit=False)
    else:
        report(args.ping, args.duration)
