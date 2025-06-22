package renderer

import "../lib/glist"
import "../lib/pool"
import sdl "vendor:sdl3"
import sdli "vendor:sdl3/image"

import gltf "../lib/glTF2"
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
model_dist_dir :: dist_dir + os.Path_Separator_String + model_dir


MAX_NODE_COUNT :: 65536
MAX_RENDER_NODES :: 4096
MAX_LIGHT_COUNT :: 1024
MAX_RENDER_LIGHTS :: 64
MAX_MESH_COUNT :: 1024
MAX_MATERIAL_COUNT :: 1024

Renderer :: struct {
	cam:                        Camera,
	ambient_light_color:        [3]f32,
	//private
	_gpu:                       ^sdl.GPUDevice,
	_window:                    ^sdl.Window,
	_pipeline:                  ^sdl.GPUGraphicsPipeline,
	_proj_mat:                  matrix[4, 4]f32,
	_depth_tex:                 ^sdl.GPUTexture,
	_meshes:                    glist.Glist(GPU_Mesh),
	_materials:                 glist.Glist(GPU_Material),
	_nodes:                     pool.Pool(Node),
	_node_map:                  map[string]pool.Pool_Key,
	//                           material   mesh    node
	_render_map:                [dynamic][dynamic][dynamic]pool.Pool_Key,

	// copy
	_copy_cmd_buf:              ^sdl.GPUCommandBuffer,
	_copy_pass:                 ^sdl.GPUCopyPass,

	// transform storage buf
	_transform_buffer:          Transform_Storage_Buffer,
	_transform_gpu_buffer:      ^sdl.GPUBuffer,
	_transform_transfer_buffer: ^sdl.GPUTransferBuffer,

	// lights storage buf
	_lights_buffer:             [MAX_RENDER_LIGHTS]GPU_Point_Light,
	_lights:                    pool.Pool(GPU_Point_Light),
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
	pos:    [3]f32,
	target: [3]f32,
}

GPU_Point_Light :: struct #align (32) {
	pos:   [4]f32, // 16
	// _pad:  f32, // 4
	color: [4]f32, // 16
	// intensity: f32, // 4
}


Node :: struct {
	_global_mat: matrix[4, 4]f32,
	pos:         [3]f32,
	scale:       [3]f32,
	rot:         quaternion128,
	light_color: [4]f32,
	mesh:        glist.Glist_Idx,
	material:    glist.Glist_Idx,
	_visited:    bool,
	visible:     bool,
	lit:         bool,
	children:    []pool.Pool_Key,
}
Primitive :: struct {
	pos:     [][3]f32,
	uv:      [][2]f32,
	normal:  [][3]f32,
	tangent: [][3]f32,
	idxs:    []u16,
}
GPU_Primitive :: struct {
	pos_buf:      ^sdl.GPUBuffer,
	uv_buf:       ^sdl.GPUBuffer,
	normal_buf:   ^sdl.GPUBuffer,
	tangents_buf: ^sdl.GPUBuffer,
	idx_buf:      ^sdl.GPUBuffer,
	num_idxs:     u32,
}
GPU_Mesh :: struct {
	primitives: []GPU_Primitive,
}
Mat_Idx :: enum {
	ALBEDO,
	NORMAL,
	ORM,
	EMISSIVE,
}
GPU_Material :: struct {
	bindings: [4]sdl.GPUTextureSamplerBinding,
}
Vert_UBO :: struct {
	vp: matrix[4, 4]f32,
}
Frag_UBO :: struct {
	view_pos:            [3]f32,
	rendered_lights:     u32,
	ambient_light_color: [3]f32,
}
Transform_Storage_Buffer :: struct {
	ms: [MAX_RENDER_NODES]matrix[4, 4]f32,
	// ns: [MAX_RENDER_NODES]matrix[4, 4]f32,
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
		{uniform_buffers = 1, storage_buffers = 1, samplers = 4},
	)

	vertex_attrs := []sdl.GPUVertexAttribute {
		{location = 0, buffer_slot = 0, format = .FLOAT3},
		{location = 1, buffer_slot = 1, format = .FLOAT2},
		{location = 2, buffer_slot = 2, format = .FLOAT3},
		{location = 3, buffer_slot = 3, format = .FLOAT3},
	}
	vertex_buffer_descriptions := []sdl.GPUVertexBufferDescription {
		{slot = 0, pitch = size_of([3]f32)},
		{slot = 1, pitch = size_of([2]f32)},
		{slot = 2, pitch = size_of([3]f32)},
		{slot = 3, pitch = size_of([3]f32)},
	}
	r._pipeline = sdl.CreateGPUGraphicsPipeline(
		r._gpu,
		{
			vertex_shader = vert_shader,
			fragment_shader = frag_shader,
			primitive_type = .TRIANGLELIST,
			vertex_input_state = {
				num_vertex_buffers = u32(len(vertex_buffer_descriptions)),
				vertex_buffer_descriptions = raw_data(vertex_buffer_descriptions),
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

init :: proc(
	gpu: ^sdl.GPUDevice,
	window: ^sdl.Window,
	cam_settings := DEFAULT_CAM_SETTINGS,
	ambient_light_color := [3]f32{0.01, 0.01, 0.01},
) -> (
	r: ^Renderer,
	err: runtime.Allocator_Error,
) {
	r = new(Renderer)
	ok := sdl.ClaimWindowForGPUDevice(gpu, window);sdle.err(ok)
	r._gpu = gpu
	r._window = window

	ok = sdl.SetGPUSwapchainParameters(gpu, window, .SDR_LINEAR, .VSYNC);sdle.err(ok)

	init_render_pipeline(r)

	r._nodes = pool.make(Node, MAX_NODE_COUNT) or_return

	win_size: [2]i32
	ok = sdl.GetWindowSize(window, &win_size.x, &win_size.y);sdle.err(ok)
	aspect := f32(win_size.x) / f32(win_size.y)
	r.ambient_light_color = ambient_light_color
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
	);sdle.err(r._depth_tex)

	transform_buf_size := u32(size_of(Transform_Storage_Buffer))
	r._transform_gpu_buffer = sdl.CreateGPUBuffer(
		r._gpu,
		{usage = {.GRAPHICS_STORAGE_READ}, size = transform_buf_size},
	);sdle.err(r._transform_gpu_buffer)
	r._transform_transfer_buffer = sdl.CreateGPUTransferBuffer(
		r._gpu,
		{usage = .UPLOAD, size = transform_buf_size},
	);sdle.err(r._transform_transfer_buffer)

	lights_size := u32(size_of(r._lights_buffer))
	r._lights = pool.make(GPU_Point_Light, MAX_LIGHT_COUNT) or_return
	r._lights_gpu_buffer = sdl.CreateGPUBuffer(
		r._gpu,
		{usage = {.GRAPHICS_STORAGE_READ}, size = lights_size},
	);sdle.err(r._lights_gpu_buffer)
	r._lights_transfer_buffer = sdl.CreateGPUTransferBuffer(
		r._gpu,
		{usage = .UPLOAD, size = lights_size},
	);sdle.err(r._lights_transfer_buffer)


	r.cam.target = r.cam.pos
	r.cam.target.z -= 1
	return
}

start_copy_pass :: proc(r: ^Renderer) {
	assert(r._copy_cmd_buf == nil)
	assert(r._copy_pass == nil)
	r._copy_cmd_buf = sdl.AcquireGPUCommandBuffer(r._gpu);sdle.err(r._copy_cmd_buf)
	r._copy_pass = sdl.BeginGPUCopyPass(r._copy_cmd_buf);sdle.err(r._copy_pass)
}

end_copy_pass :: proc(r: ^Renderer) {
	assert(r._copy_cmd_buf != nil)
	assert(r._copy_pass != nil)
	sdl.EndGPUCopyPass(r._copy_pass)
	ok := sdl.SubmitGPUCommandBuffer(r._copy_cmd_buf);sdle.err(ok)
	r._copy_pass = nil
	r._copy_cmd_buf = nil
}

load_all_assets :: proc(r: ^Renderer) -> (err: runtime.Allocator_Error) {
	start_copy_pass(r)
	load_all_models(r) or_return
	end_copy_pass(r)
	return
}

load_all_models :: proc(r: ^Renderer) -> (err: runtime.Allocator_Error) {
	f, ferr := os.open(model_dist_dir)
	if err != nil {
		log.panicf("err in opening %s to load all models, reason: %v", model_dist_dir, ferr)
	}
	it := os.read_directory_iterator_create(f)
	for file_info in os.read_directory_iterator(&it) {
		load_gltf(r, file_info.name) or_return
	}
	os.read_directory_iterator_destroy(&it)
	return
}


upload_primitive_to_gpu :: proc(
	r: ^Renderer,
	mesh: Primitive,
) -> (
	gpu_mesh: GPU_Primitive,
	err: runtime.Allocator_Error,
) {
	idxs_size := len(mesh.idxs) * size_of(u16)
	num_verts := len(mesh.pos)
	vert_vec3_size := num_verts * size_of([3]f32)
	vert_vec2_size := num_verts * size_of([2]f32)
	vert_vec3_size_u32 := u32(vert_vec3_size)
	vert_vec2_size_u32 := u32(vert_vec2_size)
	idx_byte_size_u32 := u32(idxs_size)

	gpu_mesh.num_idxs = u32(len(mesh.idxs))
	gpu_mesh.idx_buf = sdl.CreateGPUBuffer(
		r._gpu,
		{usage = {.INDEX}, size = idx_byte_size_u32},
	);sdle.err(gpu_mesh.idx_buf)
	gpu_mesh.pos_buf = sdl.CreateGPUBuffer(
		r._gpu,
		{usage = {.VERTEX}, size = vert_vec3_size_u32},
	);sdle.err(gpu_mesh.pos_buf)
	gpu_mesh.uv_buf = sdl.CreateGPUBuffer(
		r._gpu,
		{usage = {.VERTEX}, size = vert_vec2_size_u32},
	);sdle.err(gpu_mesh.uv_buf)
	gpu_mesh.normal_buf = sdl.CreateGPUBuffer(
		r._gpu,
		{usage = {.VERTEX}, size = vert_vec3_size_u32},
	);sdle.err(gpu_mesh.normal_buf)
	gpu_mesh.tangents_buf = sdl.CreateGPUBuffer(
		r._gpu,
		{usage = {.VERTEX}, size = vert_vec3_size_u32},
	);sdle.err(gpu_mesh.tangents_buf)

	transfer_buffer_size := vert_vec3_size_u32 * 3 + vert_vec2_size_u32 + idx_byte_size_u32

	transfer_buf := sdl.CreateGPUTransferBuffer(
		r._gpu,
		{usage = .UPLOAD, size = transfer_buffer_size},
	);sdle.err(transfer_buf)
	defer sdl.ReleaseGPUTransferBuffer(r._gpu, transfer_buf)

	transfer_mem := transmute([^]byte)sdl.MapGPUTransferBuffer(
		r._gpu,
		transfer_buf,
		false,
	);sdle.err(transfer_mem)

	mem.copy(transfer_mem, raw_data(mesh.idxs), idxs_size)
	mem.copy(transfer_mem[idxs_size:], raw_data(mesh.pos), vert_vec3_size)
	uv_offset := idxs_size + vert_vec3_size
	mem.copy(transfer_mem[uv_offset:], raw_data(mesh.uv), vert_vec2_size)
	normal_offset := uv_offset + vert_vec2_size
	mem.copy(transfer_mem[normal_offset:], raw_data(mesh.normal), vert_vec3_size)
	tangent_offset := normal_offset + vert_vec3_size
	mem.copy(transfer_mem[tangent_offset:], raw_data(mesh.tangent), vert_vec3_size)

	sdl.UnmapGPUTransferBuffer(r._gpu, transfer_buf)
	sdl.UploadToGPUBuffer(
		r._copy_pass,
		{transfer_buffer = transfer_buf},
		{buffer = gpu_mesh.idx_buf, size = idx_byte_size_u32},
		false,
	)
	sdl.UploadToGPUBuffer(
		r._copy_pass,
		{transfer_buffer = transfer_buf, offset = idx_byte_size_u32},
		{buffer = gpu_mesh.pos_buf, size = vert_vec3_size_u32},
		false,
	)
	sdl.UploadToGPUBuffer(
		r._copy_pass,
		{transfer_buffer = transfer_buf, offset = u32(uv_offset)},
		{buffer = gpu_mesh.uv_buf, size = vert_vec2_size_u32},
		false,
	)
	sdl.UploadToGPUBuffer(
		r._copy_pass,
		{transfer_buffer = transfer_buf, offset = u32(normal_offset)},
		{buffer = gpu_mesh.normal_buf, size = vert_vec3_size_u32},
		false,
	)
	sdl.UploadToGPUBuffer(
		r._copy_pass,
		{transfer_buffer = transfer_buf, offset = u32(tangent_offset)},
		{buffer = gpu_mesh.tangents_buf, size = vert_vec3_size_u32},
		false,
	)
	return
}

load_gltf :: proc(r: ^Renderer, file_name: string) -> (err: runtime.Allocator_Error) {
	GLTF_Ctx :: struct {
		file_name:     string,
		mesh_name:     string,
		mesh_idx:      int,
		primitive_idx: int,
	}
	mesh_err_fmt :: "err loading model=%s, mesh_name=%s mesh_idx=%d primitive=%d missing %s attr"
	get_primitive_attr :: proc(
		gltf_ctx: GLTF_Ctx,
		primitive: gltf.Mesh_Primitive,
		attr: string,
	) -> (
		accessor: gltf.Integer,
	) {
		ok: bool
		accessor, ok = primitive.attributes[attr]
		if !ok do log.panicf(mesh_err_fmt, gltf_ctx.file_name, gltf_ctx.mesh_name, gltf_ctx.mesh_idx, gltf_ctx.primitive_idx, attr)
		return
	}
	gltf_ctx: GLTF_Ctx
	gltf_ctx.file_name = file_name

	assert(r._copy_pass != nil)
	assert(r._copy_cmd_buf != nil)
	temp_mem := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp_mem)
	log.infof("loading model: %s", file_name)

	data, load_err := gltf.load_from_file(file_name)
	if load_err != nil {
		log.panicf("err loading model %s, reason: %v", file_name, load_err)
	}

	//lights
	lights: []json.Object
	if lights_ext_value, has_lights_ext := data.extensions.(json.Object)["KHR_lights_punctual"];
	   has_lights_ext {
		lights_arr := lights_ext_value.(json.Array)
		lights = make([]json.Object, len(lights_arr), context.temp_allocator)
		for light, i in lights_arr {
			lights[i] = light.(json.Object)
		}
	}

	// meshes
	mesh_mapper := make([]glist.Glist_Idx, len(data.meshes), context.temp_allocator)
	for gltf_mesh, mesh_idx in data.meshes {
		gltf_ctx.mesh_name = gltf_mesh.name.?
		gltf_ctx.mesh_idx = mesh_idx
		gpu_mesh: GPU_Mesh
		gpu_mesh.primitives = make([]GPU_Primitive, len(gltf_mesh.primitives))
		for gltf_primitive, primitive_idx in gltf_mesh.primitives {
			gltf_ctx.primitive_idx = primitive_idx
			indices_idx, has_idxs := gltf_primitive.indices.?
			if !has_idxs do log.panicf(mesh_err_fmt, gltf_ctx.file_name, gltf_ctx.mesh_name, gltf_ctx.mesh_idx, gltf_ctx.primitive_idx, "indicies")
			pos_idx := get_primitive_attr(gltf_ctx, gltf_primitive, "POSITION")
			normal_idx := get_primitive_attr(gltf_ctx, gltf_primitive, "NORMAL")
			uv_idx := get_primitive_attr(gltf_ctx, gltf_primitive, "TEXCOORD_0")

			pos_buf := gltf.buffer_slice(data, pos_idx).([][3]f32)
			norm_buf := gltf.buffer_slice(data, normal_idx).([][3]f32)
			uv_buf := gltf.buffer_slice(data, uv_idx).([][2]f32)

			num_verts := len(pos_buf)
			primitive: Primitive

			primitive.idxs = gltf.buffer_slice(data, indices_idx).([]u16)
			// calc tangent
			for i := 0; i < len(primitive.idxs); i += 3 {
				v0 := primitive.idxs[i]
				v1 := primitive.idxs[i + 1]
				v2 := primitive.idxs[i + 2]

				edge1 := primitive.pos[v1] - primitive.pos[v0]
				edge2 := primitive.pos[v2] - primitive.pos[v0]

				delta_1 := primitive.uv[v1] - primitive.uv[v0]
				delta_2 := primitive.uv[v2] - primitive.uv[v0]

				f := 1.0 / (delta_1.x * delta_2.y - delta_2.x * delta_1.y)
				tangent := f * (delta_2.y * edge1 - delta_1.y * edge2)
				// bitangent := f * (-delta_2.x * edge1 + delta_1.x * edge2)

				primitive.tangent[v0] += tangent
				primitive.tangent[v1] += tangent
				primitive.tangent[v2] += tangent
			}
			for i := 0; i < num_verts; i += 1 {
				primitive.tangent[i] = lal.normalize(primitive.tangent[i])
			}
			gpu_primitive := upload_primitive_to_gpu(r, primitive) or_return
			gpu_mesh.primitives[primitive_idx] = gpu_primitive

		} // end primitive
		mesh_glist_idx := glist.insert(&r._meshes, gpu_mesh) or_return
		mesh_mapper[mesh_idx] = mesh_glist_idx
	} // end mesh

	// nodes 
	for gltf_node, gltf_node_idx in data.nodes {
		node: Node
		// node lights
		lights_ext, ok := gltf_node.extensions.(json.Object)["KHR_lights_punctual"]
		if ok {
			light_idx := lights_ext.(json.Object)["light"].(json.Integer)
			light := lights[light_idx]
			light_type := light["type"].(json.String)
			color: [4]f32 = 1.0
			maybe_color, has_color := light["color"]
			if has_color {
				light_color := maybe_color.(json.Array)
				for channel, i in light_color {
					color[i] = f32(channel.(json.Float))
				}
			}
			intensity := f32(light["intensity"].(json.Float))
			color *= intensity
			switch light_type {
			case "point":
				node.light_color = color
				node.lit = true
			}
		}
		// node meshes
		mesh_idx, has_mesh := gltf_node.mesh.?
		if has_mesh {
			node.mesh = mesh_mapper[mesh_idx]
		}
		//TODO child nodes
	} // end nodes


	return
}


@(private)
load_texture :: proc(r: ^Renderer, file_name: string) -> (tex: sdl.GPUTextureSamplerBinding) {
	ok: bool
	// tex, ok = r._texture_catalog[file_name]
	if ok do return
	log.infof("loading texture: %s", file_name)
	temp_mem := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp_mem)

	file_path := filepath.join(
		{dist_dir, texture_dir, file_name},
		allocator = context.temp_allocator,
	)
	file_path_cstring := strings.clone_to_cstring(file_path, allocator = context.temp_allocator)
	disk_surface := sdli.Load(file_path_cstring);sdle.err(disk_surface)
	palette := sdl.GetSurfacePalette(disk_surface)
	surface := sdl.ConvertSurfaceAndColorspace(
		disk_surface,
		.RGBA32,
		palette,
		.SRGB_LINEAR,
		0,
	);sdle.err(surface)
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
			format = .R8G8B8A8_UNORM,
			usage = {.SAMPLER},
			width = width,
			height = height,
			layer_count_or_depth = 1,
			num_levels = 1,
		},
	);sdle.err(tex.texture)
	tex_transfer_buf := sdl.CreateGPUTransferBuffer(
		r._gpu,
		{usage = .UPLOAD, size = len_pixels_u32},
	);sdle.err(tex_transfer_buf)
	defer sdl.ReleaseGPUTransferBuffer(r._gpu, tex_transfer_buf)

	tex_transfer_mem := transmute([^]byte)sdl.MapGPUTransferBuffer(
		r._gpu,
		tex_transfer_buf,
		false,
	);sdle.err(tex_transfer_mem)

	// log.debugf("mempcpy %d bytes to texture transfer buf", len_pixels)
	mem.copy(tex_transfer_mem, surface.pixels, len_pixels)

	sdl.UnmapGPUTransferBuffer(r._gpu, tex_transfer_buf)
	sdl.UploadToGPUTexture(
		r._copy_pass,
		{transfer_buffer = tex_transfer_buf},
		{texture = tex.texture, w = width, h = height, d = 1},
		false,
	)
	tex.sampler = sdl.CreateGPUSampler(r._gpu, {});sdle.err(tex.sampler)
	// r._texture_catalog[file_name] = tex
	return
}

Material_Meta :: struct {
	diffuse:     string `json:"diffuse"`,
	metal_rough: string `json:"metal_rough"`,
	specular:    string `json:"specular"`,
	emissive:    string `json:"emissive"`,
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
	visible := true,
	lit := true,
) -> (
	key: pool.Pool_Key,
	err: Make_Node_Error,
) {
	ok: bool
	node: Node
	node.pos = pos
	node.rot = rot
	node.scale = scale
	node.visible = visible
	node.lit = lit
	key = pool.insert_defered(&r._nodes, node) or_return
	return
}

make_light :: proc(
	r: ^Renderer,
	light: GPU_Point_Light,
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
		// if n._material >= u32(len(r._render_map)) {
		// 	resize(&r._render_map, n._material + 1) or_return
		// }
		// if n._mesh >= u32(len(r._render_map[n._material])) {
		// 	resize(&r._render_map[n._material], n._mesh + 1) or_return
		// }
		// append(&r._render_map[n._material][n._mesh], n_key) or_return
	}
	return
}


local_transform :: #force_inline proc(n: Node) -> lal.Matrix4f32 {
	return lal.matrix4_from_trs_f32(n.pos, n.rot, n.scale)
}

@(private)
add_light :: #force_inline proc(r: ^Renderer, node: ^Node) {
	if r._lights_rendered == MAX_RENDER_LIGHTS || !node.lit do return
	light: GPU_Point_Light
	light.pos.xyz = node._global_mat[3].xyz
	r._lights_buffer[r._lights_rendered] = light
	r._lights_rendered += 1
	return
}

// @(private)
// compute_node_transforms_and_lights :: proc(r: ^Renderer) {
// 	temp_mem := runtime.default_temp_allocator_temp_begin()
// 	defer runtime.default_temp_allocator_temp_end(temp_mem)
// 	stack := make([dynamic]^Node, 0, pool.num_active(r._nodes), allocator = context.temp_allocator)
// 	idx: pool.Pool_Idx
// 	for node, i in pool.next(&r._nodes, &idx) {
// 		if node._visited do continue
// 		node._visited = true

// 		cur := node
// 		parent_transform := lal.MATRIX4F32_IDENTITY
// 		for parent in next_node_parent(r, &cur) {
// 			if parent._visited {
// 				parent_transform = parent._global_transform
// 				break
// 			}
// 			parent._visited = true
// 			append(&stack, parent)
// 		}
// 		#reverse for s_node in stack {
// 			s_node._global_transform = local_transform(s_node^) * parent_transform
// 			parent_transform = s_node._global_transform
// 		}
// 		clear(&stack)
// 		node._global_transform = local_transform(node^) * parent_transform
// 	}
// 	idx = 0
// 	for node in pool.next(&r._nodes, &idx) {
// 		node._visited = false
// 		add_light(r, node)
// 	}
// 	return
// }

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

@(private)
draw :: proc(r: ^Renderer) {
	r._draw_cmd_buf = sdl.AcquireGPUCommandBuffer(r._gpu);sdle.err(r._draw_cmd_buf)

	swapchain_tex: ^sdl.GPUTexture
	ok := sdl.WaitAndAcquireGPUSwapchainTexture(
		r._draw_cmd_buf,
		r._window,
		&swapchain_tex,
		nil,
		nil,
	);sdle.err(ok)
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

	view := lal.matrix4_look_at_f32(r.cam.pos, r.cam.target, [3]f32{0, 1, 0})
	vp := r._proj_mat * view
	r._vert_ubo = Vert_UBO {
		vp = vp,
	}
	sdl.PushGPUVertexUniformData(r._draw_cmd_buf, 0, &r._vert_ubo, size_of(Vert_UBO))

	r._frag_ubo = Frag_UBO {
		rendered_lights     = r._lights_rendered,
		view_pos            = r.cam.pos,
		ambient_light_color = r.ambient_light_color,
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
				r._transform_buffer.ms[r._nodes_rendered] = node._global_mat
				// r._transform_buffer.ns[r._nodes_rendered] = lal.inverse_transpose(
				// 	node._global_transform,
				// )
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
	// compute_node_transforms_and_lights(r)
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
	ok := sdl.SubmitGPUCommandBuffer(r._draw_cmd_buf);sdle.err(ok)
	r._lights_rendered = 0
	r._nodes_rendered = 0
}

@(private)
upload_transform_buffer :: proc(r: ^Renderer) {
	if r._nodes_rendered == 0 {
		return
	}
	size := size_of(Transform_Storage_Buffer) * r._nodes_rendered

	transfer_mem := transmute([^]byte)sdl.MapGPUTransferBuffer(
		r._gpu,
		r._transform_transfer_buffer,
		true,
	);sdle.err(transfer_mem)

	mem.copy(transfer_mem, &r._transform_buffer, int(size))

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
	size := size_of(GPU_Point_Light) * r._lights_rendered

	transfer_mem := transmute([^]byte)sdl.MapGPUTransferBuffer(
		r._gpu,
		r._lights_transfer_buffer,
		true,
	);sdle.err(transfer_mem)

	mem.copy(transfer_mem, raw_data(r._lights_buffer[:]), int(size))

	sdl.UnmapGPUTransferBuffer(r._gpu, r._lights_transfer_buffer)
	sdl.UploadToGPUBuffer(
		r._copy_pass,
		{transfer_buffer = r._lights_transfer_buffer},
		{buffer = r._lights_gpu_buffer, size = size},
		true,
	)
}

