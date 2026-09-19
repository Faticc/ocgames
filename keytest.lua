-- keytest - что на самом деле приходит от клавиатуры.
--
--   wget -f https://raw.githubusercontent.com/Faticc/ocgames/main/keytest.lua /tmp/k.lua && /tmp/k.lua
--
-- Если тут ничего не появляется при нажатиях - до компьютера они не
-- доходят вовсе, и дело не в игре: клавиатура должна стоять вплотную к
-- тому монитору, в который ты смотришь, а в монитор надо войти правой
-- кнопкой. Клавиатура на корпусе компьютера работает только в GUI самого
-- корпуса.

local event = require("event")
local component = require("component")
local term = require("term")

term.clear()
print("Клавиатуры, которые видит компьютер:")
local n = 0
for addr in component.list("keyboard") do
	n = n + 1
	print("  " .. addr:sub(1, 8))
end
if n == 0 then
	print("  ни одной - поставь блок Keyboard вплотную к монитору")
end
print("Экраны: ")
for addr in component.list("screen") do
	local s = component.proxy(addr)
	local kb = s.getKeyboards and #s.getKeyboards() or 0
	print(("  %s  клавиатур на нём: %d"):format(addr:sub(1, 8), kb))
end

print("")
print("Жми клавиши. Q - выход.")
print("Марио ждёт: стрелки 203 205 200 208, пробел 57, X 45, Q 16")
print("")

while true do
	local e, addr, ch, code, player = event.pull()
	if e == "key_down" or e == "key_up" then
		print(("%-8s символ=%-5s код=%-5s игрок=%s")
			:format(e, tostring(ch), tostring(code), tostring(player)))
		if code == 16 then break end
	end
end

term.clear()
print("Если key_up не приходил ни разу - скажи, игра переживёт и это.")
