-- FlightDirectGPU.lua : simulation 3D pour CC: Tweaked + mod DirectGPU
-- https://github.com/tiktop101/CC-DirectGPU-Mod
--
-- * Rendu en vraies couleurs RGB sur un moniteur DirectGPU (haute resolution)
-- * Terrain en quadrillage jusqu'a VIEW_DIST blocs (LOD par anneaux), brume, ciel degrade
-- * Lignes cachees : algorithme du peintre (mailles dessinees de la plus loin a la plus proche)
-- * Avion sur une boucle en spline (signe infini ou points predefinis)
--
-- Installation : bloc DirectGPU colle a l'ordinateur + un moniteur a cote.
-- Touches (dans le terminal de l'ordinateur) : Q quitter, H changer le HUD.

---------------------------------------------------------------------
-- CONFIG
---------------------------------------------------------------------
local VIEW_DIST   = 500   -- distance de vue (blocs)
local GRID_STEP   = 8      -- taille des mailles proches
local RING_N      = 10     -- mailles par demi-anneau (pair). Baisse-le si ca rame
local FOG_START   = 0.35   -- debut de la brume (fraction de VIEW_DIST)
local FPS_MAX     = 30     -- limite d'images/seconde (1 a 60)

local RESOLUTION  = nil    -- nil = auto ; sinon 0, 1, 2... (multiplicateur de resolution DirectGPU)
local POLY_FILL   = "auto" -- "auto" (teste drawPolygon au demarrage), "polygon" ou "spans"

local LIGHTING     = false -- true : ombrage du relief selon la pente (facettes visibles)
local FILL_BRIGHT  = 0.32  -- luminosite du sol sans eclairage (0 = noir, 1 = couleur pleine)
local FILL_AMBIENT = 0.10  -- (si LIGHTING) luminosite de base
local FILL_DIFFUSE = 0.32  -- (si LIGHTING) part de lumiere directe
local MAX_BANK_DEG = 35    -- inclinaison maximale de l'avion dans les virages
local ROLL_SIGN    = 1     -- mettre -1 pour inverser le sens d'inclinaison (avion + cercle)
local SHOW_GRID      = false -- true : quadrillage (lignes) ; false : polygones lisses, sans lignes
local SMOOTH_BRIGHT  = 0.62  -- (sans lignes) luminosite du sol : 0 = noir, 1 = couleur pleine
local RELIEF_SHADING = 0.45  -- (sans lignes) force de l'ombrage du relief : 0 = aucun, 1 = fort
local HUD_FONT     = "Monospaced"  -- police Java toujours dispo ("Arial" aussi possible)

local PATH_MODE   = "waypoints"   -- "infinity" ou "waypoints"
local SPEED       = 22           -- vitesse de l'avion (blocs/s)

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
-- Initialisation DirectGPU
---------------------------------------------------------------------
local gpu = peripheral.find("directgpu")
if not gpu then
  error("Peripherique 'directgpu' introuvable : place le bloc DirectGPU contre l'ordinateur.", 0)
end

pcall(gpu.clearAllDisplays)
local display
if RESOLUTION then
  display = gpu.autoDetectAndCreateDisplayWithResolution(RESOLUTION)
else
  display = gpu.autoDetectAndCreateDisplay()
end
if not display then
  error("Aucun moniteur detecte : place un moniteur a cote du bloc DirectGPU.", 0)
end

local info = gpu.getDisplayInfo(display)
local PW, PH = info.pixelWidth, info.pixelHeight

local floor, ceil, sqrt, abs = math.floor, math.ceil, math.sqrt, math.abs
local max, min = math.max, math.min

local g_fillRect, g_drawLine = gpu.fillRect, gpu.drawLine
local g_drawPolygon, g_drawText = gpu.drawPolygon, gpu.drawText

local function clamp(x, a, b) if x < a then return a elseif x > b then return b end return x end
local function lerp(a, b, t) return a + (b - a) * t end

---------------------------------------------------------------------
-- Couleurs
---------------------------------------------------------------------
local HAZE     = { 172, 196, 230 }   -- brume / horizon
local SKY_TOP  = { 62, 112, 222 }    -- haut du ciel

-- couleur du sol selon l'altitude : degrade vert -> herbe -> roche -> neige
local function heightColor(h)
  if h <= -2.99 then return 40, 100, 220 end        -- eau
  if h < 4 then
    local t = clamp((h + 3) / 7, 0, 1)
    return lerp(60, 140, t), lerp(170, 200, t), lerp(80, 60, t)
  elseif h < 9 then
    local t = (h - 4) / 5
    return lerp(140, 150, t), lerp(200, 110, t), lerp(60, 70, t)
  else
    local t = clamp((h - 9) / 4, 0, 1)
    return lerp(150, 245, t), lerp(110, 245, t), lerp(70, 250, t)
  end
end

local function rgb(r, g, b)
  return floor(r + 0.5), floor(g + 0.5), floor(b + 0.5)
end

---------------------------------------------------------------------
-- Primitives d'ecran
---------------------------------------------------------------------
local XMAX, YMAX = PW - 1, PH - 1
local LP, LQ = { 0, 0, 0, 0 }, { 0, 0, 0, 0 }

-- ligne decoupee a l'ecran (coordonnees flottantes en entree)
local function lineScreen(x0, y0, x1, y1, r, g, b)
  local dx, dy = x1 - x0, y1 - y0
  LP[1], LP[2], LP[3], LP[4] = -dx, dx, -dy, dy
  LQ[1], LQ[2], LQ[3], LQ[4] = x0, XMAX - x0, y0, YMAX - y0
  local t0, t1 = 0, 1
  for i = 1, 4 do
    local p, q = LP[i], LQ[i]
    if p == 0 then
      if q < 0 then return end
    else
      local rr = q / p
      if p < 0 then
        if rr > t1 then return end
        if rr > t0 then t0 = rr end
      else
        if rr < t0 then return end
        if rr < t1 then t1 = rr end
      end
    end
  end
  g_drawLine(display,
    floor(x0 + t0 * dx + 0.5), floor(y0 + t0 * dy + 0.5),
    floor(x0 + t1 * dx + 0.5), floor(y0 + t1 * dy + 0.5), r, g, b)
end

-- triangle rempli par lignes horizontales (sert si drawPolygon ne remplit pas)
local function fillTriSpans(x0, y0, x1, y1, x2, y2, r, g, b)
  if y1 < y0 then x0, y0, x1, y1 = x1, y1, x0, y0 end
  if y2 < y0 then x0, y0, x2, y2 = x2, y2, x0, y0 end
  if y2 < y1 then x1, y1, x2, y2 = x2, y2, x1, y1 end
  local ya = ceil(y0 - 0.5); if ya < 0 then ya = 0 end
  local yb = floor(y2 - 0.5); if yb > YMAX then yb = YMAX end
  if ya > yb then return end
  local h02 = y2 - y0
  if h02 <= 0 then return end
  local h01, h12 = y1 - y0, y2 - y1
  for y = ya, yb do
    local sy = y + 0.5
    local xa = x0 + (x2 - x0) * (sy - y0) / h02
    local xb
    if sy < y1 then
      xb = h01 > 0 and (x0 + (x1 - x0) * (sy - y0) / h01) or x1
    else
      xb = h12 > 0 and (x1 + (x2 - x1) * (sy - y1) / h12) or x1
    end
    if xa > xb then xa, xb = xb, xa end
    local xs, xe = ceil(xa - 0.5), floor(xb - 0.5)
    if xs < 0 then xs = 0 end
    if xe > XMAX then xe = XMAX end
    if xe >= xs then g_fillRect(display, xs, y, xe - xs + 1, 1, r, g, b) end
  end
end

-- test au demarrage : drawPolygon remplit-il l'interieur ?
local usePoly = false
if POLY_FILL == "polygon" then
  usePoly = true
elseif POLY_FILL == "auto" then
  local ok, res = pcall(function()
    gpu.clear(display, 0, 0, 0)
    g_drawPolygon(display, { { 4, 4 }, { 40, 4 }, { 40, 40 }, { 4, 40 } }, 255, 255, 255)
    local px = gpu.getPixel(display, 22, 22)
    local v
    if type(px) == "table" then v = px[1] or px.r or px.red else v = px end
    gpu.clear(display, 0, 0, 0)
    return type(v) == "number" and v > 200
  end)
  usePoly = ok and res == true
end

local PX, PY = {}, {}              -- sommets du polygone en cours
local polyT = {}                   -- tables de points reutilisees (drawPolygon)
for n = 3, 8 do
  polyT[n] = {}
  for i = 1, n do polyT[n][i] = { 0, 0 } end
end

local function fillPoly(n, r, g, b)
  if usePoly then
    local ok = true
    for i = 1, n do
      local x, y = PX[i], PY[i]
      if x < -3000 or x > 3000 or y < -3000 or y > 3000 then ok = false; break end
    end
    if ok then
      local t = polyT[n]
      for i = 1, n do
        t[i][1], t[i][2] = floor(PX[i] + 0.5), floor(PY[i] + 0.5)
      end
      g_drawPolygon(display, t, r, g, b)
      return
    end
  end
  for i = 2, n - 1 do
    fillTriSpans(PX[1], PY[1], PX[i], PY[i], PX[i + 1], PY[i + 1], r, g, b)
  end
end

---------------------------------------------------------------------
-- Camera + projection (pixels carres)
---------------------------------------------------------------------
local FOV   = math.rad(70)
local FOCAL = (PW / 2) / math.tan(FOV / 2)
local NEAR  = 0.3
local cx, cy = PW / 2, PH / 2

local cam = { x = 0, y = 0, z = 0, rx = 1, ry = 0, rz = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1 }

local function normalize(x, y, z)
  local l = sqrt(x * x + y * y + z * z)
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
local function drawCamLine(ax, ay, az, bx, by, bz, r, g, b)
  if az < NEAR and bz < NEAR then return end
  if az < NEAR then
    local t = (NEAR - az) / (bz - az)
    ax, ay, az = ax + (bx - ax) * t, ay + (by - ay) * t, NEAR
  elseif bz < NEAR then
    local t = (NEAR - bz) / (az - bz)
    bx, by, bz = bx + (ax - bx) * t, by + (ay - by) * t, NEAR
  end
  lineScreen(cx + ax / az * FOCAL, cy - ay / az * FOCAL,
             cx + bx / bz * FOCAL, cy - by / bz * FOCAL, r, g, b)
end

-- polygone en espace camera (coordonnees x,y,z dans qx,qy,qz) decoupe sur le plan proche
local QX, QY, QZ = {}, {}, {}
local function fillCamPoly(n, r, g, b)
  local m = 0
  for i = 1, n do
    local j = i % n + 1
    local zi, zj = QZ[i], QZ[j]
    local ini, inj = zi >= NEAR, zj >= NEAR
    if ini then
      m = m + 1
      PX[m] = cx + QX[i] / zi * FOCAL
      PY[m] = cy - QY[i] / zi * FOCAL
    end
    if ini ~= inj then
      local t = (NEAR - zi) / (zj - zi)
      m = m + 1
      PX[m] = cx + (QX[i] + (QX[j] - QX[i]) * t) / NEAR * FOCAL
      PY[m] = cy - (QY[i] + (QY[j] - QY[i]) * t) / NEAR * FOCAL
    end
  end
  if m >= 3 then fillPoly(m, r, g, b) end
end

---------------------------------------------------------------------
-- Ciel + horizon + brume
---------------------------------------------------------------------
local SKY_BANDS = 16

local function drawSky()
  -- hauteur de l'horizon a l'ecran
  local fx, fz = cam.fx, cam.fz
  local hl = fx * fx + fz * fz
  local yh
  if hl < 1e-6 then
    yh = cam.fy > 0 and PH * 4 or -PH * 4
  else
    yh = cy - FOCAL * (fx * cam.ux + fz * cam.uz) / hl
  end
  local yi = floor(clamp(yh, 0, PH))

  if yi < PH then
    -- fond sous l'horizon : brume au ras de l'horizon, puis teinte "sol" (les petits trous
    -- entre deux polygones lointains se voient ainsi beaucoup moins)
    local GB = { 70, 118, 72 }
    local nb, span = 8, PH - yi
    for i = 0, nb - 1 do
      local y0 = yi + floor(span * i / nb)
      local y1 = (i == nb - 1) and PH or yi + floor(span * (i + 1) / nb)
      if y1 > y0 then
        local t = clamp((y0 - yh) / (PH * 0.22), 0, 1) * 0.75
        g_fillRect(display, 0, y0, PW, y1 - y0,
          rgb(lerp(HAZE[1], GB[1], t), lerp(HAZE[2], GB[2], t), lerp(HAZE[3], GB[3], t)))
      end
    end
  end
  if yi > 0 then
    local bandH = yi / SKY_BANDS
    for i = 0, SKY_BANDS - 1 do
      local y0 = floor(bandH * i)
      local y1 = floor(bandH * (i + 1))
      if i == SKY_BANDS - 1 then y1 = yi end
      if y1 > y0 then
        local ymid = (y0 + y1) / 2
        local t = clamp((yh - ymid) / (FOCAL * 1.1), 0, 1)   -- 0 horizon, 1 zenith
        g_fillRect(display, 0, y0, PW, y1 - y0,
          rgb(lerp(HAZE[1], SKY_TOP[1], t), lerp(HAZE[2], SKY_TOP[2], t), lerp(HAZE[3], SKY_TOP[3], t)))
      end
    end
  end
end

---------------------------------------------------------------------
-- Terrain : anneaux a resolution decroissante, dessines du plus loin
-- au plus proche (algorithme du peintre)
---------------------------------------------------------------------
local function terrainH(x, z)
  local h = 8 * math.sin(x * 0.05) * math.cos(z * 0.06)
          + 5 * math.sin(x * 0.11 + z * 0.07)
          + 3 * math.cos(z * 0.13 - x * 0.04)
  if h < -3 then h = -3 end      -- niveau de l'eau
  return h
end

local N = RING_N - (RING_N % 2)
local SIDE = 2 * N + 1
local RINGS = max(1, ceil(math.log(VIEW_DIST / (N * GRID_STEP)) / math.log(2)) + 1)
local FOG0 = VIEW_DIST * FOG_START
local ZCUT = VIEW_DIST * 1.03

local SUN_X, SUN_Y, SUN_Z = normalize(0.5, 0.75, 0.35)

local vx, vy, vz, vsx, vsy, vok, vf, vh = {}, {}, {}, {}, {}, {}, {}, {}
local vlr, vlg, vlb = {}, {}, {}
local keep = {}
local ordA, ordB, rankA, rankB = {}, {}, {}, {}

local function edge(i, j)
  if vf[i] > 0.93 and vf[j] > 0.93 then return end
  local zi, zj = vz[i], vz[j]
  if zi < NEAR and zj < NEAR then return end
  if vok[i] and vok[j] then
    lineScreen(vsx[i], vsy[i], vsx[j], vsy[j], vlr[i], vlg[i], vlb[i])
  else
    drawCamLine(vx[i], vy[i], zi, vx[j], vy[j], zj, vlr[i], vlg[i], vlb[i])
  end
end

local function drawCell(a, b, S)
  local v00 = a * SIDE + b + 1
  local v01, v10 = v00 + 1, v00 + SIDE
  local v11 = v10 + 1
  local z00, z01, z10, z11 = vz[v00], vz[v01], vz[v10], vz[v11]
  if z00 < NEAR and z01 < NEAR and z10 < NEAR and z11 < NEAR then return end
  if z00 > ZCUT and z01 > ZCUT and z10 > ZCUT and z11 > ZCUT then return end

  local allOk = vok[v00] and vok[v01] and vok[v10] and vok[v11]
  if allOk then
    local x00, x01, x10, x11 = vsx[v00], vsx[v01], vsx[v10], vsx[v11]
    if (x00 < 0 and x01 < 0 and x10 < 0 and x11 < 0) or
       (x00 > XMAX and x01 > XMAX and x10 > XMAX and x11 > XMAX) then return end
    local y00, y01, y10, y11 = vsy[v00], vsy[v01], vsy[v10], vsy[v11]
    if (y00 < 0 and y01 < 0 and y10 < 0 and y11 < 0) or
       (y00 > YMAX and y01 > YMAX and y10 > YMAX and y11 > YMAX) then return end
  end

  -- couleur du sol : altitude moyenne + ombrage (pente) + brume
  local h00, h01, h10, h11 = vh[v00], vh[v01], vh[v10], vh[v11]
  local br, bg, bb = heightColor((h00 + h01 + h10 + h11) * 0.25)
  local shade = SHOW_GRID and FILL_BRIGHT or SMOOTH_BRIGHT
  if (SHOW_GRID and LIGHTING) or (not SHOW_GRID and RELIEF_SHADING > 0) then
    -- normale au centre de la maille (plus douce que sur un seul coin)
    local dhx = ((h10 + h11) - (h00 + h01)) / (2 * S)
    local dhz = ((h01 + h11) - (h00 + h10)) / (2 * S)
    local nl = sqrt(dhx * dhx + 1 + dhz * dhz)
    local lam = (-dhx * SUN_X + SUN_Y - dhz * SUN_Z) / nl
    if lam < 0 then lam = 0 end
    if SHOW_GRID then
      shade = FILL_AMBIENT + FILL_DIFFUSE * lam
    else
      -- sol plat = SMOOTH_BRIGHT ; pentes face au soleil plus claires, dos au soleil plus sombres
      shade = clamp(SMOOTH_BRIGHT * (1 + RELIEF_SHADING * (lam - SUN_Y) / SUN_Y), 0.08, 1)
    end
  end
  local f = (vf[v00] + vf[v01] + vf[v10] + vf[v11]) * 0.25
  local fr, fg, fb = rgb(lerp(br * shade, HAZE[1], f), lerp(bg * shade, HAZE[2], f), lerp(bb * shade, HAZE[3], f))

  -- remplissage (cache ce qui est derriere)
  if allOk then
    PX[1], PY[1] = vsx[v00], vsy[v00]
    PX[2], PY[2] = vsx[v10], vsy[v10]
    PX[3], PY[3] = vsx[v11], vsy[v11]
    PX[4], PY[4] = vsx[v01], vsy[v01]
    fillPoly(4, fr, fg, fb)
  else
    QX[1], QY[1], QZ[1] = vx[v00], vy[v00], z00
    QX[2], QY[2], QZ[2] = vx[v10], vy[v10], z10
    QX[3], QY[3], QZ[3] = vx[v11], vy[v11], z11
    QX[4], QY[4], QZ[4] = vx[v01], vy[v01], z01
    fillCamPoly(4, fr, fg, fb)
  end

  -- lignes : chaque arete est dessinee par la maille dessinee APRES sa voisine
  if SHOW_GRID then
    local ra, rb = rankA[a], rankB[b]
    if a == 0 or not keep[(a - 1) * SIDE + b + 1] or rankA[a - 1] < ra then edge(v00, v01) end
    if a == SIDE - 2 or not keep[(a + 1) * SIDE + b + 1] or rankA[a + 1] < ra then edge(v10, v11) end
    if b == 0 or not keep[a * SIDE + b] or rankB[b - 1] < rb then edge(v00, v10) end
    if b == SIDE - 2 or not keep[a * SIDE + b + 2] or rankB[b + 1] < rb then edge(v01, v11) end
  end
end

-- ordre de parcours : du bord lointain vers la case de la camera
local function makeOrder(ord, rank, ca)
  local n = 0
  for a = 0, ca - 1 do n = n + 1; ord[n] = a end
  for a = SIDE - 2, ca, -1 do n = n + 1; ord[n] = a end
  for i = 1, n do rank[ord[i]] = i end
  for i = n + 1, #ord do ord[i] = nil end
  return n
end

local function drawTerrain()
  local rx, ry, rz = cam.rx, cam.ry, cam.rz
  local ux, uy, uz = cam.ux, cam.uy, cam.uz
  local fx, fy, fz = cam.fx, cam.fy, cam.fz
  local camx, camy, camz = cam.x, cam.y, cam.z
  local span = VIEW_DIST - FOG0

  -- centres des anneaux (calage sur la grille de l'anneau suivant => raccords sans trou)
  local CCX, CCZ, SS = {}, {}, {}
  for r = 0, RINGS - 1 do
    local S = GRID_STEP * 2 ^ r
    local snap = (r == RINGS - 1) and S or S * 2
    SS[r], CCX[r], CCZ[r] = S, floor(camx / snap) * snap, floor(camz / snap) * snap
  end

  for r = RINGS - 1, 0, -1 do
    local S, ccx, ccz = SS[r], CCX[r], CCZ[r]
    local last = (r == RINGS - 1)
    local gx0, gz0 = floor(ccx / S + 0.5), floor(ccz / S + 0.5)

    -- sommets
    local k = 0
    for i = 0, SIDE - 1 do
      local wx = ccx + (i - N) * S
      for j = 0, SIDE - 1 do
        local wz = ccz + (j - N) * S
        local h
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
        vx[k], vy[k], vz[k], vh[k] = x, y, z, h
        if z >= NEAR then
          local iw = 1 / z
          vsx[k], vsy[k], vok[k] = cx + x * iw * FOCAL, cy - y * iw * FOCAL, true
        else
          vok[k] = false
        end
        local f = clamp((z - FOG0) / span, 0, 1)
        vf[k] = f
        if SHOW_GRID then
          local br, bg, bb = heightColor(h)
          vlr[k], vlg[k], vlb[k] = rgb(lerp(br, HAZE[1], f), lerp(bg, HAZE[2], f), lerp(bb, HAZE[3], f))
        end
      end
    end

    -- mailles gardees (on saute la zone couverte par l'anneau plus fin)
    local hx0, hx1, hz0, hz1
    if r > 0 then
      local Sp = SS[r - 1]
      hx0, hx1 = CCX[r - 1] - N * Sp, CCX[r - 1] + N * Sp
      hz0, hz1 = CCZ[r - 1] - N * Sp, CCZ[r - 1] + N * Sp
    end
    for a = 0, SIDE - 2 do
      local x = ccx + (a - N) * S
      for b = 0, SIDE - 2 do
        local z = ccz + (b - N) * S
        local kp = true
        if r > 0 and x >= hx0 and x + S <= hx1 and z >= hz0 and z + S <= hz1 then kp = false end
        keep[a * SIDE + b + 1] = kp
      end
    end

    -- ordre peintre selon la position de la camera dans la grille de l'anneau
    local ca = clamp(floor((camx - ccx) / S) + N, 0, SIDE - 2)
    local cb = clamp(floor((camz - ccz) / S) + N, 0, SIDE - 2)
    local na = makeOrder(ordA, rankA, ca)
    local nb = makeOrder(ordB, rankB, cb)

    for ia = 1, na do
      local a = ordA[ia]
      for ib = 1, nb do
        local b = ordB[ib]
        if keep[a * SIDE + b + 1] then drawCell(a, b, S) end
      end
    end
  end
end

---------------------------------------------------------------------
-- Avion (faces remplies, triees par profondeur)
---------------------------------------------------------------------
local V = {
  {0, 0, 3.5},      -- 1 nez
  {0, 0, -3},       -- 2 queue
  {-4, 0, -1},      -- 3 bout aile G
  {4, 0, -1},       -- 4 bout aile D
  {0, 0, 1},        -- 5 avant aile
  {0, 0, -1.2},     -- 6 arriere aile
  {-1.8, 0, -3},    -- 7 stab G
  {1.8, 0, -3},     -- 8 stab D
  {0, 0, -2.2},     -- 9 base stab
  {0, 1.8, -3},     -- 10 derive
  {0, 0.8, 0.6},    -- 11 cockpit
  {-0.6, 0, 0.3},   -- 12 flanc G
  {0.6, 0, 0.3},    -- 13 flanc D
}
local FACES = {
  { 5, 3, 6, 215, 45, 45 },  { 5, 4, 6, 235, 60, 60 },        -- ailes
  { 9, 7, 2, 235, 235, 240 }, { 9, 8, 2, 245, 245, 250 },      -- stabilisateurs
  { 9, 10, 2, 250, 250, 255 },                                 -- derive
  { 1, 12, 11, 205, 205, 215 }, { 1, 13, 11, 235, 235, 242 },  -- fuselage avant
  { 2, 12, 11, 190, 190, 200 }, { 2, 13, 11, 220, 220, 228 },  -- fuselage arriere
}
local OUTLINE = { 20, 22, 30 }

local plane = { x = 0, y = 0, z = 0, fx = 0, fy = 0, fz = 1, bank = 0 }
local pcx, pcy, pcz, order = {}, {}, {}, {}

local function drawPlane()
  local rx, ry, rz = normalize(cross(0, 1, 0, plane.fx, plane.fy, plane.fz))
  local ux, uy, uz = cross(plane.fx, plane.fy, plane.fz, rx, ry, rz)
  local cb, sb = math.cos(plane.bank), math.sin(plane.bank)
  local Rx, Ry, Rz = rx * cb + ux * sb, ry * cb + uy * sb, rz * cb + uz * sb
  local Ux, Uy, Uz = ux * cb - rx * sb, uy * cb - ry * sb, uz * cb - rz * sb

  -- ombre sur le sol
  local gh = terrainH(plane.x, plane.z)
  local sx_, sy_, sz_ = toCam(plane.x, gh + 0.3, plane.z)
  if sz_ > NEAR then
    local rad = 3.2 * FOCAL / sz_
    local ex, ey = cx + sx_ / sz_ * FOCAL, cy - sy_ / sz_ * FOCAL
    gpu.fillEllipse(display, floor(ex + 0.5), floor(ey + 0.5), max(1, floor(rad)), max(1, floor(rad * 0.45)), 30, 40, 40)
  end

  for i, v in ipairs(V) do
    local lx, ly, lz = v[1], v[2], v[3]
    local wx = plane.x + Rx * lx + Ux * ly + plane.fx * lz
    local wy = plane.y + Ry * lx + Uy * ly + plane.fy * lz
    local wz = plane.z + Rz * lx + Uz * ly + plane.fz * lz
    pcx[i], pcy[i], pcz[i] = toCam(wx, wy, wz)
  end

  -- faces triees de la plus loin a la plus proche
  local n = #FACES
  for i = 1, n do order[i] = i end
  table.sort(order, function(a, b)
    local fa, fb = FACES[a], FACES[b]
    return pcz[fa[1]] + pcz[fa[2]] + pcz[fa[3]] > pcz[fb[1]] + pcz[fb[2]] + pcz[fb[3]]
  end)
  for oi = 1, n do
    local f = FACES[order[oi]]
    for q = 1, 3 do
      local vi = f[q]
      QX[q], QY[q], QZ[q] = pcx[vi], pcy[vi], pcz[vi]
    end
    fillCamPoly(3, f[4], f[5], f[6])
    -- contour
    for q = 1, 3 do
      local p1, p2 = f[q], f[q % 3 + 1]
      drawCamLine(pcx[p1], pcy[p1], pcz[p1], pcx[p2], pcy[p2], pcz[p2], OUTLINE[1], OUTLINE[2], OUTLINE[3])
    end
  end
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
if PATH_MODE == "waypoints" then PTS = WAYPOINTS else PTS = lemniscate(20, 140, 32, 9) end

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
    TOTAL = TOTAL + sqrt((x - px) ^ 2 + (y - py) ^ 2 + (z - pz) ^ 2)
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
  local spanL = SL[hi] - SL[lo]
  local f = spanL > 0 and (s - SL[lo]) / spanL or 0
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
  local target = max(-1, min(1, diff / ds * 45)) * math.rad(MAX_BANK_DEG) * ROLL_SIGN
  local k = 1 - math.exp(-dt * 3)
  plane.bank = plane.bank + (target - plane.bank) * k
end

---------------------------------------------------------------------
-- HUD (texte, compas, horizon artificiel, mini-carte)
---------------------------------------------------------------------
local function now()
  if os.epoch then return os.epoch("utc") / 1000 end
  return os.clock()
end

local FRAME = 1 / max(1, min(60, FPS_MAX))
local hudMode = 1                       -- 1 complet, 2 minimal, 3 aucun (touche H)
local FS = max(8, floor(PH / 24))       -- taille de police
local LH = FS + 4                       -- hauteur de ligne

local function text(str, x, y, r, g, b)
  g_drawText(display, str, floor(x), floor(y), r, g, b, HUD_FONT, FS, "bold")
end

local WIND = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }

-- mini-carte : boucle precalculee
local MM_W, MM_H = floor(PH * 0.40), floor(PH * 0.30)
local MM_X, MM_Y = PW - MM_W - 8, PH - MM_H - 8
local mm = { pts = {} }
do
  local SAMPLES = 120
  local minx, maxx, minz, maxz = 1e9, -1e9, 1e9, -1e9
  local raw = {}
  for i = 0, SAMPLES - 1 do
    local x, _, z = pathAt(TOTAL * i / SAMPLES)
    raw[#raw + 1] = { x, z }
    if x < minx then minx = x end
    if x > maxx then maxx = x end
    if z < minz then minz = z end
    if z > maxz then maxz = z end
  end
  local pad = 10
  mm.scale = min((MM_W - 2 * pad) / max(maxx - minx, 1), (MM_H - 2 * pad) / max(maxz - minz, 1))
  mm.cx, mm.cz = (minx + maxx) / 2, (minz + maxz) / 2
  for i, p in ipairs(raw) do
    mm.pts[i] = {
      floor(MM_X + MM_W / 2 + (p[1] - mm.cx) * mm.scale + 0.5),
      floor(MM_Y + MM_H / 2 - (p[2] - mm.cz) * mm.scale + 0.5),
    }
  end
  mm.pts[#mm.pts + 1] = mm.pts[1]   -- boucle fermee
end

local function drawMinimap(hdg)
  g_fillRect(display, MM_X, MM_Y, MM_W, MM_H, 18, 24, 34)
  local x1, y1, x2, y2 = MM_X, MM_Y, MM_X + MM_W - 1, MM_Y + MM_H - 1
  g_drawLine(display, x1, y1, x2, y1, 120, 130, 150)
  g_drawLine(display, x2, y1, x2, y2, 120, 130, 150)
  g_drawLine(display, x2, y2, x1, y2, 120, 130, 150)
  g_drawLine(display, x1, y2, x1, y1, 120, 130, 150)
  gpu.drawPolylines(display, mm.pts, 90, 200, 255)
  local px = floor(MM_X + MM_W / 2 + (plane.x - mm.cx) * mm.scale + 0.5)
  local py = floor(MM_Y + MM_H / 2 - (plane.z - mm.cz) * mm.scale + 0.5)
  local a = math.rad(hdg)
  g_drawLine(display, px, py, floor(px + math.sin(a) * 9 + 0.5), floor(py - math.cos(a) * 9 + 0.5), 255, 220, 60)
  gpu.drawCircle(display, px, py, 3, 255, 70, 70, true)
end

local function drawCompass(hdg)
  local half = floor(PW * 0.22)
  local mid, top = floor(PW / 2), 6
  local ppd = half / 40                       -- pixels par degre (80 degres visibles)
  g_fillRect(display, mid - half, top, half * 2, LH + 12, 18, 24, 34)
  local base = floor(hdg / 5) * 5
  for k = -10, 10 do
    local a = base + k * 5
    local x = mid + (a - hdg) * ppd
    if x > mid - half and x < mid + half then
      local am = a % 360
      local long = am % 15 == 0
      g_drawLine(display, floor(x), top + (long and 2 or 5), floor(x), top + 9, 200, 210, 225)
      if am % 45 == 0 then
        local lbl = WIND[floor(am / 45) % 8 + 1]
        local col = (lbl == "N") and { 255, 80, 80 } or { 240, 240, 245 }
        text(lbl, x - #lbl * FS * 0.3, top + 11, col[1], col[2], col[3])
      end
    end
  end
  g_drawLine(display, mid, top + 10, mid - 4, top + 3, 255, 220, 60)
  g_drawLine(display, mid, top + 10, mid + 4, top + 3, 255, 220, 60)
  text(string.format("%03d", floor(hdg + 0.5) % 360), mid - FS * 1.0, top + 11 + LH * 0.0, 255, 220, 60)
end

local function drawAttitude(pitch)
  local ar = floor(PH * 0.10)
  local ax, ay = floor(PW / 2), PH - ar - 10
  gpu.drawCircle(display, ax, ay, ar, 200, 210, 225, false)

  -- horizon : reste a plat, monte/descend avec le tangage
  local d = clamp(math.rad(pitch) * ar * 1.6, -ar * 0.8, ar * 0.8)
  local hl = floor(sqrt(max(0, ar * ar - d * d)) - 1)
  g_drawLine(display, ax - hl, floor(ay + d + 0.5), ax + hl, floor(ay + d + 0.5), 120, 200, 255)

  -- symbole d'avion : s'incline EXACTEMENT comme les ailes de l'avion a l'ecran
  local c, s = math.cos(plane.bank), math.sin(plane.bank)
  local wl = ar * 0.75
  local lx, ly = ax - c * wl, ay + s * wl          -- aile gauche
  local rx_, ry_ = ax + c * wl, ay - s * wl        -- aile droite (haute si bank > 0)
  g_drawLine(display, floor(lx + 0.5), floor(ly + 0.5), floor(rx_ + 0.5), floor(ry_ + 0.5), 255, 220, 60)
  g_drawLine(display, ax, ay, floor(ax - s * ar * 0.35 + 0.5), floor(ay - c * ar * 0.35 + 0.5), 255, 220, 60)  -- derive
end

local function drawHUD(fps, ms, dist)
  if hudMode == 3 then return end
  local ratio = ms / (FRAME * 1000)
  local mc = ratio < 0.75 and { 90, 255, 120 } or (ratio < 0.95 and { 255, 220, 60 } or { 255, 80, 80 })
  local fr = fps / FPS_MAX
  local fc = fr > 0.9 and { 90, 255, 120 } or (fr > 0.6 and { 255, 220, 60 } or { 255, 80, 80 })
  text(string.format("FPS %2d", floor(fps + 0.5)), 8, 6, fc[1], fc[2], fc[3])
  text(string.format("MS %2d", floor(ms + 0.5)), 8 + FS * 6.5, 6, mc[1], mc[2], mc[3])
  if hudMode == 2 then return end

  local lap = floor(dist / TOTAL) + 1
  local pct = floor((dist % TOTAL) / TOTAL * 100)
  local lapTxt = string.format("TOUR %d  %d%%", lap, pct)
  text(lapTxt, PW - #lapTxt * FS * 0.62 - 8, 6, 190, 200, 220)

  local hdg = math.deg(atan2(plane.fx, plane.fz)) % 360
  local pitch = math.deg(math.asin(clamp(plane.fy, -1, 1)))
  local agl = plane.y - terrainH(plane.x, plane.z)

  drawCompass(hdg)
  drawAttitude(pitch)
  drawMinimap(hdg)

  if agl < 10 and floor(now() * 3) % 2 == 0 then
    local w = FS * 9
    g_fillRect(display, floor(PW / 2 - w / 2), LH * 3, floor(w), LH, 220, 40, 40)
    text(" TERRAIN ", PW / 2 - w / 2, LH * 3 + 1, 255, 255, 255)
  end

  local y0 = PH - LH * 4 - 8
  text(string.format("ALT %4d  AGL %3d", floor(plane.y), floor(agl)), 8, y0, 235, 240, 250)
  text(string.format("SPD %4d  V/S %+.1f", floor(SPEED), plane.fy * SPEED), 8, y0 + LH, 235, 240, 250)
  text(string.format("HDG %03d %-2s PIT %+d", floor(hdg + 0.5) % 360, WIND[floor((hdg + 22.5) / 45) % 8 + 1], floor(pitch + 0.5)),
       8, y0 + LH * 2, 235, 240, 250)
  text(string.format("ROLL %+d", -floor(math.deg(plane.bank) + 0.5)), 8, y0 + LH * 3, 235, 240, 250)
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

local last = now()
local nextT = last
local fps, frames, fpsT = 0, 0, last
local msAvg = 0
local timer

-- <= 20 FPS : timer (1 tick) ; > 20 FPS : attente active via evenements
local function schedule()
  local t0 = now()
  nextT = nextT + FRAME
  if nextT < t0 then nextT = t0 end
  if FRAME >= 0.05 then
    timer = os.startTimer(max(0, nextT - t0))
  else
    os.queueEvent("frame")
  end
end

if FRAME >= 0.05 then timer = os.startTimer(0) else os.queueEvent("frame") end

local ok, err = pcall(function()
  while true do
    local ev, p1 = os.pullEvent()
    if ev == "key" and p1 == keys.q then
      break
    elseif ev == "key" and p1 == keys.h then
      hudMode = hudMode % 3 + 1
    elseif ev == "frame" and now() < nextT then
      os.queueEvent("frame")
    elseif (ev == "timer" and p1 == timer) or ev == "frame" then
      local tnow = now()
      local dt = min(tnow - last, 0.2)
      last = tnow

      t = t + SPEED * dt
      updatePlane(t, dt)

      -- camera de poursuite lissee
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

      local r0 = now()
      drawSky()
      drawTerrain()
      drawPlane()
      local renderMs = (now() - r0) * 1000
      msAvg = msAvg == 0 and renderMs or (msAvg * 0.9 + renderMs * 0.1)

      drawHUD(fps, msAvg, t)
      gpu.updateDisplay(display)

      frames = frames + 1
      if tnow - fpsT >= 1 then
        fps = frames / (tnow - fpsT)
        frames, fpsT = 0, tnow
      end
      schedule()
    end
  end
end)

pcall(gpu.removeDisplay, display)
if not ok then error(err, 0) end
print("FlightDirectGPU termine.")
