package static_list

import "base:runtime"

List_Idx :: u32
Static_List :: struct($T: typeid) {
	_data: []T,
	_len:  List_Idx,
}

//There is no set or delete! as this is an insert only data structure

make :: proc($T: typeid, cap: List_Idx) -> (list: Static_List(T), err: runtime.Allocator_Error) {
	list._data = runtime.make([]T, cap) or_return
}

insert :: #force_inline proc(
	list: ^Static_List($T),
	e: T,
) -> (
	idx: List_Idx,
	err: runtime.Allocator_Error,
) #no_bounds_check {
	if list._len == cap(list) do return runtime.Allocator_Error.Out_Of_Memory
	list._data[list._len] = e
	list._len += 1
}

len :: #force_inline proc(list: ^Static_List($T)) -> (len: List_Idx) {
	return list._len
}

cap :: #force_inline proc(list: ^Static_List($T)) -> (cap: List_Idx) {
	return len(list._data)
}

get :: #force_inline proc(list: ^Static_List($T), idx: List_Idx) -> (elem: ^T) #no_bounds_check {
	assert(idx < list._len)
	return list._data[idx]
}

