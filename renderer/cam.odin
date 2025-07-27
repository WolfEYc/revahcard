package renderer

import "core:encoding/endian"
import "core:log"
import "core:math"
import lal "core:math/linalg"

NUM_FRUSTRUM_CORNERS :: 8

Frustrum_Corners :: [NUM_FRUSTRUM_CORNERS][4]f32

calc_frustrum_corners :: proc(v: mat4, p: mat4) -> (corners: Frustrum_Corners) {
	inv := lal.inverse(p * v)
	i := 0
	corner: [3]uint
	for ; corner.x < 2; corner.x += 1 {
		for corner.y = 0; corner.y < 2; corner.y += 1 {
			for corner.z = 0; corner.z < 2; corner.z += 1 {
				ndc_corner: [4]f32
				ndc_corner.xyz = 2.0 * [3]f32{f32(corner.x), f32(corner.y), f32(corner.z)} - 1.0
				ndc_corner.w = 1.0
				ndc_corner = inv * ndc_corner
				corners[i] = ndc_corner / ndc_corner.w
				i += 1
			}
		}
	}
	return
}

calc_frustrum_center :: proc(corners: Frustrum_Corners) -> (center: [3]f32) {
	for corner in corners {
		center += corner.xyz
	}
	center /= NUM_FRUSTRUM_CORNERS
	return
}

calc_dir_light_vp :: proc(pos: [3]f32) -> (vp: mat4) {

	// forwards.z = -forwards.z

	v := lal.matrix4_look_at_f32(pos, [3]f32{0, 0, 0}, [3]f32{0, 1, 0})
	// min_vec: [3]f32 = math.F32_MAX
	// max_vec: [3]f32 = math.F32_MIN
	// for corner in corners {
	// 	trf := v * corner
	// 	min_vec.x = min(min_vec.x, trf.x)
	// 	min_vec.y = min(min_vec.y, trf.y)
	// 	min_vec.z = min(min_vec.z, trf.z)
	// 	max_vec.x = max(max_vec.x, trf.x)
	// 	max_vec.y = max(max_vec.y, trf.y)
	// 	max_vec.z = max(max_vec.z, trf.z)
	// }
	// log.infof("min_vec=%v", min_vec)
	// log.infof("max_vec=%v", max_vec)

	// zMult :: 10.0

	// if min_vec.z < 0 {
	// 	min_vec.z *= zMult
	// } else {
	// 	min_vec.z /= zMult
	// }
	// if max_vec.z < 0 {
	// 	max_vec.z /= zMult
	// } else {
	// 	max_vec.z *= zMult
	// }

	// log.infof("near=%v, far=%v", min_vec.z, max_vec.z)
	p := lal.matrix_ortho3d_f32(-2.4, 2.4, -2.4, 2.4, -5, 5)
	vp = p * v
	return
}

