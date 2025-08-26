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
}

is_card_active :: proc(card: Card) -> bool {
	return card.hp <= 0
}

FIELD_W :: 4
FIELD_H :: 4
FIELD_SIZE :: FIELD_W * FIELD_H
Field :: [FIELD_SIZE]Card
HAND_SIZE :: 5
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
	rng:     Kernel_Rand,
	field:   Field,
	hand:    Hand,
	log:     Log,
	name_db: Name_DB,
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

num_active_field :: proc(k: ^Kernel) -> (num_active: i32) {
	for card in k.field {
		num_active += i32(is_card_active(card))
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
	card.effects = {rand.choice_enum(Effect, k.rng.gen)}
	card.targets = {rand.choice_enum(Target, k.rng.gen)}
	//TODO 

	return
}

