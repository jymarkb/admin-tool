#!/usr/bin/env python3
"""
Unit test verifying Egg Bag scanning, Grouping by Type and Rarity, and LocalCFrame calculations.
"""

import unittest
import re


def clean_egg_name(name):
    if not name:
        return "Unknown Egg"
    # Remove weight suffix e.g. " (85,711Kg)" or " (24kg)"
    cleaned = re.sub(r"\s*\([0-9,.]+\s*[Kk][Gg]\)\s*$", "", name)
    # Remove trailing/leading spaces
    cleaned = cleaned.strip()
    if not cleaned.lower().endswith("egg"):
        cleaned = cleaned + " Egg"
    return cleaned


def resolve_egg_rarity(species, direct_rarity=None):
    if direct_rarity and direct_rarity not in ("", "Unknown"):
        return direct_rarity

    rarity_map = {
        "biohazard": "Secret",
        "experiment": "Secret",
        "angels & demons": "Divine",
        "titan temple": "Divine",
        "cosmic": "Cosmic",
        "enchanted forest": "Legendary",
        "snow": "Rare",
        "prehistoric": "Rare",
        "unstable": "Common",
        "cherry blossom": "Rare",
        "lava": "Legendary",
    }
    low = species.lower()
    for key, rar in rarity_map.items():
        if key in low:
            return rar
    return "Common"


def group_eggs(egg_list):
    groups = {}
    for egg in egg_list:
        clean_group = clean_egg_name(egg.get("Name") or egg.get("DisplayName") or "Egg")
        rarity = resolve_egg_rarity(clean_group, egg.get("Rarity"))

        if clean_group not in groups:
            groups[clean_group] = {
                "GroupName": clean_group,
                "TotalCount": 0,
                "Rarities": {},
            }

        groups[clean_group]["TotalCount"] += 1
        if rarity not in groups[clean_group]["Rarities"]:
            groups[clean_group]["Rarities"][rarity] = {
                "Rarity": rarity,
                "Count": 0,
                "Eggs": [],
            }

        groups[clean_group]["Rarities"][rarity]["Count"] += 1
        groups[clean_group]["Rarities"][rarity]["Eggs"].append(egg)

    return groups


class TestBagGrouping(unittest.TestCase):
    def test_clean_egg_name(self):
        self.assertEqual(clean_egg_name("Enchanted Forest Egg (85,711Kg)"), "Enchanted Forest Egg")
        self.assertEqual(clean_egg_name("Snow Egg (1,710Kg)"), "Snow Egg")
        self.assertEqual(clean_egg_name("Angels & Demons Egg (1,852,765Kg)"), "Angels & Demons Egg")
        self.assertEqual(clean_egg_name("Biohazard Egg"), "Biohazard Egg")
        self.assertEqual(clean_egg_name("Biohazard"), "Biohazard Egg")
        self.assertEqual(clean_egg_name("Egg (24Kg)"), "Egg")

    def test_group_eggs_aggregation(self):
        sample_eggs = [
            {"Uid": "u1", "Name": "Biohazard Egg", "Rarity": "Secret", "Weight": 15000},
            {"Uid": "u2", "Name": "Biohazard Egg", "Rarity": "Secret", "Weight": 12000},
            {"Uid": "u3", "Name": "Angels & Demons Egg (1,852,765Kg)", "Rarity": "Divine", "Weight": 1852765},
            {"Uid": "u4", "Name": "Angels & Demons Egg (9,369Kg)", "Rarity": "Secret", "Weight": 9369},
            {"Uid": "u5", "Name": "Angels & Demons Egg (6,853Kg)", "Rarity": "Secret", "Weight": 6853},
            {"Uid": "u6", "Name": "Enchanted Forest Egg (85,711Kg)", "Rarity": "Legendary", "Weight": 85711},
            {"Uid": "u7", "Name": "Enchanted Forest Egg (6,522Kg)", "Rarity": "Epic", "Weight": 6522},
        ]

        grouped = group_eggs(sample_eggs)

        self.assertIn("Biohazard Egg", grouped)
        self.assertEqual(grouped["Biohazard Egg"]["TotalCount"], 2)
        self.assertEqual(grouped["Biohazard Egg"]["Rarities"]["Secret"]["Count"], 2)

        self.assertIn("Angels & Demons Egg", grouped)
        self.assertEqual(grouped["Angels & Demons Egg"]["TotalCount"], 3)
        self.assertEqual(grouped["Angels & Demons Egg"]["Rarities"]["Divine"]["Count"], 1)
        self.assertEqual(grouped["Angels & Demons Egg"]["Rarities"]["Secret"]["Count"], 2)

        self.assertIn("Enchanted Forest Egg", grouped)
        self.assertEqual(grouped["Enchanted Forest Egg"]["TotalCount"], 2)
        self.assertEqual(grouped["Enchanted Forest Egg"]["Rarities"]["Legendary"]["Count"], 1)
        self.assertEqual(grouped["Enchanted Forest Egg"]["Rarities"]["Epic"]["Count"], 1)

    def test_local_cframe_math(self):
        # Verify plot-to-object-space coordinate translation
        plot_pivot = (522.8, 68.2, -203.4)
        target_world_pos = (543.936, 67.6999, -118.025)

        # local = world - pivot
        local_x = target_world_pos[0] - plot_pivot[0]
        local_y = target_world_pos[1] - plot_pivot[1]
        local_z = target_world_pos[2] - plot_pivot[2]

        # Should match the user's sniffed parameters: ~21.136, -0.500, 85.375
        self.assertAlmostEqual(local_x, 21.136, places=2)
        self.assertAlmostEqual(local_y, -0.500, places=2)
        self.assertAlmostEqual(local_z, 85.375, places=2)

    def test_selection_filtering(self):
        sample_eggs = [
            {"Uid": "u1", "Name": "Biohazard Egg", "Rarity": "Secret", "Weight": 15000},
            {"Uid": "u2", "Name": "Angels & Demons Egg", "Rarity": "Divine", "Weight": 1000},
            {"Uid": "u3", "Name": "Angels & Demons Egg", "Rarity": "Secret", "Weight": 500},
        ]
        grouped = group_eggs(sample_eggs)

        # Select only Biohazard Egg_Secret and Angels & Demons Egg_Divine
        selected_keys = {
            "Biohazard Egg_Secret": True,
            "Angels & Demons Egg_Divine": True,
            "Angels & Demons Egg_Secret": False,
        }

        selected_eggs = []
        for g_name, g_data in grouped.items():
            for r_name, r_data in g_data["Rarities"].items():
                if selected_keys.get(f"{g_name}_{r_name}"):
                    selected_eggs.extend(r_data["Eggs"])

        self.assertEqual(len(selected_eggs), 2)
        uids = {e["Uid"] for e in selected_eggs}
        self.assertIn("u1", uids)
        self.assertIn("u2", uids)
        self.assertNotIn("u3", uids)

    def test_generate_bag_report_text(self):
        sample_eggs = [
            {"Uid": "u1", "Name": "Biohazard Egg", "Rarity": "Secret", "Weight": 15000},
            {"Uid": "u2", "Name": "Angels & Demons Egg (9,369Kg)", "Rarity": "Secret", "Weight": 9369},
        ]
        grouped = group_eggs(sample_eggs)
        report_lines = []
        report_lines.append(f"TOTAL UNPLACED EGGS IN BAG: {len(sample_eggs)}")
        for g_name, g_data in sorted(grouped.items()):
            report_lines.append(f"📦 {g_name} (Total: {g_data['TotalCount']})")
            for r_name, r_data in sorted(g_data["Rarities"].items()):
                report_lines.append(f"    • [{r_name}] x {r_data['Count']}")

        report = "\n".join(report_lines)
        self.assertIn("TOTAL UNPLACED EGGS IN BAG: 2", report)
        self.assertIn("📦 Biohazard Egg (Total: 1)", report)
        self.assertIn("📦 Angels & Demons Egg (Total: 1)", report)
        self.assertIn("[Secret] x 1", report)

    def test_egg_rarity_resolution_no_common_fallback(self):
        # Eggs without direct rarity attribute must resolve using default egg mapping instead of "Common"
        self.assertEqual(resolve_egg_rarity("Biohazard Egg"), "Secret")
        self.assertEqual(resolve_egg_rarity("Experiment Egg"), "Secret")
        self.assertEqual(resolve_egg_rarity("Angels & Demons Egg"), "Divine")
        self.assertEqual(resolve_egg_rarity("Titan Temple Egg"), "Divine")
        self.assertEqual(resolve_egg_rarity("Cosmic Egg"), "Cosmic")
        self.assertEqual(resolve_egg_rarity("Enchanted Forest Egg"), "Legendary")
        self.assertEqual(resolve_egg_rarity("Snow Egg"), "Rare")
        self.assertEqual(resolve_egg_rarity("Prehistoric Egg"), "Rare")

    def test_find_my_plot_tier0_homestead_ask_state(self):
        # Simulating pen-6.log Homestead state where slot 3 maps to user 4262245390
        owners_by_slot = {
            "1": 11639523613,
            "2": 11721477978,
            "3": 4262245390,
            "5": 10840520125,
            "6": 9521640019,
        }
        my_user_id = 4262245390
        found_slot = None
        for slot_key, owner_id in owners_by_slot.items():
            if int(owner_id) == my_user_id:
                found_slot = int(slot_key)
                break
        self.assertEqual(found_slot, 3)

    def test_slot_collision_avoidance(self):
        # Grid slots along X/Z
        grid_slots = [
            (500.0, 67.7, -150.0),
            (504.0, 67.7, -150.0),
            (508.0, 67.7, -150.0),
            (512.0, 67.7, -150.0),
        ]
        # Existing placed egg at slot 1
        current_placed = [{"Pos": (500.1, 67.7, -150.0)}]

        # Allocate 2 new slots
        allocated = []
        slot_idx = 0
        for _ in range(2):
            target_pos = None
            while slot_idx < len(grid_slots):
                candidate = grid_slots[slot_idx]
                occupied = False
                for p_egg in current_placed:
                    dx = p_egg["Pos"][0] - candidate[0]
                    dz = p_egg["Pos"][2] - candidate[2]
                    if (dx * dx + dz * dz) ** 0.5 < 2.5:
                        occupied = True
                        break
                slot_idx += 1
                if not occupied:
                    target_pos = candidate
                    break
            if target_pos:
                allocated.append(target_pos)
                current_placed.append({"Pos": target_pos})

        # Slot 0 was occupied, so allocated slots must be slot 1 and slot 2
        self.assertEqual(len(allocated), 2)
        self.assertEqual(allocated[0], (504.0, 67.7, -150.0))
        self.assertEqual(allocated[1], (508.0, 67.7, -150.0))

    def test_is_real_egg_tool_rejects_pets(self):
        # Implementation of isRealEggTool in Python for testing
        def is_real_egg_tool(name, attrs):
            item_type = attrs.get("ItemType")
            if item_type == "Asset":  # Pet engine type
                return False
            if item_type == "Gear" or "GearName" in attrs or attrs.get("IsBat") is True:
                return False
            if item_type == "MutationConsumable" or "MutationId" in attrs:
                return False
            if item_type == "ButterflyNet" or attrs.get("ButterflyNet") is True:
                return False
            if item_type == "Egg" or attrs.get("Category") == "Egg" or "EggUid" in attrs:
                return True
            if "egg" in name.lower():
                return True
            return False

        # Pet tools from bag.log / pen-9.log
        pet_hamster = {"ItemType": "Asset", "Category": "Wheel Hamster", "UID": "u1"}
        pet_spiderpig = {"ItemType": "Asset", "Category": "Spiderpig", "UID": "u2"}
        pet_toro = {"ItemType": "Asset", "Category": "Toro", "UID": "u3"}
        gear_bat = {"ItemType": "Gear", "IsBat": True, "GearName": "Titan Axe"}
        potion = {"ItemType": "MutationConsumable", "MutationId": "Nitro"}

        self.assertFalse(is_real_egg_tool("Wheel Hamster (12.34 kg)", pet_hamster))
        self.assertFalse(is_real_egg_tool("Spiderpig (186.57 kg)", pet_spiderpig))
        self.assertFalse(is_real_egg_tool("Toro", pet_toro))
        self.assertFalse(is_real_egg_tool("Titan Axe [X1]", gear_bat))
        self.assertFalse(is_real_egg_tool("Nitro [X11]", potion))

        # Real egg tools
        egg_tool = {"ItemType": "Egg", "EggUid": "e1"}
        unstable_egg = {}
        self.assertTrue(is_real_egg_tool("Unstable Egg", unstable_egg))
        self.assertTrue(is_real_egg_tool("Egg", egg_tool))
        self.assertTrue(is_real_egg_tool("Biohazard Egg", {}))

    def test_generate_pen_grid_slots_cframe_transformation(self):
        # Verify that grid slots generated using local pet area bounds stay strictly inside
        sz_x = 112.7
        sz_z = 49.3
        margin = 3.0
        usable_x = max(2.0, sz_x - margin * 2)
        usable_z = max(2.0, sz_z - margin * 2)
        slot_spacing = 4.0
        cols = max(1, int(usable_x // slot_spacing))
        rows = max(1, int(usable_z // slot_spacing))

        half_usable_x = usable_x / 2.0
        half_usable_z = usable_z / 2.0

        for r in range(1, rows + 1):
            for c in range(1, cols + 1):
                lx = -half_usable_x + (c - 0.5) * (usable_x / cols)
                lz = -half_usable_z + (r - 0.5) * (usable_z / rows)

                # Must be strictly within pet area boundaries
                self.assertGreaterEqual(lx, -sz_x / 2.0)
                self.assertLessEqual(lx, sz_x / 2.0)
                self.assertGreaterEqual(lz, -sz_z / 2.0)
                self.assertLessEqual(lz, sz_z / 2.0)

    def test_checkerboard_dispersion_spacing(self):
        import math
        cols, rows = 10, 4
        usable_x, usable_z = 104.7, 41.3

        phase1, phase2 = [], []
        for r in range(1, rows + 1):
            for c in range(1, cols + 1):
                if (r + c) % 2 == 0:
                    phase1.append((r, c))
                else:
                    phase2.append((r, c))

        all_slots = phase1 + phase2
        first_9 = all_slots[:9]

        coords = []
        for r, c in first_9:
            x = -usable_x / 2.0 + (c - 0.5) * (usable_x / cols)
            z = -usable_z / 2.0 + (r - 0.5) * (usable_z / rows)
            coords.append((x, z))

        min_dist = float("inf")
        for i in range(len(coords)):
            for j in range(i + 1, len(coords)):
                d = math.hypot(coords[i][0] - coords[j][0], coords[i][1] - coords[j][1])
                if d < min_dist:
                    min_dist = d

        # Minimum distance between any two eggs among first 9 must be > 14 studs
        self.assertGreater(min_dist, 14.0)


if __name__ == "__main__":
    unittest.main()
