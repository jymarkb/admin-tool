"""
Test Suite: Guard Negation & Invisibility Architecture & Verification
=====================================================================
Validates farmer/GuardNegation.lua for:
  1. Root locals budget <= 30 (Roblox hard limit 200).
  2. Single-Domain Isolation: Guard remote strike/handoff negation and invisibility only.
  3. Hookmetamethod & Namecall interception of ForestStrike and ForestHandoff.
  4. Hitbox & Spatial Invisibility (CanTouch and CanQuery negation).
  5. Visual Character Invisibility (Transparency and shadow negation).
  6. Connection & Memory Cleanup hygiene.
"""

import os
import unittest


class TestGuardNegationArchitecture(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        script_path = os.path.join(os.path.dirname(__file__), "GuardNegation.lua")
        with open(script_path, "r", encoding="utf-8") as f:
            cls.code = f.read()

    def test_01_root_locals_budget(self):
        """Verify root locals are strictly <= 30 (current count 17)."""
        root_locals = []
        for idx, line in enumerate(self.code.splitlines()):
            stripped = line.strip()
            if stripped.startswith("local ") and not line.startswith(" ") and not line.startswith("\t"):
                root_locals.append((idx + 1, stripped))
        self.assertLessEqual(len(root_locals), 30, f"Expected <= 30 root locals, got {len(root_locals)}: {root_locals}")

    def test_02_hookmetamethod_remote_negation(self):
        """Verify __namecall hook drops outgoing ForestStrike and ForestHandoff."""
        self.assertIn('hookmetamethod(game, "__namecall"', self.code)
        self.assertIn('rName == "ForestStrike"', self.code)
        self.assertIn('rName == "ForestHandoff"', self.code)
        self.assertIn('State.NegatedStrikesCount', self.code)
        self.assertIn('State.NegatedHandoffsCount', self.code)

    def test_03_hitbox_and_spatial_invisibility(self):
        """Verify CanTouch and CanQuery are disabled for collision/raycast evasion."""
        self.assertIn('part.CanTouch = false', self.code)
        self.assertIn('part.CanQuery = false', self.code)
        self.assertIn('part.Name ~= "HumanoidRootPart"', self.code)
        self.assertIn('part.CanCollide = false', self.code)

    def test_04_visual_character_invisibility(self):
        """Verify character BaseParts, accessories, and Decals can be made transparent."""
        self.assertIn('d.Transparency = 1', self.code)
        self.assertIn('d.CastShadow = false', self.code)
        self.assertIn('State.OriginalTransparency', self.code)

    def test_05_lifecycle_and_cleanup_hygiene(self):
        """Verify CharacterAdded/Removing tracking and _G.GuardNegation_Cleanup."""
        self.assertIn('LocalPlayer.CharacterAdded:Connect', self.code)
        self.assertIn('LocalPlayer.CharacterRemoving:Connect', self.code)
        self.assertIn('_G.GuardNegation_Cleanup', self.code)
        self.assertIn('disconnectAll()', self.code)

    def test_06_incoming_guard_warning_monitoring(self):
        """Verify inbound SpeedTollOffer and SpeedTollWarning monitoring for alerts."""
        self.assertIn('RE/GuardPatrol/SpeedTollOffer', self.code)
        self.assertIn('RE/GuardPatrol/SpeedTollWarning', self.code)


if __name__ == "__main__":
    unittest.main()
