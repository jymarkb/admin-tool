"""Black-box test for lightdark-flight.lua (the 35-stud / 0.5s flight test).

The real file is loaded against a small stubbed Roblox API and then driven by
firing Heartbeat with a fake clock, exactly the way the engine would. What is
asserted is what the script printed: the step lines, the per-step verdicts, and
the summary. That is also the only thing the player reads, so the test and the
real use agree by construction.

Three scenarios, one Lua state each:
  * kept    - the server holds every write  -> every check must say HELD
  * reverted- the server puts us back       -> every check must say REVERTED
  * death   - hp is SET to -1000 mid-flight -> the -1000 detector must fire

Also checked: the cadence really is one write per 0.5s, the step arithmetic is
35 studs per step along the character's facing, and noclip is restored.

    pip install --break-system-packages lupa
    python3 tests/lightdark_flight_test.py
"""
import lupa, sys, os, re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "tools"))
from luau_syntax_check import normalise

SCRIPT = open(os.path.join(ROOT, "lightdark-flight.lua")).read()

STUB = r'''
local LOG = {}
print = function(...)
  local n = select("#", ...)
  local t = {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  LOG[#LOG + 1] = table.concat(t, "\t")
end
warn = print

local FAKE_T = 0
os.clock = function() return FAKE_T end
task = { wait = function() end, delay = function() end, spawn = function() end }

-- ---- Vector3 -------------------------------------------------------------
local V = {}
local function vnew(x,y,z) return setmetatable({x=x or 0,y=y or 0,z=z or 0},V) end
local function vmag(v) return math.sqrt(v.x^2+v.y^2+v.z^2) end
V.__index = function(t,k)
  if k=="X" then return rawget(t,"x") end
  if k=="Y" then return rawget(t,"y") end
  if k=="Z" then return rawget(t,"z") end
  if k=="Magnitude" then return vmag(t) end
  if k=="Unit" then local m=vmag(t); if m<1e-9 then return vnew(0,0,0) end
                       return vnew(t.x/m,t.y/m,t.z/m) end
  return V[k]
end
V.__sub = function(a,b) return vnew(a.x-b.x,a.y-b.y,a.z-b.z) end
V.__add = function(a,b) return vnew(a.x+b.x,a.y+b.y,a.z+b.z) end
V.Dot = function(a,b) return a.x*b.x+a.y*b.y+a.z*b.z end
V.__tostring = function(a) return string.format("(%.3f, %.3f, %.3f)",a.x,a.y,a.z) end
Vector3 = { new = vnew, zero = vnew(0,0,0) }

-- ---- CFrame --------------------------------------------------------------
local CF = {}
CFrame = {}
function CFrame.new(x,y,z)
  local p
  if type(x) == "table" then p = vnew(x.X, x.Y, x.Z) else p = vnew(x,y,z) end
  return setmetatable({p=p, look=vnew(0,0,-1)}, CF)
end
CF.__index = function(t,k)
  if k == "LookVector" then return rawget(t,"look") end
  if k == "Position" then return rawget(t,"p") end
  return nil
end

-- ---- signals -------------------------------------------------------------
local function signal()
  local s = {_fns={}}
  s.Connect = function(self, fn)
    table.insert(self._fns, fn)
    return {Disconnect=function()
      for i,f in ipairs(s._fns) do if f == fn then table.remove(s._fns,i) break end end
    end}
  end
  return s
end
local function fire(s, ...)
  local snap = {}
  for i,f in ipairs(s._fns) do snap[i] = f end
  for _,fn in ipairs(snap) do fn(...) end
end

-- ---- parts ---------------------------------------------------------------
local LASTWRITE = nil
local REVERT = false
local ALLPARTS = {}

local function mkPart(name, x, y, z)
  local o = {}
  local h = { Name=name, CanCollide=true, Position=vnew(x,y,z),
              AssemblyLinearVelocity=vnew(0,0,0) }
  ALLPARTS[#ALLPARTS+1] = o
  h.IsA = function(self, cls) return cls == "BasePart" end
  h.GetNetworkOwner = function(self) return PLAYER end     -- client-owned
  h.GetDescendants = function(self) return {} end
  h.Parent = true                                  -- inside a character
  setmetatable(o, {
    __index = function(t,k)
      if k == "CFrame" then return CFrame.new(h.Position) end
      return h[k]
    end,
    __newindex = function(t,k,v)
      if k == "CFrame" then
        LASTWRITE = { before = h.Position, after = v.p }
        h.Position = v.p
      elseif k == "Position" then
        h.Position = v
      else
        h[k] = v
      end
    end,
  })
  return o
end

local ROOT = mkPart("HumanoidRootPart", 100, 50, 100)
local TORSO = mkPart("Torso", 100, 50, 100)
local H = {}

local hp = 100
local state = "Running"
local humanoid
humanoid = (function()
  local o, h = {}, { _hp = 100 }
  h.GetState = function(self) return "Enum.HumanoidStateType." .. state end
  h.FloorMaterial = "Enum.Material.Plastic"
  h.Health = 100
  h.MaxHealth = 100
  setmetatable(o, {
    __index = function(t,k) return h[k] end,
    __newindex = function(t,k,v) h[k] = v end,
  })
  return o
end)()

local character = {}
local ch = {}
ch.FindFirstChildOfClass = function(self, cls) return cls == "Humanoid" and humanoid or nil end
ch.FindFirstChild = function(self, name) return name == "HumanoidRootPart" and ROOT or nil end
ch.GetDescendants = function(self) return ALLPARTS end
setmetatable(character, { __index = function(t,k) return ch[k] end,
                          __newindex = function(t,k,v) ch[k] = v end })

PLAYER = { Character = character }                    -- global: mkPart reads it
PLAYERS = { LocalPlayer = PLAYER }
RUNSERVICE = { Heartbeat = signal() }

game = { GetService = function(self, n)
  if n == "Players" then return PLAYERS end
  if n == "RunService" then return RUNSERVICE end
  return {}
end }

-- ---- driver --------------------------------------------------------------
function DRIVE(seconds)
  local n = math.floor(seconds * 60 + 0.5)
  for i = 1, n do
    FAKE_T = FAKE_T + 1/60
    if REVERT and LASTWRITE then
      -- the server puts the character back where it was before the write
      local P = LASTWRITE.before
      local lw = LASTWRITE
      LASTWRITE = nil
      ROOT.Position = vnew(P.x, P.y, P.z)
      LASTWRITE = lw
    end
    fire(RUNSERVICE.Heartbeat, 1/60)
  end
end
function SETHP(v) hp = v; humanoid.Health = v end
function SETREVERT(v) REVERT = v end
function SETSTATE(v) state = v end
function LOGDUMP() return table.concat(LOG, "\n") end
function CLEARLOG() LOG = {} end
function PARTS() return ALLPARTS end
'''

PASS = 0
FAIL = 0
FAILED = []


def chk(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  PASS  {name:<52} {str(detail)[:110]}")
    else:
        FAIL += 1
        FAILED.append(name)
        print(f"  FAIL  {name:<52} {str(detail)[:110]}")


def run(revert=False, seconds=30, hp_at=None, hp_value=-1000.0):
    """Load the script fresh, drive it, return (log text, lua globals)."""
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    g = lua.globals()
    lua.execute(STUB)
    lua.execute(normalise(SCRIPT))
    if revert:
        lua.execute("SETREVERT(true)")
    if hp_at is not None:
        # run to the moment of the kill, then hand the rest to the same driver
        lua.execute(f"DRIVE({hp_at})")
        lua.execute(f"SETHP({hp_value})")
    lua.execute(f"DRIVE({max(0.0, seconds - (hp_at or 0))})")
    return g["LOGDUMP"](), g


def lines(txt, needle):
    return [l for l in txt.splitlines() if needle in l]


print("=== T1: the flight is configured exactly as asked (35 studs / 0.5s) ===")
txt, g = run(seconds=1.0)                      # just the header + first write
chk("config line states the cadence",
    "35 studs every 0.50s x 40 steps = 1400 studs over 20.0s" in txt,
    lines(txt, "config    |")[:1])
chk("the start position is reported", "start     | (100.0, 50.0, 100.0)" in txt,
    lines(txt, "start     |")[:1])
chk("it says the -1000 pair is not called",
    "ChangeState(Freefall) and AutoRotate stay untouched" in txt, "")
chk("the direction is the character's facing",
    "DIRECTION | (0.0, 0.0, -1.0)" in txt, lines(txt, "DIRECTION")[:1])

print("\n=== T2: the step arithmetic - 35 studs, straight along the facing ===")
step1 = lines(txt, "step 01 |")
chk("the first write is 35 studs away", "-Z" not in step1[0] and
    "asked (100.0, 50.0, 65.0)" in step1[0], step1[:1])
chk("where it landed is reported", "landed (100.0, 50.0, 65.0)" in step1[0], step1[:1])
chk("the client-side error is reported", "off by 0.00" in step1[0], step1[:1])
chk("the world line comes with it",
    "state=Enum.HumanoidStateType.Running | grounded=true | floor=Enum.Material.Plastic" in txt,
    lines(txt, "state=Enum")[:1])

print("\n=== T3: cadence - one write per 0.5s, not one per frame ===")
txt30, g30 = run(seconds=30)
steps = lines(txt30, "| wrote (")
print(f"   {len(steps)} step line(s) in 30s of 60fps frames")
txt10, _ = run(seconds=10)
n10 = len(lines(txt10, "| wrote ("))
chk("one write per 0.5s - ~20 in 10s, not 600", 19 <= n10 <= 22,
    f"{n10} writes in 10s of frames")
chk("one write per 0.5s - 40 in the whole flight", len(steps) == 40,
    f"{len(steps)} writes in 30s")

print("\n=== T4: the server KEEPS the writes -> every step reads HELD ===")
chk("40 steps written", len(steps) == 40, f"{len(steps)} steps")
checks = lines(txt30, "| HELD")
chk("40 checks ran, one per write", len(checks) == 40, f"{len(checks)} checks")
chk("not one step was reported as undone",
    not lines(txt30, "REVERTED - the server put us back")
    and not lines(txt30, "MOVED ELSEWHERE"), "")
chk("each check says how far from the write", "studs from where it was written" in txt30, "")
chk("summary counts the verdicts", "steps     | 40 HELD | 0 REVERTED | 0 moved elsewhere" in txt30,
    lines(txt30, "steps     |")[:1])
chk("summary measures the distance actually made",
    "achieved  | 1400.0 studs along the flight" in txt30, lines(txt30, "achieved  |")[:1])
chk("100% of the asked distance", "100%" in lines(txt30, "achieved  |")[0],
    lines(txt30, "achieved  |")[:1])
chk("the verdict names the outcome",
    "verdict   | THE WRITES STICK" in txt30, lines(txt30, "verdict   |")[:1])
chk("noclip is restored, not leaked",
    "restored CanCollide on 2 part(s) - nothing leaked" in txt30,
    lines(txt30, "noclip    |")[-1:])
chk("it stops because the steps ran out",
    f"stopped   | all 40 steps flown" in txt30, lines(txt30, "stopped   |")[:1])
parts = g30["PARTS"]()
chk("every part is collidable again after the flight",
    all(p.CanCollide for p in parts.values()), "")
# 40 steps x 35 studs from z=100 along -Z, at a held altitude
chk("the 40th write lands 1400 studs from the start",
    "| landed (100.0, 50.0, -1300.0)" in steps[-1], steps[-1][:110])
chk("the altitude never sagged", "| landed (100.0, 50.0," in steps[-1], steps[-1][:110])
ages = [float(m.group(1)) for m in
        re.finditer(r"check \d+ \| ([\d.]+)s after the write", txt30)]
chk("every check is timed", len(ages) == 40, f"{len(ages)} timed checks")
chk("no write ever comes early", ages and min(ages) >= 0.4995,
    f"min age {min(ages) if ages else '-'}")
chk("the cadence holds at 0.5s, not a drifted 0.517s",
    ages and max(ages) <= 0.5005, f"max age {max(ages) if ages else '-'}")

print("\n=== T5: the server UNDOES the writes -> every step reads REVERTED ===")
txt_rev, g_rev = run(revert=True, seconds=30)
chk("40 checks ran", len(lines(txt_rev, "check")) == 40, f"{len(lines(txt_rev, 'check'))}")
chk("every check says REVERTED", len(lines(txt_rev, "REVERTED - the server put us back")) >= 40,
    f"{len(lines(txt_rev, 'REVERTED - the server'))}")
chk("the check shows both positions",
    "wrote=(100.0, 50.0, 65.0) then=(100.0, 50.0, 100.0)" in txt_rev,
    lines(txt_rev, "then=")[:1])
chk("summary counts zero held", "steps     | 0 HELD | 40 REVERTED" in txt_rev,
    lines(txt_rev, "steps     |")[:1])
chk("summary says we went nowhere", "achieved  | 0.0 studs along the flight" in txt_rev,
    lines(txt_rev, "achieved  |")[:1])
chk("the verdict names it", "verdict   | THE SERVER IS UNDOING THEM" in txt_rev,
    lines(txt_rev, "verdict   |")[:1])

print("\n=== T6: a -1000 kill stops the flight and says what it was ===")
txt_hp, _ = run(seconds=12, hp_at=3.0)
chk("the death is logged", "DEATH      | hp=-1000.0" in txt_hp, lines(txt_hp, "DEATH")[:1])
chk("it is called an external kill",
    "EXTERNAL KILL: hp was SET, this is not damage" in txt_hp, lines(txt_hp, "DEATH")[:1])
chk("the flight stops there", "stopped   | the character died at step" in txt_hp,
    lines(txt_hp, "stopped   |")[:1])
chk("no writes happen after the death",
    len(lines(txt_hp, "| wrote (")) <= 8, f"{len(lines(txt_hp, '| wrote ('))} writes")
chk("the summary still prints", "============ FLIGHT SUMMARY ============" in txt_hp, "")

print("\n=== T7: the script never makes the -1000 calls (static check) ===")
code = re.sub(r"--\[\[.*?\]\]", "", SCRIPT, flags=re.S)          # drop the header block
code = re.sub(r"--[^\n]*", "", code)                              # drop line comments
chk("no ChangeState call in the code", ":ChangeState" not in code, "")
chk("AutoRotate is never set", not re.search(r"AutoRotate\s*=", code), "")
chk("no velocity is written", not re.search(r"AssemblyLinearVelocity\s*=", code), "")
chk("the write is a direct root.CFrame assignment",
    "root.CFrame = CFrame.new(target)" in code, "")
chk("it does not move the humanoid state either", "SetStateEnabled" not in code, "")

print(f"\n{'='*60}\nRESULT: {PASS} passed, {FAIL} failed")
if FAILED:
    print("FAILED: " + ", ".join(FAILED))
