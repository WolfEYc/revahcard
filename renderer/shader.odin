package renderer

import "base:runtime"
import "core:encoding/json"
import "core:log"
import os "core:os/os2"
import "core:path/filepath"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"

Shader_Info :: struct {
	samplers:         u32,
	storage_textures: u32,
	storage_buffers:  u32,
	uniform_buffers:  u32,
}

load_shader :: proc(
	device: ^sdl.GPUDevice,
	file_name: string,
	info: Shader_Info,
) -> (
	shader: ^sdl.GPUShader,
) {
	temp_mem := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp_mem)

	stage: sdl.GPUShaderStage
	switch filepath.ext(file_name) {
	case ".vert":
		stage = .VERTEX
	case ".frag":
		stage = .FRAGMENT
	}
	in_file_splits := strings.split_n(file_name, ".", 3, allocator = context.temp_allocator)
	assert(len(in_file_splits) == 3)
	in_file_splits[1] = "glsl"
	input_name := strings.join(in_file_splits, ".", allocator = context.temp_allocator)
	input_path := filepath.join({shader_dir, input_name}, allocator = context.temp_allocator)
	input_stat, in_stat_err := os.stat(input_path, allocator = context.temp_allocator)
	output_path := filepath.join({dist_dir, shader_dir, file_name}, context.temp_allocator)
	out_file_info, out_stat_err := os.stat(file_path, context.temp_allocator)

	if out_stat_err != nil && in_stat_err != nil {
		log.panicf(
			"could not load shader %s, neither input nor output file could be stat.\n input file reason: %v\noutput file reason: %v",
			file_name,
			in_stat_err,
			out_stat_err,
		)
	}

	if out_stat_err != nil ||
	   (in_stat_err == nil &&
			   time.diff(out_file_info.modification_time, input_stat.modification_time) > 0) {
		compile_shader(input_path, output_path)
	}

	out_code, read_err := os.read_entire_file(output_path, allocator = context.temp_allocator)
	if read_err != nil {
		log.panicf("failed to read shader: %v reason: %v", file_name, read_err)
	}

	shader = sdl.CreateGPUShader(
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
	);sdl_err(shader)
	return
}

compile_shader :: proc(input_path: string, output_path: string) {
	cmd_slice := make([]string, 5, allocator = context.temp_allocator)
	cmd_slice[0] = "glslc"
	cmd_slice[1] = input_path
	cmd_slice[2] = "-o"
	cmd_slice[3] = output_path
	cmd_slice[4] = "--target-env=" + target_env
	process: os.Process
	process, err = os.process_start({command = cmd_slice, stdout = os.stderr, stderr = os.stderr})
	if err != nil {
		log.panicf("failed to start glslc to compile shader, reason: %v", err)
	}
	_, err = os.process_wait(process)
	if err != nil {
		log.panicf("failed to wait for glslc to compile shader, reason: %v", err)
	}
}

