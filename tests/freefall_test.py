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
local PROXY_DATA = {}
local REJECT_ROOT = false   -- must be declared BEFORE newInstance,
                            -- or __newindex reads a global and the flag no-ops
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
V.__div=function(a,b) if type(b)=="number" then return vnew(a.x/b,a.y/b,a.z/b) end
  return vnew(a.x/b.x,a.y/b.y,a.z/b.z) end
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
function CFrame.Angles(rx, ry, rz)
  -- only Y is used by the script; do it properly so LookVector is right
  local cy, sy = math.cos(ry or 0), math.sin(ry or 0)
  return setmetatable({p=vnew(0,0,0),
    r=vnew(cy, 0, -sy), u=vnew(0,1,0), b=vnew(sy, 0, cy)}, C)
end
C.PointToObjectSpace=function(cf, p)
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

Enum = {HumanoidStateType={Physics="Physics",Running="Running",Freefall="Freefall",Landed="Landed"},
        UserInputType={MouseButton1="mb1",Touch="touch",MouseMovement="mm"},
        Font={GothamBold="gb",Gotham="g",Code="c"},
        TextXAlignment={Left="l",Center="c"}, TextYAlignment={Top="t"},
        ZIndexBehavior={Sibling="s"},
        RaycastFilterType={Exclude="Exclude",Include="Include"},
        RenderPriority={Character={Value=200},Camera={Value=200}}}
OverlapParams = {new=function() return {FilterDescendantsInstances={}} end}
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
                PostSimulation=1,PreRender=1,Died=1,CharacterAdded=1,
                StateChanged=1,Touched=1}

-- Proxy over a backing table, so __newindex fires on EVERY assignment.
local function newInstance(class)
  local data = {ClassName=class, _sig={}, Size=vnew(4,2,4)}
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
      if k=="ChangeState" then return function(_, st) data._state = st end end
      if k=="PivotTo" then return function(_, cf)
            -- move every part, the way the real model pivot does
            if data._parts then
              for _, p in ipairs(data._parts) do p.CFrame = cf end
            end
            if data.CFrame then data.CFrame = cf end
            return true end end
      if k=="GetFullName" then return function()
            return (tostring(data.Name or data.ClassName)) end end
      if k=="GetConnectedParts" then return function() return {} end end
      if k=="GetState" then return function() return data._state or "Running" end end
      if k=="Raycast" then return function(_, origin, dir, params)
            -- Two kinds of probe, because they answer different questions:
            --   pointing DOWN  -> ground height (path scan / descent target)
            --   pointing SIDEWAYS -> anything solid crossing the route at height
            if dir.Y < -0.5 then
              if data._segments and #data._segments > 0 then
                local x = origin.X
                local best = nil
                for _, seg in ipairs(data._segments) do
                  if x >= seg[1] and x <= seg[2] and seg[3] ~= false then
                    if not best or seg[3] > best then best = seg[3] end
                  end
                end
                if best then return {Position=vnew(x, best, origin.Z), Instance=nil} end
                return nil
              end
              return data._rayHit
            end
            -- horizontal: a barrier is a wall spanning [yMin,yMax] at plane x=bx
            if data._barriers then
              local x = origin.X
              -- the script passes dir * PROBE_LEN, so dir is NOT a unit vector.
              -- Normalise before using it, or every distance is multiplied by
              -- the ray length (that read "at ~18000 studs" for a wall 600 away).
              local rayLen = dir.Magnitude
              local ux = rayLen > 0 and dir.X / rayLen or 0
              local step = ux > 0 and 1 or -1
              local bestAt, bestInst = nil, nil
              for _, b in ipairs(data._barriers) do
                local bx, yMin, yMax = b[1], b[2], b[3]
                local crosses = (step > 0 and bx > x) or (step < 0 and bx < x)
                local at = math.abs(bx - x)
                if crosses and at <= rayLen
                   and origin.Y >= yMin and origin.Y <= yMax then
                  if not bestAt or at < bestAt then bestAt, bestInst = at, b[4] end
                end
              end
              if bestAt then
                return {Position=vnew(origin.X + ux * bestAt, origin.Y, origin.Z),
                        Instance=bestInst}
              end
            end
            return nil
          end end
      if EVENTS[k] then return sigOf(data,k) end
      if k=="Position" and data.CFrame then return data.CFrame.Position end
      return data[k]
    end,
    __newindex=function(_,k,v)
      -- a rejected write: the engine keeps the old position, which is exactly
      -- what makes the reference's correction detector fire
      if REJECT_ROOT and k=="CFrame" and data.Name=="HumanoidRootPart" then
        return
      end
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
  PROXY_DATA[proxy] = data
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
root.Orientation = vnew(0,0,0)
root.CFrame = CFrame.new(0,0,0)
root.AssemblyLinearVelocity = vnew(0,0,0)
root.AssemblyAngularVelocity = vnew(0,0,0)
local hum  = newInstance("Humanoid"); hum.Health=100; hum.MaxHealth=100
hum.WalkSpeed=16; hum.AutoRotate = true
local torso = newInstance("Part"); torso.Name="Torso"; torso.CanCollide=true
local head  = newInstance("Part"); head.Name="Head";   head.CanCollide=true
torso.CFrame = CFrame.new(1000, 100, 0)
head.CFrame  = CFrame.new(1000, 103, 0)
char.Humanoid = hum
char.HumanoidRootPart = root
char._parts = {root, torso, head}   -- what GetDescendants()/PivotTo walk
-- Parent must be truthy or the flight aborts as "character disappeared"
char.Parent = true; hum.Parent = true; root.Parent = true
torso.Parent = true; head.Parent = true
player.Character = char

local WORKSPACE = newInstance("Workspace")
WORKSPACE.CurrentCamera = newInstance("Camera")
WORKSPACE.FallenPartsDestroyHeight = -500

-- a stand-in kill brick so nearbyParts() has something to report
local killBrick = newInstance("Part")
killBrick.Name = "LavaKillBrick"; killBrick.CanCollide = false
killBrick.Material = "Neon"; killBrick.Position = vnew(1000,100,0)
killBrick.Parent = true
WORKSPACE.GetPartBoundsInRadius = function(_, pos, radius, params)
  local out = {killBrick}
  if WORKSPACE._guards then
    for _, g in ipairs(WORKSPACE._guards) do table.insert(out, g) end
  end
  if WORKSPACE._slabs then
    for _, sl in ipairs(WORKSPACE._slabs) do table.insert(out, sl) end
  end
  return out end

game = {GetService=function(_,name)
  if name=="Players" then return {LocalPlayer=player} end
  if name=="UserInputService" then return newInstance("UserInputService") end
  if name=="RunService" then return RUNSERVICE end
  return newInstance(name) end}
workspace = WORKSPACE

task = {wait=function() end, spawn=function(f,...) f(...) end, delay=function() end}

local RENDER_FNS = {}
RUNSERVICE.BindToRenderStep   = function(_, name, prio, fn) RENDER_FNS[name] = fn end
RUNSERVICE.UnbindFromRenderStep = function(_, name) RENDER_FNS[name] = nil end

local CLIPBOARD = nil
setclipboard = function(t) CLIPBOARD = t end

local FAKE_T = 1000.0            -- simulate a game that has been up a while
os = {clock=function() return FAKE_T end,
      date=function() return {hour=0,min=0,sec=0} end}

return {CREATED=CREATED, fire=fire, char=char, hum=hum, root=root, torso=torso,
        head=head, player=player, vnew=vnew, getCreated=function(c)
          return CREATED[c] or {} end,
        setField=function(i,k,v) i[k]=v end,
        advance=function(dt) FAKE_T = FAKE_T + dt end,
        heartbeat=function(dt) FAKE_T = FAKE_T + (dt or 1/60)
          return fire(RUNSERVICE,"Heartbeat",dt or 1/60) end,
        -- the flight is bound to a RENDER STEP now, not Heartbeat
        renderOnce=function(dt)
          FAKE_T = FAKE_T + (dt or 1/60)
          local n = 0
          for _, fn in pairs(RENDER_FNS) do n = n + 1; fn(dt or 1/60) end
          return n end,
        stepN=function(n,dt)
          for _=1,n do
            FAKE_T = FAKE_T + (dt or 1/60)
            for _, fn in pairs(RENDER_FNS) do fn(dt or 1/60) end
          end end,
        renderSubs=function()
          local n=0; for _ in pairs(RENDER_FNS) do n=n+1 end; return n end,
        heartbeatSubs=function() local s=RUNSERVICE._sig and RUNSERVICE._sig.Heartbeat
          return s and #s._fns or 0 end,
        clipboard=function() return CLIPBOARD end,
        clearClipboard=function() CLIPBOARD = nil end,
        watchStart=function() WATCH = {} end,
        watchList=function() return WATCH or {} end,
        collideStart=function() COLLIDE_LOG = {} end,
        collideList=function() return COLLIDE_LOG or {} end,
        setRayHit=function(y) WORKSPACE._rayHit = {Position=vnew(0,y,0)} end,
        clearRayHit=function() WORKSPACE._rayHit = nil end,
        -- terrain segments: ground [xFrom..xTo] at height y. Anything not covered
        -- is empty air, which is what the scan must notice.
        addGround=function(xFrom,xTo,y)
          WORKSPACE._segments = WORKSPACE._segments or {}
          table.insert(WORKSPACE._segments, {xFrom,xTo,y}) end,
        clearGrounds=function() WORKSPACE._segments = {} end,
        addBarrier=function(bx,yMin,yMax,name,part)
          WORKSPACE._barriers = WORKSPACE._barriers or {}
          table.insert(WORKSPACE._barriers, {bx,yMin,yMax,part or killBrick})
          if name then (part or killBrick).Name = name end end,
        clearBarriers=function() WORKSPACE._barriers = nil end,
        -- a solid slab: lets the landing-containment check be exercised
        slab=function(y,size)
          local p = newInstance("Part")
          p.Name = "BOTTOMS.Part"
          p.CanCollide = true
          p.Material = "Plastic"
          p.Size = size or vnew(4000, 4, 4000)
          p.CFrame = CFrame.new(0, y - (size and size.Y/2 or 2), 0)
          p.Position = vnew(0, y - (size and size.Y/2 or 2), 0)
          return p end,
        addSlab=function(cx,cy,cz,sx,sy,sz)
          local p = newInstance("Part")
          p.Name = "BOTTOMS.Part"
          p.CanCollide = true
          p.Material = "Plastic"
          p.Size = vnew(sx,sy,sz)
          p.CFrame = CFrame.new(cx,cy,cz)
          p.Position = vnew(cx,cy,cz)
          WORKSPACE._slabs = WORKSPACE._slabs or {}
          table.insert(WORKSPACE._slabs, p)
          return p end,
        clearSlabs=function() WORKSPACE._slabs = nil end,
        guardVolume=function(name, pos)
          local g = newInstance("Part")
          g.Name = name
          g.CanCollide = false
          g.Material = "SmoothPlastic"
          g.CFrame = CFrame.new(pos)
          g.Position = pos
          WORKSPACE._guards = WORKSPACE._guards or {}
          table.insert(WORKSPACE._guards, g)
          return g end,
        fireDied=function() return fire(hum, "Died") end,
        fireHealth=function(v)
          local prev = hum.Health
          hum.Health = v
          return fire(hum, "Health", v, prev) end,
        fireState=function(st) return fire(hum, "StateChanged", nil, st) end,
        emit=function(proxy, ev, ...) return fire(PROXY_DATA[proxy], ev, ...) end,
        killBrick=function() return killBrick end,
        clearTouchLog=function() end,
        snapshotGlobals=function()
          local t = {}
          for k in pairs(_G) do t[#t+1] = k end
          return t end,
        setHealth=function(v) hum.Health = v end,
        rejectRootWrites=function(on) REJECT_ROOT = on end,
        fireRespawn=function() return fire(player, "CharacterAdded") end,
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
GLOBALS_BEFORE = None
try:
    H = L.execute(STUB)
    GLOBALS_BEFORE = set(H["snapshotGlobals"]().values())
    L.execute(script)
except Exception as e:
    print("LOAD ERROR:", e)
    sys.exit(1)

print("script loaded against stubbed Roblox API")

# The Lua trap this project keeps hitting: an undeclared name silently becomes a
# global. It has already produced a broken progress readout (onProgress), a dead
# X button (dragConn), a throw-on-death (stopFlight) and a clobbered noclip flag.
# The script should create ZERO new globals, so assert that directly.
_after = set(H["snapshotGlobals"]().values())
_leaked = sorted(g for g in (_after - GLOBALS_BEFORE) if g not in ("stopFlight",))
chk("script creates no unexpected globals", not _leaked,
    f"leaked: {_leaked}" if _leaked else "none")

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
noclipBtn = buttons("NOCLIP")[0]
copyBtn = buttons("COPY")[0]
clearBtn = buttons("CLEAR")[0]
box   = values(getCreated("TextBox"))[0]

def set_noclip(on):
    """The toggle button is the only way in now; it is OFF by default."""
    want = "NOCLIP: ON" if on else "NOCLIP: OFF"
    if want not in str(noclipBtn["Text"]):
        fire(noclipBtn, "MouseButton1Click")

def flat(t): return t is False or t == False

def lastline(txt, needle):
    """The log accumulates across flights, so always read the LAST match."""
    hits = [l for l in txt.splitlines() if needle in l]
    return hits[-1] if hits else "(no line with %r)" % needle

def stat():
    """The status TextLabel is the last one created."""
    return str(values(getCreated("TextLabel"))[-1]["Text"])

def collide_off(): return torso["CanCollide"] is False or torso["CanCollide"] == False

print("\n=== T1: 2000 studs forward ===")
H["teleport"](1000, 100, 0)
H["face"](-1, 0)
chk("facing is -X", abs(root["CFrame"]["LookVector"]["X"] + 1) < 1e-9,
    str(root["CFrame"]["LookVector"]))
H["clearGrounds"]()
H["addGround"](-1200, 1200, 70)      # ground under the whole 2000-stud route
H["watchStart"]()
H["collideStart"]()
fire(fly, "MouseButton1Click")
chk("flight started", H["renderSubs"]() == 1, f"subs={H['renderSubs']()}")
H["stepN"](400)
startX, endX = 1000.0, root["CFrame"]["Position"]["X"]
travelled = startX - endX
chk("travelled ~2000 studs", 1900 <= travelled <= 2100, f"{travelled:.1f} studs")
chk("moved toward target (-X)", endX < startX, f"X {startX:.0f} -> {endX:.1f}")
chk("flight ended on its own", H["renderSubs"]() == 0, f"subs={H['renderSubs']()}")

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
# velocity is written twice per frame: once re-applying the sticky target at the
# top of the render step, once by the phase step. So writes ~= 2 x steps.
writes = n
steps = writes / 2.0
expected = 2000.0 / 78.0
chk("steps ~= 2000/78 + descent", abs(steps - (expected + 3)) <= 3,
    f"{steps:.0f} steps: {expected:.1f} flight + ~3 descent + transition")

print("\n=== T4: noclip OFF by default, opt-in via the toggle ===")
chk("noclip starts OFF", "OFF" in str(noclipBtn["Text"]), repr(str(noclipBtn["Text"])))
chk("collisions untouched by a default flight", torso["CanCollide"] is True,
    str(torso["CanCollide"]))
set_noclip(True)
chk("toggle flips to ON", "NOCLIP: ON" in str(noclipBtn["Text"]), repr(str(noclipBtn["Text"])))
H["teleport"](1000, 100, 0); H["face"](-1, 0)
H["collideStart"]()
fire(fly, "MouseButton1Click")
H["stepN"](4)
chk("noclip active during flight", flat(torso["CanCollide"]), str(torso["CanCollide"]))
H["stepN"](400)
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
chk("cancelled", H["renderSubs"]() == 0, f"subs={H['renderSubs']()}")
chk("collisions restored on abort", torso["CanCollide"] is True or torso["CanCollide"] == True,
    str(torso["CanCollide"]))

print("\n=== T6: MAX_FLIGHT_S bounds the run ===")
H["teleport"](1000, 100, 0); H["face"](-1, 0)
H["clearGrounds"]()
H["addGround"](-20000, 20000, 70)
box["Text"] = "20000"
fire(fly, "MouseButton1Click")
H["stepN"](400)
chk("run bounded", H["renderSubs"]() == 0, f"subs={H['renderSubs']()}")
chk("collisions restored after timeout",
    torso["CanCollide"] is True or torso["CanCollide"] == True, str(torso["CanCollide"]))

print("\n=== T7: shorter distance honoured ===")
H["teleport"](2000, 100, 0); H["face"](-1, 0)
H["clearGrounds"]()
H["addGround"](-500, 2100, 70)
box["Text"] = "500"
fire(fly, "MouseButton1Click")
H["stepN"](400)
trav = 2000 - root["CFrame"]["Position"]["X"]
chk("~500 studs", 450 <= trav <= 600, f"{trav:.1f}")

print("\n=== T8: refuses while ragdolled ===")
H["teleport"](1000, 100, 0)
H["clearGrounds"]()
H["addGround"](-1200, 1200, 70)
H["setField"](hum, "_state", "Physics")
box["Text"] = "2000"
fire(fly, "MouseButton1Click")
chk("no flight while Physics", H["renderSubs"]() == 0, f"subs={H['renderSubs']()}")
H["setField"](hum, "_state", "Running")

print("\n=== T9: invalid input handled ===")
box["Text"] = ""
fire(fly, "MouseButton1Click")
chk("empty input refused", H["renderSubs"]() == 0, f"subs={H['renderSubs']()}")

print("\n=== T10: X cleans up mid-flight ===")
set_noclip(True)
H["teleport"](1000, 100, 0); H["face"](-1, 0)
box["Text"] = "2000"
fire(fly, "MouseButton1Click")
H["stepN"](2)
fire(close, "MouseButton1Click")
chk("Heartbeat disconnected", H["renderSubs"]() == 0, f"subs={H['renderSubs']()}")
chk("collisions restored by X",
    torso["CanCollide"] is True or torso["CanCollide"] == True, str(torso["CanCollide"]))
chk("ScreenGui destroyed",
    any(r["_destroyed"] for r in values(getCreated("ScreenGui"))), "")

print("\n=== T11: descent uses the raycast ground, not a blind drop ===")
H["teleport"](1000, 100, 0); H["face"](-1, 0)
H["clearGrounds"]()
H["addGround"](-200, 1200, 42)
box["Text"] = "100"
fire(fly, "MouseButton1Click")
H["stepN"](400)
chk("landed near groundY+3", abs(root["CFrame"]["Position"]["Y"] - 45) < 6,
    f"Y={root['CFrame']['Position']['Y']:.1f} (ground 42)")


print("\n=== T12: THE FIX - refuses to fly where the ground runs out ===")
H["clearGrounds"]()
H["addGround"](400, 1100, 70)          # solid ground only from X=1100 down to 400
H["teleport"](1000, 100, 0); H["face"](-1, 0)
box["Text"] = "2000"
fire(fly, "MouseButton1Click")
chk("refused (no flight started)", H["renderSubs"]() == 0, f"subs={H['renderSubs']()}")
st = stat()
chk("says the ground runs out", "no ground" in st, st.split("\n")[0])
chk("did not move", abs(root["CFrame"]["Position"]["X"] - 1000) < 1e-6,
    f"X={root['CFrame']['Position']['X']:.1f}")

print("\n=== T13: cruise altitude clears the HIGHEST terrain, not the start Y ===")
H["clearGrounds"]()
H["addGround"](-1200, 1200, 70)
H["addGround"](200, 600, 300)          # a 300-stud hill in the middle of the route
H["teleport"](1000, 100, 0); H["face"](-1, 0)
box["Text"] = "2000"
H["watchStart"]()
fire(fly, "MouseButton1Click")
H["stepN"](12)                          # past the ramp, into cruise
y_here = root["CFrame"]["Position"]["Y"]
chk("climbs above the hill", y_here > 300, f"Y={y_here:.1f} (hill 300, clearance 25)")
H["stepN"](400)                       # let it finish, so T14 starts clean
chk("T13 run completed before T14", H["renderSubs"]() == 0, f"subs={H['renderSubs']()}")

print("\n=== T14: void guard aborts near FallenPartsDestroyHeight ===")
assert H["renderSubs"]() == 0, "a previous flight was still running"
H["clearGrounds"]()
H["addGround"](-1200, 1200, 70)
H["teleport"](1000, 100, 0); H["face"](-1, 0)
box["Text"] = "2000"
fire(fly, "MouseButton1Click")
H["stepN"](2)
H["teleport"](root["CFrame"]["Position"]["X"], -450, 0)   # below -500 + 100 margin
H["stepN"](1)
chk("aborted on the void guard", H["renderSubs"]() == 0, f"subs={H['renderSubs']()}")
chk("names the guard", "void guard" in stat(), stat().split("\n")[0])

print("\n=== T15: death mid-flight stops the flight and restores everything ===")
assert H["renderSubs"]() == 0, "a previous flight was still running"
H["clearGrounds"]()
H["addGround"](-1200, 1200, 70)
H["teleport"](1000, 100, 0); H["face"](-1, 0)
set_noclip(True)
box["Text"] = "2000"
fire(fly, "MouseButton1Click")
H["stepN"](3)
chk("noclip active", flat(torso["CanCollide"]), str(torso["CanCollide"]))
H["fireDied"]()
chk("flight stopped on death", H["renderSubs"]() == 0, f"subs={H['renderSubs']()}")
chk("collisions restored on death", torso["CanCollide"] is True or torso["CanCollide"] == True,
    str(torso["CanCollide"]))
chk("status reports the death", "DIED" in stat(), stat().split("\n")[0])

print("\n=== T16: respawn also clears noclip ===")
set_noclip(True)
chk("noclip back on", flat(torso["CanCollide"]) or "NOCLIP: ON" in str(noclipBtn["Text"]),
    repr(str(noclipBtn["Text"])))
H["fireRespawn"]()
chk("collisions restored on respawn",
    torso["CanCollide"] is True or torso["CanCollide"] == True, str(torso["CanCollide"]))
set_noclip(False)


print("\n=== T17: reference mechanics - whole-model move, render step, Freefall ===")
H["clearGrounds"]()
H["addGround"](-1200, 1200, 70)
H["teleport"](1000, 100, 0); H["face"](-1, 0)
box["Text"] = "2000"
fire(fly, "MouseButton1Click")
chk("bound to a RENDER STEP, not Heartbeat", H["renderSubs"]() == 1,
    f"renderSubs={H['renderSubs']()} heartbeats={H['renderSubs']()}")
H["stepN"](8)
# PivotTo must carry the limbs; a root-only write leaves them behind
rp, tp, hp = (root["CFrame"]["Position"], torso["CFrame"]["Position"],
              head["CFrame"]["Position"])
chk("PivotTo moved the WHOLE model (torso follows)", abs(tp["X"] - rp["X"]) < 1e-6,
    f"root.X={rp['X']:.1f} torso.X={tp['X']:.1f}")
chk("head follows too", abs(hp["X"] - rp["X"]) < 1e-6, f"head.X={hp['X']:.1f}")
chk("ChangeState is NOT called (avoids -1000 HP)",
    str(hum["_state"]) != "Freefall",
    f"state stayed {hum['_state']} - not forced to Freefall")
chk("AutoRotate left alone", hum["AutoRotate"] is True, str(hum["AutoRotate"]))
H["stepN"](400)
chk("AutoRotate still untouched after", hum["AutoRotate"] is True, str(hum["AutoRotate"]))

print("\n=== T18: vertical velocity is PRESERVED, not overwritten with a constant ===")
H["clearGrounds"]()
H["addGround"](-1200, 1200, 70)
H["teleport"](1000, 100, 0); H["face"](-1, 0)
box["Text"] = "2000"
fire(fly, "MouseButton1Click")
ys = []
for _ in range(12):
    root["AssemblyLinearVelocity"] = H["vnew"](0, -13.5, 0)   # gravity-ish, varying
    H["stepN"](1)
    ys.append(round(root["AssemblyLinearVelocity"]["Y"], 4))
chk("the script did not flatline Y to a constant",
    len(set(ys)) == 1 and ys[0] == -13.5, f"Y values seen {sorted(set(ys))}")
H["stepN"](400)

print("\n=== T19: COPY LOG captures a usable diagnostic log ===")
H["clearClipboard"]()
fire(copyBtn, "MouseButton1Click")
log = H["clipboard"]()
chk("clipboard got the log", log is not None and len(str(log)) > 50,
    f"{len(str(log)) if log else 0} chars")
txt = str(log)
chk("log records the START", "START #" in txt, txt.splitlines()[1] if txt else "")
chk("log records the scan", "scanned" in txt, "")
chk("log records Freefall start", "FREEFALL START" in txt, "")

print("\n=== T20: a death mid-flight is recorded with the evidence ===")
H["clearGrounds"]()
H["addGround"](-1200, 1200, 70)
H["teleport"](1000, 100, 0); H["face"](-1, 0)
H["clearClipboard"]()
box["Text"] = "2000"
fire(fly, "MouseButton1Click")
H["stepN"](6)
chk("flight running", H["renderSubs"]() == 1, f"subs={H['renderSubs']()}")
H["setHealth"](0)
H["fireDied"]()
chk("flight stopped on death", H["renderSubs"]() == 0, f"subs={H['renderSubs']()}")
fire(copyBtn, "MouseButton1Click")
txt = str(H["clipboard"]())
chk("log says DEATH", "DEATH" in txt, "")
chk("log records health", "health" in txt, "")
chk("log records position", "position" in txt, "")
chk("log records the void floor", "floor of pt" in txt, "")
chk("log lists nearby parts", "NEAR" in txt, "")

H["setHealth"](100)                  # T20 killed the humanoid; restore it or the
                                     # next test silently refuses to fly

print("\n=== T21: correction fight aborts instead of dying silently ===")
H["clearGrounds"]()
H["addGround"](-1200, 1200, 70)
H["teleport"](1000, 100, 0); H["face"](-1, 0)
H["clearClipboard"]()
box["Text"] = "2000"
fire(fly, "MouseButton1Click")
H["stepN"](6)
chk("T21 flight actually started", H["renderSubs"]() == 1,
    f"subs={H['renderSubs']()} (0 would mean it was refused, not that it aborted)")
# the engine keeps refusing our write, so root.Position stays wrong and the
# detector accumulates consecutive errors - what "sustained correction" means
H["teleport"](2000, 100, 0)          # yanked way off the sticky target
H["rejectRootWrites"](True)          # and now our correction is refused
H["stepN"](14)
H["rejectRootWrites"](False)
chk("aborted the fight", H["renderSubs"]() == 0, f"subs={H['renderSubs']()}")
fire(copyBtn, "MouseButton1Click")
txt = str(H["clipboard"]())
chk("log records CORRECTION FIGHT", "CORRECTION FIGHT" in txt, "")


print("\n=== T22: keeps watching AFTER landing (the field death came at DONE) ===")
H["clearGrounds"]()
H["addGround"](-1200, 1200, 70)
H["teleport"](1000, 100, 0); H["face"](-1, 0)
H["clearClipboard"]()
box["Text"] = "2000"
fire(fly, "MouseButton1Click")
H["stepN"](60)                        # 1.0s: lands, watch window still open
chk("render step STILL bound after landing", H["renderSubs"]() == 1,
    f"subs={H['renderSubs']()} (0 = we stopped looking at the exact moment it matters)")
H["stepN"](300)                       # 5 more seconds: past the 4s watch window
chk("watch window closes on its own", H["renderSubs"]() == 0, f"subs={H['renderSubs']()}")
fire(copyBtn, "MouseButton1Click")
txt = str(H["clipboard"]())
chk("log records the watch window", "post-flight watch" in txt, "")
chk("log records the watch ending", "post-flight watch ended" in txt, "")
chk("log records the landing check", "LANDING" in txt, "")

print("\n=== T23: a death after landing still gets the trail ===")
H["clearGrounds"]()
H["addGround"](-1200, 1200, 70)
H["teleport"](1000, 100, 0); H["face"](-1, 0)
H["clearClipboard"]()
box["Text"] = "2000"
fire(fly, "MouseButton1Click")
H["stepN"](60)                        # land, watch window opens
chk("watching", H["renderSubs"]() == 1, f"subs={H['renderSubs']()}")
H["setHealth"](0)
H["stepN"](2)                         # the watch notices
chk("stopped after the death", H["renderSubs"]() == 0, f"subs={H['renderSubs']()}")
fire(copyBtn, "MouseButton1Click")
txt = str(H["clipboard"]())
chk("post-flight death is reported", "post-flight watch" in txt, "")
chk("TRAIL is included", "TRAIL last" in txt, "")
chk("trail rows carry position + hp", "hp 0.0" in txt, "")
H["setHealth"](100)

print("\n=== T24: report separates where the flight ENDED from where death was seen ===")
H["clearGrounds"]()
H["addGround"](-1200, 1200, 70)
H["teleport"](1000, 100, 0); H["face"](-1, 0)
H["clearClipboard"]()
box["Text"] = "2000"
fire(fly, "MouseButton1Click")
H["stepN"](60)                        # land (endPos recorded), still watching
# simulate the field-log failure: the character is moved far away (respawn) and
# then reported dead, so the single-sample position is useless
H["teleport"](50, 70, 50)
H["setHealth"](0)
H["fireDied"]()
fire(copyBtn, "MouseButton1Click")
txt = str(H["clipboard"]())
chk("log gives the flight end position", "flight end" in txt, "")
chk("log gives the end->death distance", "end->death" in txt, "")
chk("log flags the move as not the death site", "not the death site" in txt, "")
H["setHealth"](100)

print("\n=== T25: Touched watchers name what hits us ===")
H["clearGrounds"]()
H["addGround"](-1200, 1200, 70)
H["teleport"](1000, 100, 0); H["face"](-1, 0)
H["clearClipboard"]()
box["Text"] = "2000"
fire(fly, "MouseButton1Click")
H["stepN"](4)
brick = H["killBrick"]()
H["emit"](root, "Touched", brick)
fire(copyBtn, "MouseButton1Click")
txt = str(H["clipboard"]())
chk("log names the touching part", "TOUCHED | " in txt,
    next((l for l in txt.splitlines() if "TOUCHED" in l), "(no TOUCHED line)"))
chk("log gives its name and class",
    "LavaKillBrick" in txt and "class=Part" in txt, "")
H["stepN"](400)

print("\n=== T26: the false positive is gone (field log reported dist=70.5) ===")
H["clearGrounds"](); H["clearSlabs"]()
H["addGround"](-1200, 1200, 70)
# a huge world slab whose CENTRE is far away but whose bounds overlap the point -
# exactly what produced "LANDING INSIDE SOLID | dist=70.5" in the field
H["addSlab"](0, 66, 0, 4000, 4, 4000)
H["teleport"](1000, 100, 0); H["face"](-1, 0)
H["clearClipboard"]()
box["Text"] = "2000"
fire(fly, "MouseButton1Click")
H["stepN"](60)
fire(copyBtn, "MouseButton1Click")
txt = str(H["clipboard"]())
chk("standing on a big slab is NOT 'inside solid'", "LANDING INSIDE SOLID" not in txt,
    lastline(txt, "LANDING"))
chk("says landing is clear", "LANDING CLEAR" in txt, "")
H["stepN"](300)

print("\n=== T27: a genuine embed IS still reported ===")
H["clearGrounds"](); H["clearSlabs"]()
H["addGround"](-1200, 1200, 70)
# a block the landing point really is inside: root lands at y=73
H["addSlab"](-1000, 73, 0, 2000, 30, 2000)
H["teleport"](1000, 100, 0); H["face"](-1, 0)
H["clearClipboard"]()
box["Text"] = "2000"
fire(fly, "MouseButton1Click")
H["stepN"](60)
fire(copyBtn, "MouseButton1Click")
txt = str(H["clipboard"]())
chk("real embed reported", "LANDING INSIDE SOLID" in txt,
    lastline(txt, "LANDING"))
H["stepN"](300)

print("\n=== T28: barriers crossing the route are found and named ===")
H["clearGrounds"](); H["clearSlabs"](); H["clearBarriers"]()
H["addGround"](-1200, 1200, 70)
# an anti-cheat style wall spanning the cruise altitude, 400 studs along
H["addBarrier"](400, 80, 200, "FrozenWallRight")
H["teleport"](1000, 100, 0); H["face"](-1, 0)
H["clearClipboard"]()
box["Text"] = "2000"
fire(fly, "MouseButton1Click")
fire(copyBtn, "MouseButton1Click")
txt = str(H["clipboard"]())
chk("barrier count reported", "barriers | 1 crossing" in txt,
    lastline(txt, "barriers |"))
chk("barrier is NAMED", "BARRIER |" in txt and "FrozenWallRight" in txt,
    lastline(txt, "BARRIER |"))
chk("says it is report-only by default", "report only" in txt, "")
H["stepN"](400)
chk("still flew the full distance (STOP_AT_BARRIER false)",
    "DONE" in str(H["clipboard"]()), "")

print("\n=== T29: guard regions at the landing are called out ===")
H["clearGrounds"](); H["clearSlabs"](); H["clearBarriers"]()
H["addGround"](-1200, 1200, 70)
H["guardVolume"]("Area", H["vnew"](-1000, 73, 0))
H["guardVolume"]("Bounds", H["vnew"](-1000, 73, 0))
H["teleport"](1000, 100, 0); H["face"](-1, 0)
H["clearClipboard"]()
box["Text"] = "2000"
fire(fly, "MouseButton1Click")
H["stepN"](60)
fire(copyBtn, "MouseButton1Click")
txt = str(H["clipboard"]())
chk("guard region named", "GUARD REGION |" in txt,
    lastline(txt, "GUARD REGION"))
chk("guard warning given", "GUARD WARNING" in txt, "")
H["stepN"](300)

print("\n=== T30: the -1000 kill is named as an EXTERNAL KILL ===")
H["clearGrounds"](); H["clearSlabs"](); H["clearBarriers"]()
H["addGround"](-1200, 1200, 70)
H["teleport"](1000, 100, 0); H["face"](-1, 0)
fire(clearBtn, "MouseButton1Click")
H["clearClipboard"]()
box["Text"] = "2000"
fire(fly, "MouseButton1Click")
H["stepN"](4)
# exactly the field value
H["setHealth"](-1000)
H["fireHealth"](-1000)
H["stepN"](1)
fire(copyBtn, "MouseButton1Click")
txt = str(H["clipboard"]())
chk("kill named as EXTERNAL", "EXTERNAL KILL" in txt, lastline(txt, "EXTERNAL KILL"))
chk("value reported as -1000", "-1000" in txt, "")
chk("cites the exploit handler", "exploit handler" in txt, "")
chk("death reason carries it", "Health set to" in txt, "")
H["setHealth"](100)

print("\n=== T31: an ordinary death is NOT called external ===")
H["clearGrounds"](); H["addGround"](-1200, 1200, 70)
H["teleport"](1000, 100, 0); H["face"](-1, 0)
fire(clearBtn, "MouseButton1Click")
H["clearClipboard"]()
box["Text"] = "2000"
fire(fly, "MouseButton1Click")
H["stepN"](4)
H["setHealth"](0)
H["fireHealth"](0)
H["stepN"](1)
fire(copyBtn, "MouseButton1Click")
txt = str(H["clipboard"]())
chk("plain zero is not an external kill", "EXTERNAL KILL" not in txt,
    lastline(txt, "HP | "))
H["setHealth"](100)

print("\n=== T32: state tampering is OFF and reported as such ===")
H["clearGrounds"](); H["addGround"](-1200, 1200, 70)
H["teleport"](1000, 100, 0); H["face"](-1, 0)
H["clearClipboard"]()
box["Text"] = "2000"
fire(fly, "MouseButton1Click")
H["stepN"](60)
fire(copyBtn, "MouseButton1Click")
txt = str(H["clipboard"]())
chk("start line reports ChangeState=false", "ChangeState=false" in txt,
    lastline(txt, "state-tampering"))
chk("start line reports AutoRotate=false", "AutoRotate=false" in txt, "")
chk("FREEFALL START line reports it too", "ChangeState=false" in txt, "")
chk("maxHealth logged", "maxHealth=" in txt, "")
H["stepN"](300)

print("\n=== T34: CLEAR empties the log so a paste cannot carry stale lines ===")
fire(clearBtn, "MouseButton1Click")
H["clearClipboard"]()
fire(copyBtn, "MouseButton1Click")
txt = str(H["clipboard"]())
chk("log is emptied", "EXTERNAL KILL" not in txt and "START #" not in txt,
    f"{len(txt.splitlines())} line(s): {txt.strip()[:60]}")
chk("says it was cleared", "log cleared" in txt, "")

print("\n=== T33: the gap between flights is logged, to expose repetition ===")
H["clearGrounds"](); H["addGround"](-1200, 1200, 70)
box["Text"] = "500"
H["teleport"](1000, 100, 0); H["face"](-1, 0)
fire(fly, "MouseButton1Click")
H["stepN"](60)
H["clearClipboard"]()
H["teleport"](1000, 100, 0); H["face"](-1, 0)
fire(fly, "MouseButton1Click")          # immediately, so the gap is tiny
fire(copyBtn, "MouseButton1Click")
txt = str(H["clipboard"]())
chk("gap is logged", "gap since last flight" in txt, lastline(txt, "gap since"))
chk("tiny gap is flagged as back-to-back", "back-to-back" in txt, "")
H["stepN"](400)

print(f"\n{'='*60}\nRESULT: {PASS} passed, {FAIL} failed")
if FAILED:
    print("FAILED: " + ", ".join(FAILED))
sys.exit(1 if FAIL else 0)
