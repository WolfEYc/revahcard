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
	if !ok || !clicked_entity.interactable do return
	s.clicked_entity = s.r.info_entity_id
	if kernel.current_turn_player(&s.k) != s.local_player do return
	#partial switch v in clicked_entity.variant {
	case ^Render_Card:
		if v.location == .HAND {
			s.hand_move = v.idx
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

	if kernel.current_turn_player(&s.k) != s.local_player do return
	#partial switch v in released_entity.variant {
	case ^Render_Card:
		hand_move, has_hand_move := s.hand_move.?
		if !has_hand_move || v.location != .FIELD do break
		s.field_move = v.idx
		move := kernel.Move {
			hand  = hand_move,
			field = v.idx,
		}
		if s.k.turn_idx == s.k.log.len - 1 {
			// undo unconfirmed move
			s.k.log.len -= 1
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
	switch v in e.variant {
	case ^Render_Card:
		#partial switch v.location {
		case .LOG:
			if int(v.idx) == s.k.log.len - 1 do break
			kernel.time_machine(&s.k, int(v.idx))
		}
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

activate_submit :: proc(s: ^Game, control: ^Control) {
	err := kernel.confirm_move(&s.k)
	switch err {
	case .CORRUPTION:
		log.panicf(
			"kernel corruption when submitting, turn_idx=%d len(log)=%d",
			s.k.turn_idx,
			s.k.log.len,
		)
	case .NO_MOVE:
		// TODO some animation indicated that you cant submit with no move
		log.errorf(
			"tried to submit with no move, turn_idx=%d len(log)=%d",
			s.k.turn_idx,
			s.k.log.len,
		)
	case .NONE:
		winner := kernel.get_winner(&s.k)
		switch winner {
		case .NONE:
			log.infof("submit success! turn_idx=%d len(log)=%d", s.k.turn_idx, s.k.log.len)
		case .RED, .BLUE:
			handle_win(s, winner)
		}
	}
}

activate_resign :: proc(s: ^Game, control: ^Control) {
	move := kernel.Move {
		hand  = -i32(s.opponent),
		field = -i32(s.opponent),
	}
	kernel.move(&s.k, move)
}

// TODO
handle_win :: proc(s: ^Game, winner: kernel.Card_Player) {
	panic("err handle win not implemented yet")
}

