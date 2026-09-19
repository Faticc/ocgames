--|============================|
--|         OpenCasino.        |
--|       Автор: SkyDrive_     |
--| Проект McSkill, cервер HTC |
--|         01.04.2017         |
--|   Version: 2.0 (графика)   |
--|============================|
-- Однорукий бандит. Всё рисуется полублоками: ячейка экрана - это два
-- пикселя, фон сверху и цвет символа снизу, так что 146x42 символа - это
-- поле 146x84 точки. Кадр собирается в таблице, в видеопамять уходят
-- только изменившиеся ячейки, а на экран - либо повтор этих же вызовов
-- (когда их немного), либо один bitblt. Поэтому барабаны крутятся 20
-- кадров в секунду, а не перерисовкой картинок через g.set.
--
-- Правила, выплаты, ставки, чат, редстоун и статистика - прежние.

local component = require("component")
local computer = require("computer")
local event = require("event")
local fs = require("filesystem")
local shell = require("shell")
local serial = require("serialization")
local g = component.gpu
event.shouldInterrupt = function () return false end
--------------------Настройки--------------------
local WIDTH, HEIGHT = 146, 42 --Разрешение; раскладка на 146x42, на мониторе больше встаёт по центру
local AUTOEXIT = 30 --Автовыход через n сек.
local TONE = 600 --Тональность звука
local RED = 0 --Сторона редстоун блока
local CHAT_NAME = "§8[§2OpenCasino§8]: " --Ник чатбокса
local STAVKA = 5 --Начальная ставка
local MAX_STAVKA = 10 --Максимальная ставка (до 1000 влезает в табло)
local SPAM = 1 --Время, в течении которого нельзя юзать комп, после выхода
-------------------------------------------------

-- Без загрузчика DwSoft (в наборе игр это games/casino.lua) библиотеки
-- sky нет - нужное из неё собирается здесь. Нет и opencb - игра идёт на
-- фишки: у каждого 1000, деньги не настоящие, выйти можно клавишей Q.
local DEMO = false
if not sky then
	local unicode = require("unicode")
	sky = {}
	function sky.fileRead(path)
		local f = io.open(path, "r")
		if not f then return nil end
		local t = f:read("*a")
		f:close()
		return t
	end
	function sky.fileWrite(path, text)
		local f = io.open(path, "w")
		if f then f:write(tostring(text) .. "\n") f:close() end
	end
	if component.isAvailable("opencb") then
		function sky.com(command)
			local _, c = component.opencb.execute(command)
			return c
		end
		function sky.money(nick)
			local c = sky.com("money " .. nick) or ""
			local _, b = string.find(c, "Баланс: §f")
			if b == nil then return "0.00" end
			if string.find(c, "Emeralds") ~= nil then return unicode.sub(c, b - 16, unicode.len(c) - 10) end
			return unicode.sub(c, b - 16, unicode.len(c) - 9)
		end
		function sky.checkMoney(nick, price)
			local balance = sky.money(nick)
			balance = string.sub(balance, 1, string.len(balance) - 3)
			if string.find(balance, "-") ~= nil then return false end
			balance = tonumber((string.gsub(balance, ",", "")))
			if not balance or balance < price then return false end
			sky.com("money take " .. nick .. " " .. price)
			return true
		end
	else
		DEMO = true
		local chips = {}
		function sky.money(nick) return string.format("%.2f", chips[nick] or 1000) end
		function sky.checkMoney(nick, price)
			local have = chips[nick] or 1000
			if have < price then return false end
			chips[nick] = have - price
			return true
		end
		function sky.com(command)
			local nick, n = command:match("^money give (%S+) (%S+)$")
			if nick then chips[nick] = (chips[nick] or 1000) + tonumber(n) end
		end
	end
end

local floor, sqrt, abs, rnd = math.floor, math.sqrt, math.abs, math.random
local atan2 = math.atan2 or math.atan

--------------------------------------------------------------- правила

-- порядок символов тот же, что в первой версии: по нему идут барабаны
-- и по нему считается выигрыш
local SYMBOLS = {"cherry", "seven", "diamond", "orange", "pickaxe", "cheese", "pokeball", "meat", "apple"}
local BONUS = {15, 100, 40, 20, 12, 17, 10, 25, 30}
local NAMES = {"Три вишни", "Три семёрки", "Три алмаза", "Три апельсина", "Три кирки",
	"Три сыра", "Три покебола", "Три окорочка", "Три яблока"}

local function Wins(a, b, c)
	if a == b and b == c then return BONUS[a]
	elseif a == b or b == c then return 2
	elseif a == c then return 1
	end
	return 0
end

--------------------------------------------------------------- экран

local maxW, maxH = g.maxResolution()
local SW, SH = math.min(WIDTH, maxW), math.min(HEIGHT, maxH)
if SW < 146 or SH < 42 then error("OpenCasino: нужен экран 146x42 - монитор и видеокарта 3 уровня") end
g.setResolution(SW, SH)
local PW, PH = SW, SH * 2
local OX = floor((SW - 146) / 2)       -- сдвиг раскладки, если экран больше
local OR = floor((SH - 42) / 2)        -- то же в строках
local OY = OR * 2                      -- и в пикселях: всегда чётный, текст ложится в ячейки

-- своя палитра: тёмные фоны, серые и слоновая кость барабанов. Остальные
-- цвета взяты из куба 6x8x5, который у видеокарты неизменен, - так все
-- они на экране ровно такие, как записаны
local PALETTE = {0x0E0719, 0x170B29, 0x24103C, 0x3A1A5E, 0x0A0612, 0x3C3C3C, 0x787878, 0xB4B4B4,
	0x2E0A1E, 0x4A1030, 0xFFF8E6, 0xE0DACA, 0xB8B2A6, 0x8C8880, 0x615E57, 0x38362F}
for i = 1, 16 do pcall(g.setPaletteColor, i - 1, PALETTE[i]) end

local fb, shown, ov = {}, {}, {}      -- кадр в пикселях, что уже в буфере, надписи поверх
local dmin, dmax = {}, {}             -- изменившиеся отрезки по строкам экрана
for i = 1, PW * PH do fb[i] = 0 end
for i = 1, SW * SH do shown[i] = -1 end

local buf
if g.allocateBuffer then
	local ok, id = pcall(g.allocateBuffer, SW, SH)
	if ok and id then buf = id end
end

--- Пометить прямоугольник пикселей изменившимся.
local function touch(x, y, w, h)
	x, y = x + OX, y + OY
	local x2 = x + w - 1
	if x < 1 then x = 1 end
	if x2 > PW then x2 = PW end
	if x2 < x then return end
	local r1, r2 = floor((y + 1) / 2), floor((y + h) / 2)
	if r1 < 1 then r1 = 1 end
	if r2 > SH then r2 = SH end
	for r = r1, r2 do
		local a = dmin[r]
		if not a then
			dmin[r], dmax[r] = x, x2
		else
			if x < a then dmin[r] = x end
			if x2 > dmax[r] then dmax[r] = x2 end
		end
	end
end

--- Точка в координатах раскладки 146x84; помечать изменения - дело вызывающего.
local function px(x, y, c)
	x, y = x + OX, y + OY
	if x >= 1 and x <= PW and y >= 1 and y <= PH then fb[(y - 1) * PW + x] = c end
end

local function getpx(x, y)
	x, y = x + OX, y + OY
	if x >= 1 and x <= PW and y >= 1 and y <= PH then return fb[(y - 1) * PW + x] end
end

local function rect(x, y, w, h, c)
	for yy = y, y + h - 1 do
		for xx = x, x + w - 1 do px(xx, yy, c) end
	end
	touch(x, y, w, h)
end

-------------------------------------------------------------- надписи

local UTF = "[\0-\x7F\xC2-\xF4][\x80-\xBF]*"

local function ulen(s)
	local n = 0
	for _ in s:gmatch(UTF) do n = n + 1 end
	return n
end

local function ucut(s, n)
	local out, k = {}, 0
	for ch in s:gmatch(UTF) do
		k = k + 1
		if k > n then break end
		out[k] = ch
	end
	return table.concat(out)
end

--- Текст поверх картинки, в ячейках раскладки. Неизменившиеся буквы
--- остаются теми же записями - их повторная запись ничего не стоит.
local function put(col, row, s, fgc, bgc)
	col, row = col + OX, row + OR
	if row < 1 or row > SH then return end
	local o, x = (row - 1) * SW, col
	for ch in s:gmatch(UTF) do
		if x >= 1 and x <= SW then
			local k = o + x
			local e = ov[k]
			if not (e and e[1] == ch and e[2] == fgc and e[3] == bgc) then ov[k] = {ch, fgc, bgc} end
		end
		x = x + 1
	end
	touch(col - OX, row * 2 - 1 - OY, x - col, 2)
end

--- Строка заданной ширины: остаток забивается пробелами, так старая
--- надпись под ней стирается сама.
local function line(col, row, width, s, fgc, bgc, align)
	local n = ulen(s)
	if n > width then s, n = ucut(s, width), width end
	local left = 0
	if align == "c" then left = floor((width - n) / 2) elseif align == "r" then left = width - n end
	put(col, row, string.rep(" ", left) .. s .. string.rep(" ", width - n - left), fgc, bgc)
end

-------------------------------------------------------------- вывод

local fgNow, bgNow
local function setfg(c) if c ~= fgNow then g.setForeground(c) fgNow = c end end
local function setbg(c) if c ~= bgNow then g.setBackground(c) bgNow = c end end

-- Журнал вывода. Всё, что кладётся в буфер видеопамяти, записывается ещё
-- и сюда, а в конце кадра решается, как показать: повторить журнал прямо
-- на экране или положить весь буфер одним bitblt. Вызовы к буферу бюджет
-- машины не тратят, а вот bitblt грязного буфера стоит почти целый тик -
-- поэтому, пока изменений немного (а между кадрами их обычно немного),
-- десяток прямых вызовов дешевле. Так же устроен present в системном gfx.
local logSet, logCopy, present
do
	local jn, jcost = 0, 0
	local jkind, jx, jy, js, jb, jf = {}, {}, {}, {}, {}, {}
	local jlb, jlf                     -- цвета последней записи в журнале
	local jlb0, jlf0                   -- ... и те, с которых журнал начат
	local CSET, CCOPY, CCOLOR = 1/256, 1/64, 1/128   -- цены у карты 3 уровня
	-- Порог, до которого журнал дешевле повторить. Bitblt, не влезший в
	-- кредит тика (у карты 3 уровня - 1.5), стоит машине ровно один тик;
	-- повтор же тратит бюджет, и подобравшись к кредиту вплотную, он и тик
	-- теряет, и на остальной кадр ничего не оставляет. По замерам
	-- (test/gamevm.lua) выигрыш держится до трети кредита, дальше пропадает.
	local LIMIT = 0.5

	function logSet(x, y, s, bgc, fgc)
		jn = jn + 1
		jkind[jn], jx[jn], jy[jn], js[jn], jb[jn], jf[jn] = "s", x, y, s, bgc, fgc
		if bgc ~= jlb then jcost = jcost + CCOLOR jlb = bgc end
		if fgc >= 0 and fgc ~= jlf then jcost = jcost + CCOLOR jlf = fgc end
		jcost = jcost + CSET
	end

	function logCopy(x, y, w, h, dy)
		jn = jn + 1
		jkind[jn], jx[jn], jy[jn], js[jn], jb[jn], jf[jn] = "c", x, y, w, h, dy
		jcost = jcost + CCOPY
	end

	--- Показать кадр: повторить журнал на экране или положить буфер целиком.
	function present()
		if jn == 0 then return end
		g.setActiveBuffer(0)
		if jcost <= LIMIT then
			local pb, pf = jlb0, jlf0
			for i = 1, jn do
				if jkind[i] == "c" then
					g.copy(jx[i], jy[i], js[i], jb[i], 0, jf[i])
				else
					if jb[i] ~= pb then g.setBackground(jb[i]) pb = jb[i] end
					if jf[i] >= 0 and jf[i] ~= pf then g.setForeground(jf[i]) pf = jf[i] end
					g.set(jx[i], jy[i], js[i])
				end
				js[i] = nil
			end
		else
			g.bitblt(0, 1, 1, SW, SH, buf, 1, 1)
			for i = 1, jn do js[i] = nil end
		end
		-- журнал пуст, и цвета карты теперь те же, что у буфера
		jn, jcost = 0, 0
		jlb0, jlf0, jlb, jlf = bgNow, fgNow, bgNow, fgNow
	end
end

local BLOCK = "\226\150\132"   -- нижний полублок
local reps = {[" "] = {}, [BLOCK] = {}}
local function rep(ch, n)
	local t = reps[ch]
	local s = t[n]
	if not s then s = string.rep(ch, n) t[n] = s end
	return s
end

--- Дописать в буфер изменившееся и положить кадр на экран. Соседние
--- ячейки с одинаковой парой цветов уходят одной записью, а записи
--- строки идут сгруппированными по цветам: смена цвета - такой же вызов
--- видеокарты, как и сама запись, и на пёстрых барабанах их было больше.
local runX, runS, runB, runF, order = {}, {}, {}, {}, {}
local function byColor(i, j)
	if runB[i] ~= runB[j] then return runB[i] < runB[j] end
	return runF[i] < runF[j]
end

local function flush()
	if buf then g.setActiveBuffer(buf) end
	for row = 1, SH do
		local c1 = dmin[row]
		if c1 then
			local c2 = dmax[row]
			dmin[row] = nil
			local o1 = (row * 2 - 2) * PW
			local o2 = o1 + PW
			local c0 = (row - 1) * SW
			local x, m = c1, 0
			while x <= c2 do
				local k = c0 + x
				local e = ov[k]
				if e then
					if shown[k] == e then
						x = x + 1
					else
						local parts, n = {e[1]}, 1
						while x + n <= c2 do
							local q = ov[k + n]
							if q and q[2] == e[2] and q[3] == e[3] then
								n = n + 1
								parts[n] = q[1]
							else
								break
							end
						end
						m = m + 1
						runX[m], runS[m], runB[m], runF[m] = x, table.concat(parts), e[3], e[2]
						for i = 0, n - 1 do shown[k + i] = ov[k + i] end
						x = x + n
					end
				else
					local t, b = fb[o1 + x], fb[o2 + x]
					local key = t * 16777216 + b
					if shown[k] == key then
						x = x + 1
					else
						local n = 1
						while x + n <= c2 and not ov[k + n] and fb[o1 + x + n] == t and fb[o2 + x + n] == b do
							n = n + 1
						end
						m = m + 1
						if t == b then
							runX[m], runS[m], runB[m], runF[m] = x, rep(" ", n), t, -1
						else
							runX[m], runS[m], runB[m], runF[m] = x, rep(BLOCK, n), t, b
						end
						for i = 0, n - 1 do shown[k + i] = key end
						x = x + n
					end
				end
			end
			if m > 0 then
				for i = 1, m do order[i] = i end
				for i = m + 1, #order do order[i] = nil end
				if m > 1 then table.sort(order, byColor) end
				for i = 1, m do
					local j = order[i]
					setbg(runB[j])
					if runF[j] >= 0 then setfg(runF[j]) end
					g.set(runX[j], row, runS[j])
					if buf then logSet(runX[j], row, runS[j], runB[j], runF[j]) end
				end
			end
		end
	end
	if buf then present() end
end

-------------------------------------------------------------- цвета

local function split(c) return floor(c / 65536), floor(c / 256) % 256, c % 256 end
local function join(r, gg, b) return floor(r + 0.5) * 65536 + floor(gg + 0.5) * 256 + floor(b + 0.5) end

local function scale(c, f)
	local r, gg, b = split(c)
	return join(r * f, gg * f, b * f)
end

local function mix(a, b, t)
	local r1, g1, b1 = split(a)
	local r2, g2, b2 = split(b)
	return join(r1 + (r2 - r1) * t, g1 + (g2 - g1) * t, b1 + (b2 - b1) * t)
end

--- Таблица, считающая значение при первом обращении: затемнение и
--- смешивание цветов на барабанах идут через неё, по разу на цвет.
local function memo(fn)
	return setmetatable({}, {__index = function(t, c) local v = fn(c) t[c] = v return v end})
end

local IVORY = 0xFFF8E6
local BG, BG_LINE = 0x170B29, 0x24103C
local PANEL = 0x0A0612
local BODY = 0x2E0A1E
local GOLD, GOLD_L, GOLD_M, GOLD_D, GOLD_DD = 0xFFDB00, 0xFFFF80, 0xCC9200, 0x996D00, 0x664900

--------------------------------------------------------------- шрифт 5x7

local FONT = {
	["0"] = {".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."},
	["1"] = {"..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."},
	["2"] = {".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"},
	["3"] = {"#####", "...#.", "..#..", "...#.", "....#", "#...#", ".###."},
	["4"] = {"...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."},
	["5"] = {"#####", "#....", "####.", "....#", "....#", "#...#", ".###."},
	["6"] = {"..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."},
	["7"] = {"#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."},
	["8"] = {".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."},
	["9"] = {".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."},
	["$"] = {"..#..", ".####", "#.#..", ".###.", "..#.#", "####.", "..#.."},
	["x"] = {".....", ".....", "#...#", ".#.#.", "..#..", ".#.#.", "#...#"},
	["+"] = {".....", "..#..", "..#..", "#####", "..#..", "..#..", "....."},
	["!"] = {"..#..", "..#..", "..#..", "..#..", "..#..", ".....", "..#.."},
	[" "] = {".....", ".....", ".....", ".....", ".....", ".....", "....."},
	O = {".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."},
	P = {"####.", "#...#", "#...#", "####.", "#....", "#....", "#...."},
	E = {"#####", "#....", "#....", "####.", "#....", "#....", "#####"},
	N = {"#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#", "#...#"},
	C = {".###.", "#...#", "#....", "#....", "#....", "#...#", ".###."},
	A = {".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"},
	S = {".####", "#....", "#....", ".###.", "....#", "....#", "####."},
	I = {".###.", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."},
}

--- Надпись шрифтом 5x7 с увеличением s; col - цвет или функция (x, y).
local function bigText(str, x, y, s, col)
	for ch in str:gmatch(UTF) do
		local gl = FONT[ch] or FONT[" "]
		for gy = 1, 7 do
			local r = gl[gy]
			for gx = 1, 5 do
				if r:sub(gx, gx) == "#" then
					for sy = 0, s - 1 do
						for sx = 0, s - 1 do
							local X, Y = x + (gx - 1) * s + sx, y + (gy - 1) * s + sy
							px(X, Y, type(col) == "function" and col(X, Y) or col)
						end
					end
				end
			end
		end
		x = x + 6 * s
	end
end

local function bigWidth(str, s) return ulen(str) * 6 * s - s end

------------------------------------------------------------- символы

-- Символы не нарисованы по точкам, а построены из фигур: шары с
-- освещением, палки, многоугольники. Так одна и та же вишня выходит и
-- крупной на барабане, и мелкой в таблице выплат.

local AW, AH = 20, 20       -- символ на барабане
local ART, MINI = {}, {}
do
local LX, LY, LZ = -0.48, -0.58, 0.66
do
	local n = sqrt(LX * LX + LY * LY + LZ * LZ)
	LX, LY, LZ = LX / n, LY / n, LZ / n
end

local R_RED = {0x330000, 0x660000, 0x990000, 0xCC0000, 0xFF0000, 0xFF4940, 0xFF9280}
local R_GRN = {0x002400, 0x004900, 0x006D00, 0x009200, 0x33B600, 0x66DB40}
local R_LIME = {0x334900, 0x336D00, 0x669200, 0x99B600, 0xCCDB00, 0xCCFF40}
local R_ORG = {0x662400, 0x994900, 0xCC6D00, 0xFF9200, 0xFFB640, 0xFFDB80}
local R_CYN = {0x004980, 0x006DBF, 0x0092FF, 0x33B6FF, 0x66DBFF, 0xCCFFFF}
local R_WOOD = {0x332400, 0x662400, 0x994900, 0xCC6D40}
local R_IVO = {0x615E57, 0x8C8880, 0xB8B2A6, 0xE0DACA, 0xFFF8E6}
local R_MEAT = {0x330000, 0x662400, 0x992400, 0xCC4900, 0xCC6D00, 0xFF9240}

local function canvas(w, h)
	local c = {w = w, h = h}
	for i = 1, w * h do c[i] = false end
	return c
end

local function paint(c, fn)
	local w, h = c.w, c.h
	for y = 1, h do
		for x = 1, w do
			local col = fn((x - 0.5) / w, (y - 0.5) / h, x, y)
			if col then c[(y - 1) * w + x] = col end
		end
	end
end

local function pick(r, t)
	if t < 0 then t = 0 elseif t > 1 then t = 1 end
	return r[floor(t * (#r - 1) + 0.5) + 1]
end

--- Яркость точки шара: (dx, dy) внутри единичного круга.
local function lit(dx, dy)
	local d = dx * dx + dy * dy
	if d > 1 then d = 1 end
	return dx * LX + dy * LY + sqrt(1 - d) * LZ
end

local function ball(c, cx, cy, rx, ry, r, spec)
	paint(c, function(u, v)
		local dx, dy = (u - cx) / rx, (v - cy) / ry
		if dx * dx + dy * dy <= 1 then
			local l = lit(dx, dy)
			if spec and l > 0.93 then return spec end
			return pick(r, (l + 0.25) / 1.1)
		end
	end)
end

local function segDist(u, v, x1, y1, x2, y2)
	local dx, dy = x2 - x1, y2 - y1
	local t = ((u - x1) * dx + (v - y1) * dy) / (dx * dx + dy * dy)
	if t < 0 then t = 0 elseif t > 1 then t = 1 end
	local ex, ey = u - (x1 + t * dx), v - (y1 + t * dy)
	return sqrt(ex * ex + ey * ey)
end

local function stick(c, x1, y1, x2, y2, wd, r)
	wd = math.max(wd, 0.6 / c.w)
	paint(c, function(u, v)
		local d = segDist(u, v, x1, y1, x2, y2)
		if d <= wd then return pick(r, 1 - d / wd * 0.8) end
	end)
end

local function inside(u, v, pts)
	local inn, j = false, #pts
	for i = 1, #pts do
		local xi, yi, xj, yj = pts[i][1], pts[i][2], pts[j][1], pts[j][2]
		if (yi > v) ~= (yj > v) and u < (xj - xi) * (v - yi) / (yj - yi) + xi then inn = not inn end
		j = i
	end
	return inn
end

local function leaf(c, cx, cy, rx, ry)
	paint(c, function(u, v)
		local dx, dy = (u - cx) / rx, (v - cy) / ry
		if dx * dx + dy * dy <= 1 then return pick(R_GRN, 0.55 - dy * 0.4 - dx * 0.1) end
	end)
end

--- Обвести фигуру по контуру снаружи (на крупных символах).
local function outline(c, col)
	local w, h, add = c.w, c.h, {}
	for y = 1, h do
		for x = 1, w do
			local i = (y - 1) * w + x
			if not c[i] and ((x > 1 and c[i - 1]) or (x < w and c[i + 1])
				or (y > 1 and c[i - w]) or (y < h and c[i + w])) then
				add[#add + 1] = i
			end
		end
	end
	for _, i in ipairs(add) do c[i] = col end
end

local P7 = {{.12, .10}, {.90, .10}, {.90, .28}, {.58, .92}, {.30, .92}, {.62, .30}, {.12, .30}}
local CROWN = {{.28, .16}, {.72, .16}, {.92, .40}, {.08, .40}}
local PAV = {{.08, .40}, {.92, .40}, {.50, .92}}
local WEDGE_TOP = {{.06, .50}, {.66, .18}, {.94, .36}}
local WEDGE_FRONT = {{.06, .50}, {.94, .36}, {.94, .80}, {.06, .86}}

local DRAW = {}

function DRAW.cherry(c)
	stick(c, .30, .62, .60, .14, .045, R_GRN)
	stick(c, .70, .66, .60, .14, .045, R_GRN)
	leaf(c, .76, .17, .17, .08)
	ball(c, .30, .70, .23, .23, R_RED, 0xFFDBBF)
	ball(c, .70, .72, .21, .21, R_RED, 0xFFDBBF)
	return 0x330000
end

function DRAW.seven(c)
	local e = 1.2 / c.w
	paint(c, function(u, v)
		if inside(u, v, P7) then
			if not inside(u - e, v - e, P7) then return 0xFF9280 end
			if not inside(u + e, v + e, P7) then return 0x990000 end
			return pick(R_RED, 0.95 - v * 0.5)
		end
	end)
	return GOLD, GOLD_DD
end

function DRAW.diamond(c)
	local sp = 1 / c.w
	paint(c, function(u, v)
		if inside(u, v, CROWN) then
			if abs(u - .30) < sp * 1.2 and abs(v - .24) < sp * 1.2 then return 0xFFFFFF end
			if v < .27 and u > .36 and u < .64 then return 0xCCFFFF end
			if u < .38 then return 0x66DBFF elseif u > .62 then return 0x0092FF end
			return 0x33B6FF
		elseif inside(u, v, PAV) then
			local gu = .5 + (u - .5) * .52 / (.92 - v + 0.001)
			local k = floor((gu - .08) / .21)
			return ({0x33B6FF, 0x006DBF, 0x0092FF, 0x004980})[math.max(0, math.min(3, k)) + 1]
		end
	end)
	return 0x002440
end

function DRAW.orange(c)
	paint(c, function(u, v, x, y)
		local dx, dy = (u - .5) / .39, (v - .56) / .37
		if dx * dx + dy * dy <= 1 then
			local l = lit(dx, dy)
			if l > 0.93 then return 0xFFFFBF end
			local t = (l + 0.25) / 1.1
			if (x * 7 + y * 13) % 11 == 0 then t = t - 0.2 end
			return pick(R_ORG, t)
		end
	end)
	stick(c, .50, .22, .54, .10, .03, R_WOOD)
	leaf(c, .66, .14, .15, .07)
	return 0x332400
end

function DRAW.pickaxe(c)
	stick(c, .16, .90, .66, .38, .06, R_WOOD)
	-- головка: полумесяц вокруг точки на продолжении рукояти, острый к концам
	local ox, oy, rr = .30, .74, .60
	paint(c, function(u, v)
		local dx, dy = u - ox, v - oy
		local d = sqrt(dx * dx + dy * dy)
		local da = atan2(dy, dx) + 0.80
		if abs(da) < 0.78 then
			local th = .085 * (1 - (da / .78) ^ 2) + .6 / c.w
			if abs(d - rr) < th then return pick(R_CYN, 0.35 + (rr + th - d) / (2 * th) * 0.65) end
		end
	end)
	return 0x002440
end

function DRAW.cheese(c)
	paint(c, function(u, v)
		if inside(u, v, WEDGE_TOP) then
			local dx, dy = (u - .56) / .05, (v - .32) / .04
			if dx * dx + dy * dy <= 1 then return 0xFFB600 end
			return v < .30 and 0xFFFF80 or 0xFFDB40
		elseif inside(u, v, WEDGE_FRONT) then
			for _, h in ipairs({{.28, .66, .07}, {.62, .56, .06}, {.50, .75, .05}, {.82, .66, .05}}) do
				local dx, dy = (u - h[1]) / h[3], (v - h[2]) / h[3]
				if dx * dx + dy * dy <= 1 then return dy < 0 and GOLD_D or GOLD_M end
			end
			return u > .8 and 0xFF9200 or 0xFFB600
		end
	end)
	return GOLD_DD
end

function DRAW.pokeball(c)
	paint(c, function(u, v)
		local dx, dy = (u - .5) / .42, (v - .52) / .42
		if dx * dx + dy * dy <= 1 then
			local l = lit(dx, dy)
			local cd = sqrt((u - .5) ^ 2 + (v - .52) ^ 2)
			if cd < .12 then
				if cd < .07 then return pick(R_IVO, (l + .3) / 1.1) end
				return 0x000000
			end
			if abs(v - .52) < .045 then return 0x000000 end
			if l > .93 then return 0xFFFFFF end
			if v < .52 then return pick(R_RED, (l + .25) / 1.1) end
			return pick(R_IVO, (l + .3) / 1.1)
		end
	end)
	return 0x000000
end

function DRAW.meat(c)
	stick(c, .50, .50, .78, .20, .06, R_IVO)
	ball(c, .75, .12, .08, .08, R_IVO)
	ball(c, .88, .24, .08, .08, R_IVO)
	local cx, cy = .38, .62
	paint(c, function(u, v)
		local a = ((u - cx) - (v - cy)) / 1.4142 / .36
		local b = ((u - cx) + (v - cy)) / 1.4142 / .25
		if a * a + b * b <= 1 then
			local l = lit((a + b) / 1.4142, (b - a) / 1.4142)
			if l > .93 then return 0xFFB680 end
			return pick(R_MEAT, (l + .25) / 1.1)
		end
	end)
	return 0x330000
end

function DRAW.apple(c)
	paint(c, function(u, v)
		local dx, dy = (u - .5) / .40, (v - .58) / .36
		if dx * dx + dy * dy <= 1 then
			local nx, ny = (u - .5) / .10, (v - .22) / .08
			if nx * nx + ny * ny <= 1 then return nil end
			local l = lit(dx, dy)
			if l > .93 then return 0xFFFFBF end
			return pick(R_LIME, (l + .25) / 1.1)
		end
	end)
	stick(c, .50, .28, .56, .08, .035, R_WOOD)
	leaf(c, .69, .13, .14, .06)
	return 0x002400
end

for i, name in ipairs(SYMBOLS) do
	local c = canvas(AW, AH)
	local o1, o2 = DRAW[name](c)
	outline(c, o1)
	if o2 then outline(c, o2) end
	ART[i] = c
	-- мелкая иконка - уменьшенная крупная: в каждой клетке берётся самый
	-- частый цвет, если фигура занимает хотя бы половину клетки
	local m, MS = canvas(8, 8), AW / 8
	for my = 0, 7 do
		for mx = 0, 7 do
			local cnt, total, best, bn = {}, 0, false, 0
			for sy = floor(my * MS), math.ceil((my + 1) * MS) - 1 do
				for sx = floor(mx * MS), math.ceil((mx + 1) * MS) - 1 do
					total = total + 1
					local col = c[sy * AW + sx + 1]
					if col then
						cnt[col] = (cnt[col] or 0) + 1
						if cnt[col] > bn then best, bn = col, cnt[col] end
					end
				end
			end
			local opaque = 0
			for _, k in pairs(cnt) do opaque = opaque + k end
			if opaque * 2 >= total then m[my * 8 + mx + 1] = best end
		end
	end
	MINI[i] = m
end
end

--- Картинка с дырками в точку (x, y) раскладки; дырки - цвет bgc или то, что лежит.
local function blit(a, x, y, bgc)
	local w = a.w
	for yy = 1, a.h do
		for xx = 1, w do
			local c = a[(yy - 1) * w + xx] or bgc
			if c then px(x + xx - 1, y + yy - 1, c) end
		end
	end
	touch(x, y, w, a.h)
end

--------------------------------------------------------------- раскладка

-- всё в пикселях раскладки 146x84; строка текста r - это пиксели 2r-1 и 2r
local MX, MY, MW, MH = 31, 20, 86, 56        -- корпус автомата
local LCD_Y = 23                             -- табло: 23..34
local REEL_Y, RW, WH, P = 37, 24, 36, 22     -- барабаны: окно 24x36, шаг символа 22
local REEL_X = {35, 62, 89}
local LSTRIP = #SYMBOLS * P
local BASE = P / 2 - WH / 2
local BTN_Y = 77

local function bgAt(x, y)
	if (x + y) % 12 == 0 or (x - y) % 12 == 0 then return BG_LINE end
	return BG
end

local function paintBg(x, y, w, h)
	for yy = y, y + h - 1 do
		for xx = x, x + w - 1 do px(xx, yy, bgAt(xx, yy)) end
	end
	touch(x, y, w, h)
end

local function frameBox(x, y, w, h, colors, fill)
	for i, c in ipairs(colors) do
		local k = i - 1
		rect(x + k, y + k, w - 2 * k, 1, c)
		rect(x + k, y + h - 1 - k, w - 2 * k, 1, c)
		rect(x + k, y + k, 1, h - 2 * k, c)
		rect(x + w - 1 - k, y + k, 1, h - 2 * k, c)
	end
	if fill then
		local n = #colors
		rect(x + n, y + n, w - 2 * n, h - 2 * n, fill)
	end
end

----------------------------------------------------------------- заголовок

local TITLE = "OPENCASINO"
local TS = 2
local TW, TH = bigWidth(TITLE, TS) + 4, 7 * TS + 3
local TX, TY = floor((146 - TW) / 2) + 1, 3
local tmask = {}
do
	local x = 2
	for ch in TITLE:gmatch(UTF) do
		local gl = FONT[ch]
		for gy = 1, 7 do
			for gx = 1, 5 do
				if gl[gy]:sub(gx, gx) == "#" then
					for sy = 0, TS - 1 do
						for sx = 0, TS - 1 do
							tmask[(1 + (gy - 1) * TS + sy) * TW + x + (gx - 1) * TS + sx] = true
						end
					end
				end
			end
		end
		x = x + 6 * TS
	end
end
local function tm(x, y) return x >= 1 and y >= 0 and x <= TW and y < TH and tmask[y * TW + x] end
local TGRAD = {0xFFFFBF, 0xFFFF80, 0xFFFF80, 0xFFDB40, 0xFFDB00, 0xFFDB00, 0xFFB600,
	0xFFB600, 0xFF9200, 0xFF9200, 0xCC6D00, 0xCC6D00, 0x994900, 0x994900}

local function drawTitle(glint)
	for y = 0, TH - 1 do
		for x = 1, TW do
			local c
			if tm(x, y) then
				c = TGRAD[y] or 0x994900
				if not tm(x, y - 1) then c = 0xFFFFFF end
				if glint and abs(x + y * 0.6 - glint) < 2.5 then c = 0xFFFFFF end
			elseif tm(x - 1, y) or tm(x + 1, y) or tm(x, y - 1) or tm(x, y + 1)
				or tm(x - 1, y - 1) or tm(x + 1, y + 1) or tm(x - 1, y + 1) or tm(x + 1, y - 1) then
				c = 0x330000
			elseif tm(x - 2, y - 2) or tm(x - 3, y - 3) then
				c = 0x660000
			else
				c = bgAt(TX + x - 1, TY + y)
			end
			px(TX + x - 1, TY + y, c)
		end
	end
	touch(TX, TY, TW, TH)
end

------------------------------------------------------------------ лампочки

local bulbs = {}
for x = 4, 142, 6 do bulbs[#bulbs + 1] = {x, 1} end
for y = 7, 77, 6 do bulbs[#bulbs + 1] = {145, y} end
for x = 142, 4, -6 do bulbs[#bulbs + 1] = {x, 83} end
for y = 77, 7, -6 do bulbs[#bulbs + 1] = {1, y} end

local BULB = {
	on = {0xFFFFFF, GOLD, GOLD, GOLD_M},
	off = {GOLD_D, GOLD_DD, GOLD_DD, 0x332400},
	red = {0xFF9280, 0xFF0000, 0xFF0000, 0xCC0000},
}

local function drawBulb(b, look)
	local x, y = b[1], b[2]
	px(x, y, look[1]) px(x + 1, y, look[2])
	px(x, y + 1, look[3]) px(x + 1, y + 1, look[4])
	touch(x, y, 2, 2)
end

------------------------------------------------------------------ барабаны

local SHADE = {0.22, 0.38, 0.55, 0.72, 0.88}   -- края окна темнее: барабан круглый
local shadeOf, shadeTab = {}, {}
for yy = 0, WH - 1 do
	local e = math.min(yy, WH - 1 - yy) + 1
	shadeOf[yy] = SHADE[e] and e or false
end
for k, f in ipairs(SHADE) do shadeTab[k] = memo(function(c) return scale(c, f) end) end
local blurred = memo(function(c) return mix(IVORY, c, 0.45) end)

local reels = {}
for i = 1, 3 do reels[i] = {x = REEL_X[i], pos = 0, v = 0, q = {}, qi = 1, hl = false} end

--- Точка ленты барабана: s - координата вдоль ленты, xx - столбец окна.
local function stripAt(s, xx)
	s = s % LSTRIP
	local si = floor(s / P)
	local ay = s - si * P - (P - AH) / 2
	local ax = xx - (RW - AW) / 2
	if ay >= 0 and ay < AH and ax >= 1 and ax <= AW then
		local a = ART[si + 1]
		return a[ay * AW + ax]
	end
	return false
end

local function drawReel(r)
	local x0, v = r.x, r.v
	local trail = v >= 8 and floor(v / 2) or 0
	for yy = 0, WH - 1 do
		local s = yy + BASE - r.pos
		local sh = shadeOf[yy]
		local st = sh and shadeTab[sh]
		for xx = 1, RW do
			local c = stripAt(s, xx)
			if not c then
				c = IVORY
				-- смаз на ходу: то, что только что проехало, оставляет след
				for d = 2, trail, 2 do
					local t = stripAt(s + d, xx)
					if t then c = blurred[t] break end
				end
			end
			if st then c = st[c] end
			px(x0 + xx - 1, REEL_Y + yy, c)
		end
	end
	if r.hl then
		for yy = 7, 28 do
			px(x0, REEL_Y + yy, r.hl) px(x0 + RW - 1, REEL_Y + yy, r.hl)
		end
		for xx = 0, RW - 1 do
			px(x0 + xx, REEL_Y + 7, r.hl) px(x0 + xx, REEL_Y + 28, r.hl)
		end
	end
	touch(x0, REEL_Y, RW, WH)
end

-- Строки окна без затемнения: при ходе ленты их содержимое просто
-- съезжает, и вместо перерисовки его двигает один bitblt внутри буфера.
-- Дальше обычная сверка дописывает лишь въехавшие строки.
local BAND1, BAND2 = floor((REEL_Y + 6) / 2) + 1, floor((REEL_Y + WH - 6) / 2)

local function shiftReel(r, d)
	local k = d / 2
	local n = BAND2 - BAND1 + 1 - abs(k)
	if k == 0 or n <= 0 or not buf then return end
	local col, a = r.x + OX, BAND1 + OR
	g.setActiveBuffer(buf)
	-- на экране этому сдвигу отвечает обычный copy - без него повтор
	-- журнала показал бы ленту несдвинутой
	logCopy(col, k > 0 and a or (a - k), RW, n, k)
	if k > 0 then
		g.bitblt(buf, col, a + k, RW, n, buf, col, a)
		for row = a + n - 1, a, -1 do
			local s0, d0 = (row - 1) * SW + col - 1, (row + k - 1) * SW + col - 1
			for x = 1, RW do shown[d0 + x] = shown[s0 + x] end
		end
		for row = a, a + k - 1 do
			local o = (row - 1) * SW + col - 1
			for x = 1, RW do shown[o + x] = -1 end
		end
	else
		k = -k
		g.bitblt(buf, col, a, RW, n, buf, col, a + k)
		for row = a, a + n - 1 do
			local s0, d0 = (row + k - 1) * SW + col - 1, (row - 1) * SW + col - 1
			for x = 1, RW do shown[d0 + x] = shown[s0 + x] end
		end
		for row = a + n, a + n + k - 1 do
			local o = (row - 1) * SW + col - 1
			for x = 1, RW do shown[o + x] = -1 end
		end
	end
end

local function posFor(sym) return ((1 - sym) * P) % LSTRIP end

--- Расписать ход барабана до символа sym: замах, разгон, ход, торможение
--- и отскок. Все шаги чётные, так что конец ровно на символе.
local VMAX = 12
local function plan(r, sym, minDist, delay, slow)
	local up = {-2, -2, -2, 0}
	local acc = {2, 4, 6, 8, 10}
	local dec = slow and {10, 8, 8, 6, 6, 6, 4, 4, 4, 4, 2, 2, 2, 2, 2} or {10, 8, 6, 4, 2}
	local bounce = {4, -2, -2}
	local fixed = 0
	for _, t in ipairs({up, acc, dec, bounce}) do for _, d in ipairs(t) do fixed = fixed + d end end
	local dist = (posFor(sym) - r.pos) % LSTRIP
	while dist < minDist + fixed do dist = dist + LSTRIP end
	local rest = dist - fixed
	local n = floor(rest / VMAX)
	local rem = rest - n * VMAX
	local q = {}
	for _ = 1, delay do q[#q + 1] = 0 end
	for _, d in ipairs(up) do q[#q + 1] = d end
	for _, d in ipairs(acc) do q[#q + 1] = d end
	if rem > 0 then q[#q + 1] = rem end
	for _ = 1, n do q[#q + 1] = VMAX end
	for _, d in ipairs(dec) do q[#q + 1] = d end
	for _, d in ipairs(bounce) do q[#q + 1] = d end
	r.q, r.qi = q, 1
end

------------------------------------------------------------------ табло

local LCD_BET = {36, 58}      -- столбцы цифр ставки
local LCD_WIN = {90, 112}     -- и выигрыша
local LCD_MSG = 62            -- надпись посередине, 25 символов

local function lcdNumber(str, area, col, ghost)
	local x1, x2 = area[1], area[2]
	rect(x1, 26, x2 - x1 + 1, 7, 0x000000)
	local slots = floor((x2 - x1 + 2) / 6)
	for i = 0, slots - 1 do bigText("8", x1 + i * 6, 26, 1, ghost) end
	if ulen(str) <= slots then
		bigText(str, x2 - bigWidth(str, 1) + 1, 26, 1, col)
	else
		line(x1, 14, x2 - x1 + 1, str, col, 0x000000, "r")
	end
end

------------------------------------------------------------------ кнопки

local SCHEME = {
	bet = {hl = 0x6649BF, face = 0x332480, sh = 0x000040, text = 0xFFFFFF},
	spin = {hl = 0xFF4940, face = 0xCC0000, sh = 0x660000, text = GOLD_L},
	login = {hl = 0x33B640, face = 0x006D00, sh = 0x002400, text = 0xFFFFFF},
	exit = {hl = 0xFF4940, face = 0x990000, sh = 0x330000, text = 0xFFFFFF},
	off = {hl = 0x787878, face = 0x3C3C3C, sh = 0x0E0719, text = 0xB4B4B4},
}

local buttons = {
	{id = "login", x = 3, w = 27, label = "ВОЙТИ", look = "login"},
	{id = "bet", x = 31, w = 9, label = "-10", d = -10, look = "bet"},
	{id = "bet", x = 42, w = 8, label = "-5", d = -5, look = "bet"},
	{id = "bet", x = 52, w = 8, label = "-1", d = -1, look = "bet"},
	{id = "spin", x = 62, w = 24, label = "КРУТИТЬ", look = "spin"},
	{id = "bet", x = 88, w = 8, label = "+1", d = 1, look = "bet"},
	{id = "bet", x = 98, w = 8, label = "+5", d = 5, look = "bet"},
	{id = "bet", x = 108, w = 9, label = "+10", d = 10, look = "bet"},
}

local function drawButton(b)
	local s = SCHEME[b.off and "off" or b.look]
	local hl, sh = s.hl, s.sh
	if b.pressed then hl, sh = sh, hl end
	rect(b.x, BTN_Y, b.w, 6, s.face)
	rect(b.x, BTN_Y, b.w, 1, hl)
	rect(b.x, BTN_Y, 1, 6, hl)
	rect(b.x, BTN_Y + 5, b.w, 1, sh)
	rect(b.x + b.w - 1, BTN_Y, 1, 6, sh)
	px(b.x, BTN_Y, bgAt(b.x, BTN_Y))
	px(b.x + b.w - 1, BTN_Y + 5, bgAt(b.x + b.w - 1, BTN_Y + 5))
	line(b.x + 1, 40, b.w - 2, b.label, s.text, s.face, "c")
end

------------------------------------------------------------------ монеты

local coins, under = {}, {}
local COIN_FACE = {{GOLD_L, GOLD, GOLD_M}, {GOLD, GOLD_M, GOLD_D}}
local COIN_EDGE = {{GOLD}, {GOLD_D}}

local function restoreCoins()
	for i = #under, 1, -1 do
		local u = under[i]
		px(u[1], u[2], u[3])
		touch(u[1], u[2], 1, 1)
		under[i] = nil
	end
end

local function stampCoins()
	for _, c in ipairs(coins) do
		local art = (floor(c.t / 3) % 2 == 0) and COIN_FACE or COIN_EDGE
		local x0, y0 = floor(c.x) - floor(#art[1] / 2), floor(c.y)
		for yy = 1, 2 do
			for xx = 1, #art[1] do
				local X, Y = x0 + xx - 1, y0 + yy - 1
				local old = getpx(X, Y)
				if old then
					under[#under + 1] = {X, Y, old}
					px(X, Y, art[yy][xx])
					touch(X, Y, 1, 1)
				end
			end
		end
	end
end

----------------------------------------------------------------- состояние

local st = {
	login = nil, stavka = STAVKA, balance = "0.00",
	spinning = false, result = nil, lastTouch = 0, spamUntil = 0,
	history = {}, msg = {}, prize = 0, winShown = 0,
	mode = "idle", modeUntil = 0, rain = 0,
	glint = nil, nextGlint = 3, blinkUntil = 0,
	redstoneOff = nil, beeps = {},
}

-- Статистика лежит рядом с самой игрой, а не в текущем каталоге: ярлык
-- /bin/casino запускается откуда угодно, и иначе счётчики расползались бы
-- по всему диску. Старый файл в текущем каталоге, если он есть, остаётся
-- в деле - чтобы накопленное не пропало.
local statPath
do
	local here = "/home/games"
	for i = 1, 4 do
		local d = debug.getinfo(i, "S")
		local p = d and d.source and d.source:match("^[=@]?(.*)/[^/]*%.lua$")
		if p and p ~= "" then here = p break end
	end
	local old = shell.getWorkingDirectory() .. "/moneyCasino"
	statPath = (not fs.exists(here .. "/moneyCasino") and fs.exists(old))
		and old or (here .. "/moneyCasino")
end
local money = {0, 0}   -- всего потрачено, всего выиграно

local function loadMoney()
	if fs.exists(statPath) then
		local text = sky.fileRead(statPath)
		local ok, obj = pcall(serial.unserialize, text or "")
		if ok and type(obj) == "table" then
			money = {tonumber(obj[1]) or 0, tonumber(obj[2]) or 0}
			return
		end
	end
	money = {0, 0}
	sky.fileWrite(statPath, "{0,0}")
end

local function saveMoney()
	sky.fileWrite(statPath, "{" .. money[1] .. "," .. money[2] .. "}")
end

local function beep(freq, dur)
	pcall(computer.beep, freq, dur or 0.05)
end

------------------------------------------------------------------ панели

local LP, RP = 3, 118          -- левая и правая панели: 27 столбцов
local PANEL_W = 25             -- ширина текста в панели

local function leftLines()
	local L = {}
	local W, GR, GD, GN, RD = 0xFFFFFF, 0xB4B4B4, GOLD, 0x33DB40, 0xFF4940
	if st.login then
		L[11] = {"ДОБРО ПОЖАЛОВАТЬ", GD}
		L[13] = {st.login, W}
		L[15] = {"Баланс:", GR}
		L[16] = {"[ " .. st.balance .. " ]", GN}
		L[19] = {"Последние игры:", GR}
		for i, h in ipairs(st.history) do L[20 + i] = {h[1], h[2]} end
		if not st.spinning then
			local left = math.max(0, math.ceil(AUTOEXIT - (computer.uptime() - st.lastTouch)))
			L[35] = {"Автовыход через: " .. left, left <= 5 and RD or GR}
		end
	else
		L[11] = {"ОБЩАЯ ИНФА", GD}
		if DEMO then
			L[13] = {"Игра на фишки:", W}
			L[14] = {"у каждого 1000,", W}
			L[15] = {"деньги не настоящие.", W}
			L[29] = {"Q - выход", GR}
		else
			L[13] = {"Вы играете на свой", W}
			L[14] = {"страх и риск.", W}
			L[15] = {"Эмы не возвращаются.", W}
		end
		L[18] = {"Всего потрачено:", GR}
		L[19] = {money[1] .. " эм.", GD}
		L[21] = {"Всего выиграно:", GR}
		L[22] = {money[2] .. " эм.", GN}
		L[25] = {"Ставка: 1-" .. MAX_STAVKA .. "$", GR}
		L[26] = {"Выигрыш = ставка x бонус", GR}
		L[33] = {"Нажмите ВОЙТИ,", GR}
		L[34] = {"чтобы начать игру", GR}
	end
	return L
end

local function drawLeft()
	local L = leftLines()
	for row = 11, 36 do
		local l = L[row]
		line(LP + 1, row, PANEL_W, l and l[1] or "", l and l[2] or 0xFFFFFF, PANEL, "c")
	end
end

local PAYORDER = {2, 3, 9, 8, 4, 6, 1, 5, 7}   -- по убыванию выплаты

local function drawRight()
	line(RP + 1, 11, PANEL_W, "ВЫПЛАТЫ", GOLD, PANEL, "c")
	line(RP + 1, 12, PANEL_W, "три в ряд:", 0xB4B4B4, PANEL, "c")
	for k, sym in ipairs(PAYORDER) do
		local col = (k - 1) % 2
		local rowk = floor((k - 1) / 2)
		local ix = RP + 2 + col * 13
		blit(MINI[sym], ix, 25 + rowk * 8, PANEL)
		line(ix + 9, 15 + rowk * 4, 3, tostring(BONUS[sym]), sym == 2 and GOLD or 0xFFFFFF, PANEL, "l")
	end
	line(RP + 1, 34, PANEL_W, "два рядом        x2", 0xFFFFFF, PANEL, "c")
	line(RP + 1, 35, PANEL_W, "два по краям     x1", 0xFFFFFF, PANEL, "c")
end

local function setMsg(a, b, col)
	st.msg = {a or "", b or "", col or GOLD}
end

local function drawMsg()
	local m = st.msg
	line(LCD_MSG, 13, 25, "", GOLD, 0x000000)
	line(LCD_MSG, 14, 25, m[1] or "", m[3] or GOLD, 0x000000, "c")
	line(LCD_MSG, 15, 25, m[2] or "", 0xB4B4B4, 0x000000, "c")
	line(LCD_MSG, 16, 25, "", GOLD, 0x000000)
end

--- Крупный множитель посреди табло на джекпоте - вместо надписи.
local function drawJackpot(text, on)
	for r = 13, 16 do
		for x = LCD_MSG, LCD_MSG + 24 do ov[(r + OR - 1) * SW + x + OX] = nil end
	end
	rect(LCD_MSG, 25, 25, 8, 0x000000)
	if on then
		local w = bigWidth(text, 1)
		bigText(text, LCD_MSG + floor((25 - w) / 2), 26, 1, function(x, y) return y < 29 and GOLD_L or GOLD end)
	end
end

local function drawBet()
	lcdNumber(st.stavka .. "$", LCD_BET, 0xFFB600, 0x332400)
end

local function drawWin()
	local v = st.winShown
	lcdNumber(tostring(v), LCD_WIN, v > 0 and 0x33DB40 or 0x006D00, 0x002400)
end

local function drawStatic()
	paintBg(1, 1, 146, 84)
	drawTitle(nil)
	-- панели
	frameBox(LP, 20, 27, 54, {GOLD_D}, PANEL)
	frameBox(RP, 20, 27, 54, {GOLD_D}, PANEL)
	-- корпус: рамка в три золотых полосы, внутри бордовый
	frameBox(MX, MY, MW, MH, {GOLD_DD, GOLD, GOLD_M}, BODY)
	rect(MX + 3, LCD_Y, MW - 6, 12, 0x000000)
	rect(MX + 3, 35, MW - 6, 1, GOLD_M)
	rect(MX + 3, 36, MW - 6, 1, GOLD_DD)
	-- промежутки между барабанами
	for _, gx in ipairs({59, 86}) do
		rect(gx, REEL_Y, 1, WH, 0x4A1030)
		rect(gx + 1, REEL_Y, 1, WH, GOLD_D)
		rect(gx + 2, REEL_Y, 1, WH, 0x4A1030)
	end
	-- стрелки линии выигрыша
	local cy = REEL_Y + floor(WH / 2) - 1
	for i, dx in ipairs({0, 1, 2}) do
		local h = 4 - i
		rect(MX + dx, cy - h + 1, 1, 2 * h, 0xFF0000)
		rect(MX + MW - 1 - dx, cy - h + 1, 1, 2 * h, 0xFF0000)
	end
	put(LCD_BET[1], 12, "СТАВКА", GOLD_M, 0x000000)
	put(LCD_WIN[2] - 6, 12, "ВЫИГРЫШ", GOLD_M, 0x000000)
	line(RP, 41, 27, "OpenCasino 2 · SkyDrive_", 0x3A1A5E, BG, "c")
	drawRight()
end

------------------------------------------------------------------ логика

local function balanceOf(nick)
	local ok, b = pcall(sky.money, nick)
	return ok and b or "?"
end

local function refreshButtons()
	for _, b in ipairs(buttons) do
		if b.id == "login" then
			b.label, b.look = st.login and "ВЫХОД" or "ВОЙТИ", st.login and "exit" or "login"
			b.off = st.spinning
		else
			b.off = not st.login or st.spinning
		end
		drawButton(b)
	end
end

local function pushHistory(text, col)
	table.insert(st.history, 1, {text, col})
	while #st.history > 10 do table.remove(st.history) end
end

local function Login(nick)
	pcall(computer.addUser, nick)
	st.login = nick
	st.stavka = STAVKA
	st.balance = balanceOf(nick)
	st.history = {}
	st.lastTouch = computer.uptime()
	st.winShown = 0
	setMsg("Удачи, " .. nick .. "!", "жмите КРУТИТЬ")
	beep(TONE, 0.05)
	drawBet()
	drawWin()
	refreshButtons()
end

local function Exit()
	st.login = nil
	st.stavka = STAVKA
	local users = {computer.users()}
	for i = 1, #users do pcall(computer.removeUser, users[i]) end
	st.spamUntil = computer.uptime() + SPAM
	st.winShown = 0
	for _, r in ipairs(reels) do r.hl = false r.dirty = true end
	setMsg("ДОБРО ПОЖАЛОВАТЬ", "нажмите ВОЙТИ")
	loadMoney()
	drawBet()
	drawWin()
	refreshButtons()
end

local function Say(sym, nick, prize)
	if DEMO then return end   -- фишки в чат не объявляем: деньги не настоящие
	pcall(function()
		component.chat_box.say(CHAT_NAME .. "§5" .. nick .. " §aВыбил " .. NAMES[sym]
			.. " в казино, выиграв " .. (sym == 2 and "§6" or "§5") .. prize .. " эм.")
	end)
end

local function Start(nick)
	if not sky.checkMoney(nick, st.stavka) then
		setMsg("Недостаточно средств", "на счету " .. balanceOf(nick), 0xFF4940)
		beep(200, 0.1)
		return
	end
	local bet = st.stavka
	money[1] = money[1] + bet
	saveMoney()

	local w = {math.random(1, #SYMBOLS), math.random(1, #SYMBOLS), math.random(1, #SYMBOLS)}
	local bonus = Wins(w[1], w[2], w[3])
	local prize = bet * bonus
	-- деньги отдаются сразу: если машину выключат посреди прокрутки,
	-- выигрыш игрока уже у него
	if prize > 0 then
		sky.com("money give " .. nick .. " " .. prize)
		pcall(function() component.opencb.addWinningToStats(nick, prize) end)
		money[2] = money[2] + prize
		saveMoney()
	end

	st.result = {w = w, bonus = bonus, prize = prize, bet = bet, nick = nick}
	st.spinning = true
	st.winShown = 0
	st.mode = "spin"
	st.rain = 0
	local tease = w[1] == w[2]
	for i, r in ipairs(reels) do
		r.hl = false
		plan(r, w[i], 100 + (i - 1) * 130 + ((i == 3 and tease) and LSTRIP or 0), (i - 1) * 2, i == 3 and tease)
	end
	st.tease = tease
	setMsg("Крутим на " .. bet .. "$", "")
	drawJackpot("", false)
	drawWin()
	refreshButtons()
end

local function showResult()
	local r = st.result
	local w, bonus, prize = r.w, r.bonus, r.prize
	st.spinning = false
	st.balance = balanceOf(r.nick)
	local now = computer.uptime()
	if bonus > 0 then
		local lit3 = {}
		if w[1] == w[2] and w[2] == w[3] then lit3 = {1, 2, 3}
		elseif w[1] == w[2] then lit3 = {1, 2}
		elseif w[2] == w[3] then lit3 = {2, 3}
		else lit3 = {1, 3} end
		st.winReels = lit3
		st.blinkUntil = now + 4
		st.countStep = math.max(1, math.ceil(prize / 20))
		if bonus >= 10 then
			st.mode, st.modeUntil = "jackpot", now + 5
			st.rain = 70
			st.jackpotText = "x" .. bonus
			setMsg("", "")
			Say(w[1], r.nick, prize)
			pcall(function() component.redstone.setOutput(RED, 15) end)
			st.redstoneOff = now + 1
			st.beeps = {{0, 523}, {3, 659}, {6, 784}, {9, 1046}}
		else
			st.mode, st.modeUntil = "win", now + 3
			setMsg("БОНУС x" .. bonus, "+" .. prize .. "$", 0x33DB40)
			st.beeps = {{0, 784}, {3, 1046}}
		end
		pushHistory(r.bet .. "$ → +" .. prize .. "$ x" .. bonus, bonus >= 10 and GOLD or 0x33DB40)
	else
		st.mode = "idle"
		setMsg("Мимо!", "попробуйте ещё раз", 0xFF4940)
		pushHistory(r.bet .. "$ → мимо", 0x787878)
	end
	st.beepFrame = 0
	refreshButtons()
end

local function getStavka(d)
	st.stavka = math.max(1, math.min(MAX_STAVKA, st.stavka + d))
	drawBet()
end

local function inButton(b, lx, lr)
	return lx >= b.x and lx <= b.x + b.w - 1 and lr >= 39 and lr <= 41
end

local function onTouch(x, y, nick)
	local now = computer.uptime()
	if now < st.spamUntil then return end
	if st.login and nick ~= st.login then return end
	local lx, lr = x - OX, y - OR
	st.lastTouch = now
	for _, b in ipairs(buttons) do
		if inButton(b, lx, lr) and not b.off then
			b.pressed, b.pressUntil = true, now + 0.2
			drawButton(b)
			if b.id == "login" then
				if st.login then Exit() else Login(nick) end
			elseif b.id == "bet" then
				getStavka(b.d)
				beep(TONE, 0.05)
			elseif b.id == "spin" then
				Start(nick)
			end
			return
		end
	end
	-- касание барабанов - тоже прокрутка
	if st.login and not st.spinning and lx >= 35 and lx <= 112 and lr >= 19 and lr <= 36 then
		Start(nick)
	end
end

------------------------------------------------------------------ кадр

local frame = 0

local function bulbLook(i, now)
	local m = st.mode
	if m == "jackpot" then
		return ((i + frame) % 2 == 0) and BULB.on or BULB.red
	elseif m == "win" then
		return (floor(frame / 3) % 2 == 0) and BULB.on or BULB.off
	elseif m == "spin" then
		return ((i + frame) % 3 ~= 0) and BULB.on or BULB.off
	end
	return ((i + floor(now * 4)) % 4 < 2) and BULB.on or BULB.off
end

local function step()
	frame = frame + 1
	local now = computer.uptime()
	restoreCoins()

	-- барабаны
	local moving = false
	for i, r in ipairs(reels) do
		if r.qi <= #r.q then
			local d = r.q[r.qi]
			r.qi = r.qi + 1
			r.pos = (r.pos + d) % LSTRIP
			r.v = abs(d)
			shiftReel(r, d)
			r.dirty = true
			moving = true
			if r.qi > #r.q then
				r.v = 0
				beep(TONE + i * 80, 0.05)
				if i == 2 and st.tease then setMsg("Ещё чуть-чуть...", "", GOLD) end
			end
		end
	end
	if st.spinning and not moving then showResult() end

	-- мигание выигравших барабанов
	if st.winReels then
		local on = now < st.blinkUntil and floor(frame / 3) % 2 == 0
		for _, i in ipairs(st.winReels) do
			local want = on and GOLD or false
			if reels[i].hl ~= want then reels[i].hl = want reels[i].dirty = true end
		end
		if now >= st.blinkUntil then st.winReels = nil end
	end
	for _, r in ipairs(reels) do
		if r.dirty then drawReel(r) r.dirty = false end
	end

	-- выигрыш на табло набегает
	if not st.spinning and st.result and st.winShown < st.result.prize then
		st.winShown = math.min(st.result.prize, st.winShown + st.countStep)
		drawWin()
	end

	-- режим подсветки и джекпот
	if (st.mode == "win" or st.mode == "jackpot") and now >= st.modeUntil then
		if st.mode == "jackpot" then drawJackpot("", false) setMsg("ДЖЕКПОТ!", "+" .. st.result.prize .. "$", GOLD) end
		st.mode = "idle"
	end
	if st.mode == "jackpot" then drawJackpot(st.jackpotText, floor(frame / 4) % 2 == 0) end
	if st.mode ~= "jackpot" then drawMsg() end

	-- звуки выигрыша - по одному за кадр, чтобы не вставала картинка
	if st.beeps and #st.beeps > 0 then
		st.beepFrame = (st.beepFrame or 0) + 1
		if st.beepFrame >= st.beeps[1][1] then
			beep(table.remove(st.beeps, 1)[2], 0.05)
		end
	end
	if st.redstoneOff and now >= st.redstoneOff then
		pcall(function() component.redstone.setOutput(RED, 0) end)
		st.redstoneOff = nil
	end

	-- лампочки: в покое - раз в четверть секунды
	if st.mode ~= "idle" or frame % 2 == 0 then
		for i, b in ipairs(bulbs) do drawBulb(b, bulbLook(i, now)) end
	end

	-- блик по заголовку
	if st.glint then
		st.glint = st.glint + 5
		if st.glint > TW + 20 then st.glint = nil st.nextGlint = now + 6 end
		drawTitle(st.glint)
	elseif now >= st.nextGlint then
		st.glint = -10
	end

	-- отжатые кнопки
	for _, b in ipairs(buttons) do
		if b.pressed and now >= b.pressUntil then b.pressed = false drawButton(b) end
	end

	-- дождь монет
	if st.rain > 0 then
		st.rain = st.rain - 1
		if rnd() < 0.8 then
			coins[#coins + 1] = {x = rnd(4, 142), y = -2, vy = 0.5 + rnd(), t = rnd(0, 5)}
		end
	end
	for i = #coins, 1, -1 do
		local c = coins[i]
		c.y = c.y + c.vy
		c.vy = c.vy + 0.12
		c.t = c.t + 1
		if c.y > 84 then table.remove(coins, i) end
	end
	stampCoins()

	-- панель слева: автовыход и прочее
	if st.login and not st.spinning and now - st.lastTouch >= AUTOEXIT then Exit() end
	drawLeft()

	flush()
end

------------------------------------------------------------------ старт

pcall(function() component.chat_box.setName("§6G§7") end)
loadMoney()
for i, r in ipairs(reels) do r.pos = posFor(rnd(0, 8) + 1) r.dirty = true end
drawStatic()
setMsg("ДОБРО ПОЖАЛОВАТЬ", "нажмите ВОЙТИ")
drawBet()
drawWin()
refreshButtons()
Exit()
st.spamUntil = 0

local lastStep = -1
while true do
	local busy = st.spinning or #coins > 0 or st.glint or st.mode ~= "idle" or st.winReels
	local e, _, x, y, _, nick = event.pull(busy and 0.05 or 0.1)
	if e == "touch" then onTouch(x, y, nick) end
	if DEMO and e == "key_down" and y == 16 then break end
	local now = computer.uptime()
	if now - lastStep >= 0.045 or e == "touch" then
		lastStep = now
		step()
	end
end

-- выход бывает только на фишках: вернуть экран, каким он был
if buf then g.setActiveBuffer(0) g.freeBuffer(buf) end
for i = 0, 15 do pcall(g.setPaletteColor, i, 0x0F0F0F * (i + 1)) end
g.setResolution(g.maxResolution())
g.setBackground(0x000000)
g.setForeground(0xFFFFFF)
require("term").clear()
