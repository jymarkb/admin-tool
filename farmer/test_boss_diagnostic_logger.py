"""
Test Suite: Boss & Guard Diagnostic Logger Architecture & Verification
======================================================================
Validates farmer/BossDiagnosticLogger.lua for:
  1. Root locals budget <= 30 (budget limit 190).
  2. Zero metamethod hooking: strictly NO hookmetamethod to avoid kicks/crashes.
  3. Passive sniffer coverage across all biomes (Forest, BossEvent, Pumpkin, Scramble, Ghost).
  4. Telemetry tracking (Position, Altitude Y, Fling detection, Ragdoll state).
  5. Export functionality (setclipboard and writefile support).
  6. Connection and memory cleanup hygiene.
"""

import os
import unittest


class TestBossDiagnosticLoggerArchitecture(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        script_path = os.path.join(os.path.dirname(__file__), "BossDiagnosticLogger.lua")
        with open(script_path, "r", encoding="utf-8") as f:
            cls.code = f.read()

    def test_01_root_locals_budget(self):
        """Verify root locals are strictly <= 30 (current count 18)."""
        root_locals = []
        for idx, line in enumerate(self.code.splitlines()):
            stripped = line.strip()
            if stripped.startswith("local ") and not line.startswith(" ") and not line.startswith("\t"):
                root_locals.append((idx + 1, stripped))
        self.assertLessEqual(len(root_locals), 30, f"Expected <= 30 root locals, got {len(root_locals)}: {root_locals}")

    def test_02_zero_metamethod_hooking(self):
        """Verify hookmetamethod is completely absent to eliminate disconnects/crashes."""
        self.assertNotIn("hookmetamethod", self.code)
        self.assertNotIn("getnamecallmethod", self.code)

    def test_03_zero_character_tampering(self):
        """Verify CanTouch and CanCollide are not modified on the player's character."""
        self.assertNotIn("part.CanTouch = false", self.code)
        self.assertNotIn("part.CanCollide = false", self.code)

    def test_04_monitored_remotes_comprehensive_coverage(self):
        """Verify coverage for Forest Guard, BossEvent, PumpkinBoss, ScrambleBoss, and RigSync."""
        # Forest Guards
        self.assertIn("RE/GuardPatrol/ForestStrike", self.code)
        self.assertIn("RE/GuardPatrol/ForestHandoff", self.code)
        self.assertIn("RE/GuardPatrol/SpeedTollOffer", self.code)
        # All-Biome Boss Events
        self.assertIn("RE/BossEvent/HazardHit", self.code)
        self.assertIn("RE/BossEvent/BlackHoleHit", self.code)
        self.assertIn("RE/PumpkinBoss/HazardHit", self.code)
        self.assertIn("RE/ScrambleBoss/HazardHit", self.code)
        self.assertIn("RE/GhostBoss/Suction", self.code)
        # RigSync & Ragdoll
        self.assertIn("RE/RigSync/Refresh", self.code)

    def test_05_export_and_copy_capabilities(self):
        """Verify clipboard and file saving support."""
        self.assertIn("setclipboard", self.code)
        self.assertIn("writefile", self.code)
        self.assertIn("boss-diagnostic.log", self.code)

    def test_06_lifecycle_and_cleanup_hygiene(self):
        """Verify lifecycle connections and clean unmounting."""
        self.assertIn("LocalPlayer.CharacterAdded:Connect", self.code)
        self.assertIn("_G.BossDiagnosticLogger_Cleanup", self.code)
        self.assertIn("disconnectAll()", self.code)


if __name__ == "__main__":
    unittest.main()
