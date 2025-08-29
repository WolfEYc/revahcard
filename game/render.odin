package main

import an "../animation"
import "../kernel"
import "../renderer"
import "base:runtime"
import lal "core:math/linalg"
import "core:strconv"

import "core:math"
import "core:strings"

Render_Assets :: struct {
	card: renderer.Shape,
	quad: renderer.Shape,
}

load_assets :: proc(s: ^Game) {
	renderer.start_copy_pass(s.r)
	s.assets.card = renderer.gen_rrect(
	s.r,
	{
		size    = {1, 2},
		radius  = 0.1,
		quality = 64, // noice
	},
	)
	s.assets.quad = renderer.gen_rrect(
	s.r,
	{
		size    = {20, 20},
		radius  = 0.1,
		quality = 4, // noice
	},
	)
	renderer.end_copy_pass(s.r)
}

Render_Card :: struct {
	active: bool,
	pos:    an.Interpolated([3]f32),
	rot:    an.Interpolated(quaternion128),
}

Render_State :: struct {
	field: [kernel.FIELD_SIZE]Render_Card,
	hand:  [kernel.HAND_SIZE]Render_Card,
}

render :: proc(s: ^Game) {
	temp_mem := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp_mem)

	renderer.begin_draw(s.r)

	light: {
		pos := [3]f32{-0.05, -0.05, 3}
		dir_to_light: [4]f32
		dir_to_light.xyz = lal.normalize(pos)
		dir_to_light.w = 1.0

		renderer.draw_dir_light(
			s.r,
			{dir_to_light = dir_to_light, color = [4]f32{5, 5, 5, 1}},
			pos,
		)
	}
	bg: {
		transform := lal.matrix4_from_trs_f32({0, 0, -5}, lal.QUATERNIONF32_IDENTITY, 1)
		req := renderer.Draw_Shape_Req {
			shape     = &s.assets.quad,
			transform = transform,
		}
		renderer.draw_shape(s.r, req)
	}
	cards: {
		// field
		for c, i in s.k.field {
			rc := s.render_state.field[i]
			render_card(s, rc, c)
		}
		for c, i in s.k.hand {
			rc := s.render_state.hand[i]
			render_card(s, rc, c)
		}
	}
	renderer.end_draw(s.r)

	renderer.begin_render(s.r)
	renderer.shadow_pass(s.r)
	renderer.begin_screen_render_pass(s.r)
	renderer.bind_pbr_bufs(s.r)
	renderer.opaque_pass(s.r)
	renderer.text_pass(s.r)
	renderer.end_render(s.r)
}


render_card :: proc(s: ^Game, rc: Render_Card, c: kernel.Card) {
	// TODO make it so if the card active state changes,
	// some sort of animation will happen perhaps

	// card
	card_pos := an.interpolate(rc.pos, s.time_s)
	card_rot := an.interpolate(rc.rot, s.time_s)
	transform := lal.matrix4_from_trs(card_pos, card_rot, 1)
	card_req := renderer.Draw_Shape_Req {
		shape     = &s.assets.card,
		transform = transform,
	}
	renderer.draw_shape(s.r, card_req)

	// card name
	NAME_POS: [3]f32 : {-0.5, 1, 0.01}
	card_name := kernel.card_to_name(s.k.name_db, c)
	card_name_str := strings.concatenate(
		{card_name.adj, card_name.color.name, card_name.food},
		context.temp_allocator,
	)
	name_transform := transform * lal.matrix4_from_trs(NAME_POS, lal.QUATERNIONF32_IDENTITY, 1)
	name_req := renderer.Draw_Text_Req {
		text      = card_name_str,
		transform = name_transform,
	}
	renderer.draw_text(s.r, name_req)

	// card hp
	HP_POS: [3]f32 : {-0.5, -0.9, 0.01}
	hp_text: [10]byte
	card_hp_str := strconv.itoa(hp_text[:], int(c.hp))
	hp_transform := transform * lal.matrix4_from_trs(HP_POS, lal.QUATERNIONF32_IDENTITY, 1)
	hp_req := renderer.Draw_Text_Req {
		text      = card_hp_str,
		transform = hp_transform,
	}
	renderer.draw_text(s.r, hp_req)
}

