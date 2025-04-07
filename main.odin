package main

import "core:log"
import sdl "vendor:sdl3"

sdl_ok_panic :: proc(ok: bool) {
	if !ok do log.panicf("SDL Error: {}", sdl.GetError())
}
sdl_nil_panic :: proc(ptr: rawptr) {
	if ptr == nil do log.panicf("SDL Error: {}", sdl.GetError())
}

sdl_err_panic::proc{
	sdl_ok_panic,
	sdl_nil_panic,
}

main :: proc() {
	context.logger = log.create_console_logger()

	// init sdl
	ok := sdl.Init({.VIDEO}); sdl_err_panic(ok)
	window := sdl.CreateWindow("Hello Triangle SDL3 Yay", 1920, 1080, {.FULLSCREEN}); sdl_err_panic(window)
	gpu := sdl.CreateGPUDevice({.SPIRV}, true, nil); sdl_err_panic(gpu)
	ok = sdl.ClaimWindowForGPUDevice(gpu, window); sdl_err_panic(ok)

	
	main_loop: for {
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
		cmd_buf := sdl.AcquireGPUCommandBuffer(gpu); sdl_err_panic(cmd_buf)
		swapchain_tex: ^sdl.GPUTexture
		ok = sdl.WaitAndAcquireGPUSwapchainTexture(cmd_buf, window, &swapchain_tex, nil, nil); sdl_err_panic(ok)

		color_target := sdl.GPUColorTargetInfo {
			texture = swapchain_tex,
			load_op = .CLEAR,
			clear_color = {0, 0, 0, 0},
			store_op = .STORE
		}
		render_pass := sdl.BeginGPURenderPass(cmd_buf, &color_target, 1, nil)
		// begin draw

		// end draw
		sdl.EndGPURenderPass(render_pass)
		ok = sdl.SubmitGPUCommandBuffer(cmd_buf); sdl_err_panic(ok)		
	}
}
