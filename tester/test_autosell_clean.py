#!/usr/bin/env python3
"""
Unit test suite verifying farmer/autosell.lua clean architecture,
anti-bloat compliance, performance optimizations, and safety invariants.
"""

import unittest
import re
import os

TARGET_FILE = "farmer/autosell.lua"

class TestAutosellClean(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        assert os.path.exists(TARGET_FILE), f"File not found: {TARGET_FILE}"
        with open(TARGET_FILE, "r") as f:
            cls.content = f.read()

        # Clean Lua comments
        cls.clean_code = re.sub(r'--\[\[.*?\]\]', '', cls.content, flags=re.DOTALL)
        cls.clean_code = re.sub(r'--[^\n]*', '', cls.clean_code)

    def test_01_root_locals_budget(self):
        """Root locals must be <= 30 (Karpathy anti-bloat guardrail)."""
        root_locals = [
            line.strip() for line in self.content.splitlines()
            if line.startswith("local ")
        ]
        self.assertLessEqual(
            len(root_locals), 30,
            f"Too many root locals: {len(root_locals)} > 30. Group into module tables!"
        )

    def test_02_single_domain_isolation(self):
        """autosell.lua must only touch satchel profile and pet satchel remotes."""
        # Must contain PetSatchel remotes
        self.assertIn("RF/ProfileMirror/FetchProfile", self.content)
        self.assertIn("RE/PetSatchel/SellSelection", self.content)

        # Must NEVER touch field remotes or world snapshot hooks
        forbidden = [
            "AskLiveSnapshot",
            "FieldEggRaritiesShown",
            "FieldEggCycleCountdown",
            "FieldEggBatchShifted",
            "AreaEggSlotsClient",
            "PromptTriggered",
        ]
        for f in forbidden:
            self.assertNotIn(
                f, self.content,
                f"Single-domain violation: {f} found in autosell.lua!"
            )

    def test_03_zero_runtime_sorting_and_prehashed_lookups(self):
        """Table sorting must be performed once at startup, never inside the inner loop."""
        # Verify startup sorting occurs
        self.assertIn("table.sort(Taxonomy.SortedSpecies", self.content)

        # Count occurrences of table.sort in the file
        sort_matches = re.findall(r'table\.sort\(', self.clean_code)
        # One for SortedSpecies startup, one in resolveVerifiedRarity for originNames
        self.assertLessEqual(
            len(sort_matches), 2,
            f"Excessive table.sort calls found: {len(sort_matches)} > 2. Inner-loop sort detected!"
        )

    def test_04_slicing_budget_compliance(self):
        """Must slice satchel iteration with >= 64 items per yield."""
        self.assertIn("SliceMinRecords = 64", self.content)
        self.assertIn("sliceRecords >= Config.SliceMinRecords", self.content)

    def test_05_connection_hygiene(self):
        """All UI connections must be tracked in UI.Connections and cleared on cleanup."""
        self.assertIn("Connections = {}", self.content)
        self.assertIn("function UI.bind(", self.content)
        self.assertIn("table.insert(UI.Connections, conn)", self.content)
        self.assertIn("table.clear(UI.Connections)", self.content)
        self.assertIn("_G.StandaloneAutoSell_Cleanup", self.content)

    def test_06_fail_closed_and_hard_keep_rules(self):
        """Must never sell plain 'Egg', unverified rarities, or placed eggs."""
        self.assertIn("function Taxonomy.isHardKeepName(", self.content)
        self.assertIn("function Taxonomy.hasPlacement(", self.content)
        self.assertIn("RarityVerified = verifiedRarity ~= nil", self.content)
        self.assertIn("if hardKeep or egg.RarityVerified ~= true", self.content)

    def test_07_countdown_throttle_invariant(self):
        """Countdown loop must step by 5s when rem > 5 to avoid UI redraw spikes."""
        self.assertIn("local step = (rem <= 5) and 1.0 or math.min(5.0,", self.content)

    def test_08_batch_network_hygiene(self):
        """Must batch SellSelection into chunks of 100 with pending UID timeout."""
        self.assertIn("BatchSize = 100", self.content)
        self.assertIn("PendingSellConfirmTimeout = 45", self.content)
        self.assertIn("Remotes.SellSelection:FireServer({ Eggs = chunk, Assets = {} })", self.content)

    def test_09_apply_scan_defined_and_connected(self):
        """Engine.applyScan must be explicitly defined and invoked by scanBtn and start loop."""
        self.assertIn("function Engine.applyScan(shouldLog)", self.content)
        self.assertIn("local scanned = Engine.applyScan(", self.content)
        self.assertIn("Engine.applyScan(true)", self.content)

if __name__ == "__main__":
    unittest.main()
