package renderer

import "../constants"
import "../shared/astc"
import gltf "../shared/glTF2"
import "../shared/glist"
import "../shared/pool"
import sdl "vendor:sdl3"

import "base:runtime"
import "core:log"
import lal "core:math/linalg"
import "core:mem"
import os "core:os/os2"
import "core:path/filepath"

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

MAX_ENTITY_COUNT :: 4096
MAX_MESH_COUNT :: 1024
MAX_MATERIAL_COUNT :: 512
MAX_TEXTURE_COUNT :: 512
MAX_SAMPLER_COUNT :: 512
MAX_IMAGE_COUNT :: 256

Renderer :: struct {
	gpu:          ^sdl.GPUDevice,
	window:       ^sdl.Window,
	pbr_pipeline: ^sdl.GPUGraphicsPipeline,
	copy_pass:    ^sdl.GPUCopyPass,
	nodes:        glist.Glist(Node),
	meshes:       glist.Glist(Mesh),
	materials:    glist.Glist(Material),
	textures:     glist.Glist(Texture),
	images:       glist.Glist(^sdl.GPUTexture),
	samplers:     glist.Glist(^sdl.GPUSampler),
	vertices:     glist.Glist(^sdl.GPUVertex),
}

Node :: struct {
	name:     string,
	mat:      matrix[4, 4]f32,
	children: []glist.Glist_Idx,
	mesh:     glist.Glist_Idx,
}

Mesh :: struct {
	vertices: glist.Glist_Idx,
	indices:  glist.Glist_Idx,
	material: glist.Glist_Idx,
}

Material :: struct {
	name:            string,
	pipeline:        glist.Glist_Idx,
	base_color_tex:  glist.Glist_Idx,
	metal_rough_tex: glist.Glist_Idx,
	normal_tex:      glist.Glist_Idx,
	ao_tex:          glist.Glist_Idx,
	emissive_tex:    glist.Glist_Idx,
	alpha_mode:      gltf.Material_Alpha_Mode,
	alpha_cutoff:    f32,
	emissive_factor: [3]f32,
	double_sided:    bool,
}

Texture :: struct {
	name:    string,
	image:   pool.Pool_Key,
	sampler: pool.Pool_Key,
}

Vertex_Data :: struct {
	pos: [3]f32,
	uv:  [2]f32,
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
}

make :: proc(
	gpu: ^sdl.GPUDevice,
	window: ^sdl.Window,
) -> (
	r: Renderer,
	err: runtime.Allocator_Error,
) {
	ok = sdl.ClaimWindowForGPUDevice(gpu, window);sdl_err(ok)
	r.gpu = gpu
	r.window = window

	r.pbr_pipeline = make_entity_pipeline(r)

	r.nodes = pool.make(Node, MAX_ENTITY_COUNT) or_return
	r.meshes = glist.make(Mesh, MAX_MESH_COUNT) or_return
	r.materials = glist.make(Material, MAX_MATERIAL_COUNT) or_return
	r.textures = glist.make(Texture, MAX_TEXTURE_COUNT) or_return
	r.images = glist.make(^sdl.GPUTexture, MAX_IMAGE_COUNT) or_return
	r.samplers = glist.make(^sdl.GPUSampler, MAX_SAMPLER_COUNT) or_return
	return
}

load_glb :: proc(r: ^Renderer, file_name: string) {
	file_path := filepath.join({constants.dist_dir, constants.shader_dir, file_name})

	data, err := gltf.load_from_file(file_path)
	if err != nil {
		log.panicf("gltf load err: %v", err)
	}
	defer gltf.unload(data)

	copy_cmd_buf := sdl.AcquireGPUCommandBuffer(r.gpu);sdl_err(copy_cmd_buf)
	defer {ok := sdl.SubmitGPUCommandBuffer(copy_cmd_buf);sdl_err(ok)}

	copy_pass := sdl.BeginGPUCopyPass(copy_cmd_buf)
	defer sdl.EndGPUCopyPass(copy_pass)

	for node, i in data.nodes {
		node_name, has_name := node.name.?
		if !has_name {
			log.warnf(
				"while loading %s, node at idx=%d has no name, skipping node...",
				file_name,
				i,
			)
			continue
		}
		mesh_idx, has_mesh := node.mesh.?
		if !has_mesh {
			// insert node with no mesh
			continue
		}

		mesh := data.meshes[mesh_idx]
		mesh_name, mesh_has_name := mesh.name
		for primitive, i in mesh.primitives {
			indices_idx, indices_ok := primitive.indices.?
			if !indices_ok {
				log.warnf(
					"while loading %s, renderer only supports indexed meshes, mesh_name=%s, primitive_idx=%d, skipping primitive...",
					file_name,
					mesh.name,
					i,
				)
				continue
			}
			vert_pos_idx, vert_pos_ok := primitive.attributes["POSITION"]
			if !vert_pos_ok {
				log.warnf(
					"while loading %s, no vert positions found, mesh_name=%s, primitive_idx=%d, skipping primitive...",
					file_name,
					mesh.name,
					i,
				)
				continue
			}

			indicies := gltf.buffer_slice(data, indices_idx).([]u16)
			primitive.material
		}
	}

	//cpy to gpu
	// {
	// 	transfer_buf := sdl.CreateGPUTransferBuffer(
	// 		r.gpu,
	// 		{usage = .UPLOAD, size = vertices_byte_size_u32 + indices_byte_size_u32},
	// 	)
	// 	transfer_mem := transmute([^]byte)sdl.MapGPUTransferBuffer(gpu, transfer_buf, false)
	// 	mem.copy(transfer_mem, raw_data(vertices), vertices_byte_size)
	// 	mem.copy(transfer_mem[vertices_byte_size:], raw_data(indices), indices_byte_size)
	// 	sdl.UnmapGPUTransferBuffer(gpu, transfer_buf)


	// 	sdl.UploadToGPUBuffer(
	// 		copy_pass,
	// 		{transfer_buffer = transfer_buf},
	// 		{buffer = vertex_buf, size = vertices_byte_size_u32},
	// 		false,
	// 	)
	// 	sdl.UploadToGPUBuffer(
	// 		copy_pass,
	// 		{transfer_buffer = transfer_buf, offset = vertices_byte_size_u32},
	// 		{buffer = indices_buf, size = indices_byte_size_u32},
	// 		false,
	// 	)
	// }


}

load_texture :: proc(r: ^Renderer, file: string) -> (texture: ^sdl.GPUTexture) {
	file_path := filepath.join({constants.dist_dir, constants.texture_dir, file_name})
	file := os.open(file_path)
	astc_header := astc.load()
	texture = sdl.CreateGPUTexture(
		r.gpu,
		{
			format = .ASTC_4x4_UNORM,
			usage = {.SAMPLER},
			width = u32(surface.w),
			height = u32(surface.h),
			layer_count_or_depth = 1,
			num_levels = 1,
		},
	);sdl_err(texture)
	return
}


load_vert_buf :: proc(r: ^Renderer, vert_data: []Vertex_Data) -> (vert_buf: ^sdl.GPUBuffer) {
	// vertices := []Vertex_Data {
	// 	{pos = {-0.5, 0.5, 0}, color = {1, 0, 0, 1}}, // tl
	// 	{pos = {0.5, 0.5, 0}, color = {0, 1, 1, 1}}, // tr
	// 	{pos = {-0.5, -0.5, 0}, color = {0, 1, 0, 1}}, // bl
	// 	{pos = {0.5, -0.5, 0}, color = {1, 1, 0, 1}}, // br
	// }
	vertices_byte_size := len(vert_data) * size_of(Vertex_Data)
	vertices_byte_size_u32 := u32(vertices_byte_size)
	vert_buf = sdl.CreateGPUBuffer(r.gpu, {usage = {.VERTEX}, size = vertices_byte_size_u32})
	return
}

load_idx_buf :: proc(r: ^Renderer, indices: []u16) -> (idx_buf: ^sdl.GPUBuffer) {
	// indices := []u16{0, 1, 2, 2, 1, 3}
	indices_len := len(indices)
	indices_len_u32 := u32(indices_len)
	indices_byte_size := indices_len * size_of(u16)
	indices_byte_size_u32 := u32(indices_byte_size)
	indices_buf := sdl.CreateGPUBuffer(r.gpu, {usage = {.INDEX}, size = indices_byte_size_u32})
	return
}

