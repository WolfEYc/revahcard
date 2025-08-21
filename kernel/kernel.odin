package kernel

import sa "core:container/small_array"
import "core:math/rand"

Effect :: enum {
	ATTACK,
	REINFORCE,
	SHARPEN,
	FREEZE,
	SEAL,
	ACTIVATE,
	COPY,
	MOVE,
	MERGE,
	SWAP,
}

Target :: enum {
	BLUE_FIELD,
	RED_FIELD,
	ADJACENT,
	OPPOSITE,
	SELF,
	MINE,
}

Card_Location :: enum u64 {
	RED_FIELD,
	BLUE_FIELD,
	MINE,
}

Reserved_Actors :: enum u64 {
	GOD,
	RED_PLAYER,
	BLUE_PLAYER,
	RED_ANCHOR,
	BLUE_ANCHOR,
}

Card :: struct {
	actor_id:       u64,
	action:         Action,
	trigger_action: Action,
	location:       Card_Location,
}

Action :: struct {
	effects:      bit_set[Effect;u64],
	targets:      bit_set[Target;u64],
	target_count: i64,
	effect_value: i64,
}

Event :: struct {
	actor_id: u64,
	turn:     u64,
	action:   Action,
}

FIELD_SIZE :: 5
MINE_SIZE :: 5
ALL_SIZE :: FIELD_SIZE * 2 + MINE_SIZE

Kernel_Rand :: struct {
	seed:  u64,
	state: rand.Default_Random_State,
	gen:   rand.Generator,
}

Kernel :: struct {
	rng:   Kernel_Rand,
	cards: sa.Small_Array(ALL_SIZE, Card),
	log:   [dynamic]Event,
}

new_kernel :: proc(seed: u64) -> (kernel: ^Kernel) {
	kernel = new(Kernel)
	kernel^ = Kernel {
		rng = Kernel_Rand{seed = seed, state = rand.create(seed)},
	}
	kernel.rng.gen = rand.default_random_generator(&kernel.rng.state)
	return
}

