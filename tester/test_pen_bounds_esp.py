#!/usr/bin/env python3
"""
Unit test verifying Pen Bounds calculation and 4-side geometry resolution.
"""

import unittest
import math


def calculate_pen_bounds(eggs, plot_center=None, plot_size=None):
    if eggs and len(eggs) > 0:
        min_x = min(p[0] for p in eggs)
        max_x = max(p[0] for p in eggs)
        min_y = min(p[1] for p in eggs)
        max_y = max(p[1] for p in eggs)
        min_z = min(p[2] for p in eggs)
        max_z = max(p[2] for p in eggs)

        span_x = max_x - min_x
        span_z = max_z - min_z
        center = ((min_x + max_x) / 2, (min_y + max_y) / 2, (min_z + max_z) / 2)
        size = (max(span_x + 8.0, 14.0), 3.0, max(span_z + 8.0, 14.0))
        source = f"PlacedEggs ({len(eggs)})"
    elif plot_center and plot_size:
        center = plot_center
        size = plot_size
        source = "PlotPart"
    else:
        center = (6575.43, 69.96, -438.45)
        size = (16.0, 3.0, 16.0)
        source = "SafeZone"

    half_w = size[0] / 2
    half_d = size[2] / 2
    h = size[1]

    # 4 distinct sides:
    # Front (+Z / South), Back (-Z / North), Left (-X / West), Right (+X / East)
    sides = {
        "Front": {
            "pos": (center[0], center[1], center[2] + half_d),
            "size": (size[0], h, 0.4),
            "color": "Cyan",
        },
        "Back": {
            "pos": (center[0], center[1], center[2] - half_d),
            "size": (size[0], h, 0.4),
            "color": "Orange",
        },
        "Left": {
            "pos": (center[0] - half_w, center[1], center[2]),
            "size": (0.4, h, size[2]),
            "color": "Green",
        },
        "Right": {
            "pos": (center[0] + half_w, center[1], center[2]),
            "size": (0.4, h, size[2]),
            "color": "Yellow",
        },
    }

    corners = {
        "FrontLeft": (center[0] - half_w, center[1], center[2] + half_d),
        "FrontRight": (center[0] + half_w, center[1], center[2] + half_d),
        "BackLeft": (center[0] - half_w, center[1], center[2] - half_d),
        "BackRight": (center[0] + half_w, center[1], center[2] - half_d),
    }

    return {
        "center": center,
        "size": size,
        "source": source,
        "sides": sides,
        "corners": corners,
    }


class TestPenBoundsESP(unittest.TestCase):
    def test_single_egg_bounds(self):
        eggs = [(100.0, 50.0, 200.0)]
        bounds = calculate_pen_bounds(eggs)

        self.assertEqual(bounds["center"], (100.0, 50.0, 200.0))
        self.assertEqual(bounds["size"], (14.0, 3.0, 14.0))

        # Check sides
        self.assertEqual(bounds["sides"]["Front"]["pos"], (100.0, 50.0, 207.0))
        self.assertEqual(bounds["sides"]["Back"]["pos"], (100.0, 50.0, 193.0))
        self.assertEqual(bounds["sides"]["Left"]["pos"], (93.0, 50.0, 200.0))
        self.assertEqual(bounds["sides"]["Right"]["pos"], (107.0, 50.0, 200.0))

    def test_multiple_eggs_bounds(self):
        eggs = [
            (100.0, 50.0, 200.0),
            (110.0, 50.0, 220.0),
            (105.0, 50.0, 210.0),
        ]
        bounds = calculate_pen_bounds(eggs)

        # X span = 10, Z span = 20 -> with margin (+8): sizeX = 18, sizeZ = 28
        self.assertEqual(bounds["center"], (105.0, 50.0, 210.0))
        self.assertEqual(bounds["size"], (18.0, 3.0, 28.0))

        # Check corners
        self.assertEqual(bounds["corners"]["FrontLeft"], (105.0 - 9.0, 50.0, 210.0 + 14.0))
        self.assertEqual(bounds["corners"]["FrontRight"], (105.0 + 9.0, 50.0, 210.0 + 14.0))
        self.assertEqual(bounds["corners"]["BackLeft"], (105.0 - 9.0, 50.0, 210.0 - 14.0))
        self.assertEqual(bounds["corners"]["BackRight"], (105.0 + 9.0, 50.0, 210.0 - 14.0))

    def test_empty_eggs_fallback(self):
        bounds = calculate_pen_bounds([])
        self.assertEqual(bounds["center"], (6575.43, 69.96, -438.45))
        self.assertEqual(bounds["source"], "SafeZone")

    def test_spatial_capacity(self):
        # 14 x 14 pen with 3.5 stud slot size: floor(14/3.5) * floor(14/3.5) = 4 * 4 = 16 slots
        slot_size = 3.5
        size_x, size_z = 14.0, 14.0
        cols = math.floor(size_x / slot_size)
        rows = math.floor(size_z / slot_size)
        self.assertEqual(cols * rows, 16)

        # 18 x 18 pen: floor(18/3.5) = 5 -> 5 * 5 = 25 slots
        cols18 = math.floor(18.0 / slot_size)
        rows18 = math.floor(18.0 / slot_size)
        self.assertEqual(cols18 * rows18, 25)

    def test_capacity_regex_patterns(self):
        import re
        patterns = [
            (r"(\d+)\s*/\s*(\d+)\s*[Ee]gg", "3/5 Eggs", ("3", "5")),
            (r"[Ee]ggs?:?\s*(\d+)\s*/\s*(\d+)", "Eggs: 2/8", ("2", "8")),
            (r"[Pp]en:?\s*(\d+)\s*/\s*(\d+)", "Pen: 4/10", ("4", "10")),
            (r"[Cc]apacity:?\s*(\d+)\s*/\s*(\d+)", "Capacity: 1/6", ("1", "6")),
        ]
        for pat, text, expected in patterns:
            m = re.search(pat, text)
            self.assertIsNotNone(m, f"Pattern {pat} should match {text}")
            self.assertEqual(m.groups(), expected)

    def test_script_contains_log_and_copy(self):
        import os
        path = os.path.join(os.path.dirname(__file__), "..", "farmer", "PenBoundsESPTest.lua")
        with open(path, "r", encoding="utf-8") as f:
            code = f.read()
        self.assertIn("logEntries", code)
        self.assertIn("logCallback", code)
        self.assertIn("COPY LOG", code)
        self.assertIn("setclipboard", code)
        self.assertIn("CenterMode", code)
        self.assertIn("modeBtn", code)
        self.assertIn("ToUpdate", code)
        self.assertIn("CenterPoint", code)
        self.assertIn("PetArea", code)
        self.assertIn("SizeMode", code)
        self.assertIn("SideOrientation", code)
        self.assertIn("sizeBtn", code)
        self.assertIn("flipBtn", code)


if __name__ == "__main__":
    unittest.main()
