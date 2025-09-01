package main

import "../kernel"
import "../lib/pool"
import "core:log"
import sdl "vendor:sdl3"

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
	switch v in clicked_entity.variant {
	case ^Render_Card:
		switch v.location {
		case .HAND:
			if kernel.is_card_active(s.k.hand[v.idx]) {
				s.move.hand = v.idx
			}
		case .FIELD:
			if kernel.is_card_active(s.k.field[v.idx]) {
				s.move.field = v.idx
			}

		}
	}

	if s.move.hand != -1 && s.move.field != -1 {
		winner, err := kernel.move(&s.k, s.move)
		switch err {
		case .HAND_OUT_OF_RANGE, .HAND_INACTIVE, .FIELD_OUT_OF_RANGE:
			log.panicf("err in m1_clicked when moving, move_err=%v", err)
		case .MOVE_LIMIT_REACHED:
			handle_win(s, winner)
			return
		case .INVALID_MERGE:
			log.errorf("invalid merge: %v", s.move)
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
	return
}

// TODO
m1_released :: proc(s: ^Game, ev: sdl.Event) {

	return
}
// TODO
handle_win :: proc(s: ^Game, winner: kernel.Card_Player) {

	return
}

