-- Что из репозитория куда ложится. Ярлыки в /bin делает установщик сам,
-- их скачивать не нужно. size и crc проставляет tools/genmanifest.py -
-- руками их не правь, а после правки игр перезапусти его.
--
-- Ставится всё по частям: установщик показывает список (окно checklist
-- из установщика DwOS), где каждая часть и каждый ролик отмечаются
-- отдельно и кладутся на свой диск. Часть - это pkg у файлов ниже.
{
	dir = "/home/games",
	-- части по порядку в списке; core - сам установщик, он ставится всегда
	packages = {
		{ "mario",  "Марио",   "платформер, восемь уровней" },
		{ "doom",   "Doom",    "шутер от первого лица" },
		{ "kart",   "Карты",   "гонки, кубок из четырёх трасс" },
		{ "chip8",  "CHIP-8",  "эмулятор приставки" },
		{ "casino", "Казино",  "однорукий бандит" },
		{ "video",  "Видео",   "проигрыватель роликов" },
		{ "tools",  "Проверки", "keytest и tapetest" },
	},
	files = {
		{ "marioart.lua",    "marioart.lua",   size = 20698, crc = "f9b0dd55", pkg = "mario" },
		{ "mario.lua",       "mario.lua",      size = 59896, crc = "3d502d0c", pkg = "mario" },
		{ "doomart.lua",     "doomart.lua",    size = 19005, crc = "2bb478d8", pkg = "doom" },
		{ "doom.lua",        "doom.lua",       size = 62023, crc = "beffbf61", pkg = "doom" },
		{ "chip8roms.lua",   "chip8roms.lua",  size = 966, crc = "074b0279", pkg = "chip8" },
		{ "chip8.lua",       "chip8.lua",      size = 13288, crc = "0440f395", pkg = "chip8" },
		{ "casino.lua",      "casino.lua",     size = 55344, crc = "28e60c50", pkg = "casino" },
		{ "kartart.lua",     "kartart.lua",    size = 21440, crc = "e4300472", pkg = "kart" },
		{ "kart.lua",        "kart.lua",       size = 71757, crc = "b302902b", pkg = "kart" },
		{ "keytest.lua",     "keytest.lua",    size = 1924, crc = "814b00b7", pkg = "tools" },
		{ "tapetest.lua",    "tapetest.lua",   size = 6729, crc = "16a34da2", pkg = "tools" },
		-- сам установщик: им же и обновляются (games-update)
		{ "install.lua",     "install.lua",    size = 29212, crc = "d5014a9a", pkg = "core" },
		-- проигрыватель роликов: меню, цвет, звук с кассеты
		{ "video.lua",       "video.lua",      size = 31376, crc = "51abbae1", pkg = "video" },
		-- Bad Apple лежит и здесь ради установщиков старше списка: они
		-- знают только files и удалили бы ролик, которого тут не нашли.
		-- Новый установщик берёт файлы с video = true как ролики.
		{ "video/badapple.bin", "badapple.bin",   size = 1318092, crc = "c62419b9", video = true, title = "Bad Apple!!", opt = true, secs = 219 },
		{ "video/badapple.dfpwm", "badapple.dfpwm", size = 898969, crc = "e55e07d5", video = true, opt = true },
	},
	-- Ролики к video, каждый - отдельной строкой списка: можно взять ролик
	-- без звука или звук без ролика. Кладутся в папку videos выбранного
	-- диска (на системном - в /home/videos), там их и ищет плеер. Звук -
	-- файл с тем же именем, .dfpwm: его пишут на кассету (W в меню video).
	videos = {
		{ "video/poop.bin",  "poop.bin",       size = 2005958, crc = "53c0034f", secs = 41 },
		{ "video/poop.dfpwm", "poop.dfpwm",     size = 167731, crc = "d3b7d404" },
		{ "video/chinenumberone.bin", "chinenumberone.bin", size = 3811336, crc = "898bd8b2", secs = 119 },
		{ "video/chinenumberone.dfpwm", "chinenumberone.dfpwm", size = 485649, crc = "c121119e" },
	},
	-- имя ярлыка -> что он запускает
	bin = {
		{ "mario", "mario.lua" },
		{ "doom", "doom.lua" },
		{ "chip8", "chip8.lua" },
		{ "video", "video.lua" },
		-- прежнее имя: открывает то же меню
		{ "badapple", "video.lua" },
		{ "casino", "casino.lua" },
		{ "kart", "kart.lua" },
		{ "keytest", "keytest.lua" },
		{ "tapetest", "tapetest.lua" },
		{ "games-update", "install.lua" },
	},
}
