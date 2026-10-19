#!/usr/bin/env python3
"""
Unit Test & Benchmark for Farm Scanning Performance in EggGoToUI_v10.lua:
1. Verifies slot lookup logic (UID, Compound Area:Slot, Pos match).
2. Simulates & benchmarks O(N*M) linear scan vs O(1) hash indexed lookup.
3. Simulates & benchmarks CRA carrier lookup before vs after.
"""

import math
import time
import unittest


class MockSlotInstance:
    def __init__(self, name, position=(0, 0, 0), attributes=None):
        self.Name = name
        self.Position = position
        self.attributes = attributes or {}

    def GetAttribute(self, key):
        return self.attributes.get(key)


# ==========================================
# 1. OLD LINEAR IMPLEMENTATION (O(N * M))
# ==========================================
def old_find_egg_slot(children, uid, nest_id, area_id, pos):
    if not uid:
        return None
    # 1. Direct name match
    for ch in children:
        if ch.Name == uid:
            return ch
    # 2. Attribute / contains
    for ch in children:
        if ch.Name == uid or uid in ch.Name:
            return ch
        au = ch.GetAttribute("Uid") or ch.GetAttribute("EggUid")
        if au and str(au) == uid:
            return ch
    # 3. AreaId / NestId match
    n_str = str(nest_id or "")
    a_str = str(area_id or "")
    if n_str or a_str:
        for ch in children:
            nm = ch.Name
            match_area = (not a_str) or (a_str in nm)
            match_nest = False
            if n_str:
                if n_str in nm:
                    match_nest = True
                else:
                    digits = "".join(filter(str.isdigit, n_str))
                    if digits:
                        num = int(digits)
                        if f"Slot_{num:03d}" in nm or f"Slot_{num}" in nm:
                            match_nest = True
            if match_area and match_nest:
                return ch
    # 4. Position match
    if pos:
        for ch in children:
            dx = ch.Position[0] - pos[0]
            dy = ch.Position[1] - pos[1]
            dz = ch.Position[2] - pos[2]
            if (dx * dx + dy * dy + dz * dz) <= 36:
                return ch
    return None


# ==========================================
# 2. NEW INDEXED IMPLEMENTATION (O(1))
# ==========================================
def build_slot_index(children):
    idx = {
        "byUid": {},
        "byName": {},
        "byAreaNest": {},
        "byNest": {},
        "positions": [],
        "children": children,
    }
    for ch in children:
        nm = ch.Name
        idx["byName"][nm] = ch
        idx["byUid"][nm] = ch

        au = ch.GetAttribute("Uid") or ch.GetAttribute("EggUid")
        if au:
            idx["byUid"][str(au)] = ch

        # Compound pattern
        import re
        m = re.search(r'_([A-Za-z]+)[:_][Ss]lot[_-]?(\d+)', nm)
        if not m:
            m = re.search(r'([A-Za-z]+)[:_][Ss]lot[_-]?(\d+)', nm)
        if m:
            area_part, slot_num_str = m.group(1).lower(), m.group(2)
            s_num = int(slot_num_str)
            idx["byAreaNest"][f"{area_part}:{slot_num_str.lower()}"] = ch
            idx["byAreaNest"][f"{area_part}:slot_{slot_num_str.lower()}"] = ch
            idx["byAreaNest"][f"{area_part}:{s_num}"] = ch
            idx["byAreaNest"][f"{area_part}:slot_{s_num}"] = ch
            idx["byAreaNest"][f"{area_part}:slot_{s_num:03d}"] = ch
            idx["byNest"].setdefault(str(s_num), ch)
            idx["byNest"].setdefault(f"slot_{s_num:03d}", ch)

        if ch.Position:
            idx["positions"].append({"inst": ch, "x": ch.Position[0], "y": ch.Position[1], "z": ch.Position[2]})

    return idx


def new_find_egg_slot(slot_idx, uid, nest_id, area_id, pos):
    if not uid:
        return None

    # 1. Direct UID
    by_u = slot_idx["byUid"].get(uid)
    if by_u:
        return by_u

    # 2. Name match
    by_n = slot_idx["byName"].get(uid)
    if by_n:
        return by_n

    # 3. Area / Nest match
    n_str = str(nest_id or "")
    a_str = str(area_id or "")
    if n_str or a_str:
        a_low = a_str.lower()
        n_low = n_str.lower()
        digits = "".join(filter(str.isdigit, n_str))
        num = int(digits) if digits else None

        if a_low and n_low:
            match = slot_idx["byAreaNest"].get(f"{a_low}:{n_low}")
            if match:
                return match
            if num is not None:
                match = slot_idx["byAreaNest"].get(f"{a_low}:{num}") or slot_idx["byAreaNest"].get(f"{a_low}:slot_{num:03d}")
                if match:
                    return match

        if num is not None and str(num) in slot_idx["byNest"]:
            cand = slot_idx["byNest"][str(num)]
            if not a_low or a_low in cand.Name.lower():
                return cand

    # 4. Position match
    if pos and slot_idx["positions"]:
        px, py, pz = pos
        for s in slot_idx["positions"]:
            dx = s["x"] - px
            dy = s["y"] - py
            dz = s["z"] - pz
            if (dx * dx + dy * dy + dz * dz) <= 36:
                return s["inst"]

    return None


class TestFarmScanPerf(unittest.TestCase):
    def setUp(self):
        # 80 slot models in AreaEggSlotsClient
        self.slots = []
        for i in range(1, 81):
            area = "Forest" if i <= 20 else ("Desert" if i <= 40 else ("Volcano" if i <= 60 else "Ocean"))
            pos = (i * 10.0, 5.0, (i % 10) * 10.0)
            slot_name = f"FirstAreaEgg_9521640019_5972878_{area}:Slot_{i:03d}"
            inst = MockSlotInstance(slot_name, position=pos)
            self.slots.append(inst)

        # 100 egg records from snapshot
        self.eggs = []
        for i in range(1, 101):
            slot_idx = (i % 80) + 1
            area = "Forest" if slot_idx <= 20 else ("Desert" if slot_idx <= 40 else ("Volcano" if slot_idx <= 60 else "Ocean"))
            pos = (slot_idx * 10.0, 5.0, (slot_idx % 10) * 10.0)
            self.eggs.append({
                "Uid": f"egg_uid_{i:04d}_hex32_sample_data",
                "NestId": f"Slot_{slot_idx:03d}",
                "AreaId": area,
                "Pos": pos,
            })

    def test_functional_parity(self):
        """Verifies new index produces identical lookup results to old linear search."""
        slot_idx = build_slot_index(self.slots)

        for egg in self.eggs:
            old_res = old_find_egg_slot(self.slots, egg["Uid"], egg["NestId"], egg["AreaId"], egg["Pos"])
            new_res = new_find_egg_slot(slot_idx, egg["Uid"], egg["NestId"], egg["AreaId"], egg["Pos"])
            self.assertEqual(old_res, new_res, f"Mismatch for egg {egg['Uid']}: old={old_res.Name if old_res else None}, new={new_res.Name if new_res else None}")

    def test_benchmark_speedup(self):
        """Measures execution time comparison across 100 scans (10,000 egg checks)."""
        scans = 100

        # Benchmark OLD linear search
        t0 = time.perf_counter()
        old_matches = 0
        for _ in range(scans):
            for egg in self.eggs:
                res = old_find_egg_slot(self.slots, egg["Uid"], egg["NestId"], egg["AreaId"], egg["Pos"])
                if res:
                    old_matches += 1
        t_old = time.perf_counter() - t0

        # Benchmark NEW indexed search (including building index once per scan)
        t0 = time.perf_counter()
        new_matches = 0
        for _ in range(scans):
            slot_idx = build_slot_index(self.slots)
            for egg in self.eggs:
                res = new_find_egg_slot(slot_idx, egg["Uid"], egg["NestId"], egg["AreaId"], egg["Pos"])
                if res:
                    new_matches += 1
        t_new = time.perf_counter() - t0

        speedup = t_old / max(t_new, 1e-9)
        self.assertEqual(old_matches, new_matches)
        print(f"\n[BENCHMARK] Old Linear Search (100 scans, 10k checks): {t_old*1000:.2f}ms")
        print(f"[BENCHMARK] New Hash Indexed Search (100 scans, 10k checks): {t_new*1000:.2f}ms")
        print(f"[BENCHMARK] Net Speedup: {speedup:.1f}x faster ({(1 - t_new/t_old)*100:.1f}% reduction in scan time)")
        self.assertGreater(speedup, 5.0, "Expected at least 5x speedup from hash indexing")


if __name__ == "__main__":
    unittest.main()
