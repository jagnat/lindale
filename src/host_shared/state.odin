package host_shared

import "core:encoding/endian"
import "core:log"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:testing"

import "../bridge"

// Param table, locked at init

ParamTable :: struct {
	descs: []bridge.ParamDescriptor,
	host_ids: []u32,
	index_of: map[u32]int,
	plugin_count: int, // framework params follow the plugin's
}

// Clones descriptor strings so they outlive the hot dll. Logs every invalid id and returns false
param_table_init :: proc(t: ^ParamTable, plugin_descs, framework_descs: []bridge.ParamDescriptor, allocator := context.allocator) -> (ok: bool) {
	ok = true
	n := len(plugin_descs) + len(framework_descs)
	t.plugin_count = len(plugin_descs)
	t.descs = make([]bridge.ParamDescriptor, n, allocator)
	t.host_ids = make([]u32, n, allocator)
	t.index_of = make(map[u32]int, n, allocator)
	for i in 0 ..< n {
		is_framework := i >= len(plugin_descs)
		d := framework_descs[i - len(plugin_descs)] if is_framework else plugin_descs[i]
		d.id = strings.clone(d.id, allocator)
		d.name = strings.clone(d.name, allocator)
		d.short_name = strings.clone(d.short_name, allocator)
		t.descs[i] = d

		if d.id == "" {
			log.errorf("param %v (%q) has no id", i, d.name)
			ok = false
			continue
		}
		if !is_framework && strings.has_prefix(d.id, bridge.RESERVED_ID_PREFIX) {
			log.errorf("param id %q uses the reserved prefix %q", d.id, bridge.RESERVED_ID_PREFIX)
			ok = false
		}
		h := bridge.param_host_id(d.id)
		if prev, taken := t.index_of[h]; taken {
			log.errorf("param id %q collides with %q", d.id, t.descs[prev].id)
			ok = false
			continue
		}
		t.index_of[h] = i
		t.host_ids[i] = h
	}
	return
}

param_index_by_host_id :: proc(t: ^ParamTable, host_id: u32) -> (int, bool) {
	i, ok := t.index_of[host_id]
	return i, ok
}

param_index_by_id :: proc(t: ^ParamTable, id: string) -> (int, bool) {
	i, ok := t.index_of[bridge.param_host_id(id)]
	if !ok || t.descs[i].id != id do return -1, false
	return i, true
}

// The table can't change after init, so the hotloader refuses a reload that fails this
param_descs_compatible :: proc(old, new: []bridge.ParamDescriptor) -> bool {
	if len(old) != len(new) do return false
	for o, i in old {
		n := new[i]
		// display names and smoothing can change live
		n.name, n.short_name, n.smooth_ms = o.name, o.short_name, o.smooth_ms
		if o != n do return false
	}
	return true
}

// Instance state store, controller thread only

StateStore :: struct {
	entries: map[string][]u8,
}

state_store_init :: proc(s: ^StateStore, allocator := context.allocator) {
	s.entries = make(map[string][]u8, allocator)
}

state_store_set :: proc(s: ^StateStore, key: string, bytes: []u8) -> bool {
	if len(key) > int(max(u16)) {
		log.errorf("state key is %v bytes, the limit is %v", len(key), max(u16))
		return false
	}
	context.allocator = s.entries.allocator
	if key in s.entries {
		delete(s.entries[key])
		s.entries[key] = slice.clone(bytes)
	} else {
		s.entries[strings.clone(key)] = slice.clone(bytes)
	}
	return true
}

state_store_get :: proc(s: ^StateStore, key: string) -> []u8 {
	return s.entries[key]
}

state_store_clear :: proc(s: ^StateStore) {
	context.allocator = s.entries.allocator
	for k, v in s.entries {
		delete(k)
		delete(v)
	}
	clear(&s.entries)
}

// State format
// little endian, f64 values, strings are u16 byte length + utf8 bytes
// header: magic, u16 version, u32 header_len, then header_len bytes of fields this reader may not know
// body: sections of tag[4] + u32 len + payload, unknown tags are skipped
//   PARM: u32 count, {id string, f64 plain value}
//   DATA: u32 count, {key string, u32 len, bytes}

STATE_MAGIC :: [5]u8{0x89, 'L', 'I', 'N', 'D'}
STATE_VERSION :: u16(1) // bump only for breaking changes

serialize_state :: proc(t: ^ParamTable, values: ^bridge.ParamValues, store: ^StateStore, allocator := context.allocator) -> []u8 {
	buf := make([dynamic]u8, allocator)
	magic := STATE_MAGIC
	append(&buf, ..magic[:])
	put_u16(&buf, STATE_VERSION)
	put_u32(&buf, 0)

	section := begin_section(&buf, "PARM")
	put_u32(&buf, u32(len(t.descs)))
	for d, i in t.descs {
		put_str(&buf, d.id)
		put_f64(&buf, values.values[i])
	}
	end_section(&buf, section)

	section = begin_section(&buf, "DATA")
	count := len(store.entries) if store != nil else 0
	put_u32(&buf, u32(count))
	if store != nil {
		// sorted so unchanged state serializes to the same bytes
		keys, _ := slice.map_keys(store.entries, allocator)
		defer delete(keys, allocator)
		slice.sort(keys)
		for k in keys {
			v := store.entries[k]
			put_str(&buf, k)
			put_u32(&buf, u32(len(v)))
			append(&buf, ..v)
		}
	}
	end_section(&buf, section)

	return buf[:]
}

// All or nothing: on failure params and store are untouched. Missing params take defaults, unknown ones are ignored
deserialize_state :: proc(t: ^ParamTable, values: ^bridge.ParamValues, store: ^StateStore, data: []u8) -> bool {
	// validate in full before touching anything, so the commit pass can't fail
	if !read_state(t, values, store, data, false) do return false
	for d, i in t.descs do values.values[i] = d.default_value
	if store != nil do state_store_clear(store)
	read_state(t, values, store, data, true)
	return true
}

@(private="file")
read_state :: proc(t: ^ParamTable, values: ^bridge.ParamValues, store: ^StateStore, data: []u8, commit: bool) -> bool {
	r := Reader{data = data, ok = true}
	magic := STATE_MAGIC
	if string(take(&r, len(magic))) != string(magic[:]) {
		log.warn("unrecognized state format")
		return false
	}
	version := get_u16(&r)
	if version > STATE_VERSION {
		log.warnf("state version %v is newer than supported %v", version, STATE_VERSION)
		return false
	}
	take(&r, int(get_u32(&r)))

	for r.ok && r.pos < len(r.data) {
		tag := string(take(&r, 4))
		body_len := int(get_u32(&r))
		body := Reader{data = take(&r, body_len), ok = r.ok}
		switch tag {
		case "PARM":
			count := get_u32(&body)
			for _ in 0 ..< count {
				id := get_str(&body)
				v := get_f64(&body)
				if !body.ok do break
				if i, found := param_index_by_id(t, id); found && commit {
					values.values[i] = clamp(v, t.descs[i].min, t.descs[i].max)
				}
			}
		case "DATA":
			if store == nil do continue
			count := get_u32(&body)
			for _ in 0 ..< count {
				key := get_str(&body)
				bytes := take(&body, int(get_u32(&body)))
				if !body.ok do break
				if commit do state_store_set(store, key, bytes)
			}
		}
		if !body.ok do r.ok = false
	}
	if !r.ok do log.warn("truncated or malformed state")
	return r.ok
}

@(private="file")
put_u16 :: proc(buf: ^[dynamic]u8, v: u16) {
	b: [2]u8
	endian.put_u16(b[:], .Little, v)
	append(buf, ..b[:])
}

@(private="file")
put_u32 :: proc(buf: ^[dynamic]u8, v: u32) {
	b: [4]u8
	endian.put_u32(b[:], .Little, v)
	append(buf, ..b[:])
}

@(private="file")
put_f64 :: proc(buf: ^[dynamic]u8, v: f64) {
	b: [8]u8
	endian.put_f64(b[:], .Little, v)
	append(buf, ..b[:])
}

@(private="file")
put_str :: proc(buf: ^[dynamic]u8, s: string) {
	assert(len(s) <= int(max(u16)))
	put_u16(buf, u16(len(s)))
	append(buf, s)
}

// returns the offset of the length field
@(private="file")
begin_section :: proc(buf: ^[dynamic]u8, tag: string) -> int {
	assert(len(tag) == 4)
	append(buf, tag)
	put_u32(buf, 0)
	return len(buf) - 4
}

@(private="file")
end_section :: proc(buf: ^[dynamic]u8, len_offset: int) {
	endian.put_u32(buf[len_offset:], .Little, u32(len(buf) - len_offset - 4))
}

@(private="file")
Reader :: struct {
	data: []u8,
	pos: int,
	ok: bool,
}

@(private="file")
take :: proc(r: ^Reader, n: int) -> []u8 {
	if !r.ok || n < 0 || r.pos + n > len(r.data) {
		r.ok = false
		return nil
	}
	s := r.data[r.pos:][:n]
	r.pos += n
	return s
}

@(private="file")
get_u16 :: proc(r: ^Reader) -> u16 {
	v, _ := endian.get_u16(take(r, 2), .Little)
	return v
}

@(private="file")
get_u32 :: proc(r: ^Reader) -> u32 {
	v, _ := endian.get_u32(take(r, 4), .Little)
	return v
}

@(private="file")
get_f64 :: proc(r: ^Reader) -> f64 {
	v, _ := endian.get_f64(take(r, 8), .Little)
	return v
}

@(private="file")
get_str :: proc(r: ^Reader) -> string {
	return string(take(r, int(get_u16(r))))
}

// Tests

@(private="file")
test_descs := []bridge.ParamDescriptor {
	{id = "gain", name = "Gain", min = -60, max = 12, default_value = 0},
	{id = "mix", name = "Mix", min = 0, max = 100, default_value = 50},
}

@(private="file")
test_framework_descs := []bridge.ParamDescriptor {
	{id = "lindale.bypass", name = "Bypass", min = 0, max = 1, default_value = 0},
}

@test
test_param_table_validation :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	// invalid tables log errors, which the test runner counts as failures
	context.logger = log.nil_logger()
	defer free_all(context.temp_allocator)

	table: ParamTable
	testing.expect(t, param_table_init(&table, test_descs, test_framework_descs))
	testing.expect_value(t, len(table.descs), 3)
	i, found := param_index_by_host_id(&table, bridge.param_host_id("lindale.bypass"))
	testing.expect(t, found && i == 2)

	dup := []bridge.ParamDescriptor{{id = "a"}, {id = "a"}}
	testing.expect(t, !param_table_init(&table, dup, nil))
	reserved := []bridge.ParamDescriptor{{id = "lindale.x"}}
	testing.expect(t, !param_table_init(&table, reserved, nil))
	empty := []bridge.ParamDescriptor{{name = "no id"}}
	testing.expect(t, !param_table_init(&table, empty, nil))
}

@test
test_state_round_trip :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	table: ParamTable
	param_table_init(&table, test_descs, test_framework_descs)
	values := bridge.ParamValues{values = []f64{-6, 25, 1}}
	store: StateStore
	state_store_init(&store)
	state_store_set(&store, "pattern", []u8{1, 2, 3})
	state_store_set(&store, "from_newer_build", []u8{9})

	data := serialize_state(&table, &values, &store)

	out := bridge.ParamValues{values = make([]f64, 3)}
	out_store: StateStore
	state_store_init(&out_store)
	testing.expect(t, deserialize_state(&table, &out, &out_store, data))
	testing.expect(t, slice.equal(out.values, values.values))
	testing.expect(t, slice.equal(state_store_get(&out_store, "pattern"), []u8{1, 2, 3}))
	testing.expect(t, slice.equal(state_store_get(&out_store, "from_newer_build"), []u8{9}))

	testing.expect(t, !deserialize_state(&table, &out, &out_store, data[:len(data) - 1]))
	testing.expect(t, !deserialize_state(&table, &out, &out_store, transmute([]u8)string("{\"Gain\": 1}")))
	// failed loads leave everything as it was
	testing.expect(t, slice.equal(out.values, values.values))
	testing.expect(t, slice.equal(state_store_get(&out_store, "pattern"), []u8{1, 2, 3}))
}

@test
test_state_bytes_deterministic :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	table: ParamTable
	param_table_init(&table, test_descs, test_framework_descs)
	values := bridge.ParamValues{values = []f64{0, 50, 0}}
	a, b: StateStore
	state_store_init(&a)
	state_store_init(&b)
	keys := []string{"k0", "k1", "k2", "k3", "k4", "k5", "k6", "k7"}
	for k in keys do state_store_set(&a, k, transmute([]u8)k)
	#reverse for k in keys do state_store_set(&b, k, transmute([]u8)k)
	testing.expect(t, slice.equal(serialize_state(&table, &values, &a), serialize_state(&table, &values, &b)))
}

@test
test_state_unknown_and_missing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	// saved by a build that had "old" and lacked "mix", plus a section and header field this build doesn't know
	saved: ParamTable
	param_table_init(&saved, []bridge.ParamDescriptor{{id = "old", max = 10}, {id = "gain", min = -60, max = 12}}, nil)
	data := serialize_state(&saved, &bridge.ParamValues{values = []f64{3, -12}}, nil)
	buf := make([dynamic]u8)
	append(&buf, ..data[:7])
	put_u32(&buf, 2)
	append(&buf, 0xAA, 0xBB)
	append(&buf, ..data[11:])
	append(&buf, "NEWS")
	put_u32(&buf, 3)
	append(&buf, 1, 2, 3)

	table: ParamTable
	param_table_init(&table, test_descs, test_framework_descs)
	out := bridge.ParamValues{values = make([]f64, 3)}
	testing.expect(t, deserialize_state(&table, &out, nil, buf[:]))
	testing.expect_value(t, out.values[0], -12)
	testing.expect_value(t, out.values[1], 50)
	testing.expect_value(t, out.values[2], 0)
}
