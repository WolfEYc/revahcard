package main

import shared "../shared"
import "core:log"
import "core:math/linalg"
import "core:mem"
import sdl "vendor:sdl3"

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

Vec3 :: [3]f32
Vertex_Data :: struct {
	pos:   Vec3,
	color: sdl.FColor,
}
main :: proc() {
	context.logger = log.create_console_logger()
	when ODIN_DEBUG == true {
		sdl.SetLogPriorities(.VERBOSE)
	}

	// init sdl
	ok := sdl.Init({.VIDEO});sdl_err(ok)
	window := sdl.CreateWindow(
		"Hello Triangle SDL3 Yay",
		1920,
		1080,
		{.FULLSCREEN},
	);sdl_err(window)
	gpu := sdl.CreateGPUDevice({.SPIRV}, true, "vulkan");sdl_err(gpu)
	ok = sdl.ClaimWindowForGPUDevice(gpu, window);sdl_err(ok)

	vertices := []Vertex_Data {
		{pos = {-0.5, -0.5, 0}, color = {1, 0, 0, 1}},
		{pos = {0, 0.5, 0}, color = {0, 1, 0, 1}},
		{pos = {0.5, -0.5, 0}, color = {0, 0, 1, 1}},
	}
	vertices_byte_size := len(vertices) * size_of(Vertex_Data)
	vertices_byte_size_u32 := u32(vertices_byte_size)
	vertex_buf := sdl.CreateGPUBuffer(gpu, {usage = {.VERTEX}, size = vertices_byte_size_u32})
	//cpy to gpu
	{
		transfer_buf := sdl.CreateGPUTransferBuffer(
			gpu,
			{usage = .UPLOAD, size = vertices_byte_size_u32},
		)
		transfer_mem := sdl.MapGPUTransferBuffer(gpu, transfer_buf, false)
		mem.copy(transfer_mem, raw_data(vertices), vertices_byte_size)
		sdl.UnmapGPUTransferBuffer(gpu, transfer_buf)

		copy_cmd_buf := sdl.AcquireGPUCommandBuffer(gpu);sdl_err(copy_cmd_buf)
		defer {ok = sdl.SubmitGPUCommandBuffer(copy_cmd_buf);sdl_err(ok)}

		copy_pass := sdl.BeginGPUCopyPass(copy_cmd_buf)
		defer sdl.EndGPUCopyPass(copy_pass)

		sdl.UploadToGPUBuffer(
			copy_pass,
			{transfer_buffer = transfer_buf},
			{buffer = vertex_buf, size = vertices_byte_size_u32},
			false,
		)
	}

	vert_shader := load_shader(gpu, "default.spv.vert", {uniform_buffers = 1})
	frag_shader := load_shader(gpu, "default.spv.frag", {})

	vertex_attrs := []sdl.GPUVertexAttribute {
		{location = 0, format = .FLOAT3, offset = u32(offset_of(Vertex_Data, pos))},
		{location = 1, format = .FLOAT4, offset = u32(offset_of(Vertex_Data, color))},
	}
	pipeline := sdl.CreateGPUGraphicsPipeline(
		gpu,
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
						format = sdl.GetGPUSwapchainTextureFormat(gpu, window),
					}),
			},
		},
	)
	win_size: [2]i32
	ok = sdl.GetWindowSize(window, &win_size.x, &win_size.y);sdl_err(ok)
	aspect := f32(win_size.x) / f32(win_size.y)
	proj_mat := linalg.matrix4_perspective_f32(linalg.to_radians(f32(90)), aspect, 0.0001, 1000)
	rotation := f32(0)
	rotation_speed := linalg.to_radians(f32(90))
	position := linalg.Vector3f32{0, 0, -5}

	UBO :: struct #max_field_align (16) {
		mvp: matrix[4, 4]f32,
	}

	last_ticks := sdl.GetTicks()
	main_loop: for {
		new_ticks := sdl.GetTicks()
		delta_time := f32(new_ticks - last_ticks) / 1000
		last_ticks = new_ticks
		// process events
		ev: sdl.Event
		for sdl.PollEvent(&ev) {
			#partial switch ev.type {
			case .QUIT:
				break main_loop
			case .KEY_DOWN:
				if ev.key.scancode == .ESCAPE do break main_loop
			}
		}
		// update game state

		// render
		{
			cmd_buf := sdl.AcquireGPUCommandBuffer(gpu);sdl_err(cmd_buf)
			defer {ok = sdl.SubmitGPUCommandBuffer(cmd_buf);sdl_err(ok)}

			swapchain_tex: ^sdl.GPUTexture
			ok = sdl.WaitAndAcquireGPUSwapchainTexture(
				cmd_buf,
				window,
				&swapchain_tex,
				nil,
				nil,
			);sdl_err(ok)
			if swapchain_tex == nil do continue

			color_target := sdl.GPUColorTargetInfo {
				texture     = swapchain_tex,
				load_op     = .CLEAR,
				clear_color = {0, 0, 0, 0},
				store_op    = .STORE,
			}
			render_pass := sdl.BeginGPURenderPass(cmd_buf, &color_target, 1, nil)
			defer sdl.EndGPURenderPass(render_pass)

			sdl.BindGPUGraphicsPipeline(render_pass, pipeline)
			model_mat := linalg.matrix4_translate_f32(position)
			rotation += rotation_speed * delta_time
			model_mat *= linalg.matrix4_rotate_f32(rotation, {0, 1, 0})
			ubo := UBO {
				mvp = proj_mat * model_mat,
			}
			sdl.PushGPUVertexUniformData(cmd_buf, 0, &ubo, size_of(ubo))
			sdl.BindGPUVertexBuffers(
				render_pass,
				0,
				&(sdl.GPUBufferBinding{buffer = vertex_buf}),
				1,
			)
			sdl.DrawGPUPrimitives(render_pass, 3, 1, 0, 0)

		}
	}
}

