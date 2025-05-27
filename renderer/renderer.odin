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
MAX_RENDER_NODES :: 4096
MAX_LIGHT_COUNT :: 1024
MAX_RENDER_LIGHTS :: 64
MAX_MESH_COUNT :: 1024
MAX_MATERIAL_COUNT :: 1024

Renderer :: struct {
	camera:                     Camera,
	//private
	_gpu:                       ^sdl.GPUDevice,
	_window:                    ^sdl.Window,
	_pipeline:                  ^sdl.GPUGraphicsPipeline,
	_proj_mat:                  matrix[4, 4]f32,
	_depth_tex:                 ^sdl.GPUTexture,

	// nodes
	_nodes:                     pool.Pool(Node),
	_meshes:                    glist.Glist(GPU_Mesh),
	_materials:                 glist.Glist(GPU_Material),
	_mesh_catalog:              map[string]glist.Glist_Idx,
	_material_catalog:          map[string]glist.Glist_Idx,
	//                      material   mesh    node
	_render_map:                [dynamic][dynamic][dynamic]pool.Pool_Key,

	// copy
	_copy_cmd_buf:              ^sdl.GPUCommandBuffer,
	_copy_pass:                 ^sdl.GPUCopyPass,

	// mvps
	_transform_buffer:          []matrix[4, 4]f32,
	_transform_gpu_buffer:      ^sdl.GPUBuffer,
	_transform_transfer_buffer: ^sdl.GPUTransferBuffer,

	// lights
	_lights_buffer:             []GPU_Light,
	_lights:                    pool.Pool(GPU_Light),
	_lights_gpu_buffer:         ^sdl.GPUBuffer,
	_lights_transfer_buffer:    ^sdl.GPUTransferBuffer,

	// per frame
	_draw_cmd_buf:              ^sdl.GPUCommandBuffer,
	_draw_render_pass:          ^sdl.GPURenderPass,
	_lights_rendered:           u32,
	_nodes_rendered:            u32,
	_vert_ubo:                  Vert_UBO,
	_frag_ubo:                  Frag_UBO,
}

Camera :: struct {
	pos: [3]f32,
	rot: quaternion128,
}

Node :: struct {
	_global_transform: matrix[4, 4]f32,
	rot:               quaternion128,
	pos:               [3]f32,
	scale:             [3]f32,
	parent:            pool.Pool_Key,
	light:             pool.Pool_Key,
	_mesh:             glist.Glist_Idx,
	_material:         glist.Glist_Idx,
	_visited:          bool,
	lit:               bool,
	visible:           bool,
}

GPU_Light :: struct #align (32) {
	pos:       [3]f32, // 12
	range:     f32, // 4
	color:     [3]f32, // 12
	intensity: f32, // 4
}

GPU_Mesh :: struct {
	vert_buf: ^sdl.GPUBuffer,
	idx_buf:  ^sdl.GPUBuffer,
	num_idxs: u32,
}
Mat_Idx :: enum {
	BASE,
	EMISSIVE,
}
GPU_Material :: struct {
	bindings: [2]sdl.GPUTextureSamplerBinding,
}

GPU_DEPTH_TEX_FMT :: sdl.GPUTextureFormat.D24_UNORM

@(private)
init_render_pipeline :: proc(r: ^Renderer) {
	vert_shader := load_shader(
		r._gpu,
		"default.spv.vert",
		{uniform_buffers = 1, storage_buffers = 1},
	)
	frag_shader := load_shader(
		r._gpu,
		"default.spv.frag",
		{uniform_buffers = 1, storage_buffers = 1, samplers = 2},
	)

	vertex_attrs := []sdl.GPUVertexAttribute {
		{location = 0, format = .FLOAT3, offset = u32(offset_of(Vertex_Data, pos))},
		{location = 1, format = .FLOAT2, offset = u32(offset_of(Vertex_Data, uv))},
		{location = 2, format = .FLOAT3, offset = u32(offset_of(Vertex_Data, normal))},
	}
	r._pipeline = sdl.CreateGPUGraphicsPipeline(
		r._gpu,
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
			depth_stencil_state = {
				enable_depth_test = true,
				enable_depth_write = true,
				compare_op = .LESS,
			},
			target_info = {
				num_color_targets = 1,
				color_target_descriptions = &(sdl.GPUColorTargetDescription {
						format = sdl.GetGPUSwapchainTextureFormat(r._gpu, r._window),
					}),
				has_depth_stencil_target = true,
				depth_stencil_format = GPU_DEPTH_TEX_FMT,
			},
		},
	)
	sdl.ReleaseGPUShader(r._gpu, vert_shader)
	sdl.ReleaseGPUShader(r._gpu, frag_shader)

	return
}

Camera_Settings :: struct {
	fovy: f32,
	near: f32,
	far:  f32,
}

DEFAULT_CAM_SETTINGS :: Camera_Settings {
	fovy = 90,
	near = 0.0001,
	far  = 1000,
}

new :: proc(
	gpu: ^sdl.GPUDevice,
	window: ^sdl.Window,
	cam_settings: Camera_Settings = DEFAULT_CAM_SETTINGS,
) -> (
	r: Renderer,
	err: runtime.Allocator_Error,
) {
	ok := sdl.ClaimWindowForGPUDevice(gpu, window);sdle.sdl_err(ok)
	r._gpu = gpu
	r._window = window

	ok = sdl.SetGPUSwapchainParameters(gpu, window, .SDR_LINEAR, .VSYNC);sdle.sdl_err(ok)

	init_render_pipeline(&r)

	r._nodes = pool.make(Node, MAX_NODE_COUNT) or_return
	r._meshes = glist.make(GPU_Mesh, MAX_MESH_COUNT) or_return
	r._materials = glist.make(GPU_Material, MAX_MATERIAL_COUNT) or_return
	r._mesh_catalog = make(map[string]glist.Glist_Idx)
	r._material_catalog = make(map[string]glist.Glist_Idx)

	win_size: [2]i32
	ok = sdl.GetWindowSize(window, &win_size.x, &win_size.y);sdle.sdl_err(ok)
	aspect := f32(win_size.x) / f32(win_size.y)
	r._proj_mat = lal.matrix4_perspective_f32(
		lal.to_radians(cam_settings.fovy),
		aspect,
		cam_settings.near,
		cam_settings.far,
	)

	r._depth_tex = sdl.CreateGPUTexture(
		r._gpu,
		{
			format = GPU_DEPTH_TEX_FMT,
			usage = {.DEPTH_STENCIL_TARGET},
			width = u32(win_size.x),
			height = u32(win_size.y),
			layer_count_or_depth = 1,
			num_levels = 1,
		},
	);sdle.sdl_err(r._depth_tex)

	transform_buf_size := u32(size_of(matrix[4, 4]f32) * MAX_RENDER_NODES)
	r._transform_gpu_buffer = sdl.CreateGPUBuffer(
		r._gpu,
		{usage = {.GRAPHICS_STORAGE_READ}, size = transform_buf_size},
	);sdle.sdl_err(r._transform_gpu_buffer)
	r._transform_transfer_buffer = sdl.CreateGPUTransferBuffer(
		r._gpu,
		{usage = .UPLOAD, size = transform_buf_size},
	);sdle.sdl_err(r._transform_transfer_buffer)
	r._transform_buffer = make([]matrix[4, 4]f32, MAX_RENDER_NODES)

	lights_size := u32(size_of(GPU_Light) * MAX_RENDER_LIGHTS)
	r._lights = pool.make(GPU_Light, MAX_LIGHT_COUNT) or_return
	r._lights_buffer = make([]GPU_Light, MAX_RENDER_LIGHTS) or_return
	r._lights_gpu_buffer = sdl.CreateGPUBuffer(
		r._gpu,
		{usage = {.GRAPHICS_STORAGE_READ}, size = lights_size},
	);sdle.sdl_err(r._lights_gpu_buffer)
	r._lights_transfer_buffer = sdl.CreateGPUTransferBuffer(
		r._gpu,
		{usage = .UPLOAD, size = lights_size},
	);sdle.sdl_err(r._lights_transfer_buffer)


	r.camera.rot = lal.QUATERNIONF32_IDENTITY
	return
}

start_copy_pass :: proc(r: ^Renderer) {
	assert(r._copy_cmd_buf == nil)
	assert(r._copy_pass == nil)
	r._copy_cmd_buf = sdl.AcquireGPUCommandBuffer(r._gpu);sdle.sdl_err(r._copy_cmd_buf)
	r._copy_pass = sdl.BeginGPUCopyPass(r._copy_cmd_buf);sdle.sdl_err(r._copy_pass)
}

end_copy_pass :: proc(r: ^Renderer) {
	assert(r._copy_cmd_buf != nil)
	assert(r._copy_pass != nil)
	sdl.EndGPUCopyPass(r._copy_pass)
	ok := sdl.SubmitGPUCommandBuffer(r._copy_cmd_buf);sdle.sdl_err(ok)
	r._copy_pass = nil
	r._copy_cmd_buf = nil
}

load_all_assets :: proc(r: ^Renderer) -> (err: runtime.Allocator_Error) {
	start_copy_pass(r)
	load_all_materials(r) or_return
	load_all_meshes(r) or_return
	end_copy_pass(r)
	return
}

load_mesh :: proc(r: ^Renderer, file_name: string) -> (err: runtime.Allocator_Error) {
	assert(r._copy_pass != nil)
	assert(r._copy_cmd_buf != nil)
	temp_mem := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp_mem)
	log.infof("loading mesh: %s", file_name)
	mesh := obj_load(file_name)
	// log.debugf("num_idxs=%d", len(mesh.idxs))

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
		r._gpu,
		{usage = {.VERTEX}, size = verts_size_u32},
	);sdle.sdl_err(gpu_mesh.vert_buf)
	gpu_mesh.idx_buf = sdl.CreateGPUBuffer(
		r._gpu,
		{usage = {.INDEX}, size = idx_byte_size_u32},
	);sdle.sdl_err(gpu_mesh.idx_buf)

	idx := glist.insert(&r._meshes, gpu_mesh) or_return
	transfer_buf := sdl.CreateGPUTransferBuffer(
		r._gpu,
		{usage = .UPLOAD, size = verts_size_u32 + idx_byte_size_u32},
	);sdle.sdl_err(transfer_buf)
	defer sdl.ReleaseGPUTransferBuffer(r._gpu, transfer_buf)

	transfer_mem := transmute([^]byte)sdl.MapGPUTransferBuffer(
		r._gpu,
		transfer_buf,
		false,
	);sdle.sdl_err(transfer_mem)

	mem.copy(transfer_mem, raw_data(mesh.verts), verts_size)
	mem.copy(transfer_mem[verts_size:], raw_data(mesh.idxs), idxs_size)

	sdl.UnmapGPUTransferBuffer(r._gpu, transfer_buf)

	sdl.UploadToGPUBuffer(
		r._copy_pass,
		{transfer_buffer = transfer_buf},
		{buffer = gpu_mesh.vert_buf, size = verts_size_u32},
		false,
	)
	sdl.UploadToGPUBuffer(
		r._copy_pass,
		{transfer_buffer = transfer_buf, offset = verts_size_u32},
		{buffer = gpu_mesh.idx_buf, size = idx_byte_size_u32},
		false,
	)
	mesh_name := filepath.short_stem(file_name)
	mesh_name = strings.clone(mesh_name)
	r._mesh_catalog[mesh_name] = idx
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
		r._gpu,
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
		r._gpu,
		{usage = .UPLOAD, size = len_pixels_u32},
	);sdle.sdl_err(tex_transfer_buf)
	defer sdl.ReleaseGPUTransferBuffer(r._gpu, tex_transfer_buf)

	tex_transfer_mem := transmute([^]byte)sdl.MapGPUTransferBuffer(
		r._gpu,
		tex_transfer_buf,
		false,
	);sdle.sdl_err(tex_transfer_mem)

	// log.debugf("mempcpy %d bytes to texture transfer buf", len_pixels)
	mem.copy(tex_transfer_mem, surface.pixels, len_pixels)

	sdl.UnmapGPUTransferBuffer(r._gpu, tex_transfer_buf)
	sdl.UploadToGPUTexture(
		r._copy_pass,
		{transfer_buffer = tex_transfer_buf},
		{texture = tex.texture, w = width, h = height, d = 1},
		false,
	)
	tex.sampler = sdl.CreateGPUSampler(r._gpu, {});sdle.sdl_err(tex.sampler)
	return
}

Material_Meta :: struct {
	base:     string `json:"base"`,
	emissive: string `json:"emissive"`,
}

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
	material.bindings[Mat_Idx.BASE] = load_texture(r, meta.base)
	material.bindings[Mat_Idx.EMISSIVE] = load_texture(r, meta.emissive)

	idx := glist.insert(&r._materials, material) or_return
	material_name := filepath.short_stem(file_name)
	material_name = strings.clone(material_name)
	r._material_catalog[material_name] = idx
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
	model_name: string,
	pos := [3]f32{0, 0, 0},
	rot := lal.QUATERNIONF32_IDENTITY,
	scale := [3]f32{1, 1, 1},
	material_name := "default",
	parent := pool.Pool_Key{},
	light := pool.Pool_Key{},
	visible := true,
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
	node.visible = visible
	node.light = light
	node._mesh, ok = r._mesh_catalog[model_name]
	if !ok {
		err = .Mesh_Not_Found
		return
	}
	node._material, ok = r._material_catalog[material_name]
	if !ok {
		err = .Material_Not_Found
		return
	}
	if light.gen != 0 {
		node.lit = true
	}
	key = pool.insert_defered(&r._nodes, node) or_return
	return
}

make_light :: proc(
	r: ^Renderer,
	light: GPU_Light,
) -> (
	key: pool.Pool_Key,
	err: runtime.Allocator_Error,
) {
	key, err = pool.insert_defered(&r._lights, light)
	return
}

get_node :: #force_inline proc(r: ^Renderer, k: pool.Pool_Key) -> (node: ^Node, ok: bool) {
	return pool.get(&r._nodes, k)
}

free_node :: #force_inline proc(r: ^Renderer, k: pool.Pool_Key) {
	pool.free_defered(&r._nodes, k)
}

@(private)
flush_node_inserts :: proc(r: ^Renderer) -> (err: runtime.Allocator_Error) {
	pending_inserts := pool.pending_inserts(&r._nodes)
	pool.flush_inserts(&r._nodes)
	for n_idx in pending_inserts {
		n_key := pool.idx_to_key(&r._nodes, n_idx)
		n, ok := pool.get(&r._nodes, n_key)
		if !ok do continue
		// log.infof("flushing insert with key: %v", n_key)
		if n._material >= u32(len(r._render_map)) {
			resize(&r._render_map, n._material + 1) or_return
		}
		if n._mesh >= u32(len(r._render_map[n._material])) {
			resize(&r._render_map[n._material], n._mesh + 1) or_return
		}
		append(&r._render_map[n._material][n._mesh], n_key) or_return
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
	parent, ok = pool.get(&r._nodes, key)
	node^ = parent
	return
}

local_transform :: #force_inline proc(n: Node) -> lal.Matrix4f32 {
	return lal.matrix4_from_trs_f32(n.pos, n.rot, n.scale)
}

@(private)
add_light :: #force_inline proc(r: ^Renderer, node: ^Node) {
	if r._lights_rendered == MAX_RENDER_LIGHTS || !node.lit do return
	light, ok := pool.get(&r._lights, node.light)
	if !ok do return
	light.pos = node._global_transform[3].xyz
	r._lights_buffer[r._lights_rendered] = light^
	r._lights_rendered += 1
	return
}

@(private)
compute_node_transforms_and_lights :: proc(r: ^Renderer) {
	temp_mem := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp_mem)
	stack := make([dynamic]^Node, 0, pool.num_active(r._nodes), allocator = context.temp_allocator)
	idx: pool.Pool_Idx
	for node, i in pool.next(&r._nodes, &idx) {
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
		clear(&stack)
		node._global_transform = local_transform(node^) * parent_transform
	}
	idx = 0
	for node in pool.next(&r._nodes, &idx) {
		node._visited = false
		add_light(r, node)
	}
	return
}

flush_nodes :: proc(r: ^Renderer) {
	// log.infof("flushing %d frees", r.nodes._free_buf_len)
	pool.flush_frees(&r._nodes)
	// log.infof("flushing %d inserts", r.nodes._insert_buf_len)
	flush_node_inserts(r)
}

flush_lights :: proc(r: ^Renderer) {
	pool.flush_frees(&r._lights)
	pool.flush_inserts(&r._lights)
}

Vert_UBO :: struct {
	vp: matrix[4, 4]f32,
}
Frag_UBO :: struct {
	rendered_lights: u32,
}
@(private)
draw :: proc(r: ^Renderer) {
	r._draw_cmd_buf = sdl.AcquireGPUCommandBuffer(r._gpu);sdle.sdl_err(r._draw_cmd_buf)

	swapchain_tex: ^sdl.GPUTexture
	ok := sdl.WaitAndAcquireGPUSwapchainTexture(
		r._draw_cmd_buf,
		r._window,
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
	depth_target_info := sdl.GPUDepthStencilTargetInfo {
		texture     = r._depth_tex,
		load_op     = .CLEAR,
		clear_depth = 1,
		store_op    = .DONT_CARE,
	}
	r._draw_render_pass = sdl.BeginGPURenderPass(
		r._draw_cmd_buf,
		&color_target,
		1,
		&depth_target_info,
	)
	sdl.BindGPUGraphicsPipeline(r._draw_render_pass, r._pipeline)
	sdl.BindGPUVertexStorageBuffers(r._draw_render_pass, 0, &(r._transform_gpu_buffer), 1)
	// log.debugf("LIGHT BUFFA=%v", r._lights_gpu_buffer)
	sdl.BindGPUFragmentStorageBuffers(r._draw_render_pass, 0, &(r._lights_gpu_buffer), 1)

	view := lal.matrix4_from_trs_f32(r.camera.pos, r.camera.rot, [3]f32{1, 1, 1})
	vp := r._proj_mat * view
	r._vert_ubo = Vert_UBO {
		vp = vp,
	}
	sdl.PushGPUVertexUniformData(r._draw_cmd_buf, 0, &r._vert_ubo, size_of(Vert_UBO))

	r._frag_ubo = Frag_UBO {
		rendered_lights = r._lights_rendered,
	}
	// log.debugf("gonna render %d lights", rendered_lights)
	sdl.PushGPUFragmentUniformData(r._draw_cmd_buf, 0, &r._frag_ubo, size_of(Frag_UBO))

	// log.debug("draw init good!")
	r._nodes_rendered = 0
	for material_meshes, material_idx in r._render_map {
		material: ^GPU_Material
		for mesh_nodes, mesh_idx in material_meshes {
			draw_instances := u32(0)
			for node_key, node_idx in mesh_nodes {
				node, ok := pool.get(&r._nodes, node_key)
				if !ok || !node.visible do continue
				if r._nodes_rendered == MAX_RENDER_NODES do break
				r._transform_buffer[r._nodes_rendered] = node._global_transform
				draw_instances += 1
				r._nodes_rendered += 1
			}
			if draw_instances == 0 do continue

			if material == nil {
				material = glist.get(&r._materials, glist.Glist_Idx(material_idx))
				sdl.BindGPUFragmentSamplers(
					r._draw_render_pass,
					0,
					raw_data(material.bindings[:]),
					len(material.bindings),
				)
			}
			mesh := glist.get(&r._meshes, glist.Glist_Idx(mesh_idx))
			sdl.BindGPUVertexBuffers(
				r._draw_render_pass,
				0,
				&(sdl.GPUBufferBinding{buffer = mesh.vert_buf}),
				1,
			)
			sdl.BindGPUIndexBuffer(
				r._draw_render_pass,
				sdl.GPUBufferBinding{buffer = mesh.idx_buf},
				._16BIT,
			)

			first_draw_index := r._nodes_rendered - draw_instances
			// log.debugf(
			// 	"mesh.num_idxs=%d draw_instances=%d, first_draw_index=%d",
			// 	mesh.num_idxs,
			// 	draw_instances,
			// 	first_draw_index,
			// )
			sdl.DrawGPUIndexedPrimitives(
				r._draw_render_pass,
				mesh.num_idxs,
				draw_instances,
				0,
				0,
				first_draw_index,
			)
		}
	}
	return
}

render :: proc(r: ^Renderer) {
	compute_node_transforms_and_lights(r)
	// log.debug("compute good!")
	draw(r)
	// log.debug("draw good!")
	storage_buffer_uploads: {
		start_copy_pass(r)
		upload_transform_buffer(r)
		// log.debug("transform good!")
		upload_lights_buffer(r)
		// log.debug("lights good!")
		end_copy_pass(r)
	}
	sdl.EndGPURenderPass(r._draw_render_pass)
	ok := sdl.SubmitGPUCommandBuffer(r._draw_cmd_buf);sdle.sdl_err(ok)
	r._lights_rendered = 0
	r._nodes_rendered = 0
}

@(private)
upload_transform_buffer :: proc(r: ^Renderer) {
	if r._nodes_rendered == 0 {
		return
	}
	size := size_of(matrix[4, 4]f32) * r._nodes_rendered

	transfer_mem := transmute([^]byte)sdl.MapGPUTransferBuffer(
		r._gpu,
		r._transform_transfer_buffer,
		true,
	);sdle.sdl_err(transfer_mem)

	mem.copy(transfer_mem, raw_data(r._transform_buffer), int(size))

	sdl.UnmapGPUTransferBuffer(r._gpu, r._transform_transfer_buffer)
	sdl.UploadToGPUBuffer(
		r._copy_pass,
		{transfer_buffer = r._transform_transfer_buffer},
		{buffer = r._transform_gpu_buffer, size = size},
		true,
	)
}

@(private)
upload_lights_buffer :: proc(r: ^Renderer) {
	if r._lights_rendered == 0 {
		return
	}
	size := size_of(GPU_Light) * r._lights_rendered

	transfer_mem := transmute([^]byte)sdl.MapGPUTransferBuffer(
		r._gpu,
		r._lights_transfer_buffer,
		true,
	);sdle.sdl_err(transfer_mem)

	mem.copy(transfer_mem, raw_data(r._lights_buffer), int(size))

	sdl.UnmapGPUTransferBuffer(r._gpu, r._lights_transfer_buffer)
	sdl.UploadToGPUBuffer(
		r._copy_pass,
		{transfer_buffer = r._lights_transfer_buffer},
		{buffer = r._lights_gpu_buffer, size = size},
		true,
	)
}

