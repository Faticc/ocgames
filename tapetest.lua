-- tapetest - кассетник руками: что компьютер видит, что на кассете и как
-- оно звучит. Плеер тут ни при чём, поэтому сюда и надо идти первым делом,
-- когда badapple идёт молча.
--
--   wget -f https://raw.githubusercontent.com/Faticc/ocgames/main/tapetest.lua /tmp/t.lua && /tmp/t.lua
--
-- Проверяется по порядку: видит ли компьютер кассетник (кассетник должен
-- стоять вплотную к нему или быть подключён кабелем, и ему нужна энергия),
-- есть ли в кассетнике кассета, записано ли на неё хоть что-нибудь и
-- слышно ли это. Если здесь музыка играет, а в badapple тишина - дело уже
-- не в железе и не в кассете.
--
-- Управление: пробел - пуск и стоп, стрелки - перемотка на 5 секунд,
-- R - в начало, T - посмотреть, что на ленте под головкой, - и = -
-- громкость, Q - выход.

local component = require("component")
local event = require("event")
local term = require("term")

-- один бит на отсчёт, 32768 отсчётов в секунду - 4096 байт на секунду
local BPS = 4096

local function mmss(sec)
	sec = math.floor(sec)
	return ("%d:%02d"):format(math.floor(sec / 60), sec % 60)
end

------------------------------------------------------------------ поиск

term.clear()
print("Кассетники, которые видит компьютер:")

local tape
local found = 0
for addr in component.list("tape_drive") do
	found = found + 1
	local t = component.proxy(addr)
	local ok, ready = pcall(t.isReady)
	if ok and ready then
		local size = t.getSize()
		print(("  %s  кассета на %s (%d КБ), %s")
			:format(addr:sub(1, 8), mmss(size / BPS), math.floor(size / 1024),
				t.getLabel() or "без подписи"))
		tape = tape or t
	else
		print(("  %s  пустой - вставь в него кассету"):format(addr:sub(1, 8)))
	end
end

if found == 0 then
	print("  ни одного.")
	print("")
	print("Кассетник (tape drive) должен стоять вплотную к компьютеру или")
	print("быть подключён к нему кабелем, и ему нужна энергия. Список всего,")
	print("что компьютер видит, покажет команда components.")
	return
end
if not tape then
	print("")
	print("Кассетник есть, а кассеты в нём нет - её надо вставить в блок.")
	return
end

------------------------------------------------------------------ лента

local size = tape.getSize()
local vol = 1
pcall(tape.setVolume, vol)
pcall(tape.setSpeed, 1)

print("")
print("Пробел - пуск и стоп, стрелки - перемотка на 5 секунд, R - в начало,")
print("T - что на ленте под головкой, - и = - громкость, Q - выход.")
print("")

--- Лента на такую-то секунду: seek двигает от текущего места, а не к
--- заданному, поэтому считаем разницу сами.
local function seekTo(sec)
	local want = math.floor(sec * BPS)
	if want < 0 then want = 0 elseif want > size then want = size end
	local pos = tape.getPosition()
	if want ~= pos then tape.seek(want - pos) end
end

--- Что лежит под головкой: секунда ленты, и сразу назад. Это первое, что
--- стоит посмотреть, если кассетник крутит, а из него ни звука.
---
--- Чистая кассета - это нули. А вот тишина внутри записи нулями не
--- пишется: заряд у DFPWM качается вокруг середины, и тишина выходит
--- ровным чередованием 0x55 и 0xAA. Поэтому одно от другого тут и
--- разделено - в начале Bad Apple!! как раз секунда такой тишины, и
--- пугаться её не надо.
local function peek()
	local pos = tape.getPosition()
	local data = tape.read(BPS) or ""
	tape.seek(pos - tape.getPosition())
	if #data == 0 then return "лента кончилась" end
	local zero, seen, kinds = 0, {}, 0
	for i = 1, #data do
		local b = data:byte(i)
		if b == 0 then zero = zero + 1 end
		if not seen[b] then seen[b] = true kinds = kinds + 1 end
	end
	if zero == #data then return "чисто: одни нули, тут не писали" end
	if kinds <= 4 and (seen[0x55] or seen[0xAA]) then
		return "запись есть, но в этом месте тишина"
	end
	return ("запись есть: %d разных байт, нулевых %d%%")
		:format(kinds, math.floor(zero / #data * 100))
end

local note = ""
local running = true
while running do
	local pos = tape.getPosition()
	local state = tape.getState()
	local n = 30
	local full = size > 0 and math.floor(pos / size * n + 0.5) or 0
	io.write(("\r%-9s %s / %s  [%s%s]  громкость %d%%  %s   ")
		:format(state, mmss(pos / BPS), mmss(size / BPS),
			("#"):rep(full), ("-"):rep(n - full), math.floor(vol * 100 + 0.5), note))

	local e, _, _, code = event.pull(0.2)
	if e == "interrupted" then running = false
	elseif e == "key_down" then
		note = ""
		if code == 16 or code == 1 then running = false            -- Q, Esc
		elseif code == 57 then                                     -- пробел
			if state == "PLAYING" then tape.stop() else tape.play() end
		elseif code == 203 then seekTo(pos / BPS - 5)              -- влево
		elseif code == 205 then seekTo(pos / BPS + 5)              -- вправо
		elseif code == 19 then seekTo(0)                           -- R
		elseif code == 20 then note = peek()                       -- T
		elseif code == 12 or code == 13 then                       -- - и =
			vol = math.min(1, math.max(0, vol + (code == 12 and -0.1 or 0.1)))
			pcall(tape.setVolume, vol)
		end
	end
end

pcall(tape.stop)
print("")
print("Играло - значит кассета в порядке и звук до тебя доходит.")
print("Молчало на непустой ленте - проверь, не выключен ли звук в игре и")
print("не слишком ли далеко ты стоишь: кассетник слышно метров за 24.")
