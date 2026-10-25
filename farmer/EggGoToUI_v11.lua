--[[
    Egg Go-To UI v11 (Clean Modular UI Scaffold)
    ===========================================================================================
    Phase 1: Pure UI Skeleton
    - Minimal, clean UI containing exactly 1 sidebar button ("Eggs") and 1 active panel.
    - Zero legacy logic / background loops to ensure maximum performance and clean slate.
    - Draggable menu toggle button and draggable main window.
    - Fully managed connection tracking and safe cleanup (_G.EggGoToUI_Cleanup).
]]

local ok, err = pcall(function()

-- Terminate any previous running instance of this script
if _G.EggGoToUI_Cleanup then
    pcall(_G.EggGoToUI_Cleanup)
end
_G.EggGoToUI_Stop = false

local Workspace         = game:GetService("Workspace")
local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService       = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    local t0 = os.clock()
    while not LocalPlayer and (os.clock() - t0 < 3) do
        task.wait(0.1)
        LocalPlayer = Players.LocalPlayer
    end
    LocalPlayer = LocalPlayer or Players.LocalPlayer
end

local PlayerGui
do
    local function getSafeUiParent()
        if typeof(gethui) == "function" then
            local okHui, h = pcall(gethui)
            if okHui and h then return h end
        end
        local okCore, core = pcall(function() return game:GetService("CoreGui") end)
        if okCore and core then
            local okTest = pcall(function() local f = Instance.new("Folder", core); f:Destroy() end)
            if okTest then return core end
        end
        return (LocalPlayer and (LocalPlayer:FindFirstChild("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui", 5))) or game:GetService("CoreGui")
    end
    PlayerGui = getSafeUiParent()
end

-- Connection management
local connections = {}
local function addConnection(conn)
    table.insert(connections, conn)
    return conn
end

local function disconnectAll()
    for _, conn in ipairs(connections) do
        pcall(function() conn:Disconnect() end)
    end
    table.clear(connections)
end

-- ============================================================================
-- 1. BIOME & EGG CATALOG TAXONOMY (Phase 1, Step 1.1)
-- ============================================================================

local RARITY_COLORS = {
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
    ["Brainrot"]  = Color3.fromRGB(240, 60,  180),
    ["1%"]        = Color3.fromRGB(255, 105, 180),
}

local RARITY_RANK = {
    ["Common"] = 1, ["Uncommon"] = 2, ["Rare"] = 3, ["Epic"] = 4, ["Legendary"] = 5,
    ["Mythic"] = 6, ["Cosmic"] = 7, ["Secret"] = 8, ["Eternal"] = 9, ["Divine"] = 10,
    ["Brainrot"] = 11, ["1%"] = 12,
}

local RARITY_ORDER = {
    "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Cosmic", "Secret", "Eternal", "Divine"
}

-- 13 Canonical World Biomes (Structured hierarchy for easy tracking and manual updates)
-- Comprehensive Biome & Egg Catalog Taxonomy (Ground Truth + Server Discovered Assets)
local BIOME_EGG_CATALOG = {
    {
        Biome = "Forest",
        EggNames = { "Egg", "Forest Egg" },
        Species = {
            { Name = "Chicken", Rarity = "Common" },
            { Name = "Dog", Rarity = "Common" },
            { Name = "Bird", Rarity = "Uncommon", Aliases = { "DesertLark" } },
            { Name = "Owl", Rarity = "Rare", Aliases = { "Burrowing Owl" } },
            { Name = "Raccoon", Rarity = "Rare" },
            { Name = "Bear", Rarity = "Epic" },
            { Name = "Fox", Rarity = "Epic", Aliases = { "Mire Fox" } },
            { Name = "Brr", Rarity = "Legendary", Aliases = { "Brr Brr Patapim" } },
        }
    },
    {
        Biome = "Lake",
        EggNames = { "Lake Egg" },
        Species = {
            { Name = "Frog", Rarity = "Common" },
            { Name = "Duckling", Rarity = "Common" },
            { Name = "Catfish", Rarity = "Uncommon" },
            { Name = "Turtle", Rarity = "Rare" },
            { Name = "Trulimero", Rarity = "Epic", Aliases = { "Trulimero Trulicina" } },
            { Name = "Swan", Rarity = "Epic" },
            { Name = "Axolotl", Rarity = "Legendary", Aliases = { "Dream Axolotl" } },
            { Name = "Leviathan", Rarity = "Cosmic" },
        }
    },
    {
        Biome = "Desert",
        EggNames = { "Desert Egg" },
        Species = {
            { Name = "Jerboa", Rarity = "Common" },
            { Name = "Fennec", Rarity = "Uncommon", Aliases = { "FennecFox", "Fennec Fox" } },
            { Name = "Camel", Rarity = "Rare" },
            { Name = "Tob Tobi", Rarity = "Epic", Aliases = { "Tob Tobi Tob Tob", "TobTobi" } },
            { Name = "Snake", Rarity = "Legendary", Aliases = { "Rattlesnake" } },
            { Name = "Sand Spider", Rarity = "Mythic" },
            { Name = "Scorpion", Rarity = "Mythic", Aliases = { "DeathstalkerScorpion" } },
            { Name = "Royal Sphinx", Rarity = "Cosmic", Aliases = { "Irihorus" } },
        }
    },
    {
        Biome = "Jungle",
        EggNames = { "Jungle Egg" },
        Species = {
            { Name = "Toucan", Rarity = "Rare" },
            { Name = "Chimpanzee", Rarity = "Rare" },
            { Name = "Crocodile", Rarity = "Epic" },
            { Name = "Gorilla", Rarity = "Legendary" },
            { Name = "Orangutini", Rarity = "Legendary", Aliases = { "Orangutini Ananassini" } },
            { Name = "Spider", Rarity = "Mythic" },
            { Name = "Tiger", Rarity = "Mythic" },
            { Name = "King Snake", Rarity = "Secret", Aliases = { "Warden" } },
        }
    },
    {
        Biome = "Snow",
        EggNames = { "Snow Egg" },
        Species = {
            { Name = "Penguin", Rarity = "Rare" },
            { Name = "Walrus", Rarity = "Epic" },
            { Name = "Polar Bear", Rarity = "Legendary" },
            { Name = "Sabertooth Tiger", Rarity = "Mythic", Aliases = { "Sabertooth" } },
            { Name = "Mammoth", Rarity = "Mythic" },
            { Name = "King Mammoth", Rarity = "Cosmic", Aliases = { "Colossal Mammoth" } },
            { Name = "Yeti", Rarity = "Secret" },
            { Name = "Ice Dragon", Rarity = "Eternal" },
        }
    },
    {
        Biome = "Volcano",
        EggNames = { "Volcano Egg", "Lava Egg" },
        Species = {
            { Name = "Lava Gecko", Rarity = "Rare", Aliases = { "Ash Gecko" } },
            { Name = "Lava Frog", Rarity = "Epic", Aliases = { "Lava frog" } },
            { Name = "Flaming Bull", Rarity = "Legendary" },
            { Name = "Lava Iguana", Rarity = "Legendary" },
            { Name = "Chillin Chilli", Rarity = "Mythic" },
            { Name = "Cerberus", Rarity = "Secret" },
            { Name = "Phoenix", Rarity = "Eternal" },
            { Name = "Lava Dragon", Rarity = "Eternal", Aliases = { "Dragon" } },
        }
    },
    {
        Biome = "Abyss Ocean",
        EggNames = { "Abyss Ocean Egg", "Ocean Egg", "Depths Egg" },
        Species = {
            { Name = "Parrotfish", Rarity = "Rare" },
            { Name = "Swordfish", Rarity = "Epic" },
            { Name = "Shark", Rarity = "Legendary", Aliases = { "Finned Thresher" } },
            { Name = "Orca", Rarity = "Mythic" },
            { Name = "Whale Shark", Rarity = "Cosmic" },
            { Name = "Beluga Whale", Rarity = "Cosmic", Aliases = { "Alabaster Whale" } },
            { Name = "Kraken", Rarity = "Secret" },
            { Name = "El Maja", Rarity = "Eternal" },
        }
    },
    {
        Biome = "Prehistoric",
        EggNames = { "Prehistoric Egg" },
        Species = {
            { Name = "Dodo", Rarity = "Rare" },
            { Name = "Ptero", Rarity = "Legendary", Aliases = { "Pterodactyl" } },
            { Name = "Anky", Rarity = "Mythic", Aliases = { "Ankylosaurus" } },
            { Name = "Tri", Rarity = "Cosmic", Aliases = { "Triceratops" } },
            { Name = "Bronto", Rarity = "Cosmic" },
            { Name = "Trala", Rarity = "Secret", Aliases = { "Tralaledon" } },
            { Name = "TRex", Rarity = "Secret", Aliases = { "TyrannosaurusRex", "T-Rex" } },
            { Name = "Mosas", Rarity = "Eternal", Aliases = { "Mosasaurus" } },
        }
    },
    {
        Biome = "Cosmic",
        EggNames = { "Cosmic Egg" },
        Species = {
            { Name = "Centapede", Rarity = "Epic" },
            { Name = "Cosmic Gecko", Rarity = "Legendary", Aliases = { "Galaxy Gecko" } },
            { Name = "Cosmic Gorilla", Rarity = "Mythic", Aliases = { "Cyclops Gorilla" } },
            { Name = "La Vacca", Rarity = "Cosmic", Aliases = { "La Vacca Saturno Saturnita" } },
            { Name = "Cosmic Dragon", Rarity = "Secret", Aliases = { "Cave Dragon" } },
            { Name = "Skeleton Boss", Rarity = "Secret", Aliases = { "Alien Skeleton Boss", "Cosmic Skeleton Boss" } },
            { Name = "Lunar Dragon", Rarity = "Eternal", Aliases = { "Eternal Lunar Dragon" } },
            { Name = "Unicorn", Rarity = "Divine" },
        }
    },
    {
        Biome = "Cherry Blossom",
        EggNames = { "Cherry Blossom Egg" },
        Species = {
            { Name = "Crane", Rarity = "Epic" },
            { Name = "Salamander", Rarity = "Legendary" },
            { Name = "Red Panda", Rarity = "Mythic" },
            { Name = "Koi", Rarity = "Cosmic" },
            { Name = "Snowy Owl", Rarity = "Cosmic" },
            { Name = "Stag", Rarity = "Secret" },
            { Name = "Oni Tiger", Rarity = "Eternal" },
            { Name = "Kitsune", Rarity = "Divine" },
        }
    },
    {
        Biome = "Brainrot Event",
        EggNames = { "Brainrot Egg" },
        Species = {
            { Name = "Tung Tung Sahur", Rarity = "Brainrot" },
            { Name = "Bananita Dolphinita", Rarity = "Brainrot" },
            { Name = "Belula Beluga", Rarity = "Brainrot" },
            { Name = "Mangolini Parrochini", Rarity = "Brainrot" },
            { Name = "Bomboclat Crocolat", Rarity = "Brainrot" },
            { Name = "Strawberry Elephant", Rarity = "Brainrot" },
        }
    },
    {
        Biome = "Titan Temple",
        EggNames = { "Titan Temple Egg" },
        Species = {
            { Name = "Crustcia", Rarity = "Legendary", Aliases = { "Crustacia", "Crab" } },
            { Name = "Spiderod", Rarity = "Legendary", Aliases = { "Spideron", "Kaiju Spider", "Kaiju" } },
            { Name = "Bladehide", Rarity = "Mythic", Aliases = { "Blade Head" } },
            { Name = "Mantaris", Rarity = "Cosmic", Aliases = { "Mantis" } },
            { Name = "Rhinotaur", Rarity = "Cosmic", Aliases = { "Rhino" } },
            { Name = "Mutant Shark", Rarity = "Secret", Aliases = { "Shark" } },
            { Name = "Gorilla King", Rarity = "Eternal", Aliases = { "King Kong" } },
            { Name = "Nightflame", Rarity = "Divine", Aliases = { "Godzilla" } },
        }
    },
    {
        Biome = "Light & Dark",
        EggNames = { "Angels & Demons Egg", "Angels Egg", "Demons Egg", "Light Egg", "Dark Egg", "Angel Eggs", "Demon Eggs" },
        Species = {
            { Name = "Light Dove", Rarity = "Legendary", Aliases = { "Dove" } },
            { Name = "Winged Lamb", Rarity = "Mythic", Aliases = { "Lamb" } },
            { Name = "Sacred Moth", Rarity = "Cosmic", Aliases = { "Moth" } },
            { Name = "Holy Peacock", Rarity = "Cosmic", Aliases = { "Peacock" } },
            { Name = "Pure Jellyfish", Rarity = "Secret", Aliases = { "Jellyfish" } },
            { Name = "Centaur", Rarity = "Secret" },
            { Name = "Pegasus", Rarity = "Eternal" },
            { Name = "ArchAngel", Rarity = "Divine" },
            { Name = "Flame Sprite", Rarity = "Legendary" },
            { Name = "Toro", Rarity = "Mythic" },
            { Name = "Demon Hound", Rarity = "Cosmic" },
            { Name = "Imp", Rarity = "Cosmic" },
            { Name = "Gargoyle", Rarity = "Secret", Aliases = { "Dark Gargoyle" } },
            { Name = "Razor Fang", Rarity = "Secret", Aliases = { "RazorFang" } },
            { Name = "Skeleton Horse", Rarity = "Eternal" },
            { Name = "World Burner", Rarity = "Divine" },
        }
    },
    {
        Biome = "Enchanted Forest",
        EggNames = { "Enchanted Forest Egg" },
        Species = {
            { Name = "Prism Gecko", Rarity = "Legendary" },
            { Name = "Petal Beetle", Rarity = "Mythic", Aliases = { "Cosmic Beetle Blue", "Cosmic Beetle" } },
            { Name = "Enchanted Bluejay", Rarity = "Mythic" },
            { Name = "Astral Jackalope", Rarity = "Cosmic", Aliases = { "Spirit Hare", "Jackalope" } },
            { Name = "Spirit Panda", Rarity = "Cosmic" },
            { Name = "Starry Fox", Rarity = "Secret", Aliases = { "Cosmic Fox" } },
            { Name = "Celestial Sunlion", Rarity = "Eternal", Aliases = { "Sunlion" } },
            { Name = "Royal Skywhale", Rarity = "Divine", Aliases = { "Skywhale" } },
        }
    },
    {
        Biome = "Halloween Dimension",
        EggNames = { "Halloween Egg", "Halloween Dimension Egg", "Whiskers Egg", "Jesterpop Egg", "Candlefang Egg", "Hooded Gerbil Egg", "Toadstool Egg", "Halloween Royal Mimic Egg", "Candy Corn Egg" },
        Species = {
            { Name = "Whiskers", Rarity = "Epic" },
            { Name = "Halloween Dimension Egg", Rarity = "Legendary" },
            { Name = "Jesterpop", Rarity = "Legendary" },
            { Name = "Hooded Gerbil", Rarity = "Legendary", Aliases = { "Halloween Egg", "Halloween" } },
            { Name = "Halloween Royal Mimic Egg", Rarity = "Legendary", Aliases = { "Halloween Royal Mimic", "Royal Mimic", "Mimic Chest", "Mimic Chest Egg" } },
            { Name = "Mimic Chest", Rarity = "Legendary", Aliases = { "Mimic Chest Egg", "Halloween Royal Mimic Egg", "Halloween Royal Mimic", "Royal Mimic" } },
            { Name = "Halloween Dimension Egg", Rarity = "Mythic" },
            { Name = "Candlefang", Rarity = "Mythic" },
            { Name = "Toadstool", Rarity = "Mythic", Aliases = { "Rotshroom", "Rotshroom Egg" } },
            { Name = "Crowshade", Rarity = "Mythic" },
            { Name = "Halloween Dimension Egg", Rarity = "Cosmic" },
            { Name = "Spirit Knight", Rarity = "Cosmic", Aliases = { "SpiritKnight" } },
            { Name = "Patchwork Imp", Rarity = "Cosmic", Aliases = { "Quilted Imp Egg", "Quilted Imp" } },
            { Name = "Haunted Scorpio", Rarity = "Cosmic" },
            { Name = "Hexed Pumpkin", Rarity = "Cosmic" },
            { Name = "Graveyard Brute", Rarity = "Secret" },
            { Name = "Halloween Dimension Egg", Rarity = "Secret" },
            { Name = "Ghost Reaper", Rarity = "Eternal" },
            { Name = "Halloween Dimension Egg", Rarity = "Eternal" },
            { Name = "Candy Corn Egg", Rarity = "Legendary", Aliases = { "Candy Corn" } },
            { Name = "Mummy Egg", Rarity = "Epic", Aliases = { "Mummy" } },
            { Name = "Ghost Fish Egg", Rarity = "Epic", Aliases = { "Ghost Fish" } },
            { Name = "Witch Pumpkin Egg", Rarity = "Legendary", Aliases = { "Witch Pumpkin" } },
            { Name = "Zombified Halloween Egg", Rarity = "Mythic", Aliases = { "Zombified Halloween" } },
            { Name = "Halloween Boss Egg", Rarity = "Cosmic", Aliases = { "Halloween Boss" } },
            { Name = "Jester Egg", Rarity = "Legendary", Aliases = { "Jester" } },
            { Name = "Witch Crow Egg", Rarity = "Cosmic", Aliases = { "Witch Crow" } },
            { Name = "BloodBloom Egg", Rarity = "Secret", Aliases = { "BloodBloom" } },
            { Name = "Shelltide Voyager Egg", Rarity = "Eternal", Aliases = { "Shelltide Voyager" } },
            { Name = "Werewolf Egg", Rarity = "Secret", Aliases = { "Werewolf" } },
            { Name = "Abomination Kong Egg", Rarity = "Eternal", Aliases = { "Abomination Kong" } },
            { Name = "Voidseer Pumpkin Egg", Rarity = "Divine", Aliases = { "Voidseer Pumpkin" } },
            { Name = "Pumpkin Golem", Rarity = "Secret", Aliases = { "Pumpkin Golem Egg" } },
        }
    },
    {
        Biome = "Monster Eggs",
        EggNames = { "Monster Egg" },
        Species = {
            { Name = "Monster Egg (Scorpio)", Rarity = "Legendary", Aliases = { "Scorpio" } },
            { Name = "Monster Egg (Froggo)", Rarity = "Mythic", Aliases = { "Froggo" } },
            { Name = "Monster Egg (Crawler)", Rarity = "Cosmic", Aliases = { "Crawler" } },
            { Name = "Monster Egg (Crocodon)", Rarity = "Secret", Aliases = { "Crocodon" } },
            { Name = "Monster Egg (Krakenoid)", Rarity = "Eternal", Aliases = { "Krakenoid" } },
            { Name = "Monster Egg (Dreadscale)", Rarity = "Divine", Aliases = { "Dreadscale" } },
            { Name = "Monster Egg (Mecha Scorpio)", Rarity = "1%", Aliases = { "Mecha Scorpio" } },
            { Name = "Monster Egg (Mecha Froggo)", Rarity = "1%", Aliases = { "Mecha Froggo" } },
            { Name = "Monster Egg (Mecha Crawler)", Rarity = "1%", Aliases = { "Mecha Crawler" } },
            { Name = "Monster Egg (Mecha Crocodon)", Rarity = "1%", Aliases = { "Mecha Crocodon" } },
            { Name = "Monster Egg (Mecha Krakenoid)", Rarity = "1%", Aliases = { "Mecha Krakenoid" } },
            { Name = "Monster Egg (Mecha Dreadscale)", Rarity = "1%", Aliases = { "Mecha Dreadscale" } },
        }
    },
    {
        Biome = "Void Eggs",
        EggNames = { "Void Egg", "Riftborn Egg", "Riftbeasts Egg", "Shattered Rift Egg" },
        Species = {
            { Name = "Riftborn Egg (Rift Eye)", Rarity = "Legendary", Aliases = { "Rift Eye" } },
            { Name = "Riftborn Egg (Voidmaw)", Rarity = "Mythic", Aliases = { "Voidmaw" } },
            { Name = "Riftborn Egg (Ventinal)", Rarity = "Cosmic", Aliases = { "Ventinal" } },
            { Name = "Riftborn Egg (Wendigo)", Rarity = "Secret", Aliases = { "Wendigo" } },
            { Name = "Riftborn Egg (World Eater)", Rarity = "Eternal", Aliases = { "World Eater" } },
            { Name = "Riftbeasts Egg (Void Angler)", Rarity = "Legendary", Aliases = { "Void Angler" } },
            { Name = "Riftbeasts Egg (Riftwing)", Rarity = "Mythic", Aliases = { "Riftwing" } },
            { Name = "Riftbeasts Egg (Dreadclaw)", Rarity = "Cosmic", Aliases = { "Dreadclaw" } },
            { Name = "Riftbeasts Egg (Mawbreaker)", Rarity = "Secret", Aliases = { "Mawbreaker" } },
            { Name = "Riftbeasts Egg (Void Serpent)", Rarity = "Eternal", Aliases = { "Void Serpent" } },
            { Name = "Shattered Rift Egg (Shardling)", Rarity = "Mythic", Aliases = { "Shardling" } },
            { Name = "Shattered Rift Egg (Shattered Ram)", Rarity = "Cosmic", Aliases = { "Shattered Ram" } },
            { Name = "Shattered Rift Egg (Shardwing)", Rarity = "Secret", Aliases = { "Shardwing" } },
            { Name = "Shattered Rift Egg (Shattered Drake)", Rarity = "Eternal", Aliases = { "Shattered Drake" } },
            { Name = "Shattered Rift Egg (Shattered Colossus)", Rarity = "Divine", Aliases = { "Shattered Colossus" } },
        }
    },
    {
        Biome = "Luminous Eggs",
        EggNames = { "Luminous Egg" },
        Species = {
            { Name = "Luminous Egg (Spike)", Rarity = "Legendary", Aliases = { "Spike" } },
            { Name = "Luminous Egg (Spirit Manta)", Rarity = "Mythic", Aliases = { "Spirit Manta" } },
            { Name = "Luminous Egg (Abyss Shark)", Rarity = "Cosmic", Aliases = { "Abyss Shark" } },
            { Name = "Luminous Egg (Electric Eel)", Rarity = "Secret", Aliases = { "Electric Eel" } },
            { Name = "Luminous Egg (Terra Snapper)", Rarity = "Eternal", Aliases = { "Terra Snapper" } },
            { Name = "Luminous Egg (Cthulhu)", Rarity = "Divine", Aliases = { "Cthulhu" } },
            { Name = "Luminous Egg (Luminous Spike)", Rarity = "1%", Aliases = { "Luminous Spike" } },
            { Name = "Luminous Egg (Luminous Spirit Manta)", Rarity = "1%", Aliases = { "Luminous Spirit Manta" } },
            { Name = "Luminous Egg (Luminous Abyss Shark)", Rarity = "1%", Aliases = { "Luminous Abyss Shark" } },
            { Name = "Luminous Egg (Luminous Electric Eel)", Rarity = "1%", Aliases = { "Luminous Electric Eel" } },
            { Name = "Luminous Egg (Luminous Terra Snapper)", Rarity = "1%", Aliases = { "Luminous Terra Snapper" } },
            { Name = "Luminous Egg (Luminous Cthulhu)", Rarity = "1%", Aliases = { "Luminous Cthulhu" } },
        }
    },
    {
        Biome = "Dr. Scramble's Laboratory",
        EggNames = { "Biohazard Egg", "Experimental Pets Egg", "Unstable DNA Egg" },
        Species = {
            { Name = "Biohazard Egg (Toxic Rat)", Rarity = "Mythic", Aliases = { "Toxic Rat" } },
            { Name = "Experimental Pets Egg (Wheel Hamster)", Rarity = "Mythic", Aliases = { "Wheel Hamster" } },
            { Name = "Unstable DNA Egg (Frogfly)", Rarity = "Mythic", Aliases = { "Frogfly" } },
            { Name = "Biohazard Egg (Radcoon)", Rarity = "Cosmic", Aliases = { "Radcoon" } },
            { Name = "Experimental Pets Egg (Stacked Turtle)", Rarity = "Cosmic", Aliases = { "Stacked Turtle" } },
            { Name = "Unstable DNA Egg (Spiderpig)", Rarity = "Cosmic", Aliases = { "Spiderpig" } },
            { Name = "Biohazard Egg (Toucax)", Rarity = "Cosmic", Aliases = { "Toucax" } },
            { Name = "Experimental Pets Egg (Three Headed Chicken)", Rarity = "Cosmic", Aliases = { "Three Headed Chicken" } },
            { Name = "Unstable DNA Egg (Sharkodile)", Rarity = "Secret", Aliases = { "Sharkodile" } },
            { Name = "Biohazard Egg (Nuceodile)", Rarity = "Secret", Aliases = { "Nuceodile" } },
            { Name = "Experimental Pets Egg (Eyeball Crab)", Rarity = "Secret", Aliases = { "Eyeball Crab" } },
            { Name = "Unstable DNA Egg (Rhinobear)", Rarity = "Eternal", Aliases = { "Rhinobear" } },
            { Name = "Biohazard Egg (Nuclear Mantis)", Rarity = "Eternal", Aliases = { "Nuclear Mantis" } },
            { Name = "Experimental Pets Egg (Deadstinger)", Rarity = "Eternal", Aliases = { "Deadstinger" } },
            { Name = "Unstable DNA Egg (Octophant)", Rarity = "Divine", Aliases = { "Octophant" } },
        }
    },
    {
        Biome = "Dr. Scramble's Experiments",
        EggNames = { "Experiment #001 Egg", "Nibbles Egg" },
        Species = {
            { Name = "Experiment #001", Rarity = "Secret" },
            { Name = "Nibbles", Rarity = "Cosmic" },
        }
    },
    {
        Biome = "Extinction Eggs",
        EggNames = { "Extinction Egg" },
        Species = {
            { Name = "Extinction Egg (Glyptodon)", Rarity = "Legendary", Aliases = { "Glyptodon" } },
            { Name = "Extinction Egg (Terrorbird)", Rarity = "Mythic", Aliases = { "Terrorbird" } },
            { Name = "Extinction Egg (Giant Sloth)", Rarity = "Cosmic", Aliases = { "Giant Sloth" } },
            { Name = "Extinction Egg (Dunkleosteus)", Rarity = "Secret", Aliases = { "Dunkleosteus" } },
            { Name = "Extinction Egg (Skeletal Glyptodon)", Rarity = "Secret", Aliases = { "Skeletal Glyptodon" } },
            { Name = "Extinction Egg (Skeletal Terrorbird)", Rarity = "Secret", Aliases = { "Skeletal Terrorbird" } },
            { Name = "Extinction Egg (Skeletal Giant Sloth)", Rarity = "Secret", Aliases = { "Skeletal Giant Sloth" } },
            { Name = "Extinction Egg (Gigantus)", Rarity = "Eternal", Aliases = { "Gigantus" } },
            { Name = "Extinction Egg (Skeletal Dunkleosteus)", Rarity = "Eternal", Aliases = { "Skeletal Dunkleosteus" } },
            { Name = "Extinction Egg (Skeletal Gigantus)", Rarity = "Eternal", Aliases = { "Skeletal Gigantus" } },
            { Name = "Extinction Egg (Sabertooth)", Rarity = "Divine", Aliases = { "Sabertooth" } },
            { Name = "Extinction Egg (Skeletal Sabertooth)", Rarity = "Divine", Aliases = { "Skeletal Sabertooth" } },
        }
    },
    {
        Biome = "Racing Event Eggs",
        EggNames = { "Racing Egg", "Race Egg", "Seahorse Egg" },
        Species = {
            { Name = "Seahorse", Rarity = "Legendary", Aliases = { "Race Seahorse" } },
            { Name = "Race Lizard", Rarity = "Rare" },
            { Name = "Race Bird", Rarity = "Cosmic" },
            { Name = "Race Cheetah", Rarity = "Secret" },
            { Name = "Engine Snail", Rarity = "Eternal" },
        }
    },
    {
        Biome = "Ungrouped",
        EggNames = { "Event Egg", "Special Egg" },
        Species = {
        }
    },
}

-- Fast lookup indexes
local SPECIES_INFO, SPECIES_INFO_BY_BIOME, EGG_ALIASES = {}, {}, {}

local function normalizeSpecies(name)
    if not name or type(name) ~= "string" then return "" end
    local str = name:lower():gsub("^%b[]%s*", "")
    str = str:gsub("%s*%(x%d+%)%s*$", ""):gsub("%s*%(%d+%%%)%s*$", ""):gsub("%s*%(%+%d+%)%s*$", "")
    for _, prefix in ipairs({ "rainbow", "golden", "silver", "gold", "shiny" }) do
        str = str:gsub("^" .. prefix .. "%s+", "")
    end
    str = str:gsub("%s*egg%s*$", ""):gsub("^%s*", ""):gsub("%s*$", "")
    return str
end

local function isGenericEggName(name)
    if not name or type(name) ~= "string" then return true end
    local clean = normalizeSpecies(name)
    if clean == "" or clean == "egg" or clean == "field" or clean == "field egg" or clean == "forest egg"
        or clean == "unknown" or clean == "slot" or clean:find("^field%s*egg") or clean:find("^forest%s*egg") then
        return true
    end
    return false
end

-- Populate indexes
for _, biomeData in ipairs(BIOME_EGG_CATALOG) do
    if not SPECIES_INFO_BY_BIOME[biomeData.Biome] then
        SPECIES_INFO_BY_BIOME[biomeData.Biome] = {}
    end

    for _, spec in ipairs(biomeData.Species) do
        local canonicalNorm = normalizeSpecies(spec.Name)
        local record = {
            DisplayName = spec.Name,
            Rarity      = spec.Rarity,
            Rank        = RARITY_RANK[spec.Rarity] or 0,
            Biome       = biomeData.Biome,
            IsCataloged = true,
        }
        if canonicalNorm ~= "" and not SPECIES_INFO[canonicalNorm] then
            SPECIES_INFO[canonicalNorm] = record
        end
        if canonicalNorm ~= "" then
            SPECIES_INFO_BY_BIOME[biomeData.Biome][canonicalNorm] = record
        end

        local inner = spec.Name:match("%((.-)%)")
        if inner then
            local innerNorm = normalizeSpecies(inner)
            if innerNorm ~= "" then
                if not SPECIES_INFO[innerNorm] then
                    SPECIES_INFO[innerNorm] = record
                end
                SPECIES_INFO_BY_BIOME[biomeData.Biome][innerNorm] = record
                EGG_ALIASES[innerNorm] = canonicalNorm
            end
        end

        if spec.Aliases then
            for _, alias in ipairs(spec.Aliases) do
                local aliasNorm = normalizeSpecies(alias)
                if aliasNorm ~= "" then
                    SPECIES_INFO_BY_BIOME[biomeData.Biome][aliasNorm] = record
                    EGG_ALIASES[aliasNorm] = canonicalNorm
                    if not SPECIES_INFO[aliasNorm] then
                        SPECIES_INFO[aliasNorm] = record
                    end
                end
            end
        end
    end

    if biomeData.Biome == "Light & Dark" then
        if not SPECIES_INFO_BY_BIOME["Angel Eggs"] then SPECIES_INFO_BY_BIOME["Angel Eggs"] = {} end
        if not SPECIES_INFO_BY_BIOME["Demon Eggs"] then SPECIES_INFO_BY_BIOME["Demon Eggs"] = {} end
        for k, v in pairs(SPECIES_INFO_BY_BIOME["Light & Dark"]) do
            if v.DisplayName:find("Dove") or v.DisplayName:find("Lamb") or v.DisplayName:find("Moth") or v.DisplayName:find("Peacock") or v.DisplayName:find("Jellyfish") or v.DisplayName:find("Centaur") or v.DisplayName:find("Pegasus") or v.DisplayName:find("ArchAngel") then
                SPECIES_INFO_BY_BIOME["Angel Eggs"][k] = v
            else
                SPECIES_INFO_BY_BIOME["Demon Eggs"][k] = v
            end
        end
    end
    if biomeData.Biome == "Halloween Dimension" then
        SPECIES_INFO_BY_BIOME["Halloween"] = SPECIES_INFO_BY_BIOME["Halloween Dimension"]
    end
end

local function getSpeciesInfo(name, biomeFilter)
    local clean = normalizeSpecies(name)
    if clean == "" then return nil end
    if biomeFilter and SPECIES_INFO_BY_BIOME[biomeFilter] then
        local bRec = SPECIES_INFO_BY_BIOME[biomeFilter][clean]
        if bRec then return bRec end
    end
    if clean == "shark" and (biomeFilter == "Titan Temple" or biomeFilter == "Temple") then
        local bTable = SPECIES_INFO_BY_BIOME["Titan Temple"]
        if bTable and bTable["mutant shark"] then return bTable["mutant shark"] end
    end
    if SPECIES_INFO[clean] then return SPECIES_INFO[clean] end
    local canonical = EGG_ALIASES[clean]
    if canonical and SPECIES_INFO[canonical] then
        return SPECIES_INFO[canonical]
    end
    for _, bTable in pairs(SPECIES_INFO_BY_BIOME) do
        if bTable[clean] then return bTable[clean] end
    end
    return nil
end

-- Keep legacy lookup helpers in a local scope so they don't consume registers
-- throughout this large LocalScript. They are currently not called elsewhere.
do
    local function getSpeciesRarity(name)
        local info = getSpeciesInfo(name)
        return info and info.Rarity or "Common"
    end

    local function getSpeciesBiome(name)
        local info = getSpeciesInfo(name)
        return info and info.Biome or nil
    end

    local function matchSpecies(nameA, nameB)
        local a = normalizeSpecies(nameA)
        local b = normalizeSpecies(nameB)
        if a == "" or b == "" then return false end
        if a == b then return true end
        local aliasA = EGG_ALIASES[a]
        local aliasB = EGG_ALIASES[b]
        if aliasA and aliasA == b then return true end
        if aliasB and aliasB == a then return true end
        if aliasA and aliasB and aliasA == aliasB then return true end
        return false
    end
end

-- ============================================================================
-- UI CONSTRUCTION
-- ============================================================================

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "EggGoToUI_v11"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = PlayerGui

-- Floating Toggle Button
local menuToggleBtn = Instance.new("TextButton")
menuToggleBtn.Name = "MenuToggleBtn"
menuToggleBtn.Size = UDim2.new(0, 40, 0, 40)
menuToggleBtn.Position = UDim2.new(0, 8, 0, 50)
menuToggleBtn.BackgroundColor3 = Color3.fromRGB(32, 40, 60)
menuToggleBtn.Text = "☰"
menuToggleBtn.TextColor3 = Color3.fromRGB(200, 215, 255)
menuToggleBtn.TextSize = 22
menuToggleBtn.Font = Enum.Font.GothamBold
menuToggleBtn.ZIndex = 200
menuToggleBtn.Parent = screenGui

Instance.new("UICorner", menuToggleBtn).CornerRadius = UDim.new(0, 8)
do
    local toggleStroke = Instance.new("UIStroke", menuToggleBtn)
    toggleStroke.Color = Color3.fromRGB(70, 110, 180)
    toggleStroke.Thickness = 1.5

    -- Drag handling for floating toggle button
    local tDragging, tDragStart, tStartPos = false, nil, nil
    addConnection(menuToggleBtn.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            tDragging = true
            tDragStart = input.Position
            tStartPos = menuToggleBtn.Position
        end
    end))

    addConnection(menuToggleBtn.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            tDragging = false
        end
    end))

    addConnection(UserInputService.InputChanged:Connect(function(input)
        if tDragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - tDragStart
            menuToggleBtn.Position = UDim2.new(
                tStartPos.X.Scale, tStartPos.X.Offset + delta.X,
                tStartPos.Y.Scale, tStartPos.Y.Offset + delta.Y
            )
        end
    end))
end

-- Main Window Frame
local main = Instance.new("Frame")
main.Name = "MainFrame"
main.Size = UDim2.new(0, 380, 0, 520)
main.Position = UDim2.new(0.5, -190, 0.5, -260)
main.BackgroundColor3 = Color3.fromRGB(22, 24, 30)
main.BorderSizePixel = 0
main.Parent = screenGui

local closeBtn = Instance.new("TextButton")

do
    Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)
    local mainStroke = Instance.new("UIStroke", main)
    mainStroke.Color = Color3.fromRGB(70, 110, 180)
    mainStroke.Thickness = 1.5

    -- Title Bar
    local titleBar = Instance.new("Frame")
    titleBar.Name = "TitleBar"
    titleBar.Size = UDim2.new(1, 0, 0, 36)
    titleBar.BackgroundColor3 = Color3.fromRGB(32, 40, 60)
    titleBar.BorderSizePixel = 0
    titleBar.Parent = main

    Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 10)

    -- Bottom filler for TitleBar corners
    local titleCornerFix = Instance.new("Frame")
    titleCornerFix.Name = "CornerFix"
    titleCornerFix.Size = UDim2.new(1, 0, 0, 12)
    titleCornerFix.Position = UDim2.new(0, 0, 1, -12)
    titleCornerFix.BackgroundColor3 = Color3.fromRGB(32, 40, 60)
    titleCornerFix.BorderSizePixel = 0
    titleCornerFix.Parent = titleBar

    local titleLabel = Instance.new("TextLabel")
    titleLabel.Name = "TitleLabel"
    titleLabel.Size = UDim2.new(1, -80, 1, 0)
    titleLabel.Position = UDim2.new(0, 12, 0, 0)
    titleLabel.BackgroundTransparency = 1
    titleLabel.Text = "Egg Go-To v11"
    titleLabel.TextColor3 = Color3.fromRGB(220, 230, 255)
    titleLabel.TextSize = 13
    titleLabel.Font = Enum.Font.GothamBold
    titleLabel.TextXAlignment = Enum.TextXAlignment.Left
    titleLabel.Parent = titleBar

    closeBtn.Name = "CloseBtn"
    closeBtn.Size = UDim2.new(0, 30, 0, 24)
    closeBtn.Position = UDim2.new(1, -38, 0.5, -12)
    closeBtn.BackgroundColor3 = Color3.fromRGB(170, 50, 50)
    closeBtn.Text = "✕"
    closeBtn.TextColor3 = Color3.new(1, 1, 1)
    closeBtn.TextSize = 13
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.Parent = titleBar
    Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)

    -- Drag handling for Main Frame
    local dragging, dragStart, startPos = false, nil, nil
    addConnection(titleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = main.Position
        end
    end))

    addConnection(titleBar.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end))

    addConnection(UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            main.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end))
end

-- Sidebar Navigation Rail (Width: 46px)
local SIDEBAR_W = 46
local sidebar = Instance.new("Frame")
sidebar.Name = "Sidebar"
sidebar.Size = UDim2.new(0, SIDEBAR_W, 1, -36)
sidebar.Position = UDim2.new(0, 0, 0, 36)
sidebar.BackgroundColor3 = Color3.fromRGB(26, 32, 46)
sidebar.BorderSizePixel = 0
sidebar.Parent = main

do
    local sidebarDivider = Instance.new("Frame")
    sidebarDivider.Name = "SidebarDivider"
    sidebarDivider.Size = UDim2.new(0, 1, 1, 0)
    sidebarDivider.Position = UDim2.new(1, -1, 0, 0)
    sidebarDivider.BackgroundColor3 = Color3.fromRGB(50, 70, 105)
    sidebarDivider.BorderSizePixel = 0
    sidebarDivider.Parent = sidebar
end

-- Sidebar Button 1: Eggs
local tabBtnEggs = Instance.new("TextButton")
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

-- Sidebar Button 2: Utility & Fast Pickup
local tabBtnUtility = Instance.new("TextButton")
tabBtnUtility.Name = "TabBtnUtility"
tabBtnUtility.Size = UDim2.new(0, 34, 0, 34)
tabBtnUtility.Position = UDim2.new(0.5, -17, 0, 52)
tabBtnUtility.BackgroundColor3 = Color3.fromRGB(35, 42, 60)
tabBtnUtility.Text = "⚡"
tabBtnUtility.TextColor3 = Color3.fromRGB(150, 170, 200)
tabBtnUtility.TextSize = 18
tabBtnUtility.Font = Enum.Font.GothamBold
tabBtnUtility.Parent = sidebar
Instance.new("UICorner", tabBtnUtility).CornerRadius = UDim.new(0, 6)

-- Sidebar Button 3: Halloween Dimension
local tabBtnHalloween = Instance.new("TextButton")
tabBtnHalloween.Name = "TabBtnHalloween"
tabBtnHalloween.Size = UDim2.new(0, 34, 0, 34)
tabBtnHalloween.Position = UDim2.new(0.5, -17, 0, 94)
tabBtnHalloween.BackgroundColor3 = Color3.fromRGB(35, 42, 60)
tabBtnHalloween.Text = "🎃"
tabBtnHalloween.TextColor3 = Color3.fromRGB(150, 170, 200)
tabBtnHalloween.TextSize = 18
tabBtnHalloween.Font = Enum.Font.GothamBold
tabBtnHalloween.Parent = sidebar
Instance.new("UICorner", tabBtnHalloween).CornerRadius = UDim.new(0, 6)

-- Content Area Container
local contentContainer = Instance.new("Frame")
contentContainer.Name = "ContentContainer"
contentContainer.Size = UDim2.new(1, -SIDEBAR_W, 1, -36)
contentContainer.Position = UDim2.new(0, SIDEBAR_W, 0, 36)
contentContainer.BackgroundTransparency = 1
contentContainer.BorderSizePixel = 0
contentContainer.ClipsDescendants = true
contentContainer.Parent = main

-- Panel 1: Eggs Panel
local tabEggs = Instance.new("Frame")
tabEggs.Name = "TabEggs"
tabEggs.Size = UDim2.new(1, 0, 1, 0)
tabEggs.Position = UDim2.new(0, 0, 0, 0)
tabEggs.BackgroundTransparency = 1
tabEggs.BorderSizePixel = 0
tabEggs.ClipsDescendants = false
tabEggs.Visible = true
tabEggs.Parent = contentContainer

-- Panel 2: Utility Panel
local tabUtility = Instance.new("Frame")
tabUtility.Name = "TabUtility"
tabUtility.Size = UDim2.new(1, 0, 1, 0)
tabUtility.Position = UDim2.new(0, 0, 0, 0)
tabUtility.BackgroundTransparency = 1
tabUtility.BorderSizePixel = 0
tabUtility.ClipsDescendants = false
tabUtility.Visible = false
tabUtility.Parent = contentContainer

-- Panel 3: Halloween Panel (Isolated Module)
local tabHalloween = Instance.new("Frame")
tabHalloween.Name = "TabHalloween"
tabHalloween.Size = UDim2.new(1, 0, 1, 0)
tabHalloween.Position = UDim2.new(0, 0, 0, 0)
tabHalloween.BackgroundTransparency = 1
tabHalloween.BorderSizePixel = 0
tabHalloween.ClipsDescendants = false
tabHalloween.Visible = false
tabHalloween.Parent = contentContainer

local hwStatusLabel, halloweenEngine, hwAutoFarmBtn, lblFarmStatus, hwAutoFishBtn, lblFishStatus, hwLogLabel = nil, nil, nil, nil, nil, nil, nil
local hwEggListScroll
local hwEmptyNotice
local hwRarityBtn
local hwRarityDropList
local hwRarityDd
-- "New Update" is a real filter entry (not force-shown), so the live list and the
-- auto-farm agree on which eggs are farmable. It stays selected by default.
local selectedHwRarities = { ["New Update"] = true, ["Divine"] = true, ["Eternal"] = true, ["Secret"] = true }
local renderHalloweenEggs
local hwAutoPickBtn
local hwAutoPickEnabled = false
local togglePickupBtn
local setHwAutoPick
local setUtilityAutoPick
local startHalloweenAutoPickup, executeHwPickupSpam, pickupHwEgg, hwPickupToken = nil, nil, nil, 0

-- Shared Dropdown Open/Close Controller
local openDropdown = nil

local function closeCurrentDropdown()
    if openDropdown then
        openDropdown.list.Visible = false
        if openDropdown.updateBtnText then
            openDropdown.updateBtnText(false)
        end
        openDropdown = nil
    end
end

local function toggleDropdown(dd)
    if openDropdown == dd then
        closeCurrentDropdown()
    else
        closeCurrentDropdown()
        openDropdown = dd
        dd.list.Visible = true
        if dd.onOpen then dd.onOpen() end
        if dd.updateBtnText then dd.updateBtnText(true) end
    end
end

local function isInsideGui(guiObj, pos)
    if not (guiObj and guiObj.Visible) then return false end
    local ok, a = pcall(function() return guiObj.AbsolutePosition end)
    local ok2, s = pcall(function() return guiObj.AbsoluteSize end)
    if not (ok and ok2 and a and s) then return false end
    return pos.X >= a.X and pos.X <= a.X + s.X and pos.Y >= a.Y and pos.Y <= a.Y + s.Y
end

addConnection(UserInputService.InputBegan:Connect(function(input)
    if not openDropdown then return end
    if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
    local p = input.Position
    if not isInsideGui(openDropdown.btn, p) and not isInsideGui(openDropdown.list, p) then
        closeCurrentDropdown()
    end
end))

local function createFilterDropdown(cfg)
    local dropList = Instance.new("Frame")
    dropList.Name = (cfg.title or "Filter") .. "DropList"
    dropList.Size = cfg.size or UDim2.new(1, 0, 0, 260)
    dropList.Position = cfg.pos or UDim2.new(0, 0, 0, 28)
    dropList.BackgroundColor3 = cfg.bgColor or Color3.fromRGB(24, 29, 42)
    dropList.BorderSizePixel = 0
    dropList.ZIndex = cfg.zIndex or 50
    dropList.ClipsDescendants = true
    dropList.Visible = false
    dropList.Parent = cfg.parent
    Instance.new("UICorner", dropList).CornerRadius = UDim.new(0, 6)

    local stroke = Instance.new("UIStroke", dropList)
    stroke.Color = cfg.strokeColor or Color3.fromRGB(60, 85, 130)
    stroke.Thickness = 1

    local quickRow = Instance.new("Frame")
    quickRow.Size = UDim2.new(1, -6, 0, 22)
    quickRow.Position = UDim2.new(0, 3, 0, 3)
    quickRow.BackgroundTransparency = 1
    quickRow.ZIndex = (cfg.zIndex or 50) + 1
    quickRow.Parent = dropList

    local allBtn = Instance.new("TextButton")
    allBtn.Size = UDim2.new(0.5, -2, 1, 0)
    allBtn.Position = UDim2.new(0, 0, 0, 0)
    allBtn.BackgroundColor3 = Color3.fromRGB(45, 95, 150)
    allBtn.Text = "All"
    allBtn.TextColor3 = Color3.new(1, 1, 1)
    allBtn.TextSize = 11
    allBtn.Font = Enum.Font.GothamBold
    allBtn.ZIndex = (cfg.zIndex or 50) + 2
    allBtn.Parent = quickRow
    Instance.new("UICorner", allBtn).CornerRadius = UDim.new(0, 4)

    local noneBtn = Instance.new("TextButton")
    noneBtn.Size = UDim2.new(0.5, -2, 1, 0)
    noneBtn.Position = UDim2.new(0.5, 2, 0, 0)
    noneBtn.BackgroundColor3 = Color3.fromRGB(110, 45, 45)
    noneBtn.Text = "None"
    noneBtn.TextColor3 = Color3.new(1, 1, 1)
    noneBtn.TextSize = 11
    noneBtn.Font = Enum.Font.GothamBold
    noneBtn.ZIndex = (cfg.zIndex or 50) + 2
    noneBtn.Parent = quickRow
    Instance.new("UICorner", noneBtn).CornerRadius = UDim.new(0, 4)

    local itemsContainer
    if cfg.scrollable then
        local scroll = Instance.new("ScrollingFrame")
        scroll.Size = UDim2.new(1, -6, 1, -29)
        scroll.Position = UDim2.new(0, 3, 0, 27)
        scroll.BackgroundTransparency = 1
        scroll.ScrollBarThickness = 3
        scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
        scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
        scroll.ZIndex = (cfg.zIndex or 50) + 1
        scroll.Parent = dropList
        itemsContainer = scroll
    else
        local frame = Instance.new("Frame")
        frame.Size = UDim2.new(1, -6, 1, -29)
        frame.Position = UDim2.new(0, 3, 0, 27)
        frame.BackgroundTransparency = 1
        frame.ZIndex = (cfg.zIndex or 50) + 1
        frame.Parent = dropList
        itemsContainer = frame
    end

    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 2)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = itemsContainer

    local itemBtns = {}

    local function updateBtnText(isOpen)
        local arrow = isOpen and "▲" or "▼"
        local sel = cfg.getSelected()
        if sel["All"] then
            cfg.btn.Text = cfg.title .. ": All " .. arrow
            return
        end
        local list = {}
        for _, it in ipairs(cfg.items) do
            if sel[it] then table.insert(list, it) end
        end
        if #list == 0 then
            cfg.btn.Text = cfg.title .. ": None " .. arrow
        elseif #list == 1 then
            cfg.btn.Text = cfg.title .. ": " .. list[1] .. " " .. arrow
        else
            cfg.btn.Text = string.format("%s: %s +%d %s", cfg.title, list[1], #list - 1, arrow)
        end
    end

    local function refreshButtons()
        local sel = cfg.getSelected()
        for _, it in ipairs(cfg.items) do
            local on = sel["All"] == true or sel[it] == true
            local b = itemBtns[it]
            if b then
                b.BackgroundColor3 = on and Color3.fromRGB(48, 80, 125) or (cfg.itemBg or Color3.fromRGB(32, 38, 52))
                b.Text = (on and "[X] " or "[ ] ") .. it
            end
        end
    end

    for i, it in ipairs(cfg.items) do
        local b = Instance.new("TextButton")
        b.Name = (cfg.title or "Item") .. "_" .. it
        b.Size = UDim2.new(1, cfg.scrollable and -4 or 0, 0, 20)
        b.LayoutOrder = i
        b.BackgroundColor3 = cfg.itemBg or Color3.fromRGB(32, 38, 52)
        b.Text = "[X] " .. it
        local col = (cfg.colorMap and cfg.colorMap[it]) or Color3.fromRGB(220, 230, 255)
        if it == "New Update" and (not cfg.colorMap or not cfg.colorMap[it]) then
            col = Color3.fromRGB(235, 150, 60)
        end
        b.TextColor3 = col
        b.TextSize = 11
        b.Font = Enum.Font.GothamBold
        b.TextXAlignment = Enum.TextXAlignment.Left
        b.ZIndex = (cfg.zIndex or 50) + 2
        b.Parent = itemsContainer
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 4)
        local pad = Instance.new("UIPadding")
        pad.PaddingLeft = UDim.new(0, 6)
        pad.Parent = b
        itemBtns[it] = b

        b.MouseButton1Click:Connect(function()
            local sel = cfg.getSelected()
            if sel["All"] then sel = {} end
            if sel[it] then sel[it] = nil else sel[it] = true end
            local totalChecked = 0
            for _, checkIt in ipairs(cfg.items) do
                if sel[checkIt] then totalChecked = totalChecked + 1 end
            end
            if totalChecked == #cfg.items then
                sel = { ["All"] = true }
            end
            cfg.setSelected(sel)
            updateBtnText(true)
            refreshButtons()
            if cfg.onChanged then cfg.onChanged() end
        end)
    end

    allBtn.MouseButton1Click:Connect(function()
        cfg.setSelected({ ["All"] = true })
        updateBtnText(true)
        refreshButtons()
        if cfg.onChanged then cfg.onChanged() end
    end)

    noneBtn.MouseButton1Click:Connect(function()
        cfg.setSelected({})
        updateBtnText(true)
        refreshButtons()
        if cfg.onChanged then cfg.onChanged() end
    end)

    local dd = {
        btn = cfg.btn,
        list = dropList,
        onOpen = refreshButtons,
        updateBtnText = updateBtnText,
    }

    cfg.btn.MouseButton1Click:Connect(function() toggleDropdown(dd) end)

    if not cfg.skipInitialUpdate then
        updateBtnText(false)
    end
    refreshButtons()

    return dd
end

-- Halloween Panel: Auto-Pickup, Rarity Filter & Live List Scrolling Container
do
    -- Auto Farm Engine Row (Two-Column: Text Left, Toggle Right - Placeholder)
    local hwAutoFarmRow = Instance.new("Frame")
    hwAutoFarmRow.Name = "HwAutoFarmRow"
    hwAutoFarmRow.Size = UDim2.new(1, -16, 0, 36)
    hwAutoFarmRow.Position = UDim2.new(0, 8, 0, 6)
    hwAutoFarmRow.BackgroundColor3 = Color3.fromRGB(24, 28, 40)
    hwAutoFarmRow.BorderSizePixel = 0
    hwAutoFarmRow.Parent = tabHalloween
    Instance.new("UICorner", hwAutoFarmRow).CornerRadius = UDim.new(0, 6)
    local strokeAutoFarm = Instance.new("UIStroke", hwAutoFarmRow)
    strokeAutoFarm.Color = Color3.fromRGB(45, 55, 75)
    strokeAutoFarm.Thickness = 1

    local lblFarmTitle = Instance.new("TextLabel")
    lblFarmTitle.Name = "LblFarmTitle"
    lblFarmTitle.Size = UDim2.new(1, -76, 0, 18)
    lblFarmTitle.Position = UDim2.new(0, 10, 0, 2)
    lblFarmTitle.BackgroundTransparency = 1
    lblFarmTitle.Text = "Auto Farm Engine"
    lblFarmTitle.TextColor3 = Color3.fromRGB(225, 235, 255)
    lblFarmTitle.Font = Enum.Font.GothamBold
    lblFarmTitle.TextSize = 12
    lblFarmTitle.TextXAlignment = Enum.TextXAlignment.Left
    lblFarmTitle.Parent = hwAutoFarmRow

    lblFarmStatus = Instance.new("TextLabel")
    lblFarmStatus.Name = "LblFarmStatus"
    lblFarmStatus.Size = UDim2.new(1, -76, 0, 14)
    lblFarmStatus.Position = UDim2.new(0, 10, 0, 19)
    lblFarmStatus.BackgroundTransparency = 1
    lblFarmStatus.Text = "Status: Idle (Placeholder)"
    lblFarmStatus.TextColor3 = Color3.fromRGB(150, 160, 180)
    lblFarmStatus.Font = Enum.Font.Gotham
    lblFarmStatus.TextSize = 10
    lblFarmStatus.TextXAlignment = Enum.TextXAlignment.Left
    lblFarmStatus.Parent = hwAutoFarmRow

    hwAutoFarmBtn = Instance.new("TextButton")
    hwAutoFarmBtn.Name = "HwAutoFarmBtn"
    hwAutoFarmBtn.Size = UDim2.new(0, 56, 0, 24)
    hwAutoFarmBtn.Position = UDim2.new(1, -66, 0.5, -12)
    hwAutoFarmBtn.BackgroundColor3 = Color3.fromRGB(45, 50, 65)
    hwAutoFarmBtn.Text = "OFF"
    hwAutoFarmBtn.TextColor3 = Color3.fromRGB(180, 190, 210)
    hwAutoFarmBtn.Font = Enum.Font.GothamBold
    hwAutoFarmBtn.TextSize = 11
    hwAutoFarmBtn.Parent = hwAutoFarmRow
    Instance.new("UICorner", hwAutoFarmBtn).CornerRadius = UDim.new(0, 5)

    local function setHwAutoFarm(enabled)
        if halloweenEngine and halloweenEngine.autoFarm then
            if enabled then
                halloweenEngine.autoFarm.start()
            else
                halloweenEngine.autoFarm.stop("Manual Stop")
            end
        else
            if hwAutoFarmBtn then
                hwAutoFarmBtn.Text = enabled and "ON" or "OFF"
                hwAutoFarmBtn.BackgroundColor3 = enabled and Color3.fromRGB(35, 135, 75) or Color3.fromRGB(45, 50, 65)
                hwAutoFarmBtn.TextColor3 = enabled and Color3.new(1, 1, 1) or Color3.fromRGB(180, 190, 210)
            end
            if lblFarmStatus then
                lblFarmStatus.Text = enabled and "Status: Active (Placeholder)" or "Status: Idle (Placeholder)"
                lblFarmStatus.TextColor3 = enabled and Color3.fromRGB(80, 210, 120) or Color3.fromRGB(150, 160, 180)
            end
        end
    end

    addConnection(hwAutoFarmBtn.MouseButton1Click:Connect(function()
        local isEnabled = halloweenEngine and halloweenEngine.autoFarmEnabled
        setHwAutoFarm(not isEnabled)
    end))

    -- Auto Fishing Engine Row (Two-Column: Text Left, Toggle Right)
    local hwAutoFishRow = Instance.new("Frame")
    hwAutoFishRow.Name = "HwAutoFishRow"
    hwAutoFishRow.Size = UDim2.new(1, -16, 0, 36)
    hwAutoFishRow.Position = UDim2.new(0, 8, 0, 46)
    hwAutoFishRow.BackgroundColor3 = Color3.fromRGB(24, 28, 40)
    hwAutoFishRow.BorderSizePixel = 0
    hwAutoFishRow.Parent = tabHalloween
    Instance.new("UICorner", hwAutoFishRow).CornerRadius = UDim.new(0, 6)
    local strokeAutoFish = Instance.new("UIStroke", hwAutoFishRow)
    strokeAutoFish.Color = Color3.fromRGB(45, 55, 75)
    strokeAutoFish.Thickness = 1

    local lblFishTitle = Instance.new("TextLabel")
    lblFishTitle.Name = "LblFishTitle"
    lblFishTitle.Size = UDim2.new(1, -76, 0, 18)
    lblFishTitle.Position = UDim2.new(0, 10, 0, 2)
    lblFishTitle.BackgroundTransparency = 1
    lblFishTitle.Text = "Auto Fishing"
    lblFishTitle.TextColor3 = Color3.fromRGB(225, 235, 255)
    lblFishTitle.Font = Enum.Font.GothamBold
    lblFishTitle.TextSize = 12
    lblFishTitle.TextXAlignment = Enum.TextXAlignment.Left
    lblFishTitle.Parent = hwAutoFishRow

    lblFishStatus = Instance.new("TextLabel")
    lblFishStatus.Name = "LblFishStatus"
    lblFishStatus.Size = UDim2.new(1, -76, 0, 14)
    lblFishStatus.Position = UDim2.new(0, 10, 0, 19)
    lblFishStatus.BackgroundTransparency = 1
    lblFishStatus.Text = "Status: Idle"
    lblFishStatus.TextColor3 = Color3.fromRGB(150, 160, 180)
    lblFishStatus.Font = Enum.Font.Gotham
    lblFishStatus.TextSize = 10
    lblFishStatus.TextXAlignment = Enum.TextXAlignment.Left
    lblFishStatus.Parent = hwAutoFishRow

    hwAutoFishBtn = Instance.new("TextButton")
    hwAutoFishBtn.Name = "HwAutoFishBtn"
    hwAutoFishBtn.Size = UDim2.new(0, 56, 0, 24)
    hwAutoFishBtn.Position = UDim2.new(1, -66, 0.5, -12)
    hwAutoFishBtn.BackgroundColor3 = Color3.fromRGB(45, 50, 65)
    hwAutoFishBtn.Text = "OFF"
    hwAutoFishBtn.TextColor3 = Color3.fromRGB(180, 190, 210)
    hwAutoFishBtn.Font = Enum.Font.GothamBold
    hwAutoFishBtn.TextSize = 11
    hwAutoFishBtn.Parent = hwAutoFishRow
    Instance.new("UICorner", hwAutoFishBtn).CornerRadius = UDim.new(0, 5)

    local function setHwAutoFish(enabled)
        -- When Auto Farm is ON, fishing is a managed phase of the same engine:
        -- farm matching eggs -> wait 3 seconds -> fish. Do not start a competing loop.
        if halloweenEngine and halloweenEngine.autoFarmEnabled then
            if halloweenEngine.fishing and halloweenEngine.fishing.log then
                halloweenEngine.fishing.log("Auto Fishing is managed by Halloween Auto Farm: farm eggs -> wait 3s -> fish.")
            end
            if hwAutoFishBtn then
                hwAutoFishBtn.Text = "AUTO"
                hwAutoFishBtn.BackgroundColor3 = Color3.fromRGB(45, 90, 135)
                hwAutoFishBtn.TextColor3 = Color3.new(1, 1, 1)
            end
            return
        end

        if halloweenEngine and halloweenEngine.fishing then
            if enabled then
                halloweenEngine.fishing.start()
            else
                halloweenEngine.fishing.stop("Manual Stop")
            end
        else
            if hwAutoFishBtn then
                hwAutoFishBtn.Text = enabled and "ON" or "OFF"
                hwAutoFishBtn.BackgroundColor3 = enabled and Color3.fromRGB(35, 135, 75) or Color3.fromRGB(45, 50, 65)
                hwAutoFishBtn.TextColor3 = enabled and Color3.new(1, 1, 1) or Color3.fromRGB(180, 190, 210)
            end
            if lblFishStatus then
                lblFishStatus.Text = enabled and "Status: Active" or "Status: Idle"
                lblFishStatus.TextColor3 = enabled and Color3.fromRGB(80, 210, 120) or Color3.fromRGB(150, 160, 180)
            end
        end
    end

    addConnection(hwAutoFishBtn.MouseButton1Click:Connect(function()
        local isEnabled = halloweenEngine and halloweenEngine.fishing and halloweenEngine.fishing.enabled
        setHwAutoFish(not isEnabled)
    end))

    -- Auto Pick Toggle Bar (Above Rarity Filter)
    local hwAutoPickFrame = Instance.new("Frame")
    hwAutoPickFrame.Name = "HwAutoPickFrame"
    hwAutoPickFrame.Size = UDim2.new(1, -16, 0, 24)
    hwAutoPickFrame.Position = UDim2.new(0, 8, 0, 86)
    hwAutoPickFrame.BackgroundTransparency = 1
    hwAutoPickFrame.BorderSizePixel = 0
    hwAutoPickFrame.Parent = tabHalloween

    hwAutoPickBtn = Instance.new("TextButton")
    hwAutoPickBtn.Name = "HwAutoPickBtn"
    hwAutoPickBtn.Size = UDim2.new(1, 0, 1, 0)
    hwAutoPickBtn.Position = UDim2.new(0, 0, 0, 0)
    hwAutoPickBtn.BackgroundColor3 = Color3.fromRGB(36, 44, 62)
    hwAutoPickBtn.Text = "[OFF] Auto Pick [E]"
    hwAutoPickBtn.TextColor3 = Color3.fromRGB(180, 190, 210)
    hwAutoPickBtn.TextSize = 11
    hwAutoPickBtn.Font = Enum.Font.GothamBold
    hwAutoPickBtn.Parent = hwAutoPickFrame
    Instance.new("UICorner", hwAutoPickBtn).CornerRadius = UDim.new(0, 5)

    setHwAutoPick = function(enabled, syncOther)
        hwAutoPickEnabled = enabled
        if hwAutoPickBtn then
            hwAutoPickBtn.Text = hwAutoPickEnabled and "[ON] Auto Pick [E]" or "[OFF] Auto Pick [E]"
            hwAutoPickBtn.BackgroundColor3 = hwAutoPickEnabled and Color3.fromRGB(35, 135, 75) or Color3.fromRGB(36, 44, 62)
            hwAutoPickBtn.TextColor3 = hwAutoPickEnabled and Color3.new(1, 1, 1) or Color3.fromRGB(180, 190, 210)
        end

        -- Reciprocal synchronization: if Halloween auto pick turns ON, utility turns OFF; if Halloween turns OFF, utility turns ON
        if syncOther ~= false and setUtilityAutoPick then
            setUtilityAutoPick(not hwAutoPickEnabled, false)
        end
    end

    hwAutoPickBtn.MouseButton1Click:Connect(function()
        setHwAutoPick(not hwAutoPickEnabled)
    end)

    -- Rarity Filter Bar (Only Rarity Dropdown - Positioned below Auto Pick)
    local hwFilterFrame = Instance.new("Frame")
    hwFilterFrame.Name = "HwFilterFrame"
    hwFilterFrame.Size = UDim2.new(1, -16, 0, 24)
    hwFilterFrame.Position = UDim2.new(0, 8, 0, 114)
    hwFilterFrame.BackgroundTransparency = 1
    hwFilterFrame.BorderSizePixel = 0
    hwFilterFrame.ClipsDescendants = false
    hwFilterFrame.ZIndex = 30
    hwFilterFrame.Parent = tabHalloween

    hwRarityBtn = Instance.new("TextButton")
    hwRarityBtn.Name = "HwRarityFilterBtn"
    hwRarityBtn.Size = UDim2.new(1, 0, 1, 0)
    hwRarityBtn.Position = UDim2.new(0, 0, 0, 0)
    hwRarityBtn.BackgroundColor3 = Color3.fromRGB(36, 44, 62)
    hwRarityBtn.Text = "Rarity: Secret +2 ▼"
    hwRarityBtn.TextColor3 = Color3.fromRGB(220, 230, 255)
    hwRarityBtn.TextSize = 11
    hwRarityBtn.Font = Enum.Font.GothamBold
    hwRarityBtn.ZIndex = 31
    hwRarityBtn.Parent = hwFilterFrame
    Instance.new("UICorner", hwRarityBtn).CornerRadius = UDim.new(0, 5)

    -- Halloween Rarity Dropdown List
    local RARITY_ROWS = { "New Update", table.unpack(RARITY_ORDER) }
    hwRarityDd = createFilterDropdown({
        parent = hwFilterFrame,
        btn = hwRarityBtn,
        title = "Rarity",
        items = RARITY_ROWS,
        getSelected = function() return selectedHwRarities end,
        setSelected = function(v) selectedHwRarities = v end,
        onChanged = function() if renderHalloweenEggs then pcall(renderHalloweenEggs) end end,
        size = UDim2.new(1, 0, 0, 280),
        pos = UDim2.new(0, 0, 0, 26),
        bgColor = Color3.fromRGB(24, 20, 34),
        strokeColor = Color3.fromRGB(90, 55, 120),
        itemBg = Color3.fromRGB(32, 28, 44),
        colorMap = RARITY_COLORS,
        skipInitialUpdate = true,
    })
    hwRarityDropList = hwRarityDd.list

    -- Scrolling Frame for detected Halloween eggs (Directly below rarity filter)
    hwEggListScroll = Instance.new("ScrollingFrame")
    hwEggListScroll.Name = "HwEggListScroll"
    hwEggListScroll.Size = UDim2.new(1, -16, 1, -266)
    hwEggListScroll.Position = UDim2.new(0, 8, 0, 144)
    hwEggListScroll.BackgroundTransparency = 1
    hwEggListScroll.BorderSizePixel = 0
    hwEggListScroll.ScrollBarThickness = 4
    hwEggListScroll.ScrollBarImageColor3 = Color3.fromRGB(200, 95, 25)
    hwEggListScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    hwEggListScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    hwEggListScroll.ZIndex = 1
    hwEggListScroll.Parent = tabHalloween

    local hwListLayout = Instance.new("UIListLayout")
    hwListLayout.Padding = UDim.new(0, 3)
    hwListLayout.SortOrder = Enum.SortOrder.LayoutOrder
    hwListLayout.Parent = hwEggListScroll

    local hwListPadding = Instance.new("UIPadding")
    hwListPadding.PaddingTop = UDim.new(0, 2)
    hwListPadding.PaddingBottom = UDim.new(0, 12)
    hwListPadding.PaddingLeft = UDim.new(0, 2)
    hwListPadding.PaddingRight = UDim.new(0, 6)
    hwListPadding.Parent = hwEggListScroll

    hwEmptyNotice = Instance.new("TextLabel")
    hwEmptyNotice.Name = "EmptyNotice"
    hwEmptyNotice.Size = UDim2.new(1, -20, 0, 80)
    hwEmptyNotice.Position = UDim2.new(0, 10, 0, 30)
    hwEmptyNotice.BackgroundTransparency = 1
    hwEmptyNotice.Text = "🎃 No Halloween eggs detected in current world.\nEnter the Halloween Portal to view eggs."
    hwEmptyNotice.TextColor3 = Color3.fromRGB(180, 165, 190)
    hwEmptyNotice.TextSize = 11.5
    hwEmptyNotice.Font = Enum.Font.Gotham
    hwEmptyNotice.TextWrapped = true
    hwEmptyNotice.Visible = true
    hwEmptyNotice.LayoutOrder = 1
    hwEmptyNotice.Parent = hwEggListScroll

    -- Small Log Box below the farm list
    local hwLogFrame = Instance.new("Frame")
    hwLogFrame.Name = "HwLogFrame"
    hwLogFrame.Size = UDim2.new(1, -16, 0, 110)
    hwLogFrame.Position = UDim2.new(0, 8, 1, -116)
    hwLogFrame.BackgroundColor3 = Color3.fromRGB(18, 22, 32)
    hwLogFrame.BorderSizePixel = 0
    hwLogFrame.Parent = tabHalloween
    Instance.new("UICorner", hwLogFrame).CornerRadius = UDim.new(0, 6)
    local strokeLog = Instance.new("UIStroke", hwLogFrame)
    strokeLog.Color = Color3.fromRGB(45, 55, 75)
    strokeLog.Thickness = 1

    local hwLogTitle = Instance.new("TextLabel")
    hwLogTitle.Name = "HwLogTitle"
    hwLogTitle.Size = UDim2.new(1, -62, 0, 16)
    hwLogTitle.Position = UDim2.new(0, 8, 0, 2)
    hwLogTitle.BackgroundTransparency = 1
    hwLogTitle.Text = "Activity & Fishing Log"
    hwLogTitle.TextColor3 = Color3.fromRGB(160, 190, 230)
    hwLogTitle.Font = Enum.Font.GothamBold
    hwLogTitle.TextSize = 10
    hwLogTitle.TextXAlignment = Enum.TextXAlignment.Left
    hwLogTitle.Parent = hwLogFrame

    local hwLogCopyBtn = Instance.new("TextButton")
    hwLogCopyBtn.Name = "HwLogCopyBtn"
    hwLogCopyBtn.Size = UDim2.new(0, 50, 0, 14)
    hwLogCopyBtn.Position = UDim2.new(1, -56, 0, 2)
    hwLogCopyBtn.BackgroundColor3 = Color3.fromRGB(45, 75, 110)
    hwLogCopyBtn.Text = "COPY"
    hwLogCopyBtn.TextColor3 = Color3.fromRGB(210, 230, 255)
    hwLogCopyBtn.Font = Enum.Font.GothamBold
    hwLogCopyBtn.TextSize = 9
    hwLogCopyBtn.Parent = hwLogFrame
    Instance.new("UICorner", hwLogCopyBtn).CornerRadius = UDim.new(0, 3)

    hwLogCopyBtn.MouseButton1Click:Connect(function()
        local content = hwLogLabel and hwLogLabel.Text or ""
        local copied = false
        if typeof(setclipboard) == "function" then
            copied = pcall(setclipboard, content)
        end
        if not copied and typeof(toclipboard) == "function" then
            copied = pcall(toclipboard, content)
        end

        hwLogCopyBtn.Text = copied and "COPIED" or "NO CLIP"
        if not copied then
            warn("[HW-Fishing] Clipboard API unavailable; unable to copy the log.")
        end
        task.delay(1.25, function()
            if hwLogCopyBtn and hwLogCopyBtn.Parent then
                hwLogCopyBtn.Text = "COPY"
            end
        end)
    end)

    local hwLogScroll = Instance.new("ScrollingFrame")
    hwLogScroll.Name = "HwLogScroll"
    hwLogScroll.Size = UDim2.new(1, -12, 1, -22)
    hwLogScroll.Position = UDim2.new(0, 6, 0, 18)
    hwLogScroll.BackgroundTransparency = 1
    hwLogScroll.BorderSizePixel = 0
    hwLogScroll.ScrollBarThickness = 3
    hwLogScroll.ScrollBarImageColor3 = Color3.fromRGB(100, 140, 200)
    hwLogScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    hwLogScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    hwLogScroll.Parent = hwLogFrame

    hwLogLabel = Instance.new("TextLabel")
    hwLogLabel.Name = "HwLogLabel"
    hwLogLabel.Size = UDim2.new(1, -4, 0, 0)
    hwLogLabel.Position = UDim2.new(0, 0, 0, 0)
    hwLogLabel.AutomaticSize = Enum.AutomaticSize.Y
    hwLogLabel.BackgroundTransparency = 1
    hwLogLabel.Text = "[Ready] Engine idle. Logs will appear here..."
    hwLogLabel.TextColor3 = Color3.fromRGB(200, 215, 235)
    hwLogLabel.Font = Enum.Font.Code
    hwLogLabel.TextSize = 9
    hwLogLabel.TextXAlignment = Enum.TextXAlignment.Left
    hwLogLabel.TextYAlignment = Enum.TextYAlignment.Top
    hwLogLabel.TextWrapped = true
    hwLogLabel.Parent = hwLogScroll
end

-- Forward declarations
local renderFarmableEggs
local requestListUpdate
local updateActivityStatus
local activityStatusLabel
local velLiveLabel
local copyJsonBtn
local startReturnTrip
local handleEggDropped
local handleEggDelivered
local executePickupSpam
local startAutoPickupSpam

-- Auto-Return & Drop Recovery State
local autoReturnActive = false
local autoReturnTargetUid = nil
local returnTripInProgress = false

-- Fast Pickup Configuration & State
local PICKUP_CONFIG = {
    Enabled        = true,
    SpamBurstCount = 4,
}
local autoPickupToken = 0

-- Instant Recovery Configuration
local RECOVERY_CONFIG = {
    Enabled   = true,
    AntiFling = true,
}

-- Velocity & Speed State (Default: Disabled)
local velocityEnabled = false
local isCarrying = false
local weAreCarrying = false
local carryUid = nil
local baseGoSpeed = 360
local baseCarrySpeed = 310
local savedWalkSpeed = 16.0
pcall(function()
    local ch = LocalPlayer and LocalPlayer.Character
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    if hum and hum.WalkSpeed > 0 and hum.WalkSpeed < 100 then
        savedWalkSpeed = hum.WalkSpeed
    end
end)

-- Filter Selection State (13 Canonical Farmable World Biomes)
local BIOME_ORDER = {
    "Forest", "Lake", "Desert", "Jungle", "Snow", "Volcano", "Abyss Ocean",
    "Prehistoric", "Cosmic", "Cherry Blossom", "Titan Temple", "Light & Dark", "Enchanted Forest"
}

local ALL_SPECIES_LIST = {}
local seenSpecies = {}

local function registerDynamicSpecies(rawName, defaultBiome, defaultRarity)
    if not rawName or type(rawName) ~= "string" or rawName == "" then return false end
    if isGenericEggName(rawName) then return false end
    local clean = normalizeSpecies(rawName)
    if clean == "" then return false end

    local existing = getSpeciesInfo(rawName, defaultBiome) or SPECIES_INFO[clean]
    if existing and existing.IsCataloged then
        local disp = existing.DisplayName or rawName
        local cleanDisp = normalizeSpecies(disp)
        if not seenSpecies[cleanDisp] then
            seenSpecies[cleanDisp] = true
            table.insert(ALL_SPECIES_LIST, {
                Name      = disp,
                Biome     = existing.Biome or defaultBiome or "Ungrouped",
                Rarity    = existing.Rarity,
                Rank      = existing.Rank or (RARITY_RANK[existing.Rarity] or 1),
                SearchKey = (disp .. " " .. (existing.Biome or "") .. " " .. existing.Rarity):lower(),
            })
            return true
        end
        return false
    end

    local disp = (existing and existing.DisplayName) or rawName
    local biome = (existing and existing.Biome) or defaultBiome
    if not biome or biome == "" or biome == "Unknown" then
        if clean:find("halloween") or clean:find("pumpkin") or clean:find("witch") or clean:find("ghost") then
            biome = "Halloween"
        else
            biome = "Ungrouped"
        end
    end
    local isCataloged = (existing and existing.IsCataloged == true)
    local rarity = (isCataloged and existing.Rarity) or defaultRarity or (biome == "Halloween" and "New Update" or "Unknown")
    local rank = (isCataloged and existing.Rank) or (RARITY_RANK[rarity] or (rarity == "New Update" and 99 or 1))

    local record = existing or {
        DisplayName = disp,
        Rarity      = rarity,
        Rank        = rank,
        Biome       = biome,
        IsCataloged = false,
    }
    if not SPECIES_INFO[clean] then
        SPECIES_INFO[clean] = record
        if not SPECIES_INFO_BY_BIOME[biome] then
            SPECIES_INFO_BY_BIOME[biome] = {}
        end
        SPECIES_INFO_BY_BIOME[biome][clean] = record
    end

    local cleanDisp = normalizeSpecies(disp)
    if not seenSpecies[cleanDisp] then
        seenSpecies[cleanDisp] = true
        table.insert(ALL_SPECIES_LIST, {
            Name      = disp,
            Biome     = biome,
            Rarity    = rarity,
            Rank      = rank,
            SearchKey = (disp .. " " .. biome .. " " .. rarity):lower(),
        })
        return true
    end
    return false
end

-- Pre-populate catalog species (Exact canonical species, aliases preserved for lookup)
do
    for _, biomeData in ipairs(BIOME_EGG_CATALOG) do
        for _, spec in ipairs(biomeData.Species) do
            local cleanDisp = normalizeSpecies(spec.Name)
            if not seenSpecies[cleanDisp] then
                seenSpecies[cleanDisp] = true
                table.insert(ALL_SPECIES_LIST, {
                    Name      = spec.Name,
                    Biome     = biomeData.Biome,
                    Rarity    = spec.Rarity,
                    Rank      = RARITY_RANK[spec.Rarity] or 0,
                    SearchKey = (spec.Name .. " " .. biomeData.Biome .. " " .. spec.Rarity):lower(),
                })
            end
        end
    end
end

-- Dynamic Game Discovery for Egg Species (ReplicatedStorage.Assets.Models.Eggs)
do
    local eggsFolder = nil
    pcall(function()
        eggsFolder = ReplicatedStorage:FindFirstChild("Assets")
            and ReplicatedStorage.Assets:FindFirstChild("Models")
            and ReplicatedStorage.Assets.Models:FindFirstChild("Eggs")
    end)
    if eggsFolder then
        local added = false
        for _, child in ipairs(eggsFolder:GetChildren()) do
            if registerDynamicSpecies(child.Name) then
                added = true
            end
        end
        if added then
            table.sort(ALL_SPECIES_LIST, function(a, b)
                return a.Name:lower() < b.Name:lower()
            end)
        end
    end
end
table.sort(ALL_SPECIES_LIST, function(a, b)
    return a.Name:lower() < b.Name:lower()
end)

local selectedRarities = { ["All"] = true }
local selectedBiomes   = { ["All"] = true }
local selectedEggs     = { ["All"] = true }

local function isRarityAllowed(r)
    if selectedRarities["All"] then return true end
    if next(selectedRarities) == nil then return false end
    return selectedRarities[r] == true
end

local function isBiomeAllowed(b)
    if selectedBiomes["All"] then return true end
    if next(selectedBiomes) == nil then return false end
    if selectedBiomes[b] == true then return true end
    if b == "Light & Dark" and (selectedBiomes["Angel Eggs"] or selectedBiomes["Demon Eggs"]) then return true end
    if (b == "Angel Eggs" or b == "Demon Eggs") and selectedBiomes["Light & Dark"] then return true end
    if b == "Halloween Dimension" and selectedBiomes["Halloween"] then return true end
    if b == "Halloween" and selectedBiomes["Halloween Dimension"] then return true end
    return false
end

local function isEggAllowed(disp, raw, info)
    if selectedEggs["All"] then return true end
    if next(selectedEggs) == nil then return false end
    if selectedEggs[disp] then return true end
    if raw and selectedEggs[raw] then return true end
    local specInfo = info or getSpeciesInfo(disp) or (raw and getSpeciesInfo(raw))
    if specInfo and selectedEggs[specInfo.DisplayName] then return true end
    return false
end

-- 1. Activity / Carrying Status Readout (Above Velocity Engine)
activityStatusLabel = Instance.new("TextLabel")
activityStatusLabel.Name = "ActivityStatusLabel"
activityStatusLabel.Size = UDim2.new(1, -16, 0, 16)
activityStatusLabel.Position = UDim2.new(0, 8, 0, 4)
activityStatusLabel.BackgroundTransparency = 1
activityStatusLabel.Text = "Status: Velocity Disabled (Normal WalkSpeed)"
activityStatusLabel.TextColor3 = Color3.fromRGB(160, 170, 190)
activityStatusLabel.TextSize = 11
activityStatusLabel.Font = Enum.Font.GothamBold
activityStatusLabel.TextXAlignment = Enum.TextXAlignment.Left
activityStatusLabel.Parent = tabEggs

-- 2. Velocity Engine Control Bar (Default: Disabled)
local velToggleBtn, goBox, carryBox

do
    local velocityFrame = Instance.new("Frame")
    velocityFrame.Name = "VelocityFrame"
    velocityFrame.Size = UDim2.new(1, -16, 0, 26)
    velocityFrame.Position = UDim2.new(0, 8, 0, 22)
    velocityFrame.BackgroundTransparency = 1
    velocityFrame.BorderSizePixel = 0
    velocityFrame.Parent = tabEggs

    velToggleBtn = Instance.new("TextButton")
    velToggleBtn.Name = "VelToggleBtn"
    velToggleBtn.Size = UDim2.new(0, 104, 1, 0)
    velToggleBtn.Position = UDim2.new(0, 0, 0, 0)
    velToggleBtn.BackgroundColor3 = Color3.fromRGB(42, 48, 65)
    velToggleBtn.Text = "[OFF] Velocity"
    velToggleBtn.TextColor3 = Color3.fromRGB(210, 220, 240)
    velToggleBtn.TextSize = 11
    velToggleBtn.Font = Enum.Font.GothamBold
    velToggleBtn.Parent = velocityFrame
    Instance.new("UICorner", velToggleBtn).CornerRadius = UDim.new(0, 4)

    local goFrame = Instance.new("Frame")
    goFrame.Name = "GoSpeedFrame"
    goFrame.Size = UDim2.new(0, 70, 1, 0)
    goFrame.Position = UDim2.new(0, 108, 0, 0)
    goFrame.BackgroundColor3 = Color3.fromRGB(28, 34, 48)
    goFrame.BorderSizePixel = 0
    goFrame.Parent = velocityFrame
    Instance.new("UICorner", goFrame).CornerRadius = UDim.new(0, 4)
    local goStroke = Instance.new("UIStroke", goFrame)
    goStroke.Color = Color3.fromRGB(50, 68, 98); goStroke.Thickness = 1

    local goLabel = Instance.new("TextLabel")
    goLabel.Size = UDim2.new(0, 20, 1, 0)
    goLabel.Position = UDim2.new(0, 4, 0, 0)
    goLabel.BackgroundTransparency = 1
    goLabel.Text = "Go:"
    goLabel.TextColor3 = Color3.fromRGB(160, 185, 220)
    goLabel.TextSize = 10.5
    goLabel.Font = Enum.Font.GothamBold
    goLabel.TextXAlignment = Enum.TextXAlignment.Left
    goLabel.Parent = goFrame

    goBox = Instance.new("TextBox")
    goBox.Name = "GoSpeedBox"
    goBox.Size = UDim2.new(1, -26, 1, 0)
    goBox.Position = UDim2.new(0, 24, 0, 0)
    goBox.BackgroundTransparency = 1
    goBox.Text = tostring(baseGoSpeed)
    goBox.PlaceholderText = "360"
    goBox.TextColor3 = Color3.new(1, 1, 1)
    goBox.TextSize = 11
    goBox.Font = Enum.Font.GothamBold
    goBox.ClearTextOnFocus = false
    goBox.TextXAlignment = Enum.TextXAlignment.Center
    goBox.Parent = goFrame

    local carryFrame = Instance.new("Frame")
    carryFrame.Name = "CarrySpeedFrame"
    carryFrame.Size = UDim2.new(0, 80, 1, 0)
    carryFrame.Position = UDim2.new(0, 182, 0, 0)
    carryFrame.BackgroundColor3 = Color3.fromRGB(28, 34, 48)
    carryFrame.BorderSizePixel = 0
    carryFrame.Parent = velocityFrame
    Instance.new("UICorner", carryFrame).CornerRadius = UDim.new(0, 4)
    local carryStroke = Instance.new("UIStroke", carryFrame)
    carryStroke.Color = Color3.fromRGB(50, 68, 98); carryStroke.Thickness = 1

    local carryLabel = Instance.new("TextLabel")
    carryLabel.Size = UDim2.new(0, 32, 1, 0)
    carryLabel.Position = UDim2.new(0, 4, 0, 0)
    carryLabel.BackgroundTransparency = 1
    carryLabel.Text = "Carry:"
    carryLabel.TextColor3 = Color3.fromRGB(160, 185, 220)
    carryLabel.TextSize = 10.5
    carryLabel.Font = Enum.Font.GothamBold
    carryLabel.TextXAlignment = Enum.TextXAlignment.Left
    carryLabel.Parent = carryFrame

    carryBox = Instance.new("TextBox")
    carryBox.Name = "CarrySpeedBox"
    carryBox.Size = UDim2.new(1, -38, 1, 0)
    carryBox.Position = UDim2.new(0, 36, 0, 0)
    carryBox.BackgroundTransparency = 1
    carryBox.Text = tostring(baseCarrySpeed)
    carryBox.PlaceholderText = "310"
    carryBox.TextColor3 = Color3.new(1, 1, 1)
    carryBox.TextSize = 11
    carryBox.Font = Enum.Font.GothamBold
    carryBox.ClearTextOnFocus = false
    carryBox.TextXAlignment = Enum.TextXAlignment.Center
    carryBox.Parent = carryFrame

    velLiveLabel = Instance.new("TextLabel")
    velLiveLabel.Name = "VelLiveLabel"
    velLiveLabel.Size = UDim2.new(1, -266, 1, 0)
    velLiveLabel.Position = UDim2.new(0, 266, 0, 0)
    velLiveLabel.BackgroundColor3 = Color3.fromRGB(24, 29, 40)
    velLiveLabel.BorderSizePixel = 0
    velLiveLabel.Text = "Vel: OFF"
    velLiveLabel.TextColor3 = Color3.fromRGB(130, 140, 160)
    velLiveLabel.TextSize = 10
    velLiveLabel.Font = Enum.Font.GothamBold
    velLiveLabel.TextXAlignment = Enum.TextXAlignment.Center
    velLiveLabel.Parent = velocityFrame
    Instance.new("UICorner", velLiveLabel).CornerRadius = UDim.new(0, 4)

    -- 2b. Instant Recovery Control Bar (Row below Velocity Engine)
    local recoveryFrame = Instance.new("Frame")
    recoveryFrame.Name = "RecoveryFrame"
    recoveryFrame.Size = UDim2.new(1, -16, 0, 26)
    recoveryFrame.Position = UDim2.new(0, 8, 0, 52)
    recoveryFrame.BackgroundColor3 = Color3.fromRGB(24, 28, 40)
    recoveryFrame.BorderSizePixel = 0
    recoveryFrame.Parent = tabEggs
    Instance.new("UICorner", recoveryFrame).CornerRadius = UDim.new(0, 4)
    local strokeRecovery = Instance.new("UIStroke", recoveryFrame)
    strokeRecovery.Color = Color3.fromRGB(45, 55, 75)
    strokeRecovery.Thickness = 1

    local lblRecoveryTitle = Instance.new("TextLabel")
    lblRecoveryTitle.Name = "RecoveryTitle"
    lblRecoveryTitle.Size = UDim2.new(1, -74, 1, 0)
    lblRecoveryTitle.Position = UDim2.new(0, 10, 0, 0)
    lblRecoveryTitle.BackgroundTransparency = 1
    lblRecoveryTitle.Text = "Instant Recovery"
    lblRecoveryTitle.TextColor3 = Color3.fromRGB(225, 235, 255)
    lblRecoveryTitle.Font = Enum.Font.GothamBold
    lblRecoveryTitle.TextSize = 11.5
    lblRecoveryTitle.TextXAlignment = Enum.TextXAlignment.Left
    lblRecoveryTitle.Parent = recoveryFrame

    local toggleRecoveryBtn = Instance.new("TextButton")
    toggleRecoveryBtn.Name = "ToggleRecoveryBtn"
    toggleRecoveryBtn.Size = UDim2.new(0, 56, 0, 20)
    toggleRecoveryBtn.Position = UDim2.new(1, -62, 0.5, -10)
    toggleRecoveryBtn.BackgroundColor3 = RECOVERY_CONFIG.Enabled and Color3.fromRGB(35, 135, 75) or Color3.fromRGB(45, 50, 65)
    toggleRecoveryBtn.Text = RECOVERY_CONFIG.Enabled and "ON" or "OFF"
    toggleRecoveryBtn.TextColor3 = RECOVERY_CONFIG.Enabled and Color3.new(1, 1, 1) or Color3.fromRGB(180, 190, 210)
    toggleRecoveryBtn.Font = Enum.Font.GothamBold
    toggleRecoveryBtn.TextSize = 11
    toggleRecoveryBtn.Parent = recoveryFrame
    Instance.new("UICorner", toggleRecoveryBtn).CornerRadius = UDim.new(0, 4)

    addConnection(toggleRecoveryBtn.MouseButton1Click:Connect(function()
        RECOVERY_CONFIG.Enabled = not RECOVERY_CONFIG.Enabled
        toggleRecoveryBtn.Text = RECOVERY_CONFIG.Enabled and "ON" or "OFF"
        toggleRecoveryBtn.BackgroundColor3 = RECOVERY_CONFIG.Enabled and Color3.fromRGB(35, 135, 75) or Color3.fromRGB(45, 50, 65)
        toggleRecoveryBtn.TextColor3 = RECOVERY_CONFIG.Enabled and Color3.new(1, 1, 1) or Color3.fromRGB(180, 190, 210)
    end))
end

-- 3. World Egg Catalog List View
local filterFrame = Instance.new("Frame")
local rarityBtn = Instance.new("TextButton")
local biomeBtn = Instance.new("TextButton")
local eggBtn = Instance.new("TextButton")

do
    -- 4. Dropdown Filter Bar (Shifted up to row 82)
    filterFrame.Name = "FilterFrame"
    filterFrame.Size = UDim2.new(1, -16, 0, 58)
    filterFrame.Position = UDim2.new(0, 8, 0, 82)
    filterFrame.BackgroundTransparency = 1
    filterFrame.BorderSizePixel = 0
    filterFrame.ClipsDescendants = false
    filterFrame.ZIndex = 30
    filterFrame.Parent = tabEggs

    -- 1. Rarity Filter Button
    rarityBtn.Name = "RarityFilterBtn"
    rarityBtn.Size = UDim2.new(0.5, -3, 0, 26)
    rarityBtn.Position = UDim2.new(0, 0, 0, 0)
    rarityBtn.BackgroundColor3 = Color3.fromRGB(36, 44, 62)
    rarityBtn.Text = "Rarity: All ▼"
    rarityBtn.TextColor3 = Color3.fromRGB(220, 230, 255)
    rarityBtn.TextSize = 11
    rarityBtn.Font = Enum.Font.GothamBold
    rarityBtn.ZIndex = 31
    rarityBtn.Parent = filterFrame
    Instance.new("UICorner", rarityBtn).CornerRadius = UDim.new(0, 6)

    -- 2. Biome Filter Button
    biomeBtn.Name = "BiomeFilterBtn"
    biomeBtn.Size = UDim2.new(0.5, -3, 0, 26)
    biomeBtn.Position = UDim2.new(0.5, 3, 0, 0)
    biomeBtn.BackgroundColor3 = Color3.fromRGB(36, 44, 62)
    biomeBtn.Text = "Biome: All ▼"
    biomeBtn.TextColor3 = Color3.fromRGB(220, 230, 255)
    biomeBtn.TextSize = 11
    biomeBtn.Font = Enum.Font.GothamBold
    biomeBtn.ZIndex = 31
    biomeBtn.Parent = filterFrame
    Instance.new("UICorner", biomeBtn).CornerRadius = UDim.new(0, 6)

    -- Row 2: Farm Label & Egg Filter Button
    local farmLabel = Instance.new("TextLabel")
    farmLabel.Name = "FarmLabel"
    farmLabel.Size = UDim2.new(0, 42, 0, 26)
    farmLabel.Position = UDim2.new(0, 2, 0, 30)
    farmLabel.BackgroundTransparency = 1
    farmLabel.Text = "Farm:"
    farmLabel.TextColor3 = Color3.fromRGB(180, 195, 220)
    farmLabel.TextSize = 11.5
    farmLabel.Font = Enum.Font.GothamBold
    farmLabel.TextXAlignment = Enum.TextXAlignment.Left
    farmLabel.ZIndex = 31
    farmLabel.Parent = filterFrame

    eggBtn.Name = "EggFilterBtn"
    eggBtn.Size = UDim2.new(1, -46, 0, 26)
    eggBtn.Position = UDim2.new(0, 46, 0, 30)
    eggBtn.BackgroundColor3 = Color3.fromRGB(36, 44, 62)
    eggBtn.Text = "All ▼"
    eggBtn.TextColor3 = Color3.fromRGB(220, 230, 255)
    eggBtn.TextSize = 11.5
    eggBtn.Font = Enum.Font.GothamBold
    eggBtn.TextTruncate = Enum.TextTruncate.AtEnd
    eggBtn.ZIndex = 31
    eggBtn.Parent = filterFrame
    Instance.new("UICorner", eggBtn).CornerRadius = UDim.new(0, 6)
end

-- Dropdown Lists Container
local rarityDd = createFilterDropdown({
    parent = filterFrame,
    btn = rarityBtn,
    title = "Rarity",
    items = RARITY_ORDER,
    getSelected = function() return selectedRarities end,
    setSelected = function(v) selectedRarities = v end,
    onChanged = function() if renderFarmableEggs then renderFarmableEggs() end end,
    size = UDim2.new(0.5, -3, 0, 256),
    pos = UDim2.new(0, 0, 0, 28),
    colorMap = RARITY_COLORS,
})
local rarityList = rarityDd.list

local biomeDd = createFilterDropdown({
    parent = filterFrame,
    btn = biomeBtn,
    title = "Biome",
    items = BIOME_ORDER,
    getSelected = function() return selectedBiomes end,
    setSelected = function(v) selectedBiomes = v end,
    onChanged = function() if renderFarmableEggs then renderFarmableEggs() end end,
    size = UDim2.new(0.5, -3, 0, 240),
    pos = UDim2.new(0.5, 3, 0, 28),
    scrollable = true,
})
local biomeList = biomeDd.list

-- Egg Dropdown List
local eggDropList = Instance.new("Frame")
eggDropList.Name = "EggDropList"
eggDropList.Size = UDim2.new(1, 0, 0, 260)
eggDropList.Position = UDim2.new(0, 0, 0, 58)
eggDropList.BackgroundColor3 = Color3.fromRGB(24, 29, 42)
eggDropList.BorderSizePixel = 0
eggDropList.ZIndex = 50
eggDropList.ClipsDescendants = true
eggDropList.Visible = false
eggDropList.Parent = filterFrame
Instance.new("UICorner", eggDropList).CornerRadius = UDim.new(0, 6)
do
    local s = Instance.new("UIStroke", eggDropList)
    s.Color = Color3.fromRGB(60, 85, 130); s.Thickness = 1
end

local eggQuickRow = Instance.new("Frame")
eggQuickRow.Size = UDim2.new(1, -6, 0, 22)
eggQuickRow.Position = UDim2.new(0, 3, 0, 3)
eggQuickRow.BackgroundTransparency = 1
eggQuickRow.ZIndex = 51
eggQuickRow.Parent = eggDropList

local eggAllBtn = Instance.new("TextButton")
eggAllBtn.Size = UDim2.new(0.5, -2, 1, 0)
eggAllBtn.Position = UDim2.new(0, 0, 0, 0)
eggAllBtn.BackgroundColor3 = Color3.fromRGB(45, 95, 150)
eggAllBtn.Text = "All"
eggAllBtn.TextColor3 = Color3.new(1, 1, 1)
eggAllBtn.TextSize = 11; eggAllBtn.Font = Enum.Font.GothamBold
eggAllBtn.ZIndex = 52; eggAllBtn.Parent = eggQuickRow
Instance.new("UICorner", eggAllBtn).CornerRadius = UDim.new(0, 4)

local eggNoneBtn = Instance.new("TextButton")
eggNoneBtn.Size = UDim2.new(0.5, -2, 1, 0)
eggNoneBtn.Position = UDim2.new(0.5, 2, 0, 0)
eggNoneBtn.BackgroundColor3 = Color3.fromRGB(110, 45, 45)
eggNoneBtn.Text = "None"
eggNoneBtn.TextColor3 = Color3.new(1, 1, 1)
eggNoneBtn.TextSize = 11; eggNoneBtn.Font = Enum.Font.GothamBold
eggNoneBtn.ZIndex = 52; eggNoneBtn.Parent = eggQuickRow
Instance.new("UICorner", eggNoneBtn).CornerRadius = UDim.new(0, 4)

local eggSearchBox = Instance.new("TextBox")
eggSearchBox.Size = UDim2.new(1, -6, 0, 22)
eggSearchBox.Position = UDim2.new(0, 3, 0, 28)
eggSearchBox.BackgroundColor3 = Color3.fromRGB(16, 20, 30)
eggSearchBox.PlaceholderText = "Search egg name or biome..."
eggSearchBox.PlaceholderColor3 = Color3.fromRGB(110, 125, 150)
eggSearchBox.Text = ""
eggSearchBox.TextColor3 = Color3.fromRGB(220, 230, 255)
eggSearchBox.TextSize = 11; eggSearchBox.Font = Enum.Font.Gotham
eggSearchBox.ClearTextOnFocus = false
eggSearchBox.TextXAlignment = Enum.TextXAlignment.Left
eggSearchBox.ZIndex = 52
eggSearchBox.Parent = eggDropList
Instance.new("UICorner", eggSearchBox).CornerRadius = UDim.new(0, 4)
do
    local p = Instance.new("UIPadding")
    p.PaddingLeft = UDim.new(0, 6)
    p.Parent = eggSearchBox
end

local eggDropScroll = Instance.new("ScrollingFrame")
eggDropScroll.Size = UDim2.new(1, -6, 1, -54)
eggDropScroll.Position = UDim2.new(0, 3, 0, 52)
eggDropScroll.BackgroundTransparency = 1
eggDropScroll.ScrollBarThickness = 4
eggDropScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
eggDropScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
eggDropScroll.ZIndex = 51
eggDropScroll.Parent = eggDropList

do
    local l = Instance.new("UIListLayout")
    l.Padding = UDim.new(0, 2)
    l.SortOrder = Enum.SortOrder.LayoutOrder
    l.Parent = eggDropScroll
end

local eggPool = {}
local rebuildEggDropdownItems
local updateEggBtnText

updateEggBtnText = function(isOpen)
    local arrow = isOpen and "▲" or "▼"
    if selectedEggs["All"] then
        eggBtn.Text = "All " .. arrow
        return
    end
    local list = {}
    for _, spec in ipairs(ALL_SPECIES_LIST) do
        if selectedEggs[spec.Name] then table.insert(list, spec.Name) end
    end
    if #list == 0 then
        eggBtn.Text = "None " .. arrow
    elseif #list == 1 then
        eggBtn.Text = list[1] .. " " .. arrow
    else
        local joined = table.concat(list, ", ")
        if #joined <= 24 then
            eggBtn.Text = joined .. " " .. arrow
        else
            eggBtn.Text = string.format("%s +%d %s", list[1], #list - 1, arrow)
        end
    end
end

rebuildEggDropdownItems = function()
    local q = eggSearchBox.Text:lower():gsub("^%s+", ""):gsub("%s+$", "")
    local matchedList = {}
    for _, spec in ipairs(ALL_SPECIES_LIST) do
        if q == "" or (spec.SearchKey and spec.SearchKey:find(q, 1, true)) or (spec.Name and spec.Name:lower():find(q, 1, true)) then
            table.insert(matchedList, spec)
        end
    end

    for idx, spec in ipairs(matchedList) do
        local item = eggPool[idx]
        if not item then
            local btn = Instance.new("TextButton")
            btn.Name = "EggBtn_" .. tostring(idx)
            btn.Size = UDim2.new(1, -4, 0, 22)
            btn.BorderSizePixel = 0
            btn.AutoButtonColor = false
            btn.TextXAlignment = Enum.TextXAlignment.Left
            btn.TextSize = 11
            btn.Font = Enum.Font.Gotham
            btn.ZIndex = 52
            btn.Parent = eggDropScroll
            Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 4)
            local pad = Instance.new("UIPadding")
            pad.PaddingLeft = UDim.new(0, 6)
            pad.PaddingRight = UDim.new(0, 6)
            pad.Parent = btn

            local sub = Instance.new("TextLabel")
            sub.Name = "SubInfo"
            sub.Size = UDim2.new(0, 120, 1, 0)
            sub.Position = UDim2.new(1, -124, 0, 0)
            sub.BackgroundTransparency = 1
            sub.TextXAlignment = Enum.TextXAlignment.Right
            sub.TextSize = 9.5
            sub.Font = Enum.Font.Gotham
            sub.ZIndex = 53
            sub.Parent = btn

            item = {
                btn  = btn,
                sub  = sub,
                spec = nil,
            }

            btn.MouseButton1Click:Connect(function()
                local s = item.spec
                if not s then return end
                if selectedEggs["All"] then
                    selectedEggs = {}
                end
                if selectedEggs[s.Name] then
                    selectedEggs[s.Name] = nil
                else
                    selectedEggs[s.Name] = true
                end
                local totalChecked = 0
                for _ in pairs(selectedEggs) do
                    totalChecked = totalChecked + 1
                end
                if totalChecked >= #ALL_SPECIES_LIST then
                    selectedEggs = { ["All"] = true }
                end
                updateEggBtnText(true)
                rebuildEggDropdownItems()
                if renderFarmableEggs then renderFarmableEggs() end
            end)

            eggPool[idx] = item
        end

        item.spec = spec
        local isChecked = selectedEggs["All"] == true or selectedEggs[spec.Name] == true
        item.btn.BackgroundColor3 = isChecked and Color3.fromRGB(48, 75, 115) or Color3.fromRGB(30, 36, 50)
        item.btn.Text = (isChecked and "[X] " or "[ ] ") .. spec.Name
        local rarCol = (spec.Rarity and RARITY_COLORS[spec.Rarity]) or Color3.fromRGB(220, 230, 255)
        item.btn.TextColor3 = isChecked and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(200, 210, 225)
        item.btn.LayoutOrder = idx

        local bName = spec.Biome or "Unknown"
        local rName = spec.Rarity or "Unknown"
        item.sub.Text = bName .. " • " .. rName
        item.sub.TextColor3 = rarCol

        item.btn.Visible = true
    end

    for idx = #matchedList + 1, #eggPool do
        eggPool[idx].btn.Visible = false
    end
end

eggSearchBox:GetPropertyChangedSignal("Text"):Connect(rebuildEggDropdownItems)

eggAllBtn.MouseButton1Click:Connect(function()
    selectedEggs = { ["All"] = true }
    updateEggBtnText(true)
    rebuildEggDropdownItems()
    if renderFarmableEggs then renderFarmableEggs() end
end)

eggNoneBtn.MouseButton1Click:Connect(function()
    selectedEggs = {}
    updateEggBtnText(true)
    rebuildEggDropdownItems()
    if renderFarmableEggs then renderFarmableEggs() end
end)

-- Dropdown Wiring for Egg species
do
    local eggDd = {
        btn = eggBtn,
        list = eggDropList,
        onOpen = function() rebuildEggDropdownItems() end,
        updateBtnText = updateEggBtnText,
    }
    eggBtn.MouseButton1Click:Connect(function() toggleDropdown(eggDd) end)
end

-- Scrolling Egg List (Shifted up to 144)
local eggListScroll = Instance.new("ScrollingFrame")
eggListScroll.Name = "EggListScroll"
eggListScroll.Size = UDim2.new(1, -16, 1, -150)
eggListScroll.Position = UDim2.new(0, 8, 0, 144)
eggListScroll.BackgroundTransparency = 1
eggListScroll.BorderSizePixel = 0
eggListScroll.ScrollBarThickness = 4
eggListScroll.ScrollBarImageColor3 = Color3.fromRGB(70, 110, 180)
eggListScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
eggListScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
eggListScroll.ZIndex = 1
eggListScroll.Parent = tabEggs

do
    local l = Instance.new("UIListLayout")
    l.Padding = UDim.new(0, 3)
    l.SortOrder = Enum.SortOrder.LayoutOrder
    l.Parent = eggListScroll

    local p = Instance.new("UIPadding")
    p.PaddingTop = UDim.new(0, 2)
    p.PaddingBottom = UDim.new(0, 12)
    p.PaddingLeft = UDim.new(0, 2)
    p.PaddingRight = UDim.new(0, 6)
    p.Parent = eggListScroll
end

-- ============================================================================
-- ============================================================================
-- TAB 2: UTILITY PANEL UI (Only Fast Pickup [E])
-- ============================================================================

do
    local rowPickup = Instance.new("Frame")
    rowPickup.Name = "RowPickup"
    rowPickup.Size = UDim2.new(1, -16, 0, 36)
    rowPickup.Position = UDim2.new(0, 8, 0, 10)
    rowPickup.BackgroundColor3 = Color3.fromRGB(24, 28, 40)
    rowPickup.BorderSizePixel = 0
    rowPickup.Parent = tabUtility
    Instance.new("UICorner", rowPickup).CornerRadius = UDim.new(0, 6)
    local strokePickup = Instance.new("UIStroke", rowPickup)
    strokePickup.Color = Color3.fromRGB(45, 55, 75)
    strokePickup.Thickness = 1

    local lblPickupTitle = Instance.new("TextLabel")
    lblPickupTitle.Size = UDim2.new(1, -80, 1, 0)
    lblPickupTitle.Position = UDim2.new(0, 12, 0, 0)
    lblPickupTitle.BackgroundTransparency = 1
    lblPickupTitle.Text = "Fast Pickup [E]"
    lblPickupTitle.TextColor3 = Color3.fromRGB(225, 235, 255)
    lblPickupTitle.Font = Enum.Font.GothamBold
    lblPickupTitle.TextSize = 12
    lblPickupTitle.TextXAlignment = Enum.TextXAlignment.Left
    lblPickupTitle.Parent = rowPickup

    togglePickupBtn = Instance.new("TextButton")
    togglePickupBtn.Name = "TogglePickupBtn"
    togglePickupBtn.Size = UDim2.new(0, 56, 0, 24)
    togglePickupBtn.Position = UDim2.new(1, -66, 0.5, -12)
    togglePickupBtn.BackgroundColor3 = Color3.fromRGB(35, 135, 75)
    togglePickupBtn.Text = "ON"
    togglePickupBtn.TextColor3 = Color3.new(1, 1, 1)
    togglePickupBtn.Font = Enum.Font.GothamBold
    togglePickupBtn.TextSize = 11
    togglePickupBtn.Parent = rowPickup
    Instance.new("UICorner", togglePickupBtn).CornerRadius = UDim.new(0, 5)

    setUtilityAutoPick = function(enabled, syncOther)
        if PICKUP_CONFIG then
            PICKUP_CONFIG.Enabled = enabled
        end
        if togglePickupBtn then
            togglePickupBtn.Text = enabled and "ON" or "OFF"
            togglePickupBtn.BackgroundColor3 = enabled and Color3.fromRGB(35, 135, 75) or Color3.fromRGB(45, 50, 65)
            togglePickupBtn.TextColor3 = enabled and Color3.new(1, 1, 1) or Color3.fromRGB(180, 190, 210)
        end
        if not enabled then
            autoPickupToken = (autoPickupToken or 0) + 1
        end

        -- Reciprocal synchronization: if utility turns ON, Halloween turns OFF; if utility turns OFF, Halloween turns ON
        if syncOther ~= false and setHwAutoPick then
            setHwAutoPick(not enabled, false)
        end
    end

    addConnection(togglePickupBtn.MouseButton1Click:Connect(function()
        setUtilityAutoPick(not (PICKUP_CONFIG and PICKUP_CONFIG.Enabled))
    end))

    local rowCopyJson = Instance.new("Frame")
    rowCopyJson.Name = "RowCopyJson"
    rowCopyJson.Size = UDim2.new(1, -16, 0, 36)
    rowCopyJson.Position = UDim2.new(0, 8, 0, 52)
    rowCopyJson.BackgroundColor3 = Color3.fromRGB(24, 28, 40)
    rowCopyJson.BorderSizePixel = 0
    rowCopyJson.Parent = tabUtility
    Instance.new("UICorner", rowCopyJson).CornerRadius = UDim.new(0, 6)
    local strokeCopyJson = Instance.new("UIStroke", rowCopyJson)
    strokeCopyJson.Color = Color3.fromRGB(45, 55, 75)
    strokeCopyJson.Thickness = 1

    local lblCopyTitle = Instance.new("TextLabel")
    lblCopyTitle.Size = UDim2.new(1, -100, 1, 0)
    lblCopyTitle.Position = UDim2.new(0, 12, 0, 0)
    lblCopyTitle.BackgroundTransparency = 1
    lblCopyTitle.Text = "Export Egg Data"
    lblCopyTitle.TextColor3 = Color3.fromRGB(225, 235, 255)
    lblCopyTitle.Font = Enum.Font.GothamBold
    lblCopyTitle.TextSize = 12
    lblCopyTitle.TextXAlignment = Enum.TextXAlignment.Left
    lblCopyTitle.Parent = rowCopyJson

    copyJsonBtn = Instance.new("TextButton")
    copyJsonBtn.Name = "CopyJsonBtn"
    copyJsonBtn.Size = UDim2.new(0, 80, 0, 24)
    copyJsonBtn.Position = UDim2.new(1, -90, 0.5, -12)
    copyJsonBtn.BackgroundColor3 = Color3.fromRGB(45, 65, 100)
    copyJsonBtn.Text = "Copy JSON"
    copyJsonBtn.TextColor3 = Color3.fromRGB(210, 230, 255)
    copyJsonBtn.TextSize = 11
    copyJsonBtn.Font = Enum.Font.GothamBold
    copyJsonBtn.Parent = rowCopyJson
    Instance.new("UICorner", copyJsonBtn).CornerRadius = UDim.new(0, 5)

    -- Row 3: NoClip Toggle
    local rowNoclip = Instance.new("Frame")
    rowNoclip.Name = "RowNoclip"
    rowNoclip.Size = UDim2.new(1, -16, 0, 36)
    rowNoclip.Position = UDim2.new(0, 8, 0, 94)
    rowNoclip.BackgroundColor3 = Color3.fromRGB(24, 28, 40)
    rowNoclip.BorderSizePixel = 0
    rowNoclip.Parent = tabUtility
    Instance.new("UICorner", rowNoclip).CornerRadius = UDim.new(0, 6)
    local strokeNoclip = Instance.new("UIStroke", rowNoclip)
    strokeNoclip.Color = Color3.fromRGB(45, 55, 75)
    strokeNoclip.Thickness = 1

    local lblNoclipTitle = Instance.new("TextLabel")
    lblNoclipTitle.Size = UDim2.new(1, -80, 1, 0)
    lblNoclipTitle.Position = UDim2.new(0, 12, 0, 0)
    lblNoclipTitle.BackgroundTransparency = 1
    lblNoclipTitle.Text = "NoClip"
    lblNoclipTitle.TextColor3 = Color3.fromRGB(225, 235, 255)
    lblNoclipTitle.Font = Enum.Font.GothamBold
    lblNoclipTitle.TextSize = 12
    lblNoclipTitle.TextXAlignment = Enum.TextXAlignment.Left
    lblNoclipTitle.Parent = rowNoclip

    local toggleNoclipBtn = Instance.new("TextButton")
    toggleNoclipBtn.Name = "ToggleNoclipBtn"
    toggleNoclipBtn.Size = UDim2.new(0, 56, 0, 24)
    toggleNoclipBtn.Position = UDim2.new(1, -66, 0.5, -12)
    toggleNoclipBtn.BackgroundColor3 = Color3.fromRGB(45, 50, 65)
    toggleNoclipBtn.Text = "OFF"
    toggleNoclipBtn.TextColor3 = Color3.fromRGB(180, 190, 210)
    toggleNoclipBtn.Font = Enum.Font.GothamBold
    toggleNoclipBtn.TextSize = 11
    toggleNoclipBtn.Parent = rowNoclip
    Instance.new("UICorner", toggleNoclipBtn).CornerRadius = UDim.new(0, 5)

    local noclipActive = false
    local noclipParts = {}

    local function refreshNoclipParts()
        table.clear(noclipParts)
        local ch = LocalPlayer and LocalPlayer.Character
        if not ch then return end
        for _, desc in ipairs(ch:GetDescendants()) do
            if desc:IsA("BasePart") and not desc:FindFirstAncestorWhichIsA("Tool") then
                table.insert(noclipParts, desc)
            end
        end
    end

    local function setNoclip(enabled)
        noclipActive = enabled
        toggleNoclipBtn.Text = noclipActive and "ON" or "OFF"
        toggleNoclipBtn.BackgroundColor3 = noclipActive and Color3.fromRGB(35, 135, 75) or Color3.fromRGB(45, 50, 65)
        toggleNoclipBtn.TextColor3 = noclipActive and Color3.new(1, 1, 1) or Color3.fromRGB(180, 190, 210)
        if noclipActive then
            refreshNoclipParts()
        else
            table.clear(noclipParts)
            pcall(function()
                local ch = LocalPlayer and LocalPlayer.Character
                if ch and ch:FindFirstChild("HumanoidRootPart") then
                    ch.HumanoidRootPart.CanCollide = true
                end
            end)
        end
    end

    addConnection(toggleNoclipBtn.MouseButton1Click:Connect(function()
        setNoclip(not noclipActive)
    end))

    local lastNoclipRefresh = 0
    addConnection(RunService.Stepped:Connect(function()
        if not noclipActive then return end
        local now = os.clock()
        local firstPart = noclipParts[1]
        if #noclipParts == 0 or not (firstPart and firstPart.Parent) or (now - lastNoclipRefresh > 2.0) then
            lastNoclipRefresh = now
            refreshNoclipParts()
        end
        for i = 1, #noclipParts do
            local part = noclipParts[i]
            if part and part.Parent and part.CanCollide then
                part.CanCollide = false
            end
        end
    end))
end

-- ============================================================================
-- 2. LIVE SERVER EGG DETECTION & FARMABLE LIST (Pooled & Throttled: Zero-Freeze)
-- ============================================================================

local eggCacheByUid = {}
local rarityByUid = {}
local cardPool = {}
local emptyNoticeLabel = nil
local listDirty, isFetchingSnapshot = false, false

local function getNetRemote(name)
    local ok, res = pcall(function()
        local net = ReplicatedStorage:FindFirstChild("Packages")
            and ReplicatedStorage.Packages:FindFirstChild("Networking")
        return net and net:FindFirstChild(name)
    end)
    return ok and res or nil
end

local function getEggPosition(r, uid)
    if typeof(r) == "table" then
        local cf = r.BoundsCFrame or r.BottomCFrame or r.Position
        local p = nil
        if typeof(cf) == "CFrame" then p = cf.Position
        elseif typeof(cf) == "Vector3" then p = cf
        elseif typeof(cf) == "table" and cf.X and cf.Y and cf.Z then
            p = Vector3.new(cf.X, cf.Y, cf.Z)
        end
        if p and p.Magnitude > 10 then return p end
    end
    local u = uid or (typeof(r) == "table" and (r.Uid or r.EggUid))
    if u and u ~= "" then
        local slots = Workspace:FindFirstChild("AreaEggSlotsClient")
        if slots then
            local sl = slots:FindFirstChild(u)
            if sl then
                if sl:IsA("BasePart") and sl.Position.Magnitude > 10 then
                    if typeof(r) == "table" then r.BoundsCFrame = sl.CFrame end
                    return sl.Position
                end
                if sl:IsA("Model") then
                    local p = sl.PrimaryPart and sl.PrimaryPart.Position
                    if p and p.Magnitude > 10 then
                        if typeof(r) == "table" then r.BoundsCFrame = sl.PrimaryPart.CFrame end
                        return p
                    end
                    local ok, piv = pcall(sl.GetPivot, sl)
                    if ok and piv and piv.Position.Magnitude > 10 then
                        if typeof(r) == "table" then r.BoundsCFrame = piv end
                        return piv.Position
                    end
                end
            end
        end
        local eggs = Workspace:FindFirstChild("Eggs")
        if eggs then
            local em = eggs:FindFirstChild(u)
            if em then
                if em:IsA("BasePart") and em.Position.Magnitude > 10 then
                    if typeof(r) == "table" then r.BoundsCFrame = em.CFrame end
                    return em.Position
                end
                if em:IsA("Model") then
                    local p = em.PrimaryPart and em.PrimaryPart.Position
                    if p and p.Magnitude > 10 then
                        if typeof(r) == "table" then r.BoundsCFrame = em.PrimaryPart.CFrame end
                        return p
                    end
                    local ok, piv = pcall(em.GetPivot, em)
                    if ok and piv and piv.Position.Magnitude > 10 then
                        if typeof(r) == "table" then r.BoundsCFrame = piv end
                        return piv.Position
                    end
                end
            end
        end
    end
    return nil
end

local function isFarmableEgg(r)
    if not r or typeof(r) ~= "table" then return false end
    local state = tostring(r.State or "")
    if state ~= "Slot" and state ~= "Dropped" then
        return false
    end
    if state == "Claimed" then
        return false
    end
    -- Exclude eggs carried by another player
    if state == "Carried" or (r.CarrierUserId and tostring(r.CarrierUserId) ~= tostring(LocalPlayer and LocalPlayer.UserId)) then
        return false
    end
    return true
end

local function resolveEggFields(r, uid, charPos)
    local rawName = r.DisplayName or r.AssetCategory or r.Name or "Egg"
    local rawArea = r.AreaId
    if rawArea == "Light Dark" then rawArea = "Light & Dark" end
    local serverRarity = r.RarityId or r.Rarity or (r.Attributes and r.Attributes.Rarity) or rarityByUid[uid]
    local pos = getEggPosition(r, uid)

    local searchArea = rawArea or (typeof(r) == "table" and r.CachedArea)
    if not searchArea or searchArea == "" or searchArea == "Unknown" then
        if pos then
            local x = pos.X
            if x >= 500 and x < 680 then searchArea = "Forest"
            elseif x >= 680 and x < 850 then searchArea = "Lake"
            elseif x >= 850 and x < 1050 then searchArea = "Desert"
            elseif x >= 1050 and x < 1300 then searchArea = "Jungle"
            elseif x >= 1300 and x < 1650 then searchArea = "Snow"
            elseif x >= 1650 and x < 2050 then searchArea = "Volcano"
            elseif x >= 2050 and x < 2500 then searchArea = "Abyss Ocean"
            elseif x >= 2500 and x < 3100 then searchArea = "Prehistoric"
            elseif x >= 3100 and x < 3700 then searchArea = "Cosmic"
            elseif x >= 3700 and x < 4400 then searchArea = "Cherry Blossom"
            elseif x >= 4400 and x < 5200 then searchArea = "Titan Temple"
            elseif x >= 5200 and x < 6100 then searchArea = "Light & Dark"
            elseif x >= 6100 and x < 7500 then searchArea = "Enchanted Forest"
            end
            if searchArea and typeof(r) == "table" then
                r.CachedArea = searchArea
            end
        end
        if rawName:lower() == "shark" and serverRarity == "Secret" then
            searchArea = "Titan Temple"
        end
    end

    local info = nil
    if rawName and not isGenericEggName(rawName) then
        info = getSpeciesInfo(r.DisplayName, searchArea)
            or getSpeciesInfo(r.AssetCategory, searchArea)
            or getSpeciesInfo(r.Name, searchArea)
            or getSpeciesInfo(rawName, searchArea)
            or getSpeciesInfo(rawName)
    end

    local disp = (info and info.DisplayName) or (not isGenericEggName(rawName) and rawName) or nil
    local rarity = (serverRarity and serverRarity ~= "" and serverRarity ~= "Unknown") and serverRarity or ((info and info.Rarity) or "Unknown")

    -- Fallback: If name is unknown/generic but rarity & area are known, deduce from catalog
    local isGeneric = (not disp or disp == "" or isGenericEggName(disp) or not info)
    if isGeneric and rarity and rarity ~= "Unknown" then
        if searchArea and SPECIES_INFO_BY_BIOME[searchArea] then
            for _, cand in pairs(SPECIES_INFO_BY_BIOME[searchArea]) do
                if cand.Rarity == rarity then
                    info = cand
                    disp = cand.DisplayName or cand.Name
                    break
                end
            end
        else
            -- Cross-biome resolution fallback for rare/unique rarities
            for bName, bTable in pairs(SPECIES_INFO_BY_BIOME) do
                for _, cand in pairs(bTable) do
                    if cand.Rarity == rarity then
                        info = cand
                        disp = cand.DisplayName or cand.Name
                        searchArea = bName
                        break
                    end
                end
                if info then break end
            end
        end
    end

    -- If still no display name, provide clean area label without polluting record
    if not disp or disp == "" or isGenericEggName(disp) then
        if searchArea and searchArea ~= "Unknown" and searchArea ~= "" then
            disp = searchArea .. " Egg"
        else
            disp = "Egg"
        end
    end

    local rank = (info and info.Rank) or (RARITY_RANK[rarity] or 1)
    local biome = (searchArea and searchArea ~= "" and searchArea ~= "Unknown") and searchArea or ((info and info.Biome) or "Unknown")
    local dist = (pos and charPos) and (pos - charPos).Magnitude or nil
    return rawName, info, disp, serverRarity, rarity, rank, biome, pos, dist
end

-- ============================================================================
-- VELOCITY & CARRY ENGINE (Instant 0ms Physics & Dual-Speed State Machine)
-- ============================================================================

local function isHoldingEgg()
    local char = LocalPlayer and LocalPlayer.Character
    if char then
        -- 1. Equipped egg Tool in hand (NOT Model: player pets and accessories are Models)
        for _, c in ipairs(char:GetChildren()) do
            if c:IsA("Tool") then
                local cName = c.Name:lower()
                if cName:find("egg", 1, true)
                    or c:GetAttribute("IsEgg") == true
                    or c:GetAttribute("HalloweenEggUid") ~= nil
                    or (hwCarryState and hwCarryState.active)
                then
                    return true, c.Name
                end
            end
        end
    end

    -- 2. ClientRenderedAssets & Server Snapshot: ONLY match if a specific carryUid is active!
    -- (NEVER match arbitrary CRA models without carryUid, as nest eggs in player's base also live in CRA!)
    if carryUid then
        local myUidStr = tostring(LocalPlayer and LocalPlayer.UserId or "")
        local cra = Workspace:FindFirstChild("ClientRenderedAssets")
        if cra and myUidStr ~= "" then
            local expectedName = myUidStr .. "_" .. tostring(carryUid)
            local m = cra:FindFirstChild(expectedName)
            if m and (m:IsA("BasePart") or m:FindFirstChildWhichIsA("BasePart", true)) then
                return true, tostring(carryUid)
            end
        end

        if eggCacheByUid and eggCacheByUid[carryUid] then
            local rec = eggCacheByUid[carryUid]
            if typeof(rec) == "table" and rec.CarrierUserId and tostring(rec.CarrierUserId) == myUidStr and rec.State == "Carried" then
                local name = rec.DisplayName or rec.AssetCategory or rec.Name or tostring(carryUid)
                return true, name
            end
        end
    end

    return false, nil
end

local hwCarryState = {
    active = false,
    name = nil,
    backpackEggs = setmetatable({}, { __mode = "k" }),
    isCarrying = nil,
}

do
    local function recordBackpackTool(tool)
        if tool and tool:IsA("Tool") and tool.Name:lower():find("egg", 1, true) then
            hwCarryState.backpackEggs[tool] = true
        end
    end

    local backpackChildConn = nil
    local function hookBackpack(bp)
        if backpackChildConn then
            pcall(function() backpackChildConn:Disconnect() end)
            backpackChildConn = nil
        end
        if bp then
            for _, t in ipairs(bp:GetChildren()) do
                recordBackpackTool(t)
            end
            backpackChildConn = bp.ChildAdded:Connect(recordBackpackTool)
            addConnection(backpackChildConn)
        end
    end

    pcall(function()
        hookBackpack(LocalPlayer and LocalPlayer:FindFirstChild("Backpack"))
    end)

    if LocalPlayer then
        addConnection(LocalPlayer.ChildAdded:Connect(function(c)
            if c.Name == "Backpack" then
                pcall(function() hookBackpack(c) end)
            end
        end))
    end

    hwCarryState.isCarrying = function()
        local char = LocalPlayer and LocalPlayer.Character
        if not char then
            hwCarryState.active = false
            hwCarryState.name = nil
            return false, nil
        end

        local heldFieldTool = nil
        for _, c in ipairs(char:GetChildren()) do
            if c:IsA("Tool") and c.Name:lower():find("egg", 1, true) then
                if not hwCarryState.backpackEggs[c] then
                    heldFieldTool = c
                    break
                end
            end
        end

        if heldFieldTool then
            hwCarryState.active = true
            hwCarryState.name = heldFieldTool.Name
            return true, heldFieldTool.Name
        end

        if hwCarryState.active then
            if not isHoldingEgg() then
                hwCarryState.active = false
                hwCarryState.name = nil
                return false, nil
            end
            return true, hwCarryState.name or "Halloween Egg"
        end

        return false, nil
    end
end

local lastCarryingCheck = 0
local cachedCarryingStatus = false
local cachedCarryingName = nil

local function setCarryingState(carrying, eggName)
    isCarrying = carrying
    weAreCarrying = carrying
    if not carrying then
        carryUid = nil
        cachedCarryingName = nil
    elseif eggName then
        cachedCarryingName = eggName
    end
    if velocityEnabled then
        local char = LocalPlayer and LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if hum then
            local targetSpeed = isCarrying and baseCarrySpeed or baseGoSpeed
            pcall(function() hum.WalkSpeed = targetSpeed end)
        end
    end
    updateActivityStatus()
end

local function getCarryingStatus(force)
    if isCarrying or weAreCarrying then
        local name = cachedCarryingName
        if not name and carryUid and eggCacheByUid and eggCacheByUid[carryUid] then
            local rec = eggCacheByUid[carryUid]
            name = rec and (rec.DisplayName or rec.AssetCategory or rec.Name) or carryUid
        end
        return true, name or "Egg"
    end
    if hwCarryState and hwCarryState.active then
        return true, hwCarryState.name or "Halloween Egg"
    end
    return false, nil
end

updateActivityStatus = function()
    local isC, eggName = getCarryingStatus()
    local activeSpeed = isCarrying and baseCarrySpeed or baseGoSpeed

    if activityStatusLabel then
        local newText, newColor
        if not velocityEnabled then
            newText = "Status: Velocity Disabled (Normal WalkSpeed)"
            newColor = Color3.fromRGB(160, 170, 190)
        elseif isCarrying then
            local dispName = eggName or cachedCarryingName or "Egg"
            newText = string.format("Status: Carrying %s (%d studs/s)", dispName, baseCarrySpeed)
            newColor = Color3.fromRGB(255, 205, 90)
        else
            newText = string.format("Status: Not Carrying | Free Movement (%d studs/s)", baseGoSpeed)
            newColor = Color3.fromRGB(150, 185, 230)
        end
        if activityStatusLabel.Text ~= newText then
            activityStatusLabel.Text = newText
            activityStatusLabel.TextColor3 = newColor
        end
    end

    if velLiveLabel then
        local newVelText, newVelColor
        if velocityEnabled then
            local char = LocalPlayer and LocalPlayer.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            local isMoving = hum and hum.MoveDirection.Magnitude > 0.05
            newVelText = string.format("Vel: %d", isMoving and activeSpeed or 0)
            newVelColor = isMoving and Color3.fromRGB(100, 240, 255) or Color3.fromRGB(150, 200, 240)
        else
            newVelText = "Vel: OFF"
            newVelColor = Color3.fromRGB(130, 140, 160)
        end
        if velLiveLabel.Text ~= newVelText then
            velLiveLabel.Text = newVelText
            velLiveLabel.TextColor3 = newVelColor
        end
    end
end

local SAFE_ZONE = Vector3.new(530.332, 70.724, -399.111)

getSafeZonePosition = function()
    return SAFE_ZONE
end

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

local activeWalkTarget = nil
local activeWalkArriveDist = 3.5
local activeWalkSnapDist = 60.0
local activeWalkUid = nil
local activeWalkCallback = nil
local activeWalkToken = 0
local walkLastPos = nil
local walkStuckFrames = 0

local cachedControls = nil
local function getPlayerInputVector()
    local inputVec = Vector3.zero
    if cachedControls and cachedControls.GetMoveVector then
        local ok, mv = pcall(function() return cachedControls:GetMoveVector() end)
        if ok and typeof(mv) == "Vector3" and mv.Magnitude > 0.05 then
            inputVec = mv
        end
    end
    if inputVec.Magnitude <= 0.05 then
        pcall(function()
            local ps = LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerScripts")
            local pm = ps and ps:FindFirstChild("PlayerModule")
            if pm then
                local controls = require(pm):GetControls()
                if controls and controls.GetMoveVector then
                    cachedControls = controls
                    local mv = controls:GetMoveVector()
                    if typeof(mv) == "Vector3" and mv.Magnitude > 0.05 then
                        inputVec = mv
                    end
                end
            end
        end)
    end
    if inputVec.Magnitude <= 0.05 and UserInputService then
        local ix, iz = 0, 0
        if UserInputService:IsKeyDown(Enum.KeyCode.A) or UserInputService:IsKeyDown(Enum.KeyCode.Left) then ix = ix - 1 end
        if UserInputService:IsKeyDown(Enum.KeyCode.D) or UserInputService:IsKeyDown(Enum.KeyCode.Right) then ix = ix + 1 end
        if UserInputService:IsKeyDown(Enum.KeyCode.W) or UserInputService:IsKeyDown(Enum.KeyCode.Up) then iz = iz - 1 end
        if UserInputService:IsKeyDown(Enum.KeyCode.S) or UserInputService:IsKeyDown(Enum.KeyCode.Down) then iz = iz + 1 end
        if ix ~= 0 or iz ~= 0 then
            inputVec = Vector3.new(ix, 0, iz).Unit
        end
    end
    return inputVec
end

local function stopWalking()
    activeWalkToken = (activeWalkToken or 0) + 1
    activeWalkTarget = nil
    activeWalkCallback = nil
    activeWalkUid = nil
    walkLastPos = nil
    walkStuckFrames = 0
    pcall(function()
        local char = LocalPlayer and LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if hum then
            hum:Move(Vector3.zero, false)
            if hrp then hum.WalkToPoint = hrp.Position end
            if not velocityEnabled then
                local normalSpeed = (savedWalkSpeed and savedWalkSpeed < 100) and savedWalkSpeed or 16.0
                hum.WalkSpeed = normalSpeed
            end
        end
        if hrp then hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0) end
    end)
end

local function toVector3(pos)
    if not pos then return nil end
    if typeof(pos) == "Vector3" then return pos end
    if typeof(pos) == "CFrame" then return pos.Position end
    if typeof(pos) == "table" and pos.X and pos.Y and pos.Z then
        return Vector3.new(pos.X, pos.Y, pos.Z)
    end
    return nil
end

-- `onFail` (optional) runs when the walk gives up: invalid target or the 45 s
-- safety timeout. Without it a caller that reschedules itself from `onArrived`
-- would stop forever the first time a walk could not finish (night reset, dead
-- character, unreachable spot).
local function walkToTarget(targetPos, arriveDist, onArrived, uid, snapDist, onFail)
    targetPos = toVector3(targetPos)
    if not targetPos then
        if onFail then task.spawn(onFail) end
        return
    end

    activeWalkToken = (activeWalkToken or 0) + 1
    local myTok = activeWalkToken

    activeWalkTarget = targetPos
    activeWalkArriveDist = arriveDist or 3.5
    activeWalkSnapDist = snapDist
    activeWalkUid = uid
    activeWalkCallback = onArrived
    walkLastPos = nil
    walkStuckFrames = 0

    pcall(function()
        local char = LocalPlayer and LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if hum then hum:MoveTo(targetPos) end
    end)

    task.spawn(function()
        local t0 = os.clock()
        local lastMoveTo = t0
        while activeWalkToken == myTok do
            -- Safety timeout (if player gets stuck or path takes > 45s)
            if os.clock() - t0 > 45.0 then
                stopWalking()
                if onFail then task.spawn(onFail) end
                return
            end

            local char = LocalPlayer and LocalPlayer.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            if not (hum and hrp and hum.Health > 0) then
                task.wait(0.1)
            else
                -- If velocity is disabled, re-issue MoveTo periodically for smooth native pathing
                if not velocityEnabled then
                    local now = os.clock()
                    if now - lastMoveTo >= 0.25 then
                        lastMoveTo = now
                        pcall(function() hum:MoveTo(targetPos) end)
                    end
                end

                -- 1. State / Target Validation checks
                -- Walking to an egg and target egg already secured: stop walking to egg
                if activeWalkUid ~= "SAFE_ZONE" and (weAreCarrying and carryUid == activeWalkUid) then
                    local cb = activeWalkCallback
                    stopWalking()
                    if cb then task.spawn(cb) end
                    return
                end

                -- Walking to SafeZone and egg dropped: immediately abort safezone walk and re-pick!
                if activeWalkUid == "SAFE_ZONE" and not (weAreCarrying or isHoldingEgg()) then
                    stopWalking()
                    if autoReturnActive and autoReturnTargetUid then
                        handleEggDropped(autoReturnTargetUid)
                    end
                    return
                end

                -- Target egg was claimed or carried by another player
                if activeWalkUid and activeWalkUid ~= "SAFE_ZONE" and eggCacheByUid and eggCacheByUid[activeWalkUid] then
                    local rec = eggCacheByUid[activeWalkUid]
                    local myId = tostring(LocalPlayer and LocalPlayer.UserId or "")
                    if rec.State == "Claimed" or (rec.CarrierUserId and tostring(rec.CarrierUserId) ~= myId) then
                        stopWalking()
                        if autoReturnActive and autoReturnTargetUid == activeWalkUid then
                            if rec.State == "Claimed" and (rec.CarrierUserId and tostring(rec.CarrierUserId) == myId) then
                                handleEggDelivered(activeWalkUid)
                            else
                                autoReturnActive = false
                                autoReturnTargetUid = nil
                                returnTripInProgress = false
                                if activityStatusLabel then
                                    activityStatusLabel.Text = "Status: Target egg taken by another player"
                                    activityStatusLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
                                end
                            end
                        end
                        return
                    end

                    -- Live refresh target position if egg shifted
                    local liveP = getEggPosition(rec, activeWalkUid)
                    if liveP then
                        targetPos = liveP
                        activeWalkTarget = liveP
                    end
                end

                local curPos = hrp.Position
                local diff = Vector3.new(targetPos.X - curPos.X, 0, targetPos.Z - curPos.Z)
                local dist = diff.Magnitude

                -- 2. Arrival or Snap Teleport Check
                local effectiveSnap = activeWalkSnapDist or 8.0
                if dist <= activeWalkArriveDist or dist <= effectiveSnap then
                    local cb = activeWalkCallback
                    local walkUid = activeWalkUid
                    local finalTarget = targetPos
                    pcall(function()
                        hrp.AssemblyLinearVelocity = Vector3.zero
                        if walkUid == "SAFE_ZONE" or walkUid == "HW_SAFEZONE" or walkUid == "HW_DROPZONE" then
                            local yPos = finalTarget.Y
                            if math.abs(curPos.Y - finalTarget.Y) <= 4 then yPos = curPos.Y end
                            hrp.CFrame = CFrame.new(finalTarget.X, yPos, finalTarget.Z) * (hrp.CFrame - hrp.CFrame.Position)
                        else
                            local bPos, lookTarget = getBesideOffset(finalTarget, curPos, 2.8)
                            hrp.CFrame = CFrame.lookAt(bPos, lookTarget)
                        end
                        hum:Move(Vector3.zero, false)
                        if hrp then hum.WalkToPoint = hrp.Position end
                    end)
                    stopWalking()
                    if cb then task.spawn(cb) end
                    return
                end

                -- 3. Anti-stuck watchdog: hop over small bumps or lateral nudge if blocked
                if walkLastPos and (Vector3.new(curPos.X - walkLastPos.X, 0, curPos.Z - walkLastPos.Z)).Magnitude < 0.5 then
                    walkStuckFrames = walkStuckFrames + 1
                    if walkStuckFrames == 3 then
                        pcall(function() hum.Jump = true end)
                    elseif walkStuckFrames >= 6 then
                        walkStuckFrames = 0
                        pcall(function()
                            hum.Jump = true
                            local rightVec = Vector3.new(-(targetPos.Z - curPos.Z), 0, targetPos.X - curPos.X)
                            if rightVec.Magnitude > 0.1 then
                                hrp.CFrame = hrp.CFrame + (rightVec.Unit * 3.5)
                            end
                        end)
                    end
                else
                    walkStuckFrames = 0
                end
                walkLastPos = curPos

                -- 4. Fast monitor tick: physics loop handles seamless steering and velocity
                task.wait(0.08)
            end
        end
    end)
end

handleEggDelivered = function(uid)
    print(string.format("[EggGoTo v11] Egg %s successfully delivered!", tostring(uid)))
    autoReturnActive = false
    autoReturnTargetUid = nil
    returnTripInProgress = false
    setCarryingState(false)
    stopWalking()
    pcall(function()
        local char = LocalPlayer and LocalPlayer.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if hrp then hrp.AssemblyLinearVelocity = Vector3.zero end
        if hum then hum:UnequipTools() end
    end)
    updateActivityStatus()
end

handleEggDropped = function(u, payload)
    if not autoReturnActive then return end
    if activeWalkUid == u then return end
    returnTripInProgress = false
    setCarryingState(false)
    stopWalking()

    local dropPos = nil
    if payload and typeof(payload) == "table" and payload.BoundsCFrame then
        local cf = payload.BoundsCFrame
        if typeof(cf) == "CFrame" then dropPos = cf.Position
        elseif typeof(cf) == "Vector3" then dropPos = cf
        elseif typeof(cf) == "table" and cf.X and cf.Y and cf.Z then
            dropPos = Vector3.new(cf.X, cf.Y, cf.Z)
        end
    end

    if not dropPos and eggCacheByUid and eggCacheByUid[u] then
        dropPos = getEggPosition(eggCacheByUid[u], u)
    end

    if not dropPos then
        local char = LocalPlayer and LocalPlayer.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if hrp then dropPos = hrp.Position end
    end

    if not dropPos then return end

    print(string.format("[EggGoTo v11] Egg dropped! Turning around to re-pick (%s)...", tostring(u)))
    if activityStatusLabel then
        activityStatusLabel.Text = "Status: Egg dropped! Re-picking egg..."
        activityStatusLabel.TextColor3 = Color3.fromRGB(255, 140, 60)
    end

    walkToTarget(dropPos, 3.5, function()
        executePickupSpam({
            Uid = u,
            Position = dropPos,
            Name = "Dropped Egg"
        })
        startAutoPickupSpam()
    end, u, 8.0)
end

startReturnTrip = function()
    if returnTripInProgress and activeWalkUid == "SAFE_ZONE" then return end
    returnTripInProgress = true

    local safePos = getSafeZonePosition()
    if not safePos then return end

    print(string.format("[EggGoTo v11] Egg secured! Automatically returning to SafeZone (%d, %d, %d)...", math.floor(safePos.X), math.floor(safePos.Y), math.floor(safePos.Z)))
    if activityStatusLabel then
        activityStatusLabel.Text = "Status: Returning to SafeZone with Egg..."
        activityStatusLabel.TextColor3 = Color3.fromRGB(100, 240, 255)
    end

    walkToTarget(safePos, 6.0, function()
        print("[EggGoTo v11] Arrived at SafeZone. Delivering egg...")
        pcall(function()
            local char = LocalPlayer and LocalPlayer.Character
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            if hrp then hrp.AssemblyLinearVelocity = Vector3.zero end
            if hum then hum:UnequipTools() end
        end)
        autoReturnActive = false
        autoReturnTargetUid = nil
        returnTripInProgress = false
        setCarryingState(false)
        if activityStatusLabel then
            activityStatusLabel.Text = "Status: Arrived at SafeZone with Egg"
            activityStatusLabel.TextColor3 = Color3.fromRGB(120, 240, 160)
        end
    end, "SAFE_ZONE", 60.0)
end

local function updateVelocityPhysics()
    local char = LocalPlayer and LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not (hum and hrp and hrp.Parent and hum.Health > 0) then return end

    -- When Velocity is disabled, do not inject custom velocity or override WalkSpeed
    if not velocityEnabled then
        return
    end

    -- Idle early exit: if not auto-walking and player is standing still (e.g. fishing, idle, paused), skip physics entirely
    local isMoving = (hum.MoveDirection.Magnitude > 0.05)
    if not activeWalkTarget and not isMoving then
        return
    end

    local targetSpeed = isCarrying and baseCarrySpeed or baseGoSpeed

    -- Case 1: Active Auto-Walk (Walking to Egg or Returning to SafeZone)
    if activeWalkTarget then
        local curPos = hrp.Position
        local diff = Vector3.new(activeWalkTarget.X - curPos.X, 0, activeWalkTarget.Z - curPos.Z)
        local targetDir = diff.Magnitude > 0.1 and diff.Unit or Vector3.zero

        -- Query player manual steering input (A, D, W, S or analog thumbstick)
        local inputVec = getPlayerInputVector()
        local moveDir = targetDir

        if inputVec.Magnitude > 0.05 then
            local cam = Workspace.CurrentCamera
            local camLook = cam and cam.CFrame.LookVector or Vector3.new(0, 0, -1)
            local camRight = cam and cam.CFrame.RightVector or Vector3.new(1, 0, 0)
            local camFwdFlat = Vector3.new(camLook.X, 0, camLook.Z).Unit
            local camRtFlat = Vector3.new(camRight.X, 0, camRight.Z).Unit
            local worldManualDir = (camRtFlat * inputVec.X - camFwdFlat * inputVec.Z)

            if worldManualDir.Magnitude > 0.05 then
                -- Smoothly blend target direction with manual lateral steering:
                -- Retains 100% full speed while allowing agile veering around obstacles!
                moveDir = (targetDir + worldManualDir.Unit * 1.0).Unit
            end
        end

        hum:Move(moveDir, false)

        if moveDir.Magnitude > 0.05 then
            hrp.AssemblyLinearVelocity = Vector3.new(
                moveDir.X * targetSpeed,
                hrp.AssemblyLinearVelocity.Y,
                moveDir.Z * targetSpeed
            )
            if hum.WalkSpeed ~= targetSpeed then
                pcall(function() hum.WalkSpeed = targetSpeed end)
            end
        end
        return
    end

    -- Case 2: Regular Velocity Physics for manual player free-roam (WASD)
    if hum.MoveDirection.Magnitude > 0.05 then
        local dir = hum.MoveDirection.Unit
        hrp.AssemblyLinearVelocity = Vector3.new(
            dir.X * targetSpeed,
            hrp.AssemblyLinearVelocity.Y,
            dir.Z * targetSpeed
        )
        if hum.WalkSpeed ~= targetSpeed then
            pcall(function() hum.WalkSpeed = targetSpeed end)
        end
    end
end

local function disableVelocity()
    velocityEnabled = false
    velToggleBtn.Text = "[OFF] Velocity"
    velToggleBtn.BackgroundColor3 = Color3.fromRGB(42, 48, 65)
    velToggleBtn.TextColor3 = Color3.fromRGB(210, 220, 240)

    local char = LocalPlayer and LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum then
        local normalSpeed = (savedWalkSpeed and savedWalkSpeed < 100) and savedWalkSpeed or 16.0
        pcall(function() hum.WalkSpeed = normalSpeed end)
    end
    updateActivityStatus()
end

local function enableVelocity()
    local char = LocalPlayer and LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum and hum.WalkSpeed > 0 and hum.WalkSpeed < 100 then
        savedWalkSpeed = hum.WalkSpeed
    end
    velocityEnabled = true
    velToggleBtn.Text = "[ON] Velocity"
    velToggleBtn.BackgroundColor3 = Color3.fromRGB(35, 135, 75)
    velToggleBtn.TextColor3 = Color3.new(1, 1, 1)

    if hum then
        local targetSpeed = isCarrying and baseCarrySpeed or baseGoSpeed
        pcall(function() hum.WalkSpeed = targetSpeed end)
    end
    updateActivityStatus()
end

addConnection(velToggleBtn.MouseButton1Click:Connect(function()
    if velocityEnabled then
        disableVelocity()
    else
        enableVelocity()
    end
end))

addConnection(goBox.FocusLost:Connect(function()
    local val = tonumber(goBox.Text)
    if val and val > 0 then
        baseGoSpeed = math.clamp(math.floor(val), 16, 500)
    end
    goBox.Text = tostring(baseGoSpeed)
    local char = LocalPlayer and LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum and velocityEnabled and not isCarrying then
        pcall(function() hum.WalkSpeed = baseGoSpeed end)
    end
    updateActivityStatus()
end))

addConnection(carryBox.FocusLost:Connect(function()
    local val = tonumber(carryBox.Text)
    if val and val > 0 then
        baseCarrySpeed = math.clamp(math.floor(val), 16, 500)
    end
    carryBox.Text = tostring(baseCarrySpeed)
    local char = LocalPlayer and LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum and velocityEnabled and isCarrying then
        pcall(function() hum.WalkSpeed = baseCarrySpeed end)
    end
    updateActivityStatus()
end))

addConnection(RunService.Heartbeat:Connect(updateVelocityPhysics))

addConnection(LocalPlayer.CharacterAdded:Connect(function(newChar)
    local hum = newChar:WaitForChild("Humanoid", 5)
    if hum and not velocityEnabled then
        if hum.WalkSpeed > 0 and hum.WalkSpeed < 100 then
            savedWalkSpeed = hum.WalkSpeed
        else
            savedWalkSpeed = 16.0
        end
    end
    setCarryingState(false)
    lastCarryingCheck = 0
    cachedCarryingStatus = false
    cachedCarryingName = nil
    if hwCarryState then
        hwCarryState.active = false
        hwCarryState.name = nil
    end
    updateActivityStatus()
    pcall(function()
        bindRecoveryCharacter(newChar)
    end)
end))

-- ============================================================================
-- ZERO-WAIT INSTANT RAGDOLL RECOVERY ENGINE (Anti-Stun & Anti-Fling)
-- ============================================================================

local recoveryJoints = {}
local recoveryConnections = {}

local function enablePlayerControls()
    if cachedControls and cachedControls.Enable then
        pcall(function() cachedControls:Enable() end)
        return
    end
    pcall(function()
        local ps = LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerScripts")
        local pm = ps and ps:FindFirstChild("PlayerModule")
        if pm then
            local controls = require(pm):GetControls()
            if controls and controls.Enable then
                cachedControls = controls
                controls:Enable()
            end
        end
    end)
end

local function clearRagdollAttributes()
    pcall(function()
        if LocalPlayer then
            LocalPlayer:SetAttribute("RagdollEndTime", 0)
            LocalPlayer:SetAttribute("RagdollTime", 0)
            LocalPlayer:SetAttribute("IsRagdoll", false)
            LocalPlayer:SetAttribute("Ragdolled", false)
        end
        local char = LocalPlayer and LocalPlayer.Character
        if char then
            char:SetAttribute("RagdollEndTime", 0)
            char:SetAttribute("RagdollTime", 0)
            char:SetAttribute("IsRagdoll", false)
            char:SetAttribute("Ragdolled", false)
        end
    end)
end

local isRecovering = false
local lastRecoveryTime = 0

executeInstantRecovery = function(reason)
    if not (RECOVERY_CONFIG and RECOVERY_CONFIG.Enabled) then return end
    local now = os.clock()
    if isRecovering or (now - lastRecoveryTime < 0.05) then return end
    isRecovering = true
    lastRecoveryTime = now

    local char = LocalPlayer and LocalPlayer.Character
    if not char then
        isRecovering = false
        return
    end
    local hum = char:FindFirstChildOfClass("Humanoid")
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not (hum and hrp and hum.Health > 0) then
        isRecovering = false
        return
    end

    clearRagdollAttributes()
    setCarryingState(false)

    if #recoveryJoints > 0 then
        for _, motor in ipairs(recoveryJoints) do
            if motor and motor.Parent and not motor.Enabled then
                motor.Enabled = true
            end
        end
    end

    hum.PlatformStand = false
    hum.Sit = false
    hum.AutoRotate = true

    pcall(function()
        hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, true)
        hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, true)
        hum:SetStateEnabled(Enum.HumanoidStateType.Physics, true)
        hum:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
        hum:SetStateEnabled(Enum.HumanoidStateType.Running, true)
        hum:ChangeState(Enum.HumanoidStateType.GettingUp)
        hum:ChangeState(Enum.HumanoidStateType.Running)
    end)

    local normalSpeed = (savedWalkSpeed and savedWalkSpeed < 100) and savedWalkSpeed or 16.0
    local curTargetSpeed = velocityEnabled and (isCarrying and baseCarrySpeed or baseGoSpeed) or normalSpeed
    if velocityEnabled then
        if hum.WalkSpeed ~= curTargetSpeed then
            hum.WalkSpeed = curTargetSpeed
        end
    else
        if hum.WalkSpeed < 16.0 or hum.WalkSpeed >= 100 then
            hum.WalkSpeed = normalSpeed
        end
    end

    enablePlayerControls()

    -- Anti-Fling Braking & Fast Grounding:
    -- Cancels horizontal fling so character stays right at the bump location beside the egg,
    -- and pulls downward fast if launched into the air.
    if RECOVERY_CONFIG.AntiFling and hrp then
        local curVel = hrp.AssemblyLinearVelocity
        local fastY = curVel.Y
        if fastY > -30 then
            fastY = -45
        end
        hrp.AssemblyLinearVelocity = Vector3.new(0, fastY, 0)
        hrp.AssemblyAngularVelocity = Vector3.zero
    end

    isRecovering = false
end

bindRecoveryCharacter = function(char)
    for _, conn in ipairs(recoveryConnections) do
        pcall(function() conn:Disconnect() end)
    end
    table.clear(recoveryConnections)
    table.clear(recoveryJoints)

    if not char then return end
    local hum = char:WaitForChild("Humanoid", 5)
    local hrp = char:WaitForChild("HumanoidRootPart", 5)
    if not (hum and hrp) then return end

    local function registerMotor(obj)
        if obj:IsA("Motor6D") and not obj:FindFirstAncestorWhichIsA("Tool") and not obj:FindFirstAncestorWhichIsA("Accessory") then
            table.insert(recoveryJoints, obj)
            local conn = obj:GetPropertyChangedSignal("Enabled"):Connect(function()
                if RECOVERY_CONFIG and RECOVERY_CONFIG.Enabled and not obj.Enabled then
                    obj.Enabled = true
                    executeInstantRecovery("JointLock")
                end
            end)
            table.insert(recoveryConnections, conn)
        end
    end

    for _, desc in ipairs(char:GetDescendants()) do
        registerMotor(desc)
    end

    local descConn = char.DescendantAdded:Connect(function(desc)
        registerMotor(desc)
    end)
    table.insert(recoveryConnections, descConn)

    local stateConn = hum.StateChanged:Connect(function(_, newState)
        if not (RECOVERY_CONFIG and RECOVERY_CONFIG.Enabled) then return end
        if newState == Enum.HumanoidStateType.Ragdoll
            or newState == Enum.HumanoidStateType.FallingDown
            or newState == Enum.HumanoidStateType.Physics then
            executeInstantRecovery(newState.Name)
        end
    end)
    table.insert(recoveryConnections, stateConn)

    local platConn = hum:GetPropertyChangedSignal("PlatformStand"):Connect(function()
        if RECOVERY_CONFIG and RECOVERY_CONFIG.Enabled and hum.PlatformStand then
            hum.PlatformStand = false
            executeInstantRecovery("PlatformStand")
        end
    end)
    table.insert(recoveryConnections, platConn)

    local sitConn = hum:GetPropertyChangedSignal("Sit"):Connect(function()
        if RECOVERY_CONFIG and RECOVERY_CONFIG.Enabled and hum.Sit then
            hum.Sit = false
            executeInstantRecovery("Sit")
        end
    end)
    table.insert(recoveryConnections, sitConn)

    if LocalPlayer then
        local attrConn1 = LocalPlayer:GetAttributeChangedSignal("RagdollEndTime"):Connect(function()
            if RECOVERY_CONFIG and RECOVERY_CONFIG.Enabled then
                local rEnd = LocalPlayer:GetAttribute("RagdollEndTime")
                if typeof(rEnd) == "number" and rEnd > 0 then
                    executeInstantRecovery("RagdollTimer")
                end
            end
        end)
        table.insert(recoveryConnections, attrConn1)
    end

    local attrConn2 = char:GetAttributeChangedSignal("RagdollEndTime"):Connect(function()
        if RECOVERY_CONFIG and RECOVERY_CONFIG.Enabled then
            local rEnd = char:GetAttribute("RagdollEndTime")
            if typeof(rEnd) == "number" and rEnd > 0 then
                executeInstantRecovery("CharRagdollTimer")
            end
        end
    end)
    table.insert(recoveryConnections, attrConn2)

    local toolAddConn = char.ChildAdded:Connect(function(child)
        if child:IsA("Tool") then
            local tName = child.Name
            if not (tName:find("Rod") or tName:find("Net") or tName:find("Bat") or tName:find("Weapon") or tName:find("Sword")) then
                setCarryingState(true, tName)
            end
        end
    end)
    table.insert(recoveryConnections, toolAddConn)

    local toolRemConn = char.ChildRemoved:Connect(function(child)
        if child:IsA("Tool") then
            local tName = child.Name
            if not (tName:find("Rod") or tName:find("Net") or tName:find("Bat") or tName:find("Weapon") or tName:find("Sword")) then
                setCarryingState(false)
            end
        end
    end)
    table.insert(recoveryConnections, toolRemConn)
end

if LocalPlayer and LocalPlayer.Character then
    task.spawn(function()
        bindRecoveryCharacter(LocalPlayer.Character)
    end)
end

-- ============================================================================
-- FAST PICKUP & PROXIMITY PROMPT ENGINE (Clean Port from v10)
-- ============================================================================

local function getCarryRemote()
    return getNetRemote("RF/EggWorld/AskFieldEggCarry")
end

local function carryEgg(uid, burstCount)
    if not uid or uid == "" then return false end
    burstCount = burstCount or (PICKUP_CONFIG and PICKUP_CONFIG.SpamBurstCount) or 8
    local rf = getCarryRemote()
    if not rf then return false end
    local payload = { Uid = uid }
    for i = 1, burstCount do
        task.spawn(function()
            pcall(function() return rf:InvokeServer(payload) end)
        end)
    end
    return true
end

local function isCarryPrompt(prompt)
    if not prompt or not prompt:IsA("ProximityPrompt") then return false end
    local name = (prompt.Name or ""):lower()
    local action = (prompt.ActionText or ""):lower()
    local obj = (prompt.ObjectText or ""):lower()

    -- Strict blacklist: REJECT ANY hatch, open, crack, buy, purchase, shop, talk, manor prompt
    if name:find("hatch") or name:find("open") or name:find("crack") or name:find("buy") or name:find("shop") or name:find("purchase") or name:find("talk") or name:find("manor") then
        return false
    end
    if action:find("hatch") or action:find("open") or action:find("crack") or action:find("buy") or action:find("shop") or action:find("purchase") or action:find("talk") then
        return false
    end
    if obj:find("hatch") or obj:find("open") or obj:find("crack") or obj:find("buy") or obj:find("shop") or obj:find("purchase") or obj:find("talk") then
        return false
    end

    -- Strict whitelist: ONLY accept steal, carry, pick, take, grab, collect, hold
    if name:find("carry") or name:find("steal") or name:find("pickup") or name:find("pick") or name:find("halloweenegg") or name:find("eggprompt") then
        return true
    end
    if action:find("steal") or action:find("carry") or action:find("pick") or action:find("take") or action:find("grab") or action:find("collect") then
        return true
    end

    return false
end

local function triggerProximityPrompt(prompt)
    if not prompt or not prompt.Parent then return end
    if not isCarryPrompt(prompt) then return end
    pcall(function()
        prompt.HoldDuration = 0
        prompt.RequiresLineOfSight = false
    end)
    if typeof(fireproximityprompt) == "function" then
        pcall(fireproximityprompt, prompt, 0)
        pcall(fireproximityprompt, prompt)
    end
    pcall(function()
        if typeof(prompt.InputHoldBegin) == "function" then
            prompt:InputHoldBegin()
            prompt:InputHoldEnd()
        end
    end)
end

local function applyReachAssist(targetPos)
    if weAreCarrying then return false end
    local char = LocalPlayer and LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root or typeof(targetPos) ~= "Vector3" then return false end
    local dist = (Vector3.new(targetPos.X, 0, targetPos.Z) - Vector3.new(root.Position.X, 0, root.Position.Z)).Magnitude
    local maxReach = (PICKUP_CONFIG and PICKUP_CONFIG.MaxReachDistance) or 35
    if dist > 3 and dist <= maxReach then
        local bPos, lookTarget = getBesideOffset(targetPos, root.Position, 2.8)
        pcall(function()
            root.AssemblyLinearVelocity = Vector3.zero
            root.CFrame = CFrame.lookAt(bPos, lookTarget)
        end)
        return true
    end
    return false
end

local function checkAndApplyReachAssist(targetPos, hasSnapped)
    if hasSnapped or not targetPos then return hasSnapped end
    local char = LocalPlayer and LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local dist = root and (targetPos - root.Position).Magnitude or 999
    if dist <= 3.5 then
        return true
    elseif dist <= 35.0 then
        if applyReachAssist(targetPos) then return true end
    end
    return hasSnapped
end

local function calculateTargetScore(pos, dist, charPos, charLook, camPos, camLook)
    local dir = dist > 0.01 and (pos - charPos).Unit or charLook
    local charDot = charLook:Dot(dir)
    local camDir = ((pos - camPos).Magnitude > 0.01) and (pos - camPos).Unit or camLook
    local camDot = camLook:Dot(camDir)
    local score = (math.max(0, camDot) * 2.2 + math.max(0, charDot) * 1.2 + 0.3) / (dist + 0.5)
    if dist <= 6 then score = score + 3 end
    return score
end

local function getBestFocusedTarget()
    if weAreCarrying then return nil end
    local char = LocalPlayer and LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return nil end

    local charPos  = root.Position
    local charLook = root.CFrame.LookVector
    local cam = Workspace.CurrentCamera
    local camPos  = cam and cam.CFrame.Position or charPos
    local camLook = cam and cam.CFrame.LookVector or charLook

    local bestTarget, highestScore = nil, -math.huge
    local maxDist = (PICKUP_CONFIG and PICKUP_CONFIG.ReachAssist and PICKUP_CONFIG.MaxReachDistance) or 16

    local function scoreTarget(pos, dist)
        return calculateTargetScore(pos, dist, charPos, charLook, camPos, camLook)
    end

    -- 1. Scan from eggCacheByUid
    if eggCacheByUid then
        for uid, r in pairs(eggCacheByUid) do
            local isCarriedByOther = r.CarrierUserId and tostring(r.CarrierUserId) ~= tostring(LocalPlayer and LocalPlayer.UserId)
            if r.State ~= "Claimed" and not isCarriedByOther then
                local pos = getEggPosition(r)
                if pos then
                    local dist = (pos - charPos).Magnitude
                    if dist <= maxDist then
                        local score = scoreTarget(pos, dist)
                        if score > highestScore then
                            highestScore = score
                            local disp = r.DisplayName or r.AssetCategory or r.Name or "Egg"
                            bestTarget = {
                                Type = "EggRecord",
                                Uid = uid,
                                Name = disp,
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

    -- 2. Scan AreaEggSlotsClient directly
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
                    if not uid and eggCacheByUid then
                        for eUid, eRec in pairs(eggCacheByUid) do
                            local ePos = getEggPosition(eRec)
                            if ePos and (ePos - pos).Magnitude < 4.0 then
                                uid = eUid
                                break
                            end
                        end
                    end
                    if uid and score > highestScore then
                        highestScore = score
                        bestTarget = {
                            Type = "SlotDirect",
                            Uid = uid,
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

    -- 3. Scan Workspace.Eggs
    local eggsFolder = Workspace:FindFirstChild("Eggs")
    if eggsFolder then
        for _, ch in ipairs(eggsFolder:GetChildren()) do
            local pos = ch:IsA("BasePart") and ch.Position or (ch:IsA("Model") and ch:GetPivot().Position)
            if pos then
                local dist = (pos - charPos).Magnitude
                if dist <= maxDist then
                    local score = scoreTarget(pos, dist)
                    local uid = ch:GetAttribute("Uid") or ch:GetAttribute("EggUid")
                    if not uid and #ch.Name == 32 and ch.Name:match("^%x+$") then uid = ch.Name end
                    if uid and score > highestScore then
                        highestScore = score
                        bestTarget = {
                            Type = "WorldEgg",
                            Uid = uid,
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

    -- Associate ProximityPrompt if not already found
    if bestTarget and not bestTarget.Prompt and bestTarget.Uid then
        if slotsFolder then
            local slotInst = slotsFolder:FindFirstChild(bestTarget.Uid)
            if not slotInst then
                for _, ch in ipairs(slotsFolder:GetChildren()) do
                    if ch:GetAttribute("Uid") == bestTarget.Uid or ch:GetAttribute("EggUid") == bestTarget.Uid then
                        slotInst = ch; break
                    end
                end
            end
            if slotInst then
                bestTarget.Prompt = slotInst:FindFirstChildWhichIsA("ProximityPrompt", true)
            end
        end
        if not bestTarget.Prompt and eggsFolder then
            local eggInst = eggsFolder:FindFirstChild(bestTarget.Uid)
            if eggInst then
                bestTarget.Prompt = eggInst:FindFirstChildWhichIsA("ProximityPrompt", true)
            end
        end
    end

    return bestTarget
end

executePickupSpam = function(target)
    if not target then return end
    if target.Uid then
        carryUid = target.Uid
    end
    if target.Prompt then
        triggerProximityPrompt(target.Prompt)
    else
        local pr = nil
        local spp = Workspace:FindFirstChild("SmartPromptPart")
        if spp then
            local sp = spp:FindFirstChildWhichIsA("ProximityPrompt", true)
            if sp and isCarryPrompt(sp) then pr = sp end
        end
        if not pr then
            local ar = Workspace:FindFirstChild("AreaEggSlotsClient")
            if ar and target.Uid then
                local sl = ar:FindFirstChild(target.Uid)
                if not sl then
                    for _, ch in ipairs(ar:GetChildren()) do
                        if ch:GetAttribute("Uid") == target.Uid or ch:GetAttribute("EggUid") == target.Uid then
                            sl = ch; break
                        end
                    end
                end
                if sl then pr = sl:FindFirstChildWhichIsA("ProximityPrompt", true) end
            end
        end
        if not pr and target.Uid and Workspace:FindFirstChild("Eggs") then
            local em = Workspace.Eggs:FindFirstChild(target.Uid)
            if em then pr = em:FindFirstChildWhichIsA("ProximityPrompt", true) end
        end
        if pr then
            triggerProximityPrompt(pr)
        end
    end
    if target.Uid then
        carryEgg(target.Uid, (PICKUP_CONFIG and PICKUP_CONFIG.SpamBurstCount) or 8)
    end
end

startAutoPickupSpam = function(initialTarget)
    if weAreCarrying then return end
    autoPickupToken = (autoPickupToken or 0) + 1
    local myTok = autoPickupToken
    task.spawn(function()
        local tStart = os.clock()
        local maxDuration = 1.5
        while autoPickupToken == myTok and PICKUP_CONFIG and PICKUP_CONFIG.Enabled and (os.clock() - tStart < maxDuration) do
            local target = initialTarget or getBestFocusedTarget()
            if target then
                executePickupSpam(target)
            end
            if weAreCarrying then
                if autoReturnActive and autoReturnTargetUid then
                    task.delay(0.2, function()
                        if autoReturnActive and weAreCarrying then
                            startReturnTrip()
                        end
                    end)
                end
                break
            end
            task.wait(0.05)
        end
    end)
end

-- Key Listener: Press [E] for Instant Zero-Hold Pickup Spam & WASD auto-walk cancel
addConnection(UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if UserInputService:GetFocusedTextBox() ~= nil then return end

    -- Cancel auto-walk / auto-return ONLY when [Q] is pressed (W, A, S, D will NOT cancel auto-travel)
    if input.KeyCode == Enum.KeyCode.Q then
        if activeWalkTarget then
            stopWalking()
        end
        if autoReturnActive then
            autoReturnActive = false
            autoReturnTargetUid = nil
            returnTripInProgress = false
            if activityStatusLabel then
                activityStatusLabel.Text = "Status: Auto-Travel Cancelled [Q]"
                activityStatusLabel.TextColor3 = Color3.fromRGB(255, 180, 100)
            end
        end
    end

    -- Jump during auto-walk / auto-return: trigger jump without cancelling movement or slowing down
    if input.KeyCode == Enum.KeyCode.Space then
        if activeWalkTarget then
            local char = LocalPlayer and LocalPlayer.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            if hum and hum.Health > 0 then
                pcall(function()
                    hum.Jump = true
                end)
            end
        end
    end

    if input.KeyCode == Enum.KeyCode.E then
        local inHw = false
        pcall(function()
            inHw = (LocalPlayer and LocalPlayer:GetAttribute("InHalloweenDimension") == true)
                or (Workspace:FindFirstChild("HalloweenDimension") ~= nil)
        end)
        if inHw and hwAutoPickEnabled and startHalloweenAutoPickup then
            startHalloweenAutoPickup()
        elseif PICKUP_CONFIG and PICKUP_CONFIG.Enabled then
            startAutoPickupSpam()
        elseif startHalloweenAutoPickup then
            startHalloweenAutoPickup()
        end
    end
end))

requestListUpdate = function()
    listDirty = true
end

local function createPooledCard(idx, parentScroll, cardPrefix, bgColor, defaultAccent, onTpClicked, onGetClicked)
    local card = Instance.new("Frame")
    card.Name = cardPrefix .. tostring(idx)
    card.Size = UDim2.new(1, -8, 0, 34)
    card.BackgroundColor3 = bgColor
    card.BorderSizePixel = 0
    card.LayoutOrder = idx
    card.Parent = parentScroll
    Instance.new("UICorner", card).CornerRadius = UDim.new(0, 6)

    local accent = Instance.new("Frame")
    accent.Name = "Accent"
    accent.Size = UDim2.new(0, 3, 1, -6)
    accent.Position = UDim2.new(0, 4, 0, 3)
    accent.BackgroundColor3 = defaultAccent or Color3.fromRGB(60, 120, 200)
    accent.BorderSizePixel = 0
    accent.Parent = card
    Instance.new("UICorner", accent).CornerRadius = UDim.new(0, 2)

    local nameLabel = Instance.new("TextLabel")
    nameLabel.Name = "NameLabel"
    nameLabel.Size = UDim2.new(1, -92, 0, 16)
    nameLabel.Position = UDim2.new(0, 12, 0, 2)
    nameLabel.BackgroundTransparency = 1
    nameLabel.TextColor3 = Color3.fromRGB(235, 242, 255)
    nameLabel.TextSize = 11.5
    nameLabel.Font = Enum.Font.GothamBold
    nameLabel.TextXAlignment = Enum.TextXAlignment.Left
    nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
    nameLabel.Parent = card

    local subLabel = Instance.new("TextLabel")
    subLabel.Name = "SubLabel"
    subLabel.Size = UDim2.new(1, -92, 0, 13)
    subLabel.Position = UDim2.new(0, 12, 0, 18)
    subLabel.BackgroundTransparency = 1
    subLabel.TextColor3 = Color3.fromRGB(160, 175, 205)
    subLabel.TextSize = 10
    subLabel.Font = Enum.Font.Gotham
    subLabel.TextXAlignment = Enum.TextXAlignment.Left
    subLabel.TextTruncate = Enum.TextTruncate.AtEnd
    subLabel.Parent = card

    local tpBtn = Instance.new("TextButton")
    tpBtn.Name = "TpBtn"
    tpBtn.Size = UDim2.new(0, 34, 0, 22)
    tpBtn.Position = UDim2.new(1, -80, 0.5, -11)
    tpBtn.BackgroundColor3 = Color3.fromRGB(42, 60, 95)
    tpBtn.Text = "TP"
    tpBtn.TextColor3 = Color3.fromRGB(200, 220, 255)
    tpBtn.TextSize = 10.5
    tpBtn.Font = Enum.Font.GothamBold
    tpBtn.Parent = card
    Instance.new("UICorner", tpBtn).CornerRadius = UDim.new(0, 4)

    local getBtn = Instance.new("TextButton")
    getBtn.Name = "GetBtn"
    getBtn.Size = UDim2.new(0, 38, 0, 22)
    getBtn.Position = UDim2.new(1, -42, 0.5, -11)
    getBtn.BackgroundColor3 = Color3.fromRGB(40, 130, 80)
    getBtn.Text = "Get"
    getBtn.TextColor3 = Color3.new(1, 1, 1)
    getBtn.TextSize = 10.5
    getBtn.Font = Enum.Font.GothamBold
    getBtn.Parent = card
    Instance.new("UICorner", getBtn).CornerRadius = UDim.new(0, 4)

    local item = {
        card      = card,
        accent    = accent,
        nameLabel = nameLabel,
        subLabel  = subLabel,
        tpBtn     = tpBtn,
        getBtn    = getBtn,
        data      = nil,
    }

    addConnection(tpBtn.MouseButton1Click:Connect(function()
        if item.data and onTpClicked then onTpClicked(item.data) end
    end))
    addConnection(getBtn.MouseButton1Click:Connect(function()
        if item.data and onGetClicked then onGetClicked(item.data) end
    end))

    return item
end

local function getOrCreateCard(idx)
    local item = cardPool[idx]
    if not item then
        item = createPooledCard(idx, eggListScroll, "Card_", Color3.fromRGB(26, 30, 40), nil, function(eggData)
            stopWalking()
            autoReturnActive = false
            autoReturnTargetUid = nil
            returnTripInProgress = false
            local targetPos = toVector3(eggData.Position or getEggPosition(eggData.Record, eggData.Uid))
            if not targetPos then return end
            pcall(function()
                local ch = LocalPlayer and LocalPlayer.Character
                local root = ch and ch:FindFirstChild("HumanoidRootPart")
                if root then
                    root.AssemblyLinearVelocity = Vector3.zero
                    root.CFrame = CFrame.new(targetPos + Vector3.new(0, 3, 0))
                end
            end)
        end, function(eggData)
            stopWalking()
            local targetPos = toVector3(eggData.Position or getEggPosition(eggData.Record, eggData.Uid))
            if not targetPos then return end
            pcall(function()
                local ch = LocalPlayer and LocalPlayer.Character
                local hum = ch and ch:FindFirstChildOfClass("Humanoid")
                if hum then hum:UnequipTools() end
            end)
            autoReturnActive = true
            autoReturnTargetUid = eggData.Uid
            returnTripInProgress = false
            walkToTarget(targetPos, 3.5, function()
                local pickupTarget = {
                    Uid = eggData.Uid,
                    Position = targetPos,
                    Name = eggData.DisplayName
                }
                executePickupSpam(pickupTarget)
                startAutoPickupSpam(pickupTarget)
            end, eggData.Uid, 8.0)
        end)
        cardPool[idx] = item
    end
    return item
end

renderFarmableEggs = function()
    if not (screenGui and screenGui.Parent and main and main.Visible and tabEggs and tabEggs.Visible) then
        return
    end

    local charPos = nil
    pcall(function()
        local ch = LocalPlayer and LocalPlayer.Character
        local root = ch and ch:FindFirstChild("HumanoidRootPart")
        if root then charPos = root.Position end
    end)

    local farmableList = {}
    for uid, r in pairs(eggCacheByUid) do
        if isFarmableEgg(r) then
            local rawName, info, disp, serverRarity, rarity, rank, biome, pos, dist = resolveEggFields(r, uid, charPos)

            if isRarityAllowed(rarity) and isBiomeAllowed(biome) and isEggAllowed(disp, rawName, info) then
                table.insert(farmableList, {
                    Record      = r,
                    Uid         = uid,
                    RawName     = rawName,
                    DisplayName = disp,
                    Rarity      = rarity,
                    Rank        = rank,
                    Biome       = biome,
                    Position    = pos,
                    Distance    = dist or 99999,
                    State       = r.State or "Slot",
                })
            end
        end
    end

    -- Sort: Highest rarity rank first, then closest distance
    table.sort(farmableList, function(a, b)
        if a.Rank ~= b.Rank then
            return a.Rank > b.Rank
        end
        return a.Distance < b.Distance
    end)


    if #farmableList == 0 then
        if not emptyNoticeLabel then
            emptyNoticeLabel = Instance.new("TextLabel")
            emptyNoticeLabel.Name = "EmptyNotice"
            emptyNoticeLabel.Size = UDim2.new(1, -20, 0, 70)
            emptyNoticeLabel.Position = UDim2.new(0, 10, 0, 20)
            emptyNoticeLabel.BackgroundTransparency = 1
            emptyNoticeLabel.Text = "No farmable eggs match current filter criteria.\n(Adjust Rarity, Biome, or Egg filters, or wait for 5m spawn)"
            emptyNoticeLabel.TextColor3 = Color3.fromRGB(140, 160, 190)
            emptyNoticeLabel.TextSize = 12
            emptyNoticeLabel.Font = Enum.Font.Gotham
            emptyNoticeLabel.TextWrapped = true
            emptyNoticeLabel.Parent = eggListScroll
        end
        emptyNoticeLabel.Visible = true

        for _, item in ipairs(cardPool) do
            item.card.Visible = false
        end
        return
    end

    if emptyNoticeLabel then
        emptyNoticeLabel.Visible = false
    end

    -- Update pooled cards without DOM destruction
    for idx, itemData in ipairs(farmableList) do
        local poolItem = getOrCreateCard(idx)
        poolItem.data = itemData

        local stateTag = itemData.State == "Dropped" and " [DROPPED]" or ""
        local distText = itemData.Distance < 90000 and string.format(" • %dm", math.floor(itemData.Distance)) or ""
        local rarColor = RARITY_COLORS[itemData.Rarity] or Color3.fromRGB(150, 150, 150)

        local subText = itemData.Biome .. " • " .. itemData.Rarity .. stateTag .. distText
        if poolItem.nameLabel.Text ~= itemData.DisplayName then
            poolItem.nameLabel.Text = itemData.DisplayName
        end
        if poolItem.subLabel.Text ~= subText then
            poolItem.subLabel.Text = subText
            poolItem.subLabel.TextColor3 = rarColor
            poolItem.accent.BackgroundColor3 = rarColor
        end
        if not poolItem.card.Visible then
            poolItem.card.Visible = true
        end
    end

    -- Hide any extra pooled cards beyond active count
    for idx = #farmableList + 1, #cardPool do
        cardPool[idx].card.Visible = false
    end
end

-- ============================================================================
-- HALLOWEEN DIMENSION LIVE EGG LIST (ISOLATED MODULE - NO PICKUP LOGIC)
-- ============================================================================

local function getHwEggPos(eggInst)
    if not eggInst then return nil end
    local hitbox = eggInst:FindFirstChild("Hitbox")
    if hitbox and hitbox:IsA("BasePart") then return hitbox.Position end
    if eggInst.PrimaryPart then return eggInst.PrimaryPart.Position end
    local ok, p = pcall(function() return eggInst:GetPivot().Position end)
    if ok and p then return p end
    local bp = eggInst:FindFirstChildWhichIsA("BasePart")
    return bp and bp.Position or nil
end

local function resolveCanonicalHwName(raw)
    if not raw or raw == "" then return nil end
    local s = tostring(raw)
    local info = (getSpeciesInfo and getSpeciesInfo(s, "Halloween")) or (getSpeciesInfo and getSpeciesInfo(s))
    if info and info.DisplayName then
        return info.DisplayName
    end
    local lower = s:lower()
    if lower == "halloween egg" or lower == "halloween" or lower == "hooded gerbil" or lower == "halloweenegg" then
        return "Hooded Gerbil Egg"
    end
    if lower == "rotshroom" or lower == "rotshroom egg" or lower == "toadstool" then
        return "Toadstool Egg"
    end
    if lower == "quilted imp" or lower == "quilted imp egg" or lower == "patchwork imp" then
        return "Patchwork Imp Egg"
    end
    if not lower:find("egg") then
        return s .. " Egg"
    end
    return s
end

-- The resolver below walks attributes, children and descendants, so cache its
-- answer per model. Weak keys: a recycled egg model does not pin memory.
local hwTemplateSignatures = nil
local function getTemplateSignatures()
    if hwTemplateSignatures then return hwTemplateSignatures end
    pcall(function()
        local eggAssets = ReplicatedStorage:FindFirstChild("Assets")
            and ReplicatedStorage.Assets:FindFirstChild("Models")
            and ReplicatedStorage.Assets.Models:FindFirstChild("Eggs")
        if not eggAssets then return end
        local sigs = {}
        for _, tModel in ipairs(eggAssets:GetChildren()) do
            if tModel:IsA("Model") then
                local childrenSet = {}
                for _, tc in ipairs(tModel:GetChildren()) do
                    childrenSet[tc.Name:lower()] = true
                end
                table.insert(sigs, { Name = tModel.Name, Children = childrenSet })
            end
        end
        if #sigs > 0 then
            hwTemplateSignatures = sigs
        end
    end)
    return hwTemplateSignatures
end

local function resolveHwEggName(eggInst)
    -- 1. Check direct attributes: PreparedSourceName is the primary live attribute
    local srcName = eggInst:GetAttribute("PreparedSourceName")
        or eggInst:GetAttribute("DisplayName")
        or eggInst:GetAttribute("EggName")
        or eggInst:GetAttribute("EggType")
        or eggInst:GetAttribute("Species")
        or eggInst:GetAttribute("Name")

    if srcName and tostring(srcName) ~= "" and tostring(srcName):lower() ~= "egg" then
        local resolved = resolveCanonicalHwName(srcName)
        if resolved then return resolved end
    end

    local hitbox = eggInst:FindFirstChild("Hitbox")
    if hitbox then
        local hbAttr = hitbox:GetAttribute("PreparedSourceName")
            or hitbox:GetAttribute("DisplayName")
            or hitbox:GetAttribute("EggName")
            or hitbox:GetAttribute("EggType")
            or hitbox:GetAttribute("Species")
        if hbAttr and tostring(hbAttr) ~= "" and tostring(hbAttr):lower() ~= "egg" then
            local resolved = resolveCanonicalHwName(hbAttr)
            if resolved then return resolved end
        end
    end

    -- 2. Check child string values
    for _, ch in ipairs(eggInst:GetChildren()) do
        if ch:IsA("StringValue") and ch.Value ~= "" and ch.Value:lower() ~= "egg" then
            local resolved = resolveCanonicalHwName(ch.Value)
            if resolved then return resolved end
        end
    end

    -- 3. Check child model names
    for _, ch in ipairs(eggInst:GetChildren()) do
        if ch:IsA("Model") and ch.Name ~= "Model" and ch.Name ~= "Hitbox" and ch.Name:lower() ~= "egg" then
            local resolved = resolveCanonicalHwName(ch.Name)
            if resolved then return resolved end
        end
    end

    -- 4. Check ProximityPrompt text on model for explicit species keywords
    local prMatch = nil
    pcall(function()
        for _, d in ipairs(eggInst:GetDescendants()) do
            if d:IsA("ProximityPrompt") then
                local txt = (d.ObjectText or "") .. " " .. (d.ActionText or "")
                for cleanName, rec in pairs(SPECIES_INFO) do
                    if cleanName ~= "egg" and cleanName ~= "halloween" and cleanName ~= "halloweenegg" then
                        if rec.DisplayName and txt:lower():find(cleanName, 1, true) then
                            prMatch = rec.DisplayName
                            break
                        end
                    end
                end
                if prMatch then break end
            end
        end
    end)
    if prMatch then
        return resolveCanonicalHwName(prMatch)
    end

    -- 5. If model is standard HalloweenEgg or Halloween Egg, it represents Hooded Gerbil Egg
    if eggInst.Name == "HalloweenEgg" or eggInst.Name == "Halloween Egg" then
        return "Hooded Gerbil Egg"
    end

    -- 6. Speculative template match against ReplicatedStorage.Assets.Models.Eggs ONLY for unnamed/generic models
    local okMatch, matchedName = pcall(function()
        local sigs = getTemplateSignatures()
        if not sigs then return nil end
        local liveChildren = {}
        local genericPartNames = {
            hitbox = true, part = true, meshpart = true, model = true,
            basepart = true, weld = true, weldconstraint = true,
            pointlight = true, attachment = true, eggradius = true,
            egggrip = true, eggglow = true, eggrootweld = true
        }
        for _, c in ipairs(eggInst:GetChildren()) do
            local cLower = c.Name:lower()
            if not genericPartNames[cLower] and not cLower:find("^cube%.") then
                liveChildren[cLower] = true
            end
        end
        local nonGenericCount = 0
        for _ in pairs(liveChildren) do nonGenericCount = nonGenericCount + 1 end
        if nonGenericCount == 0 then return nil end

        local bestName, bestCount = nil, 0
        for _, sig in ipairs(sigs) do
            local matchCount = 0
            for childName in pairs(sig.Children) do
                if liveChildren[childName] then matchCount = matchCount + 1 end
            end
            if matchCount > bestCount then
                bestCount = matchCount
                bestName = sig.Name
            end
        end
        return (bestCount >= 2) and bestName or nil
    end)
    if okMatch and matchedName then
        return resolveCanonicalHwName(matchedName)
    end

    return resolveCanonicalHwName(eggInst.Name) or eggInst.Name
end

local function getHwEggName(eggInst)
    if not eggInst then return "Hooded Gerbil Egg" end

    local eng = halloweenEngine
    local cache = eng and eng.nameCache
    local srcAttr = eggInst:GetAttribute("PreparedSourceName")
    if cache then
        local hit = cache[eggInst]
        if hit and hit.src == srcAttr then return hit.name end
    end

    local name = resolveHwEggName(eggInst)
    if cache then
        cache[eggInst] = { src = srcAttr, name = name }
    end
    return name
end

local function getHwEggColor(eggInst, eggDisplayName)
    local n = eggDisplayName and eggDisplayName:lower() or eggInst.Name:lower()
    local info = SPECIES_INFO[n] or (getSpeciesInfo and getSpeciesInfo(n))
    if info and info.IsCataloged == true and info.Rarity and RARITY_COLORS[info.Rarity] then
        return RARITY_COLORS[info.Rarity]
    end
    local glow = eggInst:FindFirstChild("Hitbox", true)
    local light = glow and glow:FindFirstChildOfClass("PointLight")
    if light then return light.Color end
    return Color3.fromRGB(230, 115, 30)
end

-- ============================================================================
-- HALLOWEEN ENGINE (MODULAR ARCHITECTURE)
-- ============================================================================
halloweenEngine = {
    dropPos = Vector3.new(-5959.698, -203.718, -7126.994),
    safeZone = Vector3.new(-5963.824, -203.718, -7274.822),
    autoFarmEnabled = false,
    autoFarmToken = 0,
    nightResetTriggered = false,
    nightResetGraceUntil = nil,
    lastNightResetAt = nil,
    -- Rarity bucket for eggs that are not in the catalog yet.
    newRarity = "New Update",
    -- model -> { src, name }; avoids re-resolving names on every render/scan.
    nameCache = setmetatable({}, { __mode = "k" }),
    -- live-list render throttle state
    hwListDirty = true,
    hwLastRenderAt = 0,
    hwRenderEvery = 1.0,
    hwHookedFolder = nil,

    triggerNightReset = function(duration)
        local now = os.clock()
        -- Debounce: strictly one-time reset per 5-min night cycle (45s cooldown)
        if halloweenEngine.lastNightResetAt and (now - halloweenEngine.lastNightResetAt < 45.0) then
            return
        end
        local grace = duration or 12.0
        halloweenEngine.nightResetTriggered = true
        halloweenEngine.lastNightResetAt = now
        halloweenEngine.nightResetGraceUntil = now + grace
        halloweenEngine.cachedWorldEggs = nil
        if halloweenEngine.nameCache then
            table.clear(halloweenEngine.nameCache)
        end
        lastCarryingCheck = 0
        if halloweenEngine.fishing then
            halloweenEngine.fishing.needsRecovery = true
            -- Drop cached remotes so they are resolved again on the next cycle.
            halloweenEngine.fishing.reHold, halloweenEngine.fishing.rfCast, halloweenEngine.fishing.rfReel = nil, nil, nil
            if halloweenEngine.fishing.running then
                halloweenEngine.fishing.stop("Night Reset")
            end
        end
        if halloweenEngine.autoFarmEnabled and lblFarmStatus then
            lblFarmStatus.Text = string.format("Status: Night Reset (Spawning %.1fs/16s)...", grace)
            lblFarmStatus.TextColor3 = Color3.fromRGB(255, 215, 0)
        end
    end,

    isNightResetActive = function()
        if halloweenEngine.nightResetGraceUntil and (os.clock() < halloweenEngine.nightResetGraceUntil) then
            return true, math.max(0, halloweenEngine.nightResetGraceUntil - os.clock())
        end
        if halloweenEngine.nightResetGraceUntil and (os.clock() >= halloweenEngine.nightResetGraceUntil) then
            halloweenEngine.nightResetGraceUntil = nil
            halloweenEngine.nightResetTriggered = false
        end
        return false, 0
    end,

    -- Sub-module: auto farm (Divine -> Eternal -> Secret priority; finishes when no eggs match filter)
    autoFarm = {
        -- Watchdog: last time a farm cycle started. The cycle chain is a set of
        -- delayed callbacks, so this is the only reliable sign that it is alive.
        lastCycleAt = 0,
        watchdogEvery = 2.0,
        watchdogStall = 75.0,
        findTarget = function()
            local charPos = nil
            pcall(function()
                local ch = LocalPlayer and LocalPlayer.Character
                local root = ch and ch:FindFirstChild("HumanoidRootPart")
                if root then charPos = root.Position end
            end)

            local rawEggModels = {}
            local seenModels = {}

            local function addEggCandidate(egg)
                if egg and not seenModels[egg] then
                    seenModels[egg] = true
                    table.insert(rawEggModels, egg)
                end
            end

            pcall(function()
                local worldEggs = halloweenEngine and halloweenEngine.cachedWorldEggs
                if not (worldEggs and worldEggs.Parent) then
                    local hw = Workspace:FindFirstChild("HalloweenDimension")
                    worldEggs = hw and hw:FindFirstChild("WorldEggs")
                    if not worldEggs then
                        worldEggs = Workspace:FindFirstChild("WorldEggs")
                    end
                    if halloweenEngine then
                        halloweenEngine.cachedWorldEggs = worldEggs
                    end
                end
                if worldEggs then
                    for _, egg in ipairs(worldEggs:GetChildren()) do
                        addEggCandidate(egg)
                    end
                end

                local tagged = CollectionService:GetTagged("HalloweenWorldEgg")
                if tagged then
                    for _, egg in ipairs(tagged) do
                        addEggCandidate(egg)
                    end
                end
            end)

            local candidates = {}
            local scanned = 0
            for _, egg in ipairs(rawEggModels) do
                local entry = halloweenEngine.classifyEgg(egg, charPos)
                if entry then
                    scanned = scanned + 1
                    if halloweenEngine.rarityMatches(entry.Rarity) then
                        table.insert(candidates, entry)
                    end
                end
            end

            -- Second return value lets callers tell "no eggs on the map" apart from
            -- "eggs exist but the rarity filter excludes all of them".
            local stats = { scanned = scanned, matched = #candidates }
            if #candidates == 0 then
                return nil, stats
            end

            -- Priority order: Highest Rarity Rank (Divine: 10 -> Eternal: 9 -> Secret: 8), then closest distance
            table.sort(candidates, function(a, b)
                if a.Rank ~= b.Rank then
                    return a.Rank > b.Rank
                end
                if a.Distance ~= b.Distance then
                    return a.Distance < b.Distance
                end
                return tostring(a.Uid) < tostring(b.Uid)
            end)

            return candidates[1], stats
        end,

        start = function()
            -- Keep manual fishing and auto-farm fishing from launching separate loops.
            if halloweenEngine.fishing and halloweenEngine.fishing.enabled then
                halloweenEngine.fishing.stop("Auto Farm Started")
            end
            halloweenEngine.autoFarmEnabled = true
            halloweenEngine.autoFarmToken = (halloweenEngine.autoFarmToken or 0) + 1
            local currentToken = halloweenEngine.autoFarmToken

            if hwAutoFarmBtn then
                hwAutoFarmBtn.Text = "ON"
                hwAutoFarmBtn.BackgroundColor3 = Color3.fromRGB(35, 135, 75)
                hwAutoFarmBtn.TextColor3 = Color3.new(1, 1, 1)
            end
            if hwAutoFishBtn then
                hwAutoFishBtn.Text = "AUTO"
                hwAutoFishBtn.BackgroundColor3 = Color3.fromRGB(45, 90, 135)
                hwAutoFishBtn.TextColor3 = Color3.new(1, 1, 1)
            end
            if lblFarmStatus then
                local inGrace, remaining = halloweenEngine.isNightResetActive()
                if inGrace then
                    lblFarmStatus.Text = string.format("Status: Night Reset (Spawning %.1fs/15s)...", remaining)
                    lblFarmStatus.TextColor3 = Color3.fromRGB(255, 215, 0)
                else
                    lblFarmStatus.Text = "Status: Scanning Eggs..."
                    lblFarmStatus.TextColor3 = Color3.fromRGB(80, 210, 120)
                end
            end

            task.spawn(function()
                halloweenEngine.autoFarm.runNextCycle(currentToken)
            end)

            -- Belt and braces: if any future path strands the chain (an error in a
            -- delayed callback, a walk with no failure branch, ...) restart it
            -- instead of leaving the farm idle until the user notices.
            task.spawn(function()
                local farm = halloweenEngine.autoFarm
                while halloweenEngine.autoFarmEnabled and halloweenEngine.autoFarmToken == currentToken do
                    task.wait(farm.watchdogEvery or 2.0)
                    if not (halloweenEngine.autoFarmEnabled and halloweenEngine.autoFarmToken == currentToken) then
                        break
                    end
                    local idleFor = os.clock() - (farm.lastCycleAt or 0)
                    if idleFor > (farm.watchdogStall or 75.0) then
                        farm.lastCycleAt = os.clock()
                        print(string.format("[EggGoTo v11] Auto farm watchdog: no cycle for %.0fs (status: %s), restarting.",
                            idleFor, tostring(lblFarmStatus and lblFarmStatus.Text or "?")))
                        pcall(stopWalking)
                        hwPickupToken = (hwPickupToken or 0) + 1
                        task.spawn(function()
                            pcall(farm.runNextCycle, currentToken)
                        end)
                    end
                end
            end)
        end,

        stop = function(reason)
            halloweenEngine.autoFarmEnabled = false
            halloweenEngine.autoFarmToken = (halloweenEngine.autoFarmToken or 0) + 1

            if hwAutoFarmBtn then
                hwAutoFarmBtn.Text = "OFF"
                hwAutoFarmBtn.BackgroundColor3 = Color3.fromRGB(45, 50, 65)
                hwAutoFarmBtn.TextColor3 = Color3.fromRGB(180, 190, 210)
            end
            if lblFarmStatus then
                lblFarmStatus.Text = (reason and reason:find("Done")) and ("Status: " .. reason) or "Status: Idle (Placeholder)"
                lblFarmStatus.TextColor3 = Color3.fromRGB(150, 160, 180)
            end

            if halloweenEngine.fishing and (halloweenEngine.fishing.running or halloweenEngine.fishing.enabled or halloweenEngine.fishing.autoCycleActive) then
                halloweenEngine.fishing.stop("Auto Farm Stopped")
            end
            if hwAutoFishBtn then
                hwAutoFishBtn.Text = "OFF"
                hwAutoFishBtn.BackgroundColor3 = Color3.fromRGB(45, 50, 65)
                hwAutoFishBtn.TextColor3 = Color3.fromRGB(180, 190, 210)
            end

            stopWalking()
        end,

        runNextCycle = function(token)
            if not halloweenEngine.autoFarmEnabled or halloweenEngine.autoFarmToken ~= token then
                return
            end
            halloweenEngine.autoFarm.lastCycleAt = os.clock()

            local inGrace, remaining = halloweenEngine.isNightResetActive()
            if inGrace then
                if halloweenEngine.fishing and halloweenEngine.fishing.running then
                    halloweenEngine.fishing.stop("Night Reset")
                end
                if lblFarmStatus then
                    lblFarmStatus.Text = string.format("Status: Night Reset (Spawning %.1fs/15s)...", remaining)
                    lblFarmStatus.TextColor3 = Color3.fromRGB(255, 215, 0)
                end
                task.delay(0.5, function()
                    if not halloweenEngine.autoFarmEnabled or halloweenEngine.autoFarmToken ~= token then
                        return
                    end
                    halloweenEngine.autoFarm.runNextCycle(token)
                end)
                return
            end

            -- A night reset respawns the character. Starting a cycle while there is
            -- no living body makes every walk below wait on a corpse and, before
            -- onFail existed, stranded the whole farm until the user pressed OFF/ON.
            local charNow = LocalPlayer and LocalPlayer.Character
            local humNow = charNow and charNow:FindFirstChildOfClass("Humanoid")
            local rootNow = charNow and charNow:FindFirstChild("HumanoidRootPart")
            if not (humNow and rootNow and humNow.Health > 0) then
                if lblFarmStatus then
                    lblFarmStatus.Text = "Status: Waiting for character to respawn..."
                    lblFarmStatus.TextColor3 = Color3.fromRGB(220, 180, 70)
                end
                task.delay(0.25, function()
                    if not halloweenEngine.autoFarmEnabled or halloweenEngine.autoFarmToken ~= token then
                        return
                    end
                    halloweenEngine.autoFarm.runNextCycle(token)
                end)
                return
            end

            -- 1. Auto Farm: check for target egg matching rarity filter
            local targetEgg, scan = halloweenEngine.autoFarm.findTarget()
            if targetEgg then
                if halloweenEngine.fishing and halloweenEngine.fishing.running then
                    halloweenEngine.fishing.stop("Egg Detected")
                end

                if lblFarmStatus then
                    lblFarmStatus.Text = string.format("Status: [%s] %s", targetEgg.Rarity or "Egg", targetEgg.Name)
                    lblFarmStatus.TextColor3 = Color3.fromRGB(80, 210, 120)
                end

                halloweenEngine.tpAction(targetEgg, function(success)
                    if not halloweenEngine.autoFarmEnabled or halloweenEngine.autoFarmToken ~= token then
                        return
                    end

                    task.delay(0.5, function()
                        if not halloweenEngine.autoFarmEnabled or halloweenEngine.autoFarmToken ~= token then
                            return
                        end
                        halloweenEngine.autoFarm.runNextCycle(token)
                    end)
                end)
                return
            end

            -- 2. No target egg: Wait 3s before transitioning to continuous fishing
            -- Distinguish "nothing on the map" from "everything is filtered out", otherwise
            -- the farm reports "done" while the live list still shows farmable-looking eggs.
            local scanned = scan and scan.scanned or 0
            if lblFarmStatus then
                if scanned > 0 then
                    lblFarmStatus.Text = string.format("Status: %d egg(s) in world, none match filter - fishing", scanned)
                else
                    lblFarmStatus.Text = "Status: Waiting 3s before fishing..."
                end
                lblFarmStatus.TextColor3 = Color3.fromRGB(220, 180, 70)
            end
            if halloweenEngine.fishing and halloweenEngine.fishing.log then
                if scanned > 0 then
                    halloweenEngine.fishing.log(string.format(
                        "Auto Farm phase done: %d egg(s) in world but none match the rarity filter. Waiting 3s, then Auto Fishing...", scanned))
                else
                    halloweenEngine.fishing.log("Auto Farm phase done (no matching eggs). Waiting 3s, then Auto Fishing...")
                end
            end

            task.spawn(function()
                local elapsed = 0
                while elapsed < 3.0 do
                    task.wait(0.5)
                    elapsed = elapsed + 0.5
                    if not halloweenEngine.autoFarmEnabled or halloweenEngine.autoFarmToken ~= token then
                        return
                    end
                    local inG, _ = halloweenEngine.isNightResetActive()
                    if inG then
                        halloweenEngine.autoFarm.runNextCycle(token)
                        return
                    end
                    local earlyEgg = halloweenEngine.autoFarm.findTarget()
                    if earlyEgg then
                        halloweenEngine.autoFarm.runNextCycle(token)
                        return
                    end
                end

                -- 3. Transition to Continuous Fishing until Night Reset!
                if not halloweenEngine.autoFarmEnabled or halloweenEngine.autoFarmToken ~= token then
                    return
                end

                if lblFarmStatus then
                    lblFarmStatus.Text = "Status: Auto Fishing (Until Night Reset)"
                    lblFarmStatus.TextColor3 = Color3.fromRGB(100, 200, 255)
                end
                if halloweenEngine.fishing and halloweenEngine.fishing.log then
                    halloweenEngine.fishing.log("Auto Fishing phase started; will return to Auto Farm at Night Reset.")
                end

                if halloweenEngine.fishing then
                    halloweenEngine.fishing.runAutoCycle(token)
                end
            end)
        end,
    },

    -- Sub-module: auto fishing (Halloween bank stand spot & water target)
    fishing = {
        enabled = false,
        token = 0,
        running = false,
        cycleBusy = false,
        autoCycleActive = false,
        catchCount = 0,
        cycleCount = 0,
        logLines = {},
        spotPos = Vector3.new(-5695.6, -203.7, -7370.9),
        castPos = Vector3.new(-5668.5, -206.5, -7368.9),
        rodName = "Haunted Rod [X1]",
        holdDelay = 0.40,
        powerMin = 0.72,
        powerMax = 0.90,
        extraWait = 1.10,
        cyclePause = 0.40,
        clicks = 13,
        maxRetries = 2,

        reHold = nil,
        rfCast = nil,
        rfReel = nil,
        -- Set by triggerNightReset; forces one full rod/remote reset before the
        -- next cast, because an interrupted cycle leaves both sides out of sync.
        needsRecovery = false,
        -- Id of a cast that was never reeled (cycle cancelled by a night reset).
        -- The server keeps that session open and answers the next Cast with
        -- nil + "Hold on..." until it is closed.
        pendingFishId = nil,
        castMaxAttempts = 4,

        logDirty = false,
        logFlushedAt = -1,
        refreshLog = function()
            local f = halloweenEngine.fishing
            if not f.logDirty then return end
            f.logDirty = false
            f.logFlushedAt = os.clock()
            if not (screenGui and screenGui.Parent and main and main.Visible and tabHalloween and tabHalloween.Visible and hwLogLabel and hwLogLabel.Parent) then return end
            pcall(function()
                local fullText = table.concat(f.logLines, "\n")
                if hwLogLabel.Text ~= fullText then
                    hwLogLabel.Text = fullText
                end
                local sc = hwLogLabel.Parent
                if sc and sc:IsA("ScrollingFrame") then
                    sc.CanvasPosition = Vector2.new(0, 99999)
                end
            end)
        end,

        log = function(msg)
            local line = os.date("%H:%M:%S") .. " " .. tostring(msg)
            table.insert(halloweenEngine.fishing.logLines, line)
            if #halloweenEngine.fishing.logLines > 50 then
                table.remove(halloweenEngine.fishing.logLines, 1)
            end
            local f = halloweenEngine.fishing
            f.logDirty = true
            if (os.clock() - (f.logFlushedAt or -1)) >= 1.0 then
                f.refreshLog()
            end
        end,

        getRemote = function(name)
            local f = halloweenEngine.fishing
            if f and f.remoteCache and f.remoteCache[name] then
                local cached = f.remoteCache[name]
                if cached.Parent then return cached end
            end
            local net = ReplicatedStorage:FindFirstChild("Packages")
                and ReplicatedStorage.Packages:FindFirstChild("Networking")
            if net then
                local r = net:FindFirstChild(name)
                if r then
                    if f then
                        if not f.remoteCache then f.remoteCache = {} end
                        f.remoteCache[name] = r
                    end
                    return r
                end
            end
            local found = ReplicatedStorage:FindFirstChild(name, true)
            if not found then
                pcall(function()
                    for _, d in ipairs(ReplicatedStorage:GetDescendants()) do
                        if d.Name == name or d.Name:lower() == name:lower() then
                            found = d
                            break
                        end
                    end
                end)
            end
            if found and f then
                if not f.remoteCache then f.remoteCache = {} end
                f.remoteCache[name] = found
            end
            return found
        end,

        initRemotes = function()
            if not halloweenEngine.fishing.reHold then
                halloweenEngine.fishing.reHold = halloweenEngine.fishing.getRemote("RE/Fishing/Hold")
            end
            if not halloweenEngine.fishing.rfCast then
                halloweenEngine.fishing.rfCast = halloweenEngine.fishing.getRemote("RF/Fishing/Cast")
            end
            if not halloweenEngine.fishing.rfReel then
                halloweenEngine.fishing.rfReel = halloweenEngine.fishing.getRemote("RF/Fishing/Reel")
            end
        end,

        findRod = function()
            -- Match only the configured rod name. Substring matches like "rod" or "fish"
            -- can select unrelated tools, so they are deliberately not accepted.
            local expectedName = halloweenEngine.fishing.rodName:lower()
            local char = LocalPlayer and LocalPlayer.Character
            if char then
                for _, t in ipairs(char:GetChildren()) do
                    if t:IsA("Tool") and t.Name:lower() == expectedName then
                        return t, true
                    end
                end
            end
            local bp = LocalPlayer and LocalPlayer:FindFirstChild("Backpack")
            if bp then
                for _, t in ipairs(bp:GetChildren()) do
                    if t:IsA("Tool") and t.Name:lower() == expectedName then
                        return t, false
                    end
                end
            end
            return nil, false
        end,

        -- A cast whose reel never returned true stays open on the server, and every
        -- following Cast is answered with nil + "Hold on...". Close it explicitly.
        -- Keep the id until the server confirms, so a rejected close is retried.
        closePendingCast = function()
            local f = halloweenEngine.fishing
            if not f.pendingFishId then return false end
            local rfReel = f.rfReel or f.getRemote("RF/Fishing/Reel")
            if not rfReel then return false end

            local id = f.pendingFishId
            local closed = false
            -- "Caught" closes an interrupted (still biting) cast; "Cancel" is the
            -- fallback for a cast whose reel was already rejected.
            for _, action in ipairs({ "Caught", "Cancel" }) do
                local ok, res = pcall(function()
                    return rfReel:InvokeServer(id, action, f.clicks)
                end)
                f.log(string.format("Closing pending cast Id=%s (%s) -> ok=%s res=%s",
                    tostring(id), action, tostring(ok), tostring(res)))
                if ok and res == true then
                    closed = true
                    break
                end
            end

            if closed then
                f.pendingFishId = nil
            else
                f.log(string.format("Pending cast Id=%s could not be closed; will retry", tostring(id)))
            end
            return closed
        end,

        -- Reset everything that a night reset can invalidate: cached remote refs
        -- (a re-streamed RemoteFunction never answers again), rod equip state and
        -- distance to the fishing spot. Call before casting after a reset, and
        -- once as a retry path when Cast returns nil.
        recoverRodState = function(cancelCheck, skipHold)
            local f = halloweenEngine.fishing
            f.reHold, f.rfCast, f.rfReel = nil, nil, nil
            f.initRemotes()

            -- Close a cast left open by the interrupted cycle; otherwise the server
            -- keeps answering Cast with nil + "Hold on...".
            f.closePendingCast()

            f.walkToSpot(cancelCheck)

            local ch = LocalPlayer and LocalPlayer.Character
            local hum = ch and ch:FindFirstChildOfClass("Humanoid")
            if hum then
                pcall(function() hum:UnequipTools() end)
                task.wait(0.2)
            end
            f.ensureRodEquipped()
            f.faceTarget()

            if not skipHold then
                local reHold = f.reHold or f.getRemote("RE/Fishing/Hold")
                if reHold then
                    pcall(function() reHold:FireServer() end)
                end
                task.wait(f.holdDelay)
            end
        end,

        ensureRodEquipped = function()
            local rod, alreadyInHand = halloweenEngine.fishing.findRod()
            local char = LocalPlayer and LocalPlayer.Character
            if not rod then
                local foundTools = {}
                local bp = LocalPlayer and LocalPlayer:FindFirstChild("Backpack")
                if char then
                    for _, item in ipairs(char:GetChildren()) do
                        if item:IsA("Tool") then table.insert(foundTools, item.Name) end
                    end
                end
                if bp then
                    for _, item in ipairs(bp:GetChildren()) do
                        if item:IsA("Tool") then table.insert(foundTools, item.Name) end
                    end
                end
                halloweenEngine.fishing.log("Required rod not found: exact name '" .. halloweenEngine.fishing.rodName .. "'. Available tools: " .. (#foundTools > 0 and table.concat(foundTools, ", ") or "none"))
                return false
            end
            if alreadyInHand then return true end
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            if not hum then
                halloweenEngine.fishing.log("Cannot equip required rod: character Humanoid not found.")
                return false
            end
            if hum.Sit then hum.Sit = false end
            local equipOk, equipErr = pcall(function() hum:EquipTool(rod) end)
            task.wait(0.25)
            local equipped = equipOk and rod.Parent == char and rod.Name:lower() == halloweenEngine.fishing.rodName:lower()
            if equipped then
                halloweenEngine.fishing.log("Equipped required rod: " .. rod.Name)
            else
                halloweenEngine.fishing.log("ERROR: Failed to equip required rod '" .. halloweenEngine.fishing.rodName .. "'" .. (equipOk and ". Tool did not move into Character." or (": " .. tostring(equipErr))))
            end
            return equipped
        end,

        walkToSpot = function(cancelCheck)
            local char = LocalPlayer and LocalPlayer.Character
            local root = char and char:FindFirstChild("HumanoidRootPart")
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            if not (char and root and hum) then return false end

            local target = halloweenEngine.fishing.spotPos
            local curDist = Vector3.new(root.Position.X - target.X, 0, root.Position.Z - target.Z).Magnitude
            if curDist <= 4.0 then return true end

            if hum.Sit then hum.Sit = false end
            if hum.PlatformStand then hum.PlatformStand = false end

            local t0 = os.clock()
            local lastP = nil
            local stuckCount = 0
            while (os.clock() - t0) < 35.0 do
                if not (LocalPlayer and LocalPlayer.Character and root.Parent and hum.Health > 0) then break end
                if cancelCheck and cancelCheck() then break end

                local p = root.Position
                local d = Vector3.new(p.X - target.X, 0, p.Z - target.Z).Magnitude
                if d <= 3.5 then
                    pcall(function()
                        root.AssemblyLinearVelocity = Vector3.zero
                        hum:Move(Vector3.zero, false)
                        hum.WalkToPoint = root.Position
                    end)
                    return true
                end

                pcall(function() hum:MoveTo(target) end)

                if lastP and Vector3.new(p.X - lastP.X, 0, p.Z - lastP.Z).Magnitude < 0.4 then
                    stuckCount = stuckCount + 1
                    if stuckCount >= 5 then
                        stuckCount = 0
                        pcall(function() hum.Jump = true end)
                    end
                else
                    stuckCount = 0
                end
                lastP = p
                task.wait(0.1)
            end

            pcall(function()
                if root then root.AssemblyLinearVelocity = Vector3.zero end
                if hum then hum:Move(Vector3.zero, false) end
            end)
            return (root and Vector3.new(root.Position.X - target.X, 0, root.Position.Z - target.Z).Magnitude <= 3.5)
        end,

        faceTarget = function()
            pcall(function()
                local ch = LocalPlayer and LocalPlayer.Character
                local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
                local castP = halloweenEngine.fishing.castPos
                if hrp and castP then
                    hrp.CFrame = CFrame.lookAt(hrp.Position, Vector3.new(castP.X, hrp.Position.Y, castP.Z))
                end
            end)
        end,

        formatReward = function(item)
            if typeof(item) ~= "table" then return tostring(item) end
            local name = item.DisplayName or item.Id or item.Name or "Fish"
            local rarity = item.Rarity or "Unknown"
            local oneIn = item.OneIn and string.format(" (1 in %s)", tostring(item.OneIn)) or ""
            local amount = item.Amount and tonumber(item.Amount) and tonumber(item.Amount) > 1 and string.format(" x%d", item.Amount) or ""
            return string.format("[%s] %s%s%s", rarity, name, amount, oneIn)
        end,

        _executeSingleCycle = function(cancelCheck, onComplete)
            if cancelCheck and cancelCheck() then
                if onComplete then onComplete(false) end
                return
            end

            halloweenEngine.fishing.initRemotes()
            local spot = halloweenEngine.fishing.spotPos
            local castP = halloweenEngine.fishing.castPos

            -- A night reset interrupts Hold/Cast mid-flight; the server then rejects the
            -- next Cast with nil. Reset rod + remote state once before casting again.
            if halloweenEngine.fishing.needsRecovery then
                halloweenEngine.fishing.needsRecovery = false
                halloweenEngine.fishing.log("Night reset detected -> resetting rod & remote state before casting.")
                halloweenEngine.fishing.recoverRodState(cancelCheck, true)
                if cancelCheck and cancelCheck() then
                    if onComplete then onComplete(false) end
                    return
                end
            end

            -- Safety drift check: if bumped > 10 studs away from spot, walk back
            local ch = LocalPlayer and LocalPlayer.Character
            local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
            if hrp then
                local d = Vector3.new(hrp.Position.X - spot.X, 0, hrp.Position.Z - spot.Z).Magnitude
                if d > 10.0 then
                    if lblFishStatus then
                        lblFishStatus.Text = "Status: Returning to spot..."
                        lblFishStatus.TextColor3 = Color3.fromRGB(255, 200, 100)
                    end
                    halloweenEngine.fishing.log(string.format("Drifted %.1f studs, walking back...", d))
                    halloweenEngine.fishing.walkToSpot(cancelCheck)
                    if cancelCheck and cancelCheck() then
                        if onComplete then onComplete(false) end
                        return
                    end
                    halloweenEngine.fishing.faceTarget()
                end
            end

            local rodOk = halloweenEngine.fishing.ensureRodEquipped()
            if not rodOk then
                halloweenEngine.fishing.log("Cycle aborted before Hold/Cast: required rod is not equipped. No other tool will be used.")
                if lblFishStatus then
                    lblFishStatus.Text = "Status: Required rod not equipped"
                    lblFishStatus.TextColor3 = Color3.fromRGB(255, 100, 80)
                end
                if onComplete then onComplete(false) end
                return
            end

            if cancelCheck and cancelCheck() then
                if onComplete then onComplete(false) end
                return
            end

            local cp = hrp and hrp.Position or Vector3.zero
            halloweenEngine.fishing.cycleCount = (halloweenEngine.fishing.cycleCount or 0) + 1
            halloweenEngine.fishing.log(string.format("--- CYCLE #%d Char=(%.1f, %.1f, %.1f) ---",
                halloweenEngine.fishing.cycleCount, cp.X, cp.Y, cp.Z))

            -- 1. Hold
            if lblFishStatus then
                lblFishStatus.Text = "Status: Holding rod..."
                lblFishStatus.TextColor3 = Color3.fromRGB(160, 200, 255)
            end
            local reHold = halloweenEngine.fishing.reHold or halloweenEngine.fishing.getRemote("RE/Fishing/Hold")
            if reHold then
                pcall(function() reHold:FireServer() end)
                halloweenEngine.fishing.log("Hold fired -> waiting 0.40s charge")
            else
                halloweenEngine.fishing.log("WARNING: RE/Fishing/Hold remote not found!")
            end
            task.wait(halloweenEngine.fishing.holdDelay)

            if cancelCheck and cancelCheck() then
                if onComplete then onComplete(false) end
                return
            end

            -- 2. Cast
            local pMin, pMax = halloweenEngine.fishing.powerMin, halloweenEngine.fishing.powerMax
            local power = pMin + math.random() * (pMax - pMin)
            power = math.floor(power * 1000) / 1000

            if lblFishStatus then
                lblFishStatus.Text = string.format("Status: Casting %.3f", power)
                lblFishStatus.TextColor3 = Color3.fromRGB(160, 200, 255)
            end

            local castResults, castOk, castData
            local maxAttempts = halloweenEngine.fishing.castMaxAttempts or 4
            local retryWaits = { 1.0, 2.0, 4.0 }
            for castAttempt = 1, maxAttempts do
                local rfCast = halloweenEngine.fishing.rfCast or halloweenEngine.fishing.getRemote("RF/Fishing/Cast")
                if not rfCast then
                    halloweenEngine.fishing.log("ERROR: RF/Fishing/Cast remote NOT FOUND in ReplicatedStorage!")
                    if lblFishStatus then
                        lblFishStatus.Text = "Status: RF/Fishing/Cast not found"
                        lblFishStatus.TextColor3 = Color3.fromRGB(255, 100, 80)
                    end
                    task.wait(2.0)
                    if onComplete then onComplete(false) end
                    return
                end

                halloweenEngine.fishing.log(string.format("Casting power=%.3f Target=(%.1f, %.1f, %.1f) attempt=%d",
                    power, castP.X, castP.Y, castP.Z, castAttempt))
                -- Pack all InvokeServer results so a nil response can be distinguished
                -- from an exception and logged with the relevant cast context.
                castResults = table.pack(pcall(function()
                    return rfCast:InvokeServer(power, castP)
                end))
                castOk, castData = castResults[1], castResults[2]
                local serverMsg = castResults[3]

                if castOk and type(castData) == "table" and castData.Id then
                    -- Keep the id: if this cycle is cancelled before the reel, the
                    -- server session has to be closed on the next one.
                    halloweenEngine.fishing.pendingFishId = castData.Id
                    break
                end

                if castAttempt >= maxAttempts then
                    break
                end

                local waitFor = retryWaits[math.min(castAttempt, #retryWaits)]
                if halloweenEngine.fishing.pendingFishId and halloweenEngine.fishing.closePendingCast() then
                    -- Session closed: the refusal was caused by it, so do not burn
                    -- the full backoff before trying again.
                    waitFor = 0.25
                end
                if serverMsg ~= nil then
                    -- The server refuses with a reason ("Hold on..."): it is busy,
                    -- not broken. Re-hold and wait longer instead of tearing down
                    -- the rod, and surface the message so it is never lost again.
                    halloweenEngine.fishing.log(string.format(
                        "Cast refused by server (%q) -> re-holding, retry %d/%d in %.1fs",
                        tostring(serverMsg), castAttempt + 1, maxAttempts, waitFor))
                else
                    halloweenEngine.fishing.log(string.format(
                        "Cast returned no fish -> resetting rod state and retrying (%d/%d) in %.1fs",
                        castAttempt + 1, maxAttempts, waitFor))
                end

                if lblFishStatus then
                    lblFishStatus.Text = string.format("Status: Cast busy (retry %d/%d)...", castAttempt + 1, maxAttempts)
                    lblFishStatus.TextColor3 = Color3.fromRGB(255, 200, 100)
                end

                if castAttempt == 1 then
                    -- First miss after a reset: reset rod/remote state once.
                    halloweenEngine.fishing.recoverRodState(cancelCheck, false)
                else
                    -- Later misses are the server still being busy: just re-hold.
                    local reHold = halloweenEngine.fishing.reHold
                        or halloweenEngine.fishing.getRemote("RE/Fishing/Hold")
                    if reHold then pcall(function() reHold:FireServer() end) end
                    task.wait(halloweenEngine.fishing.holdDelay)
                end
                task.wait(waitFor)

                if cancelCheck and cancelCheck() then
                    if onComplete then onComplete(false) end
                    return
                end
            end

            if not castOk then
                halloweenEngine.fishing.log("Cast EXCEPTION -> " .. tostring(castData))
                if lblFishStatus then
                    lblFishStatus.Text = "Status: Cast error: " .. tostring(castData):sub(1, 25)
                    lblFishStatus.TextColor3 = Color3.fromRGB(255, 100, 80)
                end
                task.wait(2.0)
                if onComplete then onComplete(false) end
                return
            end

            if type(castData) ~= "table" or not castData.Id then
                local returnDetails = {}
                for i = 2, castResults.n do
                    table.insert(returnDetails, string.format("%d:%s=%s", i - 1, typeof(castResults[i]), tostring(castResults[i])))
                end
                local returnSummary = #returnDetails > 0 and table.concat(returnDetails, ", ") or "no return values"
                local serverMsg = castResults[3]
                local failReason = serverMsg ~= nil
                    and string.format("server refused: %q", tostring(serverMsg))
                    or (castData == nil and "server returned nil (InvokeServer did not throw)" or "invalid response (missing Id)")
                halloweenEngine.fishing.log(string.format(
                    "Cast FAILED after retry -> %s; returnCount=%d; returns={%s}; power=%.3f; rodEquipped=%s; Char=(%.1f, %.1f, %.1f); Target=(%.1f, %.1f, %.1f)",
                    failReason, math.max(0, castResults.n - 1), returnSummary, power, tostring(rodOk),
                    cp.X, cp.Y, cp.Z, castP.X, castP.Y, castP.Z
                ))
                if lblFishStatus then
                    lblFishStatus.Text = "Status: Cast failed (" .. tostring(castData):sub(1, 20) .. ")"
                    lblFishStatus.TextColor3 = Color3.fromRGB(255, 160, 60)
                end
                task.wait(2.0)
                if onComplete then onComplete(false) end
                return
            end

            -- 3. Wait Bite
            local fishId = castData.Id
            local waitTime = (tonumber(castData.Wait) or 3) + halloweenEngine.fishing.extraWait
            halloweenEngine.fishing.log(string.format("Cast OK -> Id=%s Wait=%.2fs (total=%.2fs)",
                tostring(fishId), tonumber(castData.Wait) or 0, waitTime))

            -- 3. Wait Bite
            if lblFishStatus then
                lblFishStatus.Text = string.format("Status: Waiting bite %.1fs", waitTime)
                lblFishStatus.TextColor3 = Color3.fromRGB(180, 210, 255)
            end

            local waitElapsed = 0
            while waitElapsed < waitTime do
                task.wait(0.25)
                waitElapsed = waitElapsed + 0.25
                if cancelCheck and cancelCheck() then
                    break
                end
            end

            if cancelCheck and cancelCheck() then
                halloweenEngine.fishing.log("Cycle cancelled during bite wait.")
                if onComplete then onComplete(false) end
                return
            end

            -- 4. Reel with retries
            local success = false
            local caughtItem = nil
            local rfReel = halloweenEngine.fishing.rfReel or halloweenEngine.fishing.getRemote("RF/Fishing/Reel")

            if not rfReel then
                halloweenEngine.fishing.log("ERROR: RF/Fishing/Reel remote NOT FOUND!")
                if onComplete then onComplete(false) end
                return
            end

            for attempt = 1, halloweenEngine.fishing.maxRetries + 1 do
                if lblFishStatus then
                    lblFishStatus.Text = attempt > 1 and string.format("Status: Reeling (retry %d)...", attempt - 1) or "Status: Reeling..."
                    lblFishStatus.TextColor3 = Color3.fromRGB(100, 220, 140)
                end

                local res = table.pack(pcall(function()
                    return rfReel:InvokeServer(fishId, "Caught", halloweenEngine.fishing.clicks)
                end))
                local reelOk, ret1, ret2 = res[1], res[2], res[3]

                if reelOk and ret1 == true then
                    success = true
                    caughtItem = ret2
                    local itemText = halloweenEngine.fishing.formatReward(caughtItem)
                    halloweenEngine.fishing.log(string.format("Reel SUCCESS -> %s (Id=%s attempt=%d)", itemText, tostring(fishId), attempt))
                    break
                else
                    halloweenEngine.fishing.log(string.format("Reel attempt %d failed -> ok=%s ret1=%s ret2=%s",
                        attempt, tostring(reelOk), tostring(ret1), tostring(ret2)))
                end

                if attempt <= halloweenEngine.fishing.maxRetries then
                    task.wait(0.25)
                end
            end

            if success then
                halloweenEngine.fishing.pendingFishId = nil
                halloweenEngine.fishing.catchCount = (halloweenEngine.fishing.catchCount or 0) + 1
                local itemText = halloweenEngine.fishing.formatReward(caughtItem)
                if lblFishStatus then
                    lblFishStatus.Text = string.format("Status: Caught #%d %s", halloweenEngine.fishing.catchCount, itemText)
                    lblFishStatus.TextColor3 = Color3.fromRGB(100, 255, 140)
                end
            else
                -- Rejected reel leaves the cast open server-side: keep the id so the
                -- next cycle / cast retry can close it instead of spiralling on
                -- "Hold on...".
                halloweenEngine.fishing.pendingFishId = fishId
                halloweenEngine.fishing.log(string.format(
                    "Reel failed -> cast Id=%s kept pending for close", tostring(fishId)))
                if lblFishStatus then
                    lblFishStatus.Text = "Status: Reel failed after retries"
                    lblFishStatus.TextColor3 = Color3.fromRGB(255, 100, 80)
                end
            end

            task.wait(halloweenEngine.fishing.cyclePause)
            if onComplete then onComplete(success) end
        end,

        runAutoCycle = function(farmToken)
            if halloweenEngine.fishing.autoCycleActive then
                halloweenEngine.fishing.log("Duplicate auto-fishing loop ignored; a loop is already active.")
                return
            end
            halloweenEngine.fishing.autoCycleActive = true
            halloweenEngine.fishing.running = true
            halloweenEngine.fishing.initRemotes()

            local function shouldAbort()
                if not halloweenEngine.autoFarmEnabled or halloweenEngine.autoFarmToken ~= farmToken then
                    return true
                end
                local inGrace, _ = halloweenEngine.isNightResetActive()
                if inGrace then return true end
                return false
            end

            if shouldAbort() then
                halloweenEngine.fishing.running = false
                halloweenEngine.fishing.autoCycleActive = false
                if halloweenEngine.autoFarmEnabled and halloweenEngine.autoFarmToken == farmToken then
                    halloweenEngine.autoFarm.runNextCycle(farmToken)
                end
                return
            end

            local char = LocalPlayer and LocalPlayer.Character
            local root = char and char:FindFirstChild("HumanoidRootPart")
            local curPos = root and root.Position
            local spot = halloweenEngine.fishing.spotPos
            local dist = curPos and Vector3.new(curPos.X - spot.X, 0, curPos.Z - spot.Z).Magnitude or 999
            if dist > 4.0 then
                if lblFishStatus then
                    lblFishStatus.Text = string.format("Status: Walking to spot (%.0fm)...", dist)
                    lblFishStatus.TextColor3 = Color3.fromRGB(255, 200, 100)
                end
                halloweenEngine.fishing.log(string.format("Walking to spot (%.1fm)...", dist))
                halloweenEngine.fishing.walkToSpot(shouldAbort)
                if shouldAbort() then
                    halloweenEngine.fishing.running = false
                    halloweenEngine.fishing.autoCycleActive = false
                    if halloweenEngine.autoFarmEnabled and halloweenEngine.autoFarmToken == farmToken then
                        halloweenEngine.autoFarm.runNextCycle(farmToken)
                    end
                    return
                end
            end

            halloweenEngine.fishing.faceTarget()
            halloweenEngine.fishing.log("At spot. Starting continuous fishing until Night Reset.")

            while halloweenEngine.autoFarmEnabled and halloweenEngine.autoFarmToken == farmToken do
                local inGrace, rem = halloweenEngine.isNightResetActive()
                if inGrace then
                    halloweenEngine.fishing.log(string.format("Night Reset active (%.1fs)! Halting fishing for egg farm.", rem))
                    break
                end

                halloweenEngine.fishing.executeSingleCycle(shouldAbort)

                if shouldAbort() then
                    break
                end
                task.wait(halloweenEngine.fishing.cyclePause)
            end

            halloweenEngine.fishing.running = false
            halloweenEngine.fishing.autoCycleActive = false
            if halloweenEngine.autoFarmEnabled and halloweenEngine.autoFarmToken == farmToken then
                halloweenEngine.fishing.log("Fishing halted -> Handing back to Auto Farm.")
                halloweenEngine.autoFarm.runNextCycle(farmToken)
            end
        end,

        start = function()
            if halloweenEngine.autoFarmEnabled then
                halloweenEngine.fishing.log("Auto Fishing is controlled by Halloween Auto Farm: Auto Farm -> wait 3s -> Auto Fishing.")
                return
            end
            if halloweenEngine.fishing.enabled then
                halloweenEngine.fishing.log("Manual Auto Fishing start ignored; it is already enabled.")
                return
            end
            halloweenEngine.fishing.enabled = true
            halloweenEngine.fishing.token = (halloweenEngine.fishing.token or 0) + 1
            local tok = halloweenEngine.fishing.token

            if hwAutoFishBtn then
                hwAutoFishBtn.Text = "ON"
                hwAutoFishBtn.BackgroundColor3 = Color3.fromRGB(35, 135, 75)
                hwAutoFishBtn.TextColor3 = Color3.new(1, 1, 1)
            end
            if lblFishStatus then
                lblFishStatus.Text = "Status: Starting..."
                lblFishStatus.TextColor3 = Color3.fromRGB(80, 210, 120)
            end
            halloweenEngine.fishing.running = true
            halloweenEngine.fishing.log("Manual Auto Fishing started.")

            task.spawn(function()
                -- Wait for an in-flight auto-farm cycle to finish before starting another one.
                while halloweenEngine.fishing.enabled and halloweenEngine.fishing.token == tok
                    and (halloweenEngine.fishing.cycleBusy or halloweenEngine.fishing.autoCycleActive) do
                    task.wait(0.1)
                end
                if not halloweenEngine.fishing.enabled or halloweenEngine.fishing.token ~= tok then
                    if halloweenEngine.fishing.token == tok then
                        halloweenEngine.fishing.running = false
                    end
                    return
                end
                halloweenEngine.fishing.initRemotes()
                local char = LocalPlayer and LocalPlayer.Character
                local root = char and char:FindFirstChild("HumanoidRootPart")
                local curPos = root and root.Position
                local spot = halloweenEngine.fishing.spotPos
                local dist = curPos and Vector3.new(curPos.X - spot.X, 0, curPos.Z - spot.Z).Magnitude or 999
                if dist > 4.0 then
                    if lblFishStatus then
                        lblFishStatus.Text = string.format("Status: Walking to spot (%.0fm)...", dist)
                        lblFishStatus.TextColor3 = Color3.fromRGB(255, 200, 100)
                    end
                    halloweenEngine.fishing.log(string.format("Walking to spot (%.1fm)...", dist))
                    halloweenEngine.fishing.walkToSpot(function()
                        return not halloweenEngine.fishing.enabled or halloweenEngine.fishing.token ~= tok
                    end)
                end
                halloweenEngine.fishing.faceTarget()
                halloweenEngine.fishing.log("At spot. Starting fishing loop.")

                while halloweenEngine.fishing.enabled and halloweenEngine.fishing.token == tok do
                    halloweenEngine.fishing.executeSingleCycle(function()
                        return not halloweenEngine.fishing.enabled or halloweenEngine.fishing.token ~= tok
                    end)
                    if not halloweenEngine.fishing.enabled or halloweenEngine.fishing.token ~= tok then break end
                    task.wait(halloweenEngine.fishing.cyclePause)
                end
                if halloweenEngine.fishing.token == tok then
                    halloweenEngine.fishing.running = false
                end
            end)
        end,

        stop = function(reason)
            halloweenEngine.fishing.enabled = false
            halloweenEngine.fishing.token = (halloweenEngine.fishing.token or 0) + 1
            halloweenEngine.fishing.running = false

            -- When the Auto Farm is driving fishing, a stop (night reset, egg detected)
            -- is a pause, not a user-facing OFF. Keep the row honest about that.
            local farmDriven = halloweenEngine.autoFarmEnabled == true
            if hwAutoFishBtn then
                if farmDriven then
                    hwAutoFishBtn.Text = "AUTO"
                    hwAutoFishBtn.BackgroundColor3 = Color3.fromRGB(45, 90, 135)
                    hwAutoFishBtn.TextColor3 = Color3.new(1, 1, 1)
                else
                    hwAutoFishBtn.Text = "OFF"
                    hwAutoFishBtn.BackgroundColor3 = Color3.fromRGB(45, 50, 65)
                    hwAutoFishBtn.TextColor3 = Color3.fromRGB(180, 190, 210)
                end
            end
            if lblFishStatus then
                if farmDriven and reason == "Night Reset" then
                    lblFishStatus.Text = "Status: Night Reset (paused, resumes with farm)"
                    lblFishStatus.TextColor3 = Color3.fromRGB(255, 215, 0)
                else
                    lblFishStatus.Text = reason and ("Status: " .. reason) or "Status: Idle"
                    lblFishStatus.TextColor3 = Color3.fromRGB(150, 160, 180)
                end
            end
            halloweenEngine.fishing.log("Auto Fishing stopped: " .. tostring(reason or "Manual"))
        end,
    },

    -- Sub-module: other feature (modular extension hook)
    other = {
        name = "HalloweenFeatureExtensions",
        version = "1.0",
    },
}

-- Single source of truth for "is this a Halloween egg the panel can show/farm".
-- Both renderHalloweenEggs and autoFarm.findTarget classify through here, so the
-- list can never show an egg that the farm refuses to target.
halloweenEngine.classifyEgg = function(egg, charPos)
    if not egg or egg.Name:lower():find("holder") then return nil end
    if egg:GetAttribute("HalloweenEggCanPickUp") == false then return nil end

    local p = getHwEggPos(egg)
    if not p then return nil end

    local eggName = getHwEggName(egg)
    local lowerName = eggName:lower()
    if lowerName:find("holder") then return nil end
    -- Placeholder models named "Egg"/"Halloween Egg" carry no species information
    if lowerName == "egg" or lowerName == "halloween egg" or lowerName == "halloweenegg" or lowerName == "halloween" then
        return nil
    end

    local info = getSpeciesInfo and getSpeciesInfo(eggName) or nil
    local isCataloged = (info ~= nil and info.IsCataloged == true)
    local rarity = (isCataloged and info.Rarity) or egg:GetAttribute("Rarity") or halloweenEngine.newRarity
    local zone = egg:GetAttribute("Zone")

    return {
        Model       = egg,
        Name        = eggName,
        Position    = p,
        Distance    = charPos and (p - charPos).Magnitude or 99999,
        Zone        = tonumber(zone) or 99,
        Rank        = (isCataloged and info.Rank) or RARITY_RANK[rarity] or 0,
        Rarity      = rarity,
        IsCataloged = isCataloged,
        Uid         = egg:GetAttribute("HalloweenEggUid") or egg.Name,
        Color       = getHwEggColor(egg, eggName),
    }
end

halloweenEngine.rarityMatches = function(rarity)
    if not selectedHwRarities then return false end
    return selectedHwRarities["All"] == true or selectedHwRarities[rarity] == true
end

-- Serialize the complete Hold -> Cast -> Bite Wait -> Reel sequence.
-- A second loop may request a cycle, but it must not issue overlapping fishing remotes.
halloweenEngine.fishing.executeSingleCycle = function(cancelCheck, onComplete)
    local fishing = halloweenEngine.fishing
    if fishing.cycleBusy then
        fishing.log("CYCLE SKIPPED -> another Hold/Cast/Reel cycle is still active.")
        if onComplete then onComplete(false) end
        return false
    end

    fishing.cycleBusy = true
    local cycleOk, cycleErr = pcall(function()
        fishing._executeSingleCycle(cancelCheck, onComplete)
    end)
    fishing.cycleBusy = false

    if not cycleOk then
        fishing.log("Fishing cycle exception -> " .. tostring(cycleErr))
        if lblFishStatus then
            lblFishStatus.Text = "Status: Fishing cycle error"
            lblFishStatus.TextColor3 = Color3.fromRGB(255, 100, 80)
        end
    end
    return cycleOk
end

halloweenEngine.walkViaDropZoneToSafeZone = function(onComplete)
    pcall(function()
        local currChar = LocalPlayer and LocalPlayer.Character
        local h = currChar and currChar:FindFirstChildOfClass("Humanoid")
        local hrp = currChar and currChar:FindFirstChild("HumanoidRootPart")
        if h then
            if h.Sit then h.Sit = false end
            if h.PlatformStand then h.PlatformStand = false end
        end
        if hrp then
            hrp.Anchored = false
            local diff = Vector3.new(halloweenEngine.dropPos.X - hrp.Position.X, 0, halloweenEngine.dropPos.Z - hrp.Position.Z)
            if diff.Magnitude > 0.1 and velocityEnabled then
                local dir = diff.Unit
                hrp.AssemblyLinearVelocity = Vector3.new(dir.X * baseCarrySpeed, hrp.AssemblyLinearVelocity.Y, dir.Z * baseCarrySpeed)
            end
        end
    end)

    walkToTarget(halloweenEngine.dropPos, 6.0, function()
        pcall(function()
            local currChar = LocalPlayer and LocalPlayer.Character
            local hrp = currChar and currChar:FindFirstChild("HumanoidRootPart")
            if hrp then
                local diff = Vector3.new(halloweenEngine.safeZone.X - hrp.Position.X, 0, halloweenEngine.safeZone.Z - hrp.Position.Z)
                if diff.Magnitude > 0.1 and velocityEnabled then
                    local dir = diff.Unit
                    hrp.AssemblyLinearVelocity = Vector3.new(dir.X * baseCarrySpeed, hrp.AssemblyLinearVelocity.Y, dir.Z * baseCarrySpeed)
                end
            end
        end)

        local function giveUp()
            if hwCarryState then
                hwCarryState.active = false
                hwCarryState.name = nil
            end
            updateActivityStatus()
            if onComplete then onComplete(false) end
        end

        walkToTarget(halloweenEngine.safeZone, 6.0, function()
            pcall(function()
                local currChar = LocalPlayer and LocalPlayer.Character
                local h = currChar and currChar:FindFirstChildOfClass("Humanoid")
                if h then h:UnequipTools() end
            end)
            if hwCarryState then
                hwCarryState.active = false
                hwCarryState.name = nil
            end
            updateActivityStatus()
            if onComplete then onComplete(true) end
        end, "HW_SAFEZONE", 8.0, giveUp)
    end, "HW_DROPZONE", 8.0, function()
        if onComplete then onComplete(false) end
    end)
end

halloweenEngine.tpAction = function(eggData, onComplete)
    if not eggData then
        if onComplete then onComplete(false) end
        return
    end

    stopWalking()

    local model = eggData.Model
    local targetPos = toVector3((model and getHwEggPos(model)) or eggData.Position)
    if not targetPos then
        if onComplete then onComplete(false) end
        return
    end

    hwPickupToken = (hwPickupToken or 0) + 1
    local myTok = hwPickupToken

    task.spawn(function()
        local function setPlayerPos(pos)
            pcall(function()
                local ch = LocalPlayer and LocalPlayer.Character
                local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
                if hrp then
                    hrp.AssemblyLinearVelocity = Vector3.zero
                    hrp.CFrame = CFrame.new(pos)
                end
            end)
        end

        local function isCarryingNow()
            local held, name = isHoldingEgg()
            if held then return true, name end
            if hwCarryState and hwCarryState.isCarrying then
                local hwHeld, hwName = hwCarryState.isCarrying()
                if hwHeld then return true, hwName end
            end
            return false, nil
        end

        -- ==========================================================
        -- STEP 1: INITIAL TP + REPEATED PULSE UNTIL PICKUP SECURED
        -- ==========================================================
        local tStart = os.clock()
        local secured = false
        local spamPayload = {
            Model    = model,
            Name     = eggData.Name,
            Position = targetPos,
            Uid      = eggData.Uid,
            Prompt   = nil,
        }
        while hwPickupToken == myTok and (os.clock() - tStart < 3.0) do
            setPlayerPos(targetPos)

            local carrying, cName = isCarryingNow()
            if carrying or (model and model.Parent and model:GetAttribute("HalloweenEggCanPickUp") == false) then
                if hwCarryState then
                    hwCarryState.active = true
                    hwCarryState.name = cName or eggData.Name
                end
                updateActivityStatus()
                secured = true
                break
            end

            -- Update live position if egg model moved
            if model and model.Parent then
                local lp = getHwEggPos(model)
                if lp and (lp - targetPos).Magnitude <= 35 then
                    targetPos = lp
                end
            end

            local pr = model and model.Parent and model:FindFirstChildWhichIsA("ProximityPrompt", true)
            local prompt = (pr and isCarryPrompt(pr)) and pr or nil
            local liveUid = (model and model.Parent and model:GetAttribute("HalloweenEggUid")) or eggData.Uid

            if executeHwPickupSpam then
                spamPayload.Position = targetPos
                spamPayload.Uid      = liveUid
                spamPayload.Prompt   = prompt
                executeHwPickupSpam(spamPayload)
            end

            task.wait(0.035)
        end

        if hwPickupToken ~= myTok then
            if onComplete then onComplete(false) end
            return
        end

        local holdingAfterStep1, hName1 = isCarryingNow()
        if not holdingAfterStep1 and not secured then
            if onComplete then onComplete(false) end
            return -- Initial pickup did not succeed, abort gracefully
        end

        if hwCarryState then
            hwCarryState.active = true
            hwCarryState.name = hName1 or eggData.Name
        end
        updateActivityStatus()

        -- Check if egg is from Zone 1:
        -- Zone 1 eggs cannot be dropped via remote at dropPos after direct TP.
        -- Fallback for Zone 1: TP to egg + pickup, then walk towards dropPos waypoint, then to safezone!
        local isZone1 = (eggData.Zone == 1)
            or (model and tonumber(model:GetAttribute("Zone")) == 1)
            or (targetPos.Z < -6500 and targetPos.Z > -7050)

        if isZone1 then
            halloweenEngine.walkViaDropZoneToSafeZone(onComplete)
            return
        end

        -- ==========================================================
        -- STEP 2: TP TOWARDS DROP LOCATION BEFORE DROPPING (ZONES 2 & 3)
        -- ==========================================================
        for i = 1, 4 do
            if hwPickupToken ~= myTok then
                if onComplete then onComplete(false) end
                return
            end
            setPlayerPos(halloweenEngine.dropPos)
            task.wait(0.035)
        end

        -- Drop the egg: invoke AskDropEgg
        local net = ReplicatedStorage:FindFirstChild("Packages") and ReplicatedStorage.Packages:FindFirstChild("Networking")
        local dropRf = net and net:FindFirstChild("RF/HalloweenDimension/AskDropEgg")
        if dropRf then
            pcall(function() dropRf:InvokeServer() end)
        end

        if hwCarryState then
            hwCarryState.active = false
            hwCarryState.name = nil
        end
        updateActivityStatus()

        -- Brief debounce for server drop replication (40ms)
        task.wait(0.04)

        -- ==========================================================
        -- STEP 3: RE-PICKUP SAME EGG AT DROP LOCATION
        -- ==========================================================
        local rePickStart = os.clock()
        local reSecured = false

        local ch = LocalPlayer and LocalPlayer.Character
        local hum = ch and ch:FindFirstChildOfClass("Humanoid")
        if hum then
            if hum.Sit then hum.Sit = false end
            if hum.PlatformStand then hum.PlatformStand = false end
        end

        local function checkReSecured()
            if reSecured then return true end
            local held, name = isCarryingNow()
            if held then return true, name end
            if model and model.Parent and model:GetAttribute("HalloweenEggCanPickUp") == false then
                return true, eggData.Name
            end
            local currCh = LocalPlayer and LocalPlayer.Character
            if currCh then
                for _, c in ipairs(currCh:GetChildren()) do
                    if c:IsA("Tool") then
                        local cName = c.Name:lower()
                        if cName:find("egg", 1, true)
                            or c:GetAttribute("IsEgg") == true
                            or c:GetAttribute("HalloweenEggUid") ~= nil
                            or (eggData.Name and cName:find(eggData.Name:lower(), 1, true))
                        then
                            return true, c.Name
                        end
                    end
                end
            end
            local currBp = LocalPlayer and LocalPlayer:FindFirstChild("Backpack")
            if currBp then
                for _, t in ipairs(currBp:GetChildren()) do
                    if t:IsA("Tool") then
                        local tName = t.Name:lower()
                        if tName:find("egg", 1, true)
                            or t:GetAttribute("IsEgg") == true
                            or t:GetAttribute("HalloweenEggUid") ~= nil
                            or (eggData.Name and tName:find(eggData.Name:lower(), 1, true))
                        then
                            local h = currCh and currCh:FindFirstChildOfClass("Humanoid")
                            if h then h:EquipTool(t) end
                            return true, t.Name
                        end
                    end
                end
            end
            return false, nil
        end

        local connChar, connBp, connModel
        if ch then
            connChar = ch.ChildAdded:Connect(function(c)
                if c:IsA("Tool") then reSecured = true end
            end)
        end
        local currBp = LocalPlayer and LocalPlayer:FindFirstChild("Backpack")
        if currBp then
            connBp = currBp.ChildAdded:Connect(function(t)
                if t:IsA("Tool") then
                    local h = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
                    if h then h:EquipTool(t) end
                    reSecured = true
                end
            end)
        end
        if model and model.Parent then
            connModel = model:GetAttributeChangedSignal("HalloweenEggCanPickUp"):Connect(function()
                if model:GetAttribute("HalloweenEggCanPickUp") == false then
                    reSecured = true
                end
            end)
        end

        -- Dispatch carry burst: invoke server & trigger prompts
        if eggData.Uid and eggData.Uid ~= "" then
            local hwNet = ReplicatedStorage:FindFirstChild("Packages") and ReplicatedStorage.Packages:FindFirstChild("Networking")
            local hwRf = hwNet and hwNet:FindFirstChild("RF/HalloweenDimension/AskCarryEgg")
            if hwRf then
                for b = 1, 4 do
                    task.spawn(function()
                        local ok = pcall(function() return hwRf:InvokeServer(eggData.Uid) end)
                        if ok then reSecured = true end
                    end)
                end
            end
            local fieldRf = hwNet and hwNet:FindFirstChild("RF/EggWorld/AskFieldEggCarry")
            if fieldRf then
                task.spawn(function() pcall(function() fieldRf:InvokeServer({ Uid = eggData.Uid }) end) end)
            end
        end

        -- Trigger prompts on SmartPromptPart
        local sp = Workspace:FindFirstChild("SmartPromptPart")
        if sp then
            for _, pr in ipairs(sp:GetDescendants()) do
                if pr:IsA("ProximityPrompt") and isCarryPrompt(pr) then
                    triggerProximityPrompt(pr)
                end
            end
        end

        -- Trigger any nearby proximity prompts on dropped models (targeted scan: egg model + WorldEggs folder + spatial query)
        pcall(function()
            if model and model.Parent then
                for _, pr in ipairs(model:GetDescendants()) do
                    if pr:IsA("ProximityPrompt") and isCarryPrompt(pr) then
                        triggerProximityPrompt(pr)
                    end
                end
            end
            local wFolder = halloweenEngine and halloweenEngine.cachedWorldEggs
            if wFolder and wFolder.Parent then
                for _, obj in ipairs(wFolder:GetChildren()) do
                    local p = getHwEggPos(obj)
                    if p and (p - halloweenEngine.dropPos).Magnitude <= 15 then
                        for _, pr in ipairs(obj:GetDescendants()) do
                            if pr:IsA("ProximityPrompt") and isCarryPrompt(pr) then
                                triggerProximityPrompt(pr)
                            end
                        end
                    end
                end
            end
            if workspace.GetPartBoundsInRadius then
                local nearbyParts = workspace:GetPartBoundsInRadius(halloweenEngine.dropPos, 15)
                for _, part in ipairs(nearbyParts) do
                    local m = part:FindFirstAncestorWhichIsA("Model")
                    if m and m ~= ch then
                        for _, pr in ipairs(part:GetChildren()) do
                            if pr:IsA("ProximityPrompt") and isCarryPrompt(pr) then
                                triggerProximityPrompt(pr)
                            end
                        end
                    end
                end
            end
        end)

        -- Fast reactive wait (max 0.25s) - terminates instantly when reSecured or checkReSecured is true
        while hwPickupToken == myTok and not reSecured and (os.clock() - rePickStart < 0.25) do
            local isSec = checkReSecured()
            if isSec then
                reSecured = true
                break
            end
            task.wait(0.02)
        end

        if connChar then connChar:Disconnect() end
        if connBp then connBp:Disconnect() end
        if connModel then connModel:Disconnect() end

        if hwPickupToken ~= myTok then
            if onComplete then onComplete(false) end
            return
        end

        local _, fName = checkReSecured()
        if hwCarryState then
            hwCarryState.active = true
            hwCarryState.name = fName or eggData.Name
        end
        updateActivityStatus()

        -- ==========================================================
        -- STEP 4: WALK TOWARDS SAFEZONE
        -- Direct velocity travel at full carry speed (310 studs/s)
        -- ==========================================================
        pcall(function()
            local currChar = LocalPlayer and LocalPlayer.Character
            local h = currChar and currChar:FindFirstChildOfClass("Humanoid")
            local hrp = currChar and currChar:FindFirstChild("HumanoidRootPart")
            if h then
                if h.Sit then h.Sit = false end
                if h.PlatformStand then h.PlatformStand = false end
            end
            if hrp then
                hrp.Anchored = false
                local diff = Vector3.new(halloweenEngine.safeZone.X - hrp.Position.X, 0, halloweenEngine.safeZone.Z - hrp.Position.Z)
                if diff.Magnitude > 0.1 then
                    local dir = diff.Unit
                    hrp.AssemblyLinearVelocity = Vector3.new(dir.X * baseCarrySpeed, hrp.AssemblyLinearVelocity.Y, dir.Z * baseCarrySpeed)
                end
            end
        end)

        local function giveUpSafeZone()
            if hwCarryState then
                hwCarryState.active = false
                hwCarryState.name = nil
            end
            updateActivityStatus()
            if onComplete then onComplete(false) end
        end

        walkToTarget(halloweenEngine.safeZone, 6.0, function()
            pcall(function()
                local currChar = LocalPlayer and LocalPlayer.Character
                local h = currChar and currChar:FindFirstChildOfClass("Humanoid")
                if h then h:UnequipTools() end
            end)
            if hwCarryState then
                hwCarryState.active = false
                hwCarryState.name = nil
            end
            updateActivityStatus()
            if onComplete then onComplete(true) end
        end, "HW_SAFEZONE", 8.0, giveUpSafeZone)
    end)
end

local hwCardPool = {}

local function getOrCreateHwCard(idx)
    local item = hwCardPool[idx]
    if not item then
        item = createPooledCard(idx, hwEggListScroll, "HwCard_", Color3.fromRGB(26, 22, 34), Color3.fromRGB(220, 110, 30), function(eggData)
            if halloweenEngine and halloweenEngine.tpAction then
                halloweenEngine.tpAction(eggData)
            end
        end, function(eggData)
            pcall(function()
                local ch = LocalPlayer and LocalPlayer.Character
                local hum = ch and ch:FindFirstChildOfClass("Humanoid")
                if hum then
                    hum:UnequipTools()
                    if hum.Sit then hum.Sit = false end
                    if hum.PlatformStand then hum.PlatformStand = false end
                end
            end)

            local model = eggData.Model
            local targetPos = toVector3((model and getHwEggPos(model)) or eggData.Position)
            if not targetPos then return end

            local uid = eggData.Uid or (model and model:GetAttribute("HalloweenEggUid")) or (model and model.Name) or "HW_EGG"

            walkToTarget(targetPos, 3.5, function()
                pickupHwEgg(eggData, function()
                    if hwCarryState then
                        hwCarryState.active = true
                        hwCarryState.name = eggData.Name
                    end
                    updateActivityStatus()
                    if halloweenEngine and halloweenEngine.walkViaDropZoneToSafeZone then
                        halloweenEngine.walkViaDropZoneToSafeZone()
                    end
                end)
            end, "HW_" .. tostring(uid), 8.0)
        end)
        hwCardPool[idx] = item
    end
    return item
end

renderHalloweenEggs = function()
    if not (screenGui and screenGui.Parent and main and main.Visible and tabHalloween and tabHalloween.Visible) then
        return
    end

    local charPos = nil
    pcall(function()
        local ch = LocalPlayer and LocalPlayer.Character
        local root = ch and ch:FindFirstChild("HumanoidRootPart")
        if root then charPos = root.Position end
    end)

    local eggList = {}
    local rawEggModels = {}
    local seenModels = {}

    local function addEggCandidate(egg)
        if egg and not seenModels[egg] then
            seenModels[egg] = true
            table.insert(rawEggModels, egg)
        end
    end

    pcall(function()
        local worldEggs = halloweenEngine and halloweenEngine.cachedWorldEggs
        if not (worldEggs and worldEggs.Parent) then
            local hw = Workspace:FindFirstChild("HalloweenDimension")
            worldEggs = hw and hw:FindFirstChild("WorldEggs")
            if not worldEggs then
                worldEggs = Workspace:FindFirstChild("WorldEggs")
            end
            if halloweenEngine then
                halloweenEngine.cachedWorldEggs = worldEggs
            end
        end
        if worldEggs then
            for _, egg in ipairs(worldEggs:GetChildren()) do
                addEggCandidate(egg)
            end
            -- Mark the list dirty only when the world actually changes, instead of
            -- rebuilding it 3.3x/s just in case.
            if halloweenEngine and halloweenEngine.hwHookedFolder ~= worldEggs then
                if halloweenEngine.hwFolderConns then
                    for _, c in ipairs(halloweenEngine.hwFolderConns) do pcall(function() c:Disconnect() end) end
                    table.clear(halloweenEngine.hwFolderConns)
                else
                    halloweenEngine.hwFolderConns = {}
                end
                halloweenEngine.hwHookedFolder = worldEggs
                table.insert(halloweenEngine.hwFolderConns, worldEggs.ChildAdded:Connect(function()
                    halloweenEngine.hwListDirty = true
                end))
                table.insert(halloweenEngine.hwFolderConns, worldEggs.ChildRemoved:Connect(function()
                    halloweenEngine.hwListDirty = true
                end))
            end
        end

        local tagged = CollectionService:GetTagged("HalloweenWorldEgg")
        if tagged then
            for _, egg in ipairs(tagged) do
                addEggCandidate(egg)
            end
        end
    end)

    local inHw = false
    pcall(function()
        inHw = (LocalPlayer and LocalPlayer:GetAttribute("InHalloweenDimension") == true)
            or (Workspace:FindFirstChild("HalloweenDimension") ~= nil)
            or (#rawEggModels > 0)
    end)

    for _, egg in ipairs(rawEggModels) do
        -- Same classifier and same filter rule as autoFarm.findTarget, so the list
        -- never shows an egg that the auto-farm would refuse to target.
        local entry = halloweenEngine.classifyEgg(egg, charPos)
        if entry and halloweenEngine.rarityMatches(entry.Rarity) then
            local zone = egg:GetAttribute("Zone")
            local zoneName = zone and string.format("Zone %s", tostring(zone))
                or egg:GetAttribute("AreaId")
                or egg:GetAttribute("Biome")
                or "WorldEggs"

            local tagUpdate = not entry.IsCataloged and " • [New Update]" or ""
            entry.SubLabel = string.format("%s • %s%s • %d studs",
                zoneName, entry.Rarity, tagUpdate, math.floor(entry.Distance))
            table.insert(eggList, entry)
        end
    end

    -- Stable sort: Zone, then Highest Rarity Rank, then Name
    table.sort(eggList, function(a, b)
        if a.Zone ~= b.Zone then
            return a.Zone < b.Zone
        end
        if a.Rank ~= b.Rank then
            return a.Rank > b.Rank
        end
        if a.Name ~= b.Name then
            return a.Name < b.Name
        end
        return tostring(a.Uid) < tostring(b.Uid)
    end)

    local count = #eggList
    local deliv = LocalPlayer and LocalPlayer:GetAttribute("HalloweenDelivered") or 0
    if hwStatusLabel then
        if inHw or count > 0 then
            hwStatusLabel.Text = string.format("Status: In Dimension (%d Live) | Deliv: %s", count, tostring(deliv))
        else
            hwStatusLabel.Text = "Status: Outside Dimension (Portal Ready)"
        end
    end

    if count == 0 then
        if hwEmptyNotice then
            hwEmptyNotice.Visible = true
            local hasFilter = selectedHwRarities and not selectedHwRarities["All"]
            hwEmptyNotice.Text = (inHw or Workspace:FindFirstChild("HalloweenDimension"))
                and (hasFilter and "🎃 No Halloween eggs match current rarity filter.\nSelect [All] or adjust rarity filter." or "🎃 All Halloween eggs currently collected or respawning.\nWait for new spawn on pads.")
                or "🎃 No Halloween eggs detected in current world.\nEnter the Halloween Portal to view eggs."
        end
    else
        if hwEmptyNotice then hwEmptyNotice.Visible = false end
    end

    for idx, eggData in ipairs(eggList) do
        local poolItem = getOrCreateHwCard(idx)
        poolItem.data = eggData
        -- Only write the GUI properties that actually changed: every extra write
        -- is a property-changed notification plus a layout invalidation.
        if poolItem.lastName ~= eggData.Name then
            poolItem.lastName = eggData.Name
            poolItem.nameLabel.Text = eggData.Name
        end
        if poolItem.lastSub ~= eggData.SubLabel then
            poolItem.lastSub = eggData.SubLabel
            poolItem.subLabel.Text = eggData.SubLabel
        end
        if poolItem.lastColor ~= eggData.Color then
            poolItem.lastColor = eggData.Color
            poolItem.accent.BackgroundColor3 = eggData.Color
        end
        if poolItem.card.Visible ~= true then
            poolItem.card.Visible = true
        end
    end

    for idx = count + 1, #hwCardPool do
        local poolItem = hwCardPool[idx]
        if poolItem.lastSub ~= nil then
            poolItem.lastSub = nil
            poolItem.lastName = nil
            poolItem.lastColor = nil
        end
        if poolItem.card.Visible then
            poolItem.card.Visible = false
        end
    end

    -- Keep the pool bounded: a one-off 100-egg burst must not pin ~700 instances
    -- for the rest of the session.
    local POOL_MAX = 150
    while #hwCardPool > POOL_MAX do
        local extra = table.remove(hwCardPool)
        if extra and extra.card then
            pcall(function() extra.card:Destroy() end)
        end
    end
end

-- ============================================================================
-- HALLOWEEN AUTO-PICKUP ENGINE (ISOLATED WORLD 2 MODULE)
-- ============================================================================

hwPickupToken = 0

local function findBestHwPickupTarget()
    local char = LocalPlayer and LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return nil end
    local charPos  = root.Position
    local charLook = root.CFrame.LookVector
    local cam = Workspace.CurrentCamera
    local camPos  = cam and cam.CFrame.Position or charPos
    local camLook = cam and cam.CFrame.LookVector or charLook

    local function scoreHwTarget(pos, dist)
        return calculateTargetScore(pos, dist, charPos, charLook, camPos, camLook)
    end

    local rawEggModels = {}
    local seen = {}
    local function addEgg(inst)
        if inst and not seen[inst] then
            seen[inst] = true
            table.insert(rawEggModels, inst)
        end
    end

    pcall(function()
        local hw = Workspace:FindFirstChild("HalloweenDimension")
        if not hw then hw = Workspace:FindFirstChild("HalloweenDimension", true) end
        local worldEggs = hw and (hw:FindFirstChild("WorldEggs") or hw:FindFirstChild("WorldEggs", true))
        if not worldEggs then worldEggs = Workspace:FindFirstChild("WorldEggs") end
        if worldEggs then
            for _, egg in ipairs(worldEggs:GetChildren()) do
                addEgg(egg)
            end
        end
        local tagged = CollectionService:GetTagged("HalloweenWorldEgg")
        if tagged then
            for _, egg in ipairs(tagged) do
                addEgg(egg)
            end
        end
    end)

    local bestTarget = nil
    local highestScore = -math.huge
    local maxPickupDist = 45

    for _, egg in ipairs(rawEggModels) do
        -- Guards are combined (instead of `continue`) so this file also loads in
        -- stock Lua, which the long-run test harness relies on.
        if not egg.Name:lower():find("holder")
            and egg:GetAttribute("HalloweenEggCanPickUp") ~= false then
            local p = getHwEggPos(egg)
            if p then
                local dist = (p - charPos).Magnitude
                if dist <= maxPickupDist then
                    local score = scoreHwTarget(p, dist)
                    if score > highestScore then
                        local eggName = getHwEggName(egg)
                        if not eggName:lower():find("holder") then
                            highestScore = score
                            local pr = egg:FindFirstChildWhichIsA("ProximityPrompt", true)
                            bestTarget = {
                                Model    = egg,
                                Name     = eggName,
                                Position = p,
                                Distance = dist,
                                Uid      = egg:GetAttribute("HalloweenEggUid") or egg.Name,
                                Prompt   = (pr and isCarryPrompt(pr)) and pr or nil
                            }
                        end
                    end
                end
            end
        end
    end

    if bestTarget and not bestTarget.Prompt then
        local sp = Workspace:FindFirstChild("SmartPromptPart")
        if sp then
            for _, pr in ipairs(sp:GetDescendants()) do
                if pr:IsA("ProximityPrompt") and isCarryPrompt(pr) then
                    bestTarget.Prompt = pr
                    break
                end
            end
        end
    end

    return bestTarget
end

executeHwPickupSpam = function(target)
    if not target then return end
    local uid = target.Uid

    -- 1. Dispatch Halloween Remote: RF/HalloweenDimension/AskCarryEgg (Parallel Burst)
    if uid and uid ~= "" then
        local net = ReplicatedStorage:FindFirstChild("Packages") and ReplicatedStorage.Packages:FindFirstChild("Networking")
        local hwRf = net and net:FindFirstChild("RF/HalloweenDimension/AskCarryEgg")
        if hwRf then
            for i = 1, 2 do
                task.spawn(function()
                    pcall(function() hwRf:InvokeServer(uid) end)
                end)
            end
        end
    end

    -- 2. Trigger ProximityPrompt ONLY if it is a validated carry prompt
    local prompt = target.Prompt
    if not prompt and target.Model and target.Model.Parent then
        local pr = target.Model:FindFirstChildWhichIsA("ProximityPrompt", true)
        if pr and isCarryPrompt(pr) then
            prompt = pr
            target.Prompt = pr
        end
    end
    if prompt and isCarryPrompt(prompt) then
        triggerProximityPrompt(prompt)
    end
    local sp = Workspace:FindFirstChild("SmartPromptPart")
    if sp then
        for _, pr in ipairs(sp:GetDescendants()) do
            if pr:IsA("ProximityPrompt") and isCarryPrompt(pr) then
                triggerProximityPrompt(pr)
                break
            end
        end
    end
end

pickupHwEgg = function(eggData, onSecured)
    if not eggData then return end
    local model = eggData.Model
    local targetPos = (model and getHwEggPos(model)) or eggData.Position
    local uid = eggData.Uid or (model and model:GetAttribute("HalloweenEggUid")) or (model and model.Name)

    hwPickupToken = (hwPickupToken or 0) + 1
    local myTok = hwPickupToken

    task.spawn(function()
        local tStart = os.clock()
        local maxDuration = 1.5
        local hasSnapped = false
        local secured = false

        while hwPickupToken == myTok and (os.clock() - tStart < maxDuration) do
            local curHolding = isHoldingEgg() or (hwCarryState and hwCarryState.isCarrying and hwCarryState.isCarrying())
            if curHolding or weAreCarrying then
                if hwCarryState then
                    hwCarryState.active = true
                    hwCarryState.name = eggData.Name
                end
                updateActivityStatus()
                secured = true
                break -- Egg is secured! Stop burst immediately
            end

            if model and model.Parent then
                if model:GetAttribute("HalloweenEggCanPickUp") == false then
                    if hwCarryState then
                        hwCarryState.active = true
                        hwCarryState.name = eggData.Name
                    end
                    updateActivityStatus()
                    secured = true
                    break -- Server confirmed carry, stop immediately!
                end
            end

            local livePos = targetPos
            if model and model.Parent then
                local p = getHwEggPos(model)
                if p and (not targetPos or (p - targetPos).Magnitude <= 35) then
                    livePos = p
                end
            end

            if livePos then
                hasSnapped = checkAndApplyReachAssist(livePos, hasSnapped)
            end

            local pr = model and model.Parent and model:FindFirstChildWhichIsA("ProximityPrompt", true)
            local prompt = (pr and isCarryPrompt(pr)) and pr or nil

            local liveUid = (model and model.Parent and model:GetAttribute("HalloweenEggUid")) or uid

            local hwTarget = {
                Model    = model,
                Name     = eggData.Name,
                Position = livePos or targetPos,
                Uid      = liveUid,
                Prompt   = prompt,
            }

            executeHwPickupSpam(hwTarget)

            task.wait(0.035)
        end

        local isSec = secured or isHoldingEgg() or (hwCarryState and hwCarryState.isCarrying and hwCarryState.isCarrying())
        if isSec and onSecured then
            task.spawn(onSecured)
        end
    end)
end

startHalloweenAutoPickup = function()
    local holding, _ = isHoldingEgg()
    if holding or weAreCarrying then return end

    hwPickupToken = (hwPickupToken or 0) + 1
    local myTok = hwPickupToken

    task.spawn(function()
        local tStart = os.clock()
        local maxDuration = 1.2
        local hasSnapped = false

        while hwPickupToken == myTok and hwAutoPickEnabled and (os.clock() - tStart < maxDuration) do
            local curHolding, _ = isHoldingEgg()
            if curHolding or weAreCarrying then
                if hwCarryState then
                    hwCarryState.active = true
                    hwCarryState.name = target and target.Name or "Halloween Egg"
                end
                updateActivityStatus()
                break -- Egg is secured! Stop burst immediately
            end

            local target = findBestHwPickupTarget()
            if target then
                if target.Position then
                    hasSnapped = checkAndApplyReachAssist(target.Position, hasSnapped)
                end
                executeHwPickupSpam(target)

                if target.Model and target.Model.Parent then
                    if target.Model:GetAttribute("HalloweenEggCanPickUp") == false then
                        break -- Server confirmed carry, stop immediately!
                    end
                end
            end

            task.wait(0.035)
        end
    end)
end

-- ============================================================================
-- FULL EGG LIST JSON EXPORTER (For diagnostics & rarity audits)
-- ============================================================================

local exportEggListJson
do
    exportEggListJson = function()
        local charPos = nil
        pcall(function()
            local ch = LocalPlayer and LocalPlayer.Character
            local root = ch and ch:FindFirstChild("HumanoidRootPart")
            if root then charPos = root.Position end
        end)

        local exportData = {
            exportedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
            totalCached = 0,
            totalFarmable = 0,
            farmableEggs = {},
            allEggs = {},
        }

        for uid, r in pairs(eggCacheByUid) do
            exportData.totalCached = exportData.totalCached + 1
            local rawName, info, disp, serverRarity, rarity, rank, biome, pos, dist = resolveEggFields(r, uid, charPos)
            local eggItem = {
                uid = tostring(uid),
                displayName = disp,
                rawName = rawName,
                finalRarity = rarity,
                serverRarityId = serverRarity,
                rank = rank,
                biome = biome,
                state = r.State or "Slot",
                isFarmable = isFarmableEgg(r),
                distance = dist and math.floor(dist * 10 + 0.5) / 10 or nil,
            }
            table.insert(exportData.allEggs, eggItem)
            if eggItem.isFarmable then table.insert(exportData.farmableEggs, eggItem) end
        end

        exportData.totalFarmable = #exportData.farmableEggs
        table.sort(exportData.farmableEggs, function(a, b)
            if a.rank ~= b.rank then return a.rank > b.rank end
            return (a.distance or 99999) < (b.distance or 99999)
        end)

        local okJson, jsonStr = pcall(function() return HttpService:JSONEncode(exportData) end)
        if okJson and jsonStr then
            pcall(function()
                if typeof(setclipboard) == "function" then setclipboard(jsonStr)
                elseif typeof(toclipboard) == "function" then toclipboard(jsonStr) end
            end)
            return true, exportData.totalFarmable
        end
        return false, 0
    end
end

-- Local Workspace ESP sync (Pure client-side RAM read, 0 network calls, 0 latency)
local function syncAreaEggSlotsESP()
    local container = Workspace:FindFirstChild("AreaEggSlotsClient")
    if not container then return false end

    local newSpeciesDiscovered = false
    local currentUids = {}

    for _, child in ipairs(container:GetChildren()) do
        local uid = child.Name
        if uid and uid ~= "" then
            currentUids[uid] = true
            local cf = nil
            if child:IsA("BasePart") then
                cf = child.CFrame
            elseif child:IsA("Model") then
                local ok, piv = pcall(function() return child:GetPivot() end)
                if ok and piv and piv.Position.Magnitude > 10 then cf = piv end
                if not cf and child.PrimaryPart then cf = child.PrimaryPart.CFrame end
            end

            local rawSrc = child:GetAttribute("PreparedSourceName")
            local species = nil
            if type(rawSrc) == "string" and rawSrc ~= "" then
                local base = rawSrc:match("([^%.]+)$") or rawSrc
                species = base:gsub("(%l)(%u)", "%1 %2")
            else
                local attrSpecies = child:GetAttribute("DisplayName") or child:GetAttribute("Species") or child:GetAttribute("AssetCategory")
                if attrSpecies then
                    species = tostring(attrSpecies)
                else
                    for _, ch in ipairs(child:GetChildren()) do
                        local sInfo = SPECIES_INFO[ch.Name:lower()]
                        if sInfo then
                            species = sInfo.DisplayName
                            break
                        end
                    end
                end
            end

            if species and isGenericEggName(species) then
                species = nil
            end

            local existing = eggCacheByUid[uid]
            if not existing then
                existing = {
                    Uid = uid,
                    State = "Slot",
                    BoundsCFrame = cf,
                }
                if species then
                    existing.DisplayName = species
                    existing.AssetCategory = species
                end
                eggCacheByUid[uid] = existing
            else
                if cf and cf.Position.Magnitude > 10 then existing.BoundsCFrame = cf end
                if species then
                    existing.DisplayName = species
                    existing.AssetCategory = species
                end
            end

            if species and registerDynamicSpecies and registerDynamicSpecies(species, nil, nil) then
                newSpeciesDiscovered = true
            end
        end
    end

    if newSpeciesDiscovered then
        table.sort(ALL_SPECIES_LIST, function(a, b)
            return a.Name:lower() < b.Name:lower()
        end)
        if eggDropList and eggDropList.Visible and rebuildEggDropdownItems then
            rebuildEggDropdownItems()
        end
    end

    requestListUpdate()
    return true
end

-- Server snapshot reconciliation (Non-blocking with re-entrancy guard)
local function syncEggSnapshot()
    if isFetchingSnapshot then return end
    isFetchingSnapshot = true

    task.spawn(function()
        pcall(function()
            local rf = getNetRemote("RF/EggWorld/AskFieldEggSnapshot")
            if not rf then return end

            local okSnapshot, res = pcall(function()
                return rf:InvokeServer()
            end)

            if okSnapshot and typeof(res) == "table" and typeof(res.Records) == "table" then
                -- Index RareSpawns from snapshot
                if typeof(res.RareSpawns) == "table" then
                    for k, v in pairs(res.RareSpawns) do
                        if typeof(v) == "table" and v.EggUid and v.RarityId then
                            rarityByUid[tostring(v.EggUid)] = tostring(v.RarityId)
                        elseif typeof(k) == "string" and typeof(v) == "string" then
                            rarityByUid[k] = v
                        end
                    end
                end

                local currentUids = {}
                local newSpeciesDiscovered = false
                for _, r in pairs(res.Records) do
                    if typeof(r) == "table" then
                        local u = tostring(r.Uid or r.EggUid or "")
                        if u ~= "" then
                            currentUids[u] = true
                            eggCacheByUid[u] = r
                            local rId = r.RarityId or r.Rarity or (r.Attributes and r.Attributes.Rarity)
                            if rId and rId ~= "" and rId ~= "Unknown" then
                                rarityByUid[u] = tostring(rId)
                            end
                            local rawName = r.DisplayName or r.AssetCategory or r.Name
                            if rawName and registerDynamicSpecies(rawName, r.AreaId, rId) then
                                newSpeciesDiscovered = true
                            end
                        end
                    end
                end

                if newSpeciesDiscovered then
                    table.sort(ALL_SPECIES_LIST, function(a, b)
                        return a.Name:lower() < b.Name:lower()
                    end)
                    if eggDropList and eggDropList.Visible and rebuildEggDropdownItems then
                        rebuildEggDropdownItems()
                    end
                end

                for u in pairs(eggCacheByUid) do
                    if not currentUids[u] then
                        eggCacheByUid[u] = nil
                        rarityByUid[u] = nil
                    end
                end

                requestListUpdate()
            end
        end)
        isFetchingSnapshot = false
    end)
end

local function scheduleSnapshotSync(delaySec)
    if isFetchingSnapshot then return end
    task.delay(delaySec or 30.0, function()
        if not _G.EggGoToUI_Stop then
            pcall(syncEggSnapshot)
        end
    end)
end

-- Push event listener (0ms reaction, updates cache and requests throttled UI update)
local function startPushMonitor()
    local evShift = getNetRemote("RE/EggWorld/FieldEggShifted")
    local evBatch = getNetRemote("RE/EggWorld/FieldEggBatchShifted")
    local evRarities = getNetRemote("RE/EggWorld/FieldEggRaritiesShown")
    local evGone = getNetRemote("RE/EggWorld/FieldEggGone")
    local evCountdown = getNetRemote("RE/EggWorld/FieldEggCycleCountdown")

    if evShift then
        addConnection(evShift.OnClientEvent:Connect(function(payload)
            if typeof(payload) ~= "table" then return end
            local u = tostring(payload.Uid or payload.EggUid or "")
            if u == "" then return end

            local state = payload.State
            local myUidStr = tostring(LocalPlayer and LocalPlayer.UserId or "")
            if payload.CarrierUserId and tostring(payload.CarrierUserId) == myUidStr and state == "Carried" then
                carryUid = u
                setCarryingState(true, payload.DisplayName or payload.AssetCategory or payload.Name)
                if autoReturnActive and autoReturnTargetUid == u then
                    startReturnTrip()
                end
            elseif (state == "Claimed" or state == "Dropped") and carryUid == u then
                setCarryingState(false)
                if autoReturnActive and autoReturnTargetUid == u then
                    if state == "Dropped" then
                        handleEggDropped(u, payload)
                    elseif state == "Claimed" then
                        handleEggDelivered(u)
                    end
                end
            elseif state == "Carried" and payload.CarrierUserId and tostring(payload.CarrierUserId) ~= myUidStr then
                if autoReturnActive and autoReturnTargetUid == u then
                    stopWalking()
                    autoReturnActive = false
                    autoReturnTargetUid = nil
                    returnTripInProgress = false
                    if activityStatusLabel then
                        activityStatusLabel.Text = "Status: Target egg taken by another player"
                        activityStatusLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
                    end
                end
            elseif state == "Dropped" and autoReturnActive and autoReturnTargetUid == u then
                handleEggDropped(u, payload)
            elseif state == "Claimed" and autoReturnActive and autoReturnTargetUid == u then
                handleEggDelivered(u)
            end

            if state == "Claimed" then
                eggCacheByUid[u] = nil
            elseif eggCacheByUid[u] then
                eggCacheByUid[u].State = state
                if payload.CarrierUserId then
                    eggCacheByUid[u].CarrierUserId = payload.CarrierUserId
                end
                if payload.BoundsCFrame then
                    eggCacheByUid[u].BoundsCFrame = payload.BoundsCFrame
                end
            else
                eggCacheByUid[u] = payload
            end

            local rawName = payload.DisplayName or payload.AssetCategory or payload.Name
            if rawName and registerDynamicSpecies(rawName, payload.AreaId, payload.RarityId) then
                table.sort(ALL_SPECIES_LIST, function(a, b)
                    return a.Name:lower() < b.Name:lower()
                end)
                if eggDropList and eggDropList.Visible and rebuildEggDropdownItems then
                    rebuildEggDropdownItems()
                end
            end
            requestListUpdate()
        end))
    end

    if evCountdown then
        addConnection(evCountdown.OnClientEvent:Connect(function(val)
            local cd = tonumber(val) or (typeof(val) == "table" and tonumber(val.Countdown or val.Time or val.Seconds))
            if cd and cd <= 1 then
                if halloweenEngine and halloweenEngine.triggerNightReset then
                    halloweenEngine.triggerNightReset(12.0)
                end
            end
        end))
    end

    if evBatch then
        addConnection(evBatch.OnClientEvent:Connect(function()
            syncEggSnapshot()
        end))
    end

    if evRarities then
        addConnection(evRarities.OnClientEvent:Connect(function(payload)
            if typeof(payload) == "table" and typeof(payload.RareSpawns) == "table" then
                for k, v in pairs(payload.RareSpawns) do
                    if typeof(v) == "table" and v.EggUid and v.RarityId then
                        rarityByUid[tostring(v.EggUid)] = tostring(v.RarityId)
                    elseif typeof(k) == "string" and typeof(v) == "string" then
                        rarityByUid[k] = v
                    end
                end
            end
            requestListUpdate()
            syncEggSnapshot()
        end))
    end

    if evGone then
        addConnection(evGone.OnClientEvent:Connect(function(payload)
            local u = typeof(payload) == "table" and tostring(payload.Uid or "") or tostring(payload or "")
            if u ~= "" then
                if carryUid == u then
                    setCarryingState(false)
                end
                if autoReturnActive and autoReturnTargetUid == u then
                    if returnTripInProgress then
                        handleEggDelivered(u)
                    else
                        stopWalking()
                        autoReturnActive = false
                        autoReturnTargetUid = nil
                        returnTripInProgress = false
                        if activityStatusLabel then
                            activityStatusLabel.Text = "Status: Target egg expired"
                            activityStatusLabel.TextColor3 = Color3.fromRGB(255, 140, 60)
                        end
                    end
                end
                eggCacheByUid[u] = nil
                rarityByUid[u] = nil
                requestListUpdate()
            end
        end))
    end

    -- Hook AreaEggSlotsClient for native 0ms local ESP events
    local slotsContainer = Workspace:FindFirstChild("AreaEggSlotsClient")
    if slotsContainer then
        addConnection(slotsContainer.ChildAdded:Connect(function(child)
            local uid = child.Name
            if uid and uid ~= "" then
                local cf = nil
                if child:IsA("BasePart") then cf = child.CFrame
                elseif child:IsA("Model") then
                    local ok, piv = pcall(function() return child:GetPivot() end)
                    if ok and piv and piv.Position.Magnitude > 10 then cf = piv end
                    if not cf and child.PrimaryPart then cf = child.PrimaryPart.CFrame end
                end
                local rawSrc = child:GetAttribute("PreparedSourceName")
                local species = nil
                if type(rawSrc) == "string" and rawSrc ~= "" then
                    local base = rawSrc:match("([^%.]+)$") or rawSrc
                    species = base:gsub("(%l)(%u)", "%1 %2")
                else
                    local attrSpecies = child:GetAttribute("DisplayName") or child:GetAttribute("Species") or child:GetAttribute("AssetCategory")
                    if attrSpecies then
                        species = tostring(attrSpecies)
                    else
                        for _, ch in ipairs(child:GetChildren()) do
                            local sInfo = SPECIES_INFO[ch.Name:lower()]
                            if sInfo then
                                species = sInfo.DisplayName
                                break
                            end
                        end
                    end
                end

                if species and isGenericEggName(species) then
                    species = nil
                end

                local existing = eggCacheByUid[uid]
                if not existing then
                    existing = {
                        Uid = uid,
                        State = "Slot",
                        BoundsCFrame = cf,
                    }
                    if species then
                        existing.DisplayName = species
                        existing.AssetCategory = species
                    end
                    eggCacheByUid[uid] = existing
                else
                    if cf and cf.Position.Magnitude > 10 then existing.BoundsCFrame = cf end
                    if species then
                        existing.DisplayName = species
                        existing.AssetCategory = species
                    end
                end
                if species and registerDynamicSpecies and registerDynamicSpecies(species, nil, nil) then
                    table.sort(ALL_SPECIES_LIST, function(a, b) return a.Name:lower() < b.Name:lower() end)
                    if eggDropList and eggDropList.Visible and rebuildEggDropdownItems then
                        rebuildEggDropdownItems()
                    end
                end
                requestListUpdate()
            end
        end))

        addConnection(slotsContainer.ChildRemoved:Connect(function(child)
            local uid = child.Name
            if uid and uid ~= "" and eggCacheByUid[uid] and eggCacheByUid[uid].State == "Slot" then
                eggCacheByUid[uid] = nil
                rarityByUid[uid] = nil
                requestListUpdate()
            end
        end))
    end

    local okLighting, lighting = pcall(function() return game:GetService("Lighting") end)
    if okLighting and lighting then
        local lastClockTime = lighting.ClockTime
        addConnection(lighting:GetPropertyChangedSignal("ClockTime"):Connect(function()
            local cur = lighting.ClockTime
            local prev = lastClockTime or cur
            lastClockTime = cur

            local wasDay = (prev >= 6 and prev < 18)
            local isNight = (cur >= 18 or cur < 6)
            if wasDay and isNight then
                if halloweenEngine and halloweenEngine.triggerNightReset then
                    halloweenEngine.triggerNightReset(12.0)
                end
            end
        end))
    end
end

-- Throttled UI Render Loop (Max 3.3 FPS for DOM text updates = ZERO lag / ZERO freeze)
task.spawn(function()
    while not _G.EggGoToUI_Stop do
        task.wait(0.3)
        pcall(updateActivityStatus)

        -- Auto-Return State Poller fallback (ensures drop recovery even if remote event dropped)
        if autoReturnActive and autoReturnTargetUid then
            local holdingTarget = (weAreCarrying and carryUid == autoReturnTargetUid)
            local holdingAny = isHoldingEgg() or weAreCarrying
            if returnTripInProgress and not holdingAny then
                handleEggDropped(autoReturnTargetUid)
            elseif not returnTripInProgress and holdingTarget then
                startReturnTrip()
            end
        end

        if listDirty then
            listDirty = false
            pcall(renderFarmableEggs)
        end

        if halloweenEngine and halloweenEngine.fishing and halloweenEngine.fishing.logDirty then
            pcall(halloweenEngine.fishing.refreshLog)
        end

        -- Rebuild the live list event-driven when the world changed (folder hooks / filter
        -- changes). When idle or fishing, use a relaxed 15s fallback to eliminate 1 Hz DOM churn.
        if tabHalloween and tabHalloween.Visible and renderHalloweenEggs then
            local now = os.clock()
            local isFishing = halloweenEngine and halloweenEngine.fishing and halloweenEngine.fishing.running
            local fallback = isFishing and 30.0 or (halloweenEngine.hwRenderEvery or 15.0)
            if halloweenEngine.hwListDirty or (now - (halloweenEngine.hwLastRenderAt or 0)) >= fallback then
                halloweenEngine.hwListDirty = false
                halloweenEngine.hwLastRenderAt = now
                pcall(renderHalloweenEggs)
            end
        end

        -- Instant Recovery gentle safety fallback (0.3s throttled = 0 CPU cost)
        if RECOVERY_CONFIG and RECOVERY_CONFIG.Enabled and executeInstantRecovery then
            local char = LocalPlayer and LocalPlayer.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            if hum and (hum.PlatformStand or hum.Sit) then
                executeInstantRecovery("LoopFallback")
            end
        end
    end
end)

-- Background initialization (Workspace ESP & Push Monitor + 30s Overworld safety fallback)
task.spawn(function()
    task.wait(0.2)
    startPushMonitor()
    pcall(syncEggSnapshot) -- Immediate server snapshot hydration on initial start
    pcall(syncAreaEggSlotsESP) -- Supplement with local 3D positions

    while not _G.EggGoToUI_Stop do
        task.wait(30.0)
        local inHw = (LocalPlayer and LocalPlayer:GetAttribute("InHalloweenDimension") == true)
            or (Workspace:FindFirstChild("HalloweenDimension") ~= nil)
        if not inHw then
            pcall(syncEggSnapshot)
        end
    end
end)

-- ============================================================================
-- INTERACTION & CLEANUP HANDLERS
-- ============================================================================

-- Tab switching handler (ready for modular tab additions)
local function switchTab(tabName)
    closeCurrentDropdown()
    tabEggs.Visible = (tabName == "Eggs")
    tabUtility.Visible = (tabName == "Utility")
    tabHalloween.Visible = (tabName == "Halloween")

    tabBtnEggs.BackgroundColor3 = (tabName == "Eggs") and Color3.fromRGB(45, 100, 160) or Color3.fromRGB(35, 42, 60)
    tabBtnEggs.TextColor3 = (tabName == "Eggs") and Color3.new(1, 1, 1) or Color3.fromRGB(150, 170, 200)

    tabBtnUtility.BackgroundColor3 = (tabName == "Utility") and Color3.fromRGB(45, 100, 160) or Color3.fromRGB(35, 42, 60)
    tabBtnUtility.TextColor3 = (tabName == "Utility") and Color3.new(1, 1, 1) or Color3.fromRGB(150, 170, 200)

    tabBtnHalloween.BackgroundColor3 = (tabName == "Halloween") and Color3.fromRGB(200, 95, 25) or Color3.fromRGB(35, 42, 60)
    tabBtnHalloween.TextColor3 = (tabName == "Halloween") and Color3.new(1, 1, 1) or Color3.fromRGB(150, 170, 200)

    if tabName == "Eggs" then
        requestListUpdate()
    elseif tabName == "Halloween" then
        halloweenEngine.hwListDirty = false
        halloweenEngine.hwLastRenderAt = os.clock()
        if renderHalloweenEggs then pcall(renderHalloweenEggs) end
        if halloweenEngine.fishing and halloweenEngine.fishing.refreshLog then
            halloweenEngine.fishing.logDirty = true
            pcall(halloweenEngine.fishing.refreshLog)
        end
    end
end

addConnection(tabBtnEggs.MouseButton1Click:Connect(function()
    switchTab("Eggs")
end))

addConnection(tabBtnUtility.MouseButton1Click:Connect(function()
    switchTab("Utility")
end))

addConnection(tabBtnHalloween.MouseButton1Click:Connect(function()
    switchTab("Halloween")
end))

-- Menu visibility toggle
local function toggleMenuVisible()
    if openDropdown then closeCurrentDropdown() end
    main.Visible = not main.Visible
end

addConnection(menuToggleBtn.MouseButton1Click:Connect(toggleMenuVisible))

-- Copy JSON handler (Exports full egg list to clipboard)
if copyJsonBtn then
    addConnection(copyJsonBtn.MouseButton1Click:Connect(function()
        local okExport, count = exportEggListJson()
        if okExport then
            copyJsonBtn.Text = "✓ Copied!"
            copyJsonBtn.TextColor3 = Color3.fromRGB(120, 255, 150)
            task.delay(1.5, function()
                if copyJsonBtn and copyJsonBtn.Parent then
                    copyJsonBtn.Text = "Copy JSON"
                    copyJsonBtn.TextColor3 = Color3.fromRGB(210, 230, 255)
                end
            end)
        else
            copyJsonBtn.Text = "Failed"
            copyJsonBtn.TextColor3 = Color3.fromRGB(255, 120, 120)
            task.delay(1.5, function()
                if copyJsonBtn and copyJsonBtn.Parent then
                    copyJsonBtn.Text = "Copy JSON"
                    copyJsonBtn.TextColor3 = Color3.fromRGB(210, 230, 255)
                end
            end)
        end
    end))
end

-- Full cleanup routine
local function fullCleanup()
    if openDropdown then closeCurrentDropdown() end
    _G.EggGoToUI_Stop = true
    velocityEnabled = false
    activeWalkToken = (activeWalkToken or 0) + 1
    autoReturnActive = false
    returnTripInProgress = false
    if stopAutoPickupSpam then stopAutoPickupSpam() end
    if stopWalking then stopWalking() end
    if halloweenEngine then
        if halloweenEngine.autoFarm and halloweenEngine.autoFarm.stop then
            pcall(function() halloweenEngine.autoFarm.stop("Menu Closed") end)
        end
        if halloweenEngine.fishing and halloweenEngine.fishing.stop then
            pcall(function() halloweenEngine.fishing.stop("Menu Closed") end)
        end
    end
    pcall(function()
        local ch = LocalPlayer and LocalPlayer.Character
        local hum = ch and ch:FindFirstChildOfClass("Humanoid")
        if hum then
            hum:Move(Vector3.zero, false)
            local normalSpeed = (savedWalkSpeed and savedWalkSpeed < 100) and savedWalkSpeed or 16.0
            pcall(function() hum.WalkSpeed = normalSpeed end)
        end
    end)
    disconnectAll()
    if recoveryConnections then
        for _, conn in ipairs(recoveryConnections) do
            pcall(function() conn:Disconnect() end)
        end
        table.clear(recoveryConnections)
    end
    if halloweenEngine and halloweenEngine.hwFolderConns then
        for _, conn in ipairs(halloweenEngine.hwFolderConns) do
            pcall(function() conn:Disconnect() end)
        end
        table.clear(halloweenEngine.hwFolderConns)
    end

    if screenGui and screenGui.Parent then
        pcall(function() screenGui:Destroy() end)
    end

    if _G.EggGoToUI_Cleanup == fullCleanup then
        _G.EggGoToUI_Cleanup = nil
    end

    print("[EggGoToUI v11] Full cleanup completed.")
end

_G.EggGoToUI_Cleanup = fullCleanup
addConnection(closeBtn.MouseButton1Click:Connect(fullCleanup))

print("[EggGoToUI v11] Pure UI scaffold loaded successfully.")

end) -- end pcall

if not ok then
    warn("[EggGoToUI v11] FAILED TO LOAD: " .. tostring(err))
end