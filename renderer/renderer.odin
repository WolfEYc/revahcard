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
MAX_RENDER_LIGHTS :: 64

Renderer :: struct {
	cam:                       Camera,
	ambient_light_color:       [3]f32,
	model_map:                 map[string]glist.Glist_Idx,
	models:                    glist.Glist(Model),
	// render nececities
	_gpu:                      ^sdl.GPUDevice,
	_window:                   ^sdl.Window,
	_pipeline:                 ^sdl.GPUGraphicsPipeline,
	_proj_mat:                 matrix[4, 4]f32,
	_depth_tex:                ^sdl.GPUTexture,
	// defaults
	_defaut_sampler:           ^sdl.GPUSampler,
	_default_diffuse_binding:  sdl.GPUTextureSamplerBinding,
	_default_normal_binding:   sdl.GPUTextureSamplerBinding,
	_default_orm_binding:      sdl.GPUTextureSamplerBinding,
	_default_emissive_binding: sdl.GPUTextureSamplerBinding,

	// copy
	_copy_cmd_buf:             ^sdl.GPUCommandBuffer,
	_copy_pass:                ^sdl.GPUCopyPass,

	// transform storage buf
	_transform_gpu_buf:        ^sdl.GPUBuffer,

	// lights storage buf
	_lights_gpu_buf:           ^sdl.GPUBuffer,
	_frame_transfer_mem:       ^Frame_Transfer_Mem,
	_frame_transfer_buf:       ^sdl.GPUTransferBuffer,
	_draw_cmd_buf:             ^sdl.GPUCommandBuffer,
	_draw_render_pass:         ^sdl.GPURenderPass,
	_lights_rendered:          u32,
	_transforms_rendered:      u32,
	_vert_ubo:                 Vert_UBO,
	_frag_ubo:                 Frag_Frame_UBO,
}

Camera :: struct {
	pos:    [3]f32,
	target: [3]f32,
}

GPU_Point_Light :: struct #align (16) {
	pos:   [4]f32, // 16
	color: [4]f32, // 16
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
	transform: Transform_Storage_Mem,
	lights:    Lights_Storage_Mem,
}
Transform_Storage_Mem :: struct #align (16) {
	ms: [MAX_RENDER_NODES]matrix[4, 4]f32,
	// ns: [MAX_RENDER_NODES]matrix[4, 4]f32,
}
Lights_Storage_Mem :: struct #align (16) {
	_lightpad0:      [3]f32, // 12
	rendered_lights: u32, // 16
	lights:          [MAX_RENDER_LIGHTS]GPU_Point_Light,
}

GPU_DEPTH_TEX_FMT :: sdl.GPUTextureFormat.D24_UNORM

@(private)
init_render_pipeline :: proc(r: ^Renderer) {
	vert_shader := load_shader(r._gpu, "pbr.spv.vert", {uniform_buffers = 1, storage_buffers = 1})
	frag_shader := load_shader(
		r._gpu,
		"pbr.spv.frag",
		{uniform_buffers = 2, storage_buffers = 1, samplers = 5},
	)

	vertex_attrs := []sdl.GPUVertexAttribute {
		{location = 0, buffer_slot = 0, format = .FLOAT3},
		{location = 1, buffer_slot = 1, format = .FLOAT2},
		{location = 2, buffer_slot = 2, format = .FLOAT2},
		{location = 3, buffer_slot = 3, format = .FLOAT3},
		{location = 4, buffer_slot = 4, format = .FLOAT3},
	}
	vertex_buffer_descriptions := []sdl.GPUVertexBufferDescription {
		{slot = 0, pitch = size_of([3]f32)},
		{slot = 1, pitch = size_of([2]f32)},
		{slot = 2, pitch = size_of([2]f32)},
		{slot = 3, pitch = size_of([3]f32)},
		{slot = 4, pitch = size_of([3]f32)},
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
	init_render_pipeline(r)
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

	transform_buf_size :: u32(size_of(Transform_Storage_Mem))
	transform_buf_props := sdl.CreateProperties()
	sdl.SetStringProperty(
		transform_buf_props,
		sdl.PROP_GPU_BUFFER_CREATE_NAME_STRING,
		"transform_buf",
	)
	r._transform_gpu_buf = sdl.CreateGPUBuffer(
		r._gpu,
		{usage = {.GRAPHICS_STORAGE_READ}, size = transform_buf_size, props = transform_buf_props},
	);sdle.err(r._transform_gpu_buf)

	lights_size :: u32(size_of(Lights_Storage_Mem))
	light_buf_props := sdl.CreateProperties()
	sdl.SetStringProperty(light_buf_props, sdl.PROP_GPU_BUFFER_CREATE_NAME_STRING, "light_buf")
	r._lights_gpu_buf = sdl.CreateGPUBuffer(
		r._gpu,
		{usage = {.GRAPHICS_STORAGE_READ}, size = lights_size, props = light_buf_props},
	);sdle.err(r._lights_gpu_buf)

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
		file_name := strings.clone(file_info.name)
		load_gltf(r, file_name) or_return
	}
	os.read_directory_iterator_destroy(&it)
	return
}

local_transform :: #force_inline proc(n: Model_Node) -> lal.Matrix4f32 {
	return lal.matrix4_from_trs_f32(n.pos, n.rot, n.scale)
}

Draw_Req :: struct {
	model:      ^Model,
	node_idx:   u32,
	transforms: []matrix[4, 4]f32,
}
// instanced draw calls
draw_node :: proc(r: ^Renderer, req: Draw_Req) {
	node := req.model.nodes[req.node_idx]
	mesh_idx, has_mesh := node.mesh.?
	if has_mesh {
		draw_call(r, req, mesh_idx)
	}
	light, has_light := node.light.?
	if has_light {
		light := req.model.lights[light]
		lights := &r._frame_transfer_mem.lights.lights
		for transform in req.transforms {
			lights[r._lights_rendered] = GPU_Point_Light {
				pos   = transform[3],
				color = light.color,
			}
			r._lights_rendered += 1
		}
	}
	num_child := len(node.children)
	if num_child == 0 do return
	// log.infof("num_child=%d", num_child)
	// log.infof("num_transform=%d", len(req.transforms))

	temp_mem := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp_mem)
	sub_req := req
	sub_req.transforms = make([]matrix[4, 4]f32, len(req.transforms), context.temp_allocator)
	for i := 0; i < num_child; i += 1 {
		child := node.children[i]
		child_transform := local_transform(req.model.nodes[child])
		for transform, i in req.transforms {
			sub_req.transforms[i] = transform * child_transform
		}
		sub_req.node_idx = child
		draw_node(r, sub_req)
	}
}

@(private)
draw_call :: proc(r: ^Renderer, req: Draw_Req, mesh_idx: u32) {
	// log.debug("draw init good!")
	gpu_transform_mem := &r._frame_transfer_mem.transform.ms
	draw_instances := len(req.transforms)
	draw_instances_u32 := u32(draw_instances)
	first_draw_index := r._transforms_rendered
	mem.copy_non_overlapping(
		raw_data(gpu_transform_mem[first_draw_index:]),
		raw_data(req.transforms),
		draw_instances * size_of(matrix[4, 4]f32),
	)
	r._transforms_rendered += draw_instances_u32
	// log.infof("pushed_transform=%v", req.transforms[0])
	// log.infof("draw_instances=%d", draw_instances_u32)
	mesh := req.model.meshes[mesh_idx]
	for &primitive in mesh.primitives {
		material := &req.model.materials[primitive.material]
		draw_ubo := Frag_Draw_UBO {
			normal_scale = material.normal_scale,
			ao_strength  = material.ao_strength,
		}
		sdl.PushGPUFragmentUniformData(r._draw_cmd_buf, 1, &(draw_ubo), size_of(Frag_Draw_UBO))
		sdl.BindGPUFragmentSamplers(
			r._draw_render_pass,
			0,
			raw_data(material.bindings[:]),
			len(material.bindings),
		)
		sdl.BindGPUVertexBuffers(
			r._draw_render_pass,
			0,
			raw_data(primitive.vert_bufs[:]),
			len(primitive.vert_bufs),
		)
		sdl.BindGPUIndexBuffer(r._draw_render_pass, primitive.indices, primitive.indices_type)
		sdl.DrawGPUIndexedPrimitives(
			r._draw_render_pass,
			primitive.num_indices,
			draw_instances_u32,
			0,
			0,
			first_draw_index,
		)
	}
	return
}

begin_frame :: proc(r: ^Renderer) {
	assert(r._draw_render_pass == nil)
	assert(r._draw_cmd_buf == nil)
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
	sdl.BindGPUVertexStorageBuffers(r._draw_render_pass, 0, &(r._transform_gpu_buf), 1)
	// log.debugf("LIGHT BUFFA=%v", r._lights_gpu_buffer)
	sdl.BindGPUFragmentStorageBuffers(r._draw_render_pass, 0, &(r._lights_gpu_buf), 1)

	view := lal.matrix4_look_at_f32(r.cam.pos, r.cam.target, [3]f32{0, 1, 0})
	vp := r._proj_mat * view
	r._vert_ubo = Vert_UBO {
		vp = vp,
	}
	sdl.PushGPUVertexUniformData(r._draw_cmd_buf, 0, &r._vert_ubo, size_of(Vert_UBO))
	r._frag_ubo.view_pos.xyz = r.cam.pos
	r._frag_ubo.ambient_light_color.rgb = r.ambient_light_color

	sdl.PushGPUFragmentUniformData(r._draw_cmd_buf, 0, &r._frag_ubo, size_of(Frag_Frame_UBO))
	map_frame_transfer_buf(r)
}

end_frame :: proc(r: ^Renderer) {
	assert(r._draw_render_pass != nil)
	assert(r._draw_cmd_buf != nil)

	r._frame_transfer_mem.lights.rendered_lights = r._lights_rendered
	unmap_frame_transfer_buf(r)
	start_copy_pass(r)
	upload_transform_buf(r)
	upload_lights_buf(r)
	end_copy_pass(r)

	sdl.EndGPURenderPass(r._draw_render_pass)
	ok := sdl.SubmitGPUCommandBuffer(r._draw_cmd_buf);sdle.err(ok)
	r._draw_render_pass = nil
	r._draw_cmd_buf = nil
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
upload_transform_buf :: proc(r: ^Renderer) {
	transfer_offset :: u32(offset_of(Frame_Transfer_Mem, transform))
	if r._transforms_rendered == 0 do return
	// log.infof("transforms_rendered=%d", r._transforms_rendered)
	transforms_size := size_of(matrix[4, 4]f32) * r._transforms_rendered

	sdl.UploadToGPUBuffer(
		r._copy_pass,
		{transfer_buffer = r._frame_transfer_buf, offset = transfer_offset},
		{buffer = r._transform_gpu_buf, size = transforms_size},
		true,
	)
	r._transforms_rendered = 0
}

@(private)
upload_lights_buf :: proc(r: ^Renderer) {
	transfer_offset :: u32(offset_of(Frame_Transfer_Mem, lights))
	padding_and_length :: 16
	size := padding_and_length + size_of(GPU_Point_Light) * r._lights_rendered

	sdl.UploadToGPUBuffer(
		r._copy_pass,
		{transfer_buffer = r._frame_transfer_buf, offset = transfer_offset},
		{buffer = r._lights_gpu_buf, size = size},
		true,
	)
	r._lights_rendered = 0
}

