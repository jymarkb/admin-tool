--[[
    Egg Go-To UI v10 (Clean Rebuild & Master Performance Architecture)
    ===========================================================================================
    REBUILD HIGHLIGHTS & ARCHITECTURAL UPGRADES (v10):

    1. STOLEN DROPPED EGG FREEZE & LAG RESOLVED (Issue #1):
       - If an opponent picks up / steals our dropped egg, carrier and base plot detection
         now strictly overrides weDropped / dropRetry flags immediately.
       - dropRetry, weDropped, and looseUids are purged at once, blacklisting the stolen egg.
       - Eliminates the infinite 0.1s retry storm, rapid InvokeServer forceScan flooding,
         and continuous DOM destruction/re-instantiation freezes.

    2. COMPREHENSIVE PERFORMANCE & FPS ENGINE AUDIT (Issue #2):
       - Neutralise physics: eliminated heavy per-frame ch:GetDescendants() and CRA scans
         on Heartbeat; now runs once upon pickup confirmation and throttled to 2.0s intervals.
       - Ragdoll check: eliminated per-frame ch:GetDescendants() Motor6D tree traversal;
         now event-driven via Humanoid.StateChanged and only queries Motor6Ds when humanoid is
         actually in FallingDown/Physics/Ragdoll states.
       - Rubberband detector: eliminated per-frame RaycastParams allocations and throttled
         Workspace raycasting to 4 Hz (every 0.25s) with a static reusable parameter object.
       - Velocity & Telemetry: throttled Heartbeat label updates from 60-144 Hz to 10 Hz.
       - UI DOM Virtualization: skipped card list re-renders when UI is closed or not on Eggs tab.
       - Network push deduplication: filtered FieldEggShifted / BatchShifted dirty triggers.

    3. BOOST FPS ENGINE (POTATO MODE) (Issue #3):
       - Added high-performance Potato / Boost FPS toggle (UI button in Main controls).
       - Disables global shadows, fog, lighting post-processing (Bloom, Blur, ColorCorrection,
         SunRays, DepthOfField), terrain water wave speed/size/reflectance, particle emitters,
         smoke, fire, trails, sparkles, and sets Workspace BasePart materials to SmoothPlastic.
       - Hooks DescendantAdded while active to auto-downgrade newly spawned particles/lights.
       - Fully reversible with original settings restored upon toggle off or script cleanup.

    4. LIVE FPS & PING TELEMETRY INDICATOR (Issue #4):
       - Integrated live telemetry indicator prominently on the Main Title Bar.
       - Real-time rolling FPS counter and network ping (ms) with dynamic color status:
         Green (Smooth: >50 FPS, <120ms), Yellow (Moderate), Red (Degraded).

    5. RESILIENT BUMP HANDLING & SAFEZONE WALK PREVENTION (Issue #5):
       - The instant a boss bump or player ragdoll occurs while carrying, the return trip
         walkTo thread is immediately halted and Humanoid movement is zeroed instantly.
       - If the egg is dropped, it breaks immediately into drop recovery without waiting 1-3s.
       - Character never takes a single step towards safezone before fetching the dropped egg!

    6. MULTI-BUMP PERSISTENCE (Issue #6):
       - Bumps no longer count as pickup failures, delivered marks, or blacklist triggers!
       - AutoFarm will NOT give up on 3 bumps; it persistently re-fetches the dropped egg up to
         configurable MaxBumpRetries (default: 8, or infinite for Divine/Eternal/Secret).

    7. NEST EGG & LATE LOGIN RELIABILITY (Issue #7):
       - Added 5-second startup grace period so client slots and world streaming can load before
         ghost filtering evaluates missing slots.
       - When arriving at a nest, AutoFarm does NOT abort on a missing client slot if the authoritative
         server snapshot confirms the egg exists. It proceeds to invoke the carry request.
       - Eliminates false-negative ghost blacklisting on eggs present before login.
]]

local ok, err = pcall(function()

-- Terminate any previous running instance of this script
if _G.EggGoToUI_Cleanup then
    pcall(_G.EggGoToUI_Cleanup)
end
_G.EggGoToUI_Stop = false

if _G.SpamPickup_Cleanup then
    pcall(_G.SpamPickup_Cleanup)
end
_G.SpamPickup_Cleanup = nil

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

local SAFE_ZONE = Vector3.new(534.090, 70.724, -326.616)

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
    ["Swordfish"]="Epic", ["Shark"]="Legendary", ["Mutant Shark"]="Secret", ["Orca"]="Mythic",
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
    ["Crab"]="Legendary", ["Kaiju Spider"]="Legendary", ["Blade Head"]="Mythic", ["Mantis"]="Cosmic",
    ["Rhino"]="Cosmic",
    ["Gorilla King"]="Eternal", ["King Kong"]="Eternal", -- King Kong egg asset -> Gorilla King (Eternal)
    ["Nightflame"]="Divine", ["Godzilla"]="Divine", ["Dove"]="Legendary", -- Godzilla egg asset on Titan Temple -> Nightflame (Divine)
    ["Lamb"]="Mythic", ["Moth"]="Cosmic", ["Peacock"]="Cosmic",
    ["Pure Jellyfish"]="Secret", ["Centaur"]="Secret", ["Pegasus"]="Eternal",
    ["ArchAngel"]="Divine", ["Flame Sprite"]="Legendary", ["Toro"]="Mythic",
    ["Imp"]="Cosmic", ["Demon Hound"]="Cosmic", ["Gargoyle"]="Secret",
    ["RazorFang"]="Secret", ["Skeleton Horse"]="Eternal", ["World Burner"]="Divine",
    ["Equinox"]="Eternal", ["Aetheron"]="Divine",
    ["Baby Aurora Dragon"]="Legendary", ["Shadow Dragon"]="Mythic",
    ["Scorched Dragon"]="Secret", ["ScorchedDragon"]="Secret", -- both spellings (scan uses no-space)
    ["Drilla"]="Cosmic",
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
    -- Verified Ground Truth Additions & Category Cross-Mappings
    ["Toxic Rat"]="Common", ["Radcoon"]="Common", ["Sharkodile"]="Legendary",
    ["Rhinobear"]="Mythic", ["Cave Dragon"]="Secret", ["Stacked Turtle"]="Rare",
    ["TyrannosaurusRex"]="Secret", ["TRex"]="Secret",
    ["Cosmic Gecko"]="Legendary", ["Cosmic Gorilla"]="Mythic",
    ["Winged Lamb"]="Mythic", ["Sacred Moth"]="Cosmic", ["Holy Peacock"]="Cosmic",
    ["Alien Skeleton Boss"]="Secret", ["Dark Gargoyle"]="Secret",
    ["Dream Axolotl"]="Legendary", ["Warden"]="Secret",
    ["Dragon"]="Eternal", ["Jellyfish"]="Secret",
    ["Nuclear Mantis"]="Divine", ["Nuceodille"]="Eternal", ["Toucax"]="Mythic",
    ["Godzilla"]="Divine",
    ["Frogfly"]="Rare", ["Wheel Hamster"]="Rare", ["Finned Thresher"]="Legendary",
    ["Mire Fox"]="Rare", ["Eye Bat"]="Rare", ["FennecFox"]="Uncommon",
    -- Newly discovered egg assets from game scan (new-full-scan-3.log)
    ["Hellhound"]="Legendary", ["Rattlesnake"]="Legendary",
    ["Burrowing Owl"]="Rare", ["Citadel Snail"]="Epic",
    ["Colossal Mammoth"]="Cosmic", ["Ascended Vermilion Phoenix"]="Divine",
    ["Balrog"]="Eternal", ["Basilisk"]="Cosmic",
    ["Archdemon Dragon"]="Divine", ["Ash Gecko"]="Epic",
    ["DesertLark"]="Rare", ["Uncoiled Armadillo"]="Epic",
    ["DeathstalkerScorpion"]="Mythic", ["Ringlord"]="Secret",
    ["Toxic Crocodile"]="Epic", ["Toxic Hedgehog"]="Rare",
    ["Riptide Octopus"]="Eternal", ["Depths Riptide Octopus"]="Divine",

    ------------- new update
    ["Prism Gecko"]="Legendary", ["Spirit Hare"] = "Cosmic",
    ["Cosmic Beetle Blue"] = "Mythic",
    ["Enchanted Bluejay"] = "Mythic",
    ["Spirit Panda"] = "Cosmic",
    ["Cosmic Fox"] = "Secret",

}

-- ==================================================
-- SETTINGS (no more presets, no rarity filter)
-- ==================================================
local DEFAULT_SETTINGS = {
    SafeZone           = { X = SAFE_ZONE.X, Y = SAFE_ZONE.Y, Z = SAFE_ZONE.Z },
    MutationFilter     = {},
    SpeciesFilter      = { "All" },
    RarityFilter       = {"Divine", "Eternal", "Secret"},
    AutoReturn         = true,
    Velocity           = false,
    VelocityValue      = 350,
    CarryVelocityValue = 320,
    Recovery           = true,
    MaxBumpRetries     = 8,
    PickupEnabled      = true,
    PickupReachAssist  = true,
    PickupMaxDistance  = 35,
    PickupBurstCount   = 8,
    PickupShowMiniHud  = false,
    TrapEvade          = true,
    AutoTreadmill      = false,
    AutoDismount       = false,
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

-- Pre-populate species will be executed dynamically below after X methods are initialized

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
    if t.MaxBumpRetries ~= nil and typeof(t.MaxBumpRetries) ~= "number" then
        return false, "MaxBumpRetries must be a number"
    end
    if t.PickupEnabled ~= nil and typeof(t.PickupEnabled) ~= "boolean" then
        return false, "PickupEnabled must be true/false"
    end
    if t.PickupReachAssist ~= nil and typeof(t.PickupReachAssist) ~= "boolean" then
        return false, "PickupReachAssist must be true/false"
    end
    if t.PickupMaxDistance ~= nil and typeof(t.PickupMaxDistance) ~= "number" then
        return false, "PickupMaxDistance must be a number"
    end
    if t.PickupBurstCount ~= nil and typeof(t.PickupBurstCount) ~= "number" then
        return false, "PickupBurstCount must be a number"
    end
    if t.PickupShowMiniHud ~= nil and typeof(t.PickupShowMiniHud) ~= "boolean" then
        return false, "PickupShowMiniHud must be true/false"
    end
    return true
end

-- ==================================================
-- VELOCITY / RECOVERY STATE
-- ==================================================
local velocityEnabled = false
local installWalkSpeedHook = nil
local targetVelocity  = 330
local savedWalkSpeed  = 16
local zeroFriction    = PhysicalProperties.new(0.7, 0.4, 0, 10, 10)
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
    startupGraceUntil     = os.clock() + 5.0,  -- 5s grace period on startup (Issue #7)
    maxBumpRetries        = 8,                 -- Max bump retries before retarget (Issue #6)
    lastPhysicsNeutralizeAt = 0,               -- Throttling physics neutralization (Issue #2)
    lastRaycastCheck      = 0,                 -- Throttling raycasts in rubberband (Issue #2)
    lastRtt               = nil,               -- Live measured server RPC round-trip time in ms
    recoveryCount         = 0,                 -- Total zero-wait recoveries executed
    jointsTable           = {},                -- Motor6D joints index
    recoveryConnections   = {},                -- Character recovery event listeners
    slamDampenerEnabled   = true,              -- Anti-slam downward velocity absorber
    attributeSpoofEnabled = true,              -- Spoof RagdollEndTime to 0
    RAGDOLL_STALE_AFTER   = 2.5,               -- a real hit-ragdoll ends well before this
    wasRagdolledForVelocity = false,
    -- Tab 4 Utility Pickup Configuration
    PICKUP_CONFIG         = {
        Enabled          = DEFAULT_SETTINGS.PickupEnabled,
        ReachAssist      = DEFAULT_SETTINGS.PickupReachAssist,
        MaxReachDistance = DEFAULT_SETTINGS.PickupMaxDistance,
        SpamBurstCount   = DEFAULT_SETTINGS.PickupBurstCount,
        ShowMiniHud      = DEFAULT_SETTINGS.PickupShowMiniHud,
    },
    -- Tab 4 Utility Trap Evade Configuration
    TRAP_CONFIG           = {
        Enabled       = DEFAULT_SETTINGS.TrapEvade,
        DangerRadius  = 7.0,                 -- tight hazard bubble around each trap (red visual range)
        ClearanceDist = 4.8,                 -- micro sidestep clearance (left/right)
        LookaheadDist = 16.0,                -- forward lookahead distance to detect traps early
        DisableHitbox = true,
        ShowVisuals   = true,                -- render red danger range rings
    },
    activeTraps           = {},
    autoTreadmillEnabled  = DEFAULT_SETTINGS.AutoTreadmill or false,
    autoDismountEnabled   = DEFAULT_SETTINGS.AutoDismount or false,
    noEggSince            = nil,
    nightResetTriggered   = false,
    mountedAtClockTime    = nil,
    lastNightResetAt      = nil,
    nightResetGraceUntil  = nil,
    -- Movement constants
    SLOW_ZONE             = 25,
    TELEPORT_ZONE         = 8,
    SNAP_RADIUS           = 60,                -- autofarm: snap onto egg within this distance
    SNAP_Y_OFFSET         = 3,
    SAFE_ARRIVE_RADIUS    = 8,
    SAFE_SNAP_RADIUS      = 60,
    -- Autofarm constants
    AUTO_RETRY            = 4,
    PICKUP_SPAM           = 1,
    AUTO_NEXT_DELAY       = 0.8,
    AUTO_EMPTY_WAIT       = 2.0,
    AUTO_CARRY_WAIT       = 0.4,
    HOLD_RELEASE_TIMEOUT  = 8,
    WALK_TIMEOUT          = 90,
    EGG_SCAN_INTERVAL     = 1.0,
    DROP_CONFIRM          = 0.6,
    -- Egg Card Pool
    CARD_HEIGHT           = 34,
    cardPool              = {},
}

-- v9 state + helpers (kept in X because the script is close to Luau's 200-locals limit)
X.baseVelocity      = 330    -- travel speed (going to egg). targetVelocity = this minus rubberband drops
X.baseCarryVelocity = 300    -- carry speed (returning with egg). X.switchToCarry() activates it.
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
X.scrambleRequiredSpecies = {}       -- map of normalized species names currently required by Dr. Scramble
X.scrambleMissingSpecies = {}        -- map of normalized species names STILL MISSING in inventory
X.scrambleInventoryLoaded = false     -- true once initial inventory scan has completed (even if 0 eggs owned)
X.prioritizeScrambleInAutoFarm = false -- Divine -> Eternal -> Secret -> Scramble Requirements -> farther
X.autoScrambleTrade = false            -- Automatically execute trade-in / fuse when all required eggs are in inventory
X.scrambleShowMissingOnly = true       -- Only show eggs currently missing to fuse in the Scramble requirements list

-- Bidirectional category/display-name aliases (e.g. Galaxy Gecko <-> Cosmic Gecko)
X.EGG_SPECIES_ALIASES = {
    ["galaxy gecko"] = "cosmic gecko",
    ["cosmic gecko"] = "galaxy gecko",
    ["cyclops gorilla"] = "cosmic gorilla",
    ["cosmic gorilla"] = "cyclops gorilla",
    ["dream axolotl"] = "axolotl",
    ["axolotl"] = "dream axolotl",
    ["holy peacock"] = "peacock",
    ["peacock"] = "holy peacock",
    ["sacred moth"] = "moth",
    ["moth"] = "sacred moth",
    ["winged lamb"] = "lamb",
    ["lamb"] = "winged lamb",
    ["warden"] = "king snake",
    ["king snake"] = "warden",
    ["alien skeleton boss"] = "cosmic skeleton boss",
    ["cosmic skeleton boss"] = "alien skeleton boss",
    ["dark gargoyle"] = "gargoyle",
    ["gargoyle"] = "dark gargoyle",
    -- T-Rex / TyrannosaurusRex: three spellings, all chained bidirectionally
    ["tyrannosaurusrex"] = "trex",
    ["trex"] = "tyrannosaurusrex",
    ["t-rex"] = "trex",         -- t-rex -> trex (then trex alias -> tyrannosaurusrex covers the rest)
    ["dragon"] = "lava dragon",
    ["lava dragon"] = "dragon",
    ["jellyfish"] = "pure jellyfish",
    ["pure jellyfish"] = "jellyfish",
    ["godzilla"] = "nightflame",
    ["nightflame"] = "godzilla",
    ["kaiju"] = "nightflame",
    ["king kong"] = "gorilla king",
    ["gorilla king"] = "king kong",
    ["fennecfox"] = "fennec",
    ["fennec"] = "fennecfox",
    ["scorcheddragon"] = "scorched dragon",  -- game scan uses no-space
    ["scorched dragon"] = "scorcheddragon",
    ["cave dragon"] = "cosmic dragon",       -- Cave Dragon egg asset -> Cosmic Dragon pet display
    ["cosmic dragon"] = "cave dragon",
    -- Lava Frog: scan has "Lava frog" (lowercase f) vs "Lava Frog"
    -- normalizeEggSpecies lowercases, so "lava frog" == "lava frog" -> handled by exact match
}


-- Canonical map from server internal AssetCategory to player-facing display name
X.CATEGORY_TO_DISPLAY = {
    ["Galaxy Gecko"] = "Cosmic Gecko",
    ["Cyclops Gorilla"] = "Cosmic Gorilla",
    ["Lamb"] = "Winged Lamb",
    ["Moth"] = "Sacred Moth",
    ["Peacock"] = "Holy Peacock",
    ["Dragon"] = "Lava Dragon",
    ["TyrannosaurusRex"] = "TRex",
    ["Alien Skeleton Boss"] = "Cosmic Skeleton Boss",
    ["Dark Gargoyle"] = "Gargoyle",
    ["Dream Axolotl"] = "Axolotl",
    ["Warden"] = "King Snake",
    ["Jellyfish"] = "Pure Jellyfish",
    ["King Kong"] = "Gorilla King",      -- King Kong egg asset -> Gorilla King pet display
    ["Godzilla"] = "Nightflame",         -- Godzilla egg asset on Titan Temple -> Nightflame (Divine)
    ["ScorchedDragon"] = "Scorched Dragon", -- no-space variant from game scan
    ["Cave Dragon"] = "Cosmic Dragon",   -- Cave Dragon egg asset -> Cosmic Dragon pet display
}

function X.getDisplayEggName(catOrRec)
    local raw = (type(catOrRec) == "table" and (catOrRec.AssetCategory or catOrRec.DisplayName or catOrRec.displayName or catOrRec.species or catOrRec.Name)) or tostring(catOrRec or "")
    if X.CATEGORY_TO_DISPLAY[raw] then
        return X.CATEGORY_TO_DISPLAY[raw]
    end
    local low = raw:lower():gsub("%s*egg%s*$", ""):gsub("^%s*", ""):gsub("%s*$", "")
    for cat, disp in pairs(X.CATEGORY_TO_DISPLAY) do
        if cat:lower() == low then return disp end
    end
    return raw
end

function X.normalizeEggSpecies(s)
    if not s or type(s) ~= "string" then return "" end
    local str = s:lower():gsub("^%b[]%s*", ""):gsub("%s*%b()%s*$", "")
    for _, mWord in ipairs({"rainbow", "golden", "silver", "gold"}) do
        str = str:gsub("^" .. mWord .. "%s+", "")
    end
    str = str:gsub("%s*egg%s*$", ""):gsub("^%s*", ""):gsub("%s*$", "")
    return str
end

function X.matchEggSpecies(nameA, nameB)
    local a = X.normalizeEggSpecies(nameA)
    local b = X.normalizeEggSpecies(nameB)
    if a == "" or b == "" then return false end
    if a == b then return true end
    -- NOTE: substring matching removed — it caused false positives between distinct gorilla species
    -- (e.g. "gorilla" matched "cosmic gorilla", "cyclops gorilla", "gorilla king").
    -- All legitimate cross-name pairs are covered by EGG_SPECIES_ALIASES with exact equality.
    -- We resolve aliases for BOTH sides and cross-compare all combinations, which handles
    -- 3-way chains like T-Rex <-> TRex <-> TyrannosaurusRex correctly.
    if X.EGG_SPECIES_ALIASES then
        local aliasA = X.EGG_SPECIES_ALIASES[a]   -- e.g. "t-rex" -> "trex"
        local aliasB = X.EGG_SPECIES_ALIASES[b]   -- e.g. "tyrannosaurusrex" -> "trex"
        if aliasA and aliasA == b then return true end   -- a's alias == b
        if aliasB and aliasB == a then return true end   -- b's alias == a
        if aliasA and aliasB and aliasA == aliasB then return true end  -- both alias to same name
    end
    return false
end


-- Dynamic Game Discovery for Egg Species (ReplicatedStorage.Assets.Models.Eggs)
-- Falls back to canonical PET_RARITY_PRESETS cleanly without duplicate aliases
local function loadEggSpeciesFromGame()
    local eggsFolder = nil
    pcall(function()
        eggsFolder = ReplicatedStorage:FindFirstChild("Assets")
            and ReplicatedStorage.Assets:FindFirstChild("Models")
            and ReplicatedStorage.Assets.Models:FindFirstChild("Eggs")
    end)
    if eggsFolder then
        local names = {}
        for _, child in ipairs(eggsFolder:GetChildren()) do
            local raw = child.Name
            local disp = (X.getDisplayEggName and X.getDisplayEggName(raw)) or raw
            if not speciesSeen[disp] then
                speciesSeen[disp] = true
                table.insert(names, disp)
            end
        end
        table.sort(names)
        for _, n in ipairs(names) do
            table.insert(speciesOrder, n)
        end
        return #names > 0
    end
    return false
end

-- Initialize species list: prefer dynamic game discovery, fallback to clean canonical presets
do
    local okGame = loadEggSpeciesFromGame()
    if not okGame then
        local names = {}
        for n in pairs(PET_RARITY_PRESETS) do
            local disp = (X.getDisplayEggName and X.getDisplayEggName(n)) or n
            if not speciesSeen[disp] then
                speciesSeen[disp] = true
                table.insert(names, disp)
            end
        end
        table.sort(names)
        for _, n in ipairs(names) do
            table.insert(speciesOrder, n)
        end
    end
end

-- Returns true if this egg matches any missing Scramble requirement species (when prioritizeScramble is enabled)
function X.isScrambleMissingEgg(rawCat)
    if not X.prioritizeScrambleInAutoFarm or not X.scrambleMissingSpecies then return false end
    if not rawCat or rawCat == "" then return false end

    -- Lazy initial inventory sync if never loaded
    if not X.scrambleInventoryLoaded and typeof(X.scanInventoryEggsForScramble) == "function" then
        X.scrambleInventoryLoaded = true
        task.defer(function()
            pcall(X.scanInventoryEggsForScramble)
        end)
    end

    local clean = X.normalizeEggSpecies(rawCat)
    if X.scrambleMissingSpecies[clean] then return true end
    if X.EGG_SPECIES_ALIASES then
        local alias = X.EGG_SPECIES_ALIASES[clean]
        if alias and X.scrambleMissingSpecies[alias] then return true end
    end
    for missing in pairs(X.scrambleMissingSpecies) do
        if X.matchEggSpecies(missing, rawCat) then return true end
    end
    return false
end

X.ROW_H = 28
X.ROW_GAP = 4
X.ROW3_Y = 8 + (28 + 4) * 2
X.MAX_FARM_DD_HEIGHT = 200

local upVelBtn, upRecBtn   -- farm order: Divine -> Eternal -> Secret -> selected (farthest)

function X.markTeleport() X.ignoreJumpUntil = os.clock() + 0.35; X.rbLastPos = nil; X.rbSamples = {} end

-- back to TRAVEL speed (called after every egg, new target, drop, or delivery)
function X.resetVelocity(forceTravel)
    if not forceTravel and weAreCarrying then
        targetVelocity = X.baseCarryVelocity
    else
        weAreCarrying = false
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

-- ==================================================
-- SHARED CORE UTILITIES & HELPERS
-- ==================================================

function X.distXZ(a, b)
    if not a or not b then return math.huge end
    local dx = a.X - b.X
    local dz = a.Z - b.Z
    return math.sqrt(dx * dx + dz * dz)
end

function X.getNetRemote(name)
    if not name then return nil end
    local cache = X._netRemoteCache
    if not cache then
        cache = {}
        X._netRemoteCache = cache
    end
    if cache[name] and cache[name].Parent then
        return cache[name]
    end
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
    local result = ok and rem or nil
    if result then cache[name] = result end
    return result
end

function X.formatCommas(num)
    local n = math.round(tonumber(num) or 0)
    local s = tostring(math.abs(n))
    local k
    while true do
        s, k = string.gsub(s, "^(-?%d+)(%d%d%d)", "%1,%2")
        if k == 0 then break end
    end
    return (n < 0 and "-" or "") .. s
end

function X.formatPetWeight(weightVal, scaleVal)
    if type(weightVal) == "string" then
        local kgStr = weightVal:match("([%d,]+)%s*[Kk][Gg]")
        if kgStr then
            local numOnly = kgStr:gsub(",", "")
            local n = tonumber(numOnly)
            if n and n > 0 then
                return X.formatCommas(n) .. "Kg", n
            end
        end
    end
    local rawW = tonumber(weightVal) or 0
    if rawW <= 0 then return "-- kg", 0 end
    local s = tonumber(scaleVal) or 1
    -- Authoritative game formula: DisplayWeight = math.round(Weight * Scale^2)
    local finalW = math.round(rawW * (s * s))
    return X.formatCommas(finalW) .. "Kg", finalW
end

function X.formatStatNumber(val)
    if typeof(val) == "string" then return val end
    if typeof(val) ~= "number" then return nil end
    local absVal = math.abs(val)
    if absVal >= 1e12 then
        return string.format("%.1fT", val / 1e12):gsub("%.0T", "T")
    elseif absVal >= 1e9 then
        return string.format("%.1fB", val / 1e9):gsub("%.0B", "B")
    elseif absVal >= 1e6 then
        return string.format("%.1fM", val / 1e6):gsub("%.0M", "M")
    elseif absVal >= 1e3 then
        return string.format("%.1fK", val / 1e3):gsub("%.0K", "K")
    elseif absVal >= 10 then
        return string.format("%.1f", val):gsub("%.0$", "")
    else
        return string.format("%.2f", val):gsub("%.00$", "")
    end
end

function X.formatEarnString(val)
    if typeof(val) == "number" then
        return "+$" .. (X.formatStatNumber(val) or tostring(val)) .. "/s"
    end
    local s = tostring(val or "")
    if s == "" or s == "--/s" or s == "--" then return "+$0/s" end
    if not s:find("/s") then s = s .. "/s" end
    if not s:find("%$") then
        if s:find("^%+") then
            s = "+$" .. s:sub(2)
        else
            s = "+$" .. s
        end
    elseif not s:find("^%+") then
        s = "+" .. s
    end
    return s
end

function X.copyToClipboard(text)
    local ok = false
    if typeof(setclipboard) == "function" then
        ok = pcall(setclipboard, text)
    elseif typeof(toclipboard) == "function" then
        ok = pcall(toclipboard, text)
    end
    return ok
end

function X.cleanSpeciesName(name)
    if not name or type(name) ~= "string" then return "" end
    local clean = name:gsub("^%b[]%s*", "")
    for _, mWord in ipairs({"Rainbow", "Golden", "Silver", "Gold", "rainbow", "golden", "silver", "gold"}) do
        clean = clean:gsub("^" .. mWord .. "%s+", "")
    end
    clean = clean:gsub("%s*[Ee]gg%s*$", ""):gsub("^%s*", ""):gsub("%s*$", "")
    return clean
end

function X.isGearTool(tool, attrs)
    attrs = attrs or (tool and tool:GetAttributes()) or {}
    return attrs.GearName ~= nil or attrs.ItemType == "Gear" or attrs.IsBat == true
end

function X.isEggTool(tool, attrs)
    if not tool or not tool:IsA("Tool") then return false end
    attrs = attrs or tool:GetAttributes() or {}
    if X.isGearTool(tool, attrs) then return false end
    local dName = tostring(attrs.DisplayName or tool.Name):lower()
    local cat = tostring(attrs.Category or ""):lower()
    local tName = tool.Name:lower()
    return dName:find("egg", 1, true) ~= nil
        or tName:find("egg", 1, true) ~= nil
        or cat == "egg"
        or attrs.ItemType == "Egg"
        or attrs.IsEgg == true
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
            local okA, cAttrs = pcall(function() return c:GetAttributes() end)
            if okA and typeof(cAttrs) == "table" then
                if cAttrs.IsEgg == true or cAttrs.ItemType == "Egg" or (cAttrs.CarrierUserId and tostring(cAttrs.CarrierUserId) == tostring(LocalPlayer.UserId)) then
                    return "char_attr:" .. c.Name
                end
            end
        end
    end
    local cra = Workspace:FindFirstChild("ClientRenderedAssets")
    if cra then
        local myUid = tostring(LocalPlayer.UserId)
        local cUidLower = carryUid and string.lower(tostring(carryUid))
        local expectedName = carryUid and (myUid .. "_" .. tostring(carryUid))
        if expectedName then
            local m = cra:FindFirstChild(expectedName)
            if m and (m:IsA("BasePart") or m:FindFirstChildWhichIsA("BasePart", true)) then
                return "cra:" .. m.Name
            end
        end
        -- Case-insensitive match in CRA
        if cUidLower then
            for _, m in ipairs(cra:GetChildren()) do
                local mLow = string.lower(m.Name)
                if string.find(mLow, myUid, 1, true) and string.find(mLow, cUidLower, 1, true) then
                    if m:IsA("BasePart") or m:FindFirstChildWhichIsA("BasePart", true) then
                        return "cra_match:" .. m.Name
                    end
                end
            end
        end
    end
    -- Authoritative server snapshot check
    if carryUid and eggCache and eggCache.byUid and eggCache.byUid[carryUid] then
        local rec = eggCache.byUid[carryUid]
        if typeof(rec) == "table" then
            local cId = rec.CarrierUserId
            if cId and tostring(cId) == tostring(LocalPlayer.UserId) then
                return "snapshot_carrier:" .. tostring(carryUid)
            end
            if rec.State == "Carried" and not X.isCarriedByOther(carryUid, rec) then
                return "snapshot_carried:" .. tostring(carryUid)
            end
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

local function neutraliseEggPhysics(char, force)
    if not char then return end
    local now = os.clock()
    if not force and now - (X.lastPhysicsNeutralizeAt or 0) < 2.0 then return end
    X.lastPhysicsNeutralizeAt = now

    for _, d in ipairs(char:GetDescendants()) do
        if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" and d.Parent ~= char then
            pcall(function() d.Massless = true; d.CanCollide = false end)
        end
    end
    local cra = Workspace:FindFirstChild("ClientRenderedAssets")
    if cra then
        local myUidPrefix = tostring(LocalPlayer.UserId)
        for _, m in ipairs(cra:GetChildren()) do
            if string.find(m.Name, myUidPrefix, 1, true) then
                for _, p in ipairs(m:GetDescendants()) do
                    if p:IsA("BasePart") then pcall(function() p.Massless = true; p.CanCollide = false end) end
                end
            end
        end
    end
end

-- ==================================================
-- RAGDOLL & ZERO-WAIT RECOVERY HELPERS
-- ==================================================
local checkcaller = checkcaller or function() return false end
local newcclosure = newcclosure or function(f) return f end

local cachedPlayerControls = nil
local function enablePlayerControls()
    pcall(function()
        if not cachedPlayerControls then
            local ps = LocalPlayer:FindFirstChildOfClass("PlayerScripts")
            local pm = ps and ps:FindFirstChild("PlayerModule")
            if pm then
                local mod = require(pm)
                if mod and mod.GetControls then
                    cachedPlayerControls = mod:GetControls()
                end
            end
        end
        if cachedPlayerControls and cachedPlayerControls.Enable then
            cachedPlayerControls:Enable()
        end
    end)
end

local function clearRagdollAttributes()
    pcall(function()
        LocalPlayer:SetAttribute("RagdollEndTime", 0)
        LocalPlayer:SetAttribute("RagdollTime", 0)
        LocalPlayer:SetAttribute("IsRagdoll", false)
        LocalPlayer:SetAttribute("Ragdolled", false)
    end)
    local char = LocalPlayer.Character
    if char then
        pcall(function()
            char:SetAttribute("RagdollEndTime", 0)
            char:SetAttribute("RagdollTime", 0)
            char:SetAttribute("IsRagdoll", false)
            char:SetAttribute("Ragdolled", false)
        end)
    end
end

local function getRagdollReason(hum)
    if not hum then return nil end
    local re = LocalPlayer:GetAttribute("RagdollEndTime")
    if typeof(re) == "number" and re > Workspace:GetServerTimeNow() then
        if recoveryEnabled then
            clearRagdollAttributes()
            enablePlayerControls()
        else
            return "RagdollEnd"
        end
    end
    local s = hum:GetState()
    if s == Enum.HumanoidStateType.Ragdoll then return "Ragdoll" end
    if s == Enum.HumanoidStateType.FallingDown then return "FallingDown" end
    if s == Enum.HumanoidStateType.Physics then return "Physics" end
    if hum.PlatformStand then return "PlatStand" end
    if s == Enum.HumanoidStateType.FallingDown or s == Enum.HumanoidStateType.Physics or recoveryActive then
        local ch = hum.Parent
        if ch then
            local dm, tm = 0, 0
            for _, o in ipairs(ch:GetDescendants()) do
                if o:IsA("Motor6D") then tm = tm + 1; if not o.Enabled then dm = dm + 1 end end
            end
            if tm > 0 and dm >= 2 then return "Motors" end
        end
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
        if os.clock() - ragdollSince > X.RAGDOLL_STALE_AFTER then ragdollStale = true end
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

    local rec = eggCache and eggCache.byUid and eggCache.byUid[uStr]
    if rec and typeof(rec) == "table" and rec.CarrierUserId then
        local cStr = tostring(rec.CarrierUserId)
        X.carrierPlayer[uStr] = cStr
        return cStr
    end

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

function X.isCarriedByOther(uid, r)
    local uStr = tostring(uid or "")
    if uStr == "" then return false end
    if uStr == carryUid or uStr == X.ownUid then return false end

    -- 1. Direct record check (authoritative server snapshot fields)
    local rec = r or (eggCache and eggCache.byUid and eggCache.byUid[uStr])
    if rec and typeof(rec) == "table" then
        if rec.State == "Carried" then
            local cId = rec.CarrierUserId or X.carrierPlayer[uStr]
            if not cId or tostring(cId) ~= tostring(LocalPlayer.UserId) then
                return true
            end
        end
        if rec.CarrierUserId and tostring(rec.CarrierUserId) ~= tostring(LocalPlayer.UserId) then
            return true
        end
    end

    -- 2. Cached carrier from FieldEggShifted / OwnerShifted / ClientRenderedAssets
    local c = X.carrierPlayer[uStr] or X.getCarrier(uStr)
    if not c then return false end
    return tostring(c) ~= tostring(LocalPlayer.UserId)
end

function X.recPos(r)
    if typeof(r) ~= "table" then return nil end
    if typeof(r.BoundsCFrame) == "CFrame" then return r.BoundsCFrame.Position end
    if typeof(r.BottomCFrame) == "CFrame" then return r.BottomCFrame.Position end
    return nil
end

-- Robust slot resolution in Workspace.AreaEggSlotsClient:
-- Matches direct 32-hex UID, recursive/attribute Uid, Forest/Area pattern ("FirstAreaEgg_..._Forest:Slot_00X"),
-- or 3D world position within 6 studs of the expected nest position.
function X.findEggSlot(area, uid, nestId, areaId, pos, cachedChildren)
    if not area or not uid or uid == "" then return nil end
    -- 1. Direct child match (standard 32-hex UID used in 95% of areas)
    local direct = area:FindFirstChild(uid)
    if direct then return direct end

    local children = cachedChildren or area:GetChildren()

    -- 2. Attribute match or name contains UID
    for _, ch in ipairs(children) do
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
        for _, ch in ipairs(children) do
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
        for _, ch in ipairs(children) do
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

-- Cached base plot renders check (Workspace.PlacedEggRenders.<UserId>_<EggUid>)
-- Cached for 0.8s to avoid looping hundreds of instances on every frame/egg check
local baseRendersCache = nil
local lastBaseRendersTime = 0
function X.isEggInBaseRenders(uid)
    if not uid or uid == "" then return false end
    local now = os.clock()
    if not baseRendersCache or (now - lastBaseRendersTime) > 0.8 then
        lastBaseRendersTime = now
        baseRendersCache = {}
        local per = Workspace:FindFirstChild("PlacedEggRenders")
        if per then
            for _, ch in ipairs(per:GetChildren()) do
                local nm = ch.Name
                baseRendersCache[nm] = true
                local eggUidPart = string.match(nm, "_(.+)$")
                if eggUidPart then baseRendersCache[eggUidPart] = true end
            end
        end
    end
    return baseRendersCache[uid] == true
end

-- Per-area cross-check of the snapshot against the client slots (called from every successful scan).
function X.updateSlotGhosts(by, recs)
    local area = Workspace:FindFirstChild("AreaEggSlotsClient")
    if not X.USE_SLOT_CHECK or not area or typeof(recs) ~= "table" then X.missCount = {}; return end
    -- Issue #7 fix: Startup grace period gives streaming/slots 5s to load before ghost filtering
    if os.clock() < (X.startupGraceUntil or 0) then return end
    local areaChildren = area:GetChildren()
    local perArea = {}
    for _, r in ipairs(recs) do
        local u = typeof(r) == "table" and tostring(r.Uid or "") or ""
        if u ~= "" then
            local a = tostring(r.AreaId or "?")
            local pa = perArea[a]
            if not pa then pa = { n = 0, has = 0, missing = {} }; perArea[a] = pa end
            pa.n = pa.n + 1
            local p = X.recPos(r)
            local slotObj = X.findEggSlot(area, u, r.NestId, r.AreaId, p, areaChildren)
            local hasSlot = slotObj ~= nil
            local mine = (X.weDropped[u] and os.clock() - X.weDropped[u] < 60) or (dropRetry and dropRetry.uid == u) or X.looseUids[u]

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
                    local sz = X.distXZ(p, SAFE_ZONE)
                    if sz <= 30 and not mine and not hasSlot then
                        if not X.deliveredUids[u] then print("[EggGoToUI] egg rests at the delivery zone (delivered by someone):", u) end
                        X.deliveredUids[u] = true; X.listDirty = true
                    elseif X.isEggInBaseRenders(u) then
                        -- Egg was delivered into a player's base plot
                        X.deliveredUids[u] = true
                        X.blacklistStolen(u)
                        X.looseUids[u] = nil
                        X.listDirty = true
                    elseif not X.isCarriedByOther(u) and not (X.badUids[u] and os.clock() < X.badUids[u]) and (mine or not hasSlot) then
                        -- Egg was bumped or dropped loose: it is on the field, farmable!
                        X.looseUids[u] = true
                        X.clearMarks(u)
                        X.listDirty = true
                    end
                end
                -- stale entry that sits at the delivery zone from the start (delivered before we ever saw it move)
                if not hasSlot and not mine and not X.deliveredUids[u] then
                    if X.distXZ(p, SAFE_ZONE) <= 15 then
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
                local mine = (X.weDropped[u] and os.clock() - X.weDropped[u] < 60) or (dropRetry and dropRetry.uid == u) or X.looseUids[u]
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
X.GONE_TTL   = 15
X.movingAt   = {}    -- v9.8: uid -> last time its position changed >6 studs between scans (someone is carrying it)
X.restN      = {}    -- v9.8: uid -> consecutive scans it did not move
X.deliveredUids = {} -- v9.8: uid -> true: it rests at the delivery zone (another player delivered it)
X.slotLostSince = {} -- v9.8: uid -> time its slot was first seen missing (after having existed)
X.weDropped  = {}    -- v9.8: uid -> time WE dropped it

local walkToken = 0
local lastFailReason = nil
X.currentWalkingEggUid = nil

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
        X.badUids[uid] = os.clock() + (secs or 30)
        if not X.gonePos[uid] then X.gonePos[uid] = X.lastPos[uid] or X.nestPos[uid] end
    end
end

-- "taken by someone else": short progressive timeout, never permanent 1e9
function X.blacklistStolen(uid)
    local n = (X.stolenN[uid] or 0) + 1
    X.stolenN[uid] = n
    X.blacklist(uid, n == 1 and 20 or (n == 2 and 40 or 60))
end

function X.slotLost(uid)
    if not X.USE_SLOT_CHECK or (X.weDropped[uid] and os.clock() - X.weDropped[uid] < 60) or (dropRetry and dropRetry.uid == uid) or X.looseUids[uid] then return false end
    local a = Workspace:FindFirstChild("AreaEggSlotsClient")
    if not a or #a:GetChildren() == 0 then return false end
    return X.findEggSlot(a, uid) == nil
end

-- v9.8: strong evidence that another player has / had the egg (returns the reason text)
function X.takenSignal(uid)
    local now = os.clock()
    -- Issue #1 fix: Opponent carrier and base plot checks MUST take priority over weDropped and dropRetry!
    if X.isCarriedByOther(uid) then
        if dropRetry and dropRetry.uid == uid then
            dropRetry = nil; X.weDropped[uid] = nil; X.looseUids[uid] = nil
        end
        return "carried by another player"
    end
    if X.isEggInBaseRenders(uid) then
        if dropRetry and dropRetry.uid == uid then
            dropRetry = nil; X.weDropped[uid] = nil; X.looseUids[uid] = nil
        end
        return "placed in player base plot"
    end
    if X.deliveredUids[uid] then
        if dropRetry and dropRetry.uid == uid then
            dropRetry = nil; X.weDropped[uid] = nil; X.looseUids[uid] = nil
        end
        return "rests at the delivery zone (delivered)"
    end

    local wd = X.weDropped[uid]
    if wd and now - wd < 60 then return nil end                       -- we dropped it ourselves: it is on the ground
    if dropRetry and dropRetry.uid == uid then return nil end         -- currently retrying pickup after bump/drop
    if now - X.lastRagdollAt < 15 and uid == carryUid then return nil end -- recently bumped with this egg
    if X.looseUids[uid] then return nil end                           -- loose on ground is NOT taken!

    local sl = X.slotLostSince[uid]
    if sl and now - sl >= 3.0 and not X.looseUids[uid] and not (eggCache.byUid and eggCache.byUid[uid]) then
        return "nest slot vanished (taken)"
    end
    return nil
end

function X.isGhost(r)
    if not r or typeof(r) ~= "table" then return false end
    local uid = tostring(r.Uid or "")
    if uid == "" or uid == X.ownUid then return false end

    -- Authoritative server states:
    local st = tostring(r.State or "")
    if st == "Claimed" then return true, "claimed in base plot" end
    if st == "Carried" then
        local cId = r.CarrierUserId or X.carrierPlayer[uid]
        if cId and tostring(cId) ~= tostring(LocalPlayer.UserId) then
            return true, "carried by another player (server State=Carried)"
        end
        if uid ~= carryUid then
            return true, "carried by another player"
        end
    end
    if r.CarrierUserId and tostring(r.CarrierUserId) ~= tostring(LocalPlayer.UserId) then
        return true, "carried by another player"
    end

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
    if X.isCarriedByOther(uid, r) then return true, "carried by another player" end
    -- 5. FieldEggGone / FieldEggShifted network events
    if X.goneActive(uid) then return true, "Gone/Shifted event" end
    -- 6. Taken signals (stolen, moving between scans, etc.)
    local ts = X.takenSignal(uid)
    if ts then return true, ts end

    -- If the egg is loose on the ground (bumped / dropped), it is NOT a ghost!
    -- NOTE: checked AFTER carrier and base plot checks so picked-up loose eggs are not faked
    if X.looseUids[uid] then return false end

    -- 7. Eggs WE dropped or are retrying pickup for are exempt from missing slot ghosting
    local mine = (dropRetry and dropRetry.uid == uid) or (X.weDropped[uid] and os.clock() - X.weDropped[uid] < 60)
    if mine then return false end
    -- 8. Client slot cross-check: if AreaEggSlotsClient is active and has no slot for this egg,
    -- only treat as ghost if ALSO absent from the authoritative server snapshot
    if (X.missCount[uid] or 0) >= 3 and not (eggCache.byUid and eggCache.byUid[uid]) then
        return true, "nest slot missing (empty nest)"
    end
    if X.slotLostSince[uid] and (os.clock() - X.slotLostSince[uid]) >= 3.0 and not (eggCache.byUid and eggCache.byUid[uid]) then
        return true, "nest slot vanished (taken)"
    end
    return false
end

-- v9.7: weak evidence only (1 scan with no slot, waiting for 2nd scan to confirm): farm it last
function X.isUnverified(r)
    if not r or typeof(r) ~= "table" then return false end
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
                local u = typeof(pl) == "table" and tostring(pl.Uid or pl.EggUid or pl.uid or "") or tostring(pl or "")
                local newOwner = typeof(pl) == "table" and (pl.UserId or pl.Owner or pl.NewOwner) or nil
                if u ~= "" and newOwner then
                    if tostring(newOwner) ~= tostring(LocalPlayer.UserId) then
                        X.carrierPlayer[u] = tostring(newOwner)
                        X.looseUids[u] = nil
                        X.listDirty = true
                        if X.currentWalkingEggUid == u then
                            walkToken = walkToken + 1
                            local chTmp = LocalPlayer.Character
                            local hTmp = chTmp and chTmp:FindFirstChildOfClass("Humanoid")
                            local rTmp = chTmp and chTmp:FindFirstChild("HumanoidRootPart")
                            if hTmp and rTmp then
                                pcall(function()
                                    hTmp:Move(Vector3.zero)
                                    hTmp.WalkToPoint = rTmp.Position
                                    rTmp.AssemblyLinearVelocity = Vector3.new(0, rTmp.AssemblyLinearVelocity.Y, 0)
                                end)
                            end
                            lastFailReason = "[AutoFarm] Egg taken by another player — next..."
                            X.currentWalkingEggUid = nil
                            X.blacklistStolen(u)
                            if eggCache and eggCache.byUid and eggCache.byUid[u] then
                                eggCache.byUid[u] = nil
                            end
                            if dropRetry and dropRetry.uid == u then
                                dropRetry = nil
                                X.weDropped[u] = nil
                            end
                        end
                    else
                        X.carrierPlayer[u] = nil
                        X.listDirty = true
                    end
                end
            end))
        end
    end)
    -- Explicitly hook OwnerDropped so loose eggs dropped by ANY player are immediately recoverable
    pcall(function()
        local odEv = ReplicatedStorage.Packages.Networking:FindFirstChild("RE/EggWorld/OwnerDropped")
        if odEv and odEv:IsA("RemoteEvent") then
            addConnection(odEv.OnClientEvent:Connect(function(pl)
                local u = typeof(pl) == "table" and tostring(pl.Uid or pl.EggUid or pl.uid or "") or tostring(pl or "")
                if u ~= "" then
                    X.carrierPlayer[u] = nil
                    X.looseUids[u] = true
                    X.clearMarks(u)
                    local isOurs = (typeof(pl) == "table" and pl.UserId and tostring(pl.UserId) == tostring(LocalPlayer.UserId)) or (u == carryUid)
                    if isOurs then
                        X.weDropped[u] = os.clock()
                        dropRetry = { uid = u, t = os.clock(), n = ((dropRetry and dropRetry.uid == u) and dropRetry.n or 0) + 1 }
                    end
                    X.listDirty = true
                    print("[EggGoToUI] egg dropped via OwnerDropped:", u)
                end
            end))
        end
    end)
end
X.startReappearMonitor()

-- Real-time push monitor for RE/EggWorld/FieldEggShifted and FieldEggBatchShifted:
-- Captures state changes (Carried, Claimed, Dropped, Slot) and CarrierUserId as they happen
function X.startShiftedMonitor()
    local net = ReplicatedStorage:FindFirstChild("Packages")
        and ReplicatedStorage.Packages:FindFirstChild("Networking")
    if not net then return end

    local function onEggShifted(pl)
        if typeof(pl) ~= "table" then return end
        local u = tostring(pl.Uid or pl.EggUid or "")
        if u == "" then return end

        local st = tostring(pl.State or "")
        local carrier = pl.CarrierUserId

        if st == "Claimed" then
            -- Egg claimed / redeemed into a player's base plot: stolen/gone
            X.deliveredUids[u] = true
            X.badUids[u] = os.clock() + 300
            X.carrierPlayer[u] = nil
            X.looseUids[u] = nil
            X.listDirty = true
            if eggCache and eggCache.byUid and eggCache.byUid[u] then
                eggCache.byUid[u].State = "Claimed"
            end
            if X.currentWalkingEggUid == u then
                walkToken = walkToken + 1
                local chTmp = LocalPlayer.Character
                local hTmp = chTmp and chTmp:FindFirstChildOfClass("Humanoid")
                local rTmp = chTmp and chTmp:FindFirstChild("HumanoidRootPart")
                if hTmp and rTmp then
                    pcall(function()
                        hTmp:Move(Vector3.zero)
                        hTmp.WalkToPoint = rTmp.Position
                        rTmp.AssemblyLinearVelocity = Vector3.new(0, rTmp.AssemblyLinearVelocity.Y, 0)
                    end)
                end
                lastFailReason = "[AutoFarm] Egg claimed in base plot — next..."
                X.currentWalkingEggUid = nil
                X.blacklistStolen(u)
                X.looseUids[u] = nil
                if eggCache and eggCache.byUid and eggCache.byUid[u] then
                    eggCache.byUid[u] = nil
                end
                if dropRetry and dropRetry.uid == u then
                    dropRetry = nil
                    X.weDropped[u] = nil
                end
                X.listDirty = true
            end
        elseif st == "Carried" then
            local isMe = (carrier and tostring(carrier) == tostring(LocalPlayer.UserId)) or (u == carryUid) or (u == X.ownUid)
            if isMe then
                X.carrierPlayer[u] = nil
            else
                -- Another player picked it up!
                local cStr = tostring(carrier or "other")
                X.carrierPlayer[u] = cStr
                X.looseUids[u] = nil
                X.goneUids[u] = os.clock()
                X.gonePos[u] = X.recPos(pl) or X.lastPos[u] or X.nestPos[u]
                
                -- Issue #1 fix: Dropped egg stolen -> cancel retry immediately to prevent lag!
                if dropRetry and dropRetry.uid == u then
                    dropRetry = nil
                    X.weDropped[u] = nil
                    X.looseUids[u] = nil
                    print("[AutoFarm] Dropped egg stolen by player " .. cStr .. " — cancelled drop retry:", u)
                end
                
                if eggCache and eggCache.byUid and eggCache.byUid[u] then
                    eggCache.byUid[u].State = "Carried"
                    eggCache.byUid[u].CarrierUserId = carrier
                end
                if X.currentWalkingEggUid == u then
                    walkToken = walkToken + 1
                    local chTmp = LocalPlayer.Character
                    local hTmp = chTmp and chTmp:FindFirstChildOfClass("Humanoid")
                    local rTmp = chTmp and chTmp:FindFirstChild("HumanoidRootPart")
                    if hTmp and rTmp then
                        pcall(function()
                            hTmp:Move(Vector3.zero)
                            hTmp.WalkToPoint = rTmp.Position
                            rTmp.AssemblyLinearVelocity = Vector3.new(0, rTmp.AssemblyLinearVelocity.Y, 0)
                        end)
                    end
                    lastFailReason = "[AutoFarm] Egg carried by another player — next..."
                    X.currentWalkingEggUid = nil
                    X.blacklistStolen(u)
                    X.looseUids[u] = nil
                    if eggCache and eggCache.byUid and eggCache.byUid[u] then
                        eggCache.byUid[u] = nil
                    end
                    if dropRetry and dropRetry.uid == u then
                        dropRetry = nil
                        X.weDropped[u] = nil
                    end
                    X.listDirty = true
                end
                if passesFilters(pl) or X.currentWalkingEggUid == u then
                    X.listDirty = true
                end
            end
        elseif st == "Dropped" then
            -- Egg dropped on the ground (loose / pickable again!)
            X.carrierPlayer[u] = nil
            X.looseUids[u] = true
            X.clearMarks(u)
            local isMe = (pl.UserId and tostring(pl.UserId) == tostring(LocalPlayer.UserId)) or (u == carryUid)
            if isMe then
                X.weDropped[u] = os.clock()
                dropRetry = { uid = u, t = os.clock(), n = ((dropRetry and dropRetry.uid == u) and dropRetry.n or 0) + 1 }
            end
            X.listDirty = true
            if eggCache and eggCache.byUid and eggCache.byUid[u] then
                eggCache.byUid[u].State = "Dropped"
                if pl.BoundsCFrame then eggCache.byUid[u].BoundsCFrame = pl.BoundsCFrame end
                if pl.BottomCFrame then eggCache.byUid[u].BottomCFrame = pl.BottomCFrame end
            end
        elseif st == "Slot" then
            -- Egg is sitting in its nest slot
            X.carrierPlayer[u] = nil
            X.deliveredUids[u] = nil
            X.badUids[u] = nil
            X.goneUids[u] = nil
            X.listDirty = true
            if eggCache and eggCache.byUid and eggCache.byUid[u] then
                eggCache.byUid[u].State = "Slot"
            end
        end
    end

    local evShift = net:FindFirstChild("RE/EggWorld/FieldEggShifted")
    if evShift and evShift:IsA("RemoteEvent") then
        addConnection(evShift.OnClientEvent:Connect(onEggShifted))
    end

    local evBatch = net:FindFirstChild("RE/EggWorld/FieldEggBatchShifted")
    if evBatch and evBatch:IsA("RemoteEvent") then
        addConnection(evBatch.OnClientEvent:Connect(function(batch)
            if typeof(batch) == "table" then
                local recs = batch.Records or batch
                if typeof(recs) == "table" then
                    for _, pl in pairs(recs) do
                        onEggShifted(pl)
                    end
                end
            end
        end))
    end
end
X.startShiftedMonitor()

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
                if X.currentWalkingEggUid == eggId then
                    walkToken = walkToken + 1
                    local chTmp = LocalPlayer.Character
                    local hTmp = chTmp and chTmp:FindFirstChildOfClass("Humanoid")
                    local rTmp = chTmp and chTmp:FindFirstChild("HumanoidRootPart")
                    if hTmp and rTmp then
                        pcall(function()
                            hTmp:Move(Vector3.zero)
                            hTmp.WalkToPoint = rTmp.Position
                            rTmp.AssemblyLinearVelocity = Vector3.new(0, rTmp.AssemblyLinearVelocity.Y, 0)
                        end)
                    end
                    lastFailReason = "[AutoFarm] Egg carried by another player — next..."
                    X.currentWalkingEggUid = nil
                    X.blacklistStolen(eggId)
                    X.looseUids[eggId] = nil
                    if eggCache and eggCache.byUid and eggCache.byUid[eggId] then
                        eggCache.byUid[eggId] = nil
                    end
                    if dropRetry and dropRetry.uid == eggId then
                        dropRetry = nil
                        X.weDropped[eggId] = nil
                    end
                end
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
            -- When an opponent stops carrying an egg, it may have been dropped on the ground or bumped!
            -- Check if it actually went into a base plot or incubator before marking delivered:
            task.delay(0.2, function()
                if X.isEggInBaseRenders(eggId) then
                    X.deliveredUids[eggId] = true
                    X.blacklistStolen(eggId)
                    X.looseUids[eggId] = nil
                    if eggCache.byUid and eggCache.byUid[eggId] then
                        eggCache.byUid[eggId] = nil
                    end
                else
                    -- Opponent dropped it on the ground or got bumped/died!
                    -- Keep it alive and mark as loose egg so we can farm it!
                    X.looseUids[eggId] = true
                    X.clearMarks(eggId)
                    X.deliveredUids[eggId] = nil
                end
                X.listDirty = true
            end)
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

local presetRarityCache = {}
local function getPresetRarity(sp)
    if not sp or sp == "" then return nil end
    local cached = presetRarityCache[sp]
    if cached ~= nil then
        if cached == false then return nil end
        return cached.rarity, cached.pet
    end
    local n = normName(sp)
    if n == "" then
        presetRarityCache[sp] = false
        return nil
    end
    for _, e in ipairs(presetMatches) do
        if n == e.key then
            presetRarityCache[sp] = { rarity = e.rarity, pet = e.pet }
            return e.rarity, e.pet
        end
    end
    local pad = " " .. n .. " "
    for _, e in ipairs(presetMatches) do
        if pad:find(" " .. e.key .. " ", 1, true) then
            presetRarityCache[sp] = { rarity = e.rarity, pet = e.pet }
            return e.rarity, e.pet
        end
    end
    presetRarityCache[sp] = false
    return nil
end

local function resolveRaw(r)
    if typeof(r) ~= "table" then return nil end
    local sp = tostring(r.AssetCategory or "")
    local disp = (typeof(X) == "table" and typeof(X.getDisplayEggName) == "function" and X.getDisplayEggName(sp)) or sp
    local pr = getPresetRarity(disp) or getPresetRarity(sp)
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
-- ==================================================
-- ==================================================
-- ==================================================
-- SETTINGS APPLIER
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
        if typeof(installWalkSpeedHook) == "function" then installWalkSpeedHook() end
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
    if t.MaxBumpRetries ~= nil and t.MaxBumpRetries > 0 then
        X.maxBumpRetries = t.MaxBumpRetries
    end
    currentSettings.MaxBumpRetries = X.maxBumpRetries

    if t.PickupEnabled ~= nil then X.PICKUP_CONFIG.Enabled = t.PickupEnabled end
    if t.PickupReachAssist ~= nil then X.PICKUP_CONFIG.ReachAssist = t.PickupReachAssist end
    if t.PickupMaxDistance ~= nil and t.PickupMaxDistance > 0 then X.PICKUP_CONFIG.MaxReachDistance = t.PickupMaxDistance end
    if t.PickupBurstCount ~= nil and t.PickupBurstCount > 0 then X.PICKUP_CONFIG.SpamBurstCount = t.PickupBurstCount end
    if t.PickupShowMiniHud ~= nil then X.PICKUP_CONFIG.ShowMiniHud = t.PickupShowMiniHud end

    currentSettings.PickupEnabled = X.PICKUP_CONFIG.Enabled
    currentSettings.PickupReachAssist = X.PICKUP_CONFIG.ReachAssist
    currentSettings.PickupMaxDistance = X.PICKUP_CONFIG.MaxReachDistance
    currentSettings.PickupBurstCount = X.PICKUP_CONFIG.SpamBurstCount
    currentSettings.PickupShowMiniHud = X.PICKUP_CONFIG.ShowMiniHud
    if typeof(X.syncPickupUI) == "function" then pcall(X.syncPickupUI) end

    if t.TrapEvade ~= nil then X.TRAP_CONFIG.Enabled = t.TrapEvade end
    currentSettings.TrapEvade = X.TRAP_CONFIG.Enabled
    if typeof(X.syncTrapEvadeUI) == "function" then pcall(X.syncTrapEvadeUI) end
    if X.TRAP_CONFIG.Enabled then
        if typeof(X.applyAllTrapNeutralization) == "function" then pcall(X.applyAllTrapNeutralization) end
        if typeof(X.applyCanTouchProtection) == "function" then pcall(X.applyCanTouchProtection) end
        if typeof(X.updateAllTrapVisuals) == "function" then pcall(X.updateAllTrapVisuals) end
    else
        if typeof(X.restoreAllTraps) == "function" then pcall(X.restoreAllTraps) end
        if typeof(X.removeAllTrapVisuals) == "function" then pcall(X.removeAllTrapVisuals) end
    end

    if t.AutoTreadmill ~= nil then X.autoTreadmillEnabled = t.AutoTreadmill end
    currentSettings.AutoTreadmill = X.autoTreadmillEnabled == true
    if typeof(X.syncAutoTreadmillUI) == "function" then pcall(X.syncAutoTreadmillUI) end

    if t.AutoDismount ~= nil then X.autoDismountEnabled = t.AutoDismount end
    currentSettings.AutoDismount = X.autoDismountEnabled == true
    if typeof(X.syncAutoDismountUI) == "function" then pcall(X.syncAutoDismountUI) end

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

local function carryEgg(uid, sl, burstCount)
    if not uid or uid == "" then return false end
    burstCount = burstCount or 1
    if sl then
        sl.Text = "Sending carry..."
        sl.TextColor3 = Color3.fromRGB(255, 220, 100)
    end
    local rf = getCarryRemote()
    if not rf then
        if sl then sl.Text = "Carry RF not found"; sl.TextColor3 = Color3.fromRGB(255, 120, 120) end
        return false
    end
    local payload = { Uid = uid }
    local anyOk = false
    for i = 1, burstCount do
        task.spawn(function()
            local ok, e = pcall(function() return rf:InvokeServer(payload) end)
            if ok then anyOk = true end
        end)
    end
    if sl then
        sl.Text = "Carry sent!"
        sl.TextColor3 = Color3.fromRGB(120, 255, 150)
    end
    return true
end
X.carryEgg = carryEgg

-- ==================================================
-- MOVEMENT
-- ==================================================
walkToken = walkToken or 0

local function getBesideOffset(targetPos, currentPos, dist)
    dist = dist or 2.8
    local diff = Vector3.new(currentPos.X - targetPos.X, 0, currentPos.Z - targetPos.Z)
    local dir = diff.Magnitude > 0.1 and diff.Unit or Vector3.new(0, 0, 1)
    if typeof(X) == "table" and X.TRAP_CONFIG and X.TRAP_CONFIG.Enabled and typeof(X.getNearestTrapDist) == "function" then
        local trapDist, trapPos = X.getNearestTrapDist(targetPos)
        if trapDist <= 8.0 and trapPos then
            local awayFromTrap = Vector3.new(targetPos.X - trapPos.X, 0, targetPos.Z - trapPos.Z)
            if awayFromTrap.Magnitude > 0.1 then
                dir = awayFromTrap.Unit
            end
        end
    end
    local groundY = currentPos.Y
    if math.abs(groundY - targetPos.Y) > 6 then groundY = targetPos.Y end
    local besidePos = Vector3.new(targetPos.X + dir.X * dist, groundY, targetPos.Z + dir.Z * dist)
    local lookTarget = Vector3.new(targetPos.X, groundY, targetPos.Z)
    return besidePos, lookTarget
end

local function applyReachAssist(targetPos)
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root or typeof(targetPos) ~= "Vector3" then return end
    local dist = X.distXZ(targetPos, root.Position)
    local maxReach = (X.PICKUP_CONFIG and X.PICKUP_CONFIG.MaxReachDistance) or 35
    if dist > 3 and dist <= maxReach then
        local bPos, lookTarget = getBesideOffset(targetPos, root.Position, 2.8)
        if typeof(X) == "table" and typeof(X.markTeleport) == "function" then
            X.markTeleport()
        end
        pcall(function()
            root.AssemblyLinearVelocity = Vector3.zero
            root.CFrame = CFrame.lookAt(bPos, lookTarget)
        end)
    end
end

local function triggerProximityPrompt(prompt)
    if not prompt or not prompt.Parent then return end
    if typeof(fireproximityprompt) == "function" then
        pcall(fireproximityprompt, prompt, 0)
        pcall(fireproximityprompt, prompt)
    end
    pcall(function()
        if typeof(prompt.InputHoldBegin) == "function" then
            prompt:InputHoldBegin()
            task.delay(0.01, function() pcall(function() prompt:InputHoldEnd() end) end)
        end
    end)
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

-- ==================================================
-- TRAP EVASION & HITBOX NEUTRALIZATION ENGINE
-- ==================================================
function X.getNearestTrapDist(pos)
    if not pos or not X.activeTraps then return math.huge, nil end
    local minDist, nearest = math.huge, nil
    for inst, data in pairs(X.activeTraps) do
        if inst.Parent then
            local tPos = data.Position
            if not tPos then
                if inst:IsA("BasePart") then
                    tPos = inst.Position
                elseif inst:IsA("Model") then
                    local okP, p = pcall(function() return inst:GetPivot().Position end)
                    tPos = okP and p or nil
                end
                data.Position = tPos
            end
            if tPos then
                local dx = math.abs(tPos.X - pos.X)
                local dz = math.abs(tPos.Z - pos.Z)
                if dx < minDist and dz < minDist then
                    local dist = math.sqrt(dx * dx + dz * dz)
                    if dist < minDist then
                        minDist = dist
                        nearest = tPos
                    end
                end
            end
        else
            if typeof(X.removeTrapVisual) == "function" then X.removeTrapVisual(data) end
            X.activeTraps[inst] = nil
        end
    end
    return minDist, nearest
end

function X.attachTrapVisual(child, record)
    if not child or not record then return end
    if not (X.TRAP_CONFIG and X.TRAP_CONFIG.ShowVisuals and X.TRAP_CONFIG.Enabled) then return end
    if typeof(X.removeTrapVisual) == "function" then X.removeTrapVisual(record) end

    local targetPart = nil
    if child:IsA("BasePart") and child.Name ~= "Hitbox" and child.Position.Y > -100 then
        targetPart = child
    elseif child:IsA("Model") then
        for _, desc in ipairs(child:GetDescendants()) do
            if desc:IsA("BasePart") and desc.Name ~= "Hitbox" and desc.Position.Y > -100 then
                targetPart = desc
                break
            end
        end
        if not targetPart then
            local bp = child.PrimaryPart or child:FindFirstChildWhichIsA("BasePart")
            if bp and bp.Position.Y > -100 then
                targetPart = bp
            end
        end
    end
    if not targetPart then
        targetPart = Workspace.Terrain
    end
    if not targetPart then return end

    local tPos = record.Position
    if not tPos then
        local okP, p = pcall(function() return child:GetPivot().Position end)
        tPos = okP and p or (targetPart ~= Workspace.Terrain and targetPart.Position or nil)
        record.Position = tPos
    end
    if not tPos then return end

    local cfg = X.TRAP_CONFIG
    local radius = (cfg and cfg.DangerRadius) or 7.0

    pcall(function()
        local worldCF = CFrame.new(tPos.X, tPos.Y + 0.12, tPos.Z) * CFrame.Angles(math.rad(90), 0, 0)
        local localCF = (targetPart ~= Workspace.Terrain) and targetPart.CFrame:ToObjectSpace(worldCF) or worldCF

        -- Outer danger radius indicator: translucent red warning circle
        local outer = Instance.new("CylinderHandleAdornment")
        outer.Name = "TrapDangerRange"
        outer.Adornee = targetPart
        outer.Radius = radius
        outer.Height = 0.12
        outer.Color3 = Color3.fromRGB(255, 35, 35)
        outer.Transparency = 0.65
        outer.ZIndex = 1
        outer.AlwaysOnTop = true
        outer.CFrame = localCF
        outer.Parent = targetPart

        -- Inner core marker: bright red center pinpoint
        local inner = Instance.new("CylinderHandleAdornment")
        inner.Name = "TrapDangerCore"
        inner.Adornee = targetPart
        inner.Radius = 1.8
        inner.Height = 0.18
        inner.Color3 = Color3.fromRGB(255, 10, 10)
        inner.Transparency = 0.35
        inner.ZIndex = 2
        inner.AlwaysOnTop = true
        inner.CFrame = localCF
        inner.Parent = targetPart

        record.Visuals = { outer, inner }
    end)
end

function X.removeTrapVisual(record)
    if not record then return end
    if record.Visuals then
        for _, v in ipairs(record.Visuals) do
            pcall(function() v:Destroy() end)
        end
        record.Visuals = nil
    end
    if record.Connections then
        for _, conn in ipairs(record.Connections) do
            pcall(function() conn:Disconnect() end)
        end
        record.Connections = nil
    end
end

function X.updateAllTrapVisuals()
    if not X.activeTraps then return end
    local shouldShow = X.TRAP_CONFIG and X.TRAP_CONFIG.Enabled and X.TRAP_CONFIG.ShowVisuals
    for inst, record in pairs(X.activeTraps) do
        if inst.Parent then
            if shouldShow then
                if not record.Visuals then
                    X.attachTrapVisual(inst, record)
                end
            else
                X.removeTrapVisual(record)
            end
        else
            X.removeTrapVisual(record)
            X.activeTraps[inst] = nil
        end
    end
end

function X.removeAllTrapVisuals()
    if not X.activeTraps then return end
    for _, record in pairs(X.activeTraps) do
        X.removeTrapVisual(record)
    end
end

function X.getTrapDetourPoint(rp, dest)
    if not rp or not dest or not X.activeTraps then return nil end
    local cfg = X.TRAP_CONFIG
    if not (cfg and cfg.Enabled) then return nil end

    local dangerRadius  = cfg.DangerRadius or 7.0
    local clearanceDist = cfg.ClearanceDist or 4.8
    local lookaheadDist = cfg.LookaheadDist or 16.0

    local toDest = Vector3.new(dest.X - rp.X, 0, dest.Z - rp.Z)
    local distDest = toDest.Magnitude
    if distDest < 1.5 then return nil end

    local forwardDir = toDest.Unit
    local leftDir  = Vector3.new(-forwardDir.Z, 0, forwardDir.X)
    local rightDir = Vector3.new(forwardDir.Z, 0, -forwardDir.X)

    local threatPos = nil
    local threatDist, threatFwdProj, threatSideDot = 0, 0, 0
    local minThreatScore = math.huge
    local nearestDist = math.huge

    local candTraps = X._candTrapsBuffer
    if not candTraps then
        candTraps = {}
        X._candTrapsBuffer = candTraps
    else
        table.clear(candTraps)
    end
    local candCount = 0

    for inst, data in pairs(X.activeTraps) do
        if inst.Parent then
            local tPos = data.Position
            if not tPos then
                if inst:IsA("BasePart") then
                    tPos = inst.Position
                elseif inst:IsA("Model") then
                    local okP, p = pcall(function() return inst:GetPivot().Position end)
                    tPos = okP and p or nil
                end
                data.Position = tPos
            end
            if tPos then
                local distToTrap = X.distXZ(tPos, rp)
                if distToTrap < nearestDist then
                    nearestDist = distToTrap
                end

                if distToTrap <= (lookaheadDist + 4.0) then
                    candCount = candCount + 1
                    candTraps[candCount] = tPos
                    if distToTrap <= lookaheadDist then
                        local toTrap = Vector3.new(tPos.X - rp.X, 0, tPos.Z - rp.Z)
                        local forwardProj = toTrap:Dot(forwardDir)
                        local lateralDist = math.abs(toTrap:Dot(leftDir))

                        -- Trap threatens path corridor or we are inside hazard radius
                        if (forwardProj >= -2.0 and forwardProj <= math.min(distDest, lookaheadDist) and lateralDist < dangerRadius)
                           or (distToTrap <= dangerRadius) then
                            local threatScore = distToTrap + lateralDist * 0.5
                            if threatScore < minThreatScore then
                                minThreatScore = threatScore
                                threatPos = tPos
                                threatDist = distToTrap
                                threatFwdProj = forwardProj
                                threatSideDot = toTrap:Dot(leftDir)
                            end
                        end
                    end
                end
            end
        else
            if typeof(X.removeTrapVisual) == "function" then X.removeTrapVisual(data) end
            X.activeTraps[inst] = nil
        end
    end

    if not threatPos then return nil, nearestDist end

    -- Micro Left/Right Evasion:
    -- Forward lead prioritizes strong forward momentum (no wide sweeping arcs)
    local forwardLead = math.clamp(threatFwdProj * 0.5, 3.0, 6.5)
    if threatFwdProj < 1.0 then
        forwardLead = 3.5
    end

    -- Construct candidate micro-waypoints for Left and Right sidestep
    local groundY = rp.Y
    local candLeft = Vector3.new(
        rp.X + forwardDir.X * forwardLead + leftDir.X * clearanceDist,
        groundY,
        rp.Z + forwardDir.Z * forwardLead + leftDir.Z * clearanceDist
    )
    local candRight = Vector3.new(
        rp.X + forwardDir.X * forwardLead + rightDir.X * clearanceDist,
        groundY,
        rp.Z + forwardDir.Z * forwardLead + rightDir.Z * clearanceDist
    )

    -- Multi-trap intelligence: evaluate clearance of both candidates against all nearby traps
    local clearanceLeft = math.huge
    local clearanceRight = math.huge
    for i = 1, candCount do
        local tPos = candTraps[i]
        local dL = X.distXZ(candLeft, tPos)
        if dL < clearanceLeft then clearanceLeft = dL end
        local dR = X.distXZ(candRight, tPos)
        if dR < clearanceRight then clearanceRight = dR end
    end

    -- Select candidate with superior clearance; if comparable, steer away from primary threat
    local chosenPoint = nil
    if clearanceRight > (clearanceLeft + 0.6) then
        chosenPoint = candRight
    elseif clearanceLeft > (clearanceRight + 0.6) then
        chosenPoint = candLeft
    else
        chosenPoint = (threatSideDot >= 0) and candRight or candLeft
    end

    -- Close proximity safeguard: retain strong forward diagonal momentum rather than turning sideways
    if threatDist <= 4.0 then
        local steerDir = (chosenPoint == candRight) and rightDir or leftDir
        local blend = (forwardDir * 0.6 + steerDir * 0.8).Unit
        chosenPoint = Vector3.new(
            rp.X + blend.X * clearanceDist,
            groundY,
            rp.Z + blend.Z * clearanceDist
        )
    end

    return chosenPoint, nearestDist
end

function X.neutralizeTrap(inst)
    if not inst or not inst.Parent then return end
    local record = X.activeTraps and X.activeTraps[inst]
    if record and record.Neutralized then return end
    pcall(function()
        if inst:IsA("BasePart") then
            inst.CanTouch = false
            inst.CanCollide = false
            inst.CanQuery = false
        end
        local hb = inst:FindFirstChild("Hitbox")
        if hb and hb:IsA("BasePart") then
            hb.CanTouch = false
            hb.CanCollide = false
            hb.CanQuery = false
            local curCF = hb.CFrame
            if curCF.Y > -100 then
                if record and not record.OrigHitboxCF then
                    record.OrigHitboxCF = curCF
                end
                hb.CFrame = CFrame.new(curCF.X, -500, curCF.Z)
            end
        end
        if record then record.Neutralized = true end
    end)
end

function X.restoreTrap(inst)
    if not inst or not inst.Parent then return end
    local record = X.activeTraps and X.activeTraps[inst]
    pcall(function()
        if inst:IsA("BasePart") then
            inst.CanTouch = true
            inst.CanCollide = true
            inst.CanQuery = true
        end
        local hb = inst:FindFirstChild("Hitbox")
        if hb and hb:IsA("BasePart") then
            hb.CanTouch = true
            hb.CanCollide = false
            hb.CanQuery = true
            if record and record.OrigHitboxCF then
                hb.CFrame = record.OrigHitboxCF
            end
        end
        if record then record.Neutralized = false end
    end)
end

function X.applyAllTrapNeutralization()
    if not X.activeTraps then return end
    for inst, data in pairs(X.activeTraps) do
        if inst.Parent then
            X.neutralizeTrap(inst)
        else
            if typeof(X.removeTrapVisual) == "function" then X.removeTrapVisual(data) end
            X.activeTraps[inst] = nil
        end
    end
end

function X.restoreAllTraps()
    if not X.activeTraps then return end
    for inst, data in pairs(X.activeTraps) do
        if inst.Parent then
            X.restoreTrap(inst)
        end
    end
end

function X.applyCanTouchProtection()
    local char = LocalPlayer.Character
    if not char then return end
    local protect = X.TRAP_CONFIG and X.TRAP_CONFIG.Enabled
    local targetCanTouch = not protect

    local cached = X._cachedLimbs
    if not cached or cached.Char ~= char then
        cached = { Char = char, Parts = {} }
        for _, part in ipairs(char:GetDescendants()) do
            if part:IsA("BasePart") then
                local nm = part.Name:lower()
                if nm:find("foot", 1, true) or nm:find("leg", 1, true) or nm:find("root", 1, true) or nm:find("torso", 1, true) then
                    table.insert(cached.Parts, part)
                end
            end
        end
        X._cachedLimbs = cached
    end

    local parts = cached.Parts
    for i = 1, #parts do
        local part = parts[i]
        if part and part.Parent and part.CanTouch ~= targetCanTouch then
            pcall(function() part.CanTouch = targetCanTouch end)
        end
    end
end

function X.registerFieldTrap(child)
    if not child or not child.Parent then return end
    local name = child.Name:lower()
    if not (name:find("trap", 1, true) or child.Name == "PlayerTrap") then return end
    if X.activeTraps[child] then return end

    local pos = nil
    if child:IsA("BasePart") then
        pos = child.Position
    elseif child:IsA("Model") then
        local okP, p = pcall(function() return child:GetPivot().Position end)
        pos = okP and p or nil
    end

    local hb = child:FindFirstChild("Hitbox")
    local origCF = (hb and hb:IsA("BasePart")) and hb.CFrame or nil

    local record = {
        Instance = child,
        Hitbox = hb,
        OrigHitboxCF = origCF,
        Position = pos,
    }
    X.activeTraps[child] = record

    if X.TRAP_CONFIG and X.TRAP_CONFIG.Enabled then
        X.neutralizeTrap(child)
        if X.TRAP_CONFIG.ShowVisuals and typeof(X.attachTrapVisual) == "function" then
            task.defer(function()
                if child.Parent and X.activeTraps[child] then
                    X.attachTrapVisual(child, record)
                end
            end)
        end
    end

    local cAdd = child.ChildAdded:Connect(function(sub)
        if sub.Name == "Hitbox" and sub:IsA("BasePart") then
            record.Hitbox = sub
            if not record.OrigHitboxCF then record.OrigHitboxCF = sub.CFrame end
            if X.TRAP_CONFIG and X.TRAP_CONFIG.Enabled then
                X.neutralizeTrap(child)
            end
        end
        if X.TRAP_CONFIG and X.TRAP_CONFIG.Enabled and X.TRAP_CONFIG.ShowVisuals and not record.Visuals then
            task.defer(function()
                if child.Parent and X.activeTraps[child] then
                    X.attachTrapVisual(child, record)
                end
            end)
        end
    end)

    local cAnc = child.AncestryChanged:Connect(function(_, parent)
        if not parent or not child:IsDescendantOf(Workspace) then
            if typeof(X.removeTrapVisual) == "function" then
                X.removeTrapVisual(record)
            end
            X.activeTraps[child] = nil
        end
    end)

    record.Connections = { cAdd, cAnc }
end

function X.initTrapEvade()
    local transient = Workspace:FindFirstChild("Transient")
    if transient then
        for _, c in ipairs(transient:GetChildren()) do
            X.registerFieldTrap(c)
        end
        addConnection(transient.ChildAdded:Connect(function(c)
            X.registerFieldTrap(c)
        end))
        addConnection(transient.ChildRemoved:Connect(function(c)
            local rec = X.activeTraps[c]
            if rec and typeof(X.removeTrapVisual) == "function" then
                X.removeTrapVisual(rec)
            end
            X.activeTraps[c] = nil
        end))
    end

    addConnection(Workspace.ChildAdded:Connect(function(c)
        if c.Name == "Transient" then
            for _, sub in ipairs(c:GetChildren()) do
                X.registerFieldTrap(sub)
            end
            addConnection(c.ChildAdded:Connect(function(sub)
                X.registerFieldTrap(sub)
            end))
            addConnection(c.ChildRemoved:Connect(function(sub)
                local rec = X.activeTraps[sub]
                if rec and typeof(X.removeTrapVisual) == "function" then
                    X.removeTrapVisual(rec)
                end
                X.activeTraps[sub] = nil
            end))
        end
    end))

    -- Initial sweep
    if X.TRAP_CONFIG and X.TRAP_CONFIG.Enabled then
        X.applyCanTouchProtection()
        X.applyAllTrapNeutralization()
        if X.TRAP_CONFIG.ShowVisuals and typeof(X.updateAllTrapVisuals) == "function" then
            pcall(X.updateAllTrapVisuals)
        end
    end

    -- Background supervisor: maintains CanTouch protection & sweeps for newly armed traps
    task.spawn(function()
        while screenGui and screenGui.Parent do
            task.wait(1.0)
            if X.TRAP_CONFIG and X.TRAP_CONFIG.Enabled then
                X.applyCanTouchProtection()
                X.applyAllTrapNeutralization()
                if X.TRAP_CONFIG.ShowVisuals and typeof(X.updateAllTrapVisuals) == "function" then
                    pcall(X.updateAllTrapVisuals)
                end
            end
        end
    end)

    -- Manual walk auto-jump radar: if walking manually within 4.5 studs of a trap, jump over it
    task.spawn(function()
        while screenGui and screenGui.Parent do
            task.wait(0.12)
            if X.TRAP_CONFIG and X.TRAP_CONFIG.Enabled and not autoFarmEnabled then
                local ch = LocalPlayer.Character
                local r = ch and ch:FindFirstChild("HumanoidRootPart")
                local h = ch and ch:FindFirstChildOfClass("Humanoid")
                if r and h and h.MoveDirection.Magnitude > 0.05 then
                    local trapDist, _ = X.getNearestTrapDist(r.Position)
                    if trapDist <= 4.5 and not h.Jump then
                        h.Jump = true
                    end
                end
            end
        end
    end)
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
                local xz0 = X.distXZ(dest, rp0)
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
                local xz = X.distXZ(dest, rp)
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
                -- Trap Evade: Check if an armed trap obstructs our path
                local detourPoint, nearestTrapDist = nil, math.huge
                if X.TRAP_CONFIG and X.TRAP_CONFIG.Enabled and typeof(X.getTrapDetourPoint) == "function" then
                    detourPoint, nearestTrapDist = X.getTrapDetourPoint(rp, dest)
                    -- Emergency safety: if within 4.5 studs of a trap, jump to guarantee clearance
                    if nearestTrapDist and nearestTrapDist <= 4.5 and h and not h.Jump then
                        h.Jump = true
                    end
                end
                if snapRadius and xz <= snapRadius and not detourPoint then
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
                elseif detourPoint then
                    -- Micro left/right evasion: steer toward agile detour waypoint (left/right)
                    local steerVec = Vector3.new(detourPoint.X - rp.X, 0, detourPoint.Z - rp.Z)
                    if steerVec.Magnitude > 0.3 then
                        h:Move(steerVec.Unit, false)
                    end
                    task.wait(0.08)
                elseif xz <= X.TELEPORT_ZONE then
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
                elseif xz > X.SLOW_ZONE then
                    h:MoveTo(dest); task.wait(0.3)
                else
                    local d = Vector3.new(dest.X - rp.X, 0, dest.Z - rp.Z).Unit
                    h:Move(d, false); task.wait(0.08)
                end
            end
        end
        -- Halt Humanoid immediately on cancellation / token increment
        pcall(function()
            local ch = LocalPlayer.Character
            local h = ch and ch:FindFirstChildOfClass("Humanoid")
            local r = ch and ch:FindFirstChild("HumanoidRootPart")
            if h and r then
                h:Move(Vector3.zero)
                h.WalkToPoint = r.Position
                r.AssemblyLinearVelocity = Vector3.new(0, r.AssemblyLinearVelocity.Y, 0)
            end
        end)
    end)
end

-- Note: Manual get is a single-step execution of autoGetEgg (defined below with auto farm).

-- ==================================================
-- HELPERS
-- ==================================================
local function extPos(r)
    if typeof(r) ~= "table" then return nil end
    if typeof(r.BoundsCFrame) == "CFrame" then return r.BoundsCFrame.Position end
    if typeof(r.BottomCFrame) == "CFrame" then return r.BottomCFrame.Position end
    return nil
end

local function mutLabel(r)
    if typeof(r) ~= "table" or typeof(r.Mutations) ~= "table" then return nil end
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

-- lower = picked first: Divine 1, Eternal 2, Secret 3, Scramble Requirements (missing in storage only) 4, New/Unknown 4.5, everything else selected 5.xx (rarer first)
function X.eggTier(r)
    if not r or typeof(r) ~= "table" then return 5 end
    local rar = effectiveRarity(r)
    for i, n in ipairs(X.PRIORITY_CHAIN) do if n == rar then return i end end
    local catStr = tostring(r.AssetCategory or "")
    if X.isScrambleMissingEgg and X.isScrambleMissingEgg(catStr) then
        return 4
    end
    if X.isNewOrUnknownEgg and X.isNewOrUnknownEgg(r) then
        return 99 -- Unknown eggs are not auto-farmed (manual get only)
    end
    return 5 + (10 - (X.RARITY_RANK[rar] or 0)) / 100
end

local function isNewOrUnknownEgg(r)
    if not r or typeof(r) ~= "table" then return false end
    local catStr = tostring(r.AssetCategory or "")
    -- 1. Blank or explicitly unknown AssetCategory
    if catStr == "" or catStr == "Unknown" or catStr:lower() == "unknown" then
        return true
    end
    -- 2. Unresolvable rarity
    local rar = resolveRaw(r)
    if not rar or rar == "Unknown" then
        return true
    end
    -- 3. Explicit new/unknown metadata flags
    if r.IsNew == true or r.New == true or r.Unknown == true or r.isUnknown == true then
        return true
    end
    return false
end
X.isNewOrUnknownEgg = isNewOrUnknownEgg

local function matchSpeciesFilter(rawCat)
    if X.isScrambleMissingEgg and X.isScrambleMissingEgg(rawCat) then return true end
    if selectedSpecies["All"] then return true end
    if selectedSpecies[rawCat] == true then return true end
    local disp = X.getDisplayEggName and X.getDisplayEggName(rawCat)
    if disp and selectedSpecies[disp] == true then return true end
    for sel in pairs(selectedSpecies) do
        if X.matchEggSpecies(sel, rawCat) then return true end
    end
    return false
end

local function passesFilters(r)
    if not r or typeof(r) ~= "table" then return false end
    local u = tostring(r.Uid or "")
    if u == "" then return false end

    -- Authoritative server state checks (from AskFieldEggSnapshot / FieldEggShifted)
    local st = tostring(r.State or "")
    if st == "Claimed" then return false end
    if st == "Carried" then
        local cId = r.CarrierUserId or X.carrierPlayer[u]
        if cId and tostring(cId) ~= tostring(LocalPlayer.UserId) then
            return false
        end
        if u ~= carryUid and u ~= X.ownUid then
            return false
        end
    end
    if r.CarrierUserId and tostring(r.CarrierUserId) ~= tostring(LocalPlayer.UserId) then
        return false
    end

    if X.isGhost(r) then return false end      -- v9.1: taken / empty nest / base plot / delivered

    -- Mutation filter
    if next(activeMutationFilter) then
        local mOk = false
        if typeof(r.Mutations) == "table" then
            for _, n in pairs(r.Mutations) do
                if activeMutationFilter[tostring(n)] then mOk = true; break end
            end
        end
        if not mOk then return false end
    end

    local catStr = tostring(r.AssetCategory or "")
    local rar = effectiveRarity(r)

    -- UNIVERSAL OVERRIDE (Requirement #2):
    -- All new / unknown eggs automatically show even when none on farm dropdown selected!
    if isNewOrUnknownEgg(r) then
        return true
    end

    local isSpeciesSelected = false
    if X.isScrambleMissingEgg and X.isScrambleMissingEgg(catStr) then
        isSpeciesSelected = true
    elseif selectedSpecies["All"] then
        isSpeciesSelected = true
    else
        isSpeciesSelected = matchSpeciesFilter(catStr)
    end

    -- Option 2: Rarity Filter
    local isRarityMatch = false
    if X.hasRarity() then
        isRarityMatch = (X.selectedRarities[rar] == true or X.autoHigher(rar))
    end

    return isSpeciesSelected or isRarityMatch
end

-- ==================================================
-- AUTO FARM
-- ==================================================
-- FIX: forward-declare UI refs so autoFarmLoop/toggleAutoFarm capture them as upvalues
local autoFarmBtn, statusLabel
local autoFarmEnabled = false
local autoFarmToken   = 0       -- incremented to stop an in-flight run

-- Our OWN carry state (never trust a heuristic to say we carry something we never picked up)
weAreCarrying        = false
carryUid             = nil
carryMarkers         = nil    -- objects that appeared when WE picked the egg up (or nil if none seen)
lastFailReason = nil    -- shown by the loop instead of the generic "failed/skipped" text
dropRetry            = nil    -- { uid, t, n }: an egg we dropped -> fetch THIS one again first

-- ---------- LIVE EGG CACHE: one scanner, constant 1s cadence ----------
local eggCache = { records = nil, byUid = {}, t = 0, tIssue = 0, seq = 0, err = nil }
local onEggCacheUpdate = nil   -- set later by the UI: redraws the egg list on every new scan

-- v8: the snapshot call is a server round trip that can hang (e.g. right when an egg is carried/delivered/bumped).
-- Every fetch now runs in its own thread with a timeout, so one hung call can never freeze the scanner again.
function X.fetchTimed(timeout)
    local done, recs, err = false, nil, nil
    local t0 = os.clock()
    task.spawn(function()
        local r, e = fetchSnapshotRecords()
        recs, err, done = r, e, true
        if r then
            X.lastRtt = math.max(1, math.floor((os.clock() - t0) * 1000))
        end
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
            if typeof(r) == "table" then
                local u = tostring(r.Uid or "")
                if u ~= "" then
                    by[u] = r
                    local st = tostring(r.State or "")
                    local carrier = r.CarrierUserId
                    if st == "Claimed" then
                        X.deliveredUids[u] = true
                        X.looseUids[u] = nil
                        X.carrierPlayer[u] = nil
                    elseif st == "Carried" then
                        if carrier and tostring(carrier) ~= tostring(LocalPlayer.UserId) then
                            X.carrierPlayer[u] = tostring(carrier)
                            X.looseUids[u] = nil
                        elseif not carrier and u ~= carryUid and u ~= X.ownUid then
                            X.carrierPlayer[u] = "other"
                            X.looseUids[u] = nil
                        end
                    elseif st == "Dropped" then
                        X.carrierPlayer[u] = nil
                        X.looseUids[u] = true
                    elseif st == "Slot" then
                        X.carrierPlayer[u] = nil
                    end
                end
            end
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
            nextT = nextT + X.EGG_SCAN_INTERVAL            -- fixed schedule, not "wait after"
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
    while t < X.HOLD_RELEASE_TIMEOUT and (autoFarmToken == myTok or walkToken == myTok) do
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
    if carryUid and X.isCarriedByOther(carryUid) then return false end
    if carryUid and eggCache and eggCache.byUid and eggCache.byUid[carryUid] then
        local rec = eggCache.byUid[carryUid]
        if rec.State == "Dropped" or (rec.CarrierUserId and tostring(rec.CarrierUserId) ~= tostring(LocalPlayer.UserId)) then
            return false
        end
    end
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
    weAreCarrying = false
    carryUid = nil
    carryMarkers = nil
    X.resetVelocity(true)         -- v10: every new target egg starts cleanly at the default travel velocity
    X.ownUid = nil                -- v9.1: not ours until we actually start the pickup
    X.currentWalkingEggUid = uid  -- Track targeted egg for instant network push cancellation
    local completed, result = false, false
    local phase   = "walking"     -- walking -> carrying -> done
    local livePos = startPos
    local tag     = isManual and "[ManualGet] " or "[AutoFarm] "

    local function finish(ok)
        if completed then return end
        completed = true; phase = "done"; result = ok
        if X.currentWalkingEggUid == uid then
            X.currentWalkingEggUid = nil
        end
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
            if os.clock() - t0 > X.WALK_TIMEOUT then
                walkToken = walkToken + 1; finish(false); break
            end

            -- Fast check every 0.15s: if egg was stolen, claimed, carried by another player, or marked ghost, abort!
            local curRec = eggCache.byUid and eggCache.byUid[uid]
            local st = curRec and tostring(curRec.State or "") or ""
            local carrier = curRec and (curRec.CarrierUserId or X.carrierPlayer[uid]) or X.carrierPlayer[uid]
            local isCarriedByOther = (st == "Carried" and carrier and tostring(carrier) ~= tostring(LocalPlayer.UserId))
                or (carrier and tostring(carrier) ~= tostring(LocalPlayer.UserId))
                or X.isCarriedByOther(uid, curRec)
            local isClaimed = (st == "Claimed") or X.deliveredUids[uid] or X.isEggInBaseRenders(uid)
            local isGhostEgg = curRec and X.isGhost(curRec)

            if isCarriedByOther or isClaimed or isGhostEgg or X.goneActive(uid) or X.takenSignal(uid) then
                walkToken = walkToken + 1
                local chTmp = LocalPlayer.Character
                local hTmp = chTmp and chTmp:FindFirstChildOfClass("Humanoid")
                local rTmp = chTmp and chTmp:FindFirstChild("HumanoidRootPart")
                if hTmp and rTmp then
                    pcall(function()
                        hTmp:Move(Vector3.zero)
                        hTmp.WalkToPoint = rTmp.Position
                        rTmp.AssemblyLinearVelocity = Vector3.new(0, rTmp.AssemblyLinearVelocity.Y, 0)
                    end)
                end
                lastFailReason = tag .. (isCarriedByOther and "Egg carried by someone else — next..." or (isClaimed and "Egg claimed into base plot — next..." or "Egg taken by someone else — next..."))
                if not isManual then
                    X.blacklistStolen(uid)
                    X.looseUids[uid] = nil
                    if eggCache.byUid and eggCache.byUid[uid] then
                        eggCache.byUid[uid] = nil
                    end
                    if dropRetry and dropRetry.uid == uid then
                        dropRetry = nil
                        X.weDropped[uid] = nil
                    end
                end
                finish(false); break
            end

            if eggCache.seq ~= lastSeq then
                lastSeq = eggCache.seq
                local found = eggCache.byUid[uid]
                if found then
                    -- Verify found passes filters! If it doesn't pass filters (e.g. state changed to Carried/Claimed), abort!
                    if not isManual and not passesFilters(found) and not (dropRetry and dropRetry.uid == uid) then
                        walkToken = walkToken + 1
                        local chTmp = LocalPlayer.Character
                        local hTmp = chTmp and chTmp:FindFirstChildOfClass("Humanoid")
                        local rTmp = chTmp and chTmp:FindFirstChild("HumanoidRootPart")
                        if hTmp and rTmp then
                            pcall(function()
                                hTmp:Move(Vector3.zero)
                                hTmp.WalkToPoint = rTmp.Position
                                rTmp.AssemblyLinearVelocity = Vector3.new(0, rTmp.AssemblyLinearVelocity.Y, 0)
                            end)
                        end
                        lastFailReason = tag .. "Egg no longer valid (stolen/filtered) — next..."
                        X.blacklistStolen(uid)
                        X.looseUids[uid] = nil
                        if eggCache and eggCache.byUid and eggCache.byUid[uid] then
                            eggCache.byUid[uid] = nil
                        end
                        finish(false); break
                    end
                    missing = 0
                    local np = extPos(found)
                    if np then livePos = np end
                    -- v9: a higher-priority rarity (Divine > Eternal > Secret > Mythic) spawned before we picked
                    -- this egg up: switch to it (a dropped egg we are re-fetching is never abandoned; manual get stays on chosen egg)
                    if not isManual and X.hasRarity() and not (dropRetry and dropRetry.uid == uid) then
                        local okp, best, bTier = pcall(X.pickNearest, eggCache.records or {})
                        if okp and typeof(best) == "table" and bTier and bTier < 5 and tostring(best.Uid or "") ~= uid
                           and bTier < X.eggTier(found) then
                            walkToken = walkToken + 1
                            lastFailReason = "[AutoFarm] Higher rarity spawned (" .. tostring(best.AssetCategory) .. ") — switching..."
                            finish(false); break
                        end
                    end
                else
                    missing = missing + 1
                    local lim = (X.looseUids[uid] or (dropRetry and dropRetry.uid == uid)) and 5 or 2   -- v10: dropped eggs re-list tolerance
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

    local isEggNearTrap = (X.TRAP_CONFIG and X.TRAP_CONFIG.Enabled and X.getNearestTrapDist(livePos) <= 8.0)
    walkTo(function() return livePos end, 6, walkTok, function()
        phase = "carrying"                          -- stops the tracker (set before any yield)
        if cancelled() then finish(false); return end

        -- v10: Authoritative check right at the nest before pickup attempt
        do
            X.forceScan(1.5)
            if cancelled() then finish(false); return end
            local recCur = eggCache.byUid[uid]
            local inSnapshot = eggCache.byUid and eggCache.byUid[uid] ~= nil
            local isBeingCarriedByOther = X.isCarriedByOther(uid, recCur)
            local isInBase = X.isEggInBaseRenders(uid)
            local isClaimed = recCur and tostring(recCur.State or "") == "Claimed"
            local mine = (X.weDropped[uid] and os.clock() - X.weDropped[uid] < 60) or (dropRetry and dropRetry.uid == uid) or X.looseUids[uid]

            -- Issue #7 fix: Only abort if actually in base, carried by other, claimed, or truly absent from snapshot (and not dropped by us)
            if isInBase or isBeingCarriedByOther or isClaimed or (not inSnapshot and not mine) then
                lastFailReason = tag .. (isInBase and "Placed in base plot — next..." or (isBeingCarriedByOther and "Carried by someone else — next..." or "Egg no longer valid — next..."))
                if isInBase or isClaimed then
                    X.blacklistStolen(uid)
                    X.deliveredUids[uid] = true
                else
                    X.blacklist(uid, 30)
                end
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

        -- Listen BEFORE invoking so an early FieldEggShifted / Gone event can't be missed
        local gotGone, conns = false, {}
        for _, pth in ipairs({"RE/EggWorld/FieldEggShifted", "RE/EggWorld/FieldEggGone", "RE/EggWorld/FieldEggCarry"}) do
            local eok, ev = pcall(function() return ReplicatedStorage.Packages.Networking[pth] end)
            if eok and ev and ev:IsA("RemoteEvent") then
                table.insert(conns, ev.OnClientEvent:Connect(function(pl)
                    if typeof(pl) == "table" and tostring(pl.Uid or pl.EggUid or "") == uid then
                        if pl.State == "Carried" or pl.State == "Claimed" or not pl.State then
                            gotGone = true
                        end
                    end
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
            local dist = X.distXZ(livePos, r2.Position)
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
        local mine = (X.weDropped[uid] and os.clock() - X.weDropped[uid] < 60) or (dropRetry and dropRetry.uid == uid) or X.looseUids[uid]
        local maxTry = X.AUTO_RETRY
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
                local dCur = X.distXZ(livePos, rTmp.Position)
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
                    print(("[AutoFarm] carry RF -> %s %s"):format(tostring(ok2), describeVal(res2)))
                end)
            else
                lastRfInfo = "carry remote missing"; rfDone = true
            end

            -- Brief confirmation window after spam (was pure fire-and-dash).
            -- Client hold visuals / CRA model can lag 0.5–1.5s behind a successful RF, so we must NOT
            -- treat "no isHoldingEgg yet" as failure when the server already accepted the carry.
            local confDeadline = os.clock() + 1.6
            local confHow = nil
            local function rfAccepted()
                if not rfDone or not rfOk then return false end
                if rfRes == false or rfRes == nil then return false end
                if X.rfSaysGone(rfOk, rfRes) then return false end
                return true
            end
            local function rfHardRefuse()
                if not rfDone then return false end
                if not rfOk then return true end
                if X.rfSaysGone(rfOk, rfRes) then return true end
                return false
            end
            while os.clock() < confDeadline and not cancelled() do
                if rfAccepted() then
                    confHow = "rf"
                    break
                elseif rfHardRefuse() then
                    lastRfInfo = (rfOk and "reply " or "error ") .. describeVal(rfRes)
                    print(("[AutoFarm] carry RF refused on attempt %d: %s"):format(attemptNo, lastRfInfo))
                    confHow = "refused"
                    break
                end
                if gotGone then confHow = "event"; break end
                local lateMarkers = scanHoldMarkers(before)
                if lateMarkers or isHoldingEgg() then
                    confHow = lateMarkers and "marker" or "hold"
                    if lateMarkers then markers = lateMarkers end
                    break
                end
                task.wait(0.05)
            end

            if confHow == "refused" then
                if X.rfSaysGone(rfOk, rfRes) or rfRes == false then
                    lastFailReason = tag .. "Nest empty / taken (" .. lastRfInfo .. ") — next..."
                    X.blacklistStolen(uid)
                    X.deliveredUids[uid] = true
                    X.looseUids[uid] = nil
                    if eggCache.byUid[uid] then eggCache.byUid[uid] = nil end
                    X.listDirty = true
                    X.requestEggRefresh()
                    stolen = true
                    break
                end
                -- soft RF error: fall through to next attemptNo
            elseif confHow then
                carried, how = true, confHow
                print(("[AutoFarm] pickup confirmed via %s on attempt %d"):format(tostring(confHow), attemptNo))
                break
            else
                -- Attempt did not confirm pickup; do NOT start return trip empty-handed!
                warn(("[AutoFarm] pickup attempt %d unconfirmed (RF done=%s ok=%s res=%s) — retrying at egg"):format(
                    attemptNo, tostring(rfDone), tostring(rfOk), describeVal(rfRes)))
                task.wait(0.15)
            end
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
                -- Issue #6 fix: Do NOT blacklist if this is an egg we dropped and are retrying!
                if not (dropRetry and dropRetry.uid == uid) then
                    local n = (X.failCount[uid] or 0) + 1
                    X.failCount[uid] = n
                    X.blacklist(uid, n == 1 and 45 or (n == 2 and 180 or 1e9))
                    if n >= 2 then
                        X.deliveredUids[uid] = true
                        X.looseUids[uid] = nil
                    end
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
        walkTo(SAFE_ZONE, X.SAFE_ARRIVE_RADIUS, rtok, function() arrived = true; done = true end,
               { stuckHop = true, snapRadius = X.SAFE_SNAP_RADIUS })
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

            -- FAST-FAIL only for tentative (rf_no_wait) pickups where the client never showed a hold.
            -- When how is "rf" / "event" / "marker" / "hold" the server or client already confirmed
            -- the carry — do NOT turn around just because isHoldingEgg() lagged a bit.
            -- Grace is 1.8s (was 0.8s): CRA / tool visuals often appear after the RF reply.
            if how == "rf_no_wait" and not isHoldingEgg() and not carryMarkers
               and now - tStart >= 1.8 and not isRagdolled then
                carryMarkers = scanHoldMarkers(before)
                if carryMarkers or isHoldingEgg() then
                    if carryMarkers then markerSince = now end
                else
                    warn(tag .. "tentative pickup: no egg detected after 1.8s — re-queuing pickup")
                    statusLabel.Text = tag .. "Pickup missed — returning to egg..."
                    statusLabel.TextColor3 = Color3.fromRGB(255, 160, 60)
                    dropped = true
                    dropWhy = "rf_no_wait: no hold detected"
                    break
                end
            end

            -- (A) BOSS BUMP: every ragdoll/stun START since pickup
            if X.ragdollEpoch ~= seenEpoch or isRagdolled then
                if X.ragdollEpoch ~= seenEpoch then
                    seenEpoch = X.ragdollEpoch
                    bumped = true
                    fastUntil = now + 6
                    bumpScanAt = now + 0.35           -- give the server a moment to re-list a dropped egg
                    if not isHoldingEgg() then X.resetVelocity() end
                end

                -- CRITICAL FIX (Issue #5):
                -- Cancel walk to safezone, halt horizontal movement, and ground fast on bump:
                local chTmp = LocalPlayer.Character
                local hTmp = chTmp and chTmp:FindFirstChildOfClass("Humanoid")
                local rTmp = chTmp and chTmp:FindFirstChild("HumanoidRootPart")
                if hTmp and rTmp then
                    pcall(function()
                        hTmp:Move(Vector3.zero)
                        hTmp.WalkToPoint = rTmp.Position
                        -- Zero horizontal fling immediately so we stay right at the bump location:
                        local curY = rTmp.AssemblyLinearVelocity.Y
                        rTmp.AssemblyLinearVelocity = Vector3.new(0, curY > 0 and -45 or (curY > -30 and -45 or curY), 0)
                        rTmp.AssemblyAngularVelocity = Vector3.zero
                    end)
                end

                -- If not holding egg, mark dropped immediately (do NOT walk towards safezone!)
                if not isHoldingEgg() then
                    dropped = true
                    dropWhy = "bumped / dropped on hit"
                    break
                end
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
                dSafe = X.distXZ(SAFE_ZONE, rrW.Position)
            end
            if dSafe <= X.SAFE_DETECT_RADIUS then
                arrived = true; done = true; break
            end
            if dSafe <= X.SAFE_SNAP_RADIUS and not isRagdolled and now - lastSnapT >= 0.25 then
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
                        local carriedByUs = (rec.CarrierUserId and tostring(rec.CarrierUserId) == tostring(LocalPlayer.UserId))
                            or (rec.State == "Carried" and not X.isCarriedByOther(uid, rec))
                        if carriedByUs then
                            -- Server snapshot confirms WE are the carrier! Never treat as dropped!
                            seenBack = 0
                            why = nil
                            lostSince = nil
                        elseif everGone or X.snapHidesCarried then
                            -- listed again without being carried by us = it is lying on the ground (1 scan is enough right after a bump)
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
                elseif bumped or isRagdolled or now < fastUntil or dropEvt then
                    lostSince = lostSince or now
                    if now - lostSince >= (now < fastUntil and 0.3 or X.DROP_CONFIRM) then
                        why = "object gone after bump: " .. tostring(carryMarkers.label)
                    end
                else
                    -- Smooth unbumped walk: transient VFX marker despawn is never a drop!
                    lostSince = nil
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
            if not bumped then return nil end    -- Never bumped = delivery guaranteed upon arrival
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
                        if ep and X.distXZ(ep, SAFE_ZONE) > 30 then
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
            X.looseUids[uid] = true                       -- lying on the ground now
            X.ignoreGone[uid] = os.clock() + 10           -- late events are not a theft
            X.weDropped[uid] = os.clock(); X.movingAt[uid] = nil; X.deliveredUids[uid] = nil; X.slotLostSince[uid] = nil
            X.gonePos[uid] = nil; X.vanished[uid] = nil
            X.clearMarks(uid); X.stolenN[uid] = nil

            -- Increment bump count (Issue #6 fix: configurable retry persistence)
            local bumpN = ((dropRetry and dropRetry.uid == uid) and dropRetry.n or 0) + 1
            local maxRetries = currentSettings.MaxBumpRetries or 8
            dropRetry = { uid = uid, t = os.clock(), n = bumpN }
            lastFailReason = (tag .. "Egg dropped (#%d/%d) — picking it up again..."):format(bumpN, maxRetries)
            warn(tag .. "drop detected:", dropWhy, "bump count:", bumpN)
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
            -- Immediately refresh inventory & scramble requirements so delivered egg is recognized as owned:
            task.spawn(function()
                task.wait(0.3)
                if typeof(X.scanInventoryEggsForScramble) == "function" then
                    pcall(X.scanInventoryEggsForScramble)
                end
                if typeof(X.updateScrambleUI) == "function" then
                    pcall(X.updateScrambleUI)
                end
                X.listDirty = true
            end)
        end                                     -- (not arrived: the loop's gate finishes the delivery)
        X.requestEggRefresh()                   -- redraw the egg list now instead of waiting for luck
        finish(arrived)
    end, { snapRadius = X.SNAP_RADIUS, snapBeside = true, stuckHop = true })

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
        while not ok and dropRetry and dropRetry.uid == uid and dropRetry.n <= 8 and walkToken == myTok do
            task.wait(0.3)
            if walkToken ~= myTok then break end
            local cur = eggCache.byUid[uid]
            local p = cur and extPos(cur) or pos
            ok = autoGetEgg(uid, p, myTok, true)
        end
    end)
end

-- Priority: Divine -> Eternal -> Secret -> Scramble Requirements -> farthest -> any
-- STEAL OPPORTUNITY: Within top available tier, if any egg is dropped/loose/midway, steal the CLOSEST one!
function X.pickNearest(records)
    if typeof(records) ~= "table" then return nil end
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local myPos = root and root.Position
    if not myPos then return nil end
    local hasR = X.hasRarity()
    local now = os.clock()

    -- 1. Gather all valid candidates and determine best (lowest) tier
    local candidates = {}
    local bestTier = math.huge

    for _, r in ipairs(records) do
        if typeof(r) == "table" and passesFilters(r) and not (X.isNewOrUnknownEgg and X.isNewOrUnknownEgg(r)) then
            local u = tostring(r.Uid or "")
            if u ~= "" and not X.isCarriedByOther(u, r) and not (X.badUids[u] and now < X.badUids[u]) then
                local p = extPos(r)
                if p then
                    local tier = ((hasR or X.prioritizeScrambleInAutoFarm) and X.eggTier(r) or 0) + (X.isUnverified(r) and 100 or 0)
                    if tier < bestTier then
                        bestTier = tier
                    end
                    local dx = p.X - myPos.X
                    local dy = p.Y - myPos.Y
                    local dz = p.Z - myPos.Z
                    local dist = math.sqrt(dx*dx + dz*dz + dy*dy*0.25)
                    local isDropped = (r.State == "Dropped") or (X.looseUids[u] == true)
                        or (X.weDropped and X.weDropped[u] ~= nil)
                        or (X.nestPos[u] and (p - X.nestPos[u]).Magnitude > 6)
                        or (not r.NestId and not r.AreaId)
                    table.insert(candidates, {
                        rec = r,
                        uid = u,
                        pos = p,
                        tier = tier,
                        dist = dist,
                        isDropped = isDropped
                    })
                end
            end
        end
    end

    if #candidates == 0 then return nil end

    -- 2. Within bestTier:
    -- If dropped/loose/midway egg(s) exist in bestTier, STEAL the CLOSEST one!
    -- Otherwise, pick the FARTHEST nest egg in that tier!
    local bestDropped, bestDroppedDist = nil, math.huge
    local bestNest, bestNestDist = nil, -1

    for _, c in ipairs(candidates) do
        if c.tier == bestTier then
            if c.isDropped then
                if c.dist < bestDroppedDist then
                    bestDropped, bestDroppedDist = c.rec, c.dist
                end
            else
                if c.dist > bestNestDist then
                    bestNest, bestNestDist = c.rec, c.dist
                end
            end
        end
    end

    if bestDropped then
        return bestDropped, bestTier, true
    elseif bestNest then
        return bestNest, bestTier, false
    end

    return nil
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

        if not skip and not weAreCarrying and X.isOnTreadmill() then
            local shouldDismount = false
            if X.autoDismountEnabled then
                if X.checkNightReset() then
                    shouldDismount = true
                elseif eggCache and eggCache.records and #eggCache.records > 0 then
                    local okPick, best = pcall(X.pickNearest, eggCache.records)
                    if okPick and typeof(best) == "table" then
                        shouldDismount = true
                    end
                end
            end

            if shouldDismount then
                X.nightResetTriggered = false
                X.lastNightResetAt = os.clock()
                X.nightResetGraceUntil = os.clock() + 12.0
                X.noEggSince = nil
                statusLabel.Text = "[AutoFarm] Night reset! Dismounting & Walking to Safezone..."
                statusLabel.TextColor3 = Color3.fromRGB(255, 215, 0)
                X.executeAutoDismount(true, function()
                    return not autoFarmEnabled or autoFarmToken ~= myTok
                end)
                statusLabel.Text = "[AutoFarm] Arrived at Safezone. Waiting 12s for egg spawn..."
                statusLabel.TextColor3 = Color3.fromRGB(120, 255, 150)
                task.wait(0.3)
                skip = true
            else
                statusLabel.Text = "[AutoFarm] Training on Treadmill (Waiting for night reset)..."
                statusLabel.TextColor3 = Color3.fromRGB(80, 220, 120)
                task.wait(0.5)
                skip = true
            end
        end

        -- Only if a pickup of OURS is still undelivered AND the egg is still really in our hands
        if not skip and weAreCarrying then
            if stillCarrying() then
                statusLabel.Text = "[AutoFarm] Delivering carried egg..."
                statusLabel.TextColor3 = Color3.fromRGB(255, 220, 100)
                X.switchToCarry()
                if autoReturnEnabled then walkSync(SAFE_ZONE, X.SAFE_ARRIVE_RADIUS, myTok, { stuckHop = true, snapRadius = X.SAFE_SNAP_RADIUS }) end
                if carryMarkers or isHoldingEgg() then X.deliverWait(myTok) end
                X.requestEggRefresh()
            end
            weAreCarrying = false          -- one attempt, then move on (never return empty-handed)
            carryUid = nil
            carryMarkers = nil
            dropRetry = nil
            X.resetVelocity()
            skip = true

            -- Auto-trade check immediately upon egg delivery to safe zone (rate-limited to 2s)
            if X.autoScrambleTrade and X.tryAutoScrambleTrade and (os.clock() - (X.lastAutoFarmTradeCheck or 0) >= 2) then
                X.lastAutoFarmTradeCheck = os.clock()
                local okT, traded = pcall(X.tryAutoScrambleTrade)
                if okT and traded then task.wait(1.5) end
            end
        end

        if not skip then
            -- Pre-scan auto-trade check: rate-limited to 15s
            if X.autoScrambleTrade and X.tryAutoScrambleTrade and not weAreCarrying and (os.clock() - (X.lastAutoFarmTradeCheck or 0) >= 15) then
                X.lastAutoFarmTradeCheck = os.clock()
                local okT, traded = pcall(X.tryAutoScrambleTrade)
                if okT and traded then
                    task.wait(1.5)
                    skip = true
                end
            end
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
                if dropRetry and dropRetry.uid then
                    local maxRetries = currentSettings.MaxBumpRetries or 8
                    if (dropRetry.n or 0) > maxRetries or os.clock() - (dropRetry.t or 0) > 60 then
                        warn("[AutoFarm] Reached max bump retries (" .. tostring(maxRetries) .. ") for egg " .. tostring(dropRetry.uid) .. " — retargeting...")
                        dropRetry = nil
                    else
                        -- Issue #1 fix: verify dropped egg is not stolen before retrying!
                        local isStolenNow = X.isCarriedByOther(dropRetry.uid) or X.isEggInBaseRenders(dropRetry.uid) or X.deliveredUids[dropRetry.uid]
                        if isStolenNow then
                            warn("[AutoFarm] Dropped egg was stolen/claimed by another player — clearing retry:", dropRetry.uid)
                            dropRetry = nil
                        else
                            target = eggCache.byUid and eggCache.byUid[dropRetry.uid]
                            if target and X.isNewOrUnknownEgg and X.isNewOrUnknownEgg(target) then
                                target = nil
                                dropRetry = nil
                            elseif not target and os.clock() - (dropRetry.t or 0) < 6 then
                                waitingDrop = true
                            end
                        end
                    end
                end
                if not waitingDrop and not target and not skip then
                    local okPick, best, dist, stealFlag = pcall(X.pickNearest, records or {})
                    if okPick and typeof(best) == "table" then
                        target, isSteal = best, (stealFlag == true)
                    end
                end
                if waitingDrop then
                    statusLabel.Text = "[AutoFarm] Waiting for the dropped egg to reappear..."
                    statusLabel.TextColor3 = Color3.fromRGB(255, 220, 100)
                    task.wait(0.3)
                    skip = true
                elseif not target and not skip then
                    -- If no eggs on map match (e.g. user selected 'none' on farm egg and has the scramble eggs):
                    if X.autoScrambleTrade and X.tryAutoScrambleTrade and not weAreCarrying and (os.clock() - (X.lastAutoFarmTradeCheck or 0) >= 15) then
                        X.lastAutoFarmTradeCheck = os.clock()
                        local okT, traded = pcall(X.tryAutoScrambleTrade)
                        if okT and traded then
                            task.wait(1.5)
                            skip = true
                        end
                    end
                    if not skip then
                        local inNightGrace = X.nightResetGraceUntil and (os.clock() < X.nightResetGraceUntil)
                        if inNightGrace then
                            X.noEggSince = nil
                            local remaining = math.max(0, X.nightResetGraceUntil - os.clock())
                            statusLabel.Text = string.format("[AutoFarm] Night reset: eggs respawning (%.1fs/12s)...", remaining)
                            statusLabel.TextColor3 = Color3.fromRGB(255, 215, 0)
                            task.wait(0.3)
                            skip = true
                        elseif X.autoTreadmillEnabled then
                            if not X.noEggSince then
                                X.noEggSince = os.clock()
                            end
                            local elapsed = os.clock() - X.noEggSince
                            if elapsed >= 3.0 then
                                if not X.isOnTreadmill() then
                                    statusLabel.Text = "[AutoFarm] No eggs for 3s -> Moving to Treadmill..."
                                    statusLabel.TextColor3 = Color3.fromRGB(100, 200, 255)
                                    local arrived = X.executeAutoTreadmill(function()
                                        return not autoFarmEnabled or autoFarmToken ~= myTok
                                    end)
                                    if arrived then
                                        X.nightResetTriggered = false
                                        local lighting = game:GetService("Lighting")
                                        X.mountedAtClockTime = lighting and lighting.ClockTime
                                        statusLabel.Text = "[AutoFarm] Training on Treadmill (Waiting for reset)..."
                                        statusLabel.TextColor3 = Color3.fromRGB(80, 220, 120)
                                    else
                                        task.wait(0.5)
                                    end
                                else
                                    task.wait(0.5)
                                end
                                skip = true
                            else
                                statusLabel.Text = string.format("[AutoFarm] No matching eggs (%.1fs/3.0s)...", elapsed)
                                statusLabel.TextColor3 = Color3.fromRGB(255, 200, 100)
                                task.wait(0.25)
                                skip = true
                            end
                        else
                            X.noEggSince = nil
                            statusLabel.Text = "[AutoFarm] No matching eggs — waiting..."
                            statusLabel.TextColor3 = Color3.fromRGB(255, 200, 100)
                            local w = 0
                            while w < X.AUTO_EMPTY_WAIT and autoFarmEnabled and autoFarmToken == myTok do
                                task.wait(0.25); w = w + 0.25
                            end
                            skip = true
                        end
                    end
                elseif typeof(target) == "table" and not skip then
                    X.noEggSince = nil
                    X.nightResetGraceUntil = nil
                    if X.isOnTreadmill() then
                        X.executeAutoDismount(true, function()
                            return not autoFarmEnabled or autoFarmToken ~= myTok
                        end)
                    end
                    local pos = extPos(target)
                    local uid = tostring(target.Uid or "")
                    local sp  = tostring(target.AssetCategory or "?")
                    if not pos or uid == "" then
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

                        local okCall, ok = pcall(autoGetEgg, uid, pos, myTok)
                        if not okCall then
                            ok = false
                            warn("[AutoFarm] autoGetEgg error:", ok)
                        end
                        if not weAreCarrying then
                            X.resetVelocity(true)  -- v10: clean travel speed reset for every egg
                        end
                        if ok then
                            dropRetry = nil
                            statusLabel.Text = "[AutoFarm] OK " .. sp
                            statusLabel.TextColor3 = Color3.fromRGB(120, 255, 150)
                        elseif isHoldingEgg() then
                            weAreCarrying = true
                            dropRetry = nil
                            statusLabel.Text = "[AutoFarm] Holding egg — delivering..."
                            statusLabel.TextColor3 = Color3.fromRGB(255, 220, 100)
                        else
                            -- Cancel dropRetry if egg was stolen, claimed, or failed
                            local isStolenOrBad = X.isCarriedByOther(uid) or (X.badUids[uid] and os.clock() < X.badUids[uid]) or X.isEggInBaseRenders(uid) or X.deliveredUids[uid]
                            if isStolenOrBad or (dropRetry and dropRetry.uid == uid) then
                                dropRetry = nil
                                X.weDropped[uid] = nil
                                X.looseUids[uid] = nil
                            end
                            statusLabel.Text = lastFailReason or "[AutoFarm] failed/skipped — next..."
                            lastFailReason = nil
                            statusLabel.TextColor3 = Color3.fromRGB(255, 180, 80)
                        end

                        -- Neutralise egg physics throttled
                        local cch = LocalPlayer.Character
                        if cch then neutraliseEggPhysics(cch, false) end

                        local w = 0
                        local nextDelay = dropRetry and 0.25 or 0.15
                        while w < nextDelay and autoFarmEnabled and autoFarmToken == myTok do
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
            X.noEggSince = nil
            X.nightResetTriggered = false
            pcall(function()
                local ch = LocalPlayer.Character
                local hum = ch and ch:FindFirstChildOfClass("Humanoid")
                if hum then hum:Move(Vector3.zero) end
            end)
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
-- ZERO-WAIT INSTANT RAGDOLL RECOVERY ENGINE
-- Ported from instant-ragdoll-recovery.lua (v2.0 Zero-Wait)
-- ==================================================

-- Execute Zero-Wait Instant Recovery
local function executeInstantRecovery(reason)
    if not recoveryEnabled then return end

    local char = LocalPlayer.Character
    if not char then return end
    local hum = char:FindFirstChildOfClass("Humanoid")
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hum or hum.Health <= 0 then return end

    X.recoveryCount = (X.recoveryCount or 0) + 1
    recoveryActive = true
    recoveryState = RECOVERY_STATE.RECOVERING

    -- 1. Wipe RagdollEndTime to 0 so game scripts NEVER wait
    clearRagdollAttributes()

    -- 2. Zero-Frame Motor6D Joint Restoration
    local restored = 0
    if X.jointsTable and #X.jointsTable > 0 then
        for _, motor in ipairs(X.jointsTable) do
            if motor and motor.Parent and not motor.Enabled then
                motor.Enabled = true
                restored = restored + 1
            end
        end
    else
        for _, o in ipairs(char:GetDescendants()) do
            if o:IsA("Motor6D") and not o.Enabled then
                pcall(function() o.Enabled = true end)
            end
        end
    end

    -- 3. Clear PlatformStand and Sit immediately
    hum.PlatformStand = false
    hum.Sit = false
    hum.AutoRotate = true

    -- 4. Re-enable humanoid recovery states & force Running
    pcall(function()
        hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, true)
        hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, true)
        hum:SetStateEnabled(Enum.HumanoidStateType.Physics, true)
        hum:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
        hum:SetStateEnabled(Enum.HumanoidStateType.Running, true)
    end)

    pcall(function() hum:ChangeState(Enum.HumanoidStateType.GettingUp) end)
    pcall(function() hum:ChangeState(Enum.HumanoidStateType.Running) end)

    -- 5. Restore WalkSpeed if the game zeroed it
    if hum.WalkSpeed < 16.0 then
        hum.WalkSpeed = velocityEnabled and targetVelocity or math.max(savedWalkSpeed, 16.0)
    end

    -- 6. Immediately re-enable PlayerModule controls (WASD)
    enablePlayerControls()

    -- 7. Anti-Fling Braking & Fast Grounding
    -- Stay right at the bump location (cancel horizontal fling) and go down fast if airborne
    if hrp then
        local curVel = hrp.AssemblyLinearVelocity
        local fastY = curVel.Y
        -- If boss launched us upward, cancel upward launch and drive downward fast
        if fastY > 0 then
            fastY = -45
        elseif fastY > -30 then
            -- If floating or descending slowly, accelerate downward fast to touch ground immediately
            fastY = -45
        end
        -- Zero horizontal fling velocity so character stays right at the bump location beside the egg
        hrp.AssemblyLinearVelocity = Vector3.new(0, fastY, 0)
        hrp.AssemblyAngularVelocity = Vector3.zero
    end

    -- 8. Neutralize carried egg physics mass
    neutraliseEggPhysics(char, true)

    recoveryState = RECOVERY_STATE.NONE
    recoveryActive = false
    isRagdolled = false
end

-- Backward compatibility alias
local function recoveryRoutine(h, r)
    executeInstantRecovery("Routine")
end

-- Heartbeat Safety Net (Zero-Frame Enforcement)
local function applyRecovery()
    if not recoveryEnabled then return end
    local ch = LocalPlayer.Character
    local h = ch and ch:FindFirstChildOfClass("Humanoid")
    local r = ch and ch:FindFirstChild("HumanoidRootPart")
    if not h or not r or h.Health <= 0 then return end

    -- Keep active WalkSpeed track
    if h.WalkSpeed >= 16.0 and not velocityEnabled then
        savedWalkSpeed = h.WalkSpeed
    end

    -- 1. Check if server set RagdollEndTime > 0; if so, clear it immediately
    local rEnd = LocalPlayer:GetAttribute("RagdollEndTime")
    if typeof(rEnd) == "number" and rEnd > 0 then
        clearRagdollAttributes()
        enablePlayerControls()
    end

    -- 2. Check for disabled motors
    local disabled = 0
    if X.jointsTable then
        for _, m in ipairs(X.jointsTable) do
            if m and m.Parent and not m.Enabled then
                disabled = disabled + 1
                m.Enabled = true
            end
        end
    end
    if disabled > 0 then
        executeInstantRecovery(string.format("%dMotorsFixed", disabled))
    end

    -- 3. Fast Grounding & Anti-Drift (Zero slow-float)
    if r then
        local timeSinceHit = os.clock() - (X.lastRagdollAt or 0)
        if timeSinceHit < 0.6 then
            local curVel = r.AssemblyLinearVelocity
            local vy = curVel.Y
            -- If airborne following a bump, pull down fast to ground immediately (never slow-float)
            if h.FloorMaterial == Enum.Material.Air then
                if vy > -35 then vy = -45 end
            end
            -- Prevent horizontal knockback drift unless actively moving with WASD
            if h.MoveDirection.Magnitude <= 0.05 then
                r.AssemblyLinearVelocity = Vector3.new(0, vy, 0)
                r.AssemblyAngularVelocity = Vector3.zero
            else
                r.AssemblyLinearVelocity = Vector3.new(curVel.X, vy, curVel.Z)
            end
        end
    end

    -- 4. Ensure controls and WalkSpeed are intact
    if h.WalkSpeed < 16.0 then
        h.WalkSpeed = velocityEnabled and targetVelocity or math.max(savedWalkSpeed, 16.0)
        enablePlayerControls()
    end

    -- 5. Check if humanoid in ragdoll/fallen state
    local s = h:GetState()
    if s == Enum.HumanoidStateType.Ragdoll
        or s == Enum.HumanoidStateType.FallingDown
        or s == Enum.HumanoidStateType.Physics
        or h.PlatformStand
        or h.Sit then
        executeInstantRecovery(tostring(s.Name))
    end
end

-- Character Binding & Event Listeners
local function bindCharacter(char)
    if X.recoveryConnections then
        for _, conn in ipairs(X.recoveryConnections) do
            pcall(function() conn:Disconnect() end)
        end
    end
    X.recoveryConnections = {}
    X.jointsTable = {}

    if not char then return end
    local hum = char:WaitForChild("Humanoid", 5)
    local hrp = char:WaitForChild("HumanoidRootPart", 5)
    if not hum or not hrp then return end

    if hum.WalkSpeed >= 16.0 and not velocityEnabled then
        savedWalkSpeed = hum.WalkSpeed
    end

    -- Index all Motor6D joints and hook Enabled property
    local function registerMotor(obj)
        if obj:IsA("Motor6D") then
            table.insert(X.jointsTable, obj)
            local conn = obj:GetPropertyChangedSignal("Enabled"):Connect(function()
                if recoveryEnabled and not obj.Enabled then
                    obj.Enabled = true
                    executeInstantRecovery("JointLock")
                end
            end)
            table.insert(X.recoveryConnections, conn)
        end
    end

    for _, desc in ipairs(char:GetDescendants()) do
        registerMotor(desc)
    end

    local descConn = char.DescendantAdded:Connect(function(desc)
        registerMotor(desc)
    end)
    table.insert(X.recoveryConnections, descConn)

    -- State Listener
    local stateConn = hum.StateChanged:Connect(function(oldState, newState)
        local isRagState = newState == Enum.HumanoidStateType.Ragdoll
            or newState == Enum.HumanoidStateType.FallingDown
            or newState == Enum.HumanoidStateType.Physics
        if isRagState then
            X.ragdollEpoch = X.ragdollEpoch + 1
            X.lastRagdollAt = os.clock()
        end
        if recoveryEnabled and isRagState then
            executeInstantRecovery(tostring(newState.Name))
        end
    end)
    table.insert(X.recoveryConnections, stateConn)

    -- PlatformStand / Sit Watcher
    local platConn = hum:GetPropertyChangedSignal("PlatformStand"):Connect(function()
        if recoveryEnabled and hum.PlatformStand then
            hum.PlatformStand = false
            executeInstantRecovery("PlatformStand")
        end
    end)
    table.insert(X.recoveryConnections, platConn)

    local sitConn = hum:GetPropertyChangedSignal("Sit"):Connect(function()
        if recoveryEnabled and hum.Sit then
            hum.Sit = false
            executeInstantRecovery("Sit")
        end
    end)
    table.insert(X.recoveryConnections, sitConn)

    -- RagdollEndTime Attribute Watcher on Player & Character
    local attrConn1 = LocalPlayer:GetAttributeChangedSignal("RagdollEndTime"):Connect(function()
        if recoveryEnabled then
            local rEnd = LocalPlayer:GetAttribute("RagdollEndTime")
            if typeof(rEnd) == "number" and rEnd > 0 then
                executeInstantRecovery("RagdollTimerZeroed")
            end
        end
    end)
    table.insert(X.recoveryConnections, attrConn1)

    local attrConn2 = char:GetAttributeChangedSignal("RagdollEndTime"):Connect(function()
        if recoveryEnabled then
            local rEnd = char:GetAttribute("RagdollEndTime")
            if typeof(rEnd) == "number" and rEnd > 0 then
                executeInstantRecovery("CharRagdollTimerZeroed")
            end
        end
    end)
    table.insert(X.recoveryConnections, attrConn2)

    neutraliseEggPhysics(char, true)
end

-- Backward compatibility alias
local function bindFastRagdoll(h, r)
    local ch = h and h.Parent
    if ch then bindCharacter(ch) end
    return nil
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
        X.wasRagdolledForVelocity = true
        if h.MoveDirection.Magnitude > 0.05 then lastMoveDirection = h.MoveDirection.Unit end
        -- Always halt horizontal knockback when hit/ragdolled to stay at bump location
        if not r.Anchored then
            local hz = Vector3.new(r.AssemblyLinearVelocity.X, 0, r.AssemblyLinearVelocity.Z)
            if hz.Magnitude > 2 then pcall(function() r.AssemblyLinearVelocity = Vector3.new(0, r.AssemblyLinearVelocity.Y, 0) end) end
        end
        return
    end
    if X.wasRagdolledForVelocity then
        X.wasRagdolledForVelocity = false
        pcall(function() h.WalkSpeed = targetVelocity end)
        -- Do not artificially launch forward upon recovery; let active MoveDirection govern movement naturally
    end
    if weAreCarrying then
        neutraliseEggPhysics(ch)
        if targetVelocity > X.baseCarryVelocity then
            targetVelocity = X.baseCarryVelocity
        end
    else
        if targetVelocity == X.baseCarryVelocity and X.baseVelocity > X.baseCarryVelocity then
            targetVelocity = X.baseVelocity
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

local staticRayParams = RaycastParams.new()
staticRayParams.FilterType = Enum.RaycastFilterType.Exclude

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
    -- Throttled raycast (4 Hz) reusing staticRayParams to prevent per-frame garbage
    if now - (X.lastRaycastCheck or 0) >= 0.25 then
        X.lastRaycastCheck = now
        staticRayParams.FilterDescendantsInstances = { ch }
        local ok, hit = pcall(function() return Workspace:Raycast(pos, md * 9, staticRayParams) end)
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

local metamethodsInstalled = false
local function installRecoveryMetamethods()
    if metamethodsInstalled then return end
    if typeof(hookmetamethod) ~= "function" then return end
    pcall(function()
        -- Hook 1: GetAttribute spoofing
        -- Whenever game client scripts ask for "RagdollEndTime" or "RagdollTime", return 0 so they NEVER wait!
        local oldNamecall
        oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
            local method = getnamecallmethod()
            if method == "GetAttribute" then
                if recoveryEnabled and (X.attributeSpoofEnabled ~= false) and not checkcaller() then
                    local attrName = ...
                    if attrName == "RagdollEndTime" or attrName == "RagdollTime" then
                        return 0
                    end
                end
            end
            return oldNamecall(self, ...)
        end)

        -- Hook 2: __newindex protection (Ultra fast-path key check)
        -- Blocks game scripts from setting Motor6D.Enabled = false, PlatformStand = true, or zeroing WalkSpeed
        local oldNewIndex
        oldNewIndex = hookmetamethod(game, "__newindex", function(self, key, value)
            if key == "WalkSpeed" then
                if (velocityEnabled or recoveryEnabled) and not checkcaller() then
                    local char = LocalPlayer.Character
                    if char and self.Parent == char then
                        local ok, isHum = pcall(function() return self:IsA("Humanoid") end)
                        if ok and isHum then
                            local spd = velocityEnabled and targetVelocity or math.max(savedWalkSpeed, 16.0)
                            return oldNewIndex(self, key, spd)
                        end
                    end
                end
            elseif key == "PlatformStand" then
                if recoveryEnabled and value == true and not checkcaller() then
                    local char = LocalPlayer.Character
                    if char and self.Parent == char then
                        return oldNewIndex(self, key, false)
                    end
                end
            elseif key == "Enabled" then
                if recoveryEnabled and value == false and not checkcaller() then
                    local char = LocalPlayer.Character
                    if char then
                        local ok, isMotor = pcall(function() return self:IsA("Motor6D") end)
                        if ok and isMotor and self:IsDescendantOf(char) then
                            return oldNewIndex(self, key, true)
                        end
                    end
                end
            end
            return oldNewIndex(self, key, value)
        end)

        metamethodsInstalled = true
        print("[EggGoToUI v10] Zero-Wait recovery & speed metamethod hooks installed successfully.")
    end)
end
installWalkSpeedHook = installRecoveryMetamethods
pcall(installRecoveryMetamethods)

local function enableVelocity()
    installWalkSpeedHook()
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
local tabScramble
local tabUtility
local tabBtnEggs
local tabBtnPets
local tabBtnScramble
local tabBtnUtility
local switchTab
local refreshScrambleUI
local logScramble
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
function X.buildPetsTabUI()
-- ==================================================
-- TAB 2: PETS & AUTOMATION SUITE
-- ==================================================
local tabPetsLayout = Instance.new("UIListLayout")
tabPetsLayout.Padding = UDim.new(0, 6)
tabPetsLayout.SortOrder = Enum.SortOrder.LayoutOrder
tabPetsLayout.Parent = tabPets

local tabPetsPad = Instance.new("UIPadding")
tabPetsPad.PaddingTop = UDim.new(0, 6)
tabPetsPad.PaddingBottom = UDim.new(0, 6)
tabPetsPad.PaddingLeft = UDim.new(0, 8)
tabPetsPad.PaddingRight = UDim.new(0, 8)
tabPetsPad.Parent = tabPets

-- Networking & Formatting helpers (reused from X)
local getNetRemote     = X.getNetRemote
local formatStatNumber = X.formatStatNumber
local formatEarnString = X.formatEarnString
local formatPetWeight  = X.formatPetWeight

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

local function extractPetStats(petData, inst)
    local earn = nil
    local weight = nil
    local weightNum = 0

    if type(petData) == "table" then
        local rawEarn = petData["Money/s"] or petData.EarnRate or petData.MoneyRate or petData.Earn or petData.Rate or petData.Income or petData.CoinsPerSec or petData.CoinsPerSecond or petData.Cps or petData.Production or petData.Value
        if rawEarn ~= nil then
            earn = formatEarnString(rawEarn)
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
                local aEarn = attrs["Money/s"] or attrs.EarnRate or attrs.MoneyRate or attrs.Earn or attrs.Rate or attrs.Income or attrs.Value
                if aEarn ~= nil then
                    earn = formatEarnString(aEarn)
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
                            earn = formatEarnString(t)
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

    return earn or "+$0/s", weight or "-- kg", weightNum
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
            if t:IsA("Tool") and X.isEggTool(t) then
                local attrs = t:GetAttributes() or {}
                local u = tostring(attrs.UID or attrs.Uid or attrs.Id or t.Name)
                if not seen[u] then
                    seen[u] = true
                    count = count + 1
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


function X.parseEarnNumber(str)
    if typeof(str) == "number" then return str end
    if not str or typeof(str) ~= "string" then return 0 end
    local mult = 1
    local upper = str:upper()
    if upper:find("T") then mult = 1e12
    elseif upper:find("B") then mult = 1e9
    elseif upper:find("M") then mult = 1e6
    elseif upper:find("K") then mult = 1e3
    end
    local clean = str:gsub("[^%d%.]", "")
    local num = tonumber(clean)
    return num and (num * mult) or 0
end

function X.formatPriceString(val)
    if typeof(val) == "number" then
        return "$" .. (formatStatNumber(val) or tostring(val))
    end
    local s = tostring(val or "")
    if s == "" then return "$0" end
    s = s:gsub("[%s💵]+", "")
    if not s:find("%$") then s = "$" .. s end
    return s
end

X.speciesConfigCache = {}
X.configsIndexed = false

function X.indexAllConfigs()
    if X.configsIndexed then return end
    local confFolder = ReplicatedStorage:FindFirstChild("Data")
        and ReplicatedStorage.Data:FindFirstChild("Assets")
        and ReplicatedStorage.Data.Assets:FindFirstChild("Configs")
    if not confFolder then return end

    for _, mod in ipairs(confFolder:GetChildren()) do
        if mod:IsA("ModuleScript") then
            local ok, data = pcall(require, mod)
            if ok and type(data) == "table" and data.EarningRate then
                local rate = tonumber(data.EarningRate)
                if rate and rate > 0 then
                    local cKey = mod.Name:lower():gsub("[^%w]", "")
                    X.speciesConfigCache[cKey] = rate
                    if data.DisplayName and data.DisplayName ~= "" then
                        local dKey = tostring(data.DisplayName):lower():gsub("[^%w]", "")
                        X.speciesConfigCache[dKey] = rate
                    end
                end
            end
        end
    end
    -- Authoritative Shark separation:
    -- In game configs, Config [Finned Thresher] is Shark (15,000/s)
    -- Config [Shark] is Mutant Shark (215,000,000/s)
    X.speciesConfigCache["shark"] = 15000
    X.speciesConfigCache["mutantshark"] = 215000000
    X.speciesConfigCache["finnedthresher"] = 15000
    X.configsIndexed = true
end

function X.getSpeciesBaseRate(speciesName, categoryName)
    X.indexAllConfigs()

    local function norm(s)
        return s and tostring(s):lower():gsub("[^%w]", "") or nil
    end

    local nSpecies = norm(speciesName)
    local nCat = norm(categoryName)

    if nSpecies == "shark" and nCat ~= "mutantshark" then
        return 15000
    elseif nSpecies == "mutantshark" or nCat == "mutantshark" then
        return 215000000
    end

    if nCat and X.speciesConfigCache[nCat] then
        return X.speciesConfigCache[nCat]
    end
    if nSpecies and X.speciesConfigCache[nSpecies] then
        return X.speciesConfigCache[nSpecies]
    end

    if X.EGG_SPECIES_ALIASES then
        for _, k in ipairs({categoryName, speciesName}) do
            local alias = k and (X.EGG_SPECIES_ALIASES[k] or X.EGG_SPECIES_ALIASES[tostring(k):lower()])
            if alias then
                local nAlias = norm(alias)
                if nAlias and X.speciesConfigCache[nAlias] then
                    return X.speciesConfigCache[nAlias]
                end
            end
        end
    end

    return nil
end

function X.initInternalEngine()
    if X._internalEngineInited then return end
    X._internalEngineInited = true
    pcall(function()
        local EggRecords = require(ReplicatedStorage.Shared.Util.EggRecords)
        local getUpvals = (typeof(debug) == "table" and typeof(debug.getupvalues) == "function" and debug.getupvalues)
            or (typeof(getupvalues) == "function" and getupvalues)
        if getUpvals and EggRecords and type(EggRecords.SellPrice) == "function" then
            local u1 = getUpvals(EggRecords.SellPrice)
            if u1 and type(u1[3]) == "table" and type(u1[3].SalePrice) == "function" then
                local u2 = getUpvals(u1[3].SalePrice)
                if u2 and type(u2[2]) == "table" and type(u2[2].RatePerSecond) == "function" then
                    X.internalRatePerSecond = u2[2].RatePerSecond
                end
            end
        end
    end)
end

function X.getEggEarnRate(r)
    if typeof(r) ~= "table" then return "+$0/s" end

    -- 1. Direct record fields
    local raw = r["Money/s"] or r.EarnRate or r.MoneyRate or r.Earn or r.Rate or r.Income or r.CoinsPerSec or r.CoinsPerSecond or r.Cps or r.Production
    if raw ~= nil then
        return formatEarnString(raw)
    end

    -- 2. Nested Stats / Attributes in r
    if typeof(r.Stats) == "table" then
        local sEarn = r.Stats["Money/s"] or r.Stats.EarnRate or r.Stats.Earn or r.Stats.Rate
        if sEarn then
            return formatEarnString(sEarn)
        end
    end
    if typeof(r.Attributes) == "table" then
        local aEarn = r.Attributes["Money/s"] or r.Attributes.EarnRate or r.Attributes.Earn or r.Attributes.Rate
        if aEarn then
            return formatEarnString(aEarn)
        end
    end

    -- 3. Workspace.AreaEggSlotsClient slot object inspection (for map eggs)
    local area = Workspace:FindFirstChild("AreaEggSlotsClient")
    local uid = tostring(r.Uid or r.Id or r.UUID or "")
    if area and uid ~= "" and X.findEggSlot then
        local pos = extPos and extPos(r)
        local slot = X.findEggSlot(area, uid, r.NestId, r.AreaId, pos)
        if slot then
            local okA, attrs = pcall(function() return slot:GetAttributes() end)
            if okA and typeof(attrs) == "table" then
                local aVal = attrs["Money/s"] or attrs.EarnRate or attrs.MoneyRate or attrs.Earn or attrs.Rate or attrs.Income
                if aVal ~= nil then
                    return formatEarnString(aVal)
                end
            end
            for _, d in ipairs(slot:GetDescendants()) do
                if d:IsA("ValueBase") and (d.Name == "Money/s" or d.Name == "EarnRate" or d.Name == "Earn") then
                    local v = d.Value
                    if v ~= nil then return formatEarnString(v) end
                elseif d:IsA("TextLabel") and d.Text ~= "" then
                    local m = d.Text:match("[%+%$]?[%d%.]+%a*/s")
                    if m then return formatEarnString(m) end
                end
            end
        end
    end

    -- 4. Check species authoritative config & growth scaling
    local catName = r.Category or (r.Attributes and r.Attributes.Category) or r.BaseSpecies or r.AssetCategory
    local spName = r.Species or r.DisplayName or (r.Attributes and r.Attributes.DisplayName)
    local rawScale = tonumber(r.Scale) or (r.Attributes and tonumber(r.Attributes.Scale)) or 1
    local rawWeight = tonumber(r.Weight) or tonumber(r.RawWeight) or (r.Attributes and tonumber(r.Attributes.Weight)) or 0
    local mut = r.Mutation or (r.Attributes and (r.Attributes.BaseMutation or r.Attributes.Mutations)) or (typeof(mutLabel) == "function" and mutLabel(r))

    -- Method A: Direct internal client engine (RatePerSecond from AssetItems via EggRecords upvalues)
    X.initInternalEngine()
    if typeof(X.internalRatePerSecond) == "function" then
        local mutArr = {}
        if mut and mut ~= "" and mut ~= "Normal" then
            table.insert(mutArr, mut)
        end
        local iData = {
            Category = catName or spName or "Shark",
            AssetCategory = catName or spName or "Shark",
            Scale = rawScale,
            AssetScale = rawScale,
            Weight = rawWeight,
            AssetWeight = rawWeight,
            Mutations = mutArr,
            BaseMutation = (mut and mut ~= "" and mut ~= "Normal") and mut or nil,
        }
        local okRate, liveRate = pcall(X.internalRatePerSecond, iData)
        if okRate and typeof(liveRate) == "number" and liveRate > 0 then
            return formatEarnString(liveRate)
        end
    end

    -- Method B: Authoritative Config Base Rate * Growth Multiplier (STEEP_GROWTH_POWER = 1.389) * Mutation Multiplier
    local baseEarn = X.getSpeciesBaseRate(spName, catName)
    if not baseEarn then
        local fullRar = r.Rarity or (typeof(effectiveRarity) == "function" and effectiveRarity(r)) or "Common"
        local lowName = tostring(spName or catName or ""):lower()
        if lowName == "shark" then
            baseEarn = 15000
        elseif lowName == "mutant shark" then
            baseEarn = 215000000
        else
            local baseTable = {
                ["Common"]    = 100,
                ["Uncommon"]  = 500,
                ["Rare"]      = 2500,
                ["Epic"]      = 15000,
                ["Legendary"] = 100000,
                ["Mythic"]    = 1000000,
                ["Cosmic"]    = 25000000,
                ["Secret"]    = 215000000,
                ["Eternal"]   = 10000000000,
                ["Divine"]    = 150000000000,
            }
            baseEarn = baseTable[fullRar] or 100
        end
    end

    local growthMult = 1
    if rawScale <= 2.0 then
        growthMult = rawScale
    elseif rawScale <= 6.0 then
        growthMult = rawScale ^ 1.389
    else
        growthMult = 4.6 * (rawScale ^ 0.72)
    end

    local mutMult = 1
    if mut and mut ~= "" and mut ~= "Normal" then
        local lowM = tostring(mut):lower()
        if lowM:find("rainbow") then mutMult = 2.0
        elseif lowM:find("gold") then mutMult = 1.5
        elseif lowM:find("scramble") then mutMult = 1.5
        elseif lowM:find("silver") then mutMult = 1.25
        else mutMult = 1 end
    end

    local finalEarn = math.round(baseEarn * growthMult * mutMult)
    return formatEarnString(finalEarn)
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
                                if sp then
                                    equippedNames[sp] = (equippedNames[sp] or 0) + 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- 2. PlayerGui live pet slots & sell panel / satchel / backpack for live earn rates and prices
    local liveGuiEarnRates = {}
    local liveGuiSellPrices = {}
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if pg then
        pcall(function()
            for _, g in ipairs(pg:GetChildren()) do
                if g:IsA("ScreenGui") and g ~= screenGui then
                    local gLow = g.Name:lower()
                    if gLow:find("activepets") or gLow:find("satchel") or gLow:find("pet") or gLow:find("backpack") or gLow:find("sell") or gLow:find("inv") or gLow:find("haul") then
                        for _, d in ipairs(g:GetDescendants()) do
                            if d:IsA("TextLabel") and d.Text ~= "" then
                                local m = d.Text:match("[%+%$]?[%d%.]+%a*/s")
                                local isPrice = d.Text:find("💵") or (d.Text:match("^%$[%d%.]+%a*$") and not d.Text:find("/s"))
                                if m or isPrice then
                                    local p = d.Parent
                                    for _ = 1, 4 do
                                        if not p or p == g then break end
                                        local u = p.Name:match("^Pet_(%x+)$")
                                            or (p.Name:len() == 32 and p.Name:match("^%x+$") and p.Name)
                                        if not u then
                                            local okAt, pAt = pcall(function() return p:GetAttributes() end)
                                            if okAt and type(pAt) == "table" then
                                                u = pAt.UID or pAt.Uid or pAt.Id or pAt.UUID
                                            end
                                        end
                                        if u then
                                            local uStr = tostring(u)
                                            if m then
                                                local formattedRate = formatEarnString(m)
                                                liveGuiEarnRates[uStr] = formattedRate
                                                if gLow:find("activepets") then
                                                    equippedUids[uStr] = true
                                                    equippedEarnRates[uStr] = formattedRate
                                                end
                                            elseif isPrice then
                                                local cleanP = d.Text:gsub("^[%s💵]+", "")
                                                liveGuiSellPrices[uStr] = cleanP
                                            end
                                            break
                                        end
                                        p = p.Parent
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end)
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
                if not X.isGearTool(tool, attrs) and not X.isEggTool(tool, attrs) and attrs.CarrierUserId == nil then
                    local petUid = attrs.UID or attrs.Uid or attrs.Id or tool.Name
                    local uidStr = tostring(petUid)
                    if not seenUids[uidStr] then
                        seenUids[uidStr] = true
                        local rawName = attrs.DisplayName or attrs.Category or tool.Name
                        local cleanBase = X.cleanSpeciesName(rawName)
                        local rawBaseSpecies = cleanBase
                            if cleanBase:lower() == "shark" then
                                cleanBase = "Shark"
                                rawBaseSpecies = "Shark"
                            elseif cleanBase:lower() == "mutant shark" then
                                cleanBase = "Mutant Shark"
                                rawBaseSpecies = "Mutant Shark"
                            elseif X.getDisplayEggName then
                                cleanBase = X.getDisplayEggName(cleanBase)
                            end

                            local weightStr, weightNum = formatPetWeight(attrs.Weight, attrs.Scale)

                            local mut = ""
                            if type(attrs.BaseMutation) == "string" and attrs.BaseMutation ~= "" then
                                mut = attrs.BaseMutation
                            elseif type(attrs.Mutations) == "string" and attrs.Mutations ~= "" then
                                mut = attrs.Mutations
                            elseif type(attrs.Mutations) == "table" then
                                for _, m in pairs(attrs.Mutations) do
                                    if type(m) == "string" and m ~= "" then mut = m; break end
                                end
                            end
                            if mut == "" then
                                for _, mWord in ipairs({"Rainbow", "Golden", "Silver", "Gold"}) do
                                    if string.find(tool.Name, "^" .. mWord) or string.find(rawName, "^" .. mWord) or string.find(tool.Name, "%[" .. mWord .. "%]") then
                                        mut = mWord
                                        break
                                    end
                                end
                            end

                            local rarity = attrs.Rarity or (typeof(PET_RARITY_PRESETS) == "table" and (PET_RARITY_PRESETS[cleanBase] or PET_RARITY_PRESETS[rawName] or (attrs.Category and PET_RARITY_PRESETS[attrs.Category]))) or "Common"
                            if cleanBase == "Shark" then
                                rarity = "Legendary"
                            elseif cleanBase == "Mutant Shark" then
                                rarity = "Secret"
                            end

                            local isEquip = equippedUids[uidStr] == true or attrs.Equipped == true
                            local earn = equippedEarnRates[uidStr] or liveGuiEarnRates[uidStr]
                            if not earn or earn == "--/s" or earn == "" or earn == "+$0/s" then
                                local petRec = {
                                    Uid = uidStr,
                                    Species = cleanBase,
                                    BaseSpecies = rawBaseSpecies,
                                    Category = attrs.Category or rawBaseSpecies,
                                    DisplayName = rawName,
                                    Rarity = rarity,
                                    Mutation = mut,
                                    Weight = weightNum,
                                    Scale = tonumber(attrs.Scale) or 1,
                                    RawWeight = tonumber(attrs.Weight) or 0,
                                    Attributes = attrs,
                                }
                                earn = X.getEggEarnRate(petRec)
                            end
                            earn = formatEarnString(earn)

                            local sellPriceStr = liveGuiSellPrices[uidStr]
                            if not sellPriceStr or sellPriceStr == "" then
                                local earnVal = X.parseEarnNumber(earn)
                                if earnVal and earnVal > 0 then
                                    sellPriceStr = X.formatPriceString(earnVal * 80)
                                end
                            end

                            table.insert(rawPets, {
                                Id = uidStr,
                                Uid = uidStr,
                                Species = cleanBase,
                                BaseSpecies = cleanBase,
                                RawSpecies = rawBaseSpecies,
                                DisplayName = rawName,
                                Mutation = mut,
                                Rarity = rarity,
                                Equipped = isEquip,
                                _weightNum = weightNum,
                                _weight = weightStr,
                                _earn = earn,
                                _price = sellPriceStr,
                                _source = srcName
                            })
                            sourceBreakdown[srcName] = (sourceBreakdown[srcName] or 0) + 1
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
        local cleanBase = pet.BaseSpecies or pet.Species or "Unknown"
        if cleanBase:lower() == "shark" then
            cleanBase = "Shark"
        elseif cleanBase:lower() == "mutant shark" then
            cleanBase = "Mutant Shark"
        elseif X.getDisplayEggName then
            cleanBase = X.getDisplayEggName(cleanBase)
        end
        local rarity = pet.Rarity or (typeof(PET_RARITY_PRESETS) == "table" and (PET_RARITY_PRESETS[cleanBase] or (pet.Species and PET_RARITY_PRESETS[pet.Species]))) or "Common"
        if cleanBase == "Shark" then
            rarity = "Legendary"
        elseif cleanBase == "Mutant Shark" then
            rarity = "Secret"
        end

        local isEquipped = (pet.Equipped == true)
            or (uid ~= "" and equippedUids[uid] == true)
            or (equippedNames[cleanBase] and equippedNames[cleanBase] > 0)
            or (pet.RawSpecies and equippedNames[pet.RawSpecies] and equippedNames[pet.RawSpecies] > 0)
            or (pet.DisplayName and equippedNames[pet.DisplayName] and equippedNames[pet.DisplayName] > 0)

        if isEquipped then
            totalEquipped = totalEquipped + 1
            if equippedNames[cleanBase] and equippedNames[cleanBase] > 0 then
                equippedNames[cleanBase] = equippedNames[cleanBase] - 1
            elseif pet.RawSpecies and equippedNames[pet.RawSpecies] and equippedNames[pet.RawSpecies] > 0 then
                equippedNames[pet.RawSpecies] = equippedNames[pet.RawSpecies] - 1
            elseif pet.DisplayName and equippedNames[pet.DisplayName] and equippedNames[pet.DisplayName] > 0 then
                equippedNames[pet.DisplayName] = equippedNames[pet.DisplayName] - 1
            end
        else
            if not unequippedGroups[cleanBase] then
                unequippedGroups[cleanBase] = {
                    species = cleanBase,
                    baseSpecies = cleanBase,
                    mutation = pet.Mutation or "",
                    count = 0,
                    uids = {},
                    pets = {},
                    rarity = rarity,
                    earn = pet._earn or formatEarnString(0),
                    price = pet._price or "",
                    weight = pet._weight or "-- kg",
                    mutCounts = {}
                }
            end
            if pet._earn and pet._earn ~= "--/s" and pet._earn ~= "" and pet._earn ~= "+$0/s" then
                unequippedGroups[cleanBase].earn = pet._earn
            end
            if pet._price and pet._price ~= "" then
                unequippedGroups[cleanBase].price = pet._price
            end
            if pet._weight and pet._weight ~= "-- kg" then
                unequippedGroups[cleanBase].weight = pet._weight
            end
            unequippedGroups[cleanBase].count = unequippedGroups[cleanBase].count + 1
            local mName = (pet.Mutation and pet.Mutation ~= "") and pet.Mutation or "Normal"
            unequippedGroups[cleanBase].mutCounts[mName] = (unequippedGroups[cleanBase].mutCounts[mName] or 0) + 1

            table.insert(unequippedGroups[cleanBase].uids, uid)
            table.insert(unequippedGroups[cleanBase].pets, {
                uid = uid,
                species = cleanBase,
                baseSpecies = cleanBase,
                rawSpecies = pet.RawSpecies or pet.BaseSpecies or pet.Species or cleanBase,
                displayName = pet.DisplayName or cleanBase,
                mutation = pet.Mutation or "",
                weightNum = pet._weightNum or 0,
                weight = pet._weight or "-- kg",
                earn = (pet._earn and pet._earn ~= "--/s" and pet._earn ~= "") and pet._earn or unequippedGroups[cleanBase].earn or "+$0/s",
                price = (pet._price and pet._price ~= "") and pet._price or unequippedGroups[cleanBase].price or "",
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
    local rfEject    = getNetRemote("RF/Fusery/EjectPet")

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
        if rfEject then
            pcall(function() rfEject:InvokeServer() end)
        end
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

            -- Auto-pick 3 compatible pets:
            -- 1. Try to find 3 pets matching exact raw species + mutation
            local exactBuckets = {}
            for _, p in ipairs(item.pets or {}) do
                local k = (p.mutation or "Normal") .. "::" .. (p.rawSpecies or item.baseSpecies or "")
                exactBuckets[k] = exactBuckets[k] or {}
                table.insert(exactBuckets[k], p.uid)
            end
            for _, bUids in pairs(exactBuckets) do
                if #bUids >= 3 then
                    return callFuseSpecificPets(species, { bUids[1], bUids[2], bUids[3] })
                end
            end

            -- 2. Try to find 3 pets matching exact mutation
            local mutBuckets = {}
            for _, p in ipairs(item.pets or {}) do
                local k = p.mutation or "Normal"
                mutBuckets[k] = mutBuckets[k] or {}
                table.insert(mutBuckets[k], p.uid)
            end
            for _, bUids in pairs(mutBuckets) do
                if #bUids >= 3 then
                    return callFuseSpecificPets(species, { bUids[1], bUids[2], bUids[3] })
                end
            end

            -- 3. Fallback if not exactly 3 checked: use the first 3
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
local cardInv = createAutoCard("📦 Inventory Overview", 58)

invPetsLabel = Instance.new("TextLabel")
invPetsLabel.Size = UDim2.new(1, -38, 0, 16); invPetsLabel.Position = UDim2.new(0, 8, 0, 20)
invPetsLabel.BackgroundTransparency = 1
invPetsLabel.Text = "🐾 Total Pets: 0   (0 Free, 0 Equipped)"
invPetsLabel.TextColor3 = Color3.fromRGB(220, 235, 255)
invPetsLabel.TextSize = 10; invPetsLabel.Font = Enum.Font.GothamBold
invPetsLabel.TextXAlignment = Enum.TextXAlignment.Left; invPetsLabel.Parent = cardInv

invEggsLabel = Instance.new("TextLabel")
invEggsLabel.Size = UDim2.new(1, -38, 0, 16); invEggsLabel.Position = UDim2.new(0, 8, 0, 36)
invEggsLabel.BackgroundTransparency = 1
invEggsLabel.Text = "🥚 Total Eggs: 0 in inventory"
invEggsLabel.TextColor3 = Color3.fromRGB(180, 240, 200)
invEggsLabel.TextSize = 10; invEggsLabel.Font = Enum.Font.GothamBold
invEggsLabel.TextXAlignment = Enum.TextXAlignment.Left; invEggsLabel.Parent = cardInv

local refreshInvBtn = Instance.new("TextButton")
refreshInvBtn.Size = UDim2.new(0, 24, 0, 24); refreshInvBtn.Position = UDim2.new(1, -30, 0, 22)
refreshInvBtn.BackgroundColor3 = Color3.fromRGB(42, 52, 75); refreshInvBtn.Text = "🔄"
refreshInvBtn.TextColor3 = Color3.new(1, 1, 1); refreshInvBtn.TextSize = 11
refreshInvBtn.Font = Enum.Font.GothamBold; refreshInvBtn.Parent = cardInv
Instance.new("UICorner", refreshInvBtn).CornerRadius = UDim.new(0, 5)

-- CARD 2: FUSERY CANDIDATES (Count >= 3)
local cardFuse = createAutoCard("🧪 Fusery Candidates (Select 3 to Fuse)", 290)

fuseHeaderBadge = Instance.new("TextLabel")
fuseHeaderBadge.Size = UDim2.new(0, 100, 0, 18); fuseHeaderBadge.Position = UDim2.new(1, -132, 0, 3)
fuseHeaderBadge.BackgroundColor3 = Color3.fromRGB(36, 44, 62)
fuseHeaderBadge.Text = "0 eligible"
fuseHeaderBadge.TextColor3 = Color3.fromRGB(160, 210, 255)
fuseHeaderBadge.TextSize = 10; fuseHeaderBadge.Font = Enum.Font.GothamBold
fuseHeaderBadge.Parent = cardFuse
Instance.new("UICorner", fuseHeaderBadge).CornerRadius = UDim.new(0, 4)

local refreshFuseListBtn = Instance.new("TextButton")
refreshFuseListBtn.Size = UDim2.new(0, 22, 0, 18); refreshFuseListBtn.Position = UDim2.new(1, -28, 0, 3)
refreshFuseListBtn.BackgroundColor3 = Color3.fromRGB(42, 52, 75); refreshFuseListBtn.Text = "🔄"
refreshFuseListBtn.TextColor3 = Color3.new(1, 1, 1); refreshFuseListBtn.TextSize = 10
refreshFuseListBtn.Font = Enum.Font.GothamBold; refreshFuseListBtn.Parent = cardFuse
Instance.new("UICorner", refreshFuseListBtn).CornerRadius = UDim.new(0, 4)

-- Scrolling Container for Candidate Pets
local fuseScroll = Instance.new("ScrollingFrame")
fuseScroll.Size = UDim2.new(1, -10, 1, -28); fuseScroll.Position = UDim2.new(0, 5, 0, 24)
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
local cardLog = createAutoCard("📜 Fusery Activity Log", 82)

local clearLogBtn = Instance.new("TextButton")
clearLogBtn.Size = UDim2.new(0, 42, 0, 18); clearLogBtn.Position = UDim2.new(1, -48, 0, 3)
clearLogBtn.BackgroundColor3 = Color3.fromRGB(50, 58, 80); clearLogBtn.Text = "Clear"
clearLogBtn.TextColor3 = Color3.fromRGB(200, 215, 240); clearLogBtn.TextSize = 9
clearLogBtn.Font = Enum.Font.GothamBold; clearLogBtn.Parent = cardLog
Instance.new("UICorner", clearLogBtn).CornerRadius = UDim.new(0, 4)

logScroll = Instance.new("ScrollingFrame")
logScroll.Size = UDim2.new(1, -12, 0, 54); logScroll.Position = UDim2.new(0, 6, 0, 24)
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
local fuseCandidatesLoaded = false

updateFuseSelectorUI = function(forceReload)
    if not fuseCandidatesLoaded and not forceReload then
        for _, child in ipairs(fuseScroll:GetChildren()) do
            if child:IsA("Frame") or child:IsA("TextLabel") or child:IsA("TextButton") then
                child:Destroy()
            end
        end
        if fuseHeaderBadge then
            fuseHeaderBadge.Text = "Not Loaded"
            fuseHeaderBadge.TextColor3 = Color3.fromRGB(160, 180, 210)
        end
        local promptFrame = Instance.new("Frame")
        promptFrame.Size = UDim2.new(1, -4, 0, 76)
        promptFrame.BackgroundColor3 = Color3.fromRGB(22, 26, 38)
        promptFrame.BorderSizePixel = 0
        promptFrame.Parent = fuseScroll
        Instance.new("UICorner", promptFrame).CornerRadius = UDim.new(0, 6)
        local pfStr = Instance.new("UIStroke", promptFrame)
        pfStr.Color = Color3.fromRGB(45, 55, 80); pfStr.Thickness = 1

        local promptText = Instance.new("TextLabel")
        promptText.Size = UDim2.new(1, -16, 0, 20); promptText.Position = UDim2.new(0, 8, 0, 10)
        promptText.BackgroundTransparency = 1
        promptText.Text = "🧪 Fusery Candidates (Manual Load Mode)"
        promptText.TextColor3 = Color3.fromRGB(210, 225, 245)
        promptText.TextSize = 11; promptText.Font = Enum.Font.GothamBold
        promptText.Parent = promptFrame

        local loadBtn = Instance.new("TextButton")
        loadBtn.Size = UDim2.new(0, 170, 0, 26); loadBtn.Position = UDim2.new(0.5, -85, 0, 36)
        loadBtn.BackgroundColor3 = Color3.fromRGB(40, 120, 80)
        loadBtn.Text = "🔄 Load Candidates"
        loadBtn.TextColor3 = Color3.new(1, 1, 1); loadBtn.TextSize = 11
        loadBtn.Font = Enum.Font.GothamBold
        loadBtn.Parent = promptFrame
        Instance.new("UICorner", loadBtn).CornerRadius = UDim.new(0, 5)

        loadBtn.MouseButton1Click:Connect(function()
            fuseCandidatesLoaded = true
            updateFuseSelectorUI(true)
        end)
        return
    end

    fuseCandidatesLoaded = true
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
        groupHeader.Size = UDim2.new(1, 0, 0, 30)
        groupHeader.BackgroundColor3 = Color3.fromRGB(28, 36, 52)
        groupHeader.BorderSizePixel = 0
        groupHeader.LayoutOrder = 1
        groupHeader.Parent = groupCard
        Instance.new("UICorner", groupHeader).CornerRadius = UDim.new(0, 6)

        -- Left Rarity Stripe
        local strip = Instance.new("Frame")
        strip.Size = UDim2.new(0, 4, 1, -6); strip.Position = UDim2.new(0, 5, 0, 3)
        strip.BackgroundColor3 = rarCol; strip.BorderSizePixel = 0
        strip.Parent = groupHeader
        Instance.new("UICorner", strip).CornerRadius = UDim.new(0, 2)

        local mutSummaryList = {}
        for mName, mCnt in pairs(g.mutCounts or {}) do
            if mName ~= "" and mName ~= "Normal" then
                table.insert(mutSummaryList, string.format("%d %s", mCnt, mName))
            end
        end
        local mutSuffix = (#mutSummaryList > 0) and (" (" .. table.concat(mutSummaryList, ", ") .. ")") or ""

        -- Species Title + Count Badge (Clean: species, rarity, and copy count - no duplicate price on header)
        local titleLabel = Instance.new("TextLabel")
        titleLabel.Size = UDim2.new(1, -150, 1, 0); titleLabel.Position = UDim2.new(0, 14, 0, 0)
        titleLabel.BackgroundTransparency = 1
        titleLabel.Text = string.format("%s  [%s]  •  %d copies%s", g.baseSpecies, g.rarity, g.count, mutSuffix)
        titleLabel.TextColor3 = Color3.fromRGB(235, 245, 255)
        titleLabel.TextSize = 10.5; titleLabel.Font = Enum.Font.GothamBold
        titleLabel.TextXAlignment = Enum.TextXAlignment.Left
        titleLabel.TextTruncate = Enum.TextTruncate.AtEnd
        titleLabel.Parent = groupHeader

        -- Auto 3 (Lightest) Button
        local auto3Btn = Instance.new("TextButton")
        auto3Btn.Size = UDim2.new(0, 50, 0, 20); auto3Btn.Position = UDim2.new(1, -145, 0.5, -10)
        auto3Btn.BackgroundColor3 = Color3.fromRGB(40, 50, 72)
        auto3Btn.Text = "Auto 3"
        auto3Btn.TextColor3 = Color3.fromRGB(190, 220, 255)
        auto3Btn.TextSize = 9.5; auto3Btn.Font = Enum.Font.GothamBold
        auto3Btn.Parent = groupHeader
        Instance.new("UICorner", auto3Btn).CornerRadius = UDim.new(0, 4)

        -- Fuse Button
        local fuseGroupBtn = Instance.new("TextButton")
        fuseGroupBtn.Size = UDim2.new(0, 90, 0, 20); fuseGroupBtn.Position = UDim2.new(1, -92, 0.5, -10)
        fuseGroupBtn.TextSize = 9.5; fuseGroupBtn.Font = Enum.Font.GothamBold
        fuseGroupBtn.Parent = groupHeader
        Instance.new("UICorner", fuseGroupBtn).CornerRadius = UDim.new(0, 4)
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
            local petRow = Instance.new("Frame")
            petRow.Size = UDim2.new(1, 0, 0, 24)
            petRow.BorderSizePixel = 0
            petRow.LayoutOrder = idx
            petRow.Parent = rowsContainer
            Instance.new("UICorner", petRow).CornerRadius = UDim.new(0, 5)
            local rowStroke = Instance.new("UIStroke", petRow)

            -- Pet details label (index, earn/s, mutation badge, weight - only weight and earn/s, no parenthesis price)
            local rowLabel = Instance.new("TextLabel")
            rowLabel.Size = UDim2.new(1, -32, 1, 0); rowLabel.Position = UDim2.new(0, 6, 0, 0)
            rowLabel.BackgroundTransparency = 1
            local mutTag = (pet.mutation and pet.mutation ~= "" and pet.mutation ~= "Normal") and ("[" .. pet.mutation .. "] ") or ""
            local earnTag = (pet.earn and pet.earn ~= "--/s" and pet.earn ~= "") and pet.earn or "+$0/s"
            local detailText = string.format("#%d  %s  %s⚖️ %s", idx, earnTag, mutTag, pet.weight)
            rowLabel.Text = detailText
            rowLabel.TextSize = 9.5; rowLabel.Font = Enum.Font.Gotham
            rowLabel.TextXAlignment = Enum.TextXAlignment.Left
            rowLabel.TextTruncate = Enum.TextTruncate.AtEnd
            rowLabel.Parent = petRow

            -- Checkbox Button
            local chkBtn = Instance.new("TextButton")
            chkBtn.Size = UDim2.new(0, 18, 0, 18); chkBtn.Position = UDim2.new(1, -24, 0.5, -9)
            chkBtn.TextSize = 11; chkBtn.Font = Enum.Font.GothamBold
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
                    if pet.mutation == "Silver" then
                        rowLabel.TextColor3 = Color3.fromRGB(180, 215, 245)
                    elseif pet.mutation == "Golden" or pet.mutation == "Gold" then
                        rowLabel.TextColor3 = Color3.fromRGB(255, 225, 120)
                    elseif pet.mutation == "Rainbow" then
                        rowLabel.TextColor3 = Color3.fromRGB(235, 160, 255)
                    else
                        rowLabel.TextColor3 = Color3.fromRGB(170, 195, 230)
                    end
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
    fuseCandidatesLoaded = true
    updateFuseSelectorUI(true)
    logAuto("🔄 Candidate list refreshed", Color3.fromRGB(150, 220, 255))
end)

refreshInvBtn.MouseButton1Click:Connect(function()
    fuseCandidatesLoaded = true
    updateFuseSelectorUI(true)
    logAuto("🔄 Inventory overview refreshed", Color3.fromRGB(150, 220, 255))
end)

refreshPetCards = function()
    if fuseCandidatesLoaded then
        updateFuseSelectorUI(true)
    end
end

-- Background Automation Loop
task.spawn(function()
    logAuto("Fusery candidate engine ready (Manual load mode)")
    if typeof(updateFuseSelectorUI) == "function" then
        updateFuseSelectorUI(false)
    end
    while not eggScannerStop and screenGui.Parent do
        if autoFuseEnabled and fuseCandidatesLoaded then
            callBeginFuse()
        end
        task.wait(2.5)
    end
end)


end

-- ==================================================
-- TAB 3 BUILDER: DR. SCRAMBLE TRADE-IN SUITE
-- ==================================================
function X.buildScrambleTabUI()
    local tabScrambleLayout = Instance.new("UIListLayout")
    tabScrambleLayout.Padding = UDim.new(0, 8)
    tabScrambleLayout.SortOrder = Enum.SortOrder.LayoutOrder
    tabScrambleLayout.Parent = tabScramble

    local tabScramblePad = Instance.new("UIPadding")
    tabScramblePad.PaddingTop = UDim.new(0, 6)
    tabScramblePad.PaddingBottom = UDim.new(0, 10)
    tabScramblePad.PaddingLeft = UDim.new(0, 8)
    tabScramblePad.PaddingRight = UDim.new(0, 8)
    tabScramblePad.Parent = tabScramble

    -- ========================================================================
    -- 1. UTILITIES & NETWORKING (reused from X)
    -- ========================================================================

    local getNetRemote     = X.getNetRemote
    local formatCommas     = X.formatCommas
    local formatPetWeight  = X.formatPetWeight

    local function dumpTbl(tbl, maxDepth, indent)
        maxDepth = maxDepth or 2
        indent = indent or "  "
        if type(tbl) ~= "table" then return tostring(tbl) end
        if maxDepth <= 0 then return "{...}" end
        local lines = {}
        local count = 0
        for k, v in pairs(tbl) do
            count = count + 1
            if count > 20 then
                table.insert(lines, indent .. "... (truncated)")
                break
            end
            if type(v) == "table" then
                table.insert(lines, indent .. tostring(k) .. " = " .. dumpTbl(v, maxDepth - 1, indent .. "  "))
            else
                table.insert(lines, indent .. tostring(k) .. " = " .. tostring(v))
            end
        end
        return "{\n" .. table.concat(lines, "\n") .. "\n" .. string.sub(indent, 1, math.max(0, #indent - 2)) .. "}"
    end

    -- ========================================================================
    -- 2. SPECIES NORMALIZATION & EXACT ALIASING
    -- ========================================================================

    local EGG_SPECIES_ALIASES = X.EGG_SPECIES_ALIASES
    local CATEGORY_TO_DISPLAY = X.CATEGORY_TO_DISPLAY
    local normalizeEggSpecies = X.normalizeEggSpecies
    local matchEggSpecies     = X.matchEggSpecies
    local getDisplayEggName   = X.getDisplayEggName

    -- ========================================================================
    -- 3. STATE & DATA STORES
    -- ========================================================================

    local scrambleRequirements = {} -- { { slot="1", species="Galaxy Gecko", rawName="Galaxy Gecko", count=1 }, ... }
    local allInventoryEggs     = {} -- all unplaced eggs found in player satchel
    local isAutoTradeEnabled   = (X.autoScrambleTrade ~= false)
    local isTradingIn          = false
    local serverExpiresAt      = nil
    local scrambleBannerName   = "Dr. Scramble"
    local lastTradeAttempt     = 0
    local lastInventoryScan    = 0

    local rfAskState   = getNetRemote("RF/ScrambleTradeIn/AskState")
    local rfTradeIn    = getNetRemote("RF/ScrambleTradeIn/AskTradeIn") or getNetRemote("RF/ScrambleTradeIn/TradeIn")
    local rfReveal     = getNetRemote("RF/ScrambleTradeIn/AskFinishReveal")
    local reRotated    = getNetRemote("RE/ScrambleTradeIn/BannerRotated")
    local rfProfile    = getNetRemote("RF/ProfileMirror/FetchProfile")

    -- Forward declarations
    local updateUI
    local queryScrambleState
    local scanInventoryEggs
    local executeTradeIn
    local checkAndAutoTrade

    -- Helper to make section cards
    local function createCard(titleText, defaultHeight, layoutOrder)
        local card = Instance.new("Frame")
        card.Size = UDim2.new(1, 0, 0, defaultHeight)
        card.BackgroundColor3 = Color3.fromRGB(20, 23, 34)
        card.BorderSizePixel = 0
        card.LayoutOrder = layoutOrder
        card.Parent = tabScramble
        Instance.new("UICorner", card).CornerRadius = UDim.new(0, 7)
        local cStroke = Instance.new("UIStroke", card)
        cStroke.Color = Color3.fromRGB(42, 48, 70); cStroke.Thickness = 1

        local hFrame = Instance.new("Frame")
        hFrame.Size = UDim2.new(1, 0, 0, 24); hFrame.BackgroundColor3 = Color3.fromRGB(28, 32, 48)
        hFrame.BorderSizePixel = 0; hFrame.Parent = card
        Instance.new("UICorner", hFrame).CornerRadius = UDim.new(0, 7)

        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(1, -106, 1, 0); lbl.Position = UDim2.new(0, 8, 0, 0)
        lbl.BackgroundTransparency = 1; lbl.Text = titleText
        lbl.TextColor3 = Color3.fromRGB(215, 230, 255); lbl.Font = Enum.Font.GothamBold; lbl.TextSize = 10
        lbl.TextXAlignment = Enum.TextXAlignment.Left; lbl.Parent = hFrame

        return card
    end

    -- ========================================================================
    -- 4. CONTROLS BAR (Row 0: Compact 2-Row Layout)
    -- ========================================================================

    local controlsBar = Instance.new("Frame")
    controlsBar.Size = UDim2.new(1, 0, 0, 56)
    controlsBar.BackgroundTransparency = 1
    controlsBar.LayoutOrder = 0
    controlsBar.Parent = tabScramble

    -- Row 1: Rotation Countdown Timer (left) + Manual Refresh Button (right)
    local timerBadge = Instance.new("TextLabel")
    timerBadge.Size = UDim2.new(1, -34, 0, 26); timerBadge.Position = UDim2.new(0, 0, 0, 0)
    timerBadge.BackgroundColor3 = Color3.fromRGB(25, 29, 44); timerBadge.BorderSizePixel = 0
    timerBadge.Text = "⏳ Syncing timer..."
    timerBadge.TextColor3 = Color3.fromRGB(255, 215, 120); timerBadge.Font = Enum.Font.GothamBold; timerBadge.TextSize = 10
    timerBadge.Parent = controlsBar
    Instance.new("UICorner", timerBadge).CornerRadius = UDim.new(0, 6)
    local tbStroke = Instance.new("UIStroke", timerBadge)
    tbStroke.Color = Color3.fromRGB(60, 70, 100); tbStroke.Thickness = 1

    local refreshBtn = Instance.new("TextButton")
    refreshBtn.Size = UDim2.new(0, 28, 0, 26); refreshBtn.Position = UDim2.new(1, -28, 0, 0)
    refreshBtn.BackgroundColor3 = Color3.fromRGB(38, 55, 85)
    refreshBtn.Text = "🔄"; refreshBtn.TextColor3 = Color3.new(1, 1, 1)
    refreshBtn.Font = Enum.Font.GothamBold; refreshBtn.TextSize = 12
    refreshBtn.Parent = controlsBar
    Instance.new("UICorner", refreshBtn).CornerRadius = UDim.new(0, 6)

    -- Row 2: Priority Toggle + Auto-Trade Toggle + Trade Action Button
    local priorityToggleBtn = Instance.new("TextButton")
    priorityToggleBtn.Size = UDim2.new(0.32, -3, 0, 26); priorityToggleBtn.Position = UDim2.new(0, 0, 0, 30)
    priorityToggleBtn.BackgroundColor3 = X.prioritizeScrambleInAutoFarm and Color3.fromRGB(35, 80, 140) or Color3.fromRGB(45, 48, 60)
    priorityToggleBtn.Text = X.prioritizeScrambleInAutoFarm and "[ON] Priority" or "[OFF] Priority"
    priorityToggleBtn.TextColor3 = X.prioritizeScrambleInAutoFarm and Color3.fromRGB(180, 220, 255) or Color3.fromRGB(160, 165, 180)
    priorityToggleBtn.Font = Enum.Font.GothamBold; priorityToggleBtn.TextSize = 9.5
    priorityToggleBtn.Parent = controlsBar
    Instance.new("UICorner", priorityToggleBtn).CornerRadius = UDim.new(0, 6)

    local autoTradeToggleBtn = Instance.new("TextButton")
    autoTradeToggleBtn.Size = UDim2.new(0.34, -4, 0, 26); autoTradeToggleBtn.Position = UDim2.new(0.32, 2, 0, 30)
    autoTradeToggleBtn.BackgroundColor3 = isAutoTradeEnabled and Color3.fromRGB(35, 115, 70) or Color3.fromRGB(55, 58, 70)
    autoTradeToggleBtn.Text = isAutoTradeEnabled and "[ON] Auto-Trade" or "[OFF] Auto-Trade"
    autoTradeToggleBtn.TextColor3 = isAutoTradeEnabled and Color3.fromRGB(160, 255, 190) or Color3.fromRGB(180, 185, 200)
    autoTradeToggleBtn.Font = Enum.Font.GothamBold; autoTradeToggleBtn.TextSize = 9.5
    autoTradeToggleBtn.Parent = controlsBar
    Instance.new("UICorner", autoTradeToggleBtn).CornerRadius = UDim.new(0, 6)

    local manualTradeBtn = Instance.new("TextButton")
    manualTradeBtn.Size = UDim2.new(0.34, -3, 0, 26); manualTradeBtn.Position = UDim2.new(0.66, 3, 0, 30)
    manualTradeBtn.BackgroundColor3 = Color3.fromRGB(50, 48, 65)
    manualTradeBtn.Text = "⚡ Trade (0/3)"
    manualTradeBtn.TextColor3 = Color3.fromRGB(160, 165, 185)
    manualTradeBtn.Font = Enum.Font.GothamBold; manualTradeBtn.TextSize = 9.5
    manualTradeBtn.Parent = controlsBar
    Instance.new("UICorner", manualTradeBtn).CornerRadius = UDim.new(0, 6)
    local mtStroke = Instance.new("UIStroke", manualTradeBtn)
    mtStroke.Color = Color3.fromRGB(65, 60, 85); mtStroke.Thickness = 1

    -- ========================================================================
    -- 5. CARDS (Requirements, Telemetry Log)
    -- ========================================================================

    -- CARD 1: ACTIVE RECIPE REQUIREMENTS
    local cardReqs = createCard("📋 RECIPE REQUIREMENTS", 32, 1)
    cardReqs.AutomaticSize = Enum.AutomaticSize.Y
    local reqsContainer = Instance.new("Frame")
    reqsContainer.Size = UDim2.new(1, -12, 0, 0); reqsContainer.Position = UDim2.new(0, 6, 0, 26)
    reqsContainer.BackgroundTransparency = 1; reqsContainer.AutomaticSize = Enum.AutomaticSize.Y
    reqsContainer.Parent = cardReqs
    local reqsLayout = Instance.new("UIListLayout")
    reqsLayout.Padding = UDim.new(0, 4)
    reqsLayout.SortOrder = Enum.SortOrder.LayoutOrder
    reqsLayout.Parent = reqsContainer
    local reqsPad = Instance.new("UIPadding")
    reqsPad.PaddingBottom = UDim.new(0, 6)
    reqsPad.Parent = reqsContainer

    -- CARD 2: ACTIVITY & LOG TERMINAL
    local cardLog = createCard("📜 LIVE TELEMETRY & LOG", 200, 2)

    local copyLogBtn = Instance.new("TextButton")
    copyLogBtn.Size = UDim2.new(0, 44, 0, 18); copyLogBtn.Position = UDim2.new(1, -98, 0, 3)
    copyLogBtn.BackgroundColor3 = Color3.fromRGB(45, 75, 115)
    copyLogBtn.Text = "Copy"; copyLogBtn.TextColor3 = Color3.fromRGB(220, 240, 255)
    copyLogBtn.Font = Enum.Font.GothamBold; copyLogBtn.TextSize = 9; copyLogBtn.Parent = cardLog
    Instance.new("UICorner", copyLogBtn).CornerRadius = UDim.new(0, 4)

    local clearLogBtn = Instance.new("TextButton")
    clearLogBtn.Size = UDim2.new(0, 44, 0, 18); clearLogBtn.Position = UDim2.new(1, -50, 0, 3)
    clearLogBtn.BackgroundColor3 = Color3.fromRGB(55, 60, 75)
    clearLogBtn.Text = "Clear"; clearLogBtn.TextColor3 = Color3.fromRGB(200, 215, 235)
    clearLogBtn.Font = Enum.Font.GothamBold; clearLogBtn.TextSize = 9; clearLogBtn.Parent = cardLog
    Instance.new("UICorner", clearLogBtn).CornerRadius = UDim.new(0, 4)

    local logScroll = Instance.new("ScrollingFrame")
    logScroll.Size = UDim2.new(1, -12, 1, -30); logScroll.Position = UDim2.new(0, 6, 0, 26)
    logScroll.BackgroundColor3 = Color3.fromRGB(10, 11, 16); logScroll.BorderSizePixel = 0
    logScroll.ScrollBarThickness = 4; logScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    logScroll.CanvasSize = UDim2.new(0, 0, 0, 0); logScroll.Parent = cardLog
    Instance.new("UICorner", logScroll).CornerRadius = UDim.new(0, 5)

    local logTextLabel = Instance.new("TextLabel")
    logTextLabel.Size = UDim2.new(1, -8, 0, 0); logTextLabel.Position = UDim2.new(0, 4, 0, 2)
    logTextLabel.BackgroundTransparency = 1
    logTextLabel.TextColor3 = Color3.fromRGB(195, 215, 245)
    logTextLabel.Font = Enum.Font.Code; logTextLabel.TextSize = 10
    logTextLabel.TextXAlignment = Enum.TextXAlignment.Left; logTextLabel.TextYAlignment = Enum.TextYAlignment.Top
    logTextLabel.AutomaticSize = Enum.AutomaticSize.Y; logTextLabel.Parent = logScroll

    local logEntries = {}
    local MAX_LOGS = 60
    local logUpdateScheduled = false

    local function logMsg(msg, color)
        local ts = os.date("%H:%M:%S")
        local line = ("[%s] %s"):format(ts, tostring(msg))
        print("[ScrambleAutoTrade] " .. line)
        table.insert(logEntries, line)
        while #logEntries > MAX_LOGS do table.remove(logEntries, 1) end
        if not logUpdateScheduled then
            logUpdateScheduled = true
            task.defer(function()
                logUpdateScheduled = false
                if logTextLabel and logTextLabel.Parent then
                    logTextLabel.Text = table.concat(logEntries, "\n")
                    pcall(function() logScroll.CanvasPosition = Vector2.new(0, 99999) end)
                end
            end)
        end
    end
    logScramble = logMsg

    copyLogBtn.MouseButton1Click:Connect(function()
        local full = table.concat(logEntries, "\n")
        local ok = X.copyToClipboard and X.copyToClipboard(full)
        if ok then
            copyLogBtn.Text = "✓ Copied"
            logMsg("📋 Activity log copied to system clipboard!", Color3.fromRGB(140, 255, 180))
            task.delay(1.5, function() copyLogBtn.Text = "Copy" end)
        else
            logMsg("ℹ️ Clipboard not supported. Printed to developer console (F9).", Color3.fromRGB(255, 200, 100))
        end
    end)

    clearLogBtn.MouseButton1Click:Connect(function()
        logEntries = {}
        logTextLabel.Text = "[Log cleared]"
    end)

    priorityToggleBtn.MouseButton1Click:Connect(function()
        X.prioritizeScrambleInAutoFarm = not X.prioritizeScrambleInAutoFarm
        if X.prioritizeScrambleInAutoFarm then
            priorityToggleBtn.BackgroundColor3 = Color3.fromRGB(35, 80, 140)
            priorityToggleBtn.Text = "[ON] Priority"
            priorityToggleBtn.TextColor3 = Color3.fromRGB(180, 220, 255)
            logMsg("✓ Scramble AutoFarm Priority: ENABLED", Color3.fromRGB(140, 220, 255))
        else
            priorityToggleBtn.BackgroundColor3 = Color3.fromRGB(45, 48, 60)
            priorityToggleBtn.Text = "[OFF] Priority"
            priorityToggleBtn.TextColor3 = Color3.fromRGB(160, 165, 180)
            logMsg("ℹ️ Scramble AutoFarm Priority: DISABLED", Color3.fromRGB(180, 185, 200))
        end
        X.listDirty = true
    end)

    autoTradeToggleBtn.MouseButton1Click:Connect(function()
        isAutoTradeEnabled = not isAutoTradeEnabled
        X.autoScrambleTrade = isAutoTradeEnabled
        if isAutoTradeEnabled then
            autoTradeToggleBtn.BackgroundColor3 = Color3.fromRGB(35, 115, 70)
            autoTradeToggleBtn.Text = "[ON] Auto-Trade"
            autoTradeToggleBtn.TextColor3 = Color3.fromRGB(160, 255, 190)
            logMsg("✓ Auto-Trade: ENABLED (Will auto-trade immediately when 3/3 matching eggs are in inventory)", Color3.fromRGB(140, 255, 180))
            task.defer(function()
                if not weAreCarrying then
                    checkAndAutoTrade("ToggleOn")
                end
            end)
        else
            autoTradeToggleBtn.BackgroundColor3 = Color3.fromRGB(55, 58, 70)
            autoTradeToggleBtn.Text = "[OFF] Auto-Trade"
            autoTradeToggleBtn.TextColor3 = Color3.fromRGB(180, 185, 200)
            logMsg("ℹ️ Auto-Trade: DISABLED (Manual trade button available)", Color3.fromRGB(200, 215, 235))
        end
        X.listDirty = true
    end)

    refreshBtn.MouseButton1Click:Connect(function()
        if refreshBtn.Text == "⏳" then return end
        refreshBtn.Text = "⏳"
        logMsg("🔄 Manual refresh requested...", Color3.fromRGB(180, 210, 255))
        task.spawn(function()
            queryScrambleState()
            scanInventoryEggs(true)
            updateUI()
            if not weAreCarrying then
                checkAndAutoTrade("ManualRefresh")
            end
            refreshBtn.Text = "🔄"
        end)
    end)

    manualTradeBtn.MouseButton1Click:Connect(function()
        executeTradeIn(false)
    end)

    -- ========================================================================
    -- 6. AUTHORITATIVE INVENTORY SCANNER (EGGS ONLY, STRICTLY NO PETS!)
    -- ========================================================================

    scanInventoryEggs = function(force)
        -- Cache check: prevent redundant FetchProfile spam within 3.0 seconds
        if not force and (os.clock() - lastInventoryScan) < 3.0 and X.scrambleInventoryLoaded then
            return allInventoryEggs
        end
        lastInventoryScan = os.clock()

        local eggs = {}
        local seenUids = {}

        -- 1. ProfileMirror EggInventory (Ground truth for unplaced eggs in satchel)
        if not rfProfile then rfProfile = getNetRemote("RF/ProfileMirror/FetchProfile") end
        if rfProfile then
            local okP, prof = pcall(function() return rfProfile:InvokeServer(LocalPlayer) end)
            if not okP or type(prof) ~= "table" or type(prof.EggInventory) ~= "table" then
                okP, prof = pcall(function() return rfProfile:InvokeServer() end)
            end

            if okP and type(prof) == "table" and type(prof.EggInventory) == "table" then
                for eggUid, eggData in pairs(prof.EggInventory) do
                    local uidStr = tostring(eggUid)
                    -- STRICT FILTER: Only unplaced eggs (Placement == nil or Placement == false or Placement == "")
                    if not seenUids[uidStr] and type(eggData) == "table" and (eggData.Placement == nil or eggData.Placement == false or eggData.Placement == "") then
                        seenUids[uidStr] = true
                        local cat = tostring(eggData.AssetCategory or eggData.Category or eggData.Species or eggData.Name or eggData.DisplayName or eggData.EggType or "Egg")
                        local disp = getDisplayEggName(cat)
                        local wStr, wNum = formatPetWeight(eggData.Weight or 0, eggData.AssetScale or 1)
                        table.insert(eggs, {
                            uid = uidStr,
                            species = cat,
                            category = cat,
                            displayName = disp,
                            weightStr = wStr,
                            weightNum = wNum,
                            source = "Satchel"
                        })
                    end
                end
            end
        end

        -- 2. DrScrambleTradeIn In-Game GUI inspection (PlayerGui)
        pcall(function()
            local pg = LocalPlayer:FindFirstChild("PlayerGui")
            local scrGui = pg and (pg:FindFirstChild("DrScrambleTradeIn") or pg:FindFirstChild("DrScrambleTradeInNEW"))
            local invFrame = scrGui and scrGui:FindFirstChild("DrScrambleTradeInInventory", true)
            local scroll = invFrame and invFrame:FindFirstChild("ScrollingFrame", true)
            if scroll then
                for _, btn in ipairs(scroll:GetChildren()) do
                    if (btn:IsA("ImageButton") or btn:IsA("TextButton")) and btn.Name:match("^Egg_(%x+)") then
                        local rawUid = btn.Name:gsub("^Egg_", "")
                        if rawUid and #rawUid == 32 and not seenUids[rawUid] then
                            local spName = nil
                            for _, d in ipairs(btn:GetDescendants()) do
                                if d:IsA("TextLabel") and d.Text ~= "" and d.Text ~= "Unplaced" and not d.Text:match("^%b()") then
                                    local low = d.Text:lower()
                                    if not low:match("select") and not low:match("pet name") then
                                        spName = d.Text
                                        break
                                    end
                                end
                            end
                            if spName then
                                seenUids[rawUid] = true
                                local cleanSp = spName:gsub("%s*Egg%s*$", "")
                                table.insert(eggs, {
                                    uid = rawUid,
                                    species = cleanSp,
                                    category = cleanSp,
                                    displayName = spName,
                                    weightStr = "0 KG",
                                    weightNum = 0,
                                    source = "TradeGui"
                                })
                            end
                        end
                    end
                end
            end
        end)

        -- 3. STRICT PHYSICAL TOOL INSPECTION (ONLY actual Egg tools, NEVER pets!)
        local function checkTool(t, src)
            if not t or not t:IsA("Tool") then return end
            local attrs = t:GetAttributes() or {}
            if not X.isEggTool(t, attrs) then return end

            local dName = tostring(attrs.DisplayName or t.Name)
            local cat = tostring(attrs.Category or "")

            local rawUid = attrs.UID or attrs.Uid or attrs.Id or attrs.EggUID
            if not rawUid then
                local chUid = t:FindFirstChild("UID") or t:FindFirstChild("EggUID")
                if chUid and chUid:IsA("ValueBase") then rawUid = chUid.Value end
            end

            local uidStr = rawUid and tostring(rawUid) or nil
            if uidStr and #uidStr == 32 and not seenUids[uidStr] then
                seenUids[uidStr] = true
                local wStr, wNum = formatPetWeight(attrs.Weight, attrs.Scale)
                local cleanSp = X.cleanSpeciesName(dName)
                table.insert(eggs, {
                    uid = uidStr,
                    species = cleanSp,
                    category = cat ~= "" and cat or cleanSp,
                    displayName = dName,
                    weightStr = wStr,
                    weightNum = wNum,
                    source = src
                })
            end
        end

        local bp = LocalPlayer:FindFirstChild("Backpack")
        if bp then for _, t in ipairs(bp:GetChildren()) do checkTool(t, "Backpack") end end
        if LocalPlayer.Character then for _, t in ipairs(LocalPlayer.Character:GetChildren()) do checkTool(t, "Character") end end

        -- Sort lightest to heaviest
        table.sort(eggs, function(a, b) return (a.weightNum or 0) < (b.weightNum or 0) end)
        allInventoryEggs = eggs
        X.ownedInventoryEggs = eggs
        X.scrambleInventoryLoaded = true
        X.listDirty = true
        return eggs
    end

    -- ========================================================================
    -- 7. SCRAMBLE STATE & REQUIREMENTS QUERY
    -- ========================================================================

    local function parseScrambleRequirements(state)
        local reqs = {}

        local function addReq(slotKey, speciesName, count)
            if not speciesName or type(speciesName) ~= "string" or speciesName == "" then return end
            local lowCheck = speciesName:lower():gsub("%s+", "")
            if lowCheck == "petname" or lowCheck == "eggname" or lowCheck == "rarity" then return end
            local clean = X.cleanSpeciesName(speciesName)
            table.insert(reqs, {
                slot = tostring(slotKey),
                species = clean,
                rawName = speciesName,
                count = tonumber(count) or 1
            })
        end

        if type(state) == "table" then
            local container = state.Requirements or state.Recipe or state.Inputs or state.Slots or state.Eggs or state.CurrentTrade or state.Trade or state.SacrificeInputs or state.Banner or state
            if type(container) == "table" then
                for k, v in pairs(container) do
                    if type(v) == "string" then
                        addReq(k, v, 1)
                    elseif type(v) == "table" then
                        local sp = v.Species or v.Egg or v.EggType or v.Name or v.Category or v.DisplayName or v.Target or v.Type or v.EggName
                        local c = v.Count or v.Amount or v.Required or v.Quantity or 1
                        if sp then addReq(k, sp, c) end
                    end
                end
            end
        end

        -- Fallback: Inspect PlayerGui DrScrambleTradeIn GUI if AskState container empty
        if #reqs == 0 then
            local pg = LocalPlayer:FindFirstChild("PlayerGui")
            local gui = pg and (pg:FindFirstChild("DrScrambleTradeIn") or pg:FindFirstChild("DrScrambleTradeInNEW"))
            local inputs = gui and gui:FindFirstChild("SacrificeInputs", true)
            if inputs then
                for idx = 1, 3 do
                    local inp = inputs:FindFirstChild("Input" .. idx) or inputs:FindFirstChild(tostring(idx))
                    if inp then
                        local spName = nil
                        local attrs = inp:GetAttributes() or {}
                        spName = attrs.Egg or attrs.Species or attrs.DisplayName or attrs.Category
                        if not spName then
                            local emptyNode = inp:FindFirstChild("Empty", true)
                            local nameLbl = emptyNode and (emptyNode:FindFirstChild("Name") or emptyNode:FindFirstChild("Title") or emptyNode:FindFirstChild("EggName"))
                            if nameLbl and nameLbl:IsA("TextLabel") and nameLbl.Text ~= "" then
                                local nTxt = nameLbl.Text:lower():gsub("%s+", "")
                                if nTxt ~= "petname" and nTxt ~= "eggname" and nTxt ~= "rarity" then
                                    spName = nameLbl.Text
                                end
                            end
                        end
                        if spName then addReq(idx, spName, 1) end
                    end
                end
            end
        end

        table.sort(reqs, function(a, b)
            local numA = tonumber(a.slot) or 99
            local numB = tonumber(b.slot) or 99
            return numA < numB
        end)

        return reqs
    end

    queryScrambleState = function()
        if not rfAskState then rfAskState = getNetRemote("RF/ScrambleTradeIn/AskState") end
        local ok, state = false, nil
        if rfAskState then
            ok, state = pcall(function() return rfAskState:InvokeServer() end)
        end

        if ok and type(state) == "table" then
            logMsg("✓ [AskState] Received active state from server", Color3.fromRGB(140, 255, 180))
            scrambleBannerName = state.BannerDisplayName or state.BannerId or "Dr. Scramble"

            -- Unclaimed PendingReward Auto-Claim
            if not rfReveal then rfReveal = getNetRemote("RF/ScrambleTradeIn/AskFinishReveal") end
            if state.PendingReward and type(state.PendingReward) == "table" and rfReveal then
                logMsg("🎁 Detected unclaimed reward from previous trade! Calling AskFinishReveal...", Color3.fromRGB(255, 215, 120))
                pcall(function() rfReveal:InvokeServer() end)
                task.wait(0.4)
                local ok2, state2 = pcall(function() return rfAskState:InvokeServer() end)
                if ok2 and type(state2) == "table" then state = state2 end
            end

            -- Calculate exact expiry timestamp
            local exp = state.ExpiresAt or state.NextRefresh or state.ResetTime or state.EndTime
            if tonumber(exp) and tonumber(exp) > os.time() then
                serverExpiresAt = tonumber(exp)
            elseif tonumber(state.SecondsUntilRotation) then
                serverExpiresAt = os.time() + math.floor(tonumber(state.SecondsUntilRotation))
            elseif tonumber(state.TimeLeft) or tonumber(state.Remaining) then
                serverExpiresAt = os.time() + (tonumber(state.TimeLeft) or tonumber(state.Remaining))
            else
                local secsIntoHour = os.time() % 3600
                serverExpiresAt = os.time() + (3600 - secsIntoHour)
            end
        else
            logMsg("⚠️ [AskState] Remote returned: " .. tostring(state) .. " (using fallback)", Color3.fromRGB(255, 180, 80))
            local secsIntoHour = os.time() % 3600
            serverExpiresAt = os.time() + (3600 - secsIntoHour)
        end

        scrambleRequirements = parseScrambleRequirements(state)
        X.scrambleRequirements = scrambleRequirements

        local reqMap = {}
        for _, req in ipairs(scrambleRequirements) do
            local n = normalizeEggSpecies(req.species)
            if n ~= "" then reqMap[n] = true end
        end
        X.scrambleRequiredSpecies = reqMap

        logMsg(string.format("📋 Loaded %d recipe requirements for [%s]:", #scrambleRequirements, scrambleBannerName), Color3.fromRGB(180, 220, 255))
        for i, req in ipairs(scrambleRequirements) do
            local disp = getDisplayEggName(req.species)
            logMsg(string.format("  Slot #%s: %s (internal: %s)", tostring(req.slot), disp, req.species), Color3.fromRGB(200, 225, 255))
        end
    end

    -- ========================================================================
    -- 8. UI RENDERER (REQUIREMENTS & INVENTORY LIST)
    -- ========================================================================

    local function getTradeCandidates()
        local finalUids = {}
        local usedUids = {}
        local readySlotsCount = 0
        local slotMatches = {}
        local totalReq = #scrambleRequirements

        if totalReq == 0 then
            return false, finalUids, 0, 0, slotMatches, usedUids
        end

        for slotIdx, req in ipairs(scrambleRequirements) do
            slotMatches[slotIdx] = {}
            for _, egg in ipairs(allInventoryEggs) do
                local matches = matchEggSpecies(egg.species, req.species)
                    or (egg.category and egg.category ~= "" and matchEggSpecies(egg.category, req.species))
                    or (egg.displayName and egg.displayName ~= "" and matchEggSpecies(egg.displayName, req.species))
                if matches then
                    table.insert(slotMatches[slotIdx], egg)
                    if not finalUids[slotIdx] and not usedUids[egg.uid] then
                        finalUids[slotIdx] = egg.uid
                        usedUids[egg.uid] = true
                    end
                end
            end
            if finalUids[slotIdx] then
                readySlotsCount = readySlotsCount + 1
            end
        end

        local allReady = (readySlotsCount == totalReq and totalReq > 0)
        return allReady, finalUids, readySlotsCount, totalReq, slotMatches, usedUids
    end

    local slotRowFrames = {}

    updateUI = function()
        -- Match unplaced eggs to slots (1 distinct egg per slot)
        local allReady, chosenUids, readySlotsCount, totalReq, slotMatches, usedEggUids = getTradeCandidates()

        -- Sync missing species to X for AutoFarm (Data level sync always runs)
        local missingMap = {}
        for slotIdx, req in ipairs(scrambleRequirements) do
            if not chosenUids[slotIdx] then
                local n = normalizeEggSpecies(req.species)
                if n ~= "" then missingMap[n] = true end
            end
        end
        X.scrambleMissingSpecies = missingMap

        -- Update Manual / Auto Trade Button
        if isTradingIn then
            manualTradeBtn.BackgroundColor3 = Color3.fromRGB(80, 50, 120)
            manualTradeBtn.Text = "⏳ Trading In..."
            manualTradeBtn.TextColor3 = Color3.new(1, 1, 1)
            mtStroke.Color = Color3.fromRGB(150, 100, 220)
        elseif allReady and totalReq > 0 then
            if isAutoTradeEnabled then
                manualTradeBtn.BackgroundColor3 = Color3.fromRGB(35, 115, 70)
                manualTradeBtn.Text = string.format("⚡ Auto-Ready (%d/%d)", readySlotsCount, totalReq)
                manualTradeBtn.TextColor3 = Color3.fromRGB(160, 255, 190)
                mtStroke.Color = Color3.fromRGB(70, 210, 130)
            else
                manualTradeBtn.BackgroundColor3 = Color3.fromRGB(115, 60, 185)
                manualTradeBtn.Text = string.format("⚡ Trade (%d/%d Ready)", readySlotsCount, totalReq)
                manualTradeBtn.TextColor3 = Color3.new(1, 1, 1)
                mtStroke.Color = Color3.fromRGB(170, 110, 255)
            end
        else
            manualTradeBtn.BackgroundColor3 = Color3.fromRGB(50, 48, 65)
            manualTradeBtn.Text = string.format("⚡ Trade (%d/%d)", readySlotsCount, totalReq)
            manualTradeBtn.TextColor3 = Color3.fromRGB(160, 165, 185)
            mtStroke.Color = Color3.fromRGB(65, 60, 85)
        end

        -- Virtualization / Visibility Gate: Skip DOM updates if Tab 3 is hidden
        if not tabScramble or not tabScramble.Visible then return end

        -- 1. RENDER REQUIREMENTS (In-place recycling to avoid Destroy/Instance churn)
        if #scrambleRequirements == 0 then
            for _, item in ipairs(slotRowFrames) do item.frame.Visible = false end
            local emptyLbl = reqsContainer:FindFirstChild("EmptyLabel")
            if not emptyLbl then
                emptyLbl = Instance.new("TextLabel")
                emptyLbl.Name = "EmptyLabel"
                emptyLbl.Size = UDim2.new(1, 0, 0, 28)
                emptyLbl.BackgroundTransparency = 1
                emptyLbl.Text = "ℹ️ No requirements loaded. Click 🔄 to query server."
                emptyLbl.TextColor3 = Color3.fromRGB(180, 190, 210)
                emptyLbl.Font = Enum.Font.Gotham
                emptyLbl.TextSize = 10
                emptyLbl.Parent = reqsContainer
            end
            emptyLbl.Visible = true
        else
            local emptyLbl = reqsContainer:FindFirstChild("EmptyLabel")
            if emptyLbl then emptyLbl.Visible = false end

            for slotIdx, req in ipairs(scrambleRequirements) do
                local isOwned = (chosenUids[slotIdx] ~= nil)
                local totalCandidates = #(slotMatches[slotIdx] or {})
                local dispName = getDisplayEggName(req.species)

                local item = slotRowFrames[slotIdx]
                if not item then
                    local row = Instance.new("Frame")
                    row.Size = UDim2.new(1, 0, 0, 32)
                    row.BorderSizePixel = 0
                    row.LayoutOrder = slotIdx
                    row.Parent = reqsContainer
                    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)
                    local rStroke = Instance.new("UIStroke", row)
                    rStroke.Thickness = 1

                    local strip = Instance.new("Frame")
                    strip.Size = UDim2.new(0, 4, 1, -6)
                    strip.Position = UDim2.new(0, 3, 0, 3)
                    strip.BorderSizePixel = 0
                    strip.Parent = row
                    Instance.new("UICorner", strip).CornerRadius = UDim.new(0, 2)

                    local titleL = Instance.new("TextLabel")
                    titleL.Size = UDim2.new(1, -95, 0, 16)
                    titleL.Position = UDim2.new(0, 14, 0, 2)
                    titleL.BackgroundTransparency = 1
                    titleL.Font = Enum.Font.GothamBold
                    titleL.TextSize = 10
                    titleL.TextXAlignment = Enum.TextXAlignment.Left
                    titleL.TextTruncate = Enum.TextTruncate.AtEnd
                    titleL.Parent = row

                    local subL = Instance.new("TextLabel")
                    subL.Size = UDim2.new(1, -95, 0, 12)
                    subL.Position = UDim2.new(0, 14, 0, 17)
                    subL.BackgroundTransparency = 1
                    subL.Font = Enum.Font.Gotham
                    subL.TextSize = 8.5
                    subL.TextXAlignment = Enum.TextXAlignment.Left
                    subL.TextTruncate = Enum.TextTruncate.AtEnd
                    subL.Parent = row

                    local badge = Instance.new("TextLabel")
                    badge.Size = UDim2.new(0, 75, 0, 20)
                    badge.Position = UDim2.new(1, -80, 0.5, -10)
                    badge.Font = Enum.Font.GothamBold
                    badge.TextSize = 9
                    badge.Parent = row
                    Instance.new("UICorner", badge).CornerRadius = UDim.new(0, 4)

                    item = {
                        frame = row,
                        stroke = rStroke,
                        strip = strip,
                        title = titleL,
                        sub = subL,
                        badge = badge
                    }
                    slotRowFrames[slotIdx] = item
                end

                item.frame.Visible = true
                item.frame.LayoutOrder = slotIdx
                item.frame.BackgroundColor3 = isOwned and Color3.fromRGB(22, 36, 28) or Color3.fromRGB(34, 25, 30)
                item.stroke.Color = isOwned and Color3.fromRGB(45, 130, 85) or Color3.fromRGB(120, 55, 65)
                item.strip.BackgroundColor3 = isOwned and Color3.fromRGB(70, 230, 140) or Color3.fromRGB(255, 110, 80)
                item.title.Text = string.format("Slot #%s: %s (x%d)", tostring(req.slot), dispName, req.count)
                item.title.TextColor3 = isOwned and Color3.fromRGB(220, 255, 235) or Color3.fromRGB(255, 230, 235)
                item.sub.Text = string.format("Inventory: %d %s", totalCandidates, totalCandidates == 1 and "copy" or "copies")
                item.sub.TextColor3 = isOwned and Color3.fromRGB(150, 225, 185) or Color3.fromRGB(200, 160, 170)
                item.badge.BackgroundColor3 = isOwned and Color3.fromRGB(28, 75, 48) or Color3.fromRGB(75, 30, 36)
                item.badge.Text = isOwned and "✓ OWNED" or "⚠️ MISSING"
                item.badge.TextColor3 = isOwned and Color3.fromRGB(130, 255, 185) or Color3.fromRGB(255, 160, 140)
            end

            for i = #scrambleRequirements + 1, #slotRowFrames do
                slotRowFrames[i].frame.Visible = false
            end
        end
    end

    -- ========================================================================
    -- 9. TRADE-IN EXECUTION PIPELINE & AUTO-TRADE ENGINE
    -- ========================================================================

    checkAndAutoTrade = function(source)
        if not isAutoTradeEnabled then return false end
        if isTradingIn then return false end
        if weAreCarrying then return false end
        if os.clock() - lastTradeAttempt < 1.5 then return false end
        if not scrambleRequirements or #scrambleRequirements == 0 then return false end

        local allReady, finalUids, readyCount, totalReq = getTradeCandidates()
        if allReady and #finalUids == #scrambleRequirements and #finalUids > 0 then
            logMsg(string.format("⚡ [Auto-Trade] All slots ready (%d/%d)! Auto-executing (%s)...", readyCount, totalReq, tostring(source or "auto")), Color3.fromRGB(120, 255, 180))
            return executeTradeIn(true, finalUids)
        end
        return false
    end

    executeTradeIn = function(isAuto, candidateUids)
        if isTradingIn then
            if not isAuto then
                logMsg("⏳ Trade already in progress...", Color3.fromRGB(255, 180, 80))
            end
            return false
        end

        if isAuto and not isAutoTradeEnabled then return false end
        if weAreCarrying then return false end
        if os.clock() - lastTradeAttempt < 1.5 then return false end

        -- Select 1 distinct egg per requirement slot
        local finalUids = candidateUids
        if not finalUids then
            scanInventoryEggs(false)
            local allReady, uids = getTradeCandidates()
            if not allReady then
                if not isAuto then
                    logMsg(string.format("⚠️ Missing eggs for trade (%d/%d slots ready). Cannot execute.", #uids, #scrambleRequirements), Color3.fromRGB(255, 180, 80))
                end
                return false
            end
            finalUids = uids
        end

        if not scrambleRequirements or #scrambleRequirements == 0 or #finalUids < #scrambleRequirements or #finalUids == 0 then
            if not isAuto then
                logMsg(string.format("⚠️ Missing eggs for trade (%d/%d slots ready). Cannot execute.", #finalUids, #scrambleRequirements), Color3.fromRGB(255, 180, 80))
            end
            return false
        end

        if not rfTradeIn then
            rfTradeIn = getNetRemote("RF/ScrambleTradeIn/AskTradeIn") or getNetRemote("RF/ScrambleTradeIn/TradeIn")
        end
        if not rfTradeIn then
            logMsg("❌ Remote RF/ScrambleTradeIn/AskTradeIn NOT FOUND!", Color3.fromRGB(255, 100, 100))
            return false
        end

        lastTradeAttempt = os.clock()
        isTradingIn = true
        manualTradeBtn.Text = "⏳ Trading In..."
        manualTradeBtn.BackgroundColor3 = Color3.fromRGB(80, 50, 120)

        task.spawn(function()
            local modeTag = isAuto and "[AUTO-TRADE]" or "[MANUAL TRADE]"
            logMsg(string.format("🌀 %s Offering %d unplaced eggs to Dr. Scramble...", modeTag, #finalUids), Color3.fromRGB(190, 150, 255))
            for i, u in ipairs(finalUids) do
                local req = scrambleRequirements[i]
                local disp = req and getDisplayEggName(req.species) or "Egg"
                local shortU = (#u > 10) and (u:sub(1, 8) .. "...") or u
                logMsg(string.format("  Slot #%d [%s]: Offering UID %s", i, disp, shortU), Color3.fromRGB(170, 195, 235))
            end

            -- STEP 1: Invoke AskTradeIn({ [1]=uid1, [2]=uid2, [3]=uid3 })
            local ok, res, reward = pcall(function()
                return rfTradeIn:InvokeServer(finalUids)
            end)

            local resSummary = type(res) == "table" and dumpTbl(res, 2) or tostring(res)
            logMsg("⚡ [AskTradeIn] Result: " .. resSummary, (ok and res ~= false) and Color3.fromRGB(120, 255, 180) or Color3.fromRGB(255, 160, 90))

            if not ok or res == false then
                logMsg("❌ Server rejected trade-in. Check eggs or try again.", Color3.fromRGB(255, 110, 110))
                isTradingIn = false
                updateUI()
                return
            end

            -- STEP 2: Invoke AskFinishReveal to claim reward & unlock next recipe
            task.wait(0.5)
            if not rfReveal then rfReveal = getNetRemote("RF/ScrambleTradeIn/AskFinishReveal") end
            if rfReveal then
                logMsg("🎁 Calling AskFinishReveal to claim pet reward...", Color3.fromRGB(180, 215, 255))
                local okRev, resRev = pcall(function()
                    return rfReveal:InvokeServer()
                end)
                logMsg("✨ [AskFinishReveal] Result: " .. tostring(resRev), (okRev and resRev ~= false) and Color3.fromRGB(130, 255, 180) or Color3.fromRGB(255, 180, 80))
            end

            -- Lightweight snapshot synchronization
            task.wait(0.3)
            pcall(function()
                local ccReq = ReplicatedStorage:FindFirstChild("ContentCreatorRemotes")
                if ccReq and ccReq:FindFirstChild("Request") then
                    ccReq.Request:InvokeServer("snapshot", { lightweight = true })
                end
            end)

            isTradingIn = false
            logMsg("✅ Trade-In complete! Refreshing recipe...", Color3.fromRGB(140, 255, 180))

            task.wait(0.5)
            queryScrambleState()
            scanInventoryEggs(true)
            updateUI()

            -- Immediately chain next trade if eligible!
            if isAutoTradeEnabled and not weAreCarrying then
                task.defer(function()
                    checkAndAutoTrade("PostTradeChain")
                end)
            end
        end)

        return true
    end

    -- ========================================================================
    -- 10. EXTERNAL INTERFACES FOR AUTOFARM SUITE
    -- ========================================================================

    refreshScrambleUI = function(force)
        if updateUI then updateUI() end
        task.spawn(function()
            if not scrambleRequirements or #scrambleRequirements == 0 then
                queryScrambleState()
            end
            scanInventoryEggs(force == true)
            updateUI()
        end)
    end

    X.scanInventoryEggsForScramble = function(force)
        return scanInventoryEggs(force == true)
    end

    X.updateScrambleUI = function()
        updateUI()
    end

    X.tryAutoScrambleTrade = function()
        if not isAutoTradeEnabled then return false end
        if isTradingIn then return false end
        if weAreCarrying then return false end
        return checkAndAutoTrade("AutoFarmHook")
    end

    -- ========================================================================
    -- 11. EVENT LISTENERS & BACKGROUND WORKER
    -- ========================================================================

    local backpackDebounceThread = nil
    local function onBackpackChanged(triggerSrc)
        if backpackDebounceThread then
            task.cancel(backpackDebounceThread)
            backpackDebounceThread = nil
        end
        backpackDebounceThread = task.delay(2.5, function()
            backpackDebounceThread = nil
            task.spawn(function()
                scanInventoryEggs(false)
                updateUI()
                if isAutoTradeEnabled and not isTradingIn and not weAreCarrying then
                    checkAndAutoTrade(triggerSrc or "BackpackDebounced")
                end
            end)
        end)
    end

    local function bindBackpackListeners()
        local bp = LocalPlayer:FindFirstChild("Backpack")
        if bp then
            addConnection(bp.ChildAdded:Connect(function() onBackpackChanged("BackpackAdded") end))
            addConnection(bp.ChildRemoved:Connect(function() onBackpackChanged("BackpackRemoved") end))
        end
    end
    pcall(bindBackpackListeners)
    addConnection(LocalPlayer.ChildAdded:Connect(function(child)
        if child.Name == "Backpack" then pcall(bindBackpackListeners) end
    end))

    -- Server Trade Rotation Event (RE/ScrambleTradeIn/BannerRotated)
    if reRotated and reRotated:IsA("RemoteEvent") then
        addConnection(reRotated.OnClientEvent:Connect(function(...)
            logMsg("🔄 [RE/BannerRotated] Server rotated trade recipe! Reloading...", Color3.fromRGB(150, 220, 255))
            task.delay(0.5, function()
                task.spawn(function()
                    queryScrambleState()
                    scanInventoryEggs(true)
                    updateUI()
                    if not weAreCarrying then
                        checkAndAutoTrade("BannerRotatedEvent")
                    end
                end)
            end)
        end))
    end

    -- Main Background Worker Loop
    task.spawn(function()
        logMsg("🌀 Dr. Scramble Standalone Auto-Trade Engine Started")
        task.spawn(function()
            queryScrambleState()
            scanInventoryEggs(true)
            updateUI()
            if not weAreCarrying then
                checkAndAutoTrade("Startup")
            end
        end)

        local lastLoopScan = 0
        while screenGui and screenGui.Parent and not _G.EggGoToUI_Stop do
            local now = os.time()
            local diff = 0
            if serverExpiresAt then
                diff = math.max(0, serverExpiresAt - now)
                if diff <= 0 then
                    local secsIntoHour = os.time() % 3600
                    serverExpiresAt = os.time() + math.max(15, 3600 - secsIntoHour)
                    logMsg("⏰ Hourly timer expired! Querying next rotation...", Color3.fromRGB(255, 200, 100))
                    task.spawn(function()
                        queryScrambleState()
                        scanInventoryEggs(true)
                        updateUI()
                        if not weAreCarrying then
                            checkAndAutoTrade("TimerExpired")
                        end
                    end)
                    diff = math.max(0, serverExpiresAt - os.time())
                end
            else
                local secsIntoHour = os.time() % 3600
                diff = 3600 - secsIntoHour
            end

            local m = math.floor(diff / 60)
            local s = diff % 60
            timerBadge.Text = string.format("⏳ %02dm %02ds  •  %s", m, s, scrambleBannerName)

            -- Periodic evaluation every 15s per performance requirement
            if os.clock() - lastLoopScan >= 15 then
                lastLoopScan = os.clock()
                task.spawn(function()
                    scanInventoryEggs(false)
                    updateUI()
                    if isAutoTradeEnabled and not isTradingIn and not weAreCarrying then
                        checkAndAutoTrade("15sPoll")
                    end
                end)
            end

            task.wait(1)
        end
    end)
end

-- ==================================================
-- TAB 4 HELPERS: AUTO TREADMILL, DISMOUNT & PEN
-- ==================================================
function X.findMyPlot()
    if X.myPlot and X.myPlot.Parent then
        return X.myPlot, X.myPlotIndex
    end
    local plotsFolder = Workspace:FindFirstChild("Plots") or Workspace:FindFirstChild("Bases")
    if not plotsFolder then return nil, nil end

    local myIdStr = tostring(LocalPlayer.UserId)
    local myName  = string.lower(LocalPlayer.Name)

    -- Pass 1: Authoritative Owner attribute check
    for _, plot in ipairs(plotsFolder:GetChildren()) do
        local pAttrs = plot:GetAttributes()
        local ownerAttr = pAttrs.Owner or pAttrs.OwnerId or pAttrs.Player or pAttrs.UserId or pAttrs.ClaimedBy
        if ownerAttr then
            local strOwner = tostring(ownerAttr):lower()
            if strOwner == myIdStr or strOwner == myName then
                local idx = tonumber(plot.Name) or tonumber(string.match(plot.Name, "%d+"))
                X.myPlot = plot
                X.myPlotIndex = idx
                return plot, idx
            end
        end
    end

    -- Pass 2: Child Object / Sign text check
    for _, plot in ipairs(plotsFolder:GetChildren()) do
        for _, desc in ipairs(plot:GetDescendants()) do
            if desc:IsA("TextLabel") or desc:IsA("SurfaceGui") then
                local txt = desc:IsA("TextLabel") and desc.Text:lower() or ""
                if string.find(txt, myName, 1, true) or string.find(txt, string.lower(LocalPlayer.DisplayName), 1, true) then
                    local idx = tonumber(plot.Name) or tonumber(string.match(plot.Name, "%d+"))
                    X.myPlot = plot
                    X.myPlotIndex = idx
                    return plot, idx
                end
            end
        end
    end

    -- Pass 3: Proximity to SAFE_ZONE
    local bestPlot, bestDist = nil, math.huge
    for _, plot in ipairs(plotsFolder:GetChildren()) do
        local pPos = nil
        if plot:IsA("Model") then
            local ok, piv = pcall(function() return plot:GetPivot().Position end)
            pPos = ok and piv or (plot.PrimaryPart and plot.PrimaryPart.Position)
        elseif plot:IsA("BasePart") then
            pPos = plot.Position
        end
        if pPos then
            local d = X.distXZ(pPos, SAFE_ZONE)
            if d < bestDist then
                bestDist = d
                bestPlot = plot
            end
        end
    end

    if bestPlot and bestDist <= 80 then
        local idx = tonumber(bestPlot.Name) or tonumber(string.match(bestPlot.Name, "%d+"))
        X.myPlot = bestPlot
        X.myPlotIndex = idx
        return bestPlot, idx
    end

    return nil, nil
end

function X.findMyPen()
    if X.penPosition then
        return X.penPosition
    end
    -- 1. Try finding pen position from existing PlacedEggRenders for this player
    local placedRenders = Workspace:FindFirstChild("PlacedEggRenders")
    if placedRenders then
        local myPrefix = tostring(LocalPlayer.UserId) .. "_"
        local eggPositions = {}
        for _, egg in ipairs(placedRenders:GetChildren()) do
            if string.find(egg.Name, myPrefix, 1, true) then
                local p = nil
                if egg:IsA("BasePart") then p = egg.Position
                elseif egg:IsA("Model") then
                    local ok, piv = pcall(function() return egg:GetPivot().Position end)
                    p = ok and piv or nil
                end
                if p then table.insert(eggPositions, p) end
            end
        end
        if #eggPositions > 0 then
            local avgX, avgY, avgZ = 0, 0, 0
            for _, pos in ipairs(eggPositions) do
                avgX = avgX + pos.X
                avgY = avgY + pos.Y
                avgZ = avgZ + pos.Z
            end
            local center = Vector3.new(avgX / #eggPositions, avgY / #eggPositions, avgZ / #eggPositions)
            X.penPosition = center
            return center
        end
    end

    -- 2. Try finding Pen / Nest / Incubator within MyPlot
    local plot = X.myPlot
    if not plot then
        plot, _ = X.findMyPlot()
    end

    if plot then
        for _, desc in ipairs(plot:GetDescendants()) do
            local low = string.lower(desc.Name)
            if (low:find("pen") or low:find("nest") or low:find("incubator") or low:find("eggspot") or low:find("delivery"))
               and desc:IsA("BasePart") then
                X.penPosition = desc.Position
                return desc.Position
            end
        end
        local ok, piv = pcall(function() return plot:GetPivot().Position end)
        if ok and piv then
            X.penPosition = piv
            return piv
        end
    end

    -- 3. Fallback to SAFE_ZONE
    X.penPosition = SAFE_ZONE
    return SAFE_ZONE
end

function X.findMyTreadmill()
    if X.treadmillPosition and X.treadmillBelt and X.treadmillBelt.Parent then
        return X.treadmillModel, X.treadmillBelt, X.treadmillPosition
    end
    local clientTreadmills = Workspace:FindFirstChild("__ClientTreadmillRenders")
    local plotIdx = X.myPlotIndex
    if not plotIdx then
        _, plotIdx = X.findMyPlot()
    end

    local candidate = nil
    if clientTreadmills and plotIdx then
        local targetName = "TreadmillRender_" .. tostring(plotIdx)
        candidate = clientTreadmills:FindFirstChild(targetName)
    end

    -- Nearest fallback
    if not candidate and clientTreadmills then
        local penPos = X.penPosition or SAFE_ZONE
        local minDist = math.huge
        for _, tm in ipairs(clientTreadmills:GetChildren()) do
            local p = nil
            if tm:IsA("BasePart") then p = tm.Position
            elseif tm:IsA("Model") or tm:IsA("Tool") then
                local ok, piv = pcall(function() return tm:GetPivot().Position end)
                p = ok and piv or (tm:FindFirstChildWhichIsA("BasePart") and tm:FindFirstChildWhichIsA("BasePart").Position)
            end
            if p then
                local d = X.distXZ(p, penPos)
                if d < minDist then
                    minDist = d
                    candidate = tm
                end
            end
        end
    end

    -- Inside MyPlot fallback
    if not candidate and X.myPlot then
        for _, desc in ipairs(X.myPlot:GetDescendants()) do
            if string.find(string.lower(desc.Name), "treadmill") then
                candidate = desc
                break
            end
        end
    end

    if candidate then
        X.treadmillModel = candidate
        local belt = nil
        for _, p in ipairs(candidate:GetDescendants()) do
            if p:IsA("BasePart") then
                local ln = string.lower(p.Name)
                if ln:find("belt") or ln:find("cube.015") or ln:find("running") or ln:find("surface") or ln:find("pad") then
                    belt = p
                    break
                end
            end
        end
        if not belt then
            belt = candidate:FindFirstChildWhichIsA("BasePart", true)
        end
        X.treadmillBelt = belt
        if belt then
            X.treadmillPosition = belt.Position
            return candidate, belt, belt.Position
        end
    end

    return nil, nil, nil
end

function X.walkToTarget(targetPos, arrivalDist, cancelCheck, snapRadius)
    arrivalDist = arrivalDist or 3.0
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    if not char or not root or not hum then return false end

    local isSafeZone = (targetPos == SAFE_ZONE) or (typeof(targetPos) == "Vector3" and typeof(SAFE_ZONE) == "Vector3" and X.distXZ(targetPos, SAFE_ZONE) < 1.0)
    local effectiveSnapRadius = snapRadius or (isSafeZone and (X.SAFE_SNAP_RADIUS or 60) or nil)

    local startTime = os.clock()
    local timeout   = 60.0

    while (os.clock() - startTime) < timeout do
        if not LocalPlayer.Character or not root.Parent or hum.Health <= 0 then break end
        if cancelCheck and cancelCheck() then break end

        local curPos = root.Position
        local dist = X.distXZ(curPos, targetPos)

        if effectiveSnapRadius and dist <= effectiveSnapRadius then
            if isSafeZone then
                X.snapToSafe()
            else
                X.markTeleport()
                pcall(function()
                    root.AssemblyLinearVelocity = Vector3.zero
                    local targetY = targetPos.Y
                    if math.abs(root.Position.Y - targetPos.Y) <= 4 then
                        targetY = root.Position.Y
                    end
                    root.CFrame = CFrame.new(targetPos.X, targetY, targetPos.Z) * (root.CFrame - root.CFrame.Position)
                end)
            end
            pcall(function()
                root.AssemblyLinearVelocity = Vector3.zero
                hum:Move(Vector3.zero)
                hum:MoveTo(root.Position)
            end)
            return true
        end

        if dist <= arrivalDist then
            pcall(function()
                root.AssemblyLinearVelocity = Vector3.zero
                hum:Move(Vector3.zero)
                hum:MoveTo(root.Position)
            end)
            return true
        end

        if X.TRAP_CONFIG and X.TRAP_CONFIG.Enabled and typeof(X.getNearestTrapDist) == "function" then
            local nearTrapDist = X.getNearestTrapDist(curPos)
            if nearTrapDist and nearTrapDist <= 4.5 and not hum.Jump then
                hum.Jump = true
            end
        end

        local dir = Vector3.new(targetPos.X - curPos.X, 0, targetPos.Z - curPos.Z)
        if dir.Magnitude > 0.1 then
            hum:Move(dir.Unit, false)
            hum:MoveTo(targetPos)
        end

        task.wait(0.08)
    end

    pcall(function()
        if root then root.AssemblyLinearVelocity = Vector3.zero end
        hum:Move(Vector3.zero)
        if root then hum:MoveTo(root.Position) end
    end)
    local cur = root and root.Position
    return cur and (X.distXZ(cur, targetPos) <= (effectiveSnapRadius or arrivalDist)) or false
end

function X.isOnTreadmill()
    local lpAttr   = LocalPlayer:GetAttribute("IsOnTreadmill")
    local char     = LocalPlayer.Character
    local charAttr = char and char:GetAttribute("IsOnTreadmill")
    if lpAttr == true or charAttr == true then
        return true
    end
    if char and X.treadmillBelt then
        local root = char:FindFirstChild("HumanoidRootPart")
        if root then
            local dist = X.distXZ(root.Position, X.treadmillBelt.Position)
            if dist <= 4.0 and math.abs(root.Position.Y - X.treadmillBelt.Position.Y) <= 3.5 then
                local hum = char:FindFirstChildOfClass("Humanoid")
                if hum and (hum:GetState() == Enum.HumanoidStateType.Running or hum.MoveDirection.Magnitude > 0.05) then
                    return true
                end
            end
        end
    end
    return false
end

function X.initNightResetMonitor()
    if X.nightMonitorInitialized then return end
    X.nightMonitorInitialized = true
    X.nightResetTriggered = false
    X.lastClockTime = nil

    local net = ReplicatedStorage:FindFirstChild("Packages")
        and ReplicatedStorage.Packages:FindFirstChild("Networking")

    -- 1. RE/EggWorld/FieldEggCycleCountdown
    if net then
        local evCountdown = net:FindFirstChild("RE/EggWorld/FieldEggCycleCountdown")
        if evCountdown and evCountdown:IsA("RemoteEvent") then
            addConnection(evCountdown.OnClientEvent:Connect(function(val)
                local cd = tonumber(val) or (typeof(val) == "table" and tonumber(val.Countdown or val.Time or val.Seconds))
                if cd and cd <= 1 then
                    X.nightResetTriggered = true
                    X.lastNightResetAt = os.clock()
                    X.nightResetGraceUntil = os.clock() + 12.0
                end
            end))
        end

        -- 2. RE/EggWorld/FieldEggBatchShifted
        local evBatch = net:FindFirstChild("RE/EggWorld/FieldEggBatchShifted")
        if evBatch and evBatch:IsA("RemoteEvent") then
            addConnection(evBatch.OnClientEvent:Connect(function()
                if X.isOnTreadmill() then
                    X.nightResetTriggered = true
                    X.lastNightResetAt = os.clock()
                    X.nightResetGraceUntil = os.clock() + 12.0
                end
            end))
        end
    end

    -- 3. Lighting ClockTime listener
    local lighting = game:GetService("Lighting")
    if lighting then
        X.lastClockTime = lighting.ClockTime
        addConnection(lighting:GetPropertyChangedSignal("ClockTime"):Connect(function()
            local cur = lighting.ClockTime
            local prev = X.lastClockTime or cur
            X.lastClockTime = cur

            local wasDay = (prev >= 6 and prev < 18)
            local isNight = (cur >= 18 or cur < 6)
            if wasDay and isNight then
                X.nightResetTriggered = true
                X.lastNightResetAt = os.clock()
                X.nightResetGraceUntil = os.clock() + 12.0
            end
        end))
    end
end

function X.checkNightReset()
    if X.nightResetTriggered then
        return true
    end
    if X.lastNightResetAt and (os.clock() - X.lastNightResetAt) < 6.0 then
        return true
    end
    local lighting = game:GetService("Lighting")
    if lighting then
        local ct = lighting.ClockTime
        if (ct >= 18 or ct <= 5.5) then
            if X.mountedAtClockTime and (X.mountedAtClockTime >= 6 and X.mountedAtClockTime < 18) then
                return true
            end
        end
    end
    return false
end

function X.executeAutoDismount(andWalkToSafeZone, cancelCheck)
    local char = LocalPlayer.Character
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    if hum then
        pcall(function()
            hum:ChangeState(Enum.HumanoidStateType.Jumping)
            hum.Jump = true
        end)
        task.wait(0.05)
        pcall(function() hum.Jump = true end)
    end

    local rfDoff = X.getNetRemote("RF/Treadmill/AskDoff")
    if rfDoff then
        pcall(function() rfDoff:InvokeServer() end)
    end

    if andWalkToSafeZone then
        task.wait(0.15)
        local arrived = X.walkToTarget(SAFE_ZONE, X.SAFE_ARRIVE_RADIUS, cancelCheck, X.SAFE_SNAP_RADIUS)
        local ch = LocalPlayer.Character
        local r = ch and ch:FindFirstChild("HumanoidRootPart")
        local h = ch and ch:FindFirstChildOfClass("Humanoid")
        if r then pcall(function() r.AssemblyLinearVelocity = Vector3.zero end) end
        if h then
            pcall(function()
                h:Move(Vector3.zero)
                if r then h:MoveTo(r.Position) end
            end)
        end
        return arrived
    end

    return true
end

function X.executeAutoPen(cancelCheck)
    local penPos = X.penPosition or X.findMyPen()
    if not penPos then return false end

    if X.isOnTreadmill() then
        X.executeAutoDismount(false)
        task.wait(0.3)
    end

    local ok = X.walkToTarget(penPos, 3.0, cancelCheck)
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum then
        pcall(function() hum:Move(Vector3.zero) end)
    end
    return ok
end

function X.executeAutoTreadmill(cancelCheck)
    local tmModel, tmBelt, tmPos = X.treadmillModel, X.treadmillBelt, X.treadmillPosition
    if not tmPos then
        tmModel, tmBelt, tmPos = X.findMyTreadmill()
    end
    if not tmPos then
        X.findMyPlot()
        tmModel, tmBelt, tmPos = X.findMyTreadmill()
    end
    if not tmPos then return false end

    local arrived = X.walkToTarget(tmPos, 2.5, cancelCheck)
    if not arrived then return false end

    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum then
        pcall(function() hum:Move(Vector3.zero) end)
    end
    task.wait(0.15)

    -- Trigger mount
    local rfWear = X.getNetRemote("RF/Treadmill/AskWearStill")
    if rfWear then
        pcall(function() rfWear:InvokeServer() end)
        if X.myPlotIndex then
            pcall(function() rfWear:InvokeServer(X.myPlotIndex) end)
        end
        if tmModel then
            pcall(function() rfWear:InvokeServer(tmModel) end)
        end
    end

    if tmModel and typeof(fireproximityprompt) == "function" then
        local prompt = X.treadmillPrompt
        if not prompt or not prompt.Parent then
            prompt = tmModel:FindFirstChildWhichIsA("ProximityPrompt", true)
            X.treadmillPrompt = prompt
        end
        if prompt then
            pcall(function() fireproximityprompt(prompt) end)
        end
    end

    local lighting = game:GetService("Lighting")
    X.mountedAtClockTime = lighting and lighting.ClockTime
    X.nightResetTriggered = false
    return true
end

-- ==================================================
-- TAB 4 BUILDER: UTILITY SUITE (SPAM PICKUP & REACH ASSIST)
-- ==================================================
function X.buildUtilityTabUI()
    local PICKUP_CONFIG = X.PICKUP_CONFIG

    local function getBestFocusedTarget()
        local char = LocalPlayer.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if not root then return nil end

        local charPos  = root.Position
        local charLook = root.CFrame.LookVector
        local cam = Workspace.CurrentCamera
        local camPos  = cam and cam.CFrame.Position or charPos
        local camLook = cam and cam.CFrame.LookVector or charLook

        local bestTarget, highestScore = nil, -math.huge
        local maxDist = PICKUP_CONFIG.MaxReachDistance or 35

        local function scoreTarget(pos, dist)
            local dir = dist > 0.01 and (pos - charPos).Unit or charLook
            local charDot = charLook:Dot(dir)
            local camDir = ((pos - camPos).Magnitude > 0.01) and (pos - camPos).Unit or camLook
            local camDot = camLook:Dot(camDir)
            local score = (math.max(0, camDot) * 2.2 + math.max(0, charDot) * 1.2 + 0.3) / (dist + 0.5)
            if dist <= 6 then score = score + 3 end
            return score
        end

        if eggCache and eggCache.byUid then
            for uid, r in pairs(eggCache.byUid) do
                local isCarriedByOther = r.CarrierUserId and tostring(r.CarrierUserId) ~= tostring(LocalPlayer.UserId)
                if r.State ~= "Claimed" and not isCarriedByOther then
                    local pos = extPos(r)
                    if pos then
                        local dist = (pos - charPos).Magnitude
                        if dist <= maxDist then
                            local score = scoreTarget(pos, dist)
                            if score > highestScore then
                                highestScore = score
                                bestTarget = {
                                    Type = "EggRecord",
                                    Uid = uid,
                                    Name = (X.getDisplayEggName and X.getDisplayEggName(r)) or tostring(r.AssetCategory or "Egg"),
                                    Position = pos,
                                    Distance = dist,
                                    Prompt = nil
                                }
                            end
                        end
                    end
                end
            end
        end

        local slotsFolder = Workspace:FindFirstChild("AreaEggSlotsClient")
        if slotsFolder then
            for _, ch in ipairs(slotsFolder:GetChildren()) do
                local pos = ch:IsA("BasePart") and ch.Position or (ch:IsA("Model") and ch:GetPivot().Position)
                if pos then
                    local dist = (pos - charPos).Magnitude
                    if dist <= maxDist then
                        local score = scoreTarget(pos, dist)
                        local uid = ch:GetAttribute("Uid") or ch:GetAttribute("EggUid")
                        if not uid and #ch.Name == 32 and ch.Name:match("^%x+$") then uid = ch.Name end
                        if score > highestScore then
                            highestScore = score
                            bestTarget = {
                                Type = "SlotDirect",
                                Uid = uid or (bestTarget and bestTarget.Uid),
                                Name = ch.Name,
                                Position = pos,
                                Distance = dist,
                                Prompt = ch:FindFirstChildWhichIsA("ProximityPrompt", true)
                            }
                        end
                    end
                end
            end
        end

        return bestTarget
    end

    local function executePickupSpam(target)
        if not target then return end
        if PICKUP_CONFIG.ReachAssist and target.Position then
            applyReachAssist(target.Position)
        end
        if target.Prompt then
            triggerProximityPrompt(target.Prompt)
        end
        if target.Uid then
            carryEgg(target.Uid, nil, PICKUP_CONFIG.SpamBurstCount or 8)
        end
    end

    -- ========================================================================
    -- UI: SIMPLE TWO-COLUMN (TEXT | ON/OFF)
    -- ========================================================================
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 36)
    row.BackgroundColor3 = Color3.fromRGB(24, 28, 40)
    row.BorderSizePixel = 0
    row.LayoutOrder = 1
    row.Parent = tabUtility
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)
    local stroke = Instance.new("UIStroke", row)
    stroke.Color = Color3.fromRGB(45, 55, 75)
    stroke.Thickness = 1

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -70, 1, 0)
    lbl.Position = UDim2.new(0, 12, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = "Spam Pickup [E]"
    lbl.TextColor3 = Color3.fromRGB(220, 230, 255)
    lbl.Font = Enum.Font.GothamBold
    lbl.TextSize = 12
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = row

    local toggleBtn = Instance.new("TextButton")
    toggleBtn.Size = UDim2.new(0, 52, 0, 24)
    toggleBtn.Position = UDim2.new(1, -60, 0.5, -12)
    toggleBtn.Font = Enum.Font.GothamBold
    toggleBtn.TextSize = 11
    toggleBtn.Parent = row
    Instance.new("UICorner", toggleBtn).CornerRadius = UDim.new(0, 5)

    local function updateButtonStates()
        toggleBtn.Text = PICKUP_CONFIG.Enabled and "ON" or "OFF"
        toggleBtn.BackgroundColor3 = PICKUP_CONFIG.Enabled and Color3.fromRGB(35, 135, 75) or Color3.fromRGB(45, 50, 65)
        toggleBtn.TextColor3 = PICKUP_CONFIG.Enabled and Color3.new(1, 1, 1) or Color3.fromRGB(180, 190, 210)
    end
    updateButtonStates()
    X.syncPickupUI = updateButtonStates

    toggleBtn.MouseButton1Click:Connect(function()
        PICKUP_CONFIG.Enabled = not PICKUP_CONFIG.Enabled
        if currentSettings then currentSettings.PickupEnabled = PICKUP_CONFIG.Enabled end
        if jsonBox then jsonBox.Text = settingsToJSON(currentSettings) or jsonBox.Text end
        updateButtonStates()
    end)

    -- User Input — TAP E
    addConnection(UserInputService.InputBegan:Connect(function(input)
        if not PICKUP_CONFIG.Enabled then return end
        if UserInputService:GetFocusedTextBox() ~= nil then return end
        if input.KeyCode == Enum.KeyCode.E then
            local target = getBestFocusedTarget()
            if target then
                executePickupSpam(target)
            end
        end
    end))

    -- ========================================================================
    -- ROW 2: TRAP EVADE (TEXT | ON/OFF)
    -- ========================================================================
    local rowTrap = Instance.new("Frame")
    rowTrap.Size = UDim2.new(1, 0, 0, 36)
    rowTrap.BackgroundColor3 = Color3.fromRGB(24, 28, 40)
    rowTrap.BorderSizePixel = 0
    rowTrap.LayoutOrder = 2
    rowTrap.Parent = tabUtility
    Instance.new("UICorner", rowTrap).CornerRadius = UDim.new(0, 6)
    local strokeTrap = Instance.new("UIStroke", rowTrap)
    strokeTrap.Color = Color3.fromRGB(45, 55, 75)
    strokeTrap.Thickness = 1

    local lblTrap = Instance.new("TextLabel")
    lblTrap.Size = UDim2.new(1, -70, 1, 0)
    lblTrap.Position = UDim2.new(0, 12, 0, 0)
    lblTrap.BackgroundTransparency = 1
    lblTrap.Text = "Trap Evade"
    lblTrap.TextColor3 = Color3.fromRGB(220, 230, 255)
    lblTrap.Font = Enum.Font.GothamBold
    lblTrap.TextSize = 12
    lblTrap.TextXAlignment = Enum.TextXAlignment.Left
    lblTrap.Parent = rowTrap

    local toggleTrapBtn = Instance.new("TextButton")
    toggleTrapBtn.Size = UDim2.new(0, 52, 0, 24)
    toggleTrapBtn.Position = UDim2.new(1, -60, 0.5, -12)
    toggleTrapBtn.Font = Enum.Font.GothamBold
    toggleTrapBtn.TextSize = 11
    toggleTrapBtn.Parent = rowTrap
    Instance.new("UICorner", toggleTrapBtn).CornerRadius = UDim.new(0, 5)

    local function updateTrapButtonStates()
        local en = X.TRAP_CONFIG and X.TRAP_CONFIG.Enabled
        toggleTrapBtn.Text = en and "ON" or "OFF"
        toggleTrapBtn.BackgroundColor3 = en and Color3.fromRGB(35, 135, 75) or Color3.fromRGB(45, 50, 65)
        toggleTrapBtn.TextColor3 = en and Color3.new(1, 1, 1) or Color3.fromRGB(180, 190, 210)
    end
    updateTrapButtonStates()
    X.syncTrapEvadeUI = updateTrapButtonStates

    toggleTrapBtn.MouseButton1Click:Connect(function()
        X.TRAP_CONFIG.Enabled = not X.TRAP_CONFIG.Enabled
        if currentSettings then currentSettings.TrapEvade = X.TRAP_CONFIG.Enabled end
        if jsonBox then jsonBox.Text = settingsToJSON(currentSettings) or jsonBox.Text end
        updateTrapButtonStates()
        if X.TRAP_CONFIG.Enabled then
            if typeof(X.applyAllTrapNeutralization) == "function" then pcall(X.applyAllTrapNeutralization) end
            if typeof(X.applyCanTouchProtection) == "function" then pcall(X.applyCanTouchProtection) end
            if typeof(X.updateAllTrapVisuals) == "function" then pcall(X.updateAllTrapVisuals) end
        else
            if typeof(X.restoreAllTraps) == "function" then pcall(X.restoreAllTraps) end
            if typeof(X.removeAllTrapVisuals) == "function" then pcall(X.removeAllTrapVisuals) end
            local ch = LocalPlayer.Character
            if ch then
                for _, part in ipairs(ch:GetDescendants()) do
                    if part:IsA("BasePart") then pcall(function() part.CanTouch = true end) end
                end
            end
        end
    end)

    -- ========================================================================
    -- ROW 3: AUTO TREADMILL (TEXT | ON/OFF)
    -- ========================================================================
    local rowTreadmill = Instance.new("Frame")
    rowTreadmill.Size = UDim2.new(1, 0, 0, 36)
    rowTreadmill.BackgroundColor3 = Color3.fromRGB(24, 28, 40)
    rowTreadmill.BorderSizePixel = 0
    rowTreadmill.LayoutOrder = 3
    rowTreadmill.Parent = tabUtility
    Instance.new("UICorner", rowTreadmill).CornerRadius = UDim.new(0, 6)
    local strokeTm = Instance.new("UIStroke", rowTreadmill)
    strokeTm.Color = Color3.fromRGB(45, 55, 75)
    strokeTm.Thickness = 1

    local lblTm = Instance.new("TextLabel")
    lblTm.Size = UDim2.new(1, -70, 1, 0)
    lblTm.Position = UDim2.new(0, 12, 0, 0)
    lblTm.BackgroundTransparency = 1
    lblTm.Text = "Auto Treadmill"
    lblTm.TextColor3 = Color3.fromRGB(220, 230, 255)
    lblTm.Font = Enum.Font.GothamBold
    lblTm.TextSize = 12
    lblTm.TextXAlignment = Enum.TextXAlignment.Left
    lblTm.Parent = rowTreadmill

    local toggleTmBtn = Instance.new("TextButton")
    toggleTmBtn.Size = UDim2.new(0, 52, 0, 24)
    toggleTmBtn.Position = UDim2.new(1, -60, 0.5, -12)
    toggleTmBtn.Font = Enum.Font.GothamBold
    toggleTmBtn.TextSize = 11
    toggleTmBtn.Parent = rowTreadmill
    Instance.new("UICorner", toggleTmBtn).CornerRadius = UDim.new(0, 5)

    local function updateTreadmillButtonState()
        local en = X.autoTreadmillEnabled == true
        toggleTmBtn.Text = en and "ON" or "OFF"
        toggleTmBtn.BackgroundColor3 = en and Color3.fromRGB(35, 135, 75) or Color3.fromRGB(45, 50, 65)
        toggleTmBtn.TextColor3 = en and Color3.new(1, 1, 1) or Color3.fromRGB(180, 190, 210)
    end
    updateTreadmillButtonState()
    X.syncAutoTreadmillUI = updateTreadmillButtonState

    toggleTmBtn.MouseButton1Click:Connect(function()
        X.autoTreadmillEnabled = not X.autoTreadmillEnabled
        if currentSettings then currentSettings.AutoTreadmill = X.autoTreadmillEnabled end
        if jsonBox then jsonBox.Text = settingsToJSON(currentSettings) or jsonBox.Text end
        updateTreadmillButtonState()
    end)

    -- ========================================================================
    -- ROW 4: AUTO DISMOUNT (TEXT | ON/OFF)
    -- ========================================================================
    local rowDismount = Instance.new("Frame")
    rowDismount.Size = UDim2.new(1, 0, 0, 36)
    rowDismount.BackgroundColor3 = Color3.fromRGB(24, 28, 40)
    rowDismount.BorderSizePixel = 0
    rowDismount.LayoutOrder = 4
    rowDismount.Parent = tabUtility
    Instance.new("UICorner", rowDismount).CornerRadius = UDim.new(0, 6)
    local strokeDm = Instance.new("UIStroke", rowDismount)
    strokeDm.Color = Color3.fromRGB(45, 55, 75)
    strokeDm.Thickness = 1

    local lblDm = Instance.new("TextLabel")
    lblDm.Size = UDim2.new(1, -70, 1, 0)
    lblDm.Position = UDim2.new(0, 12, 0, 0)
    lblDm.BackgroundTransparency = 1
    lblDm.Text = "Auto Dismount"
    lblDm.TextColor3 = Color3.fromRGB(220, 230, 255)
    lblDm.Font = Enum.Font.GothamBold
    lblDm.TextSize = 12
    lblDm.TextXAlignment = Enum.TextXAlignment.Left
    lblDm.Parent = rowDismount

    local toggleDmBtn = Instance.new("TextButton")
    toggleDmBtn.Size = UDim2.new(0, 52, 0, 24)
    toggleDmBtn.Position = UDim2.new(1, -60, 0.5, -12)
    toggleDmBtn.Font = Enum.Font.GothamBold
    toggleDmBtn.TextSize = 11
    toggleDmBtn.Parent = rowDismount
    Instance.new("UICorner", toggleDmBtn).CornerRadius = UDim.new(0, 5)

    local function updateDismountButtonState()
        local en = X.autoDismountEnabled == true
        toggleDmBtn.Text = en and "ON" or "OFF"
        toggleDmBtn.BackgroundColor3 = en and Color3.fromRGB(35, 135, 75) or Color3.fromRGB(45, 50, 65)
        toggleDmBtn.TextColor3 = en and Color3.new(1, 1, 1) or Color3.fromRGB(180, 190, 210)
    end
    updateDismountButtonState()
    X.syncAutoDismountUI = updateDismountButtonState

    toggleDmBtn.MouseButton1Click:Connect(function()
        X.autoDismountEnabled = not X.autoDismountEnabled
        if currentSettings then currentSettings.AutoDismount = X.autoDismountEnabled end
        if jsonBox then jsonBox.Text = settingsToJSON(currentSettings) or jsonBox.Text end
        updateDismountButtonState()
        if X.autoDismountEnabled and X.isOnTreadmill() then
            task.spawn(function()
                X.executeAutoDismount(true)
            end)
        end
    end)

    -- ========================================================================
    -- ROW 5: AUTO PEN (TEXT | GO)
    -- ========================================================================
    local rowPen = Instance.new("Frame")
    rowPen.Size = UDim2.new(1, 0, 0, 36)
    rowPen.BackgroundColor3 = Color3.fromRGB(24, 28, 40)
    rowPen.BorderSizePixel = 0
    rowPen.LayoutOrder = 5
    rowPen.Parent = tabUtility
    Instance.new("UICorner", rowPen).CornerRadius = UDim.new(0, 6)
    local strokePen = Instance.new("UIStroke", rowPen)
    strokePen.Color = Color3.fromRGB(45, 55, 75)
    strokePen.Thickness = 1

    local lblPen = Instance.new("TextLabel")
    lblPen.Size = UDim2.new(1, -70, 1, 0)
    lblPen.Position = UDim2.new(0, 12, 0, 0)
    lblPen.BackgroundTransparency = 1
    lblPen.Text = "Auto Pen"
    lblPen.TextColor3 = Color3.fromRGB(220, 230, 255)
    lblPen.Font = Enum.Font.GothamBold
    lblPen.TextSize = 12
    lblPen.TextXAlignment = Enum.TextXAlignment.Left
    lblPen.Parent = rowPen

    local btnPen = Instance.new("TextButton")
    btnPen.Size = UDim2.new(0, 52, 0, 24)
    btnPen.Position = UDim2.new(1, -60, 0.5, -12)
    btnPen.Font = Enum.Font.GothamBold
    btnPen.TextSize = 11
    btnPen.Text = "GO"
    btnPen.BackgroundColor3 = Color3.fromRGB(35, 135, 75)
    btnPen.TextColor3 = Color3.new(1, 1, 1)
    btnPen.Parent = rowPen
    Instance.new("UICorner", btnPen).CornerRadius = UDim.new(0, 5)

    btnPen.MouseButton1Click:Connect(function()
        if X.activeNav == "pen" then
            X.cancelNav = true
            X.activeNav = nil
            btnPen.Text = "GO"
            btnPen.BackgroundColor3 = Color3.fromRGB(35, 135, 75)
            local ch = LocalPlayer.Character
            local hum = ch and ch:FindFirstChildOfClass("Humanoid")
            if hum then pcall(function() hum:Move(Vector3.zero) end) end
            return
        end

        X.cancelNav = false
        X.activeNav = "pen"
        btnPen.Text = "STOP"
        btnPen.BackgroundColor3 = Color3.fromRGB(180, 60, 60)

        task.spawn(function()
            X.executeAutoPen(function() return X.cancelNav or X.activeNav ~= "pen" end)
            if X.activeNav == "pen" then
                X.activeNav = nil
                btnPen.Text = "GO"
                btnPen.BackgroundColor3 = Color3.fromRGB(35, 135, 75)
            end
        end)
    end)

    X.utilityCleanup = function()
        X.cancelNav = true
        X.activeNav = nil
        pcall(function()
            local ch = LocalPlayer.Character
            local hum = ch and ch:FindFirstChildOfClass("Humanoid")
            if hum then hum:Move(Vector3.zero) end
            if typeof(X.restoreAllTraps) == "function" then X.restoreAllTraps() end
            if typeof(X.removeAllTrapVisuals) == "function" then X.removeAllTrapVisuals() end
        end)
    end
end

-- ==================================================
-- MAIN UI BUILDER
-- ==================================================
function X.buildMainUI()
-- ==================================================
-- UI
-- ==================================================
for _, n in ipairs({"EggGoToUI_v4","EggGoToUI_v5","EggGoToUI_v6","EggGoToUI_v7","EggGoToUI_v8","EggGoToUI_v9","EggGoToUI_v10"}) do
    local old = PlayerGui:FindFirstChild(n); if old then old:Destroy() end
end

screenGui = Instance.new("ScreenGui")
screenGui.Name = "EggGoToUI_v10"
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
title.BackgroundTransparency=1; title.Text="Egg Go-To v10 (Master)"
title.TextColor3=Color3.fromRGB(220,230,255); title.TextSize=13; title.Font=Enum.Font.GothamBold
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

tabBtnScramble = Instance.new("TextButton")
tabBtnScramble.Name = "TabBtnScramble"
tabBtnScramble.Size = UDim2.new(0, 34, 0, 34)
tabBtnScramble.Position = UDim2.new(0.5, -17, 0, 90)
tabBtnScramble.BackgroundColor3 = Color3.fromRGB(32, 40, 60)
tabBtnScramble.Text = "🌀"
tabBtnScramble.TextColor3 = Color3.fromRGB(160, 185, 220)
tabBtnScramble.TextSize = 18
tabBtnScramble.Font = Enum.Font.GothamBold
tabBtnScramble.Parent = sidebar
Instance.new("UICorner", tabBtnScramble).CornerRadius = UDim.new(0, 6)

tabBtnUtility = Instance.new("TextButton")
tabBtnUtility.Name = "TabBtnUtility"
tabBtnUtility.Size = UDim2.new(0, 34, 0, 34)
tabBtnUtility.Position = UDim2.new(0.5, -17, 0, 130)
tabBtnUtility.BackgroundColor3 = Color3.fromRGB(32, 40, 60)
tabBtnUtility.Text = "🛠️"
tabBtnUtility.TextColor3 = Color3.fromRGB(160, 185, 220)
tabBtnUtility.TextSize = 18
tabBtnUtility.Font = Enum.Font.GothamBold
tabBtnUtility.Parent = sidebar
Instance.new("UICorner", tabBtnUtility).CornerRadius = UDim.new(0, 6)

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
tabPets.ScrollBarThickness = 0
tabPets.CanvasSize = UDim2.new(0, 0, 0, 0)
tabPets.AutomaticCanvasSize = Enum.AutomaticSize.None
tabPets.ScrollingEnabled = false
tabPets.ClipsDescendants = true
tabPets.Visible = false
tabPets.Parent = contentContainer

-- Tab 3: Scramble Trade-In Suite
tabScramble = Instance.new("ScrollingFrame")
tabScramble.Name = "TabScramble"
tabScramble.Size = UDim2.new(1, 0, 1, 0)
tabScramble.Position = UDim2.new(0, 0, 0, 0)
tabScramble.BackgroundTransparency = 1
tabScramble.BorderSizePixel = 0
tabScramble.ScrollBarThickness = 5
tabScramble.CanvasSize = UDim2.new(0, 0, 0, 0)
tabScramble.AutomaticCanvasSize = Enum.AutomaticSize.Y
tabScramble.ClipsDescendants = true
tabScramble.Visible = false
tabScramble.Parent = contentContainer

-- Tab 4: Utility Suite (Empty for now)
tabUtility = Instance.new("ScrollingFrame")
tabUtility.Name = "TabUtility"
tabUtility.Size = UDim2.new(1, 0, 1, 0)
tabUtility.Position = UDim2.new(0, 0, 0, 0)
tabUtility.BackgroundTransparency = 1
tabUtility.BorderSizePixel = 0
tabUtility.ScrollBarThickness = 5
tabUtility.CanvasSize = UDim2.new(0, 0, 0, 0)
tabUtility.AutomaticCanvasSize = Enum.AutomaticSize.Y
tabUtility.ClipsDescendants = true
tabUtility.Visible = false
tabUtility.Parent = contentContainer

local tabUtilityLayout = Instance.new("UIListLayout")
tabUtilityLayout.Padding = UDim.new(0, 8)
tabUtilityLayout.SortOrder = Enum.SortOrder.LayoutOrder
tabUtilityLayout.Parent = tabUtility

local tabUtilityPad = Instance.new("UIPadding")
tabUtilityPad.PaddingTop = UDim.new(0, 10)
tabUtilityPad.PaddingBottom = UDim.new(0, 12)
tabUtilityPad.PaddingLeft = UDim.new(0, 10)
tabUtilityPad.PaddingRight = UDim.new(0, 10)
tabUtilityPad.Parent = tabUtility

refreshPetCards = nil

switchTab = function(tabName)
    if tabName == "Eggs" then
        main.Size = UDim2.new(0, 380, 0, 520)
        tabEggs.Visible = true
        tabPets.Visible = false
        tabScramble.Visible = false
        if tabUtility then tabUtility.Visible = false end
        tabBtnEggs.BackgroundColor3 = Color3.fromRGB(45, 100, 160)
        tabBtnEggs.TextColor3 = Color3.new(1, 1, 1)
        tabBtnPets.BackgroundColor3 = Color3.fromRGB(32, 40, 60)
        tabBtnPets.TextColor3 = Color3.fromRGB(160, 185, 220)
        tabBtnScramble.BackgroundColor3 = Color3.fromRGB(32, 40, 60)
        tabBtnScramble.TextColor3 = Color3.fromRGB(160, 185, 220)
        if tabBtnUtility then
            tabBtnUtility.BackgroundColor3 = Color3.fromRGB(32, 40, 60)
            tabBtnUtility.TextColor3 = Color3.fromRGB(160, 185, 220)
        end
    elseif tabName == "Pets" then
        main.Size = UDim2.new(0, 380, 0, 520)
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
        tabScramble.Visible = false
        if tabUtility then tabUtility.Visible = false end
        tabBtnEggs.BackgroundColor3 = Color3.fromRGB(32, 40, 60)
        tabBtnEggs.TextColor3 = Color3.fromRGB(160, 185, 220)
        tabBtnPets.BackgroundColor3 = Color3.fromRGB(45, 100, 160)
        tabBtnPets.TextColor3 = Color3.new(1, 1, 1)
        tabBtnScramble.BackgroundColor3 = Color3.fromRGB(32, 40, 60)
        tabBtnScramble.TextColor3 = Color3.fromRGB(160, 185, 220)
        if tabBtnUtility then
            tabBtnUtility.BackgroundColor3 = Color3.fromRGB(32, 40, 60)
            tabBtnUtility.TextColor3 = Color3.fromRGB(160, 185, 220)
        end
        if refreshPetCards then refreshPetCards() end
    elseif tabName == "Scramble" then
        main.Size = UDim2.new(0, 380, 0, 520)
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
        tabPets.Visible = false
        tabScramble.Visible = true
        if tabUtility then tabUtility.Visible = false end
        tabBtnEggs.BackgroundColor3 = Color3.fromRGB(32, 40, 60)
        tabBtnEggs.TextColor3 = Color3.fromRGB(160, 185, 220)
        tabBtnPets.BackgroundColor3 = Color3.fromRGB(32, 40, 60)
        tabBtnPets.TextColor3 = Color3.fromRGB(160, 185, 220)
        tabBtnScramble.BackgroundColor3 = Color3.fromRGB(45, 100, 160)
        tabBtnScramble.TextColor3 = Color3.new(1, 1, 1)
        if tabBtnUtility then
            tabBtnUtility.BackgroundColor3 = Color3.fromRGB(32, 40, 60)
            tabBtnUtility.TextColor3 = Color3.fromRGB(160, 185, 220)
        end
        if refreshScrambleUI then refreshScrambleUI() end
    elseif tabName == "Utility" then
        main.Size = UDim2.new(0, 380, 0, 520)
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
        tabPets.Visible = false
        tabScramble.Visible = false
        if tabUtility then tabUtility.Visible = true end
        tabBtnEggs.BackgroundColor3 = Color3.fromRGB(32, 40, 60)
        tabBtnEggs.TextColor3 = Color3.fromRGB(160, 185, 220)
        tabBtnPets.BackgroundColor3 = Color3.fromRGB(32, 40, 60)
        tabBtnPets.TextColor3 = Color3.fromRGB(160, 185, 220)
        tabBtnScramble.BackgroundColor3 = Color3.fromRGB(32, 40, 60)
        tabBtnScramble.TextColor3 = Color3.fromRGB(160, 185, 220)
        if tabBtnUtility then
            tabBtnUtility.BackgroundColor3 = Color3.fromRGB(45, 100, 160)
            tabBtnUtility.TextColor3 = Color3.new(1, 1, 1)
        end
    end
end
tabBtnEggs.MouseButton1Click:Connect(function() switchTab("Eggs") end)
tabBtnPets.MouseButton1Click:Connect(function() switchTab("Pets") end)
tabBtnScramble.MouseButton1Click:Connect(function() switchTab("Scramble") end)
tabBtnUtility.MouseButton1Click:Connect(function() switchTab("Utility") end)

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
velInputBox.PlaceholderText="330"; velInputBox.TextColor3=Color3.new(1,1,1)
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
carryVelInputBox.PlaceholderText="300"; carryVelInputBox.TextColor3=Color3.new(1,1,1)
carryVelInputBox.TextSize=12; carryVelInputBox.Font=Enum.Font.GothamBold; carryVelInputBox.ClearTextOnFocus=false
carryVelInputBox.TextXAlignment=Enum.TextXAlignment.Left; carryVelInputBox.Parent=carryFrame

-- Row 2: Recovery (left) + Velocity Live Status (right)
local ROW2_Y = ROW1_Y + ROW_H + ROW_GAP
local REC_BTN_W = 152
local VEL_LBL_W = 152
local ROW2_GAP  = 6

recoveryToggleBtn = Instance.new("TextButton")
recoveryToggleBtn.Size = UDim2.new(0, REC_BTN_W, 0, ROW_H)
recoveryToggleBtn.Position = UDim2.new(0, 12, 0, ROW2_Y)
recoveryToggleBtn.BackgroundColor3 = Color3.fromRGB(35, 135, 75)
recoveryToggleBtn.Text = "[ON] Recovery"
recoveryToggleBtn.TextColor3 = Color3.new(1, 1, 1)
recoveryToggleBtn.TextSize = 11
recoveryToggleBtn.Font = Enum.Font.GothamBold
recoveryToggleBtn.Parent = tabEggs
Instance.new("UICorner", recoveryToggleBtn).CornerRadius = UDim.new(0, 6)

velStatusLabel = Instance.new("TextLabel")
velStatusLabel.Size = UDim2.new(0, VEL_LBL_W, 0, ROW_H)
velStatusLabel.Position = UDim2.new(0, 12 + REC_BTN_W + ROW2_GAP, 0, ROW2_Y)
velStatusLabel.BackgroundColor3 = Color3.fromRGB(24, 29, 40)
velStatusLabel.Text = "Vel: 0"
velStatusLabel.TextColor3 = Color3.fromRGB(140, 190, 240)
velStatusLabel.TextSize = 11
velStatusLabel.Font = Enum.Font.GothamBold
velStatusLabel.TextXAlignment = Enum.TextXAlignment.Center
velStatusLabel.Parent = tabEggs
Instance.new("UICorner", velStatusLabel).CornerRadius = UDim.new(0, 6)

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

local farmDropListLayout = Instance.new("UIListLayout")
farmDropListLayout.Padding = UDim.new(0, 2)
farmDropListLayout.SortOrder = Enum.SortOrder.LayoutOrder
farmDropListLayout.Parent = farmDropScroll

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
    X.buildPetsTabUI()
    -- Populate Tab 3 (Dr. Scramble Trade-In)
    X.buildScrambleTabUI()
    -- Populate Tab 4 (Utility Suite)
    X.buildUtilityTabUI()
end
X.buildMainUI()
if typeof(X.initTrapEvade) == "function" then pcall(X.initTrapEvade) end
if typeof(X.initNightResetMonitor) == "function" then pcall(X.initNightResetMonitor) end
-- ==================================================
-- EGG CARD  (compact single-row list item)
-- ==================================================
-- ==================================================
-- EGG CARD POOL & RENDERER (Zero-Allocation DOM Recycling)
-- ==================================================
local function updateOrCreateCard(idx, r)
    if typeof(r) ~= "table" then return end
    local uid      = tostring(r.Uid or "")
    local rawCat   = tostring(r.AssetCategory or "Unknown")
    local dispName = (X.getDisplayEggName and X.getDisplayEggName(rawCat)) or rawCat
    local slot     = tostring(r.NestId or "?")
    local area     = tostring(r.AreaId or "?")
    local pos      = extPos(r)
    local mut      = mutLabel(r)
    local hl       = highlightRarity(r)
    local fullRar  = effectiveRarity(r)
    local rarCol   = ALL_RARITY_COLORS[fullRar] or RARITY_DEFAULT_COLOR

    local isFarming = (uid ~= "" and (uid == X.currentWalkingEggUid or uid == carryUid))
    local bg = isFarming and Color3.fromRGB(24, 60, 42)
        or (hl and Color3.fromRGB(45, 18, 18) or Color3.fromRGB(26, 30, 40))

    local item = X.cardPool[idx]
    if not item then
        local card = Instance.new("Frame")
        card.Size             = UDim2.new(1, -12, 0, X.CARD_HEIGHT)
        card.BackgroundColor3 = bg
        card.BorderSizePixel  = 0
        card.Parent           = listFrame
        Instance.new("UICorner", card).CornerRadius = UDim.new(0, 6)

        local strip = Instance.new("Frame")
        strip.Size             = UDim2.new(0, 3, 1, -6)
        strip.Position         = UDim2.new(0, 4, 0, 3)
        strip.BackgroundColor3 = rarCol
        strip.BorderSizePixel  = 0
        strip.Parent           = card
        Instance.new("UICorner", strip).CornerRadius = UDim.new(0, 2)

        local LEFT = 13   -- x offset after the strip
        local nm = Instance.new("TextLabel")
        nm.Size               = UDim2.new(1, -(LEFT + 138), 0, 18)
        nm.Position           = UDim2.new(0, LEFT, 0, 2)
        nm.BackgroundTransparency = 1
        nm.TextSize           = 11.5
        nm.Font               = Enum.Font.GothamBold
        nm.TextXAlignment     = Enum.TextXAlignment.Left
        nm.TextTruncate       = Enum.TextTruncate.AtEnd
        nm.Parent             = card

        local sub = Instance.new("TextLabel")
        sub.Size               = UDim2.new(1, -(LEFT + 138), 0, 13)
        sub.Position           = UDim2.new(0, LEFT, 0, 19)
        sub.BackgroundTransparency = 1
        sub.TextColor3         = Color3.fromRGB(130, 145, 175)
        sub.TextSize           = 10
        sub.Font               = Enum.Font.Gotham
        sub.TextXAlignment     = Enum.TextXAlignment.Left
        sub.TextTruncate       = Enum.TextTruncate.AtEnd
        sub.Parent             = card

        local rab = Instance.new("TextLabel")
        rab.Size               = UDim2.new(0, 68, 0, 16)
        rab.Position           = UDim2.new(1, -134, 0.5, -8)
        rab.BackgroundColor3   = rarCol
        rab.TextColor3         = Color3.new(1, 1, 1)
        rab.TextSize           = 9
        rab.Font               = Enum.Font.GothamBold
        rab.TextXAlignment     = Enum.TextXAlignment.Center
        rab.TextTruncate       = Enum.TextTruncate.AtEnd
        rab.Parent             = card
        Instance.new("UICorner", rab).CornerRadius = UDim.new(0, 4)

        local gb = Instance.new("TextButton")
        gb.Size             = UDim2.new(0, 54, 0, 24)
        gb.Position         = UDim2.new(1, -62, 0.5, -12)
        gb.BackgroundColor3 = isFarming and Color3.fromRGB(30, 115, 65) or Color3.fromRGB(38, 125, 75)
        gb.Text             = isFarming and "Farm" or "Get"
        gb.TextColor3       = Color3.new(1, 1, 1)
        gb.TextSize         = 12
        gb.Font             = Enum.Font.GothamBold
        gb.Parent           = card
        Instance.new("UICorner", gb).CornerRadius = UDim.new(0, 5)

        item = { card = card, strip = strip, nm = nm, sub = sub, rab = rab, gb = gb, pos = pos, uid = uid }
        X.cardPool[idx] = item

        gb.MouseButton1Click:Connect(function()
            if autoFarmEnabled then toggleAutoFarm() end
            local targetPos = item.pos
            if not targetPos and item.uid then
                local curRec = eggCache.byUid and eggCache.byUid[item.uid]
                targetPos = curRec and extPos(curRec)
                if not targetPos and X.nestPos then
                    targetPos = X.nestPos[item.uid]
                end
            end
            if targetPos then
                getEgg(targetPos, item.uid, statusLabel)
            else
                statusLabel.Text = "No position"
                statusLabel.TextColor3 = Color3.fromRGB(255, 120, 120)
            end
        end)
    end

    item.pos = pos
    item.uid = uid
    item.card.LayoutOrder = idx
    item.card.BackgroundColor3 = bg
    item.strip.BackgroundColor3 = rarCol

    local isNewOrUnk = X.isNewOrUnknownEgg and X.isNewOrUnknownEgg(r)
    local titleSuffix = isFarming and "  [FARMING]" or (isNewOrUnk and "  [NEW/UNKNOWN]" or "")
    item.nm.Text = string.format("%s%s", dispName, titleSuffix)
    item.nm.TextColor3 = isFarming and Color3.fromRGB(120, 255, 170)
        or (isNewOrUnk and Color3.fromRGB(255, 220, 110)
        or (hl and Color3.fromRGB(255, 195, 195) or Color3.fromRGB(215, 225, 255)))

    local subParts = { area, slot }
    if dispName ~= rawCat and rawCat ~= "Unknown" then
        table.insert(subParts, "[" .. rawCat .. "]")
    end
    if mut then table.insert(subParts, mut) end
    item.sub.Text = table.concat(subParts, " · ")

    item.rab.Text = " " .. fullRar .. " "
    item.rab.BackgroundColor3 = rarCol

    item.gb.BackgroundColor3 = isFarming and Color3.fromRGB(30, 115, 65) or Color3.fromRGB(38, 125, 75)
    item.gb.Text = isFarming and "Farm" or "Get"
    item.card.Visible = true
end

-- ==================================================
-- SCAN / RENDER
-- ==================================================
local function clearList()
    for _, it in ipairs(X.cardPool) do
        it.card.Visible = false
    end
end

local function ingestSpecies(records)
    local changed = false
    for _, r in ipairs(records) do
        local s = r.AssetCategory
        if typeof(s)=="string" and s~="" then
            local disp = (X.getDisplayEggName and X.getDisplayEggName(s)) or s
            if not speciesSeen[disp] then
                speciesSeen[disp] = true
                table.insert(speciesOrder, disp)
                changed = true
            end
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

local lastRenderTime = 0
local function renderRecords(records, quiet)
    -- OFF-SCREEN GATE (Issue #2): Skip card DOM updates if window is closed or not on Eggs tab
    if not main.Visible or not tabEggs.Visible then return end
    local now = os.clock()
    if now - lastRenderTime < 0.25 then return end
    lastRenderTime = now

    local sl = quiet and { Text = "", TextColor3 = Color3.new() } or statusLabel
    if ingestSpecies(records) and farmDropdownOpen and rebuildFarmDropdownItems then
        rebuildFarmDropdownItems()
    end
    if #records == 0 then
        sl.Text = "No eggs found"; sl.TextColor3 = Color3.fromRGB(255,160,100)
        clearList()
        listFrame.CanvasSize = UDim2.new(0, 0, 0, 0); return
    end

    local d = 0; local mc = 0; local rc = 0; local hid = 0; local unv = 0; local biomes = {}
    for _, r in ipairs(records) do
        if typeof(r) == "table" then
            if passesFilters(r) then
                d = d + 1
                local okc, ec = pcall(updateOrCreateCard, d, r)
                if not okc then warn("[EggGoToUI] card update error:", ec) end
                if mutLabel(r) then mc = mc + 1 end
                if highlightRarity(r) then rc = rc + 1 end
                if r.AreaId then biomes[tostring(r.AreaId)] = true end
            else
                local gh, why = X.isGhost(r)
                if gh then hid = hid + 1
                elseif X.isUnverified(r) then unv = unv + 1 end
            end
        end
    end

    -- Hide remaining cards in the pool beyond active count d
    for j = d + 1, #X.cardPool do
        X.cardPool[j].card.Visible = false
    end

    listFrame.CanvasSize = UDim2.new(0, 0, 0, d * (X.CARD_HEIGHT + 3))
    if d == 0 then
        sl.Text = "No eggs match active filters"; sl.TextColor3 = Color3.fromRGB(255,160,100); return
    end
    local bc = 0; for _ in pairs(biomes) do bc = bc + 1 end
    local farmCount = 0; for _ in pairs(selectedSpecies) do farmCount = farmCount + 1 end
    local suffix = selectedSpecies["All"] and "" or (" | " .. (farmCount) .. " species")
    local sum = ("%d eggs across %d biome(s)%s"):format(d, bc, suffix)
    if hid > 0 then sum = sum .. (" | %d hidden"):format(hid) end
    if unv > 0 then sum = sum .. (" | %d unverified"):format(unv) end
    if mc > 0 then sum = sum .. (" | %d mutated"):format(mc) end
    if rc > 0 then sum = sum .. (" | ⚠ %d HIGH"):format(rc) end
    sl.Text = sum
    sl.TextColor3 = rc > 0 and Color3.fromRGB(255,120,120) or Color3.fromRGB(120,255,150)
end

local function scanEggs()
    statusLabel.Text = "Fetching all eggs..."; statusLabel.TextColor3 = Color3.fromRGB(255,220,100)
    task.spawn(function()
        local recs, e = X.fetchTimed(4)
        if not recs then
            statusLabel.Text = "Error: " .. tostring(e); statusLabel.TextColor3 = Color3.fromRGB(255,120,120); return
        end
        local by = {}
        for _, r in ipairs(recs) do
            local u = typeof(r) == "table" and tostring(r.Uid or "") or ""
            if u ~= "" then by[u] = r end
        end
        pcall(X.updateSlotGhosts, by, recs)
        lastFetchedRecords = recs; renderRecords(recs)
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
    if typeof(recs) ~= "table" then return end
    if ingestSpecies(recs) and farmDropdownOpen and rebuildFarmDropdownItems then
        rebuildFarmDropdownItems()
    end
    local parts = { tostring(#recs), tostring(X.currentWalkingEggUid or ""), tostring(carryUid or "") }
    for _, r in ipairs(recs) do
        if typeof(r) == "table" and passesFilters(r) then
            table.insert(parts, tostring(r.Uid or "") .. ":" .. tostring(r.AssetCategory or "") .. ":" .. (r.Mutations and #r.Mutations or 0))
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

    local idx = 0
    for _, sp in ipairs(speciesOrder) do
        if q == "" or string.find(string.lower(sp), q, 1, true) then
            idx = idx + 1
            local btn = Instance.new("TextButton")
            btn.Size = UDim2.new(1,-4,0,22)
            btn.LayoutOrder = idx
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
        local fh = #speciesOrder * 24
        local maxH = X.MAX_FARM_DD_HEIGHT or MAX_FARM_DD_HEIGHT or 200
        local sh = math.min(fh, maxH)
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
    local clipOk = X.copyToClipboard and X.copyToClipboard(j)
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
    if typeof(X.utilityCleanup) == "function" then
        pcall(X.utilityCleanup)
    end
    if typeof(X.restoreAllTraps) == "function" then
        pcall(X.restoreAllTraps)
    end
    if X.recoveryConnections then
        for _, conn in ipairs(X.recoveryConnections) do
            pcall(function() conn:Disconnect() end)
        end
        table.clear(X.recoveryConnections)
    end
    if X.jointsTable then table.clear(X.jointsTable) end
    if X.cardPool then table.clear(X.cardPool) end
    enablePlayerControls()
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
        for _, n in ipairs({"EggGoToUI_v4","EggGoToUI_v5","EggGoToUI_v6","EggGoToUI_v7","EggGoToUI_v8","EggGoToUI_v9","EggGoToUI_v10"}) do
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
local lastHeartbeatUiUpdate = 0

addConnection(RunService.Heartbeat:Connect(function()
    -- 1. Character mechanics
    updateRagdollStatus()
    applyRecovery()
    X.detectRubberband()
    applyVelocity()

    -- 2. UI Label updates throttled to 10 Hz (every 0.1s)
    local now = os.clock()
    if now - lastHeartbeatUiUpdate >= 0.1 then
        lastHeartbeatUiUpdate = now

        local ch = LocalPlayer.Character
        local h = ch and ch:FindFirstChildOfClass("Humanoid")
        local r = ch and ch:FindFirstChild("HumanoidRootPart")
        if not h or not r then
            if velStatusLabel then velStatusLabel.Text = "Vel: --" end
            return
        end
        local hv = Vector3.new(r.AssemblyLinearVelocity.X, 0, r.AssemblyLinearVelocity.Z)
        local v = math.floor(hv.Magnitude)
        if isRagdolled then
            local tag = recoveryEnabled and "REC" or "RAG"
            velStatusLabel.Text = ("Vel: %d | %s"):format(v, tag)
            velStatusLabel.TextColor3 = Color3.fromRGB(255, 180, 80)
        else
            local egg = isHoldingEgg()
            velStatusLabel.Text = ("Vel: %d%s%s"):format(
                v,
                egg and " | Egg" or "",
                recoveryActive and " | Rec" or ""
            )
            velStatusLabel.TextColor3 = velocityEnabled and Color3.fromRGB(100, 240, 255) or Color3.fromRGB(140, 190, 240)
        end
    end
end))

addConnection(LocalPlayer.CharacterAdded:Connect(function(ch)
    task.wait(0.2)
    recoveryActive=false; recoveryState=RECOVERY_STATE.NONE
    lastMoveDirection=Vector3.zero; isRagdolled=false
    X.wasRagdolledForVelocity=false; lastGoodCFrame=nil
    bindCharacter(ch)
    local h=ch:FindFirstChildOfClass("Humanoid")
    if velocityEnabled then
        setFrictionless(true)
        if h then savedWalkSpeed=h.WalkSpeed end
    end
end))

do
    local ch=LocalPlayer.Character
    if ch then
        bindCharacter(ch)
    end
end

-- Init
installRecoveryMetamethods()
applySettings(deepCopy(DEFAULT_SETTINGS))
upVelBtn(); upRecBtn(); updateFarmBtnText()
rebuildFarmDropdownItems()
if X.refreshRarityUI then X.refreshRarityUI() end
velInputBox.Text=tostring(math.floor(X.baseVelocity))
carryVelInputBox.Text=tostring(math.floor(X.baseCarryVelocity))
jsonBox.Text=settingsToJSON(currentSettings) or "{}"

task.defer(scanEggs)

print("[EggGoToUI v10] Master Rebuild Loaded Successfully.")

end) -- end pcall

if not ok then
    warn("[EggGoToUI v10] FAILED TO LOAD: " .. tostring(err))
end
