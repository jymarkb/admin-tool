#!/usr/bin/env python3
"""
Unit & Architectural Verification Suite for Halloween Panel in farmer/EggGoToUI_v12.lua
Verifies:
  1. Config Defaults (Config.Halloween.Species lookup table)
  2. UI Elements & Layout (TabBtnHalloween, TabHalloween, HwActivityStatusLabel, HwEggListScroll, HwEmptyNotice)
  3. Halloween Card Pooling (UI.HwCardPool, UI.getOrCreateHwCard, TP/Walk buttons)
  4. Live Rendering (UI.renderHalloweenEggs with dimension discovery, tagging, distance, sorting)
  5. Single-Domain Isolation (Zero fishing, zero autosell, zero foreign remote dependencies)
  6. Lifecycle & Root Locals Budget (<= 30)
"""

import re
import unittest

class TestV12HalloweenEngine(unittest.TestCase):

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
        """Verify Halloween Dimension exists in BiomeCatalog and excess Config.Halloween.Species is removed."""
        self.assertIn('Biome = "Halloween Dimension"', self.code)
        self.assertNotIn("Config.Halloween = {", self.code, "Separate Config.Halloween table is excess")
        self.assertIn("Whiskers", self.code)
        self.assertIn("Jesterpop", self.code)
        self.assertIn("Candlefang", self.code)

    def test_04_ui_elements_and_layout(self):
        """Verify UI elements in Halloween panel."""
        self.assertIn('Name = "TabBtnHalloween"', self.code)
        self.assertIn('Name = "TabHalloween"', self.code)
        self.assertNotIn('Name = "HwActivityStatusLabel"', self.code, "Excess status bar row must be removed")
        self.assertIn('Name = "HwEggListScroll"', self.code)
        self.assertIn('Name = "HwEmptyNotice"', self.code)

    def test_05_card_pooling(self):
        """Verify Halloween card pooling."""
        self.assertIn("UI.HwCardPool", self.code)
        self.assertIn("UI.getOrCreateHwCard", self.code)
        self.assertIn('Name = "HwEggCard_"', self.code)

    def test_06_rendering_pipeline(self):
        """Verify UI.renderHalloweenEggs without excess studs, excess hardcoded pattern checks, or active panel gating."""
        self.assertIn("UI.renderHalloweenEggs", self.code)
        self.assertIn("HalloweenDimension", self.code)
        self.assertIn("HalloweenWorldEgg", self.code)
        self.assertIn("PreparedSourceName", self.code)
        self.assertNotIn("(%d studs)", self.code, "Excess studs label must be removed")
        self.assertNotIn("if not (UI.Elements.TabHalloween and UI.Elements.TabHalloween.Visible)", self.code)
        self.assertNotIn('lower:find("gerbil")', self.code, "Excess hardcoded fallback pattern logic must be removed")
        self.assertIn('"Hooded Gerbil Egg"', self.code)
        self.assertIn('"Halloween Royal Mimic Egg"', self.code)

    def test_07_no_residual_hw_activity_status_label(self):
        """Verify HwActivityStatusLabel is completely removed with zero dangling references."""
        self.assertNotIn("HwActivityStatusLabel", self.code)

    def test_08_gerbil_and_mimic_taxonomy_resolution(self):
        """Verify Hooded Gerbil and Royal Mimic are cataloged in BiomeCatalog with aliases."""
        self.assertIn('{ Name = "Hooded Gerbil Egg", Rarity = "Legendary"', self.code)
        self.assertIn('{ Name = "Halloween Royal Mimic Egg", Rarity = "Legendary"', self.code)
        self.assertIn('"HalloweenEgg"', self.code)
        self.assertIn('"Mimic Chest"', self.code)

    def test_09_simultaneous_refresh_not_gated_by_active_panel(self):
        """Verify both egg and halloween egg refresh at the same time and not by active panel."""
        self.assertNotIn('if UI.ActiveTab == "Halloween" and UI.renderHalloweenEggs', self.code)
        self.assertIn('if UI.renderFarmableEggs then\n                    pcall(UI.renderFarmableEggs)\n                end\n                if UI.renderHalloweenEggs then\n                    pcall(UI.renderHalloweenEggs)\n                end', self.code)

    def test_10_halloween_rarity_filter(self):
        """Verify rarity filter on Halloween panel."""
        self.assertIn('Name = "HwFilterBar"', self.code)
        self.assertIn('Name = "HwRarityDropdownBtn"', self.code)
        self.assertIn('hwScroll.Position = UDim2.new(0, 8, 0, 38)', self.code)
        self.assertIn('SelectedHwRarities', self.code)
        self.assertIn('local hwRar = Engine.State.SelectedHwRarities', self.code)

    def test_11_world_1_default_selected_rarities(self):
        """Verify World 1 rarity filter defaults to Divine, Eternal, and Secret."""
        def_m = re.search(r'DefaultSelectedRarities\s*=\s*\{([^}]+)\}', self.code)
        self.assertIsNotNone(def_m, "DefaultSelectedRarities not found")
        content = def_m.group(1)
        self.assertIn('["Divine"] = true', content)
        self.assertIn('["Eternal"] = true', content)
        self.assertIn('["Secret"] = true', content)
        self.assertNotIn('["All"] = true', content)

    def test_12_halloween_fast_pickup_config_and_state(self):
        """Verify Config.HwPickup and Engine.State.HwPickupToken existence and separation."""
        self.assertIn("Config.HwPickup = {", self.code)
        self.assertIn("Enabled           = false,", self.code)
        self.assertIn("FastPickupMaxDist = 45.0,", self.code)
        self.assertIn("HwPickupToken         = 0,", self.code)

    def test_13_halloween_fast_pickup_ui_elements(self):
        """Verify Halloween Fast Pickup UI element on TabHalloween filter bar and absence on TabUtility."""
        self.assertIn('Name = "HwFilterPickupBtn"', self.code)
        self.assertIn('UI.Elements.HwFilterPickupBtn = hwFilterPickupBtn', self.code)
        self.assertNotIn('Name = "RowHwPickup"', self.code)
        self.assertNotIn('Name = "ToggleHwPickupBtn"', self.code)
        self.assertIn("UI.syncPickupToggles", self.code)

    def test_14_halloween_fast_pickup_mutual_exclusion(self):
        """Verify mutual exclusion: toggling one turns off the other."""
        self.assertIn("Engine.Pickup.toggle", self.code)
        self.assertIn("Engine.HwPickup.toggle", self.code)
        # In Engine.HwPickup.toggle:
        self.assertIn("if Config.Pickup then Config.Pickup.Enabled = false end", self.code)
        # In Engine.Pickup.toggle:
        self.assertIn("if Config.HwPickup then Config.HwPickup.Enabled = false end", self.code)

    def test_15_halloween_fast_pickup_remote_and_prompts(self):
        """Verify separate Engine.HwPickup engine fires AskCarryEgg and proximity prompts."""
        self.assertIn("Engine.HwPickup.carryEgg", self.code)
        self.assertIn("Engine.HwPickup.startAutoPickupSpam", self.code)
        self.assertIn('"RF/HalloweenDimension/AskCarryEgg"', self.code)
        self.assertIn('bestEgg:GetAttribute("HalloweenEggCanPickUp") == false', self.code)

    def test_16_keybind_e_routing(self):
        """Verify KeyCode.E routes to World 1 or Halloween depending on which toggle is enabled."""
        self.assertIn("if Config.Pickup.Enabled then\n            Engine.Pickup.startAutoPickupSpam()\n        elseif Config.HwPickup and Config.HwPickup.Enabled then\n            Engine.HwPickup.startAutoPickupSpam()\n        end", self.code)

    def test_17_halloween_turn_off_restores_world_1(self):
        """Verify turning OFF Halloween fast pickup turns back ON World 1 main fast pickup."""
        self.assertIn("if Config.Pickup then Config.Pickup.Enabled = true end", self.code)

    def test_18_gorillastein_taxonomy_and_resolution(self):
        """Verify Gorillastein / Gorillastine Egg exists as Eternal in Halloween Dimension."""
        self.assertIn('Name = "Gorillastein Egg", Rarity = "Eternal"', self.code)
        self.assertIn('"Gorillastine"', self.code)
        self.assertIn('"Gorillastines"', self.code)
        self.assertIn('hitbox:GetAttribute("PreparedSourceName")', self.code)

    def test_19_werewolf_and_halloween_resolution(self):
        """Verify Werewolf Egg and Halloween species resolve via clean O(1) taxonomy & alias lookup with zero redundant loops."""
        self.assertIn("Helpers.resolveHalloweenEggName", self.code)
        self.assertIn("wEggs.ChildAdded:Connect", self.code)
        self.assertIn("wEggs.ChildRemoved:Connect", self.code)
        self.assertIn("Engine.State.HwHookedFolder", self.code)
        self.assertIn("Engine.State.HwFolderConns", self.code)

        # Connection hygiene: HwFolderConns must be cleaned up in Engine.Cleanup
        cleanup_snippet = re.search(r"Engine\.Cleanup\s*=\s*function\(\)(.*?)\nend", self.code, re.DOTALL)
        self.assertIsNotNone(cleanup_snippet)
        self.assertIn("table.clear(Engine.State.HwFolderConns)", cleanup_snippet.group(1))

        # Redundant template signatures and speculative mesh part matching must NOT exist
        self.assertNotIn("Helpers.getTemplateSignatures", self.code)
        self.assertNotIn("Helpers.matchTemplateEgg", self.code)
        self.assertNotIn("Helpers.GenericPartNames", self.code)

        # Verify Werewolf Egg is in taxonomy as Secret
        self.assertIn('{ Name = "Werewolf Egg", Rarity = "Secret", Aliases = { "Werewolf" } }', self.code)

    def test_20_hooded_gerbil_not_hijacked_by_graveyard_brute(self):
        """Verify Hooded Gerbil Egg resolves via taxonomy alias in O(1) without speculative template false-positives."""
        resolve_snippet = re.search(r"Helpers\.resolveHalloweenEggName\s*=\s*function\(model\)(.*?)\nend", self.code, re.DOTALL)
        self.assertIsNotNone(resolve_snippet)
        body = resolve_snippet.group(1)

        # Direct attribute checks and taxonomy lookup
        self.assertIn('model:GetAttribute("PreparedSourceName")', body)
        self.assertIn('hitbox:GetAttribute("PreparedSourceName")', body)
        self.assertIn('Helpers.getSpeciesInfo(tostring(raw), "Halloween Dimension")', body)
        self.assertIn('return "Hooded Gerbil Egg"', body)

        # Speculative template matching must be completely removed
        self.assertNotIn("matchTemplateEgg", body)
        self.assertNotIn("matchTemplateEgg", self.code)

        # Verify Hooded Gerbil Egg is Legendary with HalloweenEgg aliases in taxonomy
        self.assertIn('{ Name = "Hooded Gerbil Egg", Rarity = "Legendary"', self.code)
        self.assertIn('"HalloweenEgg"', self.code)

    def test_21_night_reset_and_rare_egg_spawns(self):
        """Verify staged night reset resyncs and authoritative serverRarity evaluation in UI.renderHalloweenEggs."""
        # 1. Staged resync delays on night transition
        self.assertIn("task.delay(0.5, doResync)", self.code)
        self.assertIn("task.delay(1.5, doResync)", self.code)
        self.assertIn("task.delay(3.0, doResync)", self.code)

        # 2. Authoritative serverRarity takes precedence in UI.renderHalloweenEggs
        self.assertIn('local serverRarity = model:GetAttribute("Rarity") or (hitbox and hitbox:GetAttribute("Rarity"))', self.code)
        self.assertIn('local rarity = (serverRarity and serverRarity ~= "" and serverRarity ~= "Unknown") and serverRarity or ((sInfo and sInfo.Rarity) or "Legendary")', self.code)

        # 3. Streamlined resolution: SmartPromptPart is not used for egg species naming
        resolve_snippet = re.search(r"Helpers\.resolveHalloweenEggName\s*=\s*function\(model\)(.*?)\nend", self.code, re.DOTALL)
        self.assertIsNotNone(resolve_snippet)
        self.assertNotIn('Workspace:FindFirstChild("SmartPromptPart")', resolve_snippet.group(1))

    def test_22_werewolf_egg_visible_under_divine_eternal_secret_filter(self):
        """Verify Werewolf Egg resolves to Secret rarity and is visible under Divine, Eternal, Secret filter."""
        # 1. Taxonomy entry is Secret
        self.assertIn('{ Name = "Werewolf Egg", Rarity = "Secret", Aliases = { "Werewolf" } }', self.code)

        # 2. resolveHalloweenEggName inspects ProximityPrompt and children before falling back to Hooded Gerbil
        resolve_snippet = re.search(r"Helpers\.resolveHalloweenEggName\s*=\s*function\(model\)(.*?)\nend", self.code, re.DOTALL)
        self.assertIsNotNone(resolve_snippet)
        body = resolve_snippet.group(1)
        self.assertIn("ProximityPrompt", body)
        self.assertIn("ObjectText", body)
        self.assertIn("ActionText", body)
        self.assertIn("HwNameCache", body)

        # 3. Default filter enables Secret, Eternal, Divine
        def_m = re.search(r'SelectedHwRarities\s*=\s*\{([^}]+)\}', self.code)
        self.assertIsNotNone(def_m)
        content = def_m.group(1)
        self.assertIn('["Secret"] = true', content)
        self.assertIn('["Eternal"] = true', content)
        self.assertIn('["Divine"] = true', content)

    def test_23_halloween_tp_logic_sequence(self):
        """Verify Halloween TP logic executes:
           - tp towards egg
           - pick up
           - tp towards dropzone
           - drop the egg
           - repick up
           - walk towards halloween safezone
        """
        self.assertIn("Engine.HwPickup.executeTpSequence", self.code)
        tp_snippet = re.search(r"Engine\.HwPickup\.executeTpSequence\s*=\s*function\(itemData, onComplete\)(.*?)\nend\n", self.code, re.DOTALL)
        self.assertIsNotNone(tp_snippet, "executeTpSequence must be defined")
        body = tp_snippet.group(1)

        # Step 1: TP towards egg
        self.assertIn("Engine.Travel.teleportTo(targetPos, true)", body)

        # Step 2: Pick up
        self.assertIn("Helpers.isHoldingEgg()", body)
        self.assertIn("RF/HalloweenDimension/AskCarryEgg", body)

        # Step 3: TP towards dropzone
        self.assertIn("Engine.Travel.teleportTo(dropPos, false)", body)
        self.assertIn("Engine.HwPickup.DropZone", self.code)

        # Step 4: Drop the egg
        self.assertIn("RF/HalloweenDimension/AskDropEgg", body)

        # Step 5: Re-pick up
        self.assertIn("reSecured", body)

        # Step 6: Walk towards halloween safezone
        self.assertIn("Engine.Travel.walkToTarget(safeZone, 4.0", body)
        self.assertIn("Engine.HwPickup.SafeZone", self.code)

    def test_24_halloween_get_logic_sequence(self):
        """Verify Halloween Get logic executes:
           - tp towards egg
           - pick up the egg
           - walk towards dropzone
           - walk towards safezone
        """
        self.assertIn("Engine.HwPickup.executeGetSequence", self.code)
        get_snippet = re.search(r"Engine\.HwPickup\.executeGetSequence\s*=\s*function\(itemData, onComplete\)(.*?)\nend\n", self.code, re.DOTALL)
        self.assertIsNotNone(get_snippet, "executeGetSequence must be defined")
        body = get_snippet.group(1)

        # Step 1: TP towards egg
        self.assertIn("Engine.Travel.teleportTo(targetPos, true)", body)

        # Step 2: Pick up the egg
        self.assertIn("Helpers.isHoldingEgg()", body)
        self.assertIn("RF/HalloweenDimension/AskCarryEgg", body)

        # Step 3: Walk towards dropzone
        self.assertIn("Engine.Travel.walkToTarget(dropPos, 4.0", body)

        # Step 4: Walk towards safezone
        self.assertIn("Engine.Travel.walkToTarget(safeZone, 4.0", body)

    def test_25_halloween_card_buttons_wiring(self):
        """Verify Halloween card buttons route TP to executeTpSequence and WALK to executeGetSequence."""
        self.assertIn("Engine.HwPickup.executeTpSequence(item.data)", self.code)
        self.assertIn("Engine.HwPickup.executeGetSequence(item.data)", self.code)

    def test_26_zone_1_eggs_use_walk_delivery(self):
        """Verify Zone 1 eggs route TP to pickup + walk towards dropzone and safezone (no drop remote)."""
        tp_snippet = re.search(r"Engine\.HwPickup\.executeTpSequence\s*=\s*function\(itemData, onComplete\)(.*?)\nend\n", self.code, re.DOTALL)
        self.assertIsNotNone(tp_snippet)
        body = tp_snippet.group(1)

        self.assertIn("local isZone1 =", body)
        self.assertIn("itemData.Zone == 1", body)
        self.assertIn("Zone 1 Egg - Walking to Dropzone", body)
        self.assertIn("Engine.Travel.walkToTarget(dropPos, 4.0", body)
        self.assertIn("Engine.Travel.walkToTarget(safeZone, 4.0", body)

    def test_27_teleport_beside_big_egg_ground_raycast(self):
        """Verify Engine.Travel.teleportTo prevents excess freefall on big eggs via geometry check and ground raycast."""
        tp_snippet = re.search(r"Engine\.Travel\.teleportTo\s*=\s*function\(targetPos, snapBeside(.*?)\nend\n", self.code, re.DOTALL)
        self.assertIsNotNone(tp_snippet)
        body = tp_snippet.group(1)

        self.assertIn("eggRadius", body)
        self.assertIn("eggBottomY", body)
        self.assertIn("RaycastParams.new()", body)
        self.assertIn("Workspace:Raycast", body)
        self.assertIn("rayRes.Position.Y + 2.8", body)


if __name__ == "__main__":
    unittest.main()
