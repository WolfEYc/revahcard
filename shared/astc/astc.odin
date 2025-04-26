package astc

import "core:io"


Astc :: struct {
	block_x: u8,
	block_y: u8,
	block_z: u8,
	dim_x:   u32,
	dim_y:   u32,
	dim_z:   u32,
	payload: io.Stream,
}

@(private)
Astc_Header :: struct {
	magic:   [4]u8,
	block_x: u8,
	block_y: u8,
	block_z: u8,
	dim_x:   [3]u8,
	dim_y:   [3]u8,
	dim_z:   [3]u8,
}

@(private)
Astc_Magic :: [4]u8{0x13, 0xAB, 0xA1, 0x5C}

Astc_Error :: enum {
	None = 0,
	Incorrect_Magic,
}
Error :: union #shared_nil {
	Astc_Error,
	io.Error,
}

load :: proc(stream: io.Stream) -> (astc: Astc, err: Error) {
	header_bytes: [size_of(Astc_Header)]u8
	_, err = io.read_full(stream, header_bytes[:])
	if err != nil {
		return
	}
	header := transmute(Astc_Header)header_bytes
	if header.magic != Astc_Magic {
		err = Astc_Error.Incorrect_Magic
		return
	}
	astc.block_x = header.block_x
	astc.block_y = header.block_y
	astc.block_z = header.block_z

	astc.dim_x = u32(header.dim_x[0]) + u32(header.dim_x[1] << 8) + u32(header.dim_x[2] << 16)
	astc.dim_y = u32(header.dim_y[0]) + u32(header.dim_y[1] << 8) + u32(header.dim_y[2] << 16)
	astc.dim_z = u32(header.dim_z[0]) + u32(header.dim_z[1] << 8) + u32(header.dim_z[2] << 16)
	astc.payload = stream
	return
}

