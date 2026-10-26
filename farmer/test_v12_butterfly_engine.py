#!/usr/bin/env python3
"""
Unit & Architectural Verification Suite for Lean Auto Butterfly Engine in farmer/EggGoToUI_v12.lua
Verifies:
  1. Config Defaults (Zone 6 coordinates: 6697.747, 70.724, -376.004)
  2. UI Elements & Layout in TabUtility (RowAutoButterfly at Y=304, ToggleButterflyBtn)
  3. Direct Net Equipping (Zero findNet overhead, direct FindFirstChild("Butterfly Net"))
  4. Specific & Direct Movement (goToEvent directly travels to ZonePosition, zero excess equipNet)
  5. Decoupled Isolation (Zero treadmill checks, zero egg waiting loop bloat)
  6. Zero Redundant Swing Logic (No AskSwing/AskSwarm remotes — game handles autoswing at location)
  7. Zero Butterfly Searching (No getClosestButterfly or model search loops)
  8. Lean Event Push Architecture (Only 2 event-level remotes; ZERO per-butterfly spam remotes)
  9. Lifecycle Cleanup & Root Locals Budget (<= 30)
"""

import re
import unittest

class TestV12ButterflyEngine(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        with open("farmer/EggGoToUI_v12.lua", "r") as f:
            cls.code = f.read()

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

    def test_02_root_locals_budget(self):
        """Verify root locals remain <= 30 with zero top-level bloat added."""
        root_locals = [
            l.strip() for l in self.code.splitlines()
            if re.match(r"^local\s+([a-zA-Z0-9_, ]+)", l)
        ]
        self.assertLessEqual(len(root_locals), 30, f"Expected <= 30 root locals, got {len(root_locals)}")

    def test_03_config_defaults(self):
        """Verify Config.Butterfly defaults."""
        self.assertIn("Config.Butterfly = {", self.code)
        self.assertIn("Enabled      = false", self.code)
        self.assertIn("6697.747, 70.724, -376.004", self.code)
        self.assertNotIn("SwingInterval", self.code, "Manual swing interval bloat must be eradicated")

    def test_04_ui_elements_and_tabutility_row(self):
        """Verify UI row in TabUtility."""
        self.assertIn('Name = "RowAutoButterfly"', self.code)
        self.assertIn('Text = "Auto Butterfly"', self.code)
        self.assertIn('Name = "ToggleButterflyBtn"', self.code)
        self.assertIn('UI.Elements.ToggleButterflyBtn = toggleBfBtn', self.code)
        self.assertIn('UDim2.new(0, 8, 0, 304)', self.code)

    def test_05_direct_net_equip(self):
        """Verify direct net tool equipping without separate findNet or cached net state."""
        self.assertNotIn("findNet", self.code, "findNet must be eradicated in favor of direct equip")
        self.assertNotIn("CachedNet", self.code, "CachedNet state tracking must be eliminated")
        self.assertIn("Engine.Butterfly.equipNet", self.code)
        self.assertIn('FindFirstChild("Butterfly Net")', self.code)
        self.assertIn("hum:EquipTool(net)", self.code)
        # Eradicate bloated attribute checks
        self.assertNotIn("item:GetAttribute(\"ButterflyNet\")", self.code)
        self.assertNotIn("item:GetAttribute(\"ItemType\")", self.code)

    def test_06_direct_movement_to_event(self):
        """Verify goToEvent moves directly to event zone and only equips net upon arrival."""
        self.assertIn("Engine.Butterfly.goToEvent", self.code)
        self.assertIn("Engine.Travel.walkToTarget(zone, 2.5", self.code)
        bf_code = self.code[self.code.find("Engine.Butterfly = {"):self.code.find("Engine.Pickup = {}")]
        # Verify no excess equipNet before walkToTarget
        pre_walk = bf_code[:bf_code.find("Engine.Travel.walkToTarget")]
        self.assertNotIn("equipNet()", pre_walk, "Must not excessively equip net before traveling")

    def test_07_decoupled_isolation_zero_treadmill_or_egg_coupling(self):
        """Verify zero treadmill detection or egg waiting loops inside butterfly engine."""
        bf_code = self.code[self.code.find("Engine.Butterfly = {"):self.code.find("Engine.Pickup = {}")]
        self.assertNotIn("isOnTreadmill", bf_code, "Must NOT check treadmill state in butterfly engine")
        self.assertNotIn("dismount", bf_code, "Must NOT call dismount in butterfly engine")
        self.assertNotIn("ReturnTripInProgress", bf_code, "Must NOT poll return trip in butterfly engine")
        self.assertNotIn("IsCarry", bf_code, "Must NOT poll carrying state in butterfly engine")

    def test_08_zero_swing_remotes_bloat(self):
        """Verify removal of AskSwing/AskSwarm since game auto-swings at location."""
        self.assertNotIn("RF/Butterflies/AskSwing", self.code, "AskSwing must not be invoked")
        self.assertNotIn("RF/Butterflies/AskSwarm", self.code, "AskSwarm must not be invoked")

    def test_09_zero_butterfly_searching_bloat(self):
        """Verify removal of getClosestButterfly and model searching loops."""
        self.assertNotIn("Engine.Butterfly.getClosestButterfly", self.code)
        self.assertNotIn("getClosestButterfly", self.code)

    def test_10_lean_event_push_architecture(self):
        """Ensure lean push architecture with only event-level remotes; zero per-butterfly spam."""
        self.assertNotIn("RF/LiveEvents/FetchRunning", self.code)
        bf_code = self.code[self.code.find("Engine.Butterfly = {"):self.code.find("Engine.Pickup = {}")]
        self.assertIn("RE/Butterflies/Announce", bf_code)
        self.assertIn("RE/LiveEvents/Ended", bf_code)
        # Eradicate per-butterfly spam remotes
        self.assertNotIn("RE/Butterflies/Spawned", bf_code, "Per-butterfly spawn spam remote must be removed")
        self.assertNotIn("RE/Butterflies/Removed", bf_code, "Per-butterfly catch spam remote must be removed")
        self.assertNotIn("RE/Butterflies/Escaped", bf_code, "Per-butterfly escape spam remote must be removed")
        self.assertNotIn("connectRemote", bf_code, "connectRemote helper wrapper bloat must be removed")

    def test_11_lifecycle_and_cleanup(self):
        """Verify cleanup restores state cleanly."""
        self.assertIn("if Config.Butterfly then", self.code)
        self.assertIn("if Engine.Butterfly then", self.code)
        self.assertIn("Engine.Butterfly.EventActive = false", self.code)
        self.assertNotIn("CachedNet", self.code)

if __name__ == "__main__":
    unittest.main()
