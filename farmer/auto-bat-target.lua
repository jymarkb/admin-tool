--[[
    DEPRECATED – merged into farmer/auto-bat.lua
    ============================================
    This file used to own a SECOND trigger path to RE/BatSwing/Trigger:
    per-row buttons firing `FireServer(player, token)` with their own token
    counter, no equip, no pacing, and a per-frame Heartbeat distance scan.

    Measured at 68 ms ping (farmer/test_auto_bat_trigger_race.py), that path
    landed 1.50 hits/s in every server rule - the worst of all four logics,
    because it never equips and so never gets the swap-negates-cooldown
    behaviour. Its 60 FPS distance scan also re-fetched both HumanoidRootParts
    and formatted a string per player per frame.

    Everything it did now lives in auto-bat.lua:
      - player list with recycled rows, refreshed at 5 Hz (no per-frame scan)
      - TP+LOCK button per row, 60 stud range, teleports into swing range
      - the single shared fire path, and HealthChanged-based hit confirmation

    Loading this file together with auto-bat.lua would put two independent
    token counters on one remote, so it is intentionally left as a no-op.
]]

warn("[auto-bat-target] Deprecated – target locking, 60 stud TP and hit "
    .. "confirmation are now inside farmer/auto-bat.lua. Load that instead.")
