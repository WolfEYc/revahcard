package main

import "../lib/pool"
import "../lib/sdle"
import "../renderer"
import "core:log"
import "core:math"
import lal "core:math/linalg"
import "core:math/rand"
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

	spawn :: proc(r: ^renderer.Renderer, bananers: ^[dynamic]pool.Pool_Key, model: string) {
		// load some bananers
		pos: [3]f32
		rot: [3]f32
		{
			pos.x = rand.float32_range(-2, 2)
			pos.y = rand.float32_range(-1.25, 1.25)
			pos.z = rand.float32_range(-4, -1.5)
			rot.x = rand.float32_range(-math.PI, math.PI)
			rot.y = rand.float32_range(-math.PI, math.PI)
			rot.z = rand.float32_range(-math.PI, math.PI)
		}

		rot_quat := lal.quaternion_from_euler_angles_f32(rot[0], rot[1], rot[2], .XYZ)

		banana_key, node_err := renderer.make_node(r, model, pos = pos, rot = rot_quat)
		if node_err != nil do log.panic(node_err)
		append(bananers, banana_key)
	}
	bananers := make([dynamic]pool.Pool_Key, 0, 1000)

	for _ in 0 ..< 500 {
		spawn(&r, &bananers, "item-banana")
		spawn(&r, &bananers, "item-box")
	}

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
		for banana_key in bananers {
			banana, ok := renderer.get_node(&r, banana_key);assert(ok)
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
		}

		// r.camera.pos.x += f32(0.1) * delta_time
		// r.camera.pos.y -= f32(0.1) * delta_time

		// render
		renderer.flush_nodes(&r)
		renderer.render(&r)
	}
}

