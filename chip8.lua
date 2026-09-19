-- chip8 - эмулятор CHIP-8 для DwOS: настоящая виртуальная машина
-- 1970-х, а не переписанная игра. Любой ROM (.ch8) с этой машины пойдёт
-- как есть.
--
-- Почему именно CHIP-8, а не NES или GameBoy: у CHIP-8 около тысячи
-- инструкций в секунду и экран 64x32 монохромных точки. Это OC тянет с
-- запасом. У NES процессор на 1.79 МГц и видеочип, рисующий пять с
-- лишним миллионов точек в секунду - интерпретатор на Lua внутри
-- песочницы OC выдал бы там кадр за несколько секунд.
--
--   chip8.lua [игра.ch8] [--speed=600] [--sound]
--
-- Звук по умолчанию выключен: computer.beep держит машину всю длительность
-- сигнала, а звуковой таймер CHIP-8 тикает шестьдесят раз в секунду.
--
-- Клавиатура CHIP-8 - это шестнадцать клавиш, разложенных сюда так:
--   1 2 3 C        1 2 3 4
--   4 5 6 D   ->   Q W E R
--   7 8 9 E        A S D F
--   A 0 B F        Z X C V
-- Q - выход, ПРОБЕЛ - пауза, R - перезапуск игры.

local args = { ... }
local opt, rom = {}, nil
for _, a in ipairs(args) do
	local k, v = a:match("^%-%-([%w_]+)=?(.*)$")
	if k then opt[k] = v ~= "" and v or true else rom = a end
end

local component = require("component")
local computer = require("computer")
local event = require("event")
local gpu = component.gpu

-- gfx у DwOS системный и лежит в package.loaded с самой загрузки - им
-- нарисована заставка системы, так что require не стоит ни одного чтения.
local gfx = require("gfx")

--- Каталог самой игры: встроенные ромы лежат рядом с ней, а ярлык из
--- /bin зовёт её из любого места. Имя чанка знает путь в обоих случаях.
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

------------------------------------------------------------------ машина

local W, H = 64, 32                     -- экран CHIP-8 в точках
local SPEED = tonumber(opt.speed) or 600   -- инструкций в секунду

local mem, V, disp = {}, {}, {}
local I, pc, sp, dt_, st = 0, 0x200, 0, 0, 0
local stack, keys = {}, {}
local dirtyY1, dirtyY2 = 0, 31            -- строки экрана, которые менялись
local waitKey                            -- регистр, ждущий нажатия (FX0A)

-- шрифт 0..F, по пять байт на цифру; лежит с адреса 0x50, туда же смотрит FX29
local FONT = {
	0xF0,0x90,0x90,0x90,0xF0, 0x20,0x60,0x20,0x20,0x70,
	0xF0,0x10,0xF0,0x80,0xF0, 0xF0,0x10,0xF0,0x10,0xF0,
	0x90,0x90,0xF0,0x10,0x10, 0xF0,0x80,0xF0,0x10,0xF0,
	0xF0,0x80,0xF0,0x90,0xF0, 0xF0,0x10,0x20,0x40,0x40,
	0xF0,0x90,0xF0,0x90,0xF0, 0xF0,0x90,0xF0,0x10,0xF0,
	0xF0,0x90,0xF0,0x90,0x90, 0xE0,0x90,0xE0,0x90,0xE0,
	0xF0,0x80,0x80,0x80,0xF0, 0xE0,0x90,0x90,0x90,0xE0,
	0xF0,0x80,0xF0,0x80,0xF0, 0xF0,0x80,0xF0,0x80,0x80,
}

local floor, random = math.floor, math.random

local function reset(image)
	for i = 0, 4095 do mem[i] = 0 end
	for i = 0, 15 do V[i] = 0 end
	for i = 0, W * H - 1 do disp[i] = 0 end
	for i = 1, #FONT do mem[0x50 + i - 1] = FONT[i] end
	for i = 1, #image do mem[0x200 + i - 1] = image:byte(i) end
	I, pc, sp, dt_, st = 0, 0x200, 0, 0, 0
	stack, waitKey = {}, nil
	dirtyY1, dirtyY2 = 0, H - 1
end

--- Один шаг процессора. Возвращает true, если экран изменился.
local function cycle()
	local hi, lo = mem[pc] or 0, mem[pc + 1] or 0
	local op = hi * 256 + lo
	pc = (pc + 2) & 0xFFF
	local x, y = (hi & 0x0F), (lo >> 4)
	local n, nn, nnn = lo & 0x0F, lo, op & 0x0FFF
	local head = op >> 12
	local draw = false

	if op == 0x00E0 then
		for i = 0, W * H - 1 do disp[i] = 0 end
		dirtyY1, dirtyY2 = 0, H - 1
		draw = true
	elseif op == 0x00EE then
		sp = sp - 1
		pc = stack[sp] or 0x200
	elseif head == 0x1 then pc = nnn
	elseif head == 0x2 then stack[sp] = pc sp = sp + 1 pc = nnn
	elseif head == 0x3 then if V[x] == nn then pc = (pc + 2) & 0xFFF end
	elseif head == 0x4 then if V[x] ~= nn then pc = (pc + 2) & 0xFFF end
	elseif head == 0x5 then if V[x] == V[y] then pc = (pc + 2) & 0xFFF end
	elseif head == 0x6 then V[x] = nn
	elseif head == 0x7 then V[x] = (V[x] + nn) & 0xFF
	elseif head == 0x8 then
		if n == 0x0 then V[x] = V[y]
		elseif n == 0x1 then V[x] = V[x] | V[y] V[0xF] = 0
		elseif n == 0x2 then V[x] = V[x] & V[y] V[0xF] = 0
		elseif n == 0x3 then V[x] = V[x] ~ V[y] V[0xF] = 0
		elseif n == 0x4 then
			local s = V[x] + V[y]
			V[x] = s & 0xFF
			V[0xF] = s > 0xFF and 1 or 0
		elseif n == 0x5 then
			local c = V[x] >= V[y] and 1 or 0
			V[x] = (V[x] - V[y]) & 0xFF
			V[0xF] = c
		elseif n == 0x6 then
			local c = V[x] & 1
			V[x] = V[x] >> 1
			V[0xF] = c
		elseif n == 0x7 then
			local c = V[y] >= V[x] and 1 or 0
			V[x] = (V[y] - V[x]) & 0xFF
			V[0xF] = c
		elseif n == 0xE then
			local c = (V[x] >> 7) & 1
			V[x] = (V[x] << 1) & 0xFF
			V[0xF] = c
		end
	elseif head == 0x9 then if V[x] ~= V[y] then pc = (pc + 2) & 0xFFF end
	elseif head == 0xA then I = nnn
	elseif head == 0xB then pc = (nnn + V[0]) & 0xFFF
	elseif head == 0xC then V[x] = random(0, 255) & nn
	elseif head == 0xD then
		-- спрайт рисуется исключающим ИЛИ, а VF говорит, стёрлась ли точка
		local vx, vy = V[x], V[y]
		V[0xF] = 0
		-- запоминаем строки, которых коснулся спрайт: по ним потом и
		-- пройдёмся, вместо того чтобы сверять все две тысячи точек
		if vy < dirtyY1 then dirtyY1 = vy end
		local last = vy + n - 1
		if last >= H then dirtyY1, dirtyY2 = 0, H - 1
		elseif last > dirtyY2 then dirtyY2 = last end
		for row = 0, n - 1 do
			local b = mem[(I + row) & 0xFFF] or 0
			local py = (vy + row) % H
			for col = 0, 7 do
				if (b >> (7 - col)) & 1 == 1 then
					local px = (vx + col) % W
					local i = py * W + px
					if disp[i] == 1 then V[0xF] = 1 end
					disp[i] = disp[i] ~ 1
				end
			end
		end
		draw = true
	elseif head == 0xE then
		if nn == 0x9E then if keys[V[x]] then pc = (pc + 2) & 0xFFF end
		elseif nn == 0xA1 then if not keys[V[x]] then pc = (pc + 2) & 0xFFF end end
	elseif head == 0xF then
		if nn == 0x07 then V[x] = dt_
		elseif nn == 0x0A then waitKey = x
		elseif nn == 0x15 then dt_ = V[x]
		elseif nn == 0x18 then st = V[x]
		elseif nn == 0x1E then I = (I + V[x]) & 0xFFF
		elseif nn == 0x29 then I = 0x50 + V[x] * 5
		elseif nn == 0x33 then
			mem[I] = floor(V[x] / 100)
			mem[(I + 1) & 0xFFF] = floor(V[x] / 10) % 10
			mem[(I + 2) & 0xFFF] = V[x] % 10
		elseif nn == 0x55 then
			for i = 0, x do mem[(I + i) & 0xFFF] = V[i] end
			I = (I + x + 1) & 0xFFF
		elseif nn == 0x65 then
			for i = 0, x do V[i] = mem[(I + i) & 0xFFF] or 0 end
			I = (I + x + 1) & 0xFFF
		end
	end
	return draw
end

------------------------------------------------------------------ экран

local SCALE = 2
local scr = gfx.new(gpu, 160, 50)
scr:palette({ [0] = 0x0A0A0A, [1] = 0x33FF66, [2] = 0xFFFFFF, [3] = 0x202020 })
scr:reserveTop(2)
if opt.fullscan then scr.fullScan = true end

local OX = floor((scr.pw - W * SCALE) / 2)          -- 16 пикселей слева
local OY = 4 + floor((scr.ph - 4 - H * SCALE) / 2)  -- под строкой заголовка

local shown = {}

--- Показать точки CHIP-8. Перерисовываются только изменившиеся - на
--- экран всё равно уходит один bitblt, но так дешевле и по памяти машины.
local function blitScreen(all)
	if scr.fullScan then all = true end       -- проверочный режим
	local y1, y2 = 0, H - 1
	if not all then
		y1, y2 = dirtyY1, dirtyY2
		if y1 > y2 then scr:flush() return end
	end
	dirtyY1, dirtyY2 = H, -1
	for i = y1 * W, (y2 + 1) * W - 1 do
		local v = disp[i]
		if all or shown[i] ~= v then
			shown[i] = v
			local px = OX + (i % W) * SCALE + 1
			local py = OY + floor(i / W) * SCALE + 1
			scr:rect(px, py, SCALE, SCALE, v == 1 and 1 or 0)
		end
	end
	scr:flush()
end

------------------------------------------------------------------ ввод

-- раскладка: левый верхний угол клавиатуры CHIP-8 ложится на 1/Q/A/Z
local KEYMAP = {
	[2] = 0x1, [3] = 0x2, [4] = 0x3, [5] = 0xC,
	[16] = 0x4, [17] = 0x5, [18] = 0x6, [19] = 0xD,
	[30] = 0x7, [31] = 0x8, [32] = 0x9, [33] = 0xE,
	[44] = 0xA, [45] = 0x0, [46] = 0xB, [47] = 0xF,
}

------------------------------------------------------------------ запуск

--- Взять образ игры: из файла, если он назван, иначе встроенный.
local function loadImage()
	if rom then
		local f, err = io.open(rom, "rb")
		if not f then error("не открыть " .. rom .. ": " .. tostring(err), 0) end
		local data = f:read("*a")
		f:close()
		return data, rom:match("[^/\\]+$")
	end
	local roms = neighbour("chip8roms.lua")
	local r = roms[1]
	return r.data, r.name
end

local image, title = loadImage()
reset(image)

local running, paused = true, false
local speedNote = ""

--- Обработчик клавиш; висит на event.listen. Возвращать false нельзя -
--- OpenOS снял бы обработчик с события.
local keyEvents = 0
local beepAt = 0

local function handleKey(name, _, ch, code)
	keyEvents = keyEvents + 1
	if name == "key_down" then
		if code == 16 then running = false return end        -- Q
		if code == 57 then paused = not paused return end    -- пробел
		if code == 19 then reset(image) blitScreen(true) return end   -- R
		local k = KEYMAP[code]
		if k then
			keys[k] = true
			if waitKey then V[waitKey] = k waitKey = nil end
		end
	elseif name == "key_up" then
		local k = KEYMAP[code]
		if k then keys[k] = false end
	end
	return true
end

event.listen("key_down", handleKey)
event.listen("key_up", handleKey)

local ok, err = pcall(function()
	scr:clear(0)
	scr:flush()
	scr:text(2, 1, "CHIP-8  " .. title, 2, 0)
	scr:text(scr.w - 33, 1, "1234 QWER ASDF ZXCV   R сброс  Q выход", 3, 0)
	blitScreen(true)

	local last = computer.uptime()
	local acc, tacc = 0, 0

	while running do
		-- Клавиши приходят в handleKey через event.listen: с нулевым
		-- таймаутом OpenOS сигналы не отдаёт, и опрос в цикле оставался бы
		-- глухим. Ждём чуть-чуть - за это время система разберёт очередь.
		local before = keyEvents
		local e, addr, ch, code = event.pull(0.02)
		if e == "interrupted" then running = false end
		-- подстраховка на случай, если подписка не отработала; счётчик не
		-- даёт разобрать одно и то же нажатие дважды
		if (e == "key_down" or e == "key_up") and keyEvents == before then
			handleKey(e, addr, ch, code)
		end

		local now = computer.uptime()
		local dt = now - last
		last = now
		if dt > 0.2 then dt = 0.2 end

		if not paused then
			-- процессор считаем по времени, а не по кадрам: сколько тиков
			-- прошло, столько инструкций и выполняем
			acc = acc + dt * SPEED
			local steps = floor(acc)
			acc = acc - steps
			if steps > 400 then steps = 400 end
			local dirty = false
			for _ = 1, steps do
				if waitKey then break end
				if cycle() then dirty = true end
			end

			-- таймеры идут на 60 герцах независимо от кадров
			tacc = tacc + dt * 60
			local ticks = floor(tacc)
			tacc = tacc - ticks
			if ticks > 0 then
				dt_ = math.max(0, dt_ - ticks)
				if st > 0 then
					st = math.max(0, st - ticks)
					-- звук стоит машине целого кадра, поэтому только по
					-- просьбе и не чаще раза в четверть секунды
					if opt.sound and (beepAt or 0) + 0.25 < now then
						beepAt = now
						pcall(computer.beep, 440, 0.015)
					end
				end
			end

			if dirty then blitScreen(false) end
		end
	end
end)

event.ignore("key_down", handleKey)
event.ignore("key_up", handleKey)
scr:close()
gpu.setActiveBuffer(0)
gpu.setResolution(gpu.maxResolution())
gpu.setBackground(0x000000)
gpu.setForeground(0xFFFFFF)
require("term").clear()
if not ok then error(err, 0) end
