--[[
    Egg Go-To UI v8  (= v7 + the three fixes listed under CHANGES v8 at the bottom of this comment)
    Egg Go-To UI v7 — All-Eggs List + Multi-Select Farm + Search + JSON Config + Recovery + Velocity
    -------------------------------------------------------------------------------------------
    - Farm dropdown lists ALL known eggs (pre-populated from PET_RARITY_PRESETS,
      extended at runtime from snapshot discoveries).
    - Multi-select checkboxes — tick every species you want to farm. "All" shows everything.
    - Search box at the top of the Farm dropdown filters species in real time.
    - JSON config textbox: exports/imports SafeZone, MutationFilter, SpeciesFilter
      (array), AutoReturn, Velocity, VelocityValue, Recovery. Copy / Load buttons.
    - Full recovery system: ragdoll detect -> snap to lastGoodCFrame -> anchor ->
      re-enable motors -> GetUp (StateChanged + Heartbeat).
    - Velocity system with frictionless parts, egg physics neutralisation,
      auto-pause/resume across ragdoll.
    - Fixed walkTo dead-code bug (SLOW_ZONE=25 > TELEPORT_ZONE=6).

    CHANGES v8
    1) Safe zone: arrival is checked BEFORE the ragdoll pause in walkTo; a separate watcher in the return trip
       (XZ<=14 = arrived, 50-stud snap onto the zone, also while the walker is paused); an egg that vanishes
       within 22 studs of the zone counts as DELIVERED (it used to be mistaken for a drop); after arriving we
       re-snap onto the zone until the carried object is consumed.
    2) Egg list: every snapshot call runs in its own thread with a timeout (one hung InvokeServer used to freeze
       the 1s scanner for good); a failed redraw is no longer remembered as "up to date"; forced scans right
       after pickup / bump / drop / delivery; the "Config JSON:" line shows scan #, egg count and scan age.
    3) Boss bump: only scans issued AFTER the pickup are judged (a pre-pickup scan made an immediate bump look
       like "nothing changed"); every ragdoll/stun start while carrying triggers an instant fresh scan; on arrival,
       if we were bumped, the field is re-checked and the egg is fetched again if it is still lying there.

    CHANGES v9
    1) Default velocity 260. A rubberband (server pulls us BACK against our move direction while Velocity is on and
       a farm/Get trip is running) lowers the current velocity by 10 (floor 100). It goes back to the value you
       set (default 260) after every finished egg AND whenever a new target egg is started.
    2) Rarity filter (new "Rarity:" dropdown, saved as "RarityFilter" in the JSON). Ticked rarities are ADDED to the
       autofarm list (union with the species filter; with Farm = All the rarity ticks are the only restriction).
       Priority when rarity is active:  Divine -> Eternal -> Secret -> Mythic -> the selected eggs.
       Divine/Eternal/Secret/Mythic eggs that are at least as rare as your lowest ticked rarity are picked up
       automatically, and if one spawns while walking to a lesser egg (before pickup) the farm switches to it.

    CHANGES v9.1  (empty / stolen nests are no longer treated as "still there")
    - FieldEggGone / FieldEggCarry events for an egg WE are not carrying hide that egg from the list and the farm
      right away (until a scan stops listing it), instead of waiting for the next 1s scan.
    - An egg whose client slot (AreaEggSlotsClient) existed and then vanished is hidden too.
    - Walking to an egg: the tracker aborts at once on those signals; on ARRIVAL a fresh scan re-checks the nest
      before any pickup attempt ("Nest already empty").
    - A pickup no longer counts as success from a "gone" event alone (another player taking the egg fires the same
      event) and a scan only proves a pickup if the egg was still listed when we asked. A refused pickup re-checks the
      nest with a fresh scan and stops retrying if the egg is gone.
    - Every empty / stolen / failed nest is blacklisted for a while so the farm moves on instead of retrying it.

    CHANGES v9.2  (the snapshot keeps listing eggs that are already gone -> cross-check it against the real world)
    - Every scan compares the snapshot with the client slots (AreaEggSlotsClient), PER AREA. If an area's slots are
      clearly populated (>=60% of its eggs have one, min 3 eggs) then an egg with NO slot for 2 scans in a row is a
      ghost: hidden from the list and never targeted. The list summary shows "N empty hidden".
    - A refused pickup is remembered: 1st failure 25s, 2nd 3 min, 3rd until a scan stops listing that egg. The block
      is only lifted when the egg leaves the snapshot (so a stale entry can no longer come back every 20 seconds).
    - If the server's refusal text says not found / taken / gone the nest is dropped at once (no 4 retries).
    - If the nest has no slot on arrival the farm tries only twice instead of four times.
    - Console prints "[EggGoToUI] ghost egg ..." when one is detected, and a one-time slot coverage line per area, so
      it is easy to see what the game actually exposes.

    CHANGES v9.3  (fix: the ghost checks broke "pick the dropped egg up again")
    - A dropped egg lies on the ground with no nest slot, which v9.1/v9.2 mistook for "empty / stolen nest": the
      re-fetch after a bump / boss hit / player hit was aborted and the egg blacklisted. Now an egg we drop is marked
      LOOSE at once, and any egg whose position moved away from its nest (or between scans) is loose too. Loose
      eggs are never hidden by the slot checks, never aborted on a missing slot, and get the full 4 pickup tries.
    - Only real signals still hide a loose egg: another player's Gone/Carry event, or the server refusing the pickup.
    - The rubberband detector ignores the 1.5s after any ragdoll/hit (was 1.0s) so knockback is not counted.

    CHANGES v9.4  (fix: a dropped egg (boss bump / player hit) was still flagged "stolen / empty" while lying on the field)
    - ROOT CAUSE 1: every scan wiped the LOOSE / nest / last-position memory of an egg the snapshot did not list. A carried
      egg is usually unlisted, so when it was dropped and re-listed it had lost its "loose" mark, had no slot, and the slot
      cross-check called it a ghost after 2 scans. Now an egg that vanished from the snapshot and comes back is treated as
      LOOSE at once, and its gone / blacklist / fail / ghost marks are cleared.
    - ROOT CAUSE 2: Gone/Carry events that arrive late for an egg we just dropped were counted as "taken by someone else".
      Events for an egg we drop are now ignored for 10s (X.ignoreGone).
    - A Gone/Carry mark is lifted when the egg was listed at a new place and then rests there (lying on the ground), which
      also fixes eggs dropped by OTHER players while the snapshot keeps listing carried eggs.
    - Re-fetching a dropped egg tolerates 4 missing scans (was 2) before giving up.

    CHANGES v9.5  (another player carries the egg, gets bumped / drops it: back in the nest OR somewhere else = pickable)
    - A "taken" mark (Gone/Carry event, stolen, blacklist) is no longer permanent. It is lifted when: the egg moved away
      (>4 studs) and now rests anywhere, even in another biome; the egg's nest slot vanished and came back; the game fires
      a spawn/added/drop/release/return event for that egg; or the mark simply gets old (Gone marks 25s; "stolen" blacklist
      60s -> 4 min -> until unlisted, so a truly stale ghost still stops costing trips).
    - "Gone" marks now carry a timestamp check (X.goneActive) instead of being checked as a plain true/false.

    CHANGES v9.6  (velocity default 270 + rubberband detector that actually triggers)
    - Default velocity is now 270 (was 260). Every rubberband lowers the CURRENT velocity by 10 (floor 100); it returns to
      270 (or whatever you typed) when the egg is delivered, when a trip finishes / fails, and when a new target starts.
    - The detector used to look at ONE frame only and needed an 8-stud backwards jump; a server pull spread over several
      frames (or a smaller pull) was never seen. Now it watches BOTH: a single-frame backwards jump (>= 6 studs) and the net
      progress over the last ~0.6s (moving backwards >= 12 studs while we push forward). Cooldown 0.5s (was 0.8s) so a
      series of pulls lowers the speed step by step.
    - The velocity line shows "RB n" (rubberbands counted) and the console prints each one with the old/new velocity.

    CHANGES v9.7  (eggs lying on the field are listed + rubberband detection that does not depend on MoveDirection)
    1) An egg with NO nest slot that never moved (already lying on the field when the script started, or dropped by someone
       else earlier) was hidden as a "ghost" after 2 scans. Missing-slot evidence is weak, so it no longer hides anything:
       such eggs are listed and farmed, just AFTER every egg that has proof (slot / loose). Only real signals still hide an
       egg: a Gone/Carry event, a refused pickup, or a blacklist. "N unverified" shows in the list summary and the console
       prints why an egg is hidden ("[EggGoToUI] hidden ... reason").
       On arrival the nest check no longer aborts on a missing slot (a dropped egg has none); the pickup try limit stays 2.
    2) Rubberband: the direction is now taken from MoveDirection, or (if that is zero) from our own recent movement, and
       the check works on the deviation from where our velocity says we should be (a server pull-back in ANY frame, also
       right after our own snaps once the 0.35s grace has passed). Ragdoll grace is 0.8s (was 1.5s). Near-misses are
       logged to the console so a threshold that is too high can be seen.

    CHANGES v9.8  (an egg another player already took / delivered stayed in the list)
    - v9.7 stopped hiding eggs on weak evidence, but that also stopped hiding stolen ones. Real "taken" evidence is back:
        * the Gone/Carry mark now lasts 5 min (was 25s) and is only lifted by proof it is back (slot returns, it rests
          somewhere else, it is re-listed after vanishing, or a reappear event);
        * an egg whose nest slot VANISHED (it had one before) and stays gone 4s is hidden again;
        * an egg that MOVES between scans is being carried by someone: hidden until it rests;
        * an egg that rests within 30 studs of the delivery zone (SAFE_ZONE) after moving, or any slot-less egg within
          15 studs of it, is treated as DELIVERED and hidden.
    - An egg is only "lying loose" (pickable) once it has RESTED 2 scans away from where it was, not the instant it moves.
      (Before, a carried egg that the snapshot kept updating was marked loose and could never be hidden.)
    - An egg we dropped ourselves is exempt from the carried/delivered rules for 60s.
    - Hidden eggs are still just "no slot, never seen" = shown, farmed last (v9.7).

    CHANGES v9.9  (rubberband detector: also catches a SLOW-DOWN, not only a snap back)
    - Every earlier version only looked for the character being moved BACKWARDS. A server that drags us a few studs back
      EVERY frame (or clamps our speed) never moves us backwards - we just crawl - so nothing was ever counted.
      New check: the real speed over the last ~0.45s is compared with the speed we had a moment ago (best of the
      previous 3s). If it collapses below 50% while we keep pushing in the same direction, nothing is in front of us
      (a ray checks for walls / players) and we were really moving before, it counts as a rubberband. It only fires
      right after we were at speed, so a steady limit (carrying, slopes) never keeps lowering the velocity.
    - The snap-back checks stay (one-frame jump, deviation, net drift), and the turn check is back (reversing direction
      is not a rubberband).
    - The velocity line shows the measured speed ("spd 268") or "RB off" when the detector is not watching (Velocity off,
      or no farm / Get trip running), so you can see immediately whether it is armed.
]]

local ok, err = pcall(function()

-- Terminate any previous running instance of this script
if _G.EggGoToUI_Cleanup then
    pcall(_G.EggGoToUI_Cleanup)
end
_G.EggGoToUI_Stop = false

local Players           = game:GetService("Players")
local Workspace         = game:GetService("Workspace")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService       = game:GetService("HttpService")
local RunService        = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    pcall(function() LocalPlayer = Players:GetPropertyChangedSignal("LocalPlayer"):Wait() or Players.LocalPlayer end)
    LocalPlayer = LocalPlayer or Players.LocalPlayer
end

local function getSafeUiParent()
    if typeof(gethui) == "function" then
        local ok, h = pcall(gethui)
        if ok and h then return h end
    end
    local okCore, core = pcall(function() return game:GetService("CoreGui") end)
    if okCore and core then
        local okTest = pcall(function() local f = Instance.new("Folder", core); f:Destroy() end)
        if okTest then return core end
    end
    return (LocalPlayer and (LocalPlayer:FindFirstChild("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui", 5))) or game:GetService("CoreGui")
end
local PlayerGui = getSafeUiParent()

local SAFE_ZONE = Vector3.new(536.731, 70, -368.698)

local MUTATION_COLORS = {
    ["Golden"]  = Color3.fromRGB(220, 180, 30),
    ["Rainbow"] = Color3.fromRGB(180, 80, 220),
    ["Silver"]  = Color3.fromRGB(160, 180, 210),
}
local MUTATION_DEFAULT_COLOR = Color3.fromRGB(100, 200, 255)

local ALL_RARITY_COLORS = {
    ["Common"]    = Color3.fromRGB(170, 170, 170),
    ["Uncommon"]  = Color3.fromRGB(90,  200, 100),
    ["Rare"]      = Color3.fromRGB(50,  120, 220),
    ["Epic"]      = Color3.fromRGB(140, 60,  220),
    ["Legendary"] = Color3.fromRGB(230, 140, 20),
    ["Mythic"]    = Color3.fromRGB(230, 70,  130),
    ["Cosmic"]    = Color3.fromRGB(70,  170, 255),
    ["Secret"]    = Color3.fromRGB(220, 50,  50),
    ["Eternal"]   = Color3.fromRGB(180, 90,  255),
    ["Divine"]    = Color3.fromRGB(255, 190, 70),
    ["Unknown"]   = Color3.fromRGB(120, 120, 130),
}

local HIGHLIGHT_RARITIES = {
    ["Cosmic"] = true, ["Secret"] = true, ["Eternal"] = true, ["Divine"] = true,
}
local RARITY_DEFAULT_COLOR = Color3.fromRGB(200, 200, 200)

local PET_RARITY_PRESETS = {
    ["Chicken"]="Common", ["Dog"]="Common", ["Bird"]="Uncommon",
    ["Owl"]="Rare", ["Raccoon"]="Rare", ["Bear"]="Epic", ["Fox"]="Epic",
    ["Brr Brr Patapim"]="Legendary", ["Frog"]="Common", ["Duckling"]="Common",
    ["Catfish"]="Uncommon", ["Turtle"]="Rare", ["Trulimero Trulicina"]="Epic",
    ["Swan"]="Epic", ["Axolotl"]="Legendary", ["Leviathan"]="Cosmic",
    ["Jerboa"]="Common", ["Fennec"]="Uncommon", ["Camel"]="Rare",
    ["Tob Tobi Tob Tob"]="Epic", ["Snake"]="Legendary", ["Scorpion"]="Mythic",
    ["Sand Spider"]="Mythic", ["Royal Sphinx"]="Cosmic", ["Toucan"]="Rare",
    ["Chimpanzee"]="Rare", ["Crocodile"]="Epic", ["Gorilla"]="Legendary",
    ["Orangutini Ananassini"]="Legendary", ["Spider"]="Mythic", ["Tiger"]="Mythic",
    ["King Snake"]="Secret", ["Penguin"]="Rare", ["Walrus"]="Epic",
    ["Polar Bear"]="Legendary", ["Sabertooth Tiger"]="Mythic", ["Mammoth"]="Mythic",
    ["King Mammoth"]="Cosmic", ["Yeti"]="Secret", ["Ice Dragon"]="Eternal",
    ["Lava Gecko"]="Rare", ["Lava Frog"]="Epic", ["Flaming Bull"]="Legendary",
    ["Lava Iguana"]="Legendary", ["Chillin Chilli"]="Mythic", ["Cerberus"]="Secret",
    ["Phoenix"]="Eternal", ["Lava Dragon"]="Eternal", ["Parrotfish"]="Rare",
    ["Swordfish"]="Epic", ["Shark"]="Legendary", ["Orca"]="Mythic",
    ["Whale Shark"]="Cosmic", ["Beluga Whale"]="Cosmic", ["Kraken"]="Secret",
    ["El Maja"]="Eternal", ["Dodo"]="Rare", ["Pterodactyl"]="Legendary",
    ["Ankylosaurus"]="Mythic", ["Triceratops"]="Cosmic", ["Bronto"]="Cosmic",
    ["Tralaledon"]="Secret", ["T-Rex"]="Secret", ["Mosasaurus"]="Eternal",
    ["Centapede"]="Epic", ["Galaxy Gecko"]="Legendary", ["Cyclops Gorilla"]="Mythic",
    ["La Vacca Saturno Saturnita"]="Cosmic", ["Cosmic Dragon"]="Secret",
    ["Cosmic Skeleton Boss"]="Secret", ["Eternal Lunar Dragon"]="Eternal",
    ["Unicorn"]="Divine", ["Crane"]="Epic", ["Salamander"]="Legendary",
    ["Red Panda"]="Mythic", ["Koi"]="Cosmic", ["Snowy Owl"]="Cosmic",
    ["Stag"]="Secret", ["Oni Tiger"]="Eternal", ["Kitsune"]="Divine",
    ["Crab"]="Legendary", ["Kaiju Spider"]="Legendary", ["Blade Head"]="Mythic", ["Mantis"] = "Cosmic",
    ["Mantaris"]="Cosmic", ["Rhino"]="Cosmic", ["Shark"]="Secret",
    ["Gorilla King"]="Eternal", ["Nightflame"]="Divine", ["Dove"]="Legendary",
    ["Lamb"]="Mythic", ["Moth"]="Cosmic", ["Peacock"]="Cosmic",
    ["Pure Jellyfish"]="Secret", ["Centaur"]="Secret", ["Pegasus"]="Eternal",
    ["ArchAngel"]="Divine", ["Flame Sprite"]="Legendary", ["Toro"]="Mythic",
    ["Imp"]="Cosmic", ["Demon Hound"]="Cosmic", ["Gargoyle"]="Secret",
    ["RazorFang"]="Secret", ["Skeleton Horse"]="Eternal", ["World Burner"]="Divine",
    ["Equinox"]="Eternal", ["Aetheron"]="Divine",
    ["Baby Aurora Dragon"]="Legendary", ["Shadow Dragon"]="Mythic",
    ["Scorched Dragon"]="Secret", ["Drilla"]="Cosmic",
    ["Abyss Overlord"]="Secret", ["Void Dragon"]="Eternal",
    ["Ember Dragon"]="Secret", ["Nibbles #013"]="Cosmic",
    ["Experiment #001"]="Secret", ["Rift Eye"]="Legendary",
    ["Void Angler"]="Legendary", ["Riftwing"]="Mythic",
    ["Shardling"]="Mythic", ["Voidmaw"]="Mythic",
    ["Dreadclaw"]="Cosmic", ["Shattered Ram"]="Cosmic",
    ["Ventinal"]="Cosmic", ["Mawbreaker"]="Secret",
    ["Shardwing"]="Secret", ["Wendigo"]="Secret",
    ["Shattered Drake"]="Eternal", ["Void Serpent"]="Eternal",
    ["World Eater"]="Eternal", ["Shattered Colossus"]="Divine",
    ["Tung Tung Sahur"]="Rare", ["Bananita Dolphinita"]="Epic",
    ["Belula Beluga"]="Mythic", ["Mangolini Parrochini"]="Cosmic",
    ["Bomboclat Crocolat"]="Secret", ["Strawberry Elephant"]="Eternal",
    ["Scorpio"]="Legendary", ["Froggo"]="Mythic", ["Crawler"]="Cosmic",
    ["Crocodon"]="Secret", ["Krakenoid"]="Eternal", ["Dreadscale"]="Divine",
    ["Mecha Scorpio"]="Legendary", ["Mecha Froggo"]="Mythic",
    ["Mecha Crawler"]="Cosmic", ["Mecha Crocodon"]="Secret",
    ["Mecha Krakenoid"]="Eternal", ["Mecha Dreadscale"]="Divine",
    ["Spike"]="Legendary", ["Spirit Manta"]="Mythic", ["Abyss Shark"]="Cosmic",
    ["Electric Eel"]="Secret", ["Terra Snapper"]="Eternal", ["Cthulhu"]="Divine",
    ["Luminous Spike"]="Legendary", ["Luminous Spirit Manta"]="Mythic",
    ["Luminous Abyss Shark"]="Cosmic", ["Luminous Electric Eel"]="Secret",
    ["Luminous Terra Snapper"]="Eternal", ["Luminous Cthulhu"]="Divine",
}

-- ==================================================
-- SETTINGS (no more presets, no rarity filter)
-- ==================================================
local DEFAULT_SETTINGS = {
    SafeZone       = { X = SAFE_ZONE.X, Y = SAFE_ZONE.Y, Z = SAFE_ZONE.Z },
    MutationFilter = {},
    SpeciesFilter  = { "All" },
    RarityFilter   = {},
    AutoReturn     = true,
    Velocity       = false,
    VelocityValue  = 300,
    CarryVelocityValue = 250,
    Recovery       = true,
}

local activeMutationFilter = {}
local selectedSpecies     = { ["All"] = true }   -- set
local autoReturnEnabled   = true
local currentSettings     = nil

local speciesOrder = { "All" }
local speciesSeen  = { ["All"] = true }
local lastFetchedRecords = nil

local function deepCopy(t)
    if typeof(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = deepCopy(v) end
    return c
end

currentSettings = deepCopy(DEFAULT_SETTINGS)

-- Pre-populate species from PET_RARITY_PRESETS
do
    local names = {}
    for n in pairs(PET_RARITY_PRESETS) do table.insert(names, n) end
    table.sort(names)
    for _, n in ipairs(names) do
        if not speciesSeen[n] then
            speciesSeen[n] = true
            table.insert(speciesOrder, n)
        end
    end
end

local function settingsToJSON(s)
    local ok, j = pcall(function() return HttpService:JSONEncode(s) end)
    return ok and j or nil
end

local function validateSettings(t)
    if typeof(t) ~= "table" then return false, "root is not a JSON object" end
    if t.SafeZone ~= nil then
        if typeof(t.SafeZone) ~= "table"
            or typeof(t.SafeZone.X) ~= "number"
            or typeof(t.SafeZone.Y) ~= "number"
            or typeof(t.SafeZone.Z) ~= "number" then
            return false, "SafeZone must be {X,Y,Z} numbers"
        end
    end
    if t.MutationFilter ~= nil and typeof(t.MutationFilter) ~= "table" then
        return false, "MutationFilter must be an array"
    end
    if t.SpeciesFilter ~= nil and typeof(t.SpeciesFilter) ~= "table" then
        return false, "SpeciesFilter must be an array of species names"
    end
    if t.RarityFilter ~= nil and typeof(t.RarityFilter) ~= "table" then
        return false, "RarityFilter must be an array of rarity names"
    end
    if t.AutoReturn ~= nil and typeof(t.AutoReturn) ~= "boolean" then
        return false, "AutoReturn must be true/false"
    end
    if t.Velocity ~= nil and typeof(t.Velocity) ~= "boolean" then
        return false, "Velocity must be true/false"
    end
    if t.VelocityValue ~= nil and typeof(t.VelocityValue) ~= "number" then
        return false, "VelocityValue must be a number"
    end
    if t.CarryVelocityValue ~= nil and typeof(t.CarryVelocityValue) ~= "number" then
        return false, "CarryVelocityValue must be a number"
    end
    if t.Recovery ~= nil and typeof(t.Recovery) ~= "boolean" then
        return false, "Recovery must be true/false"
    end
    return true
end

-- ==================================================
-- VELOCITY / RECOVERY STATE
-- ==================================================
local velocityEnabled = false
local targetVelocity  = 300
local savedWalkSpeed  = 16
local zeroFriction    = PhysicalProperties.new(0.7, 0, 0, 100, 100)
local originalPhysicalProperties = {}
local weAreCarrying   = false

local recoveryEnabled = true
local recoveryActive  = false
local RECOVERY_STATE = { NONE="NONE", RAGDOLLED="RAGDOLLED", RECOVERING="RECOVERING" }
local recoveryState     = RECOVERY_STATE.NONE
local lastGoodCFrame    = nil
local lastMoveDirection = Vector3.zero
local isRagdolled       = false
local ragdollSince       = nil     -- when the current ragdoll-like reason first appeared
local ragdollStale       = false   -- reason has lasted too long -> treat as a false positive
local lastRagdollReason  = nil
local RAGDOLL_STALE_AFTER = 2.5    -- a real hit-ragdoll ends well before this

-- v8 shared state + helpers live in ONE table (this script is close to Luau's 200-locals-per-function limit).
local X = {
    ragdollEpoch          = 0,     -- +1 on every ragdoll/stun START (boss bump): lets the carry trip notice hits it missed
    lastRagdollAt         = 0,
    snapHidesCarried      = nil,   -- learned: the field snapshot stops listing an egg while we carry it
    listDirty             = false, -- force the egg list to redraw on the next scan
    scanIssue             = 0,     -- scan request counter (drops out-of-order replies)
    scanApplied           = 0,
    scanBusySince         = nil,
    lastForceAt           = 0,
    SCAN_TIMEOUT          = 4,     -- a hung snapshot call is abandoned after this many seconds
    SCAN_HANG_AFTER       = 2.5,   -- the scanner starts a parallel scan if one has been in flight this long
    SAFE_DETECT_RADIUS    = 14,    -- watcher: XZ studs that count as "in the safe zone"
    SAFE_DELIVERED_RADIUS = 22,    -- an egg that vanishes this close to the zone was DELIVERED, not dropped
}
local wasRagdolledForVelocity = false
local RAGDOLL_HOLD_TIME = 0.12

-- v9 state + helpers (kept in X because the script is close to Luau's 200-locals limit)
X.baseVelocity      = 300    -- travel speed (going to egg). targetVelocity = this minus rubberband drops
X.baseCarryVelocity = 250    -- carry speed (returning with egg). X.switchToCarry() activates it.
X.VELOCITY_STEP    = 10      -- every rubberband lowers the velocity by this much...
X.MIN_VELOCITY     = 100     -- ...but never below this
X.RUBBER_BACK      = 6       -- studs pulled BACKWARDS in a single frame (against our move direction) = rubberband
X.rbLastPos        = nil
X.rbLastDir        = nil
X.rbCooldownUntil  = 0       -- one rubberband can span several frames: count it once
X.rbSamples        = {}      -- v9.6: recent {t, pos} samples for the windowed (multi-frame) detection
X.RUBBER_WINDOW    = 0.6     -- seconds of history
X.RUBBER_NET_BACK  = 12      -- net studs moved BACKWARDS over the window = rubberband
X.ignoreJumpUntil  = 0       -- our own teleports/snaps must never be mistaken for a rubberband
X.tripUntil        = 0       -- manual "Get" trip window (autofarm is checked separately)
X.rubberCount      = 0
X.selectedRarities = {}      -- set of ticked rarities (empty = rarity filter off)
X.RARITY_RANK  = { Common=1, Uncommon=2, Rare=3, Epic=4, Legendary=5, Mythic=6, Cosmic=7, Secret=8, Eternal=9, Divine=10 }
X.RARITY_ORDER = { "Divine", "Eternal", "Secret", "Cosmic", "Mythic", "Legendary", "Epic", "Rare", "Uncommon", "Common" }
X.PRIORITY_CHAIN = { "Divine", "Eternal", "Secret" }
X.ROW_H = 28
X.ROW_GAP = 4
X.ROW3_Y = 8 + (28 + 4) * 2
X.MAX_FARM_DD_HEIGHT = 200

local upVelBtn, upRecBtn   -- farm order: Divine -> Eternal -> Secret -> selected (farthest)

function X.markTeleport() X.ignoreJumpUntil = os.clock() + 0.35; X.rbLastPos = nil; X.rbSamples = {} end

-- back to TRAVEL speed (called after every egg, new target, drop, or delivery)
function X.resetVelocity()
    if weAreCarrying or (typeof(isHoldingEgg) == "function" and isHoldingEgg()) or (X.isHoldingEgg and X.isHoldingEgg()) then
        targetVelocity = X.baseCarryVelocity
    else
        targetVelocity = X.baseVelocity
    end
    if velocityEnabled then
        local ch = LocalPlayer.Character
        local h  = ch and ch:FindFirstChildOfClass("Humanoid")
        if h then pcall(function() h.WalkSpeed = targetVelocity end) end
    end
    if upVelBtn then pcall(upVelBtn) end
end

-- switch to CARRY speed right after a confirmed pickup (return trip)
function X.switchToCarry()
    targetVelocity = X.baseCarryVelocity
    if velocityEnabled then
        local ch = LocalPlayer.Character
        local h  = ch and ch:FindFirstChildOfClass("Humanoid")
        if h then pcall(function() h.WalkSpeed = targetVelocity end) end
    end
    if upVelBtn then pcall(upVelBtn) end
end

local connections = {}
local rarityConn = nil
local stateChangedConn = nil

local function addConnection(c) table.insert(connections, c); return c end
local function disconnectAll()
    for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
    table.clear(connections)
    if rarityConn then pcall(function() rarityConn:Disconnect() end); rarityConn = nil end
    if stateChangedConn then pcall(function() stateChangedConn:Disconnect() end); stateChangedConn = nil end
end

-- ==================================================
-- PHYSICS / FRICTION / EGG
-- ==================================================
local function setFrictionless(enable)
    local char = LocalPlayer.Character
    if not char then return end
    for _, d in ipairs(char:GetDescendants()) do
        if d:IsA("BasePart") then
            if enable then
                if originalPhysicalProperties[d] == nil then
                    originalPhysicalProperties[d] = d.CustomPhysicalProperties
                end
                pcall(function() d.CustomPhysicalProperties = zeroFriction end)
            else
                local o = originalPhysicalProperties[d]
                if o ~= nil then pcall(function() d.CustomPhysicalProperties = o end) end
                originalPhysicalProperties[d] = nil
            end
        end
    end
end

-- Carry and Drop state forward declarations (must precede holdingSource, ragdoll updates, and ghost checks)
weAreCarrying = false
local carryUid = nil
local carryMarkers = nil
local dropRetry = nil

-- Forward reference for checking if tracked carry markers are still active
local function markersActiveCheck(m)
    if not m then return false end
    if typeof(m.inst) == "table" then
        for _, e in ipairs(m.inst) do
            if e.inst and e.inst.Parent ~= nil then return true end
            if e.parent and e.parent.Parent and e.parent:FindFirstChild(e.name) then return true end
        end
    end
    if typeof(m.attr) == "table" then
        for _, a in ipairs(m.attr) do
            if a.obj and a.obj.Parent ~= nil then
                local ok, cur = pcall(function() return a.obj:GetAttribute(a.key) end)
                if ok and cur == a.val then return true end
            end
        end
    end
    return false
end

-- Tightened holding check.
--  * Only counts an EQUIPPED egg tool/model on the character (backpack tools no longer count)
--  * In ClientRenderedAssets, ONLY matches if carryUid is known and matches UserId_carryUid,
--    or active carryMarkers from a confirmed pickup are alive.
--    (NEVER match arbitrary ClientRenderedAssets models without carryUid, as nest eggs in the player's base also live in CRA!)
--  * holdingSource() returns what matched, so it can be shown for debugging.
local function holdingSource()
    local char = LocalPlayer.Character
    if char then
        for _, c in ipairs(char:GetChildren()) do
            if (c:IsA("Tool") or c:IsA("Model")) and string.find(string.lower(c.Name), "egg", 1, true) then
                return "char:" .. c.Name
            end
        end
    end
    local cra = Workspace:FindFirstChild("ClientRenderedAssets")
    if cra and carryUid then
        local expectedName = tostring(LocalPlayer.UserId) .. "_" .. tostring(carryUid)
        local m = cra:FindFirstChild(expectedName)
        if m and (m:IsA("BasePart") or m:FindFirstChildWhichIsA("BasePart", true)) then
            return "cra:" .. m.Name
        end
    end
    if carryMarkers and markersActiveCheck(carryMarkers) then
        return "marker:" .. tostring(carryMarkers.label or "active")
    end
    return nil
end

local function isHoldingEgg()
    return holdingSource() ~= nil
end
X.isHoldingEgg = isHoldingEgg

local function neutraliseEggPhysics(char)
    if not char then return end
    for _, d in ipairs(char:GetDescendants()) do
        if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" and d.Parent ~= char then
            pcall(function() d.Massless = true; d.CanCollide = false end)
        end
    end
    local cra = Workspace:FindFirstChild("ClientRenderedAssets")
    if cra then
        for _, m in ipairs(cra:GetChildren()) do
            if string.find(m.Name, tostring(LocalPlayer.UserId)) then
                for _, p in ipairs(m:GetDescendants()) do
                    if p:IsA("BasePart") then pcall(function() p.Massless = true; p.CanCollide = false end) end
                end
            end
        end
    end
end

-- ==================================================
-- RAGDOLL
-- ==================================================
local function getRagdollReason(hum)
    if not hum then return nil end
    local re = LocalPlayer:GetAttribute("RagdollEndTime")
    if typeof(re) == "number" and re > Workspace:GetServerTimeNow() then return "RagdollEnd" end
    local s = hum:GetState()
    if s == Enum.HumanoidStateType.Ragdoll then return "Ragdoll" end
    if s == Enum.HumanoidStateType.FallingDown then return "FallingDown" end
    if s == Enum.HumanoidStateType.Physics then return "Physics" end
    if hum.PlatformStand then return "PlatStand" end
    local ch = hum.Parent
    if ch then
        local dm, tm = 0, 0
        for _, o in ipairs(ch:GetDescendants()) do
            if o:IsA("Motor6D") then tm = tm + 1; if not o.Enabled then dm = dm + 1 end end
        end
        if tm > 0 and dm >= 2 then return "Motors" end
    end
    return nil
end

local function updateRagdollStatus()
    local ch = LocalPlayer.Character
    local h  = ch and ch:FindFirstChildOfClass("Humanoid")
    local r  = ch and ch:FindFirstChild("HumanoidRootPart")
    if not h then isRagdolled = false; ragdollSince = nil; ragdollStale = false; return end
    if not isRagdolled and r then lastGoodCFrame = r.CFrame end
    local reason = getRagdollReason(h)
    lastRagdollReason = reason
    if reason then
        if not ragdollSince then
            X.ragdollEpoch = X.ragdollEpoch + 1
            X.lastRagdollAt = os.clock()
            if carryUid and not isHoldingEgg() then
                X.looseUids[carryUid] = true
                X.weDropped[carryUid] = os.clock()
                X.clearMarks(carryUid)
                X.listDirty = true
            end
        end
        ragdollSince = ragdollSince or os.clock()
        if os.clock() - ragdollSince > RAGDOLL_STALE_AFTER then ragdollStale = true end
    else
        ragdollSince = nil; ragdollStale = false
    end
    -- A "ragdoll" that never ends (e.g. a carry/lock state that looks like one) must not freeze us.
    isRagdolled = reason ~= nil and not ragdollStale
end

-- ==================================================
-- RARITY MONITOR / PRESET LOOKUP
-- ==================================================
local rarityByUid = {}
local function startRarityMonitor()
    local ok, rm = pcall(function()
        return ReplicatedStorage.Packages.Networking["RE/EggWorld/FieldEggRaritiesShown"]
    end)
    if not ok or not rm then return end
    rarityConn = rm.OnClientEvent:Connect(function(p)
        if typeof(p) ~= "table" then return end
        local s = p.RareSpawns
        if typeof(s) ~= "table" then return end
        for _, e in pairs(s) do
            if typeof(e) == "table" and e.EggUid and e.RarityId then
                rarityByUid[tostring(e.EggUid)] = tostring(e.RarityId)
            end
        end
    end)
end
startRarityMonitor()

-- v9.1 GHOST-EGG PROTECTION (state lives in X: locals limit)
X.goneUids   = {}    -- uid -> time: another player took it / the game said it is gone (cleared once a scan stops listing it)
X.badUids    = {}    -- uid -> expiry: empty / stolen / failed nests we must not walk to again for a while
X.slotSeen   = {}    -- uid -> true: its client slot existed once, so a missing slot later means "taken"
X.ownUid     = nil   -- the egg WE are picking up / carrying (its own Gone/Carry events are ours, not a theft)
X.USE_SLOT_CHECK = true
X.missCount  = {}    -- uid -> consecutive scans it had NO slot while its area's slots are clearly populated
X.failCount  = {}    -- uid -> how many pickup attempts on it failed
X.slotDebugged = {}
X.looseUids  = {}    -- uid -> true: lying loose on the ground (dropped by us / a bump / a hit), NOT an empty nest
X.nestPos    = {}    -- uid -> where the egg lay while its nest slot still existed
X.lastPos    = {}    -- uid -> position in the previous scan
X.vanished   = {}    -- v9.4: uid -> time it stopped being listed (carried / taken). Coming back = lying loose
X.gonePos    = {}    -- v9.4: uid -> where it was when a Gone/Carry event fired
X.ignoreGone = {}    -- v9.4: uid -> expiry: Gone/Carry events are ignored (we just dropped this egg)
X.carrierPlayer = {} -- uid -> userId string of another player carrying this egg

function X.getCarrier(uid)
    local uStr = tostring(uid or "")
    if uStr == "" then return nil end
    local cached = X.carrierPlayer[uStr]
    if cached then return cached end

    local cra = Workspace:FindFirstChild("ClientRenderedAssets")
    if cra then
        for _, m in ipairs(cra:GetChildren()) do
            local usId, eggId = string.match(m.Name, "^(%d+)_(.+)$")
            if not eggId and string.find(m.Name, "_", 1, true) then
                usId, eggId = string.match(m.Name, "^(%d+)_(.*)")
            end
            if eggId and eggId == uStr then
                return usId
            elseif string.find(m.Name, uStr, 1, true) then
                local us = string.match(m.Name, "^(%d+)_")
                return us or "other"
            end
        end
    end
    return nil
end

function X.isCarriedByOther(uid)
    local c = X.getCarrier(uid)
    if not c then return false end
    return tostring(c) ~= tostring(LocalPlayer.UserId)
end

function X.recPos(r)
    if typeof(r.BoundsCFrame) == "CFrame" then return r.BoundsCFrame.Position end
    if typeof(r.BottomCFrame) == "CFrame" then return r.BottomCFrame.Position end
    return nil
end

-- Robust slot resolution in Workspace.AreaEggSlotsClient:
-- Matches direct 32-hex UID, recursive/attribute Uid, Forest/Area pattern ("FirstAreaEgg_..._Forest:Slot_00X"),
-- or 3D world position within 6 studs of the expected nest position.
function X.findEggSlot(area, uid, nestId, areaId, pos)
    if not area or not uid or uid == "" then return nil end
    -- 1. Direct child match (standard 32-hex UID used in 95% of areas)
    local direct = area:FindFirstChild(uid)
    if direct then return direct end

    -- 2. Attribute match or name contains UID
    for _, ch in ipairs(area:GetChildren()) do
        if ch.Name == uid or string.find(ch.Name, uid, 1, true) then
            return ch
        end
        local au = ch:GetAttribute("Uid") or ch:GetAttribute("EggUid")
        if au and tostring(au) == uid then
            return ch
        end
    end

    -- 3. AreaId / NestId match (e.g. FirstAreaEgg_<UserId>_<id>_Forest:Slot_005)
    local nStr = tostring(nestId or "")
    local aStr = tostring(areaId or "")
    if nStr ~= "" or aStr ~= "" then
        for _, ch in ipairs(area:GetChildren()) do
            local nm = ch.Name
            local matchArea = (aStr == "") or (string.find(nm, aStr, 1, true) ~= nil)
            local matchNest = false
            if nStr ~= "" then
                if string.find(nm, nStr, 1, true) then
                    matchNest = true
                else
                    local num = tonumber(string.match(nStr, "%d+"))
                    if num and (string.find(nm, string.format("Slot_%03d", num), 1, true) or string.find(nm, string.format("Slot_%d", num), 1, true)) then
                        matchNest = true
                    end
                end
            end
            if matchArea and matchNest then
                return ch
            end
        end
    end

    -- 4. World Position match (within 6 studs of expected nest position)
    if pos and typeof(pos) == "Vector3" then
        for _, ch in ipairs(area:GetChildren()) do
            local cp = nil
            if ch:IsA("BasePart") then
                cp = ch.Position
            elseif ch:IsA("Model") then
                local pp = ch.PrimaryPart or ch:FindFirstChildWhichIsA("BasePart")
                if pp then cp = pp.Position end
            end
            if cp and (cp - pos).Magnitude <= 6 then
                return ch
            end
        end
    end

    return nil
end

-- Check if egg is placed in any player's base plot (Workspace.PlacedEggRenders.<UserId>_<EggUid>)
function X.isEggInBaseRenders(uid)
    if not uid or uid == "" then return false end
    local per = Workspace:FindFirstChild("PlacedEggRenders")
    if not per then return false end
    for _, ch in ipairs(per:GetChildren()) do
        if string.find(ch.Name, uid, 1, true) then
            return true
        end
    end
    return false
end

-- Per-area cross-check of the snapshot against the client slots (called from every successful scan).
function X.updateSlotGhosts(by, recs)
    local area = Workspace:FindFirstChild("AreaEggSlotsClient")
    if not X.USE_SLOT_CHECK or not area then X.missCount = {}; return end
    local perArea = {}
    for _, r in ipairs(recs) do
        local u = tostring(r.Uid or "")
        if u ~= "" then
            local a = tostring(r.AreaId or "?")
            local pa = perArea[a]
            if not pa then pa = { n = 0, has = 0, missing = {} }; perArea[a] = pa end
            pa.n = pa.n + 1
            local p = X.recPos(r)
            local slotObj = X.findEggSlot(area, u, r.NestId, r.AreaId, p)
            local hasSlot = slotObj ~= nil
            local mine = (X.weDropped[u] and os.clock() - X.weDropped[u] < 60) or (dropRetry and dropRetry.uid == u)

            -- If egg is rendered on a player's base plot, it is delivered/stolen
            if X.isEggInBaseRenders(u) then
                X.deliveredUids[u] = true
                X.blacklistStolen(u)
                X.looseUids[u] = nil
                X.listDirty = true
            end

            -- Re-listed after vanishing from snapshot: only restore if it respawned in its nest or we dropped it
            if X.vanished[u] then
                X.vanished[u] = nil
                if hasSlot then
                    X.clearMarks(u); X.stolenN[u] = nil
                    X.movingAt[u] = nil; X.deliveredUids[u] = nil; X.slotLostSince[u] = nil
                    X.listDirty = true
                elseif mine then
                    X.looseUids[u] = true
                    X.clearMarks(u)
                    X.listDirty = true
                end
            end

            -- v9.5: a taken egg whose nest slot vanished and is back again = it returned to its nest (bumped carrier)
            if X.goneUids[u] or X.badUids[u] then
                if not hasSlot then
                    X.slotGoneAt[u] = X.slotGoneAt[u] or os.clock(); X.slotBackN[u] = 0
                elseif X.slotGoneAt[u] then
                    X.slotBackN[u] = (X.slotBackN[u] or 0) + 1
                    if X.slotBackN[u] >= 2 then
                        X.clearMarks(u); X.listDirty = true
                        print("[EggGoToUI] egg back in its nest (not stolen):", u)
                    end
                end
            end

            if hasSlot then
                pa.has = pa.has + 1; X.slotSeen[u] = true
                if p and not X.nestPos[u] then X.nestPos[u] = p end
                X.slotLostSince[u] = nil
                X.missCount[u] = nil
            else
                table.insert(pa.missing, u)
                if not mine then
                    X.slotLostSince[u] = X.slotLostSince[u] or os.clock()
                end
            end

            -- moved away from its nest, or moved between two scans = lying loose (a dropped egg), not an empty nest
            if p then
                local lp = X.lastPos[u]
                local nowc = os.clock()
                if lp and (p - lp).Magnitude > 6 then
                    X.movingAt[u] = nowc; X.restN[u] = 0        -- moving: someone is carrying it
                    if not mine then X.looseUids[u] = nil end; X.deliveredUids[u] = nil
                elseif lp then
                    X.restN[u] = (X.restN[u] or 0) + 1
                end
                local away = not hasSlot and X.nestPos[u] and (p - X.nestPos[u]).Magnitude > 6
                if (X.restN[u] or 0) >= 2 and (X.movingAt[u] or away) then
                    -- it moved and now RESTS: delivered (at the zone) or lying loose (dropped somewhere)
                    X.movingAt[u] = nil
                    local sz = Vector3.new(p.X - SAFE_ZONE.X, 0, p.Z - SAFE_ZONE.Z).Magnitude
                    if sz <= 30 and not mine and not hasSlot then
                        if not X.deliveredUids[u] then print("[EggGoToUI] egg rests at the delivery zone (delivered by someone):", u) end
                        X.deliveredUids[u] = true; X.listDirty = true
                    elseif X.stolenN[u] or X.isCarriedByOther(u) or X.isEggInBaseRenders(u) then
                        -- Egg was stolen/carried by another player and now rests (delivered in their base)
                        X.deliveredUids[u] = true
                        X.blacklistStolen(u)
                        X.looseUids[u] = nil
                        X.listDirty = true
                    elseif mine then
                        X.looseUids[u] = true
                    end
                end
                -- stale entry that sits at the delivery zone from the start (delivered before we ever saw it move)
                if not hasSlot and not mine and not X.deliveredUids[u] then
                    if Vector3.new(p.X - SAFE_ZONE.X, 0, p.Z - SAFE_ZONE.Z).Magnitude <= 15 then
                        X.deliveredUids[u] = true; X.listDirty = true
                    end
                end
                X.lastPos[u] = p
            end
        end
    end
    local newMiss = {}
    local totalClientSlots = #area:GetChildren()
    if totalClientSlots > 0 then
        for a, pa in pairs(perArea) do
            if not X.slotDebugged[a] then
                X.slotDebugged[a] = true
                print(("[EggGoToUI] slot coverage area %s: %d/%d eggs have a slot"):format(a, pa.has, pa.n))
            end
            for _, u in ipairs(pa.missing) do
                local mine = (X.weDropped[u] and os.clock() - X.weDropped[u] < 60) or (dropRetry and dropRetry.uid == u)
                if not mine then
                    local c = (X.missCount[u] or 0) + 1
                    newMiss[u] = c
                    if c == 2 then
                        print("[EggGoToUI] ghost egg (listed, no slot):", u, "area", a)
                        X.listDirty = true
                    end
                end
            end
        end
    end
    X.missCount = newMiss
end

X.slotGoneAt = {}    -- v9.5: uid -> time we first saw its slot missing while it carried a taken mark
X.slotBackN  = {}    -- v9.5: uid -> consecutive scans its slot is back
X.stolenN    = {}    -- v9.5: uid -> how many times it was judged "taken by someone else"
X.GONE_TTL   = 300
X.movingAt   = {}    -- v9.8: uid -> last time its position changed >6 studs between scans (someone is carrying it)
X.restN      = {}    -- v9.8: uid -> consecutive scans it did not move
X.deliveredUids = {} -- v9.8: uid -> true: it rests at the delivery zone (another player delivered it)
X.slotLostSince = {} -- v9.8: uid -> time its slot was first seen missing (after having existed)
X.weDropped  = {}    -- v9.8: uid -> time WE dropped it

function X.clearMarks(u)
    X.goneUids[u] = nil; X.badUids[u] = nil; X.failCount[u] = nil; X.missCount[u] = nil
    X.gonePos[u] = nil; X.slotGoneAt[u] = nil; X.slotBackN[u] = nil
    X.carrierPlayer[u] = nil
    X.deliveredUids[u] = nil
end

-- A Gone/Carry mark only counts for X.GONE_TTL seconds (an egg that went back to its nest looks identical to a stale one)
function X.goneActive(uid)
    local t = X.goneUids[uid]
    return t ~= nil and (os.clock() - t) < X.GONE_TTL
end

function X.blacklist(uid, secs)
    if uid and uid ~= "" then
        X.badUids[uid] = os.clock() + (secs or 45)
        if not X.gonePos[uid] then X.gonePos[uid] = X.lastPos[uid] or X.nestPos[uid] end
    end
end

-- "taken by someone else": 60s, 4 min, then until the scan stops listing it
function X.blacklistStolen(uid)
    local n = (X.stolenN[uid] or 0) + 1
    X.stolenN[uid] = n
    X.blacklist(uid, n == 1 and 60 or (n == 2 and 240 or 1e9))
end

function X.slotLost(uid)
    if not X.USE_SLOT_CHECK or (X.weDropped[uid] and os.clock() - X.weDropped[uid] < 60) or (dropRetry and dropRetry.uid == uid) then return false end
    local a = Workspace:FindFirstChild("AreaEggSlotsClient")
    if not a or #a:GetChildren() == 0 then return false end
    return X.findEggSlot(a, uid) == nil
end

-- v9.8: strong evidence that another player has / had the egg (returns the reason text)
function X.takenSignal(uid)
    local now = os.clock()
    local wd = X.weDropped[uid]
    if wd and now - wd < 60 then return nil end                       -- we dropped it ourselves: it is on the ground
    if dropRetry and dropRetry.uid == uid then return nil end         -- currently retrying pickup after bump/drop
    if now - X.lastRagdollAt < 15 and uid == carryUid then return nil end -- recently bumped with this egg
    if X.isEggInBaseRenders(uid) then return "placed in player base plot" end
    if X.deliveredUids[uid] then return "rests at the delivery zone (delivered)" end
    if X.isCarriedByOther(uid) then return "carried by another player" end
    local mv = X.movingAt[uid]
    if mv and (X.restN[uid] or 0) < 2 and now - mv < 20 then return "moving between scans (carried by someone)" end
    local sl = X.slotLostSince[uid]
    if sl and now - sl >= 2.5 and not X.looseUids[uid] then return "nest slot vanished (taken)" end
    return nil
end

function X.isGhost(r)
    local uid = tostring(r.Uid or "")
    if uid == "" or uid == X.ownUid then return false end
    -- 1. Blacklisted takes absolute priority (e.g. pickup failed, nest was empty, player delivery)
    local b = X.badUids[uid]
    if b then
        if os.clock() < b then return true, "blacklisted (taken / failed pickup)" end
        X.badUids[uid] = nil
    end
    -- 2. Eggs placed in any player's base plot
    if X.isEggInBaseRenders(uid) then return true, "placed in player base plot" end
    -- 3. Delivered eggs (safe zone or competitor base)
    if X.deliveredUids[uid] then return true, "delivered by player" end
    -- 4. Carried by another player
    if X.isCarriedByOther(uid) then return true, "carried by another player" end
    -- 5. FieldEggGone / FieldEggCarry network events
    if X.goneActive(uid) then return true, "Gone/Carry event" end
    -- 6. Taken signals (stolen, moving between scans, etc.)
    local ts = X.takenSignal(uid)
    if ts then return true, ts end
    -- 7. Eggs WE dropped or are retrying pickup for are exempt from missing slot ghosting
    local mine = (dropRetry and dropRetry.uid == uid) or (X.weDropped[uid] and os.clock() - X.weDropped[uid] < 60)
    if mine then return false end
    -- 8. Client slot cross-check: if AreaEggSlotsClient is active and has no slot for this egg
    if (X.missCount[uid] or 0) >= 2 then
        return true, "nest slot missing (empty nest)"
    end
    if X.slotLostSince[uid] and (os.clock() - X.slotLostSince[uid]) >= 2.5 then
        return true, "nest slot vanished (taken)"
    end
    return false
end

-- v9.7: weak evidence only (1 scan with no slot, waiting for 2nd scan to confirm): farm it last
function X.isUnverified(r)
    local uid = tostring(r.Uid or "")
    if uid == "" or uid == X.ownUid or X.looseUids[uid] then return false end
    return (X.missCount[uid] or 0) == 1
end

-- Does the server's refusal text say the egg no longer exists / was taken?
function X.rfSaysGone(ok, res)
    local txt = string.lower(ok and X.describeVal(res, 10) or tostring(res))
    for _, k in ipairs({"not found","notfound","not exist","doesn't exist","does not exist","nonexist",
                        "taken","claimed","gone","no longer","unavailable","expired","despawn"}) do
        if string.find(txt, k, 1, true) then return true end
    end
    return false
end

function X.startGoneMonitor()
    for _, pth in ipairs({"RE/EggWorld/FieldEggGone", "RE/EggWorld/FieldEggCarry"}) do
        local ok, ev = pcall(function() return ReplicatedStorage.Packages.Networking[pth] end)
        if ok and ev and ev:IsA("RemoteEvent") then
            addConnection(ev.OnClientEvent:Connect(function(pl)
                if typeof(pl) ~= "table" then return end
                local u = tostring(pl.Uid or pl.EggUid or "")
                if u ~= "" and u ~= X.ownUid then
                    local ig = X.ignoreGone[u]
                    if ig and os.clock() < ig then return end      -- v9.4: late event for an egg we just dropped
                    X.goneUids[u] = os.clock(); X.gonePos[u] = X.lastPos[u] or X.nestPos[u]; X.listDirty = true
                end
            end))
        end
    end
end
X.startGoneMonitor()

-- v9.5: events that mean "this egg exists on the field again" (dropped / released / respawned / returned to nest)
function X.startReappearMonitor()
    pcall(function()
        local net = ReplicatedStorage.Packages.Networking
        for _, ev in ipairs(net:GetChildren()) do
            local n = string.lower(ev.Name)
            if ev:IsA("RemoteEvent") and string.find(n, "eggworld", 1, true)
               and not string.find(n, "gone", 1, true) and not string.find(n, "carry", 1, true)
               and (string.find(n, "drop", 1, true) or string.find(n, "release", 1, true) or string.find(n, "spawn", 1, true)
                    or string.find(n, "added", 1, true) or string.find(n, "return", 1, true) or string.find(n, "respawn", 1, true)) then
                addConnection(ev.OnClientEvent:Connect(function(pl)
                    if typeof(pl) ~= "table" then return end
                    local u = tostring(pl.Uid or pl.EggUid or "")
                    if u ~= "" then
                        local isOurs = (pl.UserId and tostring(pl.UserId) == tostring(LocalPlayer.UserId)) or (u == carryUid)
                        if isOurs then
                            X.looseUids[u] = true
                            X.weDropped[u] = os.clock()
                            X.clearMarks(u)
                            dropRetry = { uid = u, t = os.clock(), n = 1 }
                        else
                            X.carrierPlayer[u] = nil
                            X.looseUids[u] = true
                            X.clearMarks(u)
                        end
                        X.listDirty = true
                        print("[EggGoToUI] egg reappeared via", ev.Name, "- not stolen:", u)
                    end
                end))
            end
        end
    end)
    -- Explicitly hook OwnerShifted to track other players taking eggs
    pcall(function()
        local osEv = ReplicatedStorage.Packages.Networking:FindFirstChild("RE/EggWorld/OwnerShifted")
        if osEv and osEv:IsA("RemoteEvent") then
            addConnection(osEv.OnClientEvent:Connect(function(pl)
                if typeof(pl) ~= "table" then return end
                local u = tostring(pl.Uid or pl.EggUid or "")
                local newOwner = pl.UserId or pl.Owner or pl.NewOwner
                if u ~= "" and newOwner then
                    if tostring(newOwner) ~= tostring(LocalPlayer.UserId) then
                        X.carrierPlayer[u] = tostring(newOwner)
                        X.looseUids[u] = nil
                        X.listDirty = true
                    end
                end
            end))
        end
    end)
end
X.startReappearMonitor()

-- Live carrier monitor: watches Workspace.ClientRenderedAssets for other players holding eggs
function X.startCarrierMonitor()
    local cra = Workspace:FindFirstChild("ClientRenderedAssets")
    if not cra then return end

    local function onCarriedAdded(m)
        local usId, eggId = string.match(m.Name, "^(%d+)_(.+)$")
        if not eggId and string.find(m.Name, "_", 1, true) then
            usId, eggId = string.match(m.Name, "^(%d+)_(.*)")
        end
        if eggId and usId then
            if tostring(usId) ~= tostring(LocalPlayer.UserId) then
                X.carrierPlayer[eggId] = tostring(usId)
                X.listDirty = true
            end
        end
    end

    local function onCarriedRemoved(m)
        local usId, eggId = string.match(m.Name, "^(%d+)_(.+)$")
        if not eggId and string.find(m.Name, "_", 1, true) then
            usId, eggId = string.match(m.Name, "^(%d+)_(.*)")
        end
        if eggId and usId and tostring(usId) ~= tostring(LocalPlayer.UserId) then
            X.carrierPlayer[eggId] = nil
            -- When another player finishes carrying an egg, they delivered it to their base/plot.
            -- Mark it delivered & blacklisted so we don't try to farm a delivered egg!
            X.deliveredUids[eggId] = true
            X.blacklistStolen(eggId)
            X.looseUids[eggId] = nil
            if eggCache.byUid[eggId] then
                eggCache.byUid[eggId] = nil
            end
            X.listDirty = true
        end
    end

    for _, c in ipairs(cra:GetChildren()) do onCarriedAdded(c) end
    addConnection(cra.ChildAdded:Connect(onCarriedAdded))
    addConnection(cra.ChildRemoved:Connect(onCarriedRemoved))
end
X.startCarrierMonitor()

local function normName(n)
    local s = tostring(n or ""):lower()
    s = s:gsub("[^%w%s]", " "):gsub("%s+", " ")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    s = s:gsub("^egg%s+", ""):gsub("%s+egg$", "")
    s = s:gsub("^pet%s+", ""):gsub("%s+pet$", "")
    return s
end

local presetMatches = {}
for p, r in pairs(PET_RARITY_PRESETS) do
    table.insert(presetMatches, { key = normName(p), pet = p, rarity = r })
end
table.sort(presetMatches, function(a, b) return #a.key > #b.key end)

local function getPresetRarity(sp)
    local n = normName(sp)
    if n == "" then return nil end
    for _, e in ipairs(presetMatches) do if n == e.key then return e.rarity, e.pet end end
    local pad = " " .. n .. " "
    for _, e in ipairs(presetMatches) do
        if pad:find(" " .. e.key .. " ", 1, true) then return e.rarity, e.pet end
    end
    return nil
end

local function resolveRaw(r)
    if typeof(r) ~= "table" then return nil end
    local sp = tostring(r.AssetCategory or "")
    local pr = getPresetRarity(sp)
    if pr then return pr end
    local uid = tostring(r.Uid or "")
    local lv = rarityByUid[uid]
    if lv then return lv end
    return nil
end
local function effectiveRarity(r) return resolveRaw(r) or "Unknown" end
local function highlightRarity(r)
    local rr = resolveRaw(r)
    if rr and HIGHLIGHT_RARITIES[rr] then return rr end
    return nil
end

-- ==================================================
-- APPLY SETTINGS
-- ==================================================
local function applySettings(t)
    local ok, err = validateSettings(t)
    if not ok then return false, err end
    currentSettings = deepCopy(t)

    if t.SafeZone then
        SAFE_ZONE = Vector3.new(t.SafeZone.X, t.SafeZone.Y, t.SafeZone.Z)
    end

    activeMutationFilter = {}
    if typeof(t.MutationFilter) == "table" then
        for _, n in pairs(t.MutationFilter) do
            if typeof(n) == "string" then activeMutationFilter[n] = true end
        end
    end

    selectedSpecies = {}
    if typeof(t.SpeciesFilter) == "table" then
        for _, n in pairs(t.SpeciesFilter) do
            if typeof(n) == "string" and n ~= "" then selectedSpecies[n] = true end
        end
    end
    if not next(selectedSpecies) then selectedSpecies["All"] = true end

    X.selectedRarities = {}
    if typeof(t.RarityFilter) == "table" then
        for _, n in pairs(t.RarityFilter) do
            if typeof(n) == "string" and X.RARITY_RANK[n] then X.selectedRarities[n] = true end
        end
    end

    if t.AutoReturn ~= nil then autoReturnEnabled = t.AutoReturn end
    if t.Velocity ~= nil then velocityEnabled = t.Velocity end

    if t.VelocityValue ~= nil and t.VelocityValue > 0 then
        X.baseVelocity = t.VelocityValue
    elseif not X.baseVelocity or X.baseVelocity <= 0 then
        X.baseVelocity = DEFAULT_SETTINGS.VelocityValue or 300
    end

    if t.CarryVelocityValue ~= nil and t.CarryVelocityValue > 0 then
        X.baseCarryVelocity = t.CarryVelocityValue
    elseif not X.baseCarryVelocity or X.baseCarryVelocity <= 0 then
        X.baseCarryVelocity = DEFAULT_SETTINGS.CarryVelocityValue or 250
    end

    if weAreCarrying or (typeof(isHoldingEgg) == "function" and isHoldingEgg()) then
        targetVelocity = X.baseCarryVelocity
    else
        targetVelocity = X.baseVelocity
    end

    if velocityEnabled then
        local ch = LocalPlayer.Character
        local h = ch and ch:FindFirstChildOfClass("Humanoid")
        if h then pcall(function() h.WalkSpeed = targetVelocity end) end
    end

    if t.Recovery ~= nil then
        recoveryEnabled = t.Recovery
        if not recoveryEnabled then recoveryState = RECOVERY_STATE.NONE end
    end

    -- Keep currentSettings fully synchronized and normalized
    currentSettings.SafeZone = { X = SAFE_ZONE.X, Y = SAFE_ZONE.Y, Z = SAFE_ZONE.Z }
    currentSettings.Velocity = velocityEnabled
    currentSettings.VelocityValue = X.baseVelocity
    currentSettings.CarryVelocityValue = X.baseCarryVelocity
    currentSettings.Recovery = recoveryEnabled
    currentSettings.AutoReturn = autoReturnEnabled
    return true
end

-- ==================================================
-- SNAPSHOT
-- ==================================================
local function fetchSnapshotRecords()
    local ok, rf = pcall(function()
        return ReplicatedStorage.Packages.Networking["RF/EggWorld/AskFieldEggSnapshot"]
    end)
    if not ok or not rf then return nil, "RF not found" end
    local cok, res = pcall(function() return rf:InvokeServer() end)
    if not cok then return nil, tostring(res) end
    if typeof(res) ~= "table" then return nil, "bad return" end
    local recs = res.Records
    if typeof(recs) ~= "table" then return nil, "no Records" end
    local all = {}
    for _, r in pairs(recs) do if typeof(r) == "table" then table.insert(all, r) end end
    table.sort(all, function(a, b)
        local aa, bb = tostring(a.AreaId or ""), tostring(b.AreaId or "")
        if aa ~= bb then return aa < bb end
        return tostring(a.NestId or "") < tostring(b.NestId or "")
    end)
    return all
end

-- ==================================================
-- CARRY
-- ==================================================
local function getCarryRemote()
    local ok, r = pcall(function() return ReplicatedStorage.Packages.Networking["RF/EggWorld/AskFieldEggCarry"] end)
    return ok and r or nil
end

local function carryEgg(uid, sl)
    sl.Text = "Sending carry..."
    sl.TextColor3 = Color3.fromRGB(255, 220, 100)
    local rf = getCarryRemote()
    if not rf then sl.Text = "Carry RF not found"; sl.TextColor3 = Color3.fromRGB(255,120,120); return false end
    local ok, e = pcall(function() rf:InvokeServer({ Uid = uid }) end)
    if ok then sl.Text = "Carry sent!"; sl.TextColor3 = Color3.fromRGB(120,255,150); return true end
    sl.Text = "Carry failed: " .. tostring(e); sl.TextColor3 = Color3.fromRGB(255,120,120); return false
end

-- ==================================================
-- MOVEMENT
-- ==================================================
local walkToken = 0
local SLOW_ZONE      = 25
local TELEPORT_ZONE  = 8
local SNAP_RADIUS    = 50    -- autofarm: once within this many studs (XZ) of the egg, CFrame-snap onto it
local SNAP_Y_OFFSET  = 3     -- stand slightly above the egg centre so we don't clip into the ground
local SAFE_ARRIVE_RADIUS = 8   -- counts as "arrived" at the safe zone within this many studs (XZ)
local SAFE_SNAP_RADIUS   = 50  -- within this many studs of the safe zone, CFrame-snap onto it

local function getBesideOffset(targetPos, currentPos, dist)
    dist = dist or 2.8
    local diff = Vector3.new(currentPos.X - targetPos.X, 0, currentPos.Z - targetPos.Z)
    local dir = diff.Magnitude > 0.1 and diff.Unit or Vector3.new(0, 0, 1)
    local groundY = currentPos.Y
    if math.abs(groundY - targetPos.Y) > 6 then groundY = targetPos.Y end
    local besidePos = Vector3.new(targetPos.X + dir.X * dist, groundY, targetPos.Z + dir.Z * dist)
    local lookTarget = Vector3.new(targetPos.X, groundY, targetPos.Z)
    return besidePos, lookTarget
end

-- Hop straight onto the safe-zone point (zero velocity, keep facing, ground-level).
function X.snapToSafe()
    local ch = LocalPlayer.Character
    local r  = ch and ch:FindFirstChild("HumanoidRootPart")
    if not r then return false end
    X.markTeleport()
    pcall(function()
        r.AssemblyLinearVelocity = Vector3.zero
        local targetY = SAFE_ZONE.Y
        if math.abs(r.Position.Y - SAFE_ZONE.Y) <= 4 then
            targetY = r.Position.Y
        end
        r.CFrame = CFrame.new(SAFE_ZONE.X, targetY, SAFE_ZONE.Z) * (r.CFrame - r.CFrame.Position)
    end)
    return true
end

-- dest may be a Vector3 OR a function returning the latest Vector3 (live-tracked target).
-- opts.snapRadius: when set, teleports onto dest once within that XZ distance.
-- opts.snapBeside: when true, teleports beside the egg facing it instead of dropping on top.
local function walkTo(destOrFn, arriveRadius, myTok, onArrived, opts)
    local snapRadius = opts and opts.snapRadius
    local stuckHop   = opts and opts.stuckHop
    task.spawn(function()
        local chkT, chkD = nil, nil          -- stall watchdog state
        while walkToken == myTok do
            local skip = false

            local dest = destOrFn
            if type(destOrFn) == "function" then
                local okd, d = pcall(destOrFn)
                dest = okd and d or nil
            end
            if typeof(dest) ~= "Vector3" then
                task.wait(0.1)
                skip = true
            end

            local ch = LocalPlayer.Character
            if not skip and not ch then
                task.wait(0.05)
                skip = true
            end

            local h, r
            if not skip then
                h = ch:FindFirstChildOfClass("Humanoid")
                r = ch:FindFirstChild("HumanoidRootPart")
                if not h or not r then
                    task.wait(0.05)
                    skip = true
                end
            end

            -- v8: ARRIVAL IS CHECKED FIRST. It is purely positional, so a ragdoll/stun that starts (or is still
            -- running) inside the zone can no longer hide "we are already there".
            if not skip then
                local rp0 = r.Position
                local xz0 = Vector3.new(dest.X - rp0.X, 0, dest.Z - rp0.Z).Magnitude
                if xz0 <= arriveRadius then
                    pcall(function() h:Move(Vector3.zero); h.WalkToPoint = rp0 end)
                    if onArrived then onArrived() end
                    return
                end
            end

            if not skip and isRagdolled then
                task.wait(0.1)
                skip = true
            end

            if not skip then
                local rp = r.Position
                local xz = Vector3.new(dest.X - rp.X, 0, dest.Z - rp.Z).Magnitude
                -- Stall watchdog (return trips): if we made <3 studs of progress in 1.0s
                -- (movement locked while carrying, stuck on geometry...) hop 35 studs toward dest (checked every 1s).
                if stuckHop then
                    local now = os.clock()
                    if not chkT then
                        chkT, chkD = now, xz
                    elseif now - chkT >= 1.0 then
                        if chkD - xz < 3 and xz > arriveRadius + 1 then
                            local dir = Vector3.new(dest.X - rp.X, 0, dest.Z - rp.Z).Unit
                            local hop = math.min(35, xz - arriveRadius + 0.5)
                            X.markTeleport()
                            pcall(function()
                                r.AssemblyLinearVelocity = Vector3.zero
                                r.CFrame = r.CFrame + dir * hop
                            end)
                            chkD = xz - hop
                        else
                            chkD = xz
                        end
                        chkT = now
                    end
                end
                if snapRadius and xz <= snapRadius then
                    -- Close enough: hop onto target (beside egg if snapBeside, otherwise safe zone)
                    h:Move(Vector3.zero)
                    X.markTeleport()
                    pcall(function()
                        r.AssemblyLinearVelocity = Vector3.zero
                        if opts and opts.snapBeside then
                            local bPos, lPos = getBesideOffset(dest, r.Position, 2.8)
                            r.CFrame = CFrame.lookAt(bPos, lPos)
                        else
                            local yPos = dest.Y
                            if math.abs(r.Position.Y - dest.Y) <= 4 then
                                yPos = r.Position.Y
                            end
                            r.CFrame = CFrame.new(dest.X, yPos, dest.Z) * (r.CFrame - r.CFrame.Position)
                        end
                    end)
                    task.wait(0.08)
                elseif xz <= TELEPORT_ZONE then
                    h:Move(Vector3.zero); X.markTeleport()
                    pcall(function()
                        r.AssemblyLinearVelocity = Vector3.zero
                        if opts and opts.snapBeside then
                            local bPos, lPos = getBesideOffset(dest, r.Position, 2.8)
                            r.CFrame = CFrame.lookAt(bPos, lPos)
                        else
                            r.CFrame = CFrame.new(dest.X, rp.Y, dest.Z)
                        end
                    end)
                    task.wait(0.08)
                elseif xz > SLOW_ZONE then
                    h:MoveTo(dest); task.wait(0.3)
                else
                    local d = Vector3.new(dest.X - rp.X, 0, dest.Z - rp.Z).Unit
                    h:Move(d, false); task.wait(0.08)
                end
            end
        end
    end)
end

-- Note: Manual get is a single-step execution of autoGetEgg (defined below with auto farm).

-- ==================================================
-- HELPERS
-- ==================================================
local function extPos(r)
    if typeof(r.BoundsCFrame) == "CFrame" then return r.BoundsCFrame.Position end
    if typeof(r.BottomCFrame) == "CFrame" then return r.BottomCFrame.Position end
    return nil
end

local function mutLabel(r)
    if typeof(r.Mutations) ~= "table" then return nil end
    local n = {}
    for _, x in pairs(r.Mutations) do if typeof(x) == "string" then table.insert(n, x) end end
    if #n == 0 then return nil end
    table.sort(n); return table.concat(n, "+")
end

function X.hasRarity() return next(X.selectedRarities) ~= nil end

-- Divine/Eternal/Secret/Mythic eggs that are at least as rare as the LOWEST ticked rarity are picked up
-- automatically (a higher rarity than the one you selected spawned -> go for it).
function X.autoHigher(rar)
    local rk = X.RARITY_RANK[rar]
    if not rk then return false end
    local inChain = false
    for _, n in ipairs(X.PRIORITY_CHAIN) do if n == rar then inChain = true; break end end
    if not inChain then return false end
    local minRank = math.huge
    for n in pairs(X.selectedRarities) do
        local k = X.RARITY_RANK[n]
        if k and k < minRank then minRank = k end
    end
    return rk >= minRank
end

-- lower = picked first: Divine 1, Eternal 2, Secret 3, Mythic 4, everything else selected 5.xx (rarer first)
function X.eggTier(r)
    local rar = effectiveRarity(r)
    for i, n in ipairs(X.PRIORITY_CHAIN) do if n == rar then return i end end
    return 5 + (10 - (X.RARITY_RANK[rar] or 0)) / 100
end

local function passesFilters(r)
    local u = tostring(r.Uid or "")
    if X.isGhost(r) then return false end      -- v9.1: taken / empty nest
    if X.isCarriedByOther(u) then return false end
    if X.deliveredUids[u] then return false end
    if X.isEggInBaseRenders(u) then return false end
    -- mutation filter
    local mOk = true
    if next(activeMutationFilter) then
        mOk = false
        if typeof(r.Mutations) == "table" then
            for _, n in pairs(r.Mutations) do
                if activeMutationFilter[tostring(n)] then mOk = true; break end
            end
        end
    end
    -- species / rarity filter.
    --   rarity OFF : "All" = everything; empty set = nothing; otherwise only selected species (as before)
    --   rarity ON  : an egg is a target if its rarity is ticked (or is a higher chain rarity), OR its species is
    --                selected. With Farm = "All" the species part does not restrict, so only the rarity applies.
    local sOk = false
    if X.hasRarity() then
        local rar = effectiveRarity(r)
        local rarMatch = X.selectedRarities[rar] == true or X.autoHigher(rar)
        if selectedSpecies["All"] then
            sOk = rarMatch
        else
            sOk = rarMatch or selectedSpecies[tostring(r.AssetCategory or "")] == true
        end
    elseif selectedSpecies["All"] then
        sOk = true
    else
        sOk = selectedSpecies[tostring(r.AssetCategory or "")] == true
    end
    return mOk and sOk
end

-- ==================================================
-- AUTO FARM
-- ==================================================
-- FIX: forward-declare UI refs so autoFarmLoop/toggleAutoFarm capture them as upvalues
local autoFarmBtn, statusLabel
local autoFarmEnabled = false
local autoFarmToken   = 0       -- incremented to stop an in-flight run
local AUTO_RETRY      = 4
local AUTO_NEXT_DELAY = 0.8     -- pause between eggs
local AUTO_EMPTY_WAIT = 2.0     -- wait when no matching eggs
local AUTO_CARRY_WAIT = 0.4     -- wait after carry RF for server to action

local HOLD_RELEASE_TIMEOUT = 8     -- max wait for the carried egg to be delivered/released
local WALK_TIMEOUT         = 90    -- give up on a single egg after this many seconds
local EGG_SCAN_INTERVAL    = 1.0   -- FIXED cadence of the live egg scan while autofarm is on
local DROP_CONFIRM         = 0.6   -- seconds the carried object must be gone before we call it dropped

-- Our OWN carry state (never trust a heuristic to say we carry something we never picked up)
weAreCarrying        = false
carryUid             = nil
carryMarkers         = nil    -- objects that appeared when WE picked the egg up (or nil if none seen)
local lastFailReason = nil    -- shown by the loop instead of the generic "failed/skipped" text
dropRetry            = nil    -- { uid, t, n }: an egg we dropped -> fetch THIS one again first

-- ---------- LIVE EGG CACHE: one scanner, constant 1s cadence ----------
local eggCache = { records = nil, byUid = {}, t = 0, tIssue = 0, seq = 0, err = nil }
local onEggCacheUpdate = nil   -- set later by the UI: redraws the egg list on every new scan

-- v8: the snapshot call is a server round trip that can hang (e.g. right when an egg is carried/delivered/bumped).
-- Every fetch now runs in its own thread with a timeout, so one hung call can never freeze the scanner again.
function X.fetchTimed(timeout)
    local done, recs, err = false, nil, nil
    task.spawn(function()
        local r, e = fetchSnapshotRecords()
        recs, err, done = r, e, true
    end)
    local t = 0
    while not done and t < timeout do task.wait(0.05); t = t + 0.05 end
    if not done then return nil, "scan timeout" end
    return recs, err
end

local function refreshEggCache(timeout)
    X.scanIssue = X.scanIssue + 1
    local issue, tIssue = X.scanIssue, os.clock()
    local recs, e = X.fetchTimed(timeout or X.SCAN_TIMEOUT)
    if recs then
        if issue < X.scanApplied then return true end       -- a newer reply already landed; ignore this late one
        X.scanApplied = issue
        local by = {}
        for _, r in ipairs(recs) do
            local u = tostring(r.Uid or "")
            if u ~= "" then by[u] = r end
        end
        eggCache.records, eggCache.byUid, eggCache.t, eggCache.tIssue, eggCache.err = recs, by, os.clock(), tIssue, nil
        eggCache.seq = eggCache.seq + 1
        -- v9.1: bookkeeping for the ghost filter
        do
            pcall(X.updateSlotGhosts, by, recs)
            for u in pairs(X.goneUids) do if not by[u] then X.goneUids[u] = nil; X.slotGoneAt[u] = nil; X.slotBackN[u] = nil end end
            for u in pairs(X.stolenN)  do if not by[u] then X.stolenN[u] = nil end end   -- unlisted now: a later re-list is a real respawn
            for u in pairs(X.slotSeen) do if not by[u] then X.slotSeen[u] = nil end end
            for u in pairs(X.badUids)  do if not by[u] then X.badUids[u] = nil; X.failCount[u] = nil end end
            for u in pairs(X.failCount) do if not by[u] then X.failCount[u] = nil end end
            -- v9.4: an unlisted egg is usually being CARRIED: remember it, and keep its loose/nest memory so it is not
            -- mistaken for an empty nest when it is dropped and listed again. Forget it after 5 minutes.
            local nowc = os.clock()
            for u in pairs(X.lastPos) do if not by[u] then X.vanished[u] = nowc; X.lastPos[u] = nil end end
            for _, tb in ipairs({ X.movingAt, X.restN, X.deliveredUids, X.slotLostSince, X.weDropped }) do
                for u in pairs(tb) do if not by[u] then tb[u] = nil end end
            end
            for u, t in pairs(X.vanished) do
                if not by[u] and nowc - t > 300 then
                    X.vanished[u] = nil; X.looseUids[u] = nil; X.nestPos[u] = nil; X.gonePos[u] = nil; X.ignoreGone[u] = nil
                end
            end
        end
        if onEggCacheUpdate then pcall(onEggCacheUpdate, recs) end
        return true
    end
    if issue >= X.scanApplied then eggCache.err = e end
    return false
end

-- Blocking, immediate scan (pickup / bump / arrival). At least 0.2s between forced scans.
function X.forceScan(timeout)
    local gap = 0.2 - (os.clock() - X.lastForceAt)
    if gap > 0 then task.wait(gap) end
    X.lastForceAt = os.clock()
    return refreshEggCache(timeout or 1.5)
end

-- Non-blocking, and makes the egg list redraw on the next scan (used after pickup / drop / delivery).
function X.requestEggRefresh()
    X.listDirty = true
    task.spawn(X.forceScan)
end

local eggScannerRunning, eggScannerStop = false, false
-- One scanner for the whole script life: constant 1s cadence, feeds the autofarm AND the egg list.
local function startEggScanner()
    if eggScannerRunning then return end
    eggScannerRunning, eggScannerStop = true, false
    task.spawn(function()
        local nextT = os.clock()
        while not eggScannerStop do
            -- each scan runs in its own thread; if the previous one is still hanging after SCAN_HANG_AFTER
            -- seconds, start another one in parallel instead of waiting on it forever
            local busy = X.scanBusySince and (os.clock() - X.scanBusySince) < X.SCAN_HANG_AFTER
            if not busy then
                local mine = os.clock()
                X.scanBusySince = mine
                task.spawn(function()
                    pcall(refreshEggCache)
                    if X.scanBusySince == mine then X.scanBusySince = nil end
                end)
            end
            nextT = nextT + EGG_SCAN_INTERVAL            -- fixed schedule, not "wait after"
            local w = nextT - os.clock()
            if w < 0 then nextT = os.clock(); w = 0 end  -- fell behind: don't burst-catch-up
            task.wait(math.max(w, 0.05))
        end
        eggScannerRunning = false
    end)
end

-- ---------- CARRY DETECTION by object identity (not by name guessing) ----------
-- Snapshot what exists BEFORE the pickup; whatever egg-ish thing is NEW afterwards is "the carried
-- egg". Persistent look-alikes that were already there can no longer fake a "holding" state.
local function takeHoldSnapshot()
    local snap = { inst = {}, attr = {} }
    local ch = LocalPlayer.Character
    if ch then for _, c in ipairs(ch:GetChildren()) do snap.inst[c] = true end end
    local cra = Workspace:FindFirstChild("ClientRenderedAssets")
    if cra then for _, c in ipairs(cra:GetChildren()) do snap.inst[c] = true end end
    for k, v in pairs(LocalPlayer:GetAttributes()) do snap.attr["P:" .. k] = v end
    if ch then for k, v in pairs(ch:GetAttributes()) do snap.attr["C:" .. k] = v end end
    return snap
end

local function attrKeyRelevant(k)
    local l = string.lower(k)
    return string.find(l, "carr", 1, true) or string.find(l, "egg", 1, true) or string.find(l, "hold", 1, true)
end

local function scanHoldMarkers(before)
    local uidPat = "%f[%d]" .. tostring(LocalPlayer.UserId) .. "%f[%D]"
    local found = { inst = {}, attr = {}, labels = {} }
    local function consider(c, tag)
        if before.inst[c] or not c.Parent then return end
        local ok
        if tag == "char:" then
            ok = (c:IsA("Tool") or c:IsA("Model")) and string.find(string.lower(c.Name), "egg", 1, true) ~= nil
        else
            ok = string.find(c.Name, uidPat) ~= nil    -- ClientRenderedAssets: only models carrying OUR UserId
        end
        if ok then
            table.insert(found.inst, { inst = c, parent = c.Parent, name = c.Name })
            table.insert(found.labels, tag .. c.Name)
        end
    end
    local ch = LocalPlayer.Character
    if ch then for _, c in ipairs(ch:GetChildren()) do consider(c, "char:") end end
    local cra = Workspace:FindFirstChild("ClientRenderedAssets")
    if cra then for _, c in ipairs(cra:GetChildren()) do consider(c, "cra:") end end
    local function attrs(obj, prefix)
        if not obj then return end
        for k, v in pairs(obj:GetAttributes()) do
            if attrKeyRelevant(k) and v ~= nil and v ~= false and v ~= 0 and v ~= before.attr[prefix .. k] then
                table.insert(found.attr, { obj = obj, key = k, val = v })
                table.insert(found.labels, "attr:" .. prefix .. k)
            end
        end
    end
    attrs(LocalPlayer, "P:"); attrs(ch, "C:")
    if #found.inst == 0 and #found.attr == 0 then return nil end
    found.label = table.concat(found.labels, ",")
    return found
end

local function markersActive(m)
    if not m then return false end
    for _, e in ipairs(m.inst) do
        if e.inst.Parent ~= nil then return true end
        -- the game may re-create the object: same name under the same parent still counts
        if e.parent and e.parent.Parent and e.parent:FindFirstChild(e.name) then return true end
    end
    for _, a in ipairs(m.attr) do
        if a.obj.Parent ~= nil then
            local ok, cur = pcall(function() return a.obj:GetAttribute(a.key) end)
            if ok and cur == a.val then return true end
        end
    end
    return false
end

local function waitMarkersGone(timeout, myTok)
    local t, streak = 0, 0
    while t < timeout and autoFarmToken == myTok do
        if not markersActive(carryMarkers) then
            streak = streak + 1
            if streak >= 3 then return true end
        else
            streak = 0
        end
        task.wait(0.1); t = t + 0.1
    end
    return not markersActive(carryMarkers)
end

-- v8: after arriving, wait for the carried object to be consumed, re-snapping onto the zone every 2s in case the
-- server rubber-banded us just outside it (one way "delivery did not register").
function X.deliverWait(myTok)
    X.snapToSafe()
    if not carryMarkers then task.wait(0.3); return true end
    local t, lastSnap, streak = 0, 0, 0
    while t < HOLD_RELEASE_TIMEOUT and (autoFarmToken == myTok or walkToken == myTok) do
        if not markersActive(carryMarkers) then
            streak = streak + 1
            if streak >= 3 then return true end
        else
            streak = 0
            if t - lastSnap >= 2 then lastSnap = t; X.snapToSafe() end
        end
        task.wait(0.1); t = t + 0.1
    end
    return not markersActive(carryMarkers)
end

-- Are we STILL carrying an egg we picked up?  (used before any delivery walk)
local function stillCarrying()
    if not weAreCarrying then return false end
    if isHoldingEgg() then return true end
    if carryMarkers and not markersActive(carryMarkers) then return false end   -- object is gone
    if carryUid and eggCache.byUid[carryUid] and not isHoldingEgg() then return false end
    return true
end

-- Did the server explicitly refuse the carry request?  (nil / true / a plain table = accepted)
local function rfRejected(ok, res)
    if not ok then return true end
    if res == false then return true end
    if typeof(res) == "table" then
        if res.Success == false or res.success == false or res.Ok == false or res.ok == false then return true end
        if res.Error ~= nil or res.error ~= nil then return true end
    end
    return false
end

function X.describeVal(v, maxn)
    if typeof(v) ~= "table" then return tostring(v) end
    local parts = {}
    for k, x in pairs(v) do
        table.insert(parts, tostring(k) .. "=" .. tostring(x))
        if #parts >= (maxn or 8) then break end
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

local describeVal = X.describeVal

-- Blocking walk (runs in the autofarm thread). Returns true only if we actually arrived.
local function walkSync(destOrFn, radius, myTok, opts, isManual)
    walkToken = walkToken + 1
    local tok = walkToken
    local done, arrived = false, false
    walkTo(destOrFn, radius, tok, function() arrived = true; done = true end, opts)
    while not done and (isManual or autoFarmToken == myTok) and walkToken == tok do task.wait(0.1) end
    if not arrived then walkToken = walkToken + 1 end
    return arrived
end

-- Walks to an egg (position refreshed from the live 1s cache), snaps onto it inside SNAP_RADIUS,
-- carries it, confirms from REAL signals only, then returns to the safe zone -- aborting the trip
-- if the egg gets dropped so we never walk home empty-handed.
local function autoGetEgg(uid, startPos, myTok, isManual)
    X.resetVelocity()             -- v9: every new target egg starts at the default velocity
    X.ownUid = nil                -- v9.1: not ours until we actually start the pickup
    local completed, result = false, false
    local phase   = "walking"     -- walking -> carrying -> done
    local livePos = startPos
    local tag     = isManual and "[ManualGet] " or "[AutoFarm] "

    local function finish(ok)
        if completed then return end
        completed = true; phase = "done"; result = ok
    end

    walkToken = walkToken + 1
    local walkTok = walkToken
    local rtok = nil

    local function cancelled()
        if isManual then return walkToken ~= walkTok and (not rtok or walkToken ~= rtok) end
        return autoFarmToken ~= myTok or (walkToken ~= walkTok and (not rtok or walkToken ~= rtok))
    end

    -- Tracker: consumes each NEW scan from the constant 1s scanner
    task.spawn(function()
        local t0, missing, lastSeq = os.clock(), 0, eggCache.seq
        while not completed and phase == "walking" and (isManual or autoFarmToken == myTok) and walkToken == walkTok do
            task.wait(0.15)
            if completed or phase ~= "walking" or (not isManual and autoFarmToken ~= myTok) or walkToken ~= walkTok then break end
            if os.clock() - t0 > WALK_TIMEOUT then
                walkToken = walkToken + 1; finish(false); break
            end
            -- v9.1: the game told us it is gone / its slot vanished -> don't walk to an empty nest
            if X.goneActive(uid) or X.takenSignal(uid) then
                walkToken = walkToken + 1
                lastFailReason = tag .. "Egg taken by someone else — next..."
                if not isManual then X.blacklistStolen(uid) end
                finish(false); break
            end
            if eggCache.seq ~= lastSeq then
                lastSeq = eggCache.seq
                local found = eggCache.byUid[uid]
                if found then
                    missing = 0
                    local np = extPos(found)
                    if np then livePos = np end
                    -- v9: a higher-priority rarity (Divine > Eternal > Secret > Mythic) spawned before we picked
                    -- this egg up: switch to it (a dropped egg we are re-fetching is never abandoned; manual get stays on chosen egg)
                    if not isManual and X.hasRarity() and not (dropRetry and dropRetry.uid == uid) then
                        local okp, best, bTier = pcall(X.pickNearest, eggCache.records or {})
                        if okp and best and bTier and bTier < 5 and tostring(best.Uid or "") ~= uid
                           and bTier < X.eggTier(found) then
                            walkToken = walkToken + 1
                            lastFailReason = "[AutoFarm] Higher rarity spawned (" .. tostring(best.AssetCategory) .. ") — switching..."
                            finish(false); break
                        end
                    end
                else
                    missing = missing + 1
                    local lim = (X.looseUids[uid] or (dropRetry and dropRetry.uid == uid)) and 4 or 2   -- v9.4: dropped eggs re-list late
                    if missing >= lim then        -- gone on 2 scans in a row: someone else took it
                        walkToken = walkToken + 1
                        lastFailReason = tag .. "Egg gone before pickup — next..."
                        if not isManual then X.blacklist(uid, 45) end
                        finish(false); break
                    end
                end
            end
        end
    end)

    walkTo(function() return livePos end, 6, walkTok, function()
        phase = "carrying"                          -- stops the tracker (set before any yield)
        if cancelled() then finish(false); return end

        -- v9.1: FRESH check right at the nest before any pickup attempt (the cache can be ~1s old)
        do
            X.forceScan(1.5)
            if cancelled() then finish(false); return end
            local areaCl = Workspace:FindFirstChild("AreaEggSlotsClient")
            local recCur = eggCache.byUid[uid]
            local curPos = recCur and extPos(recCur) or livePos
            local hasSlotNow = areaCl and X.findEggSlot(areaCl, uid, recCur and recCur.NestId, recCur and recCur.AreaId, curPos) ~= nil
            local mine = (X.weDropped[uid] and os.clock() - X.weDropped[uid] < 60) or (dropRetry and dropRetry.uid == uid)
            local emptyNest = areaCl and #areaCl:GetChildren() > 0 and not hasSlotNow and not mine
            if X.isGhost(recCur or { Uid = uid }) or X.goneActive(uid) or X.takenSignal(uid) or eggCache.byUid[uid] == nil or emptyNest then
                lastFailReason = tag .. "Nest already empty — next..."
                X.blacklistStolen(uid)
                X.deliveredUids[uid] = true
                X.looseUids[uid] = nil
                if eggCache.byUid[uid] then eggCache.byUid[uid] = nil end
                X.listDirty = true
                X.requestEggRefresh()
                finish(false); return
            end
        end
        X.ownUid = uid                              -- from here on Gone/Carry events for this uid are ours
        statusLabel.Text = tag .. "Picking up..."
        statusLabel.TextColor3 = Color3.fromRGB(255, 220, 100)

        local before = takeHoldSnapshot()
        local pickupEpoch0 = X.ragdollEpoch      -- any ragdoll/stun after this point = we were bumped while grabbing/carrying
        do
            local rec0 = eggCache.byUid[uid]
            if rec0 then print(tag .. "egg record:", describeVal(rec0, 14)) end
        end

        -- Listen BEFORE invoking so an early FieldEggGone/Carry event can't be missed
        local gotGone, conns = false, {}
        for _, pth in ipairs({"RE/EggWorld/FieldEggGone","RE/EggWorld/FieldEggCarry"}) do
            local eok, ev = pcall(function() return ReplicatedStorage.Packages.Networking[pth] end)
            if eok and ev and ev:IsA("RemoteEvent") then
                table.insert(conns, ev.OnClientEvent:Connect(function(pl)
                    if typeof(pl) == "table" and tostring(pl.Uid or pl.EggUid or "") == uid then gotGone = true end
                end))
            end
        end
        local function cleanup()
            for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
            table.clear(conns)
        end

        -- Confirmation uses REAL signals only (the old "slot missing" fallback could fire falsely):
        --   1) FieldEggGone/Carry event for our Uid
        --   2) a NEW carried-egg object/attribute appeared on us
        --   3) a fresh scan taken after the request no longer lists our Uid
        -- The carry RF runs in its own thread so a slow/hanging reply can't freeze us.
        -- Micro-teleport: re-read the egg's CURRENT position from the live scan and CFrame straight
        -- onto it (used before every carry attempt, so a nudge from the boss can't leave us out of reach).
        local function microSnap()
            local rec = eggCache.byUid[uid]
            local ep  = rec and extPos(rec)
            if ep then livePos = ep end
            local ch2 = LocalPlayer.Character
            local r2  = ch2 and ch2:FindFirstChild("HumanoidRootPart")
            local h2  = ch2 and ch2:FindFirstChildOfClass("Humanoid")
            if not r2 or typeof(livePos) ~= "Vector3" then return false end
            local dist = (Vector3.new(livePos.X, 0, livePos.Z) - Vector3.new(r2.Position.X, 0, r2.Position.Z)).Magnitude
            if dist > 75 then
                return false
            end
            if h2 then pcall(function() h2:Move(Vector3.zero) end) end
            X.markTeleport()
            pcall(function()
                r2.AssemblyLinearVelocity = Vector3.zero
                local bPos, lPos = getBesideOffset(livePos, r2.Position, 2.8)
                r2.CFrame = CFrame.lookAt(bPos, lPos)
            end)
            return true
        end

        -- The egg's slot on the client (existing signal from the original script). Only trusted as a
        -- pickup signal if it actually EXISTED before we asked.
        local area0 = Workspace:FindFirstChild("AreaEggSlotsClient")
        local slotExisted = area0 ~= nil and X.findEggSlot(area0, uid, rec0 and rec0.NestId, rec0 and rec0.AreaId, livePos) ~= nil

        -- A pickup only counts with REAL proof (no more "the server said OK" trust, which made us walk
        -- home empty-handed when the egg was not actually picked up):
        --   event / new carried object / slot removed / a fresh scan that no longer lists the egg.
        local carried, how, markers = false, nil, nil
        local stolen = false
        local lastRfInfo = "no reply"
        local mine = (X.weDropped[uid] and os.clock() - X.weDropped[uid] < 60) or (dropRetry and dropRetry.uid == uid)
        local maxTry = AUTO_RETRY
        do   -- v9.2: no slot for this egg although the slot folder is populated -> most likely an empty nest: try only twice
            local ar = Workspace:FindFirstChild("AreaEggSlotsClient")
            if X.USE_SLOT_CHECK and ar and #ar:GetChildren() > 0 and not X.findEggSlot(ar, uid, rec0 and rec0.NestId, rec0 and rec0.AreaId, livePos) and not mine then maxTry = math.min(maxTry, 2) end
        end
        for attemptNo = 1, maxTry do
            if cancelled() then break end

            -- never fire the request while ragdolled/stunned (bounded wait)
            local wr = 0
            while isRagdolled and wr < 3 and not cancelled() do task.wait(0.1); wr = wr + 0.1 end

            -- ESP check: if another player is already carrying this egg, abort immediately
            if X.isCarriedByOther(uid) then
                stolen = true
                lastFailReason = tag .. "Egg taken by another player — next..."
                break
            end

            -- DISTANCE CHECK: If knocked back > 75 studs by boss or bump, walk closer first before any micro-snap!
            local chTmp = LocalPlayer.Character
            local rTmp = chTmp and chTmp:FindFirstChild("HumanoidRootPart")
            if rTmp and typeof(livePos) == "Vector3" then
                local dCur = (Vector3.new(livePos.X, 0, livePos.Z) - Vector3.new(rTmp.Position.X, 0, rTmp.Position.Z)).Magnitude
                if dCur > 75 then
                    statusLabel.Text = (tag .. "Knocked back (%d studs) — walking closer..."):format(math.floor(dCur))
                    statusLabel.TextColor3 = Color3.fromRGB(255, 180, 80)
                    local closeWalk = walkSync(function() return livePos end, 15, myTok, { snapRadius = 40, snapBeside = true }, isManual)
                    if not closeWalk or cancelled() then break end
                    if X.isCarriedByOther(uid) then
                        stolen = true
                        lastFailReason = tag .. "Egg taken by another player — next..."
                        break
                    end
                end
            end

            microSnap(); task.wait(0.12)
            statusLabel.Text = (tag .. "Picking up... try %d/%d"):format(attemptNo, maxTry)
            statusLabel.TextColor3 = Color3.fromRGB(255, 220, 100)

            local rf = getCarryRemote()
            local rfDone, rfOk, rfRes = false, false, nil
            local seq0 = eggCache.seq
            local listedAtStart = eggCache.byUid[uid] ~= nil     -- v9.1: a scan can only PROVE a pickup if the egg was there
            if rf then
                task.spawn(function()
                    local ok2, res2 = pcall(function() return rf:InvokeServer({ Uid = uid }) end)
                    rfOk, rfRes, rfDone = ok2, res2, true
                    lastRfInfo = (ok2 and "reply " or "error ") .. describeVal(res2)
                    print("[AutoFarm] carry RF ->", ok2, describeVal(res2))
                end)
            else
                lastRfInfo = "carry remote missing"; rfDone = true
            end

            local t = 0
            while t < 4 and not cancelled() do
                local m = scanHoldMarkers(before)
                if m then carried, how, markers = true, "object " .. m.label, m; break end
                if gotGone then
                    -- v9.1: another player taking the egg fires the same event: only trust it if the server did not refuse us
                    if rfDone and rfRejected(rfOk, rfRes) then stolen = true; break end
                    if rfDone or t >= 0.6 then carried, how = true, "event"; break end
                end
                if slotExisted then
                    local a2 = Workspace:FindFirstChild("AreaEggSlotsClient")
                    if a2 and not X.findEggSlot(a2, uid, rec0 and rec0.NestId, rec0 and rec0.AreaId, livePos) then carried, how = true, "slot removed"; break end
                end
                if listedAtStart and eggCache.seq > seq0 and eggCache.byUid[uid] == nil then carried, how = true, "scan"; break end
                if rfDone then
                    if rfRejected(rfOk, rfRes) and X.rfSaysGone(rfOk, rfRes) then stolen = true; break end   -- v9.2
                    if rfRejected(rfOk, rfRes) and t >= 0.3 then break end   -- refused: try again now
                    if t >= 2.0 then break end                                -- "accepted" but no proof: try again
                end
                task.wait(0.1); t = t + 0.1
            end
            if carried then break end
            if stolen then break end
            -- v9.1: refused -> is the egg still in the nest at all? (fresh scan) if not, stop retrying
            if rfDone and rfRejected(rfOk, rfRes) then
                X.forceScan(1.5)
                if eggCache.byUid[uid] == nil or X.goneActive(uid) then stolen = true; break end
            end
            task.wait(0.4)
        end
        cleanup()
        if not carried then
            if stolen then
                lastFailReason = tag .. "Egg was taken by someone else — next..."
                X.blacklistStolen(uid)
                X.deliveredUids[uid] = true
                X.looseUids[uid] = nil
            else
                lastFailReason = tag .. "Pickup failed (" .. lastRfInfo .. ") — next..."
                local n = (X.failCount[uid] or 0) + 1
                X.failCount[uid] = n
                X.blacklist(uid, n == 1 and 45 or (n == 2 and 180 or 1e9))
                if n >= 2 then
                    X.deliveredUids[uid] = true
                    X.looseUids[uid] = nil
                end
            end
            if eggCache.byUid[uid] then
                eggCache.byUid[uid] = nil
            end
            X.listDirty = true
            X.requestEggRefresh()
            finish(false); return
        end

        weAreCarrying, carryUid, carryMarkers = true, uid, markers
        X.switchToCarry()
        local pickupConfirmT = os.clock()   -- scans issued BEFORE this may still show the egg lying on the ground
        local ch = LocalPlayer.Character
        if ch then neutraliseEggPhysics(ch) end

        if not autoReturnEnabled then
            weAreCarrying = false
            X.resetVelocity()
            X.requestEggRefresh()
            statusLabel.Text = tag .. "Secured ✓ (no return)"
            statusLabel.TextColor3 = Color3.fromRGB(120, 255, 150)
            finish(true); return
        end

        -- Drop-ish game events (found dynamically; only counted if the payload carries OUR Uid)
        local dropEvt, dropConns = nil, {}
        pcall(function()
            local net = ReplicatedStorage.Packages.Networking
            local names = {}
            for _, ev in ipairs(net:GetChildren()) do
                local n = string.lower(ev.Name)
                if ev:IsA("RemoteEvent") and string.find(n, "eggworld", 1, true)
                   and (string.find(n, "drop", 1, true) or string.find(n, "lost", 1, true)
                        or string.find(n, "release", 1, true) or string.find(n, "spawn", 1, true)
                        or string.find(n, "added", 1, true)) then
                    table.insert(names, ev.Name)
                    table.insert(dropConns, ev.OnClientEvent:Connect(function(pl)
                        print("[AutoFarm] event", ev.Name, describeVal(pl))
                        if typeof(pl) == "table" and tostring(pl.Uid or pl.EggUid or "") == uid then dropEvt = ev.Name end
                    end))
                end
            end
            print("[AutoFarm] watching drop events:", #names > 0 and table.concat(names, ", ") or "(none found)")
        end)
        local function cleanupDrop()
            for _, c in ipairs(dropConns) do pcall(function() c:Disconnect() end) end
            table.clear(dropConns)
        end

        -- RETURN TRIP: starts immediately after a confirmed pickup; snaps onto the safe zone within 50 studs.
        walkToken = walkToken + 1
        rtok = walkToken
        local done, arrived, dropped = false, false, false
        walkTo(SAFE_ZONE, SAFE_ARRIVE_RADIUS, rtok, function() arrived = true; done = true end,
               { stuckHop = true, snapRadius = SAFE_SNAP_RADIUS })
        X.requestEggRefresh()   -- scan issued right after the pickup: tells us whether the listing hides a carried egg

        local basePos = livePos            -- where the egg lay before we grabbed it
        local lostSince, seenBack, lastSeq = nil, 0, eggCache.seq
        local markerSince = carryMarkers and os.clock() or nil
        local tStart, lastStatus = os.clock(), 0
        local dropWhy = nil
        local everGone = (how == "scan")   -- only a scan taken AFTER the pickup can prove the listing hides carried eggs
        local staleMode = false            -- this egg keeps being listed while carried -> position checks only
        local slotWasGone, slotBackSince = false, nil
        if slotExisted then
            local a3 = Workspace:FindFirstChild("AreaEggSlotsClient")
            slotWasGone = not (a3 and X.findEggSlot(a3, uid, rec0 and rec0.NestId, rec0 and rec0.AreaId, basePos))
        end
        local fastUntil, forced = 0, false
        local bumped, seenEpoch, bumpScanAt, lastSnapT = false, pickupEpoch0, nil, 0

        while not done and (isManual or autoFarmToken == myTok) and walkToken == rtok do
            task.wait(0.1)
            if done then break end          -- the walker reported arrival while we slept: that is a delivery, never a "drop"
            local now = os.clock()
            if not carryMarkers then
                carryMarkers = scanHoldMarkers(before)              -- late-appearing object
                if carryMarkers then markerSince = now end
            end

            -- (A) BOSS BUMP: every ragdoll/stun START since the pickup counts (the epoch is bumped from Heartbeat AND
            -- StateChanged, so a hit shorter than this 0.1s poll is still seen). Re-check the egg immediately.
            if X.ragdollEpoch ~= seenEpoch then
                seenEpoch = X.ragdollEpoch
                bumped = true
                fastUntil = now + 6
                bumpScanAt = now + 0.35           -- give the server a moment to re-list a dropped egg
                if not isHoldingEgg() then X.resetVelocity() end
            end
            if bumpScanAt and now >= bumpScanAt and (not isRagdolled or now - X.lastRagdollAt > 0.6) then
                bumpScanAt = nil
                X.requestEggRefresh()
                task.delay(0.6, X.forceScan)      -- and once more, in case the re-listing is delayed
            end

            -- (B) SAFE-ZONE WATCHER, independent of the walker thread (which pauses while ragdolled).
            local dSafe = math.huge
            local rrW = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
            if rrW and math.abs(rrW.Position.Y - SAFE_ZONE.Y) <= 45 then
                dSafe = Vector3.new(SAFE_ZONE.X - rrW.Position.X, 0, SAFE_ZONE.Z - rrW.Position.Z).Magnitude
            end
            if dSafe <= X.SAFE_DETECT_RADIUS then
                arrived = true; done = true; break
            end
            if dSafe <= SAFE_SNAP_RADIUS and not isRagdolled and now - lastSnapT >= 0.25 then
                lastSnapT = now; X.snapToSafe()   -- the 50-stud teleport, now also from here (not only inside the walker)
            end

            -- (C) DROP SIGNALS (server truth; checked even while ragdolled - that is exactly when a hit drops it)
            local why = nil
            if dropEvt then why = "game event " .. dropEvt end

            if not why and slotExisted and not isHoldingEgg() then     -- (1) the egg's slot is back
                local a3 = Workspace:FindFirstChild("AreaEggSlotsClient")
                local present = a3 ~= nil and X.findEggSlot(a3, uid, rec0 and rec0.NestId, rec0 and rec0.AreaId, basePos) ~= nil
                if not present then
                    slotWasGone = true; slotBackSince = nil
                elseif slotWasGone then
                    slotBackSince = slotBackSince or now
                    if now - slotBackSince >= 0.6 then why = "egg slot reappeared" end
                end
            end

            if not why and not isHoldingEgg() and eggCache.seq ~= lastSeq then -- (2) what a scan taken AFTER the pickup says
                lastSeq = eggCache.seq
                if eggCache.tIssue >= pickupConfirmT then
                    local rec = eggCache.byUid[uid]
                    if not rec then
                        -- not listed while we carry it: the listing hides carried eggs (remember that for every later egg)
                        everGone = true; seenBack = 0; staleMode = false
                        X.snapHidesCarried = true
                    else
                        local ep = extPos(rec)
                        local afterBump = bumped and eggCache.tIssue >= X.lastRagdollAt
                        if everGone or X.snapHidesCarried then
                            -- listed again = it is lying on the ground (1 scan is enough right after a bump)
                            seenBack = seenBack + 1
                            if seenBack >= ((afterBump or now < fastUntil) and 1 or 2) then why = "egg listed in the field again" end
                        elseif afterBump and not staleMode then
                            -- listing behaviour still unknown, but we were bumped and a scan issued AFTER the hit lists the egg
                            why = "egg listed again after a boss bump"
                        else
                            -- listing keeps showing this egg while carried: only trust an egg that MOVED away from where it lay
                            if ep and basePos and (ep - basePos).Magnitude > 6 then seenBack = seenBack + 1 else seenBack = 0 end
                            if seenBack >= 2 then
                                why = "egg lying in the field again"
                            elseif seenBack == 0 and not bumped and now - pickupConfirmT >= 0.4 then
                                staleMode = true
                            end
                        end
                    end
                end
            end

            if isRagdolled then                                     -- (3) the carried object itself is gone
                lostSince = nil
            elseif not why and carryMarkers and markerSince and now - markerSince >= 0.3 then
                if markersActive(carryMarkers) then
                    lostSince = nil
                else
                    lostSince = lostSince or now
                    if now - lostSince >= (now < fastUntil and 0.3 or DROP_CONFIRM) then
                        why = "object gone: " .. tostring(carryMarkers.label)
                    end
                end
            end

            -- Ground truth: if we are holding the egg, IT CANNOT BE DROPPED!
            if isHoldingEgg() then
                why = nil
                lostSince = nil
            end

            if why then
                if dSafe <= X.SAFE_DELIVERED_RADIUS then
                    arrived = true; done = true                     -- it vanished right at the zone: that is the delivery
                else
                    dropped = true; dropWhy = why
                end
                break
            end

            if now - lastStatus >= 0.5 then
                lastStatus = now
                if isRagdolled then
                    statusLabel.Text = tag .. "Paused (ragdoll: " .. tostring(lastRagdollReason) .. ")"
                    statusLabel.TextColor3 = Color3.fromRGB(255, 180, 80)
                else
                    local d = dSafe ~= math.huge and dSafe or 0
                    statusLabel.Text = (tag .. "Returning %d studs (pickup: %s)%s"):format(d, tostring(how), bumped and " [bumped]" or "")
                    statusLabel.TextColor3 = Color3.fromRGB(100, 220, 255)
                end
            end

            -- safety net: still not there after 45s -> hop onto the safe zone
            if not forced and now - tStart > 45 then
                forced = true
                X.snapToSafe()
            end
        end
        cleanupDrop()

        -- LAST LINE OF DEFENCE: if a boss bump knocked the egg loose without any signal firing, we must not call the
        -- trip a success. Re-check the field with fresh scans; an egg still lying far from the zone = not delivered.
        local function verifyDelivered()
            if not (bumped or X.snapHidesCarried) then return nil end
            if staleMode and not X.snapHidesCarried then return nil end    -- listing shows carried eggs: can't tell
            local t0, waited, seq0, seen, absent = os.clock(), 0, eggCache.seq, 0, 0
            task.spawn(X.forceScan)
            while waited < 3 and (isManual or autoFarmToken == myTok) do
                task.wait(0.1); waited = waited + 0.1
                if eggCache.seq ~= seq0 and eggCache.tIssue >= t0 then
                    seq0 = eggCache.seq
                    local rec = eggCache.byUid[uid]
                    if not rec then
                        absent = absent + 1
                        if absent >= 2 then return nil end               -- not in the field on 2 fresh scans = delivered
                        task.spawn(X.forceScan)
                    else
                        absent = 0
                        local ep = extPos(rec)
                        if ep and Vector3.new(ep.X - SAFE_ZONE.X, 0, ep.Z - SAFE_ZONE.Z).Magnitude > 30 then
                            seen = seen + 1
                            if seen >= 2 then return "egg still lying in the field after arrival" end
                            task.spawn(X.forceScan)
                        end
                    end
                end
            end
            return nil
        end
        if arrived and not dropped then
            local vw = verifyDelivered()
            if vw and not isHoldingEgg() then dropped = true; dropWhy = vw end
        end

        if dropped then
            walkToken = walkToken + 1          -- stop walking home: never go home empty-handed
            weAreCarrying = false
            carryUid = nil
            carryMarkers = nil
            X.resetVelocity()
            X.looseUids[uid] = true                       -- v9.3: it is lying on the ground now, NOT an empty nest
            X.ignoreGone[uid] = os.clock() + 10           -- v9.4: late Gone/Carry events for it are not a theft
            X.weDropped[uid] = os.clock(); X.movingAt[uid] = nil; X.deliveredUids[uid] = nil; X.slotLostSince[uid] = nil
            X.gonePos[uid] = nil; X.vanished[uid] = nil
            X.clearMarks(uid); X.stolenN[uid] = nil
            dropRetry = { uid = uid, t = os.clock(),
                          n = ((dropRetry and dropRetry.uid == uid) and dropRetry.n or 0) + 1 }
            lastFailReason = tag .. "Egg dropped (" .. tostring(dropWhy) .. ") — picking it up again..."
            warn(tag .. "drop detected:", dropWhy)
            X.requestEggRefresh()
            finish(false); return
        end
        if not arrived then walkToken = walkToken + 1 end
        if arrived then
            X.deliverWait(myTok)                -- snap onto the zone + wait until the carried object is consumed
            weAreCarrying = false
            carryUid = nil
            carryMarkers = nil
            dropRetry = nil
            X.resetVelocity()                   -- v9.6: delivered -> back to the default velocity right away
            statusLabel.Text = tag .. "Safe zone ✓"
            statusLabel.TextColor3 = Color3.fromRGB(120, 255, 150)
        end                                     -- (not arrived: the loop's gate finishes the delivery)
        X.requestEggRefresh()                   -- redraw the egg list now instead of waiting for luck
        finish(arrived)
    end, { snapRadius = SNAP_RADIUS, snapBeside = true, stuckHop = true })

    while not completed and (isManual or autoFarmToken == myTok) and (walkToken == walkTok or (rtok and walkToken == rtok)) do task.wait(0.15) end
    if not isManual and autoFarmToken ~= myTok then walkToken = walkToken + 1 end
    return result
end

-- ==================================================
-- MANUAL GET (SINGLE-STEP AUTOFARM)
-- ==================================================
local function getEgg(pos, uid, sl)
    if typeof(pos) ~= "Vector3" then return end
    if autoFarmEnabled then toggleAutoFarm() end
    walkToken = walkToken + 1
    local myTok = walkToken
    task.spawn(function()
        local ok = autoGetEgg(uid, pos, myTok, true)
        while not ok and dropRetry and dropRetry.uid == uid and dropRetry.n <= 3 and walkToken == myTok do
            task.wait(0.3)
            if walkToken ~= myTok then break end
            local cur = eggCache.byUid[uid]
            local p = cur and extPos(cur) or pos
            ok = autoGetEgg(uid, p, myTok, true)
        end
    end)
end

-- Priority: Divine -> Eternal -> Secret -> farthest
-- STEAL OPPORTUNITY: When near safe zone, if any target egg is loose on ground nearby (<80 studs), steal it!
function X.pickNearest(records)
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local myPos = root and root.Position
    if not myPos then return nil end
    local hasR = X.hasRarity()

    -- 1. STEAL OPPORTUNITY:
    -- If we are at or near the safe zone, check if any matching egg is loose/on the ground nearby (< 80 studs)
    -- and NOT carried by another player. Grab it immediately before someone else does!
    local dToSafe = Vector3.new(myPos.X - SAFE_ZONE.X, 0, myPos.Z - SAFE_ZONE.Z).Magnitude
    if dToSafe <= 60 then
        local bestSteal, bestStealTier, bestStealDist = nil, math.huge, math.huge
        for _, r in ipairs(records) do
            if passesFilters(r) then
                local u = tostring(r.Uid or "")
                if not X.isCarriedByOther(u) then
                    local p = extPos(r)
                    if p then
                        local dEgg = Vector3.new(p.X - myPos.X, 0, p.Z - myPos.Z).Magnitude
                        -- Close (< 80 studs) and pickable on the ground (loose / dropped / outside nest)
                        local isGround = X.looseUids[u] or (p - SAFE_ZONE).Magnitude <= 80 or (X.nestPos[u] and (p - X.nestPos[u]).Magnitude > 6)
                        if dEgg <= 80 and isGround then
                            local tier = (hasR and X.eggTier(r) or 0) + (X.isUnverified(r) and 100 or 0)
                            if tier < bestStealTier or (tier == bestStealTier and dEgg < bestStealDist) then
                                bestSteal, bestStealTier, bestStealDist = r, tier, dEgg
                            end
                        end
                    end
                end
            end
        end
        if bestSteal then
            return bestSteal, bestStealTier, true
        end
    end

    -- 2. Standard Selection:
    -- Divine -> Eternal -> Secret -> farthest
    local best, bestTier, bestDist = nil, math.huge, 0
    for _, r in ipairs(records) do
        if passesFilters(r) then
            local u = tostring(r.Uid or "")
            if not X.isCarriedByOther(u) then
                local p = extPos(r)
                if p then
                    local dx = p.X - myPos.X
                    local dy = p.Y - myPos.Y
                    local dz = p.Z - myPos.Z
                    local d = math.sqrt(dx*dx + dz*dz + dy*dy*0.25)
                    local tier = (hasR and X.eggTier(r) or 0) + (X.isUnverified(r) and 100 or 0)
                    -- Within the same tier, always pick the FARTHEST egg (farthest gives more)
                    if tier < bestTier or (tier == bestTier and d > bestDist) then
                        best, bestTier, bestDist = r, tier, d
                    end
                end
            end
        end
    end
    return best, best and bestTier or nil, false
end

local function autoFarmLoop()
    autoFarmToken = autoFarmToken + 1
    local myTok = autoFarmToken
    weAreCarrying = false; carryUid = nil; carryMarkers = nil   -- a fresh start never assumes we hold an egg
    X.resetVelocity()
    startEggScanner()                                          -- constant 1s egg scan (idempotent)

    -- Wait for character to exist before starting
    local startWait = 0
    while autoFarmEnabled and autoFarmToken == myTok and (not LocalPlayer.Character or not LocalPlayer.Character:FindFirstChild("HumanoidRootPart")) do
        task.wait(0.25); startWait = startWait + 0.25
        if startWait > 10 then
            statusLabel.Text = "[AutoFarm] Waiting for character..."
            statusLabel.TextColor3 = Color3.fromRGB(255, 200, 100)
        end
    end
    if not autoFarmEnabled or autoFarmToken ~= myTok then return end

    while autoFarmEnabled and autoFarmToken == myTok do
        local skip = false

        if isRagdolled then
            task.wait(0.3)
            skip = true
        end

        if not skip then
            -- Make sure we have a character
            local ch = LocalPlayer.Character
            if not ch or not ch:FindFirstChild("HumanoidRootPart") then
                task.wait(0.3); skip = true
            end
        end

        -- Only if a pickup of OURS is still undelivered AND the egg is still really in our hands
        if not skip and weAreCarrying then
            if stillCarrying() then
                statusLabel.Text = "[AutoFarm] Delivering carried egg..."
                statusLabel.TextColor3 = Color3.fromRGB(255, 220, 100)
                X.switchToCarry()
                if autoReturnEnabled then walkSync(SAFE_ZONE, SAFE_ARRIVE_RADIUS, myTok, { stuckHop = true, snapRadius = SAFE_SNAP_RADIUS }) end
                if carryMarkers or isHoldingEgg() then X.deliverWait(myTok) end
                X.requestEggRefresh()
            end
            weAreCarrying = false          -- one attempt, then move on (never return empty-handed)
            carryUid = nil
            carryMarkers = nil
            dropRetry = nil
            X.resetVelocity()
            skip = true
        end

        if not skip then
            statusLabel.Text = "[AutoFarm] Scanning..."
            statusLabel.TextColor3 = Color3.fromRGB(100, 220, 255)

            -- read the constant 1s scan cache (wait briefly for the first/next scan if needed)
            local wq = 0
            while autoFarmEnabled and autoFarmToken == myTok
                  and (not eggCache.records or os.clock() - eggCache.t > 3) and wq < 4 do
                task.wait(0.1); wq = wq + 0.1
            end
            local records, err = eggCache.records, eggCache.err
            if records and os.clock() - eggCache.t > 3 then records = nil; err = err or "scan stale" end
            if not records then
                statusLabel.Text = "[AutoFarm] Scan error: " .. tostring(err)
                statusLabel.TextColor3 = Color3.fromRGB(255, 180, 80)
                task.wait(1.5)
                skip = true
            end

            if not skip then
                -- An egg we just DROPPED gets fetched again before anything else
                local target, waitingDrop = nil, false
                local isSteal = false
                if dropRetry then
                    if dropRetry.n > 4 or os.clock() - dropRetry.t > 30 then
                        dropRetry = nil
                    else
                        target = eggCache.byUid[dropRetry.uid]
                        if not target and os.clock() - dropRetry.t < 6 then waitingDrop = true end
                    end
                end
                if not waitingDrop and not target and not skip then
                    local dist; target, dist, isSteal = X.pickNearest(records)
                end
                if waitingDrop then
                    statusLabel.Text = "[AutoFarm] Waiting for the dropped egg to reappear..."
                    statusLabel.TextColor3 = Color3.fromRGB(255, 220, 100)
                    task.wait(0.3)
                    skip = true
                elseif not target and not skip then
                    statusLabel.Text = "[AutoFarm] No matching eggs — waiting..."
                    statusLabel.TextColor3 = Color3.fromRGB(255, 200, 100)
                    local w = 0
                    while w < AUTO_EMPTY_WAIT and autoFarmEnabled and autoFarmToken == myTok do
                        task.wait(0.25); w = w + 0.25
                    end
                    skip = true
                elseif target and not skip then
                    local pos = extPos(target)
                    local uid = tostring(target.Uid or "")
                    local sp  = tostring(target.AssetCategory or "?")
                    if not pos then
                        task.wait(0.5)
                        skip = true
                    else
                        if isSteal then
                            statusLabel.Text = "[AutoFarm] STEAL -> " .. sp .. " (" .. effectiveRarity(target) .. ")"
                            statusLabel.TextColor3 = Color3.fromRGB(255, 215, 0)
                        else
                            statusLabel.Text = "[AutoFarm] -> " .. sp .. " (" .. effectiveRarity(target) .. ")"
                            statusLabel.TextColor3 = Color3.fromRGB(100, 220, 255)
                        end

                        local ok = autoGetEgg(uid, pos, myTok)
                        X.resetVelocity()          -- v9: egg finished (success or not) -> back to the default velocity
                        if ok then
                            dropRetry = nil
                            statusLabel.Text = "[AutoFarm] OK " .. sp
                            statusLabel.TextColor3 = Color3.fromRGB(120, 255, 150)
                        elseif isHoldingEgg() then
                            -- We are still holding it! Don't retry from start, deliver it!
                            weAreCarrying = true
                            dropRetry = nil
                            statusLabel.Text = "[AutoFarm] Holding egg — delivering..."
                            statusLabel.TextColor3 = Color3.fromRGB(255, 220, 100)
                        else
                            statusLabel.Text = lastFailReason or "[AutoFarm] failed/skipped — next..."
                            lastFailReason = nil
                            statusLabel.TextColor3 = Color3.fromRGB(255, 180, 80)
                        end

                        -- Neutralise egg physics if still holding (defensive)
                        local cch = LocalPlayer.Character
                        if cch then neutraliseEggPhysics(cch) end

                        local w = 0
                        while w < (dropRetry and 0.1 or AUTO_NEXT_DELAY) and autoFarmEnabled and autoFarmToken == myTok do
                            task.wait(0.1); w = w + 0.1
                        end
                    end
                end
            end
        end
    end

    statusLabel.Text = "[AutoFarm] Stopped"
    statusLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
end

local function toggleAutoFarm()
    local ok, err = pcall(function()
        autoFarmEnabled = not autoFarmEnabled
        if autoFarmEnabled then
            if autoFarmBtn then
                autoFarmBtn.Text = "[ON] AutoFarm"
                autoFarmBtn.BackgroundColor3 = Color3.fromRGB(35, 135, 75)
                autoFarmBtn.TextColor3 = Color3.fromRGB(220, 255, 220)
            end
            walkToken = walkToken + 1
            autoFarmToken = autoFarmToken + 1
            if statusLabel then
                statusLabel.Text = "[AutoFarm] Starting..."
                statusLabel.TextColor3 = Color3.fromRGB(100, 220, 255)
            end
            task.spawn(function()
                local okLoop, e2 = pcall(autoFarmLoop)
                if not okLoop then
                    autoFarmEnabled = false
                    if autoFarmBtn then
                        autoFarmBtn.Text = "[OFF] AutoFarm"
                        autoFarmBtn.BackgroundColor3 = Color3.fromRGB(90, 50, 50)
                        autoFarmBtn.TextColor3 = Color3.new(1, 1, 1)
                    end
                    if statusLabel then
                        statusLabel.Text = "[AutoFarm] ERROR: " .. tostring(e2)
                        statusLabel.TextColor3 = Color3.fromRGB(255, 80, 80)
                    end
                    warn("[AutoFarm] loop error:", e2)
                end
            end)
        else
            if autoFarmBtn then
                autoFarmBtn.Text = "[OFF] AutoFarm"
                autoFarmBtn.BackgroundColor3 = Color3.fromRGB(90, 50, 50)
                autoFarmBtn.TextColor3 = Color3.new(1, 1, 1)
            end
            autoFarmToken = autoFarmToken + 1
            walkToken = walkToken + 1
            if statusLabel then
                statusLabel.Text = "[AutoFarm] Stopping..."
                statusLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
            end
        end
    end)
    if not ok then
        warn("[AutoFarm] toggle error:", err)
        if statusLabel then
            statusLabel.Text = "[AutoFarm] Toggle error: " .. tostring(err)
            statusLabel.TextColor3 = Color3.fromRGB(255, 80, 80)
        end
    end
end

-- ==================================================
-- RECOVERY ROUTINE
-- ==================================================
local function recoveryRoutine(h, r)
    if recoveryActive then return end
    recoveryActive = true
    local ch = h.Parent
    if not ch then recoveryActive = false; return end
    if lastGoodCFrame and r and r.Parent then X.markTeleport(); pcall(function() r.CFrame = lastGoodCFrame end) end

    local anchored = false
    pcall(function()
        r.AssemblyLinearVelocity = Vector3.new()
        r.AssemblyAngularVelocity = Vector3.new()
        r.Anchored = true
        anchored = true
    end)
    local function rel()
        if anchored and r and r.Parent then pcall(function() r.Anchored = false end); anchored = false end
    end

    local hs = os.clock()
    while os.clock() - hs < RAGDOLL_HOLD_TIME do
        if not recoveryEnabled then rel(); recoveryActive = false; return end
        task.wait()
    end
    if not recoveryEnabled then rel(); recoveryActive = false; return end
    recoveryState = RECOVERY_STATE.RECOVERING

    for _, o in ipairs(ch:GetDescendants()) do
        if o:IsA("Motor6D") and not o.Enabled then pcall(function() o.Enabled = true end) end
    end
    pcall(function() h.PlatformStand = false; h.Sit = false; h.AutoRotate = true end)
    pcall(function()
        h:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, true)
        h:SetStateEnabled(Enum.HumanoidStateType.FallingDown, true)
        h:SetStateEnabled(Enum.HumanoidStateType.Physics, true)
    end)
    rel()
    pcall(function() h:ChangeState(Enum.HumanoidStateType.GettingUp) end)
    task.wait(0.1)
    if h.Parent then pcall(function() h:ChangeState(Enum.HumanoidStateType.Running) end) end

    local w = 0
    while getRagdollReason(h) and w < 2 do task.wait(0.1); w = w + 0.1 end
    recoveryActive = false
end

local function applyRecovery()
    if not recoveryEnabled then return end
    local ch = LocalPlayer.Character
    local h = ch and ch:FindFirstChildOfClass("Humanoid")
    local r = ch and ch:FindFirstChild("HumanoidRootPart")
    if not h or not r then return end
    local reason = getRagdollReason(h)
    if reason and not ragdollStale then
        if recoveryState == RECOVERY_STATE.NONE then
            recoveryState = RECOVERY_STATE.RAGDOLLED
            if h.MoveDirection.Magnitude > 0.05 then lastMoveDirection = h.MoveDirection.Unit end
            task.spawn(recoveryRoutine, h, r)
        end
        if not r.Anchored then
            local hz = Vector3.new(r.AssemblyLinearVelocity.X,0,r.AssemblyLinearVelocity.Z)
            if hz.Magnitude > 2 then pcall(function() r.AssemblyLinearVelocity = Vector3.new(0,r.AssemblyLinearVelocity.Y,0) end) end
        end
    else
        if recoveryState ~= RECOVERY_STATE.NONE then recoveryState = RECOVERY_STATE.NONE end
    end
end

local function bindFastRagdoll(h, r)
    return h.StateChanged:Connect(function(_, ns)
        local isRagState = ns == Enum.HumanoidStateType.Ragdoll
            or ns == Enum.HumanoidStateType.FallingDown
            or ns == Enum.HumanoidStateType.Physics
        if isRagState then X.ragdollEpoch = X.ragdollEpoch + 1; X.lastRagdollAt = os.clock() end   -- v8: a hit is counted even with Recovery off
        if not recoveryEnabled then return end
        if recoveryState ~= RECOVERY_STATE.NONE then return end
        if isRagState then
            recoveryState = RECOVERY_STATE.RAGDOLLED
            if h.MoveDirection.Magnitude > 0.05 then lastMoveDirection = h.MoveDirection.Unit end
            task.spawn(recoveryRoutine, h, r)
        end
    end)
end

-- ==================================================
-- VELOCITY ENGINE
-- ==================================================
local function applyVelocity()
    if not velocityEnabled then return end
    local ch = LocalPlayer.Character
    local h = ch and ch:FindFirstChildOfClass("Humanoid")
    local r = ch and ch:FindFirstChild("HumanoidRootPart")
    if not h or not r then return end
    if isRagdolled then
        wasRagdolledForVelocity = true
        if h.MoveDirection.Magnitude > 0.05 then lastMoveDirection = h.MoveDirection.Unit end
        if not r.Anchored then
            local hz = Vector3.new(r.AssemblyLinearVelocity.X,0,r.AssemblyLinearVelocity.Z)
            if hz.Magnitude > 2 then pcall(function() r.AssemblyLinearVelocity = Vector3.new(0,r.AssemblyLinearVelocity.Y,0) end) end
        end
        return
    end
    if wasRagdolledForVelocity then
        wasRagdolledForVelocity = false
        pcall(function() h.WalkSpeed = targetVelocity end)
        if lastMoveDirection.Magnitude > 0.05 then
            pcall(function() r.AssemblyLinearVelocity = Vector3.new(
                lastMoveDirection.X * targetVelocity,
                r.AssemblyLinearVelocity.Y,
                lastMoveDirection.Z * targetVelocity) end)
        end
    end
    local isCarryingNow = weAreCarrying or isHoldingEgg()
    if isCarryingNow then
        neutraliseEggPhysics(ch)
        if targetVelocity > X.baseCarryVelocity then
            targetVelocity = X.baseCarryVelocity
        end
    end
    if h.WalkSpeed ~= targetVelocity then pcall(function() h.WalkSpeed = targetVelocity end) end
    if h.MoveDirection.Magnitude > 0.05 then
        local d = h.MoveDirection.Unit
        lastMoveDirection = d
        r.AssemblyLinearVelocity = Vector3.new(d.X*targetVelocity, r.AssemblyLinearVelocity.Y, d.Z*targetVelocity)
    end
end

-- v9: RUBBERBAND DETECTOR. The server yanks us back to an older position; that shows up as a big one-frame
-- displacement AGAINST the direction we are trying to move. Each one lowers the velocity by 10 (min 100);
-- X.resetVelocity() restores the user's value after the egg / at the next target. Only watched while a farm or
-- manual Get trip is running, and never for our own teleports, ragdolls or recoveries.
X.rbHist = {}        -- v9.9: recent {t, speed} samples
X.rbWallAt = 0       -- v9.9: last time something solid was right in front of us
X.rbGate = "off"     -- v9.9: shown in the velocity line
X.rbSpd = nil

function X.detectRubberband()
    local ch = LocalPlayer.Character
    local h  = ch and ch:FindFirstChildOfClass("Humanoid")
    local r  = ch and ch:FindFirstChild("HumanoidRootPart")
    if not velocityEnabled or not h or not r or not (autoFarmEnabled or os.clock() < X.tripUntil) then
        X.rbLastPos = nil; X.rbLastDir = nil; X.rbSamples = {}; X.rbHist = {}; X.rbGate = "off"; X.rbSpd = nil; return
    end
    local now  = os.clock()
    local pos  = r.Position
    local last = X.rbLastPos
    local lastT = X.rbLastT
    X.rbLastPos = pos; X.rbLastT = now

    -- direction we are trying to travel: MoveDirection, else our own recent movement
    local md
    if h.MoveDirection.Magnitude >= 0.05 then
        md = h.MoveDirection.Unit
        if X.rbLastDir and X.rbLastDir:Dot(md) < 0.85 then X.rbSamples = {}; X.rbHist = {} end   -- turned: not comparable
        X.rbLastDir = md; X.rbLastDirT = now
    elseif X.rbLastDir and now - (X.rbLastDirT or 0) < 0.4 then
        md = X.rbLastDir
    else
        X.rbLastDir = nil; X.rbSamples = {}; X.rbHist = {}; X.rbGate = "idle"; X.rbSpd = nil; return
    end
    if not last or not lastT then return end
    local dt = math.max(now - lastT, 1/240)
    if dt > 0.25 then X.rbSamples = {}; X.rbHist = {}; return end        -- lag spike / tab freeze

    if isRagdolled or recoveryActive or r.Anchored or now < X.ignoreJumpUntil or now - X.lastRagdollAt < 0.8 then
        X.rbSamples = {}; X.rbHist = {}; X.rbGate = "ign"; return        -- our own teleports / hits / recovery
    end
    X.rbGate = "ok"

    local smp = X.rbSamples
    smp[#smp + 1] = { t = now, p = pos }
    while #smp > 1 and now - smp[1].t > X.RUBBER_WINDOW do table.remove(smp, 1) end

    -- solid thing right in front of us? (a wall only stalls us - that is not a rubberband)
    do
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = { ch }
        local ok, hit = pcall(function() return Workspace:Raycast(pos, md * 9, params) end)
        if ok and hit and hit.Instance and hit.Instance.CanCollide then X.rbWallAt = now end
    end

    -- ---- (A) snap back: where we ended up vs where we were heading -------------------------------------------
    local disp = Vector3.new(pos.X - last.X, 0, pos.Z - last.Z)
    local vel  = Vector3.new(r.AssemblyLinearVelocity.X, 0, r.AssemblyLinearVelocity.Z)
    local dev  = disp - vel * dt
    local back = -(disp:Dot(md))
    local devBack = -(dev:Dot(md))
    local why = nil
    if back >= X.RUBBER_BACK then
        why = ("%.0f studs back in one frame"):format(back)
    elseif back >= 3 and devBack >= X.RUBBER_BACK + 6 and dev.Magnitude >= X.RUBBER_BACK + 6 then
        why = ("%.0f studs behind where our velocity should be"):format(devBack)
    end
    if not why and #smp >= 6 and smp[#smp].t - smp[1].t >= 0.35 then
        local d = Vector3.new(pos.X - smp[1].p.X, 0, pos.Z - smp[1].p.Z)
        local net = -(d:Dot(md))
        if net >= X.RUBBER_NET_BACK then why = ("%.0f studs back over %.1fs"):format(net, smp[#smp].t - smp[1].t) end
    end

    -- ---- (B) slow-down: speed over the last ~0.45s collapsed compared with a moment ago -------------------------
    local spd = nil
    do
        local first
        for i = 1, #smp do if now - smp[i].t <= 0.45 then first = smp[i]; break end end
        if first and now - first.t >= 0.35 then
            local d = Vector3.new(pos.X - first.p.X, 0, pos.Z - first.p.Z)
            spd = d:Dot(md) / (now - first.t)
        end
    end
    X.rbSpd = spd
    if spd then
        local hist = X.rbHist
        hist[#hist + 1] = { t = now, v = spd }
        while #hist > 1 and now - hist[1].t > 3 do table.remove(hist, 1) end
        if not why then
            local base = 0
            for i = 1, #hist do
                if now - hist[i].t >= 0.5 and hist[i].v > base then base = hist[i].v end
            end
            if base >= 0.5 * targetVelocity and base >= 60 and spd < 0.5 * base and now - X.rbWallAt > 0.6 then
                why = ("speed fell %.0f -> %.0f studs/s"):format(base, spd)
            end
        end
    end

    if not why then
        local nm = math.max(back, devBack)
        if nm >= 3 and now - (X.rbNearLog or 0) > 1 then
            X.rbNearLog = now
            print(("[EggGoToUI] near-miss: %.1f back (limit %d), dev %.1f"):format(nm, X.RUBBER_BACK, dev.Magnitude))
        end
        return
    end
    if now < X.rbCooldownUntil then return end

    X.rbCooldownUntil = now + 0.6
    X.rbSamples = {}; X.rbHist = {}
    X.rubberCount = X.rubberCount + 1
    local nv = math.max(X.MIN_VELOCITY, targetVelocity - X.VELOCITY_STEP)
    warn(("[EggGoToUI] rubberband #%d (%s) -> velocity %d -> %d"):format(X.rubberCount, why, targetVelocity, nv))
    if nv ~= targetVelocity then
        targetVelocity = nv
        pcall(function() h.WalkSpeed = nv end)
        if upVelBtn then pcall(upVelBtn) end
    end
end

local function enableVelocity()
    local ch = LocalPlayer.Character
    local h = ch and ch:FindFirstChildOfClass("Humanoid")
    if h then savedWalkSpeed = h.WalkSpeed end
    setFrictionless(true)
    if h then pcall(function() h.WalkSpeed = targetVelocity end) end
end
local function disableVelocity()
    setFrictionless(false)
    local ch = LocalPlayer.Character
    local h = ch and ch:FindFirstChildOfClass("Humanoid")
    if h then pcall(function() h.WalkSpeed = savedWalkSpeed end) end
end

-- ==================================================
-- UI FORWARD DECLARATIONS (Shared across tabs and handlers)
-- ==================================================
local screenGui
local main
local menuToggleBtn
local closeBtn
local tabEggs
local tabPets
local tabBtnEggs
local tabBtnPets
local switchTab
local velToggleBtn
local velInputBox
local velInputStroke
local carryVelInputBox
local carryInputStroke
local recoveryToggleBtn
local velStatusLabel
local farmDropdownBtn
local farmDropdownList
local farmSearchBox
local farmDropScroll
local farmDropdownOpen = false
local jsonLabel
local jsonBox
local refreshBtn
local copyBtn
local loadBtn
local listFrame
local refreshPetCards
local updateFarmBtnText
local rebuildFarmDropdownItems
local refilterAndRender
local upVelIn
local upCarryVelIn
local toggleMenuVisible
local logAuto

-- ==================================================
-- TAB 2 BUILDER
-- ==================================================
local function buildPetsTabUI()
-- ==================================================
-- TAB 2: PETS & AUTOMATION SUITE
-- ==================================================
local tabPetsLayout = Instance.new("UIListLayout")
tabPetsLayout.Padding = UDim.new(0, 8)
tabPetsLayout.SortOrder = Enum.SortOrder.LayoutOrder
tabPetsLayout.Parent = tabPets

local tabPetsPad = Instance.new("UIPadding")
tabPetsPad.PaddingTop = UDim.new(0, 8)
tabPetsPad.PaddingBottom = UDim.new(0, 12)
tabPetsPad.PaddingLeft = UDim.new(0, 10)
tabPetsPad.PaddingRight = UDim.new(0, 10)
tabPetsPad.Parent = tabPets

-- Networking helper
local function getNetRemote(name)
    local ok, rem = pcall(function()
        local net = ReplicatedStorage:FindFirstChild("Packages")
            and ReplicatedStorage.Packages:FindFirstChild("Networking")
        if net then
            local direct = net:FindFirstChild(name)
            if direct then return direct end
            local cur = net
            for part in string.gmatch(name, "[^/]+") do
                cur = cur and cur:FindFirstChild(part)
            end
            if cur then return cur end
        end
        local anyDirect = ReplicatedStorage:FindFirstChild(name, true)
        if anyDirect then return anyDirect end
        local leafName = name:match("([^/]+)$") or name
        return ReplicatedStorage:FindFirstChild(leafName, true)
    end)
    return ok and rem or nil
end

-- Fusery Automation State
local autoFuseEnabled = false
local fuseRarityThreshold = "Rare"
local FUSE_THRESHOLDS = { "Common", "Uncommon", "Rare", "Epic" }

-- Inventory Metrics State
local invTotalPets = 0
local invEquippedPets = 0
local invUnequippedPets = 0
local invTotalEggs = 0
local invPetsLabel = nil
local invEggsLabel = nil

local function formatStatNumber(val)
    if typeof(val) == "string" then return val end
    if typeof(val) ~= "number" then return nil end
    local absVal = math.abs(val)
    if absVal >= 1e12 then
        return string.format("%.1fT", val / 1e12)
    elseif absVal >= 1e9 then
        return string.format("%.1fB", val / 1e9)
    elseif absVal >= 1e6 then
        return string.format("%.1fM", val / 1e6)
    elseif absVal >= 1e3 then
        return string.format("%.1fK", val / 1e3)
    elseif absVal >= 10 then
        return string.format("%.1f", val)
    else
        return string.format("%.2f", val)
    end
end

local function formatPetWeight(weightVal, scaleVal)
    if type(weightVal) == "string" then
        local kgStr = weightVal:match("([%d,]+)%s*[Kk][Gg]")
        if kgStr then
            local numOnly = kgStr:gsub(",", "")
            local n = tonumber(numOnly)
            if n and n > 0 then
                local formatted = tostring(math.round(n))
                local k
                while true do
                    formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", "%1,%2")
                    if k == 0 then break end
                end
                return formatted .. "Kg", n
            end
        end
    end
    local rawW = tonumber(weightVal) or 0
    if rawW <= 0 then return "-- kg", 0 end
    local s = tonumber(scaleVal) or 1
    -- Authoritative game formula: DisplayWeight = math.round(Weight * Scale^2)
    local finalW = math.round(rawW * (s * s))
    local formatted = tostring(finalW)
    local k
    while true do
        formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", "%1,%2")
        if k == 0 then break end
    end
    return formatted .. "Kg", finalW
end

local function extractPetStats(petData, inst)
    local earn = nil
    local weight = nil
    local weightNum = 0

    if type(petData) == "table" then
        local rawEarn = petData["Money/s"] or petData.EarnRate or petData.MoneyRate or petData.Earn or petData.Rate or petData.Income or petData.CoinsPerSec or petData.CoinsPerSecond or petData.Cps or petData.Production
        if rawEarn ~= nil then
            if type(rawEarn) == "number" then
                earn = "+" .. formatStatNumber(rawEarn) .. "/s"
            else
                earn = tostring(rawEarn)
                if not string.find(earn, "/s") then earn = earn .. "/s" end
            end
        end

        local rawWeight = petData.Weight or petData.Mass or petData.Kg or petData.Size
        if rawWeight ~= nil then
            local scale = petData.Scale
            weight, weightNum = formatPetWeight(rawWeight, scale)
        end
    end

    if inst and (not earn or not weight or weight == "-- kg") then
        pcall(function()
            local attrs = inst:GetAttributes() or {}
            if not earn then
                local aEarn = attrs["Money/s"] or attrs.EarnRate or attrs.MoneyRate or attrs.Earn or attrs.Rate or attrs.Income
                if aEarn ~= nil then
                    if type(aEarn) == "number" then
                        earn = "+" .. formatStatNumber(aEarn) .. "/s"
                    else
                        earn = tostring(aEarn)
                        if not string.find(earn, "/s") then earn = earn .. "/s" end
                    end
                end
            end
            if not weight or weight == "-- kg" then
                local aWeight = attrs.Weight or attrs.Mass or attrs.Kg or attrs.Size
                if aWeight ~= nil then
                    local scale = attrs.Scale
                    weight, weightNum = formatPetWeight(aWeight, scale)
                end
            end
            if (not earn or not weight or weight == "-- kg") and inst:IsA("GuiObject") then
                for _, desc in ipairs(inst:GetDescendants()) do
                    if desc:IsA("TextLabel") and desc.Visible and #desc.Text > 0 then
                        local t = desc.Text
                        if not earn and (string.find(t, "/s") or string.find(t, "/sec")) then
                            earn = t
                        end
                        if (not weight or weight == "-- kg") and (string.find(t:lower(), "kg") or string.find(t:lower(), "lbs")) then
                            local wStr, wN = formatPetWeight(t, 1)
                            if wN > 0 then
                                weight = wStr
                                weightNum = wN
                            end
                        end
                    end
                end
            end
        end)
    end

    return earn or "--/s", weight or "-- kg", weightNum
end

local function countInventoryEggs()
    -- 1. Client EggState module (Instant local client read, 0 network latency)
    local clientFolder = ReplicatedStorage:FindFirstChild("Client")
    local eggStateMod = clientFolder and clientFolder:FindFirstChild("EggState")
    if eggStateMod and eggStateMod:IsA("ModuleScript") then
        local ok, eggState = pcall(function() return require(eggStateMod) end)
        if ok and type(eggState) == "table" and type(eggState.ReadOwnedEggs) == "function" then
            local okSnap, snap = pcall(eggState.ReadOwnedEggs)
            if okSnap and type(snap) == "table" then
                for _, pData in pairs(snap) do
                    if type(pData) == "table" and (pData.OwnerUserId == LocalPlayer.UserId or tostring(pData.OwnerUserId) == tostring(LocalPlayer.UserId)) then
                        local recs = pData.Records or pData
                        if type(recs) == "table" then
                            local c = 0
                            for _ in pairs(recs) do c = c + 1 end
                            if c > 0 then return c end
                        end
                    end
                end
            end
        end
    end

    -- 2. RF/EggWorld/AskLiveSnapshot remote
    local rfEggSnap = getNetRemote("RF/EggWorld/AskLiveSnapshot")
    if rfEggSnap then
        local ok, snap = pcall(function() return rfEggSnap:InvokeServer() end)
        if ok and type(snap) == "table" then
            for _, pData in pairs(snap) do
                if type(pData) == "table" and (pData.OwnerUserId == LocalPlayer.UserId or tostring(pData.OwnerUserId) == tostring(LocalPlayer.UserId)) then
                    local recs = pData.Records or pData
                    if type(recs) == "table" then
                        local c = 0
                        for _ in pairs(recs) do c = c + 1 end
                        if c > 0 then return c end
                    end
                end
            end
        end
    end

    -- 3. RF/ProfileMirror/FetchProfile(LocalPlayer).EggInventory
    local rfProfile = getNetRemote("RF/ProfileMirror/FetchProfile")
    if rfProfile then
        local ok, prof = pcall(function() return rfProfile:InvokeServer(LocalPlayer) end)
        if ok and type(prof) == "table" and type(prof.EggInventory) == "table" then
            local c = 0
            for _ in pairs(prof.EggInventory) do c = c + 1 end
            if c > 0 then return c end
        end
    end

    -- 4. Fallback: Tools in Backpack & Character
    local count = 0
    local seen = {}
    if typeof(isHoldingEgg) == "function" and isHoldingEgg() then
        count = count + 1
    end
    local function checkContainerForEggs(cont)
        if not cont then return end
        for _, t in ipairs(cont:GetChildren()) do
            if t:IsA("Tool") then
                local attrs = t:GetAttributes() or {}
                local dName = attrs.DisplayName or t.Name
                local low = string.lower(dName)
                local isEgg = string.find(low, "egg") ~= nil or attrs.Category == "Egg" or string.find(string.lower(t.Name), "egg") ~= nil
                if isEgg then
                    local u = tostring(attrs.UID or attrs.Uid or attrs.Id or t.Name)
                    if not seen[u] then
                        seen[u] = true
                        count = count + 1
                    end
                end
            end
        end
    end
    checkContainerForEggs(LocalPlayer:FindFirstChild("Backpack"))
    checkContainerForEggs(LocalPlayer.Character)

    return count
end

local function updateInventorySummaryUI()
    invTotalEggs = countInventoryEggs()
    if invPetsLabel then
        invPetsLabel.Text = string.format("🐾 Total Pets: %d   (%d Free, %d Equipped)", invTotalPets, invUnequippedPets, invEquippedPets)
    end
    if invEggsLabel then
        invEggsLabel.Text = string.format("🥚 Total Eggs: %d in inventory", invTotalEggs)
    end
end


local selectedFuseSpecies = nil
local eligibleFusePets = {}
local checkedPetUids = {}
local updateFuseSelectorUI = nil
local fuseHeaderBadge = nil

local function scanEligibleFusePets()
    local equippedUids = {}
    local equippedNames = {}
    local equippedEarnRates = {}

    -- 1. PenRoster AskLiveSnapshot for equipped pets (matches LocalPlayer.UserId records)
    local rfPen = getNetRemote("RF/PenRoster/AskLiveSnapshot")
    if rfPen then
        local ok, snap = pcall(function() return rfPen:InvokeServer() end)
        if ok and type(snap) == "table" then
            for _, pData in pairs(snap) do
                if type(pData) == "table" and (pData.OwnerUserId == LocalPlayer.UserId or tostring(pData.OwnerUserId) == tostring(LocalPlayer.UserId)) then
                    local records = pData.Records or pData
                    if type(records) == "table" then
                        for petUid, petRec in pairs(records) do
                            local uStr = tostring(petUid)
                            equippedUids[uStr] = true
                            if type(petRec) == "table" then
                                local sp = petRec.Species or petRec.Name or petRec.PetType
                                if sp then equippedNames[sp] = (equippedNames[sp] or 0) + 1 end
                            end
                        end
                    end
                end
            end
        end
    end

    -- 2. PlayerGui.ActivePets.Frame.ScrollingFrame for live equipped pet slots and earn rates
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    local activePetsGui = pg and pg:FindFirstChild("ActivePets")
    local activeSf = activePetsGui and activePetsGui:FindFirstChild("ScrollingFrame", true)
    if activeSf then
        for _, f in ipairs(activeSf:GetChildren()) do
            local uid = f.Name:match("^Pet_(%x+)$")
            if uid then
                equippedUids[uid] = true
                for _, d in ipairs(f:GetDescendants()) do
                    if d:IsA("TextLabel") and d.Text ~= "" then
                        local earnMatch = d.Text:match("%$[%d%.]+%a*/s")
                        if earnMatch then
                            equippedEarnRates[uid] = earnMatch
                        end
                    end
                end
            end
        end
    end

    -- 3. Gather all owned pets from Backpack & Character Tools (PRIMARY GROUND TRUTH)
    local rawPets = {}
    local sourceBreakdown = {}
    local seenUids = {}

    local function scanToolContainer(container, srcName)
        if not container then return end
        for _, tool in ipairs(container:GetChildren()) do
            if tool:IsA("Tool") then
                local attrs = tool:GetAttributes() or {}
                local itemType = attrs.ItemType or ""
                local isGear = attrs.GearName ~= nil or itemType == "Gear" or attrs.IsBat == true
                if not isGear then
                    local dName = attrs.DisplayName or tool.Name
                    local isEgg = string.find(dName:lower(), "egg") ~= nil or attrs.Category == "Egg" or string.find(tool.Name:lower(), "egg") ~= nil
                    if not isEgg then
                        local petUid = attrs.UID or attrs.Uid or attrs.Id or tool.Name
                        local uidStr = tostring(petUid)
                        if not seenUids[uidStr] then
                            seenUids[uidStr] = true
                            local rawName = attrs.DisplayName or attrs.Category or tool.Name
                            local cleanBase = rawName:gsub("^%b[]%s*", "")
                            for _, mWord in ipairs({"Rainbow", "Golden", "Silver", "Gold"}) do
                                cleanBase = cleanBase:gsub("^" .. mWord .. "%s+", "")
                            end

                            local weightStr, weightNum = formatPetWeight(attrs.Weight, attrs.Scale)

                            local mut = ""
                            if type(attrs.BaseMutation) == "string" and attrs.BaseMutation ~= "" then
                                mut = attrs.BaseMutation
                            elseif type(attrs.Mutations) == "string" and attrs.Mutations ~= "" then
                                mut = attrs.Mutations
                            end

                            local species = rawName
                            if mut ~= "" and not string.find(species, mut) then
                                species = string.format("[%s] %s", mut, species)
                            end

                            local rarity = attrs.Rarity or (typeof(PET_RARITY_PRESETS) == "table" and (PET_RARITY_PRESETS[attrs.DisplayName] or PET_RARITY_PRESETS[cleanBase] or PET_RARITY_PRESETS[rawName])) or "Common"

                            local isEquip = equippedUids[uidStr] == true or attrs.Equipped == true
                            local earn = equippedEarnRates[uidStr] or "--/s"

                            table.insert(rawPets, {
                                Id = uidStr,
                                Uid = uidStr,
                                Species = species,
                                BaseSpecies = cleanBase,
                                Mutation = mut,
                                Rarity = rarity,
                                Equipped = isEquip,
                                _weightNum = weightNum,
                                _weight = weightStr,
                                _earn = earn,
                                _source = srcName
                            })
                            sourceBreakdown[srcName] = (sourceBreakdown[srcName] or 0) + 1
                        end
                    end
                end
            end
        end
    end

    scanToolContainer(LocalPlayer:FindFirstChild("Backpack"), "Backpack")
    scanToolContainer(LocalPlayer.Character, "Character")

    -- 3b. ProfileMirror FetchProfile fallback with LocalPlayer argument
    if #rawPets == 0 then
        local rfProfile = getNetRemote("RF/ProfileMirror/FetchProfile")
        if rfProfile then
            local ok, prof = pcall(function() return rfProfile:InvokeServer(LocalPlayer) end)
            if ok and type(prof) == "table" then
                local pData = prof.Data or prof.Profile or prof
                local seenTables = {}

                local function searchProfile(tbl, path, depth)
                    if depth > 4 or type(tbl) ~= "table" then return end
                    if seenTables[tbl] then return end
                    seenTables[tbl] = true

                    local isCandidate = false
                    local sampleCount = 0
                    for k, v in pairs(tbl) do
                        sampleCount = sampleCount + 1
                        if (type(k) == "string" and #k == 32 and k:match("^%x+$"))
                           or (type(v) == "table" and (v.Species or v.PetName or v.PetType or v.Earn or v.Rate or v.Weight or v.PetId or v.UID)) then
                            isCandidate = true
                            break
                        end
                        if sampleCount > 8 then break end
                    end

                    if isCandidate then
                        local countInTable = 0
                        for k, v in pairs(tbl) do
                            if type(v) == "table" then
                                local petUid = v.UID or v.Id or v.Uid or v.UUID or v.PetId or (type(k) == "string" and #k >= 10 and k)
                                local uidStr = tostring(petUid or k)
                                if not seenUids[uidStr] then
                                    seenUids[uidStr] = true
                                    local species = v.DisplayName or v.Species or v.Name or v.PetName or v.PetType or "Unknown"
                                    local earn, weight, wNum = extractPetStats(v, nil)
                                    table.insert(rawPets, {
                                        Id = uidStr,
                                        Uid = uidStr,
                                        Species = species,
                                        Rarity = v.Rarity or (typeof(PET_RARITY_PRESETS) == "table" and PET_RARITY_PRESETS[species]) or "Common",
                                        Equipped = equippedUids[uidStr] == true or v.Equipped == true,
                                        _weightNum = wNum or 0,
                                        _earn = earn,
                                        _weight = weight,
                                        _source = path
                                    })
                                    countInTable = countInTable + 1
                                end
                            end
                        end
                        if countInTable > 0 then
                            sourceBreakdown[path] = (sourceBreakdown[path] or 0) + countInTable
                        end
                    else
                        for k, v in pairs(tbl) do
                            if type(v) == "table" then
                                searchProfile(v, path .. "." .. tostring(k), depth + 1)
                            end
                        end
                    end
                end

                searchProfile(pData, "Profile", 1)
            end
        end
    end

    -- 3c. PlayerGui Satchel / Backpack UI inspection fallback
    if #rawPets == 0 and pg then
        local guiCount = 0
        for _, guiObj in ipairs(pg:GetChildren()) do
            if guiObj:IsA("ScreenGui") and guiObj ~= screenGui and guiObj.Name ~= "RemoteLogger" and guiObj.Name ~= "PetProbeGui" and guiObj.Name ~= "TargetedCharacterScannerGui" then
                for _, desc in ipairs(guiObj:GetDescendants()) do
                    if desc:IsA("Frame") or desc:IsA("ImageButton") or desc:IsA("TextButton") then
                        local attrs = desc:GetAttributes() or {}
                        local petName = attrs.DisplayName or attrs.Species or attrs.PetName or attrs.Name or desc:GetAttribute("Species")
                        local petUid = attrs.UID or attrs.PetId or attrs.Uid or attrs.UUID or (#desc.Name == 32 and desc.Name:match("^%x+$") and desc.Name)

                        local parentName = (desc.Parent and desc.Parent.Name:lower()) or ""
                        local isPetSlot = string.find(parentName, "satchel") or string.find(parentName, "pet") or string.find(parentName, "grid") or string.find(parentName, "inventory")
                        if not petName and isPetSlot and #desc.Name > 1 and desc.Name ~= "Template" and desc.Name ~= "Sample" then
                            petName = desc.Name
                        end

                        if petName then
                            local uidStr = tostring(petUid or (petName .. "_" .. tostring(#rawPets + 1)))
                            if not seenUids[uidStr] then
                                seenUids[uidStr] = true
                                local isEquip = equippedUids[uidStr] == true or attrs.Equipped == true or desc:FindFirstChild("EquippedTag") ~= nil
                                local earn, weight, wNum = extractPetStats(attrs, desc)
                                local rarity = attrs.Rarity or (typeof(PET_RARITY_PRESETS) == "table" and PET_RARITY_PRESETS[petName]) or "Common"
                                table.insert(rawPets, {
                                    Id = uidStr,
                                    Uid = uidStr,
                                    Species = petName,
                                    Rarity = rarity,
                                    Equipped = isEquip,
                                    _weightNum = wNum or 0,
                                    _earn = earn,
                                    _weight = weight,
                                    _source = "PlayerGui." .. guiObj.Name
                                })
                                guiCount = guiCount + 1
                            end
                        end
                    end
                end
            end
        end
        if guiCount > 0 then
            sourceBreakdown["PlayerGui"] = guiCount
        end
    end

    -- 4. Group & Filter (EXCLUDING EQUIPPED)
    local totalPets = 0
    local totalEquipped = 0
    local unequippedGroups = {}
    for _, pet in ipairs(rawPets) do
        totalPets = totalPets + 1
        local uid = tostring(pet.Id or pet.Uid or pet.UUID or pet.PetId or "")
        local species = pet.Species or pet.Name or pet.PetType or "Unknown"
        local cleanBase = (pet.BaseSpecies or species):gsub("^%b[]%s*", "")
        for _, mWord in ipairs({"Rainbow", "Golden", "Silver", "Gold"}) do
            cleanBase = cleanBase:gsub("^" .. mWord .. "%s+", "")
        end
        local rarity = pet.Rarity or (typeof(PET_RARITY_PRESETS) == "table" and (PET_RARITY_PRESETS[species] or PET_RARITY_PRESETS[cleanBase])) or "Common"

        local isEquipped = (pet.Equipped == true)
            or (uid ~= "" and equippedUids[uid] == true)
            or (equippedNames[species] and equippedNames[species] > 0)

        if isEquipped then
            totalEquipped = totalEquipped + 1
            if equippedNames[species] and equippedNames[species] > 0 then
                equippedNames[species] = equippedNames[species] - 1
            end
        else
            if not unequippedGroups[species] then
                unequippedGroups[species] = {
                    species = species,
                    baseSpecies = cleanBase,
                    mutation = pet.Mutation or "",
                    count = 0,
                    uids = {},
                    pets = {},
                    rarity = rarity,
                    earn = pet._earn or "--/s",
                    weight = pet._weight or "-- kg"
                }
            end
            if pet._earn and pet._earn ~= "--/s" then
                unequippedGroups[species].earn = pet._earn
            end
            if pet._weight and pet._weight ~= "-- kg" then
                unequippedGroups[species].weight = pet._weight
            end
            unequippedGroups[species].count = unequippedGroups[species].count + 1
            table.insert(unequippedGroups[species].uids, uid)
            table.insert(unequippedGroups[species].pets, {
                uid = uid,
                species = species,
                baseSpecies = cleanBase,
                mutation = pet.Mutation or "",
                weightNum = pet._weightNum or 0,
                weight = pet._weight or "-- kg",
                earn = pet._earn or "--/s",
                source = pet._source or "Backpack"
            })
        end
    end

    invTotalPets = totalPets
    invEquippedPets = totalEquipped
    invUnequippedPets = math.max(0, totalPets - totalEquipped)
    if typeof(updateInventorySummaryUI) == "function" then
        updateInventorySummaryUI()
    end

    -- 5. Keep ONLY species where unequipped count >= 3
    local result = {}
    for species, data in pairs(unequippedGroups) do
        if data.count >= 3 then
            table.insert(result, data)
        end
    end

    table.sort(result, function(a, b)
        local rankA = (typeof(X) == "table" and X.RARITY_RANK and X.RARITY_RANK[a.rarity]) or 99
        local rankB = (typeof(X) == "table" and X.RARITY_RANK and X.RARITY_RANK[b.rarity]) or 99
        if rankA ~= rankB then return rankA > rankB end
        return a.count > b.count
    end)

    -- Sort pets within each group by weight (lightest to heaviest)
    for _, group in ipairs(result) do
        table.sort(group.pets, function(a, b)
            return (a.weightNum or 0) < (b.weightNum or 0)
        end)
    end

    eligibleFusePets = result

    -- Telemetry logging to console and UI activity log
    local details = {}
    for src, c in pairs(sourceBreakdown) do
        table.insert(details, string.format("%s: %d", src, c))
    end
    local srcStr = #details > 0 and table.concat(details, ", ") or "none"
    print(string.format("[EggGoToUI] Pet Scan complete: %d total (%d unequipped, %d equipped). Sources: %s. Eligible for fuse (>= 3): %d species",
        totalPets, invUnequippedPets, totalEquipped, srcStr, #result))

    return result
end

local function callFuseSpecificPets(species, uidsToFuse)
    if not species or not uidsToFuse or #uidsToFuse ~= 3 then
        logAuto("⚠️ Exactly 3 pets must be selected to fuse", Color3.fromRGB(255, 180, 80))
        return false, "Must select 3 pets"
    end

    for i = 1, 3 do
        if not uidsToFuse[i] or tostring(uidsToFuse[i]) == "" then
            logAuto("❌ Invalid Pet UID in slot " .. i, Color3.fromRGB(255, 120, 120))
            return false, "Invalid pet UID"
        end
    end

    local rfBriefing = getNetRemote("RF/Fusery/ConfirmBriefing")
    local rfLoad     = getNetRemote("RF/Fusery/LoadPet")
    local rfBegin    = getNetRemote("RF/Fusery/BeginFuse")
    local rfFinish   = getNetRemote("RF/Fusery/FinishReveal")

    if rfBriefing then pcall(function() rfBriefing:InvokeServer() end) end

    if not rfLoad then
        logAuto("❌ Remote RF/Fusery/LoadPet not found", Color3.fromRGB(255, 100, 100))
        return false, "LoadPet remote missing"
    end

    logAuto("🧪 Loading 3x selected " .. species .. " into Fusery...", Color3.fromRGB(180, 140, 255))

    local loadedCount = 0
    for slot = 1, 3 do
        local uid = tostring(uidsToFuse[slot])
        local shortUid = (#uid > 8) and (uid:sub(1, 8) .. "...") or uid
        logAuto(string.format("  [%d/3] Loading %s (%s)...", slot, species, shortUid), Color3.fromRGB(170, 190, 240))

        -- Verified server signature from farmer/fuse.log:
        -- InvokeServer(petUid, false)
        local ok, res = pcall(function()
            return rfLoad:InvokeServer(uid, false)
        end)

        if ok and res ~= false then
            loadedCount = loadedCount + 1
            logAuto(string.format("  ✓ [%d/3] Loaded", slot), Color3.fromRGB(140, 255, 180))
        else
            logAuto(string.format("  ⚠️ [%d/3] LoadPet returned: %s", slot, tostring(res)), Color3.fromRGB(255, 180, 80))
        end
        task.wait(0.15)
    end

    local fuseOk = (loadedCount >= 3)
    local fuseRes = nil
    if fuseOk then
        if rfBegin then
            local okB, resB = pcall(function() return rfBegin:InvokeServer() end)
            if okB and resB ~= false and resB ~= nil then
                fuseRes = resB
                logAuto("⚡ [Fusery] BeginFuse: " .. tostring(resB), Color3.fromRGB(120, 255, 180))
            else
                logAuto("⚡ [Fusery] BeginFuse sent", Color3.fromRGB(120, 255, 180))
            end
        end

        if rfFinish then
            task.wait(0.2)
            pcall(function() rfFinish:InvokeServer() end)
        end

        -- Trigger ContentCreator snapshot if available to sync client state
        task.wait(0.3)
        pcall(function()
            local ccReq = ReplicatedStorage:FindFirstChild("ContentCreatorRemotes")
            if ccReq and ccReq:FindFirstChild("Request") then
                ccReq.Request:InvokeServer("snapshot", { lightweight = true })
            end
        end)

        -- Clear checked state for the fused UIDs
        for _, u in ipairs(uidsToFuse) do
            checkedPetUids[u] = nil
        end
    else
        logAuto(string.format("⚠️ Only %d/3 pets loaded into Fusery. Aborting fuse.", loadedCount), Color3.fromRGB(255, 160, 80))
    end

    task.wait(0.3)
    scanEligibleFusePets()
    if typeof(updateFuseSelectorUI) == "function" then
        updateFuseSelectorUI()
    end

    if fuseOk then
        logAuto("✅ [Fusery] Successfully fused 3x " .. species .. "!", Color3.fromRGB(120, 255, 180))
        if fuseHeaderBadge then
            fuseHeaderBadge.Text = "Fused 3x!"
            fuseHeaderBadge.TextColor3 = Color3.fromRGB(120, 255, 180)
        end
    else
        logAuto(string.format("⚠️ Fusery aborted (%d/3 loaded)", loadedCount), Color3.fromRGB(255, 180, 80))
    end

    return fuseOk, fuseRes
end

local function callFuseSelectedPet(species)
    if not species then
        logAuto("⚠️ Please select an eligible pet to fuse first", Color3.fromRGB(255, 180, 80))
        return false, "No pet selected"
    end

    -- First try to find 3 checked pets for this species
    for _, item in ipairs(eligibleFusePets) do
        if item.species == species then
            local uids = {}
            for _, p in ipairs(item.pets or {}) do
                if checkedPetUids[p.uid] then
                    table.insert(uids, p.uid)
                end
            end
            if #uids == 3 then
                return callFuseSpecificPets(species, uids)
            end
            -- Fallback if not exactly 3 checked: use the first 3
            if #item.uids >= 3 then
                return callFuseSpecificPets(species, { item.uids[1], item.uids[2], item.uids[3] })
            end
        end
    end

    logAuto("⚠️ Need at least 3 unequipped " .. tostring(species) .. " to fuse", Color3.fromRGB(255, 120, 120))
    return false, "Insufficient unequipped pets"
end

local function callBeginFuse()
    if selectedFuseSpecies then
        return callFuseSelectedPet(selectedFuseSpecies)
    end

    -- Auto mode fallback: choose first candidate matching threshold
    local list = scanEligibleFusePets()
    local maxRank = (typeof(X) == "table" and X.RARITY_RANK and X.RARITY_RANK[fuseRarityThreshold]) or 99
    for _, candidate in ipairs(list) do
        local rRank = (typeof(X) == "table" and X.RARITY_RANK and X.RARITY_RANK[candidate.rarity]) or 99
        if rRank <= maxRank then
            return callFuseSelectedPet(candidate.species)
        end
    end

    return false, "No eligible unequipped pets with 3+ copies"
end


-- Telemetry Logger
local logEntries = {}
local MAX_LOG_LINES = 30
local logTextLabel = nil
local logScroll = nil

logAuto = function(msg, col)
    local ts = os.date("%H:%M:%S")
    local line = ("[%s] %s"):format(ts, tostring(msg))
    pcall(function() print("[EggGoToUI - Pets] " .. line) end)
    table.insert(logEntries, line)
    if #logEntries > MAX_LOG_LINES then table.remove(logEntries, 1) end
    if logTextLabel then
        logTextLabel.Text = table.concat(logEntries, "\n")
        if logScroll then
            pcall(function() logScroll.CanvasPosition = Vector2.new(0, 9999) end)
        end
    end
end

-- Top Banner removed per request

-- Helper to create stylized automation cards
local function createAutoCard(titleText, height)
    local card = Instance.new("Frame")
    card.Size = UDim2.new(1, 0, 0, height)
    card.BackgroundColor3 = Color3.fromRGB(24, 28, 40)
    card.BorderSizePixel = 0
    card.Parent = tabPets
    Instance.new("UICorner", card).CornerRadius = UDim.new(0, 8)
    local cStr = Instance.new("UIStroke", card)
    cStr.Color = Color3.fromRGB(50, 65, 95); cStr.Thickness = 1

    local hLabel = Instance.new("TextLabel")
    hLabel.Size = UDim2.new(1, -16, 0, 22); hLabel.Position = UDim2.new(0, 8, 0, 4)
    hLabel.BackgroundTransparency = 1; hLabel.Text = titleText
    hLabel.TextColor3 = Color3.fromRGB(200, 215, 245); hLabel.TextSize = 12
    hLabel.Font = Enum.Font.GothamBold; hLabel.TextXAlignment = Enum.TextXAlignment.Left
    hLabel.Parent = card

    return card
end

-- CARD 1: INVENTORY OVERVIEW (At the top of Pets Tab)
local cardInv = createAutoCard("📦 Inventory Overview", 74)

invPetsLabel = Instance.new("TextLabel")
invPetsLabel.Size = UDim2.new(1, -44, 0, 20); invPetsLabel.Position = UDim2.new(0, 10, 0, 26)
invPetsLabel.BackgroundTransparency = 1
invPetsLabel.Text = "🐾 Total Pets: 0   (0 Free, 0 Equipped)"
invPetsLabel.TextColor3 = Color3.fromRGB(220, 235, 255)
invPetsLabel.TextSize = 11; invPetsLabel.Font = Enum.Font.GothamBold
invPetsLabel.TextXAlignment = Enum.TextXAlignment.Left; invPetsLabel.Parent = cardInv

invEggsLabel = Instance.new("TextLabel")
invEggsLabel.Size = UDim2.new(1, -44, 0, 20); invEggsLabel.Position = UDim2.new(0, 10, 0, 48)
invEggsLabel.BackgroundTransparency = 1
invEggsLabel.Text = "🥚 Total Eggs: 0 in inventory"
invEggsLabel.TextColor3 = Color3.fromRGB(180, 240, 200)
invEggsLabel.TextSize = 11; invEggsLabel.Font = Enum.Font.GothamBold
invEggsLabel.TextXAlignment = Enum.TextXAlignment.Left; invEggsLabel.Parent = cardInv

local refreshInvBtn = Instance.new("TextButton")
refreshInvBtn.Size = UDim2.new(0, 28, 0, 28); refreshInvBtn.Position = UDim2.new(1, -36, 0, 32)
refreshInvBtn.BackgroundColor3 = Color3.fromRGB(42, 52, 75); refreshInvBtn.Text = "🔄"
refreshInvBtn.TextColor3 = Color3.new(1, 1, 1); refreshInvBtn.TextSize = 12
refreshInvBtn.Font = Enum.Font.GothamBold; refreshInvBtn.Parent = cardInv
Instance.new("UICorner", refreshInvBtn).CornerRadius = UDim.new(0, 6)

-- CARD 2: FUSERY CANDIDATES (Count >= 3)
local cardFuse = createAutoCard("🧪 Fusery Candidates (Select 3 to Fuse)", 300)

fuseHeaderBadge = Instance.new("TextLabel")
fuseHeaderBadge.Size = UDim2.new(0, 110, 0, 20); fuseHeaderBadge.Position = UDim2.new(1, -145, 0, 4)
fuseHeaderBadge.BackgroundColor3 = Color3.fromRGB(36, 44, 62)
fuseHeaderBadge.Text = "0 eligible"
fuseHeaderBadge.TextColor3 = Color3.fromRGB(160, 210, 255)
fuseHeaderBadge.TextSize = 10; fuseHeaderBadge.Font = Enum.Font.GothamBold
fuseHeaderBadge.Parent = cardFuse
Instance.new("UICorner", fuseHeaderBadge).CornerRadius = UDim.new(0, 4)

local refreshFuseListBtn = Instance.new("TextButton")
refreshFuseListBtn.Size = UDim2.new(0, 24, 0, 20); refreshFuseListBtn.Position = UDim2.new(1, -30, 0, 4)
refreshFuseListBtn.BackgroundColor3 = Color3.fromRGB(42, 52, 75); refreshFuseListBtn.Text = "🔄"
refreshFuseListBtn.TextColor3 = Color3.new(1, 1, 1); refreshFuseListBtn.TextSize = 11
refreshFuseListBtn.Font = Enum.Font.GothamBold; refreshFuseListBtn.Parent = cardFuse
Instance.new("UICorner", refreshFuseListBtn).CornerRadius = UDim.new(0, 4)

-- Scrolling Container for Candidate Pets
local fuseScroll = Instance.new("ScrollingFrame")
fuseScroll.Size = UDim2.new(1, -12, 1, -32); fuseScroll.Position = UDim2.new(0, 6, 0, 26)
fuseScroll.BackgroundColor3 = Color3.fromRGB(16, 20, 30); fuseScroll.BorderSizePixel = 0
fuseScroll.ScrollBarThickness = 4; fuseScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
fuseScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
fuseScroll.ClipsDescendants = true
fuseScroll.Parent = cardFuse
Instance.new("UICorner", fuseScroll).CornerRadius = UDim.new(0, 6)

local fsPad = Instance.new("UIPadding", fuseScroll)
fsPad.PaddingTop = UDim.new(0, 4); fsPad.PaddingBottom = UDim.new(0, 4)
fsPad.PaddingLeft = UDim.new(0, 4); fsPad.PaddingRight = UDim.new(0, 4)

local fuseScrollLayout = Instance.new("UIListLayout")
fuseScrollLayout.Padding = UDim.new(0, 4)
fuseScrollLayout.SortOrder = Enum.SortOrder.LayoutOrder
fuseScrollLayout.Parent = fuseScroll

-- CARD 3: LIVE AUTOMATION LOG
local cardLog = createAutoCard("📜 Fusery Activity Log", 125)

local clearLogBtn = Instance.new("TextButton")
clearLogBtn.Size = UDim2.new(0, 48, 0, 18); clearLogBtn.Position = UDim2.new(1, -54, 0, 4)
clearLogBtn.BackgroundColor3 = Color3.fromRGB(50, 58, 80); clearLogBtn.Text = "Clear"
clearLogBtn.TextColor3 = Color3.fromRGB(200, 215, 240); clearLogBtn.TextSize = 10
clearLogBtn.Font = Enum.Font.GothamBold; clearLogBtn.Parent = cardLog
Instance.new("UICorner", clearLogBtn).CornerRadius = UDim.new(0, 4)

logScroll = Instance.new("ScrollingFrame")
logScroll.Size = UDim2.new(1, -16, 0, 90); logScroll.Position = UDim2.new(0, 8, 0, 28)
logScroll.BackgroundColor3 = Color3.fromRGB(16, 18, 26); logScroll.BorderSizePixel = 0
logScroll.ScrollBarThickness = 4; logScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
logScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
logScroll.Parent = cardLog
Instance.new("UICorner", logScroll).CornerRadius = UDim.new(0, 6)

logTextLabel = Instance.new("TextLabel")
logTextLabel.Size = UDim2.new(1, -8, 0, 0); logTextLabel.Position = UDim2.new(0, 4, 0, 2)
logTextLabel.BackgroundTransparency = 1; logTextLabel.Text = "[Fusery system ready]"
logTextLabel.TextColor3 = Color3.fromRGB(180, 205, 240); logTextLabel.TextSize = 10
logTextLabel.Font = Enum.Font.Code; logTextLabel.TextXAlignment = Enum.TextXAlignment.Left
logTextLabel.TextYAlignment = Enum.TextYAlignment.Top; logTextLabel.AutomaticSize = Enum.AutomaticSize.Y
logTextLabel.Parent = logScroll

clearLogBtn.MouseButton1Click:Connect(function()
    logEntries = {}
    logTextLabel.Text = "[Log cleared]"
end)

local isFusing = false

updateFuseSelectorUI = function()
    local list = scanEligibleFusePets()

    -- Clean old pet rows
    for _, child in ipairs(fuseScroll:GetChildren()) do
        if child:IsA("Frame") or child:IsA("TextLabel") or child:IsA("TextButton") then
            child:Destroy()
        end
    end

    if fuseHeaderBadge then
        if #list == 0 then
            fuseHeaderBadge.Text = "0 eligible"
            fuseHeaderBadge.TextColor3 = Color3.fromRGB(160, 180, 210)
        else
            fuseHeaderBadge.Text = string.format("%d species eligible", #list)
            fuseHeaderBadge.TextColor3 = Color3.fromRGB(120, 255, 180)
        end
    end

    if #list == 0 then
        local emptyFrame = Instance.new("Frame")
        emptyFrame.Size = UDim2.new(1, -4, 0, 68)
        emptyFrame.BackgroundColor3 = Color3.fromRGB(22, 26, 38)
        emptyFrame.BorderSizePixel = 0
        emptyFrame.Parent = fuseScroll
        Instance.new("UICorner", emptyFrame).CornerRadius = UDim.new(0, 6)
        local efStr = Instance.new("UIStroke", emptyFrame)
        efStr.Color = Color3.fromRGB(45, 55, 80); efStr.Thickness = 1

        local emptyIcon = Instance.new("TextLabel")
        emptyIcon.Size = UDim2.new(1, -16, 0, 22); emptyIcon.Position = UDim2.new(0, 8, 0, 12)
        emptyIcon.BackgroundTransparency = 1
        emptyIcon.Text = "ℹ️ No unequipped pets with 3+ copies"
        emptyIcon.TextColor3 = Color3.fromRGB(210, 225, 245)
        emptyIcon.TextSize = 11; emptyIcon.Font = Enum.Font.GothamBold
        emptyIcon.Parent = emptyFrame

        local emptySub = Instance.new("TextLabel")
        emptySub.Size = UDim2.new(1, -16, 0, 18); emptySub.Position = UDim2.new(0, 8, 0, 34)
        emptySub.BackgroundTransparency = 1
        emptySub.Text = "Equipped pets (18) are protected. Collect or hatch more pets to fuse!"
        emptySub.TextColor3 = Color3.fromRGB(140, 160, 190)
        emptySub.TextSize = 10; emptySub.Font = Enum.Font.Gotham
        emptySub.Parent = emptyFrame
        return
    end

    for _, g in ipairs(list) do
        local rarCol = (typeof(ALL_RARITY_COLORS) == "table" and ALL_RARITY_COLORS[g.rarity]) or Color3.fromRGB(200, 200, 200)

        -- If none checked for this species yet, default to checking the 3 lightest (lowest weight)
        local initialChecked = 0
        for _, pet in ipairs(g.pets) do
            if checkedPetUids[pet.uid] then initialChecked = initialChecked + 1 end
        end
        if initialChecked == 0 and #g.pets >= 3 then
            checkedPetUids[g.pets[1].uid] = true
            checkedPetUids[g.pets[2].uid] = true
            checkedPetUids[g.pets[3].uid] = true
        end

        -- Outer Group Card Container
        local groupCard = Instance.new("Frame")
        groupCard.Size = UDim2.new(1, -4, 0, 0)
        groupCard.AutomaticSize = Enum.AutomaticSize.Y
        groupCard.BackgroundColor3 = Color3.fromRGB(21, 26, 38)
        groupCard.BorderSizePixel = 0
        groupCard.Parent = fuseScroll
        Instance.new("UICorner", groupCard).CornerRadius = UDim.new(0, 8)
        local gcStroke = Instance.new("UIStroke", groupCard)
        gcStroke.Color = Color3.fromRGB(45, 58, 85); gcStroke.Thickness = 1

        local groupCardLayout = Instance.new("UIListLayout")
        groupCardLayout.Padding = UDim.new(0, 2)
        groupCardLayout.SortOrder = Enum.SortOrder.LayoutOrder
        groupCardLayout.Parent = groupCard

        -- Group Header
        local groupHeader = Instance.new("Frame")
        groupHeader.Size = UDim2.new(1, 0, 0, 36)
        groupHeader.BackgroundColor3 = Color3.fromRGB(28, 36, 52)
        groupHeader.BorderSizePixel = 0
        groupHeader.LayoutOrder = 1
        groupHeader.Parent = groupCard
        Instance.new("UICorner", groupHeader).CornerRadius = UDim.new(0, 8)

        -- Left Rarity Stripe
        local strip = Instance.new("Frame")
        strip.Size = UDim2.new(0, 4, 1, -8); strip.Position = UDim2.new(0, 5, 0, 4)
        strip.BackgroundColor3 = rarCol; strip.BorderSizePixel = 0
        strip.Parent = groupHeader
        Instance.new("UICorner", strip).CornerRadius = UDim.new(0, 2)

        -- Species Title + Count Badge
        local titleLabel = Instance.new("TextLabel")
        titleLabel.Size = UDim2.new(1, -170, 1, 0); titleLabel.Position = UDim2.new(0, 16, 0, 0)
        titleLabel.BackgroundTransparency = 1
        titleLabel.Text = string.format("%s  [%s]  •  %d copies", g.species, g.rarity, g.count)
        titleLabel.TextColor3 = Color3.fromRGB(235, 245, 255)
        titleLabel.TextSize = 11; titleLabel.Font = Enum.Font.GothamBold
        titleLabel.TextXAlignment = Enum.TextXAlignment.Left
        titleLabel.TextTruncate = Enum.TextTruncate.AtEnd
        titleLabel.Parent = groupHeader

        -- Auto 3 (Lightest) Button
        local auto3Btn = Instance.new("TextButton")
        auto3Btn.Size = UDim2.new(0, 58, 0, 24); auto3Btn.Position = UDim2.new(1, -162, 0.5, -12)
        auto3Btn.BackgroundColor3 = Color3.fromRGB(40, 50, 72)
        auto3Btn.Text = "Auto 3"
        auto3Btn.TextColor3 = Color3.fromRGB(190, 220, 255)
        auto3Btn.TextSize = 10; auto3Btn.Font = Enum.Font.GothamBold
        auto3Btn.Parent = groupHeader
        Instance.new("UICorner", auto3Btn).CornerRadius = UDim.new(0, 4)

        -- Fuse Button
        local fuseGroupBtn = Instance.new("TextButton")
        fuseGroupBtn.Size = UDim2.new(0, 96, 0, 24); fuseGroupBtn.Position = UDim2.new(1, -100, 0.5, -12)
        fuseGroupBtn.TextSize = 10; fuseGroupBtn.Font = Enum.Font.GothamBold
        fuseGroupBtn.Parent = groupHeader
        Instance.new("UICorner", fuseGroupBtn).CornerRadius = UDim.new(0, 5)
        local fbStroke = Instance.new("UIStroke", fuseGroupBtn)
        fbStroke.Thickness = 1

        -- Table of row updater closures for instant, smooth check toggling
        local rowUpdaterFns = {}

        local function updateGroupFuseBtn()
            local countChecked = 0
            for _, p in ipairs(g.pets) do
                if checkedPetUids[p.uid] then countChecked = countChecked + 1 end
            end
            if countChecked == 3 then
                fuseGroupBtn.Text = "⚡ Fuse (3/3)"
                fuseGroupBtn.BackgroundColor3 = Color3.fromRGB(115, 60, 185)
                fuseGroupBtn.TextColor3 = Color3.new(1, 1, 1)
                fbStroke.Color = Color3.fromRGB(170, 110, 255)
            else
                fuseGroupBtn.Text = string.format("Select 3 (%d/3)", countChecked)
                fuseGroupBtn.BackgroundColor3 = Color3.fromRGB(44, 42, 56)
                fuseGroupBtn.TextColor3 = Color3.fromRGB(160, 160, 180)
                fbStroke.Color = Color3.fromRGB(65, 60, 80)
            end
        end

        -- Individual Pet Rows Container
        local rowsContainer = Instance.new("Frame")
        rowsContainer.Size = UDim2.new(1, 0, 0, 0)
        rowsContainer.AutomaticSize = Enum.AutomaticSize.Y
        rowsContainer.BackgroundTransparency = 1
        rowsContainer.BorderSizePixel = 0
        rowsContainer.LayoutOrder = 2
        rowsContainer.Parent = groupCard

        local rowsLayout = Instance.new("UIListLayout")
        rowsLayout.Padding = UDim.new(0, 2)
        rowsLayout.SortOrder = Enum.SortOrder.LayoutOrder
        rowsLayout.Parent = rowsContainer

        local rcPad = Instance.new("UIPadding", rowsContainer)
        rcPad.PaddingTop = UDim.new(0, 2); rcPad.PaddingBottom = UDim.new(0, 4)
        rcPad.PaddingLeft = UDim.new(0, 6); rcPad.PaddingRight = UDim.new(0, 6)

        for idx, pet in ipairs(g.pets) do
            local shortUid = (#pet.uid > 8) and (pet.uid:sub(1, 8) .. "...") or pet.uid

            local petRow = Instance.new("Frame")
            petRow.Size = UDim2.new(1, 0, 0, 28)
            petRow.BorderSizePixel = 0
            petRow.LayoutOrder = idx
            petRow.Parent = rowsContainer
            Instance.new("UICorner", petRow).CornerRadius = UDim.new(0, 5)
            local rowStroke = Instance.new("UIStroke", petRow)

            -- Pet details label (index, weight, earn/s, short UID)
            local rowLabel = Instance.new("TextLabel")
            rowLabel.Size = UDim2.new(1, -38, 1, 0); rowLabel.Position = UDim2.new(0, 8, 0, 0)
            rowLabel.BackgroundTransparency = 1
            local detailText = string.format("#%d  ⚖️ %s", idx, pet.weight)
            if pet.earn and pet.earn ~= "--/s" and pet.earn ~= "" then
                detailText = detailText .. "  •  💰 " .. tostring(pet.earn)
            end
            detailText = detailText .. "  •  [" .. shortUid .. "]"
            rowLabel.Text = detailText
            rowLabel.TextSize = 10; rowLabel.Font = Enum.Font.Gotham
            rowLabel.TextXAlignment = Enum.TextXAlignment.Left
            rowLabel.TextTruncate = Enum.TextTruncate.AtEnd
            rowLabel.Parent = petRow

            -- Checkbox Button
            local chkBtn = Instance.new("TextButton")
            chkBtn.Size = UDim2.new(0, 20, 0, 20); chkBtn.Position = UDim2.new(1, -26, 0.5, -10)
            chkBtn.TextSize = 13; chkBtn.Font = Enum.Font.GothamBold
            chkBtn.Parent = petRow
            Instance.new("UICorner", chkBtn).CornerRadius = UDim.new(0, 4)
            local chkStroke = Instance.new("UIStroke", chkBtn)
            chkStroke.Thickness = 1.2

            local function refreshRowVisual()
                local isChecked = (checkedPetUids[pet.uid] == true)
                if isChecked then
                    petRow.BackgroundColor3 = Color3.fromRGB(30, 46, 42)
                    rowStroke.Color = Color3.fromRGB(48, 150, 95)
                    rowStroke.Thickness = 1
                    rowLabel.TextColor3 = Color3.fromRGB(205, 250, 225)
                    chkBtn.BackgroundColor3 = Color3.fromRGB(35, 145, 80)
                    chkBtn.TextColor3 = Color3.new(1, 1, 1)
                    chkBtn.Text = "✓"
                    chkStroke.Color = Color3.fromRGB(80, 220, 130)
                else
                    petRow.BackgroundColor3 = Color3.fromRGB(24, 29, 42)
                    rowStroke.Color = Color3.fromRGB(38, 48, 68)
                    rowStroke.Thickness = 0.8
                    rowLabel.TextColor3 = Color3.fromRGB(170, 195, 230)
                    chkBtn.BackgroundColor3 = Color3.fromRGB(28, 34, 48)
                    chkBtn.TextColor3 = Color3.new(0, 0, 0)
                    chkBtn.Text = ""
                    chkStroke.Color = Color3.fromRGB(60, 75, 105)
                end
            end

            table.insert(rowUpdaterFns, refreshRowVisual)
            refreshRowVisual()

            local function togglePetCheck()
                if checkedPetUids[pet.uid] then
                    checkedPetUids[pet.uid] = nil
                else
                    local countChecked = 0
                    for _, p in ipairs(g.pets) do
                        if checkedPetUids[p.uid] then countChecked = countChecked + 1 end
                    end
                    if countChecked >= 3 then
                        logAuto("⚠️ 3 pets already checked for " .. g.species .. ". Uncheck one to change selection.", Color3.fromRGB(255, 180, 80))
                        return
                    end
                    checkedPetUids[pet.uid] = true
                end
                refreshRowVisual()
                updateGroupFuseBtn()
            end

            -- Click anywhere on the row OR directly on the checkbox button to toggle
            chkBtn.MouseButton1Click:Connect(togglePetCheck)

            local clickOverlay = Instance.new("TextButton")
            clickOverlay.Size = UDim2.new(1, -34, 1, 0); clickOverlay.Position = UDim2.new(0, 0, 0, 0)
            clickOverlay.BackgroundTransparency = 1; clickOverlay.Text = ""
            clickOverlay.Parent = petRow
            clickOverlay.MouseButton1Click:Connect(togglePetCheck)
        end

        updateGroupFuseBtn()

        -- Auto 3 click handler: selects first 3 (lightest) pets of this species
        auto3Btn.MouseButton1Click:Connect(function()
            for _, p in ipairs(g.pets) do
                checkedPetUids[p.uid] = nil
            end
            for i = 1, math.min(3, #g.pets) do
                checkedPetUids[g.pets[i].uid] = true
            end
            for _, fn in ipairs(rowUpdaterFns) do fn() end
            updateGroupFuseBtn()
            logAuto("✓ Selected 3 lightest " .. g.species, Color3.fromRGB(140, 240, 180))
        end)

        -- Fuse Group button click handler
        fuseGroupBtn.MouseButton1Click:Connect(function()
            local selectedUids = {}
            for _, p in ipairs(g.pets) do
                if checkedPetUids[p.uid] then table.insert(selectedUids, p.uid) end
            end
            if #selectedUids ~= 3 then
                logAuto(string.format("⚠️ Please check exactly 3 pets to fuse (%d/3 selected)", #selectedUids), Color3.fromRGB(255, 180, 80))
                return
            end
            if isFusing then
                logAuto("⏳ Fusery is busy. Please wait for current cycle to complete.", Color3.fromRGB(255, 200, 100))
                return
            end

            isFusing = true
            fuseGroupBtn.Text = "⏳ Fusing..."
            fuseGroupBtn.BackgroundColor3 = Color3.fromRGB(65, 40, 105)

            task.spawn(function()
                local ok, res = pcall(function()
                    return callFuseSpecificPets(g.species, selectedUids)
                end)
                isFusing = false
                if not ok then
                    logAuto("❌ Fuse exception: " .. tostring(res), Color3.fromRGB(255, 100, 100))
                    if typeof(updateFuseSelectorUI) == "function" then
                        updateFuseSelectorUI()
                    end
                end
            end)
        end)
    end
end

refreshFuseListBtn.MouseButton1Click:Connect(function()
    scanEligibleFusePets()
    updateFuseSelectorUI()
    logAuto("🔄 Candidate list refreshed", Color3.fromRGB(150, 220, 255))
end)

refreshInvBtn.MouseButton1Click:Connect(function()
    scanEligibleFusePets()
    updateFuseSelectorUI()
    logAuto("🔄 Inventory overview refreshed", Color3.fromRGB(150, 220, 255))
end)

refreshPetCards = function()
    scanEligibleFusePets()
    if typeof(updateFuseSelectorUI) == "function" then
        updateFuseSelectorUI()
    end
end

-- Background Automation Loop
task.spawn(function()
    logAuto("Fusery candidate engine ready")
    scanEligibleFusePets()
    if typeof(updateFuseSelectorUI) == "function" then
        updateFuseSelectorUI()
    end
    while not eggScannerStop and screenGui.Parent do
        if autoFuseEnabled then
            callBeginFuse()
        end
        task.wait(2.5)
    end
end)


end

-- ==================================================
-- MAIN UI BUILDER
-- ==================================================
local function buildMainUI()
-- ==================================================
-- UI
-- ==================================================
for _, n in ipairs({"EggGoToUI_v4","EggGoToUI_v5","EggGoToUI_v6","EggGoToUI_v7","EggGoToUI_v8","EggGoToUI_v9"}) do
    local old = PlayerGui:FindFirstChild(n); if old then old:Destroy() end
end

screenGui = Instance.new("ScreenGui")
screenGui.Name = "EggGoToUI_v9"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = PlayerGui

-- Floating toggle button: always visible, hides/shows the main menu panel
menuToggleBtn = Instance.new("TextButton")
menuToggleBtn.Size             = UDim2.new(0, 40, 0, 40)
menuToggleBtn.Position         = UDim2.new(0, 8, 0, 50)   -- Y=50 clears the Roblox core top-bar
menuToggleBtn.BackgroundColor3 = Color3.fromRGB(32, 40, 60)
menuToggleBtn.Text             = "☰"
menuToggleBtn.TextColor3       = Color3.fromRGB(200, 215, 255)
menuToggleBtn.TextSize         = 22
menuToggleBtn.Font             = Enum.Font.GothamBold
menuToggleBtn.ZIndex           = 200
menuToggleBtn.Parent           = screenGui
Instance.new("UICorner", menuToggleBtn).CornerRadius = UDim.new(0, 8)
local mts = Instance.new("UIStroke", menuToggleBtn)
mts.Color = Color3.fromRGB(70, 110, 180); mts.Thickness = 1.5

-- Drag support for the toggle button
local tDragging, tDragStart, tStartPos = false, nil, nil
menuToggleBtn.InputBegan:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 then
        tDragging = true; tDragStart = i.Position; tStartPos = menuToggleBtn.Position
    end
end)
menuToggleBtn.InputEnded:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 then tDragging = false end
end)
UserInputService.InputChanged:Connect(function(i)
    if tDragging and i.UserInputType == Enum.UserInputType.MouseMovement then
        local d = i.Position - tDragStart
        menuToggleBtn.Position = UDim2.new(
            tStartPos.X.Scale, tStartPos.X.Offset + d.X,
            tStartPos.Y.Scale, tStartPos.Y.Offset + d.Y)
    end
end)

farmDropdownOpen = false

main = Instance.new("Frame")
main.Size = UDim2.new(0, 380, 0, 520)
main.Position = UDim2.new(0.5, -190, 0.5, -260)
main.BackgroundColor3 = Color3.fromRGB(22, 24, 30)
main.BorderSizePixel = 0
main.Parent = screenGui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)
local stroke = Instance.new("UIStroke", main)
stroke.Color = Color3.fromRGB(70, 110, 180); stroke.Thickness = 1.5

local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1,0,0,36)
titleBar.BackgroundColor3 = Color3.fromRGB(32,40,60)
titleBar.BorderSizePixel = 0
titleBar.Parent = main
Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0,10)
local tfix = Instance.new("Frame")
tfix.Size = UDim2.new(1,0,0,12); tfix.Position = UDim2.new(0,0,1,-12)
tfix.BackgroundColor3 = Color3.fromRGB(32,40,60); tfix.BorderSizePixel=0; tfix.Parent=titleBar

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1,-80,1,0); title.Position = UDim2.new(0,12,0,0)
title.BackgroundTransparency=1; title.Text="Egg Go-To v9.9 (Farm + Pets Suite)"
title.TextColor3=Color3.fromRGB(220,230,255); title.TextSize=14; title.Font=Enum.Font.GothamBold
title.TextXAlignment=Enum.TextXAlignment.Left; title.Parent=titleBar

closeBtn = Instance.new("TextButton")
closeBtn.Size=UDim2.new(0,30,0,24); closeBtn.Position=UDim2.new(1,-38,0.5,-12)
closeBtn.BackgroundColor3=Color3.fromRGB(170,50,50); closeBtn.Text="X"
closeBtn.TextColor3=Color3.new(1,1,1); closeBtn.TextSize=14; closeBtn.Font=Enum.Font.GothamBold
closeBtn.Parent=titleBar; Instance.new("UICorner",closeBtn).CornerRadius=UDim.new(0,6)

-- Sidebar navigation (Compact icon-only rail)
local SIDEBAR_W = 46
local sidebar = Instance.new("Frame")
sidebar.Name = "Sidebar"
sidebar.Size = UDim2.new(0, SIDEBAR_W, 1, -36)
sidebar.Position = UDim2.new(0, 0, 0, 36)
sidebar.BackgroundColor3 = Color3.fromRGB(26, 32, 46)
sidebar.BorderSizePixel = 0
sidebar.Parent = main

local sidebarDivider = Instance.new("Frame")
sidebarDivider.Name = "SidebarDivider"
sidebarDivider.Size = UDim2.new(0, 1, 1, 0)
sidebarDivider.Position = UDim2.new(1, -1, 0, 0)
sidebarDivider.BackgroundColor3 = Color3.fromRGB(50, 70, 105)
sidebarDivider.BorderSizePixel = 0
sidebarDivider.Parent = sidebar

tabBtnEggs = Instance.new("TextButton")
tabBtnEggs.Name = "TabBtnEggs"
tabBtnEggs.Size = UDim2.new(0, 34, 0, 34)
tabBtnEggs.Position = UDim2.new(0.5, -17, 0, 10)
tabBtnEggs.BackgroundColor3 = Color3.fromRGB(45, 100, 160)
tabBtnEggs.Text = "🥚"
tabBtnEggs.TextColor3 = Color3.new(1, 1, 1)
tabBtnEggs.TextSize = 18
tabBtnEggs.Font = Enum.Font.GothamBold
tabBtnEggs.Parent = sidebar
Instance.new("UICorner", tabBtnEggs).CornerRadius = UDim.new(0, 6)

tabBtnPets = Instance.new("TextButton")
tabBtnPets.Name = "TabBtnPets"
tabBtnPets.Size = UDim2.new(0, 34, 0, 34)
tabBtnPets.Position = UDim2.new(0.5, -17, 0, 50)
tabBtnPets.BackgroundColor3 = Color3.fromRGB(32, 40, 60)
tabBtnPets.Text = "🐾"
tabBtnPets.TextColor3 = Color3.fromRGB(160, 185, 220)
tabBtnPets.TextSize = 18
tabBtnPets.Font = Enum.Font.GothamBold
tabBtnPets.Parent = sidebar
Instance.new("UICorner", tabBtnPets).CornerRadius = UDim.new(0, 6)

local contentContainer = Instance.new("Frame")
contentContainer.Name = "ContentContainer"
contentContainer.Size = UDim2.new(1, -SIDEBAR_W, 1, -36)
contentContainer.Position = UDim2.new(0, SIDEBAR_W, 0, 36)
contentContainer.BackgroundTransparency = 1
contentContainer.BorderSizePixel = 0
contentContainer.ClipsDescendants = false
contentContainer.Parent = main

-- Tab 1: Current menu (Eggs / Farm)
tabEggs = Instance.new("Frame")
tabEggs.Name = "TabEggs"
tabEggs.Size = UDim2.new(1, 0, 1, 0)
tabEggs.Position = UDim2.new(0, 0, 0, 0)
tabEggs.BackgroundTransparency = 1
tabEggs.BorderSizePixel = 0
tabEggs.ClipsDescendants = false
tabEggs.Visible = true
tabEggs.Parent = contentContainer

-- Tab 2: Pets & Automation Suite
tabPets = Instance.new("ScrollingFrame")
tabPets.Name = "TabPets"
tabPets.Size = UDim2.new(1, 0, 1, 0)
tabPets.Position = UDim2.new(0, 0, 0, 0)
tabPets.BackgroundTransparency = 1
tabPets.BorderSizePixel = 0
tabPets.ScrollBarThickness = 5
tabPets.CanvasSize = UDim2.new(0, 0, 0, 0)
tabPets.AutomaticCanvasSize = Enum.AutomaticSize.Y
tabPets.ClipsDescendants = true
tabPets.Visible = false
tabPets.Parent = contentContainer

refreshPetCards = nil

switchTab = function(tabName)
    if tabName == "Eggs" then
        tabEggs.Visible = true
        tabPets.Visible = false
        tabBtnEggs.BackgroundColor3 = Color3.fromRGB(45, 100, 160)
        tabBtnEggs.TextColor3 = Color3.new(1, 1, 1)
        tabBtnPets.BackgroundColor3 = Color3.fromRGB(32, 40, 60)
        tabBtnPets.TextColor3 = Color3.fromRGB(160, 185, 220)
    elseif tabName == "Pets" then
        if X.closeRarity then X.closeRarity() end
        if farmDropdownOpen then
            farmDropdownOpen = false
            if farmDropdownList then
                farmDropdownList.Visible = false
                farmDropdownList.Size = UDim2.new(0, 258, 0, 0)
            end
            if typeof(updateFarmBtnText) == "function" then updateFarmBtnText() end
        end
        tabEggs.Visible = false
        tabPets.Visible = true
        tabBtnEggs.BackgroundColor3 = Color3.fromRGB(32, 40, 60)
        tabBtnEggs.TextColor3 = Color3.fromRGB(160, 185, 220)
        tabBtnPets.BackgroundColor3 = Color3.fromRGB(45, 100, 160)
        tabBtnPets.TextColor3 = Color3.new(1, 1, 1)
        if refreshPetCards then refreshPetCards() end
    end
end
tabBtnEggs.MouseButton1Click:Connect(function() switchTab("Eggs") end)
tabBtnPets.MouseButton1Click:Connect(function() switchTab("Pets") end)

local COL_W = 152; local COL_GAP = 12; local ROW_H = 28; local ROW_GAP = 4

-- Row 1: Velocity Toggle + Go Speed + Carry Speed
local ROW1_Y = 8
local VEL_BTN_W = 110
local SPEED_W = 97
local SPEED_GAP = 6

velToggleBtn = Instance.new("TextButton")
velToggleBtn.Size = UDim2.new(0,VEL_BTN_W,0,ROW_H); velToggleBtn.Position=UDim2.new(0,12,0,ROW1_Y)
velToggleBtn.BackgroundColor3=Color3.fromRGB(42,48,65); velToggleBtn.Text="[OFF] Velocity"
velToggleBtn.TextColor3=Color3.fromRGB(210,220,240); velToggleBtn.TextSize=12
velToggleBtn.Font=Enum.Font.GothamBold; velToggleBtn.Parent=tabEggs
Instance.new("UICorner",velToggleBtn).CornerRadius=UDim.new(0,6)

local goFrame = Instance.new("Frame")
goFrame.Size=UDim2.new(0,SPEED_W,0,ROW_H); goFrame.Position=UDim2.new(0,12+VEL_BTN_W+SPEED_GAP,0,ROW1_Y)
goFrame.BackgroundColor3=Color3.fromRGB(28,34,48); goFrame.BorderSizePixel=0
goFrame.Parent=tabEggs; Instance.new("UICorner",goFrame).CornerRadius=UDim.new(0,6)
velInputStroke = Instance.new("UIStroke", goFrame)
velInputStroke.Color = Color3.fromRGB(60,80,115); velInputStroke.Thickness=1

local goLabel = Instance.new("TextLabel")
goLabel.Size=UDim2.new(0,32,1,0); goLabel.BackgroundTransparency=1
goLabel.Text=" Go:"; goLabel.TextColor3=Color3.fromRGB(160,185,220)
goLabel.TextSize=11; goLabel.Font=Enum.Font.GothamBold; goLabel.TextXAlignment=Enum.TextXAlignment.Left
goLabel.Parent=goFrame

velInputBox = Instance.new("TextBox")
velInputBox.Size=UDim2.new(1,-34,1,0); velInputBox.Position=UDim2.new(0,34,0,0)
velInputBox.BackgroundTransparency=1; velInputBox.Text=tostring(X.baseVelocity)
velInputBox.PlaceholderText="300"; velInputBox.TextColor3=Color3.new(1,1,1)
velInputBox.TextSize=12; velInputBox.Font=Enum.Font.GothamBold; velInputBox.ClearTextOnFocus=false
velInputBox.TextXAlignment=Enum.TextXAlignment.Left; velInputBox.Parent=goFrame

local carryFrame = Instance.new("Frame")
carryFrame.Size=UDim2.new(0,SPEED_W,0,ROW_H); carryFrame.Position=UDim2.new(0,12+VEL_BTN_W+SPEED_GAP+SPEED_W+SPEED_GAP,0,ROW1_Y)
carryFrame.BackgroundColor3=Color3.fromRGB(28,34,48); carryFrame.BorderSizePixel=0
carryFrame.Parent=tabEggs; Instance.new("UICorner",carryFrame).CornerRadius=UDim.new(0,6)
carryInputStroke = Instance.new("UIStroke", carryFrame)
carryInputStroke.Color = Color3.fromRGB(60,80,115); carryInputStroke.Thickness=1

local carryLabel = Instance.new("TextLabel")
carryLabel.Size=UDim2.new(0,44,1,0); carryLabel.BackgroundTransparency=1
carryLabel.Text=" Carry:"; carryLabel.TextColor3=Color3.fromRGB(160,185,220)
carryLabel.TextSize=11; carryLabel.Font=Enum.Font.GothamBold; carryLabel.TextXAlignment=Enum.TextXAlignment.Left
carryLabel.Parent=carryFrame

carryVelInputBox = Instance.new("TextBox")
carryVelInputBox.Size=UDim2.new(1,-46,1,0); carryVelInputBox.Position=UDim2.new(0,46,0,0)
carryVelInputBox.BackgroundTransparency=1; carryVelInputBox.Text=tostring(X.baseCarryVelocity)
carryVelInputBox.PlaceholderText="250"; carryVelInputBox.TextColor3=Color3.new(1,1,1)
carryVelInputBox.TextSize=12; carryVelInputBox.Font=Enum.Font.GothamBold; carryVelInputBox.ClearTextOnFocus=false
carryVelInputBox.TextXAlignment=Enum.TextXAlignment.Left; carryVelInputBox.Parent=carryFrame

-- Row 2: Recovery (left) + Velocity Live Status (right)
local ROW2_Y = ROW1_Y + ROW_H + ROW_GAP
recoveryToggleBtn = Instance.new("TextButton")
recoveryToggleBtn.Size=UDim2.new(0,COL_W,0,ROW_H); recoveryToggleBtn.Position=UDim2.new(0,12,0,ROW2_Y)
recoveryToggleBtn.BackgroundColor3=Color3.fromRGB(35,135,75); recoveryToggleBtn.Text="[ON] Recovery"
recoveryToggleBtn.TextColor3=Color3.new(1,1,1); recoveryToggleBtn.TextSize=13
recoveryToggleBtn.Font=Enum.Font.GothamBold; recoveryToggleBtn.Parent=tabEggs
Instance.new("UICorner",recoveryToggleBtn).CornerRadius=UDim.new(0,6)

velStatusLabel = Instance.new("TextLabel")
velStatusLabel.Size=UDim2.new(0,COL_W,0,ROW_H); velStatusLabel.Position=UDim2.new(0,12+COL_W+COL_GAP,0,ROW2_Y)
velStatusLabel.BackgroundColor3=Color3.fromRGB(24,29,40); velStatusLabel.Text="  Vel: 0"
velStatusLabel.TextColor3=Color3.fromRGB(140,190,240); velStatusLabel.TextSize=11
velStatusLabel.Font=Enum.Font.GothamBold; velStatusLabel.TextXAlignment=Enum.TextXAlignment.Left
velStatusLabel.Parent=tabEggs; Instance.new("UICorner",velStatusLabel).CornerRadius=UDim.new(0,6)

-- Row 3: Farm dropdown (multi-select)
local ROW3_Y = ROW2_Y + ROW_H + ROW_GAP
local farmLabel = Instance.new("TextLabel")
farmLabel.Size=UDim2.new(0,55,0,ROW_H); farmLabel.Position=UDim2.new(0,12,0,ROW3_Y)
farmLabel.BackgroundTransparency=1; farmLabel.Text="Farm:"
farmLabel.TextColor3=Color3.fromRGB(180,195,220); farmLabel.TextSize=13
farmLabel.Font=Enum.Font.Gotham; farmLabel.TextXAlignment=Enum.TextXAlignment.Left; farmLabel.Parent=tabEggs

farmDropdownBtn = Instance.new("TextButton")
farmDropdownBtn.Size=UDim2.new(0,258,0,ROW_H); farmDropdownBtn.Position=UDim2.new(0,70,0,ROW3_Y)
farmDropdownBtn.BackgroundColor3=Color3.fromRGB(40,48,65); farmDropdownBtn.Text="All ▼"
farmDropdownBtn.TextColor3=Color3.new(1,1,1); farmDropdownBtn.TextSize=13
farmDropdownBtn.Font=Enum.Font.GothamBold; farmDropdownBtn.Parent=tabEggs
Instance.new("UICorner",farmDropdownBtn).CornerRadius=UDim.new(0,6)

farmDropdownList = Instance.new("Frame")
farmDropdownList.Size=UDim2.new(0,258,0,0); farmDropdownList.Position=UDim2.new(0,70,0,ROW3_Y+ROW_H+2)
farmDropdownList.BackgroundColor3=Color3.fromRGB(30,36,50); farmDropdownList.BorderSizePixel=0
farmDropdownList.ClipsDescendants=true; farmDropdownList.Visible=false
farmDropdownList.ZIndex=30; farmDropdownList.Parent=tabEggs
Instance.new("UICorner",farmDropdownList).CornerRadius=UDim.new(0,6)

-- Quick row
local farmQuickRow = Instance.new("Frame")
farmQuickRow.Size=UDim2.new(1,0,0,26); farmQuickRow.BackgroundTransparency=1
farmQuickRow.Parent=farmDropdownList
local farmAllBtn = Instance.new("TextButton")
farmAllBtn.Size=UDim2.new(0.5,-2,1,-4); farmAllBtn.Position=UDim2.new(0,2,0,2)
farmAllBtn.BackgroundColor3=Color3.fromRGB(45,100,160); farmAllBtn.Text="All"
farmAllBtn.TextColor3=Color3.new(1,1,1); farmAllBtn.TextSize=12; farmAllBtn.Font=Enum.Font.GothamBold
farmAllBtn.Parent=farmQuickRow; Instance.new("UICorner",farmAllBtn).CornerRadius=UDim.new(0,4)
local farmNoneBtn = Instance.new("TextButton")
farmNoneBtn.Size=UDim2.new(0.5,-2,1,-4); farmNoneBtn.Position=UDim2.new(0.5,0,0,2)
farmNoneBtn.BackgroundColor3=Color3.fromRGB(90,45,45); farmNoneBtn.Text="None"
farmNoneBtn.TextColor3=Color3.new(1,1,1); farmNoneBtn.TextSize=12; farmNoneBtn.Font=Enum.Font.GothamBold
farmNoneBtn.Parent=farmQuickRow; Instance.new("UICorner",farmNoneBtn).CornerRadius=UDim.new(0,4)
    farmAllBtn.MouseButton1Click:Connect(function()
        selectedSpecies = { ["All"] = true }
        currentSettings.SpeciesFilter = {"All"}
        if jsonBox then jsonBox.Text = settingsToJSON(currentSettings) or jsonBox.Text end
        if updateFarmBtnText then updateFarmBtnText() end
        if rebuildFarmDropdownItems then rebuildFarmDropdownItems() end
        if refilterAndRender then refilterAndRender() end
    end)
    farmNoneBtn.MouseButton1Click:Connect(function()
        selectedSpecies = {}
        currentSettings.SpeciesFilter = {}
        if jsonBox then jsonBox.Text = settingsToJSON(currentSettings) or jsonBox.Text end
        if updateFarmBtnText then updateFarmBtnText() end
        if rebuildFarmDropdownItems then rebuildFarmDropdownItems() end
        if refilterAndRender then refilterAndRender() end
    end)


-- Search
farmSearchBox = Instance.new("TextBox")
farmSearchBox.Size=UDim2.new(1,-8,0,24); farmSearchBox.Position=UDim2.new(0,4,0,28)
farmSearchBox.BackgroundColor3=Color3.fromRGB(16,18,24); farmSearchBox.PlaceholderText="Search egg..."
farmSearchBox.Text=""; farmSearchBox.TextColor3=Color3.fromRGB(220,230,255)
farmSearchBox.PlaceholderColor3=Color3.fromRGB(110,120,140); farmSearchBox.TextSize=12
farmSearchBox.Font=Enum.Font.Gotham; farmSearchBox.ClearTextOnFocus=false
farmSearchBox.TextXAlignment=Enum.TextXAlignment.Left; farmSearchBox.Parent=farmDropdownList
Instance.new("UICorner",farmSearchBox).CornerRadius=UDim.new(0,4)
local fsp = Instance.new("UIPadding"); fsp.PaddingLeft=UDim.new(0,6); fsp.Parent=farmSearchBox

farmDropScroll = Instance.new("ScrollingFrame")
farmDropScroll.Size=UDim2.new(1,0,0,0); farmDropScroll.Position=UDim2.new(0,0,0,56)
farmDropScroll.BackgroundTransparency=1; farmDropScroll.BorderSizePixel=0
farmDropScroll.ScrollBarThickness=4; farmDropScroll.CanvasSize=UDim2.new(0,0,0,0)
farmDropScroll.AutomaticCanvasSize=Enum.AutomaticSize.Y
farmDropScroll.Parent=farmDropdownList

local MAX_FARM_DD_HEIGHT = 200

-- Row 4: JSON textbox
local ROW4_Y = ROW3_Y + 2 * (ROW_H + ROW_GAP)     -- v9: one extra row (Rarity) sits between Farm and the JSON box
jsonLabel = Instance.new("TextLabel")
jsonLabel.Size=UDim2.new(1,-24,0,14); jsonLabel.Position=UDim2.new(0,12,0,ROW4_Y)
jsonLabel.BackgroundTransparency=1; jsonLabel.Text="Config JSON:"
jsonLabel.TextColor3=Color3.fromRGB(180,195,220); jsonLabel.TextSize=11
jsonLabel.Font=Enum.Font.Gotham; jsonLabel.TextXAlignment=Enum.TextXAlignment.Left; jsonLabel.Parent=tabEggs

local JSON_BOX_H = 70
jsonBox = Instance.new("TextBox")
jsonBox.Size=UDim2.new(1,-24,0,JSON_BOX_H); jsonBox.Position=UDim2.new(0,12,0,ROW4_Y+16)
jsonBox.BackgroundColor3=Color3.fromRGB(16,18,24)
jsonBox.TextColor3=Color3.fromRGB(180,255,200); jsonBox.TextSize=10
jsonBox.Font=Enum.Font.Code; jsonBox.MultiLine=true; jsonBox.ClearTextOnFocus=false
jsonBox.TextWrapped=true; jsonBox.TextXAlignment=Enum.TextXAlignment.Left
jsonBox.TextYAlignment=Enum.TextYAlignment.Top
jsonBox.Text=settingsToJSON(DEFAULT_SETTINGS) or "{}"
jsonBox.Parent=tabEggs; Instance.new("UICorner",jsonBox).CornerRadius=UDim.new(0,8)
local jp = Instance.new("UIPadding"); jp.PaddingLeft=UDim.new(0,8); jp.PaddingRight=UDim.new(0,8); jp.PaddingTop=UDim.new(0,6); jp.Parent=jsonBox

-- Row 5: Refresh / Copy / Load / AutoFarm (4 buttons across 316px available)
local ROW5_Y = ROW4_Y + 16 + JSON_BOX_H + ROW_GAP
local BTN_W = 76
local BTN_GAP = 4

refreshBtn = Instance.new("TextButton")
refreshBtn.Size=UDim2.new(0,BTN_W,0,26); refreshBtn.Position=UDim2.new(0,12,0,ROW5_Y)
refreshBtn.BackgroundColor3=Color3.fromRGB(45,100,160); refreshBtn.Text="Refresh"
refreshBtn.TextColor3=Color3.new(1,1,1); refreshBtn.TextSize=12
refreshBtn.Font=Enum.Font.GothamBold
refreshBtn.Active=true; refreshBtn.AutoButtonColor=true; refreshBtn.ZIndex=20
refreshBtn.Parent=tabEggs
Instance.new("UICorner",refreshBtn).CornerRadius=UDim.new(0,6)

copyBtn = Instance.new("TextButton")
copyBtn.Size=UDim2.new(0,BTN_W,0,26); copyBtn.Position=UDim2.new(0,12+BTN_W+BTN_GAP,0,ROW5_Y)
copyBtn.BackgroundColor3=Color3.fromRGB(60,130,90); copyBtn.Text="Copy JSON"
copyBtn.TextColor3=Color3.new(1,1,1); copyBtn.TextSize=11
copyBtn.Font=Enum.Font.GothamBold
copyBtn.Active=true; copyBtn.AutoButtonColor=true; copyBtn.ZIndex=20
copyBtn.Parent=tabEggs
Instance.new("UICorner",copyBtn).CornerRadius=UDim.new(0,6)

loadBtn = Instance.new("TextButton")
loadBtn.Size=UDim2.new(0,BTN_W,0,26); loadBtn.Position=UDim2.new(0,12+(BTN_W+BTN_GAP)*2,0,ROW5_Y)
loadBtn.BackgroundColor3=Color3.fromRGB(160,120,40); loadBtn.Text="Load JSON"
loadBtn.TextColor3=Color3.new(1,1,1); loadBtn.TextSize=11
loadBtn.Font=Enum.Font.GothamBold
loadBtn.Active=true; loadBtn.AutoButtonColor=true; loadBtn.ZIndex=20
loadBtn.Parent=tabEggs
Instance.new("UICorner",loadBtn).CornerRadius=UDim.new(0,6)

autoFarmBtn = Instance.new("TextButton")
autoFarmBtn.Name="AutoFarmBtn"
autoFarmBtn.Size=UDim2.new(0,BTN_W,0,26); autoFarmBtn.Position=UDim2.new(0,12+(BTN_W+BTN_GAP)*3,0,ROW5_Y)
autoFarmBtn.BackgroundColor3=Color3.fromRGB(90,50,50); autoFarmBtn.Text="[OFF] AutoFarm"
autoFarmBtn.TextColor3=Color3.new(1,1,1); autoFarmBtn.TextSize=11
autoFarmBtn.Font=Enum.Font.GothamBold
autoFarmBtn.Active=true; autoFarmBtn.AutoButtonColor=true
autoFarmBtn.TextWrapped=false; autoFarmBtn.TextTruncate=Enum.TextTruncate.None
autoFarmBtn.ClipsDescendants=false
autoFarmBtn.ZIndex=25
autoFarmBtn.Parent=tabEggs
Instance.new("UICorner",autoFarmBtn).CornerRadius=UDim.new(0,6)

-- Row 6: Status
local ROW6_Y = ROW5_Y + 26 + ROW_GAP
statusLabel = Instance.new("TextLabel")
statusLabel.Size=UDim2.new(1,-24,0,20); statusLabel.Position=UDim2.new(0,12,0,ROW6_Y)
statusLabel.BackgroundTransparency=1; statusLabel.Text="Loading eggs..."
statusLabel.TextColor3=Color3.fromRGB(180,195,220); statusLabel.TextSize=12
statusLabel.Font=Enum.Font.Gotham; statusLabel.TextXAlignment=Enum.TextXAlignment.Left; statusLabel.Parent=tabEggs

-- Egg list
local LIST_Y = ROW6_Y + 22
listFrame = Instance.new("ScrollingFrame")
listFrame.Size=UDim2.new(1,-24,1,-(LIST_Y+10)); listFrame.Position=UDim2.new(0,12,0,LIST_Y)
listFrame.BackgroundColor3=Color3.fromRGB(16,18,24); listFrame.BorderSizePixel=0
listFrame.ScrollBarThickness=6; listFrame.CanvasSize=UDim2.new(0,0,0,0); listFrame.Parent=tabEggs
Instance.new("UICorner",listFrame).CornerRadius=UDim.new(0,8)
local ll = Instance.new("UIListLayout"); ll.Padding=UDim.new(0,3); ll.Parent=listFrame



    -- Drag support for main window
-- Drag
local dragging, dragStart, startPos
titleBar.InputBegan:Connect(function(i)
    if i.UserInputType==Enum.UserInputType.MouseButton1 then
        dragging=true; dragStart=i.Position; startPos=main.Position
    end
end)
titleBar.InputEnded:Connect(function(i)
    if i.UserInputType==Enum.UserInputType.MouseButton1 then dragging=false end
end)
UserInputService.InputChanged:Connect(function(i)
    if dragging and i.UserInputType==Enum.UserInputType.MouseMovement then
        local d=i.Position-dragStart
        main.Position=UDim2.new(startPos.X.Scale,startPos.X.Offset+d.X,startPos.Y.Scale,startPos.Y.Offset+d.Y)
    end
end)



    -- Populate Tab 2
    buildPetsTabUI()
end
buildMainUI()
-- ==================================================
-- EGG CARD  (compact single-row list item)
-- ==================================================
local CARD_HEIGHT = 34   -- compact row height

local function createEggCard(idx, r)
    local uid     = tostring(r.Uid or "")
    local sp      = tostring(r.AssetCategory or "Unknown")
    local slot    = tostring(r.NestId or "?")
    local area    = tostring(r.AreaId or "?")
    local pos     = extPos(r)
    local mut     = mutLabel(r)
    local hl      = highlightRarity(r)
    local fullRar = effectiveRarity(r)
    local rarCol  = ALL_RARITY_COLORS[fullRar] or RARITY_DEFAULT_COLOR

    -- card background: slightly tinted for high-rarity eggs
    local bg = hl and Color3.fromRGB(45, 18, 18) or Color3.fromRGB(26, 30, 40)
    local card = Instance.new("Frame")
    card.Size             = UDim2.new(1, -12, 0, CARD_HEIGHT)
    card.BackgroundColor3 = bg
    card.BorderSizePixel  = 0
    card.Parent           = listFrame
    Instance.new("UICorner", card).CornerRadius = UDim.new(0, 6)

    -- left rarity colour strip (always present)
    local strip = Instance.new("Frame")
    strip.Size             = UDim2.new(0, 3, 1, -6)
    strip.Position         = UDim2.new(0, 4, 0, 3)
    strip.BackgroundColor3 = rarCol
    strip.BorderSizePixel  = 0
    strip.Parent           = card
    Instance.new("UICorner", strip).CornerRadius = UDim.new(0, 2)

    local LEFT = 13   -- x offset after the strip

    -- index + egg name (top half)
    local nm = Instance.new("TextLabel")
    nm.Size               = UDim2.new(1, -(LEFT + 82), 0, 18)
    nm.Position           = UDim2.new(0, LEFT, 0, 2)
    nm.BackgroundTransparency = 1
    nm.Text               = ("#%d  %s"):format(idx, sp)
    nm.TextColor3         = hl and Color3.fromRGB(255, 195, 195) or Color3.fromRGB(215, 225, 255)
    nm.TextSize           = 12
    nm.Font               = Enum.Font.GothamBold
    nm.TextXAlignment     = Enum.TextXAlignment.Left
    nm.TextTruncate       = Enum.TextTruncate.AtEnd
    nm.Parent             = card

    -- secondary line: area · nest · mutation
    local subParts = { area, slot }
    if mut then table.insert(subParts, mut) end
    local sub = Instance.new("TextLabel")
    sub.Size               = UDim2.new(1, -(LEFT + 82), 0, 13)
    sub.Position           = UDim2.new(0, LEFT, 0, 19)
    sub.BackgroundTransparency = 1
    sub.Text               = table.concat(subParts, " · ")
    sub.TextColor3         = Color3.fromRGB(130, 145, 175)
    sub.TextSize           = 10
    sub.Font               = Enum.Font.Gotham
    sub.TextXAlignment     = Enum.TextXAlignment.Left
    sub.TextTruncate       = Enum.TextTruncate.AtEnd
    sub.Parent             = card

    -- rarity badge (vertically centred, to the left of the Get button)
    local rab = Instance.new("TextLabel")
    rab.Size               = UDim2.new(0, 68, 0, 16)
    rab.Position           = UDim2.new(1, -134, 0.5, -8)
    rab.BackgroundColor3   = rarCol
    rab.Text               = " " .. fullRar .. " "
    rab.TextColor3         = Color3.new(1, 1, 1)
    rab.TextSize           = 9
    rab.Font               = Enum.Font.GothamBold
    rab.TextXAlignment     = Enum.TextXAlignment.Center
    rab.TextTruncate       = Enum.TextTruncate.AtEnd
    rab.Parent             = card
    Instance.new("UICorner", rab).CornerRadius = UDim.new(0, 4)

    -- compact Get button
    local gb = Instance.new("TextButton")
    gb.Size             = UDim2.new(0, 54, 0, 24)
    gb.Position         = UDim2.new(1, -62, 0.5, -12)
    gb.BackgroundColor3 = Color3.fromRGB(38, 125, 75)
    gb.Text             = "Get"
    gb.TextColor3       = Color3.new(1, 1, 1)
    gb.TextSize         = 12
    gb.Font             = Enum.Font.GothamBold
    gb.Parent           = card
    Instance.new("UICorner", gb).CornerRadius = UDim.new(0, 5)
    gb.MouseButton1Click:Connect(function()
        if autoFarmEnabled then toggleAutoFarm() end
        if pos then getEgg(pos, uid, statusLabel)
        else statusLabel.Text = "No position"; statusLabel.TextColor3 = Color3.fromRGB(255, 120, 120) end
    end)
end

-- ==================================================
-- SCAN / RENDER
-- ==================================================
local function clearList()
    for _, c in ipairs(listFrame:GetChildren()) do if c:IsA("Frame") then c:Destroy() end end
end

local function ingestSpecies(records)
    local changed = false
    for _, r in ipairs(records) do
        local s = r.AssetCategory
        if typeof(s)=="string" and s~="" and not speciesSeen[s] then
            speciesSeen[s]=true; table.insert(speciesOrder,s); changed=true
        end
    end
    if changed then
        table.sort(speciesOrder, function(a,b)
            if a=="All" then return true end
            if b=="All" then return false end
            return a < b
        end)
    end
    return changed
end

local function renderRecords(records, quiet)
    -- quiet = redraw the cards only; leave the status label to the autofarm
    local sl = quiet and { Text = "", TextColor3 = Color3.new() } or statusLabel
    clearList()
    if ingestSpecies(records) and rebuildFarmDropdownItems then rebuildFarmDropdownItems() end
    if #records==0 then
        sl.Text="No eggs found"; sl.TextColor3=Color3.fromRGB(255,160,100)
        listFrame.CanvasSize=UDim2.new(0,0,0,0); return
    end
    local d=0; local mc=0; local rc=0; local hid=0; local unv=0; local biomes={}
    X.hiddenLogged = X.hiddenLogged or {}
    for _, r in ipairs(records) do
        local gh, why = X.isGhost(r)
        if gh then
            hid=hid+1
            local hu = tostring(r.Uid or "")
            if not X.hiddenLogged[hu] then
                X.hiddenLogged[hu] = true
                print(("[EggGoToUI] hidden %s (%s) reason: %s"):format(tostring(r.AssetCategory), hu, tostring(why)))
            end
        elseif X.isUnverified(r) then unv=unv+1 end
        if passesFilters(r) then
            d=d+1
            local okc, ec = pcall(createEggCard, d, r)     -- v8: one bad record must not wipe the whole list
            if not okc then warn("[EggGoToUI] card error:", ec) end
            if mutLabel(r) then mc=mc+1 end
            if highlightRarity(r) then rc=rc+1 end
            if r.AreaId then biomes[tostring(r.AreaId)]=true end
        end
    end
    listFrame.CanvasSize=UDim2.new(0,0,0,d*(CARD_HEIGHT+3))
    if d==0 then
        sl.Text="No eggs match active filters"; sl.TextColor3=Color3.fromRGB(255,160,100); return
    end
    local bc=0; for _ in pairs(biomes) do bc=bc+1 end
    local farmCount=0; for _ in pairs(selectedSpecies) do farmCount=farmCount+1 end
    local suffix = selectedSpecies["All"] and "" or (" | "..(farmCount).." species")
    local sum=("%d eggs across %d biome(s)%s"):format(d,bc,suffix)
    if hid>0 then sum=sum..(" | %d hidden"):format(hid) end
    if unv>0 then sum=sum..(" | %d unverified"):format(unv) end
    if mc>0 then sum=sum..(" | %d mutated"):format(mc) end
    if rc>0 then sum=sum..(" | ⚠ %d HIGH"):format(rc) end
    sl.Text=sum
    sl.TextColor3=rc>0 and Color3.fromRGB(255,120,120) or Color3.fromRGB(120,255,150)
end

local function scanEggs()
    statusLabel.Text="Fetching all eggs..."; statusLabel.TextColor3=Color3.fromRGB(255,220,100)
    task.spawn(function()
        local recs, e = X.fetchTimed(4)
        if not recs then
            statusLabel.Text="Error: "..tostring(e); statusLabel.TextColor3=Color3.fromRGB(255,120,120); return
        end
        local by = {}
        for _, r in ipairs(recs) do
            local u = tostring(r.Uid or "")
            if u ~= "" then by[u] = r end
        end
        pcall(X.updateSlotGhosts, by, recs)
        lastFetchedRecords=recs; renderRecords(recs)
    end)
end

function refilterAndRender()
    if lastFetchedRecords then renderRecords(lastFetchedRecords) else scanEggs() end
end

-- Live list: redraw whenever a new scan changes what the list would show (no flicker when unchanged,
-- scroll position kept, and the autofarm status text is never overwritten while farming).
local lastListSig = nil
onEggCacheUpdate = function(recs)
    lastFetchedRecords = recs
    local parts = { tostring(#recs) }
    for _, r in ipairs(recs) do
        if passesFilters(r) then
            local p = extPos(r)
            table.insert(parts, tostring(r.Uid) .. tostring(r.AssetCategory) .. (mutLabel(r) or "")
                .. (p and ("@%.0f,%.0f,%.0f"):format(p.X, p.Y, p.Z) or ""))
        end
    end
    local sig = table.concat(parts, "|")
    if sig == lastListSig and not X.listDirty then return end
    local cp = listFrame.CanvasPosition
    local okr, er = pcall(renderRecords, recs, autoFarmEnabled)
    if okr then
        lastListSig = sig; X.listDirty = false
    else
        lastListSig = nil          -- v8: a FAILED redraw must not be remembered as "up to date" (that froze the list before)
        warn("[EggGoToUI] list redraw failed:", er)
    end
    pcall(function() listFrame.CanvasPosition = cp end)
end
startEggScanner()

-- Live scan indicator (on the "Config JSON:" line): scan #, egg count and how old the newest scan is,
-- so a stuck scanner is obvious at a glance.
task.spawn(function()
    while not eggScannerStop and screenGui.Parent do
        local age = eggCache.t > 0 and (os.clock() - eggCache.t) or nil
        pcall(function()
            if age then
                jsonLabel.Text = ("Config JSON:   |   scan #%d · %d eggs · %.1fs ago%s"):format(
                    eggCache.seq, eggCache.records and #eggCache.records or 0, age, age > 3 and "  ⚠ STALE" or "")
            else
                jsonLabel.Text = "Config JSON:   |   waiting for first scan..."
            end
        end)
        task.wait(0.4)
    end
end)

-- ==================================================
-- FARM DROPDOWN (multi-select with search)
-- ==================================================
function updateFarmBtnText()
    if selectedSpecies["All"] then
        farmDropdownBtn.Text = "All ▼"
        return
    end
    local count = 0
    local first = nil
    for k in pairs(selectedSpecies) do
        count = count + 1
        if not first then first = k end
    end
    if count == 0 then
        farmDropdownBtn.Text = "None ▼"
    elseif count == 1 then
        farmDropdownBtn.Text = first .. " ▼"
    else
        farmDropdownBtn.Text = first .. " +" .. (count-1) .. " ▼"
    end
end

function rebuildFarmDropdownItems()
    for _, c in ipairs(farmDropScroll:GetChildren()) do
        if c:IsA("TextButton") then c:Destroy() end
    end
    local q = farmSearchBox.Text:lower():gsub("^%s+",""):gsub("%s+$","")

    for _, sp in ipairs(speciesOrder) do
        if q == "" or string.find(string.lower(sp), q, 1, true) then
            local btn = Instance.new("TextButton")
            btn.Size = UDim2.new(1,-4,0,22)
            local checked
            if sp == "All" then
                checked = selectedSpecies["All"] == true
            else
                checked = selectedSpecies[sp] == true
            end
            btn.BackgroundColor3 = checked and Color3.fromRGB(55,90,130) or Color3.fromRGB(40,48,65)
            btn.Text = (checked and "[X] " or "[ ] ") .. sp
            btn.TextColor3 = Color3.new(1,1,1)
            btn.TextSize = 12
            btn.Font = Enum.Font.Gotham
            btn.TextXAlignment = Enum.TextXAlignment.Left
            btn.AutoLocalize = false
            btn.Parent = farmDropScroll
            local pad = Instance.new("UIPadding"); pad.PaddingLeft=UDim.new(0,8); pad.Parent=btn

            btn.MouseButton1Click:Connect(function()
                if sp == "All" then
                    -- Toggle All: if already All, deselect to None; otherwise select All and clear others
                    if selectedSpecies["All"] then
                        selectedSpecies = {}
                    else
                        selectedSpecies = { ["All"] = true }
                    end
                else
                    -- Toggle this species; also clear "All" if it's on
                    if selectedSpecies["All"] then selectedSpecies = {} end
                    if selectedSpecies[sp] then
                        selectedSpecies[sp] = nil
                    else
                        selectedSpecies[sp] = true
                    end
                end
                -- Sync currentSettings
                local list = {}
                for k in pairs(selectedSpecies) do table.insert(list, k) end
                table.sort(list)
                currentSettings.SpeciesFilter = list
                jsonBox.Text = settingsToJSON(currentSettings) or jsonBox.Text
                updateFarmBtnText()
                rebuildFarmDropdownItems()
                refilterAndRender()
            end)
        end
    end
end

farmSearchBox:GetPropertyChangedSignal("Text"):Connect(rebuildFarmDropdownItems)

-- (farmAllBtn/farmNoneBtn wired in buildMainUI)

local function toggleFarmDropdown()
    farmDropdownOpen = not farmDropdownOpen
    farmDropdownList.Visible = farmDropdownOpen
    if farmDropdownOpen then
        local fh = #speciesOrder * 22
        local sh = math.min(fh, X.MAX_FARM_DD_HEIGHT)
        farmDropScroll.Size = UDim2.new(1,0,0,sh)
        farmDropdownList.Size = UDim2.new(0,258,0,56+sh)
        farmDropdownBtn.Text = selectedSpecies["All"] and "All ▲" or (farmDropdownBtn.Text:gsub("▼","▲"))
        rebuildFarmDropdownItems()
    else
        farmDropdownList.Size = UDim2.new(0,258,0,0)
        updateFarmBtnText()
    end
end
farmDropdownBtn.MouseButton1Click:Connect(function()
    if X.closeRarity then X.closeRarity() end
    toggleFarmDropdown()
end)

-- ==================================================
-- RARITY DROPDOWN (multi-select) — v9
-- ==================================================
do
    local R = { ITEM_H = 22, QUICK_H = 28, LIST_W = 258, rowY = X.ROW3_Y + X.ROW_H + X.ROW_GAP, open = false }

    R.label = Instance.new("TextLabel")
    R.label.Size=UDim2.new(0,55,0,X.ROW_H); R.label.Position=UDim2.new(0,12,0,R.rowY)
    R.label.BackgroundTransparency=1; R.label.Text="Rarity:"
    R.label.TextColor3=Color3.fromRGB(180,195,220); R.label.TextSize=13
    R.label.Font=Enum.Font.Gotham; R.label.TextXAlignment=Enum.TextXAlignment.Left; R.label.Parent=tabEggs

    R.btn = Instance.new("TextButton")
    R.btn.Size=UDim2.new(0,R.LIST_W,0,X.ROW_H); R.btn.Position=UDim2.new(0,70,0,R.rowY)
    R.btn.BackgroundColor3=Color3.fromRGB(40,48,65); R.btn.Text="Off ▼"
    R.btn.TextColor3=Color3.new(1,1,1); R.btn.TextSize=13
    R.btn.Font=Enum.Font.GothamBold; R.btn.Parent=tabEggs
    Instance.new("UICorner",R.btn).CornerRadius=UDim.new(0,6)

    R.list = Instance.new("Frame")
    R.list.Size=UDim2.new(0,R.LIST_W,0,0); R.list.Position=UDim2.new(0,70,0,R.rowY+X.ROW_H+2)
    R.list.BackgroundColor3=Color3.fromRGB(30,36,50); R.list.BorderSizePixel=0
    R.list.ClipsDescendants=true; R.list.Visible=false; R.list.ZIndex=31; R.list.Parent=tabEggs
    Instance.new("UICorner",R.list).CornerRadius=UDim.new(0,6)

    function R.btnText(arrow)
        local names = {}
        for _, n in ipairs(X.RARITY_ORDER) do if X.selectedRarities[n] then table.insert(names, n) end end
        local t
        if #names == 0 then t = "Off (species only)"
        elseif #names == 1 then t = names[1]
        else t = names[1] .. " +" .. (#names - 1) end
        return t .. " " .. arrow
    end

    function R.sync()
        local l = {}
        for k in pairs(X.selectedRarities) do table.insert(l, k) end
        table.sort(l)
        currentSettings.RarityFilter = l
        jsonBox.Text = settingsToJSON(currentSettings) or jsonBox.Text
        X.refreshRarityUI()
        refilterAndRender()
    end

    function X.refreshRarityUI()
        R.btn.Text = R.btnText(R.open and "▲" or "▼")
        for _, c in ipairs(R.list:GetChildren()) do
            if c:IsA("TextButton") then c:Destroy() end
        end
        local clr = Instance.new("TextButton")
        clr.Size=UDim2.new(1,-8,0,R.QUICK_H-4); clr.Position=UDim2.new(0,4,0,2)
        clr.BackgroundColor3=Color3.fromRGB(90,45,45); clr.Text="Clear (rarity filter off)"
        clr.TextColor3=Color3.new(1,1,1); clr.TextSize=12; clr.Font=Enum.Font.GothamBold
        clr.Parent=R.list; Instance.new("UICorner",clr).CornerRadius=UDim.new(0,4)
        clr.MouseButton1Click:Connect(function() X.selectedRarities = {}; R.sync() end)

        for i, n in ipairs(X.RARITY_ORDER) do
            local on = X.selectedRarities[n] == true
            local b = Instance.new("TextButton")
            b.Size=UDim2.new(1,-8,0,R.ITEM_H-2); b.Position=UDim2.new(0,4,0,R.QUICK_H+(i-1)*R.ITEM_H)
            b.BackgroundColor3 = on and Color3.fromRGB(55,90,130) or Color3.fromRGB(40,48,65)
            b.Text = (on and "[X] " or "[ ] ") .. n
            b.TextColor3 = ALL_RARITY_COLORS[n] or Color3.new(1,1,1)
            b.TextSize=12; b.Font=Enum.Font.GothamBold; b.TextXAlignment=Enum.TextXAlignment.Left
            b.AutoLocalize=false; b.Parent=R.list
            Instance.new("UICorner",b).CornerRadius=UDim.new(0,4)
            local pad = Instance.new("UIPadding"); pad.PaddingLeft=UDim.new(0,8); pad.Parent=b
            b.MouseButton1Click:Connect(function()
                if X.selectedRarities[n] then X.selectedRarities[n] = nil else X.selectedRarities[n] = true end
                R.sync()
            end)
        end
    end

    function X.closeRarity()
        if not R.open then return end
        R.open = false; R.list.Visible = false; R.list.Size = UDim2.new(0,R.LIST_W,0,0)
        R.btn.Text = R.btnText("▼")
    end

    R.btn.MouseButton1Click:Connect(function()
        if R.open then X.closeRarity(); return end
        if farmDropdownOpen then toggleFarmDropdown() end
        R.open = true; R.list.Visible = true
        R.list.Size = UDim2.new(0,R.LIST_W,0,R.QUICK_H + #X.RARITY_ORDER * R.ITEM_H)
        X.refreshRarityUI()
    end)

    addConnection(UserInputService.InputBegan:Connect(function(input)
        if not R.open or input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
        local p = input.Position
        local function inside(o)
            local a, s = o.AbsolutePosition, o.AbsoluteSize
            return p.X>=a.X and p.X<=a.X+s.X and p.Y>=a.Y and p.Y<=a.Y+s.Y
        end
        if not inside(R.btn) and not inside(R.list) then X.closeRarity() end
    end))

    X.refreshRarityUI()
end

-- ==================================================
-- CLICK-OUTSIDE
-- ==================================================
UserInputService.InputBegan:Connect(function(input)
    if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
    local p = input.Position
    local function isInside(btn, list)
        local a = btn.AbsolutePosition; local s = btn.AbsoluteSize
        local ib = p.X>=a.X and p.X<=a.X+s.X and p.Y>=a.Y and p.Y<=a.Y+s.Y
        local la = list.AbsolutePosition; local ls = list.AbsoluteSize
        local il = p.X>=la.X and p.X<=la.X+ls.X and p.Y>=la.Y and p.Y<=la.Y+ls.Y
        return ib or il
    end
    if farmDropdownOpen and not isInside(farmDropdownBtn, farmDropdownList) then
        farmDropdownOpen=false; farmDropdownList.Visible=false
        farmDropdownList.Size=UDim2.new(0,258,0,0); updateFarmBtnText()
    end
end)

-- ==================================================
-- BUTTON WIRING
-- ==================================================
refreshBtn.MouseButton1Click:Connect(function()
    -- If autofarm is running it will re-scan on its own; just force a re-scan.
    scanEggs()
end)

autoFarmBtn.MouseButton1Click:Connect(function()
    pcall(function() toggleAutoFarm() end)
end)

copyBtn.MouseButton1Click:Connect(function()
    local v=tonumber(velInputBox.Text)
    if v and v>0 then X.baseVelocity=v end
    local cv=tonumber(carryVelInputBox.Text)
    if cv and cv>0 then X.baseCarryVelocity=cv end
    -- Sync live state
    currentSettings.Velocity=velocityEnabled
    currentSettings.VelocityValue=X.baseVelocity
    currentSettings.CarryVelocityValue=X.baseCarryVelocity
    currentSettings.Recovery=recoveryEnabled
    currentSettings.AutoReturn=autoReturnEnabled
    local ml={}
    for k in pairs(activeMutationFilter) do table.insert(ml,k) end
    table.sort(ml); currentSettings.MutationFilter=ml
    local sl={}
    for k in pairs(selectedSpecies) do table.insert(sl,k) end
    table.sort(sl); currentSettings.SpeciesFilter=sl
    local rl={}
    for k in pairs(X.selectedRarities) do table.insert(rl,k) end
    table.sort(rl); currentSettings.RarityFilter=rl
    currentSettings.SafeZone={X=SAFE_ZONE.X,Y=SAFE_ZONE.Y,Z=SAFE_ZONE.Z}

    local j=settingsToJSON(currentSettings)
    if not j then
        statusLabel.Text="Copy failed"; statusLabel.TextColor3=Color3.fromRGB(255,120,120); return
    end
    jsonBox.Text=j
    local clipOk=false
    if typeof(setclipboard)=="function" then clipOk=pcall(setclipboard,j) end
    statusLabel.Text=clipOk and "Copied to clipboard" or "Copied to textbox"
    statusLabel.TextColor3=Color3.fromRGB(120,255,150)
end)

loadBtn.MouseButton1Click:Connect(function()
    local ok, decoded = pcall(function() return HttpService:JSONDecode(jsonBox.Text) end)
    if not ok then
        statusLabel.Text="Invalid JSON"; statusLabel.TextColor3=Color3.fromRGB(255,120,120); return
    end
    local a, e = applySettings(decoded)
    if not a then
        statusLabel.Text="Load failed: "..tostring(e); statusLabel.TextColor3=Color3.fromRGB(255,120,120); return
    end
    upVelBtn()
    upRecBtn()
    if velocityEnabled then enableVelocity() else disableVelocity() end
    updateFarmBtnText()
    rebuildFarmDropdownItems()
    if X.refreshRarityUI then X.refreshRarityUI() end
    velInputBox.Text=tostring(math.floor(X.baseVelocity))
    carryVelInputBox.Text=tostring(math.floor(X.baseCarryVelocity))
    jsonBox.Text=settingsToJSON(currentSettings) or jsonBox.Text
    statusLabel.Text="Config loaded"; statusLabel.TextColor3=Color3.fromRGB(120,255,150)
    refilterAndRender()
end)

-- ==================================================
-- VELOCITY / RECOVERY TOGGLES
-- ==================================================
function upVelBtn()
    if velocityEnabled then
        velToggleBtn.Text="[ON] Velocity"
        velToggleBtn.BackgroundColor3=Color3.fromRGB(35,135,75)
        velToggleBtn.TextColor3=Color3.new(1,1,1)
    else
        velToggleBtn.Text="[OFF] Velocity"
        velToggleBtn.BackgroundColor3=Color3.fromRGB(42,48,65)
        velToggleBtn.TextColor3=Color3.fromRGB(210,220,240)
    end
end

function upVelIn()
    local v=tonumber(velInputBox.Text)
    if v and v>0 then
        X.baseVelocity=v
        if currentSettings then
            currentSettings.VelocityValue=v
            if jsonBox then jsonBox.Text = settingsToJSON(currentSettings) or jsonBox.Text end
        end
        if not weAreCarrying and not isHoldingEgg() then
            targetVelocity=v
            if velocityEnabled then
                local ch=LocalPlayer.Character
                local h=ch and ch:FindFirstChildOfClass("Humanoid")
                if h then pcall(function() h.WalkSpeed=targetVelocity end) end
            end
        end
        velInputStroke.Color=Color3.fromRGB(60,140,240)
        upVelBtn()
    else
        velInputBox.Text=tostring(math.floor(X.baseVelocity))
        velInputStroke.Color=Color3.fromRGB(60,80,115)
    end
end
velInputBox.FocusLost:Connect(upVelIn)
velInputBox:GetPropertyChangedSignal("Text"):Connect(function()
    local v=tonumber(velInputBox.Text)
    if v and v>0 then
        X.baseVelocity=v
        if currentSettings then currentSettings.VelocityValue=v end
        if not weAreCarrying and not isHoldingEgg() then
            targetVelocity=v
            if velocityEnabled then
                local ch=LocalPlayer.Character
                local h=ch and ch:FindFirstChildOfClass("Humanoid")
                if h then pcall(function() h.WalkSpeed=targetVelocity end) end
            end
        end
        upVelBtn()
    end
end)

function upCarryVelIn()
    local v=tonumber(carryVelInputBox.Text)
    if v and v>0 then
        X.baseCarryVelocity=v
        if currentSettings then
            currentSettings.CarryVelocityValue=v
            if jsonBox then jsonBox.Text = settingsToJSON(currentSettings) or jsonBox.Text end
        end
        if weAreCarrying or isHoldingEgg() then
            targetVelocity=v
            if velocityEnabled then
                local ch=LocalPlayer.Character
                local h=ch and ch:FindFirstChildOfClass("Humanoid")
                if h then pcall(function() h.WalkSpeed=targetVelocity end) end
            end
        end
        carryInputStroke.Color=Color3.fromRGB(60,140,240)
        upVelBtn()
    else
        carryVelInputBox.Text=tostring(math.floor(X.baseCarryVelocity))
        carryInputStroke.Color=Color3.fromRGB(60,80,115)
    end
end
carryVelInputBox.FocusLost:Connect(upCarryVelIn)
carryVelInputBox:GetPropertyChangedSignal("Text"):Connect(function()
    local v=tonumber(carryVelInputBox.Text)
    if v and v>0 then
        X.baseCarryVelocity=v
        if currentSettings then currentSettings.CarryVelocityValue=v end
        if weAreCarrying or isHoldingEgg() then
            targetVelocity=v
            if velocityEnabled then
                local ch=LocalPlayer.Character
                local h=ch and ch:FindFirstChildOfClass("Humanoid")
                if h then pcall(function() h.WalkSpeed=targetVelocity end) end
            end
        end
        upVelBtn()
    end
end)

velToggleBtn.MouseButton1Click:Connect(function()
    upVelIn()
    upCarryVelIn()
    velocityEnabled=not velocityEnabled
    if velocityEnabled then enableVelocity() else disableVelocity() end
    upVelBtn()
    if currentSettings then
        currentSettings.Velocity=velocityEnabled
        if jsonBox then jsonBox.Text = settingsToJSON(currentSettings) or jsonBox.Text end
    end
end)

function upRecBtn()
    if recoveryEnabled then
        recoveryToggleBtn.Text="[ON] Recovery"
        recoveryToggleBtn.BackgroundColor3=Color3.fromRGB(35,135,75)
        recoveryToggleBtn.TextColor3=Color3.new(1,1,1)
    else
        recoveryToggleBtn.Text="[OFF] Recovery"
        recoveryToggleBtn.BackgroundColor3=Color3.fromRGB(42,48,65)
        recoveryToggleBtn.TextColor3=Color3.fromRGB(210,220,240)
    end
end
recoveryToggleBtn.MouseButton1Click:Connect(function()
    recoveryEnabled=not recoveryEnabled
    if not recoveryEnabled then recoveryState=RECOVERY_STATE.NONE end
    upRecBtn()
    if currentSettings then
        currentSettings.Recovery=recoveryEnabled
        if jsonBox then jsonBox.Text = settingsToJSON(currentSettings) or jsonBox.Text end
    end
end)

upVelBtn(); upRecBtn(); updateFarmBtnText()

function toggleMenuVisible()
    main.Visible = not main.Visible
    menuToggleBtn.Text = "☰"
end
menuToggleBtn.MouseButton1Click:Connect(toggleMenuVisible)

local function fullCleanup()
    _G.EggGoToUI_Stop = true
    eggScannerStop = true
    autoFarmEnabled = false
    autoFarmToken = autoFarmToken + 1
    walkToken = walkToken + 1
    X.tripUntil = 0
    velocityEnabled = false
    recoveryEnabled = false
    recoveryActive = false
    disableVelocity()
    disconnectAll()
    local ch = LocalPlayer.Character
    local h = ch and ch:FindFirstChildOfClass("Humanoid")
    local r = ch and ch:FindFirstChild("HumanoidRootPart")
    if h then
        pcall(function()
            h:Move(Vector3.zero)
            if r then h.WalkToPoint = r.Position end
            h.WalkSpeed = (savedWalkSpeed and savedWalkSpeed > 0) and savedWalkSpeed or 16
        end)
    end
    if r then
        pcall(function()
            r.AssemblyLinearVelocity = Vector3.zero
            r.AssemblyAngularVelocity = Vector3.zero
            r.Anchored = false
        end)
    end
    pcall(function()
        for _, n in ipairs({"EggGoToUI_v4","EggGoToUI_v5","EggGoToUI_v6","EggGoToUI_v7","EggGoToUI_v8","EggGoToUI_v9"}) do
            local old = PlayerGui:FindFirstChild(n); if old then old:Destroy() end
        end
        if screenGui and screenGui.Parent then screenGui:Destroy() end
    end)
    if _G.EggGoToUI_Cleanup == fullCleanup then
        _G.EggGoToUI_Cleanup = nil
    end
    print("[EggGoToUI] Full cleanup completed. All routines terminated.")
end
_G.EggGoToUI_Cleanup = fullCleanup

closeBtn.MouseButton1Click:Connect(fullCleanup)

-- ==================================================
-- HEARTBEAT LOOPS
-- ==================================================
addConnection(RunService.Heartbeat:Connect(function()
    local ch=LocalPlayer.Character
    local h=ch and ch:FindFirstChildOfClass("Humanoid")
    local r=ch and ch:FindFirstChild("HumanoidRootPart")
    if not h or not r then velStatusLabel.Text="  Vel: --"; return end
    local hv=Vector3.new(r.AssemblyLinearVelocity.X,0,r.AssemblyLinearVelocity.Z)
    local v=math.floor(hv.Magnitude)
    if isRagdolled then
        local tag=recoveryEnabled and "RECOVERY" or "RAGDOLL"
        velStatusLabel.Text=("  Vel: %d | %s"):format(v,tag)
        velStatusLabel.TextColor3=Color3.fromRGB(255,180,80)
    else
        local egg=isHoldingEgg()
        velStatusLabel.Text=("  Vel: %d%s%s%s%s"):format(v, egg and " | Egg" or "", recoveryActive and " | Recovering" or "",
            targetVelocity < X.baseVelocity and (" | ↓" .. math.floor(targetVelocity)) or "",
            (X.rubberCount > 0 and (" | RB " .. X.rubberCount) or "")
                .. (velocityEnabled and (X.rbGate == "off" and " | RB off" or (X.rbSpd and (" | spd " .. math.floor(X.rbSpd)) or "")) or ""))
        velStatusLabel.TextColor3=velocityEnabled and Color3.fromRGB(100,240,255) or Color3.fromRGB(140,190,240)
    end
end))

addConnection(RunService.Heartbeat:Connect(updateRagdollStatus))
addConnection(RunService.Heartbeat:Connect(applyRecovery))
addConnection(RunService.Heartbeat:Connect(X.detectRubberband))
addConnection(RunService.Heartbeat:Connect(applyVelocity))

addConnection(LocalPlayer.CharacterAdded:Connect(function(ch)
    task.wait(0.5)
    recoveryActive=false; recoveryState=RECOVERY_STATE.NONE
    lastMoveDirection=Vector3.zero; isRagdolled=false
    wasRagdolledForVelocity=false; lastGoodCFrame=nil
    local h=ch:FindFirstChildOfClass("Humanoid")
    local r=ch:FindFirstChild("HumanoidRootPart")
    if h and r then
        if stateChangedConn then pcall(function() stateChangedConn:Disconnect() end) end
        stateChangedConn=bindFastRagdoll(h,r)
        addConnection(stateChangedConn)
    end
    if velocityEnabled then
        setFrictionless(true)
        if h then savedWalkSpeed=h.WalkSpeed end
    end
end))

do
    local ch=LocalPlayer.Character
    if ch then
        local h=ch:FindFirstChildOfClass("Humanoid")
        local r=ch:FindFirstChild("HumanoidRootPart")
        if h and r then
            stateChangedConn=bindFastRagdoll(h,r)
            addConnection(stateChangedConn)
        end
    end
end

-- Init
applySettings(deepCopy(DEFAULT_SETTINGS))
upVelBtn(); upRecBtn(); updateFarmBtnText()
rebuildFarmDropdownItems()
if X.refreshRarityUI then X.refreshRarityUI() end
velInputBox.Text=tostring(math.floor(X.baseVelocity))
carryVelInputBox.Text=tostring(math.floor(X.baseCarryVelocity))
jsonBox.Text=settingsToJSON(currentSettings) or "{}"

task.defer(scanEggs)

print("[EggGoToUI v9.9] Loaded.")

end) -- end pcall

if not ok then
    warn("[EggGoToUI v9] FAILED TO LOAD: " .. tostring(err))
end
