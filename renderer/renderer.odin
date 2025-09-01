package renderer

import "../lib/glist"
import "../lib/pool"
import "core:container/bit_array"
import "core:fmt"
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
fonts_dir :: "fonts"
dist_dir :: "dist"
out_shader_ext :: "spv"
texture_dir :: "textures"
model_dir :: "models"
model_dist_dir :: dist_dir + os.Path_Separator_String + model_dir
font_dist_dir :: dist_dir + os.Path_Separator_String + fonts_dir

mat4 :: matrix[4, 4]f32

MAX_MODELS :: 4096
MAX_RENDER_NODES :: 4096
MAX_RENDER_LIGHTS :: 4
INFO_BUF_SIZE :: 3

Renderer :: struct {
	cam:                       Camera,
	ambient_light_color:       [3]f32,
	// render nececities
	_gpu:                      ^sdl.GPUDevice,
	_window:                   ^sdl.Window,
	_gpu_texture_format:       sdl.GPUTextureFormat,
	_pbr_pipeline:             ^sdl.GPUGraphicsPipeline,
	_pbr_text_pipeline:        ^sdl.GPUGraphicsPipeline,
	_pbr_shape_pipeline:       ^sdl.GPUGraphicsPipeline,
	_shadow_pipeline:          ^sdl.GPUGraphicsPipeline,
	_depth_tex:                ^sdl.GPUTexture,
	_window_size:              [2]i32,
	// defaults
	_defaut_sampler:           ^sdl.GPUSampler,
	_tex_binds:                [Mat_Idx]sdl.GPUTextureSamplerBinding,
	_default_text_orm_binding: sdl.GPUTextureSamplerBinding,
	_default_text_material:    Model_Material,
	_default_text_sampler:     ^sdl.GPUSampler,

	// frame gpu mem
	_active_pipeline:          ^sdl.GPUGraphicsPipeline,
	_frustrum_corners:         Frustrum_Corners,
	_frustrum_center:          [3]f32,
	_copy_cmd_buf:             ^sdl.GPUCommandBuffer,
	_copy_pass:                ^sdl.GPUCopyPass,
	_transform_gpu_buf:        ^sdl.GPUBuffer,
	_frame_transfer_mem:       ^Frame_Transfer_Mem,
	_frame_transfer_buf:       ^sdl.GPUTransferBuffer,
	_render_cmd_buf:           ^sdl.GPUCommandBuffer,
	_render_pass:              ^sdl.GPURenderPass,
	_vert_ubo:                 Vert_UBO,
	_frag_frame_ubo:           Frag_Frame_UBO,
	_draw_indirect_buf:        ^sdl.GPUBuffer,
	_draw_call_reqs:           [MAX_RENDER_NODES]Draw_Call_Req,
	_draw_transforms:          [MAX_RENDER_NODES]mat4,
	_draw_entity_ids:          [MAX_RENDER_NODES]pool.Pool_Key,
	_text_draw_transforms:     [MAX_RENDER_NODES]mat4,
	_draw_material_batch:      [MAX_RENDER_NODES]Draw_Material_Batch,
	_draw_model_batch:         [MAX_RENDER_NODES]Draw_Renderable_Batch,
	_lens:                     [Frame_Buf_Len]u32,

	//info
	info_cursor:               [2]i32,
	info_entity_id:            pool.Pool_Key,
	_info_pipeline:            ^sdl.GPUGraphicsPipeline,
	_info_tex:                 ^sdl.GPUTexture,
	_info_tbufs:               [INFO_BUF_SIZE]^sdl.GPUTransferBuffer,
	_info_fences:              [INFO_BUF_SIZE]^sdl.GPUFence,
	_info_latest_buf:          i32,

	//ttf
	_quad_idx_binding:         sdl.GPUBufferBinding,
	_default_bitmap:           Bitmap,
	_draw_text_batch:          [MAX_RENDER_NODES]Draw_Text_Batch,
}

Frame_Buf_Len :: enum {
	INDIRECT,
	DRAW_REQ,
	MAT_BATCH,
	MODEL_BATCH,
	TEXT_DRAW,
}

Camera :: struct {
	pos:    [3]f32,
	target: [3]f32,
	fovy:   f32,
	aspect: f32,
	near:   f32,
	far:    f32,
}

GPU_Point_Light :: struct {
	pos:   [4]f32,
	color: [4]f32,
}
GPU_Dir_Light :: struct {
	dir_to_light: [4]f32,
	color:        [4]f32,
}
GPU_Spot_Light :: struct {
	pos:              [4]f32,
	color:            [4]f32,
	dir:              [4]f32,
	inner_cone_angle: f32,
	outer_cone_angle: f32,
	_pad:             [2]f32,
}
GPU_Area_Light :: struct {
	pos:       [4]f32, // xyz = center position, w = unused or light intensity
	color:     [4]f32, // rgb = color, a = intensity or scale
	right:     [4]f32, // xyz = tangent vector of the rectangle, w = half-width
	up:        [4]f32, // xyz = bitangent vector, w = half-height
	two_sided: f32, // 1.0 = light both sides, 0.0 = only front side
	_pad:      [3]f32,
}

Shadow_Vert_UBO :: struct {
	vp: mat4,
}
Vert_UBO :: struct {
	vp:        mat4,
	shadow_vp: mat4,
}
Frag_Frame_UBO :: struct #packed {
	view_pos:            [4]f32,
	ambient_light_color: [4]f32,
	num_light:           [Light_Type]u32,
	dir_light:           GPU_Dir_Light,
	point_lights:        [MAX_RENDER_LIGHTS]GPU_Point_Light,
	spot_lights:         [MAX_RENDER_LIGHTS]GPU_Spot_Light,
	area_lights:         [MAX_RENDER_LIGHTS]GPU_Area_Light,
}
Light_Type :: enum {
	DIR,
	POINT,
	SPOT,
	AREA,
}
Frag_Draw_UBO :: struct {
	diffuse_override: [4]f32,
	normal_scale:     f32,
	ao_strength:      f32,
}
Frame_Transfer_Mem :: struct {
	transform:  Transform_Storage_Mem,
	draw_calls: Draw_Call_Mem,
}
Transform_Storage_Mem :: struct #align (64) {
	ms: [MAX_RENDER_NODES]mat4,
	ns: [MAX_RENDER_NODES]mat4,
}

Renderable :: union {
	^Shape,
	^Model,
}

GPU_DEPTH_TEX_FMT :: sdl.GPUTextureFormat.D24_UNORM

@(private)
init_pbr_pipe :: proc(r: ^Renderer) {
	vert_shader := load_shader(r._gpu, "pbr.spv.vert", {uniform_buffers = 1, storage_buffers = 1})
	frag_shader := load_shader(r._gpu, "pbr.spv.frag", {uniform_buffers = 2, samplers = 6})

	vertex_attrs := []sdl.GPUVertexAttribute {
		{location = 0, buffer_slot = 0, format = .FLOAT3},
		{location = 1, buffer_slot = 1, format = .FLOAT3},
		{location = 2, buffer_slot = 2, format = .FLOAT4},
		{location = 3, buffer_slot = 3, format = .FLOAT2},
		{location = 4, buffer_slot = 4, format = .FLOAT2},
	}
	vertex_buffer_descriptions := []sdl.GPUVertexBufferDescription {
		{slot = 0, pitch = size_of([3]f32)},
		{slot = 1, pitch = size_of([3]f32)},
		{slot = 2, pitch = size_of([4]f32)},
		{slot = 3, pitch = size_of([2]f32)},
		{slot = 4, pitch = size_of([2]f32)},
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
					format = r._gpu_texture_format,
				}),
			has_depth_stencil_target = true,
			depth_stencil_format = GPU_DEPTH_TEX_FMT,
		},
	},
	);sdle.err(r._pbr_pipeline)
	sdl.ReleaseGPUShader(r._gpu, vert_shader)
	sdl.ReleaseGPUShader(r._gpu, frag_shader)

	return
}

@(private)
init_pbr_text_pipe :: proc(r: ^Renderer) {
	vert_shader := load_shader(
		r._gpu,
		"pbr_text.spv.vert",
		{uniform_buffers = 1, storage_buffers = 1},
	)
	frag_shader := load_shader(r._gpu, "pbr.spv.frag", {uniform_buffers = 2, samplers = 6})

	vertex_attrs := []sdl.GPUVertexAttribute {
		{location = 0, buffer_slot = 0, format = .FLOAT3},
		{location = 1, buffer_slot = 1, format = .FLOAT2},
	}
	vertex_buffer_descriptions := []sdl.GPUVertexBufferDescription {
		{slot = 0, pitch = size_of([3]f32)},
		{slot = 1, pitch = size_of([2]f32)},
	}
	r._pbr_text_pipeline = sdl.CreateGPUGraphicsPipeline(
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
						format = r._gpu_texture_format,
						blend_state = {
							src_color_blendfactor = .SRC_ALPHA,
							dst_color_blendfactor = .ONE_MINUS_SRC_ALPHA,
							src_alpha_blendfactor = .SRC_ALPHA_SATURATE,
							dst_alpha_blendfactor = .DST_ALPHA,
							color_blend_op = .ADD,
							alpha_blend_op = .ADD,
							enable_blend = true,
						},
					}),
				has_depth_stencil_target = true,
				depth_stencil_format = GPU_DEPTH_TEX_FMT,
			},
		},
	);sdle.err(r._pbr_pipeline)
	sdl.ReleaseGPUShader(r._gpu, vert_shader)
	sdl.ReleaseGPUShader(r._gpu, frag_shader)

	return
}

@(private)
init_pbr_shape_pipe :: proc(r: ^Renderer) {
	vert_shader := load_shader(
		r._gpu,
		"pbr_shape.spv.vert",
		{uniform_buffers = 1, storage_buffers = 1},
	)
	frag_shader := load_shader(r._gpu, "pbr.spv.frag", {uniform_buffers = 2, samplers = 6})

	vertex_attrs := []sdl.GPUVertexAttribute{{location = 0, buffer_slot = 0, format = .FLOAT3}}
	vertex_buffer_descriptions := []sdl.GPUVertexBufferDescription {
		{slot = 0, pitch = size_of([3]f32)},
	}
	r._pbr_shape_pipeline = sdl.CreateGPUGraphicsPipeline(
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
						format = r._gpu_texture_format,
					}),
				has_depth_stencil_target = true,
				depth_stencil_format = GPU_DEPTH_TEX_FMT,
			},
		},
	);sdle.err(r._pbr_pipeline)
	sdl.ReleaseGPUShader(r._gpu, vert_shader)
	sdl.ReleaseGPUShader(r._gpu, frag_shader)

	return
}

@(private)
init_info_pipe :: proc(r: ^Renderer) {
	vert_shader := load_shader(r._gpu, "info.spv.vert", {uniform_buffers = 1, storage_buffers = 1})
	frag_shader := load_shader(r._gpu, "info.spv.frag", {})

	vertex_attrs := []sdl.GPUVertexAttribute{{location = 0, buffer_slot = 0, format = .FLOAT3}}
	vertex_buffer_descriptions := []sdl.GPUVertexBufferDescription {
		{slot = 0, pitch = size_of([3]f32)},
	}
	r._info_pipeline = sdl.CreateGPUGraphicsPipeline(
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
			color_target_descriptions = &(sdl.GPUColorTargetDescription{format = .R32_INT}),
			has_depth_stencil_target = true,
			depth_stencil_format = GPU_DEPTH_TEX_FMT,
		},
	},
	);sdle.err(r._info_pipeline)
	sdl.ReleaseGPUShader(r._gpu, vert_shader)
	sdl.ReleaseGPUShader(r._gpu, frag_shader)

	return
}

@(private)
init_shadow_pipe :: proc(r: ^Renderer) {
	vert_shader := load_shader(
		r._gpu,
		"shadow.spv.vert",
		{uniform_buffers = 1, storage_buffers = 1},
	)
	frag_shader := load_shader(r._gpu, "shadow.spv.frag", {})

	vertex_attrs := []sdl.GPUVertexAttribute{{location = 0, buffer_slot = 0, format = .FLOAT3}}
	vertex_buffer_descriptions := []sdl.GPUVertexBufferDescription {
		{slot = 0, pitch = size_of([3]f32)},
	}
	r._shadow_pipeline = sdl.CreateGPUGraphicsPipeline(
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
				cull_mode = .FRONT,
				// fill_mode = .LINE,
			},
			target_info = {
				num_color_targets = 0,
				has_depth_stencil_target = true,
				depth_stencil_format = GPU_DEPTH_TEX_FMT,
			},
		},
	);sdle.err(r._shadow_pipeline)
	sdl.ReleaseGPUShader(r._gpu, vert_shader)
	// sdl.ReleaseGPUShader(r._gpu, frag_shader)
	return
}

SHADOW_TEX_DIM :: 2048

init :: proc(
	gpu: ^sdl.GPUDevice,
	window: ^sdl.Window,
) -> (
	r: ^Renderer,
	err: runtime.Allocator_Error,
) {
	r = new(Renderer)
	ok := sdl.ClaimWindowForGPUDevice(gpu, window);sdle.err(ok)
	r._gpu = gpu
	r._window = window
	ok = sdl.SetGPUSwapchainParameters(gpu, window, .SDR_LINEAR, .VSYNC);sdle.err(ok)
	r._gpu_texture_format = sdl.GetGPUSwapchainTextureFormat(r._gpu, r._window)

	init_pbr_pipe(r)
	init_pbr_text_pipe(r)
	init_pbr_shape_pipe(r)
	init_shadow_pipe(r)
	init_info_pipe(r)


	// proj & view
	ok = sdl.GetWindowSize(window, &r._window_size.x, &r._window_size.y);sdle.err(ok)
	r.cam.aspect = f32(r._window_size.x) / f32(r._window_size.y)
	r.cam.fovy = 90.0
	r.cam.near = 0.001
	r.cam.far = 10
	r.cam.target = r.cam.pos
	r.cam.target.z -= 1

	w_width := u32(r._window_size.x)
	w_height := u32(r._window_size.y)
	r._depth_tex = sdl.CreateGPUTexture(
		r._gpu,
		{
			format = GPU_DEPTH_TEX_FMT,
			usage = {.DEPTH_STENCIL_TARGET},
			width = w_width,
			height = w_height,
			layer_count_or_depth = 1,
			num_levels = 1,
		},
	);sdle.err(r._depth_tex)
	r._info_tex = sdl.CreateGPUTexture(
		r._gpu,
		{
			format = .R32_INT,
			usage = {.COLOR_TARGET},
			width = w_width,
			height = w_height,
			layer_count_or_depth = 1,
			num_levels = 1,
		},
	);sdle.err(r._info_tex)

	shadow_tex := sdl.CreateGPUTexture(
		r._gpu,
		{
			format = GPU_DEPTH_TEX_FMT,
			usage = {.DEPTH_STENCIL_TARGET, .SAMPLER},
			width = SHADOW_TEX_DIM,
			height = SHADOW_TEX_DIM,
			layer_count_or_depth = 1,
			num_levels = 1,
		},
	);sdle.err(shadow_tex)
	shadow_samp := sdl.CreateGPUSampler(
		r._gpu,
		{
			min_filter = .LINEAR,
			mag_filter = .LINEAR,
			address_mode_u = .CLAMP_TO_EDGE,
			address_mode_v = .CLAMP_TO_EDGE,
			enable_compare = true,
			compare_op = .LESS,
		},
	);sdle.err(shadow_samp)


	// defaults
	start_copy_pass(r)
	r._defaut_sampler = sdl.CreateGPUSampler(r._gpu, {})
	orm_binding := load_pixel(r, {255, 128, 0, 255})
	r._tex_binds = {
		.DIFFUSE = load_pixel(r, {255, 255, 255, 255}),
		.NORMAL = load_pixel(r, {128, 128, 255, 255}),
		.METAL_ROUGH = orm_binding,
		.OCCLUSION = orm_binding,
		.EMISSIVE = load_pixel(r, {0, 0, 0, 255}),
		.SHADOW = {texture = shadow_tex, sampler = shadow_samp},
	}
	r._default_text_orm_binding = load_pixel(r, {255, 128, 69, 255})
	r._default_text_sampler = sdl.CreateGPUSampler(r._gpu, {})
	r._quad_idx_binding = load_quad_idxs(r)
	r._default_bitmap = load_bitmap(r, "jetbrains_bm.fnt")
	end_copy_pass(r)

	r.ambient_light_color = [3]f32{0.01, 0.01, 0.01}

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

	draw_indirect_buf: {
		size :: u32(size_of(Draw_Call_Mem))
		props := sdl.CreateProperties()
		sdl.SetStringProperty(props, sdl.PROP_GPU_BUFFER_CREATE_NAME_STRING, "draw_indirect_buf")
		r._draw_indirect_buf = sdl.CreateGPUBuffer(
			r._gpu,
			{usage = {.INDIRECT}, size = size, props = props},
		);sdle.err(r._draw_indirect_buf)
	}

	info_bufs: {
		r._info_latest_buf = -1
		info_tbuf_size :: size_of(u32)
		for _, i in r._info_tbufs {
			props := sdl.CreateProperties()
			tbuf_name := fmt.ctprintf("info_tbuf_%d", i)
			sdl.SetStringProperty(props, sdl.PROP_GPU_TRANSFERBUFFER_CREATE_NAME_STRING, tbuf_name)
			r._info_tbufs[i] = sdl.CreateGPUTransferBuffer(
				r._gpu,
				{usage = .DOWNLOAD, size = info_tbuf_size, props = props},
			);sdle.err(r._info_tbufs[i])
		}
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
	tex.sampler = r._defaut_sampler
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

Draw_Call_Mem :: [MAX_RENDER_NODES]sdl.GPUIndexedIndirectDrawCommand

Pipeline_Idx :: enum {
	GLTF,
	SHAPE,
}

Draw_Call_Sort_Idx :: enum {
	PIPELINE_IDX,
	MODEL_IDX,
	MATERIAL_IDX,
	PRIMITIVE_IDX,
	TRANSFORM_IDX,
}
Draw_Call_Req :: [Draw_Call_Sort_Idx]uint
Draw_Node_Req :: struct {
	model:     ^Model,
	node_idx:  u32,
	transform: mat4,
	entity_id: pool.Pool_Key,
}
Draw_Material_Batch :: struct {
	renderable:   Renderable,
	material_idx: u32,
	offset:       u32,
	draw_count:   u32,
}
Draw_Renderable_Batch :: struct {
	renderable: Renderable,
	offset:     u32,
	draw_count: u32,
}

begin_draw :: proc(r: ^Renderer) {
	mem.zero_item(&r._lens)
	mem.zero_item(&r._frag_frame_ubo)
	update_vp(r)
}

update_vp :: proc(r: ^Renderer) {
	view := lal.matrix4_look_at_f32(r.cam.pos, r.cam.target, [3]f32{0, 1, 0})
	proj_mat := lal.matrix4_perspective_f32(
		lal.to_radians(r.cam.fovy),
		r.cam.aspect,
		r.cam.near,
		r.cam.far,
	)
	r._vert_ubo.vp = proj_mat * view
}

draw_dir_light :: proc(r: ^Renderer, l: GPU_Dir_Light, pos: [3]f32) {
	r._frag_frame_ubo.dir_light = l
	r._vert_ubo.shadow_vp = calc_dir_light_vp(pos)
	r._frag_frame_ubo.num_light[.DIR] = 1
}

draw_node :: proc(r: ^Renderer, req: Draw_Node_Req) {
	model := req.model

	node := model.nodes[req.node_idx]
	mesh_idx, has_mesh := node.mesh.?
	if has_mesh {
		mesh := model.meshes[mesh_idx]
		primitive_stop := mesh.primitive_offset + mesh.num_primitives
		for i := mesh.primitive_offset; i < primitive_stop; i += 1 {
			if r._lens[.DRAW_REQ] + r._lens[.TEXT_DRAW] == MAX_RENDER_NODES do return
			primitive := model.primitives[i]
			r._draw_call_reqs[r._lens[.DRAW_REQ]] = Draw_Call_Req {
				.PIPELINE_IDX  = uint(Pipeline_Idx.GLTF),
				.MODEL_IDX     = uint(uintptr(model)),
				.MATERIAL_IDX  = uint(primitive.material),
				.PRIMITIVE_IDX = uint(i),
				.TRANSFORM_IDX = uint(r._lens[.DRAW_REQ]),
			}
			r._draw_entity_ids[r._lens[.DRAW_REQ]] = req.entity_id
			r._draw_transforms[r._lens[.DRAW_REQ]] = req.transform
			r._lens[.DRAW_REQ] += 1
		}
	}
	num_child := len(node.children)
	if num_child == 0 do return

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
	sort_text_draw_call_reqs(r)

	map_frame_transfer_buf(r)
	copy_draw_call_reqs(r)
	copy_text_draw_reqs(r)
	unmap_frame_transfer_buf(r)

	start_copy_pass(r)
	upload_transform_buf(r)
	upload_draw_call_buf(r)
	end_copy_pass(r)
}

@(private)
sort_draw_call_reqs :: proc(r: ^Renderer) {
	slice.sort_by_cmp(
		r._draw_call_reqs[:r._lens[.DRAW_REQ]],
		proc(i, j: Draw_Call_Req) -> (ordering: slice.Ordering) {
			#unroll for idx in Draw_Call_Sort_Idx {
				idx_ordering: slice.Ordering = i[idx] < j[idx] ? .Less : .Equal
				idx_ordering = i[idx] > j[idx] ? .Greater : idx_ordering
				ordering = ordering == .Equal ? idx_ordering : ordering
			}
			return
		},
	)
}

@(private)
copy_draw_call_reqs :: proc(r: ^Renderer) {
	// copies transforms and indirect draw calls to frame mem
	if r._lens[.DRAW_REQ] == 0 do return

	last_req := r._draw_call_reqs[0]
	model_matrices := &r._frame_transfer_mem.transform.ms
	normal_matrices := &r._frame_transfer_mem.transform.ns
	model_matrices[0] = r._draw_transforms[last_req[.TRANSFORM_IDX]]
	normal_matrices[0] = lal.inverse_transpose(model_matrices[0])
	renderable: Renderable
	model_ptr := uintptr(last_req[.MODEL_IDX])
	switch Pipeline_Idx(last_req[.PIPELINE_IDX]) {
	case .GLTF:
		renderable = cast(^Model)model_ptr
	case .SHAPE:
		renderable = cast(^Shape)model_ptr
	}

	last_mat_batch := Draw_Material_Batch {
		renderable   = renderable,
		material_idx = u32(last_req[.MATERIAL_IDX]),
		offset       = 0,
		draw_count   = 1,
	}
	last_model_batch := Draw_Renderable_Batch {
		renderable = renderable,
		offset     = 0,
		draw_count = 1,
	}
	num_instances: u32 = 1
	first_instance: u32 = 0
	draw_call_mem := &r._frame_transfer_mem.draw_calls
	end_iter := r._lens[.DRAW_REQ]
	for i: u32 = 1; i < end_iter; i += 1 {
		req := r._draw_call_reqs[i]
		model_matrices[i] = r._draw_transforms[req[.TRANSFORM_IDX]]
		normal_matrices[i] = lal.inverse_transpose(model_matrices[i])

		defer last_req = req
		defer num_instances += 1
		if req[.MODEL_IDX] == last_req[.MODEL_IDX] && req[.PRIMITIVE_IDX] == last_req[.PRIMITIVE_IDX] do continue
		switch Pipeline_Idx(last_req[.PIPELINE_IDX]) {
		case .GLTF:
			last_model := cast(^Model)uintptr(last_req[.MODEL_IDX])
			primitive := last_model.primitives[last_req[.PRIMITIVE_IDX]]
			draw_call_mem[r._lens[.INDIRECT]] = sdl.GPUIndexedIndirectDrawCommand {
				num_indices    = primitive.num_indices,
				num_instances  = num_instances,
				first_index    = primitive.indices_offset,
				vertex_offset  = primitive.vert_offset,
				first_instance = first_instance,
			}
		case .SHAPE:
			last_shape := cast(^Shape)uintptr(last_req[.MODEL_IDX])
			draw_call_mem[r._lens[.INDIRECT]] = sdl.GPUIndexedIndirectDrawCommand {
				num_indices    = last_shape.num_indices,
				num_instances  = num_instances,
				first_index    = 0,
				vertex_offset  = 0,
				first_instance = first_instance,
			}
		}
		r._lens[.INDIRECT] += 1
		defer last_mat_batch.draw_count += 1
		defer last_model_batch.draw_count += 1
		first_instance = i
		num_instances = 0

		if req[.MODEL_IDX] == last_req[.MODEL_IDX] && u32(req[.MATERIAL_IDX]) == last_mat_batch.material_idx do continue
		r._draw_material_batch[r._lens[.MAT_BATCH]] = last_mat_batch
		r._lens[.MAT_BATCH] += 1
		cur_renderable: Renderable
		switch Pipeline_Idx(req[.PIPELINE_IDX]) {
		case .GLTF:
			cur_renderable = cast(^Model)uintptr(req[.MODEL_IDX])
		case .SHAPE:
			cur_renderable = cast(^Shape)uintptr(req[.MODEL_IDX])
		}
		last_mat_batch = Draw_Material_Batch {
			renderable   = cur_renderable,
			material_idx = u32(req[.MATERIAL_IDX]),
			offset       = r._lens[.INDIRECT] * size_of(sdl.GPUIndexedIndirectDrawCommand),
			draw_count   = 0,
		}
		if req[.MODEL_IDX] == last_req[.MODEL_IDX] do continue
		r._draw_model_batch[r._lens[.MODEL_BATCH]] = last_model_batch
		r._lens[.MODEL_BATCH] += 1
		last_model_batch = Draw_Renderable_Batch {
			renderable = cur_renderable,
			offset     = r._lens[.INDIRECT] * size_of(sdl.GPUIndexedIndirectDrawCommand),
			draw_count = 0,
		}
	}

	// get stragglers
	last_model_idx := last_req[.MODEL_IDX]
	last_primitive_idx := last_req[.PRIMITIVE_IDX]
	model_ptr = uintptr(last_model_idx)
	switch Pipeline_Idx(last_req[.PIPELINE_IDX]) {
	case .GLTF:
		last_model := cast(^Model)model_ptr
		primitive := last_model.primitives[last_primitive_idx]
		draw_call_mem[r._lens[.INDIRECT]] = sdl.GPUIndexedIndirectDrawCommand {
			num_indices    = primitive.num_indices,
			num_instances  = num_instances,
			first_index    = primitive.indices_offset,
			vertex_offset  = primitive.vert_offset,
			first_instance = first_instance,
		}
	case .SHAPE:
		last_shape := cast(^Shape)model_ptr
		draw_call_mem[r._lens[.INDIRECT]] = sdl.GPUIndexedIndirectDrawCommand {
			num_indices    = last_shape.num_indices,
			num_instances  = num_instances,
			first_index    = 0,
			vertex_offset  = 0,
			first_instance = first_instance,
		}
	}
	r._lens[.INDIRECT] += 1

	r._draw_material_batch[r._lens[.MAT_BATCH]] = last_mat_batch
	r._lens[.MAT_BATCH] += 1
	r._draw_model_batch[r._lens[.MODEL_BATCH]] = last_model_batch
	r._lens[.MODEL_BATCH] += 1
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
	if r._lens[.INDIRECT] == 0 do return
	size := size_of(sdl.GPUIndexedIndirectDrawCommand) * r._lens[.INDIRECT]
	sdl.UploadToGPUBuffer(
		r._copy_pass,
		{transfer_buffer = r._frame_transfer_buf, offset = transfer_offset},
		{buffer = r._draw_indirect_buf, size = size},
		false,
	)
}

@(private)
upload_transform_buf :: proc(r: ^Renderer) {
	transfer_offset :: u32(offset_of(Frame_Transfer_Mem, transform))
	model_struct_offset :: u32(offset_of(Transform_Storage_Mem, ms))
	model_offset :: transfer_offset + model_struct_offset
	normal_struct_offset :: u32(offset_of(Transform_Storage_Mem, ns))
	normal_offset :: transfer_offset + normal_struct_offset
	len_transforms := r._lens[.DRAW_REQ] + r._lens[.TEXT_DRAW]
	if len_transforms == 0 do return
	size := size_of(mat4) * len_transforms

	sdl.UploadToGPUBuffer(
		r._copy_pass,
		{transfer_buffer = r._frame_transfer_buf, offset = model_offset},
		{buffer = r._transform_gpu_buf, size = size},
		false,
	)
	sdl.UploadToGPUBuffer(
		r._copy_pass,
		{transfer_buffer = r._frame_transfer_buf, offset = normal_offset},
		{buffer = r._transform_gpu_buf, offset = normal_struct_offset, size = size},
		false,
	)
}


begin_render :: proc(r: ^Renderer) {
	assert(r._render_cmd_buf == nil)
	r._active_pipeline = nil
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

poll_info :: proc(r: ^Renderer) {
	if r._info_latest_buf < 0 do return
	idx := r._info_latest_buf
	instance_idx: i32 = -1
	free_cnt := INFO_BUF_SIZE
	for i := 0; i < INFO_BUF_SIZE; i += 1 {
		if r._info_fences[idx] == nil || !sdl.QueryGPUFence(r._gpu, r._info_fences[idx]) {
			idx -= 1
			free_cnt -= 1
			if idx < 0 do idx = INFO_BUF_SIZE - 1
			continue
		}
		// ready idx!
		instance_idx_ptr := transmute([^]i32)sdl.MapGPUTransferBuffer(
			r._gpu,
			r._info_tbufs[idx],
			false,
		)
		instance_idx = instance_idx_ptr[0]
		sdl.UnmapGPUTransferBuffer(r._gpu, r._info_tbufs[idx])
		break
	}
	if instance_idx < 0 do return
	// free fence and older fences
	for i := 0; i < free_cnt; i += 1 {
		defer {
			idx -= 1
			if idx < 0 do idx = INFO_BUF_SIZE - 1
		}
		if r._info_fences[idx] == nil do continue
		sdl.ReleaseGPUFence(r._gpu, r._info_fences[idx])
		r._info_fences[idx] = nil
	}
	r.info_entity_id = r._draw_entity_ids[instance_idx]
}

info_pass :: proc(r: ^Renderer) {
	if r.info_cursor.x < 0 || r.info_cursor.y < 0 {
		return
	}
	color_target := sdl.GPUColorTargetInfo {
		texture     = r._info_tex,
		load_op     = .CLEAR,
		clear_color = {-1, 0, 0, 0},
		store_op    = .STORE,
	}
	depth_target_info := sdl.GPUDepthStencilTargetInfo {
		texture     = r._depth_tex,
		load_op     = .CLEAR,
		clear_depth = 1,
		store_op    = .DONT_CARE,
	}
	render_pass := sdl.BeginGPURenderPass(
		r._render_cmd_buf,
		&color_target,
		0,
		&depth_target_info,
	);sdle.err(render_pass)
	sdl.BindGPUGraphicsPipeline(render_pass, r._info_pipeline)
	sdl.BindGPUVertexStorageBuffers(render_pass, 0, &(r._transform_gpu_buf), 1)
	vert_ubo := Shadow_Vert_UBO {
		vp = r._vert_ubo.shadow_vp,
	}
	sdl.PushGPUVertexUniformData(r._render_cmd_buf, 0, &(vert_ubo), size_of(Shadow_Vert_UBO))
	for mod_batch in r._draw_model_batch[:r._lens[.MODEL_BATCH]] {
		bind_renderable_positions(r, render_pass, mod_batch.renderable)
		sdl.DrawGPUIndexedPrimitivesIndirect(
			render_pass,
			r._draw_indirect_buf,
			mod_batch.offset,
			mod_batch.draw_count,
		)
	}
	sdl.EndGPURenderPass(render_pass)
	copy_pass := sdl.BeginGPUCopyPass(r._render_cmd_buf);sdle.err(copy_pass)
	r._info_latest_buf += 1
	r._info_latest_buf %= INFO_BUF_SIZE
	sdl.DownloadFromGPUTexture(
		copy_pass,
		{
			texture = r._info_tex,
			x = u32(r.info_cursor.x),
			y = u32(r.info_cursor.y),
			w = 1,
			h = 1,
			d = 1,
		},
		{transfer_buffer = r._info_tbufs[r._info_latest_buf]},
	)
}

shadow_pass :: proc(r: ^Renderer) {
	lights := &r._frag_frame_ubo
	if lights.num_light[.DIR] == 0 do return

	depth_target_info := sdl.GPUDepthStencilTargetInfo {
		texture     = r._tex_binds[.SHADOW].texture,
		load_op     = .CLEAR,
		clear_depth = 1,
		store_op    = .STORE,
	}
	render_pass := sdl.BeginGPURenderPass(
		r._render_cmd_buf,
		nil,
		0,
		&depth_target_info,
	);sdle.err(render_pass)
	sdl.BindGPUGraphicsPipeline(render_pass, r._shadow_pipeline)
	sdl.BindGPUVertexStorageBuffers(render_pass, 0, &(r._transform_gpu_buf), 1)
	vert_ubo := Shadow_Vert_UBO {
		vp = r._vert_ubo.shadow_vp,
	}
	sdl.PushGPUVertexUniformData(r._render_cmd_buf, 0, &(vert_ubo), size_of(Shadow_Vert_UBO))
	for mod_batch in r._draw_model_batch[:r._lens[.MODEL_BATCH]] {
		bind_renderable_positions(r, render_pass, mod_batch.renderable)
		sdl.DrawGPUIndexedPrimitivesIndirect(
			render_pass,
			r._draw_indirect_buf,
			mod_batch.offset,
			mod_batch.draw_count,
		)
	}
	sdl.EndGPURenderPass(render_pass)
}

bind_pbr_bufs :: proc(r: ^Renderer) {
	sdl.BindGPUVertexStorageBuffers(r._render_pass, 0, &(r._transform_gpu_buf), 1)
	sdl.PushGPUVertexUniformData(r._render_cmd_buf, 0, &(r._vert_ubo), size_of(Vert_UBO))

	r._frag_frame_ubo.view_pos.xyz = r.cam.pos
	r._frag_frame_ubo.ambient_light_color.rgb = r.ambient_light_color

	sdl.PushGPUFragmentUniformData(
		r._render_cmd_buf,
		0,
		&(r._frag_frame_ubo),
		size_of(Frag_Frame_UBO),
	)
}

opaque_pass :: proc(r: ^Renderer) {
	if r._lens[.MAT_BATCH] == 0 do return
	renderable: Renderable
	pipeline_idx: Pipeline_Idx
	first_mat_batch: {
		first := r._draw_material_batch[0]
		switch v in first.renderable {
		case ^Model:
			pipeline_idx = .GLTF
			sdl.BindGPUGraphicsPipeline(r._render_pass, r._pbr_pipeline)
			bind_model(r, r._render_pass, v)
			bind_model_material(r, r._render_pass, v, first.material_idx)
		case ^Shape:
			pipeline_idx = .SHAPE
			sdl.BindGPUGraphicsPipeline(r._render_pass, r._pbr_shape_pipeline)
			bind_shape(r, r._render_pass, v)
		}
		sdl.DrawGPUIndexedPrimitivesIndirect(
			r._render_pass,
			r._draw_indirect_buf,
			first.offset,
			first.draw_count,
		)
		renderable = first.renderable
	}
	for x in r._draw_material_batch[1:r._lens[.MAT_BATCH]] {
		if x.renderable != renderable {
			switch v in x.renderable {
			case ^Model:
				bind_model(r, r._render_pass, v)
				bind_model_material(r, r._render_pass, v, x.material_idx)
			case ^Shape:
				if pipeline_idx == .GLTF {
					pipeline_idx = .SHAPE
					sdl.BindGPUGraphicsPipeline(r._render_pass, r._pbr_shape_pipeline)
				}
				bind_shape(r, r._render_pass, v)
			}
			renderable = x.renderable
		}
		model, ok := renderable.(^Model)
		if ok {
			bind_model_material(r, r._render_pass, model, x.material_idx)
		}
		sdl.DrawGPUIndexedPrimitivesIndirect(
			r._render_pass,
			r._draw_indirect_buf,
			x.offset,
			x.draw_count,
		)
	}
}
@(private)
bind_renderable_positions :: proc(
	r: ^Renderer,
	render_pass: ^sdl.GPURenderPass,
	renderable: Renderable,
) {
	switch v in renderable {
	case ^Model:
		sdl.BindGPUVertexBuffers(render_pass, 0, &(v.vert_bufs[.POS]), 1)
		sdl.BindGPUIndexBuffer(render_pass, v.index_buf, ._16BIT)
	case ^Shape:
		sdl.BindGPUVertexBuffers(render_pass, 0, &(v.pos_buf), 1)
		sdl.BindGPUIndexBuffer(render_pass, v.index_buf, ._16BIT)
	}
}

@(private)
bind_shape :: proc(r: ^Renderer, render_pass: ^sdl.GPURenderPass, shape: ^Shape) {
	sdl.BindGPUVertexBuffers(render_pass, 0, &(shape.pos_buf), 1)
	sdl.BindGPUIndexBuffer(render_pass, shape.index_buf, ._16BIT)
	material := &shape.material
	bind_material(r, render_pass, material)
}

@(private)
bind_model :: proc(r: ^Renderer, render_pass: ^sdl.GPURenderPass, model: ^Model) {
	sdl.BindGPUVertexBuffers(
		render_pass,
		0,
		cast([^]sdl.GPUBufferBinding)&model.vert_bufs,
		len(model.vert_bufs),
	)
	sdl.BindGPUIndexBuffer(render_pass, model.index_buf, ._16BIT)
}

@(private)
bind_model_material :: proc(
	r: ^Renderer,
	render_pass: ^sdl.GPURenderPass,
	model: ^Model,
	material_idx: u32,
) {
	bind_material(r, render_pass, &model.materials[material_idx])
}
@(private)
bind_material :: proc(r: ^Renderer, render_pass: ^sdl.GPURenderPass, material: ^Model_Material) {
	draw_ubo := Frag_Draw_UBO {
		diffuse_override = material.color,
		normal_scale     = material.normal_scale,
		ao_strength      = material.ao_strength,
	}
	sdl.PushGPUFragmentUniformData(r._render_cmd_buf, 1, &(draw_ubo), size_of(Frag_Draw_UBO))
	sdl.BindGPUFragmentSamplers(
		render_pass,
		0,
		cast([^]sdl.GPUTextureSamplerBinding)&material.bindings,
		len(material.bindings),
	)
}

end_render :: proc(r: ^Renderer) {
	assert(r._render_cmd_buf != nil)
	assert(r._render_pass != nil)
	sdl.EndGPURenderPass(r._render_pass)
	if r.info_cursor.x < 0 || r.info_cursor.y < 0 {
		ok := sdl.SubmitGPUCommandBuffer(r._render_cmd_buf);sdle.err(ok)
	} else {
		// info pass was made
		assert(r._info_fences[r._info_latest_buf] == nil)
		r._info_fences[r._info_latest_buf] = sdl.SubmitGPUCommandBufferAndAcquireFence(
			r._render_cmd_buf,
		);sdle.err(r._info_fences[r._info_latest_buf])
	}
	r._render_cmd_buf = nil
	r._render_pass = nil
}

screen_to_world :: proc(r: ^Renderer, screen_xy: [2]f32) -> (pos: [3]f32) {
	ndc: [4]f32
	ndc.x = 2 * (screen_xy.x / f32(r._window_size.x)) - 1
	ndc.y = 1 - 2 * (screen_xy.y / f32(r._window_size.y))
	ndc.z = 0
	ndc.w = 1.0

	update_vp(r)
	inv_vp := lal.inverse(r._vert_ubo.vp)
	world_pos := inv_vp * ndc
	pos = world_pos.xyz / world_pos.w
	return
}

