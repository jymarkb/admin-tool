"""
Unit Test Suite for Cleaned Forest Dropper (drop/dropper-1.lua)
Verifies:
  1. Anti-Bloat: Root locals <= 30 (Karpathy guidelines)
  2. Zero-Kick Safety: No metamethod hooking (__namecall, __index), no CanTouch tampering
  3. Inbound Strike Event Listening: SpeedTollOffer, RigSync Ragdoll, RagdollEndTime
  4. Outbound ForestStrike on demand
  5. Teleport to SavedLocation and AskFieldEggDrop spam
  6. Clean Lifecycle & _G Cleanup
"""

import os
import re
import unittest

SCRIPT_PATH = os.path.join(os.path.dirname(__file__), "dropper-1.lua")


class TestCleanForestDropper(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with open(SCRIPT_PATH, "r", encoding="utf-8") as f:
            cls.code = f.read()

    def test_01_root_locals_budget(self):
        """Root locals must be <= 30."""
        root_locals = []
        depth = 0
        for line in self.code.splitlines():
            trimmed = line.strip()
            if trimmed.startswith("--"):
                continue

            # Track block depth approximately
            depth_increase = len(re.findall(r"\b(function|then|do|repeat)\b", trimmed))
            depth_decrease = len(re.findall(r"\b(end|until)\b", trimmed))

            if depth == 0:
                match = re.match(r"^local\s+([A-Za-z0-9_,\s]+)", trimmed)
                if match:
                    vars_str = match.group(1).split("=")[0]
                    for v in vars_str.split(","):
                        v = v.strip()
                        if v and not v.startswith("function"):
                            root_locals.append(v)

            depth += depth_increase - depth_decrease

        self.assertLessEqual(
            len(root_locals),
            30,
            f"Root local budget exceeded: {len(root_locals)} > 30 ({root_locals})",
        )

    def test_02_zero_kick_safety(self):
        """Must not contain dangerous hooks or CanTouch tampering that cause Error Code 268."""
        code_no_comments = re.sub(r"--\[=\[.*?\]=\]", "", self.code, flags=re.DOTALL)
        code_no_comments = re.sub(r"--.*", "", code_no_comments)

        self.assertNotIn("__namecall", code_no_comments)
        self.assertNotIn("__index", code_no_comments)
        self.assertNotIn("hookmetamethod", code_no_comments)
        self.assertNotIn("CanTouch", code_no_comments)

    def test_03_remotes_monitored_and_invoked(self):
        """Must monitor pickup, invoke ForestStrike, listen to SpeedTollOffer, and drop."""
        self.assertIn("RE/EggWorld/FieldEggCarry", self.code)
        self.assertIn("RE/GuardPatrol/ForestStrike", self.code)
        self.assertIn("RE/GuardPatrol/SpeedTollOffer", self.code)
        self.assertIn("RF/EggWorld/AskFieldEggDrop", self.code)

    def test_04_instant_hit_authority_teleport(self):
        """Must set RootPart.CFrame to SavedLocation on strike and nullify ragdoll."""
        self.assertIn("State.SavedLocation", self.code)
        self.assertIn("RootPart.CFrame = CFrame.new(State.SavedLocation)", self.code)
        self.assertIn("RagdollEndTime", self.code)

    def test_05_auto_loop_and_return_to_nest(self):
        """Must support return to nest with empty hands and automated egg pickup."""
        self.assertIn("State.StartLocation", self.code)
        self.assertIn("State.AutoLoop", self.code)
        self.assertIn("Engine.returnToNestAndPickup", self.code)
        self.assertIn("Helpers.tryPickupNearbyEgg", self.code)

    def test_06_copy_log_export(self):
        """Must maintain an internal log buffer and provide clipboard export."""
        self.assertIn("State.Logs", self.code)
        self.assertIn("Helpers.copyLogs", self.code)
        self.assertIn("setclipboard", self.code)
        self.assertIn("Copy Log", self.code)

    def test_07_connection_hygiene(self):
        """Must maintain connection tracking table and provide _G cleanup."""
        self.assertIn("Connections", self.code)
        self.assertIn("_G.ForestDropper_Cleanup", self.code)
        self.assertIn("Disconnect()", self.code)

    def test_08_multi_biome_support(self):
        """Must support multi-biome selection, nest resolution, and guard rousing."""
        self.assertIn("Enchanted Forest", self.code)
        self.assertIn("Cherry Blossom", self.code)
        self.assertIn("Helpers.getBiomeNestPosition", self.code)
        self.assertIn("Helpers.getClosestGuard", self.code)
        self.assertIn("RE/GuardPatrol/Rouse", self.code)

    def test_09_four_step_workflow(self):
        """Must implement 4-step workflow: Forest pickup -> Target Biome -> Forest drop -> SafeZone."""
        self.assertIn("TargetBiomeLocation", self.code)
        self.assertIn("ForestLocation", self.code)
        self.assertIn("SafeZoneLocation", self.code)
        self.assertIn("RootPart.CFrame = CFrame.new(safePos)", self.code)
        self.assertIn("Target Egg:", self.code)
        self.assertIn("Forest:", self.code)
        self.assertIn("SafeZone:", self.code)

    def test_10_target_egg_repickup_isolation(self):
        """Must strictly isolate target biome egg during re-pickup and reject wrong Forest slot eggs."""
        self.assertIn("Helpers.repickupTargetEgg", self.code)
        self.assertIn("State.TargetEggRepicked", self.code)
        self.assertIn("Wrong egg picked up in Forest", self.code)
        self.assertIn("Re-picked up %s egg (%s) for SafeZone delivery!", self.code)


if __name__ == "__main__":
    unittest.main()
