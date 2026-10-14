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
local ASPECT  = 0.6
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
  -- repere local de l'avion avec roulis
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

  local gh = terrainH(plane.x, plane.z)
  local s = 2.5
  drawWorldLine(plane.x - s, gh + 0.2, plane.z, plane.x + s, gh + 0.2, plane.z, hex.gray)
  drawWorldLine(plane.x, gh + 0.2, plane.z - s, plane.x, gh + 0.2, plane.z + s, hex.gray)
end

---------------------------------------------------------------------
-- Trajectoire en boucle (ellipse avec variation d'altitude)
---------------------------------------------------------------------
local RX, RZ = 100, 70
local function path(t)
  return RX * math.cos(t),
         30 + 10 * math.sin(2 * t),
         RZ * math.sin(t)
end

local function pathVel(t)
  return -RX * math.sin(t),
         20 * math.cos(2 * t),
         RZ * math.cos(t)
end

local function pathAcc(t)
  return -RX * math.cos(t),
         -40 * math.sin(2 * t),
         -RZ * math.sin(t)
end

local SPEED = 0.22

local function updatePlane(t, dt)
  plane.x, plane.y, plane.z = path(t)
  local vx_, vy_, vz_ = pathVel(t)
  plane.fx, plane.fy, plane.fz = normalize(vx_, vy_, vz_)

  local ax, _, az = pathAcc(t)
  local h2 = vx_ * vx_ + vz_ * vz_
  local omega = (vx_ * az - vz_ * ax) / h2
  local target = math.max(-1, math.min(1, omega * 0.9 * 4))
  local k = 1 - math.exp(-dt * 3)
  plane.bank = plane.bank + (target - plane.bank) * k
end

---------------------------------------------------------------------
-- Boucle principale
---------------------------------------------------------------------
local t = 0
do
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

    -- camera de poursuite avec lissage exponentiel
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
