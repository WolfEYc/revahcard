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
import "core:simd"
import "core:slice"
import "core:strings"

shader_dir :: "shaders"
dist_dir :: "dist"
out_shader_ext :: "spv"
texture_dir :: "textures"
model_dir :: "models"
model_dist_dir :: dist_dir + os.Path_Separator_String + model_dir

MAX_MODELS :: 4096
MAX_RENDER_NODES :: 4096
MAX_RENDER_LIGHTS :: 4

Renderer :: struct {
	cam:                       Camera,
	ambient_light_color:       [3]f32,
	model_map:                 map[string]glist.Glist_Idx,
	models:                    glist.Glist(Model),
	// render nececities
	_gpu:                      ^sdl.GPUDevice,
	_window:                   ^sdl.Window,
	_pbr_pipeline:             ^sdl.GPUGraphicsPipeline,
	_proj_mat:                 matrix[4, 4]f32,
	_depth_tex:                ^sdl.GPUTexture,
	// defaults
	_defaut_sampler:           ^sdl.GPUSampler,
	_default_diffuse_binding:  sdl.GPUTextureSamplerBinding,
	_default_normal_binding:   sdl.GPUTextureSamplerBinding,
	_default_orm_binding:      sdl.GPUTextureSamplerBinding,
	_default_emissive_binding: sdl.GPUTextureSamplerBinding,

	// frame gpu mem
	_copy_cmd_buf:             ^sdl.GPUCommandBuffer,
	_copy_pass:                ^sdl.GPUCopyPass,
	_lights_gpu_buf:           ^sdl.GPUBuffer,
	_lights_cpu:               Lights_Storage_Mem,
	_transform_gpu_buf:        ^sdl.GPUBuffer,
	_frame_transfer_mem:       ^Frame_Transfer_Mem,
	_frame_transfer_buf:       ^sdl.GPUTransferBuffer,
	_render_cmd_buf:           ^sdl.GPUCommandBuffer,
	_render_pass:              ^sdl.GPURenderPass,
	_draw_indirect_buf:        ^sdl.GPUBuffer,
	_draw_call_reqs:           [MAX_RENDER_NODES]Draw_Call_Req,
	_draw_req_transforms:      [MAX_RENDER_NODES]matrix[4, 4]f32,
	_draw_material_batch:      [MAX_RENDER_NODES]Draw_Material_Batch,
	_frame_buf_lens:           [Frame_Buf_Len]u32,
}

Frame_Buf_Len :: enum {
	INDIRECT,
	DRAW_REQ,
	MAT_BATCH,
}

Camera :: struct {
	pos:    [3]f32,
	target: [3]f32,
}

GPU_Point_Light :: struct #align (16) {
	pos:   [4]f32, // 16
	color: [4]f32, // 16
}
GPU_Dir_Light :: struct #align (16) {
	dir_to_light: [4]f32, // 16
	color:        [4]f32, // 16
}
GPU_Spot_Light :: struct #align (16) {
	pos:              [4]f32,
	color:            [4]f32,
	dir:              [4]f32,
	inner_cone_angle: f32,
	outer_cone_angle: f32,
	_pad0:            [2]f32,
}
GPU_Area_Light :: struct #align (16) {
	pos:       [4]f32, // xyz = center position, w = unused or light intensity
	color:     [4]f32, // rgb = color, a = intensity or scale
	right:     [4]f32, // xyz = tangent vector of the rectangle, w = half-width
	up:        [4]f32, // xyz = bitangent vector, w = half-height
	two_sided: f32, // 1.0 = light both sides, 0.0 = only front side
	_pad:      [3]f32,
}

Vert_UBO :: struct {
	vp: matrix[4, 4]f32,
}
Frag_Frame_UBO :: struct {
	view_pos:            [4]f32,
	ambient_light_color: [4]f32,
}
Frag_Draw_UBO :: struct {
	normal_scale: f32,
	ao_strength:  f32,
}
Frame_Transfer_Mem :: struct {
	transform:  Transform_Storage_Mem,
	lights:     Lights_Storage_Mem,
	draw_calls: Draw_Call_Mem,
}
Transform_Storage_Mem :: struct #align (16) {
	ms: [MAX_RENDER_NODES]matrix[4, 4]f32,
	// ns: [MAX_RENDER_NODES]matrix[4, 4]f32,
}

Light_Type :: enum {
	DIR,
	POINT,
	SPOT,
	AREA,
}

Lights_Storage_Mem :: struct #align (16) {
	num_light:    [Light_Type]u32,
	point_lights: [MAX_RENDER_LIGHTS]GPU_Point_Light,
	dir_lights:   [MAX_RENDER_LIGHTS]GPU_Dir_Light,
	spot_lights:  [MAX_RENDER_LIGHTS]GPU_Spot_Light,
	area_lights:  [MAX_RENDER_LIGHTS]GPU_Area_Light,
}

GPU_DEPTH_TEX_FMT :: sdl.GPUTextureFormat.D24_UNORM

@(private)
init_pbr_pipe :: proc(r: ^Renderer) {
	vert_shader := load_shader(r._gpu, "pbr.spv.vert", {uniform_buffers = 1, storage_buffers = 1})
	frag_shader := load_shader(
		r._gpu,
		"pbr.spv.frag",
		{uniform_buffers = 2, storage_buffers = 1, samplers = 5},
	)

	vertex_attrs := []sdl.GPUVertexAttribute {
		{location = 0, buffer_slot = 0, format = .FLOAT3},
		{location = 1, buffer_slot = 1, format = .FLOAT3},
		{location = 2, buffer_slot = 2, format = .FLOAT2},
		{location = 3, buffer_slot = 3, format = .FLOAT2},
	}
	vertex_buffer_descriptions := []sdl.GPUVertexBufferDescription {
		{slot = 0, pitch = size_of([3]f32)},
		{slot = 1, pitch = size_of([3]f32)},
		{slot = 2, pitch = size_of([2]f32)},
		{slot = 3, pitch = size_of([2]f32)},
	}
	r._pbr_pipeline = sdl.CreateGPUGraphicsPipeline(
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
			rasterizer_state = {
				cull_mode = .BACK,
				// fill_mode = .LINE,
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
	init_pbr_pipe(r)
	r.models = glist.make(Model, MAX_MODELS) or_return

	// proj & view
	win_size: [2]i32
	ok = sdl.GetWindowSize(window, &win_size.x, &win_size.y);sdle.err(ok)
	aspect := f32(win_size.x) / f32(win_size.y)
	r._proj_mat = lal.matrix4_perspective_f32(
		lal.to_radians(cam_settings.fovy),
		aspect,
		cam_settings.near,
		cam_settings.far,
	)
	r.cam.target = r.cam.pos
	r.cam.target.z -= 1

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

	// defaults
	start_copy_pass(r)
	r._defaut_sampler = sdl.CreateGPUSampler(r._gpu, {})
	r._default_diffuse_binding = load_pixel(r, {255, 255, 0, 255})
	r._default_normal_binding = load_pixel(r, {128, 128, 255, 255})
	r._default_orm_binding = load_pixel(r, {255, 128, 0, 255})
	r._default_emissive_binding = load_pixel(r, {0, 0, 0, 255})
	end_copy_pass(r)

	r.ambient_light_color = ambient_light_color

	// transfer buf
	frame_buf_props := sdl.CreateProperties()
	sdl.SetStringProperty(
		frame_buf_props,
		sdl.PROP_GPU_TRANSFERBUFFER_CREATE_NAME_STRING,
		"frame_buf",
	)
	frame_buf_size := u32(size_of(Frame_Transfer_Mem))
	r._frame_transfer_buf = sdl.CreateGPUTransferBuffer(
		r._gpu,
		{usage = .UPLOAD, size = frame_buf_size, props = frame_buf_props},
	);sdle.err(r._frame_transfer_buf)
	transform_buf: {
		size :: u32(size_of(Transform_Storage_Mem))
		props := sdl.CreateProperties()
		sdl.SetStringProperty(props, sdl.PROP_GPU_BUFFER_CREATE_NAME_STRING, "transform_buf")
		r._transform_gpu_buf = sdl.CreateGPUBuffer(
			r._gpu,
			{usage = {.GRAPHICS_STORAGE_READ}, size = size, props = props},
		);sdle.err(r._transform_gpu_buf)
	}

	lights_buf: {
		size :: u32(size_of(Lights_Storage_Mem))
		props := sdl.CreateProperties()
		sdl.SetStringProperty(props, sdl.PROP_GPU_BUFFER_CREATE_NAME_STRING, "light_buf")
		r._lights_gpu_buf = sdl.CreateGPUBuffer(
			r._gpu,
			{usage = {.GRAPHICS_STORAGE_READ}, size = size, props = props},
		);sdle.err(r._lights_gpu_buf)
	}

	draw_indirect_buf: {
		size :: u32(size_of(Draw_Call_Mem))
		props := sdl.CreateProperties()
		sdl.SetStringProperty(props, sdl.PROP_GPU_BUFFER_CREATE_NAME_STRING, "draw_indirect_buf")
		r._draw_indirect_buf = sdl.CreateGPUBuffer(
			r._gpu,
			{usage = {.INDIRECT}, size = size, props = props},
		);sdle.err(r._draw_indirect_buf)
	}
	return
}

@(private)
load_pixel_f32 :: proc(r: ^Renderer, pixel_f32s: [4]f32) -> (tex: sdl.GPUTextureSamplerBinding) {
	floats := simd.from_array(pixel_f32s)
	floats *= 255
	pixel_simd := cast(#simd[4]u8)floats
	pixel := simd.to_array(pixel_simd)
	return load_pixel(r, pixel)
}
@(private)
load_pixel :: proc(r: ^Renderer, pixel: [4]byte) -> (tex: sdl.GPUTextureSamplerBinding) {
	tex.texture = sdl.CreateGPUTexture(
		r._gpu,
		{
			type = .D2,
			format = .R8G8B8A8_UNORM,
			usage = {.SAMPLER},
			width = 1,
			height = 1,
			layer_count_or_depth = 1,
			num_levels = 1,
		},
	);sdle.err(tex.texture)
	tex_transfer_buf := sdl.CreateGPUTransferBuffer(
		r._gpu,
		{usage = .UPLOAD, size = 4},
	);sdle.err(tex_transfer_buf)
	defer sdl.ReleaseGPUTransferBuffer(r._gpu, tex_transfer_buf)
	tex_transfer_mem := transmute([^]byte)sdl.MapGPUTransferBuffer(
		r._gpu,
		tex_transfer_buf,
		false,
	);sdle.err(tex_transfer_mem)
	pixel := pixel
	mem.copy_non_overlapping(tex_transfer_mem, raw_data(pixel[:]), 4)

	sdl.UnmapGPUTransferBuffer(r._gpu, tex_transfer_buf)
	sdl.UploadToGPUTexture(
		r._copy_pass,
		{transfer_buffer = tex_transfer_buf},
		{texture = tex.texture, w = 1, h = 1, d = 1},
		false,
	)
	sampler_info := sdl.GPUSamplerCreateInfo {
		min_filter     = .NEAREST,
		mag_filter     = .NEAREST,
		mipmap_mode    = .NEAREST,
		address_mode_u = .CLAMP_TO_EDGE,
		address_mode_v = .CLAMP_TO_EDGE,
	}
	tex.sampler = sdl.CreateGPUSampler(r._gpu, sampler_info)
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
		if file_info.type != .Regular || !strings.contains(file_info.name, ".glb") do continue
		file_name := strings.clone(file_info.name)
		load_gltf(r, file_name) or_return
	}
	os.read_directory_iterator_destroy(&it)
	return
}

Draw_Call_Mem :: [MAX_RENDER_NODES]sdl.GPUIndexedIndirectDrawCommand

Draw_Call_Sort_Idx :: enum {
	MODEL_IDX,
	MATERIAL_IDX,
	PRIMITIVE_IDX,
	TRANSFORM_IDX,
}
Draw_Call_Req :: #simd[len(Draw_Call_Sort_Idx)]u32
Draw_Node_Req :: struct {
	model_idx: glist.Glist_Idx,
	node_idx:  u32,
	transform: matrix[4, 4]f32,
}
Draw_Material_Batch :: struct #align (16) {
	model_idx:    glist.Glist_Idx,
	material_idx: u32,
	offset:       u32,
	draw_count:   u32,
}

begin_draw :: proc(r: ^Renderer) {
	mem.zero_item(&r._frame_buf_lens)
}

draw_node :: proc(r: ^Renderer, req: Draw_Node_Req) {
	model := glist.get(r.models, req.model_idx)
	node := model.nodes[req.node_idx]
	mesh_idx, has_mesh := node.mesh.?
	if has_mesh {
		mesh := model.meshes[mesh_idx]
		primitive_stop := mesh.primitive_offset + mesh.num_primitives
		for i := mesh.primitive_offset; i < primitive_stop; i += 1 {
			primitive := model.primitives[i]
			r._draw_call_reqs[r._frame_buf_lens[.DRAW_REQ]] = Draw_Call_Req {
				Draw_Call_Sort_Idx.MODEL_IDX     = req.model_idx,
				Draw_Call_Sort_Idx.MATERIAL_IDX  = primitive.material,
				Draw_Call_Sort_Idx.PRIMITIVE_IDX = i,
				Draw_Call_Sort_Idx.TRANSFORM_IDX = r._frame_buf_lens[.DRAW_REQ],
			}
			r._draw_req_transforms[r._frame_buf_lens[.DRAW_REQ]] = req.transform
			r._frame_buf_lens[.DRAW_REQ] += 1
		}
	}
	light, has_light := node.light.?
	if has_light {
		light := model.lights[light]
		lights := &r._lights_cpu
		num_point_light := &lights.num_light[.POINT]
		lights.point_lights[num_point_light^] = GPU_Point_Light {
			pos   = req.transform[3],
			color = light.color,
		}
		num_point_light^ += 1
	}
	num_child := len(node.children)
	if num_child == 0 do return

	temp_mem := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp_mem)
	sub_req := req
	for i := 0; i < num_child; i += 1 {
		child := node.children[i]
		child_transform := model.nodes[child].mat
		sub_req.transform = req.transform * child_transform
		sub_req.node_idx = child
		draw_node(r, sub_req)
	}
}
end_draw :: proc(r: ^Renderer) {
	sort_draw_call_reqs(r)

	map_frame_transfer_buf(r)
	copy_draw_call_reqs(r)
	copy_lights(r)
	unmap_frame_transfer_buf(r)

	start_copy_pass(r)
	upload_transform_buf(r)
	upload_lights_buf(r)
	upload_draw_call_buf(r)
	end_copy_pass(r)
}

@(private)
sort_draw_call_reqs :: proc(r: ^Renderer) {
	slice.sort_by_cmp(
		r._draw_call_reqs[:r._frame_buf_lens[.DRAW_REQ]],
		proc(i, j: Draw_Call_Req) -> (ordering: slice.Ordering) {
			orderings_lt := simd.to_array(simd.lanes_lt(i, j))
			orderings_gt := simd.to_array(simd.lanes_gt(i, j))
			#unroll for idx in Draw_Call_Sort_Idx {
				idx_ordering: slice.Ordering = cast(bool)orderings_lt[idx] ? .Less : .Equal
				idx_ordering = cast(bool)orderings_gt[idx] ? .Greater : idx_ordering
				ordering = ordering == .Equal ? idx_ordering : ordering
			}
			return
		},
	)
}


@(private)
copy_draw_call_reqs :: proc(r: ^Renderer) {
	// copies transforms and indirect draw calls to frame mem
	if r._frame_buf_lens[.DRAW_REQ] == 0 do return

	last_req := transmute([Draw_Call_Sort_Idx]u32)r._draw_call_reqs[0]
	transform_mem := &r._frame_transfer_mem.transform.ms
	transform_mem[0] = r._draw_req_transforms[last_req[.TRANSFORM_IDX]]
	last_mat_batch := Draw_Material_Batch {
		model_idx    = last_req[.MODEL_IDX],
		material_idx = last_req[.MATERIAL_IDX],
		offset       = 0,
		draw_count   = 1,
	}
	num_instances: u32 = 1
	first_instance: u32 = 0
	draw_cal_mem := &r._frame_transfer_mem.draw_calls
	end_iter := r._frame_buf_lens[.DRAW_REQ]
	for i: u32 = 1; i < end_iter; i += 1 {
		req := r._draw_call_reqs[i]
		array_req := transmute([Draw_Call_Sort_Idx]u32)simd.to_array(req)
		transform_mem[i] = r._draw_req_transforms[array_req[.TRANSFORM_IDX]]

		model_idx := array_req[.MODEL_IDX]
		primitive_idx := array_req[.PRIMITIVE_IDX]
		last_model_idx := last_req[.MODEL_IDX]
		last_primitive_idx := last_req[.PRIMITIVE_IDX]
		last_req = array_req
		defer num_instances += 1
		if model_idx == last_model_idx && primitive_idx == last_primitive_idx do continue

		model := glist.get(r.models, last_model_idx)
		primitive := model.primitives[last_primitive_idx]
		draw_cal_mem[r._frame_buf_lens[.INDIRECT]] = sdl.GPUIndexedIndirectDrawCommand {
			num_indices    = primitive.num_indices,
			num_instances  = num_instances,
			first_index    = primitive.indices_offset,
			vertex_offset  = primitive.vert_offset,
			first_instance = first_instance,
		}
		r._frame_buf_lens[.INDIRECT] += 1
		defer last_mat_batch.draw_count += 1
		first_instance = i
		num_instances = 0

		if model_idx == last_model_idx && primitive.material == last_mat_batch.material_idx do continue
		r._draw_material_batch[r._frame_buf_lens[.MAT_BATCH]] = last_mat_batch
		r._frame_buf_lens[.MAT_BATCH] += 1
		last_mat_batch = Draw_Material_Batch {
			model_idx    = model_idx,
			material_idx = primitive.material,
			offset       = r._frame_buf_lens[.INDIRECT] * size_of(sdl.GPUIndexedIndirectDrawCommand),
			draw_count   = 0,
		}
	}

	// get stragglers
	last_model_idx := last_req[Draw_Call_Sort_Idx.MODEL_IDX]
	last_primitive_idx := last_req[Draw_Call_Sort_Idx.PRIMITIVE_IDX]
	model := glist.get(r.models, last_model_idx)
	primitive := model.primitives[last_primitive_idx]
	draw_cal_mem[r._frame_buf_lens[.INDIRECT]] = sdl.GPUIndexedIndirectDrawCommand {
		num_indices    = primitive.num_indices,
		num_instances  = num_instances,
		first_index    = primitive.indices_offset,
		vertex_offset  = primitive.vert_offset,
		first_instance = first_instance,
	}
	r._frame_buf_lens[.INDIRECT] += 1

	r._draw_material_batch[r._frame_buf_lens[.MAT_BATCH]] = last_mat_batch
	r._frame_buf_lens[.MAT_BATCH] += 1
}

@(private)
copy_lights :: proc(r: ^Renderer) {
	lights_gpu := &r._frame_transfer_mem.lights
	lights_gpu^ = r._lights_cpu // that was easy!
	mem.zero_item(&r._lights_cpu.num_light)
	return
}

@(private)
map_frame_transfer_buf :: proc(r: ^Renderer) {
	assert(r._frame_transfer_mem == nil)
	r._frame_transfer_mem =
	transmute(^Frame_Transfer_Mem)sdl.MapGPUTransferBuffer(
		r._gpu,
		r._frame_transfer_buf,
		true,
	);sdle.err(r._frame_transfer_mem)
}
@(private)
unmap_frame_transfer_buf :: proc(r: ^Renderer) {
	assert(r._frame_transfer_mem != nil)
	sdl.UnmapGPUTransferBuffer(r._gpu, r._frame_transfer_buf)
	r._frame_transfer_mem = nil
}

@(private)
upload_draw_call_buf :: proc(r: ^Renderer) {
	transfer_offset :: u32(offset_of(Frame_Transfer_Mem, draw_calls))
	if r._frame_buf_lens[.INDIRECT] == 0 do return
	size := size_of(sdl.GPUIndexedIndirectDrawCommand) * r._frame_buf_lens[.INDIRECT]
	sdl.UploadToGPUBuffer(
		r._copy_pass,
		{transfer_buffer = r._frame_transfer_buf, offset = transfer_offset},
		{buffer = r._draw_indirect_buf, size = size},
		true,
	)
}

@(private)
upload_transform_buf :: proc(r: ^Renderer) {
	transfer_offset :: u32(offset_of(Frame_Transfer_Mem, transform))
	if r._frame_buf_lens[.DRAW_REQ] == 0 do return
	// log.infof("transforms_rendered=%d", r._transforms_rendered)
	transforms_size := size_of(matrix[4, 4]f32) * r._frame_buf_lens[.DRAW_REQ]

	sdl.UploadToGPUBuffer(
		r._copy_pass,
		{transfer_buffer = r._frame_transfer_buf, offset = transfer_offset},
		{buffer = r._transform_gpu_buf, size = transforms_size},
		true,
	)
}


@(private)
upload_lights_buf :: proc(r: ^Renderer) {
	transfer_offset :: u32(offset_of(Frame_Transfer_Mem, lights))
	size :: u32(size_of(Lights_Storage_Mem))

	sdl.UploadToGPUBuffer(
		r._copy_pass,
		{transfer_buffer = r._frame_transfer_buf, offset = transfer_offset},
		{buffer = r._lights_gpu_buf, size = size},
		true,
	)
}

begin_render :: proc(r: ^Renderer) {
	assert(r._render_cmd_buf == nil)
	r._render_cmd_buf = sdl.AcquireGPUCommandBuffer(r._gpu);sdle.err(r._render_cmd_buf)
}

begin_screen_render_pass :: proc(r: ^Renderer) {
	if r._render_pass != nil {
		sdl.EndGPURenderPass(r._render_pass)
	}
	swapchain_tex: ^sdl.GPUTexture
	ok := sdl.WaitAndAcquireGPUSwapchainTexture(
		r._render_cmd_buf,
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
	r._render_pass = sdl.BeginGPURenderPass(
		r._render_cmd_buf,
		&color_target,
		1,
		&depth_target_info,
	)
}

shadow_pass :: proc(r: ^Renderer) {
	//TODO
}

opaque_pass :: proc(r: ^Renderer) {
	if r._frame_buf_lens[.MAT_BATCH] == 0 do return
	sdl.BindGPUGraphicsPipeline(r._render_pass, r._pbr_pipeline)
	sdl.BindGPUVertexStorageBuffers(r._render_pass, 0, &(r._transform_gpu_buf), 1)
	sdl.BindGPUFragmentStorageBuffers(r._render_pass, 0, &(r._lights_gpu_buf), 1)

	view := lal.matrix4_look_at_f32(r.cam.pos, r.cam.target, [3]f32{0, 1, 0})
	vp := r._proj_mat * view
	vert_ubo := Vert_UBO {
		vp = vp,
	}
	sdl.PushGPUVertexUniformData(r._render_cmd_buf, 0, &(vert_ubo), size_of(Vert_UBO))
	frag_ubo: Frag_Frame_UBO

	frag_ubo.view_pos.xyz = r.cam.pos
	frag_ubo.ambient_light_color.rgb = r.ambient_light_color

	sdl.PushGPUFragmentUniformData(r._render_cmd_buf, 0, &(frag_ubo), size_of(Frag_Frame_UBO))

	model_idx: glist.Glist_Idx
	first_mat_batch: {
		first := r._draw_material_batch[0]
		bind_model(r, first.model_idx)
		bind_material(r, first.model_idx, first.material_idx)
		sdl.DrawGPUIndexedPrimitivesIndirect(
			r._render_pass,
			r._draw_indirect_buf,
			first.offset,
			first.draw_count,
		)
		model_idx = first.model_idx
	}
	for x in r._draw_material_batch[1:r._frame_buf_lens[.MAT_BATCH]] {
		if x.model_idx != model_idx {
			model_idx = x.model_idx
			bind_model(r, model_idx)
		}
		bind_material(r, model_idx, x.material_idx)
		sdl.DrawGPUIndexedPrimitivesIndirect(
			r._render_pass,
			r._draw_indirect_buf,
			x.offset,
			x.draw_count,
		)
	}
}
@(private)
bind_model :: proc(r: ^Renderer, model_idx: glist.Glist_Idx) {
	model := glist.get(r.models, model_idx)
	sdl.BindGPUVertexBuffers(
		r._render_pass,
		0,
		cast([^]sdl.GPUBufferBinding)&model.vert_bufs,
		len(model.vert_bufs),
	)
	sdl.BindGPUIndexBuffer(r._render_pass, model.index_buf, ._16BIT)
}

@(private)
bind_material :: proc(r: ^Renderer, model_idx: glist.Glist_Idx, material_idx: u32) {
	model := glist.get(r.models, model_idx)
	material := model.materials[material_idx]
	draw_ubo := Frag_Draw_UBO {
		normal_scale = material.normal_scale,
		ao_strength  = material.ao_strength,
	}
	sdl.PushGPUFragmentUniformData(r._render_cmd_buf, 1, &(draw_ubo), size_of(Frag_Draw_UBO))
	sdl.BindGPUFragmentSamplers(
		r._render_pass,
		0,
		cast([^]sdl.GPUTextureSamplerBinding)&material.bindings,
		len(material.bindings),
	)
}

end_render :: proc(r: ^Renderer) {
	assert(r._render_cmd_buf != nil)
	assert(r._render_pass != nil)
	sdl.EndGPURenderPass(r._render_pass)
	ok := sdl.SubmitGPUCommandBuffer(r._render_cmd_buf);sdle.err(ok)
	r._render_cmd_buf = nil
	r._render_pass = nil
}

