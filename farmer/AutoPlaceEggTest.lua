--[[
    ================================================================================
    STEAL AN EGG - AUTO PLACE EGG TEST HARNESS & BAG GROUPING INSPECTOR
    ================================================================================
    Features:
      1. Authoritative Bag Scanner:
         - Scans unplaced eggs from RF/ProfileMirror/FetchProfile (EggInventory where Placement == nil)
         - Scans egg tools from LocalPlayer.Backpack & LocalPlayer.Character
      2. Grouping Engine:
         - Groups bag eggs by Group / Egg Type (e.g. "Biohazard Egg", "Angels & Demons Egg")
         - Further breaks down each group by Rarity (Divine, Eternal, Secret, Cosmic, Mythic, Legendary, Epic, Rare, Uncommon, Common)
         - Computes counts, weights, and UIDs
      3. Interactive GUI & Selector:
         - Select which Group + Rarity to place on your plot
         - Live monospace log terminal with [📋 COPY REPORT] button
      4. Auto Pen Placement Protocol:
         - Invokes RF/EggWorld/AskPlaceEgg with { LocalCFrame = localCF, Uid = uid }
         - Fires RE/ToolTrigger/Trigger with the equipped egg tool instance
         - Computes slot coordinates in the player's pen grid
    ================================================================================
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")
local CoreGui           = game:GetService("CoreGui")
local RunService        = game:GetService("RunService")
local HttpService       = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    LocalPlayer = Players:GetPropertyChangedSignal("LocalPlayer"):Wait() or Players.LocalPlayer
end

-- ================================================================================
-- CONSTANTS & CANONICAL RARITIES
-- ================================================================================
local RARITY_RANK = {
    ["Divine"]    = 10,
    ["Eternal"]   = 9,
    ["Secret"]    = 8,
    ["Cosmic"]    = 7,
    ["Mythic"]    = 6,
    ["Legendary"] = 5,
    ["Epic"]      = 4,
    ["Rare"]      = 3,
    ["Uncommon"]  = 2,
    ["Common"]    = 1,
    ["Unknown"]   = 0,
}

local RARITY_COLORS = {
    ["Divine"]    = Color3.fromRGB(255, 75, 230),
    ["Eternal"]   = Color3.fromRGB(75, 220, 255),
    ["Secret"]    = Color3.fromRGB(255, 60, 60),
    ["Cosmic"]    = Color3.fromRGB(180, 80, 255),
    ["Mythic"]    = Color3.fromRGB(255, 170, 0),
    ["Legendary"] = Color3.fromRGB(255, 215, 0),
    ["Epic"]      = Color3.fromRGB(160, 60, 220),
    ["Rare"]      = Color3.fromRGB(60, 140, 255),
    ["Uncommon"]  = Color3.fromRGB(60, 220, 90),
    ["Common"]    = Color3.fromRGB(180, 180, 180),
    ["Unknown"]   = Color3.fromRGB(130, 140, 150),
}

local PET_RARITY_PRESETS = {
    -- Divine
    ["ArchAngel"]="Divine", ["World Burner"]="Divine", ["Archdemon Dragon"]="Divine",
    ["Unicorn"]="Divine", ["Kitsune"]="Divine", ["Nightflame"]="Divine", ["Godzilla"]="Divine",
    ["Nuclear Mantis"]="Divine", ["Cthulhu"]="Divine", ["Luminous Cthulhu"]="Divine",
    ["Shattered Colossus"]="Divine", ["Dreadscale"]="Divine", ["Mecha Dreadscale"]="Divine",
    ["Depths Riptide Octopus"]="Divine", ["Aetheron"]="Divine", ["Octophant"]="Divine",

    -- Eternal
    ["Eternal Lunar Dragon"]="Eternal", ["Skeleton Horse"]="Eternal", ["Pegasus"]="Eternal",
    ["Oni Tiger"]="Eternal", ["King Kong"]="Eternal", ["Gorilla King"]="Eternal",
    ["Mosasaurus"]="Eternal", ["Ice Dragon"]="Eternal", ["El Maja"]="Eternal",
    ["Riptide Octopus"]="Eternal", ["Phoenix"]="Eternal", ["Ascended Vermilion Phoenix"]="Eternal",
    ["Lava Dragon"]="Eternal", ["Dragon"]="Eternal", ["Nuceodille"]="Eternal",
    ["Void Dragon"]="Eternal", ["Shattered Drake"]="Eternal", ["Void Serpent"]="Eternal",
    ["World Eater"]="Eternal", ["Strawberry Elephant"]="Eternal", ["Krakenoid"]="Eternal",
    ["Mecha Krakenoid"]="Eternal", ["Terra Snapper"]="Eternal", ["Luminous Terra Snapper"]="Eternal",
    ["Balrog"]="Eternal", ["Equinox"]="Eternal",

    -- Secret
    ["Alien Skeleton Boss"]="Secret", ["Cosmic Skeleton Boss"]="Secret",
    ["Cave Dragon"]="Secret", ["Cosmic Dragon"]="Secret",
    ["Cosmic Fox"]="Secret", ["Dark Gargoyle"]="Secret", ["Gargoyle"]="Secret",
    ["Centaur"]="Secret", ["Jellyfish"]="Secret", ["Pure Jellyfish"]="Secret",
    ["RazorFang"]="Secret", ["Stag"]="Secret", ["TyrannosaurusRex"]="Secret",
    ["TRex"]="Secret", ["Tralaledon"]="Secret", ["Yeti"]="Secret",
    ["Mutant Shark"]="Secret", ["Kraken"]="Secret", ["Biohazard"]="Secret",
    ["Biohazard Egg"]="Secret", ["Experiment Egg"]="Secret",
    ["Cerberus"]="Secret", ["King Snake"]="Secret", ["Warden"]="Secret",
    ["Bomboclat Crocolat"]="Secret", ["Crocodon"]="Secret", ["Mecha Crocodon"]="Secret",
    ["Electric Eel"]="Secret", ["Luminous Electric Eel"]="Secret", ["Abyss Overlord"]="Secret",
    ["Ember Dragon"]="Secret", ["Experiment #001"]="Secret", ["LimitedTimeExperimentPet"]="Secret", ["Mawbreaker"]="Secret",
    ["Shardwing"]="Secret", ["Wendigo"]="Secret", ["Ringlord"]="Secret",

    -- Cosmic
    ["Cosmic Lion"]="Cosmic", ["La Vacca Saturno Saturnita"]="Cosmic", ["Mantis"]="Cosmic",
    ["Drilla"]="Cosmic", ["Imp"]="Cosmic", ["Demon Hound"]="Cosmic", ["Moth"]="Cosmic",
    ["Sacred Moth"]="Cosmic", ["Peacock"]="Cosmic", ["Holy Peacock"]="Cosmic",
    ["Spirit Panda"]="Cosmic", ["Spirit Hare"]="Cosmic", ["Koi"]="Cosmic",
    ["Snowy Owl"]="Cosmic", ["Rhino"]="Cosmic", ["Rhinotaur"]="Cosmic",
    ["Triceratops"]="Cosmic", ["Bronto"]="Cosmic", ["King Mammoth"]="Cosmic",
    ["Colossal Mammoth"]="Cosmic", ["Whale Shark"]="Cosmic", ["Beluga Whale"]="Cosmic",
    ["Royal Sphinx"]="Cosmic", ["Irihorus"]="Cosmic", ["Crawler"]="Cosmic",
    ["Mecha Crawler"]="Cosmic", ["Abyss Shark"]="Cosmic", ["Luminous Abyss Shark"]="Cosmic",
    ["Leviathan"]="Cosmic", ["Basilisk"]="Cosmic", ["Nibbles #013"]="Cosmic",
    ["Dreadclaw"]="Cosmic", ["Shattered Ram"]="Cosmic", ["Ventinal"]="Cosmic",
    ["Mangolini Parrochini"]="Cosmic", ["Radcoon"]="Cosmic", ["Spiderpig"]="Cosmic",
    ["Three Headed Chicken"]="Cosmic", ["Stacked Turtle"]="Cosmic",

    -- Mythic
    ["Cyclops Gorilla"]="Mythic", ["Cosmic Gorilla"]="Mythic", ["Cosmic Beetle Blue"]="Mythic",
    ["Lamb"]="Mythic", ["Winged Lamb"]="Mythic", ["Toro"]="Mythic", ["Toucax"]="Mythic",
    ["Red Panda"]="Mythic", ["Enchanted Bluejay"]="Mythic", ["Blade Head"]="Mythic",
    ["Rhinobear"]="Mythic", ["Ankylosaurus"]="Mythic", ["Mammoth"]="Mythic",
    ["Sabertooth Tiger"]="Mythic", ["Orca"]="Mythic", ["Sand Spider"]="Mythic",
    ["Scorpion"]="Mythic", ["DeathstalkerScorpion"]="Mythic", ["Chillin Chilli"]="Mythic",
    ["Froggo"]="Mythic", ["Mecha Froggo"]="Mythic", ["Spirit Manta"]="Mythic",
    ["Luminous Spirit Manta"]="Mythic", ["Belula Beluga"]="Mythic", ["Shadow Dragon"]="Mythic",
    ["Riftwing"]="Mythic", ["Shardling"]="Mythic", ["Voidmaw"]="Mythic", ["Tiger"]="Mythic",
    ["Spider"]="Mythic", ["Toxic Rat"]="Mythic", ["Wheel Hamster"]="Mythic",
    ["Frogfly"]="Mythic",

    -- Legendary
    ["Galaxy Gecko"]="Legendary", ["Cosmic Gecko"]="Legendary", ["Flame Sprite"]="Legendary",
    ["Salamander"]="Legendary", ["Kaiju Spider"]="Legendary", ["Crab"]="Legendary",
    ["Sharkodile"]="Legendary", ["Pterodactyl"]="Legendary", ["Polar Bear"]="Legendary",
    ["Shark"]="Legendary", ["Finned Thresher"]="Legendary", ["Snake"]="Legendary",
    ["Rattlesnake"]="Legendary", ["Hellhound"]="Legendary", ["Lava Iguana"]="Legendary",
    ["Flaming Bull"]="Legendary", ["Scorpio"]="Legendary", ["Mecha Scorpio"]="Legendary",
    ["Spike"]="Legendary", ["Luminous Spike"]="Legendary", ["Baby Aurora Dragon"]="Legendary",
    ["Rift Eye"]="Legendary", ["Void Angler"]="Legendary", ["Dove"]="Legendary",
    ["Brr Brr Patapim"]="Legendary", ["Axolotl"]="Legendary", ["Dream Axolotl"]="Legendary",
    ["Gorilla"]="Legendary", ["Prism Gecko"]="Legendary",

    -- Epic
    ["Centapede"]="Epic", ["Crane"]="Epic", ["Walrus"]="Epic", ["Swordfish"]="Epic",
    ["Toxic Crocodile"]="Epic", ["Tob Tobi Tob Tob"]="Epic", ["Uncoiled Armadillo"]="Epic",
    ["Lava Frog"]="Epic", ["Citadel Snail"]="Epic", ["Ash Gecko"]="Epic",
    ["Bananita Dolphinita"]="Epic", ["Trulimero Trulicina"]="Epic", ["Swan"]="Epic",
    ["Fox"]="Epic", ["Bear"]="Epic", ["Crocodile"]="Epic",

    -- Rare
    ["Dodo"]="Rare", ["Penguin"]="Rare", ["Parrotfish"]="Rare", ["Toxic Hedgehog"]="Rare",
    ["Camel"]="Rare", ["DesertLark"]="Rare", ["Lava Gecko"]="Rare", ["Tung Tung Sahur"]="Rare",
    ["Burrowing Owl"]="Rare", ["Owl"]="Rare", ["Raccoon"]="Rare", ["Turtle"]="Rare",
    ["Toucan"]="Rare", ["Chimpanzee"]="Rare",

    -- Uncommon
    ["Catfish"]="Uncommon", ["Bird"]="Uncommon", ["Fennec"]="Uncommon", ["FennecFox"]="Uncommon",

    -- Common
    ["Chicken"]="Common", ["Dog"]="Common", ["Frog"]="Common", ["Duckling"]="Common",
    ["Jerboa"]="Common",
}

local ALL_BIOMES_AND_EVENTS = {
    "Angels & Demons Egg",
    "Biohazard Egg",
    "Boss Egg",
    "Cherry Blossom Egg",
    "Cosmic Egg",
    "Crystal Egg",
    "Depths Egg",
    "Depths Reroll Egg",
    "Desert Egg",
    "Dragon Egg",
    "Egg",
    "Enchanted Forest Egg",
    "Experiment Egg",
    "Extinction Egg",
    "Lava Egg",
    "Light Dove Egg",
    "Luminous Egg",
    "Mecha Egg",
    "Monster Egg",
    "Monstrous Egg",
    "Ocean Egg",
    "Prehistoric Egg",
    "Riftbeasts Egg",
    "Riftborn Egg",
    "Shattered Rift Egg",
    "Skeletal Egg",
    "Snow Egg",
    "Titan Temple Egg",
    "Unstable Egg",
}

local EGG_NAME_TO_DEFAULT_RARITY = {
    ["biohazard"]              = "Secret",
    ["biohazard egg"]          = "Secret",
    ["experiment"]             = "Secret",
    ["experiment egg"]         = "Secret",
    ["limitedexperimentegg"]   = "Secret",
    ["limited experiment egg"] = "Secret",
    ["angels & demons"]        = "Divine",
    ["angels & demons egg"]    = "Divine",
    ["titan temple"]           = "Divine",
    ["titan temple egg"]       = "Divine",
    ["cosmic"]                 = "Cosmic",
    ["cosmic egg"]             = "Cosmic",
    ["enchanted forest"]       = "Legendary",
    ["enchanted forest egg"]   = "Legendary",
    ["lava"]                   = "Legendary",
    ["lava egg"]               = "Legendary",
    ["snow"]                   = "Rare",
    ["snow egg"]               = "Rare",
    ["prehistoric"]            = "Rare",
    ["prehistoric egg"]        = "Rare",
    ["cherry blossom"]         = "Rare",
    ["cherry blossom egg"]     = "Rare",
    ["ocean"]                  = "Rare",
    ["ocean egg"]              = "Rare",
    ["depths"]                 = "Divine",
    ["depths egg"]             = "Divine",
    ["desert"]                 = "Rare",
    ["desert egg"]             = "Rare",
    ["dragon"]                 = "Eternal",
    ["dragon egg"]             = "Eternal",
    ["monster"]                = "Mythic",
    ["monster egg"]            = "Mythic",
    ["monstrous"]              = "Mythic",
    ["monstrous egg"]          = "Mythic",
    ["mecha"]                  = "Legendary",
    ["mecha egg"]              = "Legendary",
    ["crystal"]                = "Legendary",
    ["crystal egg"]            = "Legendary",
    ["skeletal"]               = "Secret",
    ["skeletal egg"]           = "Secret",
    ["riftborn"]               = "Legendary",
    ["riftborn egg"]           = "Legendary",
    ["riftbeasts"]             = "Legendary",
    ["riftbeasts egg"]         = "Legendary",
    ["shattered rift"]         = "Eternal",
    ["shattered rift egg"]     = "Eternal",
    ["light dove"]             = "Legendary",
    ["light dove egg"]         = "Legendary",
    ["unstable"]               = "Common",
    ["unstable egg"]           = "Common",
    ["egg"]                    = "Common",
}

local KNOWN_BIOME_EGGS = ALL_BIOMES_AND_EVENTS

local STATIC_SPECIES_TO_BIOME_EGG = {
    -- Cosmic Egg
    ["Alien Skeleton Boss"] = "Cosmic Egg", ["Cosmic Skeleton Boss"] = "Cosmic Egg",
    ["Cave Dragon"] = "Cosmic Egg", ["Cosmic Dragon"] = "Cosmic Egg",
    ["Cosmic Fox"] = "Cosmic Egg", ["Starry Fox"] = "Cosmic Egg",
    ["Cosmic Lion"] = "Cosmic Egg",
    ["Cyclops Gorilla"] = "Cosmic Egg", ["Cosmic Gorilla"] = "Cosmic Egg",
    ["Eternal Lunar Dragon"] = "Cosmic Egg",
    ["Galaxy Gecko"] = "Cosmic Egg", ["Cosmic Gecko"] = "Cosmic Egg",
    ["La Vacca Saturno Saturnita"] = "Cosmic Egg",
    ["Mantis"] = "Cosmic Egg",
    ["Cosmic Beetle Blue"] = "Cosmic Egg",
    ["Drilla"] = "Cosmic Egg",

    -- Angels & Demons Egg
    ["Dark Gargoyle"] = "Angels & Demons Egg", ["Gargoyle"] = "Angels & Demons Egg",
    ["Centaur"] = "Angels & Demons Egg",
    ["Jellyfish"] = "Angels & Demons Egg", ["Pure Jellyfish"] = "Angels & Demons Egg",
    ["Skeleton Horse"] = "Angels & Demons Egg", ["Pegasus"] = "Angels & Demons Egg",
    ["ArchAngel"] = "Angels & Demons Egg", ["World Burner"] = "Angels & Demons Egg",
    ["RazorFang"] = "Angels & Demons Egg", ["Imp"] = "Angels & Demons Egg",
    ["Demon Hound"] = "Angels & Demons Egg", ["Flame Sprite"] = "Angels & Demons Egg",
    ["Toro"] = "Angels & Demons Egg", ["Archdemon Dragon"] = "Angels & Demons Egg",
    ["Lamb"] = "Angels & Demons Egg", ["Winged Lamb"] = "Angels & Demons Egg",
    ["Moth"] = "Angels & Demons Egg", ["Sacred Moth"] = "Angels & Demons Egg",
    ["Peacock"] = "Angels & Demons Egg", ["Holy Peacock"] = "Angels & Demons Egg",

    -- Enchanted Forest Egg
    ["Spirit Panda"] = "Enchanted Forest Egg", ["Spirit Hare"] = "Enchanted Forest Egg",
    ["Toucax"] = "Enchanted Forest Egg", ["Red Panda"] = "Enchanted Forest Egg",
    ["Enchanted Bluejay"] = "Enchanted Forest Egg", ["Salamander"] = "Enchanted Forest Egg",
    ["Stag"] = "Enchanted Forest Egg", ["Centapede"] = "Enchanted Forest Egg",
    ["Unicorn"] = "Enchanted Forest Egg", ["Kitsune"] = "Enchanted Forest Egg",
    ["Koi"] = "Enchanted Forest Egg", ["Snowy Owl"] = "Enchanted Forest Egg",
    ["Crane"] = "Enchanted Forest Egg", ["Oni Tiger"] = "Enchanted Forest Egg",

    -- Titan Temple Egg
    ["King Kong"] = "Titan Temple Egg", ["Gorilla King"] = "Titan Temple Egg",
    ["Kaiju Spider"] = "Titan Temple Egg", ["Godzilla"] = "Titan Temple Egg",
    ["Nightflame"] = "Titan Temple Egg", ["Blade Head"] = "Titan Temple Egg",
    ["Crab"] = "Titan Temple Egg", ["Rhino"] = "Titan Temple Egg",
    ["Rhinobear"] = "Titan Temple Egg", ["Rhinotaur"] = "Titan Temple Egg",

    -- Prehistoric Egg
    ["Mosasaurus"] = "Prehistoric Egg", ["TyrannosaurusRex"] = "Prehistoric Egg",
    ["TRex"] = "Prehistoric Egg", ["Tralaledon"] = "Prehistoric Egg",
    ["Triceratops"] = "Prehistoric Egg", ["Bronto"] = "Prehistoric Egg",
    ["Ankylosaurus"] = "Prehistoric Egg", ["Pterodactyl"] = "Prehistoric Egg",
    ["Dodo"] = "Prehistoric Egg",

    -- Snow Egg
    ["Ice Dragon"] = "Snow Egg", ["Yeti"] = "Snow Egg",
    ["King Mammoth"] = "Snow Egg", ["Mammoth"] = "Snow Egg",
    ["Colossal Mammoth"] = "Snow Egg", ["Sabertooth Tiger"] = "Snow Egg",
    ["Polar Bear"] = "Snow Egg", ["Walrus"] = "Snow Egg",
    ["Penguin"] = "Snow Egg",

    -- Ocean Egg / Depths Egg
    ["Whale Shark"] = "Ocean Egg", ["Shark"] = "Ocean Egg",
    ["Mutant Shark"] = "Ocean Egg", ["Finned Thresher"] = "Ocean Egg",
    ["Beluga Whale"] = "Ocean Egg", ["Orca"] = "Ocean Egg",
    ["Kraken"] = "Ocean Egg", ["El Maja"] = "Ocean Egg",
    ["Swordfish"] = "Ocean Egg", ["Parrotfish"] = "Ocean Egg",
    ["Stacked Turtle"] = "Ocean Egg", ["Octophant"] = "Ocean Egg",
    ["Abyss Overlord"] = "Depths Egg", ["Riptide Octopus"] = "Ocean Egg",

    -- Biohazard Egg
    ["Biohazard"] = "Biohazard Egg", ["Biohazard Egg"] = "Biohazard Egg",
    ["Toxic Rat"] = "Biohazard Egg", ["Radcoon"] = "Biohazard Egg",
    ["Toxic Crocodile"] = "Biohazard Egg", ["Toxic Hedgehog"] = "Biohazard Egg",
    ["Nuclear Mantis"] = "Biohazard Egg", ["Nuceodille"] = "Biohazard Egg",

    -- Experiment Egg
    ["Experiment Egg"] = "Experiment Egg", ["Experiment #001"] = "Experiment Egg",
    ["Nibbles #013"] = "Experiment Egg", ["Wheel Hamster"] = "Experiment Egg",
    ["Frogfly"] = "Experiment Egg", ["LimitedExperimentEgg"] = "Experiment Egg",
    ["LimitedTimeExperimentPet"] = "Experiment Egg",

    -- Desert Egg
    ["Royal Sphinx"] = "Desert Egg", ["Irihorus"] = "Desert Egg",
    ["Sand Spider"] = "Desert Egg", ["Scorpion"] = "Desert Egg",
    ["DeathstalkerScorpion"] = "Desert Egg", ["Snake"] = "Desert Egg",
    ["Rattlesnake"] = "Desert Egg", ["Tob Tobi Tob Tob"] = "Desert Egg",
    ["Camel"] = "Desert Egg", ["Fennec"] = "Desert Egg",
    ["FennecFox"] = "Desert Egg", ["Jerboa"] = "Desert Egg",
    ["DesertLark"] = "Desert Egg",

    -- Lava Egg
    ["Phoenix"] = "Lava Egg", ["Ascended Vermilion Phoenix"] = "Lava Egg",
    ["Lava Dragon"] = "Lava Egg", ["Dragon"] = "Lava Egg",
    ["Cerberus"] = "Lava Egg", ["Chillin Chilli"] = "Lava Egg",
    ["Lava Iguana"] = "Lava Egg", ["Flaming Bull"] = "Lava Egg",
    ["Lava Frog"] = "Lava Egg", ["Lava Gecko"] = "Lava Egg",
    ["Ash Gecko"] = "Lava Egg",

    -- Unstable Egg
    ["Three Headed Chicken"] = "Unstable Egg", ["Spiderpig"] = "Unstable Egg",

    -- Starter Egg
    ["Chicken"] = "Egg", ["Dog"] = "Egg", ["Frog"] = "Egg",
    ["Duckling"] = "Egg", ["Catfish"] = "Egg", ["Turtle"] = "Egg",
    ["Bird"] = "Egg", ["Owl"] = "Egg", ["Burrowing Owl"] = "Egg",
    ["Raccoon"] = "Egg", ["Fox"] = "Egg", ["Bear"] = "Egg",
    ["Swan"] = "Egg", ["Brr Brr Patapim"] = "Egg", ["Axolotl"] = "Egg",
    ["Dream Axolotl"] = "Egg", ["Toucan"] = "Egg", ["Chimpanzee"] = "Egg",
    ["Crocodile"] = "Egg", ["Gorilla"] = "Egg", ["Tiger"] = "Egg",
    ["Spider"] = "Egg", ["King Snake"] = "Egg", ["Warden"] = "Egg",
}

-- ================================================================================
-- STATE & LOGGING
-- ================================================================================
local State = {
    MyPlot = nil,
    MyPlotIndex = nil,
    BagEggs = {},               -- List of individual egg records in bag
    GroupedBag = {},            -- Grouped table: [GroupName] = { TotalCount, Rarities = { [Rarity] = { Count, Eggs } } }
    SelectedKeys = {},          -- Set of selected "GroupName_Rarity": boolean
    ExpandedBiomes = {},        -- Map of [GroupName] = boolean (accordion dropdown open/close)
    ShowOnlyBag = false,        -- Toggle: false = show all biomes/events; true = show only biomes currently in bag
    PlacingActive = false,
    PlaceThread = nil,
    MaxEggsCap = 30,
    PlacedEggs = {},
    GridSpacing = 10.0,         -- Studs spacing between egg slots (default: 10.0 studs)
    FillPattern = "Dispersed",   -- "Dispersed" (checkerboard 14.7+ stud spread) or "Standard" (row-by-row)
}

local logEntries = {}
local logCallback = nil

local function logMsg(fmt, ...)
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
    local timestamp = os.date("%H:%M:%S")
    local formatted = string.format("[%s] [AutoPlace] %s", timestamp, msg)
    table.insert(logEntries, formatted)
    if #logEntries > 500 then table.remove(logEntries, 1) end
    print(formatted)
    if logCallback then pcall(logCallback, formatted) end
end

-- ================================================================================
-- NETWORKING & REMOTES
-- ================================================================================
local function getNetRemote(name)
    local pkg = ReplicatedStorage:FindFirstChild("Packages")
    local net = pkg and pkg:FindFirstChild("Networking")
    if net then
        local r = net:FindFirstChild(name)
        if r then return r end
    end
    return ReplicatedStorage:FindFirstChild(name, true)
end

local Remotes = {
    AskPlaceEgg       = getNetRemote("RF/EggWorld/AskPlaceEgg"),
    ToolTrigger       = getNetRemote("RE/ToolTrigger/Trigger"),
    FetchProfile      = getNetRemote("RF/ProfileMirror/FetchProfile"),
    AskLiveSnapshot   = getNetRemote("RF/EggWorld/AskLiveSnapshot"),
    AskWearTool       = getNetRemote("RF/EggWorld/AskWearTool"),
    AskDoffTool       = getNetRemote("RF/EggWorld/AskDoffTool"),
    AskHomesteadState = getNetRemote("RF/Homestead/AskState"),
}

local function distXZ(a, b)
    if not a or not b then return math.huge end
    local dx = a.X - b.X
    local dz = a.Z - b.Z
    return math.sqrt(dx * dx + dz * dz)
end

local function isRealEggTool(t)
    if not t or not t:IsA("Tool") then return false end
    local attrs = t:GetAttributes()

    -- 1. ABSOLUTE REJECTION: Never match pets (ItemType="Asset"), gear, or consumables!
    if attrs.ItemType == "Asset" then return false end
    if attrs.ItemType == "Gear" or attrs.GearName ~= nil or attrs.IsBat == true then return false end
    if attrs.ItemType == "MutationConsumable" or attrs.MutationId ~= nil then return false end
    if attrs.ItemType == "ButterflyNet" or attrs.ButterflyNet == true then return false end

    -- 2. POSITIVE CONFIRMATION: Must be a genuine egg tool
    if attrs.ItemType == "Egg" or attrs.Category == "Egg" then return true end
    if attrs.EggUid ~= nil then return true end
    local lowName = string.lower(t.Name)
    if string.find(lowName, "egg", 1, true) then return true end

    return false
end

-- ================================================================================
-- HELPER UTILITIES: CLEANING & RARITY RESOLUTION
-- ================================================================================
local function cleanEggName(name)
    if not name or type(name) ~= "string" then return "Unknown Egg" end
    -- Remove weight suffix like " (85,711Kg)" or " (24kg)"
    local s = name:gsub("%s*%([%d,%.]+%s*[Kk][Gg]%)%s*$", "")
    s = s:gsub("^%s*", ""):gsub("%s*$", "")
    if s == "" then return "Unknown Egg" end
    local sLow = s:lower()
    if sLow == "limitedexperimentegg" or sLow == "limited experiment egg" or sLow == "experiment" then
        return "Experiment Egg"
    end
    if sLow == "biohazard" then
        return "Biohazard Egg"
    end
    if not sLow:find("egg") then
        s = s .. " Egg"
    end
    return s
end

local rarityByUid = {}
local function initRarityMonitor()
    pcall(function()
        local rfSnap = Remotes.AskLiveSnapshot
        if rfSnap then
            local ok, snap = pcall(function() return rfSnap:InvokeServer() end)
            if ok and type(snap) == "table" and type(snap.RareSpawns) == "table" then
                for _, e in pairs(snap.RareSpawns) do
                    if type(e) == "table" and e.EggUid and e.RarityId then
                        rarityByUid[tostring(e.EggUid)] = tostring(e.RarityId)
                    end
                end
            end
        end
    end)
    pcall(function()
        local evRar = getNetRemote("RE/EggWorld/FieldEggRaritiesShown")
        if evRar then
            evRar.OnClientEvent:Connect(function(p)
                if type(p) == "table" and type(p.RareSpawns) == "table" then
                    for _, e in pairs(p.RareSpawns) do
                        if type(e) == "table" and e.EggUid and e.RarityId then
                            rarityByUid[tostring(e.EggUid)] = tostring(e.RarityId)
                        end
                    end
                end
            end)
        end
    end)
end
task.spawn(initRarityMonitor)

-- ================================================================================
-- ADVANCED INTROSPECTION: SCHEMA VALIDATION & PLACEMENT CONTROLLER
-- ================================================================================
local Introspect = {
    ValidatedPayloadFormat = nil,
    PlaceEggRequestConsts  = nil,
    EggPlacementConsts     = nil,
    EPC                    = nil,
}

local function runPlacementIntrospection()
    pcall(function()
        local getUpvals = (typeof(debug) == "table" and debug.getupvalues) or (typeof(getupvalues) == "function" and getupvalues)
        local getConsts = (typeof(debug) == "table" and debug.getconstants) or (typeof(getconstants) == "function" and getconstants)

        -- 1. Inspect SchemaValidation via EggRecords.SellPrice upvalues
        local okEgg, EggRecords = pcall(require, ReplicatedStorage.Shared.Util.EggRecords)
        if okEgg and EggRecords and getUpvals then
            local u = select(2, pcall(getUpvals, EggRecords.SellPrice))
            local schemaVal = u and type(u[1]) == "table" and u[1].SchemaValidation
            if type(schemaVal) == "table" then
                -- PlaceEggRequest constants
                if type(schemaVal.PlaceEggRequest) == "function" and getConsts then
                    local okC, consts = pcall(getConsts, schemaVal.PlaceEggRequest)
                    if okC and type(consts) == "table" then
                        Introspect.PlaceEggRequestConsts = consts
                        local constList = {}
                        for _, v in pairs(consts) do table.insert(constList, tostring(v)) end
                        logMsg("[Introspect] PlaceEggRequest constants: [%s]", table.concat(constList, ", "))
                    end
                end

                -- EggPlacement constants
                if type(schemaVal.EggPlacement) == "function" and getConsts then
                    local okC, consts = pcall(getConsts, schemaVal.EggPlacement)
                    if okC and type(consts) == "table" then
                        Introspect.EggPlacementConsts = consts
                        local constList = {}
                        for _, v in pairs(consts) do table.insert(constList, tostring(v)) end
                        logMsg("[Introspect] EggPlacement constants: [%s]", table.concat(constList, ", "))
                    end
                end

                -- Test candidate payload structures against PlaceEggRequest
                if type(schemaVal.PlaceEggRequest) == "function" then
                    local dummyUid = "test_uid_12345"
                    local dummyCF = CFrame.new(10, 20, 30)
                    local candidates = {
                        { id = "LocalCFrame",    fn = function(uid, cf) return { LocalCFrame = cf, Uid = uid } end },
                        { id = "CFrame",         fn = function(uid, cf) return { CFrame = cf, Uid = uid } end },
                        { id = "BothCFrames",    fn = function(uid, cf) return { LocalCFrame = cf, CFrame = cf, Uid = uid } end },
                        { id = "PlacementCF",    fn = function(uid, cf) return { Placement = cf, Uid = uid } end },
                        { id = "PlacementObj",   fn = function(uid, cf) return { Placement = { CFrame = cf }, Uid = uid } end },
                        { id = "PlacementLocal", fn = function(uid, cf) return { Placement = { LocalCFrame = cf }, Uid = uid } end },
                        { id = "EggUidLocalCF",  fn = function(uid, cf) return { EggUid = uid, LocalCFrame = cf } end },
                    }

                    for _, cand in ipairs(candidates) do
                        local testPayload = cand.fn(dummyUid, dummyCF)
                        local okP, resP, errP = pcall(schemaVal.PlaceEggRequest, testPayload)
                        if okP and resP == true then
                            logMsg("  ⭐ PlaceEggRequest candidate [%s] PASSED schema validation!", cand.id)
                            Introspect.ValidatedPayloadFormat = cand.fn
                            break
                        else
                            logMsg("  ❌ PlaceEggRequest candidate [%s]: res=%s, err=%s", cand.id, tostring(resP), tostring(errP))
                        end
                    end
                end
            end
        end

        -- 2. Inspect EggPlacementController
        local epcMod = ReplicatedStorage:FindFirstChild("Controllers")
            and ReplicatedStorage.Controllers:FindFirstChild("Game")
            and ReplicatedStorage.Controllers.Game:FindFirstChild("Eggs")
            and ReplicatedStorage.Controllers.Game.Eggs:FindFirstChild("EggPlacementController")
        if epcMod then
            local okEPC, EPC = pcall(require, epcMod)
            if okEPC and type(EPC) == "table" then
                Introspect.EPC = EPC
                local methods = {}
                for k, v in pairs(EPC) do
                    table.insert(methods, string.format("%s (%s)", tostring(k), typeof(v)))
                end
                table.sort(methods)
                logMsg("[Introspect] EggPlacementController exports: %s", table.concat(methods, ", "))
            end
        end
    end)
end
task.spawn(runPlacementIntrospection)

local speciesToEggMap = {}
local speciesToRarityMap = {}

local function indexSpeciesConfigs()
    pcall(function()
        local confFolder = ReplicatedStorage:FindFirstChild("Data")
            and ReplicatedStorage.Data:FindFirstChild("Assets")
            and ReplicatedStorage.Data.Assets:FindFirstChild("Configs")
        if not confFolder then return end

        for _, mod in ipairs(confFolder:GetChildren()) do
            if mod:IsA("ModuleScript") then
                local ok, data = pcall(require, mod)
                if ok and type(data) == "table" then
                    local eggName = nil
                    if type(data.Egg) == "table" then
                        eggName = data.Egg.DisplayName or data.Egg.Name or data.Egg._id or data.Egg.EggName
                    elseif type(data.Egg) == "string" then
                        eggName = data.Egg
                    end

                    local rarityName = nil
                    if type(data.Rarity) == "table" then
                        rarityName = data.Rarity.DisplayName or data.Rarity.Name or data.Rarity._id
                    elseif type(data.Rarity) == "string" then
                        rarityName = data.Rarity
                    end

                    local mLow = mod.Name:lower()
                    if eggName then
                        speciesToEggMap[mLow] = eggName
                        if data.DisplayName then speciesToEggMap[tostring(data.DisplayName):lower()] = eggName end
                    end
                    if rarityName then
                        speciesToRarityMap[mLow] = rarityName
                        if data.DisplayName then speciesToRarityMap[tostring(data.DisplayName):lower()] = rarityName end
                    end
                end
            end
        end
    end)
end
task.spawn(indexSpeciesConfigs)

local function resolveEggBiomeAndRarity(rawNameOrSpecies, directRarity, uid)
    if uid and rarityByUid[uid] and (not directRarity or directRarity == "" or directRarity == "Unknown") then
        directRarity = rarityByUid[uid]
    end

    local raw = tostring(rawNameOrSpecies or ""):gsub("%s*%([%d,%.]+%s*[Kk][Gg]%)%s*$", "")
    raw = raw:gsub("^%s*", ""):gsub("%s*$", "")
    if raw == "" then raw = "Egg" end
    local low = raw:lower()

    local function getRarity(nameKey, fallback)
        if directRarity and directRarity ~= "" and directRarity ~= "Unknown" then
            return directRarity
        end
        local nLow = nameKey and nameKey:lower()
        if nLow and speciesToRarityMap[nLow] then
            return speciesToRarityMap[nLow]
        end
        if nameKey and PET_RARITY_PRESETS[nameKey] then
            return PET_RARITY_PRESETS[nameKey]
        end
        if nLow and EGG_NAME_TO_DEFAULT_RARITY[nLow] then
            return EGG_NAME_TO_DEFAULT_RARITY[nLow]
        end
        local bLow = nLow and nLow:gsub("%s*egg$", "")
        if bLow and EGG_NAME_TO_DEFAULT_RARITY[bLow] then
            return EGG_NAME_TO_DEFAULT_RARITY[bLow]
        end
        return fallback or "Common"
    end

    -- 1. Direct Biome / Event Egg exact match (e.g. "Biohazard Egg", "Angels & Demons Egg")
    for _, bEgg in ipairs(KNOWN_BIOME_EGGS) do
        local bLow = bEgg:lower()
        local bBase = bLow:gsub("%s*egg$", "")
        if low == bLow or low == bBase then
            local rar = getRarity(raw, EGG_NAME_TO_DEFAULT_RARITY[bLow] or EGG_NAME_TO_DEFAULT_RARITY[bBase] or "Common")
            return bEgg, rar, raw
        end
    end

    -- 2. Species exact match from static ground truth (authoritative Biome grouping!)
    for sp, eggGroup in pairs(STATIC_SPECIES_TO_BIOME_EGG) do
        if sp:lower() == low then
            local rar = getRarity(sp)
            return eggGroup, rar, sp
        end
    end

    -- 3. Species exact match from dynamic configs
    if speciesToEggMap[low] then
        local bEgg = speciesToEggMap[low]
        local rar = getRarity(raw)
        return bEgg, rar, raw
    end

    -- 4. Direct Biome substring match
    for _, bEgg in ipairs(KNOWN_BIOME_EGGS) do
        local bLow = bEgg:lower()
        local bBase = bLow:gsub("%s*egg$", "")
        if bBase ~= "" and low:find(bBase, 1, true) then
            local rar = getRarity(raw, EGG_NAME_TO_DEFAULT_RARITY[bLow] or EGG_NAME_TO_DEFAULT_RARITY[bBase] or "Common")
            return bEgg, rar, raw
        end
    end

    -- 5. Species substring match (longest keys first to prevent 'Dragon' matching 'Cave Dragon')
    local sortedSpecies = {}
    for sp in pairs(STATIC_SPECIES_TO_BIOME_EGG) do table.insert(sortedSpecies, sp) end
    table.sort(sortedSpecies, function(a, b) return #a > #b end)

    for _, sp in ipairs(sortedSpecies) do
        local sLow = sp:lower()
        if low:find(sLow, 1, true) or sLow:find(low, 1, true) then
            local eggGroup = STATIC_SPECIES_TO_BIOME_EGG[sp]
            local rar = getRarity(sp)
            return eggGroup, rar, sp
        end
    end

    -- 6. Fallback
    local fallback = raw
    if not fallback:lower():find("egg") then
        fallback = fallback .. " Egg"
    end
    local rar = getRarity(raw, "Common")
    return fallback, rar, raw
end

-- ================================================================================
-- 1. BAG SCANNER & GROUPING ENGINE
-- ================================================================================
local function scanAndGroupBag()
    local seenUids = {}
    local rawEggList = {}

    -- 1a. Scan RF/ProfileMirror/FetchProfile (EggInventory where Placement == nil)
    pcall(function()
        if Remotes.FetchProfile then
            local prof = nil
            for attempt = 1, 3 do
                local ok, res = pcall(function() return Remotes.FetchProfile:InvokeServer(LocalPlayer) end)
                if ok and type(res) == "table" then prof = res; break end
                task.wait(0.2)
            end
            if not prof then
                local ok, res = pcall(function() return Remotes.FetchProfile:InvokeServer() end)
                if ok and type(res) == "table" then prof = res end
            end

            if prof and type(prof.EggInventory) == "table" then
                for eggUid, eggData in pairs(prof.EggInventory) do
                    local uidStr = tostring(eggUid)
                    if type(eggData) == "table" then
                        -- STRICT UNPLACED: Placement is nil, false, or empty
                        local isPlaced = (eggData.Placement ~= nil and eggData.Placement ~= false and eggData.Placement ~= "")
                        if not isPlaced and not seenUids[uidStr] then
                            seenUids[uidStr] = true
                            local rawName = eggData.DisplayName or eggData.AssetCategory or "Egg"
                            local biomeEgg, rarity, species = resolveEggBiomeAndRarity(rawName, eggData.Rarity or eggData.RarityId or eggData.Tier, uidStr)
                            local weight = tonumber(eggData.Weight or eggData.Scale or 0)

                            table.insert(rawEggList, {
                                Uid         = uidStr,
                                RawUid      = eggUid,
                                RawName     = rawName,
                                GroupName   = biomeEgg,
                                Rarity      = rarity,
                                Species     = species,
                                Weight      = weight,
                                Source      = "ProfileSatchel",
                                RawData     = eggData,
                            })
                        end
                    end
                end
            end
        end
    end)

    -- 1b. Scan LocalPlayer.Backpack for Egg Tools
    pcall(function()
        local bp = LocalPlayer:FindFirstChild("Backpack")
        if bp then
            for _, item in ipairs(bp:GetChildren()) do
                if isRealEggTool(item) then
                    local uid = item:GetAttribute("EggUid") or item:GetAttribute("UID") or item:GetAttribute("Uid") or item.Name
                    local uidStr = tostring(uid)
                    if not seenUids[uidStr] then
                        seenUids[uidStr] = true
                        local rarAttr = item:GetAttribute("Rarity") or item:GetAttribute("RarityId") or item:GetAttribute("Tier")
                        local biomeEgg, rarity, species = resolveEggBiomeAndRarity(item.Name, rarAttr, uidStr)
                        local weight = tonumber(item:GetAttribute("Weight") or 0)

                        table.insert(rawEggList, {
                            Uid         = uidStr,
                            RawName     = item.Name,
                            GroupName   = biomeEgg,
                            Rarity      = rarity,
                            Species     = species,
                            Weight      = weight,
                            Tool        = item,
                            Source      = "Backpack",
                        })
                    else
                        -- Attach Tool instance to existing Profile record ONLY if it is a real egg tool
                        for _, e in ipairs(rawEggList) do
                            if e.Uid == uidStr then
                                e.Tool = item
                                break
                            end
                        end
                    end
                end
            end
        end
    end)

    -- 1c. Scan LocalPlayer.Character for Equipped Egg Tool
    pcall(function()
        local char = LocalPlayer.Character
        if char then
            for _, item in ipairs(char:GetChildren()) do
                if isRealEggTool(item) then
                    local uid = item:GetAttribute("EggUid") or item:GetAttribute("UID") or item:GetAttribute("Uid") or item.Name
                    local uidStr = tostring(uid)
                    if not seenUids[uidStr] then
                        seenUids[uidStr] = true
                        local rarAttr = item:GetAttribute("Rarity") or item:GetAttribute("RarityId")
                        local biomeEgg, rarity, species = resolveEggBiomeAndRarity(item.Name, rarAttr, uidStr)
                        local weight = tonumber(item:GetAttribute("Weight") or 0)

                        table.insert(rawEggList, {
                            Uid         = uidStr,
                            RawName     = item.Name,
                            GroupName   = biomeEgg,
                            Rarity      = rarity,
                            Species     = species,
                            Weight      = weight,
                            Tool        = item,
                            Source      = "Equipped",
                        })
                    else
                        for _, e in ipairs(rawEggList) do
                            if e.Uid == uidStr then
                                e.Tool = item
                                break
                            end
                        end
                    end
                end
            end
        end
    end)

    -- 1d. Fallback: PlayerGui.BackpackGui inspection ONLY if profile/backpack returned 0 eggs
    if #rawEggList == 0 then
        pcall(function()
            local pg = LocalPlayer:FindFirstChild("PlayerGui")
            local bpGui = pg and pg:FindFirstChild("BackpackGui")
            local invFrame = bpGui and bpGui:FindFirstChild("Backpack", true)
            local inv = invFrame and invFrame:FindFirstChild("Inventory", true)
            local sf = inv and inv:FindFirstChild("ScrollingFrame", true)
            if sf then
                for _, slot in ipairs(sf:GetChildren()) do
                    if slot:IsA("TextButton") or slot:IsA("GuiObject") then
                        local hasEggOverlay = slot:GetAttribute("HasEggOverlay")
                        local toolName = slot:GetAttribute("ToolName") or slot:GetAttribute("DisplayName")
                        if not toolName then
                            for _, child in ipairs(slot:GetDescendants()) do
                                if child:IsA("TextLabel") and child.Text:lower():find("egg") then
                                    toolName = child.Text
                                    break
                                end
                            end
                        end
                        if toolName and (hasEggOverlay or toolName:lower():find("egg")) then
                            local uid = slot:GetAttribute("EggUid") or slot:GetAttribute("UID") or ("gui_slot_" .. slot.Name)
                            local uidStr = tostring(uid)
                            if not seenUids[uidStr] then
                                seenUids[uidStr] = true
                                local biomeEgg, rarity, species = resolveEggBiomeAndRarity(toolName, slot:GetAttribute("Rarity"), uidStr)
                                table.insert(rawEggList, {
                                    Uid         = uidStr,
                                    RawName     = toolName,
                                    GroupName   = biomeEgg,
                                    Rarity      = rarity,
                                    Species     = species,
                                    Weight      = 0,
                                    Source      = "BackpackGui",
                                })
                            end
                        end
                    end
                end
            end
        end)
    end

    -- 2. Build Grouped Aggregates
    local grouped = {}
    for _, egg in ipairs(rawEggList) do
        local g = egg.GroupName
        local r = egg.Rarity

        if not grouped[g] then
            grouped[g] = {
                GroupName = g,
                TotalCount = 0,
                Rarities = {},
            }
        end

        grouped[g].TotalCount = grouped[g].TotalCount + 1

        if not grouped[g].Rarities[r] then
            grouped[g].Rarities[r] = {
                Rarity = r,
                Count = 0,
                Eggs = {},
                SpeciesCounts = {},
            }
        end

        grouped[g].Rarities[r].Count = grouped[g].Rarities[r].Count + 1
        table.insert(grouped[g].Rarities[r].Eggs, egg)

        local sp = egg.Species or egg.RawName
        if sp then
            grouped[g].Rarities[r].SpeciesCounts[sp] = (grouped[g].Rarities[r].SpeciesCounts[sp] or 0) + 1
        end
    end

    State.BagEggs = rawEggList
    State.GroupedBag = grouped

    -- 3. Log Clean Report
    logMsg("==================================================")
    logMsg("🎒 CURRENT BAG EGGS GROUPED BY BIOME/EVENT & RARITY")
    logMsg("Total Eggs in Bag: %d", #rawEggList)
    logMsg("==================================================")

    -- Sort groups alphabetically
    local sortedGroupNames = {}
    for gName in pairs(grouped) do table.insert(sortedGroupNames, gName) end
    table.sort(sortedGroupNames)

    for i, gName in ipairs(sortedGroupNames) do
        local gData = grouped[gName]
        logMsg("📦 [%d] %s (Total: %d)", i, gName, gData.TotalCount)

        -- Sort rarities by rank descending
        local sortedRars = {}
        for rName in pairs(gData.Rarities) do table.insert(sortedRars, rName) end
        table.sort(sortedRars, function(a, b)
            return (RARITY_RANK[a] or 0) > (RARITY_RANK[b] or 0)
        end)

        for _, rName in ipairs(sortedRars) do
            local rData = gData.Rarities[rName]
            local sampleWeights = {}
            for k = 1, math.min(3, #rData.Eggs) do
                local w = rData.Eggs[k].Weight
                if w and w > 0 then
                    table.insert(sampleWeights, string.format("%.0fkg", w))
                end
            end
            local wStr = #sampleWeights > 0 and (" | Weights: " .. table.concat(sampleWeights, ", ")) or ""

            local spParts = {}
            if rData.SpeciesCounts then
                for sp, cnt in pairs(rData.SpeciesCounts) do
                    table.insert(spParts, string.format("%s x%d", sp, cnt))
                end
                table.sort(spParts)
            end
            local spStr = #spParts > 0 and (" (" .. table.concat(spParts, ", ") .. ")") or ""

            logMsg("  • [%s] x %d%s%s", rName, rData.Count, spStr, wStr)
        end
    end
    logMsg("==================================================")

    return grouped, rawEggList
end

-- ================================================================================
-- 2. PLOT & PEN GEOMETRY FOR PLACEMENT
-- ================================================================================
local function findMyPlot(forceRefresh)
    if not forceRefresh and State.MyPlot and State.MyPlot.Parent then
        return State.MyPlot, State.MyPlotIndex
    end

    local plotsFolder = Workspace:FindFirstChild("Plots")
        or Workspace:FindFirstChild("Bases")
        or Workspace:FindFirstChild("Plot")
        or Workspace:FindFirstChild("Homesteads")
    if not plotsFolder then
        logMsg("⚠️ Plots folder not found in Workspace")
        return nil, nil
    end

    local myId = LocalPlayer.UserId
    local myIdStr = tostring(myId)
    local myName = string.lower(LocalPlayer.Name or "")
    local myDispName = LocalPlayer.DisplayName and string.lower(LocalPlayer.DisplayName) or ""

    -- ----------------------------------------------------
    -- TIER 0: Server Authoritative via RF/Homestead/AskState
    -- ----------------------------------------------------
    local rfHome = Remotes.AskHomesteadState or getNetRemote("RF/Homestead/AskState")
    if rfHome then
        local ok, res = pcall(function() return rfHome:InvokeServer() end)
        if ok and type(res) == "table" and type(res.OwnersBySlot) == "table" then
            for slotKey, ownerId in pairs(res.OwnersBySlot) do
                if tonumber(ownerId) == myId or tostring(ownerId) == myIdStr then
                    local slotNum = tonumber(slotKey) or tonumber(string.match(tostring(slotKey), "%d+"))
                    local plot = plotsFolder:FindFirstChild(tostring(slotKey))
                        or (slotNum and plotsFolder:FindFirstChild(tostring(slotNum)))
                    if not plot then
                        for _, ch in ipairs(plotsFolder:GetChildren()) do
                            if ch.Name == tostring(slotKey) or (slotNum and (tonumber(ch.Name) == slotNum or tonumber(string.match(ch.Name, "%d+")) == slotNum)) then
                                plot = ch
                                break
                            end
                        end
                    end
                    if plot then
                        State.MyPlot = plot
                        State.MyPlotIndex = slotNum
                        logMsg("✓ Player plot identified: Plot %s (Slot #%s) via RF/Homestead/AskState", plot.Name, tostring(slotNum))
                        return plot, slotNum
                    end
                end
            end
        end
    end

    -- ----------------------------------------------------
    -- TIER 1: Spatial Anchor via PlacedEggRenders (<UserId>_*)
    -- ----------------------------------------------------
    local placedRenders = Workspace:FindFirstChild("PlacedEggRenders")
    if placedRenders then
        local myPrefix = myIdStr .. "_"
        local myEggs = {}
        for _, egg in ipairs(placedRenders:GetChildren()) do
            if string.find(egg.Name, myPrefix, 1, true) then
                local p = nil
                if egg:IsA("BasePart") then
                    p = egg.Position
                elseif egg:IsA("Model") then
                    local ok, piv = pcall(function() return egg:GetPivot().Position end)
                    p = ok and piv or (egg.PrimaryPart and egg.PrimaryPart.Position)
                end
                if p then table.insert(myEggs, p) end
            end
        end

        if #myEggs > 0 then
            local bestPlot, bestDist, bestIdx = nil, math.huge, nil
            for _, plot in ipairs(plotsFolder:GetChildren()) do
                local pPos = nil
                if plot:IsA("Model") then
                    local ok, piv = pcall(function() return plot:GetPivot().Position end)
                    pPos = ok and piv or (plot.PrimaryPart and plot.PrimaryPart.Position)
                elseif plot:IsA("BasePart") then
                    pPos = plot.Position
                end
                if pPos then
                    local totalD = 0
                    for _, ePos in ipairs(myEggs) do
                        totalD = totalD + distXZ(pPos, ePos)
                    end
                    local avgD = totalD / #myEggs
                    if avgD < bestDist then
                        bestDist = avgD
                        bestPlot = plot
                        bestIdx = tonumber(plot.Name) or tonumber(string.match(plot.Name, "%d+"))
                    end
                end
            end
            if bestPlot and bestDist <= 120 then
                State.MyPlot = bestPlot
                State.MyPlotIndex = bestIdx
                logMsg("✓ Player plot identified: Plot %s (#%s) via PlacedEggRenders anchor (dist: %.1f)", bestPlot.Name, tostring(bestIdx), bestDist)
                return bestPlot, bestIdx
            end
        end
    end

    -- ----------------------------------------------------
    -- TIER 2: Visual Plot Sign / TextLabel Inspection
    -- ----------------------------------------------------
    for _, plot in ipairs(plotsFolder:GetChildren()) do
        for _, desc in ipairs(plot:GetDescendants()) do
            if desc:IsA("TextLabel") or desc:IsA("SurfaceGui") then
                local txt = desc:IsA("TextLabel") and desc.Text:lower() or ""
                if (myName ~= "" and string.find(txt, myName, 1, true)) or
                   (myDispName ~= "" and string.find(txt, myDispName, 1, true)) then
                    local idx = tonumber(plot.Name) or tonumber(string.match(plot.Name, "%d+"))
                    State.MyPlot = plot
                    State.MyPlotIndex = idx
                    logMsg("✓ Player plot identified: Plot %s (#%s) via PlotSign match ('%s')", plot.Name, tostring(idx), desc.Text)
                    return plot, idx
                end
            end
        end
    end

    -- ----------------------------------------------------
    -- TIER 3: Plot Attributes Check
    -- ----------------------------------------------------
    for _, plot in ipairs(plotsFolder:GetChildren()) do
        local pAttrs = plot:GetAttributes()
        local ownerAttr = pAttrs.Owner or pAttrs.OwnerId or pAttrs.Player or pAttrs.UserId or pAttrs.ClaimedBy
        if ownerAttr then
            local strOwner = tostring(ownerAttr):lower()
            if strOwner == myIdStr or strOwner == myName or (myDispName ~= "" and strOwner == myDispName) then
                local idx = tonumber(plot.Name) or tonumber(string.match(plot.Name, "%d+"))
                State.MyPlot = plot
                State.MyPlotIndex = idx
                logMsg("✓ Player plot identified: Plot %s (#%s) via Attributes", plot.Name, tostring(idx))
                return plot, idx
            end
        end
    end

    -- ----------------------------------------------------
    -- TIER 4: Character Proximity
    -- ----------------------------------------------------
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if root then
        local bestPlot, bestDist, bestIdx = nil, math.huge, nil
        for _, plot in ipairs(plotsFolder:GetChildren()) do
            local pPos = nil
            if plot:IsA("Model") then
                local ok, piv = pcall(function() return plot:GetPivot().Position end)
                pPos = ok and piv or (plot.PrimaryPart and plot.PrimaryPart.Position)
            elseif plot:IsA("BasePart") then
                pPos = plot.Position
            end
            if pPos then
                local d = distXZ(root.Position, pPos)
                if d < bestDist then
                    bestDist = d
                    bestPlot = plot
                    bestIdx = tonumber(plot.Name) or tonumber(string.match(plot.Name, "%d+"))
                end
            end
        end
        if bestPlot and bestDist <= 100 then
            State.MyPlot = bestPlot
            State.MyPlotIndex = bestIdx
            logMsg("✓ Player plot identified: Plot %s (#%s) via Character Proximity (dist: %.1f)", bestPlot.Name, tostring(bestIdx), bestDist)
            return bestPlot, bestIdx
        end
    end

    -- ----------------------------------------------------
    -- TIER 5: Reference Pen Coordinates Proximity Fallback
    -- ----------------------------------------------------
    local fallbackPoints = {
        Vector3.new(522.3, 70.0, -166.4),   -- Known Pen Center from pen-6.log
        Vector3.new(522.8, 68.2, -203.4),   -- Plot CenterPoint
        Vector3.new(534.090, 70.724, -326.616), -- EggGoToUI SAFE_ZONE
        Vector3.new(6575.43, 69.96, -438.45),   -- PenBoundsESP SAFE_ZONE_FALLBACK
    }
    for _, targetPt in ipairs(fallbackPoints) do
        local bestPlot, bestDist, bestIdx = nil, math.huge, nil
        for _, plot in ipairs(plotsFolder:GetChildren()) do
            local pPos = nil
            if plot:IsA("Model") then
                local ok, piv = pcall(function() return plot:GetPivot().Position end)
                pPos = ok and piv or (plot.PrimaryPart and plot.PrimaryPart.Position)
            elseif plot:IsA("BasePart") then
                pPos = plot.Position
            end
            if pPos then
                local d = distXZ(targetPt, pPos)
                if d < bestDist then
                    bestDist = d
                    bestPlot = plot
                    bestIdx = tonumber(plot.Name) or tonumber(string.match(plot.Name, "%d+"))
                end
            end
        end
        if bestPlot and bestDist <= 80 then
            State.MyPlot = bestPlot
            State.MyPlotIndex = bestIdx
            logMsg("✓ Player plot identified: Plot %s (#%s) via Reference Fallback (dist: %.1f)", bestPlot.Name, tostring(bestIdx), bestDist)
            return bestPlot, bestIdx
        end
    end

    -- ----------------------------------------------------
    -- TIER 6: First Plot Fallback
    -- ----------------------------------------------------
    local children = plotsFolder:GetChildren()
    if #children > 0 then
        local plot = children[1]
        local idx = tonumber(plot.Name) or tonumber(string.match(plot.Name, "%d+")) or 1
        State.MyPlot = plot
        State.MyPlotIndex = idx
        logMsg("⚠️ Fallback to Plot %s (#%s)", plot.Name, tostring(idx))
        return plot, idx
    end

    return nil, nil
end

local function scanPlacedEggs()
    local list = {}
    local placedRenders = Workspace:FindFirstChild("PlacedEggRenders")
    if placedRenders then
        local myPrefix = tostring(LocalPlayer.UserId) .. "_"
        for _, egg in ipairs(placedRenders:GetChildren()) do
            if string.find(egg.Name, myPrefix, 1, true) then
                local p = nil
                if egg:IsA("BasePart") then p = egg.Position
                elseif egg:IsA("Model") then
                    local ok, piv = pcall(function() return egg:GetPivot().Position end)
                    p = ok and piv or (egg.PrimaryPart and egg.PrimaryPart.Position)
                end
                if p then table.insert(list, { Inst = egg, Pos = p }) end
            end
        end
    end
    State.PlacedEggs = list
    return list
end

-- Generates grid slot coordinates inside the pen yard with exact CFrame transformation & wide spacing
local function generatePenGridSlots(plot)
    local slots = {}
    local petArea = (plot and plot:FindFirstChild("PetArea", true))
        or (plot and plot:FindFirstChild("ToUpdate") and plot.ToUpdate:FindFirstChild("PetArea"))
        or (plot and plot:FindFirstChild("StarterPen") and plot.StarterPen:FindFirstChild("PetArea"))

    local plotPivot = CFrame.new()
    local okPiv, piv = pcall(function() return plot:GetPivot() end)
    if okPiv and piv then
        plotPivot = piv
    elseif plot and plot.PrimaryPart then
        plotPivot = plot.PrimaryPart.CFrame
    end

    local slotSpacing = State.GridSpacing or 10.0
    local pattern = State.FillPattern or "Dispersed"

    if petArea and petArea:IsA("BasePart") then
        local szX = petArea.Size.X
        local szZ = petArea.Size.Z
        local margin = 4.0
        local usableX = math.max(2.0, szX - margin * 2)
        local usableZ = math.max(2.0, szZ - margin * 2)

        local cols = math.max(1, math.floor(usableX / slotSpacing))
        local rows = math.max(1, math.floor(usableZ / slotSpacing))

        local cellX = usableX / cols
        local cellZ = usableZ / rows

        logMsg("[Grid] Generating slots for Pen (%.1f x %.1f): %d cols x %d rows @ Spacing: (%.1fs x %.1fs) [Pattern: %s]",
            usableX, usableZ, cols, rows, cellX, cellZ, pattern)

        local slotMatrix = {}
        for r = 1, rows do
            slotMatrix[r] = {}
            for c = 1, cols do
                local lx = -usableX / 2 + (c - 0.5) * cellX
                local lz = -usableZ / 2 + (r - 0.5) * cellZ
                local localCF_PetArea = CFrame.new(lx, 0.2, lz)
                local worldCF = petArea.CFrame * localCF_PetArea
                local localCF_Plot = plotPivot:ToObjectSpace(worldCF)

                slotMatrix[r][c] = {
                    Pos = worldCF.Position,
                    WorldCF = worldCF,
                    LocalCF_PetArea = localCF_PetArea,
                    LocalCF_Plot = localCF_Plot,
                    Row = r,
                    Col = c,
                }
            end
        end

        if pattern == "Dispersed" then
            -- 2-Phase Checkerboard pattern: Phase 1 maximizes diagonal & horizontal distances (>14.5 studs)
            local phase1, phase2 = {}, {}
            for r = 1, rows do
                for c = 1, cols do
                    if (r + c) % 2 == 0 then
                        table.insert(phase1, slotMatrix[r][c])
                    else
                        table.insert(phase2, slotMatrix[r][c])
                    end
                end
            end
            for _, s in ipairs(phase1) do table.insert(slots, s) end
            for _, s in ipairs(phase2) do table.insert(slots, s) end
        else
            -- Standard Row-by-Row
            for r = 1, rows do
                for c = 1, cols do
                    table.insert(slots, slotMatrix[r][c])
                end
            end
        end
    else
        -- Fallback if petArea not found
        local center = Vector3.new(522.3, 67.7, -166.4)
        local width = 40.0
        local length = 90.0
        local cols = math.max(1, math.floor(width / slotSpacing))
        local rows = math.max(1, math.floor(length / slotSpacing))
        for r = 1, rows do
            for c = 1, cols do
                local x = center.X - width / 2 + (c - 0.5) * (width / cols)
                local z = center.Z - length / 2 + (r - 0.5) * (length / rows)
                local wPos = Vector3.new(x, center.Y, z)
                local wCF = CFrame.new(wPos)
                table.insert(slots, {
                    Pos = wPos,
                    WorldCF = wCF,
                    LocalCF_PetArea = wCF,
                    LocalCF_Plot = plotPivot:ToObjectSpace(wCF),
                    Row = r,
                    Col = c,
                })
            end
        end
    end
    return slots
end

-- ================================================================================
-- 3. AUTO PLACEMENT EXECUTION ENGINE
-- ================================================================================
local function placeEgg(eggRecord, targetSlot, plot)
    if not Remotes.AskPlaceEgg then
        Remotes.AskPlaceEgg = getNetRemote("RF/EggWorld/AskPlaceEgg")
        if not Remotes.AskPlaceEgg then
            logMsg("❌ RF/EggWorld/AskPlaceEgg remote not found!")
            return false
        end
    end

    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local root = char and char:FindFirstChild("HumanoidRootPart")

    -- 1. Unequip any non-egg tool currently held (e.g. pets, bats, gear)
    if char and hum then
        for _, item in ipairs(char:GetChildren()) do
            if item:IsA("Tool") and not isRealEggTool(item) then
                pcall(function() hum:UnequipTools() end)
                task.wait(0.1)
                break
            end
        end
    end

    -- 2. Resolve target coordinates and CFrames
    local targetWorldPos = (type(targetSlot) == "table" and targetSlot.Pos) or targetSlot or Vector3.new(522.3, 67.7, -166.4)
    local targetWorldCF  = (type(targetSlot) == "table" and targetSlot.WorldCF) or CFrame.new(targetWorldPos)

    local plotPivot = CFrame.new()
    local okPiv, piv = pcall(function() return plot:GetPivot() end)
    if okPiv and piv then
        plotPivot = piv
    elseif plot and plot.PrimaryPart then
        plotPivot = plot.PrimaryPart.CFrame
    end

    local localCF_Plot = (type(targetSlot) == "table" and targetSlot.LocalCF_Plot) or plotPivot:ToObjectSpace(targetWorldCF)
    local localCF_PetArea = (type(targetSlot) == "table" and targetSlot.LocalCF_PetArea) or localCF_Plot

    -- 3. Proximity alignment: move character inside pen yard if far away
    if root then
        local distToPen = (root.Position - targetWorldPos).Magnitude
        if distToPen > 18.0 then
            logMsg("🚶 Character is %.1f studs away from pen. Moving inside pen...", distToPen)
            root.CFrame = CFrame.new(targetWorldPos.X, targetWorldPos.Y + 3.0, targetWorldPos.Z)
            task.wait(0.25)
        end
    end

    local distNow = root and (root.Position - targetWorldPos).Magnitude or 0
    logMsg("Placing [%s] (%s) at World:(%.1f, %.1f, %.1f) [Dist: %.1f] -> LocalPlot:(%.2f, %.2f, %.2f)",
        eggRecord.GroupName, eggRecord.Rarity, targetWorldPos.X, targetWorldPos.Y, targetWorldPos.Z,
        distNow, localCF_Plot.Position.X, localCF_Plot.Position.Y, localCF_Plot.Position.Z)

    -- 4. Wear/equip genuine egg tool (NEVER touch pets!)
    local eggUid = eggRecord.RawUid or eggRecord.Uid
    local eggTool = eggRecord.Tool
    if not eggTool or eggTool.Parent == nil or not isRealEggTool(eggTool) then
        eggTool = nil

        -- Invoke RF/EggWorld/AskWearTool to wear the egg from satchel
        local rfWear = Remotes.AskWearTool or getNetRemote("RF/EggWorld/AskWearTool")
        if rfWear then
            local okW, resW = pcall(function()
                return rfWear:InvokeServer(eggUid)
            end)
            if not okW or resW == false then
                pcall(function()
                    resW = rfWear:InvokeServer({ Uid = eggUid })
                end)
            end
            task.wait(0.15)
        end

        -- Search Character for the newly worn egg tool (STRICT: isRealEggTool ONLY)
        if char then
            for _, t in ipairs(char:GetChildren()) do
                if isRealEggTool(t) then
                    local tUid = t:GetAttribute("EggUid") or t:GetAttribute("UID") or t:GetAttribute("Uid")
                    if (tUid and tostring(tUid) == tostring(eggRecord.Uid)) or string.find(string.lower(t.Name), "egg", 1, true) then
                        eggTool = t
                        break
                    end
                end
            end
        end

        -- Search Backpack for genuine egg tool and equip if found (STRICT: isRealEggTool ONLY)
        if not eggTool then
            local bp = LocalPlayer:FindFirstChild("Backpack")
            if bp then
                for _, t in ipairs(bp:GetChildren()) do
                    if isRealEggTool(t) then
                        local tUid = t:GetAttribute("EggUid") or t:GetAttribute("UID") or t:GetAttribute("Uid")
                        if (tUid and tostring(tUid) == tostring(eggRecord.Uid)) or string.find(string.lower(t.Name), "egg", 1, true) then
                            eggTool = t
                            if hum then
                                pcall(function() hum:EquipTool(t) end)
                                task.wait(0.15)
                            end
                            break
                        end
                    end
                end
            end
        end
    end

    -- 5. Invoke RF/EggWorld/AskPlaceEgg with priority & fallback payloads
    local ok, res = false, false

    -- Try 5a: Introspected validated payload format
    if Introspect and Introspect.ValidatedPayloadFormat then
        local payload = Introspect.ValidatedPayloadFormat(eggUid, localCF_Plot)
        ok, res = pcall(function()
            return Remotes.AskPlaceEgg:InvokeServer(payload)
        end)
        if ok and res ~= false then
            logMsg("  ✓ AskPlaceEgg (Validated Schema): res=%s", tostring(res))
        end
    end

    -- Try 5b: Standard LocalCFrame relative to plot pivot
    if not ok or res == false then
        local placeArgs = {
            LocalCFrame = localCF_Plot,
            CFrame = localCF_Plot,
            Uid = eggUid,
        }
        ok, res = pcall(function()
            return Remotes.AskPlaceEgg:InvokeServer(placeArgs)
        end)
    end

    -- Try 5c: LocalCFrame relative to PetArea
    if ok and res == false then
        local placeArgs2 = {
            LocalCFrame = localCF_PetArea,
            CFrame = localCF_PetArea,
            Uid = eggUid,
        }
        local ok2, res2 = pcall(function()
            return Remotes.AskPlaceEgg:InvokeServer(placeArgs2)
        end)
        if ok2 and res2 ~= false then
            ok, res = ok2, res2
            logMsg("  ✓ AskPlaceEgg (PetArea LocalCF): res=%s", tostring(res))
        end
    end

    -- Try 5d: World CFrame
    if ok and res == false then
        local placeArgs3 = {
            LocalCFrame = targetWorldCF,
            CFrame = targetWorldCF,
            Uid = eggUid,
        }
        local ok3, res3 = pcall(function()
            return Remotes.AskPlaceEgg:InvokeServer(placeArgs3)
        end)
        if ok3 and res3 ~= false then
            ok, res = ok3, res3
            logMsg("  ✓ AskPlaceEgg (World CF): res=%s", tostring(res))
        end
    end

    -- Try 5e: Positional arguments (uid, localCF_Plot)
    if ok and res == false then
        local ok4, res4 = pcall(function()
            return Remotes.AskPlaceEgg:InvokeServer(eggUid, localCF_Plot)
        end)
        if ok4 and res4 ~= false then
            ok, res = ok4, res4
            logMsg("  ✓ AskPlaceEgg (Positional uid, localCF): res=%s", tostring(res))
        end
    end

    -- Try 5f: Positional arguments (localCF_Plot, uid)
    if ok and res == false then
        local ok5, res5 = pcall(function()
            return Remotes.AskPlaceEgg:InvokeServer(localCF_Plot, eggUid)
        end)
        if ok5 and res5 ~= false then
            ok, res = ok5, res5
            logMsg("  ✓ AskPlaceEgg (Positional localCF, uid): res=%s", tostring(res))
        end
    end

    -- Try 5g: Placement nested table { Placement = { CFrame = localCF_Plot }, Uid = eggUid }
    if ok and res == false then
        local placeArgsNested = {
            Placement = { CFrame = localCF_Plot, LocalCFrame = localCF_Plot },
            Uid = eggUid,
        }
        local ok6, res6 = pcall(function()
            return Remotes.AskPlaceEgg:InvokeServer(placeArgsNested)
        end)
        if ok6 and res6 ~= false then
            ok, res = ok6, res6
            logMsg("  ✓ AskPlaceEgg (Nested Placement): res=%s", tostring(res))
        end
    end

    local resStr = tostring(res)
    if type(res) == "table" then
        local parts = {}
        for k, v in pairs(res) do
            table.insert(parts, string.format("%s=%s", tostring(k), tostring(v)))
        end
        resStr = "{" .. table.concat(parts, ", ") .. "}"
    end

    logMsg("  ✓ AskPlaceEgg Result: ok=%s, res=%s", tostring(ok), resStr)

    -- 6. Fire RE/ToolTrigger/Trigger ONLY with genuine egg tool
    if Remotes.ToolTrigger and eggTool and isRealEggTool(eggTool) then
        pcall(function()
            Remotes.ToolTrigger:FireServer(eggTool)
        end)
        logMsg("  ✓ ToolTrigger: fired with <%s>", eggTool.Name)
    end

    task.wait(0.2)
    return ok and (res ~= false)
end

-- ================================================================================
-- 3b. BAG REPORT GENERATOR
-- ================================================================================
local function generateBagReportText()
    local lines = {}
    table.insert(lines, "==================================================")
    table.insert(lines, "🎒 STEAL AN EGG - BAG INVENTORY GROUPING REPORT")
    table.insert(lines, string.format("TIMESTAMP: %s", os.date("!%Y-%m-%dT%H:%M:%SZ")))
    table.insert(lines, string.format("TOTAL UNPLACED EGGS IN BAG: %d", #State.BagEggs))
    table.insert(lines, "==================================================")

    local sortedGroupNames = {}
    for gName in pairs(State.GroupedBag) do table.insert(sortedGroupNames, gName) end
    table.sort(sortedGroupNames)

    for i, gName in ipairs(sortedGroupNames) do
        local gData = State.GroupedBag[gName]
        table.insert(lines, string.format("[%d] 📦 %s (Total: %d)", i, gName, gData.TotalCount))

        local sortedRars = {}
        for rName in pairs(gData.Rarities) do table.insert(sortedRars, rName) end
        table.sort(sortedRars, function(a, b)
            return (RARITY_RANK[a] or 0) > (RARITY_RANK[b] or 0)
        end)

        for _, rName in ipairs(sortedRars) do
            local rData = gData.Rarities[rName]
            local isSel = State.SelectedKeys[gName .. "_" .. rName] and " [SELECTED]" or ""
            local sampleWeights = {}
            for k = 1, math.min(5, #rData.Eggs) do
                local w = rData.Eggs[k].Weight
                if w and w > 0 then
                    table.insert(sampleWeights, string.format("%.0fkg", w))
                end
            end
            local wStr = #sampleWeights > 0 and (" | Weights: " .. table.concat(sampleWeights, ", ")) or ""

            local spParts = {}
            if rData.SpeciesCounts then
                for sp, cnt in pairs(rData.SpeciesCounts) do
                    table.insert(spParts, string.format("%s x%d", sp, cnt))
                end
                table.sort(spParts)
            end
            local spStr = #spParts > 0 and (" (" .. table.concat(spParts, ", ") .. ")") or ""

            table.insert(lines, string.format("    • [%s] x %d%s%s%s", rName, rData.Count, spStr, wStr, isSel))
        end
    end
    table.insert(lines, "==================================================")
    return table.concat(lines, "\n")
end

-- ================================================================================
-- 4. INTERACTIVE USER INTERFACE & SELECTOR
-- ================================================================================
local function getGuiParent()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if pg then return pg end
    local ok, h = pcall(function() return (typeof(gethui) == "function" and gethui()) or CoreGui end)
    if ok and h then return h end
    return LocalPlayer:WaitForChild("PlayerGui")
end

local function buildUI()
    local parent = getGuiParent()
    local existing = parent:FindFirstChild("AutoPlaceEggTestGui")
    if existing then pcall(function() existing:Destroy() end) end

    local gui = Instance.new("ScreenGui")
    gui.Name = "AutoPlaceEggTestGui"
    gui.ResetOnSpawn = false
    gui.Parent = parent

    -- Main Window
    local main = Instance.new("Frame")
    main.Name = "MainFrame"
    main.Size = UDim2.new(0, 440, 0, 560)
    main.Position = UDim2.new(0, 40, 0, 60)
    main.BackgroundColor3 = Color3.fromRGB(16, 20, 30)
    main.BorderSizePixel = 0
    main.Active = true
    main.Draggable = true
    main.Parent = gui

    Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)
    local stroke = Instance.new("UIStroke", main)
    stroke.Color = Color3.fromRGB(55, 75, 115)
    stroke.Thickness = 1.5

    -- Title Bar
    local titleBar = Instance.new("Frame")
    titleBar.Size = UDim2.new(1, 0, 0, 36)
    titleBar.BackgroundColor3 = Color3.fromRGB(24, 32, 48)
    titleBar.Parent = main
    Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 10)

    local titleLbl = Instance.new("TextLabel")
    titleLbl.Size = UDim2.new(1, -70, 1, 0)
    titleLbl.Position = UDim2.new(0, 12, 0, 0)
    titleLbl.BackgroundTransparency = 1
    titleLbl.Text = "🎒 BAG EGG GROUPING & AUTO PLACE"
    titleLbl.TextColor3 = Color3.fromRGB(240, 245, 255)
    titleLbl.Font = Enum.Font.GothamBold
    titleLbl.TextSize = 12
    titleLbl.TextXAlignment = Enum.TextXAlignment.Left
    titleLbl.Parent = titleBar

    local closeBtn = Instance.new("TextButton")
    closeBtn.Size = UDim2.new(0, 26, 0, 24)
    closeBtn.Position = UDim2.new(1, -30, 0, 6)
    closeBtn.BackgroundColor3 = Color3.fromRGB(200, 45, 45)
    closeBtn.Text = "✕"
    closeBtn.TextColor3 = Color3.new(1, 1, 1)
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.TextSize = 11
    closeBtn.Parent = titleBar
    Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 4)
    closeBtn.MouseButton1Click:Connect(function() gui:Destroy() end)

    -- Scrollable Content Body
    local scroll = Instance.new("ScrollingFrame")
    scroll.Size = UDim2.new(1, -16, 1, -44)
    scroll.Position = UDim2.new(0, 8, 0, 40)
    scroll.BackgroundTransparency = 1
    scroll.ScrollBarThickness = 5
    scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    scroll.Parent = main

    local layout = Instance.new("UIListLayout", scroll)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 6)

    -- Top Action Buttons Toolbar
    local bar = Instance.new("Frame")
    bar.Size = UDim2.new(1, 0, 0, 32)
    bar.BackgroundTransparency = 1
    bar.Parent = scroll

    local barLayout = Instance.new("UIListLayout", bar)
    barLayout.FillDirection = Enum.FillDirection.Horizontal
    barLayout.Padding = UDim.new(0, 6)

    local scanBtn = Instance.new("TextButton")
    scanBtn.Size = UDim2.new(0.48, -3, 1, 0)
    scanBtn.BackgroundColor3 = Color3.fromRGB(35, 110, 80)
    scanBtn.Text = "🔄 Scan & Group Bag"
    scanBtn.TextColor3 = Color3.new(1, 1, 1)
    scanBtn.Font = Enum.Font.GothamBold
    scanBtn.TextSize = 11
    scanBtn.Parent = bar
    Instance.new("UICorner", scanBtn).CornerRadius = UDim.new(0, 5)

    local copyBtn = Instance.new("TextButton")
    copyBtn.Size = UDim2.new(0.48, -3, 1, 0)
    copyBtn.BackgroundColor3 = Color3.fromRGB(45, 90, 160)
    copyBtn.Text = "📋 Copy Bag Report"
    copyBtn.TextColor3 = Color3.new(1, 1, 1)
    copyBtn.Font = Enum.Font.GothamBold
    copyBtn.TextSize = 11
    copyBtn.Parent = bar
    Instance.new("UICorner", copyBtn).CornerRadius = UDim.new(0, 5)

    -- Status Card
    local statusCard = Instance.new("Frame")
    statusCard.Size = UDim2.new(1, 0, 0, 40)
    statusCard.BackgroundColor3 = Color3.fromRGB(20, 26, 40)
    statusCard.Parent = scroll
    Instance.new("UICorner", statusCard).CornerRadius = UDim.new(0, 6)

    local statusLbl = Instance.new("TextLabel")
    statusLbl.Size = UDim2.new(1, -12, 1, 0)
    statusLbl.Position = UDim2.new(0, 6, 0, 0)
    statusLbl.BackgroundTransparency = 1
    statusLbl.TextColor3 = Color3.fromRGB(220, 235, 255)
    statusLbl.Font = Enum.Font.GothamBold
    statusLbl.TextSize = 11
    statusLbl.Text = "Bag: 0 eggs | Selected: 0 to place | Pen Cap: 25"
    statusLbl.TextXAlignment = Enum.TextXAlignment.Left
    statusLbl.Parent = statusCard

    -- Quick Selection Toolbar
    local selBar = Instance.new("Frame")
    selBar.Size = UDim2.new(1, 0, 0, 26)
    selBar.BackgroundTransparency = 1
    selBar.Parent = scroll

    local selLayout = Instance.new("UIListLayout", selBar)
    selLayout.FillDirection = Enum.FillDirection.Horizontal
    selLayout.Padding = UDim.new(0, 6)

    local selectAllBtn = Instance.new("TextButton")
    selectAllBtn.Size = UDim2.new(0.48, -3, 1, 0)
    selectAllBtn.BackgroundColor3 = Color3.fromRGB(40, 75, 110)
    selectAllBtn.Text = "☑ Select All"
    selectAllBtn.TextColor3 = Color3.new(1, 1, 1)
    selectAllBtn.Font = Enum.Font.GothamBold
    selectAllBtn.TextSize = 10
    selectAllBtn.Parent = selBar
    Instance.new("UICorner", selectAllBtn).CornerRadius = UDim.new(0, 4)

    local clearAllBtn = Instance.new("TextButton")
    clearAllBtn.Size = UDim2.new(0.48, -3, 1, 0)
    clearAllBtn.BackgroundColor3 = Color3.fromRGB(75, 45, 60)
    clearAllBtn.Text = "☐ Clear All"
    clearAllBtn.TextColor3 = Color3.new(1, 1, 1)
    clearAllBtn.Font = Enum.Font.GothamBold
    clearAllBtn.TextSize = 10
    clearAllBtn.Parent = selBar
    Instance.new("UICorner", clearAllBtn).CornerRadius = UDim.new(0, 4)

    -- Group List Container
    local groupContainer = Instance.new("Frame")
    groupContainer.Size = UDim2.new(1, 0, 0, 0)
    groupContainer.AutomaticSize = Enum.AutomaticSize.Y
    groupContainer.BackgroundTransparency = 1
    groupContainer.Parent = scroll

    local gLayout = Instance.new("UIListLayout", groupContainer)
    gLayout.SortOrder = Enum.SortOrder.LayoutOrder
    gLayout.Padding = UDim.new(0, 6)

    -- Function to refresh the Group UI list
    local function refreshGroupCards()
        for _, ch in ipairs(groupContainer:GetChildren()) do
            if not ch:IsA("UIListLayout") then ch:Destroy() end
        end

        local totalSelected = 0
        local sortedGroups = {}
        for gName in pairs(State.GroupedBag) do table.insert(sortedGroups, gName) end
        table.sort(sortedGroups)

        for _, gName in ipairs(sortedGroups) do
            local gData = State.GroupedBag[gName]

            local card = Instance.new("Frame")
            card.Size = UDim2.new(1, 0, 0, 0)
            card.AutomaticSize = Enum.AutomaticSize.Y
            card.BackgroundColor3 = Color3.fromRGB(22, 28, 44)
            card.Parent = groupContainer
            Instance.new("UICorner", card).CornerRadius = UDim.new(0, 6)

            local cLayout = Instance.new("UIListLayout", card)
            cLayout.SortOrder = Enum.SortOrder.LayoutOrder
            cLayout.Padding = UDim.new(0, 3)
            Instance.new("UIPadding", card).PaddingTop = UDim.new(0, 6)
            card.UIPadding.PaddingBottom = UDim.new(0, 6)
            card.UIPadding.PaddingLeft = UDim.new(0, 8)
            card.UIPadding.PaddingRight = UDim.new(0, 8)

            -- Group Header
            local headerRow = Instance.new("Frame")
            headerRow.Size = UDim2.new(1, 0, 0, 24)
            headerRow.BackgroundTransparency = 1
            headerRow.Parent = card

            local gTitle = Instance.new("TextLabel")
            gTitle.Size = UDim2.new(1, -85, 1, 0)
            gTitle.BackgroundTransparency = 1
            gTitle.Text = string.format("📦 %s (%d)", gName, gData.TotalCount)
            gTitle.TextColor3 = Color3.fromRGB(255, 230, 100)
            gTitle.Font = Enum.Font.GothamBold
            gTitle.TextSize = 11
            gTitle.TextXAlignment = Enum.TextXAlignment.Left
            gTitle.Parent = headerRow

            local toggleAllBtn = Instance.new("TextButton")
            toggleAllBtn.Size = UDim2.new(0, 80, 0, 20)
            toggleAllBtn.Position = UDim2.new(1, -80, 0, 2)
            toggleAllBtn.BackgroundColor3 = Color3.fromRGB(45, 60, 90)
            toggleAllBtn.Text = "Toggle All"
            toggleAllBtn.TextColor3 = Color3.new(1, 1, 1)
            toggleAllBtn.Font = Enum.Font.GothamBold
            toggleAllBtn.TextSize = 9
            toggleAllBtn.Parent = headerRow
            Instance.new("UICorner", toggleAllBtn).CornerRadius = UDim.new(0, 4)

            -- Rarity Rows
            local sortedRars = {}
            for rName in pairs(gData.Rarities) do table.insert(sortedRars, rName) end
            table.sort(sortedRars, function(a, b)
                return (RARITY_RANK[a] or 0) > (RARITY_RANK[b] or 0)
            end)

            local rarityBtns = {}
            for _, rName in ipairs(sortedRars) do
                local rData = gData.Rarities[rName]
                local key = gName .. "_" .. rName
                local isChecked = (State.SelectedKeys[key] == true)
                if isChecked then totalSelected = totalSelected + rData.Count end

                local spParts = {}
                if rData.SpeciesCounts then
                    for sp, cnt in pairs(rData.SpeciesCounts) do
                        table.insert(spParts, string.format("%s x%d", sp, cnt))
                    end
                    table.sort(spParts)
                end
                local spSummary = #spParts > 0 and (" (" .. table.concat(spParts, ", ") .. ")") or ""
                if #spSummary > 38 then
                    spSummary = spSummary:sub(1, 35) .. "...)"
                end

                local rowBtn = Instance.new("TextButton")
                rowBtn.Size = UDim2.new(1, 0, 0, 22)
                rowBtn.BackgroundColor3 = isChecked and Color3.fromRGB(30, 65, 50) or Color3.fromRGB(28, 36, 54)
                rowBtn.Text = string.format("  [%s] %s  •  %d eggs%s", isChecked and "✓" or " ", rName, rData.Count, spSummary)
                rowBtn.TextColor3 = RARITY_COLORS[rName] or Color3.new(1, 1, 1)
                rowBtn.Font = Enum.Font.GothamBold
                rowBtn.TextSize = 10
                rowBtn.TextXAlignment = Enum.TextXAlignment.Left
                rowBtn.Parent = card
                Instance.new("UICorner", rowBtn).CornerRadius = UDim.new(0, 4)
                table.insert(rarityBtns, { Btn = rowBtn, Key = key, RName = rName, Count = rData.Count })

                rowBtn.MouseButton1Click:Connect(function()
                    State.SelectedKeys[key] = not State.SelectedKeys[key]
                    local nowChecked = State.SelectedKeys[key]
                    rowBtn.BackgroundColor3 = nowChecked and Color3.fromRGB(30, 65, 50) or Color3.fromRGB(28, 36, 54)
                    rowBtn.Text = string.format("  [%s] %s  •  %d eggs%s", nowChecked and "✓" or " ", rName, rData.Count, spSummary)
                    refreshGroupCards()
                end)
            end

            toggleAllBtn.MouseButton1Click:Connect(function()
                local anyUnchecked = false
                for _, rb in ipairs(rarityBtns) do
                    if not State.SelectedKeys[rb.Key] then anyUnchecked = true; break end
                end
                for _, rb in ipairs(rarityBtns) do
                    State.SelectedKeys[rb.Key] = anyUnchecked
                end
                refreshGroupCards()
            end)
        end

        local placed = scanPlacedEggs()
        statusLbl.Text = string.format("Bag: %d eggs | Selected: %d to place | Pen: %d / %d",
            #State.BagEggs, totalSelected, #placed, State.MaxEggsCap)
    end

    -- Spacing & Distribution Control Bar
    local spacingBar = Instance.new("Frame")
    spacingBar.Size = UDim2.new(1, 0, 0, 26)
    spacingBar.BackgroundTransparency = 1
    spacingBar.Parent = scroll

    local spacingLbl = Instance.new("TextLabel")
    spacingLbl.Size = UDim2.new(0.38, 0, 1, 0)
    spacingLbl.BackgroundTransparency = 1
    spacingLbl.Text = string.format("Spacing: %.0fst (%s)", State.GridSpacing, State.FillPattern)
    spacingLbl.TextColor3 = Color3.fromRGB(200, 220, 255)
    spacingLbl.Font = Enum.Font.GothamBold
    spacingLbl.TextSize = 10
    spacingLbl.TextXAlignment = Enum.TextXAlignment.Left
    spacingLbl.Parent = spacingBar

    local function updateSpacingUI()
        spacingLbl.Text = string.format("Spacing: %.0fst (%s)", State.GridSpacing, State.FillPattern)
    end

    local function createSpacingBtn(text, xPos, width, onClick)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(width, -3, 1, 0)
        btn.Position = UDim2.new(xPos, 0, 0, 0)
        btn.BackgroundColor3 = Color3.fromRGB(35, 45, 65)
        btn.Text = text
        btn.TextColor3 = Color3.fromRGB(220, 235, 255)
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 10
        btn.Parent = spacingBar
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 4)
        btn.MouseButton1Click:Connect(onClick)
        return btn
    end

    createSpacingBtn("7s", 0.38, 0.12, function()
        State.GridSpacing = 7.0
        updateSpacingUI()
        logMsg("Grid Spacing set to 7.0 studs (Dense)")
    end)

    createSpacingBtn("10s", 0.50, 0.13, function()
        State.GridSpacing = 10.0
        updateSpacingUI()
        logMsg("Grid Spacing set to 10.0 studs (Balanced, ~10.5st distance)")
    end)

    createSpacingBtn("13s", 0.63, 0.13, function()
        State.GridSpacing = 13.0
        updateSpacingUI()
        logMsg("Grid Spacing set to 13.0 studs (Spacious, ~13.5st distance)")
    end)

    local patBtn
    patBtn = createSpacingBtn(State.FillPattern == "Dispersed" and "Spread" or "Rows", 0.76, 0.24, function()
        if State.FillPattern == "Dispersed" then
            State.FillPattern = "Standard"
            patBtn.Text = "Rows"
        else
            State.FillPattern = "Dispersed"
            patBtn.Text = "Spread"
        end
        updateSpacingUI()
        logMsg("Grid Pattern set to %s", State.FillPattern)
    end)

    -- Bottom Action: Place Eggs Button
    local placeBar = Instance.new("Frame")
    placeBar.Size = UDim2.new(1, 0, 0, 32)
    placeBar.BackgroundTransparency = 1
    placeBar.Parent = scroll

    local placeBtn = Instance.new("TextButton")
    placeBtn.Size = UDim2.new(0.70, -3, 1, 0)
    placeBtn.BackgroundColor3 = Color3.fromRGB(40, 140, 60)
    placeBtn.Text = "🚀 Place Selected Eggs in Pen"
    placeBtn.TextColor3 = Color3.new(1, 1, 1)
    placeBtn.Font = Enum.Font.GothamBold
    placeBtn.TextSize = 11
    placeBtn.Parent = placeBar
    Instance.new("UICorner", placeBtn).CornerRadius = UDim.new(0, 5)

    local stopBtn = Instance.new("TextButton")
    stopBtn.Size = UDim2.new(0.28, -3, 1, 0)
    stopBtn.Position = UDim2.new(0.72, 0, 0, 0)
    stopBtn.BackgroundColor3 = Color3.fromRGB(160, 45, 45)
    stopBtn.Text = "🛑 Stop"
    stopBtn.TextColor3 = Color3.new(1, 1, 1)
    stopBtn.Font = Enum.Font.GothamBold
    stopBtn.TextSize = 11
    stopBtn.Parent = placeBar
    Instance.new("UICorner", stopBtn).CornerRadius = UDim.new(0, 5)

    stopBtn.MouseButton1Click:Connect(function()
        State.PlacingActive = false
        if State.PlaceThread then
            task.cancel(State.PlaceThread)
            State.PlaceThread = nil
        end
        if Remotes.AskDoffTool then
            pcall(function() Remotes.AskDoffTool:InvokeServer() end)
        end
        logMsg("Placement stopped by user.")
        placeBtn.Text = "🚀 Place Selected Eggs in Pen"
    end)

    placeBtn.MouseButton1Click:Connect(function()
        if State.PlacingActive then return end

        local plot, plotIdx = findMyPlot(true)
        if not plot then
            logMsg("❌ Cannot place eggs: Player plot not found!")
            return
        end

        -- Collect all selected eggs
        local eggsToPlace = {}
        for gName, gData in pairs(State.GroupedBag) do
            for rName, rData in pairs(gData.Rarities) do
                local key = gName .. "_" .. rName
                if State.SelectedKeys[key] then
                    for _, egg in ipairs(rData.Eggs) do
                        table.insert(eggsToPlace, egg)
                    end
                end
            end
        end

        if #eggsToPlace == 0 then
            logMsg("⚠️ No eggs selected! Check at least one group + rarity.")
            return
        end

        local currentPlaced = scanPlacedEggs()
        local availableSlots = math.max(0, State.MaxEggsCap - #currentPlaced)
        if availableSlots <= 0 then
            logMsg("⚠️ Pen is already at capacity (%d eggs placed)!", #currentPlaced)
            return
        end

        local countToPlace = math.min(#eggsToPlace, availableSlots)
        logMsg("🚀 Starting placement of %d selected eggs (Pen available: %d)...", countToPlace, availableSlots)

        State.PlacingActive = true
        placeBtn.Text = "PLACING EGGS..."

        State.PlaceThread = task.spawn(function()
            local gridSlots = generatePenGridSlots(plot)
            local currentPlacedList = scanPlacedEggs()
            local slotIdx = 1

            for i = 1, countToPlace do
                if not State.PlacingActive then break end
                local egg = eggsToPlace[i]

                -- Find next free slot not occupied by an existing placed egg
                local minOccDist = math.max(4.0, (State.GridSpacing or 10.0) * 0.55)
                local targetSlot = nil
                while slotIdx <= #gridSlots do
                    local candidate = gridSlots[slotIdx]
                    local candidatePos = (type(candidate) == "table" and candidate.Pos) or candidate
                    local occupied = false
                    for _, pEgg in ipairs(currentPlacedList) do
                        if (pEgg.Pos - candidatePos).Magnitude < minOccDist then
                            occupied = true
                            break
                        end
                    end
                    if not occupied then
                        targetSlot = candidate
                        slotIdx = slotIdx + 1
                        break
                    end
                    slotIdx = slotIdx + 1
                end

                if not targetSlot then
                    targetSlot = gridSlots[i] or Vector3.new(522.3, 67.7, -166.4)
                end

                local targetPos = (type(targetSlot) == "table" and targetSlot.Pos) or targetSlot
                local success = placeEgg(egg, targetSlot, plot)
                table.insert(currentPlacedList, { Pos = targetPos })
                task.wait(0.35)
            end

            State.PlacingActive = false
            placeBtn.Text = "🚀 Place Selected Eggs in Pen"
            if Remotes.AskDoffTool then
                pcall(function() Remotes.AskDoffTool:InvokeServer() end)
            end
            logMsg("✓ Placement cycle complete! Re-scanning bag...")
            scanAndGroupBag()
            refreshGroupCards()
        end)
    end)

    -- Live Log Terminal
    local logCard = Instance.new("Frame")
    logCard.Size = UDim2.new(1, 0, 0, 200)
    logCard.BackgroundColor3 = Color3.fromRGB(12, 16, 24)
    logCard.Parent = scroll
    Instance.new("UICorner", logCard).CornerRadius = UDim.new(0, 6)

    local logScroll = Instance.new("ScrollingFrame")
    logScroll.Size = UDim2.new(1, -12, 1, -12)
    logScroll.Position = UDim2.new(0, 6, 0, 6)
    logScroll.BackgroundTransparency = 1
    logScroll.ScrollBarThickness = 4
    logScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    logScroll.Parent = logCard

    local logBox = Instance.new("TextBox")
    logBox.Size = UDim2.new(1, 0, 0, 0)
    logBox.AutomaticSize = Enum.AutomaticSize.Y
    logBox.BackgroundTransparency = 1
    logBox.Font = Enum.Font.Code
    logBox.TextSize = 10
    logBox.TextColor3 = Color3.fromRGB(220, 235, 255)
    logBox.TextXAlignment = Enum.TextXAlignment.Left
    logBox.TextYAlignment = Enum.TextYAlignment.Top
    logBox.ClearTextOnFocus = false
    logBox.TextEditable = false
    logBox.MultiLine = true
    logBox.TextWrapped = true
    logBox.Text = table.concat(logEntries, "\n")
    logBox.Parent = logScroll

    logCallback = function(newLine)
        logBox.Text = table.concat(logEntries, "\n")
        logScroll.CanvasPosition = Vector2.new(0, 999999)
    end

    -- Toolbar Button Callbacks
    selectAllBtn.MouseButton1Click:Connect(function()
        for gName, gData in pairs(State.GroupedBag) do
            for rName in pairs(gData.Rarities) do
                State.SelectedKeys[gName .. "_" .. rName] = true
            end
        end
        refreshGroupCards()
    end)

    clearAllBtn.MouseButton1Click:Connect(function()
        State.SelectedKeys = {}
        refreshGroupCards()
    end)

    scanBtn.MouseButton1Click:Connect(function()
        scanBtn.Text = "Scanning..."
        scanAndGroupBag()
        refreshGroupCards()
        scanBtn.Text = "🔄 Scan & Group Bag"
    end)

    copyBtn.MouseButton1Click:Connect(function()
        local reportText = generateBagReportText()
        local copied = false
        pcall(function()
            if typeof(setclipboard) == "function" then setclipboard(reportText); copied = true end
        end)
        if not copied then
            pcall(function()
                if typeof(toclipboard) == "function" then toclipboard(reportText); copied = true end
            end)
        end
        if copied then
            copyBtn.Text = "✓ REPORT COPIED!"
            task.delay(1.5, function() copyBtn.Text = "📋 Copy Bag Report" end)
        else
            logBox.Text = reportText
            logBox:CaptureFocus()
            copyBtn.Text = "Press Ctrl+C"
            task.delay(1.5, function() copyBtn.Text = "📋 Copy Bag Report" end)
        end
    end)

    -- Initial scan
    scanAndGroupBag()
    refreshGroupCards()
end

-- Launch
findMyPlot()
buildUI()
logMsg("Auto Place Egg & Bag Grouping Test initialized.")
