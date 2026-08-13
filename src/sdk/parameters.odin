package sdk

import b "../bridge"
import "core:math"
import "core:reflect"
import "core:strings"
import "core:testing"

ParamIndex :: distinct int

// Name-to-index lookup map
param_index: map[string]ParamIndex

param_init :: proc(params: []b.ParamDescriptor) {
	param_index = make(map[string]ParamIndex)
	for desc, i in params {
		param_index[desc.name] = ParamIndex(i)
	}
}

// .List label callback: step value -> enum member identifier
enum_label :: proc($E: typeid) -> proc(val: f64) -> string {
	return proc(val: f64) -> string {
		names := reflect.enum_field_names(E)
		i := int(val + 0.5)
		if i < 0 || i >= len(names) do return ""
		return names[i]
	}
}

@test
test_param_to_norm_and_back_hertz :: proc(t: ^testing.T) {
	desc := b.ParamDescriptor{
		min = 20.0,
		max = 20000.0,
		unit = .Hertz,
	}

	test_values := [?]f64{20.0, 100.0, 500, 1000.0, 5000.0, 10000.0, 20000.0}
	tolerance := 1e-9

	for val in test_values {
		norm := b.param_to_normalized(val, desc)
		back := b.normalized_to_param(norm, desc)
		diff := math.abs(val - back)
		testing.expect(t, diff <= tolerance)
	}

	test_norms := [?]f64{0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0}

	for val in test_norms {
		norm := b.normalized_to_param(val, desc)
		back := b.param_to_normalized(norm, desc)
		diff := math.abs(val - back)
		testing.expect(t, diff <= tolerance)
	}
}
