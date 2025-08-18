package main

import "../animation"
import "../lib/glist"
import "../lib/sdle"
import "../renderer"
import "base:runtime"
import "core:log"
import "core:math"
import lal "core:math/linalg"
import "core:math/rand"
import "core:mem"
import "core:slice"
import "core:time"
import sdl "vendor:sdl3"

GameState :: struct {
	time_s:      f32,
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

	last_ticks := sdl.GetTicks()
	s: GameState
	s.time_s = f32(last_ticks) / 1000

	renderer.start_copy_pass(r)
	drag_racer := renderer.load_gltf(r, "CompareNormal.glb")
	light_cube := renderer.load_gltf(r, "white_light_cube.glb")
	sun_n_floor := renderer.load_gltf(r, "sun_n_floor.glb")
	card := renderer.gen_rrect(
	r,
	{
		size    = {1, 2},
		radius  = 0.2,
		quality = 64, // noice
	},
	)
	renderer.end_copy_pass(r)

	sun_idx: u32
	floor_idx: u32
	sun_idx, ok = renderer.get_node(sun_n_floor, "Sphere");assert(ok)
	floor_idx, ok = renderer.get_node(sun_n_floor, "Cube");assert(ok)

	r.cam.pos.y = 1
	r.cam.pos.z = 1

	main_loop: for {
		temp_mem := runtime.default_temp_allocator_temp_begin()
		defer runtime.default_temp_allocator_temp_end(temp_mem)

		new_ticks := sdl.GetTicks()
		s.deltatime = f32(new_ticks - s.ticks) / 1000
		s.time_s = f32(new_ticks) / 1000
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

		renderer.begin_draw(r)
		{
			deg_per_s :: 90
			micros_per_deg :: 1_000_000 / deg_per_s
			degs := f64(s.ticks_ns / micros_per_deg) / 1000.0
			rads := f32(degs * lal.RAD_PER_DEG)
			quat := lal.quaternion_from_pitch_yaw_roll_f32(0, rads, 0)
			transform := lal.matrix4_from_trs([3]f32{0, 0, 0}, quat, [3]f32{1, 1, 1})
			transform2 := lal.matrix4_from_trs([3]f32{0, 1, 0}, quat, [3]f32{1, 1, 1})
			req := renderer.Draw_Node_Req {
				model     = &drag_racer,
				transform = transform,
				node_idx  = 0,
			}
			renderer.draw_node(r, req)
			req2 := renderer.Draw_Node_Req {
				model     = &drag_racer,
				transform = transform2,
				node_idx  = 1,
			}
			renderer.draw_node(r, req2)
		}
		{
			deg_per_s :: 90
			micros_per_deg :: 1_000_000 / deg_per_s
			degs := f64(s.ticks_ns / micros_per_deg) / 1000.0
			rads := f32(degs * lal.RAD_PER_DEG)
			quat := lal.quaternion_from_pitch_yaw_roll_f32(0, rads, 0)
			transform1 := lal.matrix4_from_trs([3]f32{1, 0.7, 0}, quat, [3]f32{1, 1, 1})
			transform2 := lal.matrix4_from_trs([3]f32{-1, 0.7, 0}, quat, [3]f32{1, 1, 1})
			req1 := renderer.Draw_Node_Req {
				model     = &light_cube,
				transform = transform1,
				node_idx  = 1,
			}
			req2 := renderer.Draw_Node_Req {
				model     = &light_cube,
				transform = transform2,
				node_idx  = 1,
			}
			// renderer.draw_node(r, req1)
			// renderer.draw_node(r, req2)
		}
		{
			rot := lal.quaternion_from_pitch_yaw_roll_f32(3 * lal.PI / 2, 0, lal.PI / 4)
			transform := lal.matrix4_from_trs_f32(
			[3]f32{3, 1, 0},
			rot,
			[3]f32{1, 1, 1}, // scale
			)
			renderer.draw_text(
				r,
				{
					text      = "Hello World!",
					transform = transform, // yay
					color     = [4]f32{0.5, 0.1, 0.2, 1.0},
				},
			)
		}
		{
			floor_rot := lal.QUATERNIONF32_IDENTITY
			floor_transform := lal.matrix4_from_trs_f32(
				[3]f32{0, -1, 0},
				floor_rot,
				[3]f32{1, 1, 1},
			)
			floor_req := renderer.Draw_Node_Req {
				model     = &sun_n_floor,
				node_idx  = floor_idx,
				transform = floor_transform,
			}
			renderer.draw_node(r, floor_req)
			pos := [3]f32{-0.05, 3, 0.05}
			dir_to_light: [4]f32
			dir_to_light.xyz = lal.normalize(pos)
			dir_to_light.w = 1.0

			renderer.draw_dir_light(
				r,
				{dir_to_light = dir_to_light, color = [4]f32{5, 5, 5, 1}},
				pos,
			)
		}
		{
			// render some shapes!
			rot := lal.quaternion_from_pitch_yaw_roll_f32(-lal.PI / 4, -lal.PI / 2, 0)
			transform := lal.matrix4_from_trs_f32(
				[3]f32{2, 2, -2},
				rot, // yay
				[3]f32{1, 1, 1},
			)
			req := renderer.Draw_Shape_Req {
				shape     = &card,
				transform = transform,
			}
			times: [3]f32 = {s.time_s, s.time_s * 2, s.time_s / 2}
			times.r -= math.floor(times.r)
			times.g -= math.floor(times.g)
			times.b -= math.floor(times.b)
			card.material.color.rgb = times
			renderer.draw_shape(r, req)
		}
		renderer.end_draw(r)

		renderer.begin_render(r)
		renderer.shadow_pass(r)
		renderer.begin_screen_render_pass(r)
		renderer.bind_pbr_bufs(r)
		renderer.opaque_pass(r)
		renderer.text_pass(r)
		renderer.end_render(r)
	}
}

