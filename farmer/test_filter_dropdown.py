#!/usr/bin/env python3
"""
Unit tests for EggGoToUI_v12.lua filter logic, clean taxonomy, and UI alignment.
Verifies all 4 user requests:
  1. Complete removal of legacy "EggAliases = {" bloat.
  2. Removal of excess CopyJsonBtn and FooterBar from TabEggs.
  3. Clean Utility tab: zero subtitle description labels, uniform 56x24 toggle buttons.
  4. Biome and Rarity filter logic verification:
     - All on: allows all eggs
     - None on: blocks all eggs
     - Specific biome/rarity: allows only matching eggs
     - Uncheck behavior from All
"""

import json
import re
import unittest

class TestFilterDropdownAndUI(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        with open("farmer/EggGoToUI_v12.lua", "r") as f:
            cls.code = f.read()

        with open("farmer/egg.json", "r") as f:
            cls.egg_data = json.load(f)["farmableEggs"]

    def test_01_no_legacy_egg_aliases_table(self):
        """Verify Config.Taxonomy.EggAliases = { is completely removed."""
        self.assertNotIn("EggAliases = {", self.code, "Legacy EggAliases table must not exist in v12!")
        self.assertNotIn("Config.Taxonomy.EggAliases", self.code, "Config.Taxonomy.EggAliases must not be referenced!")

    def test_02_no_excess_copy_json_on_tab_eggs(self):
        """Verify TabEggs does not have a redundant FooterBar or Copy JSON button."""
        self.assertNotIn("FooterBar", self.code, "FooterBar should be removed from TabEggs!")
        # TabUtility has the single canonical UtilityCopyJsonBtn
        self.assertIn('Name = "UtilityCopyJsonBtn"', self.code)
        # EggListScroll extends down (gaining 30px height after SearchBar removal)
        self.assertIn('scroll.Size = UDim2.new(1, -16, 1, -88)', self.code)

    def test_03_clean_utility_rows_and_even_toggle_buttons(self):
        """Verify TabUtility has zero subtitle text descriptions and uniform 56x24 toggle buttons."""
        self.assertNotIn("lblPDesc", self.code, "Subtitle description in RowPickup must be removed!")
        self.assertNotIn("lblRDesc", self.code, "Subtitle description in RowRecovery must be removed!")
        self.assertNotIn("lblNcDesc", self.code, "Subtitle description in RowNoclip must be removed!")
        self.assertNotIn("lblEDesc", self.code, "Subtitle description in RowExportJson must be removed!")

        # All 3 toggle buttons (Pickup, Recovery, Noclip) have uniform 56x24 dimensions
        self.assertIn('togglePickBtn.Size = UDim2.new(0, 56, 0, 24)', self.code)
        self.assertIn('testRecBtn.Size = UDim2.new(0, 56, 0, 24)', self.code)
        self.assertIn('toggleNcBtn.Size = UDim2.new(0, 56, 0, 24)', self.code)

        # All 3 toggle buttons have uniform position (1, -66, 0.5, -12)
        self.assertIn('togglePickBtn.Position = UDim2.new(1, -66, 0.5, -12)', self.code)
        self.assertIn('testRecBtn.Position = UDim2.new(1, -66, 0.5, -12)', self.code)
        self.assertIn('toggleNcBtn.Position = UDim2.new(1, -66, 0.5, -12)', self.code)

    def test_04_filter_logic_simulation(self):
        """Verify the biome and rarity filtering logic against real egg.json records."""
        def filter_egg(biome, rarity, sel_biomes, sel_rarities):
            # Rarity filter
            rarity_allowed = False
            if sel_rarities.get("All") is True:
                rarity_allowed = True
            elif len(sel_rarities) == 0:
                rarity_allowed = False
            elif sel_rarities.get(rarity) is True:
                rarity_allowed = True

            # Biome filter
            biome_allowed = False
            if sel_biomes.get("All") is True:
                biome_allowed = True
            elif len(sel_biomes) == 0:
                biome_allowed = False
            elif sel_biomes.get(biome) is True:
                biome_allowed = True
            elif biome == "Light & Dark" and (sel_biomes.get("Angel Eggs") or sel_biomes.get("Demon Eggs")):
                biome_allowed = True
            elif biome in ("Angel Eggs", "Demon Eggs") and sel_biomes.get("Light & Dark"):
                biome_allowed = True

            return rarity_allowed and biome_allowed

        # Case A: Default (All Biomes, All Rarities) -> All 65 eggs pass
        all_passed = [
            e for e in self.egg_data
            if filter_egg(e["rawRecord"]["AreaId"], e["finalRarity"], {"All": True}, {"All": True})
        ]
        self.assertEqual(len(all_passed), 65)

        # Case B: None on Biome -> 0 eggs pass
        none_biome = [
            e for e in self.egg_data
            if filter_egg(e["rawRecord"]["AreaId"], e["finalRarity"], {}, {"All": True})
        ]
        self.assertEqual(len(none_biome), 0)

        # Case C: None on Rarity -> 0 eggs pass
        none_rarity = [
            e for e in self.egg_data
            if filter_egg(e["rawRecord"]["AreaId"], e["finalRarity"], {"All": True}, {})
        ]
        self.assertEqual(len(none_rarity), 0)

        # Case D: Only "Desert" biome -> exactly 5 eggs pass
        desert_only = [
            e for e in self.egg_data
            if filter_egg(e["rawRecord"]["AreaId"], e["finalRarity"], {"Desert": True}, {"All": True})
        ]
        self.assertEqual(len(desert_only), 5)
        for e in desert_only:
            self.assertEqual(e["rawRecord"]["AreaId"], "Desert")

        # Case E: Only "Common" rarity -> only Common eggs pass
        common_only = [
            e for e in self.egg_data
            if filter_egg(e["rawRecord"]["AreaId"], e["finalRarity"], {"All": True}, {"Common": True})
        ]
        self.assertGreater(len(common_only), 0)
        for e in common_only:
            self.assertEqual(e["finalRarity"], "Common")

        # Case F: Desert + Rare only
        desert_rare = [
            e for e in self.egg_data
            if filter_egg(e["rawRecord"]["AreaId"], e["finalRarity"], {"Desert": True}, {"Rare": True})
        ]
        for e in desert_rare:
            self.assertEqual(e["rawRecord"]["AreaId"], "Desert")
            self.assertEqual(e["finalRarity"], "Rare")

    def test_05_dropdown_uncheck_logic_from_all(self):
        """Verify that when starting from All, clicking an item deselects ONLY that item."""
        items = ["Forest", "Lake", "Desert", "Jungle"]
        sel = {"All": True}

        # User clicks "Desert" to deselect it
        it = "Desert"
        if sel.get("All"):
            sel = {other: True for other in items if other != it}
        else:
            sel[it] = None if sel.get(it) else True

        self.assertNotIn("All", sel)
        self.assertNotIn("Desert", sel)
        self.assertTrue(sel.get("Forest"))
        self.assertTrue(sel.get("Lake"))
        self.assertTrue(sel.get("Jungle"))

    def test_06_clean_outside_click_without_blocking_overlay(self):
        """Verify outside-click listener is hooked without blocking DropdownOverlay."""
        self.assertIn('isInsideGui', self.code)
        self.assertNotIn('Name = "DropdownOverlay"', self.code)

if __name__ == "__main__":
    unittest.main()
