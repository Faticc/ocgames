-- chip8roms - игры, собранные из games/roms/*.asm ассемблером
-- tools/chip8asm.py. Править надо исходники, а не эти байты:
--     python tools/chip8asm.py --lua games/roms/*.asm > games/chip8roms.lua

local function bin(hex)
	local t = {}
	for b in hex:gmatch('%x%x') do t[#t + 1] = string.char(tonumber(b, 16)) end
	return table.concat(t)
end

return {
	{ name = "ОТБИВАЛКА", data = bin(
		"00e06708a2de66006500d56275043540120a76023606120860206114620163ff"
		.. "641c6b1fa2dcd011a2ddd4b16604e6a122bc6606e6a122cca2dcd01180248134"
		.. "30ff12486000620130401250603f62ff31ff125861006301311e127285008545"
		.. "3f011272865086753f00127263ff6602f6183120127c6020611463ffa2dcd011"
		.. "3f01128622926602f615f6073600128a122ca2dcd011850085568556855e855e"
		.. "86108666866ea2ded5626600863583608134a2dcd0116603f61800ee340012c2"
		.. "00eea2ddd4b174ffd4b100ee343812d200eea2ddd4b17401d4b100ee80ffe0e0"
	) },
}
