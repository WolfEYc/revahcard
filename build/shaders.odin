package build

import shared "../shared"
import "core:flags"
import "core:fmt"
import "core:log"
import os1 "core:os"
import os "core:os/os2"
import "core:slice"
import "core:strings"
import "core:time"


main :: proc() {
	context.logger = log.create_console_logger()
	dir, err := os.open(shared.shader_dir)
	if err != nil {
		log.panicf("failed to open shader_dir, reason: %s", err)
	}
	defer os.close(dir)
	shader_dir_stats: os.File_Info
	shader_dir_stats, err = os.fstat(dir, context.temp_allocator)
	if err != nil {
		log.panicf("failed to stat shader_dir, reason: %s", err)
	}

	dir_iter := os.read_directory_iterator_create(dir)

	pool_cap := max(os1.processor_core_count() - 1, 1)
	pool_len := 0
	ShaderProc :: struct {
		process:   os.Process,
		file_info: os.File_Info,
	}
	proc_pool := make([]ShaderProc, pool_cap)

	poll_pool_loop := proc(proc_pool: []ShaderProc, pool_len: ^int) {
		p_len := pool_len^
		for i := 0; i < p_len; i += 1 {
			pool_proc := proc_pool[i]
			state, err := os.process_wait(pool_proc.process, timeout = 0)
			if err == os.General_Error.Timeout {
				continue
			}
			if err == nil {
				if !state.exited do continue
				if state.exit_code == 0 {
					log.infof("glslc compiled %s sucessfully", pool_proc.file_info.name)
				} else {
					log.errorf(
						"glslc failed to compile %s, exited with code: %d",
						pool_proc.file_info.name,
						state.exit_code,
					)
				}
			} else {
				log.errorf(
					"failed to read glslc process state for %s (ignoring) reason: %s",
					pool_proc.file_info.name,
					err,
				)
			}
			// remove via swapback
			proc_pool[i] = proc_pool[p_len - 1]
			p_len -= 1
		}
		pool_len^ = p_len
	}

	cmd_slice := make([]string, 5)
	cmd_slice[0] = "glslc"
	cmd_slice[2] = "-o"
	cmd_slice[4] = "--target-env=" + shared.target_env
	log.infof("compiling shaders in %s", shader_dir_stats.fullpath)
	for info in os.read_directory_iterator(&dir_iter) {
		in_name_splits, alloc_err := strings.split(info.name, ".")
		if alloc_err != nil {
			log.panic(err)
		}
		in_name_splits[1] = shared.out_shader_ext
		out_name: string
		out_name, alloc_err = strings.join(in_name_splits, ".")
		if alloc_err != nil {
			log.panic(err)
		}
		out_path, err := os.join_path(
			[]string{shared.dist_dir, shared.shader_dir, out_name},
			context.allocator,
		)
		if err != nil {
			log.panic(err)
		}
		out_file_info: os.File_Info
		out_file_info, err = os.stat(out_path, context.allocator)
		if err == nil && time.diff(info.modification_time, out_file_info.modification_time) > 0 {
			log.infof("skipping shader %s (cached)", info.name)
			continue
		}

		cmd_slice[1] = info.fullpath
		cmd_slice[3] = out_path
		log.debugf("%s", cmd_slice)
		process: os.Process
		process, err = os.process_start(
			{command = cmd_slice, stdout = os.stderr, stderr = os.stderr},
		)
		if err != nil {
			log.panic(err)
		}
		pool_len += 1
		proc_pool[pool_len - 1].process = process
		proc_pool[pool_len - 1].file_info = info
		for pool_len == pool_cap {
			poll_pool_loop(proc_pool, &pool_len)
		}
	}
	for pool_len > 0 {
		poll_pool_loop(proc_pool, &pool_len)
	}
	return
}

