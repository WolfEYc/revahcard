package main

import an "../animation"
import "../kernel"
import "../lib/pool"
import "core:log"
import sdl "vendor:sdl3"


Control_Type :: enum {
	SUBMIT,
	RESIGN,
}

control_eventhandle :: proc(s: ^Game, ev: sdl.Event) {
	#partial switch ev.type {
	case .MOUSE_BUTTON_DOWN:
		switch ev.button.button {
		case 0:
			m1_clicked(s, ev)
		}
	case .MOUSE_BUTTON_UP:
		switch ev.button.button {
		case 0:
			m1_released(s, ev)
		}
	}
}

m1_clicked :: proc(s: ^Game, ev: sdl.Event) {
	clicked_entity, ok := pool.get(&s.entities, s.r.info_entity_id)
	if !ok do return
	s.clicked_entity = s.r.info_entity_id
	if kernel.turn(&s.k) != s.local_player do return
	#partial switch v in clicked_entity.variant {
	case ^Render_Card:
		if v.location == .HAND {
			interact_card(s, v)
		}
	}
	return
}

m1_released :: proc(s: ^Game, ev: sdl.Event) {
	defer s.clicked_entity = pool.Pool_Key{}
	released_entity, ok := pool.get(&s.entities, s.r.info_entity_id)
	if ok && s.r.info_entity_id == s.clicked_entity {
		handle_release(s, released_entity)
	} else if clicked_entity, ok := pool.get(&s.entities, s.clicked_entity); ok {
		handle_standby(s, clicked_entity)
	} else do return

	if kernel.turn(&s.k) != s.local_player do return
	#partial switch v in released_entity.variant {
	case ^Render_Card:
		_, has_hand_move := s.hand_move.?
		if v.location == .FIELD && has_hand_move {
			interact_card(s, v)
		}
	}
	return
}

handle_hover :: proc(s: ^Game, e: ^Entity) {
	an.set_target(&e.pos, s.time_s, e.hover_pos)
	e.pos.ease = e.hover_ease
	e.pos.end_s = s.time_s + e.hover_s
	an.set_target(&e.rot, s.time_s, e.hover_rot)
	e.rot.ease = e.hover_ease
	e.rot.end_s = s.time_s + e.hover_s
}

handle_hold :: proc(s: ^Game, e: ^Entity) {
	an.set_target(&e.pos, s.time_s, e.hold_pos)
	e.pos.ease = e.hold_ease
	e.pos.end_s = s.time_s + e.hold_s
	an.set_target(&e.rot, s.time_s, e.hold_rot)
	e.rot.ease = e.hold_ease
	e.rot.end_s = s.time_s + e.hold_s
}

handle_release :: proc(s: ^Game, e: ^Entity) {
	handle_standby(s, e)
	#partial switch v in e.variant {
	case ^Control:
		switch v.control_type {
		case .SUBMIT:
			activate_submit(s, v)
		case .RESIGN:
			activate_resign(s, v)
		}
	}
}

handle_standby :: proc(s: ^Game, e: ^Entity) {
	an.set_target(&e.pos, s.time_s, e.standby_pos)
	e.pos.ease = e.standby_ease
	e.pos.end_s = s.time_s + e.standby_s
	an.set_target(&e.rot, s.time_s, e.standby_rot)
	e.rot.ease = e.standby_ease
	e.rot.end_s = s.time_s + e.standby_s
}

interact_card :: proc(s: ^Game, card: ^Render_Card) {
	switch card.location {
	case .HAND:
		if s.k.hand[card.idx].active {
			s.hand_move = card.idx
		}
	case .FIELD:
		if s.k.field[card.idx].active {
			s.field_move = card.idx
		}
	case .LOG:
	// TODO time machine
	}
	return
}


activate_submit :: proc(s: ^Game, control: ^Control) {
	move: kernel.Move
	has_hand: bool
	has_field: bool
	move.hand, has_hand = s.hand_move.?
	move.field, has_field = s.field_move.?
	if !has_hand || !has_field {
		//TODO play some sort of error animation
		// to indicate to the user that they need to pick a field & hand card
		log.errorf("tried to submit has_hand=%v has_field=%v", has_hand, has_field)
		return
	}
	winner, err := kernel.move(&s.k, move)
	switch err {
	case .HAND_OUT_OF_RANGE, .HAND_INACTIVE, .FIELD_OUT_OF_RANGE:
		log.panicf("err in submit, move_err=%v", err)
	case .MOVE_LIMIT_REACHED:
		handle_win(s, winner)
		return
	case .INVALID_MERGE:
		// TODO play some animation to tell the player its not a valid merge
		log.errorf("invalid merge: %v", move)
		return
	case .NONE:
	}
	switch winner {
	case .NONE:
	case .RED, .BLUE:
		handle_win(s, winner)
		return
	}
}

activate_resign :: proc(s: ^Game, control: ^Control) {
	s.hand_move = -i32(s.opponent)
	s.field_move = -i32(s.opponent)
}

// TODO
handle_win :: proc(s: ^Game, winner: kernel.Card_Player) {
	panic("err handle win not implemented yet")
}

