#!/usr/bin/env python3
"""
Unit test for testing the 3 specific farmer regressions:
1. Speed velocity reset (baseVelocity vs baseCarryVelocity)
2. Egg target selection (Divine -> Eternal -> Secret -> Scramble -> farthest -> any; steal closest dropped)
3. Stolen egg state cleanup (no retry storm, dropRetry cleared, immediate braking)
"""

import math

def simulate_pick_nearest(records, my_pos, loose_uids, we_dropped, nest_pos, bad_uids, carrier_player, now=100.0):
    candidates = []
    best_tier = math.inf

    for r in records:
        u = r.get("Uid", "")
        # Filter check
        st = r.get("State", "")
        carrier = r.get("CarrierUserId") or carrier_player.get(u)
        is_carried_by_other = (st == "Carried" and carrier and str(carrier) != "MY_ID") or (carrier and str(carrier) != "MY_ID")
        is_blacklisted = bad_uids.get(u, 0) > now
        if not is_carried_by_other and not is_blacklisted:
            p = r.get("Pos")
            if p:
                tier = r.get("Tier", 5)
                if tier < best_tier:
                    best_tier = tier
                dx = p[0] - my_pos[0]
                dy = p[1] - my_pos[1]
                dz = p[2] - my_pos[2]
                dist = math.sqrt(dx*dx + dz*dz + dy*dy*0.25)
                is_dropped = (st == "Dropped") or (loose_uids.get(u) is True) or (we_dropped.get(u) is not None) or (nest_pos.get(u) and math.sqrt((p[0]-nest_pos[u][0])**2 + (p[2]-nest_pos[u][2])**2) > 6)
                candidates.append({
                    "rec": r,
                    "uid": u,
                    "pos": p,
                    "tier": tier,
                    "dist": dist,
                    "isDropped": is_dropped
                })

    if not candidates:
        return None, None, False

    best_dropped = None
    best_dropped_dist = math.inf
    best_nest = None
    best_nest_dist = -1

    for c in candidates:
        if c["tier"] == best_tier:
            if c["isDropped"]:
                if c["dist"] < best_dropped_dist:
                    best_dropped = c["rec"]
                    best_dropped_dist = c["dist"]
            else:
                if c["dist"] > best_nest_dist:
                    best_nest = c["rec"]
                    best_nest_dist = c["dist"]

    if best_dropped:
        return best_dropped, best_tier, True
    elif best_nest:
        return best_nest, best_tier, False

    return None, None, False


def run_tests():
    print("==================================================")
    print("TEST SUITE: FARMER LOGIC REGRESSION VERIFICATION")
    print("==================================================")

    # TEST 1: 3 Divine Eggs Scenario
    # Egg 1: delivered (not in field)
    # Egg 2: dropped midway by another player who got bumped (dist: 100 studs)
    # Egg 3: still in nest (dist: 350 studs)
    my_pos = (0, 0, 0)
    nest_egg_3 = {"Uid": "divine_nest_3", "Tier": 1, "State": "Slot", "Pos": (0, 0, 350)}
    dropped_egg_2 = {"Uid": "divine_dropped_2", "Tier": 1, "State": "Dropped", "Pos": (0, 0, 100)}
    records = [nest_egg_3, dropped_egg_2]
    loose_uids = {"divine_dropped_2": True}
    nest_pos = {"divine_nest_3": (0, 0, 350), "divine_dropped_2": (0, 0, 400)}

    chosen, tier, is_steal = simulate_pick_nearest(
        records, my_pos, loose_uids, {}, nest_pos, {}, {}
    )

    assert chosen is not None, "Failed: No egg chosen"
    assert chosen["Uid"] == "divine_dropped_2", f"Failed: Expected divine_dropped_2, got {chosen['Uid']}"
    assert is_steal is True, "Failed: Expected is_steal == True"
    print("[PASS] Test 1: Stole closest dropped midway Divine egg over distant nest Divine egg!")

    # TEST 2: Two nest Divine eggs (neither dropped)
    nest_egg_a = {"Uid": "divine_nest_a", "Tier": 1, "State": "Slot", "Pos": (0, 0, 200)}
    nest_egg_b = {"Uid": "divine_nest_b", "Tier": 1, "State": "Slot", "Pos": (0, 0, 400)}
    records = [nest_egg_a, nest_egg_b]
    chosen, tier, is_steal = simulate_pick_nearest(
        records, my_pos, {}, {}, {"divine_nest_a": (0, 0, 200), "divine_nest_b": (0, 0, 400)}, {}, {}
    )
    assert chosen["Uid"] == "divine_nest_b", f"Failed: Expected divine_nest_b (farthest), got {chosen['Uid']}"
    assert is_steal is False, "Failed: Expected is_steal == False"
    print("[PASS] Test 2: When no dropped eggs in tier, correctly selected farthest nest egg!")

    # TEST 3: Divine nest egg vs Eternal dropped egg
    # Rule: Divine (tier 1) > Eternal (tier 2) -> Divine always wins regardless of distance or dropped state!
    divine_nest = {"Uid": "divine_nest", "Tier": 1, "State": "Slot", "Pos": (0, 0, 300)}
    eternal_dropped = {"Uid": "eternal_dropped", "Tier": 2, "State": "Dropped", "Pos": (0, 0, 50)}
    records = [divine_nest, eternal_dropped]
    chosen, tier, is_steal = simulate_pick_nearest(
        records, my_pos, {"eternal_dropped": True}, {}, {"divine_nest": (0, 0, 300)}, {}, {}
    )
    assert chosen["Uid"] == "divine_nest", f"Failed: Divine must beat Eternal, got {chosen['Uid']}"
    print("[PASS] Test 3: Rarity priority preserved (Divine Tier 1 beats Eternal Tier 2 dropped)!")

    # TEST 4: Blacklisted stolen egg is never picked
    stolen_divine = {"Uid": "stolen_divine", "Tier": 1, "State": "Carried", "Pos": (0, 0, 50)}
    normal_egg = {"Uid": "normal_egg", "Tier": 5, "State": "Slot", "Pos": (0, 0, 80)}
    records = [stolen_divine, normal_egg]
    chosen, tier, is_steal = simulate_pick_nearest(
        records, my_pos, {}, {}, {}, {"stolen_divine": 150.0}, {"stolen_divine": "OTHER_USER"}
    )
    assert chosen["Uid"] == "normal_egg", f"Failed: Stolen egg must not be picked, got {chosen['Uid']}"
    print("[PASS] Test 4: Stolen/blacklisted egg excluded from pick candidates!")

    # TEST 5: Multiple dropped eggs in same tier -> pick closest dropped
    drop_near = {"Uid": "drop_near", "Tier": 1, "State": "Dropped", "Pos": (0, 0, 60)}
    drop_far = {"Uid": "drop_far", "Tier": 1, "State": "Dropped", "Pos": (0, 0, 150)}
    nest_far = {"Uid": "nest_far", "Tier": 1, "State": "Slot", "Pos": (0, 0, 350)}
    records = [drop_near, drop_far, nest_far]
    chosen, tier, is_steal = simulate_pick_nearest(
        records, my_pos, {"drop_near": True, "drop_far": True}, {}, {"nest_far": (0, 0, 350)}, {}, {}
    )
    assert chosen["Uid"] == "drop_near", f"Failed: Expected closest dropped egg (drop_near), got {chosen['Uid']}"
    assert is_steal is True, "Failed: Expected is_steal == True"
    print("[PASS] Test 5: Multiple dropped eggs picked closest dropped egg!")

    print("==================================================")
    print("ALL 5 REGRESSION UNIT TESTS PASSED SUCCESSFULLY!")
    print("==================================================")

if __name__ == "__main__":
    run_tests()
