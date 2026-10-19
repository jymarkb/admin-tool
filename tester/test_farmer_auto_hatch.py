#!/usr/bin/env python3
"""
Unit Test Suite for Auto Hatch Integration in farmer/EggGoToUI_v10.lua
Validates:
1. DEFAULT_SETTINGS, validateSettings, and applySettings handle AutoHatch
2. Tab 4 Utility Suite Layout (Row 5 Auto Pen, Row 6 Auto Hatch, Row 7 Auto Catch Butterflies)
3. Placed egg discovery from Workspace.PlacedEggRenders & RF/ProfileMirror/FetchProfile
4. Batch hatch invocation of RF/EggWorld/AskHatch & RF/EggWorld/AskFinishHatch
5. 5-second treadmill duration threshold requirement
6. Clean reset of treadmill timers upon dismount
"""

import os
import re
import unittest

MAIN_SCRIPT_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "farmer", "EggGoToUI_v10.lua"))

class TestFarmerAutoHatch(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        self = cls
        with open(MAIN_SCRIPT_PATH, "r", encoding="utf-8") as f:
            self.content = f.read()

    def test_settings_integration(self):
        """Verify DEFAULT_SETTINGS, validateSettings, and applySettings handle AutoHatch."""
        self.assertIn("AutoHatch          = false", self.content)
        self.assertIn('if t.AutoHatch ~= nil and typeof(t.AutoHatch) ~= "boolean" then', self.content)
        self.assertIn("currentSettings.AutoHatch = X.autoHatchEnabled == true", self.content)
        self.assertIn("X.syncAutoHatchUI", self.content)

    def test_ui_hierarchy_below_auto_pen(self):
        """Verify Row 6 Auto Hatch is placed directly below Row 5 Auto Pen."""
        pen_order = self.content.find("rowPen.LayoutOrder = 5")
        hatch_order = self.content.find("rowHatch.LayoutOrder = 6")
        bf_order = self.content.find("rowButterfly.LayoutOrder = 7")

        self.assertNotEqual(pen_order, -1, "rowPen must have LayoutOrder 5")
        self.assertNotEqual(hatch_order, -1, "rowHatch must have LayoutOrder 6")
        self.assertNotEqual(bf_order, -1, "rowButterfly must have LayoutOrder 7")
        self.assertLess(pen_order, hatch_order, "Auto Pen must precede Auto Hatch")
        self.assertLess(hatch_order, bf_order, "Auto Hatch must precede Auto Catch Butterflies")

        self.assertIn("Auto Hatch (5s Treadmill)", self.content)

    def test_placed_egg_discovery_and_remotes(self):
        """Verify X.scanPlacedEggs and X.executeHatchAllPlaced invoke correct remotes."""
        self.assertIn("function X.scanPlacedEggs", self.content)
        self.assertIn("function X.executeHatchAllPlaced", self.content)
        self.assertIn('RF/EggWorld/AskHatch', self.content)
        self.assertIn('RF/EggWorld/AskFinishHatch', self.content)
        self.assertIn('Workspace:FindFirstChild("PlacedEggRenders")', self.content)

    def test_5s_treadmill_trigger(self):
        """Verify hatching is strictly gated behind having been on the treadmill for at least 5 seconds."""
        # 1. autoFarmLoop check
        self.assertIn("elapsed >= 5.0", self.content,
                      "Must check elapsed >= 5.0s on treadmill")
        self.assertIn("X.treadmillEnteredAt", self.content)
        self.assertIn("X.hasHatchedThisTreadmillSession", self.content)
        self.assertIn("X.initAutoHatchMonitor", self.content)

        # 2. Reset on dismount
        dismount_pos = self.content.find("function X.executeAutoDismount")
        dismount_body = self.content[dismount_pos:dismount_pos+300]
        self.assertIn("X.treadmillEnteredAt = nil", dismount_body,
                      "Dismount must reset X.treadmillEnteredAt")
        self.assertIn("X.hasHatchedThisTreadmillSession = false", dismount_body,
                      "Dismount must reset X.hasHatchedThisTreadmillSession")

if __name__ == "__main__":
    suite = unittest.TestLoader().loadTestsFromTestCase(TestFarmerAutoHatch)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if result.wasSuccessful():
        print("\n" + "=" * 50)
        print("ALL 4 AUTO HATCH INTEGRATION TESTS PASSED!")
        print("=" * 50)
        exit(0)
    else:
        exit(1)
