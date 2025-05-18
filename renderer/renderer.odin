package renderer

import "../lib/glist"
import "../lib/pool"
import sdl "vendor:sdl3"
import sdli "vendor:sdl3/image"

import "../lib/sdle"
import "base:runtime"
import "core:encoding/json"
import "core:io"
import "core:log"
import lal "core:math/linalg"
import "core:mem"
import os "core:os/os2"
import "core:path/filepath"
import "core:slice"
import "core:strings"

shader_dir :: "shaders"
dist_dir :: "dist"
out_shader_ext :: "spv"
texture_dir :: "textures"
model_dir :: "models"
material_dir :: "materials"
materials_dist_dir :: dist_dir + os.Path_Separator_String + material_dir
mesh_dist_dir :: dist_dir + os.Path_Separator_String + model_dir


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
	parent:            pool.Pool_Key,
	pos:               [3]f32,
	rot:               quaternion128,
	scale:             [3]f32,
	mesh:              glist.Glist_Idx,
	material:          glist.Glist_Idx,

	// computed at render time
	_visited:          bool,
	_global_transform: matrix[4, 4]f32,
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
	frag_shader := load_shader(r.gpu, "default.spv.frag", {samplers = 1})

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
	ok := sdl.ClaimWindowForGPUDevice(gpu, window);sdle.sdl_err(ok)
	r.gpu = gpu
	r.window = window

	r.pipeline = make_entity_pipeline(r)

	r.nodes = pool.make(Node, MAX_NODE_COUNT) or_return
	r.meshes = glist.make(GPU_Mesh, MAX_MESH_COUNT) or_return
	r.materials = glist.make(GPU_Material, MAX_MATERIAL_COUNT) or_return
	r.mesh_catalog = make(map[string]glist.Glist_Idx)
	r.material_catalog = make(map[string]glist.Glist_Idx)

	win_size: [2]i32
	ok = sdl.GetWindowSize(window, &win_size.x, &win_size.y);sdle.sdl_err(ok)
	aspect := f32(win_size.x) / f32(win_size.y)
	r.proj_mat = lal.matrix4_perspective_f32(lal.to_radians(cam.fovy), aspect, cam.near, cam.far)
	r.view_mat = lal.MATRIX4F32_IDENTITY
	return
}

start_copy_pass :: proc(r: ^Renderer) {
	assert(r.copy_cmd_buf == nil)
	assert(r.copy_pass == nil)
	r.copy_cmd_buf = sdl.AcquireGPUCommandBuffer(r.gpu);sdle.sdl_err(r.copy_cmd_buf)
	r.copy_pass = sdl.BeginGPUCopyPass(r.copy_cmd_buf);sdle.sdl_err(r.copy_pass)
}

end_copy_pass :: proc(r: ^Renderer) {
	assert(r.copy_cmd_buf != nil)
	assert(r.copy_pass != nil)
	sdl.EndGPUCopyPass(r.copy_pass)
	r.copy_pass = nil
	ok := sdl.SubmitGPUCommandBuffer(r.copy_cmd_buf);sdle.sdl_err(ok)
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
	log.infof("loading mesh: %s", file_name)
	mesh := obj_load(file_name)

	// for v in mesh.verts {
	// 	log.infof("%v", v)
	// }
	// for i := 0; i < len(mesh.idxs); i += 3 {
	// 	log.infof("%d %d, %d", mesh.idxs[i], mesh.idxs[i + 1], mesh.idxs[i + 2])
	// }

	idxs_size := len(mesh.idxs) * size_of(u16)
	verts_size := len(mesh.verts) * size_of(Vertex_Data)
	verts_size_u32 := u32(verts_size)
	idx_byte_size_u32 := u32(idxs_size)

	gpu_mesh: GPU_Mesh
	gpu_mesh.num_idxs = u32(len(mesh.idxs))
	gpu_mesh.vert_buf = sdl.CreateGPUBuffer(
		r.gpu,
		{usage = {.VERTEX}, size = verts_size_u32},
	);sdle.sdl_err(gpu_mesh.vert_buf)
	gpu_mesh.idx_buf = sdl.CreateGPUBuffer(
		r.gpu,
		{usage = {.INDEX}, size = idx_byte_size_u32},
	);sdle.sdl_err(gpu_mesh.idx_buf)

	idx := glist.insert(&r.meshes, gpu_mesh) or_return
	transfer_buf := sdl.CreateGPUTransferBuffer(
		r.gpu,
		{usage = .UPLOAD, size = verts_size_u32 + idx_byte_size_u32},
	);sdle.sdl_err(transfer_buf)
	defer sdl.ReleaseGPUTransferBuffer(r.gpu, transfer_buf)

	transfer_mem := transmute([^]byte)sdl.MapGPUTransferBuffer(
		r.gpu,
		transfer_buf,
		false,
	);sdle.sdl_err(transfer_mem)

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
	mesh_name := filepath.short_stem(file_name)
	mesh_name = strings.clone(mesh_name)
	r.mesh_catalog[mesh_name] = idx
	return
}

load_all_meshes :: proc(r: ^Renderer) -> (err: runtime.Allocator_Error) {
	f, ferr := os.open(mesh_dist_dir)
	if err != nil {
		log.panicf("err in opening %s to load all meshes, reason: %v", mesh_dist_dir, ferr)
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
	log.infof("loading texture: %s", file_name)

	file_path := filepath.join(
		{dist_dir, texture_dir, file_name},
		allocator = context.temp_allocator,
	)
	file_path_cstring := strings.clone_to_cstring(file_path, allocator = context.temp_allocator)
	disk_surface := sdli.Load(file_path_cstring);sdle.sdl_err(disk_surface)
	palette := sdl.GetSurfacePalette(disk_surface)
	surface := sdl.ConvertSurfaceAndColorspace(
		disk_surface,
		.RGBA32,
		palette,
		.SRGB,
		0,
	);sdle.sdl_err(surface)
	sdl.DestroySurface(disk_surface)
	defer sdl.DestroySurface(surface)

	width := u32(surface.w)
	height := u32(surface.h)
	len_pixels := int(surface.h * surface.pitch)
	len_pixels_u32 := u32(len_pixels)
	// log.debugf("width=%d", width)
	// log.debugf("height=%d", height)

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
	);sdle.sdl_err(tex.texture)
	tex_transfer_buf := sdl.CreateGPUTransferBuffer(
		r.gpu,
		{usage = .UPLOAD, size = len_pixels_u32},
	);sdle.sdl_err(tex_transfer_buf)
	defer sdl.ReleaseGPUTransferBuffer(r.gpu, tex_transfer_buf)

	tex_transfer_mem := transmute([^]byte)sdl.MapGPUTransferBuffer(
		r.gpu,
		tex_transfer_buf,
		false,
	);sdle.sdl_err(tex_transfer_mem)

	// log.debugf("mempcpy %d bytes to texture transfer buf", len_pixels)
	mem.copy(tex_transfer_mem, surface.pixels, len_pixels)

	sdl.UnmapGPUTransferBuffer(r.gpu, tex_transfer_buf)
	sdl.UploadToGPUTexture(
		r.copy_pass,
		{transfer_buffer = tex_transfer_buf},
		{texture = tex.texture, w = width, h = height, d = 1},
		false,
	)
	tex.sampler = sdl.CreateGPUSampler(r.gpu, {});sdle.sdl_err(tex.sampler)
	return
}

Material_Meta :: struct {
	base: string `json:"base"`,
}

@(private)
load_material :: proc(r: ^Renderer, file_name: string) -> (err: runtime.Allocator_Error) {
	temp_mem := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp_mem)
	log.infof("loading material: %s", file_name)

	file_path := filepath.join(
		{dist_dir, material_dir, file_name},
		allocator = context.temp_allocator,
	)
	f, file_err := os.open(file_path)
	if file_err != nil {
		log.panicf("tried to open file: %s but failed, reason: %v", file_name, file_err)
	}
	defer os.close(f)
	data, io_err := os.read_entire_file_from_file(f, allocator = context.temp_allocator)
	if type_of(io_err) == runtime.Allocator_Error {
		err = io_err.(runtime.Allocator_Error)
		return
	}
	if io_err != nil {
		log.panicf("err in io read_all material %s from file, reason: %v", file_name, io_err)
	}

	meta: Material_Meta
	unmarshal_err := json.unmarshal(data, &meta, allocator = context.temp_allocator)
	if unmarshal_err != nil {
		log.panicf("failed to unmarshal model meta json, %s, reason: %v", file_name, unmarshal_err)
	}

	material: GPU_Material
	material.base = load_texture(r, meta.base)

	idx := glist.insert(&r.materials, material) or_return
	material_name := filepath.short_stem(file_name)
	material_name = strings.clone(material_name)
	r.material_catalog[material_name] = idx
	return
}

load_all_materials :: proc(r: ^Renderer) -> (err: runtime.Allocator_Error) {
	f, ferr := os.open(materials_dist_dir)
	if err != nil {
		log.panicf("err in opening materials dist dir to load all materials, reason: %v", ferr)
	}
	it := os.read_directory_iterator_create(f)
	for file_info in os.read_directory_iterator(&it) {
		load_material(r, file_info.name) or_return
	}
	os.read_directory_iterator_destroy(&it)
	return
}

Make_Node_Error :: union #shared_nil {
	runtime.Allocator_Error,
	Catalog_Error,
}
Catalog_Error :: enum {
	None = 0,
	Mesh_Not_Found,
	Material_Not_Found,
}

Make_Node_Params :: struct {
	mesh_name:     string,
	material_name: string,
	parent:        pool.Pool_Key,
	transform:     matrix[4, 4]f32,
}


make_node :: proc(
	r: ^Renderer,
	mesh_name: string,
	pos := [3]f32{0, 0, 0},
	rot := lal.QUATERNIONF32_IDENTITY,
	scale := [3]f32{1, 1, 1},
	material_name := "default",
	parent := pool.Pool_Key{},
) -> (
	key: pool.Pool_Key,
	err: Make_Node_Error,
) {
	ok: bool
	node: Node
	node.parent = parent
	node.pos = pos
	node.rot = rot
	node.scale = scale
	node.mesh, ok = r.mesh_catalog[mesh_name]
	if !ok {
		err = .Mesh_Not_Found
		return
	}
	node.material, ok = r.material_catalog[material_name]
	if !ok {
		err = .Material_Not_Found
		return
	}
	key = pool.insert_defered(&r.nodes, node) or_return
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
		log.infof("flushing insert with key: %v", n_key)
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


@(private)
next_node_parent :: #force_inline proc(
	r: ^Renderer,
	node: ^^Node,
) -> (
	parent: ^Node,
	key: pool.Pool_Key,
	ok: bool,
) {
	key = node^.parent
	parent, ok = pool.get(&r.nodes, key)
	node^ = parent
	return
}

local_transform :: #force_inline proc(n: Node) -> lal.Matrix4f32 {
	return lal.matrix4_from_trs_f32(n.pos, n.rot, n.scale)
}

@(private)
compute_node_transforms :: proc(r: ^Renderer) {
	temp_mem := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp_mem)
	stack := make([dynamic]^Node, 0, pool.num_active(r.nodes), allocator = context.temp_allocator)
	idx: pool.Pool_Idx
	for node, i in pool.next(&r.nodes, &idx) {
		if node._visited do continue
		node._visited = true

		cur := node
		parent_transform := lal.MATRIX4F32_IDENTITY
		for parent in next_node_parent(r, &cur) {
			if parent._visited {
				parent_transform = parent._global_transform
				break
			}
			parent._visited = true
			append(&stack, parent)
		}
		#reverse for s_node in stack {
			s_node._global_transform = local_transform(s_node^) * parent_transform
			parent_transform = s_node._global_transform
		}
		node._global_transform = local_transform(node^) * parent_transform
		clear(&stack)
	}
	idx = 0
	for node, i in pool.next(&r.nodes, &idx) {
		node._visited = false
	}
	return
}

flush_nodes :: proc(r: ^Renderer) {
	// log.infof("flushing %d frees", r.nodes._free_buf_len)
	pool.flush_frees(&r.nodes)
	// log.infof("flushing %d inserts", r.nodes._insert_buf_len)
	flush_node_inserts(r)
}

render :: proc(r: ^Renderer) {
	MAX_DYNAMIC_BATCH :: 64
	Mvp_Ubo :: struct {
		mvps: [MAX_DYNAMIC_BATCH]matrix[4, 4]f32,
	}
	mvp_ubo: Mvp_Ubo

	cmd_buf := sdl.AcquireGPUCommandBuffer(r.gpu);sdle.sdl_err(cmd_buf)
	defer {ok := sdl.SubmitGPUCommandBuffer(cmd_buf);sdle.sdl_err(ok)}

	swapchain_tex: ^sdl.GPUTexture
	ok := sdl.WaitAndAcquireGPUSwapchainTexture(
		cmd_buf,
		r.window,
		&swapchain_tex,
		nil,
		nil,
	);sdle.sdl_err(ok)
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

	// log.infof("computing %d node transforms", pool.num_active(r.nodes))
	compute_node_transforms(r)
	vp := r.proj_mat * r.view_mat
	// log.info("drawing...")
	// draw
	for material_meshes, material_idx in r.render_map {
		material: ^GPU_Material
		for mesh_nodes, mesh_idx in material_meshes {
			mesh: ^GPU_Mesh
			num_instances := u32(0)
			for node_key, node_idx in mesh_nodes {
				node, ok := pool.get(&r.nodes, node_key)
				if !ok do continue
				// log.infof("rendering node %d", node_idx)

				screen_transform := vp * node._global_transform
				// log.infof("pos=%v", screen_transform * [4]f32{0, 0, 0, 1})
				// log.infof("rot=%v %v %v", lal.euler_angles_xyz_from_matrix4_f32(screen_transform))
				// get_scale_from_col_major_matrix :: proc(m: matrix[4, 4]f32) -> [3]f32 {
				// 	return {
				// 		lal.vector_length(m[0].xyz),
				// 		lal.vector_length(m[1].xyz),
				// 		lal.vector_length(m[2].xyz),
				// 	}
				// }
				// log.infof("scale=%v", get_scale_from_col_major_matrix(screen_transform))
				mvp_ubo.mvps[num_instances] = screen_transform
				num_instances += 1
				if material == nil {
					material = glist.get(&r.materials, glist.Glist_Idx(material_idx))
					sdl.BindGPUFragmentSamplers(render_pass, 0, &(material.base), 1)
					// log.debugf("binding material...")
				}
				if mesh == nil {
					mesh = glist.get(&r.meshes, glist.Glist_Idx(mesh_idx))
					// only bind mesh if we know we are going to draw at least one instance
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
					// log.debugf("binding mesh...")
				}
				if num_instances == MAX_DYNAMIC_BATCH {
					// flush batch
					num_instances = 0
					sdl.PushGPUVertexUniformData(
						cmd_buf,
						0,
						&(mvp_ubo),
						size_of(matrix[4, 4]f32) * num_instances,
					)
					sdl.DrawGPUIndexedPrimitives(
						render_pass,
						mesh.num_idxs,
						num_instances,
						0,
						0,
						0,
					)
				}
			}
			if num_instances == 0 do continue
			// flush leftovers
			sdl.PushGPUVertexUniformData(
				cmd_buf,
				0,
				&(mvp_ubo),
				size_of(matrix[4, 4]f32) * num_instances,
			)
			sdl.DrawGPUIndexedPrimitives(render_pass, mesh.num_idxs, num_instances, 0, 0, 0)
			// log.debugf("drawing %d primitive(s)...", num_instances)
		}
	}
}

