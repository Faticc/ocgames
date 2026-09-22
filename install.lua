-- Установка и обновление игр из репозитория, одной командой:
--
--   wget -f https://raw.githubusercontent.com/Faticc/ocgames/main/install.lua /tmp/g.lua && /tmp/g.lua
--
-- Дальше обновляться - просто "games-update": установщик кладёт себя в
-- каталог игр и помнит, откуда ставил.
--
-- Что ставить, выбирается списком (окно checklist из установщика DwOS):
-- каждая игра, каждый ролик и звук к нему отмечаются отдельно, и у каждой
-- строки свой диск - стрелками влево-вправо. Игры ложатся в папку games
-- диска (на системном - /home/games), ролики - в videos (/home/videos).
-- Уже стоящее отмечено и стоит на своём диске: снял отметку - удалится,
-- сменил диск - переедет. Предложенное и не взятое в следующий раз
-- отмеченным не придёт; новое в репозитории помечено "новое".
--
--   --repo=владелец/репо   откуда качать (по умолчанию Faticc/ocgames)
--   --branch=ветка         ветка (main)
--   --dir=подкаталог       если файлы лежат не в корне репозитория,
--                          а, скажем, в games/ - укажи --dir=games
--   --to=/home/games       где живёт сам установщик (и игры по умолчанию)
--   --dry                  только показать, что изменится, ничего не трогая
--   --force                скачать всё заново, даже совпадающее
--   --rehash               пересчитать хэши своих файлов, не веря записанным
--   --yes                  без списка: взять то, что отмечено по умолчанию
--   --all                  без списка: всё, включая ролики
--   --only=mario,badapple  без списка: только это (игры, ролики по имени)
--   --disk=адрес|путь      куда класть новое без списка
--   --text                 список текстом, а не окном
--
-- Как обновляет. В manifest.lua у каждого файла записаны размер и CRC32
-- (их проставляет tools/genmanifest.py). Установщик сверяет их со своими
-- файлами и качает только то, что отличается или чего нет. Скачанное
-- ложится сначала в .part и заменяет старый файл, только если размер и
-- хэш сошлись, - оборванная загрузка рабочую игру не портит. Качается не
-- по имени ветки, а по хэшу коммита (ветка превращается в него запросом к
-- api.github.com): raw.githubusercontent держит ветку в кэше до пяти минут
-- и сразу после публикации отдал бы старый манифест. Что и где стоит,
-- записано в <каталог установщика>/.installed - по нему же видно, что
-- пересчитывать мегабайты роликов при каждом обновлении незачем.

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

-- Ролики лежат в репозитории сжатыми (gz у записи манифеста): GitHub
-- двоичное сам не сжимает, а интернет-карта платит тиком за каждые 2 КБ.
-- Распаковывает inflate из DwOS; под OpenOS его нет - тогда тот же файл
-- берётся из репозитория DwOS, в память.
local inflate
local function getInflate()
	if inflate ~= nil then return inflate end
	inflate = false
	local ok, m = pcall(require, "inflate")
	if ok and type(m) == "table" then inflate = m return inflate end
	local rok, h = pcall(internet.request,
		"https://raw.githubusercontent.com/Faticc/dwos/main/dist/lib/inflate.lua", nil, { ["user-agent"] = "ocgames" })
	if rok and h then
		local parts = {}
		pcall(function() for chunk in h do parts[#parts + 1] = chunk end end)
		pcall(h.close)
		local chunk = load(table.concat(parts), "=inflate", "t", _G)
		local cok, lib = pcall(chunk or error)
		if cok and type(lib) == "table" then inflate = lib end
	end
	return inflate
end

--- Скачать прямо в файл, не собирая его в памяти (ролик весит больше
--- мегабайта), и заодно посчитать хэш. gz - путь сжатого файла: тогда
--- поток распаковывается на лету. Возвращает размер и хэш.
local function download(path, to, gz)
	local h, why, code = open(path)
	if not h then return nil, why, code end
	mkdir(to)
	local f, werr = io.open(to, "wb")
	if not f then pcall(h.close) return nil, tostring(werr) end
	local n, crc = 0, 0
	local function put(chunk)
		f:write(chunk)
		n, crc = n + #chunk, crc32(crc, chunk)
	end
	local got, err = pcall(function()
		local z = gz and getInflate().new(put, "gzip")
		for chunk in h do
			if z then z:feed(chunk) else put(chunk) end
			breathe()
		end
		if z and not z.done then error("сжатый поток оборвался", 0) end
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
		local gz = f.gz and getInflate() and true
		local n, crc, code = download(gz and f.gz or f[1], part, gz)
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
print("Установщик: " .. TO .. (DRY and "   (проба, ничего не меняю)" or ""))

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

local function mb(n)
	if not n then return "?" end
	if n >= 1048576 then return ("%.1f МБ"):format(n / 1048576) end
	return ("%d КБ"):format(math.floor(n / 1024 + 0.5))
end

local function dirname(p) return p:match("^(.*)/[^/]*$") or "" end

-- Диски ---------------------------------------------------------------------

-- Куда можно писать: по строке на диск. Системный - под своим "/", игры на
-- нём ложатся в /home/games, ролики в /home/videos; остальные - под /mnt,
-- в папки games и videos. Диск, на котором стоит сам установщик, кладёт
-- игры рядом с ним.
local DISKS, HOME = {}, nil
do
	local root = fs.get("/")
	local tmp = computer.tmpAddress and computer.tmpAddress()
	local toDev = fs.get(TO)
	local list = {}
	for dev, path in fs.mounts() do list[#list + 1] = { dev = dev, path = path } end
	table.sort(list, function(a, b)
		if #a.path ~= #b.path then return #a.path < #b.path end
		return a.path < b.path
	end)
	local seen = {}
	for _, m in ipairs(list) do
		local dev, addr = m.dev, m.dev.address
		local isRoot = root and addr == root.address and m.path == "/"
		if not seen[addr] and addr ~= tmp and (isRoot or m.path:match("^/mnt/[^/]+$")) then
			seen[addr] = true
			if not dev.isReadOnly() then
				local label = dev.getLabel()
				local d = {
					addr = addr, path = m.path,
					free = (dev.spaceTotal() or 0) - (dev.spaceUsed() or 0),
					name = isRoot and ((label or "системный") .. " /")
						or ((label and (label .. " ") or "") .. m.path),
					games = isRoot and "/home/games" or (m.path .. "/games"),
					videos = isRoot and "/home/videos" or (m.path .. "/videos"),
				}
				if toDev and toDev.address == addr then
					d.games = TO
					HOME = #DISKS + 1
				end
				DISKS[#DISKS + 1] = d
			end
		end
	end
end
if not HOME then die("каталог " .. TO .. " не на записываемом диске - укажи --to=") end

local function diskOf(path)
	local dev = fs.get(path)
	if not dev then return nil end
	for i, d in ipairs(DISKS) do if d.addr == dev.address then return i end end
end

--- Диск из --disk: адрес (начало), путь монтирования или папка.
local FORCED
if opts.disk then
	for i, d in ipairs(DISKS) do
		if d.addr:find(opts.disk, 1, true) == 1 or d.path == opts.disk
			or d.games == opts.disk or d.videos == opts.disk then FORCED = i end
	end
	if not FORCED then die("диска " .. opts.disk .. " не видно среди записываемых") end
end

-- Что стоит -----------------------------------------------------------------

-- Прежние установщики писали только размер и хэш: файл у них всегда лежал
-- в каталоге установки. Теперь у каждого свой путь.
local oldFiles = {}
for name, rec in pairs(old.files or {}) do
	if type(rec) == "table" then
		rec.path = rec.path or (TO .. "/" .. name)
		oldFiles[name] = rec
	end
end

local function placed(name)
	local rec = oldFiles[name]
	if rec and fs.exists(rec.path) and not fs.isDirectory(rec.path) then return rec end
end

-- Позиции списка ------------------------------------------------------------

-- Часть - файлы с одним pkg; ролик и звук к нему - по отдельности.
local items, byKey = {}, {}
local core = { key = "core", files = {} }
local known = {}             -- все имена файлов манифеста
do
	local pkgs = {}
	for _, p in ipairs(manifest.packages or {}) do
		local it = { key = p[1], text = p[2] .. (p[3] and (" - " .. p[3]) or ""), files = {}, kind = "game" }
		pkgs[p[1]] = it
	end
	local vids = {}
	for _, f in ipairs(manifest.files) do
		known[f[2]] = true
		if f.video then
			vids[#vids + 1] = f
		elseif f.pkg == "core" or not f.pkg then
			core.files[#core.files + 1] = f
		else
			local it = pkgs[f.pkg]
			if not it then
				it = { key = f.pkg, text = f.pkg, files = {}, kind = "game" }
				pkgs[f.pkg] = it
			end
			it.files[#it.files + 1] = f
		end
	end
	for _, f in ipairs(manifest.videos or {}) do
		known[f[2]] = true
		vids[#vids + 1] = f
	end

	items[#items + 1] = { header = true, text = "Игры" }
	local order = {}
	for _, p in ipairs(manifest.packages or {}) do order[#order + 1] = pkgs[p[1]] end
	for k, it in pairs(pkgs) do
		local listed = false
		for _, o in ipairs(order) do if o == it then listed = true end end
		if not listed then order[#order + 1] = it end
	end
	for _, it in ipairs(order) do
		if #it.files > 0 then items[#items + 1] = it end
	end

	-- ролики: название берём у самого ролика, звук подписываем им же
	local titles = {}
	for _, f in ipairs(vids) do
		local base = f[2]:gsub("%.[^.]*$", "")
		if f.title then titles[base] = f.title end
	end
	if #vids > 0 then items[#items + 1] = { header = true, text = "Ролики - в папку videos диска" } end
	for _, f in ipairs(vids) do
		local base, ext = f[2]:match("^(.*)%.([^.]+)$")
		local title = titles[base] or base
		local it = { key = f[2], base = base, files = { f }, kind = "video" }
		if ext == "dfpwm" then
			it.text = title .. " - звук для кассеты"
		else
			it.text = title
			if f.secs then it.secs = ("%d:%02d"):format(math.floor(f.secs / 60), f.secs % 60) end
		end
		items[#items + 1] = it
	end
end

-- что где стоит и что отмечено по умолчанию
local seen = old.seen or {}
local fresh = old.seen == nil
for _, it in ipairs(items) do
	if not it.header then
		byKey[it.key] = it
		it.size = 0
		for _, f in ipairs(it.files) do
			it.size = it.size + (f.size or 0)
			local rec = placed(f[2])
			if rec and not it.dir then
				it.dir = dirname(rec.path)
				it.at = diskOf(rec.path)
			end
		end
		it.sub = (it.secs and (it.secs .. "  ") or "") .. mb(it.size)
		if it.dir then
			it.on = true
		elseif seen[it.key] then
			it.on = false                  -- уже предлагали и не взяли
		else
			it.on = it.kind == "game"      -- новое: игры - да, ролики - по выбору
		end
		it.disk = it.at or FORCED or HOME
		if not fresh and not it.dir and not seen[it.key] then it.sub = "новое  " .. it.sub end
	end
end

-- Выбор ---------------------------------------------------------------------

if opts.all or opts.only then
	local pick = {}
	for w in tostring(opts.only or ""):gmatch("[^,]+") do pick[w] = true end
	for _, it in ipairs(items) do
		if not it.header then
			it.on = opts.all and true or (pick[it.key] or (it.base and pick[it.base])) or false
			if it.on and not it.dir then it.disk = FORCED or HOME end
		end
	end
elseif not DRY and not opts.yes then
	local ui
	local load_ui = loadfile("/lib/core/install_ui.lua", "bt", _G)
	if load_ui then
		local graphic = io.stdin and io.stdin.tty and io.stdout and io.stdout.tty and not opts.text
		local ok, u = pcall(load_ui, graphic)
		if ok and u and u.checklist then ui = u end
	end
	if not ui then
		die("для выбора нужен установщик DwOS со списком (обнови DwOS),\n"
			.. "или скажи без списка: --yes (как отмечено), --all, --only=mario,doom,badapple")
	end
	local r = ui.checklist("Игры и ролики", items, DISKS, {
		prompt = "Отметь, что поставить; стрелками влево-вправо - на какой диск",
	})
	ui.close()
	if not r then print("Отменено, ничего не тронуто.") return end
end

-- Установка -----------------------------------------------------------------

local new = {
	repo = REPO, branch = BRANCH, dir = DIR ~= "" and DIR or nil,
	files = {}, bin = {}, seen = {},
}
for _, it in ipairs(items) do if not it.header then new.seen[it.key] = true end end

--- Совпадает ли стоящий файл с манифестом. Записанному хэшу верим, если
--- размер и время изменения те же, что и при записи, - иначе считаем.
local function upToDate(f, rec)
	if FORCE or not f.crc then return false end
	local size, mtime = fs.size(rec.path), fs.lastModified(rec.path)
	if f.size and size ~= f.size then return false end
	local crc = rec.crc
	if REHASH or rec.size ~= size or rec.mtime ~= mtime then crc = hashFile(rec.path) end
	if crc == f.crc then return true, { path = rec.path, size = size, crc = crc, mtime = mtime } end
	return false
end

local got, same, freshN, gone = 0, 0, 0, 0

--- Отложить состояние и выйти: уже скачанное проверено и должно запомниться.
local function fail(msg)
	for k, v in pairs(oldFiles) do
		if not new.files[k] and known[k] then new.files[k] = v end
	end
	writeState(TO, new)
	die(msg)
end

local function put(f, dir)
	local name = f[2]
	local rec = placed(name)
	local to = dir .. "/" .. name
	io.write(("  %-16s "):format(name))
	if rec and rec.path == to then
		local ok, r = upToDate(f, rec)
		if ok then
			new.files[name] = r
			same = same + 1
			print("не изменился")
			return
		end
	end
	if DRY then
		print(rec and (rec.path == to and "обновится" or ("переедет в " .. dir)) or ("скачается в " .. dir))
		return
	end
	local n, crc, code = install(f, to)
	if n then
		got, freshN = got + n, freshN + 1
		new.files[name] = { path = to, size = n, crc = crc, mtime = fs.lastModified(to) }
		if rec and rec.path ~= to then
			fs.remove(rec.path)
			print(("перенесён в %s, %s"):format(dir, mb(n)))
		else
			print(("%s, %s%s"):format(rec and "обновлён" or "скачан", mb(n), dir ~= TO and (" -> " .. dir) or ""))
		end
	elseif f.opt and code == 404 then
		-- необязательного файла может не быть в репозитории - не повод бросать
		print("в репозитории нет, пропускаю")
	else
		print("")
		fail("не скачался " .. f[1] .. ": " .. tostring(crc))
	end
end

local function drop(f)
	local rec = placed(f[2])
	if not rec then return end
	print(("  %-16s %s"):format(f[2], DRY and ("удалится: " .. rec.path) or ("удалён: " .. rec.path)))
	if not DRY then fs.remove(rec.path) end
	gone = gone + 1
end

-- сам установщик - всегда в своём каталоге
for _, f in ipairs(core.files) do put(f, TO) end

for _, it in ipairs(items) do
	if not it.header then
		if it.on then
			local dir = (it.disk == it.at and it.dir)
				or (it.kind == "video" and DISKS[it.disk].videos or DISKS[it.disk].games)
			for _, f in ipairs(it.files) do put(f, dir) end
		else
			for _, f in ipairs(it.files) do drop(f) end
		end
	end
end

-- То, что ставили прежде, а в манифесте больше нет. Ролики не трогаем: это
-- мегабайты, которые игрок, может быть, хочет оставить.
for name, rec in pairs(oldFiles) do
	if not known[name] and fs.exists(rec.path) then
		if name:match("%.bin$") or name:match("%.dfpwm$") then
			print(("  %-16s в репозитории больше нет, остался: %s"):format(name, rec.path))
		else
			print(("  %-16s %s"):format(name, DRY and "удалится" or "удалён - его больше нет в репозитории"))
			if not DRY then fs.remove(rec.path) end
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
	local rec = new.files[b[2]]
	local target = rec and rec.path or (DRY and placed(b[2]) and placed(b[2]).path)
	if target then
		wantedBin[b[1]] = true
		local path = "/bin/" .. b[1] .. ".lua"
		-- обновлялке ярлык подсказывает каталог: иначе она не узнает, куда ставили
		local pre = b[2] == "install.lua" and ("table.insert(a, 1, %q)\n"):format("--to=" .. TO) or ""
		local body = ("%s%s\nlocal a = { ... }\n%sreturn assert(loadfile(%q))(table.unpack(a))\n")
			:format(MARK, target, pre, target)
		local cur
		local fh = io.open(path, "r")
		if fh then cur = fh:read("*a") fh:close() end
		if cur ~= body then
			io.write(("  ярлык %-12s -> %s"):format(b[1], target))
			if DRY then print("   (проба)") else
				-- /bin бывает и на дискете только для чтения: игры уже стоят,
				-- так что это не повод обрывать установку
				mkdir(path)
				local f, werr = io.open(path, "w")
				if f then f:write(body) f:close() print("")
				else print("   не вышло (" .. tostring(werr) .. "), запускай как " .. target) end
			end
		end
		new.bin[#new.bin + 1] = b[1]
	end
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

if freshN == 0 and gone == 0 then
	print(("Всё свежее, файлов: %d."):format(same))
else
	print(("Готово: скачано %d (%s), без изменений %d, удалено %d."):format(freshN, mb(got), same, gone))
end
local HELP = {
	mario = "mario        - платформер: стрелки, вверх - прыжок, X - бег и огонь",
	doom = "doom         - шутер: стрелки, A/D - вбок, пробел - огонь, E - открыть",
	kart = "kart         - гонки: стрелки, пробел - занос, X - предмет",
	chip8 = "chip8        - эмулятор CHIP-8: 1234/QWER/ASDF/ZXCV, Q - выход",
	casino = "casino       - однорукий бандит, всё мышью",
	video = "video        - ролики: меню, пробел - пауза, стрелки - перемотка, Q - назад",
}
for _, it in ipairs(items) do
	if it.on and HELP[it.key] then print("  " .. HELP[it.key]) end
end
print("  games-update - обновить, поставить или убрать игры и ролики")
