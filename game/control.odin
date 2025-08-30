package main

import "../kernel"
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

// TODO
get_hand_card_at_screen_pos :: proc(screen_xy: [2]f32) -> (card: i32) {

	return
}

// TODO
get_field_card_at_screen_pos :: proc(screen_xy: [2]f32) -> (card: i32) {

	return
}

m1_clicked :: proc(s: ^Game, ev: sdl.Event) {
	screen_xy: [2]f32
	_ = sdl.GetMouseState(&screen_xy.x, &screen_xy.y)
	hand_card := get_hand_card_at_screen_pos(screen_xy)
	field_card := get_field_card_at_screen_pos(screen_xy)

	if hand_card != -1 && kernel.is_card_active(s.k.hand[hand_card]) {
		s.move.hand = hand_card
	}
	if hand_card != -1 && kernel.is_card_active(s.k.hand[hand_card]) {
		s.move.field = field_card
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

