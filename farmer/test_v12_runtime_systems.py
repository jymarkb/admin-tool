#!/usr/bin/env python3
"""
Comprehensive Unit Test Suite for farmer/EggGoToUI_v12.lua:
Verifies the 5 runtime subsystems reported by user:
  1. Egg detection & display (syncAreaEggSlotsESP, ChildAdded, isFarmableEgg, safe sort)
  2. Instant Recovery (ToggleRecoveryBtn, clearRagdollAttributes, Motor6D joint lock, RagdollEndTime)
  3. Velocity Engine (Heartbeat velocity injection, dual-speed WalkSpeed sync, WASD & target dir)
  4. No-Clip (ToggleNoclipBtn, Stepped loop CanCollide = false, instant refresh)
  5. Fast Pick Up (E key listener, non-blocking carry bursts, SmartPromptPart targeting)
  6. Zero Unassigned UI.Elements reads & root locals budget <= 30.
"""

import re
import unittest

class TestV12RuntimeSystems(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        with open("farmer/EggGoToUI_v12.lua", "r") as f:
            cls.code = f.read()

    def test_01_egg_detection_and_display(self):
        """Verify egg detection handles Models & BaseParts, PreparedSourceName, and safe distance sort."""
        self.assertIn("Engine.Sync.syncAreaEggSlotsESP", self.code)
        # Handles both BasePart and Model
        self.assertIn('child:IsA("BasePart")', self.code)
        self.assertIn('child:IsA("Model")', self.code)
        # Sets State = "Slot"
        self.assertIn('State = "Slot"', self.code)
        # Parses PreparedSourceName
        self.assertIn('rawSrc:match("([^%.]+)$")', self.code)
        # Hooks ChildAdded on AreaEggSlotsClient
        self.assertIn('slotsContainer.ChildAdded:Connect', self.code)
        # Default State fallback in isFarmableEgg
        self.assertIn('tostring(r.State or "Slot")', self.code)
        # Safe distance sort
        self.assertIn('(a.Distance or 99999) < (b.Distance or 99999)', self.code)
        # Immediate sync on startup
        self.assertIn('pcall(Engine.Sync.syncAreaEggSlotsESP)', self.code)

    def test_02_instant_recovery_system(self):
        """Verify Instant Recovery toggle button, joint locking, attributes & Humanoid states."""
        self.assertIn('UI.Elements.ToggleRecoveryBtn = testRecBtn', self.code)
        self.assertIn('UI.Elements.ToggleRecoveryBtn.MouseButton1Click:Connect', self.code)
        self.assertIn('Engine.Recovery.clearRagdollAttributes', self.code)
        self.assertIn('"RagdollEndTime"', self.code)
        self.assertIn('"IsRagdoll"', self.code)
        self.assertIn('"Ragdolled"', self.code)
        self.assertIn('hum:ChangeState(Enum.HumanoidStateType.Running)', self.code)
        self.assertIn('Helpers.enablePlayerControls()', self.code)
        self.assertIn('char:GetAttributeChangedSignal("RagdollEndTime")', self.code)
        self.assertIn('LocalPlayer:GetAttributeChangedSignal("RagdollEndTime")', self.code)

    def test_03_velocity_engine(self):
        """Verify Heartbeat velocity physics injects target speed and updates WalkSpeed."""
        self.assertIn('RunService.Heartbeat:Connect', self.code)
        self.assertIn('Engine.Velocity.updatePhysics()', self.code)
        self.assertIn('hrp.AssemblyLinearVelocity = Vector3.new', self.code)
        self.assertIn('hum.WalkSpeed = targetSpeed', self.code)
        self.assertIn('Engine.State.ActiveWalkTarget', self.code)

    def test_04_noclip_system(self):
        """Verify No-Clip button toggle, Stepped loop, and CanCollide disabling."""
        self.assertIn('UI.Elements.ToggleNoclipBtn.MouseButton1Click:Connect', self.code)
        self.assertIn('RunService.Stepped:Connect', self.code)
        self.assertIn('p.CanCollide = false', self.code)
        self.assertIn('not (firstPart and firstPart.Parent)', self.code)

    def test_05_fast_pickup_system(self):
        """Verify E key listener, non-blocking carry bursts, and SmartPromptPart targeting."""
        self.assertIn('input.KeyCode == Enum.KeyCode.E', self.code)
        self.assertIn('Engine.Pickup.startAutoPickupSpam()', self.code)
        # Non-blocking parallel bursts via task.spawn
        self.assertIn('task.spawn(function()', self.code)
        self.assertIn('pcall(function() return rf:InvokeServer(payload) end)', self.code)
        # Direct targeting of SmartPromptPart without laggy Workspace:GetDescendants()
        self.assertIn('Workspace:FindFirstChild("SmartPromptPart")', self.code)

    def test_06_no_unassigned_ui_elements_or_runtime_syntax_crashes(self):
        """Verify every UI.Elements access was assigned, avoiding fatal nil index crashes."""
        assigned = set(re.findall(r'UI\.Elements\.([a-zA-Z0-9_]+)\s*=', self.code))
        read = set(re.findall(r'UI\.Elements\.([a-zA-Z0-9_]+)', self.code)) - assigned
        self.assertEqual(len(read), 0, f"Unassigned UI.Elements read detected: {read}")
        self.assertNotIn("UI.Elements.CopyJsonBtn", self.code, "Dead UI.Elements.CopyJsonBtn must not exist!")
        self.assertNotIn("UI.Elements.SearchBox", self.code, "SearchBox must be removed!")
        self.assertNotIn("UI.Elements.ClearSearchBtn", self.code, "ClearSearchBtn must be removed!")
        self.assertNotIn("UI.Elements.CountLabel", self.code, "CountLabel must be removed!")
        self.assertNotIn("UI.Elements.DropdownOverlay", self.code, "DropdownOverlay must be removed!")
        self.assertNotIn('Name = "SearchBar"', self.code, "SearchBar frame must be removed!")

    def test_07_root_locals_budget(self):
        """Verify root locals count remains <= 30 (budget limit 190)."""
        root_locals = [
            l.strip() for l in self.code.splitlines()
            if re.match(r"^local\s+([a-zA-Z0-9_, ]+)", l)
        ]
        self.assertLessEqual(len(root_locals), 30, f"Expected <= 30 root locals, got {len(root_locals)}")

    def test_08_instant_recovery_zero_wait_and_speed_restoration(self):
        """Verify Instant Recovery restores WalkSpeed, has Heartbeat safety net, and handles metamethod hooks."""
        # WalkSpeed restoration on recovery
        self.assertIn('hum.WalkSpeed = targetSpeed', self.code)
        self.assertIn('hum.WalkSpeed = math.max(Engine.State.SavedWalkSpeed or 16.0, 16.0)', self.code)
        # Heartbeat safety net
        self.assertIn('RunService.Heartbeat:Connect', self.code)
        self.assertIn('Engine.Recovery.execute("RagdollTimer")', self.code)
        self.assertIn('Engine.Recovery.execute("PlatSit")', self.code)
        # Metamethod zero-wait hooks
        self.assertIn('Engine.Recovery.installHooks', self.code)
        self.assertIn('hookmetamethod(game, "__namecall"', self.code)
        self.assertIn('hookmetamethod(game, "__newindex"', self.code)
        # Neutralize carried egg mass
        self.assertIn('Engine.Recovery.neutraliseCarriedEggMass', self.code)
        self.assertIn('desc.Massless = true', self.code)

    def test_09_speed_velocity_reset_on_drop_hit_trap(self):
        """Verify speed velocity logic is a dual-speed engine parameterized by isCarry without bloated Workspace scanning."""
        # Dual-speed engine with isCarry parameter
        self.assertIn('Engine.Velocity.setCarry = function(isCarry)', self.code)
        self.assertIn('Engine.State.IsCarry = carryBool', self.code)
        self.assertIn('targetSpeed = Engine.State.IsCarry and Engine.State.BaseCarrySpeed or Engine.State.BaseGoSpeed', self.code)
        # Ensure no bloated Workspace or Tool scanning inside Velocity Engine
        vel_def = self.code.split('Engine.Velocity = {}')[1].split('Engine.Recovery = {')[0]
        self.assertNotIn('cra:FindFirstChild', vel_def)
        self.assertNotIn('child:IsA("Tool")', vel_def)
        self.assertNotIn('c:IsA("Tool")', vel_def)
        # Specific CarryUid drop monitor without blind CRA ChildAdded scan
        self.assertIn('child.Name == expName', self.code)
        self.assertNotIn('cra.ChildAdded', self.code)
        # Travel drop/delivery/safezone return methods defined
        self.assertIn('Engine.Travel.startReturnTrip = function()', self.code)
        self.assertIn('Engine.Travel.handleEggDropped = function(u, payload)', self.code)
        self.assertIn('Engine.Travel.handleEggDelivered = function(uid)', self.code)
        # Recovery execute and travel reset carry state on bump/hit/trap/drop
        self.assertIn('Engine.Velocity.setCarry(false)', self.code)

    def test_10_startup_variables_and_manual_drop_unblocked(self):
        """Verify startup variables are set on script start and manual drop is never blocked by recovery hooks."""
        # myUidStr and GuiService initialized at root on startup
        self.assertIn('local myUidStr = tostring(LocalPlayer and LocalPlayer.UserId or "")', self.code)
        self.assertIn('local GuiService        = game:GetService("GuiService")', self.code)
        # Helpers.getNetRemote has RemoteCache to avoid repetitive descendant scanning
        self.assertIn('Helpers.RemoteCache = {}', self.code)
        self.assertIn('if Helpers.RemoteCache[name] then return Helpers.RemoteCache[name] end', self.code)
        # BodyJointNames restricts Motor6D recovery strictly to character limbs
        self.assertIn('BodyJointNames', self.code)
        self.assertIn('Config.Recovery.BodyJointNames[self.Name]', self.code)
        # Ensure arbitrary Motor6Ds (like carried egg joints or grips) are NOT blocked when disabled
        newindex_block = self.code.split('oldNewIndex = hookmetamethod(game, "__newindex"')[1].split('return oldNewIndex(self, key, value)')[0]
        self.assertIn('if Config.Recovery.BodyJointNames[self.Name] then', newindex_block)
        # Ensure DescendantAdded does not hook registerMotor to prevent locking carried eggs
        bind_char_block = self.code.split('Engine.Recovery.bindCharacter = function(char)')[1].split('local stateConn = hum.StateChanged')[0]
        self.assertNotIn('DescendantAdded:Connect(registerMotor)', bind_char_block)
        # Ensure AskFieldEggDrop is not intercepted in __namecall
        namecall_block = self.code.split('oldNamecall = hookmetamethod(game, "__namecall"')[1].split('return oldNamecall(self, ...)')[0]
        self.assertNotIn('AskFieldEggDrop', namecall_block)
        # Ensure OwnerDropped is hooked to immediately register drops
        self.assertIn('connectRemote("RE/EggWorld/OwnerDropped"', self.code)

    def test_11_single_character_declaration_and_feet_animation_hygiene(self):
        """Verify Character is declared once at top level and feet animation is protected against getup/slam distortion."""
        # Declared once on startup and updated on lifecycle events
        self.assertIn('local Character = LocalPlayer and LocalPlayer.Character', self.code)
        self.assertIn('Character = newChar', self.code)
        self.assertIn('Character = nil', self.code)
        # Ensure redundant LocalPlayer and LocalPlayer.Character or local ch/char are not used inside functions
        self.assertEqual(self.code.count('local ch = LocalPlayer and LocalPlayer.Character'), 0)
        self.assertEqual(self.code.count('local char = LocalPlayer and LocalPlayer.Character'), 0)
        self.assertEqual(self.code.count('local ch = Character'), 0)
        self.assertEqual(self.code.count('local char = Character'), 0)
        # Ankle and knee joints excluded from BodyJointNames to preserve foot IK
        body_joints_block = self.code.split('BodyJointNames  = {')[1].split('}')[0]
        self.assertNotIn('"LeftAnkle"', body_joints_block)
        self.assertNotIn('"RightAnkle"', body_joints_block)
        self.assertNotIn('"LeftKnee"', body_joints_block)
        self.assertNotIn('"RightKnee"', body_joints_block)
        # Lingering getup/fall/ragdoll animation tracks stopped cleanly
        self.assertIn('animName:find("getup")', self.code)
        self.assertIn('track:Stop(0.05)', self.code)
        # Anti-fling braking and fast grounding on boss/player hit (from v10)
        self.assertIn('hrp.AssemblyLinearVelocity = Vector3.new(0, fastY, 0)', self.code)
        self.assertIn('fastY = -45', self.code)
        self.assertIn('timeSinceHit < 0.5', self.code)
        self.assertNotIn('math.clamp(curVel.Y', self.code)
        self.assertNotIn('math.clamp(vy', self.code)
        self.assertIn('hrp.AssemblyAngularVelocity = Vector3.zero', self.code)
        self.assertIn('Engine.Travel.stopWalking()', self.code)

    def test_12_night_reset_clears_all_eggs(self):
        """Verify farmable egg list is cleared cleanly on night reset and stale eggs are purged."""
        # 1. Engine.Sync.clearAllEggs exists and clears EggCacheByUid
        self.assertIn('Engine.Sync.clearAllEggs = function(reason)', self.code)
        self.assertIn('table.clear(Engine.State.EggCacheByUid)', self.code)
        self.assertIn('table.clear(Engine.State.RarityByUid)', self.code)
        # 2. AreaEggSlotsClient ChildRemoved listener to delete despawned slots
        self.assertIn('slotsContainer.ChildRemoved:Connect', self.code)
        # 3. FieldEggCycleCountdown hooked to trigger clearAllEggs
        self.assertIn('RE/EggWorld/FieldEggCycleCountdown', self.code)
        # 4. FieldEggBatchShifted triggers clearAllEggs before receiving new wave
        self.assertIn('Engine.Sync.clearAllEggs("BatchShifted")', self.code)
        # 5. Lighting day-to-night transition triggers clearAllEggs
        self.assertIn('Engine.Sync.clearAllEggs("NightTransition")', self.code)
        # 6. syncEggSnapshot purges stale eggs without shielding State == "Slot"
        self.assertNotIn('State ~= "Slot"', self.code)

    def test_13_top_level_character_parts_and_void_death_resilience(self):
        """Verify Humanoid and RootPart are top-level and void death is handled cleanly."""
        # Top level declaration
        self.assertIn('local Humanoid  = Character and Character:FindFirstChildOfClass("Humanoid")', self.code)
        self.assertIn('local RootPart  = Character and Character:FindFirstChild("HumanoidRootPart")', self.code)
        # Helper isAlive method
        self.assertIn('Helpers.isAlive = function()', self.code)
        # Void death signal listeners (h.Died and r.AncestryChanged)
        self.assertIn('h.Died:Connect', self.code)
        self.assertIn('r.AncestryChanged:Connect', self.code)
        # Falling into void coordinate guard in physics & travel
        self.assertIn('hrp.Position.Y < -400', self.code)
        # Zero repeated FindFirstChild("HumanoidRootPart") inside functions
        self.assertLessEqual(self.code.count('FindFirstChild("HumanoidRootPart")'), 2)

    def test_14_travel_clean_up_and_60_stud_teleport_snap(self):
        """Verify reusable teleportTo function, 60-stud snap on walk, and velocity-independent walk."""
        # Reusable teleportTo function exists with snapBeside support for large eggs
        self.assertIn('Engine.Travel.teleportTo = function(targetPos', self.code)
        self.assertIn('snapBeside', self.code)
        # teleportToEgg delegates to Engine.Travel.teleportTo
        self.assertIn('Engine.Travel.teleportTo(itemData.Position', self.code)
        # Reach assist delegates to Engine.Travel.teleportTo
        self.assertIn('Engine.Travel.teleportTo(targetPos', self.code)
        # TargetSnapDist configured to 60.0 studs
        self.assertIn('TargetSnapDist    = 60.0', self.code)
        # walkToTarget has 60 studs snap teleport
        self.assertIn('if dist <= snapDist or dist <= arriveDist then', self.code)
        self.assertIn('Engine.Travel.teleportTo(targetPos', self.code)
        # Walk still works when VelocityEnabled is off (hum:Move and hum:MoveTo)
        self.assertIn('hum:MoveTo(targetPos)', self.code)
        self.assertIn('not Engine.State.VelocityEnabled and hum.WalkSpeed < 16.0', self.code)
        # Delivery speed reset
        self.assertIn('hum.WalkSpeed = resetSpeed', self.code)
        # Trap recovery enables GettingUp and jumps
        self.assertIn('hum:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)', self.code)
        self.assertIn('hum.Jump = true', self.code)

    def test_15_instant_auto_return_to_safezone_on_pickup(self):
        """Verify walkToEgg primes auto-return state and egg pickup instantly launches return trip to SafeZone."""
        # 1. walkToEgg primes AutoReturnActive, target UID, resets ReturnTripInProgress, unequips tools
        walk_block = self.code.split('Engine.Travel.walkToEgg = function(itemData)')[1].split('Engine.Travel.startReturnTrip = function()')[0]
        self.assertIn('Engine.State.AutoReturnActive = true', walk_block)
        self.assertIn('Engine.State.AutoReturnTargetUid = itemData.Uid', walk_block)
        self.assertIn('Engine.State.ReturnTripInProgress = false', walk_block)
        self.assertIn('hum:UnequipTools()', walk_block)
        self.assertIn('Engine.Travel.stopWalking()', walk_block)

        # 2. carryEgg has onCarried callback and immediately triggers startReturnTrip when carry succeeds
        carry_block = self.code.split('Engine.Pickup.carryEgg = function(uid, burstCount, onCarried)')[1].split('Engine.Pickup.startAutoPickupSpam = function()')[0]
        self.assertIn('if onCarried then task.spawn(onCarried) end', carry_block)
        self.assertIn('Engine.State.AutoReturnActive and not Engine.State.ReturnTripInProgress', carry_block)
        self.assertIn('Engine.Travel.startReturnTrip()', carry_block)

        # 3. setCarry immediately triggers startReturnTrip via task.spawn if AutoReturnActive
        set_carry_block = self.code.split('Engine.Velocity.setCarry = function(isCarry)')[1].split('Engine.Velocity.setCarryingState = function(carrying)')[0]
        self.assertIn('carryBool and Engine.State.AutoReturnActive and not Engine.State.ReturnTripInProgress', set_carry_block)
        self.assertIn('task.spawn(Engine.Travel.startReturnTrip)', set_carry_block)

        # 4. FieldEggShifted triggers startReturnTrip on state == "Carried"
        self.assertIn('Engine.State.AutoReturnActive and not Engine.State.ReturnTripInProgress', self.code)

        # 5. Inventory eggs must not trigger carry speed: no tool ChildAdded hooking
        self.assertNotIn('newChar.ChildAdded:Connect', self.code)

        # 6. Watchdog fallback in 0.3s throttled loop ensures return trip runs
        loop_block = self.code.split('Engine.Loops.start = function()')[1].split('Engine.Loops.start')[0] if 'Engine.Loops.start' in self.code else self.code
        self.assertIn('Engine.State.AutoReturnActive and (Engine.State.IsCarry or Engine.State.WeAreCarrying) and not Engine.State.ReturnTripInProgress', loop_block)

        # 7. Q key cancels AutoReturnActive and resets AutoReturnTargetUid
        q_block = self.code.split('input.KeyCode == Enum.KeyCode.Q')[1].split('end\nend))')[0]
        self.assertIn('Engine.State.AutoReturnActive = false', q_block)
        self.assertIn('Engine.State.AutoReturnTargetUid = nil', q_block)
        self.assertIn('Engine.State.ReturnTripInProgress = false', q_block)

    def test_16_speed_velocity_carry_persistence_and_other_player_isolation(self):
        """Verify speed velocity does NOT swap to go speed when other players claim/drop eggs or during non-drop recoveries."""
        # Other player drops/claims must NOT falsely reset our carry state
        shifted_block = self.code.split('connectRemote("RE/EggWorld/FieldEggShifted"')[1].split('connectRemote("RE/EggWorld/FieldEggGone"')[0]
        self.assertNotIn('or Engine.State.IsCarry) then', shifted_block)
        self.assertIn('(state == "Claimed" or state == "Dropped") and (Engine.State.CarryUid == u or (payload.CarrierUserId and tostring(payload.CarrierUserId) == myUidStr))', shifted_block)

        # Other player OwnerDropped must NOT falsely reset our carry state
        owner_drop_block = self.code.split('connectRemote("RE/EggWorld/OwnerDropped"')[1].split('connectRemote')[0] if 'connectRemote' in self.code.split('connectRemote("RE/EggWorld/OwnerDropped"')[1] else self.code.split('connectRemote("RE/EggWorld/OwnerDropped"')[1]
        self.assertNotIn('or Engine.State.IsCarry\n', owner_drop_block)

        # Helpers.isHoldingEgg inspects physical hold (equipped tool/model or ClientRenderedAssets proximity)
        self.assertIn('Helpers.isHoldingEgg = function()', self.code)
        self.assertIn('myUidStr .. "_" .. tostring(Engine.State.CarryUid)', self.code)

        # Engine.Velocity.updatePhysics syncs carry state with Helpers.isHoldingEgg
        self.assertIn('Helpers.isHoldingEgg and Helpers.isHoldingEgg()', self.code)
        self.assertIn('Engine.Velocity.setCarry(true)', self.code)

        # Engine.Recovery.execute does NOT blindly clear carry state if egg is still held
        recovery_exec = self.code.split('Engine.Recovery.execute = function(reason)')[1].split('Engine.Recovery.installHooks')[0]
        self.assertIn('local stillHolding = Helpers.isHoldingEgg and Helpers.isHoldingEgg()', recovery_exec)
        self.assertIn('if not stillHolding then', recovery_exec)

    def test_17_instant_recovery_zero_wait_base_logic_alignment(self):
        """Verify instant recovery base logic aligns with instant-ragdoll-recovery.lua: zero debounce, motor health check, R15 hips, and slam dampener."""
        # 1. Zero debounce window prevents dropping consecutive stuns
        self.assertIn('DebounceWindow  = 0', self.code)

        # 2. R15 hip joints included in BodyJointNames
        body_joints = self.code.split('BodyJointNames  = {')[1].split('}')[0]
        self.assertIn('["LeftHip"]', body_joints)
        self.assertIn('["RightHip"]', body_joints)

        # 3. Heartbeat checks disabled motors in Engine.Recovery.Joints
        self.assertIn('for _, m in ipairs(Engine.Recovery.Joints) do', self.code)
        self.assertIn('m.Enabled = true', self.code)

        # 4. Humanoid state and posture checked directly on Heartbeat
        self.assertIn('hum.PlatformStand or hum.Sit', self.code)
        self.assertIn('s == Enum.HumanoidStateType.Ragdoll', self.code)

        # 5. Anti-fling braking on hit from v10 preserves position at bump location
        self.assertIn('hrp.AssemblyLinearVelocity = Vector3.new(0, fastY, 0)', self.code)
        self.assertIn('fastY = -45', self.code)
        self.assertIn('timeSinceHit < 0.5', self.code)

        # 6. Zero artificial falling down slow & zero vertical clamping (no math.clamp on Y velocity)
        self.assertNotIn('math.clamp(curVel.Y', self.code)
        self.assertNotIn('math.clamp(vy', self.code)

    def test_18_world1_safezone_delivery_speed_reset(self):
        """Verify delivery of an egg to SafeZone in World 1 properly resets speed to BaseGoSpeed / SavedWalkSpeed."""
        # 1. Delivery grace period in Engine.State
        self.assertIn('DeliveryGraceUntil', self.code)
        self.assertIn('LastDeliveredUid', self.code)

        # 2. handleEggDelivered enforces grace period, sets carry to false, and restores speed
        deliv_block = self.code.split('Engine.Travel.handleEggDelivered = function(uid)')[1].split('Engine.Travel.getEggPosition')[0]
        self.assertIn('Engine.State.DeliveryGraceUntil = os.clock() + 1.5', deliv_block)
        self.assertIn('Engine.Velocity.setCarry(false)', deliv_block)
        self.assertIn('hum.WalkSpeed = resetSpeed', deliv_block)
        self.assertIn('Engine.State.AutoReturnActive = false', deliv_block)
        self.assertIn('Engine.State.ReturnTripInProgress = false', deliv_block)

        # 3. startReturnTrip invokes handleEggDelivered upon arriving at SafeZone
        return_trip = self.code.split('Engine.Travel.startReturnTrip = function()')[1].split('Engine.Travel.handleEggDropped')[0]
        self.assertIn('Engine.Travel.handleEggDelivered(delivUid)', return_trip)

        # 4. Helpers.isHoldingEgg respects DeliveryGraceUntil and excludes SafeZone nest eggs
        holding_block = self.code.split('Helpers.isHoldingEgg = function()')[1].split('Helpers.applyReachAssist')[0]
        self.assertIn('Engine.State.DeliveryGraceUntil', holding_block)
        self.assertIn('inSafeZone', holding_block)
        self.assertNotIn('if Engine.State and Engine.State.IsCarry then return true end', holding_block)

        # 5. Engine.Velocity.updatePhysics clears carry state when physical holding ceases
        physics_block = self.code.split('Engine.Velocity.updatePhysics = function(isCarry)')[1].split('Engine.Recovery = {')[0]
        self.assertIn('Engine.Velocity.setCarry(false)', physics_block)
        self.assertIn('targetSpeed = Engine.State.IsCarry and Engine.State.BaseCarrySpeed or Engine.State.BaseGoSpeed', physics_block)

        # 6. FieldEggShifted Claimed state calls handleEggDelivered even if AutoReturnActive was cleared
        shifted_block = self.code.split('connectRemote("RE/EggWorld/FieldEggShifted"')[1].split('connectRemote("RE/EggWorld/FieldEggGone"')[0]
        self.assertIn('state == "Claimed"', shifted_block)
        self.assertIn('Engine.Travel.handleEggDelivered(u)', shifted_block)

if __name__ == "__main__":
    unittest.main()
