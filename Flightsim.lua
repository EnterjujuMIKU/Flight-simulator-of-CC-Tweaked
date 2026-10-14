-- flight.lua : simulation 3D filaire pour CC: Tweaked
-- Terrain en quadrillage + avion qui suit une boucle ultra fluide
-- Ordinateur avance (gold) recommande, ou moniteur branche (rendu plus fin).
-- Touche Q pour quitter.

---------------------------------------------------------------------
-- Affichage (terminal ou moniteur) + framebuffer
---------------------------------------------------------------------
local out = peripheral.find("monitor")
if out then out.setTextScale(0.5) else out = term.current() end
local W, H = out.getSize()
local win = window.create(out, 1, 1, W, H, false)

local hex = {}
for name, c in pairs(colors) do
  if type(c) == "number" then hex[name] = colors.toBlit(c) end
end

local SKY    = hex.lightBlue
local fb = {}
for y = 1, H do fb[y] = {} end

local function clearFb()
  for y = 1, H do
    local row = fb[y]
    for x = 1, W do row[x] = SKY end
  end
end

local function present()
  local txt = string.rep(" ", W)
  local fg  = string.rep("0", W)
  for y = 1, H do
    win.setCursorPos(1, y)
    win.blit(txt, fg, table.concat(fb[y]))
  end
end

---------------------------------------------------------------------
-- Dessin de lignes 2D (clipping Liang-Barsky + Bresenham)
---------------------------------------------------------------------
local P, Q = {0, 0, 0, 0}, {0, 0, 0, 0}
local floor = math.floor

local function line2d(x0, y0, x1, y1, c)
  local dx, dy = x1 - x0, y1 - y0
  P[1], P[2], P[3], P[4] = -dx, dx, -dy, dy
  Q[1], Q[2], Q[3], Q[4] = x0 - 1, W - x0, y0 - 1, H - y0
  local t0, t1 = 0, 1
  for i = 1, 4 do
    local p, q = P[i], Q[i]
    if p == 0 then
      if q < 0 then return end
    else
      local r = q / p
      if p < 0 then
        if r > t1 then return end
        if r > t0 then t0 = r end
      else
        if r < t0 then return end
        if r < t1 then t1 = r end
      end
    end
  end
  local ax, ay = floor(x0 + t0 * dx + 0.5), floor(y0 + t0 * dy + 0.5)
  local bx, by = floor(x0 + t1 * dx + 0.5), floor(y0 + t1 * dy + 0.5)
  local sx = ax < bx and 1 or -1
  local sy = ay < by and 1 or -1
  local adx, ady = math.abs(bx - ax), math.abs(by - ay)
  local err = adx - ady
  while true do
    if ax >= 1 and ax <= W and ay >= 1 and ay <= H then fb[ay][ax] = c end
    if ax == bx and ay == by then break end
    local e2 = 2 * err
    if e2 > -ady then err = err - ady; ax = ax + sx end
    if e2 < adx then err = err + adx; ay = ay + sy end
  end
end

---------------------------------------------------------------------
-- Camera + projection
---------------------------------------------------------------------
local FOV     = math.rad(70)
local FOCAL   = (W / 2) / math.tan(FOV / 2)
local ASPECT  = 0.6          -- une cellule de texte est plus haute que large
local NEAR    = 0.3
local FAR     = 110

local cam = { x = 0, y = 0, z = 0, rx = 1, ry = 0, rz = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1 }

local function normalize(x, y, z)
  local l = math.sqrt(x * x + y * y + z * z)
  if l == 0 then return 0, 0, 1 end
  return x / l, y / l, z / l
end

local function cross(ax, ay, az, bx, by, bz)
  return ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
end

local function lookAt(tx, ty, tz)
  local fx, fy, fz = normalize(tx - cam.x, ty - cam.y, tz - cam.z)
  local rx, ry, rz = normalize(cross(0, 1, 0, fx, fy, fz))
  local ux, uy, uz = cross(fx, fy, fz, rx, ry, rz)
  cam.fx, cam.fy, cam.fz = fx, fy, fz
  cam.rx, cam.ry, cam.rz = rx, ry, rz
  cam.ux, cam.uy, cam.uz = ux, uy, uz
end

-- monde -> espace camera
local function toCam(x, y, z)
  local dx, dy, dz = x - cam.x, y - cam.y, z - cam.z
  return dx * cam.rx + dy * cam.ry + dz * cam.rz,
         dx * cam.ux + dy * cam.uy + dz * cam.uz,
         dx * cam.fx + dy * cam.fy + dz * cam.fz
end

local cx, cy = W / 2, H / 2
local function drawCamLine(ax, ay, az, bx, by, bz, c)
  -- clipping sur le plan proche
  if az < NEAR and bz < NEAR then return end
  if az < NEAR then
    local t = (NEAR - az) / (bz - az)
    ax, ay, az = ax + (bx - ax) * t, ay + (by - ay) * t, NEAR
  elseif bz < NEAR then
    local t = (NEAR - bz) / (az - bz)
    bx, by, bz = bx + (ax - bx) * t, by + (ay - by) * t, NEAR
  end
  local x0 = cx + ax / az * FOCAL
  local y0 = cy - ay / az * FOCAL * ASPECT
  local x1 = cx + bx / bz * FOCAL
  local y1 = cy - by / bz * FOCAL * ASPECT
  line2d(x0, y0, x1, y1, c)
end

local function drawWorldLine(x0, y0, z0, x1, y1, z1, c)
  local ax, ay, az = toCam(x0, y0, z0)
  local bx, by, bz = toCam(x1, y1, z1)
  drawCamLine(ax, ay, az, bx, by, bz, c)
end

---------------------------------------------------------------------
-- Terrain
---------------------------------------------------------------------
local function terrainH(x, z)
  local h = 8 * math.sin(x * 0.05) * math.cos(z * 0.06)
          + 5 * math.sin(x * 0.11 + z * 0.07)
          + 3 * math.cos(z * 0.13 - x * 0.04)
  if h < -3 then h = -3 end      -- niveau de l'eau
  return h
end

local function heightColor(h)
  if h <= -3 then return hex.blue
  elseif h < 2 then return hex.green
  elseif h < 7 then return hex.lime
  elseif h < 11 then return hex.brown
  else return hex.white end
end

local STEP, N = 8, 11
local SIDE = 2 * N + 1
local vx, vy, vz, vh = {}, {}, {}, {}

local function drawTerrain()
  local gx0 = floor(cam.x / STEP)
  local gz0 = floor(cam.z / STEP)
  local k = 0
  for i = -N, N do
    local wx = (gx0 + i) * STEP
    for j = -N, N do
      local wz = (gz0 + j) * STEP
      local h = terrainH(wx, wz)
      k = k + 1
      vx[k], vy[k], vz[k] = toCam(wx, h, wz)
      vh[k] = h
    end
  end
  for i = 0, SIDE - 1 do
    for j = 0, SIDE - 1 do
      local a = i * SIDE + j + 1
      local az = vz[a]
      local col = heightColor(vh[a])
      if j < SIDE - 1 then
        local b = a + 1
        if az < FAR or vz[b] < FAR then
          drawCamLine(vx[a], vy[a], az, vx[b], vy[b], vz[b], col)
        end
      end
      if i < SIDE - 1 then
        local b = a + SIDE
        if az < FAR or vz[b] < FAR then
          drawCamLine(vx[a], vy[a], az, vx[b], vy[b], vz[b], col)
        end
      end
    end
  end
end

---------------------------------------------------------------------
-- Avion (modele filaire)
---------------------------------------------------------------------
local V = {
  {0, 0, 3.5},    -- 1 nez
  {0, 0, -3},     -- 2 queue
  {-4, 0, -1},    -- 3 bout aile G
  {4, 0, -1},     -- 4 bout aile D
  {0, 0, 1},      -- 5 avant aile
  {0, 0, -1.2},   -- 6 arriere aile
  {-1.8, 0, -3},  -- 7 stab G
  {1.8, 0, -3},   -- 8 stab D
  {0, 0, -2.2},   -- 9 base stab
  {0, 1.8, -3},   -- 10 derive
}
local E = {
  {1, 2, "white"}, {5, 3, "red"}, {3, 6, "red"}, {6, 4, "red"}, {4, 5, "red"},
  {9, 7, "red"}, {9, 8, "red"}, {7, 2, "red"}, {8, 2, "red"},
  {2, 10, "white"}, {10, 9, "white"},
}

local plane = { x = 0, y = 0, z = 0, fx = 0, fy = 0, fz = 1, bank = 0 }

local function drawPlane()
  local rx, ry, rz = normalize(cross(0, 1, 0, plane.fx, plane.fy, plane.fz))
  local ux, uy, uz = cross(plane.fx, plane.fy, plane.fz, rx, ry, rz)
  local cb, sb = math.cos(plane.bank), math.sin(plane.bank)
  local Rx, Ry, Rz = rx * cb + ux * sb, ry * cb + uy * sb, rz * cb + uz * sb
  local Ux, Uy, Uz = ux * cb - rx * sb, uy * cb - ry * sb, uz * cb - rz * sb

  local w = {}
  for i, v in ipairs(V) do
    local lx, ly, lz = v[1], v[2], v[3]
    local wx = plane.x + Rx * lx + Ux * ly + plane.fx * lz
    local wy = plane.y + Ry * lx + Uy * ly + plane.fy * lz
    local wz = plane.z + Rz * lx + Uz * ly + plane.fz * lz
    local a, b, c = toCam(wx, wy, wz)
    w[i] = { a, b, c }
  end
  for _, e in ipairs(E) do
    local p, q = w[e[1]], w[e[2]]
    drawCamLine(p[1], p[2], p[3], q[1], q[2], q[3], hex[e[3]])
  end

  -- ombre au sol
  local gh = terrainH(plane.x, plane.z)
  local s = 2.5
  drawWorldLine(plane.x - s, gh + 0.2, plane.z, plane.x + s, gh + 0.2, plane.z, hex.gray)
  drawWorldLine(plane.x, gh + 0.2, plane.z - s, plane.x, gh + 0.2, plane.z + s, hex.gray)
end

---------------------------------------------------------------------
-- Trajectoire : spline fermee (Catmull-Rom) passant par des points
---------------------------------------------------------------------
-- Choisis le mode :
--   "infinity"  -> boucle en forme de 8 / signe infini (lemniscate)
--   "waypoints" -> boucle irreguliere definie par tes propres points
local PATH_MODE = "infinity"
-- local PATH_MODE = "waypoints"

local SPEED = 22

local WAYPOINTS = {
  {   0, 30,    0 },
  {  70, 38,   40 },
  { 130, 28,  -10 },
  { 150, 45,  -80 },
  {  60, 32, -130 },
  { -40, 26,  -90 },
  {-110, 40,  -30 },
  { -70, 30,   50 },
}

local function lemniscate(n, a, base, amp)
  local pts = {}
  for i = 0, n - 1 do
    local t = 2 * math.pi * i / n
    local d = 1 + math.sin(t) ^ 2
    pts[#pts + 1] = {
      a * math.cos(t) / d,
      base + amp * math.sin(t),
      a * math.sin(t) * math.cos(t) / d * 1.6,
    }
  end
  return pts
end

local PTS
if PATH_MODE == "waypoints" then
  PTS = WAYPOINTS
else
  PTS = lemniscate(20, 140, 32, 9)
end

local function cr(a, b, c, d, f)
  local f2, f3 = f * f, f * f * f
  local pos = 0.5 * ((2 * b) + (-a + c) * f
            + (2 * a - 5 * b + 4 * c - d) * f2
            + (-a + 3 * b - 3 * c + d) * f3)
  local der = 0.5 * ((-a + c) + 2 * (2 * a - 5 * b + 4 * c - d) * f
            + 3 * (-a + 3 * b - 3 * c + d) * f2)
  return pos, der
end

local function spline(u)
  local n = #PTS
  local i = floor(u)
  local f = u - i
  local p0 = PTS[(i - 1) % n + 1]
  local p1 = PTS[i % n + 1]
  local p2 = PTS[(i + 1) % n + 1]
  local p3 = PTS[(i + 2) % n + 1]
  local x, dx = cr(p0[1], p1[1], p2[1], p3[1], f)
  local y, dy = cr(p0[2], p1[2], p2[2], p3[2], f)
  local z, dz = cr(p0[3], p1[3], p2[3], p3[3], f)
  return x, y, z, dx, dy, dz
end

local M = #PTS * 48
local SU, SL = { [0] = 0 }, { [0] = 0 }
local TOTAL = 0
do
  local n = #PTS
  local px, py, pz = spline(0)
  for k = 1, M do
    local u = n * k / M
    local x, y, z = spline(u)
    TOTAL = TOTAL + math.sqrt((x - px) ^ 2 + (y - py) ^ 2 + (z - pz) ^ 2)
    SU[k], SL[k] = u, TOTAL
    px, py, pz = x, y, z
  end
end

local function pathAt(s)
  s = s % TOTAL
  local lo, hi = 0, M
  while hi - lo > 1 do
    local mid = floor((lo + hi) / 2)
    if SL[mid] <= s then lo = mid else hi = mid end
  end
  local span = SL[hi] - SL[lo]
  local f = span > 0 and (s - SL[lo]) / span or 0
  local u = SU[lo] + (SU[hi] - SU[lo]) * f
  local x, y, z, dx, dy, dz = spline(u)
  dx, dy, dz = normalize(dx, dy, dz)
  return x, y, z, dx, dy, dz
end

local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

local function updatePlane(s, dt)
  local x, y, z, tx, ty, tz = pathAt(s)
  plane.x, plane.y, plane.z = x, y, z
  plane.fx, plane.fy, plane.fz = tx, ty, tz

  local ds = 4
  local _, _, _, t2x, _, t2z = pathAt(s + ds)
  local diff = atan2(t2z, t2x) - atan2(tz, tx)
  while diff > math.pi do diff = diff - 2 * math.pi end
  while diff < -math.pi do diff = diff + 2 * math.pi end
  local target = math.max(-1, math.min(1, diff / ds * 45))
  local k = 1 - math.exp(-dt * 3)
  plane.bank = plane.bank + (target - plane.bank) * k
end

---------------------------------------------------------------------
-- Boucle principale
---------------------------------------------------------------------
local t = 0
do -- initialisation de la camera
  updatePlane(t, 0)
  cam.x = plane.x - plane.fx * 16
  cam.y = plane.y + 5
  cam.z = plane.z - plane.fz * 16
end

local last = os.clock()
local fps, frames, fpsT = 0, 0, last
local timer = os.startTimer(0)

while true do
  local ev, p1 = os.pullEvent()
  if ev == "key" and p1 == keys.q then
    break
  elseif ev == "timer" and p1 == timer then
    local now = os.clock()
    local dt = math.min(now - last, 0.2)
    last = now

    t = t + SPEED * dt
    updatePlane(t, dt)

    local dxw = plane.x - plane.fx * 16
    local dyw = plane.y + 5 - plane.fy * 16
    local dzw = plane.z - plane.fz * 16
    local k = 1 - math.exp(-dt * 4)
    cam.x = cam.x + (dxw - cam.x) * k
    cam.y = cam.y + (dyw - cam.y) * k
    cam.z = cam.z + (dzw - cam.z) * k
    local minY = terrainH(cam.x, cam.z) + 3
    if cam.y < minY then cam.y = minY end
    lookAt(plane.x + plane.fx * 8, plane.y + plane.fy * 8 - 1, plane.z + plane.fz * 8)

    clearFb()
    drawTerrain()
    drawPlane()
    present()

    frames = frames + 1
    if now - fpsT >= 1 then
      fps = frames / (now - fpsT)
      frames, fpsT = 0, now
    end
    win.setBackgroundColor(colors.black)
    win.setTextColor(colors.white)
    win.setCursorPos(1, 1)
    win.write(string.format(" FPS:%.0f  Alt:%d  [Q] quitter ", fps, floor(plane.y)))
    win.setVisible(true)
    win.setVisible(false)

    timer = os.startTimer(0)
  end
end

out.setBackgroundColor(colors.black)
out.setTextColor(colors.white)
out.clear()
out.setCursorPos(1, 1)
