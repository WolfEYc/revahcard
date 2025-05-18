package main

import "../lib/pool"
import "../lib/sdle"
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
	ok := sdl.Init({.VIDEO});sdle.sdl_err(ok)

	gpu := sdl.CreateGPUDevice({.SPIRV}, true, "vulkan");sdle.sdl_err(gpu)
	window := sdl.CreateWindow(
		"Hello Triangle SDL3 Yay",
		1920,
		1080,
		{.FULLSCREEN},
	);sdle.sdl_err(window)
	r, err := renderer.new(gpu, window)
	if err != nil do log.panic(err)
	err = renderer.load_all_assets(&r)
	if err != nil do log.panic(err)

	// load some bananers
	banana_node, node_err := renderer.make_node(&r, {mesh_name = "item-banana"})
	if node_err != nil do log.panic(node_err)
	log.infof("banana_key=%v", banana_node)


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
		renderer.render(&r)
	}
}

