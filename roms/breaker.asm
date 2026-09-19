; ОТБИВАЛКА - игра для CHIP-8, собирается tools/chip8asm.py.
;
; Три ряда кирпичей, ракетка внизу, клавиши 4 и 6 (на клавиатуре Q и E).
; Попадание в кирпич ловится по флагу VF: спрайт рисуется исключающим ИЛИ,
; и если он на что-то наложился, машина сама поднимает VF - так это
; делали и настоящие игры 1977 года.
;
; Регистры: V0,V1 - мяч, V2,V3 - его скорость, V4 - ракетка, V7 - её
; ширина, VB - строка ракетки, V5,V6 - черновые.

NAME ОТБИВАЛКА

start:
	CLS
	LD V7, 8
	LD I, brick

	; кирпичи: три ряда по шестнадцать штук, сетка 4x2
	LD V6, 0
rows:
	LD V5, 0
cols:
	DRW V5, V6, 2
	ADD V5, 4
	SE V5, 64
	JP cols
	ADD V6, 2
	SE V6, 6
	JP rows

	LD V0, 32
	LD V1, 20
	LD V2, 1
	LD V3, 255
	LD V4, 28
	LD VB, 31
	LD I, ball
	DRW V0, V1, 1
	LD I, paddle
	DRW V4, VB, 1

loop:
	; ракетка
	LD V6, 4
	SKNP V6
	CALL left
	LD V6, 6
	SKNP V6
	CALL right

	; мяч: стереть, сдвинуть
	LD I, ball
	DRW V0, V1, 1
	ADD V0, V2
	ADD V1, V3

	; стены слева и справа
	SE V0, 255
	JP ck1
	LD V0, 0
	LD V2, 1
ck1:
	SE V0, 64
	JP ck2
	LD V0, 63
	LD V2, 255
ck2:
	; потолок
	SE V1, 255
	JP ck3
	LD V1, 0
	LD V3, 1
ck3:
	; ракетка стоит строкой ниже, ловим мяч на 30-й
	SE V1, 30
	JP ck4
	LD V5, V0
	SUB V5, V4
	SE VF, 1
	JP ck4
	LD V6, V5
	SUB V6, V7
	SE VF, 0
	JP ck4
	LD V3, 255
	LD V6, 2
	LD ST, V6
ck4:
	; промахнулись - мяч заново
	SE V1, 32
	JP draw
	LD V0, 32
	LD V1, 20
	LD V3, 255

draw:
	LD I, ball
	DRW V0, V1, 1
	SE VF, 1
	JP tickset
	CALL hitbrick

tickset:
	LD V6, 2
	LD DT, V6
tick:
	LD V6, DT
	SE V6, 0
	JP tick
	JP loop

; ------------------------------------------------ попадание в кирпич
; Мяч уже нарисован поверх кирпича и VF поднят. Убираем мяч, гасим весь
; кирпич (координаты выравниваем сдвигами по сетке 4x2) и разворачиваем
; мяч по вертикали.
hitbrick:
	LD I, ball
	DRW V0, V1, 1
	LD V5, V0
	SHR V5
	SHR V5
	SHL V5
	SHL V5
	LD V6, V1
	SHR V6
	SHL V6
	LD I, brick
	DRW V5, V6, 2
	LD V6, 0
	SUB V6, V3
	LD V3, V6
	ADD V1, V3
	LD I, ball
	DRW V0, V1, 1
	LD V6, 3
	LD ST, V6
	RET

; ------------------------------------------------ ракетка
left:
	SE V4, 0
	JP l1
	RET
l1:
	LD I, paddle
	DRW V4, VB, 1
	ADD V4, 255
	DRW V4, VB, 1
	RET

right:
	SE V4, 56
	JP r1
	RET
r1:
	LD I, paddle
	DRW V4, VB, 1
	ADD V4, 1
	DRW V4, VB, 1
	RET

; ------------------------------------------------ картинки
ball:
	DB 0x80
paddle:
	DB 0xFF
brick:
	DB 0xE0, 0xE0
