# Farmer & Diagnostic Suite: Technical Architecture & Feature Guide

This documentation covers the architecture, control logic, networking hooks, and operation of both the **Automated Farming Suite** (`EggGoToUI_v9_9.lua`) and the **Targeted Discovery Scanner** (`targeted-discovery-scanner.lua`).

---

## Table of Contents
1. [EggGoToUI v9.9 - Automated Farming Suite](#1-egggotoui-v99---automated-farming-suite)
   - [Overview & High-Level Architecture](#overview--high-level-architecture)
   - [Sidebar Navigation & Multi-Tab Interface](#sidebar-navigation--multi-tab-interface)
   - [Pet & Egg Automation Suite (Tab 2: Inventory & Fusery Focus)](#pet--egg-automation-suite-tab-2-inventory--fusery-focus)
   - [Dr. Scramble Trade-In Suite (Tab 3: Egg Sacrifice & Hourly Trade Engine)](#dr-scramble-trade-in-suite-tab-3-egg-sacrifice--hourly-trade-engine)
   - [Dual-Velocity Physics Engine](#dual-velocity-physics-engine)
   - [Anti-Rubberband System & Dynamic Speed Step-Down](#anti-rubberband-system--dynamic-speed-step-down)
   - [Anti-Teleport & Micro-Snap Distance Gating](#anti-teleport--micro-snap-distance-gating)
   - [Manual "Get" & Auto-Farm Unified Code Architecture](#manual-get--auto-farm-unified-code-architecture)
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
  - **`🐾` (Tab 2)**: Pet Inventory overview (free vs. equipped pets), 18 equipped pet protection, Pet Fusery automation (candidate grouping by species, $\ge 3$ unequipped threshold, authoritative in-game pet weight calculation, and 1-click 3-copy fusion).
  - **`🌀` (Tab 3)**: Dr. Scramble Trade-In automation (server recipe discovery, hourly auto-refresh & countdown, live `RE/BannerRotated` sync, unplaced inventory egg listing sorted by weight, and 3-egg sacrifice trade execution).
- **State Preservation**: Switching tabs preserves active auto-farming, background egg scanning threads, and velocity stabilization without UI interruption or reset.
- **Auto-Close Dropdowns**: Navigating across tabs automatically collapses floating dropdowns (species and rarity selectors) to prevent UI overlapping.

---

### Pet & Egg Automation Suite (Tab 2: Inventory & Fusery Focus)
Tab 2 is streamlined exclusively for **Inventory Overview** and **Fusery Machine Automation**:

1. **Inventory Overview Header (`📦 Inventory Overview`)**:
   - Located prominently at the very top of Tab 2.
   - **Total Pets**: Displays real-time pet metrics parsed across server profile mirror snapshots, character models, and client containers:
     `🐾 Total Pets: X   (Y Free, Z Equipped)`
   - **Total Eggs**: Aggregates eggs currently held on character models (`ClientRenderedAssets`), equipped tools, Backpack inventory tools, and profile satchels:
     `🥚 Total Eggs: N in inventory`
   - **Instant Refresh (`🔄`)**: Immediately queries inventory remotes and updates both counts and the Fusery candidate list.

2. **Fusery Candidates List (`🧪 Fusery Candidates (Select 3 to Fuse)`)**:
   - **Dedicated Scrollable Candidate Cards**: Replaced legacy flat rows with collapsible/grouped species cards inside a permanent, responsive `ScrollingFrame` displaying all unequipped pet species that meet the fusion threshold ($\ge 3$ unequipped copies).
   - **Equipped Pet Exclusion & Absolute Safety**: Authoritative equipped queries via `RF/PenRoster/AskLiveSnapshot`, `PlayerGui.ActivePets`, and character tool models strictly filter out all 18 equipped pets from both the count and candidate pool, guaranteeing equipped loadouts can never be consumed.
   - **Grouped Candidate Header**:
     - **Rarity Stripe & Badge**: Distinct visual stripe and badge colored according to rarity rank (`Common` through `Divine`).
     - **Species Name & Mutation Badge**: Species display name with explicit mutation prefix tags (e.g., `[Rainbow] Snowy Owl`, `[Silver] Sabertooth Tiger`, `[Golden] Sacred Moth`) and unequipped copy count.
     - **`Auto 3` Button**: One-click action to automatically select the 3 lightest (lowest weight) copies of that species.
     - **`⚡ Fuse (3/3)` Action Button**: Dynamic button that enables when exactly 3 pets are checked. Displays `Select 3 (N/3)` when fewer than 3 are checked. Loads the 3 chosen UIDs via verified remote signature `RF/Fusery/LoadPet:InvokeServer(petUid, false)` (from `farmer/fuse.log`), triggers `RF/Fusery/BeginFuse` and `RF/Fusery/FinishReveal`, requests lightweight snapshot synchronization, and automatically re-renders the list.
   - **Individual Pet Rows**: Below each species header, every single unequipped copy is individually listed:
     - **Row Number & In-Game Weight**: Exact mass badge (e.g., `⚖️ 81,133Kg`, `⚖️ 5,921Kg`). Implements the game's authoritative formula:
       $$\text{DisplayWeight} = \text{math.round}(\text{attrs.Weight} \times \text{attrs.Scale}^2)$$
       Formatted with commas matching the in-game backpack display 1:1. Sorted ascending from lightest to heaviest so lower-stat copies appear first and high-stat/heavy pets are protected.
     - **Earn Rate**: Real-time earnings rate `💰 $Y/s` when equipped or discovered in active pet registries.
     - **Pet UID**: Truncated 8-character unique identifier preview (`[ab032962...]`).
     - **Interactive Checkbox (`[✓]` / `[ ]`)**: Right-aligned toggle button on each row. Clicking the row or checkbox toggles selection with instant local visual updates (no scroll flicker). Gated to exactly 3 checked pets per species. Pre-checks the 3 lightest copies by default.
   - **Empty State Notification**: When no species currently has 3+ unequipped copies, displays an informative placeholder card reassuring that the 18 equipped pets remain protected.
   - **Instant Refresh (`🔄`)**: Header refresh button to instantly re-scan inventory and update candidates.

3. **Live Fusery Activity Log (`📜 Fusery Activity Log`)**:
   - Real-time scrolling telemetry terminal tracking scan results, pet slot loading (slots 1..3 with short UID previews), remote responses, and fusion completions.
   - `Clear` button to purge output history.

---

### Dr. Scramble Trade-In Suite (Tab 3: Egg Sacrifice & Hourly Trade Engine)
Tab 3 is dedicated to the **Dr. Scramble Trade-In Machine** (`DrScrambleTradeIn`), which functions as an egg-based sacrifice and recipe system. Players sacrifice 3 specific unplaced inventory eggs to receive exclusive rewards.

1. **Clean 2-Row Control Bar (`Card 1`)**:
   - **Row 1 (Y=5)**: Unobstructed title `🌀 Dr. Scramble Trade-In` (left) + diagnostic `🔍 State` button (right) + manual `🔄` refresh button (right). Buttons never overlap the title text.
   - **Row 2 (Y=32)**: Exact-second countdown timer `⏳ MMm SSs  •  Status` (left) + `[ON] Priority` toggle (right) + `[ON] Auto-Fuse` toggle (right).
   - **Exact-Second Server Rotation Countdown**: Synchronizes directly against `state.SecondsUntilRotation` returned by `AskState` (e.g. `792.7s`), updating `serverExpiresAt = os.time() + math.floor(state.SecondsUntilRotation)` with 1-second precision.
   - **AutoFarm Priority Toggle (`[ON] Priority` / `[OFF] Priority`)**: Toggles Scramble requirement targeting in the AutoFarm priority chain.
   - **Autonomous Auto-Fuse Toggle (`[ON] Auto-Fuse` / `[OFF] Auto-Fuse`)**: Automatically executes trade-in / fusion the exact moment all required eggs for the active recipe enter inventory!
   - **Server Event Listener (`RE/ScrambleTradeIn/BannerRotated`)**: Connects to the server's live rotation event to instantly reload requirements whenever an in-game rotation occurs.
   - **State Inspector (`🔍 State`)**: Diagnostic button that introspects raw server response tables from `RF/ScrambleTradeIn/AskState` and prints key attributes to the activity log.

2. **Bidirectional Species Aliasing Engine (`X.EGG_SPECIES_ALIASES`)**:
   - Server recipe requirements often use internal asset category names (e.g., `Galaxy Gecko`, `Cyclops Gorilla`, `Dream Axolotl`), while physical egg tools, map spawns, and GUI labels use user-facing display names (e.g., `Cosmic Gecko Egg`, `Cosmic Gorilla`, `Axolotl`).
   - `X.EGG_SPECIES_ALIASES` establishes bidirectional mapping between internal categories and display names (`galaxy gecko` $\longleftrightarrow$ `cosmic gecko`, `cyclops gorilla` $\longleftrightarrow$ `cosmic gorilla`, `dream axolotl` $\longleftrightarrow$ `axolotl`, `holy peacock` $\longleftrightarrow$ `peacock`, `sacred moth` $\longleftrightarrow$ `moth`, `winged lamb` $\longleftrightarrow$ `lamb`, `warden` $\longleftrightarrow$ `king snake`).
   - `X.matchEggSpecies(nameA, nameB)` resolves aliases bidirectionally, guaranteeing that holding `Cosmic Gecko Egg` in inventory immediately satisfies the server requirement for `Galaxy Gecko` and marks it `1/1 (Ready)`.

3. **Clean Requirement Cards with Manual "Get" Buttons (`📋 Requirements`)**:
   - **Tab 1 Card Architecture**: Full-width dark cards with left accent strips, Gotham typography, status badges, and compact action buttons. Title width is constrained so it never overlaps the filter button or badge.
   - **Controls Bar & Sizing**:
     - **Dynamic Window Resizing**: Automatically expands main window from `380x520` to `560x580` when switching to the Scramble tab, and smoothly restores `380x520` when navigating back to Eggs or Pets.
     - **Timer Badge**: Displays live countdown (`⏳ MMm SSs • Dr. Scramble`) synchronized with server rotation (`serverExpiresAt`).
     - **Priority Toggle (`[ON]/[OFF] Priority`)**: Toggles AutoFarm Scramble priority chain (`X.prioritizeScrambleInAutoFarm`).
     - **Auto-Trade Toggle (`[ON]/[OFF] Auto-Trade`)**: Gated auto-trade switch (`X.autoScrambleTrade`).
     - **Manual Refresh (`🔄`)**: Force re-queries `AskState` and authoritative inventory.
     - **Action Button (`⚡ Trade (X/3)`)**: Highlights green (`⚡ Auto-Ready (3/3)`) or purple (`⚡ Trade (3/3 Ready)`) when eligible, or indicates `⏳ Trading In...` during execution.

4. **1:1 Standalone 3-Card Architecture (Imported from `scramble-autotrade.lua`)**:
   - **Card 1: Dr. Scramble Recipe Requirements**:
     - Dynamic height auto-sizing card rendering active server recipe slots.
     - **Card Row Badges**: Each slot shows `[✓ OWNED]` (green strip/tint) or `[⚠️ MISSING]` (red strip/tint), internal species name, display name, required count, and total eligible matching copies in inventory.
   - **Card 2: Matching Unplaced Eggs in Inventory (Eligible for Sacrifice)**:
     - Always visible dedicated scrolling inventory card listing all unplaced satchel eggs matching active recipe requirements.
     - Formatted entries: `#idx 🥚 DisplayName • ⚖️ Weight • [UID] (Source)` with `✓ Selected` badge for the lightest distinct copies picked for sacrifice.
   - **Card 3: Live Telemetry & Network Log**:
     - Monospaced high-performance log terminal tracking server requests, snapshot calls, rotation events, and trade results.
     - **One-Click Clipboard Export**: `Copy` button exports entire log history directly to system clipboard via executor clipboard API with fallback to developer console (F9).
     - **Clear Button**: Instantly clears log buffer.

5. **Autonomous Trade-In Engine & Multi-Signature Remote Cycle**:
   - **Authoritative 3-Step Remote Cycle**:
     1. `RF/ScrambleTradeIn/AskState` $\longrightarrow$ Queries active recipe, countdown, and auto-claims uncollected `PendingReward`.
     2. `RF/ScrambleTradeIn/AskTradeIn` $\longrightarrow$ Submits ordered distinct 32-hex UIDs `finalUids` (`[1]=uid1, [2]=uid2, [3]=uid3`).
     3. `RF/ScrambleTradeIn/AskFinishReveal` $\longrightarrow$ **Crucial claim step**: Claims hatched pet reward into satchel and advances recipe.
     4. `ContentCreatorRemotes.Request("snapshot", { lightweight = true })` $\longrightarrow$ Fast profile sync.
   - **Strict Egg Filter (Never Sacrifices Pets)**:
     - ProfileMirror scan strictly filters `Placement == nil`.
     - Physical tools scan strictly validates `attrs.DisplayName` / `t.Name` contains `"egg"`, `Category == "Egg"`, or `attrs.ItemType == "Egg"`. Excludes gear, bats, and all 200+ pets (`ItemType == "Asset"`).
   - **Infinite Chain Execution (`PostTradeChain`)**:
     - Auto-trades immediately when 3/3 eggs are met. Upon completion, immediately checks if the newly rolled recipe can also be completed and continues auto-trading without user intervention.
   - **Safe-Zone Carrying State Protection**:
     - All auto-trade executions are strictly gated on `weAreCarrying == false`, ensuring that carried eggs are safely delivered to the home base first.

6. **AutoFarm Priority Chain & Strict Missing-Only Targeting**:
   - Priority Chain Order:
     $$\text{Divine (Tier 1)} \longrightarrow \text{Eternal (Tier 2)} \longrightarrow \text{Secret (Tier 3)} \longrightarrow \mathbf{\text{Scramble Missing Requirements (Tier 4)}} \longrightarrow \text{Farther Eggs (Tier 5+)}$$
   - **Strict Missing-Only Enforcement (`X.isScrambleRequirement`)**: Checks normalized species names and aliases against `X.scrambleMissingSpecies`. If you already have the egg in inventory (`owned >= req.count`), it is **strictly excluded** from `X.scrambleMissingSpecies` and will **never** be farmed by AutoFarm. AutoFarm only targets eggs that are confirmed missing!
   - Multi-source inventory checks authoritative `ProfileMirror.FetchProfile`, in-game `DrScrambleTradeInInventory` GUI, and physical tools in `Backpack` and `Character`.


---

### Dual-Velocity Physics Engine
The suite implements a dual-velocity state machine to balance travel speed against carrier physics penalties and server anti-cheat triggers:

1. **Travel / Go Speed (`X.baseVelocity`, Default: `300`)**:
   - Active when navigating toward eggs, scouting, retargeting, or returning to battle after recovering from a bump.
   - Maximize travel speed across large biomes without triggering rubberbands.
2. **Carry / Return Speed (`X.baseCarryVelocity`, Default: `250`)**:
   - Active strictly after a confirmed egg pickup.
   - Lower speed ensures stability while carrying high-mass or physics-welded egg models, preventing server desync, fling physics, and premature dropping.
   - **Dynamic Enforcement on Heartbeat**: `applyVelocity()` clamps active velocity to `X.baseCarryVelocity` whenever `weAreCarrying` or `isHoldingEgg()` is true, continuously neutralizing physics and preventing accidental speed overrides.
3. **State Transition Functions & Return Token Reconciliation**:
   - `X.switchToCarry()`: Evaluated on confirmed pickup. Updates humanoid `WalkSpeed` and switches internal velocity targets.
   - `X.resetVelocity()`: Restores travel velocity when an egg is delivered, dropped, stolen, or when retargeting. State-aware: checks `weAreCarrying` and `isHoldingEgg()` to ensure carry velocity is never overridden prematurely while holding an egg.
   - **Return Token Reconciliation (`rtok`)**: `autoGetEgg` generates a return walk token (`rtok`) upon pickup and waits on `walkToken == walkTok or (rtok and walkToken == rtok)` until safe-zone delivery completes, preventing premature function exits from overwriting carry speed.
   - **Fallback Delivery Path**: `autoFarmLoop` fallback delivery block invokes `X.switchToCarry()` before initiating `walkSync` to guarantee return velocity even on recovered carries.
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

### Manual "Get" & Auto-Farm Unified Code Architecture
Manual "Get" button clicks on individual egg cards directly execute `autoGetEgg(uid, pos, myTok, true)` as a single-step execution of the autonomous farming pipeline. Both modes share 100% of the exact same code, avoiding any divergence:
1. **Target Approach & 50-Stud Snap**:
   - Dynamic live position tracking through `eggCache.byUid[uid]` (with coordinate fallback if not in cache).
   - Approaching via `walkTo` with `{ snapRadius = SNAP_RADIUS (50), snapBeside = true, stuckHop = true }`. The moment the character enters within 50 studs of the egg, it CFrame-snaps beside the egg facing it (`getBesideOffset`) instead of dropping directly on top, preventing vertical hopping.
   - Pre-pickup alignment via `microSnap()` (clamped to $\le 75$ studs; engages approach walking if knocked back further).
2. **Robust Pickup & Carry Transition**:
   - Takes hold snapshot (`takeHoldSnapshot()`), listens for `FieldEggGone`/`FieldEggCarry` events, and verifies via real signals before transitioning.
   - Strict `holdingSource()` / `isHoldingEgg()` verification: checks character tools and specifically `ClientRenderedAssets` for `UserId_carryUid` or active `carryMarkers`. Arbitrary CRA models are never matched, preventing the player's base nest eggs from causing false-positive carry detections.
   - Switches velocity to carry mode (`X.switchToCarry()`) and neutralizes carried egg collision/mass (`neutraliseEggPhysics()`).
3. **Safe-Zone Return & Ground-Level Safe Snap**:
   - Navigates toward `SAFE_ZONE` using `walkTo` with `{ snapRadius = SAFE_SNAP_RADIUS (50), stuckHop = true }`.
   - Snaps to `SAFE_ZONE` preserve current ground height (`targetY = r.Position.Y` within 4 studs), completely eliminating vertical bouncing/hopping.
   - Delivery gate in `autoFarmLoop` strictly checks `weAreCarrying` before attempting delivery, ensuring idle players standing in the safe zone never get trapped in an infinite delivery/jump cycle.
   - Parallel safe-zone watcher thread checks distance every `0.1s`:
     - Within 50 studs (`SAFE_SNAP_RADIUS`): immediately executes `X.snapToSafe()` every `0.25s` even if stunned or ragdolled.
     - Within 14 studs (`X.SAFE_DETECT_RADIUS`): confirms safe-zone arrival.
     - 45s watchdog safety net guarantees delivery snap.
   - Post-arrival delivery loop (`X.deliverWait`): waits until the carried egg is consumed by the game hitbox, restores default velocity (`X.resetVelocity()`), and triggers `X.requestEggRefresh()`.
4. **Dropped Egg Auto-Recovery**:
   - If bumped or knocked loose during transit, manual get automatically detects the drop and re-fetches the egg via `dropRetry` just like auto farm.

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
- **Client Slot Ground Truth (`Workspace.AreaEggSlotsClient`)**:
  - The client's `AreaEggSlotsClient` folder is the authoritative representation of eggs actively sitting on nests.
  - Multi-pattern slot resolver (`X.findEggSlot`):
    1. Direct 32-hex child check (`area:FindFirstChild(uid)`).
    2. Attribute / recursive identifier inspection (`Uid` / `EggUid`).
    3. Biome/Nest compound identifier matching (`FirstAreaEgg_<UserId>_<id>_Forest:Slot_005`).
    4. 3D World coordinate proximity matching ($\le 6$ studs from nest position).
  - Uncapped slot cross-check (`X.updateSlotGhosts`): Evaluates all biomes without arbitrary population thresholds. If an egg's slot is missing across 2 consecutive scans ($\ge 2$s), it is flagged as an empty-nest ghost and hidden from both the UI list and auto-farm target queue.
- **Base Plot Render Introspection (`Workspace.PlacedEggRenders`)**:
  - Eggs placed or delivered into any player's base plot/nests are rendered as `<UserId>_<EggUid>` under `PlacedEggRenders`.
  - `X.isEggInBaseRenders(uid)` continuously checks this container. Any listed egg found in a base plot is immediately classified as delivered/stolen and filtered out.
- **Carrier Detection (`Workspace.ClientRenderedAssets`)**:
  - When any player picks up an egg, the game client renders `<UserId>_<EggUid>` under `ClientRenderedAssets`.
  - The scanner continuously parses these model names. If an egg's `Uid` is carried by another player (`UserId ~= LocalPlayer.UserId`), it is **immediately blacklisted** from targeting.
- **Competitor Delivery Tracking**:
  - If a carrier model approaches within 50 studs of `SAFE_ZONE`, the egg is marked as successfully secured by an opponent and dropped from the active cache.
- **Arrival Empty-Nest Verification (`autoGetEgg`)**:
  - Immediately upon reaching an egg's location, a fresh snapshot and client slot inspection (`emptyNest`) are executed.
  - If `AreaEggSlotsClient` is populated, the egg has no slot, and it is not an egg dropped by the local player, the bot aborts pickup immediately with `"Nest already empty"`, blacklists the ghost egg, requests a UI refresh, and advances to the next target without delay.
- **Immunity Scope Clamp**:
  - Only eggs dropped by the local player (`X.weDropped` within 60s or active `dropRetry`) are exempted from ghost filtering. Stale or competitor-moved eggs are never immunized.

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
| [`farmer/scramble-autotrade.lua`](file:///home/arcobaleno/admin-tool/farmer/scramble-autotrade.lua) | Standalone Dr. Scramble recipe reader, egg inventory matcher, and autonomous auto-trade suite |
| [`farmer/targeted-discovery-scanner.lua`](file:///home/arcobaleno/admin-tool/farmer/targeted-discovery-scanner.lua) | Complete, uncapped read-only game discovery and telemetry scanner |
| [`farmer/targeted-character-scanner.lua`](file:///home/arcobaleno/admin-tool/farmer/targeted-character-scanner.lua) | Dedicated local character, pet inventory, profile data, and PlayerGui scanner |
| [`farmer/farm.json`](file:///home/arcobaleno/admin-tool/farmer/farm.json) | Reference configuration profile for egg priority and speed thresholds |
| [`farmer/README.md`](file:///home/arcobaleno/admin-tool/farmer/README.md) | Technical architecture documentation and reference guide |
