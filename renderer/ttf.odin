package renderer

import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

default_text_color: sdl.Color : {69, 69, 69, 255}

draw_text :: proc(
	r: ^Renderer,
	text: string,
	transform: mat4,
	font: ^ttf.Font = nil,
	color: sdl.Color = default_text_color,
) {

}

