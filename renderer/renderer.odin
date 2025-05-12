package renderer

import "../constants"
import "../lib/glist"
import "../lib/pool"
import sdl "vendor:sdl3"
import sdli "vendor:sdl3/image"

import "base:runtime"
import "core:log"
import lal "core:math/linalg"
import "core:mem"
import os "core:os/os2"
import "core:path/filepath"
import "core:strings"

sdl_ok_panic :: proc(ok: bool) {
	if !ok do log.panicf("SDL Error: {}", sdl.GetError())
}
sdl_nil_panic :: proc(ptr: rawptr) {
	if ptr == nil do log.panicf("SDL Error: {}", sdl.GetError())
}

sdl_err :: proc {
	sdl_ok_panic,
	sdl_nil_panic,
}

MAX_BLOCK_COUNT :: 4096

Renderer :: struct {
	gpu:          ^sdl.GPUDevice,
	window:       ^sdl.Window,
	pipeline:     ^sdl.GPUGraphicsPipeline,
	blocks:       pool.Pool(Node),
	copy_cmd_buf: ^sdl.GPUCommandBuffer,
	copy_pass:    ^sdl.GPUCopyPass,
}

Node :: struct {
	mat:      matrix[4, 4]f32,
	children: []pool.Pool_Key,
}

// figure out card rendering

Vertex_Data :: struct {
	pos: [3]f32,
	uv:  [2]f32,
}

Mesh :: struct {
	verts: []Vertex_Data,
	idxs:  []u16,
}

GPU_Mesh :: struct {
	vert_buf: ^sdl.GPUBuffer,
	idx_buf:  ^sdl.GPUBuffer,
}

@(private)
make_entity_pipeline :: proc(r: Renderer) -> (pipeline: ^sdl.GPUGraphicsPipeline) {
	vert_shader := load_shader(r.gpu, "default.spv.vert", {uniform_buffers = 1})
	frag_shader := load_shader(r.gpu, "default.spv.frag", {})

	vertex_attrs := []sdl.GPUVertexAttribute {
		{location = 0, format = .FLOAT3, offset = u32(offset_of(Vertex_Data, pos))},
		{location = 1, format = .FLOAT2, offset = u32(offset_of(Vertex_Data, uv))},
	}
	pipeline = sdl.CreateGPUGraphicsPipeline(
		r.gpu,
		{
			vertex_shader = vert_shader,
			fragment_shader = frag_shader,
			primitive_type = .TRIANGLELIST,
			vertex_input_state = {
				num_vertex_buffers = 1,
				vertex_buffer_descriptions = &(sdl.GPUVertexBufferDescription {
						slot = 0,
						pitch = size_of(Vertex_Data),
					}),
				num_vertex_attributes = u32(len(vertex_attrs)),
				vertex_attributes = raw_data(vertex_attrs),
			},
			target_info = {
				num_color_targets = 1,
				color_target_descriptions = &(sdl.GPUColorTargetDescription {
						format = sdl.GetGPUSwapchainTextureFormat(r.gpu, r.window),
					}),
			},
		},
	)
	sdl.ReleaseGPUShader(r.gpu, vert_shader)
	sdl.ReleaseGPUShader(r.gpu, frag_shader)
	return
}

new :: proc(
	gpu: ^sdl.GPUDevice,
	window: ^sdl.Window,
) -> (
	r: Renderer,
	err: runtime.Allocator_Error,
) {
	ok := sdl.ClaimWindowForGPUDevice(gpu, window);sdl_err(ok)
	r.gpu = gpu
	r.window = window

	r.pipeline = make_entity_pipeline(r)

	r.nodes = pool.make(Node, MAX_ENTITY_COUNT) or_return
	return
}

start_copy_pass :: proc(r: ^Renderer) {
	assert(r.copy_cmd_buf == nil)
	assert(r.copy_pass == nil)
	r.copy_cmd_buf = sdl.AcquireGPUCommandBuffer(r.gpu);sdl_err(copy_cmd_buf)
	r.copy_pass = sdl.BeginGPUCopyPass(copy_cmd_buf)
}

end_copy_pass :: proc(r: ^Renderer) {
	assert(r.copy_cmd_buf != nil)
	assert(r.copy_pass != nil)
	sdl.EndGPUCopyPass(r.copy_pass)
	r.copy_pass = nil
	ok := sdl.SubmitGPUCommandBuffer(r.copy_cmd_buf);sdl_err(ok)
	r.copy_cmd_buf = nil
}

load_mesh :: proc(r: ^Renderer, m: Mesh) -> (gpu_mesh: GPU_Mesh) {
	assert(r.copy_pass != nil)
	assert(r.copy_cmd_buf != nil)
	idxs_size := len(m.idxs) * size_of(u16)
	verts_size := len(m.verts) * size_of(Vertex_Data)

	verts_size_u32 := u32(verts_size)
	idxs_byte_size_u32 := u32(idxs_size)
	gpu_mesh.vert_buf = sdl.CreateGPUBuffer(
		r.gpu,
		{usage = {.VERTEX}, size = verts_size_u32},
	);sdl_err(gpu_mesh.vert_buf)
	gpu_mesh.idx_buf = sdl.CreateGPUBuffer(
		r.gpu,
		{usage = {.INDEX}, size = idx_byte_size_u32},
	);sdl_err(gpu_mesh.idx_buf)

	transfer_buf := sdl.CreateGPUTransferBuffer(
		r.gpu,
		{usage = .UPLOAD, size = verts_size_u32 + idxs_byte_size_u32},
	);sdl_err(transfer_buf)
	transfer_mem := transmute([^]byte)sdl.MapGPUTransferBuffer(
		r.gpu,
		transfer_buf,
		false,
	);sdl_err(transfer_mem)
	mem.copy(transfer_mem, raw_data(m.verts), verts_size)
	mem.copy(transfer_mem[verts_size:], raw_data(m.idxs), idxs_size)
	sdl.UnmapGPUTransferBuffer(r.gpu, transfer_buf)
	sdl.UploadToGPUBuffer(
		r.copy_pass,
		{transfer_buffer = transfer_buf},
		{buffer = vert_buf, size = verts_size_u32},
		false,
	)
	sdl.UploadToGPUBuffer(
		r.copy_pass,
		{transfer_buffer = transfer_buf, offset = verts_size_u32},
		{buffer = idx_buf, size = idx_byte_size_u32},
		false,
	)
	return
}

load_texture :: proc(r: ^Renderer, file_name: string) -> (texture: ^sdl.GPUTexture) {
	temp_mem := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp_mem)

	file_path := filepath.join(
		{constants.dist_dir, constants.texture_dir, file_name},
		allocator = context.temp_allocator,
	)
	file_path_cstring := strings.clone_to_cstring(file_path, allocator = context.temp_allocator)
	surface := sdli.Load(file_path_cstring);sdl_err(surface)
	defer sdl.DestroySurface(surface)
	width := u32(surface.w)
	height := u32(surface.h)

	texture = sdl.CreateGPUTexture(
		r.gpu,
		{
			type = .D2,
			format = .R8G8B8A8_UNORM_SRGB,
			usage = {.SAMPLER},
			width = width,
			height = height,
			layer_count_or_depth = 1,
			num_levels = 1,
		},
	);sdl_err(texture)
	len_pixels := surface.w * surface.h * 4
	len_pixels_u32 := u32(len_pixels)
	tex_transfer_buf := sdl.CreateGPUTransferBuffer(
		r.gpu,
		{usage = .UPLOAD, size = len_pixels_u32},
	);sdl_err(tex_transfer_buf)
	tex_transfer_mem := sdl.MapGPUTransferBuffer(
		r.gpu,
		tex_transfer_buf,
		false,
	);sdl_err(tex_transfer_mem)
	mem.copy(tex_transfer_mem, surface.pixels, len_pixels)
	sdl.UnmapGPUTransferBuffer(r.gpu, tex_transfer_buf)
	sdl.UploadToGPUTexture(
		r.copy_pass,
		{transfer_buffer = tex_transfer_buf},
		{texture = texture, w = width, h = height, d = 1},
		false,
	)
	return
}

