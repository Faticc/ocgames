-- mario - платформер для DwOS. Не эмулятор приставки, а родной порт:
-- движок, физика и уровни написаны на Lua и потому реально играются
-- на сервере 3 уровня, а не показывают слайды.
--
-- Мир меряется пикселями полублочного экрана (см. lib/gfx.lua в системе):
-- тайл 8x8, экран 160x100 - это 20x12 тайлов плюс две верхние строки под
-- счёт.
--
-- Кадр собирается не заново: прокрутка уезжает одним bitblt, перерисовы-
-- ваются только пришедшие справа столбцы и клетки, где что-то изменилось,
-- а под каждым спрайтом запоминается фон и возвращается на место в начале
-- следующего кадра. Что из этого уйдёт на экран - один bitblt или повтор
-- нескольких вызовов - решает уже сам холст.
--
--   mario.lua [--sound] [--fps] [--level=N] [--keys]
--
-- --sound включает звук: computer.beep занимает машину на всю длительность
-- сигнала, то есть стоит кадра, поэтому по умолчанию тихо.
-- --fps показывает в строке счёта, сколько кадров в секунду выходит.
--
-- --keys показывает в строке счёта код последней нажатой клавиши - этим
-- проверяется, доходит ли до машины ввод (клавиатура должна стоять у
-- того монитора, в который смотришь).
--
-- Для отладки: --trace пишет в stderr, что происходит, --god не даёт
-- умереть от врагов, --from=КОЛОНКА ставит Марио сразу в нужное место,
-- --big (или --big=fire) начинает большим.

local args = { ... }
local opt = {}
for _, a in ipairs(args) do
	local k, v = a:match("^%-%-([%w_]+)=?(.*)$")
	if k then opt[k] = v ~= "" and v or true end
end

local component = require("component")
local computer = require("computer")
-- lib/event нужен не сам по себе, а тем, что при загрузке ставит свой
-- computer.pullSignal: в нём и Ctrl+Alt+C, и таймеры системы. Очередь
-- игра разбирает уже через него, а не через event.pull.
require("event")
local unicode = require("unicode")
local gpu = component.gpu

-- gfx у DwOS системный: он уже лежит в package.loaded с самой загрузки
-- (им нарисована заставка), поэтому require не стоит ни одного чтения с
-- диска - в отличие от прежней копии рядом с игрой.
local gfx = require("gfx")

--- Каталог самой игры: картинки лежат рядом с ней, а ярлык из /bin зовёт
--- её из любого места. Имя чанка знает путь и в том, и в другом случае,
--- так что перебирать каталоги не нужно.
local function selfdir()
	for i = 1, 4 do
		local d = debug.getinfo(i, "S")
		local p = d and d.source and d.source:match("^[=@]?(.*)/[^/]*%.lua$")
		if p and p ~= "" then return p end
	end
	return "/home/games"
end

local DIR = selfdir()

--- Соседний файл набора.
local function neighbour(name)
	local chunk, err = loadfile(DIR .. "/" .. name)
	if not chunk then error("не найден " .. DIR .. "/" .. name .. ": " .. tostring(err), 0) end
	return chunk()
end

local art = neighbour("marioart.lua")

------------------------------------------------------------------ размеры

local TW = 8                     -- сторона тайла
local COLS, ROWS = 20, 12        -- видно тайлов
local HUD = 2                    -- строк символов под счёт
local TOP = HUD * 2              -- ... и столько же пикселей сверху
local PW = COLS * TW             -- 160 пикселей поля
local PH = ROWS * TW             -- 96 пикселей поля
local SKY = 1

------------------------------------------------------------------ физика
-- Всё в пикселях за секунду: кадры в OC плавают, привязываться к ним нельзя.

local WALK, RUN = 70, 118
local ACC, DEC, SKID = 260, 340, 700
local GRAV, GRAV_HOLD, MAXFALL = 820, 380, 340
local JUMP = -238
-- под водой Марио всплывает толчками, а не прыгает
local SWIM_GRAV, SWIM_MAX, SWIM_UP, SWIM_WALK = 130, 62, -78, 52
-- Длиннее этого шаг физики не берётся: кадр в OC плавает, а тяжесть и
-- разгон складываются по шагам, и на длинном кадре прыжок вышел бы
-- другим. Обычный кадр укладывается в один шаг.
local SUBSTEP = 0.06
local ENEMY_SPD = 28
local SHELL_SPD = 150
local FIRE_SPD = 150

------------------------------------------------------------------ картинки

-- Разбор картинок отложен до загрузки уровня: заставка успевает нарисо-
-- ваться раньше, а не ждать, пока полсотни спрайтов разберутся из строк.
local TILEART, SPR = {}, {}
local function buildArt()
	if SPR.small0 then return end
	local T, S = art.tiles, art.sprites
	local function t(k, rows) TILEART[k] = gfx.art(rows) end
	t("X", T.ground) t("B", T.brick) t("?", T.qblock) t("M", T.qblock)
	t("U", T.used)   t("S", T.stair) t("C", T.castle)
	t("1", T.pipeTL) t("2", T.pipeTR) t("3", T.pipeBL) t("4", T.pipeBR)
	t("P", T.poleTop) t("p", T.pole) t("q", T.poleBase)
	t("c", T.cloudL) t("d", T.cloudR) t("h", T.bushL) t("j", T.bushR)
	t("L", T.lava)  t("H", T.bridge) t("m", T.shroomTop) t("n", T.shroomStem)
	t("~", T.waveTop) t("=", T.water)
	for k, v in pairs(S) do SPR[k] = gfx.art(v) end
	-- всё, что ходит в обе стороны, зеркалится один раз при запуске
	for _, k in ipairs({ "small0", "small1", "small2", "smallJump", "smallSkid",
	                     "big0", "big1", "big2", "bigJump", "bigSkid", "bigDuck",
	                     "goomba0", "goomba1", "koopa0", "koopa1" }) do
		SPR[k .. "L"] = gfx.flip(SPR[k])
	end
	-- строки, из которых они разобраны, больше не нужны: в машине их
	-- полтора десятка килобайт, а памяти у неё мало
	art.tiles, art.sprites = nil, nil
end

local SOLID = { X = true, B = true, ["?"] = true, M = true, U = true, S = true,
                ["1"] = true, ["2"] = true, ["3"] = true, ["4"] = true,
                H = true, m = true }
-- лава убивает от одного касания и ничего не держит
local DEADLY = { L = true }

------------------------------------------------------------------ уровень

--- Разобрать карту-список команд в сетку тайлов и список того, что на ней
--- живёт. Формат команд описан в marioart.lua.
local function build(def)
	local L = { w = def.width, name = def.name, theme = def.theme, time = def.time or 400 }
	L.map, L.bg, L.spawn = {}, {}, {}
	for r = 1, ROWS do L.map[r] = {} L.bg[r] = {} end
	L.start = { 3, 10 }

	local function put(c, r, ch)
		if c >= 1 and c <= L.w and r >= 1 and r <= ROWS then L.map[r][c] = ch end
	end
	local function putbg(c, r, ch)
		if c >= 1 and c <= L.w and r >= 1 and r <= ROWS then L.bg[r][c] = ch end
	end

	for _, line in ipairs(def.map) do
		local f = {}
		for w in line:gmatch("%S+") do f[#f + 1] = w end
		local cmd = f[1]
		if cmd == "A" then
			L.start = { tonumber(f[2]), tonumber(f[3]) }
		elseif cmd == "G" then
			for c = tonumber(f[2]), tonumber(f[3]) do put(c, 11, "X") put(c, 12, "X") end
		elseif cmd == "B" then
			local x, y, s = tonumber(f[2]), tonumber(f[3]), f[4]
			for i = 1, #s do put(x + i - 1, y, s:sub(i, i)) end
		elseif cmd == "P" then
			local x, h = tonumber(f[2]), tonumber(f[3])
			local top = 11 - h
			put(x, top, "1") put(x + 1, top, "2")
			for r = top + 1, 10 do put(x, r, "3") put(x + 1, r, "4") end
		elseif cmd == "T" then
			local x, n, d = tonumber(f[2]), tonumber(f[3]), tonumber(f[4])
			for i = 0, n - 1 do
				local col = x + i
				local hgt = d > 0 and i + 1 or n - i
				for r = 10, 11 - hgt, -1 do put(col, r, "S") end
			end
		elseif cmd == "E" then
			L.spawn[#L.spawn + 1] = { kind = f[4], col = tonumber(f[2]), row = tonumber(f[3]) }
		elseif cmd == "V" then
			L.spawn[#L.spawn + 1] = { kind = "coin", col = tonumber(f[2]), row = tonumber(f[3]) }
		elseif cmd == "D" then
			local what, x, y = f[2], tonumber(f[3]), tonumber(f[4])
			if what == "cloud" then putbg(x, y, "c") putbg(x + 1, y, "d")
			elseif what == "bush" then putbg(x, y, "h") putbg(x + 1, y, "j") end
		elseif cmd == "L" then
			for c = tonumber(f[2]), tonumber(f[3]) do put(c, 11, "L") put(c, 12, "L") end
		elseif cmd == "H" then
			-- мост в замке: доски на строке y
			local y = tonumber(f[4])
			for c = tonumber(f[2]), tonumber(f[3]) do put(c, y, "H") end
			L.bridge = L.bridge or { x1 = tonumber(f[2]), x2 = tonumber(f[3]), y = y }
		elseif cmd == "W" then
			-- платформа-гриб: шляпка длиной n и ножка под её серединой
			local x, y, n = tonumber(f[2]), tonumber(f[3]), tonumber(f[4])
			for i = 0, n - 1 do put(x + i, y, "m") end
			for r = y + 1, 10 do put(x + math.floor(n / 2), r, "n") end
		elseif cmd == "~" then
			-- вода: гребень волны и толща под ним, всё только фон
			for c = tonumber(f[2]), tonumber(f[3]) do
				putbg(c, tonumber(f[4]), "~")
				for r = tonumber(f[4]) + 1, ROWS do putbg(c, r, "=") end
			end
		elseif cmd == "R" then
			-- ось стержня - обычный блок, иначе огонь висит в пустоте
			put(tonumber(f[2]), tonumber(f[3]), "U")
			L.spawn[#L.spawn + 1] = { kind = "firebar", col = tonumber(f[2]),
			                          row = tonumber(f[3]), len = tonumber(f[4]) or 4,
			                          speed = tonumber(f[5]) or 2 }
		elseif cmd == "Z" then
			-- ходячая платформа: n тайлов, ход range пикселей, v - вертикально
			L.spawn[#L.spawn + 1] = { kind = "platform", col = tonumber(f[2]),
			                          row = tonumber(f[3]), len = tonumber(f[4]) or 3,
			                          range = tonumber(f[5]) or 40, vert = f[6] == "v" }
		elseif cmd == "K" then
			L.spawn[#L.spawn + 1] = { kind = "bowser", col = tonumber(f[2]), row = tonumber(f[3]) }
		elseif cmd == "Y" then
			L.spawn[#L.spawn + 1] = { kind = "axe", col = tonumber(f[2]), row = tonumber(f[3]) }
			L.axe = tonumber(f[2])
		elseif cmd == "F" then
			local x = tonumber(f[2])
			put(x, 2, "P")
			for r = 3, 9 do put(x, r, "p") end
			put(x, 10, "q")
			L.flag = x
		elseif cmd == "C" then
			local x = tonumber(f[2])
			for r = 6, 10 do for c = x, x + 4 do put(c, r, "C") end end
			put(x + 2, 9, nil) put(x + 2, 10, nil)      -- ворота
			put(x, 5, "C") put(x + 2, 5, "C") put(x + 4, 5, "C")
			L.castle = x
		end
	end
	return L
end

------------------------------------------------------------------ состояние

local scr = gfx.new(gpu, COLS * TW, (ROWS * TW + TOP) // 2)
local pal = {}
for i = 0, 15 do pal[i] = art.palette[i] end

local G = {
	level = nil, lv = tonumber(opt.level) or 1,
	camX = 0, lastCam = 0,
	score = 0, coins = 0, lives = 3, time = 400, timeAcc = 0,
	ents = {}, fx = {}, bumps = {},
	dirty = {}, sound = opt.sound and true or false,
	state = "title", wait = 0,
}

local M = {}       -- Марио

--- Отладка: с --trace игра пишет в stderr, что с ней происходит.
local function trace(fmt, ...)
	if opt.trace then io.stderr:write("  " .. string.format(fmt, ...) .. "\n") end
end

--- Звук. computer.beep держит машину всю длительность сигнала, а это
--- целый тик - то есть каждый прыжок стоил бы пропущенного кадра. Поэтому
--- по умолчанию тихо, а с --sound сигналы короткие и не чаще раза в
--- четверть секунды.
local function beep(f, d)
	if not G.sound then return end
	local now = computer.uptime()
	if (G.beepAt or 0) + 0.25 > now then return end
	G.beepAt = now
	pcall(computer.beep, f, d or 0.015)
end

------------------------------------------------------------------ тайлы

local function tileAt(c, r)
	if c < 1 or c > G.level.w or r < 1 or r > ROWS then return nil end
	return G.level.map[r][c]
end

local function solidAt(c, r) return SOLID[tileAt(c, r) or ""] end

local function markDirty(c) G.dirty[c] = true end

local function setTile(c, r, ch)
	if r >= 1 and r <= ROWS and c >= 1 and c <= G.level.w then
		G.level.map[r][c] = ch
		markDirty(c)
	end
end

------------------------------------------------------------------ движение

local floor = math.floor

--- Сдвиг по горизонтали с упором в стену. Возвращает true, если упёрся.
local function moveX(e, dx)
	e.x = e.x + dx
	if e.x < 0 then e.x = 0 return true end
	local c1 = floor(e.x / TW) + 1
	local c2 = floor((e.x + e.w - 1) / TW) + 1
	local r1 = floor(e.y / TW) + 1
	local r2 = floor((e.y + e.h - 1) / TW) + 1
	if dx > 0 then
		for r = r1, r2 do
			if solidAt(c2, r) then e.x = (c2 - 1) * TW - e.w return true end
		end
	elseif dx < 0 then
		for r = r1, r2 do
			if solidAt(c1, r) then e.x = c1 * TW return true end
		end
	end
	return false
end

--- Сдвиг по вертикали. При ударе головой возвращает колонку и строку
--- блока, в который ткнулись - по нему и будет удар.
local function moveY(e, dy)
	e.y = e.y + dy
	local c1 = floor(e.x / TW) + 1
	local c2 = floor((e.x + e.w - 1) / TW) + 1
	local r1 = floor(e.y / TW) + 1
	local r2 = floor((e.y + e.h - 1) / TW) + 1
	if dy > 0 then
		for c = c1, c2 do
			if solidAt(c, r2) then
				e.y = (r2 - 1) * TW - e.h
				e.vy = 0
				e.ground = true
				return
			end
		end
		e.ground = false
	elseif dy < 0 then
		local hit
		for c = c1, c2 do
			if solidAt(c, r1) then
				-- бьём тот блок, что ближе к середине головы
				local mid = e.x + e.w / 2
				if not hit or math.abs((c - 0.5) * TW - mid) < math.abs((hit - 0.5) * TW - mid) then
					hit = c
				end
			end
		end
		if hit then
			e.y = r1 * TW
			e.vy = 0
			return hit, r1
		end
	end
end

--- Шаг с разбиением на части. За кадр при 15 кадрах в секунду падение
--- уносит на два десятка пикселей - без этого тело перескочило бы верхний
--- тайл земли и застряло внутри неё.
local function step(e, dx, dy, onBump)
	local n = math.ceil(math.max(math.abs(dx), math.abs(dy)) / 4)
	if n < 1 then n = 1 end
	local wall
	for _ = 1, n do
		if moveX(e, dx / n) then wall = true end
		local c, r = moveY(e, dy / n)
		if c and onBump then onBump(c, r) end
	end
	return wall
end

------------------------------------------------------------------ существа

local function spawn(kind, x, y, extra)
	local e = { kind = kind, x = x, y = y, vx = 0, vy = 0, w = 8, h = 8,
	            anim = 0, live = true, ground = false }
	-- свойства из карты нужны уже при настройке вида, а не после неё
	if extra then for k, v in pairs(extra) do if v ~= nil then e[k] = v end end end
	if kind == "goomba" then e.vx = -ENEMY_SPD e.w = 7 e.x = x + 0.5
	elseif kind == "koopa" then e.vx = -ENEMY_SPD e.h = 12 e.w = 7
	elseif kind == "shell" then e.h = 12 e.w = 7 e.still = 0
	elseif kind == "mushroom" then e.vx = ENEMY_SPD * 1.6
	elseif kind == "flower" then e.vx = 0
	elseif kind == "coin" then e.solidfree = true
	elseif kind == "fire" then e.w = 6 e.h = 6 e.vy = 60
	elseif kind == "piranha" then
		-- сидит в трубе и высовывается: y - это верх трубы, а x сдвинут
		-- на полтайла, чтобы голова торчала посередине, а не с краю
		e.w, e.h = 8, 12
		e.x = x + 4
		e.base, e.out, e.t = y, 0, 0
		e.y = y
	elseif kind == "firebar" then
		-- вертится вокруг своей точки, длина в огоньках
		e.w, e.h = 0, 0
		e.ang, e.len, e.speed = 0, e.len or 4, e.speed or 2
	elseif kind == "platform" then
		e.w, e.h = (e.len or 3) * TW, 4
		e.home, e.range = nil, e.range or 40
		e.dir = 1
	elseif kind == "cheep" then
		e.w, e.h = 8, 8
		e.vx = -ENEMY_SPD * 1.4
		e.swim = y
	elseif kind == "flyfish" then
		-- рыба, выпрыгивающая из воды по дуге
		e.w, e.h = 8, 8
		e.vx, e.vy = -20, -175
		e.y = y
	elseif kind == "bowser" then
		e.w, e.h = 15, 16
		e.hp, e.vx, e.fireAt, e.jumpAt = 5, -20, 0, 0
	elseif kind == "axe" then
		e.w, e.h = 8, 8
	elseif kind == "bowserfire" then
		e.w, e.h = 8, 4
	end
	G.ents[#G.ents + 1] = e
	return e
end

local function effect(kind, x, y, extra)
	local e = { kind = kind, x = x, y = y, vx = 0, vy = 0, t = 0 }
	if extra then for k, v in pairs(extra) do e[k] = v end end
	G.fx[#G.fx + 1] = e
	return e
end

local function addScore(n)
	n = math.floor(n)
	trace("очки +%d", n)
	G.score = G.score + n
	G.hudDirty = true
end

local function addCoin()
	G.coins = G.coins + 1
	if G.coins >= 100 then G.coins = 0 G.lives = G.lives + 1 end
	addScore(200)
	beep(1400, 0.05)
end

------------------------------------------------------------------ удар по блоку

--- Марио ткнулся головой в блок (c,r).
local function bumpBlock(c, r)
	local t = tileAt(c, r)
	trace("удар по блоку %d,%d = %s", c, r, tostring(t))
	if not t then return end
	if t == "?" or t == "M" then
		setTile(c, r, "U")
		G.bumps[#G.bumps + 1] = { c = c, r = r, t = 0 }
		if t == "?" then
			addCoin()
			effect("coin", (c - 1) * TW, (r - 1) * TW - TW, { vy = -150 })
		else
			local kind = M.big and "flower" or "mushroom"
			spawn(kind, (c - 1) * TW, (r - 1) * TW - TW, { rise = 8 })
			beep(700, 0.06)
		end
	elseif t == "B" then
		if M.big then
			setTile(c, r, nil)
			for i = 1, 4 do
				local vx = (i % 2 == 0) and 55 or -55
				effect("debris", (c - 1) * TW + (i % 2) * 4, (r - 1) * TW + floor((i - 1) / 2) * 4,
				       { vx = vx, vy = i <= 2 and -170 or -110 })
			end
			addScore(50)
			beep(260, 0.06)
		else
			G.bumps[#G.bumps + 1] = { c = c, r = r, t = 0 }
			beep(180, 0.04)
		end
	end
end

------------------------------------------------------------------ Марио

local function resetMario(full)
	M.w, M.h = 6, 8
	M.big, M.fire = false, false
	M.vx, M.vy = 0, 0
	M.face, M.anim, M.inv = 1, 0, 0
	M.ground = false
	M.dead, M.deadT = false, 0
	M.win, M.winT, M.castleWin = false, 0, false
	M.duck = false
	-- поблажки прыжка: без них первый же шаг физики сравнивал бы nil
	M.jumpBuf, M.coyote, M.jumpHeld = 0, 0, false
	local s = G.level.start
	M.x = (s[1] - 1) * TW
	M.y = (s[2] - 1) * TW
	if full then M.x, M.y = M.x, M.y end
end

local function grow(kind)
	if kind == "flower" then
		M.fire = true
		if not M.big then M.big = true M.h = 16 M.y = M.y - 8 end
		addScore(1000)
	elseif not M.big then
		M.big = true
		M.h = 16
		M.y = M.y - 8
		addScore(1000)
	else
		addScore(1000)
	end
	beep(900, 0.08)
end

local function hurt()
	if M.inv > 0 or M.dead or opt.god then return end
	trace("получил по шапке, big=%s", tostring(M.big))
	if M.big then
		M.big, M.fire = false, false
		M.h = 8
		M.y = M.y + 8
		M.inv = 2
		beep(300, 0.1)
	else
		M.dead = true
		M.deadT = 0
		M.vy = -230
		beep(200, 0.2)
	end
end

------------------------------------------------------------------ ввод

local keys = {}    -- код -> номер кадра, в котором пришло key_down
local tap = {}     -- код -> нажали и отпустили, не дожив до шага физики
local K = {
	left  = { 203, 30 },            -- стрелка влево, A
	right = { 205, 32 },            -- стрелка вправо, D
	up    = { 200, 17, 57 },        -- стрелка вверх, W, пробел
	down  = { 208, 31 },            -- стрелка вниз, S
	run   = { 42, 54, 45, 44 },     -- shift, X, Z
	quit  = { 16, 1 },              -- Q, Esc
}

-- Прыжок, нажатый чуть раньше приземления, запоминается на JUMP_BUF, а
-- земля под ногами держится ещё COYOTE после схода с края. При двадцати
-- кадрах в секунду без этих поблажек половина прыжков пропадает: игрок
-- жмёт вовремя, а кадр, в котором Марио коснулся земли, уже прошёл.
local JUMP_BUF, COYOTE = 0.15, 0.1

--- Зажата ли клавиша. Касание, не дожившее до шага физики, считается
--- зажатой клавишей ровно один кадр.
local function down(name)
	for _, c in ipairs(K[name]) do if keys[c] or tap[c] then return true end end
	return false
end

------------------------------------------------------------------ отрисовка

local UNDER = false

--- Нарисовать столбец мировых тайлов. Всё рисование фона идёт только так:
--- и при прокрутке, и когда блок сменился.
local function drawColumn(col)
	local sx = (col - 1) * TW - G.camX + 1
	if sx > PW or sx < 1 - TW then return end
	scr:rect(sx, TOP + 1, TW, PH, SKY)
	if col < 1 or col > G.level.w then return end
	local bg, map = G.level.bg, G.level.map
	for r = 1, ROWS do
		local b = bg[r][col]
		if b then scr:tile(sx, TOP + 1 + (r - 1) * TW, TILEART[b]) end
	end
	for r = 1, ROWS do
		local t = map[r][col]
		if t then
			local dy = 0
			for _, bp in ipairs(G.bumps) do
				if bp.c == col and bp.r == r then dy = bp.dy or 0 end
			end
			scr:tile(sx, TOP + 1 + (r - 1) * TW - dy, TILEART[t])
		end
	end
end

local function redrawAll()
	scr:rect(1, TOP + 1, PW, PH, SKY)
	local c0 = floor(G.camX / TW)
	for c = c0, c0 + COLS + 1 do drawColumn(c) end
end

--- Спрайт по состоянию Марио.
local function marioSprite()
	local n
	if M.dead then n = "smallDead"
	elseif M.big then
		if M.duck and M.ground then n = "bigDuck"
		elseif not M.ground then n = "bigJump"
		elseif M.skid then n = "bigSkid"
		elseif math.abs(M.vx) < 4 then n = "big0"
		else n = (M.anim % 2 == 0) and "big1" or "big2" end
	else
		if not M.ground then n = "smallJump"
		elseif M.skid then n = "smallSkid"
		elseif math.abs(M.vx) < 4 then n = "small0"
		else n = (M.anim % 2 == 0) and "small1" or "small2" end
	end
	if M.face < 0 and not M.dead and SPR[n .. "L"] then n = n .. "L" end
	return SPR[n]
end

local function entSprite(e)
	if e.kind == "goomba" then
		if e.flat then return SPR.goombaFlat end
		local n = (e.anim % 2 == 0) and "goomba0" or "goomba1"
		return SPR[e.vx > 0 and n .. "L" or n]
	elseif e.kind == "koopa" then
		local n = (e.anim % 2 == 0) and "koopa0" or "koopa1"
		return SPR[e.vx > 0 and n .. "L" or n]
	elseif e.kind == "shell" then return SPR.shell
	elseif e.kind == "mushroom" then return SPR.mushroom
	elseif e.kind == "flower" then return SPR.flower
	elseif e.kind == "coin" then return SPR.coin
	elseif e.kind == "fire" then return SPR.fireball
	elseif e.kind == "piranha" then
		return (e.anim % 2 < 1) and SPR.piranha0 or SPR.piranha1
	elseif e.kind == "cheep" or e.kind == "flyfish" then return SPR.cheep
	elseif e.kind == "axe" then return SPR.axe
	elseif e.kind == "bowserfire" then return SPR.bowserFire
	elseif e.kind == "bowser" then
		return (e.anim % 2 < 1) and SPR.bowser or SPR.bowser1
	end
end

local hudCache = {}
local function drawHUD()
	local L = G.level
	-- всё, что уходит в "%d", округляем на месте: любое дробное число
	-- здесь роняет игру, а прийти оно может из физики. Сравниваем сами
	-- числа, а не собранную строку: строка собирается редко, а мусор,
	-- который она оставляет, каждый кадр собирал бы за собой сборщик
	local sc, lv, tm = math.floor(G.score), math.floor(G.lives), math.floor(G.time)
	if hudCache.sc ~= sc or hudCache.lv ~= lv or hudCache.tm ~= tm or hudCache.nm ~= L.name then
		hudCache.sc, hudCache.lv, hudCache.tm, hudCache.nm = sc, lv, tm, L.name
		scr:text(2, 1, string.format("MARIO %06d   x%02d   %s   %03d    ", sc, lv, L.name, tm), 2, 0)
	end
	local cn = math.floor(G.coins)
	if hudCache.cn ~= cn then
		hudCache.cn = cn
		scr:text(scr.w - 6, 1, string.format("$%02d", cn), 6, 0)
	end
	-- с --keys видно прямо в игре, доходят ли нажатия до машины
	if opt.keys and hudCache.key ~= G.lastKey then
		hudCache.key = G.lastKey
		scr:text(scr.w - 26, 2, "клавиша: " .. (G.lastKey or "-") .. "      ", 3, 0)
	end
	if opt.fps then
		-- без буфера видеопамяти кадр уходит на экран десятками вызовов
		-- вместо одного, и это видно по частоте - так что помечаем
		local f = ("фпс %2d%s"):format(math.floor((G.fps or 0) + 0.5),
			scr.buf and "" or " без VRAM")
		if hudCache.fps ~= f then
			hudCache.fps = f
			scr:text(2, 2, f, 3, 0)
		end
	end
end

--- Полноэкранная заставка: меню, заставка мира, конец игры. Строка,
--- начатая с "~", выделяется цветом, сама тильда не печатается.
local function screenText(lines, bgc)
	scr.top = 1
	scr:clear(bgc or 0)
	scr:flush(true)
	for i, l in ipairs(lines) do
		local row = floor(scr.h / 2) - #lines + (i - 1) * 2
		local fg = 2
		if l:sub(1, 1) == "~" then fg = 6 l = l:sub(2) end
		-- ширину считаем в символах: в кириллице байт вдвое больше
		local len = unicode.len(l)
		scr:text(math.max(1, floor((scr.w - len) / 2) + 1), row, l, fg, 0)
	end
	scr:present()
	scr.top = HUD + 1
end

------------------------------------------------------------------ загрузка уровня

local function loadLevel(n)
	buildArt()
	local def = art.levels[((n - 1) % #art.levels) + 1]
	G.level = build(def)
	G.time = G.level.time
	G.timeAcc = 0
	G.ents, G.fx, G.bumps, G.dirty = {}, {}, {}, {}
	G.camX, G.lastCam = 0, 0
	UNDER = def.theme == "under"
	G.water = def.theme == "water"

	local p = {}
	for i = 0, 15 do p[i] = art.palette[i] end
	local over = (def.theme == "under" and art.underPalette)
		or (def.theme == "castle" and art.castlePalette)
		or (def.theme == "water" and art.waterPalette)
	if over then for k, v in pairs(over) do p[k] = v end end
	SKY = 1
	scr:palette(p)

	if opt.from then G.level.start = { tonumber(opt.from), 10 } end
	resetMario(true)
	if opt.big then M.big = true M.h = 16 M.y = M.y - 8 M.fire = opt.big == "fire" end

	-- всё, что стоит на карте, ждёт своей колонки: враги оживают, когда
	-- камера подходит ближе экрана
	G.pending = {}
	for _, s in ipairs(G.level.spawn) do
		G.pending[#G.pending + 1] = { kind = s.kind, x = (s.col - 1) * TW,
			y = (s.row - 1) * TW, col = s.col,
			len = s.len, speed = s.speed, range = s.range, vert = s.vert }
	end

	for i = 1, scr.w * scr.h do scr.shown[i] = -1 end
	scr:clear(0)
	redrawAll()
	hudCache = {}
	G.hudDirty = true
end

------------------------------------------------------------------ шаг мира

local function activatePending()
	local limit = G.camX + PW + 24
	for i = #G.pending, 1, -1 do
		local s = G.pending[i]
		if s.x < limit then
			spawn(s.kind, s.x, s.y,
				{ len = s.len, speed = s.speed, range = s.range, vert = s.vert })
			table.remove(G.pending, i)
		end
	end
end

local function overlap(a, b)
	return a.x < b.x + b.w and b.x < a.x + a.w and
	       a.y < b.y + b.h and b.y < a.y + a.h
end

local function killEnemy(e, byShell)
	e.live = false
	addScore(byShell and 200 or 100)
end

local function stepEnemies(dt)
	for i = #G.ents, 1, -1 do
		local e = G.ents[i]
		local k = e.kind

		if e.rise and e.rise > 0 then
			-- бонус выезжает из блока: пока едет, сквозь всё проходит
			local d = math.min(e.rise, 26 * dt)
			e.y = e.y - d
			e.rise = e.rise - d
			if e.rise <= 0 and k == "mushroom" then e.vx = ENEMY_SPD * 1.6 end
		elseif k == "coin" then
			e.live = false
		elseif k == "fire" then
			e.vy = e.vy + GRAV * dt
			if moveX(e, e.vx * dt) then e.live = false end
			local before = e.y
			moveY(e, e.vy * dt)
			if e.ground then e.vy = -150 e.ground = false end
			if e.y == before and e.vy > 0 then e.vy = -150 end
			if e.x < G.camX - 8 or e.x > G.camX + PW + 8 then e.live = false end
		elseif k == "piranha" then
			-- Высовывается из трубы и прячется обратно, но пока Марио
			-- стоит прямо над трубой, сидит смирно - иначе её было бы не
			-- пройти.
			e.t = e.t + dt
			local near = math.abs((M.x + M.w / 2) - (e.x + 4)) < 16
			local phase = (e.t % 4) / 4
			local want = 0
			if phase < 0.35 then want = math.min(12, (phase / 0.35) * 12)
			elseif phase < 0.6 then want = 12
			elseif phase < 0.95 then want = 12 - ((phase - 0.6) / 0.35) * 12 end
			if near and want > e.out then want = e.out end
			e.out = want
			e.y = e.base - e.out
			e.anim = e.anim + dt * 5
		elseif k == "firebar" then
			-- вертящийся огненный стержень: сам не движется, опасны огоньки
			e.ang = e.ang + e.speed * dt
			if not M.dead and not M.win then
				local cx, cy = e.x + 4, e.y + 4
				for j = 1, e.len do
					local r = j * 6
					local fx = cx + math.cos(e.ang) * r
					local fy = cy + math.sin(e.ang) * r
					if M.x < fx + 3 and fx - 3 < M.x + M.w and
					   M.y < fy + 3 and fy - 3 < M.y + M.h then hurt() end
				end
			end
		elseif k == "platform" then
			-- ходит между двумя точками; Марио, стоящий сверху, едет с ней
			e.home = e.home or (e.vert and e.y or e.x)
			local d = 30 * dt * e.dir
			if e.vert then
				e.y = e.y + d
				if e.y > e.home + e.range then e.y = e.home + e.range e.dir = -1
				elseif e.y < e.home - e.range then e.y = e.home - e.range e.dir = 1 end
			else
				e.x = e.x + d
				if e.x > e.home + e.range then e.x = e.home + e.range e.dir = -1
				elseif e.x < e.home - e.range then e.x = e.home - e.range e.dir = 1 end
			end
			e.dx, e.dy = e.vert and 0 or d, e.vert and d or 0
		elseif k == "cheep" then
			-- рыба плывёт по прямой, слегка покачиваясь
			e.t = (e.t or 0) + dt
			e.x = e.x + e.vx * dt
			e.y = e.swim + math.sin(e.t * 2) * 6
			if e.x < G.camX - 24 then e.live = false end
		elseif k == "flyfish" then
			-- выпрыгнула, описала дугу и ушла обратно в воду
			e.vy = e.vy + 320 * dt
			e.x = e.x + e.vx * dt
			e.y = e.y + e.vy * dt
			if e.y > PH + 16 then e.live = false end
		elseif k == "axe" then
			-- топор ждёт Марио и обрывает мост вместе с Боузером
			e.anim = e.anim + dt
		elseif k == "bowser" then
			e.vy = math.min(e.vy + GRAV * dt, MAXFALL)
			e.anim = e.anim + dt * 3
			e.home = e.home or e.x
			if step(e, e.vx * dt, e.vy * dt) then e.vx = -e.vx end
			if e.x > e.home + 24 then e.vx = -math.abs(e.vx)
			elseif e.x < e.home - 24 then e.vx = math.abs(e.vx) end
			local now = computer.uptime()
			if e.ground and now > (e.jumpAt or 0) then
				e.jumpAt = now + 2.5
				e.vy = -150
			end
			if now > (e.fireAt or 0) and e.x - M.x < 130 then
				e.fireAt = now + 1.8
				spawn("bowserfire", e.x - 4, e.y + 5, { vx = -110 })
			end
		elseif k == "bowserfire" then
			e.x = e.x + e.vx * dt
			if e.x < G.camX - 16 then e.live = false end
			if not M.dead and not M.win and overlap(M, e) then
				e.live = false
				hurt()
			end
		elseif k == "flower" then
			-- стоит и ждёт
		else
			-- гумбы, купы, панцири и грибы падают и ходят до стены
			e.vy = math.min(e.vy + GRAV * dt, MAXFALL)
			if e.flat then
				e.flatT = (e.flatT or 0) + dt
				if e.flatT > 0.5 then e.live = false end
			else
				if step(e, e.vx * dt, e.vy * dt) then e.vx = -e.vx end
				-- не шагать в пропасть умеют все, кроме пущенного панциря
				if e.ground and k ~= "shell" then
					local ahead = floor((e.x + (e.vx > 0 and e.w + 1 or -1)) / TW) + 1
					local below = floor((e.y + e.h + 1) / TW) + 1
					if not solidAt(ahead, below) then e.vx = -e.vx end
				end
				e.anim = e.anim + dt * 6
			end
			if e.y > PH + 32 then e.live = false end
		end

		-- огненный шар сшибает то, во что попал
		if k == "fire" and e.live then
			for _, o in ipairs(G.ents) do
				if o.live and overlap(e, o) then
					local ok = o.kind
					if ok == "goomba" or ok == "koopa" or ok == "shell"
					   or ok == "piranha" or ok == "cheep" or ok == "flyfish" then
						killEnemy(o, true)
						e.live = false
						beep(500, 0.04)
					elseif ok == "bowser" then
						o.hp = o.hp - 1
						o.hit = 0.15
						e.live = false
						if o.hp <= 0 then
							o.live = false
							addScore(5000)
						end
					end
				end
			end
		end

		-- панцирь сшибает всех на пути
		if k == "shell" and e.vx ~= 0 then
			for _, o in ipairs(G.ents) do
				if o ~= e and o.live and (o.kind == "goomba" or o.kind == "koopa") and overlap(e, o) then
					killEnemy(o, true)
					beep(500, 0.05)
				end
			end
		end

		-- встреча с Марио
		if e.live and not M.dead and not M.win and overlap(M, e) then
			trace("встреча с %s: py=%.1f pvy=%.1f y=%.1f вражья y=%.1f", k,
				M.py or -1, M.pvy or -1, M.y, e.y)
			if k == "platform" then
				-- платформа не вредит: на ней стоят, это разбирается в
				-- шаге Марио
			elseif k == "axe" then
				-- топор обрывает мост, и Боузер падает в лаву вместе с ним
				e.live = false
				for _, o in ipairs(G.ents) do
					if o.kind == "bowser" then o.live = false end
				end
				local br = G.level.bridge
				if br then
					for c = br.x1, br.x2 do setTile(c, br.y, nil) end
				end
				addScore(5000)
				M.win, M.winT, M.castleWin = true, 0, true
				M.vx, M.vy = 0, 0
				beep(1000, 0.08)
			elseif k == "piranha" or k == "cheep" or k == "flyfish" or k == "bowser" then
				-- этих не потопчешь: пиранья кусается, рыба в воде, а
				-- Боузера берёт только огонь или топор
				hurt()
			elseif k == "mushroom" or k == "flower" then
				e.live = false
				grow(k)
			elseif k == "shell" then
				-- насколько глубоко Марио вошёл во врага сверху: считать по
				-- ней надёжнее, чем по краю - при 15 кадрах в секунду за шаг
				-- пролетает с десяток пикселей, и тонкую полоску над головой
				-- врага Марио просто перепрыгивает
				-- падал ли Марио на врага сверху: судить надо по тому, где
				-- он был в начале кадра. Враг не подставка, Марио проваливается
				-- мимо него до земли и к этой проверке уже стоит с vy = 0
				local fromAbove = (M.pvy or 0) > 0 and (M.py or M.y) + M.h <= e.y + 3
				if e.vx ~= 0 and fromAbove then
					e.vx = 0
					M.vy = -160
				elseif e.vx == 0 then
					e.vx = (M.x < e.x) and SHELL_SPD or -SHELL_SPD
					e.x = e.x + (e.vx > 0 and 2 or -2)
					addScore(400)
					beep(600, 0.05)
				else
					hurt()
				end
			elseif not e.flat then
				-- сверху - топот, иначе больно
				if (M.pvy or 0) > 0 and (M.py or M.y) + M.h <= e.y + 3 then
					if k == "koopa" then
						e.kind = "shell"
						e.vx = 0
						e.h = 12
						e.y = e.y + 0
						addScore(100)
					else
						e.flat = true
						e.vx = 0
						killEnemy(e)
					end
					M.vy = down("up") and -220 or -150
					beep(800, 0.04)
				else
					hurt()
				end
			end
		end

		-- уехавшее за левый край больше не нужно: на длинном уровне
		-- иначе к концу набирается десяток существ, которые считаются
		-- каждый кадр и которых никто не увидит
		if e.live and e.x < G.camX - 48 and k ~= "shell"
		   and k ~= "platform" and k ~= "firebar" and k ~= "axe" and k ~= "bowser" then
			e.live = false
		end
		if not e.live then table.remove(G.ents, i) end
	end
end

local function stepEffects(dt)
	for i = #G.fx, 1, -1 do
		local f = G.fx[i]
		f.t = f.t + dt
		if f.kind == "coin" then
			f.y = f.y + f.vy * dt
			f.vy = f.vy + 520 * dt
			if f.t > 0.45 then table.remove(G.fx, i) end
		elseif f.kind == "debris" then
			f.vy = f.vy + 620 * dt
			f.x = f.x + f.vx * dt
			f.y = f.y + f.vy * dt
			if f.y > PH + 16 or f.t > 1.4 then table.remove(G.fx, i) end
		elseif f.kind == "score" then
			f.y = f.y - 26 * dt
			if f.t > 0.7 then table.remove(G.fx, i) end
		end
	end
	for i = #G.bumps, 1, -1 do
		local b = G.bumps[i]
		b.t = b.t + dt
		local prev = b.dy or 0
		b.dy = floor(math.sin(math.min(b.t, 0.18) / 0.18 * math.pi) * 4)
		if prev ~= b.dy then markDirty(b.c) end
		if b.t > 0.18 then
			markDirty(b.c)
			table.remove(G.bumps, i)
		end
	end
end

local function stepMario(dt)
	if M.dead then
		M.deadT = M.deadT + dt
		if M.deadT > 0.4 then
			M.vy = math.min(M.vy + GRAV * dt, MAXFALL)
			M.y = M.y + M.vy * dt
		end
		return
	end

	if M.win then
		M.winT = M.winT + dt
		if M.castleWin then
			-- в замке победу даёт топор: Марио уходит вправо
			M.vx = 46
			M.x = M.x + M.vx * dt
			M.anim = M.anim + dt * 8
			M.ground = true
			M.face = 1
			return
		end
		-- съезд по флагштоку, потом шаг к замку
		if M.y + M.h < (10 - 1) * TW then
			M.y = M.y + 46 * dt
			M.face = 1
		else
			M.vx = 46
			M.x = M.x + M.vx * dt
			M.anim = M.anim + dt * 8
			M.ground = true
		end
		return
	end

	local want = 0
	if down("left") then want = -1 end
	if down("right") then want = want + 1 end
	M.duck = M.big and down("down") and M.ground

	local top = down("run") and RUN or WALK
	if G.water then top = SWIM_WALK end
	if M.duck then want = 0 end

	if want ~= 0 then
		local turning = (want > 0 and M.vx < 0) or (want < 0 and M.vx > 0)
		M.vx = M.vx + want * (turning and SKID or ACC) * dt
		if math.abs(M.vx) > top then M.vx = want * top end
		M.face = want
		M.skid = turning and M.ground
	else
		M.skid = false
		local d = DEC * dt
		if math.abs(M.vx) <= d then M.vx = 0 else M.vx = M.vx - (M.vx > 0 and d or -d) end
	end

	-- Прыжок. Нажатие живёт JUMP_BUF секунды, а земля под ногами - ещё
	-- COYOTE после схода с края: тогда прыжок, нажатый чуть раньше
	-- приземления или чуть позже обрыва, всё равно случается. Повторное
	-- нажатие берётся только с новой клавиши, поэтому зажатая кнопка не
	-- заставляет Марио скакать. Пока её держат и он летит вверх, тянет
	-- слабее - отсюда высота по длине нажатия.
	M.jumpBuf = M.jumpBuf > 0 and M.jumpBuf - dt or 0
	M.coyote = M.ground and COYOTE or (M.coyote > 0 and M.coyote - dt or 0)
	if M.jumpBuf > 0 and M.coyote > 0 and not G.water then
		M.vy = JUMP - math.abs(M.vx) * 0.12
		M.ground, M.coyote, M.jumpBuf = false, 0, 0
		trace("прыжок с y=%.0f", M.y)
		beep(520, 0.04)
	end
	M.jumpHeld = down("up")
	local g = (M.jumpHeld and M.vy < 0) and GRAV_HOLD or GRAV
	M.vy = math.min(M.vy + g * dt, MAXFALL)
	if G.water then
		-- под водой не прыгают, а гребут: толчок вверх по нажатию, не
		-- чаще чем раз в четверть секунды, и тонешь медленно
		M.vy = math.min(M.pvyRaw or M.vy, SWIM_MAX)
		M.vy = math.min(M.vy + SWIM_GRAV * dt, SWIM_MAX)
		M.swimAt = math.max(0, (M.swimAt or 0) - dt)
		if M.jumpBuf > 0 and M.swimAt <= 0 then
			M.vy = SWIM_UP
			M.swimAt = 0.28
			M.jumpBuf = 0
			M.ground = false
		end
	end
	M.pvyRaw = M.vy

	M.py, M.pvy = M.y, M.vy
	step(M, M.vx * dt, M.vy * dt, bumpBlock)
	if M.x < G.camX then M.x = G.camX M.vx = 0 end     -- назад за край экрана нельзя

	-- лава не держит и не ранит - она убивает сразу
	do
		local c1 = floor(M.x / TW) + 1
		local c2 = floor((M.x + M.w - 1) / TW) + 1
		local r1 = floor(M.y / TW) + 1
		local r2 = floor((M.y + M.h - 1) / TW) + 1
		for c = c1, c2 do
			for r = r1, r2 do
				if DEADLY[tileAt(c, r) or ""] then
					M.dead, M.deadT, M.vy = true, 0, -230
					return
				end
			end
		end
	end

	-- ходячая платформа: на ней стоят и едут вместе с ней
	for _, e in ipairs(G.ents) do
		if e.kind == "platform" and e.live then
			local prevBottom = (M.py or M.y) + M.h
			if M.vy >= 0 and M.x + M.w > e.x and e.x + e.w > M.x
			   and prevBottom <= e.y + 4 and M.y + M.h >= e.y then
				M.y = e.y - M.h
				M.vy = 0
				M.ground = true
				M.coyote = 0.1
				M.x = M.x + (e.dx or 0)
				M.y = M.y + (e.dy or 0)
			end
		end
	end

	if M.ground and math.abs(M.vx) > 4 then M.anim = M.anim + dt * (4 + math.abs(M.vx) / 14) end
	if M.inv > 0 then M.inv = M.inv - dt end

	-- флагшток
	local L = G.level
	if L.flag and not M.win then
		local fx = (L.flag - 1) * TW
		if M.x + M.w >= fx and M.x <= fx + TW then
			M.win = true
			M.winT = 0
			M.vx, M.vy = 0, 0
			M.x = fx - 4
			addScore(2000 + math.max(0, (10 - 1) * TW - M.y) * 4)
			beep(1000, 0.08)
		end
	end

	if M.y > PH + 24 then
		M.dead = true
		M.deadT = 1
	end
end

--- Огненный шар по кнопке бега, когда Марио с цветком.
local function tryFire()
	if not (M.fire and not M.dead and not M.win) then return end
	local n = 0
	for _, e in ipairs(G.ents) do if e.kind == "fire" then n = n + 1 end end
	if n >= 2 then return end
	spawn("fire", M.x + (M.face > 0 and M.w or -6), M.y + 2, { vx = M.face * FIRE_SPD, vy = 40 })
	beep(1200, 0.03)
end

------------------------------------------------------------------ кадр

-- Счётчик по фазам кадра: включается ключом --prof и печатает разбивку
-- при выходе. os.clock есть только на стенде, в игре профиль промолчит.
local clock = os.clock or function() return 0 end
local prof = { restore = 0, scroll = 0, cols = 0, sprites = 0, flush = 0, logic = 0 }
local function mark(name, t0)
	prof[name] = prof[name] + (clock() - t0)
	return clock()
end

local function render()
	local t = opt.prof and clock() or 0
	scr:restore()
	if opt.prof then t = mark("restore", t) end

	-- прокрутка: камера едет за Марио и никогда не откатывается назад
	local target = floor(M.x) - 62
	if target > G.camX then G.camX = target end
	local maxCam = G.level.w * TW - PW
	if G.camX > maxCam then G.camX = maxCam end
	if G.camX < 0 then G.camX = 0 end

	local dx = G.camX - G.lastCam
	if dx ~= 0 then
		scr:scroll(dx)
		if opt.prof then t = mark("scroll", t) end
		G.lastCam = G.camX
		-- дорисовываем ровно те колонки, что открылись с краю, а не
		-- четыре про запас: на быстром беге это вдвое меньше работы
		local from, to
		if dx > 0 then
			from = floor((G.camX + PW - dx) / TW) + 1
			to = floor((G.camX + PW - 1) / TW) + 1
		else
			from = floor(G.camX / TW) + 1
			to = floor((G.camX - dx) / TW) + 1
		end
		for c = from, to do drawColumn(c) end
	end
	if opt.prof then t = mark("cols", t) end

	-- --redraw собирает фон заново каждый кадр: так проверяется, что
	-- обычная дорисовка по краям ничего не пропускает
	if opt.redraw then
		redrawAll()
		for c in pairs(G.dirty) do G.dirty[c] = nil end
	else
		for c in pairs(G.dirty) do drawColumn(c) G.dirty[c] = nil end
	end

	-- спрайты поверх фона, с запоминанием того, что под ними
	local ox = -G.camX + 1
	for _, f in ipairs(G.fx) do
		local a = f.kind == "coin" and SPR.coin or (f.kind == "debris" and SPR.debris)
		if a then scr:stamp(floor(f.x) + ox, floor(f.y) + TOP + 1, a) end
	end
	for _, e in ipairs(G.ents) do
		if e.kind == "firebar" then
			-- стержень - это цепочка огоньков вокруг своей точки
			local cx, cy = floor(e.x) + ox + 4, floor(e.y) + TOP + 5
			for j = 1, e.len do
				local r = j * 6
				local fx = floor(cx + math.cos(e.ang) * r) - 4
				local fy = floor(cy + math.sin(e.ang) * r) - 4
				if fx > -8 and fx <= PW then scr:stamp(fx, fy, SPR.fireball) end
			end
		elseif e.kind == "platform" then
			-- платформа шире спрайта, поэтому выкладывается тайлами
			for j = 0, (e.len or 3) - 1 do
				local sx = floor(e.x) + ox + j * TW
				if sx > -8 and sx <= PW then
					scr:stamp(sx, floor(e.y) + TOP + 1, TILEART.m)
				end
			end
		else
			local a = entSprite(e)
			if a then
				local sx = floor(e.x) + ox - (e.w < 8 and 1 or 0)
				if sx > -16 and sx <= PW then scr:stamp(sx, floor(e.y) + TOP + 1, a) end
			end
		end
	end
	if M.inv <= 0 or (floor(M.inv * 14) % 2 == 0) then
		scr:stamp(floor(M.x) + ox - 1, floor(M.y) + TOP + 1, marioSprite())
	end
	if opt.prof then t = mark("sprites", t) end

	scr:flush(true)
	drawHUD()
	scr:present()
	if opt.prof then mark("flush", t) end
end

------------------------------------------------------------------ главный цикл

local running = true

-- Ввод. Клавиатура приходит сигналами, и очередь у машины одна на всё;
-- за одно пробуждение мод отдаёт ровно один сигнал. Отсюда всё, из-за
-- чего управление казалось вязким:
--
--  * пока клавишу держат, мод шлёт key_down снова и снова, чаще, чем идут
--    кадры. Разбирая по событию за кадр, игра отставала всё сильнее, и
--    key_up приходило с опозданием в секунды: Марио бежал, когда его уже
--    отпустили, а очередь мода в конце концов переполнялась и теряла
--    сигналы - тогда клавиша залипала совсем;
--  * event.pull(0) очередь не спрашивает вовсе (при нулевом ожидании он
--    выходит сразу), так что прежний "добор" не разбирал ничего;
--  * нажатие и отпускание, попавшие в один кадр, гасили друг друга -
--    короткий тычок по прыжку пропадал целиком.
--
-- Теперь очередь разбирается напрямую computer.pullSignal: он, в отличие
-- от event.pull, отдаёт то, что уже стоит в очереди. За кадр добираем
-- столько, сколько успеваем до нового тика, и к самому кадру ввод разобран
-- весь. Повтор от мода отличается от нового нажатия тем, что клавиша уже
-- помечена зажатой, и на прыжок с огнём не влияет.
--
-- Чего здесь сознательно нет - сторожа на потерянное key_up. Соблазн
-- велик: отпускание всё-таки может пропасть, и тогда Марио уйдёт в
-- пропасть сам. Но узнать об этом не по чему. Система повторяет только
-- ту клавишу, которую нажали последней: зажал "вправо", нажал прыжок - и
-- "вправо" молчит, хотя его держат. Сторож, считающий молчание за
-- отпускание, отпускал бы бег на ровном месте, а следующий повтор
-- принимал бы за новое нажатие - то есть заставлял бы Марио скакать на
-- зажатом прыжке. Лучше уж редкое залипание, которое лечится повторным
-- нажатием.

local pullSignal = computer.pullSignal
local DRAIN = 64          -- событий за кадр самое большее, страховка от потопа

local frame = 0           -- номер кадра: им метятся нажатия

--- Разобрать один сигнал. Возвращает false, когда игру пора закрывать.
local function handleSignal(e, _, _, code)
	if e == "key_down" then
		if opt.keys then G.lastKey = "вниз " .. tostring(code) end
		if keys[code] then
			-- Это повтор от мода, а не новое нажатие: пока клавишу просто
			-- держат, он шлёт key_down снова и снова. Марио от них не
			-- скачет и не стреляет - прыжок берётся только с новой
			-- клавиши, как в приставочном оригинале.
			keys[code] = frame
			return true
		end
		keys[code] = frame
		for _, u in ipairs(K.up) do if code == u then M.jumpBuf = JUMP_BUF end end
		for _, q in ipairs(K.quit) do if code == q then return false end end
		if code == 45 or code == 44 or code == 42 or code == 54 then tryFire() end
		-- на заставке годится любая клавиша: так сразу видно, доходит ли
		-- до игры ввод вообще
		if G.state == "title" then G.state = "intro" G.wait = 0 G.drawn = false end
		if G.state == "over" or G.state == "won" then
			G.score, G.lives, G.lv = 0, 3, 1
			G.state = "intro" G.wait = 0 G.drawn = false
		end
	elseif e == "key_up" then
		if opt.keys then G.lastKey = "вверх " .. tostring(code) end
		-- нажали и отпустили внутри одного кадра: касание всё равно
		-- должно сработать, иначе при двадцати кадрах в секунду пропадает
		-- всякий быстрый тычок
		if keys[code] == frame then tap[code] = true end
		keys[code] = nil
	elseif e == "interrupted" then
		return false
	end
	return true
end

--- Разобрать очередь и дождаться нового тика.
---
--- Часы машины идут тиками по 0.05 с, а просыпается она чаще: мод будит
--- её каждые executionDelay миллисекунд, пока есть чем заняться. Вернись
--- отсюда раньше, чем часы сдвинулись, - и у кадра выйдет нулевое dt, а
--- физике придётся выдумать время: игра пойдёт быстрее настоящей. Плавнее
--- она от лишних кадров всё равно не станет - экран обновляется раз в
--- тик, - зато бюджет вызовов они съедят.
---
--- Поэтому кадр здесь один на тик, а промежуток не пропадает: пока тик не
--- начался, из очереди выбирается ввод. В этом и вся затея - раньше за
--- кадр разбиралось одно событие, теперь успевает несколько, и к самому
--- кадру ввод разобран весь, до последнего отпускания.
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

local function die()
	G.lives = G.lives - 1
	if G.lives <= 0 then
		G.state = "over"
		G.wait = 0
		G.drawn = false
	else
		G.state = "intro"
		G.wait = 0
	end
end

local ok, err = pcall(function()
	scr:palette(pal)
	scr:reserveTop(HUD)
	if opt.fullscan then scr.fullScan = true end
	-- уровень тут не строится: заставка ничего о нём не знает, а к тому
	-- времени, как игрок нажмёт клавишу, состояние "intro" построит его
	-- сам. Раньше он строился дважды - до заставки и после неё.
	G.state = "title"

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
				local lines = { "S U P E R   M A R I O", "", "OpenComputers edition",
				                "", "~любая клавиша - начать игру",
				                "стрелки - идти, вверх - прыжок",
				                "X - бег и огонь, Q - выход" }
				-- о том, что сильно портит частоту кадров, лучше сказать
				-- сразу, а не оставлять гадать
				if not scr.buf then
					lines[#lines + 1] = ""
					lines[#lines + 1] = "~нет видеопамяти: кадр уходит на экран"
					lines[#lines + 1] = "~десятками вызовов, будет медленно"
				end
				local rw, rh = gpu.getResolution()
				if rw < COLS * TW or rh * 2 < PH + TOP then
					lines[#lines + 1] = ""
					lines[#lines + 1] = ("~экран %dx%d вместо 160x50 - видно не всё"):format(rw, rh)
				end
				screenText(lines)
			end
			-- меню ждёт клавиши, кадры крутить незачем
			pump(0.2)
		elseif G.state == "intro" then
			if G.wait == 0 then
				loadLevel(G.lv)
				screenText({ "МИР " .. G.level.name, "", "Марио  x" .. G.lives })
			end
			G.wait = G.wait + dt
			if G.wait > 1.4 then
				G.state = "play"
				-- клавишу, которой уходили с заставки, засчитывать за
				-- прыжок не надо: на заставке годится любая, в том числе
				-- пробел, и Марио подпрыгивал бы на первом же кадре
				M.jumpBuf, M.coyote = 0, 0
				for i = 1, scr.w * scr.h do scr.shown[i] = -1 end
				scr:clear(0)
				redrawAll()
				hudCache = {}
				last = computer.uptime()
			end
		elseif G.state == "won" then
			if not G.drawn then
				G.drawn = true
				screenText({ "И Г Р А   П Р О Й Д Е Н А", "",
				             "пройдено уровней: " .. #art.levels,
				             "счёт " .. math.floor(G.score),
				             "", "~любая клавиша - сначала", "Q - выход" })
			end
			pump(0.2)
		elseif G.state == "over" then
			if not G.drawn then
				G.drawn = true
				screenText({ "И Г Р А   О К О Н Ч Е Н А", "", "счёт " .. G.score,
				             "", "~любая клавиша - сначала", "Q - выход" })
			end
			pump(0.2)
		else
			local tl = opt.prof and clock() or 0
			activatePending()
			-- Длинный кадр считается не одним шагом, а несколькими: тяжесть
			-- и разгон складываются по шагам, поэтому при кадре вдвое
			-- длиннее прыжок вышел бы заметно другим. Дробим до SUBSTEP -
			-- обычный кадр как был одним шагом, так и остаётся, а просевший
			-- перестаёт менять высоту прыжка и дальность разбега.
			local n = math.ceil(dt / SUBSTEP)
			local sd = dt / n
			for _ = 1, n do
				stepMario(sd)
				stepEnemies(sd)
				stepEffects(sd)
			end
			if opt.trace and (G.traceT or 0) + 1 < computer.uptime() then
				G.traceT = computer.uptime()
				local e = G.ents[1]
				trace("Марио x=%.0f y=%.0f vy=%.0f земля=%s врагов=%d  первый: %s x=%.0f y=%.0f vx=%.0f",
					M.x, M.y, M.vy, tostring(M.ground), #G.ents,
					e and e.kind or "-", e and e.x or 0, e and e.y or 0, e and e.vx or 0)
			end
			if opt.prof then prof.logic = prof.logic + (clock() - tl) end

			G.timeAcc = G.timeAcc + dt
			if G.timeAcc > 0.4 and not M.win then
				G.timeAcc = G.timeAcc - 0.4
				G.time = G.time - 1
				G.hudDirty = true
				if G.time <= 0 then M.dead = true M.deadT = 1 end
			end

			render()

			if M.dead and M.deadT > 2.2 then die() end
			if M.win and M.winT > (M.castleWin and 2.5 or 3.5) then
				G.lv = G.lv + 1
				if G.lv > #art.levels then
					G.state = "won"
					G.drawn = false
				else
					G.state = "intro"
					G.wait = 0
				end
			end

			frames = frames + 1
			fpsT = fpsT + dt
			if fpsT > 1 then
				G.fps = frames / fpsT
				frames, fpsT = 0, 0
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
	local order = { "logic", "restore", "scroll", "cols", "sprites", "flush" }
	io.stderr:write(("профиль, всего %.3f с:\n"):format(sum))
	for _, k in ipairs(order) do
		io.stderr:write(("  %-8s %6.1f мс  %4.1f%%\n"):format(
			k, prof[k] * 1000, sum > 0 and prof[k] / sum * 100 or 0))
	end
end
print(("Счёт: %d   монет: %d"):format(G.score, G.coins))
