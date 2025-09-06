package main

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
	switch v in clicked_entity.variant {
	case ^Render_Card:
		interact_card(s, v)
	case ^Control:
		switch v.control_type {
		case .SUBMIT:
			hold_submit(s, v)
		case .RESIGN:
			hold_resign(s, v)
		}
	}
	return
}

m1_released :: proc(s: ^Game, ev: sdl.Event) {
	clicked_entity, ok := pool.get(&s.entities, s.r.info_entity_id)
	if !ok do return
	switch v in clicked_entity.variant {
	case ^Render_Card:
		interact_card(s, v)
	case ^Control:
		switch v.control_type {
		case .SUBMIT:
			activate_submit(s, v)
		case .RESIGN:
			activate_resign(s, v)
		}
	}
	return
}

interact_card :: proc(s: ^Game, card: ^Render_Card) {
	switch card.location {
	case .HAND:
		if kernel.is_card_active(s.k.hand[card.idx]) {
			s.move.hand = card.idx
		}
	case .FIELD:
		if kernel.is_card_active(s.k.field[card.idx]) {
			s.move.field = card.idx
		}
	case .LOG:
	// TODO time machine
	}
	return
}

hold_resign :: proc(s: ^Game, control: ^Control) {
	// TODO perhaps some animation showing that they are holding the button
}
hold_simulate :: proc(s: ^Game, control: ^Control) {
	// TODO perhaps some animation showing that they are holding the button
}
hold_submit :: proc(s: ^Game, control: ^Control) {
	// TODO perhaps some animation showing that they are holding the submit button down
}

activate_submit :: proc(s: ^Game, control: ^Control) {
	if s.move.hand < 0 || s.move.field < 0 {
		//TODO play some sort of error animation
		// to indicate to the user that they need to pick a field & hand card
		return
	}
	winner, err := kernel.move(&s.k, s.move)
	switch err {
	case .HAND_OUT_OF_RANGE, .HAND_INACTIVE, .FIELD_OUT_OF_RANGE:
		log.panicf("err in submit, move_err=%v", err)
	case .MOVE_LIMIT_REACHED:
		handle_win(s, winner)
		return
	case .INVALID_MERGE:
		// TODO play some animation to tell the player its not a valid merge
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
// TODO
activate_resign :: proc(s: ^Game, control: ^Control) {
}
//TODO
activate_simulate :: proc(s: ^Game, control: ^Control) {
}

// TODO
handle_win :: proc(s: ^Game, winner: kernel.Card_Player) {
	panic("err handle win not implemented yet")
}

