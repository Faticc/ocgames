-- video - проигрыватель роликов BAPL для DwOS: меню со всеми роликами,
-- что найдутся на дисках, цветное видео и звук с кассеты.
--
--   video                              - меню: стрелки, Enter, W - звук на кассету
--   video клип.bin [--loop] [--from=1:30] [--free] [--mute] [--sync=0.75]
--   video --writetape=клип.dfpwm       - записать звук на кассету
--
-- Ролики ищутся рядом с плеером, в /home/videos, /home/games, /home и в
-- корне и папке videos каждого диска из /mnt - туда их кладёт установщик
-- (games-update), каждый на тот диск, что выбрали. Делает их tools/packvideo.py из любого
-- mp4, рядом кладёт .dfpwm для кассеты.
--
-- Два формата. Первый - Bad Apple!! (tools/packbadapple.py): до восьми
-- оттенков серого, перемотка по ключевым кадрам прямо в потоке. Второй -
-- цветной: 16 своих цветов ролика в палитре карты и 240 зашитых цветов
-- куба третьего уровня, перемотка по снимкам, лежащим отдельно от потока.
--
-- Экран OC - символы, а не точки: нижний полублок U+2584 делит ячейку
-- пополам, верх - цвет фона, низ - цвет символа. В файле лежат не
-- пиксели, а уже готовые вызовы gpu.set: отрезки ячеек, которые в этом
-- кадре надо перекрасить, разложенные по парам цветов. Диффом, выбором
-- цветов и потолком вызовов на кадр занят упаковщик на большом
-- компьютере, здесь остаётся прочитать пару килобайт и сделать сотни
-- вызовов в буфер видеопамяти - бюджет машины они не тратят. На экран
-- кадр уходит одним bitblt, а если изменений мало - их повтором прямо на
-- экране (так дешевле, см. lib/gfx.lua).
--
-- Почему не холст gfx.surface: у него все цвета - либо индексы палитры,
-- либо RGB, а цветному ролику нужно и то и другое сразу. Свои 16 цветов
-- ролик ставит в палитру и зовёт по индексу, а цвета куба передаёт как
-- RGB ровно тех значений, что зашиты в карту: такой цвет ложится в куб
-- без округления, какая бы палитра ни стояла у буфера.
--
-- Звук крутит кассетник Computronics (tape_drive): кассета пишется один
-- раз (W в меню или --writetape), дальше блок играет её сам. Плеер держит
-- ленту там же, где картинка, - при запуске, паузе, перемотке и раз в
-- секунду на сверку. На кассете имя ролика, и чужую плеер не заиграет.
--
-- Слышно не то место, где лента сейчас: клиент копит буфер
-- (audioPreloadMs, по умолчанию 750 мс) и только потом начинает играть.
-- Ленту пустили - картинка ждёт sync секунд; лента уже идёт - при
-- перемотке она встаёт на sync впереди кадра. Не сошлось на глаз -
-- подстрой клавишами [ и ].
--
-- Управление: пробел - пауза, стрелки - перемотка на 5 секунд, R - сначала,
-- M - звук, [ и ] - подстройка звука, - и = - громкость, Q - назад в меню.
--
-- --free гонит кадры без оглядки на часы - так видно, сколько их машина
-- вытягивает на самом деле; обычно же плеер держит частоту ролика, а не
-- успевая - пропускает вывод кадра, но не его разбор.

local args = { ... }
local opt = {}
local rest = {}
for _, a in ipairs(args) do
	local k, v = a:match("^%-%-([%w_]+)=?(.*)$")
	if k then opt[k] = v ~= "" and v or true else rest[#rest + 1] = a end
end

local component = require("component")
local computer = require("computer")
local event = require("event")
local unicode = require("unicode")
local gfx = require("gfx")
local gpu = component.gpu

local floor, rep, uptime = math.floor, string.rep, computer.uptime
local BLOCK = "\226\150\132"   -- U+2584, нижний полублок

local function mmss(sec)
	sec = floor(sec)
	return ("%d:%02d"):format(floor(sec / 60), sec % 60)
end

------------------------------------------------------------------ файлы

--- Каталог самого плеера: ярлык из /bin зовёт его из любого места.
local function selfdir()
	for i = 1, 4 do
		local d = debug.getinfo(i, "S")
		local p = d and d.source and d.source:match("^[=@]?(.*)/[^/]*%.lua$")
		if p and p ~= "" then return p end
	end
	return "/home/games"
end

--- Файл по имени, как дано, а если это просто имя - рядом с плеером.
local function find(name)
	if name:find("/") then return io.open(name, "rb"), name end
	local p = selfdir() .. "/" .. name
	local f = io.open(p, "rb")
	if f then return f, p end
	return io.open(name, "rb"), name
end

--- read даёт не больше maxReadBuffer за раз (в конфиге сервера 2 КБ).
local function readn(f, n)
	local parts, got = {}, 0
	while got < n do
		local c = f:read(n - got)
		if not c or #c == 0 then break end
		parts[#parts + 1] = c
		got = got + #c
	end
	return table.concat(parts)
end

local function u16(s, i) return s:byte(i) + s:byte(i + 1) * 256 end
local function u32(s, i)
	return s:byte(i) + s:byte(i + 1) * 256 + s:byte(i + 2) * 65536 + s:byte(i + 3) * 16777216
end

local function basename(p) return (p:match("([^/]+)$") or p):gsub("%.[^.]*$", "") end

--- Заголовок ролика. full = true - ещё и палитра со снимками: без них
--- показывать нечего, а меню хватает имени и длины.
local function probe(path, full)
	local f = io.open(path, "rb")
	if not f then return nil, "не открылся " .. path end
	local head = readn(f, 16)
	if #head < 16 or head:sub(1, 4) ~= "BAPL" or (head:byte(5) ~= 1 and head:byte(5) ~= 2) then
		f:close()
		return nil, path .. " - это не ролик BAPL"
	end
	local v = {
		path = path, name = basename(path), ver = head:byte(5),
		PW = u16(head, 6), PH = u16(head, 8), FPS = u16(head, 10) / 100, N = u32(head, 12),
	}
	local ncol
	if v.ver == 1 then
		ncol = head:byte(16)
		v.title = v.name
	else
		local tl = head:byte(16)
		v.title = tl > 0 and readn(f, tl) or v.name
		ncol = u16(readn(f, 2), 1)
	end
	v.ncol = ncol
	v.CW, v.CH = v.PW, floor(v.PH / 2)
	if not full then f:close() return v end

	-- цвета: индекс -> что передать карте и индекс ли это палитры
	local rgb = readn(f, ncol * 3)
	v.pal, v.cv, v.cp = {}, {}, {}
	for i = 0, ncol - 1 do
		local c = rgb:byte(i * 3 + 1) * 65536 + rgb:byte(i * 3 + 2) * 256 + rgb:byte(i * 3 + 3)
		if i < 16 then
			v.pal[i] = c
			v.cv[i], v.cp[i] = i, true
		else
			v.cv[i], v.cp[i] = c, false
		end
	end
	local t = readn(f, 6)
	v.KEYINT, v.NKEYS = u16(t, 1), u32(t, 3)
	v.keys, v.snaps = {}, {}
	if v.ver == 1 then
		t = readn(f, v.NKEYS * 4)
		for i = 1, v.NKEYS do v.keys[i] = u32(t, (i - 1) * 4 + 1) end
	else
		t = readn(f, v.NKEYS * 8)
		for i = 1, v.NKEYS do
			v.snaps[i] = u32(t, (i - 1) * 8 + 1)
			v.keys[i] = u32(t, (i - 1) * 8 + 5)
		end
	end
	v.fh = f
	return v
end

------------------------------------------------------------------ звук

-- Кассетник держит DFPWM: 4096 байт на секунду звука. Даровые вызовы у
-- него только getPosition, getSize и isReady, а seek, play и stop стоят
-- тика - поэтому ленту трогаем на паузе, перемотке и раз в секунду.
local TAPE_BPS = 4096

local tape, emptyDrive
for addr in component.list("tape_drive") do
	local t = component.proxy(addr)
	local ok, ready = pcall(t.isReady)
	if ok and ready then tape = t break end
	emptyDrive = true
end

local snd = {
	on = false,
	vol = math.min(1, math.max(0, tonumber(opt.volume) or 1)),
	sync = tonumber(opt.sync) or 0.75,
	size = 0,
	label = nil,
}

local function readTape()
	if not tape then return end
	local ok, sz = pcall(tape.getSize)
	snd.size = ok and sz or 0
	local ok2, l = pcall(tape.getLabel)
	l = ok2 and l or nil
	-- кассеты, записанные прежним badapple, подписаны так
	if l == "Bad Apple!!" then l = "badapple" end
	snd.label = l
end
readTape()

local function tapeTo(sec)
	local want = floor(sec * TAPE_BPS)
	if want < 0 then want = 0 elseif want > snd.size then want = snd.size end
	local ok, pos = pcall(tape.getPosition)
	if ok and want ~= pos then pcall(tape.seek, want - pos) end
end

--- Идущую ленту - на sync впереди кадра.
local function sndSeek(sec)
	if snd.on then tapeTo(sec + snd.sync) end
end

--- Пустить ленту с этого кадра; вернёт, сколько картинке ждать звук.
local function sndPlay(sec)
	if not snd.on then return 0 end
	tapeTo(sec)
	pcall(tape.play)
	return snd.sync > 0 and snd.sync or 0
end

local function sndStop()
	if tape then pcall(tape.stop) end
end

--- Сверка раз в секунду: поправка слышна щелчком, поэтому порог не мелкий.
local function sndCheck(sec)
	if not snd.on then return end
	local ok, pos = pcall(tape.getPosition)
	if not ok or pos >= snd.size then return end
	local d = pos / TAPE_BPS - snd.sync - sec
	if d > 0.25 or d < -0.25 then sndSeek(sec) end
end

--- Записать звук на кассету и подписать её именем ролика. Пишем по 8 КБ:
--- тика стоит каждый write, а не каждый байт.
local function writetape(path, label, say)
	if not tape then
		return nil, emptyDrive and "в кассетнике нет кассеты"
			or "кассетника не видно - поставь tape drive рядом с компьютером"
	end
	local f = io.open(path, "rb")
	if not f then return nil, "не найден " .. path end
	readTape()
	local len = f:seek("end") or 0
	f:seek("set", 0)
	pcall(tape.stop)
	pcall(tape.seek, -tape.getPosition())
	local done = 0
	while done < len do
		local chunk = readn(f, 8192)
		if #chunk == 0 then break end
		local before = tape.getPosition()
		tape.write(chunk)
		local wrote = tape.getPosition() - before
		done = done + wrote
		say(("записываю %s: %3d%%"):format(label, floor(done / len * 100)))
		if wrote < #chunk then break end            -- лента кончилась
	end
	f:close()
	pcall(tape.setLabel, label)
	pcall(tape.seek, -tape.getPosition())
	readTape()
	local msg = ("записано %d КБ - %s звука"):format(floor(done / 1024), mmss(done / TAPE_BPS))
	if done < len then msg = msg .. (", кассета короче ролика (%s)"):format(mmss(len / TAPE_BPS)) end
	return msg
end

if opt.writetape then
	local f, p = find(opt.writetape == true and "badapple.dfpwm" or tostring(opt.writetape))
	if f then f:close() end
	local msg, err = writetape(p, basename(p), function(s) io.write("\r" .. s) end)
	print()
	if not msg then io.stderr:write(err .. "\n") os.exit(1) end
	print(msg)
	os.exit(0)
end

------------------------------------------------------------------ экран

local SW, SH = 160, 50
do
	local mw, mh = gpu.maxResolution()
	SW, SH = math.min(SW, mw), math.min(SH, mh)
	-- setResolution стоит тика: если экран и так нужного размера - не зовём
	local cw, ch = gpu.getResolution()
	if cw ~= SW or ch ~= SH then gpu.setResolution(SW, SH) end
end

-- цены вызовов к экрану по уровням карты - те же, что в lib/gfx.lua
local TIER = SW >= 160 and 3 or SW >= 80 and 2 or 1
local CSET = ({ 1/64, 1/128, 1/256 })[TIER]
local CCOL = ({ 1/32, 1/64, 1/128 })[TIER]

-- На выходе ставим штатную палитру карты (серые 15, 30, ... 240), а не ту,
-- что застали: палитру помнит монитор, и если прошлый показ оборвался
-- (машину выключили посреди ролика), "застали" мы палитру того ролика - и
-- вернули бы её же. А на штатную рассчитаны и DwOS, и ShopOS.
local savedPal = {}
for i = 0, 15 do savedPal[i] = floor(255 * (i + 1) / 17) * 0x010101 end
local GREY, BLACK, WHITE, HILITE = 0x999999, 0x000000, 0xFFFFFF, 0x33497F

--- Строка на экран прямо, мимо буфера: меню и строка состояния.
local function text(x, y, s, fg, bg, width)
	local len = unicode.len(s)
	if width then
		if len > width then s = unicode.sub(s, 1, width) len = width end
		s = s .. rep(" ", width - len)
	end
	gpu.setBackground(bg or BLACK)
	gpu.setForeground(fg or WHITE)
	gpu.set(x, y, s)
end

------------------------------------------------------------------ показ

--- Проиграть ролик. Вернёт "back" (Q, конец ролика) или "quit" (Ctrl+C).
local function play(v)
	local fh = v.fh
	local CW, CH, FPS, NFRAMES = v.CW, v.CH, v.FPS, v.N
	if CW > SW or CH + 1 > SH then
		fh:close()
		return "back", ("ролик %dx%d ячеек, а экран %dx%d - нужен монитор побольше")
			:format(CW, CH + 1, SW, SH)
	end
	local X0 = floor((SW - CW) / 2) + 1
	local Y0 = floor((SH - 1 - CH) / 2) + 1
	local BAR = SH

	-- звук: если на кассете этот ролик или она не подписана; кассету с
	-- чужим именем не трогаем (M включит и её)
	readTape()
	snd.on = tape ~= nil and not opt.mute
		and (snd.label == nil or snd.label == "" or snd.label == v.name)

	------------------------------------------------ холст

	-- свой буфер размером с ролик; без видеопамяти рисуем прямо на экран
	local buf
	if gpu.allocateBuffer then
		local ok, id = pcall(gpu.allocateBuffer, CW, CH)
		if ok and id then buf = id end
	end
	local OX, OY = 1, 1
	if not buf then OX, OY = X0, Y0 end
	local CV, CP = v.cv, v.cp
	local cbg, cfg                   -- что сейчас стоит на карте (индексы)

	-- журнал для повтора на экране: пять параллельных массивов, а не
	-- таблица на каждый вызов - кадр их делает сотни
	local LX, LY, LS, LB, LF = {}, {}, {}, {}, {}
	local ln, cost, stale, lbg, lfg = 0, 0, true, nil, nil
	local mw, mh = gpu.maxResolution()
	local LIMIT = math.min(({ 0.5, 1, 2 })[TIER] * CW * CH / (mw * mh), gfx.budget or 0.9)

	local spaces, blocks = {}, {}
	local function runstr(cache, ch, n)
		local s = cache[n]
		if not s then s = rep(ch, n) cache[n] = s end
		return s
	end

	local gtop, gbot, gstr         -- цвета текущей группы и её символ

	local function group(top, bot)
		if top ~= cbg then gpu.setBackground(CV[top], CP[top]) cbg = top end
		if top == bot then
			gstr = spaces
			bot = -1
		else
			gstr = blocks
			if bot ~= cfg then gpu.setForeground(CV[bot], CP[bot]) cfg = bot end
		end
		gtop, gbot = top, bot
	end

	local function span(p, len)
		local row = floor(p / CW)
		local x, y = p - row * CW + 1, row + 1
		local s = runstr(gstr, gstr == spaces and " " or BLOCK, len)
		gpu.set(OX + x - 1, OY + y - 1, s)
		if buf and not stale then
			ln = ln + 1
			LX[ln], LY[ln], LS[ln], LB[ln], LF[ln] = x, y, s, gtop, gbot
			if gtop ~= lbg then cost = cost + CCOL lbg = gtop end
			if gbot >= 0 and gbot ~= lfg then cost = cost + CCOL lfg = gbot end
			cost = cost + CSET
			if cost > LIMIT then stale = true end
		end
	end

	local function present()
		if not buf then return end
		if ln == 0 and not stale then return end
		gpu.setActiveBuffer(0)
		if not stale then
			local bg, fg
			for i = 1, ln do
				local b, f = LB[i], LF[i]
				if b ~= bg then gpu.setBackground(CV[b], CP[b]) bg = b end
				if f >= 0 and f ~= fg then gpu.setForeground(CV[f], CP[f]) fg = f end
				gpu.set(X0 + LX[i] - 1, Y0 + LY[i] - 1, LS[i])
			end
		else
			gpu.bitblt(0, X0, Y0, CW, CH, buf, 1, 1)
		end
		gpu.setActiveBuffer(buf)
		-- делят ли буферы цвета с экраном - не наше дело: переспросим
		cbg, cfg = nil, nil
		ln, cost, stale, lbg, lfg = 0, 0, false, nil, nil
	end

	------------------------------------------------ поток

	local sbuf, bp, eof = "", 1, false
	local CHUNK = 2048
	local function refill()
		if bp > 1 then sbuf = sbuf:sub(bp) bp = 1 end
		while #sbuf < CHUNK and not eof do
			local c = fh:read(CHUNK)
			if not c or #c == 0 then eof = true break end
			sbuf = sbuf .. c
		end
	end
	local function jumpTo(off)
		fh:seek("set", off)
		sbuf, bp, eof = "", 1, false
	end

	--- Число переменной длины: по семь бит на байт, старший - "дальше есть".
	local function rdv()
		local n, mul = 0, 1
		while true do
			if bp > #sbuf then
				refill()
				if bp > #sbuf then return n end
			end
			local b = sbuf:byte(bp)
			bp = bp + 1
			if b < 128 then return n + b * mul end
			n = n + (b - 128) * mul
			mul = mul * 128
		end
	end
	local function rdb()
		if bp > #sbuf then
			refill()
			if bp > #sbuf then return 0 end
		end
		local b = sbuf:byte(bp)
		bp = bp + 1
		return b
	end

	local drawFrame
	if v.ver == 1 then
		-- первая версия: отрезки разложены по всем состояниям ячейки подряд
		local NC = v.ncol
		drawFrame = function()
			for s = 0, NC * NC - 1 do
				local n = rdv()
				if n > 0 then
					group(floor(s / NC), s % NC)
					local p = 0
					for _ = 1, n do
						p = p + rdv()
						local len = rdv()
						span(p, len)
						p = p + len
					end
				end
			end
		end
	else
		-- вторая: группы по паре цветов, цвета - по байту
		drawFrame = function()
			for _ = 1, rdv() do
				local top = rdb()
				group(top, rdb())
				local p = 0
				for _ = 1, rdv() do
					p = p + rdv()
					local len = rdv()
					span(p, len)
					p = p + len
				end
			end
		end
	end

	--- Перемотка. Вернёт номер следующего кадра к разбору.
	local function seek(n)
		if n < 0 then n = 0 end
		if n >= NFRAMES then n = NFRAMES - 1 end
		local ki = v.KEYINT > 0 and floor(n / v.KEYINT) or 0
		if ki + 1 > v.NKEYS then ki = v.NKEYS - 1 end
		stale = true            -- всё, что ниже, уйдёт на экран bitblt-ом
		if v.ver == 1 then
			-- ключевой кадр лежит в потоке: от него доигрываем вслепую
			jumpTo(v.keys[ki + 1])
			local at = ki * v.KEYINT
			while at < n do drawFrame() at = at + 1 end
			return at
		end
		-- снимок лежит отдельно: рисуем его и читаем поток с этого места
		jumpTo(v.snaps[ki + 1])
		drawFrame()
		jumpTo(v.keys[ki + 1])
		return ki * v.KEYINT + 1
	end

	------------------------------------------------ состояние

	local FREE = opt.free and true or false
	local cur = 0
	local skips, dropped, shownFps = 0, 0, 0
	local paused, running, result = false, true, "back"

	local barText, barAt
	local function drawBar()
		local at = floor(cur * 4 / FPS)
		if at == barAt and barText then return end
		barAt = at
		local n = 24
		local full = floor(math.min(cur, NFRAMES) / NFRAMES * n + 0.5)
		local sound = ""
		if snd.on then sound = ("  лента %+.2f"):format(snd.sync)
		elseif tape and snd.label and snd.label ~= "" and snd.label ~= v.name then
			sound = ("  на кассете \"%s\""):format(snd.label)
		elseif tape then sound = "  звук выкл"
		elseif emptyDrive then sound = "  нет кассеты"
		end
		local s = ("%s %s  %s / %s  [%s%s]  %.0f к/с%s%s   пробел, стрелки, R%s, Q - назад")
			:format(paused and "||" or ">", v.title, mmss(cur / FPS), mmss(NFRAMES / FPS),
				rep("#", full), rep("-", n - full), shownFps,
				dropped > 0 and ("  пропущено %d"):format(dropped) or "", sound,
				tape and ", M - звук" or "")
		if s == barText then return end
		barText = s
		if buf then gpu.setActiveBuffer(0) end
		text(1, BAR, s, GREY, BLACK, SW)
		if buf then gpu.setActiveBuffer(buf) end
		cbg, cfg = nil, nil
	end

	------------------------------------------------ клавиши

	local pending = {}
	local function handleKey(name, _, _, code)
		if name == "key_down" then pending[#pending + 1] = code end
		return true
	end
	event.listen("key_down", handleKey)

	--- Отдать управление системе. Таймаут ненулевой - с нулевым сигналы
	--- не отдаются, и плеер остаётся глухим (см. mario.lua).
	local function pump(timeout)
		local e, _, _, code = event.pull(timeout or 0.01)
		if e == "interrupted" then running = false result = "quit"
		elseif e == "key_down" then
			if pending[#pending] ~= code then pending[#pending + 1] = code end
		end
	end

	local jump, resumed
	local function takeKeys()
		while #pending > 0 do
			local c = table.remove(pending, 1)
			if c == 16 or c == 1 then running = false                 -- Q, Esc
			elseif c == 57 then                                       -- пробел
				paused = not paused
				barAt = nil
				if paused then sndStop() else resumed = true end
			elseif c == 203 then jump = -5                            -- влево
			elseif c == 205 then jump = 5                             -- вправо
			elseif c == 19 then jump = -1e9                           -- R
			elseif c == 50 then                                       -- M
				if snd.on then
					snd.on = false
					sndStop()
				elseif tape then
					snd.on = true
					pcall(tape.setVolume, snd.vol)
					resumed = not paused
				end
				barAt = nil
			elseif (c == 26 or c == 27) and snd.on then               -- [ и ]
				snd.sync = math.min(3, math.max(0, snd.sync + (c == 26 and -0.05 or 0.05)))
				if not paused then sndSeek(cur / FPS) end
				barAt = nil
			elseif (c == 12 or c == 13) and tape then                 -- - и =
				snd.vol = math.min(1, math.max(0, snd.vol + (c == 12 and -0.1 or 0.1)))
				pcall(tape.setVolume, snd.vol)
				barAt = nil
			end
		end
	end

	------------------------------------------------ цикл

	local ok, err = pcall(function()
		-- поля вокруг ролика заливаются один раз
		text(1, 1, "", WHITE, BLACK)
		gpu.fill(1, 1, SW, SH, " ")
		-- своя палитра на время ролика, старая вернётся после
		for i = 0, 15 do
			if v.pal[i] then pcall(gpu.setPaletteColor, i, v.pal[i]) end
		end
		if buf then
			gpu.setActiveBuffer(buf)
			gpu.setBackground(BLACK)
			gpu.fill(1, 1, CW, CH, " ")
		end

		local from = 0
		if opt.from then
			local m, s = tostring(opt.from):match("^(%d+):(%d+)$")
			from = floor((m and (tonumber(m) * 60 + tonumber(s)) or tonumber(opt.from) or 0) * FPS)
		end
		cur = seek(from)
		present()

		if snd.on then pcall(tape.setVolume, snd.vol) end
		local base = uptime() + sndPlay(cur / FPS) - cur / FPS
		local fpsT, fpsN = uptime(), 0
		local sndT = uptime()

		while running do
			takeKeys()
			if resumed then
				base = uptime() + sndPlay(cur / FPS) - cur / FPS
				sndT = uptime()
				resumed = nil
			end
			if jump then
				cur = seek(jump <= -1e9 and 0 or (cur + floor(jump * FPS)))
				jump = nil
				base = uptime() - cur / FPS
				dropped, skips = 0, 0
				barAt = nil
				if not paused then sndSeek(cur / FPS) sndT = uptime() end
				present()
			end

			if paused then
				drawBar()
				pump(0.05)
				base = uptime() - cur / FPS
			elseif cur >= NFRAMES then
				if opt.loop then
					cur = seek(0)
					present()
					sndStop()
					base = uptime() + sndPlay(0) - cur / FPS
					sndT = uptime()
				else running = false end
			else
				drawFrame()
				cur = cur + 1
				-- отстаём - кадр разобран (иначе следующий не соберётся), но
				-- на экран не идёт; подряд больше двух не пропускаем
				local due = base + cur / FPS
				local now = uptime()
				if not FREE and now > due + 2 / FPS and skips < 2 then
					dropped = dropped + 1
					skips = skips + 1
				else
					if skips > 0 then base = now - cur / FPS skips = 0 end
					present()
					fpsN = fpsN + 1
					if now - fpsT >= 1 then
						shownFps = fpsN / (now - fpsT)
						fpsT, fpsN = now, 0
						barAt = nil
					end
				end
				if now - sndT >= 1 then sndT = now sndCheck(cur / FPS) end
				drawBar()
				local wait = FREE and 0 or (due - uptime())
				pump(wait > 0 and wait or 0.001)
			end
		end
	end)

	event.ignore("key_down", handleKey)
	sndStop()
	fh:close()
	if buf then
		gpu.setActiveBuffer(0)
		pcall(gpu.freeBuffer, buf)
	end
	gfx.restorePalette(gpu, savedPal)
	if not ok then error(err, 0) end
	return result
end

------------------------------------------------------------------ меню

--- Где искать ролики: рядом с плеером, в /home/videos, /home и на дисках.
local function scan()
	local ok, fs = pcall(require, "filesystem")
	local dirs, seen = {}, {}
	local function add(d)
		d = d:gsub("/+$", "")
		if d == "" then d = "/" end
		if not seen[d] then seen[d] = true dirs[#dirs + 1] = d end
	end
	add(selfdir())
	add("/home/videos")
	add("/home/games")     -- туда ролик ставили прежние установщики
	add("/home")
	if ok and fs.list then
		local okm, it = pcall(fs.list, "/mnt")
		if okm and it then
			for m in it do
				add("/mnt/" .. m)
				add("/mnt/" .. m:gsub("/$", "") .. "/videos")
			end
		end
	end
	local list, got = {}, {}
	for _, d in ipairs(dirs) do
		local names = {}
		if ok and fs.list then
			local okl, it = pcall(fs.list, d)
			if okl and it then for n in it do names[#names + 1] = n end end
		end
		for _, n in ipairs(names) do
			if n:lower():match("%.bin$") then
				local p = (d == "/" and "" or d) .. "/" .. n
				local real = fs.realPath and fs.realPath(p) or p
				if not got[real] then
					got[real] = true
					local v = probe(p)
					if v then
						v.size = fs.size and fs.size(p) or 0
						local dp = p:gsub("%.[^.]*$", ".dfpwm")
						v.dfpwm = fs.exists and fs.exists(dp) and dp or nil
						v.dir = d
						list[#list + 1] = v
					end
				end
			end
		end
	end
	table.sort(list, function(a, b) return a.title:lower() < b.title:lower() end)
	return list, dirs
end

local function mb(n)
	if n >= 1048576 then return ("%.1f МБ"):format(n / 1048576) end
	return ("%d КБ"):format(floor(n / 1024))
end

local function menu()
	local list = scan()
	local sel, top = 1, 1
	local note = nil
	local ROWS = SH - 6

	local function row(v)
		local sound = ""
		if tape and snd.label == v.name then sound = "звук на кассете"
		elseif v.dfpwm then sound = tape and "W - звук на кассету" or ".dfpwm есть, нет кассетника"
		end
		local col = v.ver == 1 and (v.ncol .. " серых") or (v.ncol .. " цв.")
		local t = v.title
		if unicode.len(t) > 40 then t = unicode.sub(t, 1, 39) .. "~" end
		-- format считает байты, а не буквы: кириллицу добиваем сами
		local function pad(x, n) return x .. rep(" ", n - unicode.len(x)) end
		return " " .. pad(t, 41) .. pad(mmss(v.N / v.FPS), 7)
			.. pad(("%dx%d"):format(v.PW, v.PH), 9) .. pad(("%g к/с"):format(v.FPS), 9)
			.. pad(col, 10) .. pad(mb(v.size or 0), 10) .. sound
	end

	local function draw()
		text(1, 1, "", WHITE, BLACK)
		gpu.fill(1, 1, SW, SH, " ")
		text(2, 2, "Ролики", WHITE, BLACK)
		if #list == 0 then
			text(2, 4, "Роликов не нашлось. Положи .bin рядом с плеером, в /home/videos", GREY)
			text(2, 5, "или в папку videos на любом диске. Сделать из mp4:", GREY)
			text(4, 7, "python tools/packvideo.py клип.mp4", WHITE)
		end
		if sel < top then top = sel end
		if sel > top + ROWS - 1 then top = sel - ROWS + 1 end
		for i = 0, ROWS - 1 do
			local v = list[top + i]
			if v then
				local on = top + i == sel
				text(1, 4 + i, row(v), on and WHITE or GREY, on and HILITE or BLACK, SW)
			end
		end
		text(2, SH - 1, note or "", WHITE, BLACK, SW - 2)
		text(2, SH, "стрелки - выбор, Enter - смотреть, W - записать звук на кассету, Q - выход",
			GREY, BLACK, SW - 2)
	end

	while true do
		draw()
		local e, _, _, code = event.pull()
		if e == "interrupted" then return end
		if e == "key_down" then
			note = nil
			if code == 16 or code == 1 then return                     -- Q, Esc
			elseif code == 200 then sel = math.max(1, sel - 1)          -- вверх
			elseif code == 208 then sel = math.min(#list, sel + 1)      -- вниз
			elseif code == 201 then sel = math.max(1, sel - ROWS)       -- PgUp
			elseif code == 209 then sel = math.min(#list, sel + ROWS)   -- PgDn
			elseif code == 28 and list[sel] then                        -- Enter
				local v, err = probe(list[sel].path, true)
				if not v then note = err
				else
					local r, msg = play(v)
					if r == "quit" then return end
					note = msg
				end
			elseif code == 17 and list[sel] then                        -- W
				local v = list[sel]
				if not v.dfpwm then
					note = "звука к ролику нет: сделай " .. v.name .. ".dfpwm (packvideo делает его сам)"
				else
					local msg, err = writetape(v.dfpwm, v.name, function(s)
						text(2, SH - 1, s, WHITE, BLACK, SW - 2)
					end)
					note = msg or err
				end
			end
			if sel < 1 then sel = 1 end
		end
	end
end

------------------------------------------------------------------ запуск

local ok, err = pcall(function()
	if rest[1] then
		local f, p = find(rest[1])
		if not f then error("не найден " .. rest[1], 0) end
		f:close()
		local v, e = probe(p, true)
		if not v then error(e, 0) end
		local _, msg = play(v)
		if msg then error(msg, 0) end
	else
		menu()
	end
end)

gfx.restorePalette(gpu, savedPal)
gpu.setResolution(gpu.maxResolution())
gpu.setBackground(0x000000)
gpu.setForeground(0xFFFFFF)
require("term").clear()
if not ok then io.stderr:write(tostring(err) .. "\n") end
