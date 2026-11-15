-- Block World's GPU side: WGSL for zgx's shader fills and layer shaders.
--
-- The world is drawn by `world`, a layer shader over the game's box: a
-- voxel ray caster (one ray a pixel, stepped cell by cell). It reads the
-- world from the data canvases painted inside that box (see game.luau):
--   * the height map at x 384..479, y 0..95: red = height * 4,
--     green = surface kind * 32;
--   * the changed blocks: 16 tiles of 96 by 96, four to a row, one tile
--     per three layers of height, each layer a colour channel holding
--     (block id + 1) * 8, or nothing where the block is as generated;
--   * the entities (dropped blocks, bits of broken ones) in a row at y 96
--     from x 384 (see tb_ent_px).
-- Everything else (terrain by depth, the blocks' looks, light, water, sky,
-- clouds, the player and their hand) is computed here. The look is the
-- Zeron film's: smooth blocks with soft bevels, each block a little its
-- own; a round sun and soft clouds.
--
-- The layer's params:
--   0: the camera (x, y, z, yaw)
--   1: (pitch, time, flags: 1 under water + 2 ready + 4 * the field of view
--      in degrees, how far the targeted block is broken 0..1)
--   2: (the targeted block x, y, z, x < 0 for none; the block in hand, 0
--      none, -1 no hand at all, + 0.5 crouching)
--   3: (the arm's swing 0..1, the legs' swing, the camera's distance behind
--      the player's eyes (0: first person), how many entities)
--
-- `icon` is a shader fill drawing one block as an isometric cube, for the
-- hotbar and inventory. Both share `common`: the block ids and the painter.

local common = [[
const TB_WX: i32 = 96;
const TB_WY: i32 = 48;
const TB_WZ: i32 = 96;
const TB_WATER: i32 = 18;

const TB_AIR: i32 = 0;
const TB_GRASS: i32 = 1;
const TB_DIRT: i32 = 2;
const TB_STONE: i32 = 3;
const TB_COBBLE: i32 = 4;
const TB_PLANKS: i32 = 5;
const TB_LOG: i32 = 6;
const TB_LEAVES: i32 = 7;
const TB_SAND: i32 = 8;
const TB_WATERB: i32 = 9;
const TB_GLASS: i32 = 10;
const TB_BRICKS: i32 = 11;
const TB_BEDROCK: i32 = 12;
const TB_COAL: i32 = 13;
const TB_IRON: i32 = 14;
const TB_SNOW: i32 = 15;
const TB_GRAVEL: i32 = 16;
const TB_GOLD: i32 = 17;
const TB_WOOL: i32 = 18;
const TB_STONEBRICK: i32 = 19;
const TB_BOOKS: i32 = 20;
const TB_CRAFT: i32 = 21;
// Items (not blocks): drawn as sprites.
const TB_STICK: i32 = 22;
const TB_FIRST_ITEM: i32 = 22;

fn tb_h(p: vec2<f32>, s: f32) -> f32 {
	let q = vec2<f32>(dot(p, vec2<f32>(127.1, 311.7)), dot(p, vec2<f32>(269.5, 183.3))) + vec2<f32>(s * 17.13, s * 31.71);
	return fract(sin(q.x + q.y * 0.137) * 43758.5453);
}

// Smooth value noise (0..1) at `p`, seeded by `s`.
fn tb_vn(p: vec2<f32>, s: f32) -> f32 {
	let i = floor(p);
	let f = fract(p);
	let u = f * f * (vec2<f32>(3.0) - 2.0 * f);
	let a = tb_h(i, s);
	let b = tb_h(i + vec2<f32>(1.0, 0.0), s);
	let c = tb_h(i + vec2<f32>(0.0, 1.0), s);
	let d = tb_h(i + vec2<f32>(1.0, 1.0), s);
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Each block's own draw (0..1): no two alike.
fn tb_jit(cell: vec3<f32>, s: f32) -> f32 {
	return tb_h(vec2<f32>(cell.x * 1.37 + cell.y * 7.13, cell.z * 1.91), s);
}

// A face's soft bevel: its rims rounded off; a side's top rim catching the
// sky, its foot in shade.
fn tb_bevel(uv: vec2<f32>, face: i32) -> f32 {
	let w = 0.09;
	let l = 1.0 - smoothstep(0.0, w, uv.x);
	let r = 1.0 - smoothstep(0.0, w, 1.0 - uv.x);
	let t = 1.0 - smoothstep(0.0, w, uv.y);
	let b = 1.0 - smoothstep(0.0, w, 1.0 - uv.y);
	if (face == 2) {
		// (and a little lighter up the face)
		return (1.0 + 0.10 * t - 0.15 * b - 0.06 * max(l, r)) * (1.03 - 0.08 * uv.y);
	}
	return 1.0 - 0.035 * max(max(l, r), max(t, b));
}

fn tb_soil(uv: vec2<f32>, k: f32) -> vec3<f32> {
	let n = tb_vn(uv * 3.0 + vec2<f32>(k * 11.0, k * 5.0), 2.0);
	return vec3<f32>(0.66, 0.46, 0.34) * (0.92 + 0.08 * k + 0.07 * n);
}

fn tb_rock(uv: vec2<f32>, k: f32) -> vec3<f32> {
	let n = tb_vn(uv * 2.4 + vec2<f32>(k * 9.0, k * 3.0), 3.0);
	return vec3<f32>(0.61, 0.61, 0.67) * (0.90 + 0.10 * k + 0.08 * n);
}

// Rounded stones set in mortar (a cell's nearest two points, three a side).
fn tb_stones(uv: vec2<f32>, k: f32, base: vec3<f32>) -> vec3<f32> {
	let p = uv * 3.0;
	let cell = floor(p);
	var f1 = 9.0;
	var f2 = 9.0;
	var id = vec2<f32>(0.0);
	for (var j = -1; j <= 1; j = j + 1) {
		for (var i = -1; i <= 1; i = i + 1) {
			let cc = cell + vec2<f32>(f32(i), f32(j));
			let ctr = cc + vec2<f32>(0.2) + 0.6 * vec2<f32>(tb_h(cc, 4.1 + k), tb_h(cc, 4.2 + k));
			let d = length(p - ctr);
			if (d < f1) {
				f2 = f1;
				f1 = d;
				id = cc;
			} else if (d < f2) {
				f2 = d;
			}
		}
	}
	let seam = smoothstep(0.06, 0.20, f2 - f1);
	let stone = base * (0.86 + 0.20 * tb_h(id, 4.3 + k)) * (1.06 - 0.16 * f1);
	return mix(base * 0.62, stone, seam);
}

// Boards across the face, four to a block, soft grooves between.
fn tb_boards(uv: vec2<f32>, k: f32) -> vec3<f32> {
	let row = floor(uv.y * 4.0);
	let ry = fract(uv.y * 4.0);
	var c = vec3<f32>(0.80, 0.62, 0.42) * (0.90 + 0.12 * tb_h(vec2<f32>(row, k * 17.0), 5.0));
	c = c * (0.97 + 0.03 * sin(uv.x * 21.0 + row * 2.3));
	let g = min(ry, 1.0 - ry);
	return c * (0.78 + 0.22 * smoothstep(0.0, 0.10, g));
}

fn tb_bark(uv: vec2<f32>, k: f32) -> vec3<f32> {
	let g = 0.5 + 0.5 * sin(uv.x * 6.2832 * 3.0 + k * 3.0);
	return vec3<f32>(0.56, 0.39, 0.28) * (0.92 + 0.08 * k) * (1.0 - 0.10 * pow(g, 6.0));
}

fn tb_rings(uv: vec2<f32>, k: f32) -> vec3<f32> {
	let r = length(uv - vec2<f32>(0.5));
	if (r > 0.42) {
		return tb_bark(uv, k);
	}
	let w = 0.5 + 0.5 * sin(r * 44.0);
	return mix(vec3<f32>(0.86, 0.69, 0.48), vec3<f32>(0.76, 0.58, 0.40), w * 0.7);
}

// A few round gems in rock.
fn tb_gems(uv: vec2<f32>, k: f32, col: vec3<f32>) -> vec3<f32> {
	var c = tb_rock(uv, k);
	for (var i = 0; i < 3; i = i + 1) {
		let q = vec2<f32>(0.22, 0.22) + 0.56 * vec2<f32>(tb_h(vec2<f32>(f32(i), k * 13.0), 13.0), tb_h(vec2<f32>(f32(i), k * 13.0), 13.5));
		let d = length(uv - q);
		let g = 1.0 - smoothstep(0.075, 0.095, d);
		c = mix(c, col * (1.08 - 1.6 * d), g);
	}
	return c;
}

fn tb_masonry(uv: vec2<f32>, k: f32, rows: f32, per: f32, brick: vec3<f32>, mortar: vec3<f32>) -> vec3<f32> {
	let row = floor(uv.y * rows);
	let off = select(0.0, 0.5 / per, row - 2.0 * floor(row / 2.0) > 0.5);
	let x = fract((uv.x + off) * per);
	let y = fract(uv.y * rows);
	let m = min(min(x, 1.0 - x) / per, min(y, 1.0 - y) / rows);
	let b = brick * (0.88 + 0.16 * tb_h(vec2<f32>(floor((uv.x + off) * per), row + k * 9.0), 11.3));
	return mix(mortar, b, smoothstep(0.008, 0.022, m));
}

// A block's colour (rgb) and coverage (a: 0 shows through) at `uv` (0..1,
// row 0 at the top) of a face (0 the top, 1 the bottom, 2 a side), of the
// block at `cell`.
fn tb_tex(id: i32, face: i32, uv: vec2<f32>, cell: vec3<f32>, time: f32) -> vec4<f32> {
	let k = tb_jit(cell, f32(id) * 1.7);
	let bev = tb_bevel(uv, face);
	// (a top's place in the world, for patches that cross blocks)
	let wp = cell.xz + uv;
	switch (id) {
		case 1: {
			let spread = tb_vn(wp * 0.11, 1.0);
			let top = mix(vec3<f32>(0.50, 0.78, 0.42), vec3<f32>(0.63, 0.84, 0.45), spread) * (0.97 + 0.05 * k);
			if (face == 0) { return vec4<f32>(top * bev, 1.0); }
			if (face == 1) { return vec4<f32>(tb_soil(uv, k) * bev, 1.0); }
			return vec4<f32>(top * vec3<f32>(0.86, 0.88, 0.86) * bev, 1.0);
		}
		case 2: { return vec4<f32>(tb_soil(uv, k) * bev, 1.0); }
		case 3: { return vec4<f32>(tb_rock(uv, k) * bev, 1.0); }
		case 4: { return vec4<f32>(tb_stones(uv, k, vec3<f32>(0.62, 0.62, 0.67)) * bev, 1.0); }
		case 5: { return vec4<f32>(tb_boards(uv, k) * bev, 1.0); }
		case 6: {
			if (face == 2) { return vec4<f32>(tb_bark(uv, k) * bev, 1.0); }
			return vec4<f32>(tb_rings(uv, k) * bev, 1.0);
		}
		case 7: {
			let base = mix(vec3<f32>(0.18, 0.45, 0.34), vec3<f32>(0.25, 0.52, 0.33), k);
			let n = tb_vn(uv * 2.2 + vec2<f32>(k * 13.0, k * 7.0), 7.0);
			let lift = select(1.0, 1.14, face == 0);
			return vec4<f32>(base * lift * (0.90 + 0.16 * n) * bev, 1.0);
		}
		case 8: {
			var c = vec3<f32>(0.95, 0.88, 0.70) * (0.96 + 0.06 * k);
			if (face == 0) {
				c = c * (0.985 + 0.025 * sin((wp.x * 0.8 + wp.y * 0.35) * 6.2832));
			}
			return vec4<f32>(c * bev, 1.0);
		}
		case 9: {
			let s = sin(wp.x * 1.7 + time * 1.4) * sin(wp.y * 1.3 - time * 1.1);
			let c = vec3<f32>(0.20, 0.60, 0.76) * (0.95 + 0.07 * s);
			return vec4<f32>(c, 0.7);
		}
		case 10: {
			let e = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
			if (e < 0.05) { return vec4<f32>(0.86, 0.93, 0.97, 1.0); }
			let s = uv.x + uv.y;
			if (abs(s - 0.55) < 0.05 && uv.x < 0.45) { return vec4<f32>(0.95, 0.98, 1.0, 1.0); }
			return vec4<f32>(0.0);
		}
		case 11: { return vec4<f32>(tb_masonry(uv, k, 4.0, 2.0, vec3<f32>(0.78, 0.43, 0.35), vec3<f32>(0.86, 0.84, 0.80)) * bev, 1.0); }
		case 12: { return vec4<f32>(vec3<f32>(0.29, 0.29, 0.33) * (0.90 + 0.12 * k) * bev, 1.0); }
		case 13: { return vec4<f32>(tb_gems(uv, k, vec3<f32>(0.20, 0.20, 0.24)) * bev, 1.0); }
		case 14: { return vec4<f32>(tb_gems(uv, k, vec3<f32>(0.90, 0.72, 0.60)) * bev, 1.0); }
		case 15: {
			let snow = vec3<f32>(0.96, 0.97, 1.0) * (0.97 + 0.03 * k);
			if (face == 1) { return vec4<f32>(tb_soil(uv, k) * bev, 1.0); }
			return vec4<f32>(snow * bev, 1.0);
		}
		case 16: {
			let n = tb_vn(uv * 6.0 + vec2<f32>(k * 9.0, k * 4.0), 16.0);
			let c = mix(vec3<f32>(0.52, 0.50, 0.49), vec3<f32>(0.68, 0.65, 0.62), smoothstep(0.35, 0.65, n));
			return vec4<f32>(c * bev, 1.0);
		}
		case 17: { return vec4<f32>(tb_gems(uv, k, vec3<f32>(0.98, 0.82, 0.30)) * bev, 1.0); }
		case 18: { return vec4<f32>(vec3<f32>(0.94, 0.93, 0.90) * (0.96 + 0.05 * k) * bev, 1.0); }
		case 19: { return vec4<f32>(tb_masonry(uv, k, 2.0, 1.0, vec3<f32>(0.64, 0.64, 0.69), vec3<f32>(0.44, 0.44, 0.48)) * bev, 1.0); }
		case 20: {
			if (face != 2 || uv.y < 0.1 || uv.y > 0.9 || abs(uv.y - 0.5) < 0.06) { return vec4<f32>(tb_boards(uv, k) * bev, 1.0); }
			let spine = floor(uv.x * 8.0);
			let h = tb_h(vec2<f32>(spine, select(0.0, 1.0, uv.y > 0.5) + k * 5.0), 20.0);
			var c = vec3<f32>(0.70, 0.30, 0.30);
			if (h > 0.75) { c = vec3<f32>(0.30, 0.44, 0.70); } else if (h > 0.5) { c = vec3<f32>(0.34, 0.60, 0.40); } else if (h > 0.3) { c = vec3<f32>(0.80, 0.68, 0.40); }
			return vec4<f32>(c * (0.86 + 0.14 * smoothstep(0.0, 0.3, fract(uv.x * 8.0))) * bev, 1.0);
		}
		case 21: {
			// The crafting table: a grid cut in its top; its sides boards under
			// a dark rim, a saw and a hammer hung on them.
			if (face == 0) {
				var c = tb_boards(uv, k) * 1.05;
				let g = abs(fract(uv * 3.0) - vec2<f32>(0.5));
				if (max(g.x, g.y) > 0.44) { c = c * 0.55; }
				let e = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
				if (e < 0.06) { c = vec3<f32>(0.42, 0.29, 0.18); }
				return vec4<f32>(c * bev, 1.0);
			}
			if (face == 1) { return vec4<f32>(tb_boards(uv, k) * bev, 1.0); }
			var c = tb_boards(uv, k);
			if (uv.y < 0.2) { c = vec3<f32>(0.45, 0.31, 0.19) * (0.95 + 0.1 * k); }
			// a saw: a grey blade, a wooden grip
			if (uv.x > 0.14 && uv.x < 0.44 && uv.y > 0.34 && uv.y < 0.52 && uv.y - 0.34 < (0.44 - uv.x) * 0.9) { c = vec3<f32>(0.62, 0.64, 0.68); }
			if (uv.x > 0.38 && uv.x < 0.48 && uv.y > 0.3 && uv.y < 0.42) { c = vec3<f32>(0.40, 0.26, 0.15); }
			// a hammer: a handle, a head
			if (uv.x > 0.66 && uv.x < 0.72 && uv.y > 0.36 && uv.y < 0.82) { c = vec3<f32>(0.40, 0.26, 0.15); }
			if (uv.x > 0.58 && uv.x < 0.80 && uv.y > 0.32 && uv.y < 0.42) { c = vec3<f32>(0.50, 0.50, 0.54); }
			return vec4<f32>(c * bev, 1.0);
		}
		default: { return vec4<f32>(1.0, 0.0, 1.0, 1.0); }
	}
}

]]

local world = common .. [[
// The block changed at `c` (its id + 1), or 0 for as generated.
fn tb_ov(c: vec3<i32>) -> i32 {
	let t = c.y / 3;
	let ch = c.y - t * 3;
	let px = f32((t % 4) * TB_WX + c.x) + 0.5;
	let py = f32((t / 4) * TB_WZ + c.z) + 0.5;
	let s = zgx_sample(vec2<f32>(px, py));
	var v = s.r;
	if (ch == 1) {
		v = s.g;
	} else if (ch == 2) {
		v = s.b;
	}
	return i32(round(v * 31.875));
}

// A column's height and surface kind (0 grass, 1 sand, 2 snow, 3 gravel).
fn tb_hm(x: i32, z: i32) -> vec2<i32> {
	let s = zgx_sample(vec2<f32>(384.5 + f32(x), 0.5 + f32(z)));
	return vec2<i32>(i32(round(s.r * 63.75)), i32(round(s.g * 7.96875)));
}

fn tb_terrain(y: i32, h: i32, surf: i32) -> i32 {
	if (y == 0) { return TB_BEDROCK; }
	if (y > h) {
		if (y <= TB_WATER) { return TB_WATERB; }
		return TB_AIR;
	}
	if (y == h) {
		if (surf == 1) { return TB_SAND; }
		if (surf == 2) { return TB_SNOW; }
		if (surf == 3) { return TB_GRAVEL; }
		return TB_GRASS;
	}
	if (y >= h - 3) {
		if (surf == 1) { return TB_SAND; }
		if (surf == 3) { return TB_GRAVEL; }
		return TB_DIRT;
	}
	return TB_STONE;
}

fn tb_block(c: vec3<i32>) -> i32 {
	if (c.y < 0) { return TB_BEDROCK; }
	if (c.y >= TB_WY) { return TB_AIR; }
	if (c.x < 0 || c.z < 0 || c.x >= TB_WX || c.z >= TB_WZ) {
		if (c.y <= TB_WATER) { return TB_WATERB; }
		return TB_AIR;
	}
	let o = tb_ov(c);
	if (o > 0) { return o - 1; }
	let hs = tb_hm(c.x, c.z);
	return tb_terrain(c.y, hs.x, hs.y);
}

fn tb_solid(c: vec3<i32>) -> f32 {
	let b = tb_block(c);
	return select(1.0, 0.0, b == TB_AIR || b == TB_WATERB || b == TB_GLASS);
}

fn tb_vao(s1: f32, s2: f32, c: f32) -> f32 {
	if (s1 > 0.5 && s2 > 0.5) { return 0.0; }
	return 3.0 - s1 - s2 - c;
}

const TB_SUN: vec3<f32> = vec3<f32>(0.42, 0.66, -0.62);
fn tb_sky(ro: vec3<f32>, rd: vec3<f32>, time: f32) -> vec3<f32> {
	let up = clamp(rd.y, 0.0, 1.0);
	var c = mix(vec3<f32>(0.71, 0.83, 1.0), vec3<f32>(0.40, 0.60, 0.98), pow(up, 0.55));
	let sd = normalize(TB_SUN);
	// (a round sun in a soft glow; soft clouds)
	let dd = max(dot(rd, sd), 0.0);
	c = c + vec3<f32>(1.0, 0.92, 0.74) * (0.10 * pow(dd, 6.0) + 0.30 * pow(dd, 90.0));
	c = mix(c, vec3<f32>(1.0, 0.98, 0.90), smoothstep(0.99875, 0.99905, dd));
	if (rd.y > 0.01) {
		let tc = (88.0 - ro.y) / rd.y;
		if (tc > 0.0) {
			let pc = ro.xz + rd.xz * tc + vec2<f32>(time * 1.2, 0.0);
			let cov = tb_vn(pc / 34.0, 21.0) * 0.62 + tb_vn(pc / 12.0, 22.0) * 0.38;
			let fade = 1.0 - smoothstep(120.0, 520.0, tc);
			c = mix(c, vec3<f32>(1.0, 1.0, 1.0), smoothstep(0.54, 0.70, cov) * 0.85 * fade);
		}
	}
	return c;
}

// A segment's distance from `p`.
fn tb_seg(p: vec2<f32>, a: vec2<f32>, b: vec2<f32>) -> f32 {
	let pa = p - a;
	let ba = b - a;
	let h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
	return length(pa - ba * h);
}

// Cracks over a face being broken, at `stage` (1..10): jagged lines out
// from a point near the middle, more and longer stage by stage, with
// branches late. The distance to the nearest line.
fn tb_crack(uv: vec2<f32>, stage: f32, seed: f32) -> f32 {
	let c = vec2<f32>(0.5) + (vec2<f32>(tb_h(vec2<f32>(seed, 1.0), 40.0), tb_h(vec2<f32>(seed, 2.0), 41.0)) - 0.5) * 0.22;
	var d = 9.0;
	for (var i = 0; i < 7; i = i + 1) {
		let fi = f32(i);
		let need = fi * 0.95;
		if (stage <= need) {
			break;
		}
		let grow = clamp((stage - need) / 4.0, 0.0, 1.0);
		var a = c;
		let base = fi * 0.8976 + tb_h(vec2<f32>(seed, fi), 42.0) * 0.8;
		for (var j = 0; j < 6; j = j + 1) {
			let fj = f32(j);
			let frac = clamp(grow * 6.0 - fj, 0.0, 1.0);
			if (frac <= 0.0) {
				break;
			}
			// (each step turns a little off the ray's heading: jagged, not curly)
			let ang = base + (tb_h(vec2<f32>(seed + fi * 3.1, fj), 43.0) - 0.5) * 1.5;
			let len = 0.06 + 0.05 * tb_h(vec2<f32>(fi + seed, fj), 44.0);
			let b = a + vec2<f32>(cos(ang), sin(ang)) * len * frac;
			d = min(d, tb_seg(uv, a, b));
			if (j == 2 && stage > need + 4.0 && tb_h(vec2<f32>(fi, seed), 45.0) > 0.4) {
				let side = select(-1.0, 1.0, tb_h(vec2<f32>(fi, fj + seed), 46.0) > 0.5);
				let ba = base + side * 0.8;
				d = min(d, tb_seg(uv, b, b + vec2<f32>(cos(ba), sin(ba)) * 0.12 * clamp(stage - need - 4.0, 0.0, 1.0)));
			}
			a = b;
		}
	}
	return d;
}

// Light on a face by its (world) normal: the top brightest, the bottom
// darkest, the sides between.
fn tb_light_n(n: vec3<f32>) -> f32 {
	if (n.y > 0.5) { return 1.0; }
	if (n.y < -0.5) { return 0.52; }
	return mix(0.64, 0.80, abs(n.z));
}

fn tb_face_light(n: vec3<f32>) -> f32 {
	return tb_light_n(n);
}

// A ray from `o` along `d` against a box of half size `h` about the origin:
// its normal at the way in (xyz) and the distance there (w), or w < 0.
fn tb_box(o: vec3<f32>, d: vec3<f32>, h: vec3<f32>) -> vec4<f32> {
	let dn = d + select(vec3<f32>(0.0), vec3<f32>(1e-6), abs(d) < vec3<f32>(1e-6));
	let inv = 1.0 / dn;
	let t0 = (-h - o) * inv;
	let t1 = (h - o) * inv;
	let tmin = min(t0, t1);
	let tmax = max(t0, t1);
	let tn = max(max(tmin.x, tmin.y), tmin.z);
	let tf = min(min(tmax.x, tmax.y), tmax.z);
	if (tf < tn || tn < 0.0) {
		return vec4<f32>(-1.0);
	}
	var n = vec3<f32>(0.0, 0.0, -sign(dn.z));
	if (tn == tmin.x) {
		n = vec3<f32>(-sign(dn.x), 0.0, 0.0);
	} else if (tn == tmin.y) {
		n = vec3<f32>(0.0, -sign(dn.y), 0.0);
	}
	return vec4<f32>(n, tn);
}

// Where on a box's face a point `p` (in the box's frame, half size `h`)
// lies: uv 0..1 (row 0 at the top), and which face (0 top, 1 bottom, 2 side).
fn tb_box_uv(p: vec3<f32>, n: vec3<f32>, h: vec3<f32>) -> vec3<f32> {
	let q = clamp(p / h * 0.5 + vec3<f32>(0.5), vec3<f32>(0.0), vec3<f32>(0.999));
	if (n.y > 0.5) { return vec3<f32>(q.x, q.z, 0.0); }
	if (n.y < -0.5) { return vec3<f32>(q.x, q.z, 1.0); }
	if (abs(n.x) > 0.5) { return vec3<f32>(q.z, 1.0 - q.y, 2.0); }
	return vec3<f32>(q.x, 1.0 - q.y, 2.0);
}

fn tb_rot_y(a: f32) -> mat3x3<f32> {
	let c = cos(a);
	let s = sin(a);
	return mat3x3<f32>(vec3<f32>(c, 0.0, s), vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(-s, 0.0, c));
}

fn tb_rot_x(a: f32) -> mat3x3<f32> {
	let c = cos(a);
	let s = sin(a);
	return mat3x3<f32>(vec3<f32>(1.0, 0.0, 0.0), vec3<f32>(0.0, c, s), vec3<f32>(0.0, -s, c));
}

fn tb_rot_z(a: f32) -> mat3x3<f32> {
	let c = cos(a);
	let s = sin(a);
	return mat3x3<f32>(vec3<f32>(c, s, 0.0), vec3<f32>(-s, c, 0.0), vec3<f32>(0.0, 0.0, 1.0));
}

// Entities (dropped blocks and bits of broken ones), painted in a row at
// y 96 from x 384, three points each:
//   0: the whole block it's in, (x * 2, y * 4, z * 2) / 255;
//   1: where in that block, each a 64th, * 4 / 255;
//   2: (block id * 8, its turn (a drop's phase) in 64ths of a circle * 4,
//      its size in 128ths of a block * 4) / 255.
// A drop (size 0.1 and more) bobs and turns by itself, on the time.
fn tb_ent_px(k: i32, j: i32) -> vec4<f32> {
	return zgx_sample(vec2<f32>(384.5 + f32(k * 3 + j), 96.5)) * 255.0;
}

// An item's picture (Pixel Perfection's 16 by 16 pixel art, CC BY-SA 4.0:
// icons/atlas.png, painted at x 384, y 98: 32 by 32 each, three to a row,
// from id 22) at `uv` (0..1, row 0 at the top), its pixels kept square:
// colour and coverage.
fn tb_icon(id: i32, uv: vec2<f32>) -> vec4<f32> {
	let k = id - TB_FIRST_ITEM;
	let cell = vec2<f32>(f32(k % 3), f32(k / 3)) * 32.0;
	let t = clamp(floor(uv * 32.0), vec2<f32>(0.0), vec2<f32>(31.0)) + vec2<f32>(0.5);
	return zgx_sample(vec2<f32>(384.0, 98.0) + cell + t);
}

// An item as Minecraft draws one in the world: its picture, a sixteenth
// thick (a slab at z -1/32..1/32 in its frame, x and y -0.5..0.5). The ray
// in that frame from `o` along `d`: the distance in and its colour (w 0:
// missed). Its edges show where the picture runs out inside the slab.
fn tb_item_slab(id: i32, o: vec3<f32>, d: vec3<f32>) -> vec4<f32> {
	let hit = tb_box(o, d, vec3<f32>(0.5, 0.5, 1.0 / 32.0));
	if (hit.w <= 0.0) {
		return vec4<f32>(0.0);
	}
	// Through the slab, a few looks: the first covered texel is it.
	let t1 = (sign(d.z) * (1.0 / 32.0) - o.z) / select(d.z, 1e-6, abs(d.z) < 1e-6);
	let far = max(hit.w, select(t1, hit.w + 0.06, abs(d.z) < 1e-6));
	for (var i = 0; i < 4; i = i + 1) {
		let t = mix(hit.w, far, f32(i) / 3.0);
		let p = o + d * t;
		if (abs(p.x) <= 0.5 && abs(p.y) <= 0.5) {
			let c = tb_icon(id, vec2<f32>(p.x + 0.5, 0.5 - p.y));
			if (c.a > 0.5) {
				// (the face lit, the cut edges darker)
				let edge = select(1.0, 0.72, i > 0 || abs(hit.z) < 0.5);
				return vec4<f32>(c.rgb * edge, t);
			}
		}
	}
	return vec4<f32>(0.0);
}

struct TbHit {
	t: f32,
	n: vec3<f32>,
	col: vec3<f32>,
}

fn tb_entities(ro: vec3<f32>, rd: vec3<f32>, count: i32, far: f32, time: f32) -> TbHit {
	var best = TbHit(far, vec3<f32>(0.0), vec3<f32>(0.0));
	for (var k = 0; k < count; k = k + 1) {
		let a = tb_ent_px(k, 0);
		let b = tb_ent_px(k, 1);
		let ctr = vec3<f32>(round(a.x / 2.0), round(a.y / 4.0), round(a.z / 2.0)) + vec3<f32>(round(b.x / 4.0), round(b.y / 4.0), round(b.z / 4.0)) / 64.0;
		// (A quick miss: the ray passes well clear of it.)
		let oc = ctr - ro;
		let along = dot(oc, rd);
		if (along < 0.0 || along > best.t + 1.0 || dot(oc, oc) - along * along > 0.16) {
			continue;
		}
		let c = tb_ent_px(k, 2);
		let id = i32(round(c.x / 8.0));
		let phase = round(c.y / 4.0) / 64.0 * 6.2832;
		let half = round(c.z / 4.0) / 128.0;
		var turn = phase;
		var at = ctr;
		if (half >= 0.1) {
			turn = time * 1.4 + phase;
			at = ctr + vec3<f32>(0.0, 0.12 + 0.06 * sin(time * 2.6 + phase), 0.0);
		}
		let r = tb_rot_y(turn);
		let rt = transpose(r);
		if (id >= TB_FIRST_ITEM) {
			// An item: its picture as a thin slab, standing, turning.
			let sc = half * 3.0;
			let hitp = tb_item_slab(id, rt * (ro - at) / sc, rt * rd / sc);
			if (hitp.w > 0.0 && hitp.w < best.t) {
				best = TbHit(hitp.w, vec3<f32>(0.0, 0.0, 1.0), hitp.rgb * 0.95);
			}
			continue;
		}
		let h = vec3<f32>(half);
		let hit = tb_box(rt * (ro - at), rt * rd, h);
		if (hit.w > 0.0 && hit.w < best.t) {
			let p = rt * (ro - at) + rt * rd * hit.w;
			let f = tb_box_uv(p, hit.xyz, h);
			var uv = f.xy;
			if (half < 0.06) {
				// A bit of a broken block: a few pixels of its face, its own,
				// in squares (4 by 4 of a 16th each).
				let corner = floor(vec2<f32>(tb_h(vec2<f32>(f32(k), 1.0), 50.0), tb_h(vec2<f32>(f32(k), 2.0), 51.0)) * 12.0);
				uv = (corner + floor(uv * 4.0) + vec2<f32>(0.5)) / 16.0;
			}
			let tx = tb_tex(id, i32(f.z), uv, vec3<f32>(f32(id) * 3.0, 7.0, 1.0), time);
			let nw = r * hit.xyz;
			best = TbHit(hit.w, nw, tx.rgb * (0.15 + 0.85 * tb_light_n(nw)));
		}
	}
	return best;
}

// Mobs, painted in a row at y 97 from x 384, four points each:
//   0, 1: where it stands, as an entity's (tb_ent_px);
//   2: (kind * 32: 1 a chicken, 2 a pig, 3 a sheep; its facing in 64ths
//      of a circle * 4; its legs' swing, -1..1 as 0..63, * 4) / 255;
//   3: (hurt: 252 while it flashes red; its head's tilt, -0.8..0.8 as
//      0..63, * 4; 0) / 255.
fn tb_mob_px(k: i32, j: i32) -> vec4<f32> {
	return zgx_sample(vec2<f32>(384.5 + f32(k * 4 + j), 97.5)) * 255.0;
}

struct TbPart {
	pivot: vec3<f32>,
	off: vec3<f32>,
	h: vec3<f32>,
	// 0 still, 1 or -1 a leg (its swing's sign), 2 the head
	moves: f32,
	kind: i32,
}

// A mob's parts, in sixteenths of a block from its feet (x right, y up, z
// back; it faces -z). A part with no size is none.
fn tb_mob_part(t: i32, i: i32) -> TbPart {
	var q = TbPart(vec3<f32>(0.0), vec3<f32>(0.0), vec3<f32>(0.0), 0.0, 0);
	if (t == 2) {
		// pig
		switch (i) {
			case 0: { q = TbPart(vec3<f32>(0.0, 10.0, 1.0), vec3<f32>(0.0), vec3<f32>(5.0, 4.0, 8.0), 0.0, 0); }
			case 1: { q = TbPart(vec3<f32>(0.0, 12.0, -7.0), vec3<f32>(0.0, 0.0, -4.0), vec3<f32>(4.0, 4.0, 4.0), 2.0, 1); }
			case 2: { q = TbPart(vec3<f32>(0.0, 12.0, -7.0), vec3<f32>(0.0, -1.5, -8.5), vec3<f32>(2.0, 1.5, 0.5), 2.0, 2); }
			case 3: { q = TbPart(vec3<f32>(-3.0, 6.0, -5.0), vec3<f32>(0.0, -3.0, 0.0), vec3<f32>(2.0, 3.0, 2.0), 1.0, 3); }
			case 4: { q = TbPart(vec3<f32>(3.0, 6.0, -5.0), vec3<f32>(0.0, -3.0, 0.0), vec3<f32>(2.0, 3.0, 2.0), -1.0, 3); }
			case 5: { q = TbPart(vec3<f32>(-3.0, 6.0, 7.0), vec3<f32>(0.0, -3.0, 0.0), vec3<f32>(2.0, 3.0, 2.0), -1.0, 3); }
			case 6: { q = TbPart(vec3<f32>(3.0, 6.0, 7.0), vec3<f32>(0.0, -3.0, 0.0), vec3<f32>(2.0, 3.0, 2.0), 1.0, 3); }
			default: {}
		}
	} else if (t == 3) {
		// sheep
		switch (i) {
			case 0: { q = TbPart(vec3<f32>(0.0, 17.0, 1.0), vec3<f32>(0.0), vec3<f32>(5.0, 5.0, 9.0), 0.0, 10); }
			case 1: { q = TbPart(vec3<f32>(0.0, 19.0, -7.0), vec3<f32>(0.0, 0.0, -4.0), vec3<f32>(3.0, 3.0, 4.0), 2.0, 11); }
			case 2: { q = TbPart(vec3<f32>(-3.0, 12.0, -5.0), vec3<f32>(0.0, -6.0, 0.0), vec3<f32>(2.0, 6.0, 2.0), 1.0, 12); }
			case 3: { q = TbPart(vec3<f32>(3.0, 12.0, -5.0), vec3<f32>(0.0, -6.0, 0.0), vec3<f32>(2.0, 6.0, 2.0), -1.0, 12); }
			case 4: { q = TbPart(vec3<f32>(-3.0, 12.0, 7.0), vec3<f32>(0.0, -6.0, 0.0), vec3<f32>(2.0, 6.0, 2.0), -1.0, 12); }
			case 5: { q = TbPart(vec3<f32>(3.0, 12.0, 7.0), vec3<f32>(0.0, -6.0, 0.0), vec3<f32>(2.0, 6.0, 2.0), 1.0, 12); }
			default: {}
		}
	} else {
		// chicken
		switch (i) {
			case 0: { q = TbPart(vec3<f32>(0.0, 8.0, 1.0), vec3<f32>(0.0), vec3<f32>(3.0, 3.0, 4.0), 0.0, 20); }
			case 1: { q = TbPart(vec3<f32>(0.0, 9.0, -3.0), vec3<f32>(0.0, 3.0, -1.5), vec3<f32>(2.0, 3.0, 1.5), 2.0, 21); }
			case 2: { q = TbPart(vec3<f32>(0.0, 9.0, -3.0), vec3<f32>(0.0, 4.0, -4.0), vec3<f32>(2.0, 1.0, 1.0), 2.0, 22); }
			case 3: { q = TbPart(vec3<f32>(0.0, 9.0, -3.0), vec3<f32>(0.0, 2.0, -3.5), vec3<f32>(1.0, 1.0, 0.5), 2.0, 23); }
			case 4: { q = TbPart(vec3<f32>(-1.5, 5.0, 1.0), vec3<f32>(0.0, -2.5, 0.0), vec3<f32>(0.5, 2.5, 0.5), 1.0, 24); }
			case 5: { q = TbPart(vec3<f32>(1.5, 5.0, 1.0), vec3<f32>(0.0, -2.5, 0.0), vec3<f32>(0.5, 2.5, 0.5), -1.0, 24); }
			case 6: { q = TbPart(vec3<f32>(-3.5, 9.0, 1.0), vec3<f32>(0.0), vec3<f32>(0.5, 2.0, 3.0), 0.0, 25); }
			case 7: { q = TbPart(vec3<f32>(3.5, 9.0, 1.0), vec3<f32>(0.0), vec3<f32>(0.5, 2.0, 3.0), 0.0, 25); }
			default: {}
		}
	}
	return q;
}

// A part's colour at `q` (0..1 across it: x right, y up, z back), seen on
// its face with normal `n` (its own frame).
fn tb_mob_col(kind: i32, q: vec3<f32>, n: vec3<f32>) -> vec3<f32> {
	let front = n.z < -0.5;
	switch (kind) {
		case 0: { return vec3<f32>(0.94, 0.66, 0.66) * (0.97 + 0.03 * sin(q.z * 17.0)); }
		case 1: {
			if (front && q.y > 0.5 && q.y < 0.72) {
				let ex = abs(q.x - 0.5);
				if (ex > 0.24 && ex < 0.44) {
					return select(vec3<f32>(0.08), vec3<f32>(0.98), ex > 0.34);
				}
			}
			return vec3<f32>(0.94, 0.66, 0.66);
		}
		case 2: {
			if (front && q.y > 0.3 && q.y < 0.7 && abs(abs(q.x - 0.5) - 0.24) < 0.1) {
				return vec3<f32>(0.55, 0.30, 0.32);
			}
			return vec3<f32>(0.88, 0.55, 0.57);
		}
		case 3: { return select(vec3<f32>(0.90, 0.62, 0.62), vec3<f32>(0.62, 0.42, 0.40), q.y < 0.2); }
		case 10: {
			let n2 = sin(q.x * 31.0) * sin(q.y * 23.0) * sin(q.z * 29.0);
			return vec3<f32>(0.93, 0.93, 0.90) * (0.94 + 0.06 * n2);
		}
		case 11: {
			// a wool cap over a tan face
			if (q.y > 0.72 || (!front && q.z > 0.55 && q.y > 0.4)) { return vec3<f32>(0.92, 0.92, 0.89); }
			if (front && q.y > 0.42 && q.y < 0.6) {
				let ex = abs(q.x - 0.5);
				if (ex > 0.18 && ex < 0.42) {
					return select(vec3<f32>(0.10), vec3<f32>(0.96), ex > 0.31);
				}
			}
			return vec3<f32>(0.78, 0.66, 0.56);
		}
		case 12: { return select(vec3<f32>(0.78, 0.66, 0.56), vec3<f32>(0.92, 0.92, 0.89), q.y > 0.62); }
		case 20: { return vec3<f32>(0.97, 0.97, 0.95); }
		case 21: {
			if (front && q.y > 0.55 && q.y < 0.75 && abs(q.x - 0.5) > 0.28) { return vec3<f32>(0.08); }
			return vec3<f32>(0.97, 0.97, 0.95);
		}
		case 22: { return vec3<f32>(0.96, 0.66, 0.18); }
		case 23: { return vec3<f32>(0.86, 0.12, 0.10); }
		case 24: { return vec3<f32>(0.95, 0.70, 0.20); }
		case 25: { return vec3<f32>(0.90, 0.90, 0.88); }
		default: { return vec3<f32>(1.0, 0.0, 1.0); }
	}
}

fn tb_mobs(ro: vec3<f32>, rd: vec3<f32>, count: i32, far: f32) -> TbHit {
	var best = TbHit(far, vec3<f32>(0.0), vec3<f32>(0.0));
	for (var k = 0; k < count; k = k + 1) {
		let a = tb_mob_px(k, 0);
		let b = tb_mob_px(k, 1);
		let feet = vec3<f32>(round(a.x / 2.0), round(a.y / 4.0), round(a.z / 2.0)) + vec3<f32>(round(b.x / 4.0), round(b.y / 4.0), round(b.z / 4.0)) / 64.0;
		let oc = feet + vec3<f32>(0.0, 0.6, 0.0) - ro;
		let along = dot(oc, rd);
		if (along < -1.0 || along > best.t + 1.5 || dot(oc, oc) - along * along > 1.3) {
			continue;
		}
		let c = tb_mob_px(k, 2);
		let d3 = tb_mob_px(k, 3);
		let t = i32(round(c.x / 32.0));
		let yaw = round(c.y / 4.0) / 64.0 * 6.2832;
		let limb = round(c.z / 4.0) / 63.0 * 2.0 - 1.0;
		let hurt = d3.x > 128.0;
		let tilt = (round(d3.y / 4.0) / 63.0 * 2.0 - 1.0) * 0.8;
		let body = tb_rot_y(yaw);
		let P = 0.0625;
		for (var i = 0; i < 8; i = i + 1) {
			let q = tb_mob_part(t, i);
			if (q.h.x <= 0.0) {
				continue;
			}
			var r = body;
			if (q.moves == 2.0) {
				r = body * tb_rot_x(tilt);
			} else if (q.moves != 0.0) {
				r = body * tb_rot_x(limb * 0.75 * q.moves);
			}
			let pw = feet + body * (q.pivot * P);
			let h = q.h * P;
			let off = q.off * P;
			let hit = tb_part(ro, rd, pw, r, off, h);
			if (hit.w > 0.0 && hit.w < best.t) {
				let rt = transpose(r);
				let p = rt * (ro - pw) - off + rt * rd * hit.w;
				let qq = clamp(p / h * 0.5 + vec3<f32>(0.5), vec3<f32>(0.0), vec3<f32>(1.0));
				var col = tb_mob_col(q.kind, qq, hit.xyz);
				if (hurt) {
					col = mix(col, vec3<f32>(1.0, 0.15, 0.1), 0.5);
				}
				let nw = r * hit.xyz;
				best = TbHit(hit.w, nw, col * (0.2 + 0.8 * tb_light_n(nw)));
			}
		}
	}
	return best;
}

// One part of a body: a box of half size `h` whose middle is `off` from
// `pivot` in the part's frame, turned by `r` about the pivot.
fn tb_part(ro: vec3<f32>, rd: vec3<f32>, pivot: vec3<f32>, r: mat3x3<f32>, off: vec3<f32>, h: vec3<f32>) -> vec4<f32> {
	let rt = transpose(r);
	let o = rt * (ro - pivot) - off;
	return tb_box(o, rt * rd, h);
}

const TB_PX: f32 = 0.05625; // a body's "pixel": 32 to its 1.8 blocks

const TB_SKIN: vec3<f32> = vec3<f32>(0.86, 0.66, 0.50);
const TB_HAIR: vec3<f32> = vec3<f32>(0.20, 0.13, 0.10);
const TB_TOP: vec3<f32> = vec3<f32>(0.55, 0.42, 0.95);
const TB_PANTS: vec3<f32> = vec3<f32>(0.24, 0.25, 0.31);
const TB_SHOE: vec3<f32> = vec3<f32>(0.90, 0.90, 0.88);

// The player, seen from behind them (third person): feet at `feet`, facing
// `yaw`, the head turned up by `pitch`; `limb` the legs' swing, `swing` the
// arm's (0..1), `held` the block in hand (0 none).
fn tb_player(ro: vec3<f32>, rd: vec3<f32>, feet: vec3<f32>, yaw: f32, pitch: f32, limb: f32, swing: f32, held: i32, far: f32, time: f32) -> TbHit {
	var best = TbHit(far, vec3<f32>(0.0), vec3<f32>(0.0));
	// (A quick miss: the ray passes well clear of the body.)
	let mid = feet + vec3<f32>(0.0, 0.9, 0.0);
	let oc = mid - ro;
	let along = dot(oc, rd);
	if (along < 0.0 || dot(oc, oc) - along * along > 1.2) {
		return best;
	}
	let body = tb_rot_y(yaw);
	let P = TB_PX;
	let arm = sin(sqrt(swing) * 3.1416);
	for (var i = 0; i < 7; i = i + 1) {
		var pivot = vec3<f32>(0.0);
		var r = body;
		var off = vec3<f32>(0.0);
		var h = vec3<f32>(2.0, 6.0, 2.0) * P;
		if (i == 0) {
			// head
			pivot = vec3<f32>(0.0, 24.0, 0.0);
			r = body * tb_rot_x(pitch);
			off = vec3<f32>(0.0, 4.0, 0.0) * P;
			h = vec3<f32>(4.0, 4.0, 4.0) * P;
		} else if (i == 1) {
			// body
			pivot = vec3<f32>(0.0, 18.0, 0.0);
			h = vec3<f32>(4.0, 6.0, 2.0) * P;
		} else if (i == 2 || i == 3) {
			// legs
			let s = select(-1.0, 1.0, i == 2);
			pivot = vec3<f32>(2.0 * s, 12.0, 0.0);
			r = body * tb_rot_x(limb * s);
			off = vec3<f32>(0.0, -6.0, 0.0) * P;
		} else if (i == 4 || i == 5) {
			// arms (4 the right)
			let s = select(-1.0, 1.0, i == 4);
			pivot = vec3<f32>(6.0 * s, 22.0, 0.0);
			var a = -limb * s * 0.8;
			if (i == 4) {
				a = a + arm * 1.3 + select(0.0, 0.3, held > 0);
			}
			r = body * tb_rot_x(a) * tb_rot_z(s * 0.06);
			off = vec3<f32>(0.0, -4.0, 0.0) * P;
		} else {
			// the block in the right hand
			if (held <= 0 || held >= TB_FIRST_ITEM) {
				break;
			}
			pivot = vec3<f32>(6.0, 22.0, 0.0);
			r = body * tb_rot_x(-limb * 0.8 + arm * 1.3 + 0.3);
			off = vec3<f32>(0.0, -10.5, -3.0) * P;
			h = vec3<f32>(2.6) * P;
		}
		let pw = feet + body * (vec3<f32>(pivot.x, 0.0, pivot.z) * P) + vec3<f32>(0.0, pivot.y * P, 0.0);
		let hit = tb_part(ro, rd, pw, r, off, h);
		if (hit.w > 0.0 && hit.w < best.t) {
			let rt = transpose(r);
			let p = rt * (ro - pw) - off + rt * rd * hit.w;
			let q = p / h * 0.5 + vec3<f32>(0.5); // 0..1 across the part, y up, z back
			let n = hit.xyz;
			var col = TB_TOP;
			if (i == 0) {
				col = TB_SKIN;
				let front = n.z < -0.5;
				let top = n.y > 0.5;
				if (top || n.z > 0.5 || q.y > 0.72 || (!front && q.y > 0.45)) {
					col = TB_HAIR;
				}
				if (front && q.y > 0.36 && q.y < 0.5) {
					// eyes: white, then the iris inside
					let ex = abs(q.x - 0.5);
					if (ex > 0.13 && ex < 0.33) {
						col = vec3<f32>(0.96);
						if (ex > 0.13 && ex < 0.22) {
							col = vec3<f32>(0.23, 0.30, 0.55);
						}
					}
				}
				if (front && q.y > 0.18 && q.y < 0.24 && abs(q.x - 0.5) < 0.12) {
					col = TB_SKIN * 0.72;
				}
			} else if (i == 1) {
				col = TB_TOP;
				if (n.z < -0.5 && abs(q.x - 0.5) < 0.05) {
					col = TB_TOP * 1.18;
				}
				if (q.y < 0.12) {
					col = TB_TOP * 0.82;
				}
			} else if (i == 2 || i == 3) {
				col = select(TB_PANTS, TB_SHOE, q.y < 0.17);
			} else if (i == 4 || i == 5) {
				col = select(TB_TOP, TB_SKIN, q.y < 0.33);
			} else {
				let f = tb_box_uv(p, n, h);
				col = tb_tex(held, i32(f.z), f.xy, vec3<f32>(1.0), time).rgb;
			}
			let nw = r * n;
			best = TbHit(hit.w, nw, col * (0.2 + 0.8 * tb_light_n(nw)));
		}
	}
	return best;
}

// Rotations the way Minecraft's are written (right-handed, degrees).
fn mc_rx(deg: f32) -> mat3x3<f32> {
	let a = radians(deg);
	let c = cos(a);
	let s = sin(a);
	return mat3x3<f32>(vec3<f32>(1.0, 0.0, 0.0), vec3<f32>(0.0, c, s), vec3<f32>(0.0, -s, c));
}

fn mc_ry(deg: f32) -> mat3x3<f32> {
	let a = radians(deg);
	let c = cos(a);
	let s = sin(a);
	return mat3x3<f32>(vec3<f32>(c, 0.0, -s), vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(s, 0.0, c));
}

fn mc_rz(deg: f32) -> mat3x3<f32> {
	let a = radians(deg);
	let c = cos(a);
	let s = sin(a);
	return mat3x3<f32>(vec3<f32>(c, s, 0.0), vec3<f32>(-s, c, 0.0), vec3<f32>(0.0, 0.0, 1.0));
}

// The hand in first person, posed and swung as Minecraft does it
// (ItemInHandRenderer: the arm's place, its attack swing, then the held
// thing's own first-person display transform), in Minecraft's camera frame
// (x right, y up, z back). `d`: the ray, from the eye. `held`: the block or
// item (0 the bare arm). `swing` 0..1. `limb`: the walk's sway. xyz its
// colour, w 1 where it is.
fn tb_hand(dc: vec3<f32>, held: i32, swing: f32, limb: f32, time: f32) -> vec4<f32> {
	let d = vec3<f32>(dc.x, dc.y, -dc.z);
	let s = swing;
	let sq = sqrt(s);
	let bob = vec3<f32>(limb * 0.025, -abs(limb) * 0.025, 0.0);
	if (held <= 0) {
		// The bare arm (renderPlayerArm).
		let t0 = vec3<f32>(-0.3 * sin(sq * 3.1416) + 0.64, 0.4 * sin(sq * 6.2832) - 0.6, -0.4 * sin(s * 3.1416) - 0.72) + bob;
		let f4 = sin(s * s * 3.1416);
		let f5 = sin(sq * 3.1416);
		let r1 = mc_ry(45.0) * mc_ry(f5 * 70.0) * mc_rz(f4 * -20.0);
		let r2 = mc_rz(120.0) * mc_rx(200.0) * mc_ry(-135.0);
		// p = t0 + r1 * (T(-1, 3.6, 3.5) + r2 * (T(5.6, 0, 0) + q)): q in the
		// arm's model (its box, pixels / 16).
		let r = r1 * r2;
		let rt = transpose(r);
		let off = t0 + r1 * vec3<f32>(-1.0, 3.6, 3.5) + r * vec3<f32>(5.6, 0.0, 0.0);
		let o = rt * (-off);
		let dd = rt * d;
		let lo = vec3<f32>(-8.0, 0.0, -2.0) / 16.0;
		let hi = vec3<f32>(-4.0, 12.0, 2.0) / 16.0;
		let mid = (lo + hi) * 0.5;
		let hit = tb_box(o - mid, dd, (hi - lo) * 0.5);
		if (hit.w <= 0.0) {
			return vec4<f32>(0.0);
		}
		let p = o + dd * hit.w;
		// (y runs down the arm in its model: the hand at the far end)
		let col = select(TB_TOP, TB_SKIN, p.y > 8.0 / 16.0);
		let nw = r * hit.xyz;
		let l = 0.62 + 0.38 * clamp(dot(nw, normalize(vec3<f32>(0.2, 1.0, 0.6))), 0.0, 1.0);
		return vec4<f32>(col * l, 1.0);
	}
	// Holding something (renderArmWithItem): the swing's sweep, the hand's
	// place, the attack's turn.
	let t0 = vec3<f32>(-0.4 * sin(sq * 3.1416) + 0.56, 0.2 * sin(sq * 6.2832) - 0.52, -0.2 * sin(s * 3.1416) - 0.72) + bob;
	let fa = sin(s * s * 3.1416);
	let fb = sin(sq * 3.1416);
	// (Minecraft's chop is 80 degrees, and its tool turns edge-on through
	// most of the swing; 65 here, with the tool's face turned 30 degrees
	// more to the eye below, keeps it in view all the way.)
	let chop = select(-80.0, -65.0, held >= TB_FIRST_ITEM);
	let ra = mc_ry(45.0 + fa * -20.0) * mc_rz(fb * -20.0) * mc_rx(fb * chop) * mc_ry(-45.0);
	// The held thing's own first-person transform: a block (block.json)
	// small and turned 45 degrees; a tool (item/handheld.json) up, its
	// head ahead.
	var rd = mc_ry(45.0);
	var td = vec3<f32>(0.0);
	var sc = 0.4;
	if (held >= TB_FIRST_ITEM) {
		rd = mc_rx(0.0) * mc_ry(-62.0) * mc_rz(25.0);
		td = vec3<f32>(1.13, 3.2, 1.13) / 16.0;
		sc = 0.68;
	}
	// p = t0 + ra * (td + rd * (sc * q)), q in the thing's model.
	let r = ra * rd;
	let rt = transpose(r);
	let o = transpose(rd) * (transpose(ra) * (-t0) - td) / sc;
	let dd = rt * d / sc;
	if (held >= TB_FIRST_ITEM) {
		let it = tb_item_slab(held, o, dd);
		if (it.w <= 0.0) {
			return vec4<f32>(0.0);
		}
		return vec4<f32>(it.rgb, 1.0);
	}
	let hit = tb_box(o, dd, vec3<f32>(0.5));
	if (hit.w <= 0.0) {
		return vec4<f32>(0.0);
	}
	let p = o + dd * hit.w;
	let f = tb_box_uv(p, hit.xyz, vec3<f32>(0.5));
	let tx = tb_tex(held, i32(f.z), f.xy, vec3<f32>(2.0), time);
	let nw = r * hit.xyz;
	// (Minecraft's flat item light: the top brightest, one side a little
	// less, the other least)
	var l = 0.62;
	if (nw.y > 0.5) {
		l = 1.0;
	} else if (nw.z > 0.3) {
		l = 0.82;
	}
	return vec4<f32>(tx.rgb * l, 1.0);
}

fn layer(input: LayerInput) -> vec4<f32> {
	let P0 = input.params[0];
	let P1 = input.params[1];
	let P2 = input.params[2];
	let P3 = input.params[3];
	let ro = P0.xyz;
	let yaw = P0.w;
	let pitch = P1.x;
	let time = P1.y;
	let flags = u32(round(P1.z));
	let under = (flags & 1u) != 0u;
	let ready = (flags & 2u) != 0u;
	let fov = max(f32(flags >> 2u), 30.0);
	let broken = P1.w;
	if (!ready) {
		return vec4<f32>(0.40, 0.60, 0.98, 1.0);
	}
	let tgt = vec3<i32>(i32(round(P2.x)), i32(round(P2.y)), i32(round(P2.z)));
	let has_target = P2.x >= 0.0;
	let held = i32(round(P2.w));
	let swing = P3.x;
	let limb = P3.y;
	let tp = P3.z;
	// (entities, and mobs * 64)
	let ents = i32(round(P3.w)) % 64;
	let mobs = i32(round(P3.w)) / 64;

	let fw = vec3<f32>(cos(pitch) * sin(yaw), sin(pitch), -cos(pitch) * cos(yaw));
	let rt = vec3<f32>(cos(yaw), 0.0, sin(yaw));
	let upv = cross(rt, fw);
	let uv = (input.p - input.size * 0.5) / (input.size.y * 0.5);
	let th = tan(fov * 0.5 * 3.1416 / 180.0);
	let rd = normalize(fw + rt * uv.x * th - upv * uv.y * th);

	let rdn = rd + select(vec3<f32>(0.0), vec3<f32>(1e-6), abs(rd) < vec3<f32>(1e-6));
	let inv = 1.0 / rdn;
	let t0s = (vec3<f32>(0.0) - ro) * inv;
	let t1s = (vec3<f32>(f32(TB_WX), f32(TB_WY), f32(TB_WZ)) - ro) * inv;
	let tmin = min(t0s, t1s);
	let tmax = max(t0s, t1s);
	let tn = max(max(tmin.x, tmin.y), tmin.z);
	let tf = min(min(tmax.x, tmax.y), tmax.z);

	var hit = false;
	var hit_t = 1e9;
	var hit_id = 0;
	var hit_cell = vec3<i32>(0);
	var hit_n = vec3<f32>(0.0, 1.0, 0.0);
	var hit_tex = vec3<f32>(0.0);
	var water_t = -1.0;
	var water_len = 0.0;

	if (tf > max(tn, 0.0)) {
		var t = max(tn, 0.0) + 1e-4;
		let p0 = ro + rd * t;
		var cell = clamp(vec3<i32>(floor(p0)), vec3<i32>(0), vec3<i32>(TB_WX - 1, TB_WY - 1, TB_WZ - 1));
		let stp = select(vec3<i32>(-1), vec3<i32>(1), rd > vec3<f32>(0.0));
		let tdelta = abs(inv);
		var tmx = (vec3<f32>(cell) + select(vec3<f32>(0.0), vec3<f32>(1.0), rd > vec3<f32>(0.0)) - ro) * inv;
		var n = vec3<f32>(0.0);
		if (tn > 0.0) {
			if (tn == tmin.x) {
				n = vec3<f32>(-f32(stp.x), 0.0, 0.0);
			} else if (tn == tmin.y) {
				n = vec3<f32>(0.0, -f32(stp.y), 0.0);
			} else {
				n = vec3<f32>(0.0, 0.0, -f32(stp.z));
			}
		}
		var prev = -1;
		for (var i = 0; i < 260; i = i + 1) {
			let id = tb_block(cell);
			if (id == TB_WATERB) {
				if (water_t < 0.0 && prev != TB_WATERB) {
					water_t = t;
				}
			} else if (id != TB_AIR) {
				if (!(id == TB_GLASS && prev == TB_GLASS)) {
					let hp = ro + rd * t;
					let lc = clamp(hp - vec3<f32>(cell), vec3<f32>(0.0), vec3<f32>(0.9999));
					var face = 2;
					var fuv = vec2<f32>(lc.x, 1.0 - lc.y);
					if (n.y > 0.5) {
						face = 0;
						fuv = lc.xz;
					} else if (n.y < -0.5) {
						face = 1;
						fuv = lc.xz;
					} else if (abs(n.x) > 0.5) {
						fuv = vec2<f32>(lc.z, 1.0 - lc.y);
					}
					if (dot(n, n) < 0.5) {
						face = 0;
						fuv = lc.xz;
					}
					let tx = tb_tex(id, face, fuv, vec3<f32>(cell), time);
					if (tx.a > 0.5) {
						hit = true;
						hit_t = t;
						hit_id = id;
						hit_cell = cell;
						hit_n = n;
						hit_tex = tx.rgb;
						break;
					}
				}
			}
			prev = id;
			var tnext = 0.0;
			if (tmx.x < tmx.y && tmx.x < tmx.z) {
				cell.x = cell.x + stp.x;
				tnext = tmx.x;
				tmx.x = tmx.x + tdelta.x;
				n = vec3<f32>(-f32(stp.x), 0.0, 0.0);
			} else if (tmx.y < tmx.z) {
				cell.y = cell.y + stp.y;
				tnext = tmx.y;
				tmx.y = tmx.y + tdelta.y;
				n = vec3<f32>(0.0, -f32(stp.y), 0.0);
			} else {
				cell.z = cell.z + stp.z;
				tnext = tmx.z;
				tmx.z = tmx.z + tdelta.z;
				n = vec3<f32>(0.0, 0.0, -f32(stp.z));
			}
			if (id == TB_WATERB) {
				water_len = water_len + (tnext - t);
			}
			t = tnext;
			if (cell.x < 0 || cell.y < 0 || cell.z < 0 || cell.x >= TB_WX || cell.y >= TB_WY || cell.z >= TB_WZ) {
				break;
			}
		}
	}

	let horizon = vec3<f32>(0.71, 0.83, 1.0);
	var col = vec3<f32>(0.0);
	var dist = hit_t;
	if (hit) {
		var light = tb_face_light(hit_n);
		let ni = vec3<i32>(round(hit_n));
		let a = hit_cell + ni;
		let hp = ro + rd * hit_t;
		let lc = clamp(hp - vec3<f32>(hit_cell), vec3<f32>(0.0), vec3<f32>(1.0));
		var ua = vec3<i32>(1, 0, 0);
		var va = vec3<i32>(0, 1, 0);
		var fc = lc.xy;
		if (ni.y != 0) {
			va = vec3<i32>(0, 0, 1);
			fc = lc.xz;
		} else if (ni.x != 0) {
			ua = vec3<i32>(0, 0, 1);
			fc = lc.zy;
		}
		let sxm = tb_solid(a - ua);
		let sxp = tb_solid(a + ua);
		let svm = tb_solid(a - va);
		let svp = tb_solid(a + va);
		let a00 = tb_vao(sxm, svm, tb_solid(a - ua - va));
		let a10 = tb_vao(sxp, svm, tb_solid(a + ua - va));
		let a01 = tb_vao(sxm, svp, tb_solid(a - ua + va));
		let a11 = tb_vao(sxp, svp, tb_solid(a + ua + va));
		let ao = mix(mix(a00, a10, fc.x), mix(a01, a11, fc.x), fc.y) / 3.0;
		light = light * (0.42 + 0.58 * ao);
		if (a.x >= 0 && a.z >= 0 && a.x < TB_WX && a.z < TB_WZ && a.y >= 0) {
			let hs = tb_hm(a.x, a.z);
			if (a.y < hs.x) {
				light = light * 0.55;
			}
		}
		col = hit_tex * light;
		// The block being broken: cracks, stage by stage.
		if (has_target && broken > 0.0 && all(hit_cell == tgt)) {
			let stage = min(floor(broken * 10.0) + 1.0, 10.0);
			let seed = f32((hit_cell.x * 7 + hit_cell.y * 13 + hit_cell.z * 3) % 97) + dot(hit_n, vec3<f32>(1.0, 2.0, 3.0)) * 5.0;
			// In pixels, 16 to a face: each pixel a crack runs through goes dark,
			// a few near them lighter, as chipped.
			let cell = floor(fc * 16.0);
			let pc = (cell + vec2<f32>(0.5)) / 16.0;
			let d = tb_crack(pc, stage, seed);
			if (d < 0.034) {
				col = col * select(0.34, 0.24, tb_h(cell, seed + 61.0) > 0.5);
			} else if (d < 0.066 && tb_h(cell, seed + 62.0) > 0.72) {
				col = col * 0.62;
			}
			col = col * (1.0 - 0.012 * stage);
		}
	} else if (rd.y < -0.0001 && ro.y > f32(TB_WATER) + 1.0) {
		// Past the island: the open sea.
		let ts = (f32(TB_WATER) + 1.0 - ro.y) / rd.y;
		dist = ts;
		if (water_t < 0.0) {
			water_t = ts;
		}
		// The same seabed as the island's edge: gravel, its top at y = 11.
		col = vec3<f32>(0.53, 0.50, 0.48);
		hit = true;
		water_len = (f32(TB_WATER) + 1.0 - 11.0) / max(-rd.y, 1e-4);
	} else {
		col = tb_sky(ro, rd, time);
		dist = 1e9;
	}

	// Dropped blocks and bits, and the player seen from behind: nearer than
	// the world or not.
	var near = dist;
	if (ents > 0) {
		let e = tb_entities(ro, rd, ents, near, time);
		if (e.t < near) {
			near = e.t;
			col = e.col;
		}
	}
	if (mobs > 0) {
		let e = tb_mobs(ro, rd, mobs, near);
		if (e.t < near) {
			near = e.t;
			col = e.col;
		}
	}
	if (tp > 0.0) {
		let eye = ro + fw * tp;
		let crouch = fract(P2.w) > 0.25;
		let feet = eye - vec3<f32>(0.0, select(1.62, 1.32, crouch), 0.0);
		let e = tb_player(ro, rd, feet, yaw, pitch, limb, swing, i32(floor(P2.w)), near, time);
		if (e.t < near) {
			near = e.t;
			col = e.col;
		}
	}
	if (near < dist) {
		if (water_t >= 0.0 && water_t < near) {
			water_len = near - water_t;
		} else {
			water_t = -1.0;
		}
		dist = near;
		hit = true;
	}

	if (water_t >= 0.0 && !under) {
		let wp = ro + rd * water_t;
		let wt = tb_tex(TB_WATERB, 0, fract(wp.xz), floor(wp), time);
		let depth = select(water_len, 30.0, !hit);
		let a = clamp(0.45 + depth * 0.10, 0.0, 0.88);
		col = mix(col, wt.rgb, a);
		let fres = pow(1.0 - clamp(-rd.y, 0.0, 1.0), 4.0);
		col = mix(col, tb_sky(wp, reflect(rd, vec3<f32>(0.0, 1.0, 0.0)), time), 0.35 * fres);
		dist = min(dist, water_t);
	}

	if (under) {
		let k = clamp(0.25 + min(dist, 40.0) / 22.0, 0.0, 0.95);
		col = mix(col, vec3<f32>(0.07, 0.19, 0.48), k);
	} else if (dist < 1e8) {
		let fog = smoothstep(58.0, 120.0, dist);
		col = mix(col, horizon, fog);
	}

	// The hand, over everything, in first person (P2.w < 0: no hand).
	if (tp <= 0.0 && P2.w > -0.5) {
		let dc = normalize(vec3<f32>(uv.x * th, -uv.y * th, 1.0));
		let hd = tb_hand(dc, i32(floor(P2.w)), swing, limb, time);
		if (hd.w > 0.5) {
			col = select(hd.rgb, mix(hd.rgb, vec3<f32>(0.07, 0.19, 0.48), 0.35), under);
		}
	}
	return vec4<f32>(col, 1.0);
}
]]

local icon = common .. [[
fn tb_face_uv(q: vec2<f32>, o: vec2<f32>, e1: vec2<f32>, e2: vec2<f32>) -> vec2<f32> {
	let d = q - o;
	let det = e1.x * e2.y - e2.x * e1.y;
	return vec2<f32>((d.x * e2.y - e2.x * d.y) / det, (e1.x * d.y - d.x * e1.y) / det);
}

fn tb_in(u: vec2<f32>) -> bool {
	return u.x >= 0.0 && u.x < 1.0 && u.y >= 0.0 && u.y < 1.0;
}

fn fill(input: FillInput) -> vec4<f32> {
	let id = i32(input.params[0].x + 0.5);
	if (id >= TB_FIRST_ITEM) {
		// (Items show as their pictures: the slot's image, not this.)
		return vec4<f32>(0.0);
	}
	let s = min(input.size.x, input.size.y) * 0.40;
	let c = input.size * vec2<f32>(0.5, 0.5);
	let q = (input.p - c) / s;
	let k = 0.8660254;
	var face = -1;
	var u = tb_face_uv(q, vec2<f32>(0.0, -1.0), vec2<f32>(k, 0.5), vec2<f32>(-k, 0.5));
	if (tb_in(u)) {
		face = 0;
	} else {
		u = tb_face_uv(q, vec2<f32>(-k, -0.5), vec2<f32>(k, 0.5), vec2<f32>(0.0, 1.0));
		if (tb_in(u)) {
			face = 1;
		} else {
			u = tb_face_uv(q, vec2<f32>(0.0, 0.0), vec2<f32>(k, -0.5), vec2<f32>(0.0, 1.0));
			if (tb_in(u)) {
				face = 2;
			}
		}
	}
	if (face < 0) {
		return vec4<f32>(0.0);
	}
	let tf = select(2, 0, face == 0);
	let tx = tb_tex(id, tf, clamp(u, vec2<f32>(0.0), vec2<f32>(0.999)), vec3<f32>(0.0), 0.0);
	if (tx.a < 0.5) {
		return vec4<f32>(0.0);
	}
	var sh = 1.0;
	if (face == 1) { sh = 0.80; }
	if (face == 2) { sh = 0.62; }
	return vec4<f32>(tx.rgb * sh, 1.0);
}
]]

return { world = world, icon = icon }
