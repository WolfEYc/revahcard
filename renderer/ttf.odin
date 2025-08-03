package renderer

import "../lib/glist"
import sdle "../lib/sdle"
import "base:runtime"
import "core:fmt"
import "core:mem"
import os "core:os/os2"
import "core:path/filepath"
import "core:strings"
import sdl "vendor:sdl3"
import sdli "vendor:sdl3/image"


quad_idxs :: [6]u16{0, 1, 2, 1, 2, 3}

load_quad_idxs :: proc(r: ^Renderer) -> (binding: sdl.GPUBufferBinding) {
	tbuf_props := sdl.CreateProperties();sdle.err(tbuf_props)
	defer sdl.DestroyProperties(tbuf_props)
	ok := sdl.SetStringProperty(
		tbuf_props,
		sdl.PROP_GPU_TRANSFERBUFFER_CREATE_NAME_STRING,
		"quad_transfer_buf",
	);sdle.err(ok)
	transfer_buf := sdl.CreateGPUTransferBuffer(
		r._gpu,
		{usage = .UPLOAD, size = size_of(quad_idxs), props = tbuf_props},
	);sdle.err(transfer_buf)
	defer sdl.ReleaseGPUTransferBuffer(r._gpu, transfer_buf)
	tmem := cast(^[6]u16)sdl.MapGPUTransferBuffer(r._gpu, transfer_buf, false)
	tmem^ = quad_idxs
	sdl.UnmapGPUTransferBuffer(r._gpu, transfer_buf)

	gpu_buf_props := sdl.CreateProperties();sdle.err(gpu_buf_props)
	sdl.SetStringProperty(gpu_buf_props, sdl.PROP_GPU_BUFFER_CREATE_NAME_STRING, "quad_idx_buf")
	binding.buffer = sdl.CreateGPUBuffer(
		r._gpu,
		{usage = {.INDEX}, size = size_of(quad_idxs), props = gpu_buf_props},
	);sdle.err(binding.buffer)
	sdl.UploadToGPUBuffer(
		r._copy_pass,
		{transfer_buffer = transfer_buf},
		{buffer = binding.buffer, size = size_of(quad_idxs)},
		false,
	)
	return
}

Bitmap :: struct {
	material: Model_Material,
	pos_buf:  sdl.GPUBufferBinding,
	uv_buf:   sdl.GPUBufferBinding,
	charset:  map[rune]u32, // quad #
}

load_bitmap :: proc(r: ^Renderer, font_filename: string) -> (bm: Bitmap) {
	temp_mem := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp_mem)
	font := load_font(r, font_filename)
	diffuse := load_bm_png(r, font.page.file)
	bm.material = Model_Material {
		name = font_filename,
		normal_scale = 1,
		ao_strength = 0,
		bindings = {
			.DIFFUSE = {texture = diffuse, sampler = r._default_text_sampler},
			.EMISSIVE = r._default_emissive_binding,
			.NORMAL = r._default_normal_binding,
			.METAL_ROUGH = r._default_orm_binding,
			.OCCLUSION = r._default_orm_binding,
			.SHADOW = r._shadow_binding,
		},
	}
	bm.charset = make(map[rune]u32, len(font.chars))

	transfer_quads: {
		tbuf_props := sdl.CreateProperties();sdle.err(tbuf_props)
		defer sdl.DestroyProperties(tbuf_props)
		tbuf_name := fmt.ctprintf("%s_transfer_buf", font_filename)
		ok := sdl.SetStringProperty(
			tbuf_props,
			sdl.PROP_GPU_TRANSFERBUFFER_CREATE_NAME_STRING,
			tbuf_name,
		);sdle.err(ok)
		num_chars := u32(len(font.chars))
		verts_size := num_chars * 4 * size_of(f32) * 5 // 5 cuz only pos and uv
		transfer_buf := sdl.CreateGPUTransferBuffer(
			r._gpu,
			{usage = .UPLOAD, size = verts_size, props = tbuf_props},
		);sdle.err(transfer_buf)
		defer sdl.ReleaseGPUTransferBuffer(r._gpu, transfer_buf)
		tmem := transmute([^]byte)sdl.MapGPUTransferBuffer(r._gpu, transfer_buf, false)
		pos := (transmute([^][4][3]f32)tmem)[:num_chars]
		uv_offset: u32 = size_of([4][3]f32) * num_chars
		uv := (transmute([^][4][2]f32)tmem[uv_offset:])[:num_chars]
		uv_size: u32 = size_of([4][2]f32) * num_chars

		for char, i in font.chars {
			pos_ptr := &pos[i]
			uv_ptr := &uv[i]
			char_to_quad(char, pos_ptr, uv_ptr)
			bm.charset[char.id] = u32(i)
		}
		sdl.UnmapGPUTransferBuffer(r._gpu, transfer_buf)


		pos_buf_props := sdl.CreateProperties();sdle.err(pos_buf_props)
		pos_buf_name := fmt.ctprintf("%_pos_buf", font_filename)
		sdl.SetStringProperty(pos_buf_props, sdl.PROP_GPU_BUFFER_CREATE_NAME_STRING, pos_buf_name)
		bm.pos_buf.buffer = sdl.CreateGPUBuffer(
			r._gpu,
			{usage = {.VERTEX}, size = uv_offset, props = pos_buf_props},
		);sdle.err(bm.pos_buf.buffer)
		sdl.UploadToGPUBuffer(
			r._copy_pass,
			{transfer_buffer = transfer_buf},
			{buffer = bm.pos_buf.buffer, size = uv_offset},
			false,
		)

		uv_buf_props := sdl.CreateProperties();sdle.err(uv_buf_props)
		uv_buf_name := fmt.ctprintf("%_uv_buf", font_filename)
		sdl.SetStringProperty(uv_buf_props, sdl.PROP_GPU_BUFFER_CREATE_NAME_STRING, uv_buf_name)
		bm.uv_buf.buffer = sdl.CreateGPUBuffer(
			r._gpu,
			{usage = {.VERTEX}, size = uv_size, props = uv_buf_props},
		);sdle.err(bm.uv_buf.buffer)
		sdl.UploadToGPUBuffer(
			r._copy_pass,
			{transfer_buffer = transfer_buf, offset = uv_offset},
			{buffer = bm.uv_buf.buffer, size = uv_size},
			false,
		)
	}
	return
}

char_to_quad :: proc(char: Font_Char, pos: ^[4][3]f32, uv: ^[4][2]f32) {


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
	id:        rune,
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
		{texture = tex, w = w, h = h, d = 1},
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

