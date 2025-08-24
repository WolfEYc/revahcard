package kernel

import sa "core:container/small_array"
import "core:log"
import "core:math/rand"
import "core:testing"

Effect :: enum {
	ATTACK,
	REINFORCE,
	SHARPEN,
	FREEZE,
	MERGE_TO,
	MERGE_FROM,
	COPY_TO,
	COPY_FROM,
	SWAP,
}

Target :: enum {
	SELF,
	UP,
	DOWN,
	LEFT,
	RIGHT,
}

Card :: struct {
	effects:      bit_set[Effect;u32],
	targets:      bit_set[Target;u32],
	target_count: u32,
	effect_value: u32,
}

is_card_active :: proc(card: Card) -> bool {
	return card.target_count != 0
}


FIELD_W :: 4
FIELD_H :: 4
FIELD_SIZE :: FIELD_W * FIELD_H
Field :: [FIELD_SIZE]Card

MAX_MOVES :: 256
Pos :: u32

Move :: [2]Pos
Log :: sa.Small_Array(MAX_MOVES, Move)

Kernel_Rand :: struct {
	seed:  u64,
	state: rand.Default_Random_State,
	gen:   rand.Generator,
}

Kernel :: struct {
	rng:     Kernel_Rand,
	field:   Field,
	log:     Log,
	name_db: Name_DB,
}

reset_rng :: proc(k: ^Kernel) {
	k.rng.state = rand.create(k.rng.seed)
	k.rng.gen = rand.default_random_generator(&k.rng.state)
}

gen_pos :: proc(k: Kernel) -> (pos: Pos) {
	pos = rand.uint32(k.rng.gen) % FIELD_SIZE
	return
}

@(test)
test_random :: proc(t: ^testing.T) {
	k: Kernel
	k.rng.seed = 69420
	reset_rng(&k)
	pos1 := gen_pos(k)
	reset_rng(&k)
	pos2 := gen_pos(k)
	testing.expectf(t, pos1 == pos2, "%d != %d, big sad", pos1, pos2)
}

Move_Error :: enum {
	OUT_OF_RANGE,
	MOVE_LIMIT_REACHED,
	INVALID_MERGE,
}


move :: proc(k: ^Kernel, move: Move) -> (err: Move_Error) {
	if k.log.len == MAX_MOVES do return .MOVE_LIMIT_REACHED
	if move.x >= FIELD_SIZE || move.y >= FIELD_SIZE do return .OUT_OF_RANGE
	card_x := k.field[move.x]
	card_y := k.field[move.y]

	if is_card_active(card_x) && is_card_active(card_y) {
		x_name := card_to_name(k.name_db, card_x)
		y_name := card_to_name(k.name_db, card_x)
		if x_name.food.category != y_name.food.category do return .INVALID_MERGE
	}

	sa.append(&k.log, move)
	return
}

