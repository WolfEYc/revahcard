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
		sdl.SetHint(sdl.HINT_RENDER_VULKAN_DEBUG, "1")
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
	banana_key, node_err := renderer.make_node(&r, "item-banana", pos = {0, 0, -1})
	if node_err != nil do log.panic(node_err)
	log.infof("banana_key=%v", banana_key)

	renderer.flush_nodes(&r)
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
		banana, ok := pool.get(&r.nodes, banana_key);assert(ok)
		x_rotation_amt := lal.to_radians(f32(45) * delta_time)
		y_rotation_amt := lal.to_radians(f32(90) * delta_time)
		z_rotation_amt := lal.to_radians(f32(15) * delta_time)
		// log.debugf("rot_amt=%.2f", rotation_amt)
		rot_apply := lal.quaternion_from_euler_angles_f32(
			x_rotation_amt,
			y_rotation_amt,
			z_rotation_amt,
			.XYZ,
		)
		banana.rot = rot_apply * banana.rot


		// render
		renderer.flush_nodes(&r)
		renderer.render(&r)
	}
}

