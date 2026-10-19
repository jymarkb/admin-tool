#!/usr/bin/env python3
"""
Unit Test Suite for Auto Catch Butterflies Feature
Validates:
1. DEFAULT_SETTINGS & Settings Validation/Application
2. Butterfly Zone Coordinates (6697.747, 70.724, -376.004)
3. Butterfly Net Tool Resolution & Auto-Equipping Logic
4. Network Listeners & Event State Detection
5. Priority Farming Architecture (Farm First Before Butterflies)
6. Dynamic Abort / Cancellation When Eggs Respawn
7. UI Tab 4 (Utility) Row 6 Integration & Serialization
"""

import os
import re
import unittest

FILE_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "farmer", "EggGoToUI_v10.lua"))

class TestButterflyAutoFarm(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        self = cls
        with open(FILE_PATH, "r", encoding="utf-8") as f:
            self.content = f.read()

    def test_default_settings_and_validation(self):
        """Verify DEFAULT_SETTINGS, validateSettings, and applySettings handle AutoCatchButterflies."""
        # 1. DEFAULT_SETTINGS
        self.assertIn("AutoCatchButterflies = false", self.content,
                      "DEFAULT_SETTINGS must define AutoCatchButterflies = false")
        
        # 2. validateSettings
        self.assertRegex(self.content,
                         r'if\s+t\.AutoCatchButterflies\s*~=\s*nil\s+and\s+typeof\(t\.AutoCatchButterflies\)\s*~=\s*"boolean"\s+then',
                         "validateSettings must ensure AutoCatchButterflies is a boolean")

        # 3. applySettings
        self.assertRegex(self.content,
                         r'if\s+t\.AutoCatchButterflies\s*~=\s*nil\s+then\s+X\.autoButterflyEnabled\s*=\s*t\.AutoCatchButterflies\s+end',
                         "applySettings must update X.autoButterflyEnabled")
        self.assertIn("currentSettings.AutoCatchButterflies = X.autoButterflyEnabled == true", self.content,
                      "currentSettings.AutoCatchButterflies must be synchronized")

    def test_butterfly_zone_coordinates(self):
        """Verify BUTTERFLY_ZONE is defined with exact XYZ: 6697.747, 70.724, -376.004."""
        match = re.search(r'BUTTERFLY_ZONE\s*=\s*Vector3\.new\(\s*6697\.747\s*,\s*70\.724\s*,\s*-376\.004\s*\)', self.content)
        self.assertIsNotNone(match, "X.BUTTERFLY_ZONE must be Vector3.new(6697.747, 70.724, -376.004)")

    def test_butterfly_net_identification_and_equipping(self):
        """Verify tool inspection identifies Butterfly Net and equips it from Backpack/Inventory."""
        # 1. Tool check helper
        self.assertIn("function X.isButterflyNetTool", self.content,
                      "X.isButterflyNetTool function must be defined")
        self.assertIn('item.Name == "Butterfly Net"', self.content)
        self.assertIn('item:GetAttribute("ButterflyNet") == true', self.content)
        self.assertIn('item:GetAttribute("ItemType") == "ButterflyNet"', self.content)

        # 2. Equip function
        self.assertIn("function X.equipButterflyNet", self.content,
                      "X.equipButterflyNet function must be defined")
        self.assertIn('LocalPlayer:FindFirstChild("Backpack")', self.content)
        self.assertIn('hum:EquipTool', self.content,
                      "Must equip net from Backpack via Humanoid:EquipTool")
        self.assertIn('X._cachedButterflyNet', self.content,
                      "Must use O(1) cached tool reference for zero search overhead")
        self.assertNotIn('RF/Butterflies/AskClaimNet', self.content,
                         "Claiming logic must be removed since player already possesses the net")

    def test_butterfly_event_monitoring_and_remotes(self):
        """Verify network listener setup for live event and workspace detection."""
        self.assertIn("function X.initButterflyMonitor", self.content)
        self.assertIn("RE/Butterflies/Announce", self.content)
        self.assertIn("RE/Butterflies/Spawned", self.content)
        self.assertIn("RE/Butterflies/Removed", self.content)
        self.assertIn("RE/Butterflies/Escaped", self.content)
        self.assertIn("RE/LiveEvents/Began", self.content)
        self.assertIn("RE/LiveEvents/Ended", self.content)
        self.assertIn("RF/Butterflies/AskSwing", self.content)
        self.assertIn("RF/Butterflies/AskSwarm", self.content)
        self.assertIn("function X.isButterflyEventActive", self.content)

    def test_late_login_and_in_progress_fallbacks(self):
        """Verify fallbacks when joining late or missing RE/Butterflies/Announce."""
        # 1. Server remote function polling for active live events
        self.assertIn('RF/LiveEvents/FetchRunning', self.content,
                      "Must query RF/LiveEvents/FetchRunning to detect running events on late login")
        # 2. Workspace butterfly physical presence check
        self.assertIn("function X.hasButterfliesInWorkspace", self.content)
        self.assertIn("function X.getButterflies", self.content)
        # 3. Dynamic container hooking for future folder addition
        self.assertIn("Workspace.ChildAdded", self.content,
                      "Must hook Workspace.ChildAdded to detect butterfly folders created after load")
        # 4. Immediate startup check via task.spawn
        self.assertIn("task.spawn", self.content)

    def test_priority_farming_architecture(self):
        """Verify AutoFarm focuses on farming first before traveling to butterfly zone."""
        # 1. Carried eggs delivered first
        carry_pos = self.content.find("if not skip and weAreCarrying then")
        no_target_pos = self.content.find("elseif not target and not skip then")
        butterfly_pos = self.content.find("elseif X.autoButterflyEnabled and X.isButterflyEventActive() then")
        target_pos = self.content.find("elseif typeof(target) == \"table\" and not skip then")
        
        self.assertGreater(no_target_pos, carry_pos, "Carrying check must precede egg targeting")
        self.assertGreater(butterfly_pos, no_target_pos, "Butterfly branch must be inside 'not target' block")
        self.assertLess(butterfly_pos, target_pos, "Butterfly branch must be part of no-target handling before target branch")

        # 2. X.hasFarmEggAvailable priority guard
        self.assertIn("function X.hasFarmEggAvailable", self.content)
        self.assertIn("weAreCarrying", self.content)
        self.assertIn("X.pickNearest", self.content)

        # 3. Dynamic cancellation during butterfly catching
        self.assertIn("X.hasFarmEggAvailable()", self.content,
                      "Butterfly cancel check must query X.hasFarmEggAvailable() to break loop on egg spawn")

    def test_treadmill_dismount_on_butterfly_event(self):
        """Verify character dismounts from treadmill if butterfly event starts."""
        self.assertIn("X.autoButterflyEnabled and X.isButterflyEventActive()", self.content)
        self.assertIn("isButterflyDismount = true", self.content)
        self.assertIn("X.executeAutoDismount(", self.content)

    def test_ui_tab_4_row_6_integration(self):
        """Verify Tab 4 Utility has Row 6 for Auto Catch Butterflies with toggle and serialization."""
        self.assertIn("Auto Catch Butterflies", self.content)
        self.assertIn("rowButterfly.LayoutOrder = 7", self.content)
        self.assertIn("X.syncAutoButterflyUI = updateButterflyButtonState", self.content)
        self.assertIn("currentSettings.AutoCatchButterflies = X.autoButterflyEnabled == true", self.content)

    def test_stationary_zone_holding(self):
        """Verify character holds strictly stationary at BUTTERFLY_ZONE without wandering."""
        # 1. No wandering towards butterflies
        self.assertNotIn("hum:MoveTo(bPos)", self.content,
                         "Must NOT move towards individual butterflies — hold one zone location only")
        # 2. Holds position at zone with zero movement
        self.assertIn("hum:Move(Vector3.zero)", self.content,
                      "Must stop movement at zone with hum:Move(Vector3.zero)")
        self.assertIn("distFromCenter > 2.5", self.content,
                      "Must only re-align if drifted away from zone")


if __name__ == "__main__":
    suite = unittest.TestLoader().loadTestsFromTestCase(TestButterflyAutoFarm)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if result.wasSuccessful():
        print("\n" + "=" * 50)
        print("ALL 7 BUTTERFLY AUTOFARM UNIT TESTS PASSED!")
        print("=" * 50)
        exit(0)
    else:
        exit(1)
