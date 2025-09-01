package main

import an "../animation"
import "../kernel"
import "../lib/pool"
import "../renderer"
import "base:runtime"
import "core:fmt"
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
	for _, i in s.render_state.field {
		rc := Render_Card {
			location = .FIELD,
			idx      = i32(i),
		}
		name := fmt.aprintf("render_card_field_%d", i)
		entity := Entity {
			name    = name,
			variant = rc,
		}
		insert_entity(s, &entity)
		s.render_state.field[i] = entity.id
	}
	for _, i in s.render_state.hand {
		rc := Render_Card {
			location = .HAND,
			idx      = i32(i),
		}
		name := fmt.aprintf("render_card_hand_%d", i)
		entity := Entity {
			name    = name,
			variant = rc,
		}
		insert_entity(s, &entity)
		s.render_state.hand[i] = entity.id
	}
}

Render_Card :: struct {
	active:   bool,
	pos:      an.Interpolated([3]f32),
	rot:      an.Interpolated(quaternion128),
	location: Card_Location,
	idx:      i32,
}

Render_State :: struct {
	field: [kernel.FIELD_SIZE]pool.Pool_Key,
	hand:  [kernel.HAND_SIZE]pool.Pool_Key,
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
		for &c, i in s.k.field {
			entity, ok := pool.get(&s.entities, s.render_state.field[i]);assert(ok)
			render_card(s, entity)
		}
		for &c, i in s.k.hand {
			entity, ok := pool.get(&s.entities, s.render_state.hand[i]);assert(ok)
			render_card(s, entity)
		}
	}
	renderer.end_draw(s.r)

	renderer.begin_render(s.r)
	renderer.shadow_pass(s.r)
	renderer.begin_screen_render_pass(s.r)
	renderer.bind_pbr_bufs(s.r)
	renderer.opaque_pass(s.r)
	renderer.text_pass(s.r)
	renderer.info_pass(s.r)
	renderer.end_render(s.r)
}

Card_Location :: enum {
	FIELD,
	HAND,
}


get_card_start_pos :: proc(entity: ^Entity) -> (pos: [3]f32) {
	render_card := entity.variant.(Render_Card)
	switch render_card.location {
	case .FIELD:
		FIELD_START_POS :: [3]f32{-10, 5, 0}
		CARD_OFFSET :: [2]f32{1.2, -2.2}
		xy_grid := kernel.to_grid(i32(render_card.idx))
		xy_world := [2]f32{f32(xy_grid.x), f32(xy_grid.y)} * CARD_OFFSET
		pos.y = FIELD_START_POS.y + xy_world.y
		pos.xz = FIELD_START_POS.xz
	case .HAND:
		HAND_BASE_POS :: [3]f32{-10, -4, 0}
		return HAND_BASE_POS
	}
	return
}
get_card_inactive_pos :: proc(entity: ^Entity) -> (pos: [3]f32) {
	render_card := entity.variant.(Render_Card)
	switch render_card.location {
	case .FIELD:
		FIELD_START_POS :: [3]f32{10, 5, 0}
		CARD_OFFSET :: [2]f32{1.2, -2.2}
		xy_grid := kernel.to_grid(i32(render_card.idx))
		xy_world := [2]f32{f32(xy_grid.x), f32(xy_grid.y)} * CARD_OFFSET
		pos.y = FIELD_START_POS.y + xy_world.y
		pos.xz = FIELD_START_POS.xz
	case .HAND:
		HAND_BASE_POS :: [3]f32{10, -4, 0}
		return HAND_BASE_POS
	}
	return
}

get_card_active_pos :: proc(entity: ^Entity) -> (pos: [3]f32) {
	render_card := entity.variant.(Render_Card)
	switch render_card.location {
	case .FIELD:
		FIELD_BASE_POS :: [3]f32{-5, 5, 0}
		CARD_OFFSET :: [2]f32{1.2, -2.2}
		xy_grid := kernel.to_grid(i32(render_card.idx))
		xy_world := [2]f32{f32(xy_grid.x), f32(xy_grid.y)} * CARD_OFFSET
		pos.xy = FIELD_BASE_POS.xy + xy_world
		pos.z = FIELD_BASE_POS.z
	case .HAND:
		HAND_BASE_POS :: [3]f32{-3, -4, 0}
		CARD_OFFSET :: 1.2
		x_world := f32(render_card.idx) * CARD_OFFSET
		pos.x = HAND_BASE_POS.x + x_world
		pos.yz = HAND_BASE_POS.yz
	}
	return
}

get_card_inactive_rot :: proc(entity: ^Entity) -> (rot: quaternion128) {
	rot = lal.quaternion_from_pitch_yaw_roll_f32(0, lal.PI + 0.001, 0)
	return
}
get_card_active_rot :: proc(entity: ^Entity) -> (rot: quaternion128) {
	rot = lal.quaternion_from_pitch_yaw_roll_f32(0, 0, 0)
	return
}

render_card :: proc(s: ^Game, entity: ^Entity) {
	// interpolation
	render_card := entity.variant.(Render_Card)
	card: ^kernel.Card
	switch render_card.location {
	case .FIELD:
		card = &s.k.field[render_card.idx]
	case .HAND:
		card = &s.k.hand[render_card.idx]
	}
	c_active := kernel.is_card_active(card^)
	if render_card.active != c_active {
		render_card.active = c_active
		pos: [3]f32
		rot: quaternion128
		if c_active {
			pos = get_card_active_pos(entity)
			rot = get_card_active_rot(entity)
			render_card.pos.start = get_card_start_pos(entity)
			render_card.rot.start = get_card_inactive_rot(entity)
		} else {
			pos = get_card_inactive_pos(entity)
			rot = get_card_inactive_rot(entity)
		}
		an.set_target(&render_card.pos, s.time_s, pos)
		CARD_ANIM_S :: 0.2
		render_card.pos.end_s = s.time_s + CARD_ANIM_S
	}

	// card
	card_pos := an.interpolate(render_card.pos, s.time_s)
	card_rot := an.interpolate(render_card.rot, s.time_s)
	transform := lal.matrix4_from_trs(card_pos, card_rot, 1)
	card_req := renderer.Draw_Shape_Req {
		shape     = &s.assets.card,
		transform = transform,
		entity_id = entity.id,
	}
	renderer.draw_shape(s.r, card_req)

	// card name
	NAME_POS: [3]f32 : {-0.5, 1, 0.01}
	card_name := kernel.card_to_name(s.k.name_db, card^)
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
	card_hp_str := strconv.itoa(hp_text[:], int(card.hp))
	hp_transform := transform * lal.matrix4_from_trs(HP_POS, lal.QUATERNIONF32_IDENTITY, 1)
	hp_req := renderer.Draw_Text_Req {
		text      = card_hp_str,
		transform = hp_transform,
	}
	renderer.draw_text(s.r, hp_req)
}

