-- doom - шутер для DwOS. Как и марио, это не эмулятор, а родной
-- порт: движок, стрельба, монстры и карты написаны на Lua и потому реально
-- играются на сервере 3 уровня.
--
-- Рисуется лучами (raycasting), как и положено движку той эпохи: на каждый
-- из 160 столбцов экрана пускается луч, шагает по сетке карты (DDA) и
-- говорит, до какой стены сколько идти. Расстояние задаёт высоту столбца,
-- точка попадания - колонку текстуры, а дальность - ступень затемнения.
-- Пол и потолок - плоские, поэтому считаются один раз по строкам, а не на
-- каждый луч.
--
-- Почему не настоящий Doom: настоящий читает WAD и рисует мир деревом BSP
-- с секторами разной высоты, с полом, потолком и лестницами. Это не
-- невозможно на Lua, но чтение тридцатимегабайтного WAD в машину с
-- четырьмя мегабайтами памяти - нет. Здесь мир - сетка клеток, и всё, что
-- из этого следует (стены одной высоты, пол без ступенек), - честная
-- плата за то, что оно идёт двадцать кадров в секунду.
--
--   doom.lua [--sound] [--fps] [--level=N] [--keys]
--
-- --sound включает звук: computer.beep занимает машину на всю длительность
-- сигнала, то есть стоит кадра, поэтому по умолчанию тихо.
--
-- Для отладки: --trace пишет в stderr, что происходит, --god не даёт
-- умереть, --prof печатает разбивку времени по фазам кадра, --fullscan и
-- --redraw включают заведомо честный медленный путь отрисовки (кадры
-- обязаны совпасть с обычным).

local args = { ... }
local opt = {}
for _, a in ipairs(args) do
	local k, v = a:match("^%-%-([%w_]+)=?(.*)$")
	if k then opt[k] = v ~= "" and v or true end
end

-- Сколько памяти машины уходит на саму игру: в OC её мало, и знать это
-- полезнее, чем гадать. Печатается с --prof.
local component = require("component")
local computer = require("computer")

--- Занятая память в КБ. В песочнице машины collectgarbage нет - там
--- считаем по computer.freeMemory; в обычном Lua (тестовый стенд) он есть.
local function memUsed()
	if collectgarbage then collectgarbage() return collectgarbage("count") end
	return (computer.totalMemory() - computer.freeMemory()) / 1024
end
local MEM0 = memUsed()
-- lib/event нужен не сам по себе, а тем, что при загрузке ставит свой
-- computer.pullSignal: в нём и Ctrl+Alt+C, и таймеры системы. Очередь
-- игра разбирает уже через него, а не через event.pull.
require("event")
local unicode = require("unicode")
local gpu = component.gpu

-- gfx у DwOS системный и лежит в package.loaded с самой загрузки - им
-- нарисована заставка системы, так что require не стоит ни одного чтения.
local gfx = require("gfx")

--- Каталог самой игры: картинки лежат рядом с ней, а ярлык из /bin зовёт
--- её из любого места. Имя чанка знает путь в обоих случаях.
local function selfdir()
	for i = 1, 4 do
		local d = debug.getinfo(i, "S")
		local p = d and d.source and d.source:match("^[=@]?(.*)/[^/]*%.lua$")
		if p and p ~= "" then return p end
	end
	return "/home/games"
end

local DIR = selfdir()

local function neighbour(name)
	local chunk, err = loadfile(DIR .. "/" .. name)
	if not chunk then error("не найден " .. DIR .. "/" .. name .. ": " .. tostring(err), 0) end
	return chunk()
end

local art = neighbour("doomart.lua")

-- --seed=N делает разброс повторяемым: Lua 5.4 иначе берёт случайное
-- зерно при запуске, и два одинаковых прогона стенда расходятся. В
-- оригинальном Doom случайность вообще была таблицей на 256 чисел.
if opt.seed then math.randomseed(tonumber(opt.seed) or 1) end

local floor, abs, sqrt = math.floor, math.abs, math.sqrt
local sin, cos, pi = math.sin, math.cos, math.pi
local random = math.random
-- в Lua 5.3 это math.atan с двумя доводами, в 5.2 - math.atan2
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

------------------------------------------------------------------ размеры

local HUD = 2                    -- строк символов под состояние
local TOP = HUD * 2              -- ... и столько же пикселей сверху
local VW, VH = 160, 96           -- окно вида в пикселях
local VY0, VY1 = TOP + 1, TOP + VH
local WALLH = VH * 1.5           -- высота стены в пикселях на расстоянии 1:
                                 -- полторы ширины клетки, иначе залы
                                 -- выглядят полем с заборчиком
local FOV = 0.72                 -- половина плоскости камеры
local SHMAX = 4                  -- ступеней затемнения сверх самой светлой
local RANGE = 26                 -- дальше этого луч не идёт
local FALL = 0.26                -- на сколько ступеней темнеет клетка пути

------------------------------------------------------------------ графика

--- Затемнение с расстоянием - это шаг по цепочке art.darker, а не второй
--- комплект картинок: SHADEROW[ступень] - таблица "цвет -> тёмный цвет".
---
--- Держать пять готовых копий каждой картинки было бы быстрее на один
--- поиск в таблице, но это мегабайт с лишним в машине, у которой всего
--- памяти может быть два. Поэтому копия одна, а тень берётся в момент
--- отрисовки.
local SHADEROW = {}
for s = 0, SHMAX do
	local row = {}
	for c = 0, 15 do
		local cur = c
		for _ = 1, s do cur = art.darker[cur] or 0 end
		row[c] = cur
	end
	SHADEROW[s] = row
end

local function hexc(ch) return tonumber(ch, 16) end

--- Текстура стены раскладывается по колонкам: рисуем-то вертикальными
--- полосами, и в горячем цикле нужен именно столбец, а не строка.
local function buildTex(rows, recol)
	local cols = {}
	for x = 1, 16 do
		local col = {}
		for y = 1, 16 do
			local c = hexc(rows[y]:sub(x, x))
			if recol and recol[c] then c = recol[c] end
			col[y] = c
		end
		cols[x] = col
	end
	return cols
end

local function buildSpr(rows, recol)
	local base = gfx.art(rows)
	if not recol then return base end
	local a = { w = base.w, h = base.h }
	for i = 1, base.w * base.h do
		local c = base[i]
		a[i] = c and (recol[c] or c) or false
	end
	return a
end

local T = art.tiles

--- Дверь одна, а полоса на ней перекрашивается под цвет ключа: жёлтый
--- 'd' в картинке - это место под краску, а не сам цвет.
local DOORCOL = { none = 5, red = 11, blue = 14, yellow = 13 }

--- Мип-уровни. Вдали и на стене, что уходит вбок, на один столбец экрана
--- приходится по нескольку текселей, а берётся из них один - какой
--- попадётся. Отсюда шахматка и рябь, которые ползают при каждом шаге.
--- Поэтому у каждой текстуры есть копии, где блоки 2x2, 4x4 и 8x8
--- текселей усреднены и приведены к ближайшему цвету палитры. Копии
--- той же раскладки 16x16 (блок просто повторён), так что slice о них
--- ничего не знает, а весь выбор - одно сравнение на столбец.
local MIPS = 3

--- Каналы цвета без битовых операций: процессор бывает и на Lua 5.2.
local function rgb(c) return floor(c / 65536) % 256, floor(c / 256) % 256, c % 256 end

local function nearestColor(r, g, b)
	local best, bd = 0, math.huge
	for i = 0, 15 do
		local cr, cg, cb = rgb(art.palette[i])
		local dr, dg, db = r - cr, g - cg, b - cb
		-- глаз к зелёному чувствительнее всего, к синему - меньше всего
		local d = 2 * dr * dr + 4 * dg * dg + 3 * db * db
		if d < bd then best, bd = i, d end
	end
	return best
end

local function mipTex(cols, level)
	local n = floor(2 ^ level + 0.5)
	-- столбцы внутри блока одинаковые, поэтому таблица на блок одна: так
	-- все три уровня стоят меньше, чем одна исходная текстура
	local out = {}
	for bx = 0, 15, n do
		local col = {}
		for x = bx + 1, bx + n do out[x] = col end
	end
	for bx = 0, 15, n do
		for by = 0, 15, n do
			local r, g, b = 0, 0, 0
			for x = bx + 1, bx + n do
				for y = by + 1, by + n do
					local cr, cg, cb = rgb(art.palette[cols[x][y]])
					r, g, b = r + cr, g + cg, b + cb
				end
			end
			local k = n * n
			local c = nearestColor(r / k, g / k, b / k)
			for y = by + 1, by + n do out[bx + 1][y] = c end
		end
	end
	return out
end

local TEX, TEXID = {}, {}
local MIP = { [0] = TEX }    -- MIP[уровень][текстура][столбец]

-- Текстуры, мипы и спрайты собираются не при запуске, а перед первым
-- уровнем: заставка успевает нарисоваться раньше, чем одиннадцать
-- текстур обзаведутся тремя уровнями усреднения.
local function buildTextures()
	local list = { "rock", "brick", "tech", "blood", "wood", "support", "exit" }
	for i, name in ipairs(list) do
		TEX[i] = buildTex(T[name])
		TEXID[name] = i
	end
	for _, k in ipairs({ "none", "red", "blue", "yellow" }) do
		TEX[#TEX + 1] = buildTex(T.door, { [13] = DOORCOL[k] })
		TEXID["door_" .. k] = #TEX
	end
	for l = 1, MIPS do
		MIP[l] = {}
		for i, t in ipairs(TEX) do MIP[l][i] = mipTex(t, l) end
	end
end

--- Какой мип брать: сколько текселей приходится на пиксель по большей из
--- осей. По горизонтали это 16 * dx/dcamX: для стены вдоль X выходит
--- dist * |dir x plane| / |rdx| на единицу camX, а |dir x plane| = FOV.
local FOOT = 16 * 2 * FOV / VW
local function mipLevel(dist, rd, hgt)
	local f = rd ~= 0 and FOOT * dist / abs(rd) or 99
	local fv = 16 / hgt
	if fv > f then f = fv end
	if f < 1.5 then return 0 elseif f < 3 then return 1 elseif f < 6 then return 2 end
	return 3
end

local SPR = {}
local function buildSprites()
	local S = art.sprites
	for k, v in pairs(S) do SPR[k] = buildSpr(v) end
	-- сержант - тот же вояка в тёмной форме, барон - имп покрупнее и в
	-- другой окраске: перекраска дешевле второго комплекта графики
	SPR.serg0 = buildSpr(S.zombie0, { [7] = 2, [8] = 3, [3] = 15 })
	SPR.serg1 = buildSpr(S.zombie1, { [7] = 2, [8] = 3, [3] = 15 })
	SPR.sergdead = buildSpr(S.corpse, { [7] = 2, [8] = 3, [9] = 4 })
	SPR.baron0 = buildSpr(S.imp0, { [7] = 10, [8] = 11, [9] = 13 })
	SPR.baron1 = buildSpr(S.imp1, { [7] = 10, [8] = 11, [9] = 13 })
	SPR.keyR = buildSpr(S.key, { [13] = 11 })
	SPR.keyB = buildSpr(S.key, { [13] = 14 })
	SPR.keyY = buildSpr(S.key)
	SPR.bigball = buildSpr(S.fireball, { [12] = 15, [13] = 10 })
	SPR.gun = buildSpr(S.clip, { [13] = 4, [3] = 2 })
end

local WPN = {}

--- Собрать всю графику. Зовётся перед первым уровнем и ничего не делает
--- во второй раз.
local MEMGAME = 0
local function buildArt()
	if TEX[1] then return end
	buildTextures()
	buildSprites()
	for k, v in pairs(art.weapons) do WPN[k] = gfx.art(v) end
	-- строки, из которых всё это разобрано, больше не нужны: в машине
	-- это десятки килобайт, а памяти у неё мало
	T, art.tiles, art.sprites, art.weapons = nil, nil, nil, nil
	MEMGAME = memUsed() - MEM0
end

------------------------------------------------------------------ правила

local MONSTERS = {
	zombie = { hp = 20, spd = 1.5, size = 0.80, rad = 0.32, sight = 16,
	           walk = { "zombie0", "zombie1" }, dead = "corpse", deadSize = 0.22,
	           attack = "hitscan", shots = 1, dmg = 3, dmgMax = 10, rate = 1.5,
	           name = "бывший вояка", drop = nil },
	serg   = { hp = 30, spd = 1.5, size = 0.80, rad = 0.32, sight = 16,
	           walk = { "serg0", "serg1" }, dead = "sergdead", deadSize = 0.22,
	           attack = "hitscan", shots = 3, dmg = 3, dmgMax = 8, rate = 2.2,
	           name = "сержант", drop = "shotgun" },
	imp    = { hp = 60, spd = 1.9, size = 0.85, rad = 0.34, sight = 18,
	           walk = { "imp0", "imp1" }, dead = "gore", deadSize = 0.22,
	           attack = "ball", ballSpd = 6, dmg = 8, dmgMax = 20, rate = 1.9,
	           name = "имп" },
	demon  = { hp = 150, spd = 3.6, size = 0.72, rad = 0.42, sight = 16,
	           walk = { "demon0", "demon1" }, dead = "gore", deadSize = 0.22,
	           attack = "melee", dmg = 8, dmgMax = 22, rate = 1.0, reach = 1.2,
	           name = "демон" },
	baron  = { hp = 400, spd = 2.1, size = 1.30, rad = 0.5, sight = 20,
	           walk = { "baron0", "baron1" }, dead = "gore", deadSize = 0.3,
	           attack = "ball", ballSpd = 7, ballArt = "bigball",
	           dmg = 18, dmgMax = 40, rate = 1.7, name = "барон ада" },
}

local ITEMS = {
	h = { art = "bonus",  size = 0.28, hp = 2,  over = true, msg = "пузырёк здоровья" },
	H = { art = "medkit", size = 0.38, hp = 25, msg = "аптечка" },
	a = { art = "armor",  size = 0.42, armor = 50, msg = "броня" },
	c = { art = "clip",   size = 0.28, bullets = 20, msg = "обойма" },
	s = { art = "shells", size = 0.30, shells = 8,  msg = "патроны к дробовику" },
	G = { art = "gun",    size = 0.34, weapon = 3, bullets = 20, msg = "пулемёт!" },
	r = { art = "keyR",   size = 0.40, key = "red",    msg = "красный ключ" },
	b = { art = "keyB",   size = 0.40, key = "blue",   msg = "синий ключ" },
	y = { art = "keyY",   size = 0.40, key = "yellow", msg = "жёлтый ключ" },
}

local WEAPONS = {
	{ name = "пистолет", art = "pistol",   ammo = "bullets", rate = 0.40,
	  pellets = 1, dmg = 5,  dmgMax = 15, spread = 0.015, snd = 900,  flash = { 0, -8 } },
	{ name = "дробовик", art = "shotgun",  ammo = "shells",  rate = 0.95,
	  pellets = 7, dmg = 4,  dmgMax = 12, spread = 0.10,  snd = 400,  flash = { 0, -8 } },
	{ name = "пулемёт",  art = "chaingun", ammo = "bullets", rate = 0.14,
	  pellets = 1, dmg = 4,  dmgMax = 13, spread = 0.045, snd = 1200, flash = { 0, -8 } },
}

local KEYNAME = { red = "красный", blue = "синий", yellow = "жёлтый" }

------------------------------------------------------------------ состояние

local scr = gfx.new(gpu, 160, 50)
local fb, pw = scr.fb, scr.pw
MEMGAME = memUsed() - MEM0   -- графика плюс кадр в памяти

local P = {}          -- игрок
local G = { state = "title", lv = 1, msg = "", msgT = 0 }
local L                -- текущий уровень
local ents, items, shots, fx = {}, {}, {}, {}

local zbuf = {}
local ceilRow, floorRow = {}, {}
local horizon, lastHorizon = VY0 + VH / 2, -1
local colDirty = {}    -- столбцы, которые надо перерисовать
local dirtyAll = true
local lastBoxes, boxes = {}, {}   -- где в прошлом кадре лежали спрайты

local function trace(fmt, ...)
	if opt.trace then io.stderr:write("[doom] " .. fmt:format(...) .. "\n") end
end

--- Звук. computer.beep держит машину всю длительность сигнала, поэтому по
--- умолчанию тихо, а с --sound - не чаще раза в четверть секунды.
local function beep(f, d)
	if not opt.sound then return end
	local now = computer.uptime()
	if (G.beepAt or 0) + 0.12 > now then return end
	G.beepAt = now
	pcall(computer.beep, f, d or 0.02)
end

local function say(msg)
	G.msg, G.msgT = msg, 3
	G.hudDirty = true
end

------------------------------------------------------------------ уровень

local SOLIDCH = { ["#"] = "rock", B = "brick", T = "tech", M = "blood",
                  W = "wood", I = "support", X = "exit" }
local DOORCH  = { ["+"] = "none", ["1"] = "red", ["2"] = "blue", ["3"] = "yellow" }
local MONCH   = { z = "zombie", g = "serg", i = "imp", d = "demon", K = "baron" }

local function loadLevel(n)
	buildArt()
	local def = art.maps[n]
	L = { name = def.name, w = #def.rows[1], h = #def.rows,
	      ceil = def.ceil, floor = def.floor, light = def.light or 0,
	      rows = def.rows }
	L.cells, L.doors = {}, {}
	ents, items, shots, fx = {}, {}, {}, {}
	L.kills, L.killsTotal, L.items, L.itemsTotal = 0, 0, 0, 0
	L.time = 0

	local sx, sy, sdir = 1.5, 1.5, def.dir or 0
	for y = 0, L.h - 1 do
		local row = def.rows[y + 1]
		for x = 0, L.w - 1 do
			local ch = row:sub(x + 1, x + 1)
			local idx = y * L.w + x
			local wall = SOLIDCH[ch]
			local door = DOORCH[ch]
			if wall then
				L.cells[idx] = TEXID[wall]
				if ch == "X" then L.exitAt = idx end
			elseif door then
				L.cells[idx] = TEXID["door_" .. door]
				L.doors[idx] = { o = 0, state = "closed", t = 0,
				                 key = door ~= "none" and door or nil }
			elseif ch == "@" then
				sx, sy = x + 0.5, y + 0.5
			elseif MONCH[ch] then
				local kind = MONCH[ch]
				local m = MONSTERS[kind]
				ents[#ents + 1] = { kind = kind, t = m, x = x + 0.5, y = y + 0.5,
				                    hp = m.hp, anim = 0, cool = random() * 2,
				                    awake = false, pain = 0, flash = 0, state = "live" }
				L.killsTotal = L.killsTotal + 1
			elseif ITEMS[ch] then
				items[#items + 1] = { x = x + 0.5, y = y + 0.5, kind = ch, t = ITEMS[ch] }
				L.itemsTotal = L.itemsTotal + 1
			end
		end
	end

	-- --at=КОЛОНКА,СТРОКА[,ГРАДУСЫ] ставит игрока сразу куда надо: гонять
	-- стенд от начала уровня до дальней двери каждый раз - лишнее
	if opt.at then
		local ax, ay, aa = tostring(opt.at):match("^(%-?[%d%.]+),(%-?[%d%.]+),?(%-?[%d%.]*)$")
		if ax then
			sx, sy = tonumber(ax) + 0.5, tonumber(ay) + 0.5
			if aa ~= "" then sdir = tonumber(aa) * pi / 180 end
		end
	end

	P.x, P.y, P.ang = sx, sy, sdir
	P.bob, P.fire, P.flash, P.pain, P.pick = 0, 0, 0, 0, 0
	if not P.keep then
		P.hp, P.armor = 100, 0
		P.bullets, P.shells = 50, 0
		P.have = { true, false, false }
		P.weapon = 1
	end
	P.keys = {}
	P.dead = false
	G.hudDirty, dirtyAll = true, true
	trace("уровень %s %dx%d, монстров %d, вещей %d", L.name, L.w, L.h, L.killsTotal, L.itemsTotal)
end

--- Клетка непроходима? Приоткрытая меньше чем наполовину дверь - стена.
local function solid(x, y)
	if x < 0 or y < 0 or x >= L.w or y >= L.h then return true end
	local idx = floor(y) * L.w + floor(x)
	local c = L.cells[idx]
	if not c then return false end
	local d = L.doors[idx]
	if d then return d.o < 0.55 end
	return true
end

--- Видит ли одна точка другую: шагаем по клеткам, пока не упрёмся.
local function canSee(x1, y1, x2, y2)
	local dx, dy = x2 - x1, y2 - y1
	local dist = sqrt(dx * dx + dy * dy)
	if dist < 0.001 then return true end
	local steps = floor(dist * 3) + 1
	local sx, sy = dx / steps, dy / steps
	local x, y = x1, y1
	for _ = 1, steps - 1 do
		x, y = x + sx, y + sy
		if solid(x, y) then return false end
	end
	return true
end

------------------------------------------------------------------ движение

local RAD = 0.3   -- радиус игрока и монстров при столкновении со стенами

--- Живые монстры - тоже препятствие, и друг другу, и игроку: иначе они
--- слипаются в одну точку и проходят сквозь него насквозь.
local function entBlocked(x, y, rad, me)
	for _, o in ipairs(ents) do
		if o ~= me and o.state == "live" then
			local dx, dy = o.x - x, o.y - y
			local r = rad + o.t.rad
			if dx * dx + dy * dy < r * r then return true end
		end
	end
	return false
end

--- Шаг с разбором по осям: упёршись в стену наискось, скользим вдоль неё,
--- а не встаём намертво.
local function tryMove(o, nx, ny, rad, me)
	rad = rad or RAD
	local moved = false
	if not solid(nx + rad, o.y) and not solid(nx - rad, o.y)
		and not solid(nx, o.y + rad) and not solid(nx, o.y - rad)
		and not entBlocked(nx, o.y, rad, me) then
		o.x = nx moved = true
	end
	if not solid(o.x + rad, ny) and not solid(o.x - rad, ny)
		and not solid(o.x, ny + rad) and not solid(o.x, ny - rad)
		and not entBlocked(o.x, ny, rad, me) then
		o.y = ny moved = true
	end
	return moved
end

------------------------------------------------------------------ бой

local function spawnFx(x, y, sprite, life, size)
	fx[#fx + 1] = { x = x, y = y, spr = sprite, life = life, size = size or 0.3 }
end

local function hurtPlayer(dmg, why)
	if opt.god or P.dead then return end
	-- броня забирает треть, пока не кончится
	if P.armor > 0 then
		local a = floor(dmg / 3)
		if a > P.armor then a = P.armor end
		P.armor = P.armor - a
		dmg = dmg - a
	end
	P.hp = P.hp - dmg
	P.pain = 0.22
	G.hudDirty = true
	beep(180, 0.05)
	if P.hp <= 0 then
		P.hp = 0
		P.dead = true
		P.deadT = 0
		say("ты умер - любая клавиша")
		trace("смерть от %s", why or "?")
	end
end

local function killEnt(e)
	e.state = "dead"
	e.anim = 0
	L.kills = L.kills + 1
	G.hudDirty = true
	beep(140, 0.06)
	if e.t.drop then
		-- сержант роняет дробовик: первый в игре добывается именно так
		items[#items + 1] = { x = e.x, y = e.y, kind = "drop",
		                      t = { art = "shells", size = 0.3, weapon = 2,
		                            shells = 4, msg = "дробовик!" } }
	end
end

local function hurtEnt(e, dmg)
	if e.state ~= "live" then return end
	e.hp = e.hp - dmg
	e.awake = true
	if e.hp <= 0 then killEnt(e) else
		if random() < 0.45 then e.pain = 0.3 end
	end
end

--- Луч выстрела: до какой стены он дойдёт и в кого попадёт раньше.
local function hitscan(x, y, ang, dmg, fromPlayer)
	local rx, ry = cos(ang), sin(ang)
	-- сначала стена: шагаем по клеткам грубо, этого хватает
	local wallT = RANGE
	local step = 0.12
	local cx, cy = x, y
	for i = 1, floor(RANGE / step) do
		cx, cy = cx + rx * step, cy + ry * step
		if solid(cx, cy) then wallT = i * step break end
	end
	-- теперь цели: проекция на луч и отход от него
	local best, bestT
	if fromPlayer then
		for _, e in ipairs(ents) do
			if e.state == "live" then
				local dx, dy = e.x - x, e.y - y
				local t = dx * rx + dy * ry
				if t > 0.2 and t < wallT then
					local px2, py2 = x + rx * t, y + ry * t
					local off = sqrt((e.x - px2) ^ 2 + (e.y - py2) ^ 2)
					if off < e.t.rad + 0.12 and (not bestT or t < bestT) then
						best, bestT = e, t
					end
				end
			end
		end
	else
		local dx, dy = P.x - x, P.y - y
		local t = dx * rx + dy * ry
		if t > 0.2 and t < wallT then
			local px2, py2 = x + rx * t, y + ry * t
			if sqrt((P.x - px2) ^ 2 + (P.y - py2) ^ 2) < 0.42 then
				hurtPlayer(dmg, "пуля")
				return
			end
		end
	end
	if best then
		hurtEnt(best, dmg)
		spawnFx(best.x, best.y, "gore", 0.12, 0.25)
	else
		spawnFx(x + rx * (wallT - 0.05), y + ry * (wallT - 0.05), "flash", 0.06, 0.12)
	end
end

local function fireWeapon()
	local w = WEAPONS[P.weapon]
	if P.fire > 0 or P.dead then return end
	local ammo = P[w.ammo]
	if ammo <= 0 then
		say("нет патронов")
		-- пустой пистолет не должен молчать в пустоту: сам переключаемся
		for i = #WEAPONS, 1, -1 do
			if P.have[i] and P[WEAPONS[i].ammo] > 0 then P.weapon = i G.hudDirty = true break end
		end
		P.fire = 0.4
		return
	end
	P[w.ammo] = ammo - 1
	P.fire = w.rate
	P.flash = 0.09
	G.hudDirty = true
	beep(w.snd, 0.02)
	for _ = 1, w.pellets do
		local a = P.ang + (random() - 0.5) * 2 * w.spread
		hitscan(P.x, P.y, a, random(w.dmg, w.dmgMax), true)
	end
	-- на выстрел сбегаются: тишина в Doom дороже патронов
	for _, e in ipairs(ents) do
		if e.state == "live" and not e.awake then
			local d = sqrt((e.x - P.x) ^ 2 + (e.y - P.y) ^ 2)
			if d < 12 then e.awake = true end
		end
	end
end

local function switchWeapon(i)
	if P.have[i] and P.weapon ~= i then
		P.weapon = i
		P.fire = 0.2
		G.hudDirty = true
		say("в руках " .. WEAPONS[i].name)
	end
end

------------------------------------------------------------------ двери

local function openDoor(idx, d)
	if d.key and not P.keys[d.key] then
		say("нужен " .. KEYNAME[d.key] .. " ключ")
		beep(200, 0.06)
		return false
	end
	if d.state == "closed" or d.state == "closing" then
		d.state = "opening"
		beep(700, 0.04)
	end
	d.t = 0
	return true
end

local function use()
	-- щупаем клетку перед носом: дверь открываем, рубильник дёргаем
	for r = 0.5, 1.6, 0.35 do
		local x, y = P.x + cos(P.ang) * r, P.y + sin(P.ang) * r
		if x >= 0 and y >= 0 and x < L.w and y < L.h then
			local idx = floor(y) * L.w + floor(x)
			local d = L.doors[idx]
			if d then openDoor(idx, d) return end
			if L.cells[idx] then
				if idx == L.exitAt then
					beep(1200, 0.1)
					G.state = "between"
					G.drawn = false
					trace("выход: убито %d/%d", L.kills, L.killsTotal)
				end
				return
			end
		end
	end
end

local function stepDoors(dt)
	for idx, d in pairs(L.doors) do
		if d.state == "opening" then
			d.o = d.o + dt * 1.6
			dirtyAll = true
			if d.o >= 1 then d.o = 1 d.state = "open" d.t = 0 end
		elseif d.state == "open" then
			d.t = d.t + dt
			-- дверь стоит открытой пять секунд, потом закрывается сама
			if d.t > 5 then
				local px, py = floor(P.x), floor(P.y)
				if py * L.w + px ~= idx then d.state = "closing" end
			end
		elseif d.state == "closing" then
			d.o = d.o - dt * 1.2
			dirtyAll = true
			if d.o <= 0 then d.o = 0 d.state = "closed" end
		end
	end
end

------------------------------------------------------------------ монстры

local function monsterAttack(e)
	local m = e.t
	e.cool = m.rate * (0.7 + random() * 0.6)
	e.flash = 0.12
	if m.attack == "melee" then
		local d = sqrt((e.x - P.x) ^ 2 + (e.y - P.y) ^ 2)
		if d < (m.reach or 1.2) then hurtPlayer(random(m.dmg, m.dmgMax), m.name) end
		beep(250, 0.03)
	elseif m.attack == "hitscan" then
		beep(600, 0.02)
		for _ = 1, (m.shots or 1) do
			local a = atan2(P.y - e.y, P.x - e.x) + (random() - 0.5) * 0.18
			hitscan(e.x, e.y, a, random(m.dmg, m.dmgMax), false)
		end
	else
		beep(500, 0.03)
		local a = atan2(P.y - e.y, P.x - e.x) + (random() - 0.5) * 0.06
		shots[#shots + 1] = { x = e.x, y = e.y, vx = cos(a) * m.ballSpd,
		                      vy = sin(a) * m.ballSpd, dmg = random(m.dmg, m.dmgMax),
		                      spr = m.ballArt or "fireball",
		                      size = m.ballArt and 0.42 or 0.3 }
	end
end

local scratch = {}   -- одна таблица на все попытки шага, чтобы не мусорить

local function stepEnts(dt)
	for _, e in ipairs(ents) do
		e.anim = e.anim + dt
		if e.flash > 0 then e.flash = e.flash - dt end
		if e.state == "live" then
			local dx, dy = P.x - e.x, P.y - e.y
			local dist = sqrt(dx * dx + dy * dy)
			if e.pain > 0 then
				e.pain = e.pain - dt
			else
				if not e.awake then
					if dist < e.t.sight and canSee(e.x, e.y, P.x, P.y) then
						e.awake = true
						beep(300, 0.03)
					end
				end
				if e.awake and not P.dead then
					e.cool = e.cool - dt
					local see = canSee(e.x, e.y, P.x, P.y)
					local reach = e.t.reach or 1.2
					if e.cool <= 0 and see and (e.t.attack ~= "melee" and dist < 15 or dist < reach) then
						monsterAttack(e)
					elseif dist > (e.t.attack == "melee" and reach * 0.8 or 1.4) then
						-- идём на игрока, у стены пробуем вдоль неё
						local s = e.t.spd * dt
						local ux, uy = dx / dist, dy / dist
						local o = scratch
						o.x, o.y = e.x, e.y
						if not tryMove(o, e.x + ux * s, e.y + uy * s, e.t.rad, e) then
							-- обходим: пробуем вбок
							local side = e.side or (random() < 0.5 and 1 or -1)
							e.side = side
							tryMove(o, e.x - uy * s * side, e.y + ux * s * side, e.t.rad, e)
						end
						e.x, e.y = o.x, o.y
					end
				end
			end
		end
	end
	-- шары
	for i = #shots, 1, -1 do
		local s = shots[i]
		local nx, ny = s.x + s.vx * dt, s.y + s.vy * dt
		local hit = false
		if solid(nx, ny) then hit = true
		elseif (nx - P.x) ^ 2 + (ny - P.y) ^ 2 < 0.2 then
			hurtPlayer(s.dmg, "шар")
			hit = true
		end
		s.x, s.y = nx, ny
		if hit then
			spawnFx(s.x, s.y, "flash", 0.12, 0.5)
			table.remove(shots, i)
		elseif (s.x - P.x) ^ 2 + (s.y - P.y) ^ 2 > RANGE * RANGE then
			table.remove(shots, i)
		end
	end
	for i = #fx, 1, -1 do
		fx[i].life = fx[i].life - dt
		if fx[i].life <= 0 then table.remove(fx, i) end
	end
end

------------------------------------------------------------------ вещи

local function pickup(it)
	local t = it.t
	local took = false
	if t.hp then
		local cap = t.over and 200 or 100
		if P.hp < cap then P.hp = math.min(cap, P.hp + t.hp) took = true end
	end
	if t.armor and P.armor < 100 then P.armor = math.min(100, P.armor + t.armor) took = true end
	if t.bullets then P.bullets = math.min(200, P.bullets + t.bullets) took = true end
	if t.shells then P.shells = math.min(50, P.shells + t.shells) took = true end
	if t.weapon and not P.have[t.weapon] then
		P.have[t.weapon] = true
		P.weapon = t.weapon
		took = true
	end
	if t.key and not P.keys[t.key] then P.keys[t.key] = true took = true end
	if took then
		say("взято: " .. t.msg)
		P.pick = 0.12
		G.hudDirty = true
		beep(1400, 0.02)
	end
	return took
end

local function stepItems()
	for i = #items, 1, -1 do
		local it = items[i]
		if (it.x - P.x) ^ 2 + (it.y - P.y) ^ 2 < 0.24 then
			if pickup(it) then
				if it.kind ~= "drop" then L.items = L.items + 1 end
				table.remove(items, i)
			end
		end
	end
end

------------------------------------------------------------------ игрок

-- Ходьба на WASD, поворот стрелками, огонь пробелом: мыши в машине нет,
-- поэтому поворот - такая же клавиша, как остальные, и держать его удобнее
-- другой рукой, чем той, что ходит.
local keys = {}    -- код -> номер кадра, в котором пришло key_down
local tap = {}     -- код -> нажали и отпустили, не дожив до шага
local K = {
	forward = { 17 },             -- W
	back    = { 31 },             -- S
	strafeL = { 30 },             -- A
	strafeR = { 32 },             -- D
	turnL   = { 203 },            -- стрелка влево
	turnR   = { 205 },            -- стрелка вправо
	run     = { 42, 54 },         -- shift
	fire    = { 57, 29, 157 },    -- пробел, ctrl
	use     = { 18, 28 },         -- E, enter
	map     = { 15 },             -- tab
	quit    = { 16, 1 },          -- Q, esc
}

--- Зажата ли клавиша. Касание, не дожившее до шага, считается зажатой
--- клавишей ровно один кадр: при двадцати кадрах в секунду короткий тычок
--- по огню иначе пропадал бы целиком.
local function down(name)
	for _, c in ipairs(K[name]) do if keys[c] or tap[c] then return true end end
	return false
end

-- Длиннее этого шаг физики не берётся: кадр в OC плавает, а разбег и
-- полёт шаров складываются по шагам.
local SUBSTEP = 0.06
local WALK, RUNSPD = 2.6, 4.4
local TURN, TURNRUN = 2.4, 3.4

local function stepPlayer(dt)
	if P.dead then
		P.deadT = P.deadT + dt
		return
	end
	local run = down("run")
	local spd = (run and RUNSPD or WALK) * dt
	local trn = (run and TURNRUN or TURN) * dt
	if down("turnL") then P.ang = P.ang - trn end
	if down("turnR") then P.ang = P.ang + trn end
	local dx, dy = cos(P.ang), sin(P.ang)
	local mx, my = 0, 0
	if down("forward") then mx, my = mx + dx, my + dy end
	if down("back") then mx, my = mx - dx, my - dy end
	if down("strafeL") then mx, my = mx + dy, my - dx end
	if down("strafeR") then mx, my = mx - dy, my + dx end
	local len = sqrt(mx * mx + my * my)
	if len > 0 then
		mx, my = mx / len * spd, my / len * spd
		tryMove(P, P.x + mx, P.y + my)
		P.bob = (P.bob + (run and 11 or 7.5) * dt) % (2 * pi)
	end
	if down("fire") then fireWeapon() end
	if P.fire > 0 then P.fire = P.fire - dt end
	if P.flash > 0 then P.flash = P.flash - dt end
	if P.pain > 0 then P.pain = P.pain - dt end
	if P.pick > 0 then P.pick = P.pick - dt end
	stepItems()
end

------------------------------------------------------------------ отрисовка

--- Пол и потолок - плоские, поэтому их цвет зависит только от строки
--- экрана: считаем таблицу один раз на положение горизонта, а не на луч.
local function buildRows()
	local half = WALLH * 0.5
	for y = VY0, VY1 do
		local d
		if y > horizon then d = half / (y - horizon)
		elseif y < horizon then d = half / (horizon - y)
		else d = 99 end
		local s = floor(d * FALL) + L.light
		if s > SHMAX then s = SHMAX elseif s < 0 then s = 0 end
		ceilRow[y] = SHADEROW[s][L.ceil]
		floorRow[y] = SHADEROW[s][L.floor]
	end
	lastHorizon = horizon
end

--- Где кусок стены высотой h с серединой на mid ложится на экран. Пиксель
--- y занимает [y, y+1) и попадает в стену, если его середина внутри.
--- Оба края считаются от точных дробных координат: если округлять верх,
--- а низ получать прибавкой округлённой высоты, две ошибки складываются,
--- и нижний край прямой стены идёт зубцами то вверх, то вниз.
local function span(topF, h)
	return floor(topF + 0.5), floor(topF + h + 0.5) - 1
end

--- Текстурная полоса с отсечением. topF и h - где лёг бы весь кусок стены
--- (дробные), y1..y2 - что из этого видно. Строка текстуры тоже берётся
--- от дробного верха, а не от округлённого, - иначе швы кирпича прыгают
--- на пиксель от столбца к столбцу вместе с краем.
local function slice(x, col, sh, topF, h, y1, y2)
	if h <= 0 then return end
	local k = 16 / h
	local t = (y1 + 0.5 - topF) * k
	if t < 0 then t = 0 end
	-- целая часть и остаток отдельно: floor на каждый пиксель стоил бы
	-- половины времени всей отрисовки мира
	local ty = floor(t)
	local fr = t - ty
	local last = col[16]
	local o = (y1 - 1) * pw + x
	for _ = y1, y2 do
		fb[o] = sh[col[ty + 1] or last]
		o = o + pw
		fr = fr + k
		while fr >= 1 do fr = fr - 1 ty = ty + 1 end
	end
end

local dirX, dirY, planeX, planeY

--- Один столбец: луч, стена, потолок и пол над и под ней. Здесь игра и
--- проводит почти всё своё время, поэтому тут нет ни вызовов функций на
--- пиксель, ни арифметики с плавающей точкой сверх необходимой.
local function paintColumn(x)
	local camX = 2 * (x - 0.5) / VW - 1
	local rdx = dirX + planeX * camX
	local rdy = dirY + planeY * camX
	local mx, my = floor(P.x), floor(P.y)
	local ddx = rdx == 0 and 1e30 or abs(1 / rdx)
	local ddy = rdy == 0 and 1e30 or abs(1 / rdy)
	local stepX, stepY, sdx, sdy
	if rdx < 0 then stepX = -1 sdx = (P.x - mx) * ddx
	else stepX = 1 sdx = (mx + 1 - P.x) * ddx end
	if rdy < 0 then stepY = -1 sdy = (P.y - my) * ddy
	else stepY = 1 sdy = (my + 1 - P.y) * ddy end

	local side, tex, dist
	local dTex, dDist, dSide, dOpen
	local W = L.w
	for _ = 1, 64 do
		if sdx < sdy then sdx = sdx + ddx mx = mx + stepX side = 0
		else sdy = sdy + ddy my = my + stepY side = 1 end
		if mx < 0 or my < 0 or mx >= W or my >= L.h then break end
		local idx = my * W + mx
		local c = L.cells[idx]
		if c then
			local pdist = side == 0 and (sdx - ddx) or (sdy - ddy)
			local door = L.doors[idx]
			if door and door.o > 0.001 then
				-- дверь уехала вверх: за ней видно дальше, но её саму надо
				-- потом положить поверх того, что там окажется
				if door.o < 0.999 and not dTex then
					dTex, dSide, dOpen, dDist = c, side, door.o, pdist
				end
			else
				tex, dist = c, pdist
				break
			end
		end
	end

	local y1, y2 = VY0, VY0 - 1
	local itop, ibot, topF, lineH
	if tex and dist and dist > 0.0001 then
		lineH = WALLH / dist
		topF = horizon - lineH * 0.5
		itop, ibot = span(topF, lineH)
		y1 = itop < VY0 and VY0 or itop
		y2 = ibot > VY1 and VY1 or ibot
		zbuf[x] = dist
	else
		-- луч ушёл в никуда: сверху потолок, снизу пол, стены нет
		dist = RANGE
		zbuf[x] = RANGE
		y1, y2 = horizon, horizon - 1
	end

	-- потолок
	local o = (VY0 - 1) * pw + x
	for y = VY0, y1 - 1 do fb[o] = ceilRow[y] o = o + pw end
	-- стена
	if tex and y2 >= y1 then
		local wx
		if side == 0 then wx = P.y + dist * rdy else wx = P.x + dist * rdx end
		wx = wx - floor(wx)
		local tx = floor(wx * 16) + 1
		if (side == 0 and rdx > 0) or (side == 1 and rdy < 0) then tx = 17 - tx end
		if tx < 1 then tx = 1 elseif tx > 16 then tx = 16 end
		local s = floor(dist * FALL) + L.light + side
		if s > SHMAX then s = SHMAX elseif s < 0 then s = 0 end
		local lv = mipLevel(dist, side == 0 and rdx or rdy, lineH)
		slice(x, MIP[lv][tex][tx], SHADEROW[s], topF, lineH, y1, y2)
	end
	-- пол
	o = y2 * pw + x
	for y = y2 + 1, VY1 do fb[o] = floorRow[y] o = o + pw end

	-- приоткрытая дверь: она уехала вверх, и за ней уже видно стену, так
	-- что дверь кладётся поверх дальней стены своим куском
	if dTex and dDist and dOpen and dOpen < 0.999 and dDist > 0.0001 and dDist <= dist then
		local dH = WALLH / dDist
		local dTopF = horizon - dH * 0.5
		local dtop, dbot = span(dTopF, dH)
		-- сама дверь уехала вверх на свою долю высоты, а видна только в
		-- проёме - от dtop до dbot
		local sTopF = dTopF - dH * dOpen
		local _, sBot = span(sTopF, dH)
		local cy1 = dtop < VY0 and VY0 or dtop
		local cy2 = dbot > VY1 and VY1 or dbot
		if sBot < cy2 then cy2 = sBot end
		if cy2 >= cy1 then
			local wx
			if dSide == 0 then wx = P.y + dDist * rdy else wx = P.x + dDist * rdx end
			wx = wx - floor(wx)
			local tx = floor(wx * 16) + 1
			if (dSide == 0 and rdx > 0) or (dSide == 1 and rdy < 0) then tx = 17 - tx end
			if tx < 1 then tx = 1 elseif tx > 16 then tx = 16 end
			local s = floor(dDist * FALL) + L.light + dSide
			if s > SHMAX then s = SHMAX elseif s < 0 then s = 0 end
			local lv = mipLevel(dDist, dSide == 0 and rdx or rdy, dH)
			slice(x, MIP[lv][dTex][tx], SHADEROW[s], sTopF, dH, cy1, cy2)
			if dOpen < 0.5 then zbuf[x] = dDist end
		end
	end
end

--- Спрайт в мире: билборд, всегда лицом к игроку. Столбцы, закрытые
--- стеной, пропускаются по zbuf.
local rowTex = {}
local function drawSprite(sx, sy, spr, worldH, shadeBias)
	local dx, dy = sx - P.x, sy - P.y
	local det = planeX * dirY - dirX * planeY
	if det == 0 then return end
	local inv = 1 / det
	local tx = inv * (dirY * dx - dirX * dy)
	local ty = inv * (-planeY * dx + planeX * dy)
	if ty < 0.25 then return end
	local scale = WALLH / ty
	local hpix = floor(worldH * scale + 0.5)
	if hpix < 1 then return end
	local wpix = floor(hpix * spr.w / spr.h + 0.5)
	if wpix < 1 then return end
	local scx = VW * 0.5 * (1 + tx / ty)
	local groundY = floor(horizon + scale * 0.5 + 0.5)
	local y1 = groundY - hpix + 1
	local y2 = groundY
	local x1 = floor(scx - wpix * 0.5 + 0.5)
	local x2 = x1 + wpix - 1
	local cy1 = y1 < VY0 and VY0 or y1
	local cy2 = y2 > VY1 and VY1 or y2
	local cx1 = x1 < 1 and 1 or x1
	local cx2 = x2 > VW and VW or x2
	if cx2 < cx1 or cy2 < cy1 then return end

	local s = floor(ty * FALL) + L.light + (shadeBias or 0)
	if s > SHMAX then s = SHMAX elseif s < 0 then s = 0 end
	local a, sh = spr, SHADEROW[s]
	local aw, ah = spr.w, spr.h

	-- строка экрана -> строка картинки считается один раз на спрайт
	local n = 0
	for y = cy1, cy2 do
		n = n + 1
		rowTex[n] = floor((y - y1) * ah / hpix) * aw
	end

	for x = cx1, cx2 do
		if zbuf[x] > ty then
			local txc = floor((x - x1) * aw / wpix) + 1
			local o = (cy1 - 1) * pw + x
			for k = 1, n do
				local c = a[rowTex[k] + txc]
				if c then fb[o] = sh[c] end
				o = o + pw
			end
		end
	end
	boxes[#boxes + 1] = cx1
	boxes[#boxes + 1] = cx2
	scr:touch(cx1, cy1, cx2 - cx1 + 1, cy2 - cy1 + 1)
end

--- Картинка без масштабирования: оружие в руках и вспышка ствола.
local function blitArt(x, y, a)
	local aw, ah = a.w, a.h
	local x1 = x < 1 and 1 or x
	local y1 = y < VY0 and VY0 or y
	local x2 = x + aw - 1 local y2 = y + ah - 1
	if x2 > VW then x2 = VW end
	if y2 > VY1 then y2 = VY1 end
	if x2 < x1 or y2 < y1 then return end
	for yy = y1, y2 do
		local o = (yy - 1) * pw
		local ao = (yy - y) * aw - x + 1
		for xx = x1, x2 do
			local c = a[ao + xx]
			if c then fb[o + xx] = c end
		end
	end
	boxes[#boxes + 1] = x1
	boxes[#boxes + 1] = x2
	scr:touch(x1, y1, x2 - x1 + 1, y2 - y1 + 1)
end

-- Список того, что рисуется спрайтами, живёт между кадрами: заводить его
-- заново двадцать раз в секунду - это мусор, который потом собирать.
local sortBuf = {}
local function put(n, x, y, spr, h, bias, ent)
	local t = sortBuf[n]
	if not t then t = {} sortBuf[n] = t end
	local dx, dy = x - P.x, y - P.y
	t.d, t.x, t.y, t.spr, t.h, t.bias, t.ent = dx * dx + dy * dy, x, y, spr, h, bias, ent
end

local function drawThings()
	local n = 0
	for _, e in ipairs(ents) do
		n = n + 1
		if e.state == "dead" then
			put(n, e.x, e.y, SPR[e.t.dead], e.t.deadSize, nil, nil)
		else
			put(n, e.x, e.y, SPR[e.t.walk[(floor(e.anim * 4) % 2) + 1]], e.t.size,
				e.pain > 0 and -1 or nil, e)
		end
	end
	for _, it in ipairs(items) do
		n = n + 1
		put(n, it.x, it.y, SPR[it.t.art], it.t.size, nil, nil)
	end
	for _, s in ipairs(shots) do
		n = n + 1
		put(n, s.x, s.y, SPR[s.spr], s.size, -2, nil)
	end
	for _, f in ipairs(fx) do
		n = n + 1
		put(n, f.x, f.y, SPR[f.spr], f.size, -2, nil)
	end
	for i = #sortBuf, n + 1, -1 do sortBuf[i] = nil end
	-- дальние рисуются первыми, ближние их перекрывают
	table.sort(sortBuf, function(a, b) return a.d > b.d end)
	for i = 1, n do
		local t = sortBuf[i]
		if t.spr then drawSprite(t.x, t.y, t.spr, t.h, t.bias) end
		-- вспышка выстрела монстра висит там же, где он сам
		local e = t.ent
		if e and e.flash and e.flash > 0 and e.state == "live" then
			drawSprite(e.x, e.y, SPR.flash, e.t.size * 0.45, -3)
		end
	end
end

local function drawGun()
	local w = WEAPONS[P.weapon]
	local a = WPN[w.art]
	local bx = floor(sin(P.bob) * 4)
	local by = floor(abs(cos(P.bob)) * 3)
	local gx = floor((VW - a.w) / 2) + 1 + bx
	local gy = VY1 - a.h + 1 + by
	if P.flash > 0 then
		local fa = SPR.flash
		blitArt(gx + floor((a.w - fa.w) / 2) + w.flash[1],
		        gy + w.flash[2] - fa.h + 8, fa)
	end
	blitArt(gx, gy, a)
end

------------------------------------------------------------------ карта

local function drawAutomap()
	local cw = floor(math.min(VW / L.w, VH / L.h))
	if cw < 2 then cw = 2 end
	local ox = floor((VW - cw * L.w) / 2)
	local oy = VY0 + floor((VH - cw * L.h) / 2)
	scr:rect(1, VY0, VW, VH, 0)
	for y = 0, L.h - 1 do
		for x = 0, L.w - 1 do
			local idx = y * L.w + x
			local c = L.cells[idx]
			if c then
				local col = 3
				local d = L.doors[idx]
				if d then
					col = d.key == "red" and 11 or d.key == "blue" and 14
						or d.key == "yellow" and 13 or 5
				elseif idx == L.exitAt then col = 15 end
				scr:rect(ox + x * cw + 1, oy + y * cw, cw, cw, col)
			end
		end
	end
	for _, it in ipairs(items) do
		scr:rect(ox + floor(it.x * cw), oy + floor(it.y * cw), 2, 2, 13)
	end
	if opt.god then
		for _, e in ipairs(ents) do
			if e.state == "live" then
				scr:rect(ox + floor(e.x * cw), oy + floor(e.y * cw), 2, 2, 11)
			end
		end
	end
	-- игрок и куда смотрит
	local px = ox + floor(P.x * cw)
	local py = oy + floor(P.y * cw)
	scr:rect(px - 1, py - 1, 3, 3, 5)
	for r = 1, cw * 2 do
		scr:rect(px + floor(cos(P.ang) * r), py + floor(sin(P.ang) * r), 1, 1, 15)
	end
end

------------------------------------------------------------------ строка состояния

local hudCache = {}

local function drawHUD()
	if not G.hudDirty and not opt.fps and not opt.keys then return end
	G.hudDirty = false
	local w = WEAPONS[P.weapon]
	local line = ("ЗДОР %3d   БРОНЯ %3d   %s %3d   %s   УБИТО %d/%d"):format(
		floor(P.hp), floor(P.armor),
		w.ammo == "shells" and "ДРОБЬ" or "ПАТР", floor(P[w.ammo]),
		L.name, L.kills, L.killsTotal)
	if hudCache.line ~= line then
		scr:text(2, 1, line .. "   ", 5, 0)
		hudCache.line = line
	end
	local kk = (P.keys.red and "К" or "-") .. (P.keys.blue and "С" or "-")
		.. (P.keys.yellow and "Ж" or "-")
	if hudCache.keys ~= kk then
		hudCache.keys = kk
		scr:text(scr.w - 10, 1, "КЛЮЧИ " .. kk, 13, 0)
	end
	local msg = G.msgT > 0 and G.msg or ""
	if hudCache.msg ~= msg then
		hudCache.msg = msg
		scr:text(2, 2, msg .. string.rep(" ", math.max(0, 46 - unicode.len(msg))), 13, 0)
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

local function screenText(lines, bgc)
	scr.top = 1
	scr:clear(bgc or 0)
	scr:flush(true)
	for i, l in ipairs(lines) do
		local row = floor(scr.h / 2) - #lines + (i - 1) * 2
		local fg = 5
		if l:sub(1, 1) == "~" then fg = 11 l = l:sub(2) end
		local len = unicode.len(l)
		scr:text(math.max(1, floor((scr.w - len) / 2) + 1), row, l, fg, 0)
	end
	scr:present()
	scr.top = HUD + 1
	hudCache = {}
end

------------------------------------------------------------------ палитра

local curPal = nil
local function setPalette(extra)
	local key = extra or "base"
	if curPal == key then return end
	curPal = key
	local p = {}
	for i = 0, 15 do p[i] = art.palette[i] end
	if extra == "pain" then
		for i, v in pairs(art.painPalette) do p[i] = v end
	elseif extra == "pick" then
		for i, v in pairs(art.pickPalette) do p[i] = v end
	end
	scr:palette(p)
end

------------------------------------------------------------------ кадр

local clock = os.clock or function() return 0 end
local prof = { world = 0, things = 0, gun = 0, flush = 0, logic = 0 }
local function mark(name, t0)
	prof[name] = prof[name] + (clock() - t0)
	return clock()
end

local lastX, lastY, lastAng = -1, -1, -1

local function render()
	local t = opt.prof and clock() or 0
	dirX, dirY = cos(P.ang), sin(P.ang)
	planeX, planeY = -dirY * FOV, dirX * FOV

	if G.automap then
		drawAutomap()
		scr:flush(true)
		drawHUD()
		scr:present()
		return
	end

	-- горизонт слегка качается при ходьбе - от этого и появляется ощущение
	-- шага; таблицы пола и потолка пересчитываются только когда он съехал
	local nh = floor(VY0 + VH * 0.5 + sin(P.bob * 2) * 1.5 + 0.5)
	if nh ~= horizon then horizon = nh dirtyAll = true end
	if lastHorizon ~= horizon then buildRows() end

	if P.x ~= lastX or P.y ~= lastY or P.ang ~= lastAng then dirtyAll = true end
	lastX, lastY, lastAng = P.x, P.y, P.ang
	if opt.redraw then dirtyAll = true end

	-- то, что в прошлом кадре закрывали спрайты и оружие, надо собрать
	-- заново: фон под ними не хранится, зато и не копируется
	if dirtyAll then
		for x = 1, VW do paintColumn(x) end
		scr:touch(1, VY0, VW, VH)
	else
		local n = 0
		for i = 1, #lastBoxes, 2 do
			for x = lastBoxes[i], lastBoxes[i + 1] do
				if not colDirty[x] then colDirty[x] = true n = n + 1 end
			end
		end
		if n > 0 then
			for x = 1, VW do
				if colDirty[x] then
					paintColumn(x)
					colDirty[x] = nil
					scr:touch(x, VY0, 1, VH)
				end
			end
		end
	end
	dirtyAll = false
	if opt.prof then t = mark("world", t) end

	for i = #boxes, 1, -1 do boxes[i] = nil end
	drawThings()
	if opt.prof then t = mark("things", t) end
	drawGun()
	if opt.prof then t = mark("gun", t) end
	lastBoxes, boxes = boxes, lastBoxes

	scr:flush(true)
	drawHUD()
	scr:present()
	if opt.prof then mark("flush", t) end
end

------------------------------------------------------------------ главный цикл

local running = true

-- Ввод. Клавиатура приходит сигналами, и очередь у машины одна на всё; за
-- одно пробуждение мод отдаёт ровно один сигнал. Разбирая по событию за
-- кадр, игра отставала всё сильнее, пока клавишу держат: мод шлёт key_down
-- снова и снова, чаще, чем идут кадры, - и key_up приходило с опозданием в
-- секунды. Прежний "добор" не помогал: он звал event.pull(0), а тот при
-- нулевом ожидании выходит, не спросив очередь.
--
-- Теперь очередь разбирается напрямую computer.pullSignal, и за кадр
-- добирается столько, сколько успевается до нового тика. Повтор от мода
-- отличается от нового нажатия тем, что клавиша уже помечена зажатой: на
-- зажатом E дверь больше не дёргается без конца, а Tab не мигает картой.
-- Нажатие и отпускание, попавшие в один кадр, раньше гасили друг друга -
-- теперь такое касание живёт ровно один кадр.

local pullSignal = computer.pullSignal
local DRAIN = 64          -- событий за кадр самое большее, страховка от потопа
local frame = 0           -- номер кадра: им метятся нажатия

--- Разобрать один сигнал. Возвращает false, когда игру пора закрывать.
local function handleSignal(e, _, _, code)
	if e == "interrupted" then return false end
	if type(code) ~= "number" then return true end
	if e == "key_down" then
		if opt.keys then G.lastKey = "вниз " .. tostring(code) end
		-- повтор от мода, а не новое нажатие: клавиша уже зажата
		if keys[code] then keys[code] = frame return true end
		keys[code] = frame
		for _, q in ipairs(K.quit) do if code == q then return false end end
		if G.state == "play" then
			if code == 2 then switchWeapon(1) end
			if code == 3 then switchWeapon(2) end
			if code == 4 then switchWeapon(3) end
			for _, u in ipairs(K.use) do if code == u then use() end end
			for _, m in ipairs(K.map) do
				if code == m then
					G.automap = not G.automap
					dirtyAll = true
					G.hudDirty = true
					for i = 1, scr.w * scr.h do scr.shown[i] = -1 end
				end
			end
			if P.dead and P.deadT > 1 then G.state = "restart" end
		elseif G.state ~= "play" then
			G.advance = true
		end
	elseif e == "key_up" then
		if opt.keys then G.lastKey = "вверх " .. tostring(code) end
		if keys[code] == frame then tap[code] = true end
		keys[code] = nil
	end
	return true
end

--- Разобрать очередь и дождаться нового тика.
---
--- Часы машины идут тиками по 0.05 с, а просыпается она чаще: мод будит
--- её каждые executionDelay миллисекунд, пока есть чем заняться. Вернись
--- отсюда раньше, чем часы сдвинулись, - и у кадра выйдет нулевое dt, а
--- физике придётся выдумать время: игра пойдёт быстрее настоящей. Плавнее
--- она от лишних кадров не станет - экран обновляется раз в тик, - зато
--- бюджет вызовов они съедят.
---
--- Поэтому кадр здесь один на тик, а промежуток не пропадает: пока тик не
--- начался, из очереди выбирается ввод, и к самому кадру он разобран весь.
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

local function startLevel(keep)
	P.keep = keep
	loadLevel(G.lv)
	P.keep = nil
	setPalette()
	scr:reserveTop(HUD)
	for i = 1, scr.w * scr.h do scr.shown[i] = -1 end
	scr:clear(0)
	hudCache = {}
	horizon, lastHorizon = floor(VY0 + VH * 0.5), -1
	dirtyAll = true
	G.state = "play"
	G.automap = false
end

local ok, err = pcall(function()
	setPalette()
	scr:reserveTop(HUD)
	if opt.fullscan then scr.fullScan = true end
	if opt.level then G.lv = math.max(1, math.min(#art.maps, tonumber(opt.level) or 1)) end
	-- уровень тут не строится: заставке он не нужен, а startLevel построит
	-- его сам, когда игрок нажмёт клавишу. Раньше он строился дважды.

	local last = computer.uptime()
	local frames, fpsT = 0, 0

	while running do
		frame = frame + 1
		-- касания прошлого кадра своё отработали
		for c in pairs(tap) do tap[c] = nil end
		pump(0)
		local now = computer.uptime()
		local dt = now - last
		last = now
		if dt > 0.12 then dt = 0.12 end
		if dt <= 0 then dt = 0.02 end

		if G.state == "title" then
			if not G.drawn then
				G.drawn = true
				local lines = { "D O O M", "", "OpenComputers edition", "",
				                "~любая клавиша - вниз, в ад",
				                "W/S - вперёд и назад, A/D - вбок",
				                "стрелки влево-вправо - поворот",
				                "пробел - огонь, E - открыть, Tab - карта",
				                "1/2/3 - оружие, shift - бегом, Q - выход" }
				if not scr.buf then
					lines[#lines + 1] = ""
					lines[#lines + 1] = "~нет видеопамяти: кадр уходит на экран"
					lines[#lines + 1] = "~десятками вызовов, будет медленно"
				end
				local rw, rh = gpu.getResolution()
				if rw < 160 or rh < 50 then
					lines[#lines + 1] = ""
					lines[#lines + 1] = ("~экран %dx%d вместо 160x50 - видно не всё"):format(rw, rh)
				end
				screenText(lines)
			end
			if G.advance then G.advance = false startLevel(false) end
			pump(0.2)
		elseif G.state == "between" then
			if not G.drawn then
				G.drawn = true
				local kp = L.killsTotal > 0 and floor(L.kills / L.killsTotal * 100) or 100
				local ip = L.itemsTotal > 0 and floor(L.items / L.itemsTotal * 100) or 100
				screenText({ "УРОВЕНЬ ПРОЙДЕН", "", L.name, "",
				             ("убито  %d%%"):format(kp), ("найдено %d%%"):format(ip),
				             ("время  %d:%02d"):format(floor(L.time / 60), floor(L.time % 60)),
				             "", "~любая клавиша - дальше" })
			end
			if G.advance then
				G.advance = false
				G.lv = G.lv + 1
				if G.lv > #art.maps then
					G.state = "won"
					G.drawn = false
				else
					startLevel(true)   -- оружие и патроны переходят на новый уровень
				end
			end
			pump(0.2)
		elseif G.state == "restart" then
			-- смерть возвращает на тот же уровень с начальным набором,
			-- как в оригинале
			startLevel(false)
		elseif G.state == "won" then
			if not G.drawn then
				G.drawn = true
				screenText({ "А Д   З А Ч И Щ Е Н", "",
				             "пройдено уровней: " .. #art.maps, "",
				             "~любая клавиша - сначала", "Q - выход" })
			end
			if G.advance then
				G.advance = false
				G.lv = 1
				startLevel(false)
			end
			pump(0.2)
		else
			local tl = opt.prof and clock() or 0
			-- Длинный кадр считается не одним шагом, а несколькими: на
			-- просевшем кадре иначе и разбег другой, и шар успевает
			-- проскочить стену. Обычный кадр укладывается в один шаг.
			local n = math.ceil(dt / SUBSTEP)
			local sd = dt / n
			for _ = 1, n do
				stepPlayer(sd)
				stepEnts(sd)
				stepDoors(sd)
			end
			L.time = L.time + dt
			if G.msgT > 0 then
				G.msgT = G.msgT - dt
				if G.msgT <= 0 then G.hudDirty = true end
			end
			if opt.prof then prof.logic = prof.logic + (clock() - tl) end

			-- вспышки боли и подбора - это переопределение палитры, а не
			-- перерисовка кадра: шестнадцать вызовов вместо шестнадцати
			-- тысяч точек
			setPalette(P.pain > 0 and "pain" or (P.pick > 0 and "pick" or nil))

			if opt.trace and (G.traceT or 0) + 1 < computer.uptime() then
				G.traceT = computer.uptime()
				trace("x=%.2f y=%.2f угол=%.2f здор=%d патр=%d монстров=%d шаров=%d",
					P.x, P.y, P.ang, P.hp, P.bullets, #ents, #shots)
			end

			render()

			if P.dead and P.deadT > 3.5 then G.state = "restart" end

			frames = frames + 1
			fpsT = fpsT + dt
			if fpsT > 1 then
				G.fps = frames / fpsT
				frames, fpsT = 0, 0
				if opt.fps then G.hudDirty = true end
			end
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
	io.stderr:write(("профиль, всего %.3f с, память под игру %.0f КБ:\n"):format(sum, MEMGAME))
	for _, k in ipairs({ "logic", "world", "things", "gun", "flush" }) do
		io.stderr:write(("  %-7s %6.1f мс  %4.1f%%\n"):format(
			k, prof[k] * 1000, sum > 0 and prof[k] / sum * 100 or 0))
	end
end
