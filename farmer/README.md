# Farmer & Diagnostic Suite: Technical Architecture & Feature Guide

This documentation covers the architecture, control logic, networking hooks, and operation of both the **Automated Farming Suite** (`EggGoToUI_v9_9.lua`) and the **Targeted Discovery Scanner** (`targeted-discovery-scanner.lua`).

---

## Table of Contents
1. [EggGoToUI v9.9 - Automated Farming Suite](#1-egggotoui-v99---automated-farming-suite)
   - [Overview & High-Level Architecture](#overview--high-level-architecture)
   - [Sidebar Navigation & Multi-Tab Interface](#sidebar-navigation--multi-tab-interface)
   - [Pet & Egg Automation Suite (Tab 2)](#pet--egg-automation-suite-tab-2)
   - [Dual-Velocity Physics Engine](#dual-velocity-physics-engine)
   - [Anti-Rubberband System & Dynamic Speed Step-Down](#anti-rubberband-system--dynamic-speed-step-down)
   - [Anti-Teleport & Micro-Snap Distance Gating](#anti-teleport--micro-snap-distance-gating)
   - [Instant Ragdoll Recovery Engine](#instant-ragdoll-recovery-engine)
   - [ESP Carrier Tracking & Ghost Egg Blacklisting](#esp-carrier-tracking--ghost-egg-blacklisting)
   - [Target Priority Chain & Safe Zone Steal Logic](#target-priority-chain--safe-zone-steal-logic)
   - [JSON Configuration Engine & State Synchronization](#json-configuration-engine--state-synchronization)
   - [Clean Shutdown & Memory Deallocation](#clean-shutdown--memory-deallocation)
2. [Targeted Discovery Scanner](#2-targeted-discovery-scanner)
   - [Overview & Safety Principles](#overview--safety-principles)
   - [Local Player & Character State Introspection](#local-player--character-state-introspection)
   - [Networking Discovery & Remote Classification](#networking-discovery--remote-classification)
   - [Uncapped Hierarchy & Asset Dump Engine](#uncapped-hierarchy--asset-dump-engine)
   - [Compound Identifier Parsing (`ClientRenderedAssets`)](#compound-identifier-parsing-clientrenderedassets)
   - [Deep Object Discovery Matching](#deep-object-discovery-matching)
   - [Output Pipeline (Clipboard, File System, In-Game UI)](#output-pipeline-clipboard-file-system-in-game-ui)
3. [File Organization & Workflow](#3-file-organization--workflow)

---

## 1. EggGoToUI v9.9 - Automated Farming Suite

### Overview & High-Level Architecture
`EggGoToUI_v9_9.lua` is a fully autonomous client-side agent designed for continuous egg harvesting, delivery, and competitive theft in "Steal an Egg" (Roblox). It features server-authoritative state reconciliation, multi-threaded snapshot polling, real-time physics stabilization, and adaptive velocity management.

```
                          ┌────────────────────────┐
                          │    Egg Cache Scanner   │
                          │   (1.0s Fixed Cadence) │
                          └───────────┬────────────┘
                                      │
                                      ▼
┌─────────────────────────┐   ┌───────────────┐   ┌────────────────────────┐
│  ClientRenderedAssets   │──▶│ Target Filter │◀──│ UI Filters (Rarity /   │
│ (Carrier / Ghost Check) │   │   & Sorter    │   │ Species / Mutation)    │
└─────────────────────────┘   └───────┬───────┘   └────────────────────────┘
                                      │
                                      ▼
                        ┌───────────────────────────┐
                        │ Priority Target Evaluator │
                        │  (Steal Priority Check)   │
                        └─────────────┬─────────────┘
                                      │
              ┌───────────────────────┴───────────────────────┐
              ▼                                               ▼
   ┌───────────────────────┐                       ┌───────────────────────┐
   │ Go Phase (Speed: 300) │                       │Carry Phase(Speed: 250)│
   │  - Unheld Target Path │                       │  - Safe Zone Return   │
   │  - Anti-Teleport Gate │                       │  - Zero Friction Part │
   │  - Rubberband Stepdown│                       │  - Drop Detection     │
   └───────────────────────┘                       └───────────────────────┘
```

---

### Sidebar Navigation & Multi-Tab Interface
The HUD features a vertical sidebar layout separating core modules into clean, dedicated tabs:

- **Navigation Rail (`46px` icon-only rail)**:
  - **`🥚` (Tab 1)**: Autonomous farming controls, dual-velocity inputs, recovery toggles, live speed metrics, species & rarity filters, JSON profile syncing, and the live egg list view.
  - **`🐾` (Tab 2)**: Autonomous egg placement & incubation, pet satchel auto-selling, fusery & mutation automation, best pet auto-equipper, live telemetry logger, and species catalog with 1-click targeting.
- **State Preservation**: Switching tabs preserves active auto-farming, background egg scanning threads, and velocity stabilization without UI interruption or reset.
- **Auto-Close Dropdowns**: Navigating across tabs automatically collapses floating dropdowns (species and rarity selectors) to prevent UI overlapping.

---

### Pet & Egg Automation Suite (Tab 2)
The dedicated Pets tab bridges inventory management, egg processing, pet mutations, and farming targeting into an integrated autonomous pipeline:

1. **Egg Placement & Incubation Automation**:
   - **`Auto Place Egg`**: Continuously monitors the player's held egg and backpack inventory; automatically delivers and seats eggs onto available nests/incubators using `RF/EggWorld/AskPlaceEgg`.
   - **`Auto Hatch`**: Actively triggers incubation completion and hatch sequences via `RF/EggWorld/AskHatch` and `RF/EggWorld/AskFinishHatch`.
   - **`Skip Growth`**: Automatically calls `RF/EggWorld/AskSkipGrowth` to bypass maturation timers when enabled.
   - **`Place Held Egg`**: Instant one-click manual placement fallback.

2. **Pet Satchel & Auto Sell Automation**:
   - **`Auto Sell`**: Toggles continuous server-side satchel offloading via `RF/Haul/WriteAutoSell` and autonomous inventory flushing.
   - **`Sell Satchel`**: Manual panic button triggering `RE/PetSatchel/SellEveryPet` for immediate space clearance.
   - **Rarity Ceiling Filter**: Configurable multi-tier selector cycling through `Common`, `Uncommon`, `Rare`, and `Epic` to guarantee high-tier and shiny pets are never liquidated.

3. **Fusery & Mutation Machine Automation**:
   - **`Auto Fuse`**: Manages the complete fusion cycle end-to-end: acknowledges tutorial briefings via `RF/Fusery/ConfirmBriefing`, initiates multi-pet fusion with `RF/Fusery/BeginFuse`, and finalizes pet reveals with `RF/Fusery/FinishReveal`.
   - **`Fuse Now`**: Manual trigger to perform an immediate fusion batch on demand.
   - **Fuse Rarity Filter**: Restricts automated fusing candidates to designated rarity brackets to preserve target collections.

4. **Loadout & Equip Automation**:
   - **`Auto Equip Best`**: Background thread periodically queries player stat multipliers and auto-equips the strongest pet loadout via `RF/Haul/WearBest`.
   - **`Wear Best Now`**: Immediate one-click remote invocation to optimize equipped pets.

5. **Live Automation Telemetry Logger**:
   - Integrated 30-entry FIFO scrolling terminal embedded directly in the HUD.
   - Timestamps formatted with second-level precision (`[HH:MM:SS]`).
   - Categorized status tags (`[PLACE]`, `[HATCH]`, `[SELL]`, `[FUSE]`, `[EQUIP]`, `[SYS]`).
   - Auto-scroll lock to latest events and one-click `Clear` button.

6. **Species Catalog & Quick Target Bridge**:
   - **Pre-Populated 100+ Pet Catalogue**: Indexed directly from `PET_RARITY_PRESETS` across all tiers: `Divine`, `Eternal`, `Secret`, `Cosmic`, `Mythic`, `Legendary`, `Epic`, `Rare`, `Uncommon`, and `Common`.
   - **Instant Search & Rarity Filter Chips**: Real-time substring search with horizontal scroll chips for instant tier filtering.
   - **Owned & Equipped Introspection (`🔄 Scan Owned`)**: Introspects local character hierarchies and data containers (`Pets`, `Inventory`, `PetInventory`) to tag owned (`🎒`) and equipped (`⭐`) pets.
   - **One-Click Target Assignment (`✓ Farm` / `🎯 Target Filtered`)**: Clicking `Farm` on any pet automatically sets the active farm target in Tab 1, updates JSON configuration, and switches tabs seamlessly.

---

### Dual-Velocity Physics Engine
The suite implements a dual-velocity state machine to balance travel speed against carrier physics penalties and server anti-cheat triggers:

1. **Travel / Go Speed (`X.baseVelocity`, Default: `300`)**:
   - Active when navigating toward eggs, scouting, retargeting, or returning to battle after recovering from a bump.
   - Maximize travel speed across large biomes without triggering rubberbands.
2. **Carry / Return Speed (`X.baseCarryVelocity`, Default: `250`)**:
   - Active strictly after a confirmed egg pickup.
   - Lower speed ensures stability while carrying high-mass or physics-welded egg models, preventing server desync, fling physics, and premature dropping.
3. **State Transition Functions**:
   - `X.switchToCarry()`: Evaluated on confirmed pickup. Updates humanoid `WalkSpeed` and switches internal velocity targets.
   - `X.resetVelocity()`: Restores travel velocity when an egg is delivered, dropped, stolen, or when retargeting.
4. **Frictionless Character Part Normalization**:
   - Sets character physical properties to custom zero friction: `PhysicalProperties.new(0.7, 0, 0, 100, 100)`.
   - Neutralizes assembly masses on carried eggs (`Massless = true`, `CanCollide = false`) to prevent character dragging or inertia flipping.

---

### Anti-Rubberband System & Dynamic Speed Step-Down
Server velocity checks often push client characters backwards when client velocity exceeds strict server caps:
- **Windowed Velocity Monitor (`X.detectRubberband`)**:
  - Samples positions over `X.RUBBER_WINDOW = 0.6s`.
  - Compares the character's movement vector against the camera/joystick move direction.
  - If pulled backwards $\ge 6$ studs in a single frame or net $\ge 12$ studs over the window (`X.RUBBER_NET_BACK`), a rubberband is recorded.
- **Dynamic Step-Down (`X.VELOCITY_STEP = 10`, `X.MIN_VELOCITY = 100`)**:
  - Every detected rubberband automatically decrements active velocity by 10 studs/s down to a safe floor of 100 studs/s.
  - Automatically resets to `X.baseVelocity` once smooth transit resumes without pushbacks.
- **Teleport Exemption (`X.markTeleport`)**:
  - Sets an immunity window (`0.35s`) after authorized snaps to avoid false rubberband triggers.

---

### Anti-Teleport & Micro-Snap Distance Gating
Hard teleports over long distances cause instant server death or character despawns:
- **Distance Gate Clamp**: All micro-snaps (`microSnap`) are clamped to a strict maximum radius:
  $$\text{Distance} \le 75\text{ studs}\quad (\text{SAFE\_SNAP\_RADIUS} = 75)$$
- **Boss Bump / Knockback Recovery**:
  - When knocked back $> 75$ studs by a boss or enemy player, the bot **never teleports**.
  - It engages smooth synchronized walking (`walkSync`) with stuck-hop detection until within the $\le 75$ stud threshold before attempting final pickup.

---

### Instant Ragdoll Recovery Engine
Fast recovery ensures zero downtime when hit by bosses, traps, or player pushes:
- **State Change Listener (`bindFastRagdoll`)**:
  - Hooks `Humanoid.StateChanged`.
  - Upon detecting `Ragdoll`, `FallingDown`, or `PlatformStanding`, it immediately forces:
    ```lua
    humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
    ```
- **Physics Reset & Safe Alignment**:
  - Cancels linear and angular assembly velocities (`AssemblyLinearVelocity = Vector3.zero`, `AssemblyAngularVelocity = Vector3.zero`).
  - Re-aligns the `HumanoidRootPart` to upright orientation at `lastGoodCFrame`.
- **False-Positive Guard**:
  - Tracks `RAGDOLL_STALE_AFTER = 2.5s`. Stale or glitch states are forced upright to prevent permanent stun loops.

---

### ESP Carrier Tracking & Ghost Egg Blacklisting
Prevents the bot from chasing phantom eggs or eggs already taken by competitors:
- **Carrier Detection (`Workspace.ClientRenderedAssets`)**:
  - When any player picks up an egg, the game client renders `<UserId>_<EggUid>` under `ClientRenderedAssets`.
  - The scanner continuously parses these model names. If an egg's `Uid` is carried by another player (`UserId ~= LocalPlayer.UserId`), it is **immediately blacklisted** from targeting.
- **Competitor Delivery Tracking**:
  - If a carrier model approaches within 50 studs of `SAFE_ZONE`, the egg is marked as successfully secured by an opponent and dropped from the active cache.

---

### Target Priority Chain & Safe Zone Steal Logic
1. **Tier Priority Hierarchy**:
   $$\text{Divine} \longrightarrow \text{Eternal} \longrightarrow \text{Secret} \longrightarrow \text{Farthest Selected}$$
   *(Mythic is omitted from the top emergency chain to avoid detours for low-tier eggs).*
2. **Safe Zone Steal Priority**:
   - When the bot is near its own safe zone ($\le 60$ studs), it sweeps for dropped, loose, or competitor-fumbled target eggs within an 80-stud perimeter.
   - Triggers `[AutoFarm] STEAL` to instantly secure nearby high-tier eggs before embarking on long cross-map treks.

---

### JSON Configuration Engine & State Synchronization
Complete bidirectional synchronization between live UI controls, memory state, and serialized JSON:

```json
{
  "AutoReturn": true,
  "CarryVelocityValue": 250,
  "MutationFilter": [],
  "RarityFilter": ["Divine", "Eternal", "Secret"],
  "Recovery": true,
  "SafeZone": { "X": 427.6, "Y": 70.7, "Z": -423.4 },
  "SpeciesFilter": ["All"],
  "Velocity": true,
  "VelocityValue": 300
}
```

- **Backwards Compatibility**: Automatically falls back to `DEFAULT_SETTINGS.CarryVelocityValue` (`250`) when loading legacy configurations that only define `VelocityValue`.
- **Live Sync**: Modifying `Go` speed or `Carry` speed boxes updates `currentSettings` and immediately writes to `jsonBox.Text` on focus loss or input change.
- **One-Click Export/Import**: `Copy JSON` writes to system clipboard (`setclipboard`) with textbox fallback; `Load JSON` parses and reconfigures live bot parameters on the fly.

---

### Clean Shutdown & Memory Deallocation
Clicking the title bar "X" button triggers a comprehensive `fullCleanup()` routine:
1. Halts `autoFarmLoop` immediately by setting `autoFarmEnabled = false` and advancing `autoFarmToken`.
2. Cancels active movement loops (`walkTo`, `retSafe`) by advancing `walkToken` and halting humanoid navigation (`h:Move(Vector3.zero)`).
3. Terminates the background 1.0s egg cache scanner and live telemetry watcher loops (`eggScannerStop = true`).
4. Disables velocity and recovery engines, unanchoring `HumanoidRootPart` and resetting assembly linear and angular velocities.
5. Restores character humanoid `WalkSpeed` (normal 16) and original physical friction properties (`setFrictionless(false)`).
6. Disconnects all `RunService.Heartbeat`, `CharacterAdded`, network listeners (`RE/FieldEggGone`, `ChildAdded`), and user input connections.
7. Completely destroys `ScreenGui` instances from `PlayerGui` / `CoreGui`.
8. Cleans up `_G.EggGoToUI_Cleanup`; subsequent script executions also invoke this cleanup at launch to prevent ghost threads or parallel script conflicts.

---

## 2. Targeted Discovery Scanner

### Overview & Safety Principles
`targeted-discovery-scanner.lua` is a 100% read-only diagnostic and environment introspection tool. It maps out game memory, attributes, active network remotes, asset tables, and world objects without invoking server remotes or sending network packets.

---

### Local Player & Character State Introspection
- **Player & Attribute Dumps**: Dumps player identification, `LocalPlayer:GetAttributes()` sorted alphabetically, and status flags (`ProfileReady`, `AreaId`, `CashPackGroup`, etc.).
- **Humanoid & Character Metrics**: Character path, `WalkSpeed`, `JumpPower`, `JumpHeight`, `HipHeight`, `Health`, `PlatformStand`, and `Sit` state.
- **Leaderstats & Values**: Iterates through all `ValueBase` objects under `leaderstats` and the Player container, recording full object paths, names, types, and values.

---

### Networking Discovery & Remote Classification
- **Recursive Remote Mapping**: Scans all descendants of `ReplicatedStorage` (particularly `ReplicatedStorage.Packages.Networking`).
- **RemoteEvent & RemoteFunction Cataloguing**: Records exact remote names and class types.
- **Targeted Categorization**:
  - `EggWorld RE / RF`: Lists all gameplay remotes (`AskFieldEggSnapshot`, `AskFieldEggCarry`, `FieldEggBatchShifted`, etc.).
  - `BossEvent RE / RF`: Lists boss combat events (`HazardHit`, `BlackHoleHit`, `HealthShifted`, etc.).
  - `BossMastery RF`: Lists shop and mastery endpoints (`AskBuyShopItem`, `AskUseMutationConsumable`, etc.).

---

### Uncapped Hierarchy & Asset Dump Engine
- **No Limits / Zero Truncation**: Unlike older scanners that capped lists at 50 or 150 items with `... and X more children`, this engine lists **every single child** without limits.
- **Egg Species Catalogue**: Dumps all 154+ individual egg models stored under `ReplicatedStorage.Assets.Models.Eggs`.
- **Targeted Workspace Roots**: Fully enumerates `Workspace.Plots`, `Workspace.Eggs`, `Workspace.Map`, `Workspace.__ClientTreadmillRenders`, and `Workspace.World`.
- **Empty Folder Clarity**: Folders with zero children explicitly output `(empty)` with clean spacing between blocks.

---

### Compound Identifier Parsing (`ClientRenderedAssets`)
In "Steal an Egg", carried eggs are rendered on the client under `Workspace.ClientRenderedAssets` using concatenated keys:
$$\text{Name} = \langle\text{UserId}\rangle\_\langle\text{EggUid}\rangle$$
The scanner automatically decomposes these identifiers:
```
[FOUND] Workspace.ClientRenderedAssets [Folder]
    11729036952_0b0bd09942e8406e8d8645a14245a1ef [Model]  -->  (Player UserId: 11729036952 | EggUid: 0b0bd09942e8406e8d8645a14245a1ef)
    4746108170_065a260a68d24141bb05e4d3dfd6e6e2 [Model]   -->  (Player UserId: 4746108170 | EggUid: 065a260a68d24141bb05e4d3dfd6e6e2)
```

---

### Deep Object Discovery Matching
- **Precision Keyword Search**: Matches objects whose own names contain: `Egg`, `Nest`, `Boss`, `Fuse`, `Guard`, `FitBounds`, `EggSpot`, or `EggPoint`.
- **Parent Subpart Filtering**: Avoids dumping hundreds of unrelated Blender geometry names (`Cube.019`, `Cylinder.005`, `smoke1`, `Text`) by matching against the object's specific identity.
- **Uncapped Discovery**: Dumps all matching world objects across `Workspace` and `ReplicatedStorage` without cutoff.

---

### Output Pipeline (Clipboard, File System, In-Game UI)
- **Interactive Draggable UI**: Dark-themed HUD (`500x480`) with live scanning progress indicators.
- **Background Worker**: Executes inside a `task.defer` coroutine to prevent client framerate dips during large scans.
- **`📋 COPY`**: Copies the entire raw text report directly to the system clipboard via `setclipboard()`.
- **`💾 SAVE FILE`**: Saves the full report directly to the executor's workspace folder as `1.8-data-support-scan.txt` via `writefile()`.
- **Scrollable In-Game Console**: Multi-line read-only text viewer for rapid in-game inspection.

---

## 3. File Organization & Workflow

All production farming and discovery scripts reside in the `farmer/` directory:

| File | Purpose |
| :--- | :--- |
| [`farmer/EggGoToUI_v9_9.lua`](file:///home/arcobaleno/admin-tool/farmer/EggGoToUI_v9_9.lua) | Main autonomous egg farming, speed management, and delivery script |
| [`farmer/targeted-discovery-scanner.lua`](file:///home/arcobaleno/admin-tool/farmer/targeted-discovery-scanner.lua) | Complete, uncapped read-only game discovery and telemetry scanner |
| [`farmer/farm.json`](file:///home/arcobaleno/admin-tool/farmer/farm.json) | Reference configuration profile for egg priority and speed thresholds |
| [`farmer/README.md`](file:///home/arcobaleno/admin-tool/farmer/README.md) | Technical architecture documentation and reference guide |
