#!/usr/bin/env python3
"""
Unit test verifying Biome / Event Egg Grouping + Rarity resolution for the 103 eggs in pen-6.log.
Matches the in-game inventory UI shown in Screenshot 2026-10-14 103939.png.
"""

import unittest
import re

# Static authoritative mapping of pet species -> Biome / Event Egg
SPECIES_TO_BIOME_EGG = {
    # Cosmic Egg (Cosmic Biome)
    "Alien Skeleton Boss": "Cosmic Egg",
    "Cosmic Skeleton Boss": "Cosmic Egg",
    "Cave Dragon": "Cosmic Egg",
    "Cosmic Dragon": "Cosmic Egg",
    "Cosmic Fox": "Cosmic Egg",
    "Starry Fox": "Cosmic Egg",
    "Cosmic Lion": "Cosmic Egg",
    "Cyclops Gorilla": "Cosmic Egg",
    "Cosmic Gorilla": "Cosmic Egg",
    "Eternal Lunar Dragon": "Cosmic Egg",
    "Galaxy Gecko": "Cosmic Egg",
    "Cosmic Gecko": "Cosmic Egg",
    "La Vacca Saturno Saturnita": "Cosmic Egg",
    "Mantis": "Cosmic Egg",
    "Cosmic Beetle Blue": "Cosmic Egg",
    "Drilla": "Cosmic Egg",

    # Angels & Demons Egg (Event)
    "Dark Gargoyle": "Angels & Demons Egg",
    "Gargoyle": "Angels & Demons Egg",
    "Centaur": "Angels & Demons Egg",
    "Jellyfish": "Angels & Demons Egg",
    "Pure Jellyfish": "Angels & Demons Egg",
    "Skeleton Horse": "Angels & Demons Egg",
    "Pegasus": "Angels & Demons Egg",
    "ArchAngel": "Angels & Demons Egg",
    "World Burner": "Angels & Demons Egg",
    "RazorFang": "Angels & Demons Egg",
    "Imp": "Angels & Demons Egg",
    "Demon Hound": "Angels & Demons Egg",
    "Flame Sprite": "Angels & Demons Egg",
    "Toro": "Angels & Demons Egg",
    "Archdemon Dragon": "Angels & Demons Egg",
    "Lamb": "Angels & Demons Egg",
    "Winged Lamb": "Angels & Demons Egg",
    "Moth": "Angels & Demons Egg",
    "Sacred Moth": "Angels & Demons Egg",
    "Peacock": "Angels & Demons Egg",
    "Holy Peacock": "Angels & Demons Egg",

    # Enchanted Forest Egg (Enchanted Forest Biome)
    "Spirit Panda": "Enchanted Forest Egg",
    "Spirit Hare": "Enchanted Forest Egg",
    "Toucax": "Enchanted Forest Egg",
    "Red Panda": "Enchanted Forest Egg",
    "Enchanted Bluejay": "Enchanted Forest Egg",
    "Salamander": "Enchanted Forest Egg",
    "Stag": "Enchanted Forest Egg",
    "Centapede": "Enchanted Forest Egg",
    "Unicorn": "Enchanted Forest Egg",
    "Kitsune": "Enchanted Forest Egg",
    "Koi": "Enchanted Forest Egg",
    "Snowy Owl": "Enchanted Forest Egg",
    "Crane": "Enchanted Forest Egg",
    "Oni Tiger": "Enchanted Forest Egg",

    # Titan Temple Egg (Titan Temple Biome)
    "King Kong": "Titan Temple Egg",
    "Gorilla King": "Titan Temple Egg",
    "Kaiju Spider": "Titan Temple Egg",
    "Godzilla": "Titan Temple Egg",
    "Nightflame": "Titan Temple Egg",
    "Blade Head": "Titan Temple Egg",
    "Crab": "Titan Temple Egg",
    "Rhino": "Titan Temple Egg",
    "Rhinobear": "Titan Temple Egg",
    "Rhinotaur": "Titan Temple Egg",

    # Prehistoric Egg (Prehistoric Biome)
    "Mosasaurus": "Prehistoric Egg",
    "TyrannosaurusRex": "Prehistoric Egg",
    "TRex": "Prehistoric Egg",
    "Tralaledon": "Prehistoric Egg",
    "Triceratops": "Prehistoric Egg",
    "Bronto": "Prehistoric Egg",
    "Ankylosaurus": "Prehistoric Egg",
    "Pterodactyl": "Prehistoric Egg",
    "Dodo": "Prehistoric Egg",

    # Snow Egg (Snow Biome)
    "Ice Dragon": "Snow Egg",
    "Yeti": "Snow Egg",
    "King Mammoth": "Snow Egg",
    "Mammoth": "Snow Egg",
    "Colossal Mammoth": "Snow Egg",
    "Sabertooth Tiger": "Snow Egg",
    "Polar Bear": "Snow Egg",
    "Walrus": "Snow Egg",
    "Penguin": "Snow Egg",

    # Ocean Egg / Depths Egg (Ocean / Depths Biome)
    "Whale Shark": "Ocean Egg",
    "Shark": "Ocean Egg",
    "Mutant Shark": "Ocean Egg",
    "Finned Thresher": "Ocean Egg",
    "Beluga Whale": "Ocean Egg",
    "Orca": "Ocean Egg",
    "Kraken": "Ocean Egg",
    "El Maja": "Ocean Egg",
    "Swordfish": "Ocean Egg",
    "Parrotfish": "Ocean Egg",
    "Stacked Turtle": "Ocean Egg",
    "Octophant": "Ocean Egg",
    "Abyss Overlord": "Depths Egg",
    "Riptide Octopus": "Ocean Egg",

    # Biohazard Egg (Biohazard Biome)
    "Biohazard": "Biohazard Egg",
    "Toxic Rat": "Biohazard Egg",
    "Radcoon": "Biohazard Egg",
    "Toxic Crocodile": "Biohazard Egg",
    "Toxic Hedgehog": "Biohazard Egg",
    "Nuclear Mantis": "Biohazard Egg",
    "Nuceodille": "Biohazard Egg",

    # Desert Egg (Desert Biome)
    "Royal Sphinx": "Desert Egg",
    "Irihorus": "Desert Egg",
    "Sand Spider": "Desert Egg",
    "Scorpion": "Desert Egg",
    "DeathstalkerScorpion": "Desert Egg",
    "Snake": "Desert Egg",
    "Rattlesnake": "Desert Egg",
    "Tob Tobi Tob Tob": "Desert Egg",
    "Camel": "Desert Egg",
    "Fennec": "Desert Egg",
    "FennecFox": "Desert Egg",
    "Jerboa": "Desert Egg",
    "DesertLark": "Desert Egg",

    # Lava Egg (Lava Biome)
    "Phoenix": "Lava Egg",
    "Ascended Vermilion Phoenix": "Lava Egg",
    "Lava Dragon": "Lava Egg",
    "Dragon": "Lava Egg",
    "Cerberus": "Lava Egg",
    "Chillin Chilli": "Lava Egg",
    "Lava Iguana": "Lava Egg",
    "Flaming Bull": "Lava Egg",
    "Lava Frog": "Lava Egg",
    "Lava Gecko": "Lava Egg",
    "Ash Gecko": "Lava Egg",

    # Unstable / Farm / Starter Egg
    "Frogfly": "Unstable Egg",
    "Wheel Hamster": "Unstable Egg",
    "Three Headed Chicken": "Unstable Egg",
    "Spiderpig": "Unstable Egg",
    "Chicken": "Egg",
    "Dog": "Egg",
    "Frog": "Egg",
    "Duckling": "Egg",
    "Catfish": "Egg",
    "Turtle": "Egg",
}

SPECIES_TO_RARITY = {
    # Divine
    "ArchAngel": "Divine", "World Burner": "Divine", "Archdemon Dragon": "Divine",
    "Unicorn": "Divine", "Kitsune": "Divine", "Nightflame": "Divine", "Godzilla": "Divine",
    "Nuclear Mantis": "Divine", "Cthulhu": "Divine", "Luminous Cthulhu": "Divine",
    "Shattered Colossus": "Divine", "Dreadscale": "Divine", "Mecha Dreadscale": "Divine",
    "Depths Riptide Octopus": "Divine", "Aetheron": "Divine",

    # Eternal
    "Eternal Lunar Dragon": "Eternal", "Skeleton Horse": "Eternal", "Pegasus": "Eternal",
    "Oni Tiger": "Eternal", "King Kong": "Eternal", "Gorilla King": "Eternal",
    "Mosasaurus": "Eternal", "Ice Dragon": "Eternal", "El Maja": "Eternal",
    "Riptide Octopus": "Eternal", "Phoenix": "Eternal", "Ascended Vermilion Phoenix": "Eternal",
    "Lava Dragon": "Eternal", "Dragon": "Eternal", "Nuceodille": "Eternal",
    "Void Dragon": "Eternal", "Shattered Drake": "Eternal", "Void Serpent": "Eternal",
    "World Eater": "Eternal", "Strawberry Elephant": "Eternal", "Krakenoid": "Eternal",
    "Mecha Krakenoid": "Eternal", "Terra Snapper": "Eternal", "Luminous Terra Snapper": "Eternal",
    "Balrog": "Eternal", "Equinox": "Eternal",

    # Secret
    "Alien Skeleton Boss": "Secret", "Cosmic Skeleton Boss": "Secret",
    "Cave Dragon": "Secret", "Cosmic Dragon": "Secret",
    "Cosmic Fox": "Secret", "Dark Gargoyle": "Secret", "Gargoyle": "Secret",
    "Centaur": "Secret", "Jellyfish": "Secret", "Pure Jellyfish": "Secret",
    "RazorFang": "Secret", "Stag": "Secret", "TyrannosaurusRex": "Secret",
    "TRex": "Secret", "Tralaledon": "Secret", "Yeti": "Secret",
    "Mutant Shark": "Secret", "Kraken": "Secret", "Biohazard": "Secret",
    "Cerberus": "Secret", "King Snake": "Secret", "Warden": "Secret",
    "Bomboclat Crocolat": "Secret", "Crocodon": "Secret", "Mecha Crocodon": "Secret",
    "Electric Eel": "Secret", "Luminous Electric Eel": "Secret", "Abyss Overlord": "Secret",
    "Ember Dragon": "Secret", "Experiment #001": "Secret", "Mawbreaker": "Secret",
    "Shardwing": "Secret", "Wendigo": "Secret", "Ringlord": "Secret",

    # Cosmic
    "Cosmic Lion": "Cosmic", "La Vacca Saturno Saturnita": "Cosmic", "Mantis": "Cosmic",
    "Drilla": "Cosmic", "Imp": "Cosmic", "Demon Hound": "Cosmic", "Moth": "Cosmic",
    "Sacred Moth": "Cosmic", "Peacock": "Cosmic", "Holy Peacock": "Cosmic",
    "Spirit Panda": "Cosmic", "Spirit Hare": "Cosmic", "Koi": "Cosmic",
    "Snowy Owl": "Cosmic", "Rhino": "Cosmic", "Rhinotaur": "Cosmic",
    "Triceratops": "Cosmic", "Bronto": "Cosmic", "King Mammoth": "Cosmic",
    "Colossal Mammoth": "Cosmic", "Whale Shark": "Cosmic", "Beluga Whale": "Cosmic",
    "Royal Sphinx": "Cosmic", "Irihorus": "Cosmic", "Crawler": "Cosmic",
    "Mecha Crawler": "Cosmic", "Abyss Shark": "Cosmic", "Luminous Abyss Shark": "Cosmic",
    "Leviathan": "Cosmic", "Basilisk": "Cosmic", "Nibbles #013": "Cosmic",
    "Dreadclaw": "Cosmic", "Shattered Ram": "Cosmic", "Ventinal": "Cosmic",
    "Mangolini Parrochini": "Cosmic",

    # Mythic
    "Cyclops Gorilla": "Mythic", "Cosmic Gorilla": "Mythic", "Cosmic Beetle Blue": "Mythic",
    "Lamb": "Mythic", "Winged Lamb": "Mythic", "Toro": "Mythic", "Toucax": "Mythic",
    "Red Panda": "Mythic", "Enchanted Bluejay": "Mythic", "Blade Head": "Mythic",
    "Rhinobear": "Mythic", "Ankylosaurus": "Mythic", "Mammoth": "Mythic",
    "Sabertooth Tiger": "Mythic", "Orca": "Mythic", "Sand Spider": "Mythic",
    "Scorpion": "Mythic", "DeathstalkerScorpion": "Mythic", "Chillin Chilli": "Mythic",
    "Froggo": "Mythic", "Mecha Froggo": "Mythic", "Spirit Manta": "Mythic",
    "Luminous Spirit Manta": "Mythic", "Belula Beluga": "Mythic", "Shadow Dragon": "Mythic",
    "Riftwing": "Mythic", "Shardling": "Mythic", "Voidmaw": "Mythic", "Tiger": "Mythic",
    "Spider": "Mythic",

    # Legendary
    "Galaxy Gecko": "Legendary", "Cosmic Gecko": "Legendary", "Flame Sprite": "Legendary",
    "Salamander": "Legendary", "Kaiju Spider": "Legendary", "Crab": "Legendary",
    "Sharkodile": "Legendary", "Pterodactyl": "Legendary", "Polar Bear": "Legendary",
    "Shark": "Legendary", "Finned Thresher": "Legendary", "Snake": "Legendary",
    "Rattlesnake": "Legendary", "Hellhound": "Legendary", "Lava Iguana": "Legendary",
    "Flaming Bull": "Legendary", "Scorpio": "Legendary", "Mecha Scorpio": "Legendary",
    "Spike": "Legendary", "Luminous Spike": "Legendary", "Baby Aurora Dragon": "Legendary",
    "Rift Eye": "Legendary", "Void Angler": "Legendary", "Dove": "Legendary",
    "Brr Brr Patapim": "Legendary", "Axolotl": "Legendary", "Dream Axolotl": "Legendary",
    "Gorilla": "Legendary", "Prism Gecko": "Legendary",

    # Epic
    "Centapede": "Epic", "Crane": "Epic", "Walrus": "Epic", "Swordfish": "Epic",
    "Toxic Crocodile": "Epic", "Tob Tobi Tob Tob": "Epic", "Uncoiled Armadillo": "Epic",
    "Lava Frog": "Epic", "Citadel Snail": "Epic", "Ash Gecko": "Epic",
    "Bananita Dolphinita": "Epic", "Trulimero Trulicina": "Epic", "Swan": "Epic",
    "Fox": "Epic", "Bear": "Epic", "Crocodile": "Epic",

    # Rare
    "Frogfly": "Rare", "Wheel Hamster": "Rare", "Three Headed Chicken": "Rare",
    "Dodo": "Rare", "Penguin": "Rare", "Stacked Turtle": "Rare", "Octophant": "Rare",
    "Parrotfish": "Rare", "Toxic Hedgehog": "Rare", "Camel": "Rare",
    "DesertLark": "Rare", "Lava Gecko": "Rare", "Tung Tung Sahur": "Rare",
    "Burrowing Owl": "Rare", "Owl": "Rare", "Raccoon": "Rare", "Turtle": "Rare",
    "Toucan": "Rare", "Chimpanzee": "Rare",

    # Uncommon
    "Catfish": "Uncommon", "Bird": "Uncommon", "Fennec": "Uncommon", "FennecFox": "Uncommon",

    # Common
    "Toxic Rat": "Common", "Radcoon": "Common", "Spiderpig": "Common", "Chicken": "Common",
    "Dog": "Common", "Frog": "Common", "Duckling": "Common", "Jerboa": "Common",
}

KNOWN_BIOME_EGGS = [
    "Angels & Demons Egg",
    "Titan Temple Egg",
    "Cosmic Egg",
    "Prehistoric Egg",
    "Enchanted Forest Egg",
    "Snow Egg",
    "Biohazard Egg",
    "Cherry Blossom Egg",
    "Ocean Egg",
    "Depths Egg",
    "Desert Egg",
    "Lava Egg",
    "Unstable Egg",
    "Riftborn Egg",
    "Monster Egg",
    "Dragon Egg",
    "Luminous Egg",
    "Egg",
]


def resolve_egg_biome_and_rarity(raw_name_or_species, direct_rarity=None):
    if not raw_name_or_species:
        return "Unknown Egg", direct_rarity or "Common"

    # Clean off weight like " (85,711Kg)" or " (24kg)"
    cleaned = re.sub(r"\s*\([0-9,.]+\s*[Kk][Gg]\)\s*$", "", str(raw_name_or_species)).strip()
    low = cleaned.lower()

    # 1. Direct Biome / Event Egg exact match
    for b_egg in KNOWN_BIOME_EGGS:
        b_low = b_egg.lower()
        b_base = re.sub(r"\s*egg$", "", b_low)
        if low == b_low or low == b_base:
            rar = direct_rarity or SPECIES_TO_RARITY.get(cleaned) or "Common"
            return b_egg, rar

    # 2. Species exact match first
    for sp, egg_group in SPECIES_TO_BIOME_EGG.items():
        if sp.lower() == low:
            rar = direct_rarity or SPECIES_TO_RARITY.get(sp) or "Common"
            return egg_group, rar

    # 3. Direct Biome / Event Egg substring match
    for b_egg in KNOWN_BIOME_EGGS:
        b_low = b_egg.lower()
        b_base = re.sub(r"\s*egg$", "", b_low)
        if b_base in low:
            rar = direct_rarity or SPECIES_TO_RARITY.get(cleaned) or "Common"
            return b_egg, rar

    # 4. Species substring match (longest keys first to prevent "Dragon" matching "Cave Dragon")
    for sp in sorted(SPECIES_TO_BIOME_EGG.keys(), key=len, reverse=True):
        if sp.lower() in low or low in sp.lower():
            egg_group = SPECIES_TO_BIOME_EGG[sp]
            rar = direct_rarity or SPECIES_TO_RARITY.get(sp) or "Common"
            return egg_group, rar

    # 5. Fallback
    fallback = cleaned
    if not fallback.lower().endswith("egg"):
        fallback = fallback + " Egg"
    rar = direct_rarity or "Common"
    return fallback, rar


class TestBiomeGrouping(unittest.TestCase):
    def test_pen_6_all_103_eggs_grouping(self):
        # Raw entries from pen-6.log
        pen_6_counts = {
            "Alien Skeleton Boss": 4,
            "Cave Dragon": 6,
            "Centapede": 1,
            "Centaur": 1,
            "Cosmic Fox": 6,
            "Cosmic Lion": 2,
            "Cyclops Gorilla": 1,
            "Dark Gargoyle": 14,
            "Eternal Lunar Dragon": 1,
            "Frogfly": 4,
            "Ice Dragon": 1,
            "Jellyfish": 7,
            "Kaiju Spider": 2,
            "King Kong": 3,
            "Mosasaurus": 2,
            "Octophant": 1,
            "Radcoon": 1,
            "Red Panda": 1,
            "Salamander": 1,
            "Shark": 3,
            "Skeleton Horse": 2,
            "Spiderpig": 1,
            "Spirit Hare": 1,
            "Spirit Panda": 13,
            "Stacked Turtle": 2,
            "Stag": 2,
            "Three Headed Chicken": 1,
            "Toucax": 4,
            "Toxic Rat": 7,
            "TyrannosaurusRex": 1,
            "Whale Shark": 1,
            "Wheel Hamster": 6,
        }

        total_eggs = sum(pen_6_counts.values())
        self.assertEqual(total_eggs, 103)

        grouped = {}
        for sp, count in pen_6_counts.items():
            b_egg, rar = resolve_egg_biome_and_rarity(sp)
            if b_egg not in grouped:
                grouped[b_egg] = {"Total": 0, "Rarities": {}}
            grouped[b_egg]["Total"] += count
            grouped[b_egg]["Rarities"][rar] = grouped[b_egg]["Rarities"].get(rar, 0) + count

        # Verify grouped totals
        self.assertIn("Cosmic Egg", grouped)
        self.assertEqual(grouped["Cosmic Egg"]["Total"], 20)
        self.assertEqual(grouped["Cosmic Egg"]["Rarities"]["Secret"], 16)  # 6 Fox + 6 Dragon + 4 Alien Boss
        self.assertEqual(grouped["Cosmic Egg"]["Rarities"]["Cosmic"], 2)   # 2 Lion
        self.assertEqual(grouped["Cosmic Egg"]["Rarities"]["Mythic"], 1)   # 1 Gorilla
        self.assertEqual(grouped["Cosmic Egg"]["Rarities"]["Eternal"], 1)  # 1 Lunar Dragon

        self.assertIn("Angels & Demons Egg", grouped)
        self.assertEqual(grouped["Angels & Demons Egg"]["Total"], 24)
        self.assertEqual(grouped["Angels & Demons Egg"]["Rarities"]["Secret"], 22) # 14 Gargoyle + 7 Jellyfish + 1 Centaur
        self.assertEqual(grouped["Angels & Demons Egg"]["Rarities"]["Eternal"], 2) # 2 Skeleton Horse

        self.assertIn("Enchanted Forest Egg", grouped)
        self.assertEqual(grouped["Enchanted Forest Egg"]["Total"], 23)
        self.assertEqual(grouped["Enchanted Forest Egg"]["Rarities"]["Cosmic"], 14) # 13 Panda + 1 Hare
        self.assertEqual(grouped["Enchanted Forest Egg"]["Rarities"]["Mythic"], 5)  # 4 Toucax + 1 Red Panda
        self.assertEqual(grouped["Enchanted Forest Egg"]["Rarities"]["Secret"], 2)  # 2 Stag
        self.assertEqual(grouped["Enchanted Forest Egg"]["Rarities"]["Legendary"], 1) # 1 Salamander
        self.assertEqual(grouped["Enchanted Forest Egg"]["Rarities"]["Epic"], 1)    # 1 Centapede

        self.assertIn("Titan Temple Egg", grouped)
        self.assertEqual(grouped["Titan Temple Egg"]["Total"], 5)
        self.assertEqual(grouped["Titan Temple Egg"]["Rarities"]["Eternal"], 3)    # 3 King Kong
        self.assertEqual(grouped["Titan Temple Egg"]["Rarities"]["Legendary"], 2)  # 2 Kaiju Spider

        self.assertIn("Prehistoric Egg", grouped)
        self.assertEqual(grouped["Prehistoric Egg"]["Total"], 3)
        self.assertEqual(grouped["Prehistoric Egg"]["Rarities"]["Eternal"], 2)     # 2 Mosasaurus
        self.assertEqual(grouped["Prehistoric Egg"]["Rarities"]["Secret"], 1)      # 1 TRex

        self.assertIn("Snow Egg", grouped)
        self.assertEqual(grouped["Snow Egg"]["Total"], 1)
        self.assertEqual(grouped["Snow Egg"]["Rarities"]["Eternal"], 1)            # 1 Ice Dragon

        self.assertIn("Biohazard Egg", grouped)
        self.assertEqual(grouped["Biohazard Egg"]["Total"], 8)
        self.assertEqual(grouped["Biohazard Egg"]["Rarities"]["Common"], 8)        # 7 Toxic Rat + 1 Radcoon

        self.assertIn("Ocean Egg", grouped)
        self.assertEqual(grouped["Ocean Egg"]["Total"], 7)
        self.assertEqual(grouped["Ocean Egg"]["Rarities"]["Legendary"], 3)         # 3 Shark
        self.assertEqual(grouped["Ocean Egg"]["Rarities"]["Rare"], 3)              # 2 Turtle + 1 Octophant
        self.assertEqual(grouped["Ocean Egg"]["Rarities"]["Cosmic"], 1)            # 1 Whale Shark

        self.assertIn("Unstable Egg", grouped)
        self.assertEqual(grouped["Unstable Egg"]["Total"], 12)
        self.assertEqual(grouped["Unstable Egg"]["Rarities"]["Rare"], 11)          # 6 Hamster + 4 Frogfly + 1 Chicken
        self.assertEqual(grouped["Unstable Egg"]["Rarities"]["Common"], 1)         # 1 Spiderpig

        # Verify sum matches 103 exactly
        sum_total = sum(g["Total"] for g in grouped.values())
        self.assertEqual(sum_total, 103)

    def test_direct_biome_names_from_screenshot(self):
        # Items directly visible in Screenshot 2026-10-14 103939.png
        b, r = resolve_egg_biome_and_rarity("Titan Temple Egg (111,774Kg)", "Divine")
        self.assertEqual(b, "Titan Temple Egg")
        self.assertEqual(r, "Divine")

        b, r = resolve_egg_biome_and_rarity("Cosmic Egg (69,058Kg)", "Cosmic")
        self.assertEqual(b, "Cosmic Egg")
        self.assertEqual(r, "Cosmic")

        b, r = resolve_egg_biome_and_rarity("Prehistoric Egg (94,745Kg)", "Eternal")
        self.assertEqual(b, "Prehistoric Egg")
        self.assertEqual(r, "Eternal")

        b, r = resolve_egg_biome_and_rarity("Snow Egg (59,888Kg)", "Eternal")
        self.assertEqual(b, "Snow Egg")
        self.assertEqual(r, "Eternal")

        b, r = resolve_egg_biome_and_rarity("Enchanted Forest Egg (85,711Kg)", "Legendary")
        self.assertEqual(b, "Enchanted Forest Egg")
        self.assertEqual(r, "Legendary")

        b, r = resolve_egg_biome_and_rarity("Angels & Demons Egg (11,303Kg)", "Secret")
        self.assertEqual(b, "Angels & Demons Egg")
        self.assertEqual(r, "Secret")


if __name__ == "__main__":
    unittest.main()
