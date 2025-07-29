package renderer

import sdle "../lib/sdle"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

default_text_color: sdl.Color : {69, 69, 69, 255}

Text_Draw_Req :: struct {
	text:       cstring,
	transform:  mat4,
	font:       ^ttf.Font,
	color:      sdl.Color,
	wrap_width: Maybe(i32),
}

draw_text :: proc(r: ^Renderer, req: Text_Draw_Req) {
	if r._frame_buf_lens[.TEXT_DRAW] == MAX_TEXT_SURFACES do return
	r._text_reqs[r._frame_buf_lens[.TEXT_DRAW]] = req
	r._frame_buf_lens[.TEXT_DRAW] += 1
}

@(private)
_copy_texts :: proc(r: ^Renderer) {
	// TODO gc unused & shmove indices at end
	// TODO single large transfer buffer for all texts 
	// TODO insert draw calls

	return
}

@(private)
_allocate_text :: proc(r: ^Renderer, req: Text_Draw_Req) -> (idx: i32) {
	if r._text_alloc == MAX_TEXT_SURFACES do return -1
	surface: ^sdl.Surface
	wrap_w, has_wrap := req.wrap_width.?
	if has_wrap {
		surface = ttf.RenderText_Blended_Wrapped(req.font, req.text, 0, req.color, wrap_w)
	} else {
		surface = ttf.RenderText_Blended(req.font, req.text, 0, req.color)
	}
	sdle.err(surface)
	idx = r._text_alloc
	r._text_alloc += 1
	r._text_dim[idx].x = surface.w
	r._text_dim[idx].y = surface.h

	return
}

