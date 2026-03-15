package platform

import "core:encoding/json"
import "core:log"

import "../bridge"

// Serializes parameter values to a JSON byte slice.
serialize_params :: proc(
	param_descs: []bridge.ParamDescriptor,
	param_values: ^bridge.ParamValues,
	allocator := context.allocator,
) -> ([]u8, bool) {
	param_map := make(map[string]f64, len(param_descs), context.temp_allocator)
	defer delete(param_map)
	for desc, i in param_descs {
		param_map[desc.name] = param_values.values[i]
	}
	data, err := json.marshal(param_map, allocator = allocator)
	if err != nil {
		log.warnf("Failed to serialize param state: {}", err)
		return nil, false
	}
	return data, true
}

// Deserializes parameter values from a JSON byte slice into param_values.
// Unrecognized keys are ignored. Missing keys stay at their default values.
deserialize_params :: proc(
	param_descs: []bridge.ParamDescriptor,
	param_values: ^bridge.ParamValues,
	data: []u8,
) -> bool {
	for desc, i in param_descs {
		param_values.values[i] = desc.default_value
	}

	param_map: map[string]f64
	err := json.unmarshal(data, &param_map, allocator = context.temp_allocator)
	if err != nil {
		log.warnf("Failed to deserialize param state: {}", err)
		return false
	}
	defer delete(param_map)

	for name, value in param_map {
		for desc, i in param_descs {
			if desc.name == name {
				param_values.values[i] = value
				break
			}
		}
	}
	return true
}
