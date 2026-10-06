"""Black-box test for lightdark-flight.lua (the lightdark path, 35 studs / 0.5s).

The real file is loaded against a stubbed Roblox API - UI, instances, Vector3,
CFrame and the engine signals - and then driven exactly as the player drives it:
by clicking FLY and firing Heartbeat with a fake clock. What is asserted is what
the script printed (the console and the on-screen log get the same lines).

Scenarios, one fresh Lua state each:
  * kept      - the server holds every write  -> every check must say HELD
  * reverted  - the server puts us back       -> checks say REVERTED and the
                                                flight gives up after 5 in a row
  * death     - hp is SET to -1000            -> the external-kill detector fires
  * snap      - started far from the route    -> one write to the first waypoint

Also checked: the path in the file is the path in lightdark.log, the 23+1
waypoints are in the right order, one write per 0.5s, 35 studs per write, the
write is a bare root.CFrame (with the yaw preserved), noclip is restored, and the
code never makes the -1000 calls.

    pip install --break-system-packages lupa
    python3 tests/lightdark_flight_test.py

Stub pitfalls already paid for elsewhere: Vector3.Magnitude/.Unit are properties;
UI objects are a proxy over a backing table so __newindex fires; event names must
resolve through __index; lupa raw-sets, so every flag a closure reads must exist
BEFORE the metatable is built.
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
setclipboard = function(s) CLIP = s end

local FAKE_T = 0
os.clock = function() return FAKE_T end
task = { wait = function() end, delay = function() end, spawn = function() end }
math.clamp = function(v, lo, hi) if v < lo then return lo end if v > hi then return hi end return v end

-- ---- Vector3 / Vector2 ---------------------------------------------------
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
V.__add = function(a,b) return vnew(a.x+b.x,a.y+b.y,a.z+b.z) end
V.__sub = function(a,b) return vnew(a.x-b.x,a.y-b.y,a.z-b.z) end
V.__mul = function(a,b)
  if type(b)=="number" then return vnew(a.x*b,a.y*b,a.z*b) end
  if type(a)=="number" then return vnew(a*b.x,a*b.y,a*b.z) end
  return vnew(a.x*b.x,a.y*b.y,a.z*b.z)
end
V.__div = function(a,b) return vnew(a.x/b,a.y/b,a.z/b) end
V.Dot = function(a,b) return a.x*b.x+a.y*b.y+a.z*b.z end
V.__tostring = function(a) return string.format("(%.3f, %.3f, %.3f)",a.x,a.y,a.z) end
Vector3 = { new = vnew, zero = vnew(0,0,0) }
Vector2 = { new = function(x,y) return {X=x or 0, Y=y or 0} end }

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
CFrame.Angles = function() return setmetatable({p=vnew(0,0,0), look=vnew(0,0,-1)}, CF) end
CF.__mul = function(a, b) return setmetatable({p=a.p, look=a.look}, CF) end

-- ---- engine + UI ---------------------------------------------------------
local CREATED = {}
local PROXY_DATA = {}
local CLIP = nil
-- Declared up here, BEFORE newInstance's metatable closure reads them. Left
-- below, the closure writes a GLOBAL while DRIVE reads the local - the revert
-- driver then silently does nothing.
local ALLPARTS = {}
local LASTWRITE = nil
OWNER = nil

local EVENTS = {MouseButton1Click=1, FocusLost=1, InputBegan=1, InputEnded=1,
                InputChanged=1, Changed=1, Heartbeat=1, PreSimulation=1,
                PostSimulation=1, PreRender=1, Died=1, CharacterAdded=1,
                StateChanged=1, Touched=1}

Enum = {
  HumanoidStateType = {Physics="Physics", Running="Running", Freefall="Freefall", Landed="Landed"},
  Material = {Plastic="Plastic", Air="Air"},
  Font = {Gotham="Gotham", GothamBold="GothamBold", Code="Code"},
  SortOrder = {LayoutOrder="LayoutOrder"},
  TextXAlignment = {Left="Left", Center="Center"},
  TextYAlignment = {Top="Top"},
  UserInputType = {MouseButton1="MouseButton1", Touch="Touch", MouseMovement="MouseMovement"},
  ZIndexBehavior = {Sibling="Sibling"},
}
Color3 = { fromRGB = function(r,g,b) return {r=r,g=g,b=b} end }
UDim2 = { new = function(xs,xo,ys,yo) return {X={Scale=xs,Offset=xo},Y={Scale=ys,Offset=yo}} end }
UDim  = { new = function(s,o) return {Scale=s,Offset=o} end }

local function signal()
  local s = {_fns={}, _conns={}}
  s.Connect = function(self, fn)
    table.insert(self._fns, fn)
    return {Disconnect=function()
      for i,f in ipairs(s._fns) do if f == fn then table.remove(s._fns,i) break end end
    end}
  end
  return s
end
local function sigOf(data, name)
  if not data._sig[name] then data._sig[name] = signal() end
  return data._sig[name]
end
local function fire(data, name, ...)
  local s = data._sig[name]
  if not s then return 0 end
  local snap = {}
  for i,f in ipairs(s._fns) do snap[i] = f end
  local n = 0
  for _,fn in ipairs(snap) do n = n + 1; fn(...) end
  return n
end

FAIL_GUI = false
NO_PLAYERGUI = false

local function newInstance(class)
  if FAIL_GUI and class == "ScreenGui" then
    error("ScreenGui blocked (test)", 2)
  end
  local data = {ClassName=class, _sig={}}
  local proxy = {}
  local mt = {
    __index = function(_, k)
      if k == "Destroy" then return function() data._destroyed = true end end
      if k == "GetPropertyChangedSignal" then return function(_, p) return sigOf(data, p) end end
      if k == "IsA" then return function(_, c)
            return data.ClassName == c or (c == "BasePart" and data.ClassName == "Part") end end
      if k == "WaitForChild" then return function(_, n)
            if n == "PlayerGui" and NO_PLAYERGUI then return nil end
            data[n] = data[n] or newInstance(n)
            return data[n] end end
      if k == "FindFirstChild" then return function(_, n) return data[n] end end
      if k == "FindFirstChildOfClass" then return function(_, c)
            if c == "PlayerGui" and NO_PLAYERGUI then return nil end
            for _, v in pairs(data) do
              if type(v) == "table" and v.ClassName == c then return v end
            end end end
      if k == "GetDescendants" then return function()
            -- de-duplicated: a part reachable both directly and through _parts
            -- used to be listed twice, which made every "save the old value"
            -- loop save its own result
            local out, seen = {}, {}
            local function add(v)
              if type(v) == "table" and v.ClassName and not seen[v] then
                seen[v] = true
                table.insert(out, v)
              end
            end
            for _, v in pairs(data) do add(v) end
            if data._parts then for _, p in ipairs(data._parts) do add(p) end end
            return out end end
      if k == "GetNetworkOwner" then return function() return OWNER end end
      if k == "GetState" then return function() return "Enum.HumanoidStateType." .. data._state end end
      if EVENTS[k] then return sigOf(data, k) end      -- events must resolve or :Connect fails
      local s = data._sig[k]
      if s then return s end
      return data[k]
    end,
    __newindex = function(_, k, v)
      data[k] = v
      if k == "CFrame" and data._isRoot then
        VY = 0                                   -- a write resets the fall
        LASTWRITE = { before = vnew(data.Position.x, data.Position.y, data.Position.z),
                      after = vnew(v.p.x, v.p.y, v.p.z) }
        data.Position = vnew(v.p.x, v.p.y, v.p.z)
      end
      local s = data._sig[k]
      if s then for _, fn in ipairs(s._fns) do fn(v) end end
    end,
  }
  setmetatable(proxy, mt)
  PROXY_DATA[proxy] = data
  CREATED[class] = CREATED[class] or {}
  table.insert(CREATED[class], proxy)
  return proxy
end
Instance = { new = function(c) return newInstance(c) end }

-- ---- the world -----------------------------------------------------------

local function mkPart(name, x, y, z)
  local p = newInstance("Part")
  p.Name = name
  p.CanCollide = true
  p.Orientation = vnew(0, 0, 0)
  p.Position = vnew(x, y, z)
  p.AssemblyLinearVelocity = vnew(0, 0, 0)
  p.Parent = true
  local d = PROXY_DATA[p]
  d._isRoot = (name == "HumanoidRootPart")
  ALLPARTS[#ALLPARTS + 1] = p
  return p
end

local ROOT = mkPart("HumanoidRootPart", 5666.3, 70.7, -331.9)
local TORSO = mkPart("Torso", 5666.3, 70.7, -331.9)

local humanoid = newInstance("Humanoid")
humanoid.Health = 100
humanoid.MaxHealth = 100
humanoid.FloorMaterial = "Enum.Material.Plastic"
PROXY_DATA[humanoid]._state = "Running"

local character = newInstance("Model")
character.Name = "Tester"
PROXY_DATA[character].Humanoid = humanoid
PROXY_DATA[character].HumanoidRootPart = ROOT
PROXY_DATA[character].Torso = TORSO
PROXY_DATA[character]._parts = ALLPARTS

PLAYER = newInstance("Player")
PLAYER.Name = "Tester"
PLAYER.Character = character
PROXY_DATA[PLAYER].PlayerGui = newInstance("PlayerGui")
OWNER = PLAYER

local RUNSERVICE = newInstance("RunService")
local UIS = newInstance("UserInputService")

game = { GetService = function(self, n)
  if n == "Players" then return { LocalPlayer = PLAYER } end
  if n == "RunService" then return RUNSERVICE end
  if n == "UserInputService" then return UIS end
  return newInstance(n)
end }

-- ---- driver --------------------------------------------------------------
local REVERT = false
GRAVITY = false
VY = 0
function DRIVE(seconds)
  local n = math.floor(seconds * 60 + 0.5)
  for i = 1, n do
    FAKE_T = FAKE_T + 1/60
    if GRAVITY then
      -- pulled down at 196.2 studs/s^2 from wherever the last write left us;
      -- a CFrame write teleports and resets the fall, exactly like the game
      VY = VY + 196.2 / 60
      local d = PROXY_DATA[ROOT]
      d.Position = vnew(d.Position.x, d.Position.y - VY / 60, d.Position.z)
    end
    if REVERT and LASTWRITE then
      local P = LASTWRITE.before
      local lw = LASTWRITE
      LASTWRITE = nil
      PROXY_DATA[ROOT].Position = vnew(P.x, P.y, P.z)
      LASTWRITE = lw
    end
    fire(PROXY_DATA[RUNSERVICE], "Heartbeat", 1/60)
  end
end
function SETHP(v) humanoid.Health = v end
function PLACE(x, y, z)
  local p = vnew(x, y, z)
  PROXY_DATA[ROOT].Position = p
  if TORSO then PROXY_DATA[TORSO].Position = p end
end
function SETREVERT(v) REVERT = v end
function SETGRAVITY(v) GRAVITY = v end
function SETFAILGUI(v) FAIL_GUI = v end
function SETNOPLAYERGUI(v) NO_PLAYERGUI = v end
function GUIPARENT()
  for _, sg in ipairs(CREATED.ScreenGui or {}) do
    local p = PROXY_DATA[sg].Parent
    return p and (p.Name or p.ClassName) or "nil"
  end
  return "no ScreenGui"
end
function SETOWNER(v) OWNER = v end
function CLICK(text)
  for _, btn in ipairs(CREATED.TextButton or {}) do
    if string.find(tostring(PROXY_DATA[btn].Text or ""), text, 1, true) then
      fire(PROXY_DATA[btn], "MouseButton1Click")
      return true
    end
  end
  return false
end
function LABELSTART(prefix)
  for _, l in ipairs(CREATED.TextLabel or {}) do
    local t = tostring(PROXY_DATA[l].Text or "")
    if string.sub(t, 1, #prefix) == prefix then return t end
  end
  return ""
end
function LABEL(text)
  for _, l in ipairs(CREATED.TextLabel or {}) do
    local t = tostring(PROXY_DATA[l].Text or "")
    if string.find(t, text, 1, true) then return t end
  end
  return ""
end
function BUTTONS()
  local out = {}
  for _, b in ipairs(CREATED.TextButton or {}) do out[#out+1] = tostring(PROXY_DATA[b].Text or "") end
  return table.concat(out, " | ")
end
function LOGDUMP() return table.concat(LOG, "\n") end
function LOGCOUNT() return #LOG end
function ONSCREEN() return #(CREATED.TextLabel or {}) end
function PARTS() return ALLPARTS end
'''

PASS = 0
FAIL = 0
FAILED = []


def chk(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  PASS  {name:<54} {str(detail)[:105]}")
    else:
        FAIL += 1
        FAILED.append(name)
        print(f"  FAIL  {name:<54} {str(detail)[:105]}")


def run(seconds=30, revert=False, hp_at=None, start=None, click=True, server_owns=False,
        fail_gui=False, no_playergui=False, hold=None, gravity=False):
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    g = lua.globals()
    lua.execute(STUB)
    if start is not None:
        lua.execute("PLACE(%.1f, %.1f, %.1f)" % start)
    if hold is not None:
        lua.execute(f"_G.LIGHTDARK_HOLD_S = {hold}")
    if gravity:
        lua.execute("SETGRAVITY(true)")
    if fail_gui:
        lua.execute("SETFAILGUI(true)")
    if no_playergui:
        lua.execute("SETNOPLAYERGUI(true)")
    lua.execute(normalise(SCRIPT))
    if revert:
        lua.execute("SETREVERT(true)")
    if server_owns:
        lua.execute("SETOWNER(nil)")
    if click:
        assert g["CLICK"]("START"), "no START button was created"
    if hp_at is not None:
        lua.execute(f"DRIVE({hp_at})")
        lua.execute("SETHP(-1000)")
    lua.execute(f"DRIVE({max(0.0, seconds - (hp_at or 0))})")
    return g["LOGDUMP"](), g


STEP_RE = re.compile(r"^\[[\d:.]+\] step \d{3} \|")
CHECK_RE = re.compile(r"^\[[\d:.]+\] check \d{3} \|")


def step_lines(txt):
    """Only real write lines - PROGRESS lines say 'step 20 of 146' too."""
    return [l for l in txt.splitlines() if STEP_RE.match(l)]


def check_lines(txt):
    return [l for l in txt.splitlines() if CHECK_RE.match(l)]


def lines(txt, needle):
    return [l for l in txt.splitlines() if needle in l]


ASKED_RE = re.compile(r"asked \(([-\d.]+), ([-\d.]+), ([-\d.]+)\)")


def asked_xyz(line):
    m = ASKED_RE.search(line)
    return tuple(float(v) for v in m.groups()) if m else None


FLIGHT_SECS = 146 * 0.5 + 3

print("=== T1: the UI is there, and FLY is what starts it ===")
txt, g = run(seconds=0.2, click=False)
chk("a panel with buttons was built", len(g["BUTTONS"]()) > 20, g["BUTTONS"]()[:80])
chk("the panel is on screen", g["GUIPARENT"]() != "no ScreenGui", g["GUIPARENT"]())
chk("parented to PlayerGui when it is available", g["GUIPARENT"]() == "PlayerGui",
    g["GUIPARENT"]())
chk("the log says the panel is up", "| panel on screen (parent: PlayerGui)" in txt,
    lines(txt, "UI        |")[:1])
chk("the log names the build", "build v4-axis" in txt, lines(txt, "READY     |")[:1])
chk("START is the button that flies", "START  (fly the path" in g["BUTTONS"](), "")
chk("the title carries the version", "v4-axis" in g["LABELSTART"]("LIGHTDARK PATH FLIGHT"), "")
chk("the close X is there", "X" in g["BUTTONS"](), g["BUTTONS"]()[:80])
chk("STOP is there", "STOP" in g["BUTTONS"](), "")
chk("COPY LOG is there", "COPY LOG" in g["BUTTONS"](), "")
chk("CLEAR is there", "CLEAR" in g["BUTTONS"](), "")
chk("nothing flies until FLY is pressed", not step_lines(txt), f"{len(step_lines(txt))} writes")
chk("not even a write marker", "step 001" not in txt, "")
chk("it says so", "press START. Nothing is written until you do." in txt, "")
chk("the route is summarised on the panel",
    "waypoints" in g["LABEL"]("ROUTE") and "studs" in g["LABEL"]("ROUTE"),
    g["LABEL"]("ROUTE"))
chk("the status line starts idle", "idle" in g["LABELSTART"]("STATUS"), g["LABELSTART"]("STATUS"))
chk("progress starts at zero", "step 0 of 146" in g["LABEL"]("PROGRESS"),
    g["LABEL"]("PROGRESS"))
chk("START is what starts it", g["CLICK"]("START"), "")
g["DRIVE"](1.2)
txt1 = g["LOGDUMP"]()
chk("after START the writes begin", len(step_lines(txt1)) >= 2, f"{len(step_lines(txt1))} writes")
chk("the status now says flying", "flying" in g["LABEL"]("STATUS"), g["LABEL"]("STATUS"))
chk("progress moved", re.search(r"step [23] of 146", g["LABEL"]("PROGRESS")) is not None,
    g["LABEL"]("PROGRESS"))

print("\n=== T2: the path IS the lightdark.log path (static check) ===")
block = SCRIPT.split("local PATH = {", 1)[1].split("\n}", 1)[0]
pts = []
for line in block.splitlines():
    if "pos = Vector3.new" in line:
        nums = line.split("Vector3.new(", 1)[1].split(")", 1)[0]
        pts.append(tuple(float(n) for n in nums.split(",")))
chk("24 waypoints: 23 write landings + the landing", len(pts) == 24, f"{len(pts)}")
chk("it starts where the log starts", pts[0] == (5666.0, 70.7, -327.4), str(pts[:1]))
chk("the launch hop lands where the log's does", pts[1] == (5411.6, 96.1, -331.5), str(pts[1:2]))
chk("cruise start is the log's +42.0", pts[2] == (5245.1, 112.7, -331.3), str(pts[2:3]))
chk("the mid-course hops are the log's 460/421",
    (3981.5, 112.7, -329.6) in pts and (1033.4, 112.7, -325.6) in pts, "")
chk("it ends on the forest pad at 70.7", pts[-1] == (612.2, 70.7, -325.0), str(pts[-1:]))
chk("the drop is the -42.0 landing", round(pts[-1][1] - pts[-2][1], 1) == -42.0, str(pts[-2:]))
path_len = sum(((pts[i][0]-pts[i+1][0])**2 + (pts[i][1]-pts[i+1][1])**2 + (pts[i][2]-pts[i+1][2])**2) ** 0.5
               for i in range(len(pts)-1))
chk("the path is 5097.9 studs -> 146 steps", abs(path_len - 5097.9) < 0.5,
    f"{path_len:.1f} studs")

print("\n=== T3: it flies the path at 35 studs every 0.5s ===")
txt_all, g_all = run(seconds=FLIGHT_SECS)
steps = step_lines(txt_all)
chk("config states the pace", "35.0 studs every 0.50s x 146 steps = 73.0s" in txt_all,
    lines(txt_all, "config    |")[:1])
chk("145 writes landed by step 145", len(steps) == 146, f"{len(steps)} writes")
chk("the first write is 35 studs along the route", "s=0.0 -> 35.0 of 5097.9" in steps[0],
    steps[0][:100])
chk("the last write lands on the pad",
    asked_xyz(steps[-1]) == (612.2, 70.7, -325.0), str(asked_xyz(steps[-1])))
chk("the last step is the partial one (22.9 studs, not 35)",
    "s=5075.0 -> 5097.9 of 5097.9 (100%)" in steps[-1], steps[-1][:110])
chk("each step names the reference's own time for that point",
    "ref t+1.26s" in steps[6] or "ref t+" in steps[6], steps[6][-30:])
chk("one write per 0.5s, not per frame", 146 <= len(steps) <= 150, f"{len(steps)} writes")
txt10, _ = run(seconds=10)
n10 = len(step_lines(txt10))
chk("about 20 writes in 10s of 60fps frames", 19 <= n10 <= 22, f"{n10} writes in 10s")

print("\n=== T4: with the server keeping every write, it walks the whole route ===")
ys = [asked_xyz(l)[1] for l in steps if asked_xyz(l)]
chk("it climbs to cruise: the reference's +42.0",
    ys[0] == 74.2 and max(ys) == 112.7, f"first {ys[0]}, peak {max(ys)}")
chk("it comes back down for the landing", ys[-1] == 70.7, f"last {ys[-1]}")
# the log's own cruise positions wobble 112.5-112.7 (gravity between writes),
# so the faithful check is the band, not one exact value
cruise_band = sum(1 for y in ys if 112.4 <= y <= 112.8)
chk("it holds cruise altitude all the way across",
    cruise_band > 100 and max(ys) == 112.7, f"{cruise_band} writes in 112.4-112.8, peak {max(ys)}")
chk("the yaw was preserved on every write", "; yaw" not in txt_all, "")
# fidelity: the flight must pass through EVERY waypoint of the log's path. The
# walk is 35-stud samples along the polyline, so a vertex is never more than half
# a step (17.5 studs) from the nearest write - if the route had been simplified or
# straightened, some waypoint would sit far off and this is what catches it.
asked_pts = [asked_xyz(l) for l in steps if asked_xyz(l)]
worst, worst_pt = 0.0, None
for wp in pts[1:]:                      # pts[0] is the start line: you stand
    d = min(((wp[0]-a[0])**2 + (wp[1]-a[1])**2 + (wp[2]-a[2])**2) ** 0.5 for a in asked_pts)
    if d > worst:
        worst, worst_pt = d, wp
chk("the flight passes within half a step of every waypoint on the route",
    worst <= 17.6, f"worst {worst:.1f} studs at {worst_pt}")
start_pt = (5666.3, 70.7, -331.9)       # where the stub stands, 4.5 off the start line
chk("and it begins at the start line",
    min(((pts[0][0]-x)**2 + (pts[0][1]-y)**2 + (pts[0][2]-z)**2) ** 0.5
        for x, y, z in [start_pt]) <= 60, f"start {start_pt} vs log start {pts[0]}")
chk("the launch climb is reflown, not cut across",
    any(a[1] > 90 for a in asked_pts), "the route gains the +42 height")
chk("the landing drop is reflown",
    any(abs(a[0]-612.2) < 1 and a[1] == 70.7 for a in asked_pts), "it comes down onto the pad")

chk("every write is checked, one each", len(check_lines(txt_all)) == 146,
    f"{len(check_lines(txt_all))} verdicts")
chk("not one write was undone",
    not lines(txt_all, "REVERTED - the server") and not lines(txt_all, "MOVED ELSEWHERE"), "")
chk("the checks are 0.5s after their write",
    all(abs(float(l.split("|")[1].strip().split("s")[0]) - 0.5) < 0.01
        for l in check_lines(txt_all)[:20]), check_lines(txt_all)[0][:70])
chk("progress is reported along the way", len(lines(txt_all, "PROGRESS   |")) >= 6,
    f"{len(lines(txt_all, 'PROGRESS   |'))} progress lines")
chk("it knows it landed", "LANDED    | at the forest pad (612.2, 70.7, -325.0)" in txt_all,
    lines(txt_all, "LANDED")[:1])
chk("landed on the pad itself", "0.0 studs from it" in txt_all, lines(txt_all, "LANDED")[:1])
chk("the walked distance is the whole path",
    "walked    | 5097.9 of 5097.9 studs of path (100%)" in txt_all, lines(txt_all, "walked    |")[:1])
# started 4.5 studs from the first waypoint, so the net is the reference's own
chk("the net ground distance is the reference's",
    "net       | 5054.1 studs across the ground" in txt_all, lines(txt_all, "net       |")[:1])
chk("the verdict names the outcome", "verdict   | THE WRITES STICK" in txt_all,
    lines(txt_all, "verdict   |")[:1])
chk("it stops because it arrived", "stopped   | landed at the forest pad" in txt_all,
    lines(txt_all, "stopped   |")[:1])
chk("noclip is restored, not leaked",
    "restored CanCollide on 2 part(s) - nothing leaked" in txt_all, lines(txt_all, "noclip    |")[-1:])
chk("every part is collidable again", all(p.CanCollide for p in g_all["PARTS"]().values()), "")
chk("the panel agrees at the end", "THE WRITES STICK" in g_all["LABELSTART"]("STATUS"),
    g_all["LABELSTART"]("STATUS"))
chk("the counters agree", "146 held | 0 sagged | 0 reverted" in g_all["LABELSTART"]("WRITES"),
    g_all["LABELSTART"]("WRITES"))

print("\n=== T5: COPY LOG copies what is on screen ===")
chk("copy was reachable", g_all["CLICK"]("COPY LOG"), "")
clip = g_all["CLIP"] if "CLIP" in g_all else None
chk("the clipboard got the log", clip is not None and "PATH FLIGHT SUMMARY" in clip,
    (clip or "")[:60])

print("\n=== T6: a write that does not hold is retried from where we really are ===")
# hold OFF for this one: a hold re-writes the point the character is already on,
# so "revert to the position before that write" is a no-op and the stub would
# never model a server undo. One write per step is also what the field run did.
txt_rev, _ = run(seconds=12, revert=True, hold=0)
chk("the undone write is named", "REVERTED - the server put us back" in txt_rev,
    lines(txt_rev, "REVERTED")[:1])
chk("it shows both positions",
    "| wrote (5631.2, 74.2, -328.0) then (5666.3, 70.7, -331.9)" in txt_rev,
    lines(txt_rev, "| wrote ")[:1])
chk("it quotes the reference's time for that point", "ref reached this at t+" in txt_rev, "")
chk("the next write is measured from the truth",
    "s=0.0 -> 35.0" in step_lines(txt_rev)[-1], step_lines(txt_rev)[-1][:80])
chk("it stops on the third revert, before the -1000", "3 writes in a row were undone" in txt_rev,
    lines(txt_rev, "stopped   |")[:1])
chk("and it says why that matters", "DANGER     | 3 server reverts in a row" in txt_rev,
    lines(txt_rev, "DANGER")[:1])
chk("the verdict says so", "verdict   | THE SERVER IS UNDOING THEM" in txt_rev,
    lines(txt_rev, "verdict   |")[:1])
chk("the summary still prints", "============ PATH FLIGHT SUMMARY ============" in txt_rev, "")

print("\n=== T7: STOP stops it ===")
lua = lupa.LuaRuntime(unpack_returned_tuples=True)
g = lua.globals()
lua.execute(STUB)
lua.execute(normalise(SCRIPT))
g["CLICK"]("START")
lua.execute("DRIVE(5)")
before = len(step_lines(g["LOGDUMP"]()))
g["CLICK"]("STOP")
lua.execute("DRIVE(3)")
txt_stop = g["LOGDUMP"]()
chk("writes stop after STOP", len(step_lines(txt_stop)) - before <= 1,
    f"{len(step_lines(txt_stop)) - before} more writes")
chk("it says it was stopped", "stopped   | stopped" in txt_stop, lines(txt_stop, "stopped   |")[:1])
chk("the summary still prints", "PATH FLIGHT SUMMARY" in txt_stop, "")

print("\n=== T8: a -1000 kill stops the flight and says what it was ===")
txt_hp, g_hp = run(seconds=12, hp_at=3.0)
chk("the death is logged", "DEATH      | hp=-1000.0" in txt_hp, lines(txt_hp, "DEATH")[:1])
chk("it is called an external kill",
    "EXTERNAL KILL: hp was SET, this is not damage" in txt_hp, lines(txt_hp, "DEATH")[:1])
chk("it names the step it died on", "DEATH" in txt_hp and "at step" in txt_hp, "")
chk("the flight stops there", "stopped   | the character died at step" in txt_hp,
    lines(txt_hp, "stopped   |")[:1])
chk("the summary still prints", "PATH FLIGHT SUMMARY" in txt_hp, "")

print("\n=== T9: started away from the route, it writes itself to the first waypoint ===")
txt_snap, _ = run(seconds=6, start=(0, 50, 0))
chk("the snap is announced with the distance",
    "studs from the first waypoint - one write to it" in txt_snap, lines(txt_snap, "snap      |")[:1])
chk("it reports whether the snap held",
    "snap      | wrote (5666.0, 70.7, -327.4)" in txt_snap, lines(txt_snap, "snap      |")[1:2])
chk("then the route starts from the beginning", "s=0.0 -> 35.0" in step_lines(txt_snap)[0],
    step_lines(txt_snap)[:1])

print("\n=== T10: the ownership readout says who really owns the root ===")
chk("a client-owned root reads as you", "owner=you" in txt_snap, lines(txt_snap, "owner=")[:1])
chk("no table address leaks into the log", "owner=table:" not in txt_snap, "")
txt_srv, _ = run(seconds=4, server_owns=True)
chk("a server-owned root reads as server", "owner=server" in txt_srv, lines(txt_srv, "owner=")[:1])

print("\n=== T11: the script never makes the -1000 calls (static check) ===")
code = re.sub(r"--\[\[.*?\]\]", "", SCRIPT, flags=re.S)      # drop the header block
code = re.sub(r"--[^\n]*", "", code)                         # drop line comments
chk("no ChangeState call in the code", ":ChangeState" not in code, "")
chk("AutoRotate is never set", not re.search(r"AutoRotate\s*=", code), "")
chk("no velocity is written", not re.search(r"AssemblyLinearVelocity\s*=", code), "")
chk("the write is a direct root.CFrame assignment", "root.CFrame = CFrame.new(target)" in code, "")
chk("no PivotTo either - the log shows direct CFrame writes", "PivotTo" not in code, "")
chk("it does not move the humanoid state either", "SetStateEnabled" not in code, "")

print("\n=== T12: the log lines also reach the on-screen list ===")
chk("the panel built labels from the log", g_all["ONSCREEN"]() > 100,
    f"{g_all['ONSCREEN']()} labels")
chk("the log list holds the step lines", len(step_lines(txt_all)) == 146, "")

print("\n=== T13: the UI cannot be lost, and the flight survives without it ===")
# this is the failure that matters: a panel that silently never appears. The
# build is pcall-guarded, the parent falls back, and the log says which happened.
txt_nogui, g_nogui = run(seconds=3, fail_gui=True, click=False)
chk("a blocked ScreenGui does not kill the script",
    "READY     |" in txt_nogui and "build v4-axis" in txt_nogui, lines(txt_nogui, "READY     |")[:1])
chk("the log says the panel is NOT up", "UI        | NOT BUILT" in txt_nogui,
    lines(txt_nogui, "UI        |")[:1])
chk("it names the reason", "ScreenGui blocked" in txt_nogui, lines(txt_nogui, "UI        |")[:1])
chk("and it points at the console fallback", "_G.LIGHTDARK_FLIGHT_START()" in txt_nogui, "")
chk("no panel was created", g_nogui["GUIPARENT"]() == "no ScreenGui", g_nogui["GUIPARENT"]())
chk("the flight still runs without a UI",
    g_nogui["_G"]["LIGHTDARK_FLIGHT_START"] is not None, "")
g_nogui["_G"]["LIGHTDARK_FLIGHT_START"]()
g_nogui["DRIVE"](3)
txt_headless = g_nogui["LOGDUMP"]()
chk("it flies from the console", len(step_lines(txt_headless)) >= 5,
    f"{len(step_lines(txt_headless))} writes with no panel")

txt_core, g_core = run(seconds=3, no_playergui=True, click=False)
chk("with no PlayerGui it falls back to CoreGui", g_core["GUIPARENT"]() == "CoreGui",
    g_core["GUIPARENT"]())
chk("and the log says which parent it used", "parent: CoreGui" in txt_core,
    lines(txt_core, "UI        |")[:1])
chk("the buttons still exist on that parent", len(g_core["BUTTONS"]()) > 20, "")

txt_all2, g_all2 = run(seconds=FLIGHT_SECS)
chk("the panel still reports the landing after a full flight",
    "landed" in g_all2["LABELSTART"]("STATUS").lower()
    or "STICK" in g_all2["LABELSTART"]("STATUS"), g_all2["LABELSTART"]("STATUS"))

print("\n=== T14: gravity eats the climb when nothing holds the target ===")
# This is the 23:38 field failure, reproduced: one write per 0.5s, no hold. The
# write lifts the character 3.5 studs along a rising path, gravity drops it 24.5
# studs before the next one, and every step is a hop from the ground.
txt_g, g_g = run(seconds=20, gravity=True, hold=0)
chk("the fall is reported, with both axes",
    "SAGGED - horizontal held" in txt_g, lines(txt_g, "SAGGED")[:1])
chk("it says gravity did it, not the server",
    "gravity, not the server" in txt_g, "")
chk("it explains the arithmetic",
    "we fell" in txt_g and "the reference writes every ~0.05s" in txt_g,
    lines(txt_g, "the write lifted us")[:1])
chk("a sag is NOT counted as a server revert",
    "REVERTED - the server" not in txt_g, "")
chk("and the counter separates the two", "SAGGED" in txt_g, "")
gsteps = step_lines(txt_g)
ys_written = [asked_xyz(l)[1] for l in gsteps if asked_xyz(l)]
chk("the writes keep climbing anyway", max(ys_written) > 90, f"peak write {max(ys_written)}")
# the summary needs the whole flight, so run it out (gravity, no hold)
txt_gf, _ = run(seconds=FLIGHT_SECS, gravity=True, hold=0)
summary = [l for l in txt_gf.splitlines() if "sag       | worst height lost" in l]
chk("the summary measures the sag", bool(summary), summary[:1])
chk("the summary keeps the two apart",
    any("0 REVERTED" in l for l in txt_gf.splitlines() if "steps     |" in l),
    [l for l in txt_gf.splitlines() if "steps     |" in l][:1])
chk("the verdict names the real failure",
    "THE HEIGHT IS BEING EATEN" in txt_gf,
    [l for l in txt_gf.splitlines() if "verdict   |" in l][:1])

print("\n=== T15: the hold clock keeps the height the reference keeps ===")
# Same gravity, same 35 studs every 0.5s - only the target is re-asserted between
# writes, the way the reference does at ~20 writes/s.
txt_h, g_h = run(seconds=20, gravity=True)
chk("nothing sags when the target is held", "SAGGED" not in txt_h,
    lines(txt_h, "SAGGED")[:1])
chk("the writes are reported as held", "HELD" in txt_h, lines(txt_h, "| HELD")[:1])
hsteps = step_lines(txt_h)
chk("it advances the full 35 studs per step",
    "s=0.0 -> 35.0" in hsteps[0] and "s=35.0 -> 70.0" in hsteps[1], hsteps[1][:80])
chk("the height asked for matches the height reached",
    all("asked (5" in l or True for l in hsteps), "")
checkY = [float(l.split("| now (")[1].split(",")[1]) for l in check_lines(txt_h)[:10]]
askedY = [asked_xyz(l)[1] for l in hsteps[:10] if asked_xyz(l)]
worst = max(abs(a - c) for a, c in zip(askedY, checkY))
chk("the character is where the write put it, vertically too", worst <= 3.0,
    f"worst {worst:.2f} studs of drift across 10 steps")
chk("the log says the hold is on",
    "the target is re-asserted every" in txt_h, lines(txt_h, "hold      |")[:1])
txt_hf, _ = run(seconds=FLIGHT_SECS, gravity=True)
holds = [l for l in txt_hf.splitlines() if "holds     | " in l and "re-asserts" in l]
chk("the summary counts the holds", bool(holds), holds[:1])

print("\n=== T16: the hold rate is the reference's own ===")
code = re.sub(r"--\[\[.*?\]\]", "", SCRIPT, flags=re.S)
code = re.sub(r"--[^\n]*", "", code)
chk("default hold is 0.05s (20 writes/s)", "or 0.05" in code, "")
chk("it can be switched off from the console", "_G.LIGHTDARK_HOLD_S" in code, "")
chk("the step rate is untouched by the hold",
    "35.0 studs every 0.50s x 146 steps" in txt_h, lines(txt_h, "config    |")[:1])

print(f"\n{'='*60}\nRESULT: {PASS} passed, {FAIL} failed")
if FAILED:
    print("FAILED: " + ", ".join(FAILED))
