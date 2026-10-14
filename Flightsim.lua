-- flight.lua : simulation 3D filaire pour CC: Tweaked
-- * Terrain en quadrillage visible jusqu'a ~1000 blocs (LOD par anneaux)
-- * Suppression des lignes cachees (z-buffer + relief opaque)
-- * Avion sur une boucle en spline (signe infini ou points predefinis)
-- Ordinateur avance (gold) ou moniteur. Touche Q pour quitter.

---------------------------------------------------------------------
-- CONFIG
---------------------------------------------------------------------
local VIEW_DIST  = 200   -- distance de vue (blocs)
local GRID_STEP  = 8      -- taille des mailles proches
local RING_N     = 10     -- mailles par demi-anneau (DOIT etre pair). Baisse a 8 si ca rame
local FOG_DIST   = 250    -- au-dela, les lignes passent en gris
local SUBPIXEL   = true   -- true : 2x3 pixels par caractere (detail x6, plus lourd)
local GRID_DIST  = 250    -- au-dela, plus de lignes : le relief reste visible en silhouette noire

local PATH_MODE  = "infinity"  -- "infinity" ou "waypoints"
local SPEED      = 22          -- vitesse de l'avion (blocs/s)

-- Boucle irreguliere (mode "waypoints") : {x, altitude, z}
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

---------------------------------------------------------------------
-- Affichage (terminal ou moniteur) + framebuffers
---------------------------------------------------------------------
local out = peripheral.find("monitor")
if out then out.setTextScale(0.5) else out = term.current() end
local W, H = out.getSize()
local win = window.create(out, 1, 1, W, H, false)

local hex = {}
for name, c in pairs(colors) do
  if type(c) == "number" then hex[name] = tonumber(colors.toBlit(c), 16) end
end

local SKY    = hex.lightBlue
local GROUND = hex.black
local GRAYC  = hex.gray

local floor, ceil = math.floor, math.ceil

-- Resolution interne : en mode SUBPIXEL chaque caractere = 2x3 pixels
-- (caracteres 128-159), soit 6x plus de details.
local SW, SH = W, H
if SUBPIXEL then SW, SH = W * 2, H * 3 end

local fb, D = {}, {}   -- couleurs (0-15) / profondeur (1/z), en pixels
for y = 1, SH do fb[y] = {}; D[y] = {} end

local function clearBuffers()
  for y = 1, SH do
    local row, drow = fb[y], D[y]
    for x = 1, SW do row[x] = SKY; drow[x] = 0 end
  end
end

-- palette par defaut de CC, pour choisir la couleur la plus proche
local PAL = {
  {240,240,240},{242,178,51},{229,127,216},{153,178,242},{222,222,108},{127,204,25},
  {242,178,204},{76,76,76},{153,153,153},{76,153,178},{178,102,229},{51,102,204},
  {127,102,76},{87,166,78},{204,76,76},{17,17,17},
}
local DIST = {}
for a = 0, 15 do
  DIST[a] = {}
  for b = 0, 15 do
    local pa, pb = PAL[a + 1], PAL[b + 1]
    DIST[a][b] = (pa[1] - pb[1]) ^ 2 + (pa[2] - pb[2]) ^ 2 + (pa[3] - pb[3]) ^ 2
  end
end

local BLC, CH = {}, {}
for i = 0, 15 do BLC[i] = string.sub("0123456789abcdef", i + 1, i + 1) end
for b = 0, 31 do CH[b] = string.char(128 + b) end
local BITV = { 1, 2, 4, 8, 16, 32 }
local cols, px6 = {}, {}

local function present()
  if not SUBPIXEL then
    local txt = string.rep(" ", W)
    local fg  = string.rep("0", W)
    for y = 1, H do
      local row, bgs = fb[y], {}
      for x = 1, W do bgs[x] = BLC[row[x]] end
      win.setCursorPos(1, y)
      win.blit(txt, fg, table.concat(bgs))
    end
    return
  end

  local chr, fgs, bgs = {}, {}, {}
  for cyc = 1, H do
    local r1, r2, r3 = fb[cyc * 3 - 2], fb[cyc * 3 - 1], fb[cyc * 3]
    for cxc = 1, W do
      local x = cxc * 2
      local c1, c2, c3, c4, c5, c6 = r1[x - 1], r1[x], r2[x - 1], r2[x], r3[x - 1], r3[x]
      if c1 == c2 and c2 == c3 and c3 == c4 and c4 == c5 and c5 == c6 then
        chr[cxc], fgs[cxc], bgs[cxc] = " ", "0", BLC[c6]
      else
        -- le pixel bas-droit sert de fond (le bit 32 n'existe pas en 128-159)
        cols[1], cols[2], cols[3], cols[4], cols[5] = c1, c2, c3, c4, c5
        px6[1], px6[2], px6[3], px6[4], px6[5], px6[6] = c1, c2, c3, c4, c5, c6
        local best, bestn = c6, 0
        for i = 1, 5 do
          local c = cols[i]
          if c ~= c6 then
            local n = 0
            for j = 1, 5 do if cols[j] == c then n = n + 1 end end
            if n > bestn then bestn, best = n, c end
          end
        end
        local bits = 0
        if bestn > 0 then
          local dbest, dbg = DIST[best], DIST[c6]
          for i = 1, 5 do
            local c = px6[i]
            if c == best or (c ~= c6 and dbest[c] < dbg[c]) then
              bits = bits + BITV[i]
            end
          end
        end
        chr[cxc], fgs[cxc], bgs[cxc] = CH[bits], BLC[best], BLC[c6]
      end
    end
    win.setCursorPos(1, cyc)
    win.blit(table.concat(chr), table.concat(fgs), table.concat(bgs))
  end
end

---------------------------------------------------------------------
-- Rasterisation : lignes avec test de profondeur
---------------------------------------------------------------------
local P, Q = {0, 0, 0, 0}, {0, 0, 0, 0}

local function line2d(x0, y0, w0, x1, y1, w1, c)
  local dx, dy = x1 - x0, y1 - y0
  P[1], P[2], P[3], P[4] = -dx, dx, -dy, dy
  Q[1], Q[2], Q[3], Q[4] = x0 - 1, SW - x0, y0 - 1, SH - y0
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
  local dwl = w1 - w0
  local wa, wb = w0 + dwl * t0, w0 + dwl * t1
  local ax, ay = floor(x0 + t0 * dx + 0.5), floor(y0 + t0 * dy + 0.5)
  local bx, by = floor(x0 + t1 * dx + 0.5), floor(y0 + t1 * dy + 0.5)
  local sx = ax < bx and 1 or -1
  local sy = ay < by and 1 or -1
  local adx, ady = math.abs(bx - ax), math.abs(by - ay)
  local n = adx > ady and adx or ady
  local dw = n > 0 and (wb - wa) / n or 0
  local w = wa
  local err = adx - ady
  while true do
    if ax >= 1 and ax <= SW and ay >= 1 and ay <= SH and w >= D[ay][ax] then
      fb[ay][ax] = c
    end
    if ax == bx and ay == by then break end
    local e2 = 2 * err
    if e2 > -ady then err = err - ady; ax = ax + sx end
    if e2 < adx then err = err + adx; ay = ay + sy end
    w = w + dw
  end
end

---------------------------------------------------------------------
-- Rasterisation : triangles remplis (relief opaque) avec z-buffer
-- La profondeur stockee est legerement reculee (polygon offset) pour
-- que les lignes posees sur la surface restent visibles.
---------------------------------------------------------------------
local EPS = 1e-4

local function fillTri(x0, y0, w0, x1, y1, w1, x2, y2, w2, col)
  local minx, maxx, miny, maxy = x0, x0, y0, y0
  if x1 < minx then minx = x1 elseif x1 > maxx then maxx = x1 end
  if x2 < minx then minx = x2 elseif x2 > maxx then maxx = x2 end
  if y1 < miny then miny = y1 elseif y1 > maxy then maxy = y1 end
  if y2 < miny then miny = y2 elseif y2 > maxy then maxy = y2 end
  local ix0 = ceil(minx); if ix0 < 1 then ix0 = 1 end
  local ix1 = floor(maxx); if ix1 > SW then ix1 = SW end
  if ix0 > ix1 then return end
  local iy0 = ceil(miny); if iy0 < 1 then iy0 = 1 end
  local iy1 = floor(maxy); if iy1 > SH then iy1 = SH end
  if iy0 > iy1 then return end

  local det = (y1 - y2) * (x0 - x2) + (x2 - x1) * (y0 - y2)
  if det == 0 then return end
  local inv = 1 / det
  local A0, B0 = (y1 - y2) * inv, (x2 - x1) * inv
  local A1, B1 = (y2 - y0) * inv, (x0 - x2) * inv
  local dw0, dw1 = w0 - w2, w1 - w2
  local dwx = A0 * dw0 + A1 * dw1
  local dwy = B0 * dw0 + B1 * dw1
  local bias = (dwx < 0 and -dwx or dwx) + (dwy < 0 and -dwy or dwy)
             + (w0 + w1 + w2) * 0.00067

  for py = iy0, iy1 do
    local ddy, ddx = py - y2, ix0 - x2
    local l0 = A0 * ddx + B0 * ddy
    local l1 = A1 * ddx + B1 * ddy
    local w = w2 + l0 * dw0 + l1 * dw1 - bias
    local row, drow = fb[py], D[py]
    for px = ix0, ix1 do
      if l0 >= -EPS and l1 >= -EPS and (1 - l0 - l1) >= -EPS then
        if w > drow[px] then drow[px] = w; row[px] = col end
      end
      l0 = l0 + A0; l1 = l1 + A1; w = w + dwx
    end
  end
end

---------------------------------------------------------------------
-- Camera + projection
---------------------------------------------------------------------
local FOV    = math.rad(70)
local FOCAL  = (SW / 2) / math.tan(FOV / 2)
local ASPECT = SUBPIXEL and 1.0 or 0.6   -- sous-pixels carres ; une cellule entiere est plus haute que large
local FY     = FOCAL * ASPECT
local NEAR   = 0.3
local cx, cy = SW / 2, SH / 2

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

local function toCam(x, y, z)
  local dx, dy, dz = x - cam.x, y - cam.y, z - cam.z
  return dx * cam.rx + dy * cam.ry + dz * cam.rz,
         dx * cam.ux + dy * cam.uy + dz * cam.uz,
         dx * cam.fx + dy * cam.fy + dz * cam.fz
end

-- ligne en espace camera (decoupe plan proche + projection)
local function drawCamLine(ax, ay, az, bx, by, bz, c)
  if az < NEAR and bz < NEAR then return end
  if az < NEAR then
    local t = (NEAR - az) / (bz - az)
    ax, ay, az = ax + (bx - ax) * t, ay + (by - ay) * t, NEAR
  elseif bz < NEAR then
    local t = (NEAR - bz) / (az - bz)
    bx, by, bz = bx + (ax - bx) * t, by + (ay - by) * t, NEAR
  end
  local w0, w1 = 1 / az, 1 / bz
  line2d(cx + ax * w0 * FOCAL, cy - ay * w0 * FY, w0,
         cx + bx * w1 * FOCAL, cy - by * w1 * FY, w1, c)
end

local function drawWorldLine(x0, y0, z0, x1, y1, z1, c)
  local ax, ay, az = toCam(x0, y0, z0)
  local bx, by, bz = toCam(x1, y1, z1)
  drawCamLine(ax, ay, az, bx, by, bz, c)
end

-- triangle en espace camera, avec decoupe sur le plan proche
local function fillTriCam(ax, ay, az, bx, by, bz, px, py, pz, col)
  local xs, ys, zs = { ax, bx, px }, { ay, by, py }, { az, bz, pz }
  local ox, oy, oz, n = {}, {}, {}, 0
  for i = 1, 3 do
    local j = i % 3 + 1
    local zi, zj = zs[i], zs[j]
    local ini, inj = zi >= NEAR, zj >= NEAR
    if ini then n = n + 1; ox[n], oy[n], oz[n] = xs[i], ys[i], zi end
    if ini ~= inj then
      local t = (NEAR - zi) / (zj - zi)
      n = n + 1
      ox[n] = xs[i] + (xs[j] - xs[i]) * t
      oy[n] = ys[i] + (ys[j] - ys[i]) * t
      oz[n] = NEAR
    end
  end
  if n < 3 then return end
  local sx, sy, sw = {}, {}, {}
  for i = 1, n do
    local iw = 1 / oz[i]
    sx[i], sy[i], sw[i] = cx + ox[i] * iw * FOCAL, cy - oy[i] * iw * FY, iw
  end
  for i = 2, n - 1 do
    fillTri(sx[1], sy[1], sw[1], sx[i], sy[i], sw[i], sx[i + 1], sy[i + 1], sw[i + 1], col)
  end
end

---------------------------------------------------------------------
-- Terrain : anneaux a resolution decroissante (clipmap)
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

local N = RING_N - (RING_N % 2)           -- force un nombre pair
local SIDE = 2 * N + 1
local RINGS = math.max(1, ceil(math.log(VIEW_DIST / (N * GRID_STEP)) / math.log(2)) + 1)

local vx, vy, vz, vsx, vsy, vsw, vok, vcol = {}, {}, {}, {}, {}, {}, {}, {}
local keep = {}
local holeX0, holeX1, holeZ0, holeZ1 = 0, 0, 0, 0

local function kept(a, b)
  if a < 0 or b < 0 or a >= SIDE - 1 or b >= SIDE - 1 then return false end
  return keep[a * SIDE + b + 1]
end

local function tri(i, j, k)
  local zi, zj, zk = vz[i], vz[j], vz[k]
  if zi < NEAR and zj < NEAR and zk < NEAR then return end
  if vok[i] and vok[j] and vok[k] then
    fillTri(vsx[i], vsy[i], vsw[i], vsx[j], vsy[j], vsw[j], vsx[k], vsy[k], vsw[k], GROUND)
  else
    fillTriCam(vx[i], vy[i], zi, vx[j], vy[j], zj, vx[k], vy[k], zk, GROUND)
  end
end

local function edge(i, j)
  local zi, zj = vz[i], vz[j]
  if zi < NEAR and zj < NEAR then return end
  if zi > GRID_DIST and zj > GRID_DIST then return end
  if vok[i] and vok[j] then
    line2d(vsx[i], vsy[i], vsw[i], vsx[j], vsy[j], vsw[j], vcol[i])
  else
    drawCamLine(vx[i], vy[i], zi, vx[j], vy[j], zj, vcol[i])
  end
end

local function drawTerrain()
  local rx, ry, rz = cam.rx, cam.ry, cam.rz
  local ux, uy, uz = cam.ux, cam.uy, cam.uz
  local fx, fy, fz = cam.fx, cam.fy, cam.fz
  local camx, camy, camz = cam.x, cam.y, cam.z

  for r = 0, RINGS - 1 do
    local S = GRID_STEP * 2 ^ r
    local last = (r == RINGS - 1)
    -- le centre de chaque anneau est cale sur la grille de l'anneau
    -- suivant : les trous tombent pile sur des bords de mailles
    local snap = last and S or S * 2
    local ccx = floor(camx / snap) * snap
    local ccz = floor(camz / snap) * snap
    local gx0, gz0 = floor(ccx / S + 0.5), floor(ccz / S + 0.5)

    -- sommets
    local k = 0
    for i = 0, SIDE - 1 do
      local wx = ccx + (i - N) * S
      for j = 0, SIDE - 1 do
        local wz = ccz + (j - N) * S
        local h
        -- bord exterieur : sommets impairs interpoles => raccord sans trou
        if not last and (i == 0 or i == SIDE - 1) and (gz0 + j - N) % 2 == 1 then
          h = (terrainH(wx, wz - S) + terrainH(wx, wz + S)) * 0.5
        elseif not last and (j == 0 or j == SIDE - 1) and (gx0 + i - N) % 2 == 1 then
          h = (terrainH(wx - S, wz) + terrainH(wx + S, wz)) * 0.5
        else
          h = terrainH(wx, wz)
        end
        k = k + 1
        local dx, dy, dz = wx - camx, h - camy, wz - camz
        local x = dx * rx + dy * ry + dz * rz
        local y = dx * ux + dy * uy + dz * uz
        local z = dx * fx + dy * fy + dz * fz
        vx[k], vy[k], vz[k] = x, y, z
        if z >= NEAR then
          local iw = 1 / z
          vsx[k], vsy[k], vsw[k], vok[k] = cx + x * iw * FOCAL, cy - y * iw * FY, iw, true
        else
          vok[k] = false
        end
        vcol[k] = (z > FOG_DIST) and GRAYC or heightColor(h)
      end
    end

    -- mailles : relief rempli (sauf zone deja couverte par l'anneau fin)
    for a = 0, SIDE - 2 do
      local x = ccx + (a - N) * S
      for b = 0, SIDE - 2 do
        local z = ccz + (b - N) * S
        local kp = true
        if r > 0 and x >= holeX0 and x + S <= holeX1 and z >= holeZ0 and z + S <= holeZ1 then
          kp = false
        end
        keep[a * SIDE + b + 1] = kp
        if kp then
          local v00 = a * SIDE + b + 1
          local v01, v10 = v00 + 1, v00 + SIDE
          local v11 = v10 + 1
          tri(v00, v01, v10)
          tri(v01, v11, v10)
        end
      end
    end

    -- lignes du quadrillage (testees contre le z-buffer)
    for a = 0, SIDE - 1 do
      for b = 0, SIDE - 1 do
        local v = a * SIDE + b + 1
        if b < SIDE - 1 and (kept(a, b) or kept(a - 1, b)) then edge(v, v + 1) end
        if a < SIDE - 1 and (kept(a, b) or kept(a, b - 1)) then edge(v, v + SIDE) end
      end
    end

    holeX0, holeX1 = ccx - N * S, ccx + N * S
    holeZ0, holeZ1 = ccz - N * S, ccz + N * S
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
  drawWorldLine(plane.x - s, gh + 0.5, plane.z, plane.x + s, gh + 0.5, plane.z, hex.gray)
  drawWorldLine(plane.x, gh + 0.5, plane.z - s, plane.x, gh + 0.5, plane.z + s, hex.gray)
end

---------------------------------------------------------------------
-- Trajectoire : spline fermee (Catmull-Rom) passant par des points
---------------------------------------------------------------------
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

-- table longueur d'arc -> parametre u (vitesse constante)
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

    local dxw = plane.x - plane.fx * 16
    local dyw = plane.y + 5 - plane.fy * 16
    local dzw = plane.z - plane.fz * 16
    local k = 1 - math.exp(-dt * 4)
    cam.x = cam.x + (dxw - cam.x) * k
    cam.y = cam.y + (dyw - cam.y) * k
    cam.z = cam.z + (dzw - cam.z) * k
    local minY = terrainH(cam.x, cam.z) + 4
    if cam.y < minY then cam.y = minY end
    lookAt(plane.x + plane.fx * 8, plane.y + plane.fy * 8 - 1, plane.z + plane.fz * 8)

    clearBuffers()
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
