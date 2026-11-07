"""
Unit Test Suite for Standalone EggSnatchBackTest.lua
Verifies:
  1. Anti-Bloat: Root locals <= 30 (Karpathy guidelines)
  2. Zero-Kick Safety: No metamethod hooking (__namecall, __index), no CanTouch tampering
  3. Remotes Coverage: RF/EggWorld/AskFieldEggCarry, RE/EggWorld/FieldEggCarry, RE/GuardPatrol/SpeedTollOffer
  4. Anti-Ragdoll & Knockback Nullification
  5. Clean Connection Lifecycle & _G Cleanup
"""

import os
import re
import unittest

SCRIPT_PATH = os.path.join(os.path.dirname(__file__), "EggSnatchBackTest.lua")


class TestEggSnatchBackStandalone(unittest.TestCase):
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
        # Strip comments
        code_no_comments = re.sub(r"--\[=\[.*?\]=\]", "", self.code, flags=re.DOTALL)
        code_no_comments = re.sub(r"--.*", "", code_no_comments)

        self.assertNotIn("__namecall", code_no_comments)
        self.assertNotIn("__index", code_no_comments)
        self.assertNotIn("hookmetamethod", code_no_comments)
        self.assertNotIn("CanTouch", code_no_comments)

    def test_03_remotes_monitored_and_invoked(self):
        """Must monitor and invoke relevant game networking remotes."""
        self.assertIn("RF/EggWorld/AskFieldEggCarry", self.code)
        self.assertIn("RE/EggWorld/FieldEggCarry", self.code)
        self.assertIn("RE/EggWorld/FieldEggShifted", self.code)
        self.assertIn("RE/GuardPatrol/SpeedTollOffer", self.code)
        self.assertIn("RE/RigSync/Refresh", self.code)

    def test_04_anti_ragdoll_and_knockback_nullification(self):
        """Must reset RagdollEndTime to 0 and cancel AssemblyLinearVelocity."""
        self.assertIn("AssemblyLinearVelocity", self.code)
        self.assertIn("Vector3.zero", self.code)
        self.assertIn("RagdollEndTime", self.code)

    def test_05_connection_hygiene(self):
        """Must maintain connection tracking table and provide _G cleanup."""
        self.assertIn("Connections", self.code)
        self.assertIn("_G.EggSnatchBack_Cleanup", self.code)
        self.assertIn("Disconnect()", self.code)

    def test_06_copy_log_feature(self):
        """Must maintain an internal log buffer and provide clipboard export."""
        self.assertIn("State.Logs", self.code)
        self.assertIn("Helpers.copyLogs", self.code)
        self.assertIn("setclipboard", self.code)
        self.assertIn("Copy Log", self.code)


if __name__ == "__main__":
    unittest.main()
