package renderer

import "../lib/glist"
import sdle "../lib/sdle"
import "base:runtime"
import "core:fmt"
import "core:log"
import lal "core:math/linalg"
import "core:mem"
import os "core:os/os2"
import "core:path/filepath"
import "core:slice"
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

Bitmap_Vert_Idx :: enum {
	POS,
	UV,
}

Bitmap :: struct {
	name:          string,
	material:      Model_Material,
	vert_bindings: [Bitmap_Vert_Idx]sdl.GPUBufferBinding,
	glyphs:        map[rune]Glyph, // quad #
	base:          f32,
	y_advance:     f32,
}

PIXEL_PER_WORLD :: 0.005

load_bitmap :: proc(r: ^Renderer, font_filename: string) -> (bm: Bitmap) {
	temp_mem := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp_mem)
	font := load_font(r, font_filename)
	diffuse := load_bm_png(r, font.page.file)
	bm.name = font_filename
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
	bm.glyphs = make(map[rune]Glyph, len(font.chars))
	bm.y_advance = f32(font.common.line_height) * PIXEL_PER_WORLD
	bm.base = f32(font.common.base) * PIXEL_PER_WORLD

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
			char_to_quad(font, char, pos_ptr, uv_ptr)
			offset := [2]f32{f32(char.x_offset), f32(char.y_offset)}
			offset *= PIXEL_PER_WORLD
			bm.glyphs[char.id] = Glyph {
				vert_offset = i32(i) * 4,
				offset      = offset,
				x_advance   = f32(char.x_advance) * PIXEL_PER_WORLD,
			}
		}
		sdl.UnmapGPUTransferBuffer(r._gpu, transfer_buf)

		pos_buf_props := sdl.CreateProperties();sdle.err(pos_buf_props)
		pos_buf_name := fmt.ctprintf("%_pos_buf", font_filename)
		sdl.SetStringProperty(pos_buf_props, sdl.PROP_GPU_BUFFER_CREATE_NAME_STRING, pos_buf_name)
		bm.vert_bindings[.POS].buffer = sdl.CreateGPUBuffer(
			r._gpu,
			{usage = {.VERTEX}, size = uv_offset, props = pos_buf_props},
		);sdle.err(bm.vert_bindings[.POS].buffer)
		sdl.UploadToGPUBuffer(
			r._copy_pass,
			{transfer_buffer = transfer_buf},
			{buffer = bm.vert_bindings[.POS].buffer, size = uv_offset},
			false,
		)

		uv_buf_props := sdl.CreateProperties();sdle.err(uv_buf_props)
		uv_buf_name := fmt.ctprintf("%_uv_buf", font_filename)
		sdl.SetStringProperty(uv_buf_props, sdl.PROP_GPU_BUFFER_CREATE_NAME_STRING, uv_buf_name)
		bm.vert_bindings[.UV].buffer = sdl.CreateGPUBuffer(
			r._gpu,
			{usage = {.VERTEX}, size = uv_size, props = uv_buf_props},
		);sdle.err(bm.vert_bindings[.UV].buffer)
		sdl.UploadToGPUBuffer(
			r._copy_pass,
			{transfer_buffer = transfer_buf, offset = uv_offset},
			{buffer = bm.vert_bindings[.UV].buffer, size = uv_size},
			false,
		)
	}
	return
}

char_to_quad :: proc(font: Font, char: Font_Char, pos: ^[4][3]f32, uv: ^[4][2]f32) {
	offset: [2]f32 = {f32(char.width), f32(-char.height)}
	offset *= PIXEL_PER_WORLD
	pos^ = {
		0, // top left
		{offset.x, 0, 0}, // top right
		{0, offset.y, 0}, // bot left
		{offset.x, offset.y, 0}, // bot right
	}
	scale: [2]f32 = {
		f32(font.common.scale_w), // w
		f32(font.common.scale_h), // h
	}
	origin: [2]f32 = {f32(char.x), f32(char.y)}
	origin /= scale
	uv_offset: [2]f32 = {f32(char.width), f32(char.height)}
	uv_offset /= scale

	uv^ = {
		origin,
		{origin.x + uv_offset.x, origin.y},
		{origin.x, origin.y + uv_offset.y},
		origin + uv_offset,
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
Draw_Text_Req :: struct {
	text:       string,
	transform:  mat4,
	bitmap:     ^Bitmap,
	color:      Maybe([4]f32),
	wrap_width: Maybe(f32),
}
Draw_Text_Batch :: struct {
	color:         [4]f32,
	bitmap:        ^Bitmap,
	char:          rune,
	transform_idx: u32,
}
Glyph :: struct {
	vert_offset: i32,
	offset:      [2]f32,
	x_advance:   f32,
}

draw_text :: proc(r: ^Renderer, req: Draw_Text_Req) {
	bitmap := req.bitmap == nil ? &r._default_bitmap : req.bitmap
	color, has_color := req.color.?
	if !has_color {
		color = default_text_color
	}
	wrap_width, has_wrap_width := req.wrap_width.?
	pen: [2]f32
	pen.y = -bitmap.base

	for c in req.text {
		if r._lens[.TEXT_DRAW] + r._lens[.DRAW_REQ] == MAX_RENDER_NODES do return
		glyph, ok := bitmap.glyphs[c]
		glyph = ok ? glyph : bitmap.glyphs[' ']
		idx := r._lens[.TEXT_DRAW]
		pos := pen + glyph.offset
		pen_transform := lal.matrix4_from_trs(
			[3]f32{pos.x, pos.y, 0},
			lal.QUATERNIONF32_IDENTITY,
			[3]f32{1, 1, 1},
		)
		r._text_draw_transforms[idx] = req.transform * pen_transform
		batch := Draw_Text_Batch {
			color         = color,
			bitmap        = bitmap,
			char          = c,
			transform_idx = idx,
		}
		r._draw_text_batch[idx] = batch
		r._lens[.TEXT_DRAW] += 1
		pen.x += glyph.x_advance
		if (c != ' ' && c != '\n') || pen.x < wrap_width do continue
		pen.x = 0
		pen.y -= bitmap.y_advance
	}
}

@(private)
sort_text_draw_call_reqs :: proc(r: ^Renderer) {
	slice.sort_by_cmp(
		r._draw_text_batch[:r._lens[.TEXT_DRAW]],
		proc(i, j: Draw_Text_Batch) -> (ordering: slice.Ordering) {
			ordering = slice.cmp(i.bitmap, j.bitmap)
			ordering = ordering == .Equal ? slice.cmp(i.color, j.color) : ordering
			ordering = ordering == .Equal ? slice.cmp(i.char, j.char) : ordering
			return
		},
	)
}

@(private)
copy_text_draw_reqs :: proc(r: ^Renderer) {
	// copies transforms and indirect draw calls to frame mem
	if r._lens[.DRAW_REQ] == 0 do return
	model_matrices := &r._frame_transfer_mem.transform.ms
	normal_matrices := &r._frame_transfer_mem.transform.ns
	end_iter := r._lens[.TEXT_DRAW]
	matrix_offset := r._lens[.DRAW_REQ]
	for i: u32 = 0; i < end_iter; i += 1 {
		req := r._draw_text_batch[i]
		idx := matrix_offset + i
		model_matrices[idx] = r._text_draw_transforms[req.transform_idx]
		normal_matrices[idx] = lal.inverse_transpose(model_matrices[0])
	}
}

text_pass :: proc(r: ^Renderer) {
	// TODO render da text, dont be lazy!
	if r._lens[.TEXT_DRAW] == 0 do return
	sdl.BindGPUGraphicsPipeline(r._render_pass, r._pbr_text_pipeline)
	sdl.BindGPUIndexBuffer(r._render_pass, r._quad_idx_binding, ._16BIT)
	bitmap: ^Bitmap
	color: [4]f32 = 1
	char: rune = r._draw_text_batch[0].char
	first_instance: u32 = 0
	for batch, i in r._draw_text_batch[:r._lens[.TEXT_DRAW]] {
		if batch.bitmap != bitmap {
			bitmap = batch.bitmap
			color = batch.color
			bind_bitmap(r, bitmap, color)
		}
		if batch.color != color {
			color = batch.color
			bind_text_frag_ubo(r, bitmap, color)
		}
		if batch.char != char {
			idx := u32(i)
			num_instances := idx - first_instance
			text_draw_call(r, bitmap, char, first_instance, num_instances)
			first_instance = idx
		}
	}
	num_instances := r._lens[.TEXT_DRAW] - first_instance
	text_draw_call(r, bitmap, char, first_instance, num_instances)
}

@(private)
bind_bitmap :: proc(r: ^Renderer, bitmap: ^Bitmap, color: [4]f32) {
	sdl.BindGPUVertexBuffers(
		r._render_pass,
		0,
		cast([^]sdl.GPUBufferBinding)&bitmap.vert_bindings,
		len(bitmap.vert_bindings),
	)
	sdl.BindGPUFragmentSamplers(
		r._render_pass,
		0,
		cast([^]sdl.GPUTextureSamplerBinding)&bitmap.material.bindings,
		len(bitmap.material.bindings),
	)
	bind_text_frag_ubo(r, bitmap, color)
}

@(private)
bind_text_frag_ubo :: proc(r: ^Renderer, bitmap: ^Bitmap, color: [4]f32) {
	draw_ubo := Frag_Draw_UBO {
		diffuse_override = color,
		normal_scale     = bitmap.material.normal_scale,
		ao_strength      = bitmap.material.ao_strength,
	}
	sdl.PushGPUFragmentUniformData(r._render_cmd_buf, 1, &(draw_ubo), size_of(Frag_Draw_UBO))
}

@(private)
text_draw_call :: proc(
	r: ^Renderer,
	bitmap: ^Bitmap,
	char: rune,
	first_instance: u32,
	num_instances: u32,
) {
	glyph, ok := bitmap.glyphs[char]
	if !ok {
		log.panicf(
			"rune: %c not in bitmap: %s but made it past text draw somehow",
			char,
			bitmap.name,
		)
	}
	// text transforms come after normal 3d objects
	first_instace_text := r._lens[.DRAW_REQ] + first_instance
	sdl.DrawGPUIndexedPrimitives(
		r._render_pass,
		4,
		num_instances,
		0,
		glyph.vert_offset,
		first_instace_text,
	)
}

