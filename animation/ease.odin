package animation

import "core:math"

Ease :: enum {
	LINEAR,
	SINE,
	SINE_IN,
	SINE_OUT,
	CUBIC,
	CUBIC_IN,
	CUBIC_OUT,
	QUINT,
	QUINT_IN,
	QUINT_OUT,
	CIRC,
	CIRC_IN,
	CIRC_OUT,
	ELASTIC,
	ELASTIC_IN,
	ELASTIC_OUT,
	QUAD,
	QUAD_IN,
	QUAD_OUT,
	QUART,
	QUART_IN,
	QUART_OUT,
	EXPO,
	EXPO_IN,
	EXPO_OUT,
	BACK,
	BACK_IN,
	BACK_OUT,
	BOUNCE,
	BOUNCE_IN,
	BOUNCE_OUT,
}

ease_out_bounce :: #force_inline proc(dt: f32) -> (dt1: f32) {
	n1: f32 : 7.5625
	d1: f32 : 2.75
	d11: f32 : 1 / d1
	d15: f32 : 1.5 / d1
	d2: f32 : 2 / d1
	d25: f32 : 2.5 / d1
	d225: f32 : 2.25 / d1
	d2625: f32 : 2.625 / d1
	dt_sub_d15: f32 : d1 - d15
	dt_sub_d225: f32 : d1 - d225
	dt_sub_d2625: f32 : d1 - d2625


	first := n1 * dt * dt
	second := n1 * dt_sub_d15 * dt_sub_d15 + 0.75
	third := n1 * dt_sub_d225 * dt_sub_d225 + 0.9375
	fourth := n1 * dt_sub_d2625 * dt_sub_d2625 + 0.984375


	else_third := dt < d25 ? third : fourth
	else_second := dt < d2 ? second : else_third
	dt1 = dt < d11 ? first : else_second
	return
}

// dt 0 - 1
ease :: #force_inline proc(ease: Ease, dt: f32) -> (dt1: f32) {
	c1 :: 1.70158
	c2 :: c1 * 1.525
	c2_plus_1 :: c2 + 1
	c3 :: c1 + 1
	c4 :: 2 * math.PI / 3
	c5 :: 2 * math.PI / 4.5
	switch ease {
	case .LINEAR:
		return dt
	case .SINE:
		return -(math.cos(dt * math.PI) - 1) / 2
	case .SINE_IN:
		return 1 - math.cos(dt * math.PI / 2)
	case .SINE_OUT:
		return math.sin(dt * math.PI / 2)
	case .CUBIC:
		first := 4 * dt * dt * dt
		second := 1 - math.pow(-2 * dt + 2, 3) / 2
		return dt < 0.5 ? first : second
	case .CUBIC_IN:
		return dt * dt * dt
	case .CUBIC_OUT:
		return 1 - math.pow(1 - dt, 3)
	case .QUINT:
		dt_4 := dt * dt
		dt_4 *= dt_4
		first := 16 * dt_4 * dt
		second := 1 - math.pow(-2 * dt + 2, 5) / 2
		return dt < 0.5 ? first : second
	case .QUINT_IN:
		dt_4 := dt * dt
		dt_4 *= dt_4
		return dt_4 * dt
	case .QUINT_OUT:
		return 1 - math.pow(1 - dt, 5)
	case .CIRC:
		two_dt := 2 * dt
		neg_two_dt_plus_2 := -two_dt + 2
		neg_two_dt_plus_2 *= neg_two_dt_plus_2
		two_dt *= two_dt
		lt_half := (1 - math.sqrt(1 - two_dt)) / 2
		gt_half := (math.sqrt(1 - neg_two_dt_plus_2) + 1) / 2
		return dt < 0.5 ? lt_half : gt_half
	case .CIRC_IN:
		return 1 - math.sqrt(1 - dt * dt)
	case .CIRC_OUT:
		dt1 = dt - 1
		dt1 *= dt1
		return math.sqrt(1 - dt1)
	case .ELASTIC:
		sined := math.sin((20 * dt - 11.125) * c5)
		first := -(math.pow2_f32(20 * dt - 10) * sined) / 2
		second := math.pow2_f32(-20 * dt + 10) * sined / 2 + 1
		return dt == 0 ? 0 : dt == 1 ? 1 : dt < 0.5 ? first : second
	case .ELASTIC_IN:
		ten_dt := 10 * dt
		dt1 = -math.pow2_f32(ten_dt - 10) * math.sin((ten_dt - 10.75) * c4)
		return dt == 0 ? 0 : dt == 1 ? 1 : dt1
	case .ELASTIC_OUT:
		dt1 = math.pow2_f32(-10 * dt) * math.sin((dt * 10 - 0.75) * c4) + 1
		return dt == 0 ? 0 : dt == 1 ? 1 : dt1
	case .QUAD:
		first := 2 * dt * dt
		second := -2 * dt + 2
		second *= second
		second = 1 - second / 2
		return dt < 0.5 ? first : second
	case .QUAD_IN:
		return dt * dt
	case .QUAD_OUT:
		dt1 = 1 - dt
		dt1 *= dt1
		return 1 - dt1
	case .QUART:
		dt4 := dt * dt
		dt4 *= dt4
		first := 8 * dt4
		second := -2 * dt + 2
		second *= second
		second *= second
		second = 1 - second / 2
		return dt1 < 0.5 ? first : second
	case .QUART_IN:
		dt1 := dt * dt
		dt1 *= dt1
		return
	case .QUART_OUT:
		dt1 = 1 - dt
		dt1 *= dt1
		dt1 *= dt1
		return 1 - dt1
	case .EXPO:
		twenty_dt := 20 * dt
		first := math.pow2_f32(twenty_dt - 10) / 2
		second := (2 - math.pow2_f32(-twenty_dt + 10)) / 2
		return dt == 0 ? 0 : dt == 1 ? 1 : dt < 0.5 ? first : second
	case .EXPO_IN:
		return dt == 0 ? 0 : math.pow2_f32(10 * dt - 10)
	case .EXPO_OUT:
		return dt == 1 ? 1 : 1 - math.pow2_f32(-10 * dt)
	case .BACK:
		two_dt := 2 * dt
		two_dt_sub_two := two_dt - 2
		first := (two_dt * two_dt * (c2_plus_1 * two_dt - c2)) / 2
		second := (two_dt_sub_two * two_dt_sub_two * (c2_plus_1 * two_dt_sub_two + c2) + 2) / 2
		return dt < 0.5 ? first : second
	case .BACK_IN:
		dt2 := dt * dt
		return c3 * dt2 * dt - c1 * dt2
	case .BACK_OUT:
		dt_sub_1 := dt - 1
		dt_sub_1_2 := dt_sub_1 * dt_sub_1
		dt_sub_1_3 := dt_sub_1_2 * dt_sub_1
		return 1 + c3 * dt_sub_1_3 + c1 * dt_sub_1_2
	case .BOUNCE_OUT:
		return ease_out_bounce(dt)
	case .BOUNCE_IN:
		return 1 - ease_out_bounce(1 - dt)
	case .BOUNCE:
		two_dt := 2 * dt
		first := (1 - ease_out_bounce(1 - two_dt)) / 2
		second := (1 + ease_out_bounce(two_dt - 1)) / 2
		return dt < 0.5 ? first : second
	}
	return
}

