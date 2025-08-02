package renderer

import sdle "../lib/sdle"
import "base:runtime"
import "core:mem"
import os "core:os/os2"
import "core:path/filepath"
import "core:strings"
import sdl "vendor:sdl3"
import sdli "vendor:sdl3/image"


load_bm :: proc(r: ^Renderer, filename: string) -> (binding: sdl.GPUTextureSamplerBinding) {
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
	binding.texture = sdl.CreateGPUTexture(
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
	);sdle.err(binding.texture)
	sdl.UploadToGPUTexture(
		r._copy_pass,
		{transfer_buffer = trans, pixels_per_row = w, rows_per_layer = h},
		{texture = binding.texture, w = w, h = h, d = 1},
		false,
	)
	sdl.ReleaseGPUTransferBuffer(r._gpu, trans)
	binding.sampler = r._default_text_sampler
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
}

