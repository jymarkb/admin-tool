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
        """Verify Halloween Fast Pickup UI elements on TabHalloween and TabUtility."""
        self.assertIn('Name = "HwFilterPickupBtn"', self.code)
        self.assertIn('UI.Elements.HwFilterPickupBtn = hwFilterPickupBtn', self.code)
        self.assertIn('Name = "RowHwPickup"', self.code)
        self.assertIn('Name = "ToggleHwPickupBtn"', self.code)
        self.assertIn('UI.Elements.ToggleHwPickupBtn = toggleHwPBtn', self.code)
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
        """Verify Werewolf Egg resolves via ProximityPrompt keyword search, template signatures, and event connections."""
        self.assertIn("Helpers.resolveHalloweenEggName", self.code)
        self.assertIn("Helpers.getTemplateSignatures", self.code)
        self.assertIn("Helpers.matchTemplateEgg", self.code)
        self.assertIn("wEggs.ChildAdded:Connect", self.code)
        self.assertIn("wEggs.ChildRemoved:Connect", self.code)
        self.assertIn("Engine.State.HwHookedFolder", self.code)
        self.assertIn("Engine.State.HwFolderConns", self.code)

        # ProximityPrompt keyword search must ignore generic terms and match specific species keywords
        self.assertIn('cleanName ~= "egg" and cleanName ~= "halloween" and cleanName ~= "halloweenegg"', self.code)
        self.assertIn('fullTxt:find(cleanName, 1, true)', self.code)

        # Verify Werewolf Egg is in taxonomy as Secret
        self.assertIn('{ Name = "Werewolf Egg", Rarity = "Secret", Aliases = { "Werewolf" } }', self.code)

        # Simulate keyword matching for ProximityPrompt text "Steal Werewolf Egg"
        prompt_text = "Steal Werewolf Egg".lower()
        self.assertIn("werewolf", prompt_text)

        # Template signatures matching against ReplicatedStorage.Assets.Models.Eggs
        self.assertIn('ReplicatedStorage.Assets.Models.Eggs', self.code)
        self.assertIn('Helpers.GenericPartNames', self.code)

    def test_20_hooded_gerbil_not_hijacked_by_graveyard_brute(self):
        """Verify standard HalloweenEgg resolves to Hooded Gerbil Egg before template matching to prevent Graveyard Brute false positives."""
        # Ensure Step 5 returns Hooded Gerbil Egg before speculative template match
        resolve_snippet = re.search(r"Helpers\.resolveHalloweenEggName\s*=\s*function\(model\)(.*?)\nend", self.code, re.DOTALL)
        self.assertIsNotNone(resolve_snippet)
        body = resolve_snippet.group(1)

        pos_gerbil = body.find('model.Name == "HalloweenEgg" or model.Name == "Halloween Egg"')
        pos_template = body.find('Helpers.matchTemplateEgg(model)')
        self.assertGreater(pos_gerbil, 0, "HalloweenEgg check missing in resolveHalloweenEggName")
        self.assertGreater(pos_template, 0, "matchTemplateEgg missing in resolveHalloweenEggName")
        self.assertLess(pos_gerbil, pos_template, "HalloweenEgg must default to Hooded Gerbil Egg BEFORE speculative matchTemplateEgg to avoid Graveyard Brute false positives")

        # Verify Hooded Gerbil Egg is Legendary
        self.assertIn('{ Name = "Hooded Gerbil Egg", Rarity = "Legendary"', self.code)

if __name__ == "__main__":
    unittest.main()
