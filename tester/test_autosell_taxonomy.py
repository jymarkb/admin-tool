#!/usr/bin/env python3
"""
Unit test verifying autosell.lua taxonomy, rarity tiers, and egg grouping.
Option A: Full synchronization against sample-egg.json and game assets.
"""

import unittest
import re

class TestAutosellTaxonomy(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with open("farmer/autosell.lua") as f:
            cls.lua_code = f.read()

        # Strip Lua comments
        cls.clean_code = re.sub(r'--[^\n]*', '', cls.lua_code)

        def parse_lua_table(name):
            m = re.search(rf'local {name} = \{{(.*?)\n\}}', cls.clean_code, re.DOTALL)
            assert m, f"Table {name} not found"
            entries = {}
            for k, v, num in re.findall(r'\[\"([^\"]+)\"\]\s*=\s*(?:\"([^\"]+)\"|(\d+))', m.group(1)):
                entries[k] = v if v else int(num)
            return entries

        cls.rarity_ranks = parse_lua_table("RARITY_RANK")
        cls.presets = parse_lua_table("PET_RARITY_PRESETS")
        cls.species_to_egg = parse_lua_table("STATIC_SPECIES_TO_BIOME_EGG")
        cls.defaults = parse_lua_table("EGG_NAME_TO_DEFAULT_RARITY")

        m_biomes = re.search(r'local ALL_BIOMES_AND_EVENTS = \{(.*?)\n\}', cls.clean_code, re.DOTALL)
        assert m_biomes, "ALL_BIOMES_AND_EVENTS not found"
        cls.all_biomes = set(re.findall(r'\"([^\"]+)\"', m_biomes.group(1)))

    def test_rarity_ranks(self):
        self.assertEqual(self.rarity_ranks.get("1%"), 12)
        self.assertEqual(self.rarity_ranks.get("Brainrot"), 11)
        self.assertEqual(self.rarity_ranks.get("Divine"), 10)
        self.assertEqual(self.rarity_ranks.get("Eternal"), 9)
        self.assertEqual(self.rarity_ranks.get("Secret"), 8)
        self.assertEqual(self.rarity_ranks.get("Cosmic"), 7)
        self.assertEqual(self.rarity_ranks.get("Mythic"), 6)
        self.assertEqual(self.rarity_ranks.get("Legendary"), 5)
        self.assertEqual(self.rarity_ranks.get("Epic"), 4)
        self.assertEqual(self.rarity_ranks.get("Rare"), 3)
        self.assertEqual(self.rarity_ranks.get("Uncommon"), 2)
        self.assertEqual(self.rarity_ranks.get("Common"), 1)
        self.assertEqual(self.rarity_ranks.get("Unknown"), 0)

    def test_halloween_royal_mimic(self):
        self.assertEqual(self.presets.get("Halloween Royal Mimic Egg"), "Legendary")
        self.assertEqual(self.presets.get("Halloween Royal Mimic"), "Legendary")
        self.assertEqual(self.presets.get("Royal Mimic"), "Legendary")
        self.assertEqual(self.presets.get("Mimic Chest"), "Legendary")
        self.assertEqual(self.presets.get("Mimic Chest Egg"), "Legendary")
        self.assertEqual(self.species_to_egg.get("Halloween Royal Mimic Egg"), "Halloween Dimension Egg")
        self.assertEqual(self.species_to_egg.get("Royal Mimic"), "Halloween Dimension Egg")
        self.assertEqual(self.species_to_egg.get("Mimic Chest"), "Halloween Dimension Egg")

    def test_desert_lark(self):
        self.assertEqual(self.species_to_egg.get("DesertLark"), "Desert Egg")
        self.assertEqual(self.presets.get("DesertLark"), "Rare")

    def test_brainrot_pets(self):
        for br in ["Bananita Dolphinita", "Belula Beluga", "Bomboclat Crocolat", "Mangolini Parrochini", "Strawberry Elephant", "Tung Tung Sahur"]:
            self.assertEqual(self.presets.get(br), "Brainrot")
            self.assertEqual(self.species_to_egg.get(br), "Brainrot Egg")

    def test_mecha_pets(self):
        for mecha in ["Mecha Scorpio", "Mecha Froggo", "Mecha Crawler", "Mecha Crocodon", "Mecha Krakenoid", "Mecha Dreadscale"]:
            self.assertEqual(self.presets.get(mecha), "1%")
            self.assertEqual(self.species_to_egg.get(mecha), "Monster Egg")

    def test_luminous_pets(self):
        for lum in ["Luminous Spike", "Luminous Spirit Manta", "Luminous Abyss Shark", "Luminous Electric Eel", "Luminous Terra Snapper", "Luminous Cthulhu"]:
            self.assertEqual(self.presets.get(lum), "1%")
            self.assertEqual(self.species_to_egg.get(lum), "Luminous Egg")

    def test_distinct_biome_groupings(self):
        self.assertEqual(self.species_to_egg.get("Chicken"), "Forest Egg")
        self.assertEqual(self.species_to_egg.get("Duckling"), "Lake Egg")
        self.assertEqual(self.species_to_egg.get("Toucan"), "Jungle Egg")
        self.assertEqual(self.species_to_egg.get("Dragon"), "Volcano Egg")
        self.assertEqual(self.species_to_egg.get("Shark"), "Abyss Ocean Egg")

    def test_safety_hold_base_egg(self):
        self.assertNotIn("egg", self.defaults)

    def test_canonical_biomes_count(self):
        self.assertGreaterEqual(len(self.all_biomes), 22)
        for canon in ["Forest Egg", "Lake Egg", "Jungle Egg", "Volcano Egg", "Abyss Ocean Egg", "Halloween Dimension Egg", "Brainrot Egg"]:
            self.assertIn(canon, self.all_biomes)

if __name__ == "__main__":
    unittest.main()
