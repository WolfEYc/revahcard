package renderer

import "../constants"
import gltf "../shared/glTF2"
import sdl "vendor:sdl3"
import sdli "vendor:sdl3/image"

import "core:log"
import lal "core:math/linalg"
import "core:mem"
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


Renderer :: struct {
	gpu:             ^sdl.GPUDevice,
	window:          ^sdl.Window,
	entity_pipeline: ^sdl.GPUGraphicsPipeline,
}
Node :: struct {
	name:     string,
	mat:      matrix[4, 4]f32,
	parent:   EntityIdx,
	children: []EntityIdx,
	mesh:     EntityIdx,
}

Mesh :: struct {
	vertices: EntityIdx,
	indices:  EntityIdx,
	material: EntityIdx,
}

Material :: struct {
	name:            string,
	pipeline:        EntityIdx,
	base_color_tex:  EntityIdx,
	metal_rough_tex: EntityIdx,
	normal_tex:      EntityIdx,
	ao_tex:          EntityIdx,
	emissive_tex:    EntityIdx,
	alpha_mode:      gltf.Material_Alpha_Mode,
	alpha_cutoff:    f32,
	emissive_factor: [3]f32,
	double_sided:    bool,
}

Texture :: struct {
	name:    string,
	texture: EntityIdx,
	sampler: EntityIdx,
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

	data.textures[0]

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

load_texture :: proc(r: ^Renderer, file: cstring) -> (texture: ^sdl.GPUTexture) {
	surface := sdli.Load(file);sdl_err(surface)
	surface.format
	texture = sdl.CreateGPUTexture(
		r.gpu,
		{
			format = .R8G8B8A8_UNORM,
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

