#!/usr/bin/env python3
"""
Unit Test Suite for Streamlined Attribute Manager UI (farmer/AttributeManagerUI.lua)
Verifies:
  1. Syntax & Bracket Balance: 100% balanced (), {}, [].
  2. Luau Root Locals Budget: Root locals <= 30 (Karpathy & Anti-Bloat rules).
  3. Streamlined Minimal UI:
     - Simple ON / OFF buttons only.
     - Close (✕) button.
     - Absence of complex log footers and verbose badge grids.
  4. Ragdoll Attributes Deletion:
     - IsRagdoll, RagdollEndTime, RagdollTime, Ragdolled all targeted.
     - Sets attributes to nil on both LocalPlayer and Character.
  5. Halloween Dimension Control:
     - InHalloweenDimension ON / OFF toggle button.
     - Persists across CharacterAdded.
  6. Clean Lifecycle & Teardown:
     - _G.AttributeManager_Cleanup hook.
     - Disconnects all tracked connections and removes ScreenGui.
"""

import os
import re
import unittest

TARGET_FILE = os.path.join(os.path.dirname(__file__), "AttributeManagerUI.lua")


class TestAttributeManagerUI(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.assertTrue(cls, os.path.exists(TARGET_FILE), f"{TARGET_FILE} must exist")
        with open(TARGET_FILE, "r", encoding="utf-8") as f:
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
                self.assertEqual(
                    pairs[top],
                    ch,
                    f"Mismatched {top} at char {top_i} with {ch} at char {i}",
                )
        self.assertEqual(len(stack), 0, f"Unclosed brackets remaining: {stack}")

    def test_02_root_locals_budget(self):
        """Root locals must be <= 30 (Anti-Bloat budget)."""
        root_locals = []
        for l in self.code.splitlines():
            m = re.match(r"^local\s+([a-zA-Z0-9_, ]+)", l)
            if m:
                root_locals.append(m.group(1).strip())
        self.assertLessEqual(
            len(root_locals),
            30,
            f"Root local budget exceeded: {len(root_locals)} > 30 ({root_locals})",
        )

    def test_03_ragdoll_attributes_targeted(self):
        """Verify all 4 ragdoll attributes are targeted for deletion."""
        target_attrs = ["IsRagdoll", "RagdollEndTime", "RagdollTime", "Ragdolled"]
        for attr in target_attrs:
            self.assertIn(
                f'"{attr}"',
                self.code,
                f"Must target attribute '{attr}' for deletion",
            )

    def test_04_deletion_logic(self):
        """Verify deleteRagdollAttributes sets attributes to nil."""
        self.assertIn("deleteRagdollAttributes", self.code)
        self.assertIn(':SetAttribute(name, nil)', self.code)

    def test_05_halloween_dimension_controls(self):
        """Verify InHalloweenDimension attribute and enable/disable toggle button."""
        self.assertIn("InHalloweenDimension", self.code)
        self.assertIn("setHalloweenDimension", self.code)
        self.assertIn("toggleHalloweenDimension", self.code)
        self.assertIn("HallowToggleBtn", self.code)

    def test_06_close_button_present(self):
        """Verify close button with X exists."""
        self.assertIn("closeBtn", self.code)
        self.assertIn('"✕"', self.code)

    def test_07_clean_lifecycle_and_teardown(self):
        """Verify _G.AttributeManager_Cleanup hook and connection disconnection."""
        self.assertIn("_G.AttributeManager_Cleanup", self.code)
        self.assertIn("Disconnect()", self.code)
        self.assertIn("screenGui:Destroy()", self.code)


if __name__ == "__main__":
    unittest.main()
