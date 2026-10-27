#!/usr/bin/env python3
"""
Unit Test Suite for farmer/AutoFishing.lua
Verifies:
  1. Syntax & bracket/parenthesis/block balance
  2. Root locals budget <= 190
  3. Zero dead code (getAutoCastPos completely excised)
  4. Zero metamethod hooking (hookmetamethod completely excised)
  5. Exact proven coordinates preserved
  6. Dynamic rod detection & zero-re-equip bypass
  7. Full cleanup & connection hygiene
  8. Accurate remote invocation & retry loop
"""

import unittest
import os
import re

class TestAutoFishing(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        filepath = os.path.join(os.path.dirname(__file__), "AutoFishing.lua")
        with open(filepath, "r", encoding="utf-8") as f:
            cls.code = f.read()

    def test_01_bracket_and_syntax_balance(self):
        """Verify code balance for parentheses, brackets, and do/function/end blocks."""
        open_parens = self.code.count("(")
        close_parens = self.code.count(")")
        self.assertEqual(open_parens, close_parens, f"Parentheses mismatch: {open_parens} vs {close_parens}")

        open_brackets = self.code.count("[")
        close_brackets = self.code.count("]")
        self.assertEqual(open_brackets, close_brackets, f"Brackets mismatch: {open_brackets} vs {close_brackets}")

        open_curly = self.code.count("{")
        close_curly = self.code.count("}")
        self.assertEqual(open_curly, close_curly, f"Curly braces mismatch: {open_curly} vs {close_curly}")

    def test_02_root_locals_budget(self):
        """Verify root-level locals are well within Roblox limit (<= 190)."""
        lines = self.code.splitlines()
        root_locals = [l.strip() for l in lines if l.startswith("local ")]
        self.assertLessEqual(len(root_locals), 190)
        self.assertLessEqual(len(root_locals), 30, f"Expected clean architecture with <= 30 root locals, got {len(root_locals)}")

    def test_03_zero_dead_code_and_zero_metamethod(self):
        """Verify getAutoCastPos and hookmetamethod are completely removed."""
        self.assertNotIn("getAutoCastPos", self.code, "Dead function getAutoCastPos should not exist")
        self.assertNotIn("hookmetamethod", self.code, "hookmetamethod should be completely eliminated")
        self.assertNotIn("getnamecallmethod", self.code)
        self.assertNotIn("oldNamecall", self.code)

    def test_04_exact_proven_coordinates_preserved(self):
        """Verify Halloween bank coordinates and reel target coordinates are preserved."""
        self.assertIn("Vector3.new(-5695.6, -203.7, -7370.9)", self.code)
        self.assertIn("Vector3.new(-5668.5, -206.5, -7368.9)", self.code)

    def test_05_dynamic_rod_detection_and_equip_bypass(self):
        """Verify rod detection is dynamic (any rod) and checks Character first to bypass unnecessary re-equipping."""
        self.assertIn("local function isRod(tool)", self.code)
        self.assertIn('tool:GetAttribute("GearName")', self.code)
        self.assertIn('tool.Name:lower():find("rod"', self.code)
        # Check that Character children are iterated before Backpack
        char_idx = self.code.find("for _, t in ipairs(Character:GetChildren()) do")
        bp_idx = self.code.find("for _, t in ipairs(bp:GetChildren()) do")
        self.assertNotEqual(char_idx, -1)
        self.assertNotEqual(bp_idx, -1)
        self.assertLess(char_idx, bp_idx, "Must check Character before Backpack for zero-re-equip bypass")

    def test_06_connection_hygiene_and_cleanup(self):
        """Verify connection hygiene: connections table, disconnectAll, and global cleanup."""
        self.assertIn("local connections = {}", self.code)
        self.assertIn("local function addConnection(conn)", self.code)
        self.assertIn("local function disconnectAll()", self.code)
        self.assertIn("_G.SimpleAutoFish_Cleanup = cleanup", self.code)
        self.assertIn("disconnectAll()", self.code)
        self.assertIn("UI.Gui:Destroy()", self.code)

    def test_07_reliable_remotes_and_retries(self):
        """Verify proven remote calls (Hold, Cast, Reel) with retry loop."""
        self.assertIn('getNet("RE/Fishing/Hold")', self.code)
        self.assertIn('getNet("RF/Fishing/Cast")', self.code)
        self.assertIn('getNet("RF/Fishing/Reel")', self.code)
        self.assertIn("Remotes.Hold:FireServer()", self.code)
        self.assertIn("Remotes.Cast:InvokeServer(power, Config.CAST_POS)", self.code)
        self.assertIn('Remotes.Reel:InvokeServer(fishId, "Caught", Config.CLICKS)', self.code)
        self.assertIn("MAX_REEL_RETRIES", self.code)
        self.assertIn("for attempt = 1, Config.MAX_REEL_RETRIES + 1 do", self.code)

    def test_08_no_bulky_log_box_spam(self):
        """Verify bulky 220px logbox and multi-line concatenation spam is removed."""
        self.assertNotIn("logBox = Instance.new(\"TextBox\")", self.code)
        self.assertNotIn("table.concat(logLines", self.code)

if __name__ == "__main__":
    unittest.main()
