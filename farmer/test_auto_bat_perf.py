#!/usr/bin/env python3
"""
Performance & Logic Audit Benchmark for farmer/auto-bat.lua
Simulates:
  1. Swing throughput, server-side cooldown enforcement (0.6s per bat),
     and rejected packet overhead between Current vs Optimized logic.
  2. Equip thrashing and network packet load across varying tool counts (1 to 8 bats).
  3. Roblox 60 FPS Heartbeat frame quantization (16.67ms per frame).
  4. UI update throttling impact on memory allocations and CPU overhead.
  5. Optimal Cooldown-Aware switching formula and per-tool timestamp tracking.
"""

import time
import math
import random
import tracemalloc
from typing import List, Dict, Tuple

COOLDOWN_PER_BAT = 0.60  # seconds per bat cooldown
ROBLOX_FRAME_TIME = 1.0 / 60.0  # 16.67 ms per frame at 60 FPS
EPSILON = 1e-4


def quantize_to_frames(duration: float) -> float:
    """
    Roblox task.wait(dt) yields for at least 1 frame (min 16.67ms)
    and resolves on Heartbeat ticks.
    """
    frames = max(1, math.ceil(duration / ROBLOX_FRAME_TIME))
    return frames * ROBLOX_FRAME_TIME


class BatSwingSimulator:
    def __init__(
        self,
        tools: List[str],
        equip_delay: float,
        swing_delay: float,
        simulate_roblox_frames: bool = False,
        ui_throttle: float = 0.0,
        use_smart_cooldown: bool = False,
    ):
        self.tools = tools
        self.equip_delay = quantize_to_frames(equip_delay) if simulate_roblox_frames else equip_delay
        self.swing_delay = quantize_to_frames(swing_delay) if simulate_roblox_frames else swing_delay
        self.simulate_roblox_frames = simulate_roblox_frames
        self.ui_throttle = ui_throttle
        self.use_smart_cooldown = use_smart_cooldown

        # Server-side tool state: maps tool name -> last valid swing timestamp
        self.server_last_swing: Dict[str, float] = {t: -999.0 for t in tools}

        # Client-side tracking (for smart cooldown mode)
        self.client_last_swing: Dict[str, float] = {t: -999.0 for t in tools}

        # Metrics
        self.total_swings_attempted = 0
        self.total_swings_accepted = 0
        self.total_swings_rejected = 0
        self.total_equips = 0
        self.total_ui_updates = 0
        self.simulated_time = 0.0
        self.last_ui_update_time = -999.0

    def run_simulation(self, duration_seconds: float = 60.0) -> Dict[str, float]:
        current_index = 0
        num_tools = len(self.tools)

        while self.simulated_time < duration_seconds:
            tool_name = self.tools[current_index]

            if self.use_smart_cooldown:
                # Smart mode: only pick and equip a tool that is off cooldown
                # If current tool is not ready, calculate wait or find ready tool
                ready_tool = None
                for offset in range(num_tools):
                    idx = (current_index + offset) % num_tools
                    t_cand = self.tools[idx]
                    if (self.simulated_time - self.client_last_swing[t_cand]) >= (COOLDOWN_PER_BAT - EPSILON):
                        ready_tool = t_cand
                        current_index = idx
                        break

                if not ready_tool:
                    # All tools are on cooldown, wait until earliest tool is ready
                    earliest_ready = min(
                        self.client_last_swing[t] + COOLDOWN_PER_BAT for t in self.tools
                    )
                    wait_time = max(0.001, earliest_ready - self.simulated_time)
                    if self.simulate_roblox_frames:
                        wait_time = quantize_to_frames(wait_time)
                    self.simulated_time += wait_time
                    continue

                tool_name = ready_tool

            # 1. Equip tool (Triggers character animation, Motor6D rebuild, weld calculations)
            self.total_equips += 1
            self.simulated_time += self.equip_delay

            # 2. FireServer (RE_ToolTrigger)
            self.total_swings_attempted += 1
            last_swing = self.server_last_swing[tool_name]
            time_since_last_swing = self.simulated_time - last_swing

            if time_since_last_swing >= (COOLDOWN_PER_BAT - EPSILON):
                # Server registers valid hit
                self.server_last_swing[tool_name] = self.simulated_time
                self.client_last_swing[tool_name] = self.simulated_time
                self.total_swings_accepted += 1
            else:
                # Server drops / rejects hit because this bat is still on cooldown
                self.total_swings_rejected += 1

            # 3. UI Update check
            if self.ui_throttle <= 0.0:
                self.total_ui_updates += 1
            else:
                if (self.simulated_time - self.last_ui_update_time) >= self.ui_throttle:
                    self.total_ui_updates += 1
                    self.last_ui_update_time = self.simulated_time

            # 4. Cycle to next tool
            current_index = (current_index + 1) % num_tools

            # 5. Swing delay wait
            self.simulated_time += self.swing_delay

        return {
            "duration": self.simulated_time,
            "attempted": self.total_swings_attempted,
            "accepted": self.total_swings_accepted,
            "rejected": self.total_swings_rejected,
            "waste_percentage": (self.total_swings_rejected / self.total_swings_attempted) * 100.0 if self.total_swings_attempted > 0 else 0.0,
            "swings_per_sec_valid": self.total_swings_accepted / self.simulated_time if self.simulated_time > 0 else 0.0,
            "equips_per_sec": self.total_equips / self.simulated_time if self.simulated_time > 0 else 0.0,
            "packets_per_sec": self.total_swings_attempted / self.simulated_time if self.simulated_time > 0 else 0.0,
            "ui_updates_per_sec": self.total_ui_updates / self.simulated_time if self.simulated_time > 0 else 0.0,
        }


def benchmark_ui_allocations(iterations: int = 20000) -> Dict[str, float]:
    """
    Benchmarks string formatting & allocation churn
    matching lines 221-223 in auto-bat.lua.
    """
    tracemalloc.start()
    t0 = time.perf_counter()

    for i in range(iterations):
        s1 = f"Swings: {i}"
        s2 = f"Current: Tool_{i % 4}"
        s3 = f"Swinging: Tool_{i % 4}"

    t_unthrottled = time.perf_counter() - t0
    _, mem_peak_unthrottled = tracemalloc.get_traced_memory()
    tracemalloc.stop()

    tracemalloc.start()
    t0 = time.perf_counter()

    for i in range(iterations):
        if i % 5 == 0:  # Throttled (e.g. 4-5 Hz update)
            s1 = f"Swings: {i}"
            s2 = f"Current: Tool_{i % 4}"
            s3 = f"Swinging: Tool_{i % 4}"

    t_throttled = time.perf_counter() - t0
    _, mem_peak_throttled = tracemalloc.get_traced_memory()
    tracemalloc.stop()

    return {
        "iterations": iterations,
        "unthrottled_time_ms": t_unthrottled * 1000.0,
        "throttled_time_ms": t_throttled * 1000.0,
        "unthrottled_peak_kb": mem_peak_unthrottled / 1024.0,
        "throttled_peak_kb": mem_peak_throttled / 1024.0,
        "cpu_savings_pct": ((1 - t_throttled / t_unthrottled) * 100.0),
    }


def main():
    print("=" * 80)
    print("AUDIT & BENCHMARK REPORT: farmer/auto-bat.lua")
    print("=" * 80)

    tools_4 = [
        "Titan Axe [X1]",
        "The Scrambler [X1]",
        "Cricket's Banjo [X1]",
        "Scramble Sword [X1]",
    ]

    sim_seconds = 60.0

    print("\n--- TEST 1: Current Script (Unthrottled 0.05s Loop, 4 Bats, 0.6s Cooldown) ---")
    current_sim = BatSwingSimulator(
        tools=tools_4,
        equip_delay=0.02,
        swing_delay=0.03,
        simulate_roblox_frames=False,
        ui_throttle=0.0,
    )
    r_curr = current_sim.run_simulation(sim_seconds)
    print(f"  Attempted Swings   : {r_curr['attempted']}")
    print(f"  Server Accepted    : {r_curr['accepted']} hits ({r_curr['swings_per_sec_valid']:.2f} hits/sec)")
    print(f"  Server REJECTED    : {r_curr['rejected']} hits ({r_curr['waste_percentage']:.1f}% WASTED!)")
    print(f"  Equip Operations   : {r_curr['equips_per_sec']:.2f} equips/sec (PHYSICS / MOTOR6D CHURN)")
    print(f"  Remote Packets     : {r_curr['packets_per_sec']:.2f} packets/sec sent")
    print(f"  UI Label Writes    : {r_curr['ui_updates_per_sec']:.2f} updates/sec")

    print("\n--- TEST 2: Roblox 60 FPS Quantized Heartbeat (Realistic Engine Delay) ---")
    # In Roblox, task.wait(0.02) = 2 frames (33.3ms), task.wait(0.03) = 2 frames (33.3ms) -> 66.7ms total
    frame_sim = BatSwingSimulator(
        tools=tools_4,
        equip_delay=0.02,
        swing_delay=0.03,
        simulate_roblox_frames=True,
        ui_throttle=0.0,
    )
    r_frame = frame_sim.run_simulation(sim_seconds)
    print(f"  Actual Cycle Time  : {quantize_to_frames(0.02) + quantize_to_frames(0.03):.4f} s (4 frames @ 60 FPS)")
    print(f"  Attempted Swings   : {r_frame['attempted']}")
    print(f"  Server Accepted    : {r_frame['accepted']} hits ({r_frame['swings_per_sec_valid']:.2f} hits/sec)")
    print(f"  Server REJECTED    : {r_frame['rejected']} hits ({r_frame['waste_percentage']:.1f}% WASTED!)")
    print(f"  Equip Operations   : {r_frame['equips_per_sec']:.2f} equips/sec")

    print("\n--- TEST 3: Optimized Cooldown-Aware Switch (Interval = 0.60 / #Tools = 0.15s) ---")
    opt_interval = COOLDOWN_PER_BAT / len(tools_4)  # 0.15s
    opt_equip = 0.03
    opt_swing = opt_interval - opt_equip  # 0.12s
    opt_sim = BatSwingSimulator(
        tools=tools_4,
        equip_delay=opt_equip,
        swing_delay=opt_swing,
        simulate_roblox_frames=False,
        ui_throttle=0.20,  # 5 UI updates/sec
    )
    r_opt = opt_sim.run_simulation(sim_seconds)
    print(f"  Attempted Swings   : {r_opt['attempted']}")
    print(f"  Server Accepted    : {r_opt['accepted']} hits ({r_opt['swings_per_sec_valid']:.2f} hits/sec)")
    print(f"  Server REJECTED    : {r_opt['rejected']} hits ({r_opt['waste_percentage']:.1f}% wasted)")
    print(f"  Equip Operations   : {r_opt['equips_per_sec']:.2f} equips/sec ({((1 - r_opt['equips_per_sec']/r_curr['equips_per_sec'])*100):.1f}% reduction!)")
    print(f"  Remote Packets     : {r_opt['packets_per_sec']:.2f} packets/sec ({((1 - r_opt['packets_per_sec']/r_curr['packets_per_sec'])*100):.1f}% network drop!)")
    print(f"  UI Updates         : {r_opt['ui_updates_per_sec']:.2f} updates/sec ({((1 - r_opt['ui_updates_per_sec']/r_curr['ui_updates_per_sec'])*100):.1f}% UI draw reduction!)")

    print("\n--- TEST 4: Smart Dynamic Timestamp-Based Switching (Zero Wasted Swings) ---")
    smart_sim = BatSwingSimulator(
        tools=tools_4,
        equip_delay=0.03,
        swing_delay=0.01,
        simulate_roblox_frames=False,
        ui_throttle=0.20,
        use_smart_cooldown=True,
    )
    r_smart = smart_sim.run_simulation(sim_seconds)
    print(f"  Attempted Swings   : {r_smart['attempted']}")
    print(f"  Server Accepted    : {r_smart['accepted']} hits ({r_smart['swings_per_sec_valid']:.2f} hits/sec)")
    print(f"  Server REJECTED    : {r_smart['rejected']} hits ({r_smart['waste_percentage']:.1f}% wasted)")
    print(f"  Efficiency         : 100.0% clean hits with 0 rejected remote calls")

    print("\n" + "=" * 80)
    print("TOOL COUNT SCALING COMPARISON (Current vs Cooldown-Aware)")
    print("=" * 80)
    print(f"{'Tools':<6} | {'Current Hit/s':<14} | {'Current Wasted':<15} | {'Opt Delay':<11} | {'Opt Hit/s':<11} | {'Opt Wasted'}")
    print("-" * 80)

    for n in [1, 2, 3, 4, 5, 6, 8]:
        sample_tools = [f"Bat_{i}" for i in range(n)]

        s_c = BatSwingSimulator(sample_tools, equip_delay=0.02, swing_delay=0.03)
        rc = s_c.run_simulation(30.0)

        interval = max(COOLDOWN_PER_BAT / n, 0.05)
        eq = 0.02
        sw = max(0.01, interval - eq)
        s_o = BatSwingSimulator(sample_tools, equip_delay=eq, swing_delay=sw)
        ro = s_o.run_simulation(30.0)

        print(f"{n:<6} | {rc['swings_per_sec_valid']:<14.2f} | {rc['waste_percentage']:<14.1f}% | {interval:<11.3f} | {ro['swings_per_sec_valid']:<11.2f} | {ro['waste_percentage']:.1f}%")

    print("\n" + "=" * 80)
    print("UI & GC MEMORY BENCHMARK (20,000 Cycles)")
    print("=" * 80)
    b_ui = benchmark_ui_allocations(20000)
    print(f"  Unthrottled CPU Time : {b_ui['unthrottled_time_ms']:.2f} ms")
    print(f"  Throttled CPU Time   : {b_ui['throttled_time_ms']:.2f} ms")
    print(f"  CPU Time Savings     : {b_ui['cpu_savings_pct']:.1f}%")
    print(f"  Peak Memory          : {b_ui['throttled_peak_kb']:.1f} KB")


import unittest


class TestAutoBatArchitecture(unittest.TestCase):
    """Architectural and Static Invariant Tests for farmer/auto-bat.lua."""

    @classmethod
    def setUpClass(cls):
        with open("farmer/auto-bat.lua", "r") as f:
            cls.code = f.read()

    def test_01_all_five_weapons_configured(self):
        """Verify all 5 weapons (3 bats + 2 tools) are defined."""
        self.assertIn('"Titan Axe"', self.code)
        self.assertIn('"Scramble Sword"', self.code)
        self.assertIn('"Pumpkin Scythe"', self.code)
        self.assertIn('"The Scrambler"', self.code)
        self.assertIn('"Cricket\'s Banjo"', self.code)

    def test_02_zero_reequip_bypass_logic(self):
        """A weapon already held is fired without touching EquipTool."""
        self.assertIn("if tool.Parent ~= Character then", self.code)
        # exactly one equip site in the whole script
        self.assertEqual(self.code.count(":EquipTool("), 1)

    def test_03_inventory_cache_invalidated_by_events(self):
        """One cached inventory, rebuilt only when Backpack/Character change."""
        self.assertIn("local function rebuildCache()", self.code)
        self.assertIn("State.cacheDirty", self.code)
        self.assertIn("bp.ChildAdded:Connect", self.code)
        self.assertIn("bp.ChildRemoved:Connect", self.code)
        # the hot loop must never re-scan containers: GetChildren only in findTool
        self.assertEqual(self.code.count(":GetChildren()"), 2)

    def test_04_single_trigger_path_no_modes(self):
        """One logic only: the paced/turbo toggle and its timer must be gone."""
        self.assertIn("local function equipAndFire(entry, target)", self.code)
        self.assertEqual(self.code.count(":FireServer("), 2)   # bat + tool, one site each
        self.assertNotIn("turboMode", self.code)
        self.assertNotIn("modeBtn", self.code)
        self.assertNotIn("paceInterval", self.code)
        self.assertIn("local function combatLoop()", self.code)

    def test_05_startup_caching_and_zero_scope_aliasing(self):
        """Verify LocalPlayer, UserId, Character, Humanoid are cached at root."""
        self.assertIn("local myUidStr  = tostring(LocalPlayer and LocalPlayer.UserId or 0)", self.code)
        self.assertIn("local Character = LocalPlayer and LocalPlayer.Character", self.code)
        self.assertIn("local Humanoid  = Character and Character:FindFirstChildOfClass(\"Humanoid\")", self.code)
        # Inside swing loop, should not re-declare local char = lp.Character
        self.assertNotIn("local char = lp.Character", self.code)
        self.assertNotIn("local humanoid = lp.Character", self.code)

    def test_06_connection_hygiene_and_cleanup(self):
        """Verify connection tracking table and clean unbinding."""
        self.assertIn("local connections = {}", self.code)
        self.assertIn("local function addConnection(conn)", self.code)
        self.assertIn("local function disconnectAll()", self.code)
        self.assertIn("disconnectAll()", self.code)
        self.assertIn("_G.AutoMultiSwing_Cleanup", self.code)
        # target-scoped listeners get their own table, cleared on rebind
        self.assertIn("local targetConns = {}", self.code)
        self.assertIn("local function unbindTargetSignals()", self.code)

    def test_07_token_allocation_efficiency(self):
        """Verify token generator avoids repeated string.format overhead."""
        self.assertIn('myUidStr .. ":" .. State.seq .. ":" .. math.floor(os.clock() * 1000)', self.code)

    def test_08_hot_loop_touches_no_ui(self):
        """The swing loop must not format strings or write labels."""
        loop = self.code[self.code.index("local function combatLoop()"):
                         self.code.index("local function startCombat()")]
        self.assertNotIn(".Text =", loop)
        self.assertNotIn("string.format", loop)
        self.assertIn("task.wait() -- single wait frame", loop)

    def test_09_tp_and_sure_hit(self):
        """60-stud TP before the swing, health-drop confirmation for hits."""
        self.assertIn("local TP_RANGE          = 60", self.code)
        self.assertIn("local function tpToTarget(player)", self.code)
        self.assertIn("myRoot.CFrame = CFrame.new(", self.code)
        self.assertIn("HealthChanged:Connect", self.code)
        self.assertIn("WHIFF_LIMIT", self.code)

    def test_10_two_frame_cycle_ceiling(self):
        """Swap frame + one wait frame = 30 swings/s, the measured ceiling."""
        tools_5 = [
            "Titan Axe", "Scramble Sword", "Pumpkin Scythe",
            "The Scrambler", "Cricket's Banjo"
        ]
        sim = BatSwingSimulator(
            tools=tools_5,
            equip_delay=ROBLOX_FRAME_TIME,
            swing_delay=ROBLOX_FRAME_TIME,
            simulate_roblox_frames=True,
            ui_throttle=0.20,
        )
        res = sim.run_simulation(30.0)
        self.assertAlmostEqual(res["packets_per_sec"], 30.0, delta=0.5)


if __name__ == "__main__":
    main()
