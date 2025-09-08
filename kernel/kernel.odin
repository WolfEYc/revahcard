package kernel

import sa "core:container/small_array"
import "core:log"
import "core:math/rand"
import "core:testing"

Effect :: enum {
	SWAP,
	ATTACK,
	SHARPEN,
	FREEZE,
}

Target :: enum {
	LEFT,
	RIGHT,
	UP,
	DOWN,
}

Card_Player :: enum {
	NONE,
	BLUE,
	RED,
}

Card :: struct {
	effects:      bit_set[Effect;u32], // food
	targets:      bit_set[Target;u32], // category
	target_count: i32, // adj
	effect_value: i32, // adj
	hp:           i32,
	player_fl:    Card_Player,
	frozen_turns: i32,
	active:       bool,
}

FIELD_W :: 4
FIELD_H :: 4
FIELD_SIZE :: FIELD_W * FIELD_H
Field :: [FIELD_SIZE]Card
HAND_SIZE :: 3
Hand :: [HAND_SIZE]Card

MAX_MOVES :: 256

Move :: struct {
	hand:  i32,
	field: i32,
}
Log :: sa.Small_Array(MAX_MOVES, Move)

Kernel_Rand :: struct {
	seed:  u64,
	state: rand.Default_Random_State,
	gen:   rand.Generator,
}

Kernel :: struct {
	rng:      Kernel_Rand,
	field:    Field,
	hand:     Hand,
	log:      Log,
	turn_idx: int,
	name_db:  Name_DB,
}

new_game :: proc(seed: u64) -> (k: Kernel) {
	k.rng.seed = seed
	reset_rng(&k)
	reset_hand(&k)
	reset_field(&k)
	return
}

reset_rng :: proc(k: ^Kernel) {
	k.rng.state = rand.create(k.rng.seed)
	k.rng.gen = rand.default_random_generator(&k.rng.state)
}

reset_hand :: proc(k: ^Kernel) {
	for _, i in k.hand {
		k.hand[i] = gen_card(k)
	}
}

reset_field :: proc(k: ^Kernel) {
	k.field = Field{}
	red_pos := rand.int31_max(FIELD_SIZE, k.rng.gen)
	blue_pos := rand.int31_max(FIELD_SIZE, k.rng.gen)
	k.field[red_pos].hp = 30
	k.field[red_pos].player_fl = .RED
	k.field[blue_pos].hp = 30
	k.field[blue_pos].player_fl = .BLUE
}

num_active_field :: proc(k: ^Kernel) -> (num_active: i32) {
	for card in k.field {
		num_active += i32(card.active)
	}
	return
}

remap :: proc(x: f32, low: f32, high: f32, min: f32, max: f32) -> (y: f32) {
	y = (x - low) / (high - low)
	y *= (max - min)
	y += min
	return
}


gen_card :: proc(k: ^Kernel) -> (card: Card) {
	rg := context.random_generator
	context.random_generator = k.rng.gen
	defer context.random_generator = rg

	card.effects = {rand.choice_enum(Effect, k.rng.gen)}
	card.targets = {rand.choice_enum(Target, k.rng.gen)}
	GEN_TARGET_COUNT_STOP :: 3
	card.target_count = rand.int31_max(GEN_TARGET_COUNT_STOP, k.rng.gen)
	card.target_count = max(1, card.target_count)
	card.effect_value = GEN_TARGET_COUNT_STOP - card.target_count + 2

	GEN_HP_STOP :: 3
	card.hp = rand.int31_max(GEN_HP_STOP)
	card.hp += 2

	card.active = true
	return
}


current_turn_player :: proc(k: ^Kernel) -> (player: Card_Player) {
	return turn_player(k.turn_idx)
}
turn_player :: proc(idx: int) -> (player: Card_Player) {
	return (idx + 1) % 4 < 2 ? .BLUE : .RED
}

