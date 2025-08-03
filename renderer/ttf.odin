package renderer

import "../lib/glist"
import sdle "../lib/sdle"
import "base:runtime"
import "core:mem"
import os "core:os/os2"
import "core:path/filepath"
import "core:strings"
import sdl "vendor:sdl3"
import sdli "vendor:sdl3/image"


Bitmap :: struct {
	model_idx: glist.Glist_Idx,
	charset:   map[rune]u32, // node_idx
}

load_bm :: proc(r: ^Renderer, font_filename: string) -> (bm: Bitmap) {
	font := load_font(r, font_filename)
	model: Model
	model.textures = make([]^sdl.GPUTexture, 1)
	model.textures[0] = load_bm_png(r, font.page.file)

	err: runtime.Allocator_Error
	bm.model_idx, err = glist.insert(&r.models, model);assert(err == nil)
	for char in font.chars {
		// TODO gen quads (yes you gotta upload them shits to da GPU Isaac)
	}
	return
}

Font :: struct {
	info:   Font_Info,
	common: Font_Common,
	page:   Font_Page,
	chars:  Font_Chars,
}
Font_Info :: struct {
	face:      string,
	size:      int,
	bold:      int,
	italic:    int,
	charset:   string,
	unicode:   int,
	stretch_h: int,
	smooth:    int,
	aa:        int,
	padding:   [4]int,
	spacing:   [2]int,
}
Font_Common :: struct {
	line_height: int,
	base:        int,
	scale_w:     int,
	scale_h:     int,
	pages:       int,
	packed:      int,
}
Font_Page :: struct {
	id:   int,
	file: string,
}
Font_Chars :: []Font_Char
Font_Char :: struct {
	id:        int,
	x:         int,
	y:         int,
	width:     int,
	height:    int,
	x_offset:  int,
	y_offset:  int,
	x_advance: int,
	page:      int,
	chnl:      int,
}

load_font :: proc(r: ^Renderer, filename: string) -> (font: Font) {


	return
}

load_bm_png :: proc(r: ^Renderer, filename: string) -> (tex: ^sdl.GPUTexture) {
	temp_mem := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp_mem)
	sb: strings.Builder
	strings.builder_init_len(&sb, len(filename) + len(font_location) + 2, context.temp_allocator)
	strings.write_string(&sb, font_location)
	strings.write_rune(&sb, os.Path_Separator)
	strings.write_string(&sb, filename)
	filepath := strings.to_cstring(&sb)

	disk_surf := sdli.Load(filepath);sdle.err(disk_surf)
	palette := sdl.GetSurfacePalette(disk_surf)
	surf := sdl.ConvertSurfaceAndColorspace(
		disk_surf,
		.RGBA32,
		palette,
		.SRGB_LINEAR,
		0,
	);sdle.err(surf)
	sdl.DestroySurface(disk_surf)
	w := u32(surf.w)
	h := u32(surf.h)
	bytes_size := surf.h * surf.pitch
	bytes_size_u32 := u32(bytes_size)
	trans := sdl.CreateGPUTransferBuffer(
		r._gpu,
		{usage = .UPLOAD, size = bytes_size_u32},
	);sdle.err(trans)
	trans_mem := transmute([^]byte)sdl.MapGPUTransferBuffer(
		r._gpu,
		trans,
		false,
	);sdle.err(trans_mem)
	mem.copy_non_overlapping(trans_mem, surf.pixels, int(bytes_size))
	sdl.UnmapGPUTransferBuffer(r._gpu, trans)
	tex = sdl.CreateGPUTexture(
		r._gpu,
		{
			type = .D2,
			format = .R8G8B8A8_UNORM,
			usage = {.SAMPLER},
			width = w,
			height = h,
			layer_count_or_depth = 1,
			num_levels = 1,
		},
	);sdle.err(tex)
	sdl.UploadToGPUTexture(
		r._copy_pass,
		{transfer_buffer = trans, pixels_per_row = w, rows_per_layer = h},
		{texture = binding.texture, w = w, h = h, d = 1},
		false,
	)
	sdl.ReleaseGPUTransferBuffer(r._gpu, trans)
	return
}

default_text_color :: [4]f32{0.1, 0.1, 0.1, 1}
Text_Draw_Req :: struct {
	text:       string,
	transform:  mat4,
	material:   Maybe(Model_Material),
	color:      Maybe([4]f32),
	wrap_width: Maybe(i32),
}
draw_text :: proc(r: ^Renderer, req: Text_Draw_Req) {
	// if r._frame_buf_lens[.TEXT_DRAW] == MAX_TEXT_SURFACES do return
	// r._text_reqs[r._frame_buf_lens[.TEXT_DRAW]] = req
	// r._frame_buf_lens[.TEXT_DRAW] += 1

	material, has_mat := req.material.?
	if !has_mat {
		material = r._default_text_material
	}
	color, has_color := req.color.?
	if !has_mat {
		color = default_text_color
	}
	wrap_width, has_wrap_width := req.wrap_width.?


}

