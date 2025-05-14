package main

import "../renderer"
import "core:log"
import lal "core:math/linalg"
import "core:mem"
import sdl "vendor:sdl3"


main :: proc() {
	context.logger = log.create_console_logger()
	when ODIN_DEBUG == true {
		sdl.SetLogPriorities(.VERBOSE)
	}

	// init sdl
	ok := sdl.Init({.VIDEO});renderer.sdl_err(ok)

	gpu := sdl.CreateGPUDevice({.SPIRV}, true, "vulkan");renderer.sdl_err(gpu)
	window := sdl.CreateWindow(
		"Hello Triangle SDL3 Yay",
		1920,
		1080,
		{.FULLSCREEN},
	);renderer.sdl_err(window)
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

	}
}

