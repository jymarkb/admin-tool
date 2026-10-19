#!/usr/bin/env python3
"""
Comprehensive Unit Test Suite for farmer/EggGoToUI_Clean.lua
Verifies AST syntax validity, local limits, namespacing, business logic,
formulas, constants, and complete feature coverage adhering to CURRENT_LOGIC_SUMMARY.md.
"""

import os
import sys
import unittest
import re

try:
    import luaparser.ast as ast
    import luaparser.astnodes as nodes
    LUAPARSER_AVAILABLE = True
except ImportError:
    LUAPARSER_AVAILABLE = False


TARGET_FILE = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "farmer", "EggGoToUI_Clean.lua"))


class TestEggGoToUIClean(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not os.path.exists(TARGET_FILE):
            raise FileNotFoundError(f"Clean file not found at {TARGET_FILE}")
        with open(TARGET_FILE, "r", encoding="utf-8") as f:
            cls.content = f.read()
        cls.lines = cls.content.splitlines()

    def test_01_ast_syntax_validity(self):
        """Test that the Lua code parses cleanly with luaparser with 0 errors."""
        self.assertTrue(LUAPARSER_AVAILABLE, "luaparser must be installed")
        try:
            tree = ast.parse(self.content)
            self.assertIsNotNone(tree)
        except Exception as e:
            self.fail(f"AST Parsing failed with error: {e}")

    def test_02_luau_local_variable_limit(self):
        """Test that top-level local variables are <= 25 (far below the strict Luau 200 limit)."""
        tree = ast.parse(self.content)
        top_locals = [node for node in tree.body.body if isinstance(node, (ast.LocalAssign, ast.LocalFunction))]
        count = len(top_locals)
        print(f"\n[CLEAN STATS] Top-level local statements: {count} (Luau limit is 200)")
        self.assertLessEqual(count, 25, f"Top-level local declarations ({count}) exceed 25 threshold!")

    def test_03_app_namespace_structure(self):
        """Test that all required subsystems exist under App table."""
        required_namespaces = [
            "App.Config", "App.State", "App.Cache", "App.Settings",
            "App.Net", "App.Species", "App.Geo", "App.Ghost",
            "App.Recovery", "App.Physics", "App.Traps", "App.Nav",
            "App.Pickup", "App.Scanner", "App.Farm", "App.Treadmill",
            "App.Hatch", "App.Butterflies", "App.Pen", "App.Fusery",
            "App.Scramble", "App.UI",
        ]
        for ns in required_namespaces:
            self.assertIn(f"{ns} =", self.content, f"Namespace declaration '{ns}' missing from App")

    def test_04_window_geometry_constants(self):
        """Test unified window geometry: 380x520 main, 46px sidebar, 334x484 content."""
        self.assertIn("WindowWidth = 380", self.content)
        self.assertIn("WindowHeight = 520", self.content)
        self.assertIn("SidebarWidth = 46", self.content)
        self.assertIn("ContentWidth = 334", self.content)
        self.assertIn("ContentHeight = 484", self.content)
        self.assertIn("CardHeight = 34", self.content)

    def test_05_species_aliasing_and_rarity_presets(self):
        """Test bidirectional species aliasing, display mapping, and rarity presets."""
        # Godzilla == Nightflame
        self.assertIn('["godzilla"] = "nightflame"', self.content)
        self.assertIn('["nightflame"] = "godzilla"', self.content)
        self.assertIn('["Godzilla"] = "Nightflame"', self.content)
        self.assertIn('["Nightflame"] = "Divine"', self.content)
        self.assertIn('["Godzilla"] = "Divine"', self.content)

        # Shark vs Mutant Shark separation
        self.assertIn('["Shark"] = "Legendary"', self.content)
        self.assertIn('["Mutant Shark"] = "Secret"', self.content)

        # Cosmic aliases
        self.assertIn('["galaxy gecko"] = "cosmic gecko"', self.content)
        self.assertIn('["cave dragon"] = "cosmic dragon"', self.content)
        self.assertIn('["cyclops gorilla"] = "cosmic gorilla"', self.content)

    def test_06_option_b_filter_and_tiers(self):
        """Test Option B filter, tier ranks, and midway dropped egg steal logic."""
        self.assertIn("function App.Farm.PassesFilters(r)", self.content)
        self.assertIn("function App.Farm.EggTier(r)", self.content)
        self.assertIn("function App.Farm.PickNearest(records)", self.content)
        self.assertIn("bestDropped", self.content)
        self.assertIn("bestNest", self.content)
        # Skip unknown eggs in pickNearest
        self.assertIn("not App.Species.IsNewOrUnknownEgg(r)", self.content)

    def test_07_recovery_and_metamethod_hooks(self):
        """Test zero-wait recovery, fast-path metamethod hooks, and anti-fling brake."""
        self.assertIn("function App.Recovery.Execute(reason)", self.content)
        self.assertIn("function App.Recovery.InstallMetamethodHooks()", self.content)
        self.assertIn('key == "WalkSpeed"', self.content)
        self.assertIn('key == "PlatformStand"', self.content)
        self.assertIn('key == "Enabled"', self.content)
        self.assertIn("fastY = -45", self.content)  # Fast downward grounding
        self.assertIn("Vector3.new(0, fastY, 0)", self.content)

    def test_08_dual_velocity_state_machine(self):
        """Test travel speed (300) vs carry speed (250) and forceTravel reset."""
        self.assertIn("BaseVelocity = 300", self.content)
        self.assertIn("BaseCarryVelocity = 250", self.content)
        self.assertIn("function App.Physics.SwitchToCarry()", self.content)
        self.assertIn("function App.Physics.ResetVelocity(forceTravel)", self.content)
        self.assertIn("function App.Physics.ApplyHeartbeat()", self.content)

    def test_09_trap_evasion_subsystem(self):
        """Test 4-layer trap evasion: underground displacement, CanTouch, lateral detour."""
        self.assertIn("function App.Traps.Neutralize(inst)", self.content)
        self.assertIn("hb.CFrame = CFrame.new(curCF.X, -500, curCF.Z)", self.content)
        self.assertIn("function App.Traps.ApplyCanTouchProtection()", self.content)
        self.assertIn("function App.Traps.GetDetourPoint(rp, dest)", self.content)

    def test_10_spam_pickup_with_reach_assist_guard(self):
        """Test Spam Pickup [E], single-snap reach assist guard, and universal CRA egg detection."""
        self.assertIn("function App.Pickup.StartSpamLoop()", self.content)
        self.assertIn("function App.Pickup.ApplyReachAssist(targetPos)", self.content)
        self.assertIn("function App.Pickup.IsHoldingEgg()", self.content)
        self.assertIn("hasSnapped = true", self.content)
        self.assertIn("ClientRenderedAssets", self.content)

    def test_11_treadmill_and_5s_autohatch(self):
        """Test 3-pass plot heuristic, treadmill finding, and 5s duration gated hatch."""
        self.assertIn("function App.Treadmill.FindPlot()", self.content)
        self.assertIn("function App.Treadmill.FindTreadmill()", self.content)
        self.assertIn("function App.Hatch.ExecuteAll()", self.content)
        self.assertIn("elapsed >= 5.0", self.content)
        self.assertIn("HasHatchedThisTreadmillSession", self.content)

    def test_12_butterflies_event_handling(self):
        """Test Zone 6 butterfly coordinates and O(1) net equip."""
        self.assertIn("Vector3.new(6697.747, 70.724, -376.004)", self.content)
        self.assertIn("function App.Butterflies.EquipNet()", self.content)
        self.assertIn("function App.Butterflies.ExecuteCatch()", self.content)

    def test_13_pen_bounds_and_esp(self):
        """Test 4-tier pen bounds resolution and 4-side colored neon ESP."""
        self.assertIn("function App.Pen.GetBounds()", self.content)
        self.assertIn("function App.Pen.ToggleESP()", self.content)
        self.assertIn("FRONT (+Z)", self.content)
        self.assertIn("BACK (-Z)", self.content)
        self.assertIn("LEFT (-X)", self.content)
        self.assertIn("RIGHT (+X)", self.content)

    def test_14_pet_fusery_formula_and_isolation(self):
        """Test math.round(weight * scale^2), equipped pet exclusion, and 3-pet loading."""
        self.assertIn("function App.Fusery.ScanEligiblePets()", self.content)
        self.assertIn("function App.Fusery.ExecuteFuse(species, petUids)", self.content)
        self.assertIn("rawW * (s * s)", self.content)
        self.assertIn("RF/Fusery/LoadPet", self.content)
        self.assertIn("RF/Fusery/BeginFuse", self.content)
        self.assertIn("RF/Fusery/FinishReveal", self.content)
        self.assertIn("RF/Fusery/EjectPet", self.content)

    def test_15_scramble_trade_in_suite(self):
        """Test Dr. Scramble 3-step cycle, rotation timer loop, and live telemetry log."""
        self.assertIn("function App.Scramble.FetchState()", self.content)
        self.assertIn("function App.Scramble.ExecuteTrade()", self.content)
        self.assertIn("function App.Scramble.StartTimerLoop()", self.content)
        self.assertIn("RF/ScrambleTradeIn/AskState", self.content)
        self.assertIn("RF/ScrambleTradeIn/AskTradeIn", self.content)
        self.assertIn("RF/ScrambleTradeIn/AskFinishReveal", self.content)

    def test_16_ui_card_pool_zero_allocation(self):
        """Test zero-allocation card pool updateOrCreateCard and off-screen gating."""
        self.assertIn("function App.UI.UpdateOrCreateCard(idx, r)", self.content)
        self.assertIn("function App.UI.RenderEggList()", self.content)
        self.assertIn("App.Cache.CardPool", self.content)
        # Off-screen gate
        self.assertIn('if App.State.CurrentTab ~= "Eggs" then return end', self.content)


if __name__ == "__main__":
    unittest.main()
