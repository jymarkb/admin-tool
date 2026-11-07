"""
Unit Test Suite for Standalone SpeedMultiplierTest.lua
Verifies:
  1. Anti-Bloat: Root locals <= 30 (Karpathy guidelines)
  2. Zero-Kick Safety: No metamethod hooking (__namecall, __index), no CanTouch tampering
  3. Linear Velocity Physics: AssemblyLinearVelocity driven by MoveDirection and Multiplier
  4. Multiplier Controls: Presets (1.0x to 3.0x), custom input, live base speed sync
  5. Clipboard Log Export: setclipboard support and log buffer
  6. Clean Lifecycle & _G Cleanup
"""

import os
import re
import unittest

SCRIPT_PATH = os.path.join(os.path.dirname(__file__), "SpeedMultiplierTest.lua")


class TestSpeedMultiplierStandalone(unittest.TestCase):
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

    def test_03_assembly_linear_velocity_physics(self):
        """Must drive AssemblyLinearVelocity along MoveDirection."""
        self.assertIn("AssemblyLinearVelocity", self.code)
        self.assertIn("MoveDirection", self.code)
        self.assertIn("State.Multiplier", self.code)

    def test_04_remotes_synchronization(self):
        """Must monitor RigSync and FieldEggCarry to compute dynamic base speeds."""
        self.assertIn("RE/RigSync/Refresh", self.code)
        self.assertIn("RE/EggWorld/FieldEggCarry", self.code)
        self.assertIn("SetWalkSpeed", self.code)

    def test_05_copy_log_export(self):
        """Must maintain an internal log buffer and provide clipboard export."""
        self.assertIn("State.Logs", self.code)
        self.assertIn("Helpers.copyLogs", self.code)
        self.assertIn("setclipboard", self.code)
        self.assertIn("Copy Log", self.code)

    def test_06_connection_hygiene(self):
        """Must maintain connection tracking table and provide _G cleanup."""
        self.assertIn("Connections", self.code)
        self.assertIn("_G.SpeedMultiplier_Cleanup", self.code)
        self.assertIn("Disconnect()", self.code)


if __name__ == "__main__":
    unittest.main()
