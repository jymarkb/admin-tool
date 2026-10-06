"""Smoke + behaviour test for farmer/debug.lua (the V8 forensics scanner).

That file is Luau (`+=`), so it is normalised with tools/luau_syntax_check.py
before loading. Everything else is a black-box run: the real file is loaded
against a stubbed Roblox API, then driven by firing the engine signals it
subscribes to, and the assertions are made against the lines it actually emitted.

`print` is captured instead of reading the script's own buffer, because
addLogEntry() prints every entry - so the test sees exactly what the player sees
in the log panel.

    pip install --break-system-packages lupa
    python3 tests/debug_scanner_test.py

Stub notes (learned the hard way in tests/freefall_test.py):
  * Vector3.Magnitude / .Unit are PROPERTIES, not methods.
  * UI objects are a proxy over a backing table so __newindex fires on every
    write; any flag a closure reads must be declared BEFORE the instance
    metatable is built, or it resolves to a global and silently does nothing.
  * fields the script reads without a guard (AbsoluteContentSize) must exist, or
    `nil.Y` throws during load.
"""
import lupa, sys, os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools"))
from luau_syntax_check import normalise

STUB = r'''
local CREATED = {}
local PROXY_DATA = {}
local LOG = {}

-- capture every printed line: addLogEntry() prints each entry
local realprint = print
print = function(...)
  local n = select("#", ...)
  local t = {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  LOG[#LOG + 1] = table.concat(t, "\t")
end

local PUMP = nil          -- RunService.Heartbeat:Wait() advances the world
local PUMP_BUDGET = 0
local REVERT_TO = nil     -- when set, the "server" puts the character back

local function signal()
  local s = {_fns={}}
  s.Connect = function(self, fn)
    table.insert(self._fns, fn)
    return {Disconnect=function()
      for i, f in ipairs(s._fns) do if f == fn then table.remove(s._fns, i) break end end
    end}
  end
  s.Wait = function()
    -- In the real engine Wait() yields to the next Heartbeat, which is what lets
    -- the replay's blocking loop advance. A no-op here would spin forever.
    if not PUMP then return end
    PUMP_BUDGET = PUMP_BUDGET - 1
    if PUMP_BUDGET <= 0 then
      error("pump budget exhausted: the flight never finished", 2)
    end
    PUMP()
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
  for i, f in ipairs(s._fns) do snap[i] = f end
  local n = 0
  for _, fn in ipairs(snap) do n = n + 1; fn(...) end
  return n
end

-- ---- Vector3 -------------------------------------------------------------
local V = {}
local function vnew(x,y,z) return setmetatable({x=x or 0,y=y or 0,z=z or 0},V) end
local function vmag(v) return math.sqrt(v.x^2+v.y^2+v.z^2) end
local function vunit(v) local m=vmag(v); if m<1e-9 then return vnew(0,0,0) end
                          return vnew(v.x/m,v.y/m,v.z/m) end
V.__index=function(t,k)
  if k=="X" then return rawget(t,"x") end
  if k=="Y" then return rawget(t,"y") end
  if k=="Z" then return rawget(t,"z") end
  if k=="Magnitude" then return vmag(t) end
  if k=="Unit" then return vunit(t) end
  return V[k]
end
V.__add=function(a,b) return vnew(a.x+b.x,a.y+b.y,a.z+b.z) end
V.__sub=function(a,b) return vnew(a.x-b.x,a.y-b.y,a.z-b.z) end
V.__mul=function(a,b)
  if type(b)=="number" then return vnew(a.x*b,a.y*b,a.z*b) end
  if type(a)=="number" then return vnew(a*b.x,a*b.y,a*b.z) end
  return vnew(a.x*b.x,a.y*b.y,a.z*b.z)
end
V.__div=function(a,b) if type(b)=="number" then return vnew(a.x/b,a.y/b,a.z/b) end
  return vnew(a.x/b.x,a.y/b.y,a.z/b.z) end
V.__unm=function(a) return vnew(-a.x,-a.y,-a.z) end
V.Dot=function(a,b) return a.x*b.x+a.y*b.y+a.z*b.z end
V.Cross=function(a,b) return vnew(a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x) end
V.__tostring=function(a) return string.format("(%.3f, %.3f, %.3f)",a.x,a.y,a.z) end
Vector3 = {new=vnew, zero=vnew(0,0,0)}
Vector2 = {new=function(x,y) return {X=x or 0, Y=y or 0} end}
local function cross(a,b) return vnew(a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x) end

-- ---- CFrame --------------------------------------------------------------
local C = {}
CFrame = {}
function CFrame.new(x,y,z)
  if type(x)=="table" and y==nil then
    return setmetatable({p=x,r=vnew(1,0,0),u=vnew(0,1,0),b=vnew(0,0,1)},C)
  end
  if type(x)=="table" and type(y)=="table" then
    local look=vunit(y-x); local b=-look
    local r=vunit(cross(vnew(0,1,0),b)); local u=cross(b,r)
    return setmetatable({p=x,r=r,u=u,b=b},C)
  end
  return setmetatable({p=vnew(x,y,z),r=vnew(1,0,0),u=vnew(0,1,0),b=vnew(0,0,1)},C)
end
function CFrame.Angles(rx,ry,rz)
  local cy,sy = math.cos(ry or 0), math.sin(ry or 0)
  return setmetatable({p=vnew(0,0,0),r=vnew(cy,0,-sy),u=vnew(0,1,0),b=vnew(sy,0,cy)},C)
end
C.PointToObjectSpace=function(cf,p)
  local d = p - cf.p
  return vnew(d:Dot(cf.r), d:Dot(cf.u), d:Dot(cf.b)) end
function C.__sub(a) return setmetatable({p=vnew(0,0,0),r=a.r,u=a.u,b=a.b},C) end
function C.__add(a,b) return setmetatable({p=a.p+b,r=a.r,u=a.u,b=a.b},C) end
function C.__mul(a,b)
  local p=a.p+(a.r*b.p.x+a.u*b.p.y+a.b*b.p.z)
  return setmetatable({p=p,
    r=a.r*b.r.x+a.u*b.r.y+a.b*b.r.z,
    u=a.r*b.u.x+a.u*b.u.y+a.b*b.u.z,
    b=a.r*b.b.x+a.u*b.b.y+a.b*b.b.z},C)
end
C.__index=function(t,k)
  if k=="Position" then return rawget(t,"p") end
  if k=="LookVector" then return -1*rawget(t,"b") end
  return C[k]
end

Enum = {
  Font={Code="Code",Gotham="Gotham",GothamBold="GothamBold"},
  HumanoidStateType={Physics="Physics",Running="Running",Freefall="Freefall",
                     Landed="Landed",Jumping="Jumping",FallingDown="FallingDown",
                     Dead="Dead",GettingUp="GettingUp",Climbing="Climbing"},
  RaycastFilterType={Exclude="Exclude",Include="Include"},
  RenderPriority={Character={Value=300},Camera={Value=200}},
  SortOrder={LayoutOrder="LayoutOrder",Name="Name"},
  TextTruncate={AtEnd="AtEnd",None="None"},
  TextXAlignment={Left="Left",Center="Center",Right="Right"},
  TextYAlignment={Top="Top",Center="Center"},
  UserInputType={MouseButton1="mb1",Touch="touch",MouseMovement="mm"},
  ZIndexBehavior={Sibling="Sibling"},
  Material={Plastic="Plastic",Neon="Neon",SmoothPlastic="SmoothPlastic",Air="Air"},
  EasingStyle={Quad="Quad"}, EasingDirection={Out="Out"},
}
Color3 = {fromRGB=function(r,g,b) return {r=r,g=g,b=b} end}
Color3.new = Color3.fromRGB
UDim2 = {new=function(xs,xo,ys,yo) return {X={Scale=xs,Offset=xo},Y={Scale=ys,Offset=yo}} end}
UDim  = {new=function(s,o) return {Scale=s,Offset=o} end}
TweenInfo = {new=function() return {} end}
TweenService = {Create=function(self, obj, info, props)
  return {Play=function() end, Cancel=function() end} end, GetService=function() return end}
DateTime = {now=function() return {UnixTimestampMillis=1759800000000} end}
RaycastParams = {new=function() return {FilterDescendantsInstances={}} end}
OverlapParams = {new=function() return {FilterDescendantsInstances={}} end}
math.clamp = function(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local EVENTS = {MouseButton1Click=1,FocusLost=1,InputBegan=1,InputEnded=1,Changed=1,
                InputChanged=1,Heartbeat=1,PreSimulation=1,PostSimulation=1,PreRender=1,
                Died=1,CharacterAdded=1,StateChanged=1,Touched=1,MouseEnter=1,
                MouseLeave=1,HealthChanged=1,DescendantAdded=1,ChildAdded=1}

local function newInstance(class)
  local data = {ClassName=class, _sig={}, Size=vnew(4,2,4), Material="Plastic",
                CanCollide=true, Position=vnew(0,0,0), CFrame=CFrame.new(0,0,0),
                Text="", Visible=true, Value=0, Name=class,
                AbsoluteContentSize={X=0,Y=0}}
  local proxy = {}
  local mt = {
    __index=function(_, k)
      if k=="Destroy" then return function() data._destroyed=true end end
      if k=="GetPropertyChangedSignal" then return function(_, p) return sigOf(data,p) end end
      if k=="IsA" then return function(_, c)
            return data.ClassName==c or (c=="BasePart" and data.ClassName=="Part") end end
      if k=="WaitForChild" then return function(_, n) return data[n] end end
      if k=="FindFirstChild" then return function(_, n) return data[n] end end
      if k=="FindFirstChildOfClass" then return function(_, c)
            for _, v in pairs(data) do
              if type(v)=="table" and v.ClassName==c then return v end
            end end end
      if k=="GetChildren" then return function()
            local out = {}
            for _, v in pairs(data) do
              if type(v)=="table" and v.ClassName then table.insert(out, v) end
            end return out end end
      if k=="GetDescendants" then return function()
            local out = {}
            local function walk(t)
              for _, v in pairs(t) do
                if type(v)=="table" and v.ClassName then
                  table.insert(out, v); walk(v)
                end
              end
            end
            walk(data)
            if data._parts then
              for _, p in ipairs(data._parts) do table.insert(out, p) end
            end
            return out end end
      if k=="GetState" then return function() return data._state or "Running" end end
      if k=="ChangeState" then return function(_, st) data._state = st end end
      if k=="Move" then return function(_, d) data.MoveDirection = d end end
      if k=="MoveTo" then return function() end end
      if k=="PivotTo" then return function(_, cf)
            if data._parts then for _, p in ipairs(data._parts) do p.CFrame = cf end end
            data.CFrame = cf; return true end end
      if k=="GetFullName" then return function() return tostring(data.Name) end end
      if k=="GetConnectedParts" then return function() return {} end end
      if k=="GetNetworkOwner" then return function() return data._owner end end
      if k=="IsGrounded" then return function() return data._grounded or false end end
      if k=="SetNetworkOwner" then return function() end end
      if k=="Raycast" then return function(_, origin, dir, params)
            -- _ground = nil means nothing below (a void); a number is the distance
            local g = data._ground
            if g == nil then return nil end
            return {Distance = g, Instance = data._groundPart,
                    Position = origin + dir * 0.1, Material = "Plastic"}
          end end
      if k=="GetPartBoundsInRadius" then return function(_, pos, r, params)
            return data._overlap or {} end end
      if k=="Play" then return function() end end
      if k=="Stop" then return function() end end
      if k=="LoadAnimation" then return function()
            return {Play=function() end, Stop=function() end, IsPlaying=false} end end
      if EVENTS[k] then return sigOf(data,k) end
      return data[k]
    end,
    __newindex=function(_, k, v)
      local prev = data[k]
      data[k] = v
      -- a real Part's Position follows its CFrame; without this the replay's
      -- PivotTo would look like a failed write on every single frame
      if k == "CFrame" and type(v) == "table" and v.p then
        rawset(data, "Position", v.p)
      end
      local s = data._sig[k]
      if s then for _, fn in ipairs(s._fns) do fn(v, prev) end end
    end,
  }
  setmetatable(proxy, mt)
  PROXY_DATA[proxy] = data
  CREATED[class] = CREATED[class] or {}
  table.insert(CREATED[class], proxy)
  return proxy
end
Instance = {new=function(c) return newInstance(c) end}

-- ---- scene ---------------------------------------------------------------
local player = newInstance("Player"); player.Name = "Tester"; player.UserId = 1
player.GetNetworkPing = function() return 0.042 end
local playerGui = newInstance("PlayerGui"); player.PlayerGui = playerGui
local RUNSERVICE = newInstance("RunService")

local char = newInstance("Model"); char.Name = "Tester"
local root = newInstance("Part"); root.Name = "HumanoidRootPart"
local torso = newInstance("Part"); torso.Name = "Torso"
local head  = newInstance("Part"); head.Name = "Head"
local hum = newInstance("Humanoid")
hum.Health = 100; hum.MaxHealth = 100; hum.WalkSpeed = 16; hum.HipHeight = 2.0; hum.JumpPower = 50; hum.JumpHeight = 7.2
hum.PlatformStand = false
hum.AutoRotate = true; hum.FloorMaterial = "Plastic"; hum._state = "Running"

root.CFrame = CFrame.new(0, 100, 0); root.Position = vnew(0,100,0)
root.AssemblyLinearVelocity = vnew(0,0,0)
root.AssemblyAngularVelocity = vnew(0,0,0)
root.ReceiveAge = 0.01
root.AssemblyMass = 12.0
root.Orientation = vnew(0,0,0)
torso.CFrame = CFrame.new(0, 99, 0); torso.Position = vnew(0,99,0)
head.CFrame  = CFrame.new(0, 103, 0); head.Position = vnew(0,103,0)

char.Humanoid = hum
char.HumanoidRootPart = root
char.Torso = torso          -- FindFirstChild("Torso") must find it, or the
char.Head = head            -- rig-stretch check silently returns every tick
char._parts = {root, torso, head}
char.Parent = true; hum.Parent = true; root.Parent = true
torso.Parent = true; head.Parent = true
player.Character = char

local WORKSPACE = newInstance("Workspace")
-- network ownership: the script distinguishes nil (server-owned) from LocalPlayer
function WORKSPACE.GetRealPhysicsFPS() return 60.0 end
function WORKSPACE.GetPhysicsThrottling() return 100 end
function WORKSPACE.GetNumAwakeParts() return 3 end
function WORKSPACE.SetNetworkOwner(self, who) self._networkOwner = who end
WORKSPACE.CurrentCamera = newInstance("Camera")
WORKSPACE.FallenPartsDestroyHeight = -500
WORKSPACE.Gravity = 196.2
WORKSPACE._overlap = {}

game = {GetService=function(_, name)
  if name=="Players" then return {LocalPlayer=player} end
  if name=="RunService" then return RUNSERVICE end
  if name=="TweenService" then return TweenService end
  if name=="Workspace" then return WORKSPACE end
  return newInstance(name) end}
workspace = WORKSPACE
setclipboard = function(t) end
task = {wait=function() end, spawn=function(f, ...) if f then f(...) end end,
        delay=function(_, f) if f then f() end end, defer=function(f) if f then f() end end}

local FAKE_T = 1000.0
os = {clock=function() return FAKE_T end, date=function() return "00:00:00" end,
      time=function() return FAKE_T end}

local RENDER = {}
RUNSERVICE.BindToRenderStep = function(_, name, prio, fn) RENDER[name] = fn end
RUNSERVICE.UnbindFromRenderStep = function(_, name) RENDER[name] = nil end

local H = {}
H.root, H.hum, H.char, H.torso, H.head = root, hum, char, torso, head
H.workspace, H.runsrv, H.player = WORKSPACE, RUNSERVICE, player
H.getCreated = function(c) return CREATED[c] or {} end
H.fire = fire
H.emit = function(proxy, ev, ...) return fire(PROXY_DATA[proxy], ev, ...) end
H.data = function(proxy) return PROXY_DATA[proxy] end
H.vnew = vnew
H.advance = function(dt) FAKE_T = FAKE_T + (dt or 1/60) end
-- heartbeat drives the transform sampler AND the forensics tick
H.tick = function(dt)
  FAKE_T = FAKE_T + (dt or 1/60)
  fire(RUNSERVICE, "Heartbeat", dt or 1/60)
end
H.stage = function(name, dt)
  FAKE_T = FAKE_T + (dt or 1/60)
  fire(RUNSERVICE, name or "PreSimulation", dt or 1/60)
end
H.stepN = function(n, dt)
  for _=1,n do
    FAKE_T = FAKE_T + (dt or 1/60)
    fire(RUNSERVICE, "Heartbeat", dt or 1/60)
  end
end
-- move the whole rig, the way a teleport would
H.place = function(x, y, z)
  local p = vnew(x, y, z)
  root.Position = p
  root.CFrame = CFrame.new(p)
  if char._parts then
    for _, part in ipairs(char._parts) do part.Position = p end
  end
  return p
end
H.renderOnce = function(dt)
  dt = dt or 1/60
  FAKE_T = FAKE_T + dt
  local snap = {}
  for name, fn in pairs(RENDER) do snap[#snap + 1] = fn end
  for _, fn in ipairs(snap) do fn(dt) end
end
H.renderCount = function()
  local n = 0
  for _ in pairs(RENDER) do n = n + 1 end
  return n
end
-- Wait() -> render step -> revert (if any) -> Heartbeat, i.e. one frame
H.installPump = function(budget)
  PUMP_BUDGET = budget or 20000  -- a stalled flight fails the test, never hangs it
  PUMP = function()
    H.renderOnce(1/60)
    if REVERT_TO then
      local p = vnew(REVERT_TO.x, REVERT_TO.y, REVERT_TO.z)
      local d = PROXY_DATA[root]
      rawset(d, "Position", p)
      rawset(d, "CFrame", CFrame.new(p))
    end
    fire(RUNSERVICE, "Heartbeat", 1/60)
  end
end
H.setRevert = function(x, y, z)
  if x == nil then REVERT_TO = nil else REVERT_TO = {x=x, y=y, z=z} end
end
H.setState = function(st) rawset(PROXY_DATA[hum], "_state", st) end
H.setOwner = function(part, who) PROXY_DATA[part]._owner = who end
H.setGrounded = function(part, v) PROXY_DATA[part]._grounded = v end
H.setGround = function(distance, part)
  local d = PROXY_DATA[WORKSPACE]
  d._ground = distance
  d._groundPart = part
end
H.setVel = function(x,y,z)
  root.AssemblyLinearVelocity = vnew(x,y,z)
end
H.table = function(...) return {...} end
H.log = function() return table.concat(LOG, "\n") end
H.mark = function() return #LOG end
H.since = function(m)
  local out = {}
  for i = (m or 0) + 1, #LOG do out[#out + 1] = LOG[i] end
  return table.concat(out, "\n")
end
H.clearLog = function() LOG = {} end
H.logCount = function() return #LOG end
return H
'''

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
script = normalise(open(os.path.join(ROOT, "farmer", "debug.lua")).read())


def boot(source):
    """Load the stub + a script into a fresh runtime. Returns (rt, H, new_globals).

    new_globals is the set of globals the SCRIPT created, relative to the stub -
    a local declared after its first use silently becomes one of these, which has
    bitten this project five times.
    """
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    handle = rt.execute(STUB)
    before = set(rt.globals().keys())
    rt.execute(source)
    return rt, handle, set(rt.globals().keys()) - before


def pristine_source():
    """farmer/debug.lua as it is on main, for baseline comparison."""
    import subprocess
    try:
        out = subprocess.run(["git", "show", "origin/main:farmer/debug.lua"],
                             cwd=ROOT, capture_output=True, text=True, timeout=30)
        if out.returncode == 0 and out.stdout.strip():
            return normalise(out.stdout)
    except Exception:
        pass
    return None

PASS = FAIL = 0
FAILED = []
def chk(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  PASS  {name:<52}{detail}")
    else:
        FAIL += 1
        FAILED.append(name)
        print(f"  FAIL  {name:<52}{detail}")

def lastline(txt, needle):
    hits = [l for l in txt.splitlines() if needle in l]
    return hits[-1] if hits else f"(no line with {needle!r})"

# baseline: the same stub against the unmodified scanner on main, so global
# leaks inherited from it are not blamed on this patch
BASELINE_GLOBALS = set()
_pristine = pristine_source()
if _pristine:
    try:
        _rt, _h, BASELINE_GLOBALS = boot(_pristine)
        print(f"baseline (origin/main) leaks {len(BASELINE_GLOBALS)} global(s): "
              f"{sorted(BASELINE_GLOBALS) or 'none'}")
    except Exception as e:
        print("baseline could not be loaded, skipping the comparison:", e)

try:
    L, H, NEW_GLOBALS = boot(script)
except Exception as e:
    print("LOAD ERROR:", e)
    try:
        print(L.eval('debug.traceback and debug.traceback() or ""'))
    except Exception:
        pass
    sys.exit(1)

print("farmer/debug.lua loaded against stubbed Roblox API")

root, hum, torso = H["root"], H["hum"], H["torso"]
fire = H["fire"]
def make_part(name, x=0, y=0, z=0, size=10, collide=True, cls="Part"):
    """Build a stub part and place it. Returns the proxy."""
    part = L.eval(f'Instance.new("{cls}")')
    part["Name"] = name
    part["Size"] = H["vnew"](size, size, size)
    part["CanCollide"] = collide
    part["CFrame"] = L.eval(f'CFrame.new({x}, {y}, {z})')
    part["Position"] = H["vnew"](x, y, z)
    return part

def set_nearby(parts):
    """The stub's GetPartBoundsInRadius returns whatever the Workspace holds."""
    wd = H["data"](H["workspace"])
    wd["_overlap"] = H["table"](*parts)

def goto_start(x, y, z, dt=0.033):
    """Stand at (x, y, z) with an empty burst ledger and a primed sampler.

    The teleport to the start line is logged (the sampler has to see it) and then
    wiped by the CLEAR button. Returns a mark: assert with since(mark), because
    the printed log keeps everything from earlier tests.
    """
    H["place"](x, y, z)
    H["tick"](dt)                                     # logged ...
    m = H["mark"]()
    fire(buttons("Clear")[0], "MouseButton1Click")    # ... then wiped
    assert "BURST" not in H["since"](m), "CLEAR left a burst behind"
    return H["mark"]()


def buttons(sub):
    return [b for b in list(H["getCreated"]("TextButton").values())
            if sub in str(b["Text"])]

print("\n=== T0: the script leaks no globals of its own ===")
leaked = NEW_GLOBALS - BASELINE_GLOBALS
chk("no new globals created by the script", not leaked,
    f"leaked: {sorted(leaked)}" if leaked else
    f"({len(BASELINE_GLOBALS)} inherited from main)")

print("\n=== T1: the scanner starts and reports its baseline ===")
txt = H["log"]()
chk("SCANNER READY V13 is announced", "SCANNER READY V13" in txt, lastline(txt, "SCANNER READY"))
chk("reports capture + forensics state", "capture=" in txt and "forensics=" in txt,
    lastline(txt, "forensics="))
chk("reports the baseline hp/maxHealth", "baseline | hp=100.0/100.0" in txt,
    lastline(txt, "baseline |"))
chk("announces the watch thresholds",
    "bigJump=" in txt and "revert=" in txt and "rigStretch=" in txt,
    lastline(txt, "watches |"))
chk("Touched watchers subscribed", "TOUCH WATCH" in txt, lastline(txt, "TOUCH WATCH"))

print("\n=== T2: THE GAP - a big jump that the server UNDOES (REVERTED) ===")
set_nearby([make_part("COLL GUARD.BOTTOMS", 0, 99, 0, 30)])
H["clearLog"]()
H["place"](0, 100, 0)
H["tick"]()
H["place"](300, 100, 0)          # a 300-stud leap: this is the flight
H["tick"]()
txt = H["log"]()
chk("the jump is logged as a move", "TRANSFORM_JUMP" in txt,
    lastline(txt, "TRANSFORM_JUMP"))
H["place"](0, 100, 0)            # the server puts us back
H["tick"]()
txt = H["log"]()
chk("REVERTED is detected", "REVERTED" in txt, lastline(txt, "REVERTED"))
chk("says the write did not stick", "did NOT stick" in txt,
    lastline(txt, "did NOT stick"))
chk("shows where we were put", "wrote to (" in txt, lastline(txt, "wrote to ("))

print("\n=== T3: a big jump that HOLDS is reported as KEPT ===")
H["clearLog"]()
H["place"](0, 100, 0)
H["tick"]()
H["place"](300, 100, 0)
H["tick"]()
H["advance"](2.5)                 # past REVERT_WINDOW_S
H["tick"]()
txt = H["log"]()
chk("KEPT is reported", "KEPT |" in txt, lastline(txt, "KEPT |"))
chk("KEPT says how long it held", "held for" in txt, lastline(txt, "held for"))

print("\n=== T4: the -1000 exploit kill is named, not mistaken for damage ===")
set_nearby([make_part("Lake.Bounds", 500, 99, 0, 40)])
H["clearLog"]()
H["place"](500, 100, 0)
hum["Health"] = -1000
H["emit"](hum, "HealthChanged", -1000)
txt = H["log"]()
chk("EXTERNAL KILL is named", "EXTERNAL KILL" in txt, lastline(txt, "HEALTH |"))
chk("says health was SET", "health was SET" in txt, "")
chk("shows hp / maxHealth", "hp=-1000.0/100.0" in txt, lastline(txt, "hp=-1000"))
chk("logs what was nearby at the kill", "NEAR AT KILL" in txt,
    lastline(txt, "NEAR AT KILL"))
hum["Health"] = 100
H["emit"](hum, "HealthChanged", 100)

print("\n=== T5: an ordinary death is NOT called external ===")
H["clearLog"]()
H["emit"](hum, "HealthChanged", 0)
txt = H["log"]()
chk("not flagged as external", "EXTERNAL KILL" not in txt, lastline(txt, "HEALTH |"))
chk("called a normal change", "normal change" in txt, lastline(txt, "normal change"))
hum["Health"] = 100

print("\n=== T6: Died produces the full DEATH block ===")
H["clearLog"]()
H["emit"](hum, "Died")
txt = H["log"]()
chk("DEATH header", "DEATH" in txt, "")
for field in ["reason", "health", "state", "phase", "velocity", "NEAR"]:
    chk(f"death block reports {field}", f"| {field}" in txt or f"  {field}" in txt, "")

print("\n=== T7: Touched is recorded and guard-named parts are flagged ===")
H["clearLog"]()
guest = H["getCreated"]("Model")[0] if H["getCreated"]("Model") else None
sb = L.eval('''(function()
  local p = Instance.new("Part")
  p.Name = "COLL GUARD.WALL LEFT (COLL GUARD).Part"
  return p end)()''')
H["emit"](torso, "Touched", sb)
txt = H["log"]()
chk("TOUCHED is logged", "TOUCHED |" in txt, lastline(txt, "TOUCHED |"))
chk("names the part", "COLL GUARD" in txt, "")
chk("flags the guard naming", "GUARD-NAMED" in txt, lastline(txt, "GUARD-NAMED"))

# the floor under your feet fires Touched constantly: report it once, then stay quiet
H["clearLog"]()
floor = make_part("NormalFloor")
H["emit"](torso, "Touched", floor)
H["advance"](1.0)
H["emit"](torso, "Touched", floor)
H["emit"](torso, "Touched", floor)
txt = H["log"]()
chk("an ordinary part is reported once", txt.count("TOUCHED") == 1,
    f"{txt.count('TOUCHED')} TOUCHED line(s)")

# a guard volume keeps reporting, rate-limited
H["clearLog"]()
H["emit"](torso, "Touched", sb)
H["advance"](0.1)                      # inside the dedupe window
H["emit"](torso, "Touched", sb)
chk("a guard part is de-duplicated", H["log"]().count("TOUCHED") == 1,
    f"{H['log']().count('TOUCHED')} TOUCHED line(s)")
H["advance"](1.0)                      # past TOUCH_DEDUPE_S
H["emit"](torso, "Touched", sb)
chk("a guard part reports again later", H["log"]().count("TOUCHED") == 2,
    f"{H['log']().count('TOUCHED')} TOUCHED line(s)")

# a non-collidable trigger is always interesting
H["clearLog"]()
trigger = make_part("KillBrick", collide=False)
H["emit"](torso, "Touched", trigger)
H["advance"](1.0)
H["emit"](torso, "Touched", trigger)
chk("a non-collidable trigger keeps reporting",
    H["log"]().count("TOUCHED") == 2, f"{H['log']().count('TOUCHED')} TOUCHED line(s)")

print("\n=== T8: the src/dt bug - each channel now has its own previous sample ===")
H["clearLog"]()
H["place"](0, 100, 0)
H["stage"]("PreSimulation", 1/60)          # primes that channel's previous sample
for i in range(1, 5):
    H["place"](i * 300, 100, 0)            # a 300-stud jump on this channel
    H["stage"]("PreSimulation", 1/60)
txt = H["log"]()
chk("src=PreSimulation now appears", "src=PreSimulation" in txt,
    lastline(txt, "src="))
# a shared previous sample made dt a gap between DIFFERENT channels (dt=40.5 seen
# in a real log). With per-channel samples dt must be a frame delta.
dt_large = False
for line in txt.splitlines():
    if "src=PreSimulation" in line and "dt=" in line:
        d = float(line.split("dt=")[1].split(" ")[0])
        if d > 1.0:
            dt_large = True
chk("dt on PreSimulation is a frame delta, not a channel gap", not dt_large,
    "no dt > 1.0" if not dt_large else "found a dt > 1.0")

print("\n=== T9: zero velocity is flagged rather than faked by the clamp ===")
H["clearLog"]()
H["setVel"](0, 0, 0)
H["place"](0, 100, 0); H["tick"]()
H["place"](200, 100, 0); H["tick"]()
txt = H["log"]()
chk("zeroVel flag present", "zeroVel=1" in txt, lastline(txt, "zeroVel"))
chk("explains the clamp", "clamp, not a real ratio" in txt, "")

print("\n=== T10: NET displacement is reported while moving fast ===")
H["clearLog"]()
H["setVel"](500, 0, 0)
for i in range(1, 8):
    H["place"](200 + i * 20, 100, 0)
    H["advance"](0.2)
    H["tick"](0.2) if False else H["tick"](0.2)
txt = H["log"]()
chk("NET line emitted", "NET |" in txt, lastline(txt, "NET |"))
chk("NET reports net studs", "net=" in txt, lastline(txt, "net="))
H["setVel"](0, 0, 0)

print("\n=== T11: rig stretch is reported when limbs lag the root ===")
# NOTE: clearLog resets the rig baseline by design, so the baseline has to be
# established AFTER the clear, not before it.
H["clearLog"]()
H["setVel"](0, 0, 0)
H["place"](0, 100, 0)
torso["Position"] = H["vnew"](0, 100, 0)     # resting rig: baseline, 0 offset
H["tick"](0.5)
chk("a healthy rig is silent",
    "RIG STRETCH" not in H["log"](), "")
torso["Position"] = H["vnew"](0, 90, 0)      # 10 studs off the root
for i in range(6):
    H["tick"](0.1)
txt = H["log"]()
chk("RIG STRETCH reported", "RIG STRETCH" in txt, lastline(txt, "RIG STRETCH"))
chk("reports how far it stretched", "torso" in txt and "limit" in txt,
    lastline(txt, "torso"))
torso["Position"] = H["vnew"](0, 99, 0)
H["clearLog"]()

print("\n=== T12: coming to rest triggers a containment check ===")
H["clearLog"]()
H["setVel"](300, 0, 0)
H["place"](800, 100, 0); H["tick"]()
H["setVel"](0, 0, 0)
set_nearby([])                               # nothing solid here
for i in range(4):
    H["advance"](0.1); H["tick"](0.1)
txt = H["log"]()
chk("AT REST reported when clear",
    "AT REST" in txt and "INSIDE SOLID" not in txt, lastline(txt, "AT REST"))

# an identical stop, but now inside a wall
H["clearLog"]()
H["setVel"](300, 0, 0)
H["place"](1200, 100, 0); H["tick"]()
set_nearby([make_part("COLL GUARD.WALL LEFT", 1200, 100, 0, 40)])
H["setVel"](0, 0, 0)
for i in range(4):
    H["advance"](0.1); H["tick"](0.1)
txt = H["log"]()
chk("INSIDE SOLID reported when embedded", "INSIDE SOLID" in txt,
    lastline(txt, "INSIDE SOLID"))
chk("names the block we are inside", "COLL GUARD.WALL LEFT" in txt, "")
set_nearby([])

print("\n=== T13: the DUMP button produces a usable bundle (ownership + snapshot) ===")
set_nearby([make_part("GuardAreas.Prehistoric", 800, 100, 0, 25)])
H["clearLog"]()
snap = buttons("DUMP")[0]
fire(snap, "MouseButton1Click")
txt = H["log"]()
chk("SNAPSHOT header", "SNAPSHOT" in txt, lastline(txt, "SNAPSHOT"))
chk("the ownership bundle comes with it", "---- OWNERSHIP" in txt,
    lastline(txt, "---- OWNERSHIP"))
chk("reports state/hp", "state=" in txt and "hp=" in txt, lastline(txt, "state="))
chk("reports velocity", "vel=(" in txt, lastline(txt, "vel=("))
chk("lists what is nearby", "SNAP NEAR" in txt, lastline(txt, "SNAP NEAR"))
chk("reports the ground below", "ground below" in txt, lastline(txt, "ground below"))
chk("reports what is straight ahead", "ahead |" in txt, lastline(txt, "ahead |"))

print("\n=== T17: void proximity is measured with a ray, not guessed ===")
H["clearLog"]()
H["setVel"](0, 0, 0)
H["place"](0, 500, 0)
H["setGround"](None)                       # nothing below us
H["advance"](2.0); H["tick"](0.1)
txt = H["log"]()
chk("nothing below is reported", "VOID WARNING" in txt, lastline(txt, "VOID WARNING"))
chk("says how far it looked", "no ground within" in txt, "")

H["clearLog"]()
H["setGround"](10)                         # ground 13 studs below: fine
H["advance"](2.0)
for i in range(3):
    H["tick"](0.1)
chk("close ground is silent", "VOID WARNING" not in H["log"](), "")

H["clearLog"]()
H["setGround"](90, make_part("GuardAreas.Prehistoric", 0, 400, 0, 20))
H["advance"](2.0); H["tick"](0.1)
txt = H["log"]()
chk("a 93-stud drop is reported", "VOID WARNING" in txt, lastline(txt, "VOID WARNING"))
chk("reports the real gap", "93.0 studs below" in txt, "")
chk("names the surface below", "GuardAreas.Prehistoric" in txt, "")
H["setGround"](10)

H["clearLog"]()
H["setGround"](12, make_part("COLL GUARD.WALL RIGHT", 0, 100, -12, 20))
fire(snap, "MouseButton1Click")
txt = H["log"]()
chk("names the obstacle ahead", "COLL GUARD.WALL RIGHT" in txt,
    lastline(txt, "ahead |"))
chk("flags it as guard-named", "GUARD-NAMED" in txt, "")

print("\n=== T14: DIAG: LEDGER drops the watches, FULL brings them back ===")
H["clearLog"]()
fb = buttons("DIAG:")[0]
fire(fb, "MouseButton1Click")
txt = H["log"]()
chk("the dial reports LEDGER", "DIAG | LEDGER" in txt, lastline(txt, "DIAG |"))
chk("it says exactly what went off",
    "capture=true | forensics=false | flightTrace=false" in txt,
    lastline(txt, "capture="))
chk("button label changes", "DIAG: LEDGER" in str(fb["Text"]), repr(str(fb["Text"])[:44]))
H["clearLog"]()
H["place"](0, 100, 0); H["tick"]()
H["place"](400, 100, 0); H["tick"]()
H["place"](0, 100, 0); H["tick"]()
txt = H["log"]()
chk("no REVERTED while the watches are off", "REVERTED" not in txt, "")
fire(fb, "MouseButton1Click")
chk("the dial reports FULL again", "DIAG | FULL" in H["log"](),
    lastline(H["log"](), "DIAG |"))

print("\n=== T15: CLEAR also resets the forensics state ===")
H["clearLog"]()
H["place"](0, 100, 0); H["tick"]()
H["place"](400, 100, 0); H["tick"]()     # arms pendingJump
clr = buttons("Clear")[0]
fire(clr, "MouseButton1Click")
H["clearLog"]()
H["place"](0, 100, 0); H["tick"]()       # must NOT be reported as REVERTED
txt = H["log"]()
chk("no stale REVERTED after CLEAR", "REVERTED" not in txt, "")

print("\n=== T16: StateChanged reports the humanoid state with context ===")
H["clearLog"]()
H["emit"](hum, "StateChanged", "Running", "Freefall")
txt = H["log"]()
chk("STATE logged", "STATE |" in txt, lastline(txt, "STATE |"))
chk("shows old -> new", "-> Freefall" in txt, "")
chk("includes nc and floor", "nc=" in txt and "floor=" in txt, "")

print("\n=== T18: a flight that WORKS is traced write by write ===")
H["clearLog"]()
H["setOwner"](root, H["player"])            # client-owned: writes are authoritative
H["setOwner"](torso, H["player"])
H["setOwner"](H["head"], H["player"])
H["setGrounded"](root, False)
H["setVel"](0, 0, 0)
H["place"](0, 200, 0)
H["setGround"](400)
H["installPump"](20000)
replay = buttons("REPLAY")[0]
fire(replay, "MouseButton1Click")
txt = H["log"]()
chk("the flight trace starts", "FLIGHT TRACE START" in txt, "")
chk("the reference profile is written out",
    "REPLAY PARAMS" in txt and "dx =" in txt and "dt =" in txt, lastline(txt, "REPLAY PARAMS"))
chk("expected distance is computed", "expected total=" in txt, lastline(txt, "expected total"))
chk("ownership is recorded before the flight", "owner | root=" in txt,
    lastline(txt, "owner | root="))
chk("physics state is recorded", "physics | realFPS=" in txt, lastline(txt, "physics |"))
chk("every frame shows asked vs actual", "asked=(" in txt, lastline(txt, "FRAME 0"))
chk("the render step is unbound at the end", H["renderCount"]() == 0,
    f"{H['renderCount']()} render step(s) still bound")
chk("the trace ends with a verdict", "FLIGHT TRACE END" in txt, lastline(txt, "verdict"))
chk("ALL WRITES HELD for a clean flight", "ALL WRITES HELD" in txt,
    lastline(txt, "verdict"))
chk("achieved distance is reported", "achieved  |" in txt, lastline(txt, "achieved  |"))
frames = [l for l in txt.splitlines() if "FRAME " in l]
chk("the per-frame trace is capped", len(frames) <= 60, f"{len(frames)} FRAME lines")
chk("the trace summarises writes and actions",
    "writes (%.0f/s)" in txt or "writes (" in txt, lastline(txt, "duration  |"))

print("\n=== T19: the -1000 trigger calls are OFF by default, and visible ===")
chk("the flight starts with stateCalls OFF",
    "stateCalls=OFF" in txt, lastline(txt, "REPLAY START"))
chk("skipping them is stated plainly", "STATE CALLS | SKIPPED" in txt,
    lastline(txt, "STATE CALLS |"))
chk("ChangeState is NOT called by default",
    "ACTION | ChangeState" not in txt, "")
chk("AutoRotate is NOT touched by default",
    "ACTION | AutoRotate" not in txt and "AUTOROTATE" not in txt, "")

# the A/B control: MODE -> CONTROL applies state calls ON with everything else
# that belongs with them, which is how the failing launch is reproduced on demand
H["clearLog"]()
sb2 = buttons("MODE:")[0]
fire(sb2, "MouseButton1Click")
chk("the dial reports CONTROL", "MODE | CONTROL" in H["log"](),
    lastline(H["log"](), "MODE |"))
chk("it says what it applied", "stateCalls=true" in H["log"](),
    lastline(H["log"](), "stateCalls="))
chk("the button label changes",
    "CONTROL" in str(sb2["Text"]), repr(str(sb2["Text"])[:44]))
H["clearLog"]()
H["place"](0, 200, 0)
H["tick"](0.033)
m = H["mark"]()
fire(replay, "MouseButton1Click")
txt = H["since"](m)
chk("ChangeState is recorded as an action",
    "ACTION | ChangeState(Freefall)" in txt, lastline(txt, "ChangeState"))
chk("AutoRotate is recorded as an action",
    "ACTION | AutoRotate=false" in txt, lastline(txt, "AutoRotate=false"))
chk("actions carry a flight-relative timestamp", "t+0." in txt, "")
chk("the -1000 triggers are labelled as such", "the -1000 trigger" in txt,
    lastline(txt, "the -1000 trigger"))
chk("the flight reports stateCalls=ON", "stateCalls=ON" in txt,
    lastline(txt, "REPLAY START"))
# ordering matters: a flight that died 0.03s in must show the action BEFORE the death
lines = txt.splitlines()
act = [i for i, l in enumerate(lines) if "ACTION | ChangeState" in l]
dead = [i for i, l in enumerate(lines) if "DEATH" in l or "ABORTED" in l]
chk("the action is logged before any abort/death",
    not dead or not act or act[0] < dead[0],
    f"action@{act[0] if act else '-'} death@{dead[0] if dead else '-'}")
chk("AutoRotate is reported back on the humanoid", "AUTOROTATE |" in txt, "")
fire(sb2, "MouseButton1Click")          # back to TEST
chk("the dial reports TEST again", "MODE | TEST" in H["log"](),
    lastline(H["log"](), "MODE |"))
chk("and everything it owns goes back with it",
    "stateCalls=false" in H["log"](), lastline(H["log"](), "stateCalls="))

print("\n=== T20: a flight the server UNDOES is reported as such ===")
H["clearLog"]()
H["place"](0, 200, 0)
H["setVel"](0, 0, 0)
H["setGround"](400)
H["setRevert"](0, 200, 0)                   # the server holds us in place
H["installPump"](20000)
fire(replay, "MouseButton1Click")
txt = H["log"]()
chk("the rejected write is named", "WRITE REJECTED" in txt, lastline(txt, "WRITE REJECTED"))
chk("shows where the character actually is", "character at (" in txt, "")
chk("shows the offset", "off by" in txt, lastline(txt, "off by"))
chk("records the owner at that moment", "owner=" in txt, lastline(txt, "owner="))
chk("the flight still ends with a verdict", "verdict" in txt, lastline(txt, "verdict"))
chk("the character not moving is called out",
    "DID NOT MOVE" in txt or "FOUGHT BACK" in txt or "pushback" in txt,
    lastline(txt, "verdict"))
chk("the trace ends even when the flight is fought", "FLIGHT TRACE END" in txt, "")

# The flight's own correction detector cannot fire, and this is why it never
# showed up in the field logs: it re-applies the sticky target at the top of every
# frame and THEN measures the error, so the error it measures is its own write.
# The server reverts between frames, where the flight is not looking.
chk("the flight's own CORRECTION FIGHT stays silent",
    "CORRECTION FIGHT" not in txt, "(it measures its own write)")
chk("the ledger catches what the flight cannot", "WRITE REJECTED" in txt,
    lastline(txt, "WRITE REJECTED"))
rejects = [l for l in txt.splitlines() if "WRITE REJECTED" in l]
chk("rejections are rate limited, not one per frame", len(rejects) <= 12,
    f"{len(rejects)} rejection line(s)")
H["setRevert"](None)

print("\n=== T21: the ledger-only dial silences the per-write trace ===")
H["clearLog"]()
tb = buttons("DIAG:")[0]
fire(tb, "MouseButton1Click")
chk("the trace went off with the dial", "flightTrace=false" in H["log"](),
    lastline(H["log"](), "capture="))
H["clearLog"]()
H["place"](0, 200, 0)
H["installPump"](20000)
fire(replay, "MouseButton1Click")
chk("no trace lines while the trace is off", "FLIGHT TRACE START" not in H["log"](), "")
fire(tb, "MouseButton1Click")
chk("the dial reports FULL again", "DIAG | FULL" in H["log"](),
    lastline(H["log"](), "DIAG |"))

print("\n=== T22: DUMP answers \"who owns me right now?\" ===")
H["clearLog"]()
ob = buttons("DUMP")[0]
fire(ob, "MouseButton1Click")
txt = H["log"]()
chk("ownership bundle printed", "---- OWNERSHIP" in txt, "")
chk("reports the root owner", "root      |" in txt, lastline(txt, "root      |"))
chk("reports receiveAge", "receiveAge=" in txt, "")
chk("reports physics", "realFPS=" in txt, "")

print("\n=== T23: a change of ownership is announced ===")
H["clearLog"]()
H["setOwner"](root, None)                   # nil = the server owns it
H["advance"](1.0); H["tick"](0.1)
H["advance"](1.0); H["tick"](0.1)
txt = H["log"]()
chk("ownership change is logged", "OWNERSHIP |" in txt, lastline(txt, "OWNERSHIP |"))
chk("explains what server-owned means", "SERVER-OWNED" in txt, lastline(txt, "SERVER-OWNED"))
H["setOwner"](root, H["player"])

print("\n=== T24: a whole escape flight collapses into one block ===")
H["setVel"](0, 0, 0)
m = goto_start(5666.3, 70.7, -331.9)       # the real log's start, on the ground
# 40 steps at ~4200 studs/s, every 4th one SHORT - the shape of the 04:16 flight
x, y = 5666.3, 70.7
for i in range(1, 41):
    short = (i % 4 == 0)
    x -= 50.0 if short else 200.0
    y = min(112.7, y + (13.7 if i == 1 else (22.1 if i == 2 else (6.2 if i == 3 else 0.0))))
    H["place"](x, y, -331.9)
    H["tick"](0.0476)
H["setVel"](0, -196.2 * 0.0476, 0)
H["place"](x, 70.7, -331.9)               # the final drop
H["tick"](0.0476)
H["advance"](0.6); H["tick"](0.1)          # stop: the tick closes the burst
txt = H["since"](m)
chk("the burst opens", "BURST START" in txt, "")
chk("the burst closes itself when it stops", "BURST END" in txt,
    lastline(txt, "BURST END"))
chk("net distance is reported", "moved     |" in txt, lastline(txt, "moved     |"))
chk("the start position is reconstructed",
    "5666.3, 70.7, -331.9" in txt, lastline(txt, "from      |"))
chk("the Y profile is reported",
    "peak" in lastline(txt, "Y         |") and "final drop" in txt,
    lastline(txt, "Y         |"))
chk("the Y peak is the cruise height", "112.7" in lastline(txt, "Y         |"),
    lastline(txt, "Y         |"))
chk("the wave up before the flight is reported", "+13.7" in txt, "")
chk("step count is reported", "41 distinct" in txt, lastline(txt, "steps     |"))
chk("frame timing is reported", "avg frame" in txt, lastline(txt, "timing    |"))
chk("cruise speed is reported", "cruise" in txt, lastline(txt, "speed     |"))
chk("the state is reported", "states    |" in txt, lastline(txt, "states    |"))
chk("the source census is reported", "sources   |" in txt, lastline(txt, "sources   |"))
chk("the size histogram is reported",
    "sizes     |" in txt and "median" in txt, lastline(txt, "sizes     |"))
chk("the step rate is reported", "steps/s" in txt, lastline(txt, "rate      |"))

print("\n=== T25: the replication payload - every step as (t, dx, dy) ===")
# the header line also contains "t/dx/dy", so only take the payload lines
steps = [l for l in txt.splitlines()
         if "BURST STEPS | " in l and "(t/dx/dy)" not in l]
triples = [t for l in steps for t in l.split("| ", 1)[1].split(", ") if "/" in t]
chk("the step list is emitted", len(steps) > 0, f"{len(steps)} line(s)")
chk("every distinct step is listed", len(triples) == 41, f"{len(triples)} step(s)")
chk("steps are chunked, not one giant line", len(steps) >= 6, f"{len(steps)} line(s)")
chk("deltas are signed and precise", any("+13.7" in t for t in triples),
    next((t for t in triples if "13.7" in t), ""))
chk("each step carries t, dx and dy", triples[0].count("/") == 2, triples[0])
chk("the first step starts at t=0", triples[0].startswith("0.000"), triples[0])

print("\n=== T26: the flight was FIGHTING - short steps are counted ===")
chk("short steps are counted", "step(s) under" in txt, lastline(txt, "speed     |"))
chk("the verdict is PARTIAL, not a clean HELD",
    "verdict   | PARTIAL" in txt or "PARTIAL -" in lastline(txt, "verdict   |"),
    lastline(txt, "verdict   |"))
chk("it says the writes were pushed back", "pushed back" in txt, "")

print("\n=== T27: echoes across stage channels are not counted as steps ===")
H["setVel"](0, 0, 0)
m = goto_start(0, 100, 0)
for i in range(6):
    H["place"](300, 100, 0)               # ONE write, reported 6 times
    H["advance"](0.03); H["tick"](0.03)
H["advance"](0.6); H["tick"](0.1)
txt = H["since"](m)
chk("one distinct step", "1 distinct" in txt, lastline(txt, "steps     |"))
chk("the repeats are called echoes", "channel echoes" in txt,
    lastline(txt, "steps     |"))

print("\n=== T28: a reversion inside a burst is caught (the 02:57 signature) ===")
H["setVel"](0, 0, 0)
m = goto_start(5000, 70.7, -325.0)
for i in range(1, 6):                      # fly west
    H["place"](5000 - i * 200, 70.7, -325.0)
    H["tick"](0.0476)
H["place"](5000, 70.7, -325.0)             # the server puts us back
H["tick"](0.0476)
H["advance"](0.6); H["tick"](0.1)
txt = H["since"](m)
chk("BURST REVERSED is reported", "BURST REVERSED" in txt, lastline(txt, "BURST REVERSED"))
chk("it says how far back it went", "went back" in txt, lastline(txt, "went back"))
chk("the verdict is REVERTED", "verdict   | REVERTED" in txt,
    lastline(txt, "verdict   |"))
chk("the profile is still emitted", "BURST STEPS" in txt, "")

print("\n=== T29: a velocity change with no write is now visible ===")
H["setVel"](0, 0, 0)
m = goto_start(400, 70.7, -325.0, 0.05)
H["tick"](0.05)                            # prime the velocity sample
H["setVel"](-171.7, 0.1, 0.1)              # the post-landing push
H["tick"](0.05)
txt = H["since"](m)
chk("VELOCITY JUMP is logged", "VELOCITY JUMP" in txt, lastline(txt, "VELOCITY JUMP"))
chk("it shows the size of the change", "change 171.7 studs/s" in txt, "")
chk("it names the owner and floor", "owner=" in txt and "floor=" in txt, "")
H["setVel"](0, 0, 0)

print("\n=== T30: a coast is marked as physics, not a teleport ===")
H["setVel"](0, 0, 0)
m = goto_start(600, 70.7, -325.0, 0.05)
H["setVel"](-200, 0, 0)
x = 600.0
for i in range(4):                          # velocity explains every step
    x -= 10.0
    H["place"](x, 70.7, -325.0)
    H["tick"](0.05)
txt = H["since"](m)
chk("coasting moves are tagged", "physics-explained" in txt,
    lastline(txt, "physics-explained"))
chk("a coast does not open a burst", "BURST START" not in txt, "")
H["setVel"](0, 0, 0)

print("\n=== T31: a watched property change is logged ===")
m = H["mark"]()
hum["WalkSpeed"] = 250
txt = H["since"](m)
chk("PROP fires for WalkSpeed", "PROP | WalkSpeed" in txt, lastline(txt, "PROP |"))
chk("it shows the new value", "250.0" in txt, "")
hum["WalkSpeed"] = 16

print("\n=== T32: which CHANNEL saw the writes names the mechanism ===")
# A move that never assigns root.CFrame leaves the CFrameChanged hook silent. The
# stub moves Position directly to model that (in the engine, Position is a view of
# CFrame, so this is a logic test of the ledger, not of Roblox's signal rules).
H["setVel"](0, 0, 0)
m = goto_start(0, 100, 0)
for i in range(1, 4):
    H["data"](H["root"])["Position"] = H["vnew"](i * 200, 100, 0)
    H["advance"](0.05); H["tick"](0.05)
H["advance"](0.6); H["tick"](0.1)
mech = H["since"](m)
# the message itself contains the word, so check the census LINE
chk("the census has no CFrameChanged", "CFrameChanged" not in lastline(mech, "sources   |"),
    lastline(mech, "sources   |"))
chk("silence names every other mechanism",
    "no CFrameChanged event" in mech, lastline(mech, "mechanism |"))

print("\n=== T33: a real root.CFrame write IS attributed to CFrameChanged ===")
H["setVel"](0, 0, 0)
m = goto_start(0, 100, 0)
for i in range(1, 4):                       # through the instance, so signals fire
    H["root"]["CFrame"] = L.eval(f'CFrame.new({i * 200}, 100, 0)')
    H["advance"](0.05); H["tick"](0.05)
H["advance"](0.6); H["tick"](0.1)
mech = H["since"](m)
chk("a real CFrame write is recognised",
    "direct root.CFrame write" in mech, lastline(mech, "mechanism |"))
chk("the write is attributed to CFrameChanged",
    "CFrameChanged" in lastline(mech, "sources   |"), lastline(mech, "sources   |"))

print("\n=== T36: MODE carries the write style with it (PivotTo vs CFrame only) ===")
m = H["mark"]()
H["place"](0, 200, 0)
H["tick"](0.033)
m = H["mark"]()
fire(replay, "MouseButton1Click")
txt = H["since"](m)
chk("TEST writes the whole rig", "write=PivotTo+CFrame" in txt,
    lastline(txt, "REPLAY START"))

pb = buttons("MODE:")[0]
fire(pb, "MouseButton1Click")                     # -> CONTROL
chk("CONTROL writes the root only", "root.CFrame only" in H["log"](),
    lastline(H["log"](), "stateCalls="))
H["place"](0, 200, 0)
H["tick"](0.033)
m = H["mark"]()
fire(replay, "MouseButton1Click")
txt = H["since"](m)
chk("the flight reports the new mode", "write=CFrame only" in txt,
    lastline(txt, "REPLAY START"))
chk("PivotTo is skipped in that mode",
    "TRYING" not in txt and "write=CFrame only" in txt, "")
# in a clean flight nothing names the write kind, so force a rejection: with the
# server reverting, the rejection line must say which mode was used
H["place"](0, 200, 0)
H["tick"](0.033)
H["setRevert"](0, 200, 0)
m = H["mark"]()
fire(replay, "MouseButton1Click")
txt = H["since"](m)
chk("a rejection names the write mode",
    "WRITE REJECTED | #" in txt and "CFrame only" in txt,
    lastline(txt, "WRITE REJECTED"))
H["setRevert"](None)
fire(pb, "MouseButton1Click")                     # -> back to TEST
chk("TEST brings the whole rig back", "PivotTo + root.CFrame" in H["log"](),
    lastline(H["log"](), "stateCalls="))

print("\n=== T34: ownership uses the real API and reports a value ===")
m = H["mark"]()
H["setOwner"](root, H["player"])
H["setOwner"](torso, H["player"])
H["setOwner"](H["head"], H["player"])
ob = buttons("DUMP")[0]
fire(ob, "MouseButton1Click")
txt = H["since"](m)
chk("no API error in the ownership readout", "<error>" not in txt,
    lastline(txt, "root      |"))
chk("a client-owned root reads as you", "root      | you" in txt,
    lastline(txt, "root      |"))
chk("the character tally is real", "you x" in txt, lastline(txt, "character |"))

H["setOwner"](root, None)               # nil = the server owns it
m = H["mark"]()
fire(ob, "MouseButton1Click")
txt = H["since"](m)
chk("a nil owner reads as server", "root      | server" in txt,
    lastline(txt, "root      |"))
chk("still no error", "<error>" not in txt, "")
H["setOwner"](root, H["player"])

print("\n=== T35: a stale sample is a GAP, not a phantom 5000-stud move ===")
H["setVel"](0, 0, 0)
H["place"](0, 100, 0)
H["tick"](0.033)
H["advance"](25.0)                      # the sampler loses track (respawn/reload)
m = H["mark"]()
H["place"](5050, 100, 0)
H["tick"](0.033)
txt = H["since"](m)
chk("the gap is reported as a gap", "SAMPLE GAP" in txt, lastline(txt, "SAMPLE GAP"))
chk("it says how long the sampler was blind", "since the last sample" in txt, "")
chk("it says it is not a move", "NOT a move" in txt, "")
chk("no phantom move is logged",
    "LARGE_MOVE" not in txt and "TRANSFORM_JUMP" not in txt,
    lastline(txt, "SAMPLE GAP")[:70])
chk("it does not open a burst", "BURST START" not in txt, "")
# and a normal frame delta right after is still treated as a real move
H["clearLog"]()
H["place"](5250, 100, 0)
H["tick"](0.033)
chk("the next normal sample is a move again",
    "TRANSFORM_JUMP" in H["log"]() or "LARGE_MOVE" in H["log"](),
    lastline(H["log"](), "MOVE"))

print("\n=== T0b: no local is used before it is declared (the global trap) ===")
# A function defined ABOVE a `local x` that reads `x` gets a GLOBAL, not that
# local - so a flag can be set by a button and never seen by the code that reads
# it. This has now happened five times in this project.
import re as _re
_lines = script.split("\n")
_decl = {}
for _i, _l in enumerate(_lines):
    _m = _re.match(r"local\s+([A-Za-z_][\w]*)\s*(?:=|,|$)", _l)  # column 0 only
    if _m:
        for _n in _re.findall(r"[A-Za-z_][\w]*", _m.group(0))[1:]:
            _decl.setdefault(_n, _i)
_hoisted = {"stateCallsEnabled", "evaluatePendingJump", "pendingJump"}
_bad = []
for _name, _line in _decl.items():
    if _line < 100:
        continue
    for _j in range(0, _line):
        _code = _lines[_j].split("--")[0]
        # only a call-free read (a bare mention) is dangerous; assignments to a
        # not-yet-declared local are caught by the same check
        if _re.search(rf"(?<![\w.:]){_re.escape(_name)}(?![\w])", _code):
            if _name not in _hoisted:
                _bad.append(f"{_name} used at line {_j+1} but declared at {_line+1}")
            break
chk("no local is read by code defined above it", not _bad,
    ("; ".join(_bad[:3])) if _bad else f"{len(_decl)} locals checked")

print("\n=== T37: one write seen three times is ONE step, not three ===")
# The four stage channels sample the same write at different instants of the
# frame, and in Freefall the character has fallen a few studs between them: the
# second channel sees Y-3, the third Y-5. Those are echoes of one write. The old
# test compared 3D distance with a 1-stud tolerance, so the fall defeated it and
# the write was counted again - which is how a 24-write flight came back as
# "36 distinct steps" with "19 step(s) under 60% of it" and a false PARTIAL.
H["setVel"](0, 0, 0)
m = goto_start(5666.3, 70.7, -331.9)
x = 5666.3
for dx in (-139.8, -214.2, -67.3, -234.4, -186.8, -290.2):
    x += dx
    for drift in (0.0, 3.0, 5.0):            # three channels, one write
        H["place"](x, 112.7 - drift, -331.9)  # same spot, fallen a little
        H["tick"](0.0004)
        H["tick"](0.0004)
H["advance"](0.6); H["tick"](0.1)
txt = H["since"](m)
chk("6 writes read back as 6 steps",
    "6 distinct (6 channel echoes)" in txt, lastline(txt, "steps     |"))
chk("the profile keeps the reference's shape",
    "6 steps | stopped" in txt, lastline(txt, "BURST END"))
# A phantom step is a zero-horizontal step: the character did not go anywhere,
# the ledger just noticed the fall. None may appear in a flight profile.
steps = []
for ln in txt.splitlines():
    if "BURST STEPS |" not in ln or ", " not in ln or "/" not in ln:
        continue
    body = ln.split("|")[-1]
    for item in body.split(","):
        t, dx, dy = item.strip().split("/")
        steps.append((float(dx), float(dy)))
chk("no zero-horizontal step survived the dedupe",
    steps and all(abs(dx) > 0.5 for dx, _ in steps),
    f"{len(steps)} steps, min |dx| {min((abs(dx) for dx, _ in steps), default=0):.1f}")
chk("every write in the burst is represented",
    len(steps) == 6, f"{len(steps)} steps in the payload")

print("\n=== T38: the measured reference profile is intact ===")
# These are the numbers the working flight of 05:01:42 actually produced, so the
# profile in the script must add up to them - otherwise "replicate the reference"
# means nothing.
# plain string parsing - no regex, no escaping surprises
_block = script.split("MEASURED_X_DELTAS = {", 1)[1].split("}", 1)[0]
_deltas = [float(tok) for tok in _block.replace("\n", "").split(",") if tok.strip()]
_launch_block = script.split("MEASURED_LAUNCH = {", 1)[1].split("\n}", 1)[0]
_launch_pts = []
for _line in _launch_block.splitlines():
    if "dx =" in _line:
        _sx = _line.split("dx =", 1)[1].split(",")[0].strip()
        _sy = _line.split("dy =", 1)[1].split("}")[0].strip()
        _launch_pts.append((float(_sx), float(_sy)))
_drop = float(script.split("MEASURED_DROP_Y =", 1)[1].split("\n", 1)[0].split("--")[0].strip())
_studs = abs(_launch_pts[-1][0]) + sum(abs(d) for d in _deltas)
chk("the measured profile has 3 launch steps", len(_launch_pts) == 3, str(len(_launch_pts)))
chk("...and 22 cruise chunks", len(_deltas) == 22, str(len(_deltas)))
chk("it reproduces 5054.1 studs", abs(_studs - 5054.1) < 1.0, f"{_studs:.1f}")
chk("it climbs to +42.0", abs(_launch_pts[-1][1] - 42.0) < 0.05,
    f"{_launch_pts[-1][1]:.1f}")
chk("it drops -42.0", abs(_drop + 42.0) < 0.05, f"{_drop:.1f}")
chk("every chunk is a real measured step",
    all(0 < abs(d) < 500 for d in _deltas), f"min {min(map(abs, _deltas))}")

print("\n=== T39: MODE carries the profile with it, and the log says which is flying ===")
m = H["mark"]()
H["setVel"](0, 0, 0)
H["place"](0, 200, 0)
H["tick"](0.033)
m = H["mark"]()
fire(replay, "MouseButton1Click")
txt = H["since"](m)
chk("the measured profile is the default", "TEST (the reference setup)" in str(
    buttons("MODE:")[0]["Text"]), str(buttons("MODE:")[0]["Text"]).replace("\n", " / ")[:70])
chk("the replay names the profile",
    "profile=measured-0501" in txt, lastline(txt, "REPLAY START"))
chk("the params name it too", "MEASURED 05:01:42" in txt,
    lastline(txt, "REPLAY PARAMS"))
chk("the chunk count matches the measured flight", "chunks=22" in txt,
    lastline(txt, "REPLAY PARAMS"))
pb2 = buttons("MODE:")[0]
fire(pb2, "MouseButton1Click")                   # -> CONTROL
chk("CONTROL reports the other profile", "profile=ld-p3" in H["log"](),
    lastline(H["log"](), "profile="))
H["place"](0, 200, 0)
H["tick"](0.033)
m = H["mark"]()
fire(replay, "MouseButton1Click")
txt = H["since"](m)
chk("the reconstruction names itself", "profile=ld-p3" in txt,
    lastline(txt, "REPLAY START"))
chk("both profiles keep the same destination",
    "launchEnd=" in txt, lastline(txt, "REPLAY START"))
fire(pb2, "MouseButton1Click")          # back to TEST / measured

print("\n=== T40: every burst is scored against the working flight ===")
H["setVel"](0, 0, 0)
m = goto_start(5666.3, 70.7, -331.9)
x = 5666.3
for i in range(20):
    x -= 200.0
    H["place"](x, 112.7, -331.9)
    H["tick"](0.056)
H["place"](x, 70.7, -331.9)
H["tick"](0.056)
H["advance"](0.6); H["tick"](0.1)
txt = H["since"](m)
chk("a comparison block is printed", "REFERENCE DIFF" in txt, lastline(txt, "REFERENCE DIFF"))
chk("our numbers are reported", "this flight |" in txt, lastline(txt, "this flight |"))
chk("the reference numbers are reported",
    "reference   | 25 steps | 5054.1 studs" in txt, lastline(txt, "reference   |"))
chk("a clean flight is called a match", "MATCHES the reference" in txt,
    lastline(txt, "REFERENCE DIFF"))

# and when the server eats the writes, the diff must say so
H["setVel"](0, 0, 0)
m = goto_start(5000, 70.7, -325.0)
for i in range(4):
    H["place"](5000 - i * 200, 70.7, -325.0)
    H["tick"](0.056)
H["place"](5000, 70.7, -325.0)
H["tick"](0.056)
H["advance"](0.6); H["tick"](0.1)
txt = H["since"](m)
chk("a reverted flight does NOT match", "DOES NOT MATCH" in txt,
    lastline(txt, "REFERENCE DIFF"))

print("\n=== T41: the panel is six buttons, and the flight logic is one of them ===")
# Eleven switches, several of them settings that only mean something in
# combination, is what made the panel ambiguous: a half-switched combination
# tests nothing and reads as noise. This is the guard against that coming back.
texts = sorted(str(b["Text"]) for b in list(H["getCreated"]("TextButton").values()))
plain = [t.replace("\n", " / ") for t in texts]
print("   buttons:", plain)
chk("six buttons plus the close X", len(texts) == 7, f"{len(texts)}: {plain}")
chk("one button flies", len(buttons("REPLAY")) == 1, str(plain))
chk("one button carries the flight logic", len(buttons("MODE:")) == 1, str(plain))
chk("the rest are log housekeeping",
    len(buttons("Copy")) == 1 and len(buttons("Clear")) == 1, str(plain))
chk("one dial for how loud the log is", len(buttons("DIAG:")) == 1, str(plain))
chk("one button dumps ownership + snapshot", len(buttons("DUMP")) == 1, str(plain))
stale = [k for k in ("STATECALLS", "WRITE:", "PROFILE:", "FORENSICS", "FLIGHT TRACE",
                     "CAPTURE:", "OWNERSHIP", "SNAPSHOT")
         if any(k in t for t in texts)]
chk("no single-setting switch is left on the panel", not stale, f"found: {stale}")
mode_text = str(buttons("MODE:")[0]["Text"])
chk("the mode button states what it applies",
    "stateCalls OFF" in mode_text and "measured profile" in mode_text,
    mode_text.replace("\n", " / "))
diag_text = str(buttons("DIAG:")[0]["Text"])
chk("the diag button states what it applies", "FULL" in diag_text or "LEDGER" in diag_text,
    diag_text)

print(f"\n{'='*60}\nRESULT: {PASS} passed, {FAIL} failed")
if FAILED:
    print("FAILED: " + ", ".join(FAILED))
sys.exit(1 if FAIL else 0)
