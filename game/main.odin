package main

import "../lib/glist"
import "../lib/sdle"
import "../renderer"
import "base:runtime"
import "core:log"
import "core:math"
import lal "core:math/linalg"
import "core:math/rand"
import "core:mem"
import sdl "vendor:sdl3"

GameState :: struct {
	deltatime:   f32,
	movedir:     [2]f32,
	mouse_delta: [2]f32,
	rot:         [3]f32, // yaw pitch roll
	freecam:     bool,
}

main :: proc() {
	context.logger = log.create_console_logger()
	when ODIN_DEBUG {
		sdl.SetLogPriorities(.VERBOSE)
		sdl.SetHint(sdl.HINT_RENDER_VULKAN_DEBUG, "1")
	}

	// init sdl
	ok := sdl.Init({.VIDEO});sdle.err(ok)

	gpu := sdl.CreateGPUDevice({.SPIRV}, true, "vulkan");sdle.err(gpu)
	window := sdl.CreateWindow(
		"Hello Triangle SDL3 Yay",
		1920,
		1080,
		{.FULLSCREEN},
	);sdle.err(window)
	r, err := renderer.init(gpu, window)
	if err != nil do log.panic(err)
	err = renderer.load_all_assets(r)
	if err != nil do log.panic(err)

	last_ticks := sdl.GetTicks()
	s: GameState

	drag_racer_idx, has_drag_racer := r.model_map["vehicle_drag_racer.glb"];assert(has_drag_racer)
	drag_racer_rot: [3]f32

	main_loop: for {
		temp_mem := runtime.default_temp_allocator_temp_begin()
		defer runtime.default_temp_allocator_temp_end(temp_mem)

		new_ticks := sdl.GetTicks()
		s.deltatime = f32(new_ticks - last_ticks) / 1000
		last_ticks = new_ticks
		// process events
		ev: sdl.Event
		for sdl.PollEvent(&ev) {
			#partial switch ev.type {
			case .QUIT:
				break main_loop
			case .KEY_DOWN:
				#partial switch ev.key.scancode {
				case .ESCAPE:
					break main_loop
				}
			}
			freecam_eventhandle(&s, r, ev)
		}
		// update state
		freecam_update(&s, r)

		drag_racer := glist.get(r._models, drag_racer_idx)
		num_drag_racer :: 1
		transforms := make([]matrix[4, 4]f32, num_drag_racer, context.temp_allocator)
		drag_racer_rot_spd :: 90 * lal.RAD_PER_DEG
		drag_racer_rot.y += drag_racer_rot_spd * s.deltatime
		drag_racer_quat := lal.quaternion_from_euler_angles(
			drag_racer_rot.x,
			drag_racer_rot.y,
			drag_racer_rot.z,
			.XYZ,
		)
		transforms[0] = lal.matrix4_from_trs([3]f32{0, 0, 0}, drag_racer_quat, [3]f32{1, 1, 1})
		// render
		renderer.begin_frame(r)
		// draw sh*t
		renderer.draw_node(r, {model = drag_racer, transforms = transforms}, 0)

		renderer.end_frame(r)
	}
}

