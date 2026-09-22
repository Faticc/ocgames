-- Установка и обновление игр из репозитория, одной командой:
--
--   wget -f https://raw.githubusercontent.com/Faticc/ocgames/main/install.lua /tmp/g.lua && /tmp/g.lua
--
-- Дальше обновляться - просто "games-update": установщик кладёт себя в
-- каталог игр и помнит, откуда ставил.
--
--   --repo=владелец/репо   откуда качать (по умолчанию Faticc/ocgames)
--   --branch=ветка         ветка (main)
--   --dir=подкаталог       если файлы лежат не в корне репозитория,
--                          а, скажем, в games/ - укажи --dir=games
--   --to=/home/games       куда ставить
--   --dry                  только показать, что изменится, ничего не трогая
--   --force                скачать всё заново, даже совпадающее
--   --rehash               пересчитать хэши своих файлов, не веря записанным
--
-- Как обновляет. В manifest.lua у каждого файла записаны размер и CRC32
-- (их проставляет tools/genmanifest.py). Установщик сверяет их со своими
-- файлами и качает только то, что отличается или чего нет. Скачанное
-- ложится сначала в .part и заменяет старый файл, только если размер и
-- хэш сошлись, - оборванная загрузка рабочую игру не портит. Качается не
-- по имени ветки, а по хэшу коммита (ветка превращается в него запросом к
-- api.github.com): raw.githubusercontent держит ветку в кэше до пяти минут
-- и сразу после публикации отдал бы старый манифест. Файлы и
-- ярлыки, которые ставил он сам, а в манифесте их больше нет, удаляются;
-- чужое в каталоге не трогается. Что и с каким хэшем стоит, записано в
-- <каталог>/.installed - по нему же видно, что пересчитывать 1.3 МБ
-- ролика при каждом обновлении незачем.

local component = require("component")
local computer = require("computer")
local shell = require("shell")
local fs = require("filesystem")

local _, opts = shell.parse(...)
local DRY    = opts.dry and true or false
local FORCE  = opts.force and true or false
local REHASH = opts.rehash and true or false
local STATE_NAME = ".installed"

local function die(s) io.stderr:write(s .. "\n") os.exit(1) end

-- CRC32 --------------------------------------------------------------------

--- Процессор бывает и на Lua 5.3 (операторы & ~ >>), и на 5.2 (bit32):
--- код под 5.3 в 5.2 даже не разберётся, поэтому он собирается через load.
local crc32
do
	local f = load([[
		local T = {}
		for i = 0, 255 do
			local c = i
			for _ = 1, 8 do
				if c & 1 == 1 then c = 0xEDB88320 ~ (c >> 1) else c = c >> 1 end
			end
			T[i] = c
		end
		local byte = string.byte
		return function(crc, s)
			crc = ~crc & 0xFFFFFFFF
			for i = 1, #s do crc = T[(crc ~ byte(s, i)) & 0xFF] ~ (crc >> 8) end
			return ~crc & 0xFFFFFFFF
		end]])
	if f then
		crc32 = f()
	elseif bit32 then
		local band, bxor, rshift, bnot = bit32.band, bit32.bxor, bit32.rshift, bit32.bnot
		local T = {}
		for i = 0, 255 do
			local c = i
			for _ = 1, 8 do
				if band(c, 1) == 1 then c = bxor(0xEDB88320, rshift(c, 1)) else c = rshift(c, 1) end
			end
			T[i] = c
		end
		local byte = string.byte
		crc32 = function(crc, s)
			crc = bnot(crc)
			for i = 1, #s do crc = bxor(T[band(bxor(crc, byte(s, i)), 0xFF)], rshift(crc, 8)) end
			return bnot(crc)
		end
	else
		die("нет ни битовых операций, ни bit32 - хэш считать нечем")
	end
end

local function hex(crc) return ("%08x"):format(crc) end

--- Машина, которая слишком долго не уступает управление, падает, а хэш
--- мегабайтного ролика - это долго. Поэтому время от времени отдаём тик.
local lastYield = computer.uptime()
local function breathe()
	if computer.uptime() - lastYield > 1 then
		os.sleep(0)
		lastYield = computer.uptime()
	end
end

--- Хэш файла на диске.
local function hashFile(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local crc, n = 0, 0
	while true do
		local s = f:read(16384)
		if not s then break end
		crc, n = crc32(crc, s), n + #s
		breathe()
	end
	f:close()
	return hex(crc), n
end

-- Состояние установки -------------------------------------------------------

--- Что писать в .installed: только строки, числа, булевы и таблицы.
local function serialize(v, ind)
	ind = ind or ""
	local t = type(v)
	if t == "string" then return ("%q"):format(v)
	elseif t == "number" or t == "boolean" then return tostring(v)
	elseif t ~= "table" then return "nil" end
	local keys = {}
	for k in pairs(v) do keys[#keys + 1] = k end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	local out, ind2 = { "{\n" }, ind .. "\t"
	for _, k in ipairs(keys) do
		local key = type(k) == "string" and k:match("^[%a_][%w_]*$") and k or ("[" .. serialize(k) .. "]")
		out[#out + 1] = ind2 .. key .. " = " .. serialize(v[k], ind2) .. ",\n"
	end
	out[#out + 1] = ind .. "}"
	return table.concat(out)
end

local function readState(dir)
	local f = io.open(dir .. "/" .. STATE_NAME, "r")
	if not f then return nil end
	local src = f:read("*a")
	f:close()
	local chunk = load("return " .. src, "=" .. STATE_NAME, "t", {})
	local ok, st = pcall(chunk or error)
	return ok and type(st) == "table" and st or nil
end

local function writeState(dir, st)
	local f = io.open(dir .. "/" .. STATE_NAME, "w")
	if not f then return false end
	f:write(serialize(st), "\n")
	f:close()
	return true
end

--- Откуда запущен установщик: если из каталога игр (ярлык games-update),
--- то и ставить туда же, и репозиторий брать тот же.
local function selfDir()
	local ok, info = pcall(function() return require("process").info() end)
	local path = ok and info and info.path
	return path and path:match("^(.*)/[^/]*$")
end

local TO0 = opts.to and opts.to:gsub("/+$", "")
if not TO0 then
	local d = selfDir()
	TO0 = (d and fs.exists(d .. "/" .. STATE_NAME)) and d or "/home/games"
end
local old = readState(TO0) or {}

local REPO   = opts.repo or old.repo or "Faticc/ocgames"
local BRANCH = opts.branch or old.branch or "main"
local DIR    = opts.dir or old.dir or ""
local SUB    = DIR ~= "" and (DIR:gsub("/+$", "") .. "/") or ""

-- Сеть ---------------------------------------------------------------------

if not component.isAvailable("internet") then die("нужна интернет-карта") end
local internet = require("internet")

-- raw.githubusercontent.com держит файлы в кэше до пяти минут (max-age=300):
-- сразу после публикации по имени ветки может прийти старый манифест, и
-- обновление скажет "всё свежее". Адрес с хэшем коммита кэш устаревшим не
-- отдаст, поэтому ветка сначала превращается в хэш. Не вышло (лимит API,
-- нет сети до api.github.com) - качаем по имени ветки, как раньше.
-- Так же устроен update в самой DwOS.
local REF = BRANCH
do
	local ok, h = pcall(internet.request,
		("https://api.github.com/repos/%s/commits/%s"):format(REPO, BRANCH), nil,
		{ ["user-agent"] = "ocgames", ["accept"] = "application/vnd.github.sha" })
	if ok and h then
		local body = {}
		pcall(function() for chunk in h do body[#body + 1] = chunk end end)
		pcall(h.close)
		local sha = table.concat(body):match("^%s*(%x+)%s*$")
		if sha and #sha == 40 then REF = sha end
	end
end

--- Открыть поток и дождаться кода ответа. 404 отличаем от обрыва связи:
--- необязательные файлы (ролики к video) на него не жалуются.
local function open(path)
	local url = ("https://raw.githubusercontent.com/%s/%s/%s%s"):format(REPO, REF, SUB, path)
	local ok, h = pcall(internet.request, url, nil, { ["user-agent"] = "ocgames" })
	if not ok then return nil, tostring(h) end
	local code
	for _ = 1, 200 do
		code = h.response()
		if code then break end
		os.sleep(0.05)
	end
	if code and code ~= 200 then pcall(h.close) return nil, "HTTP " .. code, code end
	return h
end

--- Скачать файл целиком - так читается только manifest.lua.
local function fetch(path)
	local h, why = open(path)
	if not h then return nil, why end
	local parts = {}
	local got, err = pcall(function()
		for chunk in h do parts[#parts + 1] = chunk end
	end)
	pcall(h.close)
	if not got then return nil, tostring(err) end
	return table.concat(parts)
end

local function mkdir(path)
	local dir = path:match("^(.*)/[^/]*$")
	if dir and dir ~= "" and not fs.exists(dir) then fs.makeDirectory(dir) end
end

--- Скачать прямо в файл, не собирая его в памяти (ролик весит больше
--- мегабайта), и заодно посчитать хэш. Возвращает размер и хэш.
local function download(path, to)
	local h, why, code = open(path)
	if not h then return nil, why, code end
	mkdir(to)
	local f, werr = io.open(to, "wb")
	if not f then pcall(h.close) return nil, tostring(werr) end
	local n, crc = 0, 0
	local got, err = pcall(function()
		for chunk in h do
			f:write(chunk)
			n, crc = n + #chunk, crc32(crc, chunk)
			breathe()
		end
	end)
	f:close()
	pcall(h.close)
	if not got then return nil, tostring(err) end
	return n, hex(crc)
end

--- Скачать в .part, сверить с манифестом и только тогда подменить файл.
--- Два раза пробуем: raw.githubusercontent иногда рвёт длинные ответы.
local function install(f, to)
	local part = to .. ".part"
	local lastErr
	for try = 1, 2 do
		local n, crc, code = download(f[1], part)
		if not n then
			fs.remove(part)
			if code == 404 then return nil, crc, 404 end
			lastErr = crc
		elseif (f.size and n ~= f.size) or (f.crc and crc ~= f.crc) then
			fs.remove(part)
			lastErr = ("пришло %d Б с хэшем %s, а ждали %s Б с хэшем %s"):format(
				n, crc, tostring(f.size), tostring(f.crc))
		else
			if fs.exists(to) then fs.remove(to) end
			local ok, rerr = fs.rename(part, to)
			if not ok then fs.remove(part) return nil, "не переименовать .part: " .. tostring(rerr) end
			return n, crc
		end
		if try == 1 then print("   повтор: " .. tostring(lastErr)) end
	end
	return nil, lastErr
end

-- Манифест ------------------------------------------------------------------

print(("Игры: %s@%s%s%s"):format(REPO, BRANCH,
	REF ~= BRANCH and (" (" .. REF:sub(1, 7) .. ")") or "",
	SUB ~= "" and (" /" .. SUB) or ""))

local src, why = fetch("manifest.lua")
if not src then die("manifest.lua: " .. tostring(why)) end
local mchunk, perr = load("return " .. src, "=manifest", "t", {})
if not mchunk then die("manifest.lua не читается: " .. tostring(perr)) end
local manifest = mchunk()
local TO = (opts.to or (old.files and TO0) or manifest.dir or TO0):gsub("/+$", "")
if TO ~= TO0 then old = readState(TO) or {} end
print("Каталог: " .. TO .. (DRY and "   (проба, ничего не меняю)" or ""))

-- Железо проверяем до установки: играть на однобитном экране не выйдет
do
	local gpu = component.isAvailable("gpu") and component.gpu
	if not gpu then die("нужна видеокарта") end
	local w, h = gpu.maxResolution()
	if w < 160 or h < 50 then
		print(("  внимание: экран %dx%d, а играм нужно 160x50 - поставь"):format(w, h))
		print("  видеокарту и монитор 3 уровня, иначе картинка обрежется")
	end
	if gpu.getDepth and gpu.getDepth() < 4 then
		print("  внимание: видеокарта 1 уровня - цветов не будет")
	end
	if not gpu.allocateBuffer then
		print("  внимание: видеопамяти нет, игры будут рисовать прямо на экран")
	end
end

-- Сверка и загрузка ----------------------------------------------------------

local oldFiles = old.files or {}
local new = {
	repo = REPO, branch = BRANCH, dir = DIR ~= "" and DIR or nil,
	files = {}, bin = {},
}

--- Совпадает ли файл на диске с манифестом. Записанному хэшу верим, если
--- размер и время изменения те же, что и при записи, - иначе считаем.
local function upToDate(f, to)
	if FORCE or not fs.exists(to) or fs.isDirectory(to) then return false end
	if not f.crc then return false end   -- манифест без хэшей: качаем всё, как раньше
	local size, mtime = fs.size(to), fs.lastModified(to)
	if f.size and size ~= f.size then return false end
	local rec = oldFiles[f[2]]
	local crc
	if not REHASH and rec and rec.crc and rec.size == size and rec.mtime == mtime then
		crc = rec.crc
	else
		crc = hashFile(to)
	end
	if crc == f.crc then
		new.files[f[2]] = { size = size, crc = crc, mtime = mtime }
		return true
	end
	return false
end

local got, same, fresh, gone = 0, 0, 0, 0
local wanted = {}
for _, f in ipairs(manifest.files) do
	local to = TO .. "/" .. f[2]
	wanted[f[2]] = true
	io.write(("  %-16s "):format(f[2]))
	if upToDate(f, to) then
		same = same + 1
		print("не изменился")
	elseif DRY then
		print(fs.exists(to) and "обновится" or "скачается")
	else
		local had = fs.exists(to)
		local n, crc, code = install(f, to)
		if n then
			got, fresh = got + n, fresh + 1
			new.files[f[2]] = { size = n, crc = crc, mtime = fs.lastModified(to) }
			print(("%s, %d Б"):format(had and "обновлён" or "скачан", n))
		elseif f.opt and code == 404 then
			-- необязательного файла может не быть в репозитории; это не
			-- повод бросать установку - остальное уже стоит
			print("в репозитории нет, пропускаю")
		else
			print("")
			-- состояние всё равно сохраняем: скачанное до этого проверено
			for k, v in pairs(oldFiles) do
				if not new.files[k] and wanted[k] then new.files[k] = v end
			end
			writeState(TO, new)
			die("не скачался " .. f[1] .. ": " .. tostring(crc))
		end
	end
end

-- То, что ставили прежде, а в манифесте больше нет
for name in pairs(oldFiles) do
	if not wanted[name] then
		local path = TO .. "/" .. name
		if fs.exists(path) then
			print(("  %-16s %s"):format(name, DRY and "удалится" or "удалён - его больше нет в репозитории"))
			if not DRY then fs.remove(path) end
			gone = gone + 1
		end
	end
end

-- Ярлыки: чтобы играть, набрав "mario" из любого каталога ----------------------

local MARK = "-- ярлык на "
local function isOurs(path)
	-- в двоичном режиме: в текстовом read(n) считает буквы, а не байты
	local f = io.open(path, "rb")
	if not f then return false end
	local head = f:read(#MARK)
	f:close()
	return head == MARK
end

local wantedBin = {}
for _, b in ipairs(manifest.bin or {}) do
	wantedBin[b[1]] = true
	local path = "/bin/" .. b[1] .. ".lua"
	-- обновлялке ярлык подсказывает каталог: иначе она не узнает, куда ставили
	local pre = b[2] == "install.lua" and ("table.insert(a, 1, %q)\n"):format("--to=" .. TO) or ""
	local body = ("%s%s/%s\nlocal a = { ... }\n%sreturn assert(loadfile(%q))(table.unpack(a))\n")
		:format(MARK, TO, b[2], pre, TO .. "/" .. b[2])
	local cur
	local fh = io.open(path, "r")
	if fh then cur = fh:read("*a") fh:close() end
	if cur ~= body then
		io.write(("  ярлык %-12s -> %s"):format(b[1], path))
		if DRY then print("   (проба)") else
			-- /bin бывает и на дискете только для чтения: игры уже стоят,
			-- так что это не повод обрывать установку
			mkdir(path)
			local f, werr = io.open(path, "w")
			if f then f:write(body) f:close() print("")
			else print("   не вышло (" .. tostring(werr) .. "), запускай как " .. TO .. "/" .. b[2]) end
		end
	end
	new.bin[#new.bin + 1] = b[1]
end
for _, name in ipairs(old.bin or {}) do
	local path = "/bin/" .. name .. ".lua"
	if not wantedBin[name] and fs.exists(path) and isOurs(path) then
		print(("  ярлык %-12s %s"):format(name, DRY and "удалится" or "удалён"))
		if not DRY then fs.remove(path) end
	end
end

if DRY then
	print(("Проба: без изменений %d, к удалению %d. Ничего не тронуто."):format(same, gone))
	return
end
if not writeState(TO, new) then print("  внимание: не записать " .. TO .. "/" .. STATE_NAME) end

if fresh == 0 and gone == 0 then
	print(("Всё свежее, файлов: %d."):format(same))
else
	print(("Готово: скачано %d (%d Б), без изменений %d, удалено %d."):format(fresh, got, same, gone))
end
print("  mario        - платформер: стрелки, вверх - прыжок, X - бег и огонь")
print("  doom         - шутер: стрелки, A/D - вбок, пробел - огонь, E - открыть")
print("  chip8        - эмулятор CHIP-8: 1234/QWER/ASDF/ZXCV, Q - выход")
print("  video        - ролики: меню, пробел - пауза, стрелки - перемотка, Q - назад")
print("  games-update - обновить игры")
