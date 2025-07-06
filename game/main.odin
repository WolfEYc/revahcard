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
	ticks:       u64,
	ticks_ns:    u64,
	deltatime:   f32, // in seconds
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
	window := sdl.CreateWindow("buffer", 1920, 1080, {.FULLSCREEN});sdle.err(window)
	r, err := renderer.init(gpu, window)
	if err != nil do log.panic(err)
	err = renderer.load_all_assets(r)
	if err != nil do log.panic(err)

	last_ticks := sdl.GetTicks()
	s: GameState

	drag_racer_idx, has_drag_racer := r.model_map["vehicle-drag-racer.glb"];assert(has_drag_racer)
	drag_racer_model := glist.get(r.models, drag_racer_idx)
	drag_racer_node, has_drag_racer_node :=
		drag_racer_model.node_map["vehicle-drag-racer"];assert(has_drag_racer_node)
	light_cube_idx, has_light_cube := r.model_map["white_light_cube.glb"];assert(has_light_cube)
	light_cube_model := glist.get(r.models, light_cube_idx)
	r.cam.pos.y = 1
	r.cam.pos.z = 1

	main_loop: for {
		temp_mem := runtime.default_temp_allocator_temp_begin()
		defer runtime.default_temp_allocator_temp_end(temp_mem)

		new_ticks := sdl.GetTicks()
		s.deltatime = f32(new_ticks - s.ticks) / 1000
		s.ticks = new_ticks
		s.ticks_ns = sdl.GetTicksNS()
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

		drag_racer_req: renderer.Draw_Req
		{
			num_instances :: 1
			deg_per_s :: 90
			micros_per_deg :: 1_000_000 / deg_per_s
			degs := f64(s.ticks_ns / micros_per_deg) / 1000.0
			rads := f32(degs * lal.RAD_PER_DEG)
			quat := lal.quaternion_from_pitch_yaw_roll_f32(0, rads, 0)
			transforms := make([]matrix[4, 4]f32, num_instances, context.temp_allocator)
			transforms[0] = lal.matrix4_from_trs([3]f32{0, 0, 0}, quat, [3]f32{1, 1, 1})
			drag_racer_req = renderer.Draw_Req {
				model      = drag_racer_model,
				transforms = transforms,
				node_idx   = drag_racer_node,
			}
		}
		light_cube_req: renderer.Draw_Req
		{
			num_instances :: 2
			deg_per_s :: 90
			micros_per_deg :: 1_000_000 / deg_per_s
			degs := f64(s.ticks_ns / micros_per_deg) / 1000.0
			rads := f32(degs * lal.RAD_PER_DEG)
			quat := lal.quaternion_from_pitch_yaw_roll_f32(0, rads, 0)
			transforms := make([]matrix[4, 4]f32, num_instances, context.temp_allocator)
			transforms[0] = lal.matrix4_from_trs([3]f32{1, 0.7, 0}, quat, [3]f32{1, 1, 1})
			transforms[1] = lal.matrix4_from_trs([3]f32{-1, 0.7, 0}, quat, [3]f32{1, 1, 1})
			light_cube_req = renderer.Draw_Req {
				model      = light_cube_model,
				transforms = transforms,
				node_idx   = 1,
			}
		}
		// render
		renderer.begin_frame(r)
		// draw sh*t
		renderer.draw_node(r, drag_racer_req)
		renderer.draw_node(r, light_cube_req)

		renderer.end_frame(r)
	}
}

