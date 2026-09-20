-- badapple - проигрыватель роликов BAPL для DwOS. Внутри Bad
-- Apple!!: 4379 кадров 130x98 точек, три с половиной минуты, 1.3 МБ.
--
--   badapple [файл.bin] [--loop] [--from=1:30] [--free] [--mute]
--   badapple --writetape=badapple.dfpwm    - записать звук на кассету
--
-- Почему это вообще идёт на игровой машине. Экран OC - символы, а не
-- точки: нижний полублок U+2584 делит ячейку пополам, и при двух цветах
-- у ячейки всего четыре состояния (см. lib/gfx.lua). Значит весь ролик - это
-- поле 130x49 ячеек, которое двадцать раз в секунду меняет состояния.
--
-- Разжимать картинку и сравнивать её с предыдущей на Lua было бы дорого,
-- поэтому в файле лежат не пиксели, а уже готовые вызовы gpu.set: отрезки
-- ячеек, которые в этом кадре надо перекрасить, разложенные по цветам.
-- Диффом кадров и склейкой отрезков занят упаковщик на большом компьютере
-- (tools/packbadapple.py), а здесь остаётся прочитать три сотни байт и
-- сделать сотню вызовов в холст lib/gfx. Вызовы к видеопамяти бюджет
-- машины не тратят, а на экран холст сам решает, как кадр положить:
-- изменений мало - повторит их прямо там, много - сделает bitblt.
--
-- Перемотка идёт по ключевым кадрам: их смещения лежат в заголовке, файл
-- перематывается seek-ом, и от ключевого кадра доигрывается остаток.
--
-- Звук в ролике не лежит и лежать не может: кадр стоит пару сотен байт, а
-- секунда звука - четыре тысячи. Его крутит кассетник Computronics
-- (tape_drive): кассета пишется один раз (--writetape, файл к ней готовит
-- tools/packdfpwm.py из mp3 или того же mp4), дальше блок играет её сам, ни
-- байта не спрашивая у машины. Плееру остаётся держать ленту там же, где
-- идёт картинка - при запуске, паузе, перемотке и раз в секунду на сверку.
--
-- Слышно при этом не то место, где лента сейчас: клиент копит буфер
-- (audioPreloadMs, по умолчанию 750 мс) и только потом начинает играть.
-- Отсюда две поправки на один и тот же --sync. Ленту пустили - буфер пуст,
-- играть начнут ровно с того места, куда её поставили, но через sync
-- секунд: значит лента встаёт точно на кадр, а картинка ждёт звук. Лента
-- уже идёт - буфер полон, слышно то, что прочитано sync назад: значит при
-- перемотке лента встаёт на sync впереди кадра, и картинка не ждёт ничего.
-- Не сошлось на глаз - подстрой на ходу клавишами [ и ].
--
-- Управление: пробел - пауза, стрелки - перемотка на 5 секунд, R - сначала,
-- M - звук, [ и ] - подстройка звука, - и = - громкость, Q - выход.
--
-- --free гонит кадры без оглядки на часы - так видно, сколько их машина
-- вытягивает на самом деле; обычно же плеер держит те 20 к/с, под которые
-- упакован ролик, а не успевая - пропускает вывод кадра, но не его разбор.

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
-- gfx у DwOS системный и уже лежит в package.loaded: холст, журнал вывода
-- и выбор между повтором и bitblt берутся готовыми, а не пишутся здесь
-- ещё раз.
local gfx = require("gfx")
local gpu = component.gpu

local floor, rep, uptime = math.floor, string.rep, computer.uptime
local BLOCK = "\226\150\132"   -- U+2584, нижний полублок

local function mmss(sec)
	sec = floor(sec)
	return ("%d:%02d"):format(floor(sec / 60), sec % 60)
end

------------------------------------------------------------------ файл

--- Каталог самой игры: ролик лежит рядом с ней, а ярлык из /bin зовёт её
--- из любого места. Имя чанка знает путь в обоих случаях.
local function selfdir()
	for i = 1, 4 do
		local d = debug.getinfo(i, "S")
		local p = d and d.source and d.source:match("^[=@]?(.*)/[^/]*%.lua$")
		if p and p ~= "" then return p end
	end
	return "/home/games"
end

--- Ролик: по имени, как дано, а если это просто имя - рядом с игрой.
local function find(name)
	if name:find("/") then
		local f = io.open(name, "rb")
		return f, name
	end
	local p = selfdir() .. "/" .. name
	local f = io.open(p, "rb")
	if f then return f, p end
	f = io.open(name, "rb")
	return f, name
end

--- read даёт не больше maxReadBuffer за раз (в конфиге сервера это 2 КБ),
--- поэтому добираем нужное в цикле.
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

------------------------------------------------------------------ звук

-- Кассетник держит DFPWM: один бит на отсчёт, 32768 отсчётов в секунду -
-- ровно 4096 байт на секунду звука. В бюджет машины он не лезет вовсе, но
-- вызовы к нему разные: даровые (прямые) у него только getPosition, getSize
-- и isReady, а seek, play и stop стоят тика, то есть кадра. Отсюда и
-- обращение с лентой: трогаем её на паузе, перемотке и раз в секунду на
-- сверку, а не каждый кадр.
local TAPE_BPS = 4096

local tape, emptyDrive
for addr in component.list("tape_drive") do
	local t = component.proxy(addr)
	local ok, ready = pcall(t.isReady)
	if ok and ready then tape = t break end
	emptyDrive = true
end

local snd = {
	on = tape ~= nil and not opt.mute,
	vol = math.min(1, math.max(0, tonumber(opt.volume) or 1)),
	sync = tonumber(opt.sync) or 0.75,
	size = 0,
}
if tape then
	local ok, sz = pcall(tape.getSize)
	snd.size = ok and sz or 0
end

--- Лента на такую-то секунду звука.
local function tapeTo(sec)
	local want = floor(sec * TAPE_BPS)
	if want < 0 then want = 0 elseif want > snd.size then want = snd.size end
	local ok, pos = pcall(tape.getPosition)
	if ok and want ~= pos then pcall(tape.seek, want - pos) end
end

--- Идущую ленту - на sync впереди кадра: слышно то, что прочитано буфер
--- назад.
local function sndSeek(sec)
	if snd.on then tapeTo(sec + snd.sync) end
end

--- Пустить остановленную ленту с этого кадра. Играть с него начнут через
--- sync секунд - столько набирается буфер, - поэтому ровно столько ждёт и
--- картинка; сколько ждать, узнаёт вызвавший.
local function sndPlay(sec)
	if not snd.on then return 0 end
	tapeTo(sec)
	pcall(tape.play)
	return snd.sync > 0 and snd.sync or 0
end

local function sndStop()
	if tape then pcall(tape.stop) end
end

--- Сверка. Само сравнение бесплатное, поправка стоит тика и слышна
--- щелчком, поэтому порог не мелкий: разойтись они могут только если
--- машина или мир подвисли. Доигранную до конца ленту не трогаем - иначе
--- она будет дёргаться раз в секунду до конца ролика.
local function sndCheck(sec)
	if not snd.on then return end
	local ok, pos = pcall(tape.getPosition)
	if not ok or pos >= snd.size then return end
	local d = pos / TAPE_BPS - snd.sync - sec
	if d > 0.25 or d < -0.25 then sndSeek(sec) end
end

--- Запись кассеты - дело разовое: дальше она помнит звук сама. Пишем
--- большими кусками, потому что тика стоит каждый write, а не каждый байт:
--- на 877 КБ разница между двумя килобайтами за вызов и восемью - это
--- полминуты ожидания.
local function writetape(name)
	if not tape then
		io.stderr:write(emptyDrive and "в кассетнике нет кассеты\n"
			or "кассетника не видно - поставь tape drive рядом с компьютером\n")
		os.exit(1)
	end
	local f, p = find(name)
	if not f then
		io.stderr:write("не найден " .. name .. "\n")
		io.stderr:write("сделать из mp3 или mp4: python tools/packdfpwm.py звук.mp3 -o badapple.dfpwm\n")
		os.exit(1)
	end
	local len = f:seek("end") or 0
	f:seek("set", 0)
	print(("%s: %d КБ, %s звука"):format(p, floor(len / 1024), mmss(len / TAPE_BPS)))
	print(("кассета: %d КБ, %s"):format(floor(snd.size / 1024), mmss(snd.size / TAPE_BPS)))
	if len > snd.size then print("кассета короче - запишу, сколько влезет") end
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
		io.write(("\rзаписано %3d%%"):format(floor(done / len * 100)))
		if wrote < #chunk then break end            -- лента кончилась
	end
	f:close()
	pcall(tape.setLabel, "Bad Apple!!")
	pcall(tape.seek, -tape.getPosition())
	print(("\rзаписано %d КБ - %s звука"):format(floor(done / 1024), mmss(done / TAPE_BPS)))
end

if opt.writetape then
	writetape(opt.writetape == true and "badapple.dfpwm" or tostring(opt.writetape))
	os.exit(0)
end

------------------------------------------------------------------ ролик

local NAME = rest[1] or "badapple.bin"
local fh, path = find(NAME)
if not fh then
	io.stderr:write("не найден " .. NAME .. " - положи его рядом с badapple.lua\n")
	io.stderr:write("скачать: wget -f <ссылка> /home/games/badapple.bin\n")
	os.exit(1)
end

local function u16(s, i) return s:byte(i) + s:byte(i + 1) * 256 end
local function u32(s, i)
	return s:byte(i) + s:byte(i + 1) * 256 + s:byte(i + 2) * 65536 + s:byte(i + 3) * 16777216
end

local head = readn(fh, 16)
if #head < 16 or head:sub(1, 4) ~= "BAPL" or head:byte(5) ~= 1 then
	io.stderr:write(path .. " - это не ролик BAPL первой версии\n")
	os.exit(1)
end

local PW, PH      = u16(head, 6), u16(head, 8)     -- поле в точках
local FPS         = u16(head, 10) / 100
local NFRAMES     = u32(head, 12)
local COLORS      = head:byte(16)
local CW, CH      = PW, PH / 2                     -- ... оно же в ячейках
local NSTATES     = COLORS * COLORS

local pal = {}
do
	local rgb = readn(fh, COLORS * 3)
	for i = 0, COLORS - 1 do
		pal[i] = rgb:byte(i * 3 + 1) * 65536 + rgb:byte(i * 3 + 2) * 256 + rgb:byte(i * 3 + 3)
	end
end

local KEYINT, NKEYS
do
	local t = readn(fh, 6)
	KEYINT, NKEYS = u16(t, 1), u32(t, 3)
end
local KEYS = {}
do
	local t = readn(fh, NKEYS * 4)
	for i = 1, NKEYS do KEYS[i] = u32(t, (i - 1) * 4 + 1) end
end

do
	local mw, mh = gpu.maxResolution()
	if mw < CW or mh < CH + 1 then
		io.stderr:write(("ролик %dx%d ячеек, а экран %dx%d - нужен монитор побольше\n")
			:format(CW, CH + 1, mw, mh))
		os.exit(1)
	end
end

------------------------------------------------------------------ чтение потока

-- Поток читается кусками и разбирается по месту: кадр - это сотня-другая
-- чисел переменной длины, копить его целиком незачем.
local buf, bp, eof = "", 1, false
local CHUNK = 2048

local function refill()
	if bp > 1 then buf = buf:sub(bp) bp = 1 end
	while #buf < CHUNK and not eof do
		local c = fh:read(CHUNK)
		if not c or #c == 0 then eof = true break end
		buf = buf .. c
	end
end

--- Число переменной длины: по семь бит на байт, старший бит - "дальше есть".
--- Без побитовых операций - они появились только в Lua 5.3.
local function rdv()
	local n, mul = 0, 1
	while true do
		if bp > #buf then
			refill()
			if bp > #buf then return n end
		end
		local b = buf:byte(bp)
		bp = bp + 1
		if b < 128 then return n + b * mul end
		n = n + (b - 128) * mul
		mul = mul * 128
	end
end

------------------------------------------------------------------ экран

local SW, SH = 160, 50
do
	local mw, mh = gpu.maxResolution()
	SW, SH = math.min(SW, mw), math.min(SH, mh)
	-- setResolution - вызов не direct, то есть целый тик; если экран и так
	-- нужного размера, тратить его не на что
	local cw, ch = gpu.getResolution()
	if cw ~= SW or ch ~= SH then gpu.setResolution(SW, SH) end
end

local X0 = floor((SW - CW) / 2) + 1        -- левый верхний угол ролика
local Y0 = floor((SH - 1 - CH) / 2) + 1    -- нижняя строка - под состояние
local BAR = SH                             -- строка состояния

-- своя палитра на время ролика, старая вернётся при выходе
local saved = gfx.savePalette(gpu)
gfx.restorePalette(gpu, pal)               -- поставить свою: та же работа

-- Холст на весь экран: вывод копится в видеопамяти, а present сам решает,
-- повторить изменения прямо на экране (в этом ролике их обычно мало) или
-- положить кадр одним bitblt. Без видеопамяти холст рисует прямо на
-- экран - те же вызовы, но каждый стоит бюджета машины.
local scr = gfx.surface(gpu, { palette = true })

-- Цвета строки состояния. Холст работает индексами палитры, а ролику их
-- нужно всего два-четыре, поэтому серый для строки кладётся в свободный
-- конец палитры; занял ролик все шестнадцать - возьмём, что есть.
local BARFG, BARBG = 15, 0
if COLORS <= BARFG then pcall(gpu.setPaletteColor, BARFG, 0x999999) end

-- Строки повторов режутся не каждый раз: длин всего сотня, а строится
-- каждая один раз за ролик.
local sp, bl = {}, {}
local function runstr(cache, ch, n)
	local s = cache[n]
	if not s then s = rep(ch, n) cache[n] = s end
	return s
end

-- Что означает каждое состояние ячейки: цвет фона, цвет символа и сам
-- символ. Одинаковые половинки - это просто пробел на фоне, и тогда цвет
-- символа менять не нужно вовсе.
local ST = {}
for s = 0, NSTATES - 1 do
	local top, bot = floor(s / COLORS), s % COLORS
	ST[s] = { top = top, bot = bot, solid = top == bot }
end

------------------------------------------------------------------ кадр

--- Разобрать и нарисовать один кадр. Отрезки лежат разложенными по
--- состояниям, поэтому цвет ставится один раз на состояние, а не на
--- каждый вызов gpu.set: холст сам не переставляет то, что уже стоит.
local function drawFrame()
	for s = 0, NSTATES - 1 do
		local n = rdv()
		if n > 0 then
			local st = ST[s]
			local top, bot = st.top, st.bot
			local cache, ch = sp, " "
			-- у сплошной ячейки виден только фон: цвет символа не трогаем
			if not st.solid then cache, ch = bl, BLOCK else bot = nil end
			local p = 0
			for _ = 1, n do
				p = p + rdv()
				local len = rdv()
				local row = floor(p / CW)
				scr:set(X0 + p - row * CW, Y0 + row, runstr(cache, ch, len), bot, top)
				p = p + len
			end
		end
	end
end

local function present() scr:present() end

--- Перемотка: ближайший ключевой кадр не позже нужного, seek на его
--- смещение - и доиграть остаток вслепую, не выводя на экран.
local function seek(n)
	if n < 0 then n = 0 end
	if n >= NFRAMES then n = NFRAMES - 1 end
	local ki = KEYINT > 0 and floor(n / KEYINT) or 0
	if ki + 1 > NKEYS then ki = NKEYS - 1 end
	fh:seek("set", KEYS[ki + 1])
	buf, bp, eof = "", 1, false
	local at = ki * KEYINT
	while at < n do drawFrame() at = at + 1 end
	return at
end

------------------------------------------------------------------ состояние

local FREE = opt.free and true or false
local cur = 0              -- следующий кадр к показу
local skips = 0            -- пропущено подряд
local paused = false
local running = true
local dropped = 0
local shownFps = 0

local barText, barAt
local function drawBar()
	-- строка состояния живёт своей жизнью: собирать её каждый кадр -
	-- лишний мусор на ровном месте, четыре раза в секунду хватает
	local at = floor(cur * 4 / FPS)
	if at == barAt and barText then return end
	barAt = at
	local n = 30
	local full = floor(cur / NFRAMES * n + 0.5)
	-- про звук в строке - только то, чего не слышно: включён ли он вообще
	-- и на сколько лента уведена от кадра
	local sound = ""
	if snd.on then sound = ("  лента %+.2f"):format(snd.sync)
	elseif tape then sound = "  звук выкл"
	elseif emptyDrive then sound = "  нет кассеты"
	end
	local s = ("%s %s / %s  [%s%s]  %.0f к/с%s%s   пробел - пауза, стрелки - перемотка, R - сначала%s, Q - выход")
		:format(paused and "||" or ">", mmss(cur / FPS), mmss(NFRAMES / FPS),
			rep("#", full), rep("-", n - full), shownFps,
			dropped > 0 and ("  пропущено %d"):format(dropped) or "", sound,
			tape and ", M - звук" or "")
	if s == barText then return end
	barText = s
	local len = unicode.len(s)
	if len > SW then s = unicode.sub(s, 1, SW) len = SW end
	-- строка состояния - такой же вывод на холст, только цвета у неё не
	-- из палитры ролика: серым по чёрному
	scr:set(1, BAR, s .. rep(" ", SW - len), BARFG, BARBG)
end

------------------------------------------------------------------ клавиши

local pending = {}

local function handleKey(name, _, _, code)
	if name ~= "key_down" then return true end
	pending[#pending + 1] = code
	return true
end

event.listen("key_down", handleKey)

--- Отдать управление системе: за это время система разберёт очередь и
--- вызовет handleKey. Таймаут обязательно ненулевой - с нулевым
--- сигналы не отдаёт, и игра остаётся глухой (см. mario.lua).
local function pump(timeout)
	local e, _, _, code = event.pull(timeout or 0.01)
	if e == "interrupted" then running = false
	elseif e == "key_down" then
		-- подстраховка на случай, если подписка не сработала
		if pending[#pending] ~= code then pending[#pending + 1] = code end
	end
end

local jump          -- насколько перемотать, решает главный цикл
local resumed       -- с паузы сняли: ленту пускает тоже главный цикл
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

------------------------------------------------------------------ показ

local ok, err = pcall(function()
	-- поля вокруг ролика заливаются один раз: дальше кадры меняют только
	-- то, что внутри
	scr:fill(1, 1, SW, SH, " ", BARFG, BARBG)
	scr:present()

	if opt.from then
		local m, s = tostring(opt.from):match("^(%d+):(%d+)$")
		local sec = m and (tonumber(m) * 60 + tonumber(s)) or tonumber(opt.from) or 0
		cur = seek(floor(sec * FPS))
	end

	if snd.on then pcall(tape.setVolume, snd.vol) end

	-- время, от которого идёт отсчёт: сдвинуто на то, сколько картинка
	-- ждёт звук (без звука - ноль, и отсчёт идёт от сейчас)
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
			-- на паузе лента стоит: её поставит на место снятие с паузы
			if not paused then sndSeek(cur / FPS) sndT = uptime() end
			present()          -- на паузе кадр иначе не сменится
		end

		if paused then
			drawBar()
			pump(0.05)
			base = uptime() - cur / FPS
		else
			if cur >= NFRAMES then
				if opt.loop then
					cur = seek(0)
					sndStop()
					base = uptime() + sndPlay(0)
					sndT = uptime()
				else running = false end
			else
				drawFrame()
				cur = cur + 1
				-- отстаём - кадр всё равно разобран (иначе следующий не
				-- соберётся), но на экран его не кладём: bitblt тут самое
				-- дорогое, и пропуск даёт догнать ролик
				local due = base + cur / FPS
				local now = uptime()
				if not FREE and now > due + 2 / FPS and skips < 2 then
					dropped = dropped + 1
					skips = skips + 1
				else
					-- подряд больше двух кадров не пропускаем: машине,
					-- которая не тянет 20 к/с, лучше показать ролик
					-- медленнее, чем чёрный экран, поэтому заодно
					-- сдвигаем и отсчёт времени
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
	end
end)

------------------------------------------------------------------ уборка

event.ignore("key_down", handleKey)
sndStop()
scr:close()
gfx.restorePalette(gpu, saved)
gpu.setResolution(gpu.maxResolution())
gpu.setBackground(0x000000)
gpu.setForeground(0xFFFFFF)
require("term").clear()
if not ok then error(err, 0) end
