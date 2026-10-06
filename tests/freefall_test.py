"""Black-box test for freefall.lua.

Stubs enough of the Roblox API to LOAD the real script and drive it through its
own UI, replaying frames one at a time and recording every velocity it claims.

The point of this file is the central claim of the script: that it never asserts
HORIZONTAL velocity, which is what stops the server reconciling and rubberbanding.
So the key assertion is not only "did it travel 2000 studs" but "was every single
velocity write horizontal-free".

    pip install --break-system-packages lupa
    python3 tests/freefall_test.py

Inherited stub pitfalls (long version in tests/snap_forward_test.py):
  * Vector3.Magnitude / .Unit are PROPERTIES, not methods.
  * lupa writes Lua table fields with a RAW set, so UI objects are a proxy over a
    backing table, registered by proxy, and mutated only from Lua.
  * event names must resolve through __index to the signal object, or
    `btn.MouseButton1Click:Connect(...)` fails with "index a nil value".
  * CFrame arithmetic across the Python boundary loses metamethods - do CFrame
    maths inside Lua (see H["teleport"] / H["face"]).
"""
import lupa, sys, os

STUB = r'''
local CREATED = {}
local WATCH, COLLIDE_LOG          -- declared here so the instance mt captures them
local function signal()
  local s = {_fns={}}
  s.Connect = function(self, fn)
    table.insert(self._fns, fn)
    return {Disconnect=function()
      for i,f in ipairs(s._fns) do if f==fn then table.remove(s._fns,i) break end end
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
  local n = 0
  local snapshot = {}
  for i,f in ipairs(s._fns) do snapshot[i]=f end
  for _, fn in ipairs(snapshot) do n = n + 1; fn(...) end
  return n
end

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
function CFrame.new(x,y,z)
  if type(x)=="table" and y==nil then
    return setmetatable({p=x,r=vnew(1,0,0),u=vnew(0,1,0),b=vnew(0,0,1)},C)
  end
  if type(x)=="table" and type(y)=="table" then   -- CFrame.new(pos, lookAt)
    local look=vunit(y-x); local b=-look
    local r=vunit(cross(vnew(0,1,0),b)); local u=cross(b,r)
    return setmetatable({p=x,r=r,u=u,b=b},C)
  end
  return setmetatable({p=vnew(x,y,z),r=vnew(1,0,0),u=vnew(0,1,0),b=vnew(0,0,1)},C)
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
        ZIndexBehavior={Sibling="s"},
        RaycastFilterType={Exclude="Exclude",Include="Include"}}
Color3 = {fromRGB=function(r,g,b) return {r=r,g=g,b=b} end}
UDim2 = {new=function(xs,xo,ys,yo) return {X={Scale=xs,Offset=xo},Y={Scale=ys,Offset=yo}} end}
UDim  = {new=function(s,o) return {Scale=s,Offset=o} end}
RaycastParams = {new=function() return {FilterDescendantsInstances={}} end}
-- math.clamp is a Roblox extension; stock Lua has no such function
math.clamp = function(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local EVENTS = {MouseButton1Click=1,FocusLost=1,InputBegan=1,InputEnded=1,
                Changed=1,InputChanged=1,Heartbeat=1,PreSimulation=1,
                PostSimulation=1,PreRender=1}

-- Proxy over a backing table, so __newindex fires on EVERY assignment.
local function newInstance(class)
  local data = {ClassName=class, _sig={}}
  local proxy = {}
  local mt = {
    __index=function(_,k)
      if k=="Destroy" then return function() data._destroyed=true end end
      if k=="GetPropertyChangedSignal" then return function(_,p) return sigOf(data,p) end end
      if k=="IsA" then return function(_,c)
            return data.ClassName==c or (c=="BasePart" and data.ClassName=="Part") end end
      if k=="WaitForChild" then return function(_,n) return data[n] end end
      if k=="FindFirstChild" then return function(_,n) return data[n] end end
      if k=="FindFirstChildOfClass" then return function(_,c)
            for _,v in pairs(data) do
              if type(v)=="table" and v.ClassName==c then return v end
            end end end
      if k=="GetDescendants" then return function()
            local out={}
            local function walk(t)
              for _,v in pairs(t) do
                if type(v)=="table" and v.ClassName then table.insert(out,v); walk(v) end
              end
            end
            walk(data)
            if data._parts then for _,p in ipairs(data._parts) do table.insert(out,p) end end
            return out end end
      if k=="Move" then return function(_, d) data.MoveDirection = d end end
      if k=="GetState" then return function() return data._state or "Running" end end
      if k=="Raycast" then return function(_, origin, dir, params) return data._rayHit end end
      if EVENTS[k] then return sigOf(data,k) end
      if k=="Position" and data.CFrame then return data.CFrame.Position end
      return data[k]
    end,
    __newindex=function(_,k,v)
      local prev = data[k]
      data[k]=v
      if WATCH and k=="AssemblyLinearVelocity" then
        table.insert(WATCH, {x=v.x, y=v.y, z=v.z})
      end
      if COLLIDE_LOG and k=="CanCollide" then table.insert(COLLIDE_LOG, v) end
      local s = data._sig[k]
      if s then for _,fn in ipairs(s._fns) do fn(v, prev) end end
    end,
  }
  setmetatable(proxy, mt)
  -- register the PROXY, not the backing table
  CREATED[class] = CREATED[class] or {}
  table.insert(CREATED[class], proxy)
  return proxy
end
Instance = {new=function(c) return newInstance(c) end}

local player = newInstance("Player"); player.Name="Tester"; player.UserId=1
local RUNSERVICE = newInstance("RunService")

local char = newInstance("Model"); char.Name = "Tester"
local root = newInstance("Part"); root.Name = "HumanoidRootPart"
local hum  = newInstance("Humanoid"); hum.Health=100; hum.WalkSpeed=16
local torso = newInstance("Part"); torso.Name="Torso"; torso.CanCollide=true
local head  = newInstance("Part"); head.Name="Head";   head.CanCollide=true
char.Humanoid = hum
char.HumanoidRootPart = root
char._parts = {root, torso, head}   -- what GetDescendants() will walk
player.Character = char

local WORKSPACE = newInstance("Workspace")
WORKSPACE.CurrentCamera = newInstance("Camera")

game = {GetService=function(_,name)
  if name=="Players" then return {LocalPlayer=player} end
  if name=="UserInputService" then return newInstance("UserInputService") end
  if name=="RunService" then return RUNSERVICE end
  return newInstance(name) end}
workspace = WORKSPACE

task = {wait=function() end, spawn=function(f,...) f(...) end, delay=function() end}

local FAKE_T = 1000.0            -- simulate a game that has been up a while
os = {clock=function() return FAKE_T end}

return {CREATED=CREATED, fire=fire, char=char, hum=hum, root=root, torso=torso,
        head=head, player=player, vnew=vnew, getCreated=function(c)
          return CREATED[c] or {} end,
        setField=function(i,k,v) i[k]=v end,
        advance=function(dt) FAKE_T = FAKE_T + dt end,
        heartbeat=function(dt) FAKE_T = FAKE_T + (dt or 1/60)
          return fire(RUNSERVICE,"Heartbeat",dt or 1/60) end,
        stepN=function(n,dt) for _=1,n do FAKE_T = FAKE_T + (dt or 1/60)
          fire(RUNSERVICE,"Heartbeat",dt or 1/60) end end,
        heartbeatSubs=function() local s=RUNSERVICE._sig and RUNSERVICE._sig.Heartbeat
          return s and #s._fns or 0 end,
        watchStart=function() WATCH = {} end,
        watchList=function() return WATCH or {} end,
        collideStart=function() COLLIDE_LOG = {} end,
        collideList=function() return COLLIDE_LOG or {} end,
        setRayHit=function(y) WORKSPACE._rayHit = {Position=vnew(0,y,0)} end,
        clearRayHit=function() WORKSPACE._rayHit = nil end,
        -- CFrame maths must happen in Lua or metamethods are lost
        teleport=function(x,y,z) root.CFrame = CFrame.new(x,y,z)
          return root.CFrame.Position end,
        face=function(dx,dz)
          local from = root.CFrame.Position
          root.CFrame = CFrame.new(from, from + vnew(dx,0,dz))
          return root.CFrame.LookVector end}
'''

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
script = open(os.path.join(ROOT, "freefall.lua")).read()

PASS = FAIL = 0
FAILED = []
def chk(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  PASS  {name:<48}{detail}")
    else:
        FAIL += 1
        FAILED.append(name)
        print(f"  FAIL  {name:<48}{detail}")

L = lupa.LuaRuntime(unpack_returned_tuples=True)
try:
    H = L.execute(STUB)
    L.execute(script)
except Exception as e:
    print("LOAD ERROR:", e)
    sys.exit(1)

print("script loaded against stubbed Roblox API")

root, hum, torso, head = H["root"], H["hum"], H["torso"], H["head"]
fire = H["fire"]
getCreated = H["getCreated"]

def values(tbl):
    """Lua tables iterate as KEYS from Python; .values() gives the entries."""
    return list(tbl.values())

def buttons(substr):
    return [b for b in values(getCreated("TextButton")) if substr in str(b["Text"])]

fly   = buttons("FLY")[0]
close = buttons("X")[0]
box   = values(getCreated("TextBox"))[0]

def collide_off(): return torso["CanCollide"] is False or torso["CanCollide"] == False

print("\n=== T1: 2000 studs forward ===")
H["teleport"](1000, 100, 0)
H["face"](-1, 0)
chk("facing is -X", abs(root["CFrame"]["LookVector"]["X"] + 1) < 1e-9,
    str(root["CFrame"]["LookVector"]))
H["setRayHit"](70)
H["watchStart"]()
H["collideStart"]()
fire(fly, "MouseButton1Click")
chk("flight started", H["heartbeatSubs"]() == 1, f"subs={H['heartbeatSubs']()}")
H["stepN"](400)
startX, endX = 1000.0, root["CFrame"]["Position"]["X"]
travelled = startX - endX
chk("travelled ~2000 studs", 1900 <= travelled <= 2100, f"{travelled:.1f} studs")
chk("moved toward target (-X)", endX < startX, f"X {startX:.0f} -> {endX:.1f}")
chk("flight ended on its own", H["heartbeatSubs"]() == 0, f"subs={H['heartbeatSubs']()}")

print("\n=== T2: THE core claim - no horizontal velocity ever claimed ===")
vels = values(H["watchList"]())
n = len(vels)
horiz = [v for v in vels if abs(v["x"]) > 1e-9 or abs(v["z"]) > 1e-9]
chk("velocity writes recorded", n > 10, f"{n} writes")
chk("ZERO horizontal claims", len(horiz) == 0,
    f"{len(horiz)}/{n} horizontal" + (f" e.g. {horiz[0]}" if horiz else ""))
ys = sorted({round(v["y"], 2) for v in vels})
chk("downward claim, never upward", all(y <= 0 for y in ys), f"Y claims {ys}")

print("\n=== T3: speed is STEP_SIZE per frame, as in the logs ===")
flight_frames = n
chk("~2000/78 frames + ramp + descent", 25 <= flight_frames <= 40,
    f"{flight_frames} frames x 78 = {flight_frames*78} studs")

print("\n=== T4: collisions off during, restored after ===")
col = values(H["collideList"]())
chk("collisions were disabled", any(c is False or c == False for c in col), f"{len(col)} writes")
chk("collisions restore to true", (col[-1] is True or col[-1] == True), f"last={col[-1]}")
chk("Torso collides again", torso["CanCollide"] is True or torso["CanCollide"] == True,
    str(torso["CanCollide"]))

print("\n=== T5: noclip never leaks on abort ===")
H["teleport"](1000, 100, 0); H["face"](-1, 0)
fire(fly, "MouseButton1Click")
H["stepN"](3)
chk("noclip active during flight", collide_off(), str(torso["CanCollide"]))
fire(fly, "MouseButton1Click")            # second press cancels
chk("cancelled", H["heartbeatSubs"]() == 0, f"subs={H['heartbeatSubs']()}")
chk("collisions restored on abort", torso["CanCollide"] is True or torso["CanCollide"] == True,
    str(torso["CanCollide"]))

print("\n=== T6: MAX_FLIGHT_S bounds the run ===")
H["teleport"](1000, 100, 0); H["face"](-1, 0)
box["Text"] = "100000"
fire(fly, "MouseButton1Click")
H["stepN"](400)
chk("run bounded", H["heartbeatSubs"]() == 0, f"subs={H['heartbeatSubs']()}")
chk("collisions restored after timeout",
    torso["CanCollide"] is True or torso["CanCollide"] == True, str(torso["CanCollide"]))

print("\n=== T7: shorter distance honoured ===")
H["teleport"](2000, 100, 0); H["face"](-1, 0)
box["Text"] = "500"
fire(fly, "MouseButton1Click")
H["stepN"](400)
trav = 2000 - root["CFrame"]["Position"]["X"]
chk("~500 studs", 450 <= trav <= 600, f"{trav:.1f}")

print("\n=== T8: refuses while ragdolled ===")
H["teleport"](1000, 100, 0)
H["setField"](hum, "_state", "Physics")
box["Text"] = "2000"
fire(fly, "MouseButton1Click")
chk("no flight while Physics", H["heartbeatSubs"]() == 0, f"subs={H['heartbeatSubs']()}")
H["setField"](hum, "_state", "Running")

print("\n=== T9: invalid input handled ===")
box["Text"] = ""
fire(fly, "MouseButton1Click")
chk("empty input refused", H["heartbeatSubs"]() == 0, f"subs={H['heartbeatSubs']()}")

print("\n=== T10: X cleans up mid-flight ===")
H["teleport"](1000, 100, 0); H["face"](-1, 0)
box["Text"] = "2000"
fire(fly, "MouseButton1Click")
H["stepN"](2)
fire(close, "MouseButton1Click")
chk("Heartbeat disconnected", H["heartbeatSubs"]() == 0, f"subs={H['heartbeatSubs']()}")
chk("collisions restored by X",
    torso["CanCollide"] is True or torso["CanCollide"] == True, str(torso["CanCollide"]))
chk("ScreenGui destroyed",
    any(r["_destroyed"] for r in values(getCreated("ScreenGui"))), "")

print("\n=== T11: descent uses the raycast ground, not a blind drop ===")
H["teleport"](1000, 100, 0); H["face"](-1, 0)
H["setRayHit"](42)
box["Text"] = "100"
fire(fly, "MouseButton1Click")
H["stepN"](400)
chk("landed near groundY+3", abs(root["CFrame"]["Position"]["Y"] - 45) < 6,
    f"Y={root['CFrame']['Position']['Y']:.1f} (ground 42)")

print(f"\n{'='*60}\nRESULT: {PASS} passed, {FAIL} failed")
if FAILED:
    print("FAILED: " + ", ".join(FAILED))
sys.exit(1 if FAIL else 0)
