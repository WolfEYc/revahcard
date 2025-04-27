package main

import "core:log"
import lal "core:math/linalg"
import "core:mem"
import sdl "vendor:sdl3"


MAX_DYNAMIC_BATCH :: 64
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

	gpu := sdl.CreateGPUDevice({.SPIRV}, true, "vulkan");sdl_err(gpu)
	window := sdl.CreateWindow(
		"Hello Triangle SDL3 Yay",
		1920,
		1080,
		{.FULLSCREEN},
	);sdl_err(window)
	win_size: [2]i32
	ok = sdl.GetWindowSize(window, &win_size.x, &win_size.y);sdl_err(ok)
	aspect := f32(win_size.x) / f32(win_size.y)
	proj_mat := lal.matrix4_perspective_f32(lal.to_radians(f32(90)), aspect, 0.0001, 1000)
	rotation := f32(0)
	rotation_speed := lal.to_radians(f32(90))
	position := lal.Vector3f32{0, 0, -5}

	Mvp_Ubo :: struct {
		mvps: [MAX_DYNAMIC_BATCH]matrix[4, 4]f32,
	}
	mvp_ubo: Mvp_Ubo
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

			// draw
			{
				num_instances := u32(2)
				model_mat := lal.matrix4_translate_f32(position)
				model_mat2 := model_mat * lal.matrix4_translate_f32({3, 0, 0})
				rotation += rotation_speed * delta_time
				model_mat *= lal.matrix4_rotate_f32(rotation, {1, 0, 0})
				model_mat2 *= lal.matrix4_rotate_f32(rotation, {0, 1, 0})
				mvp_ubo.mvps[0] = proj_mat * model_mat
				mvp_ubo.mvps[1] = proj_mat * model_mat2

				sdl.PushGPUVertexUniformData(
					cmd_buf,
					0,
					&(mvp_ubo),
					size_of(proj_mat) * num_instances,
				)
				sdl.BindGPUVertexBuffers(
					render_pass,
					0,
					&(sdl.GPUBufferBinding{buffer = vertex_buf}),
					1,
				)
				sdl.BindGPUIndexBuffer(
					render_pass,
					sdl.GPUBufferBinding{buffer = indices_buf},
					._16BIT,
				)
				sdl.DrawGPUIndexedPrimitives(render_pass, indices_len_u32, num_instances, 0, 0, 0)
			}
		}
	}
}

