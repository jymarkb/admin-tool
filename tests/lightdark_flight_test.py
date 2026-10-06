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
V.__mul = function(a,b)
  if type(b)=="number" then return vnew(a.x*b,a.y*b,a.z*b) end
  if type(a)=="number" then return vnew(a*b.x,a*b.y,a*b.z) end
  return vnew(a.x*b.x,a.y*b.y,a.z*b.z)
end
V.__div = function(a,b) return vnew(a.x/b,a.y/b,a.z/b) end
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
-- the script preserves yaw, so CFrame.Angles and CFrame*CFrame have to work
CFrame.Angles = function() return setmetatable({p=vnew(0,0,0), look=vnew(0,0,-1)}, CF) end
CF.__mul = function(a, b) return setmetatable({p=a.p, look=a.look}, CF) end

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
              Orientation=vnew(0,0,0), AssemblyLinearVelocity=vnew(0,0,0) }
  ALLPARTS[#ALLPARTS+1] = o
  h.IsA = function(self, cls) return cls == "BasePart" end
  h.GetNetworkOwner = function(self) return OWNER end
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

OWNER = nil                                    -- set below, before mkPart runs
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
OWNER = PLAYER                                 -- the client owns its own parts
function SETOWNER(v) OWNER = v end
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
function PLACE(x,y,z) ROOT.Position = vnew(x,y,z) end      -- stand somewhere
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


def run(revert=False, seconds=30, hp_at=None, hp_value=-1000.0, start=(100, 50, 100),
        server_owns=False):
    """Load the script fresh, drive it, return (log text, lua globals)."""
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    g = lua.globals()
    lua.execute(STUB)
    lua.execute("PLACE(%.1f, %.1f, %.1f)" % start)
    lua.execute(normalise(SCRIPT))
    if revert:
        lua.execute("SETREVERT(true)")
    if server_owns:
        lua.execute("SETOWNER(nil)")
    if hp_at is not None:
        # run to the moment of the kill, then hand the rest to the same driver
        lua.execute(f"DRIVE({hp_at})")
        lua.execute(f"SETHP({hp_value})")
    lua.execute(f"DRIVE({max(0.0, seconds - (hp_at or 0))})")
    return g["LOGDUMP"](), g


def lines(txt, needle):
    return [l for l in txt.splitlines() if needle in l]


STEP_RE = re.compile(r"^\[[\d:]+\.[\d]+\] step \d{3} \|")
CHECK_RE = re.compile(r"^\[[\d:]+\.[\d]+\] check \d{3} \|")


def step_lines(txt):
    """Only real write lines - the progress lines say 'step 20 of 145' too."""
    return [l for l in txt.splitlines() if STEP_RE.match(l)]


def check_lines(txt):
    return [l for l in txt.splitlines() if CHECK_RE.match(l)]


ASKED_RE = re.compile(r"asked \(([-\d.]+), ([-\d.]+), ([-\d.]+)\)")


def asked_xyz(line):
    m = ASKED_RE.search(line)
    return tuple(float(v) for v in m.groups()) if m else None


PAD = (5666.3, 70.7, -331.9)
LAND = (612.2, 70.7, -325.0)

print("=== T1: the route is the lightdark one, and the pace is 35 studs / 0.5s ===")
txt, g = run(seconds=1.0, start=(5666.3, 70.7, -331.9))
chk("the route is named end to end", "route     | lightdark pad -> forest landing" in txt,
    lines(txt, "route     |")[:1])
chk("the three legs are the measured ones",
    "path      | launch 423.3 | cruise 4573.5 | drop 72.7 | total 5069.5 studs" in txt,
    lines(txt, "path      |")[:1])
chk("145 steps of 35 studs, 72.5s", "config    | 35.0 studs every 0.50s x 145 steps = 72.5s" in txt,
    lines(txt, "config    |")[:1])
chk("standing on the pad, no snap write", "snap      | already at the lightdark pad" in txt,
    lines(txt, "snap      |")[:1])
chk("it says the -1000 pair is not called",
    "ChangeState(Freefall) and AutoRotate stay untouched" in txt, "")

print("\n=== T2: the first writes climb the launch leg ===")
steps = step_lines(txt)
chk("the first write is 35 studs along the launch", "s=0.0 -> 35.0 of 5069.5 (0%)" in steps[0],
    steps[0][:100])
chk("...towards the cruise start, gaining height",
    "(-1.0, 0.1, 0.0)" not in steps[0] and "asked (5631.5, 74.2, -331.9)" in steps[0],
    steps[0][:120])
chk("the leg it is on is named", "cruise start" in steps[0], steps[0][-40:])
chk("where it landed is reported", "landed (5631.5, 74.2, -331.9)" in steps[0], steps[0][:120])
chk("the world line comes with it",
    "state=Enum.HumanoidStateType.Running | grounded=" in txt, lines(txt, "state=Enum")[:1])

print("\n=== T3: cadence - one write per 0.5s, not one per frame ===")
chk("two writes in the first second, 0.5s apart", len(steps) == 3,
    f"{len(steps)} writes in 1.0s of frames (60 frames)")
txt10, _ = run(seconds=10, start=PAD)
n10 = len(step_lines(txt10))
chk("about 20 writes in 10s of flight (600 frames)", 19 <= n10 <= 22,
    f"{n10} writes in 10s")

print("\n=== T4: the whole path, with the server KEEPING every write ===")
flight_secs = 3 + 145 * 0.5 + 2
txt_all, g_all = run(seconds=flight_secs + 10, start=PAD)
allsteps = step_lines(txt_all)
chk("145 writes - the whole path", len(allsteps) == 145, f"{len(allsteps)} writes")
chk("the last write lands exactly on the pad",
    "asked (612.2, 70.7, -325.0)" in allsteps[-1] and "landed (612.2, 70.7, -325.0)" in allsteps[-1],
    allsteps[-1][:120])
chk("the last step is the partial one", "s=5040.0 -> 5069.5 of 5069.5 (100%)" in allsteps[-1],
    allsteps[-1][:110])
chk("it climbed to cruise and came back down",
    "asked (5631.5, 74.2," in allsteps[0] and "asked (612.2, 70.7," in allsteps[-1], "")
chk("every write is checked, one each", len(check_lines(txt_all)) == 145,
    f"{len(check_lines(txt_all))} verdicts for {len(allsteps)} writes")
chk("not one write was undone",
    not lines(txt_all, "REVERTED - the server") and not lines(txt_all, "MOVED ELSEWHERE"), "")
chk("progress is reported along the way",
    len(lines(txt_all, "PROGRESS   |")) >= 6, f"{len(lines(txt_all, 'PROGRESS   |'))} progress lines")
chk("it knows it landed", "LANDED    | at the forest landing (612.2, 70.7, -325.0)" in txt_all,
    lines(txt_all, "LANDED")[:1])
chk("landed on the pad itself", "0.0 studs from the pad" in txt_all, lines(txt_all, "LANDED")[:1])
chk("the walked distance is the path", "walked    | 5069.5 of 5069.5 studs of path (100%)" in txt_all,
    lines(txt_all, "walked    |")[:1])
chk("the net ground distance is the reference's 5054.1",
    "net       | 5054.1 studs across the ground" in txt_all, lines(txt_all, "net       |")[:1])
chk("the verdict names the outcome", "verdict   | THE WRITES STICK" in txt_all,
    lines(txt_all, "verdict   |")[:1])
chk("it stops because it arrived", "stopped   | landed at the forest landing" in txt_all,
    lines(txt_all, "stopped   |")[:1])
chk("noclip is restored, not leaked",
    "restored CanCollide on 2 part(s) - nothing leaked" in txt_all, lines(txt_all, "noclip    |")[-1:])
ys = [asked_xyz(l)[1] for l in allsteps if asked_xyz(l)]
chk("the altitude profile is the reference's: +42 up, then -42 down",
    ys and ys[0] == 74.2 and max(ys) == 112.7 and ys[-1] == 70.7,
    f"first {ys[0]}, peak {max(ys)}, last {ys[-1]}")
chk("it holds the cruise, it does not balloon",
    ys.count(112.7) > 100, f"{ys.count(112.7)} writes at cruise altitude")
parts = g_all["PARTS"]()
chk("every part is collidable again after the flight",
    all(p.CanCollide for p in parts.values()), "")

print("\n=== T5: a write that does not hold is retried from where we really are ===")
txt_rev, _ = run(revert=True, seconds=12, start=PAD)
chk("the undone write is named", "REVERTED - the server put us back" in txt_rev,
    lines(txt_rev, "REVERTED")[:1])
chk("it shows both positions", "then (5666.3, 70.7, -331.9)" in txt_rev,
    lines(txt_rev, "then ")[:1])
chk("the next write is measured from the truth, not from the failed target",
    "s=0.0 -> 35.0" in step_lines(txt_rev)[-1], step_lines(txt_rev)[-1][:90])
chk("it gives up after 5 in a row",
    "5 writes in a row were undone" in txt_rev, lines(txt_rev, "stopped   |")[:1])
chk("the summary still prints", "============ PATH FLIGHT SUMMARY ============" in txt_rev, "")
chk("it says the writes never survived", "verdict   | THE SERVER IS UNDOING THEM" in txt_rev,
    lines(txt_rev, "verdict   |")[:1])

print("\n=== T6: it starts with one write to the pad when we are not standing on it ===")
txt_snap, _ = run(seconds=6, start=(0, 50, 0))
chk("the snap is announced with the distance",
    "snap      | " in txt_snap and "studs from the lightdark pad - one write to the start line" in txt_snap,
    lines(txt_snap, "snap      |")[:1])
chk("the snap reports whether it held", "snap      | wrote (5666.3, 70.7, -331.9)" in txt_snap,
    lines(txt_snap, "snap      |")[1:2])
chk("then the path starts from the pad", "s=0.0 -> 35.0" in step_lines(txt_snap)[0],
    step_lines(txt_snap)[:1])

print("\n=== T6b: the ownership readout says who really owns the root ===")
# A nil GetNetworkOwner() means the SERVER owns it, and then every client write is
# a request. This is the readout that tells those two worlds apart, so it has to
# print the truth rather than a table address.
chk("a client-owned root reads as you", "owner=you" in txt_snap, lines(txt_snap, "owner=")[:1])
chk("no table address leaks into the log", "owner=table:" not in txt_snap, "")
txt_srv, _ = run(seconds=4, start=PAD, server_owns=True)
chk("a server-owned root reads as server", "owner=server" in txt_srv, lines(txt_srv, "owner=")[:1])

print("\n=== T7: a -1000 kill stops the flight and says what it was ===")
txt_hp, _ = run(seconds=12, hp_at=3.0, start=PAD)
chk("the death is logged", "DEATH      | hp=-1000.0" in txt_hp, lines(txt_hp, "DEATH")[:1])
chk("it is called an external kill",
    "EXTERNAL KILL: hp was SET, this is not damage" in txt_hp, lines(txt_hp, "DEATH")[:1])
chk("the flight stops there", "stopped   | the character died at step" in txt_hp,
    lines(txt_hp, "stopped   |")[:1])
chk("the summary still prints", "============ PATH FLIGHT SUMMARY ============" in txt_hp, "")

print("\n=== T8: the route in the file is the measured one (static check) ===")
block = SCRIPT.split("local PATH = {", 1)[1].split("\n}", 1)[0]
pts = []
for line in block.splitlines():
    if "pos = Vector3.new" in line:
        nums = line.split("Vector3.new(", 1)[1].split(")", 1)[0]
        pts.append(tuple(float(n) for n in nums.split(",")))
chk("four waypoints", len(pts) == 4, str(pts))
chk("it starts on the lightdark pad", pts and pts[0] == PAD, str(pts[:1]))
chk("it cruises at 112.7 (+42.0 from 70.7)",
    pts and pts[1][1] == 112.7 and round(pts[1][1] - pts[0][1], 1) == 42.0, str(pts[1:2]))
chk("it lands on the forest pad", pts and pts[-1] == LAND, str(pts[-1:]))
chk("the drop is -42.0", pts and round(pts[-1][1] - pts[-2][1], 1) == -42.0, str(pts[-2:]))

print("\n=== T9: the script never makes the -1000 calls (static check) ===")
code = re.sub(r"--\[\[.*?\]\]", "", SCRIPT, flags=re.S)      # drop the header block
code = re.sub(r"--[^\n]*", "", code)                            # drop line comments
chk("no ChangeState call in the code", ":ChangeState" not in code, "")
chk("AutoRotate is never set", not re.search(r"AutoRotate\s*=", code), "")
chk("no velocity is written", not re.search(r"AssemblyLinearVelocity\s*=", code), "")
chk("the write is a direct root.CFrame assignment",
    "root.CFrame = CFrame.new(target)" in code, "")
chk("it does not move the humanoid state either", "SetStateEnabled" not in code, "")

print(f"\n{'='*60}\nRESULT: {PASS} passed, {FAIL} failed")
if FAILED:
    print("FAILED: " + ", ".join(FAILED))
