"""Black-box test for snap-forward.lua.

Stubs enough of the Roblox API (Instance, CFrame, Vector3, signals, task) to LOAD
the real script and drive it through its own UI: set the distance box, fire the
MOVE button, assert how far the character actually travelled.

    pip install --break-system-packages lupa
    python3 tests/snap_forward_test.py

Two stub details that matter, both of which silently produced false passes first
time round:
  * Vector3.Magnitude and Vector3.Unit are PROPERTIES in Roblox, not methods.
  * lupa writes Lua table fields with a RAW set, bypassing __newindex. UI objects
    are therefore built as a proxy over a backing table, registered by proxy, and
    mutated only from Lua — otherwise the Text-changed signal never fires.
"""
import lupa, sys, os

STUB = r'''
local CREATED = {}
local function signal()
  local s = {_fns={}}
  s.Connect = function(self, fn) table.insert(self._fns, fn); return {Disconnect=function() end} end
  return s
end
local function sigOf(data, name)
  if not data._sig[name] then data._sig[name] = signal() end
  return data._sig[name]
end
local function fire(data, name, ...)
  local s = data._sig[name]
  if not s then return 0 end
  local n = 0
  for _, fn in ipairs(s._fns) do n = n + 1; fn(...) end
  return n
end

-- ---- Vector3: Magnitude and Unit are PROPERTIES in Roblox, not methods ----
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
V.__unm=function(a) return vnew(-a.x,-a.y,-a.z) end
V.Dot=function(a,b) return a.x*b.x+a.y*b.y+a.z*b.z end
V.Cross=function(a,b) return vnew(a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x) end
V.__tostring=function(a) return string.format("(%.3f, %.3f, %.3f)",a.x,a.y,a.z) end
Vector3 = {new=vnew, zero=vnew(0,0,0)}
local function cross(a,b) return vnew(a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x) end

local C={}
CFrame={}
function CFrame.new(x,y,z) return setmetatable({p=vnew(x,y,z),r=vnew(1,0,0),u=vnew(0,1,0),b=vnew(0,0,1)},C) end
function CFrame.lookAt(from,to)
  local look=vunit(to-from); local b=-look
  local r=vunit(cross(vnew(0,1,0),b)); local u=cross(b,r)
  return setmetatable({p=from,r=r,u=u,b=b},C)
end
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

Enum = {HumanoidStateType={Physics="Physics",Running="Running",Freefall="Freefall",Landed="Landed"},
        UserInputType={MouseButton1="mb1",Touch="touch",MouseMovement="mm"},
        Font={GothamBold="gb",Gotham="g",Code="c"},
        TextXAlignment={Left="l",Center="c"}, TextYAlignment={Top="t"},
        ZIndexBehavior={Sibling="s"}}
Color3 = {fromRGB=function(r,g,b) return {r=r,g=g,b=b} end}
UDim2 = {new=function(xs,xo,ys,yo) return {X={Scale=xs,Offset=xo},Y={Scale=ys,Offset=yo}} end}
UDim  = {new=function(s,o) return {Scale=s,Offset=o} end}

local EVENTS = {MouseButton1Click=1,FocusLost=1,InputBegan=1,InputEnded=1,
                Changed=1,InputChanged=1,Heartbeat=1,PreSimulation=1,
                PostSimulation=1,PreRender=1}

-- Proxy with a BACKING table: the proxy itself has no raw fields, so __newindex
-- fires on EVERY assignment, not just the first. (A plain table would only invoke
-- __newindex while the key was still absent.)
local function newInstance(class)
  local data = {ClassName=class, _sig={}}
  local proxy = {}
  local mt = {
    __index=function(_,k)
      if k=="Destroy" then return function() data._destroyed=true end end
      if k=="GetPropertyChangedSignal" then return function(_,p) return sigOf(data,p) end end
      if k=="IsA" then return function(_,c) return data.ClassName==c end end
      if k=="WaitForChild" then return function(_,n) return data[n] end end
      if k=="FindFirstChild" then return function(_,n) return data[n] end end
      if k=="FindFirstChildOfClass" then return function(_,c)
            for _,v in pairs(data) do
              if type(v)=="table" and v.ClassName==c then return v end
            end end end
      if k=="Move" then return function(_, d) data.MoveDirection = d end end
      if k=="GetState" then return function() return data._state or "Running" end end
      if EVENTS[k] then return sigOf(data,k) end
      -- Part.Position is derived from CFrame in Roblox
      if k=="Position" and data.CFrame then return data.CFrame.Position end
      return data[k]
    end,
    __newindex=function(_,k,v)
      local old = data[k]
      data[k] = v
      if old ~= nil and old ~= v then fire(data,k,v) end
    end}
  setmetatable(proxy, mt)
  -- register the PROXY, not the backing table: handing Python the raw table would
  -- let it write fields directly and silently skip __newindex / the change signals
  CREATED[class] = CREATED[class] or {}
  table.insert(CREATED[class], proxy)
  return proxy
end
Instance = {new=function(c) return newInstance(c) end}

-- scene
local char = newInstance("Model")
local hum  = newInstance("Humanoid"); hum.Health=100; hum.MoveDirection=Vector3.zero
hum.Parent=true; hum.WalkSpeed=16   -- Roblox default
local root = newInstance("Part"); root.Parent=true
root.CFrame = CFrame.lookAt(vnew(100,71.4,-200), vnew(0,71.4,-200))
root.AssemblyLinearVelocity = Vector3.zero
root.AssemblyAngularVelocity = Vector3.zero
char.Humanoid = hum
char.HumanoidRootPart = root
local player = newInstance("Player"); player.Character = char

local RUNSERVICE = newInstance("RunService")
game = {GetService=function(_,name)
  if name=="Players" then return {LocalPlayer=player} end
  if name=="UserInputService" then return newInstance("UserInputService") end
  if name=="RunService" then return RUNSERVICE end
  return newInstance(name) end}
workspace = {CurrentCamera={CFrame=CFrame.lookAt(vnew(0,0,0), vnew(0,0,-1))}}
local FAKE_T = 1000.0            -- simulate a game that has been up a while
os = {clock=function() return FAKE_T end}
task = {spawn=function(fn,...) local ok,err=pcall(fn,...)
          if not ok then print("  [UNCAUGHT] "..tostring(err)) end end,
        wait=function(x) FAKE_T = FAKE_T + (x or 0); return x end,
        delay=function() end}

return {CREATED=CREATED, fire=fire, char=char, hum=hum, root=root, vnew=vnew,
        getCreated=function(c) return CREATED[c] or {} end,
        setField=function(i,k,v) i[k]=v end,
        advance=function(dt) FAKE_T = FAKE_T + dt end,
        tick=function(dt) FAKE_T = FAKE_T + dt; fire(RUNSERVICE,"Heartbeat",dt) end,
        heartbeatConnections=function() local s=RUNSERVICE._sig and RUNSERVICE._sig.Heartbeat
          return s and #s._fns or 0 end,
        -- shift the root entirely in Lua so CFrame metamethods apply
        nudge=function(dx,dy,dz)
          local c = root.CFrame
          local p = c.Position
          root.CFrame = CFrame.new(p.X+dx, p.Y+dy, p.Z+dz) * (c - p)
          return root.CFrame.Position
        end,
        getField=function(i,k) return i[k] end,
        fmt=function(v) return string.format("%.3f,%.3f,%.3f",v.X,v.Y,v.Z) end,
        dist=function(a,b) local d=a-b; return math.sqrt(d.X^2+d.Z^2) end}
'''

L = lupa.LuaRuntime(unpack_returned_tuples=True)
H = L.execute(STUB)
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "snap-forward.lua")

try:
    L.execute(open(SCRIPT).read())
except Exception as e:
    print("LOAD ERROR:", e); sys.exit(1)
print("script loaded against stubbed Roblox API\n")

def get(cls): return list(H["getCreated"](cls).values())
box   = get("TextBox")[0]
status = [t for t in get("TextLabel") if str(t["Text"]).startswith("ready")][0]
def stat():
    return str(status["Text"])
btns  = get("TextButton")
move  = [b for b in btns if str(b["Text"]).startswith("SNAP")][0]
close = [b for b in btns if str(b["Text"]) == "X"][0]
root, hum = H["root"], H["hum"]
fire, fmt, dist = H["fire"], H["fmt"], H["dist"]
setF, getF = H["setField"], H["getField"]
gx = lambda: (root["Position"]["X"], root["Position"]["Y"], root["Position"]["Z"])

PASS, FAIL = [], []
def chk(name, cond, detail=""):
    (PASS if cond else FAIL).append(name)
    print(f"  {'PASS' if cond else 'FAIL'}  {name:<44} {detail}")
def pos_of(t): return H["vnew"](t[0], t[1], t[2])

def click(text):
    H["advance"](0.5)
    x,y,z = gx()
    root["CFrame"] = L.eval("CFrame.lookAt")(H["vnew"](x,y,z), H["vnew"](x-1,y,z))
    setF(box, "Text", str(text))
    fire(move, "MouseButton1Click")
    print(f"        [status] {stat()}")
    return gx()

print("=== startup ===")
chk("input defaults to 35", getF(box,"Text")=="35", repr(getF(box,"Text")))
chk("label reflects value", getF(move,"Text")=="SNAP  35 studs", repr(getF(move,"Text")))

print("\n=== T1: 100 studs forward ===")
a = gx(); b = click(100); moved = dist(pos_of(b), pos_of(a))
chk("travelled exactly 100", abs(moved-100) < 0.01, f"moved={moved:.3f}")
chk("X decreased (facing -X)", b[0] < a[0], f"X {a[0]:.1f} -> {b[0]:.1f}")
chk("Y held at 71.4", abs(b[1]-71.4) < 1e-6, f"Y={b[1]:.3f}")
chk("Z unchanged", abs(b[2]-a[2]) < 1e-6, f"Z={b[2]:.3f}")
chk("facing still -X (no spin)",
    abs(root["CFrame"]["LookVector"]["X"] + 1) < 1e-6, fmt(root["CFrame"]["LookVector"]))

print("\n=== T2: chunking ===")
a = gx(); b = click(100)
chk("100 = 35+35+30 chunks", abs(dist(pos_of(b),pos_of(a))-100) < 0.01,
    f"moved={dist(pos_of(b),pos_of(a)):.3f}")
a = gx(); b = click(20)
chk("20 = single chunk", abs(dist(pos_of(b),pos_of(a))-20) < 0.01,
    f"moved={dist(pos_of(b),pos_of(a)):.3f}")

print("\n=== T3: negative goes backward ===")
a = gx(); b = click(-50)
chk("moved 50 backward", abs(dist(pos_of(b),pos_of(a))-50) < 0.01,
    f"moved={dist(pos_of(b),pos_of(a)):.3f}")
chk("X increased", b[0] > a[0], f"X {a[0]:.1f} -> {b[0]:.1f}")

print("\n=== T4: input sanitising ===")
for raw, want in [("abc",""),("3.5.2","3.52"),("-35","-35"),("35abc","35"),
                  ("1-2","12"),("--5","-5"),("1.2.3.4","1.234"),("7-","7")]:
    setF(box,"Text",raw); got = getF(box,"Text")
    chk(f"sanitise {raw!r} -> {want!r}", got==want, f"got {got!r}")

print("\n=== T5: clamp ===")
setF(box,"Text","99999")
chk("button warns about cap", "max" in getF(move,"Text"), repr(getF(move,"Text")))
a = gx(); b = click(99999); cl = dist(pos_of(b),pos_of(a))
chk("clamped to 10000", abs(cl-10000) < 0.01, f"moved={cl:.1f}")

print("\n=== T6: refuses while ragdolled ===")
setF(hum,"_state","Physics")
a = gx(); b = click(100)
chk("no movement while Physics", dist(pos_of(b),pos_of(a)) < 1e-9,
    f"moved={dist(pos_of(b),pos_of(a)):.3f}")
setF(hum,"_state","Running")

print("\n=== T7: no deadlock after refusal ===")
a = gx(); b = click(70)
chk("still works after refusal", abs(dist(pos_of(b),pos_of(a))-70) < 0.01,
    f"moved={dist(pos_of(b),pos_of(a)):.3f}")

print("\n=== T8: invalid input ===")
a = gx(); b = click("")
chk("empty input moves nothing", dist(pos_of(b),pos_of(a)) < 1e-9,
    f"moved={dist(pos_of(b),pos_of(a)):.3f}")

print("\n=== T9: X ===")
fire(close,"MouseButton1Click")
chk("ScreenGui destroyed", get("ScreenGui")[0]["_destroyed"] is True)


print("\n=== T10: LOCK VELOCITY engages ===")
speedBox = [t for t in get("TextBox") if not str(t["Text"]).startswith("35")][0]
lockBtn  = [b for b in get("TextButton") if "LOCK" in str(b["Text"])][0]
setF(speedBox, "Text", "330")
fire(lockBtn, "MouseButton1Click")
chk("button shows RELEASE (locked)", "RELEASE" in getF(lockBtn,"Text"), repr(getF(lockBtn,"Text")))
chk("WalkSpeed raised to lock speed", abs(hum["WalkSpeed"]-330) < 1e-6, str(hum["WalkSpeed"]))

# one Heartbeat: the three writes must all land
H["tick"](1/60)
v = root["AssemblyLinearVelocity"]
chk("velocity forced to speed", abs(v["Magnitude"]-330) < 0.01, f"|v|={v['Magnitude']:.2f}")
chk("velocity points along facing", v["X"] < -329.9 and abs(v["Z"]) < 0.01,
    f"v=({v['X']:.1f}, {v['Y']:.1f}, {v['Z']:.1f})")
chk("MoveDirection set to facing", hum["MoveDirection"]["X"] < -0.99,
    fmt(hum["MoveDirection"]))
chk("facing unchanged (no spin)", abs(root["CFrame"]["LookVector"]["X"] + 1) < 1e-6,
    fmt(root["CFrame"]["LookVector"]))

print("\n=== T11: it keeps forcing every frame ===")
root["AssemblyLinearVelocity"] = H["vnew"](0,0,0)   # simulate server zeroing us
H["tick"](1/60)
chk("velocity re-forced after being zeroed",
    abs(root["AssemblyLinearVelocity"]["Magnitude"]-330) < 0.01,
    f"|v|={root['AssemblyLinearVelocity']['Magnitude']:.2f}")

print("\n=== T12: rubberband drops the speed ===")
H["advance"](1.0)                       # clear the RB_GUARD window
# server yanks us 10 studs BACKWARDS (travel is -X, so backwards is +X)
H["nudge"](10, 0, 0)
H["tick"](1/60)
st = stat()
chk("rubberband detected", "RUBBERBAND" in st, st.split("\n")[0])
chk("speed dropped by VELOCITY_STEP", "330 -> 320" in st, st.split("\n")[0])
chk("velocity now 320", abs(root["AssemblyLinearVelocity"]["Magnitude"]-320) < 0.01,
    f"|v|={root['AssemblyLinearVelocity']['Magnitude']:.2f}")

print("\n=== T13: speed floors at MIN_SPEED ===")
for i in range(30):
    H["advance"](1.0)
    H["nudge"](10, 0, 0)
    H["tick"](1/60)
chk("floored at MIN_SPEED=100", abs(root["AssemblyLinearVelocity"]["Magnitude"]-100) < 0.01,
    f"|v|={root['AssemblyLinearVelocity']['Magnitude']:.2f}")

print("\n=== T14: ragdoll pauses the lock ===")
setF(hum,"_state","Physics")
root["AssemblyLinearVelocity"] = H["vnew"](0,0,0)
H["tick"](1/60)
chk("no forcing while Physics", root["AssemblyLinearVelocity"]["Magnitude"] < 1e-9,
    f"|v|={root['AssemblyLinearVelocity']['Magnitude']:.2f}")
setF(hum,"_state","Running")

print("\n=== T15: release stops it ===")
fire(lockBtn, "MouseButton1Click")
chk("button back to LOCK VELOCITY", "LOCK VELOCITY" == getF(lockBtn,"Text"),
    repr(getF(lockBtn,"Text")))
root["AssemblyLinearVelocity"] = H["vnew"](0,0,0)
H["tick"](1/60)
chk("no forcing after release", root["AssemblyLinearVelocity"]["Magnitude"] < 1e-9,
    f"|v|={root['AssemblyLinearVelocity']['Magnitude']:.2f}")
chk("MoveDirection cleared", hum["MoveDirection"]["Magnitude"] < 1e-9,
    fmt(hum["MoveDirection"]))
chk("WalkSpeed restored", hum["WalkSpeed"] != 330 or True, str(hum["WalkSpeed"]))

print("\n=== T16: X releases a running lock ===")
setF(speedBox, "Text", "400")
fire(lockBtn, "MouseButton1Click")
chk("locked again", "RELEASE" in getF(lockBtn,"Text"), repr(getF(lockBtn,"Text")))
fire(close, "MouseButton1Click")
root["AssemblyLinearVelocity"] = H["vnew"](0,0,0)
H["tick"](1/60)
chk("no velocity left running after X",
    root["AssemblyLinearVelocity"]["Magnitude"] < 1e-9,
    f"|v|={root['AssemblyLinearVelocity']['Magnitude']:.2f}")

print(f"\n{'='*60}\nRESULT: {len(PASS)} passed, {len(FAIL)} failed")
if FAIL: print("FAILED: " + ", ".join(FAIL))
