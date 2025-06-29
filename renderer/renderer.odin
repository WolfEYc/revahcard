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

MAX_MODELS :: 4096
MAX_RENDER_NODES :: 4096
MAX_RENDER_LIGHTS :: 64

Renderer :: struct {
	cam:                        Camera,
	ambient_light_color:        [3]f32,
	model_map:                  map[string]glist.Glist_Idx,
	// render nececities
	_gpu:                       ^sdl.GPUDevice,
	_window:                    ^sdl.Window,
	_pipeline:                  ^sdl.GPUGraphicsPipeline,
	_proj_mat:                  matrix[4, 4]f32,
	_depth_tex:                 ^sdl.GPUTexture,
	_defaut_sampler:            ^sdl.GPUSampler,

	// catalog
	_models:                    glist.Glist(Model),

	// copy
	_copy_cmd_buf:              ^sdl.GPUCommandBuffer,
	_copy_pass:                 ^sdl.GPUCopyPass,

	// transform storage buf
	_transform_buffer:          Transform_Storage_Buffer,
	_transform_buffer_cheata:   [MAX_RENDER_NODES]matrix[4, 4]f32,
	_transform_gpu_buffer:      ^sdl.GPUBuffer,
	_transform_transfer_buffer: ^sdl.GPUTransferBuffer,

	// lights storage buf
	_lights_buffer:             [MAX_RENDER_LIGHTS]GPU_Point_Light,
	_lights_gpu_buffer:         ^sdl.GPUBuffer,
	_lights_transfer_buffer:    ^sdl.GPUTransferBuffer,

	// per frame                model     mesh      transform
	_draw_state:                [dynamic][dynamic][dynamic]u32, // _transform_buffer index
	_draw_cmd_buf:              ^sdl.GPUCommandBuffer,
	_draw_render_pass:          ^sdl.GPURenderPass,
	_lights_rendered:           u32,
	_transforms_rendered:       u32,
	_vert_ubo:                  Vert_UBO,
	_frag_ubo:                  Frag_UBO,
}

Camera :: struct {
	pos:    [3]f32,
	target: [3]f32,
}

GPU_Point_Light :: struct #align (32) {
	pos:   [4]f32, // 16
	color: [4]f32, // 16
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
	vert_shader := load_shader(r._gpu, "pbr.spv.vert", {uniform_buffers = 1, storage_buffers = 1})
	frag_shader := load_shader(
		r._gpu,
		"pbr.spv.frag",
		{uniform_buffers = 1, storage_buffers = 1, samplers = 5},
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
	r._defaut_sampler = sdl.CreateGPUSampler(r._gpu, {})

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
	r._lights_gpu_buffer = sdl.CreateGPUBuffer(
		r._gpu,
		{usage = {.GRAPHICS_STORAGE_READ}, size = lights_size},
	);sdle.err(r._lights_gpu_buffer)
	r._lights_transfer_buffer = sdl.CreateGPUTransferBuffer(
		r._gpu,
		{usage = .UPLOAD, size = lights_size},
	);sdle.err(r._lights_transfer_buffer)

	r._models = glist.make(Model, MAX_MODELS) or_return
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

local_transform :: #force_inline proc(n: Model_Node) -> lal.Matrix4f32 {
	return lal.matrix4_from_trs_f32(n.pos, n.rot, n.scale)
}

Draw_Req :: struct {
	model_idx: glist.Glist_Idx,
	node_idx:  u32,
	transform: matrix[4, 4]f32,
}
// call me a bunch!
draw_node :: proc(r: ^Renderer, req: Draw_Req) {
	Draw_Model_Node_Req :: struct {
		model:     ^Model,
		meshes:    ^[dynamic][dynamic]u32,
		node_idx:  u32,
		transform: matrix[4, 4]f32,
	}
	sub_req: Draw_Model_Node_Req
	sub_req.model = glist.get(&r._models, req.model_idx)
	req_len_model := req.model_idx + 1
	if req_len_model > u32(len(r._draw_state)) do resize(&r._draw_state, req_len_model)
	sub_req.meshes = &r._draw_state[req.model_idx]
	req_len_mesh := len(sub_req.model.meshes)
	if req_len_mesh > len(sub_req.meshes) do resize(sub_req.meshes, req_len_mesh)
	sub_req.transform = req.transform

	draw_model_node :: proc(r: ^Renderer, req: Draw_Model_Node_Req) {
		node := req.model.nodes[req.node_idx]
		sub_req := req
		sub_req.transform = local_transform(node) * req.transform
		mesh_idx, has_mesh := node.mesh.?
		if has_mesh {
			mesh := req.model.meshes[mesh_idx]
			transform_idxs := &req.meshes[mesh_idx]
			r._transform_buffer_cheata[r._transforms_rendered] = sub_req.transform
			append(transform_idxs, r._transforms_rendered)
			r._transforms_rendered += 1
		}
		light, has_light := node.light.?
		if has_light {
			pos4: [4]f32
			pos4.xyz = node.pos
			pos4.a = 1
			light := req.model.lights[light]
			r._lights_buffer[r._lights_rendered] = GPU_Point_Light {
				pos   = pos4 * req.transform,
				color = light.color,
			}
			r._lights_rendered += 1
		}
		for child in node.children {
			sub_req.node_idx = child
			draw_model_node(r, sub_req)
		}
	}
	draw_model_node(r, sub_req)
}
// call me afterwards to render the frame
render_frame :: proc(r: ^Renderer) {
	begin_frame(r)
	draw_calls(r)
	// log.debug("draw good!")
	storage_buffer_uploads: {
		start_copy_pass(r)
		upload_transform_buffer(r)
		// log.debug("transform good!")
		upload_lights_buffer(r)
		// log.debug("lights good!")
		end_copy_pass(r)
	}
	end_frame(r)
}

@(private)
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
}


@(private)
draw_calls :: proc(r: ^Renderer) {

	// log.debug("draw init good!")
	r._transforms_rendered = 0
	for meshes, model_idx in r._draw_state {
		for transform_idxs, mesh_idx in meshes {
			draw_instances := u32(0)
			for transform_idx in transform_idxs {
				r._transform_buffer.ms[r._transforms_rendered] =
					r._transform_buffer_cheata[transform_idx]
				// r._transform_buffer.ns[r._nodes_rendered] = lal.inverse_transpose(
				// 	node._global_transform,
				// )
				draw_instances += 1
				r._transforms_rendered += 1
			}
			if draw_instances == 0 do continue
			model := glist.get(&r._models, glist.Glist_Idx(model_idx))
			mesh := model.meshes[mesh_idx]
			for primitive_idx in mesh { 	// TODO actually do the draw call correctly
				sdl.BindGPUFragmentSamplers(
					r._draw_render_pass,
					0,
					raw_data(material.bindings[:]),
					len(material.bindings),
				)
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
				first_draw_index := r._transforms_rendered - draw_instances
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
	}
	return
}

@(private)
upload_transform_buffer :: proc(r: ^Renderer) {
	if r._transforms_rendered == 0 {
		return
	}
	size := size_of(Transform_Storage_Buffer) * r._transforms_rendered

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

@(private)
end_frame :: proc(r: ^Renderer) {
	assert(r._draw_render_pass != nil)
	assert(r._draw_cmd_buf != nil)
	sdl.EndGPURenderPass(r._draw_render_pass)
	ok := sdl.SubmitGPUCommandBuffer(r._draw_cmd_buf);sdle.err(ok)
	r._draw_render_pass = nil
	r._draw_cmd_buf = nil
	r._lights_rendered = 0
	r._transforms_rendered = 0
}

