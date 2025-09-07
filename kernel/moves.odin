package kernel

import sa "core:container/small_array"
import "core:testing"

Move_Error :: enum {
	NONE,
	HAND_OUT_OF_RANGE,
	HAND_INACTIVE,
	FIELD_OUT_OF_RANGE,
	MOVE_LIMIT_REACHED,
	INVALID_MERGE,
}

move :: proc(k: ^Kernel, m: Move, log_move := true) -> (winner: Card_Player, err: Move_Error) {
	if m.hand < 0 {
		winner = Card_Player(-m.hand)
	}
	if k.log.len == MAX_MOVES {
		err = .MOVE_LIMIT_REACHED
		return
	}
	if m.hand >= HAND_SIZE {
		err = .HAND_OUT_OF_RANGE
		return
	}
	if m.field >= FIELD_SIZE {
		err = .FIELD_OUT_OF_RANGE
		return
	}
	card_hand := k.hand[m.hand]
	if !card_hand.active {
		err = .HAND_INACTIVE
		return
	}

	card_field := k.field[m.field]
	if card_field.active {
		intersect_effect := card_hand.effects & card_field.effects
		intersect_target := card_hand.targets & card_field.targets
		buff := card(intersect_effect) * card(intersect_target)
		if buff == 0 {
			err = .INVALID_MERGE
			return
		}
		card_field.effects += card_hand.effects
		card_field.targets += card_hand.targets
		card_field.target_count += card_hand.target_count
		card_field.effect_value += card_hand.effect_value
		card_field.effect_value *= i32(buff)
		card_field.hp += card_hand.hp
		card_field.frozen_turns = 0
	} else {
		card_field = card_hand
	}
	k.field[m.field] = card_field

	if k.log.len % 2 == 0 {
		k.hand[m.hand].active = false
	} else { 	// simulate
		simulate(k)
		mark_dead_cards_inactive(k)
		reset_hand(k)
		winner = get_winner(k)
	}

	if log_move {
		sa.append(&k.log, m)
	}
	return
}

time_machine :: proc(k: ^Kernel, move_idx: int) {
	assert(move_idx < k.log.len)
	reset_rng(k)
	reset_hand(k)
	reset_field(k)
	for i := 0; i <= move_idx; i += 1 {
		m := k.log.data[i]
		move(k, m, log_move = false)
	}
}

simulate :: proc(k: ^Kernel) {
	for i: i32 = 0; i < FIELD_SIZE; i += 1 {
		if !k.field[i].active do continue
		if k.field[i].frozen_turns > 0 {
			k.field[i].frozen_turns -= 1
			continue
		}
		for effect in k.field[i].effects {
			switch effect {
			case .SWAP:
				target := obtain_swap_target(k, i)
				swap(k, i, target)
			case .ATTACK, .SHARPEN, .FREEZE:
				effect_targets(k, i, effect, k.field[i].effect_value)
			}
		}
	}
}

get_winner :: proc(k: ^Kernel) -> Card_Player {
	for card in k.field {
		if card.player_fl == .BLUE && card.hp <= 0 do return .RED
		if card.player_fl == .RED && card.hp <= 0 do return .BLUE
	}
	return .NONE
}

mark_dead_cards_inactive :: proc(k: ^Kernel) {
	for i: i32 = 0; i < FIELD_SIZE; i += 1 {
		if k.field[i].hp > 0 do continue
		k.field[i].active = false
	}
}


to_grid :: proc(x: i32) -> (xy: [2]i32) {
	assert(x < FIELD_SIZE)
	xy.y = x / FIELD_W
	xy.x = x % FIELD_W
	return
}

to_idx :: proc(xy: [2]i32) -> (x: i32) {
	x = xy.y * FIELD_W + xy.x
	return
}

@(private)
obtain_swap_target :: proc(k: ^Kernel, a: i32) -> (target: i32) {
	card := k.field[a]
	x := to_grid(a)
	for target in card.targets {
		for i: i32 = 0; i < card.target_count; i += 1 {
			x1 := x
			switch target {
			case .LEFT:
				x1.x = x.x - (i + 1)
			case .RIGHT:
				x1.x = x.x + (i + 1)
			case .UP:
				x1.x = x.y - (i + 1)
			case .DOWN:
				x1.x = x.y + (i + 1)
			}
			if x1.x < 0 || x1.x >= FIELD_W || x1.y < 0 || x1.y >= FIELD_H do continue
			return to_idx(x1)
		}
	}
	return a
}

@(private)
effect_targets :: proc(k: ^Kernel, a: i32, effect: Effect, effect_value: i32) {
	card := k.field[a]
	x := to_grid(a)
	for target in card.targets {
		for i: i32 = 0; i < card.target_count; i += 1 {
			x1 := x
			switch target {
			case .LEFT:
				x1.x = x.x - (i + 1)
			case .RIGHT:
				x1.x = x.x + (i + 1)
			case .UP:
				x1.x = x.y - (i + 1)
			case .DOWN:
				x1.x = x.y + (i + 1)
			}
			if x1.x < 0 || x1.x >= FIELD_W || x1.y < 0 || x1.y >= FIELD_H do continue
			idx := to_idx(x1)
			#partial switch effect {
			case .ATTACK:
				attack(k, idx, effect_value)
			case .FREEZE:
				freeze(k, idx, effect_value)
			case .SHARPEN:
				sharpen(k, idx, effect_value)
			}
		}
	}
	return
}

@(private)
swap :: proc(k: ^Kernel, a, b: i32) {
	k.field[a], k.field[b] = k.field[b], k.field[a]
}

@(test)
test_swap :: proc(t: ^testing.T) {
	k := Kernel{}
	k.field[6].hp = 69
	k.field[3].hp = 420
	swap(&k, 6, 3)
	testing.expect(t, k.field[6].hp == 420, "card 6 hp != 420")
	testing.expect(t, k.field[3].hp == 69, "card 3 hp != 69")
}

@(private)
attack :: proc(k: ^Kernel, a: i32, amt: i32) {
	k.field[a].hp -= amt
}

@(private)
sharpen :: proc(k: ^Kernel, a: i32, amt: i32) {
	k.field[a].effect_value += amt
}

@(private)
freeze :: proc(k: ^Kernel, a: i32, amt: i32) {
	k.field[a].frozen_turns += amt
}

