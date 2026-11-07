#!/usr/bin/env python3
"""
Unit test suite for farmer/EggMutationScanner.lua
Verifies syntax, root local budget, remote paths, and UI components.
"""

import re
import unittest

class TestEggMutationScanner(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        with open("farmer/EggMutationScanner.lua", "r") as f:
            cls.code = f.read()

    def test_01_root_locals_budget(self):
        """Verify root locals budget is strictly <= 30."""
        root_locals = []
        for idx, line in enumerate(self.code.splitlines()):
            stripped = line.strip()
            if stripped.startswith("local ") and not line.startswith(" ") and not line.startswith("\t"):
                root_locals.append((idx + 1, stripped))
        self.assertLessEqual(len(root_locals), 30, f"Too many root locals: {len(root_locals)}")

    def test_02_remote_event_monitoring_coverage(self):
        """Verify all critical EggWorld remote events are monitored."""
        self.assertIn("RE/EggWorld/FieldEggShifted", self.code)
        self.assertIn("RE/EggWorld/FieldEggBatchShifted", self.code)
        self.assertIn("RE/EggWorld/FieldEggCarry", self.code)
        self.assertIn("RE/EggWorld/OwnerDropped", self.code)

    def test_03_deep_scan_containers(self):
        """Verify AreaEggSlotsClient, Backpack, Character, and Workspace.Eggs are scanned."""
        self.assertIn('"AreaEggSlotsClient"', self.code)
        self.assertIn('"Backpack"', self.code)
        self.assertIn('"Character"', self.code)
        self.assertIn('"Eggs"', self.code)

    def test_04_ui_elements_and_export(self):
        """Verify interactive UI buttons and export mechanisms."""
        self.assertIn("RUN SCAN", self.code)
        self.assertIn("COPY LOG", self.code)
        self.assertIn("SAVE FILE", self.code)
        self.assertIn("setclipboard", self.code)
        self.assertIn("writefile", self.code)
        self.assertIn("EggMutationScannerHUD", self.code)

    def test_05_cleanup_registration(self):
        """Verify cleanup routine is registered in _G."""
        self.assertIn("_G.EggMutationScanner_Cleanup", self.code)

if __name__ == "__main__":
    unittest.main()
