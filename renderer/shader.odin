package renderer

import "../constants"
import "core:encoding/json"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import sdl "vendor:sdl3"

load_shader :: proc(
	device: ^sdl.GPUDevice,
	shaderfile: string,
	info: Shader_Info,
) -> ^sdl.GPUShader {
	stage: sdl.GPUShaderStage
	switch filepath.ext(shaderfile) {
	case ".vert":
		stage = .VERTEX
	case ".frag":
		stage = .FRAGMENT
	}

	shaderfile := filepath.join(
		{constants.dist_dir, constants.shader_dir, shaderfile},
		context.temp_allocator,
	)
	code, ok := os.read_entire_file_from_filename(shaderfile, context.temp_allocator);assert(ok)

	// info := load_shader_info(shaderfile)

	return sdl.CreateGPUShader(
		device,
		{
			code_size = len(code),
			code = raw_data(code),
			entrypoint = "main",
			format = {.SPIRV},
			stage = stage,
			num_uniform_buffers = info.uniform_buffers,
			num_samplers = info.samplers,
			num_storage_buffers = info.storage_buffers,
			num_storage_textures = info.storage_textures,
		},
	)
}

Shader_Info :: struct {
	samplers:         u32,
	storage_textures: u32,
	storage_buffers:  u32,
	uniform_buffers:  u32,
}

load_shader_info :: proc(shaderfile: string) -> (result: Shader_Info) {
	json_filename := strings.concatenate({shaderfile, ".json"}, context.temp_allocator)
	json_data, ok := os.read_entire_file_from_filename(
		json_filename,
		context.temp_allocator,
	);assert(ok)
	err := json.unmarshal(
		json_data,
		&result,
		allocator = context.temp_allocator,
	);assert(err == nil)
	return
}

