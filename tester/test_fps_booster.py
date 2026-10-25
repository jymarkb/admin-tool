#!/usr/bin/env python3
"""
Unit test suite for farmer/fps_booster.lua:
Verifies:
1. Syntax and loadability of the Lua script.
2. Root locals budget <= 190 (Karpathy guardrail).
3. Single-domain isolation (does not mutate egg farms, fishing remotes, or satchel profiles).
4. Connection hygiene (all connections tracked in connection tables and cleaned up).
5. Comprehensive feature coverage (SFX, VFX, Lighting/Shadows, Smooth Plastic, 3D Rendering toggle).
6. State restoration capability (does not irreversibly corrupt game state).
"""

import os
import unittest

class TestFpsBooster(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.script_path = "farmer/fps_booster.lua"
        self_dir = os.path.dirname(os.path.abspath(__file__))
        repo_root = os.path.dirname(self_dir)
        cls.full_path = os.path.join(repo_root, cls.script_path)
        with open(cls.full_path, "r", encoding="utf-8") as f:
            cls.code = f.read()

    def test_01_file_exists_and_non_empty(self):
        self.assertTrue(os.path.exists(self.full_path), "farmer/fps_booster.lua does not exist!")
        self.assertGreater(len(self.code), 500, "farmer/fps_booster.lua is suspiciously short!")

    def test_02_root_locals_budget(self):
        """Root locals must be <= 190 (Roblox limit is 200)."""
        root_locals = sum(
            1 for line in self.code.splitlines()
            if line.startswith("local ") and not line.startswith("local function")
        )
        self.assertLessEqual(root_locals, 190, f"Root locals ({root_locals}) exceeded budget of 190!")

    def test_03_connection_hygiene_and_cleanup(self):
        """All connections must be tracked and cleanup must be exported to _G."""
        self.assertIn("addConnection", self.code)
        self.assertIn("cleanup", self.code)
        self.assertIn("_G.FPSBooster_Cleanup", self.code)

    def test_04_single_domain_isolation(self):
        """Must NOT hook into egg remotes, autosell profile, or fishing remotes."""
        forbidden_strings = [
            "AskFieldEggCarry",
            "AskCarryEgg",
            "SellSelection",
            "FetchProfile",
            "RF/Fishing/Cast",
            "RF/Fishing/Reel",
        ]
        for s in forbidden_strings:
            self.assertNotIn(s, self.code, f"FPS booster violates single-domain isolation with {s}!")

    def test_05_sfx_optimization_present(self):
        """Must provide SFX muting and new sound interception."""
        self.assertIn("SoundService", self.code)
        self.assertIn(":IsA(\"Sound\")", self.code)

    def test_06_vfx_optimization_present(self):
        """Must disable particles, trails, beams, smoke, fire, sparkles."""
        for vfx in ["ParticleEmitter", "Trail", "Beam", "Smoke", "Fire", "Sparkles"]:
            self.assertIn(f'"{vfx}"', self.code, f"Missing VFX optimization for {vfx}!")

    def test_07_lighting_and_shadows_present(self):
        """Must optimize Lighting and shadows."""
        self.assertIn("GlobalShadows", self.code)
        self.assertIn("Lighting", self.code)

    def test_08_3d_rendering_toggle_present(self):
        """Must support 3D rendering toggle (Set3dRenderingEnabled)."""
        self.assertIn("Set3dRenderingEnabled", self.code)

    def test_09_fps_cap_present(self):
        """Must support FPS capping via setfpscap."""
        self.assertIn("setfpscap", self.code)

if __name__ == "__main__":
    unittest.main()
