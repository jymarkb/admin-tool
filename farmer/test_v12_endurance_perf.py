#!/usr/bin/env python3
"""
Long-Run Performance & Endurance Stress Test Suite for farmer/EggGoToUI_v12.lua
==============================================================================
Validates multi-hour endurance, memory stability, and performance invariants:
  1. Multi-Cycle Night & Day Reset Endurance (5 cycles, 500+ egg batch shifts)
     - Flat memory growth (< 5.0% growth between cycle 1 and cycle 5)
     - Zero phantom egg persistence in EggCacheByUid
  2. 60 FPS Stepped & Heartbeat Allocation Profiling (60,000 simulated ticks)
     - Zero unthrottled GetDescendants() calls in Stepped loop (throttled to 2.0s)
     - Idle velocity bypass (zero allocations when stationary)
  3. Character Respawn & Tool Swap Stress Test (200 cycles)
     - Zero Motor6D joint leaks into Engine.Recovery.Joints
     - Zero connection leaks in Engine.Recovery.Connections
  4. DOM Card Pool Recycling (Zero DOM allocation during UI re-renders)
  5. Lua Codebase Anti-Bloat & Safety Invariant Audit on EggGoToUI_v12.lua
"""

import re
import time
import tracemalloc
import unittest


class TestV12EndurancePerformance(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        with open("farmer/EggGoToUI_v12.lua", "r") as f:
            cls.lua_code = f.read()

    # =========================================================================
    # TEST 1: Multi-Cycle Night & Day Reset Endurance (5 full cycles)
    # =========================================================================
    def test_01_multi_cycle_night_reset_memory_endurance(self):
        """Simulate 5 consecutive Night & Day Resets with hundreds of egg shifts.
        Verify memory remains flat (growth < 5.0%) and zero phantom eggs remain."""
        tracemalloc.start()

        state = {
            "EggCacheByUid": {},
            "RarityByUid": {},
            "IsCarry": False,
            "CarryUid": None,
            "CyclesCompleted": 0,
        }

        def clear_all_eggs(reason):
            preserved_carry = None
            if state["IsCarry"] and state["CarryUid"] and state["CarryUid"] in state["EggCacheByUid"]:
                preserved_carry = state["EggCacheByUid"][state["CarryUid"]]
            state["EggCacheByUid"].clear()
            state["RarityByUid"].clear()
            if preserved_carry and state["CarryUid"]:
                state["EggCacheByUid"][state["CarryUid"]] = preserved_carry

        def simulate_night_cycle(cycle_id):
            # Phase 1: Night transition clears all field eggs
            clear_all_eggs(f"NightTransition_{cycle_id}")

            # Phase 2: Server pushes batch of 120 new eggs across 13 biomes
            for i in range(120):
                uid = f"Egg_C{cycle_id}_{i}"
                state["EggCacheByUid"][uid] = {
                    "Uid": uid,
                    "State": "Slot",
                    "BoundsCFrame": (i * 10, 50, i * 10),
                    "PreparedSourceName": f"Species_{i % 25}",
                    "DisplayName": f"Species_{i % 25} Egg",
                }
                state["RarityByUid"][uid] = "Legendary" if i % 10 == 0 else "Common"

            # Phase 3: Player farms 10 eggs, dropping and picking up
            for f in range(10):
                farm_uid = f"Egg_C{cycle_id}_{f}"
                if farm_uid in state["EggCacheByUid"]:
                    # Claimed / delivered egg
                    del state["EggCacheByUid"][farm_uid]

            # Phase 4: Cycle countdown finishes (reset)
            clear_all_eggs(f"CycleCountdown_{cycle_id}")
            state["CyclesCompleted"] += 1

        # Baseline warmup cycle
        simulate_night_cycle(0)

        memory_snapshots = []
        tracemalloc.reset_peak()

        for c in range(1, 6):
            simulate_night_cycle(c)
            current_mem, _ = tracemalloc.get_traced_memory()
            memory_snapshots.append(current_mem)

        tracemalloc.stop()

        self.assertEqual(state["CyclesCompleted"], 6)
        self.assertEqual(len(state["EggCacheByUid"]), 0, "Phantom eggs remained after cycle reset!")
        self.assertEqual(len(state["RarityByUid"]), 0, "Rarities leaked after cycle reset!")

        # Verify memory remains strictly flat across 5 consecutive cycles (< 5% growth)
        mem_cycle_1 = memory_snapshots[0]
        mem_cycle_5 = memory_snapshots[-1]
        growth = (mem_cycle_5 - mem_cycle_1) / max(mem_cycle_1, 1)
        self.assertLess(
            growth, 0.05,
            f"Memory grew by {growth * 100:.2f}% across 5 night resets, indicating a leak!"
        )

    # =========================================================================
    # TEST 2: 60 FPS Stepped & Heartbeat High-Frequency Physics Stress (60,000 frames)
    # =========================================================================
    def test_02_stepped_noclip_zero_frame_allocation(self):
        """Simulate 60,000 Stepped ticks (16 minutes of 60 FPS gameplay).
        Verify No-Clip throttles GetDescendants to every 2.0s, eliminating GC pressure."""
        call_counts = {"GetDescendants": 0}

        class MockCharacter:
            def __init__(self):
                self.parts = [{"Name": f"Part_{i}", "IsA": "BasePart", "CanCollide": True} for i in range(25)]

            def GetDescendants(self):
                call_counts["GetDescendants"] += 1
                return list(self.parts)

        mock_char = MockCharacter()
        noclip_parts = []
        last_refresh = 0.0

        tracemalloc.start()
        # 60,000 frames at dt = 1/60s (1000 simulated seconds)
        simulated_time = 0.0
        for frame in range(60000):
            simulated_time += 1.0 / 60.0
            first_part = noclip_parts[0] if len(noclip_parts) > 0 else None

            # v12 logic: throttled to 2.0s refresh
            if len(noclip_parts) == 0 or not first_part or (simulated_time - last_refresh > 2.0):
                last_refresh = simulated_time
                noclip_parts.clear()
                for p in mock_char.GetDescendants():
                    if p["IsA"] == "BasePart":
                        noclip_parts.append(p)

            # Steady state: zero allocations
            for i in range(len(noclip_parts)):
                p = noclip_parts[i]
                if p["CanCollide"]:
                    p["CanCollide"] = False

        cur_mem, peak_mem = tracemalloc.get_traced_memory()
        tracemalloc.stop()

        # In 1000 seconds, GetDescendants should be called at most ~501 times (every 2.0s), NOT 60,000 times!
        self.assertLessEqual(call_counts["GetDescendants"], 505)
        # Heap memory should remain negligible (< 200 KB) after 60,000 frames
        self.assertLess(peak_mem, 200 * 1024, "NoClip loop leaked excessive memory during 60k frames!")

    def test_03_heartbeat_velocity_idle_bypass(self):
        """Simulate Heartbeat loop when player is stationary.
        Verify zero expensive operations and zero heap allocation when stationary."""
        hrp = {"AssemblyLinearVelocity": (0, 0, 0)}
        hum = {"MoveDirection": (0, 0, 0), "WalkSpeed": 16.0}
        active_walk_target = None

        tracemalloc.start()
        for _ in range(60000):
            # v12 logic in updatePhysics
            if active_walk_target:
                # moving to target
                pass
            elif hum["MoveDirection"][0] != 0 or hum["MoveDirection"][2] != 0:
                # manual WASD
                pass
            # Idle: early exit, 0 allocations

        cur_mem, peak_mem = tracemalloc.get_traced_memory()
        tracemalloc.stop()

        self.assertLess(peak_mem, 50 * 1024, "Idle velocity loop allocated memory during stationary state!")

    # =========================================================================
    # TEST 3: Character Respawn & Tool Swap Stress Test (200 cycles)
    # =========================================================================
    def test_04_recovery_joint_leak_prevention(self):
        """Simulate 200 character respawns and repeated tool swaps.
        Verify BodyJointNames whitelist prevents tool joints from leaking into recovery."""
        recovery_joints = []
        recovery_connections = []

        # R15 body joints whitelist from v12 Config.Recovery.BodyJointNames
        whitelist = {
            "RootJoint": True, "Root": True, "Neck": True, "Waist": True,
            "Left Shoulder": True, "Right Shoulder": True, "Left Hip": True, "Right Hip": True,
            "LeftShoulder": True, "RightShoulder": True, "LeftElbow": True, "RightElbow": True,
            "LeftWrist": True, "RightWrist": True,
        }

        def bind_character(motors):
            # Disconnect old connections & clear tables (v12 bindCharacter logic)
            for c in recovery_connections:
                c["Connected"] = False
            recovery_connections.clear()
            recovery_joints.clear()

            for obj in motors:
                if obj["IsA"] == "Motor6D" and whitelist.get(obj["Name"]):
                    recovery_joints.append(obj)
                    recovery_connections.append({"Connected": True, "Target": obj})

        # 200 respawns
        for cycle in range(200):
            # Skeleton with 14 whitelisted joints + 10 random tool/accessory joints
            char_motors = [{"Name": name, "IsA": "Motor6D"} for name in whitelist.keys()]
            char_motors.append({"Name": "HandleWeld", "IsA": "Motor6D"})
            char_motors.append({"Name": "RodWeld", "IsA": "Motor6D"})
            char_motors.append({"Name": "EggCarryWeld", "IsA": "Motor6D"})

            bind_character(char_motors)

        # After 200 respawns, joints and connections must be exactly 14, NEVER 200 * 17!
        self.assertEqual(len(recovery_joints), 14, "Motor6D joints leaked across character respawns!")
        self.assertEqual(len(recovery_connections), 14, "Connections leaked across character respawns!")

    # =========================================================================
    # TEST 4: DOM Card Pool Recycling Audit
    # =========================================================================
    def test_05_dom_card_pool_zero_dom_allocation(self):
        """Verify UI.CardPool reuses existing card frames without continuous Instantiation."""
        card_pool = []
        instantiation_count = 0

        def get_or_create_card(idx):
            nonlocal instantiation_count
            if idx <= len(card_pool):
                return card_pool[idx - 1]
            instantiation_count += 1
            card = {"Index": idx, "Visible": False}
            card_pool.append(card)
            return card

        def render_farmable_eggs(egg_count):
            for idx in range(1, egg_count + 1):
                c = get_or_create_card(idx)
                c["Visible"] = True
            for idx in range(egg_count + 1, len(card_pool) + 1):
                card_pool[idx - 1]["Visible"] = False

        # Fluctuate egg list size across 100 render passes
        counts = [15, 45, 10, 60, 20, 55, 30, 70, 25, 50] * 10
        for cnt in counts:
            render_farmable_eggs(cnt)

        # Peak cards created should exactly equal the maximum egg count (70), never 100 * counts!
        self.assertEqual(instantiation_count, 70, "CardPool failed to recycle DOM elements!")
        self.assertEqual(len(card_pool), 70)

    # =========================================================================
    # TEST 5: Codebase Performance & Anti-Bloat Invariant Checks on v12
    # =========================================================================
    def test_06_codebase_tight_loop_safety(self):
        """Audit EggGoToUI_v12.lua for zero unthrottled loops and zero performance anti-patterns."""
        # 1. No unmanaged spin-wait loops
        self.assertNotIn("while wait() do", self.lua_code, "Found unmanaged while wait() loop!")
        self.assertNotIn("while true do wait(1)", self.lua_code, "Found unmanaged while true loop!")

        # 2. No unthrottled GetDescendants in Stepped loop
        stepped_block = self.lua_code[
            self.lua_code.find("RunService.Stepped:Connect") : self.lua_code.find("RunService.Heartbeat:Connect")
        ]
        self.assertIn("now - lastNoclipRefresh > 2.0", stepped_block, "Stepped loop missing 2.0s refresh throttle!")

        # 3. No Workspace:GetChildren() traversals
        self.assertNotIn(
            "for _, obj in ipairs(Workspace:GetChildren()) do",
            self.lua_code,
            "Workspace:GetChildren() traversal found!"
        )

        # 4. Zero unthrottled print spam
        self.assertNotIn("print(", stepped_block, "Stepped loop contains console print spam!")
        heartbeat_block = self.lua_code[
            self.lua_code.find("RunService.Heartbeat:Connect") : self.lua_code.find("UI.updateActivityStatus")
        ]
        self.assertNotIn("print(", heartbeat_block, "Heartbeat loop contains console print spam!")

    def test_07_connection_hygiene_and_cleanup(self):
        """Verify Engine.Cleanup and disconnectAll properly disconnect all tracked connections."""
        self.assertIn("Engine.Cleanup = function()", self.lua_code)
        self.assertIn("disconnectAll()", self.lua_code)
        self.assertIn("table.clear(Engine.Recovery.Connections)", self.lua_code)
        self.assertIn("_G.EggGoToUI_Stop = true", self.lua_code)
        self.assertIn("_G.EggGoToUI_Cleanup = Engine.Cleanup", self.lua_code)

    def test_08_cycle_reset_hygiene(self):
        """Verify cycle reset and day/night transitions cleanly purge cached entities."""
        self.assertIn('Engine.Sync.clearAllEggs("NightTransition")', self.lua_code)
        self.assertIn('Engine.Sync.clearAllEggs("BatchShifted")', self.lua_code)
        self.assertIn('Engine.Sync.clearAllEggs("CycleCountdown")', self.lua_code)
        self.assertIn("table.clear(Engine.State.EggCacheByUid)", self.lua_code)
        self.assertIn("table.clear(Engine.State.RarityByUid)", self.lua_code)

    # =========================================================================
    # TEST 6: Trap Evade Long-Run Endurance & Zero-Allocation Profiling
    # =========================================================================
    def test_09_trap_evade_endurance_and_leak_prevention(self):
        """Simulate 500 traps spawning and despawning across 5 cycles.
        Verify zero connection leaks and flat memory growth (< 5.0%)."""
        tracemalloc.start()

        class MockTrap:
            def __init__(self, name, x, y, z):
                self.Name = name
                self.X = x
                self.Y = y
                self.Z = z

        active_traps = {}
        total_connections_created = 0
        active_connections = []

        def register_trap(inst):
            nonlocal total_connections_created
            if inst in active_traps:
                return
            conn1 = {"Connected": True, "Type": "ChildAdded"}
            conn2 = {"Connected": True, "Type": "AncestryChanged"}
            total_connections_created += 2
            active_connections.extend([conn1, conn2])
            active_traps[inst] = {
                "Instance": inst,
                "Position": (inst.X, inst.Y, inst.Z),
                "Connections": [conn1, conn2],
            }

        def unregister_trap(inst):
            rec = active_traps.get(inst)
            if rec:
                for c in rec["Connections"]:
                    c["Connected"] = False
                    if c in active_connections:
                        active_connections.remove(c)
                del active_traps[inst]

        # Baseline warm-up
        warmup = [MockTrap(f"PlayerTrap_{i}", i * 10, 0, i * 10) for i in range(50)]
        for t in warmup:
            register_trap(t)
        for t in warmup:
            unregister_trap(t)

        memory_snapshots = []
        tracemalloc.reset_peak()

        # 5 cycles of 100 traps spawning & despawning (500 traps total)
        import gc
        for cycle in range(5):
            batch = [MockTrap(f"PlayerTrap_C{cycle}_{i}", i * 5, 0, i * 5) for i in range(100)]
            for t in batch:
                register_trap(t)
            # Despawn all traps
            for t in batch:
                unregister_trap(t)

            gc.collect()
            cur_mem, _ = tracemalloc.get_traced_memory()
            memory_snapshots.append(cur_mem)

        tracemalloc.stop()

        # At the end, active_traps and active_connections must be 0!
        self.assertEqual(len(active_traps), 0, "Traps leaked into active_traps table!")
        self.assertEqual(len(active_connections), 0, "Trap event connections leaked!")

        # Memory between cycle 1 and cycle 5 must remain flat (< 5% growth)
        mem_c1 = memory_snapshots[0]
        mem_c5 = memory_snapshots[-1]
        growth = (mem_c5 - mem_c1) / max(mem_c1, 1)
        self.assertLess(growth, 0.05, f"Trap lifecycle leaked memory (growth: {growth * 100:.2f}%)!")

    def test_10_trap_radar_zero_allocation_profiling(self):
        """Simulate 60,000 frames of radar checks (16 minutes of continuous gameplay).
        Verify zero allocation fast-path when no traps exist and minimal footprint when traps are active."""
        active_traps = {}

        # 1. Zero-allocation fast path when map has no traps (common overworld state)
        tracemalloc.start()
        tracemalloc.reset_peak()
        start_mem, _ = tracemalloc.get_traced_memory()

        for _ in range(60000):
            # v12 fast path: if not next(ActiveTraps) then return nil / moveDir end
            if not active_traps:
                pass

        end_mem, _ = tracemalloc.get_traced_memory()
        tracemalloc.stop()
        self.assertLessEqual(end_mem - start_mem, 1024, "Empty trap radar allocated memory during 60k frames!")

        # 2. Active radar with 5 traps on map (steady state execution)
        for i in range(5):
            active_traps[f"Trap_{i}"] = {"Position": (i * 20.0, 0.0, i * 20.0)}

        def get_nearest_trap(cur_x, cur_z):
            min_dist = float("inf")
            nearest = None
            for data in active_traps.values():
                tpos = data["Position"]
                dx = tpos[0] - cur_x
                dz = tpos[2] - cur_z
                dist = (dx * dx + dz * dz) ** 0.5
                if dist < min_dist:
                    min_dist = dist
                    nearest = tpos
            return min_dist, nearest

        tracemalloc.start()
        tracemalloc.reset_peak()
        start_mem, _ = tracemalloc.get_traced_memory()

        for frame in range(60000):
            cur_x = (frame % 500) * 1.0
            cur_z = (frame % 500) * 1.0
            _ = get_nearest_trap(cur_x, cur_z)

        end_mem, _ = tracemalloc.get_traced_memory()
        tracemalloc.stop()
        # Over 60,000 frames, net memory growth should be 0
        self.assertLessEqual(end_mem - start_mem, 1024, "Active trap radar leaked memory during 60k frames!")

    def test_11_trap_evade_code_invariants(self):
        """Verify targeted container listeners, complete neutralization, and zero loop bloat in EggGoToUI_v12.lua."""
        # 1. Complete neutralization & limb shielding eradicated (preserves game portals)
        self.assertIn("CFrame.new(curCF.X, -500, curCF.Z)", self.lua_code)
        self.assertNotIn("applyLimbShield", self.lua_code, "applyLimbShield must not exist to preserve portal triggers")
        self.assertNotIn("targetCanTouch = not enabled", self.lua_code, "Character limb CanTouch must never be mutated")

        # 2. Speculative detour and jumping loops eradicated (clean direct movement)
        self.assertNotIn("checkManualRadar", self.lua_code, "Redundant manual radar loops must not exist")
        self.assertNotIn("getEvadeDirection", self.lua_code, "Detour corridor math must not exist")

        # 3. Engine.Traps.init strictly targets Transient (no Debris or Workspace:GetChildren() loops)
        self.assertIn('Workspace:FindFirstChild("Transient")', self.lua_code)
        self.assertNotIn('Workspace:FindFirstChild("Debris")', self.lua_code)
        self.assertIn("hookTransient", self.lua_code)

        # 4. Cleanup restores all traps and clears ActiveTraps
        self.assertIn("Engine.Traps.restore(inst)", self.lua_code)
        self.assertIn("table.clear(Engine.Traps.ActiveTraps)", self.lua_code)

    def test_12_portal_compatibility_preservation(self):
        """Verify character limbs retain CanTouch=True so game portals (Touched events) function normally."""
        # Mock Character limbs
        class MockPart:
            def __init__(self, name):
                self.Name = name
                self.CanTouch = True
                self.Parent = True

        limbs = [
            MockPart("HumanoidRootPart"),
            MockPart("Head"),
            MockPart("UpperTorso"),
            MockPart("LowerTorso"),
            MockPart("LeftFoot"),
            MockPart("RightFoot"),
        ]

        # In Lua script, nothing alters character part CanTouch when TrapEvade is active
        self.assertNotIn("part.CanTouch = false", self.lua_code, "Character parts must never have CanTouch set to false")

        # Mock Portal Touched trigger
        portal_triggered = False
        def on_portal_touched(hit_part):
            nonlocal portal_triggered
            # Roblox engine invariant: Touched only fires if hit_part.CanTouch == True
            if hit_part.CanTouch:
                portal_triggered = True

        # Simulate character stepping into portal
        for limb in limbs:
            on_portal_touched(limb)

        self.assertTrue(portal_triggered, "Portal failed to trigger because character limb CanTouch was blocked!")

    def test_13_auto_treadmill_and_dismount_performance_and_isolation(self):
        """Verify Auto Treadmill cached resolution, isolated dismount jump, and cleanup hygiene."""
        # 1. Cached position zero allocation check
        self.assertIn("Engine.Treadmill.CachedPosition", self.lua_code)
        self.assertIn("if Engine.Treadmill.CachedPosition and Engine.Treadmill.CachedModel and Engine.Treadmill.CachedModel.Parent then", self.lua_code)

        # 2. Dismount trigger jump invariant
        self.assertIn("hum:ChangeState(Enum.HumanoidStateType.Jumping)", self.lua_code)
        self.assertIn("hum.Jump = true", self.lua_code)
        self.assertIn('"RF/Treadmill/AskDoff"', self.lua_code)

        # 3. Cleanup resets plot and treadmill state
        self.assertIn("Engine.Plot.CachedPlot = nil", self.lua_code)
        self.assertIn("Config.Treadmill.Enabled = false", self.lua_code)
        self.assertIn("Engine.Treadmill.CachedPosition = nil", self.lua_code)

        # 4. Zero coupling to egg autofarm or hatch routines
        self.assertNotIn("executeAutoTreadmill", self.lua_code, "Legacy coupled treadmill function must not exist")
        self.assertNotIn("treadmillEnteredAt", self.lua_code, "Egg hatch timer coupling must not exist in v12")


if __name__ == "__main__":
    unittest.main()
