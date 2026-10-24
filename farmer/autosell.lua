--[[
    Standalone Auto Sell Eggs
    - Small independent UI
    - Scans unplaced EggInventory records from FetchProfile
    - Sells known-rarity eggs strictly below the selected threshold
    - Keeps Unknown-rarity eggs and entries without verified UIDs
    - Hard-keeps plain "Egg" / "Unknown Egg" names (event/new/base)
    - Uses RE/PetSatchel/SellSelection with { Eggs = { UIDs }, Assets = {} }
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer or Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

if _G.StandaloneAutoSell_Cleanup then
    pcall(_G.StandaloneAutoSell_Cleanup)
end

local function getUiParent()
    if typeof(gethui) == "function" then
        local ok, parent = pcall(gethui)
        if ok and parent then return parent end
    end
    return PlayerGui or CoreGui
end

local function getNetRemote(name)
    local packages = ReplicatedStorage:FindFirstChild("Packages")
    local networking = packages and packages:FindFirstChild("Networking")
    local remote = networking and networking:FindFirstChild(name)
    return remote or ReplicatedStorage:FindFirstChild(name, true)
end

local Remotes = {
    FetchProfile = getNetRemote("RF/ProfileMirror/FetchProfile"),
    SellSelection = getNetRemote("RE/PetSatchel/SellSelection"),
}

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

local PET_RARITY_PRESETS = {
    -- Divine
    ["ArchAngel"]="Divine", ["World Burner"]="Divine", ["Archdemon Dragon"]="Divine",
    ["Unicorn"]="Divine", ["Kitsune"]="Divine", ["Nightflame"]="Divine", ["Godzilla"]="Divine",
    ["Nuclear Mantis"]="Divine", ["Cthulhu"]="Divine", ["Luminous Cthulhu"]="Divine",
    ["Shattered Colossus"]="Divine", ["Dreadscale"]="Divine", ["Mecha Dreadscale"]="Divine",
    ["Depths Riptide Octopus"]="Divine", ["Aetheron"]="Divine", ["Octophant"]="Divine",
    ["Voidseer Pumpkin"]="Divine",

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
    ["Graveyard Brute"]="Secret", ["BloodBloom"]="Secret", ["Werewolf"]="Secret", ["Pumpkin Golem"]="Secret",

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
    ["Hexed Pumpkin"]="Cosmic",

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
    ["Candy Corn"]="Legendary", ["Witch Pumpkin"]="Legendary",

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
    "Halloween Egg",
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
    ["halloween"]              = "Secret",
    ["halloween egg"]          = "Secret",
    -- deliberately NO ["egg"] = "Common" so plain base eggs never get a sellable default
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

    -- Halloween Egg
    ["Voidseer Pumpkin"] = "Halloween Egg",
    ["Hexed Pumpkin"] = "Halloween Egg",
    ["Graveyard Brute"] = "Halloween Egg",
    ["BloodBloom"] = "Halloween Egg",
    ["Werewolf"] = "Halloween Egg",
    ["Candy Corn"] = "Halloween Egg",
    ["Witch Pumpkin"] = "Halloween Egg",
    ["Pumpkin Golem"] = "Halloween Egg",

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


local State = {
    BagEggs = {},
    SellBelowRarity = "Secret",
    SellInterval = 600,          -- default 600s as requested
    AutoSellActive = false,
    AutoSellToken = 0,
}
local logLines = {}
local scanBusy = false
local guiAlive = true
local logBox = nil

local function appendLog(message)
    local line = os.date("%H:%M:%S") .. " " .. tostring(message)
    table.insert(logLines, line)
    while #logLines > 80 do table.remove(logLines, 1) end
    print("[StandaloneAutoSell] " .. line)
    if logBox and logBox.Parent then
        local first = math.max(1, #logLines - 8)
        local visible = {}
        for i = first, #logLines do table.insert(visible, logLines[i]) end
        logBox.Text = table.concat(visible, "\n")
        logBox.CursorPosition = -1
    end
end


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

local speciesToEggMap = {}
local speciesToRarityMap = {}
local rarityIdToName = {}
local speciesConfigIndexReady = false

local function canonicalRarityText(text)
    local compact = tostring(text or ""):lower():gsub("[^%w]", "")
    compact = compact:gsub("^rarityid", ""):gsub("^rarity", ""):gsub("^tier", ""):gsub("rarity$", "")
    for name in pairs(RARITY_RANK) do
        if name ~= "Unknown" and compact == name:lower() then return name end
    end
    return nil
end

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

                    if type(data.Rarity) == "table" and rarityName then
                        for _, idKey in ipairs({ "_id", "Id", "ID", "Key", "Value" }) do
                            local rarityId = data.Rarity[idKey]
                            if rarityId ~= nil then
                                local idText = tostring(rarityId):lower()
                                local canonical = canonicalRarityText(rarityName) or tostring(rarityName)
                                rarityIdToName[idText] = canonical
                                rarityIdToName[idText:gsub("[^%w]", "")] = canonical
                            end
                        end
                    elseif type(data.Rarity) == "string" and rarityName then
                        local rarityKey = data.Rarity:lower()
                        local canonical = canonicalRarityText(rarityName) or tostring(rarityName)
                        rarityIdToName[rarityKey] = canonical
                        rarityIdToName[rarityKey:gsub("[^%w]", "")] = canonical
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
    speciesConfigIndexReady = true
end
task.spawn(indexSpeciesConfigs)

local function metadataText(value)
    if type(value) == "string" or type(value) == "number" then
        local text = tostring(value):gsub("^%s*", ""):gsub("%s*$", "")
        return text ~= "" and text or nil
    end
    if type(value) == "table" then
        for _, key in ipairs({ "DisplayName", "Name", "RarityName", "RarityId", "EggName", "EggType", "Species", "Value", "_id", "Id", "Tier" }) do
            local result = metadataText(value[key])
            if result then return result end
        end
    end
    return nil
end

local function readMetadataField(data, keys)
    if type(data) ~= "table" then return nil end
    local sources = { data }
    for _, sourceKey in ipairs({ "Attributes", "Data", "Metadata", "EggData", "Details" }) do
        local source = data[sourceKey]
        if type(source) == "table" then table.insert(sources, source) end
    end
    for _, source in ipairs(sources) do
        for _, key in ipairs(keys) do
            local value = source[key]
            if value ~= nil and value ~= "" then return value end
        end
    end
    return nil
end

local RARITY_FIELDS = { "Rarity", "RarityId", "RarityName", "Tier", "PetRarity", "EggRarity", "RarityType" }
local EGG_GROUP_FIELDS = { "EggType", "EggName", "EggDisplayName", "SourceEgg", "OriginEgg", "BiomeEgg", "EggCategory", "Egg" }
local EGG_NAME_FIELDS = { "DisplayName", "AssetCategory", "Name", "SpeciesName", "PetName", "Species", "AssetName", "EggDisplayName", "EggName", "EggType" }
local UID_FIELDS = { "EggUid", "EggUID", "Uid", "UID", "UniqueId", "UniqueID", "InstanceId", "InventoryUid" }

local function normalizeRarity(value)
    local text = metadataText(value)
    if not text then return nil end
    local byId = rarityIdToName[text:lower()]
    if not byId then byId = rarityIdToName[text:lower():gsub("[^%w]", "")] end
    if byId then return canonicalRarityText(byId) or byId end
    return canonicalRarityText(text)
end

local function normalizeEggLookupName(name)
    local text = tostring(name or ""):gsub("%s*%([%d,%.]+%s*[Kk][Gg]%)%s*$", "")
    text = text:lower():gsub("^%s*", ""):gsub("%s*$", ""):gsub("%s+", " ")
    text = text:gsub("%s*egg%s*$", "")
    return text
end

local function canonicalEggGroupName(value)
    local text = metadataText(value)
    if not text or tonumber(text) then return nil end
    local cleaned = cleanEggName(text)
    local lookup = normalizeEggLookupName(cleaned)
    if lookup == "" or lookup == "unknown" then return nil end
    for _, knownName in ipairs(KNOWN_BIOME_EGGS) do
        if normalizeEggLookupName(knownName) == lookup then return knownName end
    end
    for _, knownName in ipairs(ALL_BIOMES_AND_EVENTS) do
        if normalizeEggLookupName(knownName) == lookup then return knownName end
    end
    if lookup == "egg" or lookup == "unknown egg" then return nil end
    return cleaned
end

local function readEggGroupMetadata(data)
    for _, key in ipairs(EGG_GROUP_FIELDS) do
        local candidate = readMetadataField(data, { key })
        local normalized = canonicalEggGroupName(candidate)
        if normalized then return normalized end
    end
    return nil
end

local function readEggRawName(data)
    for _, key in ipairs(EGG_NAME_FIELDS) do
        local text = metadataText(readMetadataField(data, { key }))
        if text then
            local low = text:lower()
            if not (key == "AssetCategory" and tonumber(text)) and low ~= "unknown" and low ~= "egg" then
                return text
            end
        end
    end
    return nil
end

-- Standalone rarity cache (no external event hooks or snapshot dependencies)
local rarityByUid = {}

local function resolveEggBiomeAndRarity(rawNameOrSpecies, directRarity, uid, directEggGroup)
    local raw = metadataText(rawNameOrSpecies) or "Unknown Egg"
    raw = raw:gsub("%s*%([%d,%.]+%s*[Kk][Gg]%)%s*$", "")
    raw = raw:gsub("^%s*", ""):gsub("%s*$", "")
    if raw == "" then raw = "Unknown Egg" end
    local low = raw:lower()

    local explicitGroup = canonicalEggGroupName(directEggGroup)
    if explicitGroup and (explicitGroup:lower() == "egg" or explicitGroup:lower() == "unknown egg") then
        explicitGroup = nil
    end

    local function getRarity(nameKey, groupKey)
        local direct = normalizeRarity(directRarity)
        if direct then return direct end

        local uidRarity = uid and normalizeRarity(rarityByUid[tostring(uid)])
        if uidRarity then return uidRarity end

        local nLow = nameKey and tostring(nameKey):lower()
        if nLow and speciesToRarityMap[nLow] then
            local configured = normalizeRarity(speciesToRarityMap[nLow])
            if configured then return configured end
        end
        if nLow then
            for presetName, presetRarity in pairs(PET_RARITY_PRESETS) do
                if presetName:lower() == nLow then
                    local preset = normalizeRarity(presetRarity)
                    if preset then return preset end
                end
            end
            local eggDefault = EGG_NAME_TO_DEFAULT_RARITY[nLow]
            if not eggDefault then
                eggDefault = EGG_NAME_TO_DEFAULT_RARITY[nLow:gsub("%s*egg%s*$", "")]
            end
            if eggDefault then
                local normalized = normalizeRarity(eggDefault)
                if normalized then return normalized end
            end
        end

        -- Use a type-level default only when the record name itself is that egg type;
        -- do not assign an egg's base rarity to an unrelated species inside it.
        local groupLow = groupKey and tostring(groupKey):lower()
        if nLow and groupLow and (nLow == groupLow or nLow == groupLow:gsub("%s*egg%s*$", "")) then
            local groupDefault = EGG_NAME_TO_DEFAULT_RARITY[groupLow]
                or EGG_NAME_TO_DEFAULT_RARITY[groupLow:gsub("%s*egg%s*$", "")]
            if groupDefault then
                local normalized = normalizeRarity(groupDefault)
                if normalized then return normalized end
            end
        end
        return "Unknown"
    end

    -- Explicit inventory egg-type fields outrank inferred species-to-biome mappings.
    if explicitGroup then
        return explicitGroup, getRarity(raw, explicitGroup), raw
    end

    -- 1. Known biome/event egg exact match.
    for _, bEgg in ipairs(KNOWN_BIOME_EGGS) do
        local bLow = bEgg:lower()
        local bBase = bLow:gsub("%s*egg%s*$", "")
        if low == bLow or low == bBase then
            return bEgg, getRarity(raw, bEgg), raw
        end
    end

    -- 2. Exact species match from the static species-to-egg map.
    for species, eggGroup in pairs(STATIC_SPECIES_TO_BIOME_EGG) do
        if species:lower() == low then
            return eggGroup, getRarity(species, eggGroup), species
        end
    end

    -- 3. Exact species match from loaded game configs.
    if speciesToEggMap[low] then
        local eggGroup = canonicalEggGroupName(speciesToEggMap[low]) or cleanEggName(metadataText(speciesToEggMap[low]) or "Unknown Egg")
        return eggGroup, getRarity(raw, eggGroup), raw
    end

    -- 4. Known egg-type substring match.
    for _, bEgg in ipairs(KNOWN_BIOME_EGGS) do
        local bLow = bEgg:lower()
        local bBase = bLow:gsub("%s*egg%s*$", "")
        if bBase ~= "" and low:find(bBase, 1, true) then
            return bEgg, getRarity(raw, bEgg), raw
        end
    end

    -- 5. Species substring match, longest first to avoid short-name collisions.
    local sortedSpecies = {}
    for species in pairs(STATIC_SPECIES_TO_BIOME_EGG) do table.insert(sortedSpecies, species) end
    table.sort(sortedSpecies, function(a, b) return #a > #b end)
    for _, species in ipairs(sortedSpecies) do
        local speciesLow = species:lower()
        if low:find(speciesLow, 1, true) or speciesLow:find(low, 1, true) then
            local eggGroup = STATIC_SPECIES_TO_BIOME_EGG[species]
            return eggGroup, getRarity(species, eggGroup), species
        end
    end

    -- 6. Preserve an unrecognized type as its own group and never guess Common.
    local fallbackGroup = cleanEggName(raw)
    return fallbackGroup, getRarity(raw, fallbackGroup), raw
end


-- Resolve only sale-safe rarity evidence. The older grouping resolver below may
-- infer a useful display rarity from presets/name matches, but inferred values
-- must never authorize a destructive sell request.
local function resolveVerifiedRarity(data, rawName, uid)
    local observed = {}
    local origins = {}
    local unresolvedPrimary = false

    local function add(value, origin)
        local rarity = normalizeRarity(value)
        if rarity then
            observed[rarity] = true
            origins[rarity] = origins[rarity] or {}
            origins[rarity][origin] = true
        end
    end

    if type(data) == "table" then
        local sources = { data }
        for _, sourceKey in ipairs({ "Attributes", "Data", "Metadata", "EggData", "Details" }) do
            local source = data[sourceKey]
            if type(source) == "table" then table.insert(sources, source) end
        end

        for _, source in ipairs(sources) do
            for _, key in ipairs(RARITY_FIELDS) do
                local value = source[key]
                if value ~= nil and value ~= "" then
                    local rarity = normalizeRarity(value)
                    if rarity then
                        add(value, "inventory:" .. key)
                    elseif key == "Rarity" or key == "RarityId" or key == "RarityName"
                        or key == "PetRarity" or key == "EggRarity" or key == "RarityType" then
                        -- An explicit but unrecognized rarity is not permission to
                        -- fall back to a guessed species preset.
                        unresolvedPrimary = true
                    end
                end
            end
        end
    end

    local uidRarity = uid and normalizeRarity(rarityByUid[tostring(uid)])
    if uidRarity then add(uidRarity, "matching-uid rarity event") end

    -- Game config fallback is permitted only for an exact full-name match.
    -- Do not use the older fuzzy species match for sale authorization.
    local exactName = tostring(rawName or "")
        :gsub("%s*%([%d,%.]+%s*[Kk][Gg]%)%s*$", "")
        :gsub("^%s*", ""):gsub("%s*$", "")
        :lower():gsub("%s+", " ")
    local exactConfigRarity = normalizeRarity(speciesToRarityMap[exactName])
    if exactConfigRarity then add(exactConfigRarity, "exact game config") end

    local distinctCount, soleRarity = 0, nil
    for rarity in pairs(observed) do
        distinctCount = distinctCount + 1
        soleRarity = rarity
    end

    if unresolvedPrimary then
        return nil, "explicit rarity field is unrecognized"
    end
    if distinctCount > 1 then
        return nil, "rarity sources conflict"
    end
    if distinctCount == 0 then
        return nil, "no verified rarity source"
    end

    local originNames = {}
    for origin in pairs(origins[soleRarity] or {}) do table.insert(originNames, origin) end
    table.sort(originNames)
    return soleRarity, table.concat(originNames, "+")
end

local function hasPlacement(data)
    local placement = readMetadataField(data, { "Placement", "PlacedAt" })
    if placement == nil or placement == false or placement == "" or placement == 0 then
        local placedFlag = readMetadataField(data, { "IsPlaced", "Placed" })
        return placedFlag == true or placedFlag == 1 or tostring(placedFlag):lower() == "true"
    end
    if type(placement) == "table" and next(placement) == nil then return false end
    return true
end

-- Hard keep for plain base / unknown egg names so event or new eggs never get sold by accident.
local function isHardKeepName(egg)
    local candidates = { egg.RawName, egg.GroupName, egg.Species }
    for _, cand in ipairs(candidates) do
        if cand then
            local n = tostring(cand):lower()
                :gsub("%s*%([%d,%.]+%s*[Kk][Gg]%)%s*$", "")
                :gsub("^%s*", ""):gsub("%s*$", "")
                :gsub("%s+", " ")
            local base = n:gsub("%s*egg%s*$", "")
            if base == "" or base == "egg" or base == "unknown" or n == "egg" or n == "unknown egg" then
                return true
            end
        end
    end
    return false
end

local function scanInventory()
    local configWaitStart = os.clock()
    while not speciesConfigIndexReady and os.clock() - configWaitStart < 1.5 do
        task.wait(0.05)
    end

    if not Remotes.FetchProfile then
        return nil, "RF/ProfileMirror/FetchProfile was not found. Nothing was sold."
    end

    local profile
    for attempt = 1, 3 do
        local ok, result = pcall(function()
            return Remotes.FetchProfile:InvokeServer(LocalPlayer)
        end)
        if ok and type(result) == "table" then
            profile = result
            break
        end
        task.wait(0.2)
    end
    if not profile then
        local ok, result = pcall(function() return Remotes.FetchProfile:InvokeServer() end)
        if ok and type(result) == "table" then profile = result end
    end
    if type(profile) ~= "table" then
        return nil, "Profile scan failed. Nothing was sold."
    end

    local inventory = profile.EggInventory
        or (type(profile.Data) == "table" and profile.Data.EggInventory)
        or (type(profile.ProfileData) == "table" and profile.ProfileData.EggInventory)
    if type(inventory) ~= "table" then
        return nil, "EggInventory was not found in the profile. Nothing was sold."
    end

    local eggs, seenUids = {}, {}
    local unknownCount, missingUidCount = 0, 0
    -- A large satchel takes ~0.3 ms of string work per egg, so a 1000-egg scan
    -- would freeze a frame for ~300 ms. Resolve the records in ~2 ms slices so a
    -- scan never stutters the client, however big the bag gets. The record cap
    -- keeps the slice bounded even if the clock does not advance per record.
    local SLICE_MIN_RECORDS = 64
    local SLICE_MAX_RECORDS = 128
    local SLICE_SECONDS = 0.004
    local sliceRecords = 0
    local sliceStart = os.clock()
    for inventoryKey, data in pairs(inventory) do
        sliceRecords = sliceRecords + 1
        if sliceRecords >= SLICE_MIN_RECORDS
            and (sliceRecords >= SLICE_MAX_RECORDS or os.clock() - sliceStart >= SLICE_SECONDS) then
            task.wait()
            sliceStart = os.clock()
            sliceRecords = 0
            if not guiAlive then
                return nil, "Window closed during the scan. Nothing was sold."
            end
        end
        if type(data) == "table" and not hasPlacement(data) then
            local dataUid = metadataText(readMetadataField(data, UID_FIELDS))
            local keyUid = type(inventoryKey) == "string" and inventoryKey ~= "" and inventoryKey or nil
            local uid = dataUid or keyUid
            local rawName = readEggRawName(data) or readEggGroupMetadata(data) or "Unknown Egg"
            local directGroup = readEggGroupMetadata(data)
            local directRarity = readMetadataField(data, RARITY_FIELDS)
            local groupName, inferredRarity, species = resolveEggBiomeAndRarity(rawName, directRarity, uid, directGroup)
            local verifiedRarity, raritySource = resolveVerifiedRarity(data, rawName, uid)
            local canSell = uid ~= nil and tostring(uid) ~= "" and not tostring(uid):match("^unresolved_")
            local uidText = canSell and tostring(uid) or nil

            if uidText and seenUids[uidText] then
                -- Duplicate profile entry; keep the first record only.
            else
                if uidText then seenUids[uidText] = true end
                -- Keep heuristic rarity for diagnostics only. Auto-sell sees Unknown
                -- unless the rarity is supported by consistent metadata/config evidence.
                local rarityName = verifiedRarity or "Unknown"
                if not verifiedRarity then unknownCount = unknownCount + 1 end
                if not canSell then missingUidCount = missingUidCount + 1 end
                local record = {
                    Uid = uidText,
                    CanSell = canSell,
                    RawName = rawName,
                    GroupName = groupName or cleanEggName(rawName),
                    Species = species or rawName,
                    Rarity = rarityName,
                    RarityVerified = verifiedRarity ~= nil,
                    RaritySource = raritySource,
                    InferredRarity = normalizeRarity(inferredRarity) or "Unknown",
                }
                -- Resolved here, inside the sliced loop, so the eligibility pass
                -- below does not re-run the name matcher once per egg.
                record.HardKeep = isHardKeepName(record)
                table.insert(eggs, record)
            end
        end
    end
    return eggs, nil, unknownCount, missingUidCount
end

local function getSellableEggUids(eggs)
    local thresholdRank = RARITY_RANK[State.SellBelowRarity] or 0
    local seen, uids = {}, {}
    local unknownCount, missingUidCount = 0, 0
    for _, egg in ipairs(eggs or State.BagEggs) do
        local rarity = normalizeRarity(egg.Rarity) or "Unknown"
        local rank = RARITY_RANK[rarity]
        local hardKeep = egg.HardKeep
        if hardKeep == nil then hardKeep = isHardKeepName(egg) end
        if hardKeep or egg.RarityVerified ~= true or rarity == "Unknown" or not rank then
            -- Fail closed: guessed, legacy, unverified, or plain "Egg" names are never sold.
            unknownCount = unknownCount + 1
        elseif rank < thresholdRank then
            local uid = egg.CanSell and egg.Uid or nil
            uid = uid ~= nil and tostring(uid) or ""
            if uid ~= "" and not uid:match("^unresolved_") then
                if not seen[uid] then
                    seen[uid] = true
                    table.insert(uids, uid)
                end
            else
                missingUidCount = missingUidCount + 1
            end
        end
    end
    return uids, unknownCount, missingUidCount
end

-- One scan calls the eligibility pass from applyScan, updatePreview and the loop
-- itself. Keep the result while the bag and the threshold are unchanged: it is a
-- pure function of those two, and a 1000-egg bag makes a wasted pass cost ~6 ms.
local sellableMemoBag, sellableMemoRarity
local sellableMemoUids, sellableMemoUnknown, sellableMemoMissing
local function getSellableEggUidsCached(eggs)
    if sellableMemoBag == eggs and sellableMemoRarity == State.SellBelowRarity then
        return sellableMemoUids, sellableMemoUnknown, sellableMemoMissing
    end
    local uids, unknownCount, missingUidCount = getSellableEggUids(eggs)
    sellableMemoBag, sellableMemoRarity = eggs, State.SellBelowRarity
    sellableMemoUids, sellableMemoUnknown, sellableMemoMissing = uids, unknownCount, missingUidCount
    return uids, unknownCount, missingUidCount
end

-- Avoid resending the same UIDs while the profile catches up with a SellSelection
-- request. Since FireServer has no acknowledgement, pending entries expire so a
-- failed request can be retried later.
local pendingSellUids = {}
local PENDING_SELL_CONFIRM_TIMEOUT = 45

local function reconcilePendingSellUids(eggs)
    if next(pendingSellUids) == nil then return end   -- nothing pending: no pass needed
    local presentUids = {}
    for _, egg in ipairs(eggs or {}) do
        if egg.Uid and egg.Uid ~= "" then presentUids[tostring(egg.Uid)] = true end
    end

    local now = os.clock()
    for uid, sentAt in pairs(pendingSellUids) do
        if not presentUids[uid] or now - sentAt >= PENDING_SELL_CONFIRM_TIMEOUT then
            pendingSellUids[uid] = nil
        end
    end
end


-- ============================== COMPACT UI ==============================
local gui = Instance.new("ScreenGui")
gui.Name = "StandaloneAutoSellEggs"
gui.ResetOnSpawn = false
gui.DisplayOrder = 9999
gui.Parent = getUiParent()

local frame = Instance.new("Frame")
frame.Name = "Main"
frame.Size = UDim2.fromOffset(370, 292)
frame.Position = UDim2.new(1, -386, 0.5, -146)
frame.BackgroundColor3 = Color3.fromRGB(18, 22, 32)
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)
local outline = Instance.new("UIStroke", frame)
outline.Color = Color3.fromRGB(70, 120, 175)
outline.Thickness = 1.2

local topBar = Instance.new("Frame")
topBar.Size = UDim2.new(1, 0, 0, 30)
topBar.BackgroundColor3 = Color3.fromRGB(30, 40, 58)
topBar.BorderSizePixel = 0
topBar.Active = true
topBar.Parent = frame
Instance.new("UICorner", topBar).CornerRadius = UDim.new(0, 8)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -42, 1, 0)
title.Position = UDim2.fromOffset(10, 0)
title.BackgroundTransparency = 1
title.Text = "♻ AUTO SELL EGGS"
title.TextColor3 = Color3.fromRGB(225, 238, 255)
title.Font = Enum.Font.GothamBold
title.TextSize = 12
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = topBar

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.fromOffset(24, 22)
closeBtn.Position = UDim2.new(1, -29, 0, 4)
closeBtn.BackgroundColor3 = Color3.fromRGB(145, 47, 47)
closeBtn.Text = "X"
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 11
closeBtn.Parent = topBar
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 4)

-- Simple draggable title bar.
local dragInputConnection
do
    local dragging, dragStart, startPos = false, nil, nil
    topBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = frame.Position
        end
    end)
    topBar.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
    dragInputConnection = UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
end

local thresholdBtn = Instance.new("TextButton")
thresholdBtn.Size = UDim2.fromOffset(145, 26)
thresholdBtn.Position = UDim2.fromOffset(8, 38)
thresholdBtn.BackgroundColor3 = Color3.fromRGB(45, 42, 61)
thresholdBtn.Text = "Sell below: Secret ▼"
thresholdBtn.TextColor3 = Color3.fromRGB(255, 100, 100)
thresholdBtn.Font = Enum.Font.GothamBold
thresholdBtn.TextSize = 10
thresholdBtn.Parent = frame
Instance.new("UICorner", thresholdBtn).CornerRadius = UDim.new(0, 4)

local intervalLabel = Instance.new("TextLabel")
intervalLabel.Size = UDim2.fromOffset(48, 26)
intervalLabel.Position = UDim2.fromOffset(160, 38)
intervalLabel.BackgroundTransparency = 1
intervalLabel.Text = "Loop (s)"
intervalLabel.TextColor3 = Color3.fromRGB(190, 205, 225)
intervalLabel.Font = Enum.Font.Gotham
intervalLabel.TextSize = 10
intervalLabel.Parent = frame

local intervalBox = Instance.new("TextBox")
intervalBox.Size = UDim2.fromOffset(42, 26)
intervalBox.Position = UDim2.fromOffset(207, 38)
intervalBox.BackgroundColor3 = Color3.fromRGB(9, 13, 20)
intervalBox.TextColor3 = Color3.fromRGB(240, 244, 255)
intervalBox.Text = tostring(State.SellInterval)   -- shows 600
intervalBox.ClearTextOnFocus = false
intervalBox.Font = Enum.Font.Code
intervalBox.TextSize = 11
intervalBox.Parent = frame
Instance.new("UICorner", intervalBox).CornerRadius = UDim.new(0, 4)

local scanBtn = Instance.new("TextButton")
scanBtn.Size = UDim2.fromOffset(48, 26)
scanBtn.Position = UDim2.fromOffset(255, 38)
scanBtn.BackgroundColor3 = Color3.fromRGB(53, 85, 125)
scanBtn.Text = "SCAN"
scanBtn.TextColor3 = Color3.new(1, 1, 1)
scanBtn.Font = Enum.Font.GothamBold
scanBtn.TextSize = 10
scanBtn.Parent = frame
Instance.new("UICorner", scanBtn).CornerRadius = UDim.new(0, 4)

local preview = Instance.new("TextLabel")
preview.Size = UDim2.new(1, -16, 0, 30)
preview.Position = UDim2.fromOffset(8, 68)
preview.BackgroundTransparency = 1
preview.Text = "Scan first. Only verified, consistent rarities can be sold; guessed/new/plain Egg names are kept."
preview.TextColor3 = Color3.fromRGB(184, 200, 221)
preview.Font = Enum.Font.Gotham
preview.TextSize = 9
preview.TextWrapped = true
preview.TextXAlignment = Enum.TextXAlignment.Left
preview.Parent = frame

local startBtn = Instance.new("TextButton")
startBtn.Size = UDim2.fromOffset(112, 26)
startBtn.Position = UDim2.fromOffset(8, 100)
startBtn.BackgroundColor3 = Color3.fromRGB(35, 125, 72)
startBtn.Text = "▶ START LOOP"
startBtn.TextColor3 = Color3.new(1, 1, 1)
startBtn.Font = Enum.Font.GothamBold
startBtn.TextSize = 10
startBtn.Parent = frame
Instance.new("UICorner", startBtn).CornerRadius = UDim.new(0, 4)

local stopBtn = Instance.new("TextButton")
stopBtn.Size = UDim2.fromOffset(82, 26)
stopBtn.Position = UDim2.fromOffset(126, 100)
stopBtn.BackgroundColor3 = Color3.fromRGB(135, 48, 48)
stopBtn.Text = "STOP"
stopBtn.TextColor3 = Color3.new(1, 1, 1)
stopBtn.Font = Enum.Font.GothamBold
stopBtn.TextSize = 10
stopBtn.Parent = frame
Instance.new("UICorner", stopBtn).CornerRadius = UDim.new(0, 4)

local copyBtn = Instance.new("TextButton")
copyBtn.Size = UDim2.fromOffset(116, 26)
copyBtn.Position = UDim2.fromOffset(214, 100)
copyBtn.BackgroundColor3 = Color3.fromRGB(67, 65, 105)
copyBtn.Text = "COPY LOG"
copyBtn.TextColor3 = Color3.new(1, 1, 1)
copyBtn.Font = Enum.Font.GothamBold
copyBtn.TextSize = 10
copyBtn.Parent = frame
Instance.new("UICorner", copyBtn).CornerRadius = UDim.new(0, 4)

logBox = Instance.new("TextBox")
logBox.Name = "Log"
logBox.Size = UDim2.new(1, -16, 0, 154)
logBox.Position = UDim2.fromOffset(8, 130)
logBox.BackgroundColor3 = Color3.fromRGB(8, 11, 17)
logBox.TextColor3 = Color3.fromRGB(168, 218, 177)
logBox.Font = Enum.Font.Code
logBox.TextSize = 9
logBox.TextXAlignment = Enum.TextXAlignment.Left
logBox.TextYAlignment = Enum.TextYAlignment.Top
logBox.TextWrapped = true
logBox.MultiLine = true
logBox.ClearTextOnFocus = false
logBox.TextEditable = false
logBox.Text = "Ready. Choose a rarity threshold, scan, then start."
logBox.Parent = frame
Instance.new("UICorner", logBox).CornerRadius = UDim.new(0, 5)

local rarityChoices = { "Divine", "Eternal", "Secret", "Cosmic", "Mythic", "Legendary", "Epic", "Rare", "Uncommon", "Common" }
local dropdown = Instance.new("Frame")
dropdown.Name = "RarityDropdown"
dropdown.Size = UDim2.fromOffset(145, #rarityChoices * 21)
dropdown.BackgroundColor3 = Color3.fromRGB(24, 28, 40)
dropdown.BorderSizePixel = 0
dropdown.Visible = false
dropdown.ZIndex = 100
dropdown.Parent = gui
Instance.new("UICorner", dropdown).CornerRadius = UDim.new(0, 5)
local dropLayout = Instance.new("UIListLayout")
dropLayout.SortOrder = Enum.SortOrder.LayoutOrder
dropLayout.Parent = dropdown
Instance.new("UIStroke", dropdown).Color = Color3.fromRGB(75, 95, 130)

local function updatePreview(countdownSeconds)
    local uids, unknownCount, missingUidCount = getSellableEggUidsCached(State.BagEggs)
    local timeInfo
    if State.AutoSellActive and countdownSeconds ~= nil then
        local mins = math.floor(countdownSeconds / 60)
        local secs = countdownSeconds % 60
        timeInfo = string.format(" | Next in %dm %02ds", mins, secs)
    else
        timeInfo = string.format(" | Every %.0fs (10m)", State.SellInterval)
    end
    preview.Text = string.format("Below %s: %d sellable | Hard-kept: %d%s",
        State.SellBelowRarity, #uids, unknownCount, timeInfo)
end

local function applyScan(shouldLog)
    if scanBusy then return false end
    scanBusy = true
    local ok, eggs, err, unknownCount, missingUidCount = pcall(scanInventory)
    scanBusy = false
    if not ok then
        appendLog("SCAN ERROR: " .. tostring(eggs))
        preview.Text = "Scan failed; no eggs were sold. See log."
        return false
    end
    if not eggs then
        if not guiAlive then return false end     -- closed mid-scan: nothing to report
        appendLog("SCAN ERROR: " .. tostring(err))
        preview.Text = "Scan failed; no eggs were sold. See log."
        return false
    end
    State.BagEggs = eggs
    reconcilePendingSellUids(eggs)
    local uids, unknownSkipped, missingUidSkipped = getSellableEggUidsCached(eggs)
    updatePreview()
    if shouldLog then
        appendLog(string.format("Scan complete: %d unplaced eggs; eligible=%d; unverified/unknown/hard-kept=%d; missing UID=%d.",
            #eggs, #uids, unknownCount or unknownSkipped, missingUidCount or missingUidSkipped))
        local heldCount = 0
        for _, egg in ipairs(eggs) do
            local hardKeepEgg = egg.HardKeep
            if hardKeepEgg == nil then hardKeepEgg = isHardKeepName(egg) end
            if (egg.RarityVerified ~= true or hardKeepEgg) and heldCount < 8 then
                heldCount = heldCount + 1
                local guess = egg.InferredRarity and egg.InferredRarity ~= "Unknown"
                    and ("; name-only guess=" .. egg.InferredRarity) or ""
                local reason = isHardKeepName(egg) and "hard-kept plain/base Egg name" or tostring(egg.RaritySource or "unverified rarity")
                appendLog(string.format("SAFETY HOLD: %s (UID=%s)%s; %s.",
                    tostring(egg.RawName), tostring(egg.Uid or "missing"), guess, reason))
            end
        end
        if heldCount >= 8 then appendLog("Additional unverified/hard-kept eggs omitted from scan log.") end
    end
    return true
end

thresholdBtn.MouseButton1Click:Connect(function()
    dropdown.Position = UDim2.fromOffset(thresholdBtn.AbsolutePosition.X, thresholdBtn.AbsolutePosition.Y + thresholdBtn.AbsoluteSize.Y)
    dropdown.Visible = not dropdown.Visible
end)

for index, rarityName in ipairs(rarityChoices) do
    local choice = rarityName
    local option = Instance.new("TextButton")
    option.Size = UDim2.new(1, 0, 0, 21)
    option.BackgroundColor3 = Color3.fromRGB(30, 36, 52)
    option.Text = "  " .. choice
    option.TextColor3 = ({Divine=Color3.fromRGB(255,75,230), Eternal=Color3.fromRGB(75,220,255), Secret=Color3.fromRGB(255,60,60), Cosmic=Color3.fromRGB(180,80,255), Mythic=Color3.fromRGB(255,170,0), Legendary=Color3.fromRGB(255,215,0), Epic=Color3.fromRGB(160,60,220), Rare=Color3.fromRGB(60,140,255), Uncommon=Color3.fromRGB(60,220,90), Common=Color3.fromRGB(180,180,180)})[choice]
    option.Font = Enum.Font.GothamBold
    option.TextSize = 10
    option.TextXAlignment = Enum.TextXAlignment.Left
    option.LayoutOrder = index
    option.ZIndex = 101
    option.Parent = dropdown
    option.MouseButton1Click:Connect(function()
        State.SellBelowRarity = choice
        thresholdBtn.Text = "Sell below: " .. choice .. " ▼"
        thresholdBtn.TextColor3 = option.TextColor3
        dropdown.Visible = false
        updatePreview()
        appendLog("Threshold set to " .. choice .. "; eggs at or above this rarity will be kept.")
    end)
end

intervalBox.FocusLost:Connect(function()
    local value = tonumber(intervalBox.Text)
    if not value then
        intervalBox.Text = tostring(State.SellInterval)
        appendLog("Invalid interval. Kept " .. tostring(State.SellInterval) .. " seconds.")
        return
    end
    State.SellInterval = math.floor(math.clamp(value, 3, 3600) * 10 + 0.5) / 10
    intervalBox.Text = tostring(State.SellInterval)
    updatePreview()
    appendLog(string.format("Loop interval set to %.1f seconds.", State.SellInterval))
end)

scanBtn.MouseButton1Click:Connect(function()
    if scanBusy then appendLog("A scan is already in progress."); return end
    scanBtn.Text = "..."
    task.spawn(function()
        applyScan(true)
        if scanBtn and scanBtn.Parent then scanBtn.Text = "SCAN" end
    end)
end)

startBtn.MouseButton1Click:Connect(function()
    if State.AutoSellActive then return end
    if not Remotes.SellSelection or not Remotes.SellSelection:IsA("RemoteEvent") then
        Remotes.SellSelection = getNetRemote("RE/PetSatchel/SellSelection")
    end
    if not Remotes.SellSelection or not Remotes.SellSelection:IsA("RemoteEvent") then
        appendLog("ERROR: RE/PetSatchel/SellSelection was not found; loop not started.")
        return
    end
    local interval = tonumber(intervalBox.Text)
    if interval then State.SellInterval = math.floor(math.clamp(interval, 3, 3600) * 10 + 0.5) / 10 end
    intervalBox.Text = tostring(State.SellInterval)

    State.AutoSellActive = true
    State.AutoSellToken = State.AutoSellToken + 1
    local token = State.AutoSellToken
    startBtn.Text = "RUNNING..."
    appendLog(string.format("Auto-sell started: below %s, every %.1fs. Guessed, conflicting, unknown, plain Egg, and missing-UID eggs will be kept.", State.SellBelowRarity, State.SellInterval))

    task.spawn(function()
        local consecutiveScanFailures = 0
        local lastNoEligibleState = nil

        while guiAlive and State.AutoSellActive and State.AutoSellToken == token do
            if scanBusy then
                task.wait(0.1)
            else
                -- Do not print a full scan summary every interval; this loop may run for hours.
                local scanned = applyScan(false)
                local waitDuration = State.SellInterval

                if scanned then
                    consecutiveScanFailures = 0
                    if State.AutoSellActive and State.AutoSellToken == token then
                        local candidates, unknownCount, missingUidCount = getSellableEggUidsCached(State.BagEggs)
                        local eggUids = {}
                        local pendingCount = 0
                        for _, uid in ipairs(candidates) do
                            if pendingSellUids[uid] then
                                pendingCount = pendingCount + 1
                            else
                                table.insert(eggUids, uid)
                            end
                        end

                        if #eggUids == 0 then
                            local idleState = pendingCount > 0 and "pending" or "empty"
                            if idleState ~= lastNoEligibleState then
                                if pendingCount > 0 then
                                    appendLog(string.format("Waiting for profile confirmation on %d previously requested egg(s); duplicate UIDs will not be resent for %.0fs.", pendingCount, PENDING_SELL_CONFIRM_TIMEOUT))
                                else
                                    appendLog(string.format("No eligible eggs below %s. Unknown/hard-kept=%d; missing UID kept=%d.", State.SellBelowRarity, unknownCount, missingUidCount))
                                end
                                lastNoEligibleState = idleState
                            end
                        else
                            lastNoEligibleState = nil
                            local BATCH_SIZE = 100
                            local totalBatches = math.ceil(#eggUids / BATCH_SIZE)
                            local sentCount = 0
                            for b = 1, totalBatches do
                                if not guiAlive or not State.AutoSellActive or State.AutoSellToken ~= token then break end
                                local sIdx = (b - 1) * BATCH_SIZE + 1
                                local eIdx = math.min(#eggUids, b * BATCH_SIZE)
                                local chunk = {}
                                for i = sIdx, eIdx do table.insert(chunk, eggUids[i]) end

                                local callOk, callErr = pcall(function()
                                    Remotes.SellSelection:FireServer({ Eggs = chunk, Assets = {} })
                                end)
                                if callOk then
                                    local sentAt = os.clock()
                                    for _, uid in ipairs(chunk) do pendingSellUids[uid] = sentAt end
                                    sentCount = sentCount + #chunk
                                else
                                    appendLog("SELL ERROR: " .. tostring(callErr))
                                end
                                if b < totalBatches then task.wait(0.1) end
                            end
                            appendLog(string.format("SellSelection request sent for %d egg(s) below %s in %d batch(es). Unknown/hard-kept=%d; missing UID kept=%d.",
                                sentCount, State.SellBelowRarity, totalBatches, unknownCount, missingUidCount))
                        end
                    end
                else
                    -- On repeated profile failures, back off to avoid hammering FetchProfile.
                    consecutiveScanFailures = consecutiveScanFailures + 1
                    local backoff = math.min(60, 3 * (2 ^ math.min(consecutiveScanFailures - 1, 5)))
                    waitDuration = math.max(State.SellInterval, backoff)
                    lastNoEligibleState = nil
                    appendLog(string.format("Scan retry delayed %.0fs after failure #%d.", waitDuration, consecutiveScanFailures))
                end

                local waitUntil = os.clock() + waitDuration
                while guiAlive and State.AutoSellActive and State.AutoSellToken == token and os.clock() < waitUntil do
                    local rem = math.max(0, math.ceil(waitUntil - os.clock()))
                    updatePreview(rem)
                    task.wait(math.min(1.0, math.max(0.05, waitUntil - os.clock())))
                end
            end
        end
        if State.AutoSellToken == token then
            State.AutoSellActive = false
            if startBtn and startBtn.Parent then startBtn.Text = "▶ START LOOP" end
            appendLog("Auto-sell loop stopped.")
            updatePreview()
        end
    end)
end)

stopBtn.MouseButton1Click:Connect(function()
    if State.AutoSellActive then
        State.AutoSellActive = false
        State.AutoSellToken = State.AutoSellToken + 1
        appendLog("Stop requested.")
        updatePreview()
    end
    startBtn.Text = "▶ START LOOP"
end)

copyBtn.MouseButton1Click:Connect(function()
    local allText = table.concat(logLines, "\n")
    local copied = false
    if typeof(setclipboard) == "function" then
        copied = pcall(setclipboard, allText)
    elseif typeof(toclipboard) == "function" then
        copied = pcall(toclipboard, allText)
    end
    if copied then
        appendLog("Log copied to clipboard.")
    else
        appendLog("Clipboard API unavailable; log remains in the UI and output console.")
    end
end)

local function cleanup()
    guiAlive = false
    State.AutoSellActive = false
    State.AutoSellToken = State.AutoSellToken + 1
    if dragInputConnection then pcall(function() dragInputConnection:Disconnect() end) end
    table.clear(rarityByUid)
    table.clear(pendingSellUids)
    _G.StandaloneAutoSell_Cleanup = nil
    if gui and gui.Parent then pcall(function() gui:Destroy() end) end
end
_G.StandaloneAutoSell_Cleanup = cleanup
closeBtn.MouseButton1Click:Connect(cleanup)

appendLog("Loaded. Safety mode: only verified, consistent rarities can be sold; guessed, conflicting, plain Egg, or missing-UID eggs are kept. Default threshold is Secret, default loop 600s.")
task.spawn(function()
    task.wait(0.15)
    if guiAlive then applyScan(true) end
end)