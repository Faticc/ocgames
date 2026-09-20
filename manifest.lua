-- Что из репозитория куда ложится. Ярлыки в /bin делает установщик сам,
-- их скачивать не нужно. size и crc проставляет tools/genmanifest.py -
-- руками их не правь, а после правки игр перезапусти его.
{
	dir = "/home/games",
	files = {
		{ "marioart.lua",    "marioart.lua",   size = 20698, crc = "f9b0dd55" },
		{ "mario.lua",       "mario.lua",      size = 59896, crc = "3d502d0c" },
		{ "doomart.lua",     "doomart.lua",    size = 19005, crc = "2bb478d8" },
		{ "doom.lua",        "doom.lua",       size = 62023, crc = "beffbf61" },
		{ "chip8roms.lua",   "chip8roms.lua",  size = 966, crc = "074b0279" },
		{ "chip8.lua",       "chip8.lua",      size = 13288, crc = "0440f395" },
		{ "casino.lua",      "casino.lua",     size = 55344, crc = "28e60c50" },
		{ "kartart.lua",     "kartart.lua",    size = 21440, crc = "e4300472" },
		{ "kart.lua",        "kart.lua",       size = 71757, crc = "b302902b" },
		{ "keytest.lua",     "keytest.lua",    size = 1924, crc = "814b00b7" },
		-- сам установщик: им же и обновляются (games-update)
		{ "install.lua",     "install.lua",    size = 18734, crc = "8fe7197f" },
		{ "badapple.lua",    "badapple.lua",   size = 26205, crc = "992f1773" },
		-- ролик к плееру: 1.3 МБ, в репозитории его может и не быть -
		-- тогда установщик просто скажет, что не нашёл, и пойдёт дальше
		{ "badapple.bin",    "badapple.bin",   size = 1318092, crc = "c62419b9", opt = true },
		-- и звук к нему: его пишут на кассету (badapple --writetape),
		-- собирается он tools/packdfpwm.py и тоже не обязателен
		{ "badapple.dfpwm",  "badapple.dfpwm", size = 898969, crc = "e55e07d5", opt = true },
	},
	-- имя ярлыка -> что он запускает
	bin = {
		{ "mario", "mario.lua" },
		{ "doom", "doom.lua" },
		{ "chip8", "chip8.lua" },
		{ "badapple", "badapple.lua" },
		{ "casino", "casino.lua" },
		{ "kart", "kart.lua" },
		{ "games-update", "install.lua" },
	},
}
