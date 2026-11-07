#!/usr/bin/env python3
"""
Unit & Architectural Verification Suite for farmer/SimpleEggListUI.lua
Verifies:
  1. Syntax & Bracket Balance: 100% balanced (), {}, [].
  2. Luau Root Locals Budget: Root locals <= 190 (target <= 30).
  3. Single-Domain Isolation:
     - Pure egg list viewer grouped per biome.
     - No velocity physics, no auto-walk engine, no auto-sell, no combat/bat tools.
  4. Single Action Button on Each Egg Item:
     - Verifies GoBtn is created on each item.
     - Verifies strict absence of bloat buttons (No Velocity bar, No Utility panel toggles, No Filter dropdowns).
  5. 3-Step Swap Sequence Execution:
     - Verifies findForestEgg, fastPickup, and executeSwapSequence implementations.
     - Verifies teleportTo and _G.DropperTargetEggPos bridge.
  6. Biome Grouping:
     - Canonical farmable biomes catalog & taxonomy normalization.
     - Live egg grouping per biome.
  7. Zero-Crosstalk Network & Clean Teardown:
     - AreaEggSlotsClient ChildAdded/ChildRemoved hooks.
     - RemoteEvent push listeners (FieldEggShifted, FieldEggBatchShifted, FieldEggGone).
     - Clean connection tracking and teardown (_G.SimpleEggListUI_Cleanup).
"""

import re
import unittest
import os

TARGET_FILE = "farmer/SimpleEggListUI.lua"

class TestSimpleEggListUI(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        if not os.path.exists(TARGET_FILE):
            cls.code = ""
            return
        with open(TARGET_FILE, "r") as f:
            cls.code = f.read()

    def test_00_file_exists(self):
        self.assertTrue(os.path.exists(TARGET_FILE), f"{TARGET_FILE} must exist")

    def test_01_bracket_and_syntax_balance(self):
        """Ensure 100% balance of parentheses, brackets, and braces."""
        stack = []
        pairs = {"(": ")", "{": "}", "[": "]"}
        for i, ch in enumerate(self.code):
            if ch in pairs:
                stack.append((ch, i))
            elif ch in pairs.values():
                self.assertTrue(len(stack) > 0, f"Unmatched closing '{ch}' at char {i}")
                top, top_i = stack.pop()
                self.assertEqual(pairs[top], ch, f"Mismatched {top} at {top_i} with {ch} at {i}")
        self.assertEqual(len(stack), 0, f"Unclosed brackets remaining: {stack}")

    def test_02_luau_root_locals_budget(self):
        """Ensure root locals strictly remain <= 190 (Roblox hard limit 200). Target: <= 30."""
        root_locals = [
            l.strip() for l in self.code.splitlines()
            if re.match(r"^local\s+([a-zA-Z0-9_, ]+)", l)
        ]
        self.assertLessEqual(len(root_locals), 30, f"Expected <= 30 root locals, got {len(root_locals)}")
        self.assertLessEqual(len(root_locals), 190, "Root locals strictly exceeded 190 budget limit!")

    def test_03_action_button_on_items(self):
        """Verify each item has the single action button (GoBtn) and no legacy bloat buttons."""
        self.assertIn('Name = "GoBtn"', self.code, "Item must have GoBtn action button")
        self.assertIn("Engine.executeSwapSequence", self.code, "GoBtn must trigger executeSwapSequence")

        # Verify absence of legacy bloat controls from v12
        forbidden_patterns = [
            r'VelToggleBtn',
            r'TogglePickupBtn',
            r'ToggleRecoveryBtn',
            r'ToggleNoclipBtn',
            r'ToggleTrapEvadeBtn',
            r'ToggleTreadmillBtn',
            r'TriggerDismountBtn',
            r'ToggleButterflyBtn',
            r'createFilterDropdown',
        ]
        for pat in forbidden_patterns:
            self.assertIsNone(
                re.search(pat, self.code),
                f"Forbidden control '{pat}' detected in SimpleEggListUI!"
            )

    def test_04_swap_sequence_workflow(self):
        """Verify 3-step sequence: TP Forest egg -> Fast pick up -> Hit Authority TP clicked egg."""
        self.assertIn("Engine.findForestEgg", self.code, "Engine must define findForestEgg")
        self.assertIn("Engine.fastPickup", self.code, "Engine must define fastPickup")
        self.assertIn("Engine.teleportTo", self.code, "Engine must define teleportTo")
        self.assertIn("executeSwapSequence", self.code, "Engine must define executeSwapSequence")
        self.assertIn("_G.DropperTargetEggPos", self.code, "Must expose target egg position to dropper-1.lua")

        # Anti-rubberband hit authority from dropper-1.lua
        self.assertIn("Engine.strikeTeleportToTarget", self.code, "Engine must define strikeTeleportToTarget")
        self.assertIn("RE/GuardPatrol/ForestStrike", self.code, "Must request ForestStrike for hit authority")
        self.assertIn("RE/GuardPatrol/SpeedTollOffer", self.code, "Must listen for SpeedTollOffer strike confirmation")
        self.assertIn("Helpers.nullifyRagdoll", self.code, "Must define nullifyRagdoll to clear ragdoll physics")
        self.assertIn("Engine.dropEggSpam", self.code, "Must define dropEggSpam to eject Forest bait egg")
        self.assertIn("Helpers.getForestGuardCFrame", self.code, "Must define getForestGuardCFrame")

        # Ported TP & Pickup helpers from EggGoToUI_v12.lua
        self.assertIn("Helpers.getEggInstance", self.code, "Must port getEggInstance from EggGoToUI_v12")
        self.assertIn("snapBeside", self.code, "teleportTo must support snapBeside geometry from EggGoToUI_v12")
        self.assertIn("RaycastFilterType.Exclude", self.code, "teleportTo must use ground raycast from EggGoToUI_v12")
        self.assertIn("Helpers.extractSlotKey", self.code, "Must extract FirstAreaSlotKey matching forest.log")
        self.assertIn("FirstAreaSlotKey", self.code, "AskFieldEggCarry must send FirstAreaSlotKey matching forest.log")

    def test_05_biome_catalog_and_grouping(self):
        """Verify 13 canonical biomes and biome grouping logic."""
        expected_biomes = [
            "Forest", "Lake", "Desert", "Jungle", "Snow", "Volcano", "Abyss Ocean",
            "Prehistoric", "Cosmic", "Cherry Blossom", "Titan Temple", "Light & Dark", "Enchanted Forest"
        ]
        for b in expected_biomes:
            self.assertIn(f'"{b}"', self.code, f"Canonical biome '{b}' must be recognized")
        self.assertIn("BiomeOrder", self.code, "BiomeOrder must be defined for sorted grouping")

    def test_06_live_event_hooks_and_cleanup(self):
        """Verify live event hooks, snapshot sync, and safe cleanup."""
        self.assertIn("AreaEggSlotsClient", self.code)
        self.assertIn("FieldEggShifted", self.code)
        self.assertIn("FieldEggBatchShifted", self.code)
        self.assertIn("FieldEggGone", self.code)
        self.assertIn("_G.SimpleEggListUI_Cleanup", self.code)
        self.assertIn("disconnectAll", self.code)

    def test_07_clipboard_and_logging(self):
        """Verify internal log tracking, clipboard copy support, and CopyLogBtn."""
        self.assertIn("State.Logs", self.code, "State must maintain Logs table")
        self.assertIn("Helpers.log", self.code, "Helpers must implement log function")
        self.assertIn("Helpers.copyLogs", self.code, "Helpers must implement copyLogs function")
        self.assertIn("setclipboard", self.code, "copyLogs must support setclipboard")
        self.assertIn('Name = "CopyLogBtn"', self.code, "TitleBar must feature CopyLogBtn")
        self.assertIn("Helpers.copyLogs()", self.code, "CopyLogBtn must trigger copyLogs")

    def test_08_forest_egg_disambiguation(self):
        """Verify Forest egg selection strictly excludes Enchanted Forest to prevent wrong teleports."""
        self.assertIn('not low:find("enchanted", 1, true)', self.code,
                      "findForestEgg must strictly filter out Enchanted Forest slots")
        self.assertIn('not string.find(tostring(State.ForestEggUid), "Enchanted", 1, true)', self.code,
                      "getForestEggUid must strictly exclude Enchanted Forest")

    def test_09_hop_towards_egg_and_distance_box(self):
        """Verify Hop button on rows, adjustable hop distance box, and hopTowardsEgg logic."""
        self.assertIn('Name = "HopBtn"', self.code, "Item must have HopBtn action button")
        self.assertIn("Engine.hopTowardsEgg", self.code, "HopBtn must trigger Engine.hopTowardsEgg")
        self.assertIn('Name = "HopControlBar"', self.code, "Must have HopControlBar")
        self.assertIn('Name = "HopDistanceBox"', self.code, "Must have HopDistanceBox for live tuning")
        self.assertIn("Config.HopDistance", self.code, "Must define Config.HopDistance")
        self.assertIn("Config.HopInterval", self.code, "Must define Config.HopInterval")
        self.assertIn("State.IsHopping", self.code, "Must define State.IsHopping")

        # Extract hopTowardsEgg function definition to verify strict boundaries
        hop_fn_match = re.search(r"Engine\.hopTowardsEgg\s*=\s*function\((.*?)\)(.*?)Engine\.Sync", self.code, re.DOTALL)
        self.assertIsNotNone(hop_fn_match, "Engine.hopTowardsEgg function must be defined")
        hop_body = hop_fn_match.group(2)

        # Must perform chunked CFrame Lerp with safe interval
        self.assertIn("startPos:Lerp", hop_body, "hopTowardsEgg must interpolate chunks via startPos:Lerp")
        self.assertIn("AssemblyLinearVelocity", hop_body, "hopTowardsEgg must zero velocity to prevent rubberbanding")

        # Strict Boundary: "only add hop towards egg do not add pick up or return"
        self.assertNotIn("fastPickup", hop_body, "hopTowardsEgg must NOT call fastPickup")
        self.assertNotIn("dropEggSpam", hop_body, "hopTowardsEgg must NOT call dropEggSpam")
        self.assertNotIn("ForestStrike", hop_body, "hopTowardsEgg must NOT call ForestStrike")
        self.assertNotIn("AskFieldEggCarry", hop_body, "hopTowardsEgg must NOT trigger pickup remotes")

if __name__ == "__main__":
    unittest.main()
