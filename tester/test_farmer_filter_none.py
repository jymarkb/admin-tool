#!/usr/bin/env python3
"""
Unit test for verifying:
1. When user selects 'None' as farm filter, passesFilters returns False for regular and unknown eggs,
   completely clearing the egg farm list unless an explicit Rarity Filter matches.
2. applySettings does not revert selectedSpecies to 'All' when SpeciesFilter is empty [].
3. ProximityPrompt HoldDuration is zeroed in triggerProximityPrompt.
4. Target selection requires a valid egg Uid.
"""

import re
import sys

LUA_FILE = "/home/arcobaleno/admin-tool/farmer/EggGoToUI_v10.lua"

def test_filter_none_and_prompt():
    print("==================================================")
    print("TEST SUITE: FILTER NONE & PROMPT FIX VERIFICATION")
    print("==================================================")

    with open(LUA_FILE, "r", encoding="utf-8") as f:
        content = f.read()

    # 1. verify applySettings does not force All on empty SpeciesFilter
    assert 'elseif t.SpeciesFilter == nil then\n        selectedSpecies["All"] = true' in content, \
        "Failed: applySettings still forces All when SpeciesFilter is empty table!"
    print("[PASS] Test 1: applySettings preserves empty SpeciesFilter (None) without reverting to All.")

    # 2. verify passesFilters does not unconditionally return true on isNewOrUnknownEgg
    # It must only return true if selectedSpecies['All'] is active
    assert re.search(r'if\s+selectedSpecies\["All"\]\s+and\s+isNewOrUnknownEgg\(r\)\s+then\s+return\s+true\s+end', content), \
        "Failed: passesFilters still unconditionally passes unknown eggs when None is selected!"
    print("[PASS] Test 2: passesFilters gates unknown eggs behind selectedSpecies['All'], allowing None to clear list.")

    # 3. verify isNewOrUnknownEgg does not treat known species with unresolvable live rarity as unknown
    assert "not getPresetRarity(catStr) and not speciesSeen[catStr]" in content, \
        "Failed: isNewOrUnknownEgg treats known species as unknown on late login!"
    print("[PASS] Test 3: Known species are protected from being treated as unknown on late login.")

    # 4. verify triggerProximityPrompt sets HoldDuration = 0
    assert "prompt.HoldDuration = 0" in content, \
        "Failed: prompt.HoldDuration = 0 not set in triggerProximityPrompt!"
    assert "prompt.RequiresLineOfSight = false" in content, \
        "Failed: prompt.RequiresLineOfSight = false not set in triggerProximityPrompt!"
    print("[PASS] Test 4: ProximityPrompt HoldDuration zeroed and LineOfSight bypassed (no hold UI).")

    # 5. verify getBestFocusedTarget only targets with valid Uid
    assert "if uid and score > highestScore then" in content, \
        "Failed: getBestFocusedTarget can target empty slots without Uid!"
    print("[PASS] Test 5: getBestFocusedTarget strictly requires valid egg Uid before targeting.")

    # 6. verify fetchSnapshotRecords parses RareSpawns and individual record rarities
    assert "rarityByUid[tostring(e.EggUid)] = tostring(e.RarityId)" in content, \
        "Failed: fetchSnapshotRecords does not populate rarityByUid!"
    print("[PASS] Test 6: Snapshot fetch populates rarityByUid on late login.")

    print("==================================================")
    print("ALL 6 FILTER & PROMPT TESTS PASSED SUCCESSFULLY!")
    print("==================================================")

if __name__ == "__main__":
    test_filter_none_and_prompt()
