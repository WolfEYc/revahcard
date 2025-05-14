package pool

import "base:runtime"
import "core:slice/heap"

Pool_Idx :: u32
Gen_Counter :: u32
Pool_Key :: struct {
	idx: Pool_Idx,
	gen: Gen_Counter,
}

// yeah these guys are made to live forever, so pretty much just leak them LOL!!!
Pool :: struct($T: typeid) {
	_entities:        []T,
	_actives:         []bool,
	_gens:            []Gen_Counter,
	_vacant_min_heap: []Pool_Idx,
	_free_buf:        []Pool_Idx,
	_insert_buf:      []Pool_Idx,
	_vacant_len:      Pool_Idx,
	_max_used_len:    Pool_Idx,
	_free_buf_len:    Pool_Idx,
	_insert_buf_len:  Pool_Idx,
	_max_active_len:  Pool_Idx, // useful for not wasting iterating into the inactive only entities range
	_num_actives:     Pool_Idx,
}


make :: proc($T: typeid, cap: Pool_Idx) -> (pool: Pool(T), err: runtime.Allocator_Error) {
	Entity_Elem :: struct {
		entity:     T,
		actives:    bool,
		gen:        Gen_Counter,
		heap_idx:   Pool_Idx,
		free_buf:   Pool_Idx,
		insert_buf: Pool_Idx,
	}
	Entity_SOA :: #soa[]Entity_Elem
	pool_mem: Entity_SOA
	pool_mem = make(Entity_SOA, cap) or_return
	pool._entities, pool._actives, pool._gens, pool._vacant_min_heap, pool._free_buf, pool._insert_buf =
		soa_unzip(pool_mem)
}


@(private)
min_heap_less :: #force_inline proc(a, b: Pool_Idx) -> bool {
	return a > b
}

validate_idx :: #force_inline proc(pool: ^Pool($T), key: Pool_Key) -> bool #no_bounds_check {
	assert(key.idx < pool._max_used_len)
	return key.gen != 0 && pool._actives[key.idx] && key.gen == pool._gens[key.idx]
}

@(require_results)
get :: #force_inline proc(pool: ^Pool($T), key: Pool_Key) -> (res: ^T, ok: bool) #no_bounds_check {
	if !validate_idx(pool, key) do return
	res = &pool._entities[idx.idx]
	ok = true
}

next :: #force_inline proc(
	pool: ^Pool($T),
	idx: ^Pool_Idx,
) -> (
	entity: ^T,
	key: Pool_Key,
	ok: bool,
) #no_bounds_check {
	i := idx^
	for ; i < pool._max_active_len; i += 1 {
		if !pool._actives[i] do continue
		next_key.idx = i
		next_key.gen = pool._gens[i]
		entity = &pool._entities[i]
		ok = true
		break
	}
	idx^ = i
}

@(private)
backtrack_max_active_idx :: proc(pool: ^Pool($T)) #no_bounds_check {
	for pool._max_active_len > 0 && !pool._actives[pool._max_active_len - 1] {
		pool._max_active_len -= 1
	}
}

@(private)
free :: #force_inline proc(pool: ^Pool($T), idx: Pool_Idx) #no_bounds_check {
	pool._actives[idx] = false
	pool._vacant_min_heap[len(pool._entities) - 1] = idx
	heap.push(pool._vacant_min_heap, min_heap_less)
}

free_immediate :: proc(pool: ^Pool($T), key: Pool_Key) #no_bounds_check {
	if !validate_idx(pool, key) do return
	free(pool, idx.idx)
	backtrack_max_active_idx(pool)
	pool._vacant_len += 1
}

free_defered :: #force_inline proc(pool: ^Pool($T), key: Pool_Key) #no_bounds_check {
	if !validate_idx(pool, key) do return
	pool._free_buf[pool._free_buf_len] = idx.idx
	pool._free_buf_len += 1
}

flush_frees :: proc(pool: ^Pool($T)) #no_bounds_check {
	for idx in pool._free_buf[:pool._free_buf_len] {
		free(pool, idx)
	}
	pool._vacant_len += pool._free_buf_len
	pool._free_buf_len = 0
	backtrack_max_active_idx(pool)
}

insert_immediate :: proc(
	pool: ^Pool($T),
	elem: T,
) -> (
	key: Pool_Key,
	err: runtime.Allocator_Error,
) #no_bounds_check {
	if pool == nil {
		err = runtime.Allocator_Error.Invalid_Pointer
		return
	}
	if pool._vacant_len == 0 && pool._max_used_len == len(pool._entities) {
		err = runtime.Allocator_Error.Out_Of_Memory
		return
	}
	if pool._vacant_len == 0 {
		//grow used
		pool._entities[pool._max_used_len] = elem
		pool._actives[pool._max_used_len] = true
		pool._gens[pool._max_used_len] = 1
		key.idx = pool._max_used_len
		key.gen = 1
		pool._max_active_len = pool._max_used_len
		pool._max_used_len += 1
	} else {
		// reuse slot
		heap.pop(pool._vacant_min_heap, min_heap_less)
		pool._vacant_len -= 1
		vacant_idx := pool._vacant_min_heap[len(pool._entities) - 1]
		pool._entities[vacant_idx] = elem
		pool._gens[vacant_idx] += 1
		pool._actives[vacant_idx] = true
		key.idx = vacant_idx
		key.gen = pool._gens[vacant_idx]
		pool._max_active_len = max(pool._max_active_len, vacant_idx + 1)
	}
	pool._num_actives += 1
}

insert_defered :: proc(
	pool: ^Pool($T),
	elem: T,
) -> (
	key: Pool_Key,
	err: runtime.Allocator_Error,
) #no_bounds_check {
	if pool == nil {
		err = runtime.Allocator_Error.Invalid_Pointer
		return
	}
	if pool._vacant_len == 0 && pool._max_used_len == len(pool._entities) {
		err = runtime.Allocator_Error.Out_Of_Memory
		return
	}
	if pool._vacant_len == 0 {
		//grow used
		key.gen = 1
		key.idx = pool._max_used_len

		pool._entities[key.idx] = elem
		pool._gens[key.idx] = 1

		pool._insert_buf[pool._insert_buf_len] = key.idx
		pool._insert_buf_len += 1

		pool._max_used_len += 1
	} else {
		// reuse slot
		heap.pop(pool._vacant_min_heap, min_heap_less)
		pool._vacant_len -= 1
		key.idx = pool._vacant_min_heap[len(pool._entities) - 1]

		key.gen = pool._gens[key.idx] + 1
		pool._gens[key.idx] = key.gen
		pool._entities[key.idx] = elem

		pool._insert_buf[pool._insert_buf_len] = key.idx
		pool._insert_buf_len += 1
	}
}

flush_inserts :: proc(pool: ^Pool($T)) #no_bounds_check {
	for idx in pool._insert_buf[:pool._insert_buf_len] {
		pool._actives[idx] = true
		pool._max_active_len = max(pool._max_active_len, idx + 1)
	}
	pool._num_actives += pool._insert_buf_len
	pool._insert_buf_len = 0
}

