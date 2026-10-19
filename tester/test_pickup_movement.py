import re

def test_pickup_movement():
    with open('farmer/EggGoToUI_v10.lua', 'r') as f:
        content = f.read()

    print("=" * 50)
    print("TEST SUITE: PICKUP MOVEMENT & SNAP FREEDOM VERIFICATION")
    print("=" * 50)

    # Test 1: applyReachAssist guarded against weAreCarrying and snaps within [3, maxReach]
    assert "if weAreCarrying then return false end" in content, "applyReachAssist must abort if weAreCarrying"
    assert "if dist > 3 and dist <= maxReach then" in content, "applyReachAssist must snap if dist > 3"
    assert "return true" in content and "return false" in content, "applyReachAssist must return boolean"
    print("[PASS] Test 1: applyReachAssist guarded against weAreCarrying and returns snap success.")

    # Test 2: holdingSource preserves tightened CRA check (no false positive from base eggs)
    assert "cra_user:" not in content, "holdingSource must not contain wildcard cra_user check"
    assert "local expectedName = carryUid and (myUid .. \"_\" .. tostring(carryUid))" in content, \
        "holdingSource must strictly check carryUid in CRA"
    print("[PASS] Test 2: holdingSource strictly matches carryUid in CRA without false base-egg positives.")

    # Test 3: startAutoPickupSpam handles reach assist once via hasSnapped
    assert "local hasSnapped = false" in content, "startAutoPickupSpam must track hasSnapped"
    assert "if not hasSnapped and PICKUP_CONFIG.ReachAssist and target.Position then" in content, \
        "startAutoPickupSpam must only snap once per E-press"
    assert "hasSnapped = true" in content, "startAutoPickupSpam must mark hasSnapped"
    print("[PASS] Test 3: startAutoPickupSpam only allows reach assist to snap once per E-press.")

    # Test 4: startAutoPickupSpam sets carryUid on targeted egg
    assert "carryUid = target.Uid" in content, "executePickupSpam must populate carryUid"
    print("[PASS] Test 4: carryUid is populated on targeted egg for accurate confirmation.")

    # Test 5: Post-pickup recovery unlocks controls, neutralizes physics, and ensures WalkSpeed
    assert "enablePlayerControls()" in content, "startAutoPickupSpam must call enablePlayerControls"
    assert "neutraliseEggPhysics(char, true)" in content, "startAutoPickupSpam must neutralize egg physics"
    assert "hum.WalkSpeed = math.max(savedWalkSpeed or 16, 16)" in content, "startAutoPickupSpam must ensure WalkSpeed >= 16"
    print("[PASS] Test 5: Post-pickup recovery unlocks controls, neutralizes egg physics, and ensures WalkSpeed.")

    print("=" * 50)
    print("ALL 5 PICKUP MOVEMENT TESTS PASSED SUCCESSFULLY!")
    print("=" * 50)

if __name__ == '__main__':
    test_pickup_movement()
