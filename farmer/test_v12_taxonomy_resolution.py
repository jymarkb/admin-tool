#!/usr/bin/env python3
"""
Taxonomy and Field Resolution Verification Suite for EggGoToUI_v12.lua
Tests real game dumps (egg.json, egg-2.json, egg-3.json, egg-4.json) against v12
to ensure zero regression in species display name, rarity, rank, and biome.
"""

import json
import re
import unittest

def norm_name(s):
    if not s: return ""
    s = s.lower().strip()
    for p in ["rainbow", "golden", "silver", "gold", "shiny"]:
        if s.startswith(p + " "):
            s = s[len(p)+1:].strip()
    if s.endswith("egg"):
        s = s[:-3].strip()
    return s.strip()

class TestV12TaxonomyResolution(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        with open("farmer/EggGoToUI_v12.lua", "r") as f:
            cls.src = f.read()

        m = re.search(r'BiomeCatalog\s*=\s*\{(.*?)\n\s*Config\.Velocity', cls.src, re.DOTALL)
        assert m is not None, "Could not find BiomeCatalog in v12"
        cat_text = m.group(1)

        cls.info_map = {}
        cls.by_biome = {}

        current_biome = None
        for line in cat_text.splitlines():
            b_m = re.search(r'Biome\s*=\s*"([^"]+)"', line)
            if b_m:
                current_biome = b_m.group(1)
                cls.by_biome[current_biome] = {}
                continue

            spec_m = re.search(r'Name\s*=\s*"([^"]+)"\s*,\s*Rarity\s*=\s*"([^"]+)"', line)
            if spec_m and current_biome:
                name = spec_m.group(1)
                rar = spec_m.group(2)
                rec = {"DisplayName": name, "Rarity": rar, "Biome": current_biome}
                cls.info_map[norm_name(name)] = rec
                cls.by_biome[current_biome][norm_name(name)] = rec

                inner_m = re.search(r'\(([^)]+)\)', name)
                if inner_m:
                    cls.info_map[norm_name(inner_m.group(1))] = rec
                    cls.by_biome[current_biome][norm_name(inner_m.group(1))] = rec

                al_m = re.search(r'Aliases\s*=\s*\{([^}]+)\}', line)
                if al_m:
                    for al in re.findall(r'"([^"]+)"', al_m.group(1)):
                        cls.info_map[norm_name(al)] = rec
                        cls.by_biome[current_biome][norm_name(al)] = rec

    def test_01_all_13_biomes_in_catalog(self):
        """Ensure all 13 farmable biomes exist in BiomeCatalog."""
        expected = [
            "Forest", "Lake", "Desert", "Jungle", "Snow", "Volcano", "Abyss Ocean",
            "Prehistoric", "Cosmic", "Cherry Blossom", "Titan Temple", "Light & Dark", "Enchanted Forest"
        ]
        for b in expected:
            self.assertIn(b, self.by_biome, f"Biome '{b}' missing from catalog")

    def test_02_event_biomes_in_catalog(self):
        """Ensure event biomes exist in catalog including Halloween Dimension."""
        event_biomes = [
            "Brainrot Event", "Monster Eggs", "Void Eggs", "Luminous Eggs",
            "Dr. Scramble's Laboratory", "Dr. Scramble's Experiments", "Extinction Eggs", "Racing Event Eggs",
            "Halloween Dimension"
        ]
        for b in event_biomes:
            self.assertIn(b, self.by_biome, f"Event biome '{b}' missing from catalog")

    def test_03_real_game_dumps_taxonomy_match(self):
        """Verify 100% of eggs from real game logs match canonical biomes and rarities."""
        expected_biomes = {
            "Forest", "Lake", "Desert", "Jungle", "Snow", "Volcano", "Abyss Ocean",
            "Prehistoric", "Cosmic", "Cherry Blossom", "Titan Temple", "Light & Dark", "Enchanted Forest"
        }
        for log_path in ["farmer/egg.json", "farmer/egg-2.json", "farmer/egg-3.json"]:
            with open(log_path) as f:
                farmable = json.load(f)["farmableEggs"]
            self.assertEqual(len(farmable), 65)
            counts = {}
            for egg in farmable:
                spec_key = egg.get("assetCategory") or egg.get("rawName")
                clean = norm_name(spec_key)
                info = self.info_map.get(clean)
                self.assertIsNotNone(info, f"Unmatched species '{spec_key}' in {log_path}")
                self.assertNotEqual(info["Biome"], "Ungrouped", f"Species '{spec_key}' in {log_path} fell into Ungrouped")
                self.assertNotEqual(info["Rarity"], "Unknown", f"Species '{spec_key}' in {log_path} has Unknown rarity")
                counts[info["Biome"]] = counts.get(info["Biome"], 0) + 1
            self.assertEqual(set(counts.keys()), expected_biomes, f"Biome mismatch in {log_path}")
            for b, count in counts.items():
                self.assertEqual(count, 5, f"Biome '{b}' has {count} eggs in {log_path} (expected 5)")

    def test_04_shark_vs_mutant_shark_disambiguation(self):
        """Verify Shark in Titan Temple resolves to Mutant Shark Secret, while Shark in Abyss Ocean resolves to Legendary."""
        # Abyss Ocean Shark
        abyss_shark = self.by_biome.get("Abyss Ocean", {}).get("shark")
        self.assertIsNotNone(abyss_shark)
        self.assertEqual(abyss_shark["DisplayName"], "Shark")
        self.assertEqual(abyss_shark["Rarity"], "Legendary")

        # Titan Temple Mutant Shark
        titan_shark = self.by_biome.get("Titan Temple", {}).get("shark")
        self.assertIsNotNone(titan_shark)
        self.assertEqual(titan_shark["DisplayName"], "Mutant Shark")
        self.assertEqual(titan_shark["Rarity"], "Secret")

    def test_05_alias_resolutions(self):
        """Verify key aliases: Cosmic Beetle Blue -> Petal Beetle, Spirit Hare -> Astral Jackalope."""
        # Cosmic Beetle Blue
        info_beetle = self.info_map.get(norm_name("Cosmic Beetle Blue"))
        self.assertIsNotNone(info_beetle)
        self.assertEqual(info_beetle["DisplayName"], "Petal Beetle")
        self.assertEqual(info_beetle["Rarity"], "Mythic")
        self.assertEqual(info_beetle["Biome"], "Enchanted Forest")

        # Spirit Hare
        info_hare = self.info_map.get(norm_name("Spirit Hare"))
        self.assertIsNotNone(info_hare)
        self.assertEqual(info_hare["DisplayName"], "Astral Jackalope")
        self.assertEqual(info_hare["Rarity"], "Cosmic")
        self.assertEqual(info_hare["Biome"], "Enchanted Forest")

    def test_06_x_coordinate_biome_deduction(self):
        """Verify resolveEggFields contains the full spatial coordinate bounds."""
        self.assertIn("x >= 500 and x < 680 then searchArea = \"Forest\"", self.src)
        self.assertIn("x >= 680 and x < 850 then searchArea = \"Lake\"", self.src)
        self.assertIn("x >= 850 and x < 1050 then searchArea = \"Desert\"", self.src)
        self.assertIn("x >= 1050 and x < 1300 then searchArea = \"Jungle\"", self.src)
        self.assertIn("x >= 1300 and x < 1650 then searchArea = \"Snow\"", self.src)
        self.assertIn("x >= 1650 and x < 2050 then searchArea = \"Volcano\"", self.src)
        self.assertIn("x >= 2050 and x < 2500 then searchArea = \"Abyss Ocean\"", self.src)
        self.assertIn("x >= 2500 and x < 3100 then searchArea = \"Prehistoric\"", self.src)
        self.assertIn("x >= 3100 and x < 3700 then searchArea = \"Cosmic\"", self.src)
        self.assertIn("x >= 3700 and x < 4400 then searchArea = \"Cherry Blossom\"", self.src)
        self.assertIn("x >= 4400 and x < 5200 then searchArea = \"Titan Temple\"", self.src)
        self.assertIn("x >= 5200 and x < 6100 then searchArea = \"Light & Dark\"", self.src)
        self.assertIn("x >= 6100 and x < 7500 then searchArea = \"Enchanted Forest\"", self.src)

    def test_07_server_rarity_resolution(self):
        """Verify resolveEggFields reads live server rarity from RarityId and RarityByUid."""
        self.assertIn("r.RarityId or r.Rarity or (r.Attributes and r.Attributes.Rarity) or Engine.State.RarityByUid[uid]", self.src)

    def test_08_halloween_dimension_complete_species(self):
        """Verify complete Halloween dimension taxonomy coverage."""
        hw = self.by_biome.get("Halloween Dimension", {})
        expected_species = [
            ("voidseer pumpkin", "Divine"),
            ("abomination kong", "Eternal"),
            ("gorillastein", "Eternal"),
            ("gorillastine", "Eternal"),
            ("ghost reaper", "Eternal"),
            ("shelltide voyager", "Eternal"),
            ("halloween dimension", "Eternal"),
            ("bloodbloom", "Secret"),
            ("graveyard brute", "Secret"),
            ("phantom dragon", "Secret"),
            ("pumpkin golem", "Secret"),
            ("soul phantom", "Secret"),
            ("werewolf", "Secret"),
            ("halloween boss", "Cosmic"),
            ("haunted scorpio", "Cosmic"),
            ("hexed pumpkin", "Cosmic"),
            ("patchwork imp", "Cosmic"),
            ("spirit knight", "Cosmic"),
            ("witch crow", "Cosmic"),
            ("candlefang", "Mythic"),
            ("crowshade", "Mythic"),
            ("toadstool", "Mythic"),
            ("zombified halloween", "Mythic"),
            ("candy corn", "Legendary"),
            ("halloween royal mimic", "Legendary"),
            ("hooded gerbil", "Legendary"),
            ("jester", "Legendary"),
            ("jesterpop", "Legendary"),
            ("witch pumpkin", "Legendary"),
            ("ghost fish", "Epic"),
            ("mummy", "Epic"),
            ("whiskers", "Epic"),
            ("hollow bat", "Rare"),
            ("scarecrow", "Rare"),
        ]
        for name, rarity in expected_species:
            self.assertIn(name, hw, f"Species '{name}' missing from Halloween Dimension")
            self.assertEqual(hw[name]["Rarity"], rarity, f"Mismatched rarity for '{name}'")

if __name__ == "__main__":
    unittest.main()
