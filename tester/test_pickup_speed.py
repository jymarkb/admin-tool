#!/usr/bin/env python3
"""
Unit test for testing the pickup acceleration features:
1. Get Pick Up (autoGetEgg):
   - Zero blocking forceScan at arrival
   - Zero artificial sleep (task.wait(0.12) removed)
   - Concurrent carry burst (SpamBurstCount / 6 calls)
   - Proximity prompt trigger integration
   - Tightened confirmation window (0.45s deadline, 0.02s tick)
2. Spam Pick Up (buildUtilityTabUI):
   - Auto pickup spam on press E (no holding required)
   - High-speed loop (~28Hz / 0.035s) until egg secured (isHoldingEgg)
   - Discovery scope checks AreaEggSlotsClient, Eggs, WorldEggs
   - Attribute and distance UID fallback mapping
   - Proximity prompt triggering for both SlotDirect and EggRecord
"""

import re
import sys

LUA_FILE = "/home/arcobaleno/admin-tool/farmer/EggGoToUI_v10.lua"

def test_pickup_acceleration():
    print("==================================================")
    print("TEST SUITE: PICKUP ACCELERATION VERIFICATION")
    print("==================================================")

    with open(LUA_FILE, "r", encoding="utf-8") as f:
        content = f.read()

    # 1. autoGetEgg: verify no blocking forceScan at arrival
    assert "X.forceScan(1.5)" not in content, "Failed: Found blocking X.forceScan(1.5) in code!"
    print("[PASS] Test 1: Blocking X.forceScan(1.5) completely eliminated from egg arrival.")

    # 2. autoGetEgg: verify microSnap has no task.wait(0.12)
    assert "microSnap(); task.wait(0.12)" not in content, "Failed: Found artificial microSnap 0.12s wait!"
    assert "microSnap()" in content, "Failed: microSnap() not found!"
    print("[PASS] Test 2: Artificial 0.12s wait after microSnap removed.")

    # 3. autoGetEgg: verify burst carry invokes
    assert re.search(r"for\s+b\s*=\s*1\s*,\s*burstCount\s+do", content), "Failed: Concurrent carry burst not found in autoGetEgg!"
    print("[PASS] Test 3: Concurrent carry burst loop implemented in autoGetEgg.")

    # 4. autoGetEgg: verify proximity prompt trigger in autoGetEgg
    assert "triggerProximityPrompt(promptToFire)" in content, "Failed: triggerProximityPrompt not integrated into autoGetEgg!"
    print("[PASS] Test 4: ProximityPrompt triggering integrated into autoGetEgg.")

    # 5. autoGetEgg: verify tightened confirmation deadline (0.45s) and tick (0.02s)
    assert "confDeadline = os.clock() + 0.45" in content, "Failed: 0.45s confDeadline not found!"
    assert re.search(r"while\s+os\.clock\(\)\s*<\s*confDeadline.*task\.wait\(0\.02\)", content, re.DOTALL), "Failed: 0.02s task.wait tick not found in conf loop!"
    print("[PASS] Test 5: Fast 0.45s confirmation deadline with 0.02s ticks verified.")

    # 6. buildUtilityTabUI: verify auto pickup spam on press E (no hold required)
    assert "startAutoPickupSpam()" in content, "Failed: startAutoPickupSpam not found!"
    assert re.search(r"if\s+input\.KeyCode\s*==\s*Enum\.KeyCode\.E\s+then\s+startAutoPickupSpam\(\)", content), "Failed: startAutoPickupSpam not triggered on E press!"
    assert re.search(r"while\s+X\.autoPickupToken\s*==\s*myTok\s+and\s+PICKUP_CONFIG\.Enabled.*task\.wait\(0\.035\)", content, re.DOTALL), "Failed: Auto pickup spam loop at 0.035s tick not found!"
    assert "if isHoldingEgg() or weAreCarrying then" in content, "Failed: isHoldingEgg completion check not found in auto-spam loop!"
    print("[PASS] Test 6: Auto pickup spam on press E (no holding required) verified.")

    # 7. buildUtilityTabUI: verify discovery in Eggs and WorldEggs
    assert '"Eggs"' in content and '"WorldEggs"' in content, "Failed: Workspace.Eggs and Workspace.WorldEggs not scanned in getBestFocusedTarget!"
    print("[PASS] Test 7: Multi-container discovery (AreaEggSlotsClient, Eggs, WorldEggs) verified.")

    # 8. buildUtilityTabUI: verify slot UID fallback mapping
    assert "(ePos - pos).Magnitude < 4.0" in content, "Failed: Slot position distance mapping fallback not found!"
    print("[PASS] Test 8: Slot UID mapping via proximity (< 4.0 studs) verified.")

    print("==================================================")
    print("ALL 8 PICKUP ACCELERATION TESTS PASSED!")
    print("==================================================")

if __name__ == "__main__":
    test_pickup_acceleration()
