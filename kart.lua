-- kart - гонки для DwOS: восемь машин, предметы, заносы и поворачивающаяся
-- под колёсами земля.
--
-- Мир здесь не рисуется лучами, как в doom, и не выкладывается тайлами,
-- как в марио. Земля - одна плоскость, и видно её всю сразу. Для строки
-- экрана y расстояние до земли не зависит ни от чего, кроме самой строки:
--
--     z = высота камеры * фокус / (y - горизонт)
--
-- а значит, строку можно пройти слева направо с постоянным шагом по
-- карте - двумя сложениями на точку, без деления и без floor. Это тот
-- самый приём, которым на приставках делали гонки с поворачивающейся
-- дорогой, и он даёт то, чего рейкастер не умеет: поворачивается вся
-- земля, а не стены вокруг игрока.
--
--   kart.lua [--sound] [--fps] [--track=N] [--laps=N] [--keys]
--
-- --sound включает звук: computer.beep занимает машину на всю длительность
-- сигнала, то есть стоит кадра, поэтому по умолчанию тихо.
--
-- Для отладки: --trace пишет в stderr, что происходит, --prof печатает
-- разбивку времени по кадру, --seed=N делает случайность повторяемой,
-- --nocpu убирает соперников, --auto отдаёт машину игрока тому же ИИ,
-- --map печатает собранную трассу клетками и выходит, --fullscan
-- заставляет сверять весь экран вместо помеченных областей.

local opt = {}
for _, a in ipairs({ ... }) do
	local k, v = a:match("^%-%-([%w_]+)=?(.*)$")
	if k then opt[k] = v ~= "" and v or true end
end

local component = require("component")
local computer = require("computer")

--- Занятая память в КБ: в песочнице машины collectgarbage нет, там
--- считаем по computer.freeMemory.
local function memUsed()
	if collectgarbage then collectgarbage() return collectgarbage("count") end
	return (computer.totalMemory() - computer.freeMemory()) / 1024
end
local MEM0 = memUsed()

-- lib/event нужен не сам по себе, а тем, что при загрузке ставит свой
-- computer.pullSignal: в нём и Ctrl+Alt+C, и таймеры системы. Очередь
-- игра разбирает уже через него.
require("event")
local unicode = require("unicode")
local gpu = component.gpu

-- gfx у DwOS системный и лежит в package.loaded с самой загрузки, так что
-- require не стоит ни одного чтения с диска.
local gfx = require("gfx")

-- Каталог самой игры: картинки лежат рядом с ней, а ярлык из /bin зовёт
-- её из любого места, поэтому путь берётся из имени куска.
local art
do
	local dir = "/home/games"
	for i = 1, 4 do
		local d = debug.getinfo(i, "S")
		local p = d and d.source and d.source:match("^[=@]?(.*)/[^/]*%.lua$")
		if p and p ~= "" then dir = p break end
	end
	local chunk, err = loadfile(dir .. "/kartart.lua")
	if not chunk then error("не найден " .. dir .. "/kartart.lua: " .. tostring(err), 0) end
	art = chunk()
end

if opt.seed then math.randomseed(tonumber(opt.seed) or 1) end

local floor, ceil, abs, sqrt = math.floor, math.ceil, math.abs, math.sqrt
local min, max, random = math.min, math.max, math.random
local sin, cos, pi = math.sin, math.cos, math.pi
local byte = string.byte
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
local clock = os.clock or function() return computer.uptime() end

------------------------------------------------------------------ размеры

local HUD = 2                   -- строк символов под счёт
local TOP = HUD * 2             -- ... это столько точек
local VW, VH = 160, 96          -- окно вида в точках
local VY0, VY1 = TOP + 1, TOP + VH
local HOR = VY0 + 29            -- строка горизонта: выше неё небо
local FOCAL = 90                -- фокус камеры в точках
local CAMH = 1.2                -- камера над землёй, тайлов
local CAMBACK = 2.6             -- камера позади машины, тайлов
local ZMAX = 30                 -- дальше этого земля не считается - дымка
local TEX = 8                   -- точек в тайле
local MW = 40                   -- клеток в стороне карты
local MS = 64                   -- ширина массива карты: за MW идёт пустота
local HALFX = -(VW - 1) / 2     -- от центра строки до её левого края

-- Разбор текселя на клетку и точку внутри неё. Таблицы посчитаны с
-- запасом в обе стороны: уехать взглядом за край мира можно, а лишней
-- проверки в горячем цикле быть не должно - там, за краем, лежит клетка
-- поля, и мир просто продолжается.
--
-- Отрицательных ключей в таблицах нет нарочно: Lua кладёт их в хэш-часть,
-- а это вдвое больше памяти на запись. Поэтому координата сдвинута на
-- LOOKOFF, и сдвиг этот прибавляется раз на строку, а не на точку.
local LOOKOFF, LOOKMAX = 512, 1535
local TCOL, TROW, TFX, TFY = {}, {}, {}, {}
do
	local VOIDCELL = 50         -- строка и столбец за краем карты
	for i = 0, LOOKMAX do
		local t = i - LOOKOFF
		local cell = (t >= 0 and t < MW * TEX) and floor(t / TEX) or VOIDCELL
		TCOL[i] = cell
		TROW[i] = cell * MS
		-- LOOKOFF кратен размеру тайла, поэтому остаток от сдвига не
		-- зависит: i % TEX и t % TEX - одно и то же
		local r = i % TEX
		TFX[i] = r + 1
		TFY[i] = r * TEX
	end
end

------------------------------------------------------------------ холст

local scr = gfx.new(gpu, 160, 50)
scr:reserveTop(HUD)
if opt.fullscan then scr.fullScan = true end
local fb, pw = scr.fb, scr.pw

------------------------------------------------------------------ атлас тайлов

-- Все тайлы лежат в одном плоском массиве: цвет точки (px, py) тайла n -
-- это ATLAS[n * 64 + py * 8 + px + 1]. В сетке карты хранится сразу n * 64,
-- поэтому в горячем цикле нет ни одного умножения.

local ATLAS = {}
local TILEN = {}        -- имя <-> номер тайла
local TILET = {}        -- номер -> свойства поверхности
local SPR = {}          -- общие картинки
local KART = {}         -- [гонщик][сторона] -> картинка
local LINETILE, BOOSTTILE

do
	--- Развернуть картинку из строк: цифра - цвет, точка - дырка.
	---
	--- Точки лежат не таблицей, а строкой, по байту на точку: у восьми
	--- гонщиков одиннадцать картинок каждому, и таблицей это вышло бы
	--- под треть мегабайта - по шестнадцать байт на точку. Прозрачность
	--- это 16, то есть значение, которого у цвета быть не может.
	local function buildArt(rows, recol)
		local h, w = #rows, #rows[1]
		local px = {}
		for y = 1, h do
			local r = rows[y]
			for x = 1, w do
				local c = r:sub(x, x)
				local v = c ~= "." and tonumber(c, 16) or nil
				if v and recol then v = recol[v] or v end
				px[(y - 1) * w + x] = v or 16
			end
		end
		return { w = w, h = h, px = string.char(table.unpack(px)) }
	end

	--- Отражение по горизонтали: половину сторон машины рисовать не нужно.
	local function flipArt(a)
		local px, w = {}, a.w
		for y = 0, a.h - 1 do
			for x = 1, w do px[y * w + x] = a.px:byte(y * w + (w + 1 - x)) end
		end
		return { w = w, h = a.h, px = string.char(table.unpack(px)) }
	end

	local function mirrorX(rows)
		local r = {}
		for i, s in ipairs(rows) do r[i] = s:reverse() end
		return r
	end

	local function mirrorY(rows)
		local r = {}
		for i = 1, #rows do r[i] = rows[#rows - i + 1] end
		return r
	end

	local function rot90(rows)
		local h, w = #rows, #rows[1]
		local r = {}
		for y = 1, w do
			local line = {}
			for x = 1, h do line[x] = rows[h - x + 1]:sub(y, y) end
			r[y] = table.concat(line)
		end
		return r
	end

	-- Стрелка ускорителя нарисована одна - вправо; остальные семь
	-- поворотов это её отражения и поворот на четверть.
	local derived = {
		{ "boostHL",  "boostH",  mirrorX },
		{ "boostVD",  "boostH",  rot90 },
		{ "boostVU",  "boostH",  function(r) return mirrorY(rot90(r)) end },
		{ "boostD2",  "boostD1", mirrorX },
		{ "boostD1B", "boostD1", function(r) return mirrorY(mirrorX(r)) end },
		{ "boostD2B", "boostD1", mirrorY },
	}

	local n = 0
	local function addTile(name, rows, propName)
		n = n + 1
		TILEN[name] = n
		TILEN[n] = name
		TILET[n] = art.terrain[propName or name] or art.terrain.road
		local o = n * 64
		for y = 0, 7 do
			local r = rows[y + 1]
			for x = 0, 7 do
				ATLAS[o + y * 8 + x + 1] = tonumber(r:sub(x + 1, x + 1), 16) or 0
			end
		end
	end

	for _, name in ipairs(art.tileOrder) do addTile(name, art.tiles[name], name) end
	for _, d in ipairs(derived) do addTile(d[1], d[3](art.tiles[d[2]]), d[2]) end

	-- Направление -> какой тайл класть. Разметке хватает четырёх наклонов
	-- (у черты нет начала и конца), стрелке нужно восемь.
	LINETILE = { TILEN.lineH, TILEN.lineD2, TILEN.lineV, TILEN.lineD1 }
	BOOSTTILE = {
		TILEN.boostH, TILEN.boostD2B, TILEN.boostVD, TILEN.boostD1B,
		TILEN.boostHL, TILEN.boostD2, TILEN.boostVU, TILEN.boostD1,
	}

	for _, s in ipairs({ "itemBox", "coin", "banana", "mushroom", "star", "bolt",
	                     "pipe", "tree", "palm", "torch", "lakitu", "smoke", "spark" }) do
		SPR[s] = buildArt(art.sprites[s])
	end
	-- зелёный панцирь и красный - одна картинка с разной перекраской
	SPR.shellGreen = buildArt(art.sprites.shell, { [8] = 15 })
	SPR.shellRed = buildArt(art.sprites.shell)

	local sides = { "kartBack", "kartBack3", "kartSide", "kartFront3", "kartFront" }
	for i, r in ipairs(art.racers) do
		local recol = { [8] = r.body, [12] = r.trim }
		local set = {}
		for s, name in ipairs(sides) do set[s] = buildArt(art.sprites[name], recol) end
		-- стороны 6..8 - это 4..2 наоборот
		set[6] = flipArt(set[4])
		set[7] = flipArt(set[3])
		set[8] = flipArt(set[2])
		set.me = buildArt(art.sprites.meMid, recol)
		set.meL = buildArt(art.sprites.meLeft, recol)
		set.meR = flipArt(set.meL)
		KART[i] = set
	end
end

local T_VOID   = TILEN.void
local T_ROAD   = TILEN.road
local T_CURB   = TILEN.curb
local T_START  = TILEN.start
local T_SHOULD = TILEN.shoulder
local T_OIL    = TILEN.oil

------------------------------------------------------------------ состояние

local G = {
	state = "title",      -- title, select, count, race, finish, cup
	track = 1,
	laps = tonumber(opt.laps) or 3,
	me = 1,               -- каким гонщиком играем
	msg = "", msgT = 0,
	fps = 0, hudDirty = true,
}

local L = {}              -- разобранная трасса
local karts = {}          -- машины, karts[1] - игрок
local objs = {}           -- ящики, монеты, бананы, панцири, придорожное
local order = {}          -- машины по местам
local points = {}         -- очки кубка по гонщикам
local MAP, TER = {}, {}   -- сетка мира: смещение в атласе и поверхность

local function trace(fmt, ...)
	if not opt.trace then return end
	io.stderr:write("[kart] " .. fmt:format(...) .. "\n")
end

local lastBeep = 0
local function beep(f, d)
	if not opt.sound then return end
	local now = computer.uptime()
	if now - lastBeep < 0.12 then return end
	lastBeep = now
	pcall(computer.beep, f, d or 0.05)
end

local function say(m, t)
	G.msg, G.msgT = m, t or 2
	G.hudDirty = true
end

------------------------------------------------------------------ трасса

--- Точка замкнутой кривой Катмулла-Рома по опорным точкам.
local function spline(p, i, t)
	local n = #p / 2
	local function px(k) return p[((k - 1) % n) * 2 + 1] end
	local function py(k) return p[((k - 1) % n) * 2 + 2] end
	local t2, t3 = t * t, t * t * t
	local function c(a, b, cc, d)
		return 0.5 * (2 * b + (cc - a) * t + (2 * a - 5 * b + 4 * cc - d) * t2
			+ (-a + 3 * b - 3 * cc + d) * t3)
	end
	return c(px(i - 1), px(i), px(i + 1), px(i + 2)),
	       c(py(i - 1), py(i), py(i + 1), py(i + 2))
end

local function setCell(cx, cy, tile)
	if cx < 0 or cy < 0 or cx >= MW or cy >= MW then return end
	local o = cy * MS + cx
	MAP[o] = tile * 64
	TER[o] = tile
end

--- Круглый штамп: всё, что ближе r к точке, становится этим тайлом.
local function stamp(x, y, r, tile)
	local r2 = r * r
	local x0, x1 = floor(x - r), floor(x + r)
	local y0, y1 = floor(y - r), floor(y + r)
	if x0 < 0 then x0 = 0 end
	if y0 < 0 then y0 = 0 end
	if x1 >= MW then x1 = MW - 1 end
	if y1 >= MW then y1 = MW - 1 end
	local t64 = tile * 64
	for cy = y0, y1 do
		local o = cy * MS
		local dy = cy + 0.5 - y
		local dy2 = dy * dy
		for cx = x0, x1 do
			local dx = cx + 0.5 - x
			if dx * dx + dy2 <= r2 then
				MAP[o + cx] = t64
				TER[o + cx] = tile
			end
		end
	end
end

--- Куда смотрит отрезок: номер наклона для разметки и для стрелок.
local function dirSlot(dx, dy, slots)
	local a = atan2(dy, dx) / pi * (slots / 2)
	return floor(a + 0.5) % slots + 1
end

local function tileAt(x, y)
	if x < 0 or y < 0 or x >= MW or y >= MW then return L.field or T_VOID end
	return TER[floor(y) * MS + floor(x)] or T_VOID
end

local function terrainAt(x, y)
	return TILET[tileAt(x, y)] or art.terrain.void
end

--- Собрать трассу: поле, обочина, бордюр, дорога, разметка, предметы и
--- путевые точки - всё из одной осевой линии.
local function buildTrack(n)
	local tr = art.tracks[n]
	local th = art.themes[tr.theme]
	L = { name = tr.name, theme = th, def = tr, width = tr.width, num = n }

	-- 1. поле: два тайла в шахматку, чтобы трава не была заливкой
	local f1 = TILEN[th.field == "grass" and "grass" or "water"]
	local f2 = TILEN[th.field == "grass" and "grass2" or "water2"]
	L.field = f1
	-- Заливается вся сетка, включая то, что лежит за краем карты: туда
	-- смотрит взгляд на прямой, и мир должен продолжаться полем, а не
	-- обрываться в чёрное. Клетка, в которую таблицы сводят всё, что
	-- вообще за пределами, тоже попадает сюда.
	for cy = 0, MS - 1 do
		local o = cy * MS
		for cx = 0, MS - 1 do
			local t = ((cx + cy) % 2 == 0) and f1 or f2
			MAP[o + cx] = t * 64
			TER[o + cx] = t
		end
	end

	-- 2. плотная выборка кривой: по ней и красим, и считаем длину
	local pts, cum = {}, {}
	local segs = #tr.path / 2
	local prevx, prevy, total = nil, nil, 0
	for i = 1, segs do
		for k = 0, 23 do
			local x, y = spline(tr.path, i, k / 24)
			if prevx then total = total + sqrt((x - prevx) ^ 2 + (y - prevy) ^ 2) end
			pts[#pts + 1] = x
			pts[#pts + 1] = y
			cum[#cum + 1] = total
			prevx, prevy = x, y
		end
	end
	local nP = #cum
	total = total + sqrt((pts[1] - prevx) ^ 2 + (pts[2] - prevy) ^ 2)
	L.len = total

	-- 3. дорога штампами вдоль кривой. Порядок важен: обочина шире всех,
	-- бордюр уже, дорога уже всех, и каждый слой перекрывает края
	-- предыдущего - поэтому отдельных контуров рисовать не надо.
	local half = tr.width / 2
	for _, layer in ipairs({ { half + 1.5, T_SHOULD }, { half + 0.5, T_CURB },
	                         { half, T_ROAD } }) do
		for i = 1, nP do
			stamp(pts[i * 2 - 1], pts[i * 2], layer[1], layer[2])
		end
	end

	-- 4. разметка: пунктир по осевой, наклон черты - по направлению пути
	local dashOn, dashD = true, 0
	for i = 1, nP do
		local x, y = pts[i * 2 - 1], pts[i * 2]
		local j = i % nP + 1
		local dx, dy = pts[j * 2 - 1] - x, pts[j * 2] - y
		local step = sqrt(dx * dx + dy * dy)
		dashD = dashD + step
		if dashD > 1.5 then dashD = 0 dashOn = not dashOn end
		if dashOn and step > 0 then
			local cx, cy = floor(x), floor(y)
			if cx >= 0 and cy >= 0 and cx < MW and cy < MW
				and TER[cy * MS + cx] == T_ROAD then
				setCell(cx, cy, LINETILE[dirSlot(dx, dy, 4)])
			end
		end
	end

	-- 5. линия старта поперёк дороги
	local sx, sy = pts[1], pts[2]
	local dx, dy = pts[3] - sx, pts[4] - sy
	local dl = sqrt(dx * dx + dy * dy)
	dx, dy = dx / dl, dy / dl
	L.startx, L.starty, L.startdx, L.startdy = sx, sy, dx, dy
	local t = -half - 0.4
	while t <= half + 0.4 do
		stamp(sx - dy * t, sy + dx * t, 0.5, T_START)
		t = t + 0.25
	end

	-- 6. путевые точки: та же кривая с ровным шагом. По ним едут
	-- соперники, считаются круги и места, и на них же Лакиту возвращает
	-- вылетевших.
	local wps, want, i = {}, 0, 1
	while want < total do
		while i < nP and cum[i] < want do i = i + 1 end
		wps[#wps + 1] = { x = pts[i * 2 - 1], y = pts[i * 2] }
		want = want + 1.2
	end
	for k = 1, #wps do
		local nk = wps[k % #wps + 1]
		local ddx, ddy = nk.x - wps[k].x, nk.y - wps[k].y
		local dd = sqrt(ddx * ddx + ddy * ddy)
		if dd < 0.001 then ddx, ddy, dd = 1, 0, 1 end
		wps[k].dx, wps[k].dy = ddx / dd, ddy / dd
	end
	L.wp = wps
	L.nwp = #wps

	-- 7. что расставил автор трассы: доля круга s и смещение вбок
	objs = {}
	local function at(s, off)
		local k = floor(s * L.nwp) % L.nwp + 1
		local w = L.wp[k]
		return w.x - w.dy * (off or 0), w.y + w.dx * (off or 0), w
	end
	for _, c in ipairs(tr.cmds or {}) do
		local kind = c[1]
		if kind == "boxes" or kind == "coins" then
			local cnt = c[3]
			for j = 1, cnt do
				local off = (j - (cnt + 1) / 2) * (tr.width / (cnt + 0.4))
				local x, y = at(c[2], off)
				objs[#objs + 1] = { x = x, y = y, live = true,
					kind = kind == "boxes" and "box" or "coin",
					h = kind == "boxes" and 0.46 or 0.3 }
			end
		elseif kind == "pad" then
			local x, y, w = at(c[2], c[3])
			local tl = BOOSTTILE[dirSlot(w.dx, w.dy, 8)]
			for ay = -1, 1 do
				for ax = -1, 1 do setCell(floor(x) + ax, floor(y) + ay, tl) end
			end
		elseif kind == "oil" then
			local x, y = at(c[2], c[3])
			stamp(x, y, 0.8, T_OIL)
		elseif kind == "obj" then
			local x, y = at(c[2], c[3])
			objs[#objs + 1] = { x = x, y = y, live = true, kind = "prop",
				spr = c[4], h = c[4] == "torch" and 0.85 or 1.4 }
		elseif kind == "tile" then
			setCell(c[2], c[3], TILEN[c[4]] or T_ROAD)
		elseif kind == "fill" then
			for cy = c[3], c[5] do
				for cx = c[2], c[4] do setCell(cx, cy, TILEN[c[6]] or T_ROAD) end
			end
		end
	end
	trace("трасса %s: длина %.1f, точек %d, предметов %d", L.name, total, L.nwp, #objs)
end

-- --map печатает собранную трассу клетками в stderr и выходит. Это нужно
-- тому, кто двигает опорные точки: видно, что из них вышло, и гонку для
-- этого запускать не надо.
local function dumpMap()
	local ch = { road = ".", curb = "#", start = "=", shoulder = ":",
	             grass = ",", grass2 = " ", water = "~", water2 = " ",
	             dirt = "d", bridge = "B", oil = "o", void = "?" }
	for y = 0, MW - 1 do
		local line = {}
		for x = 0, MW - 1 do
			local name = TILEN[TER[y * MS + x]] or "void"
			line[x + 1] = ch[name] or (name:find("^line") and "-")
				or (name:find("^boost") and ">") or "?"
		end
		io.stderr:write(table.concat(line) .. "\n")
	end
	io.stderr:write(("%s: %.1f тайлов, %d путевых точек\n"):format(L.name, L.len, L.nwp))
end

------------------------------------------------------------------ палитра и небо

local curPal
local function setPalette(force)
	local key = L.num or 0
	if curPal == key and not force then return end
	curPal = key
	local p = {}
	for i = 0, 15 do p[i] = art.palette[i] end
	for i, v in pairs(L.theme.palette) do p[i] = v end
	scr:palette(p)
end

-- Небо. Панорама не хранится точками: на каждый её столбец известна
-- только высота гребня холмов, а цвет строки берётся из таблицы. Ширина
-- панорамы - ровно полный оборот при этом фокусе, поэтому в повороте даль
-- едет с той же скоростью, что и земля, и мир не разъезжается.
local PANW = floor(2 * pi * FOCAL + 0.5)
local RIDGE, SKYROW, clouds = {}, {}, {}

local function buildSky()
	local hills = L.theme.hills or 0.5
	local base = HOR - 5
	for x = 0, PANW - 1 do
		local a = x / PANW * 2 * pi
		local h = sin(a * 3) * 3.2 + sin(a * 5 + 1.3) * 2.1 + sin(a * 11 + 0.7) * 1.1
		RIDGE[x] = floor(base - (h + 4) * hills)
	end
	for y = VY0, HOR do
		local t = (y - VY0) / (HOR - VY0)
		-- к горизонту небо выцветает: через строку подмешивается дымка
		SKYROW[y] = (t > 0.72 and (y % 2 == 0 or t > 0.9)) and 3 or 13
	end
	clouds = {}
	if L.theme.clouds then
		for i = 1, 7 do
			clouds[i] = { x = floor(PANW * (i - 0.5) / 7) + (i * 53) % 40,
			              y = VY0 + 1 + (i * 7) % 7, w = 8 + (i * 5) % 9 }
		end
	end
end

--- Небо рисуется только когда оно сдвинулось: на прямой это каждый раз
--- один и тот же столбик, и трогать его незачем.
local lastSky
local function drawSky(ang, force)
	local off = floor(ang / (2 * pi) * PANW + 0.5) % PANW
	if off == lastSky and not force then return end
	lastSky = off
	for x = 1, VW do
		local r = RIDGE[(off + x - 1) % PANW]
		for y = VY0, HOR do
			local c
			if y < r then c = SKYROW[y]
			elseif y < r + 2 then c = 6
			else c = 5 end
			fb[(y - 1) * pw + x] = c
		end
	end
	for _, cl in ipairs(clouds) do
		local cx = (cl.x - off) % PANW
		if cx < VW + 12 then
			for dy = 0, 2 do
				local yy = cl.y + dy
				local w = cl.w - dy * 3
				for dx = -w, w do
					local xx = floor(cx + dx)
					if xx >= 1 and xx <= VW and yy < RIDGE[(off + xx - 1) % PANW] then
						fb[(yy - 1) * pw + xx] = 4
					end
				end
			end
		end
	end
	scr:touch(1, VY0, VW, HOR - VY0 + 1)
end

------------------------------------------------------------------ земля

-- Всё, что зависит только от строки экрана, посчитано один раз: строка не
-- двигается, двигается мир под ней.
local ZROW, ZSTEP, ROWN, ROWFADE = {}, {}, {}, {}
local HAZE1 = {}
local GY0                       -- первая строка, где земля ближе ZMAX

for c = 0, 15 do HAZE1[c] = art.hazier[c] or c end
for y = HOR + 1, VY1 do
	local sy = y - HOR
	local z = CAMH * FOCAL / sy
	ZROW[y] = z
	ZSTEP[y] = z * TEX / FOCAL              -- текселей на точку вбок
	if z <= ZMAX and not GY0 then GY0 = y end
	-- Чем ближе строка, тем крупнее на ней тексель: у нижних строк один и
	-- тот же тексель ложится на две-три точки подряд, и спрашивать карту
	-- на каждую из них незачем. Это снимает больше половины выборок.
	local n = floor(0.85 / ZSTEP[y])
	ROWN[y] = (n < 1 and 1) or (n > 3 and 3) or n
	ROWFADE[y] = z > 13 and HAZE1 or nil
end
GY0 = GY0 or HOR + 1

local camX, camY, camA = 20, 20, 0
local camCos, camSin = 1, 0

--- Земля: на строку - одно деление, дальше только сложения.
local function drawGround()
	local cosA, sinA = camCos, camSin
	local rx, ry = -sinA, cosA          -- вправо от направления взгляда
	local cxT, cyT = camX * TEX + LOOKOFF, camY * TEX + LOOKOFF
	local A, M = ATLAS, MAP
	local col, row, ffx, ffy = TCOL, TROW, TFX, TFY
	local fogc = 13

	-- у горизонта земля дальше, чем её имеет смысл считать: там дымка
	for y = HOR + 1, GY0 - 1 do
		local o = (y - 1) * pw
		for x = o + 1, o + VW do fb[x] = fogc end
	end

	for y = GY0, VY1 do
		local zt = ZROW[y] * TEX
		local st = ZSTEP[y]
		local n = ROWN[y]
		local sxs, sys = rx * st, ry * st
		local wx = cxT + cosA * zt + sxs * HALFX
		local wy = cyT + sinA * zt + sys * HALFX
		local o = (y - 1) * pw
		local fade = ROWFADE[y]
		if n > 1 then sxs, sys = sxs * n, sys * n end
		local itx = floor(wx)
		local ity = floor(wy)
		local fx, fy = wx - itx, wy - ity
		local isx, isy = floor(sxs), floor(sys)
		local fsx, fsy = sxs - isx, sys - isy
		if itx < 0 or itx > LOOKMAX or ity < 0 or ity > LOOKMAX then
			for x = o + 1, o + VW do fb[x] = fogc end
		elseif fade then
			for x = o + 1, o + VW do
				fb[x] = fade[A[M[row[ity] + col[itx]] + ffy[ity] + ffx[itx]]]
				itx = itx + isx fx = fx + fsx
				if fx >= 1 then fx = fx - 1 itx = itx + 1 end
				ity = ity + isy fy = fy + fsy
				if fy >= 1 then fy = fy - 1 ity = ity + 1 end
			end
		elseif n == 1 then
			for x = o + 1, o + VW do
				fb[x] = A[M[row[ity] + col[itx]] + ffy[ity] + ffx[itx]]
				itx = itx + isx fx = fx + fsx
				if fx >= 1 then fx = fx - 1 itx = itx + 1 end
				ity = ity + isy fy = fy + fsy
				if fy >= 1 then fy = fy - 1 ity = ity + 1 end
			end
		elseif n == 2 then
			local x, last = o + 1, o + VW - 1
			while x <= last do
				local c = A[M[row[ity] + col[itx]] + ffy[ity] + ffx[itx]]
				fb[x] = c fb[x + 1] = c
				x = x + 2
				itx = itx + isx fx = fx + fsx
				if fx >= 1 then fx = fx - 1 itx = itx + 1 end
				ity = ity + isy fy = fy + fsy
				if fy >= 1 then fy = fy - 1 ity = ity + 1 end
			end
		else
			local x, last = o + 1, o + VW - 2
			while x <= last do
				local c = A[M[row[ity] + col[itx]] + ffy[ity] + ffx[itx]]
				fb[x] = c fb[x + 1] = c fb[x + 2] = c
				x = x + 3
				itx = itx + isx fx = fx + fsx
				if fx >= 1 then fx = fx - 1 itx = itx + 1 end
				ity = ity + isy fy = fy + fsy
				if fy >= 1 then fy = fy - 1 ity = ity + 1 end
			end
			if x <= o + VW then
				local c = A[M[row[ity] + col[itx]] + ffy[ity] + ffx[itx]]
				while x <= o + VW do fb[x] = c x = x + 1 end
			end
		end
	end
	scr:touch(1, HOR + 1, VW, VY1 - HOR)
end

------------------------------------------------------------------ спрайты в мире

local colTab = {}

--- Картинка, растянутая до w x h точек, с дырками и перекраской.
local function drawScaled(a, x, y, w, h, shade)
	if w < 1 or h < 1 then return end
	local x0, x1 = max(1, x), min(VW, x + w - 1)
	local y0, y1 = max(VY0, y), min(VY1, y + h - 1)
	if x1 < x0 or y1 < y0 then return end
	local aw, px = a.w, a.px
	local kx, ky = aw / w, a.h / h
	for i = x0, x1 do colTab[i] = floor((i - x) * kx) + 1 end
	for yy = y0, y1 do
		local ao = floor((yy - y) * ky) * aw
		local o = (yy - 1) * pw
		for xx = x0, x1 do
			local c = byte(px, ao + colTab[xx])
			if c ~= 16 then fb[o + xx] = shade and shade[c] or c end
		end
	end
	scr:touch(x0, y0, x1 - x0 + 1, y1 - y0 + 1)
end

--- Тень под машиной - это не чёрное пятно, а то, что под ней лежало,
--- прогнанное через таблицу затемнения: на траве тень зелёная, на дороге
--- серая, и всё это без единого лишнего цвета в палитре.
local function drawShadow(cx, cy, rx, ry)
	if rx < 1.5 or ry < 1 then return end
	local dark = art.darker
	local y0, y1 = max(VY0, floor(cy - ry)), min(VY1, floor(cy + ry))
	local x0, x1 = max(1, floor(cx - rx)), min(VW, floor(cx + rx))
	if x1 < x0 or y1 < y0 then return end
	for yy = y0, y1 do
		local dy = (yy - cy) / ry
		local w = 1 - dy * dy
		if w > 0 then
			w = sqrt(w) * rx
			local a, b = max(x0, floor(cx - w)), min(x1, floor(cx + w))
			local o = (yy - 1) * pw
			for xx = a, b do
				local c = fb[o + xx]
				fb[o + xx] = dark[c] or c
			end
		end
	end
	scr:touch(x0, y0, x1 - x0 + 1, y1 - y0 + 1)
end

-- Что рисовать в этом кадре: всё складывается в список, сортируется по
-- дальности и кладётся от дальнего к ближнему.
local draws = {}

--- minz - ближе какого расстояния предмет не рисуется. Своей машине это
--- ни к чему, а чужая, попавшая между камерой и игроком, закрыла бы
--- пол-экрана бампером - её лучше не показывать вовсе.
local function addDraw(x, y, spr, wh, hh, lift, shade, minz)
	local dx, dy = x - camX, y - camY
	local z = dx * camCos + dy * camSin
	if z < (minz or 0.4) or z > ZMAX then return end
	local l = dx * (-camSin) + dy * camCos
	local k = FOCAL / z
	local sx = (VW + 1) / 2 + l * k
	local sy = HOR + CAMH * k                  -- земля под предметом
	local w = floor(wh * k + 0.5)
	local h = floor(hh * k + 0.5)
	if w < 1 or h < 1 or sx < -w or sx > VW + w then return end
	local d = { z = z, spr = spr, x = floor(sx - w / 2),
	            y = floor(sy - h - (lift or 0) * k), w = w, h = h,
	            sx = sx, sy = sy, shade = shade }
	draws[#draws + 1] = d
	return d
end

local function farther(a, b) return a.z > b.z end

local function drawThings()
	table.sort(draws, farther)
	for i = 1, #draws do
		local d = draws[i]
		if d.shadow then drawShadow(d.sx, d.sy, d.w * 0.42, d.w * 0.15) end
		drawScaled(d.spr, d.x, d.y, d.w, d.h, d.shade)
	end
end

------------------------------------------------------------------ правила

-- Всё, из чего складывается поведение машины. Держать это одной таблицей
-- удобнее, чем дюжиной отдельных чисел: видно, что с чем сравнимо.
local CAR = {
	top = 7.4,          -- тайлов в секунду по чистой дороге
	accel = 1.7,        -- как быстро скорость подтягивается к своей
	brake = 8.0,
	drag = 2.4,
	turn = 2.3,         -- радиан в секунду
	driftTurn = 1.8,    -- во сколько раз круче руль в заносе
	grip = 9.0,         -- как быстро вектор скорости идёт за носом
	driftGrip = 2.3,
	boost = 11.5,       -- скорость под ускорением
	radius = 0.42,      -- для столкновений
}
local SUBSTEP = 0.03

local ITEMS = { "banana", "green", "red", "mushroom", "star", "bolt" }
-- Веса: {на первом месте, на последнем}. Отставшему чаще выпадает то, чем
-- можно догнать, - как в оригинале.
local WEIGHT = {
	banana   = { 40, 8 },
	green    = { 32, 12 },
	red      = { 10, 26 },
	mushroom = { 14, 30 },
	star     = { 2,  14 },
	bolt     = { 2,  10 },
}
local ITEMSPR = {
	banana = "banana", green = "shellGreen", red = "shellRed",
	mushroom = "mushroom", star = "star", bolt = "bolt",
}
local CUPPTS = { 9, 6, 3, 1, 0, 0, 0, 0 }

local function wrapAng(a)
	while a > pi do a = a - 2 * pi end
	while a < -pi do a = a + 2 * pi end
	return a
end

--- Ближайшая путевая точка по всей трассе: нужна только при рождении и
--- при возврате Лакиту.
local function nearestWp(x, y)
	local best, bd = 1, 1e9
	for i = 1, L.nwp do
		local w = L.wp[i]
		local d = (w.x - x) ^ 2 + (w.y - y) ^ 2
		if d < bd then bd = d best = i end
	end
	return best
end

--- А в гонке - только рядом с прошлой: трасса замкнута, и искать по всей
--- длине каждый кадр незачем.
local function findWp(k)
	local best, bd = k.wp, 1e9
	for i = k.wp - 6, k.wp + 12 do
		local j = (i - 1) % L.nwp + 1
		local w = L.wp[j]
		local d = (w.x - k.x) ^ 2 + (w.y - k.y) ^ 2
		if d < bd then bd = d best = j end
	end
	return best
end

local function rollItem(place, n)
	local t = n > 1 and (place - 1) / (n - 1) or 0
	local sum, pick = 0, {}
	for _, it in ipairs(ITEMS) do
		local w = WEIGHT[it]
		sum = sum + w[1] + (w[2] - w[1]) * t
		pick[#pick + 1] = { it, sum }
	end
	local r = random() * sum
	for _, p in ipairs(pick) do
		if r <= p[2] then return p[1] end
	end
	return "banana"
end

local function spinOut(k, why)
	if k.star > 0 or k.spin > 0 or k.fall > 0 then return end
	k.spin = 1.1
	k.spd = k.spd * 0.2
	k.drift, k.driftT = 0, 0
	k.coins = max(0, k.coins - 2)
	if k == karts[1] then
		if why then say(why) end
		beep(200, 0.12)
	end
end

local function dropObj(kind, k, ahead)
	local a = k.ang + (ahead and 0 or pi)
	local o = {
		kind = kind, live = true, owner = k,
		x = k.x + cos(a) * 0.9, y = k.y + sin(a) * 0.9,
		vx = 0, vy = 0, h = kind == "banana" and 0.28 or 0.34, life = 60,
	}
	objs[#objs + 1] = o
	return o
end

local function useItem(k)
	local it = k.item
	if not it or k.itemT > 0 then return end
	k.item = nil
	if k == karts[1] then G.hudDirty = true end
	if it == "mushroom" then
		k.boost = max(k.boost, 1.3)
		beep(900, 0.08)
	elseif it == "star" then
		k.star = 6
		beep(1200, 0.08)
	elseif it == "banana" then
		dropObj("banana", k, false)
	elseif it == "green" or it == "red" then
		local o = dropObj(it, k, true)
		o.vx, o.vy = cos(k.ang) * 13, sin(k.ang) * 13
		o.life = 5
		if it == "red" then
			for i = 1, #order do
				if order[i] == k and i > 1 then o.target = order[i - 1] end
			end
		end
		beep(700, 0.06)
	elseif it == "bolt" then
		for _, o in ipairs(karts) do
			if o ~= k and o.star <= 0 then
				o.small = 6
				o.spd = o.spd * 0.5
				if o.item and random() < 0.5 then o.item = nil end
			end
		end
		if k == karts[1] then say("МОЛНИЯ! ВСЕ СЖАЛИСЬ") end
		beep(300, 0.12)
	end
end

------------------------------------------------------------------ машина

local control = { gas = false, brake = false, left = false, right = false,
                  hop = false, hopNew = false }

local function newKart(racerIdx, gridPos, isAI)
	local r = art.racers[racerIdx]
	-- Стартовая решётка: по двое в ряд позади линии старта. Отступ
	-- отсчитывается по путевым точкам, а не по прямой, - иначе на
	-- повороте задние ряды оказались бы в траве.
	local rowN = floor((gridPos - 1) / 2)
	local side = (gridPos % 2 == 1) and -1 or 1
	local wi = (-floor((1.6 + rowN * 1.7) / 1.2)) % L.nwp + 1
	local w = L.wp[wi]
	local a = atan2(w.dy, w.dx)
	local k = {
		racer = racerIdx, ai = isAI, name = r.name, body = r.body,
		skill = r.skill, aggro = r.aggro,
		x = w.x - w.dy * side * 0.9,
		y = w.y + w.dx * side * 0.9,
		ang = a, vx = 0, vy = 0, spd = 0,
		-- круг 0: линия старта прямо перед решёткой, и первое её
		-- пересечение как раз и открывает первый круг
		lap = 0, half = true, prog = 0, place = gridPos, coins = 0,
		item = nil, itemT = 0, boost = 0, spin = 0, star = 0, small = 0,
		drift = 0, driftT = 0, hop = 0, fall = 0, back = 0, shake = 0,
		steerIn = 0, done = false, time = 0,
		lane = (random() - 0.5) * (L.width * 0.5),
	}
	k.wp = nearestWp(k.x, k.y)
	k.prog = k.lap * L.nwp + k.wp
	return k
end

--- Куда вернуть вылетевшего: на путевую точку, которую он прошёл.
local function respawn(k)
	local w = L.wp[k.wp]
	k.x, k.y = w.x, w.y
	k.ang = atan2(w.dy, w.dx)
	k.vx, k.vy, k.spd = 0, 0, 0
	k.fall, k.spin = 0, 0
end

local function driveAI(k, dt)
	local look = 3 + floor(k.spd * 0.55)
	local w = L.wp[(k.wp + look - 1) % L.nwp + 1]
	local tx = w.x - w.dy * k.lane
	local ty = w.y + w.dx * k.lane
	local diff = wrapAng(atan2(ty - k.y, tx - k.x) - k.ang)

	-- объехать банан, если он прямо по курсу
	for i = 1, #objs do
		local o = objs[i]
		if o.live and o.kind == "banana" then
			local dx, dy = o.x - k.x, o.y - k.y
			if dx * dx + dy * dy < 9 then
				local rel = wrapAng(atan2(dy, dx) - k.ang)
				if abs(rel) < 0.3 then diff = diff + (rel > 0 and -0.6 or 0.6) end
			end
		end
	end

	k.steerIn = max(-1, min(1, diff * 2.6))
	-- на крутом повороте соперник сбрасывает газ, но не до нуля: иначе он
	-- ползёт и гонки не выходит
	k.gasIn = abs(diff) < 0.8 or k.spd < CAR.top * 0.5
	k.brakeIn = false

	if k.item and k.itemT <= 0 then
		local it = k.item
		if it == "mushroom" then
			if abs(diff) < 0.2 then useItem(k) end
		elseif it == "star" or it == "bolt" then
			if random() < dt * 0.8 then useItem(k) end
		elseif it == "banana" then
			if random() < dt * 0.5 then useItem(k) end
		else
			for _, o in ipairs(karts) do
				if o ~= k then
					local dx, dy = o.x - k.x, o.y - k.y
					local d = sqrt(dx * dx + dy * dy)
					if d < 10 and abs(wrapAng(atan2(dy, dx) - k.ang)) < 0.28 then
						useItem(k)
						break
					end
				end
			end
		end
	end
end

local function stepKart(k, dt, racing)
	if k.fall > 0 then
		k.fall = k.fall - dt
		if k.fall <= 0 then respawn(k) end
		return
	end

	local ter = terrainAt(k.x, k.y)
	local kind = ter.kind

	-- вылет: пустота всегда, вода и лава - если тема такая
	if kind == "fall" or (kind == "field" and L.theme.deadly) then
		k.fall = 1.5
		k.spd, k.vx, k.vy = 0, 0, 0
		k.drift, k.driftT = 0, 0
		if k == karts[1] then
			say("ЛАКИТУ ВЫЛАВЛИВАЕТ")
			beep(180, 0.15)
		end
		return
	end

	if k.spin > 0 then k.spin = k.spin - dt end
	if k.star > 0 then k.star = k.star - dt end
	if k.small > 0 then k.small = k.small - dt end
	if k.boost > 0 then k.boost = k.boost - dt end
	if k.itemT > 0 then
		k.itemT = k.itemT - dt
		if k.itemT <= 0 and k == karts[1] then G.hudDirty = true end
	end

	local grip = ter.grip or 1
	local top = CAR.top * grip * (1 + k.coins * 0.010)
	if k.ai then
		top = top * k.skill
		-- резинка: отставший от игрока едет чуть быстрее, а оторвавшийся
		-- чуть медленнее. Без неё гонка расслаивается на первом круге, и
		-- обгонять становится некого.
		local me = karts[1]
		if me and me ~= k and not opt.nocpu then
			local d = (me.prog - k.prog) / L.nwp
			if d > 0.25 then d = 0.25 elseif d < -0.2 then d = -0.2 end
			top = top * (1 + d * 0.3)
		end
	end
	if k.star > 0 then top = top * 1.22 end
	if k.small > 0 then top = top * 0.66 end
	if kind == "boost" and racing then k.boost = max(k.boost, 0.7) end
	-- Масло крутит того, кто на него заехал, но только в этот миг: иначе
	-- остановившийся посреди пятна крутился бы на нём до конца гонки.
	local onOil = kind == "oil"
	if onOil and not k.wasOil and k.spd > 2.5 and k.star <= 0 then spinOut(k, "МАСЛО!") end
	k.wasOil = onOil
	if k.boost > 0 then top = max(top, CAR.boost * grip) end

	local gas, brk, steer
	if k.spin > 0 then
		gas, brk, steer = false, false, 0
		k.ang = k.ang + 13 * dt
	elseif k.ai then
		gas, brk, steer = k.gasIn, k.brakeIn, k.steerIn or 0
	else
		gas, brk = control.gas, control.brake
		steer = (control.left and -1 or 0) + (control.right and 1 or 0)
		k.steerIn = steer
	end
	if not racing then gas, brk = false, false end

	-- Прыжок и занос. Прыгнул с повёрнутым рулём - пошёл юзом: нос
	-- поворачивает быстрее обычного, а скорость догоняет его лениво, и
	-- машину несёт боком. Чем дольше держишь, тем сильнее мини-турбо на
	-- выходе - ровно как этому и учит оригинал.
	if not k.ai and k.spin <= 0 then
		if control.hopNew and k.hop <= 0 and k.drift == 0 and k.spd > 1.5 then
			k.hop = 0.26
		end
		if k.hop > 0 then
			k.hop = k.hop - dt
			if k.hop <= 0 and control.hop and steer ~= 0 then
				k.drift = steer
				k.driftT = 0
			end
		end
		if k.drift ~= 0 then
			if not control.hop or not gas or k.spd < 1.5 then
				if k.driftT > 1.25 then
					k.boost = max(k.boost, 0.85)
					say("МИНИ-ТУРБО!")
					beep(1000, 0.06)
				elseif k.driftT > 0.7 then
					k.boost = max(k.boost, 0.4)
				end
				k.drift, k.driftT = 0, 0
			else
				k.driftT = k.driftT + dt
				if steer ~= 0 then k.drift = steer end
			end
		end
	elseif k.spin > 0 then
		k.drift, k.driftT, k.hop = 0, 0, 0
	end

	if gas then
		k.spd = k.spd + (top - k.spd) * min(1, CAR.accel * dt)
	else
		k.spd = k.spd - CAR.drag * dt
	end
	if brk then k.spd = k.spd - CAR.brake * dt end
	if k.spd < 0 then k.spd = brk and max(k.spd, -2.2) or 0 end

	-- на месте руль не работает, как и положено
	local eff = min(1, abs(k.spd) / 2.2)
	if k.drift ~= 0 then
		k.ang = k.ang + k.drift * CAR.turn * CAR.driftTurn * eff * dt * (0.6 + 0.4 * abs(steer))
	else
		k.ang = k.ang + steer * CAR.turn * eff * dt * (k.spd < 0 and -1 or 1)
	end

	-- сцепление: вектор скорости подтягивается к носу, а в заносе лениво
	local g = (k.drift ~= 0) and CAR.driftGrip or CAR.grip
	local kk = min(1, g * dt)
	k.vx = k.vx + (cos(k.ang) * k.spd - k.vx) * kk
	k.vy = k.vy + (sin(k.ang) * k.spd - k.vy) * kk
	k.x = k.x + k.vx * dt
	k.y = k.y + k.vy * dt

	k.shake = ter.shake and (k.shake + dt * 20) or 0

	if k.x < -3 then k.x = -3 elseif k.x > MW + 3 then k.x = MW + 3 end
	if k.y < -3 then k.y = -3 elseif k.y > MW + 3 then k.y = MW + 3 end

	-- Круг засчитывается только тому, кто прошёл дальнюю половину трассы:
	-- иначе можно было бы вилять через линию старта туда-сюда.
	local prev = k.wp
	local nw = findWp(k)
	k.wp = nw
	if nw > L.nwp * 0.35 and nw < L.nwp * 0.75 then k.half = true end
	if prev > L.nwp * 0.8 and nw < L.nwp * 0.2 and k.half then
		k.half = false
		k.lap = k.lap + 1
		if k == karts[1] and k.lap > 1 and k.lap <= G.laps then
			say("КРУГ " .. k.lap .. " ИЗ " .. G.laps)
			beep(800, 0.06)
		end
	elseif prev < L.nwp * 0.2 and nw > L.nwp * 0.8 then
		k.lap = k.lap - 1
		k.half = true
	end
	k.prog = k.lap * L.nwp + nw
	local w = L.wp[nw]
	k.back = (k.vx * w.dx + k.vy * w.dy) < -0.5 and (k.back + dt) or 0
end

--- Столкновения: машины расталкиваются и теряют на этом скорость.
local function bumpKarts()
	local n = #karts
	for i = 1, n do
		local a = karts[i]
		if a.fall <= 0 then
			for j = i + 1, n do
				local b = karts[j]
				if b.fall <= 0 then
					local dx, dy = b.x - a.x, b.y - a.y
					local d2 = dx * dx + dy * dy
					local r = CAR.radius * 2
					if d2 < r * r and d2 > 0.0001 then
						local d = sqrt(d2)
						local push = (r - d) * 0.5
						local nx, ny = dx / d * push, dy / d * push
						a.x, a.y = a.x - nx, a.y - ny
						b.x, b.y = b.x + nx, b.y + ny
						if a.star > 0 and b.star <= 0 then spinOut(b, "ЗВЕЗДА!")
						elseif b.star > 0 and a.star <= 0 then spinOut(a, "ЗВЕЗДА!")
						else
							a.spd = a.spd * 0.93
							b.spd = b.spd * 0.93
						end
					end
				end
			end
		end
	end
end

local function stepObjs(dt, racing)
	for i = #objs, 1, -1 do
		local o = objs[i]
		local flying = o.kind == "green" or o.kind == "red"
		if flying then
			if o.target and o.kind == "red" then
				-- красный правит на цель, но лениво: от него можно уйти
				local want = atan2(o.target.y - o.y, o.target.x - o.x)
				local cur = atan2(o.vy, o.vx)
				local d = wrapAng(want - cur)
				local a = cur + max(-2.6 * dt, min(2.6 * dt, d))
				local sp = sqrt(o.vx * o.vx + o.vy * o.vy)
				o.vx, o.vy = cos(a) * sp, sin(a) * sp
			end
			o.x = o.x + o.vx * dt
			o.y = o.y + o.vy * dt
			o.life = o.life - dt
			if o.life <= 0 then o.live = false end
		elseif not o.live and o.back then
			o.back = o.back - dt
			if o.back <= 0 then o.live = true o.back = nil end
		end

		if o.live and racing then
			for _, k in ipairs(karts) do
				if k.fall <= 0 and not k.done then
					local dx, dy = o.x - k.x, o.y - k.y
					local d2 = dx * dx + dy * dy
					if o.kind == "box" then
						if d2 < 0.4 and not k.item and k.itemT <= 0 then
							o.live = false
							o.back = 5
							k.itemT = 0.8
							k.item = rollItem(k.place, #karts)
							if k == karts[1] then
								beep(600, 0.05)
								G.hudDirty = true
							end
						end
					elseif o.kind == "coin" then
						if d2 < 0.32 then
							o.live = false
							o.back = 9
							k.coins = min(20, k.coins + 1)
							if k == karts[1] then
								beep(1100, 0.04)
								G.hudDirty = true
							end
						end
					elseif o.kind == "prop" then
						-- В дерево можно въехать, но не застрять в нём:
						-- машину выталкивает наружу, иначе она крутилась
						-- бы у ствола до конца гонки.
						if d2 < 0.4 then
							local d = sqrt(d2)
							if d > 0.001 then
								local nx, ny = dx / d, dy / d
								k.x, k.y = o.x - nx * 0.7, o.y - ny * 0.7
								k.vx, k.vy = -nx * 1.5, -ny * 1.5
							end
							if k.spd > 2.5 then spinOut(k, "ТРЕСЬ!") end
							k.spd = min(k.spd, 1.5)
						end
					elseif o.kind == "banana" then
						-- свой банан не бьёт сразу: его роняют под себя, и
						-- наехать на него можно только вернувшись
						if d2 < 0.3 and (k ~= o.owner or o.life < 58) then
							o.live = false
							spinOut(k, "БАНАН!")
						end
					elseif flying then
						if d2 < 0.36 and (k ~= o.owner or o.life < 4.5) then
							o.live = false
							spinOut(k, "ПАНЦИРЬ!")
						end
					end
				end
			end
		end
		if not o.live and (o.kind == "banana" or flying) then table.remove(objs, i) end
	end
end

--- Места: по кругам и путевым точкам, а внутри точки - по тому, кто
--- ближе к следующей.
local function rankKarts()
	for _, k in ipairs(karts) do
		if k.done then
			k.sort = 1e6 - k.finishPlace
		else
			local w = L.wp[k.wp]
			k.sort = k.prog + ((k.x - w.x) * w.dx + (k.y - w.y) * w.dy) * 0.5
		end
	end
	local n = #karts
	for i = 1, n do order[i] = karts[i] end
	for i = 2, n do
		local v = order[i]
		local j = i - 1
		while j >= 1 and order[j].sort < v.sort do
			order[j + 1] = order[j]
			j = j - 1
		end
		order[j + 1] = v
	end
	for i = 1, n do order[i].place = i end
end

------------------------------------------------------------------ отрисовка гонки

--- Какая из восьми сторон машины видна отсюда.
local function kartSide(k)
	local rel = wrapAng(k.ang - atan2(k.y - camY, k.x - camX))
	local s = floor((rel + pi) / (2 * pi) * 8 + 0.5) % 8
	-- 0 - едет на камеру, 4 - от камеры
	return ((s + 4) % 8) + 1
end

local STARPAL = { 9, 4, 8, 15, 12, 14 }
local starShade = {}

local function kartShade(k, frame)
	if k.star <= 0 then return nil end
	local c = STARPAL[(frame % #STARPAL) + 1]
	for i = 0, 15 do starShade[i] = (i == 0 or i == 1) and i or c end
	return starShade
end

local frameNo = 0

local function drawRace()
	draws = {}
	local me = karts[1]
	-- за кем смотрит камера: в гонке это игрок, на заставке - лидер
	local cam = G.camKart or me

	for _, k in ipairs(karts) do
		local set = KART[k.racer]
		local spr, wh, hh
		local scale = k.small > 0 and 0.62 or 1
		if k == me and k.spin <= 0 and G.state ~= "title" then
			-- свою машину видно всегда сзади, зато крупно и с наклоном
			local st = set.me
			if k.drift ~= 0 then st = k.drift < 0 and set.meL or set.meR
			elseif k.steerIn < 0 then st = set.meL
			elseif k.steerIn > 0 then st = set.meR end
			spr, wh, hh = st, 0.98 * scale, 0.74 * scale
		else
			spr, wh, hh = set[kartSide(k)], 0.86 * scale, 0.62 * scale
		end
		local lift = 0
		if k.hop > 0 then lift = 0.14 end
		if k.fall > 0 then lift = -(1.5 - k.fall) * 0.7 end
		local d = addDraw(k.x, k.y, spr, wh, hh, lift, kartShade(k, frameNo),
			k ~= cam and 1.4 or nil)
		if d then d.shadow = k.fall <= 0 end
		-- дым из-под колёс в заносе, а когда мини-турбо набралось - искры
		if k.drift ~= 0 and frameNo % 2 == 0 then
			local s = k.driftT > 1.25 and SPR.spark or SPR.smoke
			addDraw(k.x - cos(k.ang) * 0.5, k.y - sin(k.ang) * 0.5, s, 0.3, 0.22, 0.05)
		end
		if k.fall > 0 and k.fall < 1.1 then
			addDraw(k.x, k.y, SPR.lakitu, 1.1, 0.95, 1.5 + k.fall * 0.4)
		end
	end

	for _, o in ipairs(objs) do
		if o.live then
			local spr
			if o.kind == "box" then spr = SPR.itemBox
			elseif o.kind == "coin" then spr = SPR.coin
			elseif o.kind == "banana" then spr = SPR.banana
			elseif o.kind == "green" then spr = SPR.shellGreen
			elseif o.kind == "red" then spr = SPR.shellRed
			elseif o.kind == "prop" then spr = SPR[o.spr] end
			if spr then
				local w = o.h * spr.w / spr.h
				local lift = 0
				if o.kind == "box" then lift = 0.24 + sin(frameNo * 0.25) * 0.05 end
				addDraw(o.x, o.y, spr, w, o.h, lift)
			end
		end
	end

	drawThings()
end

------------------------------------------------------------------ миникарта и счёт

local MINI, MINIW = {}, 28
local MINIX, MINIY = 3, VY0 + 2

--- Карта трассы рисуется один раз на гонку, а каждый кадр на неё только
--- ставятся точки машин.
local function buildMini()
	local k = MW / MINIW
	local plain = { [T_ROAD] = 3, [T_START] = 4, [T_CURB] = 8, [T_SHOULD] = 10 }
	for y = 0, MINIW - 1 do
		for x = 0, MINIW - 1 do
			local t = TER[floor(y * k) * MS + floor(x * k)] or T_VOID
			local c = plain[t]
			if not c then
				local name = TILEN[t] or ""
				if name:find("^line") or name:find("^boost") or name == "oil"
					or name == "bridge" then c = 3
				elseif name:find("^water") then c = 6
				elseif name == "dirt" then c = 11
				else c = 5 end
			end
			MINI[y * MINIW + x] = c
		end
	end
end

local function drawMini()
	for y = 0, MINIW - 1 do
		local o = (MINIY + y - 1) * pw + MINIX
		local mo = y * MINIW
		for x = 0, MINIW - 1 do fb[o + x] = MINI[mo + x] end
	end
	for x = -1, MINIW do
		fb[(MINIY - 2) * pw + MINIX + x] = 0
		fb[(MINIY + MINIW - 1) * pw + MINIX + x] = 0
	end
	for y = -1, MINIW do
		fb[(MINIY + y - 1) * pw + MINIX - 1] = 0
		fb[(MINIY + y - 1) * pw + MINIX + MINIW] = 0
	end
	local k = MINIW / MW
	for i = #karts, 1, -1 do
		local kt = karts[i]
		local x = MINIX + floor(kt.x * k)
		local y = MINIY + floor(kt.y * k)
		if x >= MINIX and x < MINIX + MINIW and y >= MINIY and y < MINIY + MINIW then
			-- своя машина мигает, чтобы её было видно среди семи чужих
			local c = (i == 1 and frameNo % 8 < 4) and 4 or kt.body
			fb[(y - 1) * pw + x] = c
		end
	end
	scr:touch(MINIX - 1, MINIY - 1, MINIW + 2, MINIW + 2)
end

local function drawItemSlot()
	local k = karts[1]
	local x0, y0, w, h = VW - 22, VY0 + 2, 20, 18
	for y = y0, y0 + h - 1 do
		local o = (y - 1) * pw
		local edge = (y == y0 or y == y0 + h - 1)
		for x = x0, x0 + w - 1 do
			fb[o + x] = (edge or x == x0 or x == x0 + w - 1) and 0 or 1
		end
	end
	local it = k.item
	-- пока рулетка крутится, в окошке мелькает всё подряд
	if k.itemT > 0 then it = ITEMS[floor(frameNo / 2) % #ITEMS + 1] end
	if it then
		local spr = SPR[ITEMSPR[it]]
		local ww, hh = floor(spr.w * 1.4), floor(spr.h * 1.4)
		drawScaled(spr, x0 + floor((w - ww) / 2), y0 + floor((h - hh) / 2), ww, hh)
	end
	scr:touch(x0, y0, w, h)
end

local hudCache = {}

--- Дополнить до n знакомест. string.format этого не умеет: он считает
--- байты, а в кириллице их по два на букву, и колонки разъезжаются.
local function pad(s, n)
	return s .. string.rep(" ", max(0, n - unicode.len(s)))
end

local function fmtTime(t)
	if not t then return "--:--.-" end
	return ("%d:%04.1f"):format(floor(t / 60), t % 60)
end

local function drawHUD()
	if not G.hudDirty and not opt.fps and not opt.keys then return end
	G.hudDirty = false
	local k = karts[1]
	local line = ("МЕСТО %d/%d   КРУГ %d/%d   %s   МОНЕТ %2d   %s"):format(
		k.place, #karts, min(max(k.lap, 1), G.laps), G.laps,
		fmtTime(k.time), k.coins, L.name)
	if hudCache.line ~= line then
		hudCache.line = line
		scr:text(2, 1, line .. "   ", 4, 0)
	end
	local msg = G.msgT > 0 and G.msg or ""
	if k.back > 1.2 and G.state == "race" then msg = "НЕ ТУДА!" end
	if hudCache.msg ~= msg then
		hudCache.msg = msg
		scr:text(2, 2, msg .. string.rep(" ", max(0, 42 - unicode.len(msg))), 9, 0)
	end
	if opt.keys and hudCache.key ~= G.lastKey then
		hudCache.key = G.lastKey
		scr:text(scr.w - 26, 2, "клавиша: " .. (G.lastKey or "-") .. "      ", 3, 0)
	end
	if opt.fps then
		local f = ("фпс %2d%s"):format(floor((G.fps or 0) + 0.5), scr.buf and "" or " без VRAM")
		if hudCache.fps ~= f then
			hudCache.fps = f
			scr:text(scr.w - 42, 2, f, 3, 0)
		end
	end
end

------------------------------------------------------------------ экраны

--- Надпись поверх кадра. Кадр при этом остаётся в буфере, поэтому текст
--- ложится на картинку, а не на пустой экран.
local function banner(lines, row0, fg)
	for i, l in ipairs(lines) do
		local text, color = l, fg or 4
		if text:sub(1, 1) == "~" then color = 9 text = text:sub(2) end
		if text:sub(1, 1) == "#" then color = 8 text = text:sub(2) end
		local len = unicode.len(text)
		local x = max(1, floor((scr.w - len) / 2) + 1)
		scr:text(x, row0 + i - 1, text, color, 0)
	end
end

local function screenBegin(bg)
	-- Строки счёта холст сам не проверяет (они отданы под текст), поэтому
	-- перед экраном во весь холст их надо пометить изменившимися - иначе
	-- поверх заставки останется висеть строка гонки.
	scr.top = 1
	for i = 1, scr.w * HUD do scr.shown[i] = -1 end
	scr:clear(bg or 0)
end

local function screenEnd()
	scr:flush(true)
	scr.top = HUD + 1
	hudCache = {}
end

------------------------------------------------------------------ гонка

local raceT = 0

local function startRace(track, attract)
	G.track = track
	buildTrack(track)
	buildSky()
	buildMini()
	setPalette(true)
	G.laps = tonumber(opt.laps) or 3

	local others = {}
	for i = 1, #art.racers do
		if i ~= G.me then others[#others + 1] = i end
	end
	for i = #others, 2, -1 do
		local j = random(i)
		others[i], others[j] = others[j], others[i]
	end
	local n = opt.nocpu and 1 or #art.racers
	karts = {}
	karts[1] = newKart(G.me, n, (attract or opt.auto) and true or false)
	for i = 2, n do karts[i] = newKart(others[i - 1], i - 1, true) end

	rankKarts()
	raceT = 0
	G.finishOrder = {}
	G.gasHeld = 0
	G.count = 3.0
	G.state = attract and "title" or "count"
	G.drawn = false
	lastSky = nil
	scr:clear(0)
	G.hudDirty = true
	hudCache = {}
	G.msgT = 0
end

local function updateCamera(k, dt)
	local want = k.ang
	if k.drift ~= 0 then want = k.ang - k.drift * 0.2 end
	if not k.camA then k.camA = want end
	G.camKart = k
	k.camA = k.camA + wrapAng(want - k.camA) * min(1, dt * 7)
	camA = k.camA
	if k.shake > 0 and k.spd > 3 then camA = camA + sin(k.shake) * 0.005 end
	camCos, camSin = cos(camA), sin(camA)
	local back = CAMBACK + min(1.0, k.spd * 0.06)
	camX = k.x - camCos * back
	camY = k.y - camSin * back
end

local function finishKart(k)
	k.done = true
	k.finish = raceT
	G.finishOrder[#G.finishOrder + 1] = k
	k.finishPlace = #G.finishOrder
end

local function stepWorld(dt, racing)
	local n = max(1, ceil(dt / SUBSTEP))
	local sd = dt / n
	for _ = 1, n do
		for _, k in ipairs(karts) do
			if k.ai and racing then driveAI(k, sd) end
			if not k.done then stepKart(k, sd, racing) end
		end
		bumpKarts()
		stepObjs(sd, racing)
	end
	rankKarts()
end

local function stepRace(dt)
	if G.state == "count" then
		local was = ceil(G.count)
		G.count = G.count - dt
		if ceil(G.count) ~= was and G.count > 0 then beep(500, 0.08) end
		if control.gas then G.gasHeld = G.gasHeld + dt else G.gasHeld = 0 end
		if G.count <= 0 then
			G.state = "race"
			beep(1200, 0.1)
			-- ракетный старт: газ, нажатый в последний миг перед зелёным,
			-- даёт разгон, а нажатый слишком рано - глохнет
			if G.gasHeld > 0 and G.gasHeld < 0.45 then
				karts[1].boost = 1.1
				say("РАКЕТНЫЙ СТАРТ!")
			elseif G.gasHeld > 1.2 then
				karts[1].spin = 0.8
				say("ПЕРЕГАЗОВКА")
			else
				say("ПОЕХАЛИ!", 1)
			end
		end
	end

	local racing = G.state == "race"
	stepWorld(dt, racing)

	if racing then
		raceT = raceT + dt
		for _, k in ipairs(karts) do
			if not k.done then
				k.time = k.time + dt
				if k.lap > G.laps then finishKart(k) end
			end
		end
		if karts[1].done then
			G.state = "finish"
			G.drawn = false
		end
	end
end

------------------------------------------------------------------ кадр

-- Отсчёт на старте рисуется не буквой, а семью полосками, как на
-- табло: на экране 160x100 цифра из шрифта потерялась бы.
local SEGS = { [1] = "i", [2] = "abged", [3] = "abgcd" }

--- Полоска цифры: обводка в один пиксель, чтобы её было видно и на
--- светлой дороге, и на тёмной.
local function seg(x, y, w, h, c)
	scr:rect(x - 1, y - 1, w + 2, h + 2, 0)
	scr:rect(x, y, w, h, c)
end

local function bigDigit(n, x, y, w, h, t, c)
	local segs = SEGS[n]
	if not segs then return end
	local half = floor(h / 2)
	local function has(ch) return segs:find(ch, 1, true) end
	if has("i") then seg(x + floor((w - t) / 2), y, t, h, c) end
	if has("a") then seg(x, y, w, t, c) end
	if has("b") then seg(x + w - t, y, t, half, c) end
	if has("c") then seg(x + w - t, y + half, t, h - half, c) end
	if has("d") then seg(x, y + h - t, w, t, c) end
	if has("e") then seg(x, y + half, t, h - half, c) end
	if has("f") then seg(x, y, t, half, c) end
	if has("g") then seg(x, y + half - floor(t / 2), w, t, c) end
end

--- Полоса под названием. Рисуется до flush - это точки кадра, а не
--- текст, поэтому лечь она должна вместе с землёй.
local function titleBand()
	scr:rect(1, 13, VW, 17, 0)
	scr:rect(1, 13, VW, 1, 8)
	scr:rect(1, 29, VW, 1, 8)
end

local prof = { world = 0, things = 0, hud = 0, flush = 0, logic = 0 }
local function mark(name, t0)
	if not opt.prof then return t0 end
	local t = clock()
	prof[name] = prof[name] + (t - t0)
	return t
end

local function render()
	local t0 = opt.prof and clock() or 0
	drawSky(camA)
	drawGround()
	if G.state == "title" then titleBand() end
	t0 = mark("world", t0)
	drawRace()
	-- отсчёт ложится поверх машин: он и должен закрывать собой всё
	if G.state == "count" then
		local n = ceil(G.count)
		bigDigit(n, 70, 19, 21, 30, 5, n > 1 and 8 or 9)
	end
	drawMini()
	if G.state ~= "title" then drawItemSlot() end
	t0 = mark("things", t0)
	scr:flush(true)
	t0 = mark("flush", t0)
	if G.state ~= "title" then drawHUD() end
	mark("hud", t0)
end

------------------------------------------------------------------ ввод

local running = true
local keys, tap = {}, {}
local pullSignal = computer.pullSignal
local DRAIN = 64
local frame = 0

local K = {
	quit  = { 16 },                      -- Q
	gas   = { 200, 17 },                 -- вверх, W
	brake = { 208, 31 },                 -- вниз, S
	left  = { 203, 30 },                 -- влево, A
	right = { 205, 32 },                 -- вправо, D
	hop   = { 57, 42, 54 },              -- пробел, shift
	use   = { 45, 29, 44 },              -- X, ctrl, Z
}

local function down(list)
	for i = 1, #list do
		if keys[list[i]] then return true end
	end
	return false
end

local function handleSignal(e, _, _, code)
	if e == "interrupted" then return false end
	if type(code) ~= "number" then return true end
	if e == "key_down" then
		if opt.keys then G.lastKey = "вниз " .. tostring(code) end
		-- повтор от мода, а не новое нажатие: клавиша уже зажата
		if keys[code] then keys[code] = frame return true end
		keys[code] = frame
		for _, q in ipairs(K.quit) do
			if code == q then return false end
		end
		if G.state == "race" or G.state == "count" then
			for _, u in ipairs(K.use) do
				if code == u then useItem(karts[1]) end
			end
		elseif G.state == "select" and (code == 203 or code == 205) then
			G.me = code == 203 and ((G.me - 2) % #art.racers + 1) or (G.me % #art.racers + 1)
			G.drawn = false
		else
			G.advance = true
		end
	elseif e == "key_up" then
		if opt.keys then G.lastKey = "вверх " .. tostring(code) end
		if keys[code] == frame then tap[code] = true end
		keys[code] = nil
	end
	return true
end

--- Разобрать очередь и дождаться нового тика: кадр здесь один на тик, а
--- промежуток не пропадает - из очереди выбирается ввод.
local function pump(timeout)
	local t0 = computer.uptime()
	local n = 0
	while running do
		local e, addr, ch, code = pullSignal(n == 0 and (timeout or 0) or 0)
		if e then
			if not handleSignal(e, addr, ch, code) then running = false break end
			n = n + 1
			if n >= DRAIN then break end
		end
		if computer.uptime() > t0 then break end
	end
end

local lastHop = false
local function readControls()
	control.gas = down(K.gas)
	control.brake = down(K.brake)
	control.left = down(K.left)
	control.right = down(K.right)
	local hop = down(K.hop)
	control.hopNew = hop and not lastHop
	control.hop = hop
	lastHop = hop
end

------------------------------------------------------------------ экраны меню

local function drawTitle()
	banner({ "С У П Е Р   М А Р И О   К А Р Т" }, 8, 4)
	banner({ "восемь машин, четыре трассы, три круга" }, 10, 9)
	banner({ "нажми любую клавишу" }, 12, 15)
	local hint = "стрелки - руль и газ    пробел - прыжок и занос    X - предмет    Q - выход"
	scr:text(max(1, floor((scr.w - unicode.len(hint)) / 2) + 1), 47, hint, 3, 0)
	if not scr.buf then
		banner({ "нет видеопамяти: кадр уходит на экран десятками вызовов" }, 44, 8)
	end
	local rw, rh = gpu.getResolution()
	if rw < 160 or rh < 50 then
		banner({ ("экран %dx%d вместо 160x50 - видно не всё"):format(rw, rh) }, 45, 8)
	end
end

local function drawSelect()
	screenBegin(0)
	for i, rc in ipairs(art.racers) do
		local x = 4 + (i - 1) * 19
		local sel = (i == G.me)
		drawScaled(KART[i][sel and 5 or 1], x, sel and 52 or 56, sel and 18 or 14,
			sel and 15 or 11)
	end
	drawScaled(KART[G.me].me, 63, 20, 34, 26)
	screenEnd()
	banner({ "В Ы Б Е Р И   Г О Н Щ И К А" }, 4, 4)
	banner({ "#" .. art.racers[G.me].name }, 24, art.racers[G.me].body)
	for i, rc in ipairs(art.racers) do
		local x = 4 + (i - 1) * 19
		scr:text(x, 35, rc.name, i == G.me and 4 or rc.body, 0)
	end
	banner({ "стрелки влево-вправо - выбрать",
	         "~любая другая клавиша - на старт" }, 42)
	scr:present()
end

local function drawFinish()
	-- Кто не успел пересечь линию к тому мигу, как финишировал игрок,
	-- получает место по пройденному пути, но времени у него нет: гонку
	-- за него никто не доезжал.
	for _, k in ipairs(order) do
		if not k.done then
			finishKart(k)
			k.finish = nil
		end
	end
	for i, k in ipairs(G.finishOrder) do
		points[k.racer] = (points[k.racer] or 0) + (CUPPTS[i] or 0)
	end
	screenBegin(0)
	-- три первых на пьедестале
	for i = 1, min(3, #G.finishOrder) do
		local x = 58 + (i - 1) * 24
		drawScaled(KART[G.finishOrder[i].racer][1], x, 70 - (4 - i) * 4, 20, 16)
	end
	screenEnd()
	local lines = { "Ф И Н И Ш  -  " .. L.name, "" }
	for i, k in ipairs(G.finishOrder) do
		lines[#lines + 1] = ("%d.  %s %8s   +%d очк   всего %2d"):format(
			i, pad(k.name, 8), fmtTime(k.finish), CUPPTS[i] or 0, points[k.racer] or 0)
	end
	banner(lines, 4)
	banner({ G.track < #art.tracks and "~любая клавиша - следующая трасса"
		or "~любая клавиша - итоги кубка" }, 44)
	scr:present()
end

local function drawCup()
	local rank = {}
	for i = 1, #art.racers do rank[i] = i end
	table.sort(rank, function(a, b) return (points[a] or 0) > (points[b] or 0) end)
	screenBegin(0)
	for i = 1, 3 do
		local x = 58 + (i - 1) * 24
		drawScaled(KART[rank[i]][1], x, 72 - (4 - i) * 5, 20, 16)
	end
	screenEnd()
	local lines = { "К У Б О К   Г Р И Б А", "" }
	for i, r in ipairs(rank) do
		-- строчка игрока не должна съезжать вбок от пометки, поэтому
		-- пустое место под неё занято и у остальных
		lines[#lines + 1] = ("%d.  %s %2d очк%s"):format(
			i, pad(art.racers[r].name, 8), points[r] or 0,
			r == G.me and "   <- ты" or "        ")
	end
	banner(lines, 4)
	banner({ "~любая клавиша - новый кубок, Q - выход" }, 44)
	scr:present()
end

------------------------------------------------------------------ главный цикл

local ok, err = pcall(function()
	for i = 1, #art.racers do points[i] = 0 end
	G.track = max(1, min(#art.tracks, tonumber(opt.track) or 1))

	if opt.map then
		buildTrack(G.track)
		dumpMap()
		return
	end

	-- Заставка - это не картинка, а сама игра: по трассе едут все восемь,
	-- камера смотрит за лидером, а название лежит поверх.
	startRace(G.track, true)

	local last = computer.uptime()
	local frames, fpsT = 0, 0

	while running do
		frame = frame + 1
		frameNo = frame
		for c in pairs(tap) do tap[c] = nil end
		pump(0)
		local now = computer.uptime()
		local dt = now - last
		last = now
		if dt > 0.12 then dt = 0.12 end
		if dt <= 0 then dt = 0.02 end

		if G.state == "title" then
			-- Заставка смотрит за машиной выбранного гонщика, а не за
			-- лидером: лидер меняется, и камера прыгала бы с места на место.
			stepWorld(dt, true)
			updateCamera(karts[1], dt)
			render()
			drawTitle()
			scr:present()
			if G.advance then
				G.advance = false
				G.state = "select"
				G.drawn = false
			end
		elseif G.state == "select" then
			if not G.drawn then
				G.drawn = true
				drawSelect()
			end
			if G.advance then
				G.advance = false
				startRace(G.track, false)
			end
			pump(0.15)
		elseif G.state == "count" or G.state == "race" then
			readControls()
			local tl = opt.prof and clock() or 0
			stepRace(dt)
			if opt.prof then prof.logic = prof.logic + (clock() - tl) end
			if G.msgT > 0 then
				G.msgT = G.msgT - dt
				if G.msgT <= 0 then G.hudDirty = true end
			end
			G.hudDirty = true
			updateCamera(karts[1], dt)
			if G.state == "finish" then
				G.drawn = false
			else
				render()
				if G.state == "count" then
					banner({ ceil(G.count) > 0 and "" or "С Т А Р Т !" }, 20, 15)
				end
				scr:present()
			end
			frames = frames + 1
			fpsT = fpsT + dt
			if fpsT > 1 then
				G.fps = frames / fpsT
				frames, fpsT = 0, 0
				if opt.trace then
					local k = karts[1]
					trace("кадров %d: место %d, круг %d, скорость %.1f, вращает %.1f, "
						.. "ловят %.1f, предмет %s, под колёсами %s (%.1f, %.1f)",
						floor(G.fps + 0.5), k.place, k.lap, k.spd, k.spin, k.fall,
						k.item or "-", TILEN[tileAt(k.x, k.y)] or "?", k.x, k.y)
				end
			end
		elseif G.state == "finish" then
			if not G.drawn then
				G.drawn = true
				drawFinish()
			end
			if G.advance then
				G.advance = false
				if G.track < #art.tracks then
					startRace(G.track + 1, false)
				else
					G.state = "cup"
					G.drawn = false
				end
			end
			pump(0.2)
		elseif G.state == "cup" then
			if not G.drawn then
				G.drawn = true
				drawCup()
			end
			if G.advance then
				G.advance = false
				for i = 1, #art.racers do points[i] = 0 end
				startRace(1, true)
			end
			pump(0.2)
		end
	end
end)

scr:close()
gpu.setActiveBuffer(0)
gpu.setResolution(gpu.maxResolution())
gpu.setBackground(0x000000)
gpu.setForeground(0xFFFFFF)
require("term").clear()
if not ok then error(err, 0) end
if opt.prof then
	local sum = 0
	for _, v in pairs(prof) do sum = sum + v end
	io.stderr:write(("профиль, всего %.3f с, память под игру %.0f КБ:\n")
		:format(sum, memUsed() - MEM0))
	for _, k in ipairs({ "logic", "world", "things", "hud", "flush" }) do
		io.stderr:write(("  %-7s %6.1f мс  %4.1f%%\n"):format(
			k, prof[k] * 1000, sum > 0 and prof[k] / sum * 100 or 0))
	end
end
