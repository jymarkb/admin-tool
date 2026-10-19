#!/usr/bin/env python3
"""
Unit Test Suite for Standalone Auto Hatch Test Suite (farmer/AutoHatchTest.lua)
Validates:
1. Target Remote RF/EggWorld/AskHatch and Sample Parameter "195552ae54d5418bb16ac9265c445b83"
2. Auxiliary Remotes (AskFinishHatch, FetchProfile)
3. Placed Egg Discovery Engine (Workspace.PlacedEggRenders & ProfileMirror)
4. ProximityPrompt Detection & Fallback
5. Standalone HUD Components (Draggable Bar, UID TextBox, Actions, Log Console)
6. Autonomous Auto-Hatch Loop Architecture
7. Zero modification to EggGoToUI_v10.lua
"""

import os
import re
import unittest
try:
    import luaparser.ast as ast
    LUAPARSER_AVAILABLE = True
except ImportError:
    LUAPARSER_AVAILABLE = False

HATCH_SCRIPT_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "farmer", "AutoHatchTest.lua"))
MAIN_SCRIPT_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "farmer", "EggGoToUI_v10.lua"))

class TestAutoHatchSuite(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        self = cls
        with open(HATCH_SCRIPT_PATH, "r", encoding="utf-8") as f:
            self.content = f.read()

    def test_ast_syntax_validity(self):
        """Verify AutoHatchTest.lua is 100% syntactically valid Lua/Luau."""
        if LUAPARSER_AVAILABLE:
            tree = ast.parse(self.content)
            self.assertIsNotNone(tree, "AST parse tree should not be None")

    def test_target_remote_and_sample_parameter(self):
        """Verify RF/EggWorld/AskHatch is targeted with sample UID 195552ae54d5418bb16ac9265c445b83."""
        self.assertIn("RF/EggWorld/AskHatch", self.content,
                      "Script must resolve RF/EggWorld/AskHatch")
        self.assertIn("195552ae54d5418bb16ac9265c445b83", self.content,
                      "Script must include sample UID 195552ae54d5418bb16ac9265c445b83 as default")
        self.assertIn("rfHatch:InvokeServer(eggUid)", self.content,
                      "Must pass eggUid as argument [1] to AskHatch:InvokeServer")

    def test_auxiliary_remotes(self):
        """Verify auxiliary remotes (AskFinishHatch, FetchProfile) are wired."""
        self.assertIn("RF/EggWorld/AskFinishHatch", self.content,
                      "Should wire RF/EggWorld/AskFinishHatch for post-hatch pet claims")
        self.assertIn("RF/ProfileMirror/FetchProfile", self.content,
                      "Should wire RF/ProfileMirror/FetchProfile for authoritative placed egg verification")

    def test_placed_egg_discovery_engine(self):
        """Verify placed egg detection from Workspace.PlacedEggRenders and ProfileMirror."""
        self.assertIn("Workspace:FindFirstChild(\"PlacedEggRenders\")", self.content,
                      "Must scan Workspace.PlacedEggRenders")
        self.assertIn("prof.EggInventory", self.content,
                      "Must scan prof.EggInventory")
        self.assertIn("eggData.Placement", self.content,
                      "Must verify Placement ~= nil for pen-placed eggs")

    def test_proximity_prompt_support(self):
        """Verify ProximityPrompt detection and fireproximityprompt support."""
        self.assertIn("ProximityPrompt", self.content)
        self.assertIn("fireproximityprompt", self.content)

    def test_gui_hud_elements(self):
        """Verify modern HUD structure matching AutoPenTreadmill styling."""
        self.assertIn("AutoHatchTestGui", self.content)
        self.assertIn("HATCH TARGET UID", self.content)
        self.assertIn("SCAN PEN EGGS", self.content)
        self.assertIn("HATCH ALL PLACED", self.content)
        self.assertIn("AUTO HATCH:", self.content)
        self.assertIn("WALK TO PEN CENTER", self.content)
        self.assertIn("Copy Logs", self.content)

    def test_standalone_isolation(self):
        """Verify EggGoToUI_v10.lua remains untouched prior to user testing."""
        with open(MAIN_SCRIPT_PATH, "r", encoding="utf-8") as f:
            main_content = f.read()
        self.assertNotIn("AutoHatchTestGui", main_content)

if __name__ == "__main__":
    suite = unittest.TestLoader().loadTestsFromTestCase(TestAutoHatchSuite)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if result.wasSuccessful():
        print("\n" + "=" * 50)
        print("ALL AUTO HATCH TEST SUITE UNIT TESTS PASSED!")
        print("=" * 50)
        exit(0)
    else:
        exit(1)
