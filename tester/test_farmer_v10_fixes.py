#!/usr/bin/env python3
"""
Unit Test Suite for farmer/EggGoToUI_v10.lua Surgical Bug Fixes:
1. Issue 1: Butterfly event lag / almost freezes
   - bFolder direct children return without sweeping entire Workspace
   - Non-blocking task.spawn for butterfly swing and swarm remotes
2. Issue 2: Dropped midway stolen egg retargeting
   - updateSlotGhosts clears marks & badUids when resting loose away from nest
   - onEggShifted restores egg in eggCache.byUid when Dropped
   - isGhost allows loose/dropped eggs without being blocked by obsolete badUids
   - pickNearest does not filter out dropped/loose eggs on badUids
   - isCarriedByOther returns false for dropped eggs not actively in CRA
3. Issue 3: Over-time FPS drop / memory leak mitigations
   - Scramble 15s inventory poll gated behind isAutoTradeEnabled or tabScramble.Visible
   - timerBadge.Text updates gated behind tabScramble.Visible
   - detectRubberband throttled to 20 Hz (0.05s) to eliminate per-frame table garbage
   - getRagdollReason avoids calling Workspace:GetServerTimeNow() when RagdollEndTime is 0
   - Periodic pruning of rarityByUid and scanner cleanup of carrierPlayer/missCount
"""

import os
import unittest
import re

TARGET_FILE = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "farmer", "EggGoToUI_v10.lua"))


class TestEggGoToUIV10Fixes(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not os.path.exists(TARGET_FILE):
            raise FileNotFoundError(f"Target file not found at {TARGET_FILE}")
        with open(TARGET_FILE, "r", encoding="utf-8") as f:
            cls.content = f.read()

    def test_issue1_butterfly_direct_folder_and_throttled_scan(self):
        """Verify X.getButterflies returns bFolder children directly and throttles broad Workspace scans."""
        self.assertIn("function X.getButterflies()", self.content)
        # Direct return if bFolder has children
        self.assertRegex(
            self.content,
            r'if\s+#list\s*>\s*0\s*then\s+return\s+list\s+end',
            "X.getButterflies must return list directly if bFolder has children"
        )
        # Throttled fallback check
        self.assertIn("X.lastBroadBfScan", self.content)
        self.assertIn("X.lastBroadBfList", self.content)

    def test_issue1_butterfly_nonblocking_remotes(self):
        """Verify executeAutoButterfly uses non-blocking task.spawn for swing and swarm remotes."""
        # Find executeAutoButterfly definition
        fn_match = re.search(r'function\s+X\.executeAutoButterfly\(cancelCheck\)([\s\S]+?)end\s*\n\s*if\s+hum', self.content)
        self.assertIsNotNone(fn_match, "function X.executeAutoButterfly must be defined")
        body = fn_match.group(1)

        # Must spawn background task for remotes
        self.assertRegex(
            body,
            r'task\.spawn\(function\(\)\s+if\s+rfSwing\s+then[\s\S]+?if\s+rfSwarm\s+then',
            "RemoteFunction invocations in executeAutoButterfly must run in task.spawn"
        )

    def test_issue2_dropped_stolen_egg_retargeting(self):
        """Verify updateSlotGhosts, onEggShifted, isGhost, and pickNearest allow dropped stolen eggs."""
        # 1. updateSlotGhosts: loose egg detection must NOT be blocked by badUids
        self.assertRegex(
            self.content,
            r'elseif\s+not\s+X\.isCarriedByOther\(u\)\s+and\s+\(mine\s+or\s+not\s+hasSlot\)\s+then\s+--\s*Egg was bumped or dropped loose',
            "updateSlotGhosts must not require badUids to be expired to recognize loose eggs"
        )

        # 2. onEggShifted: Dropped event must clear badUids and restore eggCache.byUid
        self.assertRegex(
            self.content,
            r'elseif\s+st\s*==\s*"Dropped"\s*then[\s\S]+?X\.badUids\[u\]\s*=\s*nil[\s\S]+?if\s+eggCache\s+and\s+eggCache\.byUid\s+then',
            "onEggShifted Dropped must clear badUids and update eggCache.byUid"
        )

        # 3. isGhost: loose/dropped eggs must not be blacklisted
        self.assertRegex(
            self.content,
            r'if\s+X\.looseUids\[uid\]\s+or\s+\(r\s+and\s+r\.State\s*==\s*"Dropped"\)\s+then\s+X\.badUids\[uid\]\s*=\s*nil\s+return\s+false\s+end',
            "isGhost must exempt loose or dropped eggs from blacklisting"
        )

        # 4. pickNearest: isLooseOrDropped must bypass badUids
        self.assertIn("local isLooseOrDropped = (r.State == \"Dropped\") or (X.looseUids[u] == true)", self.content)
        self.assertIn("local isBad = (X.badUids[u] and now < X.badUids[u]) and not isLooseOrDropped", self.content)

        # 5. isCarriedByOther: clears stale carrierPlayer for dropped/loose eggs not in CRA
        self.assertRegex(
            self.content,
            r'if\s+\(rec\s+and\s+rec\.State\s*==\s*"Dropped"\)\s+or\s+X\.looseUids\[uStr\]\s+then[\s\S]+?X\.carrierPlayer\[uStr\]\s*=\s*nil\s+return\s+false',
            "isCarriedByOther must clear stale carrierPlayer for dropped/loose eggs"
        )

    def test_issue3_overtime_lag_mitigations(self):
        """Verify performance optimizations preventing over-time FPS drop and memory leaks."""
        # 1. Scramble 15s poll gated behind active auto-trade or visible tab
        self.assertRegex(
            self.content,
            r'if\s+isAutoTradeEnabled\s+or\s+\(tabScramble\s+and\s+tabScramble\.Visible\)\s+then\s+task\.spawn\(function\(\)\s+scanInventoryEggs\(false\)',
            "Scramble 15s inventory scan must be gated by tab visibility or isAutoTradeEnabled"
        )

        # 2. detectRubberband throttled to 20Hz (0.05s)
        self.assertRegex(
            self.content,
            r'if\s+now\s*-\s*\(X\.lastRbCheck\s+or\s+0\)\s*<\s*0\.05\s+then\s+return\s+end\s+X\.lastRbCheck\s*=\s*now',
            "detectRubberband must throttle execution to 0.05s intervals"
        )

        # 3. getRagdollReason checks re > 0 before calling Workspace:GetServerTimeNow()
        self.assertRegex(
            self.content,
            r'if\s+typeof\(re\)\s*==\s*"number"\s+and\s+re\s*>\s*0\s+and\s+re\s*>\s*Workspace:GetServerTimeNow\(\)\s+then',
            "getRagdollReason must check re > 0 before calling GetServerTimeNow"
        )

        # 4. rarityByUid periodic pruning
        self.assertIn("X._scanPruneCount = (X._scanPruneCount or 0) + 1", self.content)
        self.assertIn("for k in pairs(rarityByUid) do", self.content)

        # 5. scanner cleanup of carrierPlayer and missCount
        self.assertIn("for u in pairs(X.carrierPlayer) do if not by[u] then X.carrierPlayer[u] = nil end end", self.content)
        self.assertIn("for u in pairs(X.missCount) do if not by[u] then X.missCount[u] = nil end end", self.content)

    def test_issue4_target_egg_treadmill_dismount(self):
        """Verify auto dismount goes to safe zone to reset placement without setting night reset grace."""
        # 1. autoFarmLoop detects target egg and flags isEggDismount
        self.assertRegex(
            self.content,
            r'local\s+isEggDismount\s*=\s*false[\s\S]+?elseif\s+eggCache\s+and\s+eggCache\.records[\s\S]+?shouldDismount\s*=\s*true\s+isEggDismount\s*=\s*true',
            "eggCache target must set isEggDismount = true"
        )
        # 2. isEggDismount uses executeAutoDismount(true) without setting nightResetGraceUntil
        self.assertRegex(
            self.content,
            r'if\s+isEggDismount\s+then[\s\S]+?X\.executeAutoDismount\(true,[\s\S]+?elseif\s+isButterflyDismount',
            "isEggDismount must call executeAutoDismount(true) and not set night grace"
        )
        # 3. Target egg acquired while on treadmill dismounts and walks to safezone to reset placement
        self.assertRegex(
            self.content,
            r'elseif\s+typeof\(target\)\s*==\s*"table"\s+and\s+not\s+skip\s+then[\s\S]+?if\s+X\.isOnTreadmill\(\)\s+then\s+X\.executeAutoDismount\(true,',
            "target egg branch must call executeAutoDismount(true)"
        )
        # 4. executeAutoDismount defaults andWalkToSafeZone to true
        self.assertRegex(
            self.content,
            r'function\s+X\.executeAutoDismount\(andWalkToSafeZone,\s*cancelCheck\)[\s\S]+?if\s+andWalkToSafeZone\s*==\s*nil\s+then\s+andWalkToSafeZone\s*=\s*true\s+end',
            "executeAutoDismount must default andWalkToSafeZone to true"
        )

    def test_issue5_nonblocking_treadmill_and_dismount_remotes(self):
        """Verify rfDoff and rfWear InvokeServer calls are non-blocking inside task.spawn."""
        # executeAutoDismount rfDoff
        self.assertRegex(
            self.content,
            r'local\s+rfDoff\s*=\s*X\.getNetRemote\("RF/Treadmill/AskDoff"\)\s+if\s+rfDoff\s+then\s+task\.spawn\(function\(\)\s+pcall\(function\(\)\s+rfDoff:InvokeServer\(\)',
            "rfDoff:InvokeServer must be wrapped in task.spawn"
        )
        # executeAutoTreadmill rfWear
        self.assertRegex(
            self.content,
            r'local\s+rfWear\s*=\s*X\.getNetRemote\("RF/Treadmill/AskWearStill"\)\s+if\s+rfWear\s+then\s+task\.spawn\(function\(\)\s+pcall\(function\(\)\s+rfWear:InvokeServer\(\)',
            "rfWear:InvokeServer must be wrapped in task.spawn"
        )

    def test_issue6_scan_placed_eggs_fallback_only(self):
        """Verify Source B RF/ProfileMirror/FetchProfile is only called if #placed == 0."""
        self.assertRegex(
            self.content,
            r'--\s*Source B: RF/ProfileMirror/FetchProfile[^\n]*\n\s*if\s+#placed\s*==\s*0\s+then\s+local\s+rfProfile\s*=\s*X\.getNetRemote\("RF/ProfileMirror/FetchProfile"\)',
            "Source B FetchProfile must be gated behind if #placed == 0 then"
        )

    def test_issue7_scramble_sync_on_delivery_gated(self):
        """Verify delivery Scramble sync is gated by scramble enabled or visible."""
        self.assertRegex(
            self.content,
            r'if\s+X\.autoScrambleTrade\s+or\s+X\.prioritizeScrambleInAutoFarm\s+or\s+\(tabScramble\s+and\s+tabScramble\.Visible\)\s+then\s+task\.spawn\(function\(\)\s+task\.wait\(0\.3\)[\s\S]+?pcall\(X\.scanInventoryEggsForScramble\)',
            "Delivery scramble scan must be gated by active scramble configuration"
        )

    def test_issue8_joints_table_in_get_ragdoll_reason(self):
        """Verify getRagdollReason utilizes pre-indexed X.jointsTable to avoid ch:GetDescendants()."""
        self.assertRegex(
            self.content,
            r'if\s+X\.jointsTable\s+and\s+#X\.jointsTable\s*>\s*0\s+then\s+for\s+_\s*,\s*o\s+in\s+ipairs\(X\.jointsTable\)\s+do[\s\S]+?else\s+local\s+ch\s*=\s*hum\.Parent',
            "getRagdollReason must check X.jointsTable before descending character tree"
        )

    def test_issue9_loop_termination_and_clocktime_guards(self):
        """Verify infinite loops check _G.EggGoToUI_Stop and checkNightReset updates ClockTime."""
        # initAutoHatchMonitor loop
        self.assertRegex(
            self.content,
            r'function\s+X\.initAutoHatchMonitor\(\)[\s\S]+?task\.spawn\(function\(\)\s+while\s+not\s+_G\.EggGoToUI_Stop\s+and\s+screenGui\s+and\s+screenGui\.Parent\s+do',
            "initAutoHatchMonitor must check _G.EggGoToUI_Stop and screenGui.Parent"
        )
        # trap supervisor loops
        self.assertRegex(
            self.content,
            r'while\s+screenGui\s+and\s+screenGui\.Parent\s+and\s+not\s+_G\.EggGoToUI_Stop\s+do\s+task\.wait\(1\.0\)',
            "Trap supervisor loop must check _G.EggGoToUI_Stop"
        )
        # checkNightReset ClockTime update
        self.assertRegex(
            self.content,
            r'if\s+ct\s*>=\s*6\s+and\s+ct\s*<\s*18\s+and\s+X\.isOnTreadmill\(\)\s+then\s+X\.mountedAtClockTime\s*=\s*ct\s+end',
            "checkNightReset must refresh mountedAtClockTime during daytime"
        )

    def test_issue10_safezone_delivery_hold_guard(self):
        """Verify deliverWait waits for isHoldingEgg to clear and autoFarmLoop guards against moving to next egg while holding."""
        # 1. deliverWait checks isHoldingEgg and connects to FieldEggRedeemVerdict
        self.assertRegex(
            self.content,
            r'function\s+X\.deliverWait\(myTok\)[\s\S]+?evRedeem[\s\S]+?stillHeld\s*=\s*isHoldingEgg\(\)\s+or',
            "deliverWait must check isHoldingEgg and connect to redeem events"
        )
        # 2. walkToEgg only finishes true if consumed or not isHoldingEgg
        self.assertRegex(
            self.content,
            r'local\s+consumed\s*=\s*X\.deliverWait\(myTok\)[\s\S]+?if\s+consumed\s+or\s+not\s+isHoldingEgg\(\)\s+then[\s\S]+?finish\(true\)[\s\S]+?else\s+weAreCarrying\s*=\s*true[\s\S]+?finish\(false\)',
            "walkToEgg must not finish true if egg is still held"
        )
        # 3. autoFarmLoop delivers carried egg if weAreCarrying or isHoldingEgg
        self.assertRegex(
            self.content,
            r'if\s+not\s+skip\s+and\s+\(weAreCarrying\s+or\s+isHoldingEgg\(\)\)\s+then',
            "autoFarmLoop must deliver held egg if isHoldingEgg is true"
        )
        # 4. autoFarmLoop target branch guards against targeting next egg while holding
        self.assertRegex(
            self.content,
            r'elseif\s+typeof\(target\)\s*==\s*"table"\s+and\s+not\s+skip\s+then\s+--\s*Safety guard:[^\n]*\s+if\s+isHoldingEgg\(\)\s+then\s+weAreCarrying\s*=\s*true',
            "autoFarmLoop must guard against targeting next egg while isHoldingEgg is true"
        )
        # 5. holdingSource ignores delivered eggs
        self.assertRegex(
            self.content,
            r'if\s+carryUid\s+and\s+not\s+X\.deliveredUids\[carryUid\]\s+and\s+eggCache',
            "holdingSource must ignore delivered eggs"
        )

    def test_issue11_admin_abuse_toggle_and_logic(self):
        """Verify Admin Abuse toggle is in Utility tab, defaults to false, and autoGetEgg teleports directly to egg."""
        # 1. DEFAULT_SETTINGS has AdminAbuse = false
        self.assertRegex(
            self.content,
            r'AdminAbuse\s*=\s*false',
            "DEFAULT_SETTINGS must have AdminAbuse = false"
        )

        # 2. validateSettings validates AdminAbuse boolean
        self.assertRegex(
            self.content,
            r'if\s+t\.AdminAbuse\s*~=\s*nil\s+and\s+typeof\(t\.AdminAbuse\)\s*~=\s*"boolean"\s+then',
            "validateSettings must validate AdminAbuse boolean"
        )

        # 3. Table X initializes adminAbuseEnabled
        self.assertRegex(
            self.content,
            r'adminAbuseEnabled\s*=\s*DEFAULT_SETTINGS\.AdminAbuse\s+or\s+false',
            "Table X must initialize adminAbuseEnabled"
        )

        # 4. applySettings syncs AdminAbuse
        self.assertRegex(
            self.content,
            r'if\s+t\.AdminAbuse\s*~=\s*nil\s+then\s+X\.adminAbuseEnabled\s*=\s*t\.AdminAbuse\s+end[\s\S]+?currentSettings\.AdminAbuse\s*=\s*X\.adminAbuseEnabled\s*==\s*true[\s\S]+?if\s+typeof\(X\.syncAdminAbuseUI\)\s*==\s*"function"\s+then\s+pcall\(X\.syncAdminAbuseUI\)\s+end',
            "applySettings must update X.adminAbuseEnabled and invoke X.syncAdminAbuseUI"
        )

        # 5. Tab 4 Utility row 8 layout and toggle
        self.assertRegex(
            self.content,
            r'rowAdminAbuse\.LayoutOrder\s*=\s*8[\s\S]+?rowAdminAbuse\.Parent\s*=\s*tabUtility[\s\S]+?lblAdminAbuse\.Text\s*=\s*"Admin Abuse"[\s\S]+?X\.syncAdminAbuseUI\s*=\s*updateAdminAbuseButtonState',
            "Utility tab must include Row 8 for Admin Abuse with LayoutOrder = 8"
        )

        # 6. autoGetEgg uses instant teleport only when shouldTp (useTp and adminAbuseEnabled) is true
        self.assertRegex(
            self.content,
            r'local\s+function\s+autoGetEgg\(uid,\s*startPos,\s*myTok,\s*isManual,\s*useTp\)[\s\S]+?local\s+shouldTp\s*=\s*\(useTp\s*==\s*true\)\s+and\s+\(X\.adminAbuseEnabled\s*==\s*true\)[\s\S]+?if\s+shouldTp\s+then[\s\S]+?X\.markTeleport\(\)[\s\S]+?getBesideOffset\(livePos,\s*hrp\.Position,\s*2\.5\)[\s\S]+?task\.spawn\(onEggArrived\)[\s\S]+?else\s+walkTo\(function\(\)\s+return\s+livePos\s+end,\s*6,\s*walkTok,\s*onEggArrived',
            "autoGetEgg must teleport directly only when shouldTp is true, otherwise walkTo"
        )

        # 7. X.tpToEgg defined and calls autoGetEgg with useTp = true
        self.assertRegex(
            self.content,
            r'function\s+X\.tpToEgg\(pos,\s*uid,\s*sl\)[\s\S]+?autoGetEgg\(uid,\s*pos,\s*myTok,\s*true,\s*true\)',
            "X.tpToEgg must call autoGetEgg with isManual = true and useTp = true"
        )

        # 8. Farm list cards include TP button beside Get button with Admin Abuse check
        self.assertRegex(
            self.content,
            r'local\s+tb\s*=\s*Instance\.new\("TextButton"\)[\s\S]+?tb\.Text\s*=\s*"TP"[\s\S]+?tb\.Parent\s*=\s*card[\s\S]+?local\s+gb\s*=\s*Instance\.new\("TextButton"\)[\s\S]+?item\s*=\s*\{[^}]*gb\s*=\s*gb,\s*tb\s*=\s*tb[^}]*\}',
            "Farm list card must include a TP button beside Get button"
        )
        self.assertRegex(
            self.content,
            r'tb\.MouseButton1Click:Connect\(function\(\)[\s\S]+?if\s+not\s+X\.adminAbuseEnabled\s+then[\s\S]+?X\.tpToEgg\(targetPos,\s*item\.uid,\s*statusLabel\)',
            "Clicking TP button must verify X.adminAbuseEnabled and trigger X.tpToEgg"
        )

    def test_issue12_dropped_egg_bump_retry_and_treadmill_guard(self):
        """Verify dropped eggs survive boss bumps without false removal or premature treadmill routing."""
        # 1. autoFarmLoop does NOT clear dropRetry on failed autoGetEgg unless stolen
        self.assertRegex(
            self.content,
            r'else\s+--\s*Cancel dropRetry ONLY if egg was stolen or placed in player base plot\s+local\s+isStolenNow\s*=\s*X\.isCarriedByOther\(uid\)\s+or\s+X\.isEggInBaseRenders\(uid\)\s+if\s+isStolenNow\s+then\s+dropRetry\s*=\s*nil\s+X\.weDropped\[uid\]\s*=\s*nil\s+X\.looseUids\[uid\]\s*=\s*nil\s+end\s+if\s+dropRetry\s+and\s+dropRetry\.uid\s*==\s*uid\s+then',
            "autoFarmLoop must preserve dropRetry on drop unless stolen"
        )

        # 2. autoFarmLoop retargets dropped egg with 300s timeout and 9999 retries for top rarities
        self.assertRegex(
            self.content,
            r'local\s+maxRetries\s*=\s*isTop\s+and\s+9999\s+or\s+\(currentSettings\.MaxBumpRetries\s+or\s+8\)\s+local\s+maxTimeout\s*=\s*isTop\s+and\s+300\s+or\s+60',
            "autoFarmLoop must use top rarity retries and timeout for dropped eggs"
        )

        # 3. autoFarmLoop recovers target from records and Workspace.Eggs / WorldEggs
        self.assertRegex(
            self.content,
            r'for\s+_\s*,\s*fName\s+in\s+ipairs\(\{"Eggs",\s*"WorldEggs"\}\)\s+do\s+local\s+folder\s*=\s*Workspace:FindFirstChild\(fName\)',
            "autoFarmLoop must search Eggs/WorldEggs if dropped target is missing from cache"
        )

        # 4. autoFarmLoop blocks treadmill routing when dropRetry is active
        self.assertRegex(
            self.content,
            r'elseif\s+X\.autoTreadmillEnabled\s+then\s+if\s+dropRetry\s+and\s+dropRetry\.uid\s+then\s+X\.noEggSince\s*=\s*nil\s+statusLabel\.Text\s*=\s*"\[AutoFarm\] Retrying dropped egg\.\.\."',
            "autoFarmLoop must block treadmill routing while dropRetry is active"
        )

        # 5. autoGetEgg pickup failure preserves our dropped eggs without blacklisting or false delivery
        self.assertRegex(
            self.content,
            r'local\s+isOurDropped\s*=\s*\(dropRetry\s+and\s+dropRetry\.uid\s*==\s*uid\)[\s\S]+?elseif\s+isOurDropped\s+then\s+lastFailReason\s*=\s*tag\s*\.\.\s*"Pickup retry[\s\S]+?X\.looseUids\[uid\]\s*=\s*true\s+X\.badUids\[uid\]\s*=\s*nil\s+X\.deliveredUids\[uid\]\s*=\s*nil',
            "autoGetEgg pickup failure must preserve our dropped eggs"
        )

        # 6. isGhost exempts weDropped and dropRetry before checking deliveredUids
        self.assertRegex(
            self.content,
            r'if\s+\(dropRetry\s+and\s+dropRetry\.uid\s*==\s*uid\)\s+or\s+\(X\.weDropped\[uid\]\s+and\s+os\.clock\(\)\s*-\s*X\.weDropped\[uid\]\s*<\s*180\)\s+then\s+X\.badUids\[uid\]\s*=\s*nil\s+X\.deliveredUids\[uid\]\s*=\s*nil\s+return\s+false\s+end\s+if\s+X\.deliveredUids\[uid\]\s+then',
            "isGhost must exempt our dropped eggs before checking deliveredUids"
        )


if __name__ == "__main__":
    unittest.main()

