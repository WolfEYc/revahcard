package kernel

Card_Effect :: enum {
	CREATE,
	PLAY,
	ATTACK,
	REINFORCE,
	SHARPEN,
	FREEZE,
	SEAL,
	RETRACT,
	DESTROY,
	ACTIVATE,
	COPY,
	MOVE,
	SWAP,
	CHANGE_TARGET,
	CHANGE_EFFECT,
}

Card_Target :: enum {
	ALL,
	ALL_BOARD,
	BLUE_BOARD,
	RED_BOARD,
	ALL_HAND,
	BLUE_HAND,
	RED_HAND,
	ADJACENT,
	OPPOSITE,
	SELF,
}


Card :: struct {
	effects:              bit_set[Card_Effect],
	targets:              bit_set[Card_Target],
	target_count:         int,
	effect_value:         int,
	trigger_effects:      bit_set[Card_Effect],
	trigger_targets:      bit_set[Card_Target],
	trigger_target_count: int,
}

