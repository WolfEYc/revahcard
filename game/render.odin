package main

import an "../animation"
import "../kernel"
import "../lib/pool"
import "../renderer"
import "base:runtime"
import sa "core:container/small_array"
import "core:fmt"
import "core:log"
import lal "core:math/linalg"
import "core:strconv"

import "core:math"
import "core:strings"

Render_Assets :: struct {
	card:     renderer.Shape,
	quad:     renderer.Shape,
	controls: [Control_Type]renderer.Model,
}

load_assets :: proc(s: ^Game) {
	renderer.start_copy_pass(s.r)
	defer renderer.end_copy_pass(s.r)
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
	for i in 0 ..< kernel.FIELD_SIZE {
		s.render_state.card_mem[i] = Render_Card {
			location = .FIELD,
			idx      = i32(i),
		}
		name := fmt.aprintf("render_card_field_%d", i)
		entity := Entity {
			name    = name,
			variant = &s.render_state.card_mem[i],
		}
		insert_entity(s, &entity)
		s.render_state.cards[i] = entity.id
	}
	for i in 0 ..< kernel.HAND_SIZE {
		mem_idx := i + kernel.FIELD_SIZE
		render_card := &s.render_state.card_mem[mem_idx]
		render_card^ = Render_Card {
			location = .HAND,
			idx      = i32(i),
		}
		name := fmt.aprintf("render_card_hand_%d", i)
		entity := Entity {
			name    = name,
			variant = render_card,
		}
		insert_entity(s, &entity)
		s.render_state.cards[mem_idx] = entity.id
	}
	for i in 0 ..< kernel.MAX_MOVES {
		mem_idx := i + kernel.HAND_SIZE + kernel.FIELD_SIZE
		render_card := &s.render_state.card_mem[mem_idx]
		render_card^ = Render_Card {
			location = .LOG,
			idx      = i32(i),
		}
		name := fmt.aprintf("render_card_log_%d", i)
		entity := Entity {
			name    = name,
			variant = render_card,
		}
		insert_entity(s, &entity)
		s.render_state.cards[mem_idx] = entity.id
	}
	for ctype in Control_Type {
		gltf_name := fmt.aprintf("control_%v.glb", ctype)
		s.assets.controls[ctype] = renderer.load_gltf(s.r, gltf_name)

		control := &s.render_state.controls_mem[ctype]
		control.control_type = ctype
		entity := Entity {
			name    = gltf_name,
			variant = control,
		}
		insert_entity(s, &entity)
		s.render_state.controls[ctype] = entity.id
	}
}

Render_Card :: struct {
	location:    Card_Location,
	idx:         i32,
	render_data: kernel.Card,
}

Control :: struct {
	control_type: Control_Type,
}

NUM_CARDS :: kernel.FIELD_SIZE + kernel.HAND_SIZE + kernel.MAX_MOVES

Render_State :: struct {
	cards:        [NUM_CARDS]pool.Pool_Key,
	card_mem:     [NUM_CARDS]Render_Card,
	controls:     [Control_Type]pool.Pool_Key,
	controls_mem: [Control_Type]Control,
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
		for entity_id in s.render_state.cards {
			entity, ok := pool.get(&s.entities, entity_id);assert(ok)
			render_card(s, entity)
		}
	}
	controls: {
		for entity_id in s.render_state.controls {
			entity, ok := pool.get(&s.entities, entity_id);assert(ok)
			render_control(s, entity)
		}
	}
	renderer.end_draw(s.r)

	renderer.begin_render(s.r)
	renderer.info_pass(s.r)
	renderer.shadow_pass(s.r)
	renderer.begin_screen_render_pass(s.r)
	renderer.bind_pbr_bufs(s.r)
	renderer.opaque_pass(s.r)
	renderer.text_pass(s.r)
	renderer.end_render(s.r)
}

Card_Location :: enum {
	FIELD,
	HAND,
	LOG,
}

get_card_start_pos :: proc(s: ^Game, entity: ^Entity) -> (pos: [3]f32) {
	render_card := entity.variant.(^Render_Card)
	switch render_card.location {
	case .FIELD:
		FIELD_START_POS :: [3]f32{-10, 5, 0}
		CARD_OFFSET :: [2]f32{1.2, -2.2}
		xy_grid := kernel.to_grid(i32(render_card.idx))
		xy_world := [2]f32{f32(xy_grid.x), f32(xy_grid.y)} * CARD_OFFSET
		pos.y = FIELD_START_POS.y + xy_world.y
		pos.xz = FIELD_START_POS.xz
	case .HAND:
		HAND_START_POS :: [3]f32{-10, -4, 0}
		return HAND_START_POS
	case .LOG:
		LOG_BASE_POS :: [3]f32{4, 4, 0}
		return LOG_BASE_POS
	}
	return
}
get_card_inactive_pos :: proc(s: ^Game, entity: ^Entity) -> (pos: [3]f32) {
	render_card := entity.variant.(^Render_Card)
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
	case .LOG:
		LOG_BASE_POS :: [3]f32{4, 4, 0}
		return LOG_BASE_POS
	}
	return
}
get_card_active_pos :: proc(s: ^Game, entity: ^Entity) -> (pos: [3]f32) {
	render_card := entity.variant.(^Render_Card)
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
	case .LOG:
		LOG_BASE_POS :: [3]f32{4, 4, 0}
		CARD_OFFSET :: 1.2
		x_world := f32(i32(s.k.log.len) - render_card.idx) * CARD_OFFSET
		pos.x = LOG_BASE_POS.x + x_world
		pos.yz = LOG_BASE_POS.yz
	}
	return
}
get_card_start_rot :: proc(s: ^Game, entity: ^Entity) -> (rot: quaternion128) {
	rot = lal.quaternion_from_pitch_yaw_roll_f32(0, lal.PI + 0.001, 0)
	return
}
get_card_inactive_rot :: proc(s: ^Game, entity: ^Entity) -> (rot: quaternion128) {
	rot = lal.quaternion_from_pitch_yaw_roll_f32(0, lal.PI - 0.001, 0)
	return
}
get_card_active_rot :: proc(s: ^Game, entity: ^Entity) -> (rot: quaternion128) {
	rot = lal.quaternion_from_pitch_yaw_roll_f32(0, 0, 0)
	return
}

CARD_ANIM_S :: 0.2
BLUE_COLOR: [4]f32 : {0, 1, 1, 1}
RED_COLOR: [4]f32 : {1, 0, 0, 1}
render_card :: proc(s: ^Game, entity: ^Entity) {
	// interpolation
	render_card := entity.variant.(^Render_Card)
	card: ^kernel.Card
	move: kernel.Move
	switch render_card.location {
	case .FIELD:
		card = &s.k.field[render_card.idx]
	case .HAND:
		card = &s.k.hand[render_card.idx]
	case .LOG:
		move = s.k.log.data[render_card.idx]
		return
	}
	if render_card.render_data.active != card.active {
		render_card.render_data.active = card.active
		entity.interactable = card.active
		pos: [3]f32
		rot: quaternion128
		if card.active {
			pos = get_card_active_pos(s, entity)
			rot = get_card_active_rot(s, entity)
			entity.pos.start = get_card_start_pos(s, entity)
			entity.rot.start = get_card_inactive_rot(s, entity)
		} else {
			pos = get_card_inactive_pos(s, entity)
			rot = get_card_inactive_rot(s, entity)
		}
		an.set_target(&entity.pos, s.time_s, pos)
		entity.pos.end_s = s.time_s + CARD_ANIM_S
	}

	// card
	card_pos := an.interpolate(entity.pos, s.time_s)
	card_rot := an.interpolate(entity.rot, s.time_s)
	transform := lal.matrix4_from_trs(card_pos, card_rot, 1)
	card_req := renderer.Draw_Shape_Req {
		shape     = &s.assets.card,
		transform = transform,
		entity_id = entity.id,
	}
	renderer.draw_shape(s.r, card_req)

	if render_card.location == .LOG {
		turn := kernel.turn_player(int(render_card.idx))
		color := turn == .BLUE ? BLUE_COLOR : RED_COLOR

		HAND_POS: [3]f32 : {0, 0.9, 0.01}
		hand_transform := transform * lal.matrix4_from_trs(HAND_POS, 1, 1)
		hand_buf: [2]byte
		hand_str := strconv.itoa(hand_buf[:], int(move.hand))
		hand_req := renderer.Draw_Text_Req {
			text      = hand_str,
			transform = hand_transform,
			color     = color,
		}
		renderer.draw_text(s.r, hand_req)

		FIELD_POS: [3]f32 : {0, -0.5, 0.01}
		field_transform := transform * lal.matrix4_from_trs(FIELD_POS, 1, 1)
		field_buf: [2]byte
		field_str := strconv.itoa(field_buf[:], int(move.field))
		field_req := renderer.Draw_Text_Req {
			text      = field_str,
			transform = hand_transform,
			color     = color,
		}
		renderer.draw_text(s.r, field_req)
		return
	}

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

render_control :: proc(s: ^Game, entity: ^Entity) {
	req: renderer.Draw_Node_Req
	req.entity_id = entity.id
	pos := an.interpolate(entity.pos, s.time_s)
	rot := an.interpolate(entity.rot, s.time_s)
	req.transform = lal.matrix4_from_trs(pos, rot, 1)
	control := entity.variant.(^Control)
	req.model = &s.assets.controls[control.control_type]
	renderer.draw_node(s.r, req)
}

