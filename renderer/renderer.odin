package renderer

import "../lib/glist"
import "../lib/pool"
import sdl "vendor:sdl3"
import sdli "vendor:sdl3/image"

import "base:runtime"
import "core:encoding/json"
import "core:log"
import lal "core:math/linalg"
import "core:mem"
import os "core:os/os2"
import "core:path/filepath"
import "core:strings"

shader_dir :: "shaders"
dist_dir :: "dist"
out_shader_ext :: "spv"
target_env :: "vulkan1.4"
texture_dir :: "textures"
model_dir :: "models"
material_dir :: "materials"
materials_dist_dir :: dist_dir + os.Path_Separator_String + material_dir
models_dist_dir :: dist_dir + os.Path_Separator_String + model_dir

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

MAX_NODE_COUNT :: 65536
MAX_MESH_COUNT :: 1024
MAX_MATERIAL_COUNT :: 1024

Renderer :: struct {
	gpu:              ^sdl.GPUDevice,
	window:           ^sdl.Window,
	pipeline:         ^sdl.GPUGraphicsPipeline,
	nodes:            pool.Pool(Node),
	meshes:           glist.Glist(GPU_Mesh),
	materials:        glist.Glist(GPU_Material),
	mesh_catalog:     map[string]glist.Glist_Idx,
	material_catalog: map[string]glist.Glist_Idx,
	copy_cmd_buf:     ^sdl.GPUCommandBuffer,
	copy_pass:        ^sdl.GPUCopyPass,
	proj_mat:         matrix[4, 4]f32,
	view_mat:         matrix[4, 4]f32,
	//            material   mesh     node
	render_map:       [dynamic][dynamic][dynamic]pool.Pool_Key,
}

Node :: struct {
	parent:           pool.Pool_Key,
	local_transform:  matrix[4, 4]f32,
	mesh:             glist.Glist_Idx,
	material:         glist.Glist_Idx,

	// computed at render time
	visited:          bool,
	global_transform: matrix[4, 4]f32,
}

GPU_Mesh :: struct {
	vert_buf: ^sdl.GPUBuffer,
	idx_buf:  ^sdl.GPUBuffer,
	num_idxs: u32,
}
GPU_Material :: struct {
	base: sdl.GPUTextureSamplerBinding,
}

@(private)
make_entity_pipeline :: proc(r: Renderer) -> (pipeline: ^sdl.GPUGraphicsPipeline) {
	vert_shader := load_shader(r.gpu, "default.spv.vert", {uniform_buffers = 1})
	frag_shader := load_shader(r.gpu, "default.spv.frag", {uniform_buffers = 1})

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

Camera_Settings :: struct {
	fovy: f32,
	near: f32,
	far:  f32,
}

DEFAULT_CAM :: Camera_Settings {
	fovy = 90,
	near = 0.0001,
	far  = 1000,
}

new :: proc(
	gpu: ^sdl.GPUDevice,
	window: ^sdl.Window,
	cam: Camera_Settings = DEFAULT_CAM,
) -> (
	r: Renderer,
	err: runtime.Allocator_Error,
) {
	ok := sdl.ClaimWindowForGPUDevice(gpu, window);sdl_err(ok)
	r.gpu = gpu
	r.window = window

	r.pipeline = make_entity_pipeline(r)

	r.nodes = pool.make(Node, MAX_NODE_COUNT) or_return
	r.meshes = glist.make(GPU_Mesh, MAX_MESH_COUNT) or_return
	r.materials = glist.make(GPU_Material, MAX_MATERIAL_COUNT) or_return
	r.mesh_catalog = make(map[string]glist.Glist_Idx)
	r.material_catalog = make(map[string]glist.Glist_Idx)

	win_size: [2]i32
	ok = sdl.GetWindowSize(window, &win_size.x, &win_size.y);sdl_err(ok)
	aspect := f32(win_size.x) / f32(win_size.y)
	r.proj_mat = lal.matrix4_perspective_f32(lal.to_radians(cam.fovy), aspect, cam.near, cam.far)
	return
}

start_copy_pass :: proc(r: ^Renderer) {
	assert(r.copy_cmd_buf == nil)
	assert(r.copy_pass == nil)
	r.copy_cmd_buf = sdl.AcquireGPUCommandBuffer(r.gpu);sdl_err(r.copy_cmd_buf)
	r.copy_pass = sdl.BeginGPUCopyPass(r.copy_cmd_buf)
}

end_copy_pass :: proc(r: ^Renderer) {
	assert(r.copy_cmd_buf != nil)
	assert(r.copy_pass != nil)
	sdl.EndGPUCopyPass(r.copy_pass)
	r.copy_pass = nil
	ok := sdl.SubmitGPUCommandBuffer(r.copy_cmd_buf);sdl_err(ok)
	r.copy_cmd_buf = nil
}

load_all_assets :: proc(r: ^Renderer) -> (err: runtime.Allocator_Error) {
	start_copy_pass(r)
	load_all_materials(r) or_return
	load_all_meshes(r) or_return
	end_copy_pass(r)
	return
}

@(private)
load_mesh :: proc(r: ^Renderer, file_name: string) -> (err: runtime.Allocator_Error) {
	assert(r.copy_pass != nil)
	assert(r.copy_cmd_buf != nil)
	temp_mem := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp_mem)

	mesh := obj_load(file_name)
	idxs_size := len(mesh.idxs) * size_of(u16)
	verts_size := len(mesh.verts) * size_of(Vertex_Data)

	verts_size_u32 := u32(verts_size)
	idx_byte_size_u32 := u32(idxs_size)
	gpu_mesh: GPU_Mesh
	gpu_mesh.vert_buf = sdl.CreateGPUBuffer(
		r.gpu,
		{usage = {.VERTEX}, size = verts_size_u32},
	);sdl_err(gpu_mesh.vert_buf)
	gpu_mesh.idx_buf = sdl.CreateGPUBuffer(
		r.gpu,
		{usage = {.INDEX}, size = idx_byte_size_u32},
	);sdl_err(gpu_mesh.idx_buf)
	idx := glist.insert(&r.meshes, gpu_mesh) or_return
	r.mesh_catalog[file_name] = idx

	transfer_buf := sdl.CreateGPUTransferBuffer(
		r.gpu,
		{usage = .UPLOAD, size = verts_size_u32 + idx_byte_size_u32},
	);sdl_err(transfer_buf)
	transfer_mem := transmute([^]byte)sdl.MapGPUTransferBuffer(
		r.gpu,
		transfer_buf,
		false,
	);sdl_err(transfer_mem)
	mem.copy(transfer_mem, raw_data(mesh.verts), verts_size)
	mem.copy(transfer_mem[verts_size:], raw_data(mesh.idxs), idxs_size)
	sdl.UnmapGPUTransferBuffer(r.gpu, transfer_buf)
	sdl.UploadToGPUBuffer(
		r.copy_pass,
		{transfer_buffer = transfer_buf},
		{buffer = gpu_mesh.vert_buf, size = verts_size_u32},
		false,
	)
	sdl.UploadToGPUBuffer(
		r.copy_pass,
		{transfer_buffer = transfer_buf, offset = verts_size_u32},
		{buffer = gpu_mesh.idx_buf, size = idx_byte_size_u32},
		false,
	)
	return
}

load_all_meshes :: proc(r: ^Renderer) -> (err: runtime.Allocator_Error) {
	f, ferr := os.open(models_dist_dir)
	if err != nil {
		log.fatalf("err in opening materials dist dir to load all materials, reason: %v", ferr)
	}
	it := os.read_directory_iterator_create(f)
	for file_info in os.read_directory_iterator(&it) {
		load_mesh(r, file_info.name) or_return
	}
	os.read_directory_iterator_destroy(&it)
	return
}

@(private)
load_texture :: proc(r: ^Renderer, file_name: string) -> (tex: sdl.GPUTextureSamplerBinding) {
	temp_mem := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp_mem)

	file_path := filepath.join(
		{dist_dir, texture_dir, file_name},
		allocator = context.temp_allocator,
	)
	file_path_cstring := strings.clone_to_cstring(file_path, allocator = context.temp_allocator)
	surface := sdli.Load(file_path_cstring);sdl_err(surface)
	defer sdl.DestroySurface(surface)
	width := u32(surface.w)
	height := u32(surface.h)

	tex.texture = sdl.CreateGPUTexture(
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
	);sdl_err(tex.texture)
	len_pixels := int(surface.w * surface.h * 4)
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
		{texture = tex.texture, w = width, h = height, d = 1},
		false,
	)
	tex.sampler = sdl.CreateGPUSampler(r.gpu, {});sdl_err(tex.sampler)
	return
}

Material_Meta :: struct {
	base: string `json:"base"`,
}

@(private)
load_material :: proc(r: ^Renderer, file_name: string) -> (err: runtime.Allocator_Error) {
	temp_mem := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp_mem)

	file_path := filepath.join(
		{dist_dir, model_dir, file_name},
		allocator = context.temp_allocator,
	)
	data, file_err := os.read_entire_file_from_path(file_path, allocator = context.temp_allocator)
	if file_err.(runtime.Allocator_Error) != .None {
		err = file_err.(runtime.Allocator_Error)
		return
	}
	if file_err != nil {
		log.panicf("err in loading material %s reason: %v", file_name, err)
	}

	meta: Material_Meta
	unmarshal_err := json.unmarshal(data, &meta, allocator = context.temp_allocator)
	if unmarshal_err != nil {
		log.fatalf("failed to unmarshal model meta json, %s, reason: %v", file_name, unmarshal_err)
	}


	material: GPU_Material
	material.base = load_texture(r, meta.base)

	idx := glist.insert(&r.materials, material) or_return
	r.material_catalog[file_name] = idx
	return
}

load_all_materials :: proc(r: ^Renderer) -> (err: runtime.Allocator_Error) {
	f, ferr := os.open(materials_dist_dir)
	if err != nil {
		log.fatalf("err in opening materials dist dir to load all materials, reason: %v", ferr)
	}
	it := os.read_directory_iterator_create(f)
	for file_info in os.read_directory_iterator(&it) {
		load_material(r, file_info.name) or_return
	}
	os.read_directory_iterator_destroy(&it)
	return
}

insert_node_defered :: proc(
	r: ^Renderer,
	n: Node,
) -> (
	key: pool.Pool_Key,
	err: runtime.Allocator_Error,
) {
	key = pool.insert_defered(&r.nodes, n) or_return
	return
}

@(private)
flush_node_inserts :: proc(r: ^Renderer) -> (err: runtime.Allocator_Error) {
	pending_inserts := pool.pending_inserts(&r.nodes)
	pool.flush_inserts(&r.nodes)
	for n_idx in pending_inserts {
		n_key := pool.idx_to_key(&r.nodes, n_idx)
		n, ok := pool.get(&r.nodes, n_key)
		if !ok do continue
		if n.material >= u32(len(r.render_map)) {
			resize(&r.render_map, n.material + 1) or_return
		}
		if n.mesh >= u32(len(r.render_map[n.material])) {
			resize(&r.render_map[n.material], n.mesh + 1) or_return
		}
		append(&r.render_map[n.material][n.mesh], n_key) or_return
	}
	return
}

MAX_DYNAMIC_BATCH :: 64
render :: proc(r: ^Renderer) {
	Mvp_Ubo :: struct {
		mvps: [MAX_DYNAMIC_BATCH]matrix[4, 4]f32,
	}
	mvp_ubo: Mvp_Ubo

	cmd_buf := sdl.AcquireGPUCommandBuffer(r.gpu);sdl_err(cmd_buf)
	defer {ok := sdl.SubmitGPUCommandBuffer(cmd_buf);sdl_err(ok)}

	swapchain_tex: ^sdl.GPUTexture
	ok := sdl.WaitAndAcquireGPUSwapchainTexture(
		cmd_buf,
		r.window,
		&swapchain_tex,
		nil,
		nil,
	);sdl_err(ok)
	if swapchain_tex == nil do return

	color_target := sdl.GPUColorTargetInfo {
		texture     = swapchain_tex,
		load_op     = .CLEAR,
		clear_color = {0, 0, 0, 0},
		store_op    = .STORE,
	}
	render_pass := sdl.BeginGPURenderPass(cmd_buf, &color_target, 1, nil)
	defer sdl.EndGPURenderPass(render_pass)
	sdl.BindGPUGraphicsPipeline(render_pass, r.pipeline)
	vp := r.proj_mat * r.view_mat

	flush_node_inserts(r)
	// draw
	for material_meshes, material_idx in r.render_map {
		if len(material_meshes) == 0 do continue

		material := glist.get(&r.materials, glist.Glist_Idx(material_idx))
		sdl.BindGPUFragmentSamplers(render_pass, 0, &(material.base), 1)
		for mesh_nodes, mesh_idx in material_meshes {
			num_instances := u32(len(mesh_nodes))
			if num_instances == 0 do continue
			//TODO if num_instances > MAX_DYNAMIC_BATCH gotta looperino

			for node_key, instance_idx in mesh_nodes {
				node, ok := pool.get(&r.nodes, node_key);assert(ok)
				mvp_ubo.mvps[instance_idx] = vp * node.global_transform
			}
			mesh := glist.get(&r.meshes, glist.Glist_Idx(mesh_idx))
			sdl.PushGPUVertexUniformData(
				cmd_buf,
				0,
				&(mvp_ubo),
				size_of(r.proj_mat) * num_instances,
			)
			sdl.BindGPUVertexBuffers(
				render_pass,
				0,
				&(sdl.GPUBufferBinding{buffer = mesh.vert_buf}),
				1,
			)
			sdl.BindGPUIndexBuffer(
				render_pass,
				sdl.GPUBufferBinding{buffer = mesh.idx_buf},
				._16BIT,
			)
			sdl.DrawGPUIndexedPrimitives(render_pass, mesh.num_idxs, num_instances, 0, 0, 0)
		}
	}
}

