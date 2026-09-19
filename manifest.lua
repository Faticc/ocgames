-- Что из репозитория куда ложится. Ярлыки в /bin делает установщик сам,
-- их скачивать не нужно. size и crc проставляет tools/genmanifest.py -
-- руками их не правь, а после правки игр перезапусти его.
{
	dir = "/home/games",
	files = {
		{ "marioart.lua",    "marioart.lua",   size = 20698, crc = "f9b0dd55" },
		{ "mario.lua",       "mario.lua",      size = 52525, crc = "ebb33897" },
		{ "doomart.lua",     "doomart.lua",    size = 19005, crc = "2bb478d8" },
		{ "doom.lua",        "doom.lua",       size = 58100, crc = "7cb00377" },
		{ "chip8roms.lua",   "chip8roms.lua",  size = 966, crc = "074b0279" },
		{ "chip8.lua",       "chip8.lua",      size = 13288, crc = "0440f395" },
		{ "casino.lua",      "casino.lua",     size = 55344, crc = "28e60c50" },
		{ "keytest.lua",     "keytest.lua",    size = 1924, crc = "814b00b7" },
		-- сам установщик: им же и обновляются (games-update)
		{ "install.lua",     "install.lua",    size = 17221, crc = "c73c9ae8" },
		{ "badapple.lua",    "badapple.lua",   size = 17323, crc = "6f0a0ad9" },
		-- ролик к плееру: 1.3 МБ, в репозитории его может и не быть -
		-- тогда установщик просто скажет, что не нашёл, и пойдёт дальше
		{ "badapple.bin",    "badapple.bin",   size = 1318092, crc = "c62419b9", opt = true },
	},
	-- имя ярлыка -> что он запускает
	bin = {
		{ "mario", "mario.lua" },
		{ "doom", "doom.lua" },
		{ "chip8", "chip8.lua" },
		{ "badapple", "badapple.lua" },
		{ "casino", "casino.lua" },
		{ "games-update", "install.lua" },
	},
}
