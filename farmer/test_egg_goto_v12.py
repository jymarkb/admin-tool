#!/usr/bin/env python3
"""
Unit & Architectural Verification Suite for farmer/EggGoToUI_v12.lua
Verifies:
  1. Section 1: Config Defaults (Taxonomy, 13 biomes, up to Divine, dual-speed 360/310, recovery, pickup)
  2. Section 2: UI Codes (Per Panel & Row: ScreenGui, Topbar, TabEggs rows 1-6, TabUtility rows 1-4)
  3. Section 3: Helper Code (Remotes, SafeUiParent, Draggable, Taxonomy normalizers, Prompts, JSON export)
  4. Section 4: Engine & Loop Logic (Velocity physics, Instant Recovery, Fast Pickup, Travel, Push Monitor, Loops, Cleanup)
  5. Anti-Bloat & Modular Architecture Guardrails:
     - Root locals <= 190 (Strict limit: < 30)
     - Single-Domain Isolation (Zero Halloween bloat, zero fishing bloat, zero autosell bloat)
     - Syntax and Bracket balance verification
"""

import re
import unittest

class TestEggGoToV12Architecture(unittest.TestCase):

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

    def test_02_luau_root_locals_budget(self):
        """Ensure root locals strictly remain <= 190 (Roblox hard limit 200). Target: <= 30."""
        root_locals = [
            l.strip() for l in self.code.splitlines()
            if re.match(r"^local\s+([a-zA-Z0-9_, ]+)", l)
        ]
        self.assertLessEqual(len(root_locals), 30, f"Expected <= 30 root locals, got {len(root_locals)}")
        self.assertLessEqual(len(root_locals), 190, "Root locals strictly exceeded 190 budget limit!")

    def test_03_section_1_config_defaults(self):
        """Verify Section 1 contains all required configuration defaults."""
        self.assertIn("SECTION 1: CONFIG DEFAULT", self.code)
        self.assertIn("Config.Taxonomy", self.code)
        self.assertIn("Config.Velocity", self.code)
        self.assertIn("Config.Recovery", self.code)
        self.assertIn("Config.Pickup", self.code)
        self.assertIn("Config.UI", self.code)

        # 13 Farmable Biomes
        expected_biomes = [
            "Forest", "Lake", "Desert", "Jungle", "Snow", "Volcano", "Abyss Ocean",
            "Prehistoric", "Cosmic", "Cherry Blossom", "Titan Temple", "Light & Dark", "Enchanted Forest"
        ]
        for b in expected_biomes:
            self.assertIn(f'"{b}"', self.code, f"Biome '{b}' must exist in catalog")

        # Rarities up to Divine only
        self.assertIn('"Divine"', self.code)
        self.assertIn('"Eternal"', self.code)
        self.assertIn('"Secret"', self.code)

        # Dual-Speed Defaults
        self.assertIn("DefaultGoSpeed    = 360", self.code)
        self.assertTrue(
            "DefaultCarrySpeed = 300" in self.code or "DefaultCarrySpeed = 310" in self.code,
            "DefaultCarrySpeed must be configured"
        )

        # Instant Recovery Defaults
        self.assertIn("AntiFling       = true", self.code)
        self.assertIn("BrakeVelocity   = true", self.code)
        self.assertIn("GroundDistance  = 2.5", self.code)

    def test_04_section_2_ui_codes_per_panel_and_row(self):
        """Verify Section 2 is cleanly structured per panel and row."""
        self.assertIn("SECTION 2: UI CODES (Per Panel & Row)", self.code)
        self.assertIn("UI.build", self.code)
        self.assertIn("UI.Elements", self.code)
        self.assertIn("UI.createFilterDropdown", self.code)

        # Root Containers
        self.assertIn('Name = "EggGoToUI_v12"', self.code)
        self.assertIn('Name = "MenuToggleBtn"', self.code)
        self.assertIn('Name = "MainFrame"', self.code)
        self.assertIn('Name = "TitleBar"', self.code)
        self.assertIn('Name = "CloseBtn"', self.code)

        # Navigation Sidebar & Content Container
        self.assertIn('Name = "Sidebar"', self.code)
        self.assertIn('Name = "TabBtnEggs"', self.code)
        self.assertIn('Name = "TabBtnUtility"', self.code)
        self.assertIn('Name = "TabBtnHalloween"', self.code)
        self.assertIn('Name = "ContentContainer"', self.code)
        self.assertIn('Name = "TabHalloween"', self.code)
        self.assertIn('Name = "HwEggListScroll"', self.code)
        self.assertIn('Name = "HwEmptyNotice"', self.code)
        self.assertNotIn('Name = "HwActivityStatusLabel"', self.code)

        # Dropdown ZIndex layering (must render above EggListScroll)
        self.assertIn('filterBar.ZIndex = 40', self.code)
        self.assertIn('filterBar.ClipsDescendants = false', self.code)
        self.assertIn('scroll.ZIndex = 1', self.code)

        # Panel 1: TabEggs Rows (Search, CountLabel, and DropdownOverlay removed per user request)
        self.assertIn('Name = "TabEggs"', self.code)
        self.assertIn('Name = "ActivityStatusLabel"', self.code)
        self.assertIn('Name = "VelToggleBtn"', self.code)
        self.assertIn('Name = "GoSpeedBox"', self.code)
        self.assertIn('Name = "CarrySpeedBox"', self.code)
        self.assertIn('Name = "BiomeDropdownBtn"', self.code)
        self.assertIn('Name = "RarityDropdownBtn"', self.code)
        self.assertIn('Name = "EggListScroll"', self.code)
        self.assertIn('Name = "EmptyNotice"', self.code)
        self.assertNotIn('Name = "SearchBox"', self.code)
        self.assertNotIn('Name = "ClearSearchBtn"', self.code)
        self.assertNotIn('Name = "CountLabel"', self.code)
        self.assertNotIn('Name = "DropdownOverlay"', self.code)

        # Panel 2: TabUtility Rows
        self.assertIn('Name = "TabUtility"', self.code)
        self.assertIn('Name = "RowPickup"', self.code)
        self.assertIn('Name = "TogglePickupBtn"', self.code)
        self.assertIn('Name = "RowRecovery"', self.code)
        self.assertIn('Name = "TestRecoveryBtn"', self.code)
        self.assertIn('Name = "RowNoclip"', self.code)
        self.assertIn('Name = "ToggleNoclipBtn"', self.code)
        self.assertIn('Name = "RowExportJson"', self.code)
        self.assertIn('Name = "UtilityCopyJsonBtn"', self.code)

    def test_05_section_3_helper_code(self):
        """Verify Section 3 helper utilities."""
        self.assertIn("SECTION 3: HELPER CODE", self.code)
        self.assertIn("Helpers.getNetRemote", self.code)
        self.assertIn("Helpers.getSafeUiParent", self.code)
        self.assertIn("Helpers.makeDraggable", self.code)
        self.assertIn("Helpers.enablePlayerControls", self.code)
        self.assertIn("Helpers.applyReachAssist", self.code)
        self.assertIn("Helpers.normalizeSpecies", self.code)
        self.assertIn("Helpers.isGenericEggName", self.code)
        self.assertIn("Helpers.getSpeciesInfo", self.code)
        self.assertIn("Helpers.isCarryPrompt", self.code)
        self.assertIn("Helpers.triggerProximityPrompt", self.code)
        self.assertIn("Helpers.exportEggListJson", self.code)

    def test_06_section_4_engine_and_loop_logic(self):
        """Verify Section 4 Engine and background loop logic."""
        self.assertIn("SECTION 4: ENGINE (Core & Loop Logic)", self.code)
        self.assertIn("Engine.State", self.code)
        self.assertIn("Engine.Velocity", self.code)
        self.assertIn("Engine.Velocity.setCarryingState", self.code)
        self.assertIn("Engine.Velocity.isHoldingEgg", self.code)
        self.assertIn("Engine.Velocity.getCarryingStatus", self.code)
        self.assertIn("Engine.Velocity.updatePhysics", self.code)

        self.assertIn("Engine.Recovery", self.code)
        self.assertIn("Engine.Recovery.execute", self.code)
        self.assertIn("Engine.Recovery.bindCharacter", self.code)

        self.assertIn("Engine.Pickup", self.code)
        self.assertIn("Engine.Pickup.carryEgg", self.code)
        self.assertIn("Engine.Pickup.startAutoPickupSpam", self.code)

        self.assertIn("Engine.Travel", self.code)
        self.assertIn("Engine.Travel.teleportToEgg", self.code)
        self.assertIn("Engine.Travel.walkToEgg", self.code)
        self.assertIn("Engine.Travel.stopWalking", self.code)

        self.assertIn("Engine.Sync", self.code)
        self.assertIn("Engine.Sync.startPushMonitor", self.code)
        self.assertIn("Engine.Sync.syncEggSnapshot", self.code)
        self.assertIn("Engine.Sync.syncAreaEggSlotsESP", self.code)

        self.assertIn("Engine.Loops", self.code)
        self.assertIn("Engine.Loops.start", self.code)
        self.assertIn("Engine.Cleanup", self.code)

        # Remotes in Push Monitor
        self.assertIn("RE/EggWorld/FieldEggShifted", self.code)
        self.assertIn("RE/EggWorld/FieldEggBatchShifted", self.code)
        self.assertIn("RE/EggWorld/FieldEggRaritiesShown", self.code)
        self.assertIn("RE/EggWorld/FieldEggGone", self.code)

    def test_07_single_domain_isolation(self):
        """Ensure complete absence of event bloat, fishing bloat, and autosell bloat."""
        lower_code = self.code.lower()
        self.assertNotIn("halloweenengine", lower_code, "Halloween event engine bloat must not exist in v12")
        self.assertNotIn("candycorn", lower_code, "Halloween event currency logic must not exist in v12")
        self.assertNotIn("findrod", lower_code, "Fishing rod logic must not exist in v12")
        self.assertNotIn("haunted rod", lower_code, "Event rod must not exist in v12")
        self.assertNotIn("autosell", lower_code, "Autosell logic must not exist in v12")
        self.assertNotIn("sellselection", lower_code, "Autosell remotes must not exist in v12")

    def test_08_trap_evade_system(self):
        """Verify Trap Evade clean neutralization architecture (zero speculative detour math bloat)."""
        # 1. Config Defaults (Clean neutralization)
        self.assertIn("Config.TrapEvade = {", self.code)
        self.assertIn("Enabled          = true", self.code)
        self.assertIn("NeutralizeHitbox = true", self.code)

        # 2. UI Elements & TabUtility Row
        self.assertIn("ToggleTrapEvadeBtn = nil", self.code)
        self.assertIn('Name = "RowTrapEvade"', self.code)
        self.assertIn('Text = "Trap Evade"', self.code)
        self.assertIn('Name = "ToggleTrapEvadeBtn"', self.code)
        self.assertIn("UI.Elements.ToggleTrapEvadeBtn = toggleTrapBtn", self.code)

        # 3. Engine.Traps Module (Targeted lifecycle strictly in Workspace.Transient)
        self.assertIn("Engine.Traps = {", self.code)
        self.assertIn("Engine.Traps.register", self.code)
        self.assertIn("Engine.Traps.unregister", self.code)
        self.assertIn("Engine.Traps.neutralize", self.code)
        self.assertIn("Engine.Traps.restore", self.code)
        self.assertIn("Engine.Traps.init", self.code)
        self.assertNotIn("applyLimbShield", self.code, "applyLimbShield broke game portals and must be eradicated")

        # 4. Hitbox neutralization & Portal Protection (Zero mutation of Character limbs)
        self.assertIn("CFrame.new(curCF.X, -500, curCF.Z)", self.code)
        self.assertNotIn("targetCanTouch = not enabled", self.code, "Character limb CanTouch must never be disabled")

        # 5. Direct Travel Speed Preservation (Zero detour / jump bloat)
        self.assertNotIn("getEvadeDirection", self.code, "Speculative detour math must be eradicated")
        self.assertNotIn("checkManualRadar", self.code, "Redundant manual radar loops must be eradicated")

        # 6. Targeted Lifecycle & Cleanup
        self.assertIn('Workspace:FindFirstChild("Transient")', self.code)
        self.assertIn("Engine.Traps.init", self.code)
        self.assertIn("Engine.Traps.restore(inst)", self.code)

    def test_09_auto_treadmill_and_dismount_system(self):
        """Verify Auto Treadmill scanning & isolated non-toggle Auto Dismount jump architecture."""
        # 1. Config Defaults
        self.assertIn("Config.Treadmill = {", self.code)
        self.assertIn("Enabled = false", self.code)

        # 2. UI Elements & Rows in TabUtility
        self.assertIn("ToggleTreadmillBtn = nil", self.code)
        self.assertIn("TriggerDismountBtn = nil", self.code)
        self.assertIn('Name = "RowAutoTreadmill"', self.code)
        self.assertIn('Text = "Auto Treadmill"', self.code)
        self.assertIn('Name = "ToggleTreadmillBtn"', self.code)
        self.assertIn('Name = "RowAutoDismount"', self.code)
        self.assertIn('Text = "Auto Dismount"', self.code)
        self.assertIn('Name = "TriggerDismountBtn"', self.code)
        self.assertIn('Text = "Jump"', self.code)

        # 3. Row Y coordinates check (proper 42px pitch grid)
        self.assertIn('UDim2.new(0, 8, 0, 178)', self.code)
        self.assertIn('UDim2.new(0, 8, 0, 220)', self.code)
        self.assertIn('UDim2.new(0, 8, 0, 262)', self.code)

        # 4. Engine.Plot & Engine.Treadmill Modules (Decoupled & Targeted)
        self.assertIn("Engine.Plot = {", self.code)
        self.assertIn("Engine.Plot.getPlot", self.code)
        self.assertIn("Engine.Treadmill = {", self.code)
        self.assertNotIn("findMyPlot", self.code, "Overcomplicated legacy plot checking must not exist")
        self.assertIn("Engine.Treadmill.findTreadmill", self.code)
        self.assertIn("Engine.Treadmill.isOnTreadmill", self.code)
        self.assertIn("Engine.Treadmill.goToTreadmill", self.code)
        self.assertIn("Engine.Treadmill.dismount", self.code)

        # 5. Targeted Treadmill Container Discovery with Authoritative Plot Index
        self.assertIn('Workspace:FindFirstChild("__ClientTreadmillRenders")', self.code)
        self.assertIn('"TreadmillRender_" .. tostring(plotIdx)', self.code)

        # 6. Isolated Non-Toggle Dismount (Direct Jump + AskDoff Remote)
        self.assertIn("Enum.HumanoidStateType.Jumping", self.code)
        self.assertIn("hum.Jump = true", self.code)
        self.assertIn('"RF/Treadmill/AskDoff"', self.code)

        # 7. Single-Domain Isolation: Zero coupling to egg autofarm or auto-hatch in treadmill engine
        self.assertNotIn("executeHatchAllPlaced", self.code)
        self.assertNotIn("hasHatchedThisTreadmillSession", self.code)
        self.assertNotIn("nightResetGraceUntil", self.code)

if __name__ == "__main__":
    unittest.main()
