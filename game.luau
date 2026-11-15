--!nonstrict
-- Block World: the game. A component (`Game { store = …, play = … }`) that
-- fills its room with a first-person voxel world drawn by shaders.luau's
-- ray caster, and the screens around it (title, pause, options, controls).
--
-- The world (96 x 48 x 96 blocks, an island in an open sea) lives here as
-- a height map and a buffer of changed blocks; the shader reads the same
-- through data canvases painted inside its box (see shaders.luau's header
-- for the layout). Physics, raycasting and input run in a frame timer.
--
-- Survival: you start with nothing. Holding the mouse on a block cracks it
-- and breaks it (harder blocks take longer; stone needs a pickaxe to drop
-- anything); it drops as a small block that you pick up by walking to it.
-- Placing spends one from the selected hotbar stack. Logs make planks,
-- planks sticks and a crafting table, and at the table, wooden tools
-- (items.luau). Chickens, pigs and sheep wander the island (mobs.luau).
--
-- The mouse is held with the pointer lock while you play; the menus and
-- the inventory keep it and draw a cursor of their own (or use the
-- system's, when the pointer is free), and every menu also works from the
-- keyboard.
--
-- Sounds go through `props.play(name, volume)` (init.luau: macOS's afplay).

local shaders = require("./shaders")
local items = require("./items")
local mobsmod = require("./mobs")

local WX, WY, WZ, WATER = 96, 48, 96, 18
local DATA_W, DATA_H = 480, 384

local AIR, GRASS, DIRT, STONE, COBBLE, PLANKS, LOG, LEAVES, SAND, WATERB =
	items.AIR, items.GRASS, items.DIRT, items.STONE, items.COBBLE, items.PLANKS, items.LOG, items.LEAVES, items.SAND, items.WATER
local GLASS, BRICKS, BEDROCK, COAL, IRON, SNOW, GRAVEL, GOLD, WOOL, STONEBRICK, BOOKS =
	items.GLASS, items.BRICKS, items.BEDROCK, items.COAL, items.IRON, items.SNOW, items.GRAVEL, items.GOLD, items.WOOL, items.STONEBRICK, items.BOOKS
local CRAFT = items.CRAFT
local NAMES = items.NAMES

-- The sound each block makes (sounds/<name>1..3.wav).
local SOUND = {
	[GRASS] = "grass",
	[DIRT] = "dirt",
	[STONE] = "stone",
	[COBBLE] = "stone",
	[PLANKS] = "wood",
	[LOG] = "wood",
	[LEAVES] = "leaves",
	[SAND] = "sand",
	[GLASS] = "stone",
	[BRICKS] = "stone",
	[BEDROCK] = "stone",
	[COAL] = "stone",
	[IRON] = "stone",
	[SNOW] = "snow",
	[GRAVEL] = "gravel",
	[GOLD] = "stone",
	[WOOL] = "snow",
	[STONEBRICK] = "stone",
	[BOOKS] = "wood",
	[CRAFT] = "wood",
}

local SLOTS = 36 -- 1..9 the hotbar, 10..36 the inventory above it
local GRID0 = SLOTS -- 37..45 the crafting grid's cells (in rows)
local OUT = SLOTS + 10 -- 46 what the grid makes
local MAX_ENTS = 32 -- dropped blocks and bits the shader draws at once
local MAX_MOBS = 12 -- animals it draws at once (the nearest)
-- Bumped to start everyone's world afresh (a save from another epoch is
-- set aside; settings carry over).
local WORLD_EPOCH = 2

local SPLASHES = {
	"Inside Zeron!",
	"Now with water!",
	"100% blocks!",
	"Made with Luau!",
	"Mine it, place it!",
	"Soft bevels!",
	"Ray traced, sort of!",
	"Also try Pixels!",
}
local HW, PH, EYE = 0.3, 1.8, 1.62
local REACH = 6

local floor, abs, sqrt, min, max = math.floor, math.abs, math.sqrt, math.min, math.max
local readu8, writeu8 = buffer.readu8, buffer.writeu8

local function idx(x: number, y: number, z: number): number
	return (y * WZ + z) * WX + x
end

local function terrain(y: number, h: number, surf: number): number
	if y == 0 then
		return BEDROCK
	end
	if y > h then
		return if y <= WATER then WATERB else AIR
	end
	if y == h then
		if surf == 1 then
			return SAND
		elseif surf == 2 then
			return SNOW
		elseif surf == 3 then
			return GRAVEL
		end
		return GRASS
	end
	if y >= h - 3 then
		if surf == 1 then
			return SAND
		elseif surf == 3 then
			return GRAVEL
		end
		return DIRT
	end
	return STONE
end

-- xorshift32: the same world from the same seed, everywhere.
local function rng(seed: number)
	local s = bit32.bor(seed % 4294967296, 1)
	return function(): number
		s = bit32.bxor(s, bit32.lshift(s, 13))
		s = bit32.bxor(s, bit32.rshift(s, 17))
		s = bit32.bxor(s, bit32.lshift(s, 5))
		return s / 4294967296
	end
end

local function make_noise(rand)
	local perm, vals = {}, {}
	for i = 0, 255 do
		perm[i] = i
		vals[i] = rand()
	end
	for i = 255, 1, -1 do
		local j = floor(rand() * (i + 1))
		perm[i], perm[j] = perm[j], perm[i]
	end
	local function lattice(ix: number, iz: number): number
		return vals[perm[(perm[ix % 256] + iz) % 256]]
	end
	return function(x: number, z: number): number
		local ix, iz = floor(x), floor(z)
		local fx, fz = x - ix, z - iz
		local ux, uz = fx * fx * (3 - 2 * fx), fz * fz * (3 - 2 * fz)
		local a, b = lattice(ix, iz), lattice(ix + 1, iz)
		local c, d = lattice(ix, iz + 1), lattice(ix + 1, iz + 1)
		return a + (b - a) * ux + (c - a) * uz + (a - b - c + d) * ux * uz
	end
end

local function fbm(noise, x: number, z: number): number
	local s, a, f, norm = 0, 1, 1, 0
	for _ = 1, 4 do
		s += noise(x * f, z * f) * a
		norm += a
		a *= 0.5
		f *= 2.03
	end
	return s / norm
end

local function new_world(seed: number)
	return {
		seed = seed,
		height = buffer.create(WX * WZ),
		surf = buffer.create(WX * WZ),
		ovr = buffer.create(WX * WY * WZ),
		edits = {} :: { [number]: number },
		spawn = { WX / 2, 30, WZ / 2 },
	}
end

local function get_block(w, x: number, y: number, z: number): number
	if y < 0 then
		return BEDROCK
	end
	if y >= WY then
		return AIR
	end
	if x < 0 or z < 0 or x >= WX or z >= WZ then
		return if y <= WATER then WATERB else AIR
	end
	local o = readu8(w.ovr, idx(x, y, z))
	if o > 0 then
		return o - 1
	end
	local c = z * WX + x
	return terrain(y, readu8(w.height, c), readu8(w.surf, c))
end

local function set_raw(w, x: number, y: number, z: number, id: number)
	writeu8(w.ovr, idx(x, y, z), id + 1)
end

-- Builds the world a slice at a time: `yield` hands the frame back.
local function generate(w, yield: (number) -> ())
	local rand = rng(w.seed)
	local na, nb, nc = make_noise(rand), make_noise(rand), make_noise(rand)
	local half = WX / 2
	for z = 0, WZ - 1 do
		for x = 0, WX - 1 do
			local cx, cz = (x + 0.5 - half) / half, (z + 0.5 - half) / half
			local d = sqrt(cx * cx + cz * cz)
			local isl = math.clamp((d - 0.62) / 0.36, 0, 1)
			isl = isl * isl * (3 - 2 * isl)
			local base = fbm(na, x / 26, z / 26)
			local hills = fbm(nb, x / 13 + 50, z / 13 + 50)
			local mount = max(0, nc(x / 30, z / 30) - 0.5) * 2
			local h = 21 + (base - 0.5) * 16 + (hills - 0.5) * 5 + mount * mount * 24
			h = h * (1 - isl) + 10 * isl
			h = floor(math.clamp(h, 2, 40))
			local surf = 0
			if h >= 33 then
				surf = 2
			elseif h <= WATER + 1 then
				surf = if h < WATER - 3 then 3 else 1
			end
			local c = z * WX + x
			writeu8(w.height, c, h)
			writeu8(w.surf, c, surf)
		end
		yield(0.3 * z / WZ)
	end

	-- Trees: one at most in each 6 by 6 cell.
	for gz = 0, WZ - 1, 6 do
		for gx = 0, WX - 1, 6 do
			if rand() < 0.62 then
				local x = gx + 1 + floor(rand() * 4)
				local z = gz + 1 + floor(rand() * 4)
				if x >= 3 and z >= 3 and x < WX - 3 and z < WZ - 3 then
					local c = z * WX + x
					local h = readu8(w.height, c)
					if readu8(w.surf, c) == 0 and h > WATER + 1 and h < 32 then
						local top = h + 4 + floor(rand() * 3)
						set_raw(w, x, h, z, DIRT)
						for y = h + 1, top do
							set_raw(w, x, y, z, LOG)
						end
						for ly = top - 2, top + 1 do
							local r = if ly <= top - 1 then 2 else 1
							for dz = -r, r do
								for dx = -r, r do
									local corner = abs(dx) == r and abs(dz) == r
									local skip = corner and (ly == top + 1 or rand() < 0.5)
									if not skip and not (dx == 0 and dz == 0 and ly <= top) then
										if get_block(w, x + dx, ly, z + dz) == AIR then
											set_raw(w, x + dx, ly, z + dz, LEAVES)
										end
									end
								end
							end
						end
					end
				end
			end
		end
		yield(0.3 + 0.2 * gz / WZ)
	end

	-- Ores, in small clusters, deeper for the rarer ones.
	local dirs = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }
	for z = 0, WZ - 1 do
		for x = 0, WX - 1 do
			local h = readu8(w.height, z * WX + x)
			for y = 1, h - 4 do
				local r = rand()
				local ore = nil
				if r < 0.008 then
					ore = COAL
				elseif r < 0.0115 and y < 26 then
					ore = IRON
				elseif r < 0.0128 and y < 12 then
					ore = GOLD
				end
				if ore then
					set_raw(w, x, y, z, ore)
					for _ = 1, 1 + floor(rand() * 3) do
						local d = dirs[1 + floor(rand() * 6)]
						local ox, oy, oz = x + d[1], y + d[2], z + d[3]
						if get_block(w, ox, oy, oz) == STONE then
							set_raw(w, ox, oy, oz, ore)
						end
					end
				end
			end
		end
		yield(0.5 + 0.45 * z / WZ)
	end

	-- Where to stand: the dry ground nearest the middle.
	for r = 0, 40 do
		for dz = -r, r do
			for dx = -r, r do
				if max(abs(dx), abs(dz)) == r then
					local x, z = WX / 2 + dx, WZ / 2 + dz
					local c = z * WX + x
					local h = readu8(w.height, c)
					local open = h > WATER
					for y = h + 1, min(WY - 1, h + 9) do
						if get_block(w, x, y, z) ~= AIR then
							open = false
						end
					end
					if open then
						w.spawn = { x + 0.5, h + 1, z + 0.5 }
						return
					end
				end
			end
		end
	end
end

local function hex(r: number, g: number, b: number): string
	return string.format("#%02x%02x%02x", r, g, b)
end

local function clamp(v: number, a: number, b: number): number
	return if v < a then a elseif v > b then b else v
end

local function empty_inventory()
	local t = {}
	for i = 1, SLOTS do
		t[i] = 0
	end
	return t
end

-- Puts `n` of `id` into `list` (stacks of it first, then empty slots, the
-- hotbar before the rest); returns how many didn't fit.
-- `d`: a tool's wear left (tools stack one to a slot).
local function stow(list, id: number, n: number, from: number?, to: number?, d: number?): number
	from, to = from or 1, to or SLOTS
	local cap = items.max_stack(id)
	if cap > 1 then
		for i = from, to do
			local s = list[i]
			if n > 0 and s ~= 0 and s.id == id and s.n < cap then
				local mv = min(cap - s.n, n)
				list[i] = { id = id, n = s.n + mv }
				n -= mv
			end
		end
	end
	for i = from, to do
		if n > 0 and list[i] == 0 then
			local mv = min(cap, n)
			list[i] = { id = id, n = mv, d = d }
			n -= mv
		end
	end
	return n
end

-- The look: frosted glass over the world, soft rims, one accent (Zeron's
-- violet), white type with a soft shadow.
local UI = {
	text = "#f4f5f8",
	dim = "#ffffffa8",
	faint = "#ffffff66",
	glass = "#0c0f18d9",
	glass_strong = "#10131de8",
	rim = "#ffffff1c",
	rim_strong = "#ffffff3d",
	well = "#ffffff0d",
	well_hover = "#ffffff24",
	accent = "#8f7dff",
	accent_soft = "#8f7dff40",
	glow = "#8f7dff73",
	gold = "#ffdc4a",
	blur = 18,
}

local SHADOW = { x = 0, y = 1, blur = 3, color = "#000000a6" }
local LIFT = { x = 0, y = 12, blur = 40, color = "#00000073" }

local function text(value, opts)
	local t = { value, color = UI.text, text_size = 13, text_shadow = SHADOW }
	for k, v in opts or {} do
		t[k] = v
	end
	if t.text_shadow == false then
		t.text_shadow = nil
	end
	return ui.text(t)
end

-- A block or item's picture, `size` square: an item's icon (Pixel
-- Perfection's pixel art, kept sharp), or a block as a little cube
-- (shaders.luau's icon).
local function thing(id: number, size: number, icon)
	if id >= items.FIRST_ITEM then
		return ui.image {
			src = "icons/" .. (items.ICONS[id] or "stick") .. ".png",
			w = size,
			h = size,
			fit = "contain",
			image_rendering = "pixelated",
		}
	end
	return ui.div {
		w = size,
		h = size,
		bg_shader = icon,
		shader_params = { { id, 0, 0, 0 } },
	}
end

-- A worn tool's bar: how much is left, green through amber to red.
local function wear_bar(d: number, width: number)
	local f = clamp(d / items.DURABILITY, 0, 1)
	local col = if f > 0.6 then "#5ee07a" elseif f > 0.3 then "#f2c94c" else "#ff5d5d"
	return ui.div {
		absolute = true,
		left = 7,
		right = 7,
		bottom = 5,
		h = 3,
		rounded = 2,
		bg = "#000000b3",
		ui.div { h = 3, rounded = 2, w = (width - 14) * f, bg = col },
	}
end

-- An inventory slot: `entry` is 0 (empty) or { id, n, d? }. `look` "hud"
-- (the hotbar over the world: `lit` the selected one, `number` its key) or
-- "panel" (the inventory: `lit` the one under the cursor; `big`, the
-- crafting result).
local Slot = ui.component(function(props)
	local entry = props.entry
	local hud = props.look == "hud"
	local size = if hud then 48 elseif props.big then 56 else 44
	local lit = props.lit or function()
		return false
	end
	return ui.div {
		w = size,
		h = size,
		rounded = if hud then 9 else 8,
		bg = function()
			if hud then
				return if lit() then "#ffffff2e" else "#ffffff0a"
			end
			return if lit() then UI.well_hover else UI.well
		end,
		border = function()
			return if hud and lit() then 2 else 1
		end,
		border_color = function()
			if lit() then
				return if hud then "#ffffff" else UI.accent
			end
			return UI.rim
		end,
		shadow = function()
			return if hud and lit() then { x = 0, y = 0, blur = 16, color = UI.glow } else { x = 0, y = 0, blur = 0, color = "#00000000" }
		end,
		items = "center",
		justify = "center",
		on_mount = props.on_mount,
		if hud and props.number
			then ui.div {
				absolute = true,
				left = 5,
				top = 3,
				text(tostring(props.number), { text_size = 9, weight = 700, color = UI.faint, text_shadow = false }),
			}
			else false,
		if entry ~= 0 then thing(entry.id, size - (if props.big then 16 else 14), props.icon) else false,
		if entry ~= 0 and entry.n > 1
			then ui.div {
				absolute = true,
				right = 5,
				bottom = 2,
				text(tostring(entry.n), { text_size = 13, weight = 800 }),
			}
			else false,
		if entry ~= 0 and entry.d and entry.d < items.DURABILITY then wear_bar(entry.d, size) else false,
	}
end)

-- The mouse cursor the menus draw while the pointer is locked: an arrow.
local ARROW = {
	"X",
	"XX",
	"X.X",
	"X..X",
	"X...X",
	"X....X",
	"X.....X",
	"X......X",
	"X.......X",
	"X........X",
	"X.....XXXXX",
	"X..X..X",
	"X.X X..X",
	"XX  X..X",
	"X    X..X",
	"     X..X",
	"      XX",
}

local function arrow_canvas()
	local s = 1.25
	return ui.canvas {
		w = 12 * s,
		h = 18 * s,
		draw = function(c)
			for y, row in ARROW do
				for x = 1, #row do
					local ch = string.sub(row, x, x)
					if ch == "X" then
						c:rect((x - 1) * s, (y - 1) * s, s, s, "#000000")
					elseif ch == "." then
						c:rect((x - 1) * s, (y - 1) * s, s, s, "#ffffff")
					end
				end
			end
		end,
	}
end

return ui.component(function(props)
	local store = props.store
	local play_sound = props.play
	local world_shader = ui.layer_shader(shaders.world)
	local icon_shader = ui.shader(shaders.icon)

	-- What the screen shows, as state.
	-- `screen`: "loading", "title", "game", "inventory", "pause", "options",
	-- "controls" or "confirm".
	local screen = ui.use_state("loading")
	local back_to = "title" -- where options and controls go back to
	local ready = ui.use_state(false)
	local progress = ui.use_state(0)
	local debug = ui.use_state("")
	local show_debug = ui.use_state(false)
	local notice = ui.use_state("")
	local name_shown = ui.use_state(0) -- when the selected slot last changed (ui.now)
	local selected = ui.use_state(1)
	local inv = ui.use_state(empty_inventory())
	local held = ui.use_state(0) -- the stack on the cursor in the inventory
	local cur = ui.use_state({ 0, 0 }) -- the cursor, from the game's top left
	local locked_s = ui.use_state(false)
	local hover_slot = ui.use_state(0)
	local sel = ui.use_state({ 1, 1 }) -- the menu's chosen button: row, column
	local splash = ui.use_state(SPLASHES[1])
	local now_s = ui.use_state(0) -- the clock, for the splash's pulse (10 a second)
	local ent_rev = ui.use_state(0)
	local mob_rev = ui.use_state(0)
	-- The crafting grid: 2 by 2 in the inventory, 3 by 3 at a table (its
	-- cells in rows; 0 or { id, n }).
	local grid = ui.use_state({ 0, 0, 0, 0, 0, 0, 0, 0, 0 })
	local grid_n = ui.use_state(2)
	local craft_out = ui.computed(function()
		return items.craft(grid:get(), grid_n:get()) or 0
	end)
	local revs = {}
	for t = 1, 16 do
		revs[t] = ui.use_state(0)
	end
	local hm_rev = ui.use_state(0)

	local saved = store and store.get() or nil
	local settings = { sens = 0.5, fov = 70, volume = 1, bob = true }
	if saved and type(saved.settings) == "table" then
		local s = saved.settings
		if type(s.sens) == "number" then
			settings.sens = clamp(s.sens, 0, 1)
		end
		if type(s.fov) == "number" then
			settings.fov = clamp(s.fov, 50, 110)
		end
		if type(s.volume) == "number" then
			settings.volume = clamp(s.volume, 0, 1)
		end
		if type(s.bob) == "boolean" then
			settings.bob = s.bob
		end
	end
	local settings_rev = ui.use_state(0)

	-- The world and the player, as plain values (read every frame).
	local w = nil
	local P = {
		x = 48,
		y = 30,
		z = 48,
		vx = 0,
		vy = 0,
		vz = 0,
		yaw = 0,
		pitch = -0.25,
		ground = false,
		eye = EYE,
		sneak = false,
		sprint = false,
		wet = false,
		fall_from = 30,
	}
	local keys: { [string]: boolean } = {}
	local el = nil
	local root = nil
	local locked = false
	local gen = nil
	local dirty_save = false
	local save_at = 0
	local target: { number }? = nil
	local before: { number }? = nil
	local hud_at = 0
	local notice_at = 0
	local frames, fps_at, fps = 0, 0, 0
	local third = false
	local last_w = -1e9
	-- Breaking: the left button held, the block being broken, how far.
	local mining = false
	local mine_key = ""
	local mine_prog = 0
	local mine_gap = 0
	local hit_tick = 0
	local swing_t = 1 -- the arm's swing, 0..1 (1 at rest)
	local walk = 0 -- distance walked, for the bob, the legs and the steps
	local step_at = 0
	local amp = 0 -- how much of a stride the legs and bob show
	local swim_at = 0
	local dragging = nil -- the slider being dragged
	local drops = {}
	local bits = {}
	local mobs = {}
	local mobs_restored = false
	local respawn_at = 0
	local attack_cool = 0
	local ent_px = {} -- the entities' colours, three a piece (the canvas)
	local mob_px = {} -- the mobs' colours, four a piece
	local merge_at = 0
	local flow = {}
	local flow_seen = {}
	local flow_at = 0
	local sounds_at, sounds_n = 0, 0
	local fov_now = 70
	local title_turn = 0

	local function play(name: string, vol: number)
		if not play_sound or settings.volume <= 0 then
			return
		end
		-- At most a dozen a second: the rest would only be noise.
		local now = ui.now()
		if now - sounds_at > 1000 then
			sounds_at, sounds_n = now, 0
		end
		sounds_n += 1
		if sounds_n > 12 then
			return
		end
		pcall(play_sound, name, clamp(vol * settings.volume, 0, 1))
	end

	local function block_sound(id: number, vol: number)
		local s = SOUND[id]
		if s then
			play(s .. tostring(math.random(1, 3)), vol)
		end
	end

	local function save_now()
		if not store or not w then
			return
		end
		local list = {}
		for i, id in w.edits do
			table.insert(list, i)
			table.insert(list, id)
		end
		local slots = {}
		for i, s in inv:peek() do
			slots[i * 3 - 2] = if s == 0 then 0 else s.id
			slots[i * 3 - 1] = if s == 0 then 0 else s.n
			slots[i * 3] = if s == 0 then 0 else (s.d or 0)
		end
		local dl = {}
		for _, d in drops do
			table.insert(dl, { d.x, d.y, d.z, d.id, d.n, d.d or 0 })
		end
		local ml = {}
		for _, m in mobs do
			table.insert(ml, { m.kind, m.x, m.y, m.z, m.hp })
		end
		store.set {
			version = 4,
			epoch = WORLD_EPOCH,
			mobs = ml,
			seed = w.seed,
			edits = list,
			player = { P.x, P.y, P.z, P.yaw, P.pitch },
			inventory = slots,
			selected = selected:peek(),
			drops = dl,
			settings = { sens = settings.sens, fov = settings.fov, volume = settings.volume, bob = settings.bob },
		}
		dirty_save = false
	end

	local function load_inventory(restore)
		local list = empty_inventory()
		local saved_slots = restore and restore.inventory
		local per = if restore and restore.version == 4 then 3 else 2
		if type(saved_slots) == "table" and restore.version and restore.version >= 2 then
			for i = 1, SLOTS do
				local id, n = saved_slots[i * per - per + 1], saved_slots[i * per - per + 2]
				local d = if per == 3 then saved_slots[i * 3] else 0
				if type(id) == "number" and type(n) == "number" and NAMES[id] and n >= 1 then
					list[i] = {
						id = id,
						n = min(items.max_stack(id), floor(n)),
						d = if items.TOOLS[id] then (if type(d) == "number" and d > 0 then d else items.DURABILITY) else nil,
					}
				end
			end
		end
		inv:set(list)
		local s = restore and restore.selected
		selected:set(if type(s) == "number" and s >= 1 and s <= 9 then s else 1)
		drops = {}
		if restore and type(restore.drops) == "table" then
			for _, d in restore.drops do
				if type(d) == "table" and #d >= 5 and NAMES[d[4]] then
					table.insert(drops, {
						x = d[1],
						y = d[2],
						z = d[3],
						vx = 0,
						vy = 0,
						vz = 0,
						id = d[4],
						n = d[5],
						d = if d[6] and d[6] > 0 then d[6] else nil,
						age = 1,
						delay = 0,
						phase = math.random() * 6.2832,
					})
				end
			end
		end
		bits = {}
		mobs = {}
		if restore and type(restore.mobs) == "table" then
			for _, m in restore.mobs do
				if type(m) == "table" and mobsmod.KINDS[m[1]] then
					local mob = mobsmod.new(m[1], m[2], m[3], m[4])
					mob.hp = m[5] or mob.hp
					table.insert(mobs, mob)
				end
			end
		end
		mobs_restored = #mobs > 0
	end

	local function say(t: string)
		notice:set(t)
		notice_at = ui.now()
	end

	local function bump_all()
		for t = 1, 16 do
			revs[t]:set(revs[t]:peek() + 1)
		end
		hm_rev:set(hm_rev:peek() + 1)
	end

	-- Screens.
	local function go(to: string)
		if to == "title" then
			splash:set(SPLASHES[math.random(1, #SPLASHES)])
		end
		screen:set(to)
		sel:set({ 1, 1 })
		dragging = nil
	end

	local start_after = "title" -- where loading goes when the world is made
	local apply_preview
	local function start(seed: number, restore, after: string)
		w = new_world(seed)
		ready:set(false)
		progress:set(0)
		load_inventory(restore)
		held:set(0)
		flow, flow_seen = {}, {}
		go("loading")
		local slice_from = ui.now()
		gen = coroutine.create(function()
			generate(w, function(p)
				if ui.now() - slice_from > 9 then
					progress:set(p)
					coroutine.yield()
					slice_from = ui.now()
				end
			end)
			if restore and type(restore.edits) == "table" then
				local list = restore.edits
				for i = 1, #list - 1, 2 do
					local at, id = list[i], list[i + 1]
					if type(at) == "number" and type(id) == "number" and at >= 0 and at < WX * WY * WZ then
						writeu8(w.ovr, at, id + 1)
						w.edits[at] = id
					end
				end
			end
			local pl = restore and restore.player
			if type(pl) == "table" and #pl >= 5 then
				P.x, P.y, P.z, P.yaw, P.pitch = pl[1], pl[2], pl[3], pl[4], pl[5]
			else
				P.x, P.y, P.z = w.spawn[1], w.spawn[2], w.spawn[3]
				P.yaw, P.pitch = 0.6, -0.2
			end
			P.vx, P.vy, P.vz = 0, 0, 0
			P.fall_from = P.y
		end)
		start_after = after
	end

	local function new_world_now()
		start(floor(ui.now() * 1000) % 2147483647 + 7, nil, "game")
		dirty_save = true
	end

	-- A saved world from before the last reset (another epoch) is left
	-- behind: a fresh island, the settings kept.
	if saved and type(saved.seed) == "number" and saved.epoch == WORLD_EPOCH then
		start(saved.seed, saved, "title")
	else
		start(floor(ui.now() * 1000) % 2147483647 + 7, nil, "title")
		dirty_save = true
	end

	-- Blocks the player can't walk into; the island's edge is a wall.
	local function solid(x: number, y: number, z: number): boolean
		if x < 0 or z < 0 or x >= WX or z >= WZ then
			return true
		end
		local b = get_block(w, x, y, z)
		return b ~= AIR and b ~= WATERB
	end

	local function water_at(x: number, y: number, z: number): boolean
		return get_block(w, floor(x), floor(y), floor(z)) == WATERB
	end

	local function collides(px: number, py: number, pz: number): boolean
		for y = floor(py), floor(py + PH - 1e-6) do
			for z = floor(pz - HW), floor(pz + HW - 1e-6) do
				for x = floor(px - HW), floor(px + HW - 1e-6) do
					if solid(x, y, z) then
						return true
					end
				end
			end
		end
		return false
	end

	-- Ground under the player's feet anywhere in their footprint.
	local function supported(px: number, pz: number): boolean
		local y = floor(P.y - 0.05)
		for z = floor(pz - HW), floor(pz + HW - 1e-6) do
			for x = floor(px - HW), floor(px + HW - 1e-6) do
				if solid(x, y, z) then
					return true
				end
			end
		end
		return false
	end

	-- Moves along one axis; true when something stopped it.
	local function move_axis(axis: number, d: number): boolean
		if d == 0 then
			return false
		end
		local nx, ny, nz = P.x, P.y, P.z
		if axis == 1 then
			nx += d
		elseif axis == 2 then
			ny += d
		else
			nz += d
		end
		-- Crouching on an edge: no stepping off it.
		if axis ~= 2 and P.sneak and P.ground and not supported(nx, nz) then
			return true
		end
		if not collides(nx, ny, nz) then
			P.x, P.y, P.z = nx, ny, nz
			return false
		end
		local ox, oy, oz = P.x, P.y, P.z
		if axis == 1 then
			P.x = if d > 0 then floor(nx + HW) - HW - 1e-4 else floor(nx - HW) + 1 + HW + 1e-4
		elseif axis == 2 then
			P.y = if d > 0 then floor(ny + PH) - PH - 1e-4 else floor(ny) + 1
		else
			P.z = if d > 0 then floor(nz + HW) - HW - 1e-4 else floor(nz - HW) + 1 + HW + 1e-4
		end
		if collides(P.x, P.y, P.z) then
			P.x, P.y, P.z = ox, oy, oz
		end
		return true
	end

	local function look_dir(): (number, number, number)
		local cp = math.cos(P.pitch)
		return cp * math.sin(P.yaw), math.sin(P.pitch), -cp * math.cos(P.yaw)
	end

	-- The first block within reach along the view, and the cell before it.
	local function raycast()
		local ox, oy, oz = P.x, P.y + P.eye, P.z
		local dx, dy, dz = look_dir()
		local x, y, z = floor(ox), floor(oy), floor(oz)
		local sx = if dx > 0 then 1 else -1
		local sy = if dy > 0 then 1 else -1
		local sz = if dz > 0 then 1 else -1
		local tdx = if dx ~= 0 then abs(1 / dx) else math.huge
		local tdy = if dy ~= 0 then abs(1 / dy) else math.huge
		local tdz = if dz ~= 0 then abs(1 / dz) else math.huge
		local tmx = if dx ~= 0 then (if dx > 0 then x + 1 - ox else ox - x) * tdx else math.huge
		local tmy = if dy ~= 0 then (if dy > 0 then y + 1 - oy else oy - y) * tdy else math.huge
		local tmz = if dz ~= 0 then (if dz > 0 then z + 1 - oz else oz - z) * tdz else math.huge
		local px, py, pz = x, y, z
		local t = 0
		while t <= REACH do
			if x >= 0 and z >= 0 and x < WX and z < WZ and y >= 0 and y < WY then
				local b = get_block(w, x, y, z)
				if b ~= AIR and b ~= WATERB then
					return { x, y, z, b }, { px, py, pz }, t
				end
			end
			px, py, pz = x, y, z
			if tmx < tmy and tmx < tmz then
				x += sx
				t = tmx
				tmx += tdx
			elseif tmy < tmz then
				y += sy
				t = tmy
				tmy += tdy
			else
				z += sz
				t = tmz
				tmz += tdz
			end
		end
		return nil, nil, nil
	end

	local function set_block(x: number, y: number, z: number, id: number): boolean
		if x < 0 or z < 0 or x >= WX or z >= WZ or y < 1 or y >= WY then
			return false
		end
		local at = idx(x, y, z)
		writeu8(w.ovr, at, id + 1)
		w.edits[at] = id
		local t = y // 3 + 1
		revs[t]:set(revs[t]:peek() + 1)
		dirty_save = true
		return true
	end

	-- Water: the sea fills what opens to it below its level, a step at a
	-- time (down and sideways), so a hole dug by the shore floods.
	local function flow_check(x: number, y: number, z: number)
		if x < 0 or z < 0 or x >= WX or z >= WZ or y < 1 or y > WATER then
			return
		end
		local at = idx(x, y, z)
		if flow_seen[at] then
			return
		end
		flow_seen[at] = true
		table.insert(flow, { x, y, z })
	end

	local function flow_around(x: number, y: number, z: number)
		flow_check(x, y, z)
		flow_check(x + 1, y, z)
		flow_check(x - 1, y, z)
		flow_check(x, y, z + 1)
		flow_check(x, y, z - 1)
		flow_check(x, y - 1, z)
	end

	local function flow_step()
		local list = flow
		flow, flow_seen = {}, {}
		local done = 0
		for _, c in list do
			local x, y, z = c[1], c[2], c[3]
			if done > 160 then
				flow_check(x, y, z)
			elseif get_block(w, x, y, z) == AIR then
				local wet = get_block(w, x, y + 1, z) == WATERB
					or get_block(w, x + 1, y, z) == WATERB
					or get_block(w, x - 1, y, z) == WATERB
					or get_block(w, x, y, z + 1) == WATERB
					or get_block(w, x, y, z - 1) == WATERB
				if wet then
					set_block(x, y, z, WATERB)
					done += 1
					flow_check(x + 1, y, z)
					flow_check(x - 1, y, z)
					flow_check(x, y, z + 1)
					flow_check(x, y, z - 1)
					flow_check(x, y - 1, z)
				end
			end
		end
	end

	-- Bits of a broken block, thrown out from it (or off the face being hit).
	local function spawn_bits(id: number, x: number, y: number, z: number, n: number, spread: number)
		for _ = 1, n do
			if #bits >= 24 then
				table.remove(bits, 1)
			end
			table.insert(bits, {
				x = x + (math.random() - 0.5) * spread,
				y = y + (math.random() - 0.5) * spread,
				z = z + (math.random() - 0.5) * spread,
				vx = (math.random() - 0.5) * 3,
				vy = math.random() * 3 + 0.5,
				vz = (math.random() - 0.5) * 3,
				id = id,
				turn = math.random() * 6.28,
				life = 0.45 + math.random() * 0.4,
				half = 0.03 + math.random() * 0.02,
			})
		end
	end

	local function spawn_drop(id: number, n: number, x: number, y: number, z: number, vx: number, vy: number, vz: number, delay: number, d: number?)
		if #drops >= 64 then
			table.remove(drops, 1)
		end
		table.insert(drops, {
			x = x,
			y = y,
			z = z,
			vx = vx,
			vy = vy,
			vz = vz,
			id = id,
			n = n,
			d = d,
			age = 0,
			delay = delay,
			phase = math.random() * 6.2832,
		})
	end

	local function swing()
		swing_t = 0
	end

	local function held_id(): number
		local s = inv:peek()[selected:peek()]
		return if s == 0 then 0 else s.id
	end

	-- The tool in hand wears by `amount`; at nothing it breaks.
	local function wear_tool(amount: number)
		local i = selected:peek()
		local s = inv:peek()[i]
		if s == 0 or not items.TOOLS[s.id] then
			return
		end
		local list = table.clone(inv:peek())
		local d = (s.d or items.DURABILITY) - amount
		if d <= 0 then
			list[i] = 0
			play("tool_break", 0.8)
			say(NAMES[s.id] .. " broke")
		else
			list[i] = { id = s.id, n = 1, d = d }
		end
		inv:set(list)
		dirty_save = true
	end

	-- Breaks the targeted block: it drops where it stood.
	local function break_block()
		local hit = target
		if not hit or not items.BLOCKS[hit[4]] then
			return
		end
		local x, y, z, id = hit[1], hit[2], hit[3], hit[4]
		local _, gives = items.break_time(id, held_id())
		if not set_block(x, y, z, AIR) then
			return
		end
		if id == GLASS then
			play("glass", 0.7)
		else
			block_sound(id, 0.9)
		end
		spawn_bits(id, x + 0.5, y + 0.5, z + 0.5, 16, 0.8)
		if gives then
			for _, dr in items.drops_of(id, math.random) do
				spawn_drop(dr[1], dr[2], x + 0.5, y + 0.4, z + 0.5, (math.random() - 0.5) * 2, 2.5, (math.random() - 0.5) * 2, 0.35)
			end
		end
		if items.TOOLS[held_id()] then
			wear_tool(1)
		end
		if y <= WATER then
			flow_around(x, y, z)
		end
		target, before = raycast()
	end

	-- Places one of the selected stack's block against the targeted face.
	local function place_block()
		if not target or not before then
			return
		end
		local i = selected:peek()
		local s = inv:peek()[i]
		if s == 0 or not items.is_block(s.id) then
			return
		end
		local x, y, z = before[1], before[2], before[3]
		local here = get_block(w, x, y, z)
		if here ~= AIR and here ~= WATERB then
			return
		end
		-- Not inside the player.
		if x + 1 > P.x - HW and x < P.x + HW and z + 1 > P.z - HW and z < P.z + HW and y + 1 > P.y and y < P.y + PH then
			return
		end
		if not set_block(x, y, z, s.id) then
			return
		end
		block_sound(s.id, 0.75)
		swing()
		local list = table.clone(inv:peek())
		list[i] = if s.n > 1 then { id = s.id, n = s.n - 1 } else 0
		inv:set(list)
		target, before = raycast()
	end

	-- Q: one of the selected stack thrown ahead.
	local function drop_one()
		local i = selected:peek()
		local s = inv:peek()[i]
		if s == 0 then
			return
		end
		local list = table.clone(inv:peek())
		list[i] = if s.n > 1 then { id = s.id, n = s.n - 1, d = s.d } else 0
		inv:set(list)
		local dx, dy, dz = look_dir()
		spawn_drop(s.id, 1, P.x + dx * 0.4, P.y + P.eye - 0.3, P.z + dz * 0.4, dx * 4.5, dy * 4.5 + 1.5, dz * 4.5, 1.5, s.d)
		swing()
		dirty_save = true
	end

	-- Middle-click: selects the hotbar slot holding the targeted block.
	local function pick_block()
		if not target then
			return
		end
		local list = inv:peek()
		for i = 1, 9 do
			local s = list[i]
			if s ~= 0 and s.id == target[4] then
				selected:set(i)
				name_shown:set(ui.now())
				return
			end
		end
	end

	local function select_slot(i: number)
		if i ~= selected:peek() then
			selected:set(i)
			dirty_save = true
		end
		name_shown:set(ui.now())
	end

	-- What the crafting grid makes, taken: onto the cursor, or (`shift`) as
	-- many times as it can straight into the inventory.
	local function take_output(shift: boolean)
		local function consume()
			local g = table.clone(grid:peek())
			for k = 1, 9 do
				local c = g[k]
				if c ~= 0 then
					g[k] = if c.n > 1 then { id = c.id, n = c.n - 1 } else 0
				end
			end
			grid:set(g)
		end
		local made = false
		if shift then
			for _ = 1, 64 do
				local o = items.craft(grid:peek(), grid_n:peek())
				if not o then
					break
				end
				local list = table.clone(inv:peek())
				if stow(list, o.id, o.n, 1, SLOTS, if items.TOOLS[o.id] then items.DURABILITY else nil) > 0 then
					break
				end
				inv:set(list)
				consume()
				made = true
			end
		else
			local o = items.craft(grid:peek(), grid_n:peek())
			if not o then
				return
			end
			local h = held:peek()
			if h == 0 then
				held:set({ id = o.id, n = o.n, d = if items.TOOLS[o.id] then items.DURABILITY else nil })
				consume()
				made = true
			elseif h.id == o.id and h.n + o.n <= items.max_stack(o.id) then
				held:set({ id = h.id, n = h.n + o.n })
				consume()
				made = true
			end
		end
		if made then
			play("wood" .. tostring(math.random(1, 3)), 0.25)
			dirty_save = true
		end
	end

	-- The inventory screen's clicks, on slot `i` (1..36 the inventory, 37..45
	-- the crafting grid, 46 what it makes). `alt`: a right-click (half a stack
	-- up, or one down); `shift`: straight across (the hotbar and the rest, or
	-- out of the grid).
	local function click_slot(i: number, alt: boolean, shift: boolean)
		if i == OUT then
			take_output(shift)
			return
		end
		local in_grid = i > SLOTS
		local st = if in_grid then grid else inv
		local j = if in_grid then i - GRID0 else i
		local list = table.clone(st:peek())
		local s, h = list[j], held:peek()
		if shift and h == 0 and s ~= 0 then
			list[j] = 0
			if in_grid then
				local inv_list = table.clone(inv:peek())
				local left = stow(inv_list, s.id, s.n, 1, SLOTS, s.d)
				inv:set(inv_list)
				if left > 0 then
					list[j] = { id = s.id, n = left, d = s.d }
				end
			else
				local from, to = if i <= 9 then 10 else 1, if i <= 9 then SLOTS else 9
				local left = stow(list, s.id, s.n, from, to, s.d)
				if left > 0 then
					list[j] = { id = s.id, n = left, d = s.d }
				end
			end
		elseif not alt then
			if h == 0 then
				if s ~= 0 then
					held:set(s)
					list[j] = 0
				end
			elseif s == 0 then
				list[j] = h
				held:set(0)
			elseif s.id == h.id and items.max_stack(s.id) > 1 then
				local mv = min(items.max_stack(s.id) - s.n, h.n)
				list[j] = { id = s.id, n = s.n + mv }
				held:set(if h.n - mv > 0 then { id = h.id, n = h.n - mv } else 0)
			else
				list[j] = h
				held:set(s)
			end
		else
			if h == 0 then
				if s ~= 0 then
					local half = math.ceil(s.n / 2)
					held:set({ id = s.id, n = half, d = s.d })
					list[j] = if s.n - half > 0 then { id = s.id, n = s.n - half } else 0
				end
			elseif s == 0 or (s.id == h.id and s.n < items.max_stack(s.id)) then
				list[j] = { id = h.id, n = (if s == 0 then 0 else s.n) + 1, d = h.d }
				held:set(if h.n > 1 then { id = h.id, n = h.n - 1, d = h.d } else 0)
			end
		end
		st:set(list)
		dirty_save = true
	end

	-- The pointer: held while playing, and through the menus.
	local function lock()
		if root and not locked then
			pcall(function()
				root:focus()
			end)
			local ok, got = pcall(function()
				return root:lock_pointer()
			end)
			locked = ok and got == true
			locked_s:set(locked)
		end
		return locked
	end

	local function unlock()
		locked = false
		locked_s:set(false)
		if root then
			pcall(function()
				root:unlock_pointer()
			end)
		end
	end

	local function root_size(): (number, number)
		local rw = root and root.width or DATA_W
		local rh = root and root.height or DATA_H
		return rw, rh
	end

	local function center_cursor()
		local rw, rh = root_size()
		cur:set({ rw / 2, rh / 2 })
	end

	local function resume()
		if not ready:peek() then
			return
		end
		keys = {}
		mining = false
		go("game")
		lock()
	end

	-- The inventory (its 2 by 2 grid), or a crafting table's 3 by 3.
	local function open_inventory(n: number?)
		grid_n:set(n or 2)
		go("inventory")
		keys = {}
		mining = false
		center_cursor()
		hover_slot:set(0)
	end

	local function close_inventory()
		-- What's on the cursor and in the grid goes back in, or is thrown out.
		local back = {}
		local h = held:peek()
		if h ~= 0 then
			table.insert(back, h)
		end
		for _, c in grid:peek() do
			if c ~= 0 then
				table.insert(back, c)
			end
		end
		held:set(0)
		grid:set({ 0, 0, 0, 0, 0, 0, 0, 0, 0 })
		local list = table.clone(inv:peek())
		for _, c in back do
			local left = stow(list, c.id, c.n, 1, SLOTS, c.d)
			if left > 0 then
				local dx, _, dz = look_dir()
				spawn_drop(c.id, left, P.x + dx * 0.4, P.y + P.eye - 0.3, P.z + dz * 0.4, dx * 3, 1.5, dz * 3, 1.5, c.d)
			end
		end
		inv:set(list)
		go("game")
		keys = {}
	end

	-- Menus: rows of buttons by id. A row of two is two halves.
	local MENUS = {
		title = { { "play" }, { "new" }, { "options", "controls" } },
		pause = { { "resume" }, { "options", "controls" }, { "quit" } },
		options = { { "sens" }, { "fov" }, { "volume" }, { "bob" }, { "done" } },
		controls = { { "done" } },
		confirm = { { "create", "cancel" } },
	}

	local SLIDERS = {
		sens = {
			get = function()
				return settings.sens
			end,
			set = function(v)
				settings.sens = v
			end,
			label = function()
				return string.format("Mouse Sensitivity: %d%%", floor(25 + settings.sens * 175 + 0.5))
			end,
		},
		fov = {
			get = function()
				return (settings.fov - 50) / 60
			end,
			set = function(v)
				settings.fov = floor(50 + v * 60 + 0.5)
			end,
			label = function()
				return string.format("FOV: %d", settings.fov)
			end,
		},
		volume = {
			get = function()
				return settings.volume
			end,
			set = function(v)
				settings.volume = floor(v * 20 + 0.5) / 20
			end,
			label = function()
				return if settings.volume <= 0 then "Sound: OFF" else string.format("Sound: %d%%", floor(settings.volume * 100 + 0.5))
			end,
		},
	}

	local LABELS = {
		play = "Play",
		new = "New World",
		options = "Options…",
		controls = "Controls",
		resume = "Back to Game",
		quit = "Save and Quit to Title",
		done = "Done",
		create = "Create New World",
		cancel = "Cancel",
	}

	local function label_of(id: string): string
		settings_rev:get()
		if SLIDERS[id] then
			return SLIDERS[id].label()
		end
		if id == "bob" then
			return if settings.bob then "View Bobbing: ON" else "View Bobbing: OFF"
		end
		return LABELS[id] or id
	end

	local function changed_settings()
		settings_rev:set(settings_rev:peek() + 1)
		dirty_save = true
	end

	local function activate(id: string)
		play("click", 0.5)
		if id == "play" or id == "resume" then
			resume()
		elseif id == "new" then
			go("confirm")
		elseif id == "create" then
			new_world_now()
		elseif id == "cancel" then
			go("title")
		elseif id == "options" or id == "controls" then
			back_to = screen:peek()
			go(id)
		elseif id == "done" then
			save_now()
			go(back_to)
		elseif id == "quit" then
			save_now()
			go("title")
		elseif id == "bob" then
			settings.bob = not settings.bob
			changed_settings()
		end
	end

	local btn_els = {}
	local inv_els = {}

	-- The element under the cursor (the game's top-left coordinates).
	local function under(e): boolean
		if not e or not e.mounted or not e.x or not root or not root.x then
			return false
		end
		local c = cur:peek()
		local x, y = c[1] + root.x, c[2] + root.y
		return x >= e.x and x < e.x + e.width and y >= e.y and y < e.y + e.height
	end

	local function button_at(): (string?, number, number)
		local rows = MENUS[screen:peek()]
		if not rows then
			return nil, 0, 0
		end
		for r, row in rows do
			for c, id in row do
				if under(btn_els[id]) then
					return id, r, c
				end
			end
		end
		return nil, 0, 0
	end

	local function slider_to_cursor(id: string)
		local e = btn_els[id]
		local sl = SLIDERS[id]
		if not sl or not e or not e.x or not root or not root.x then
			return
		end
		local x = cur:peek()[1] + root.x
		sl.set(clamp((x - e.x - 8) / (e.width - 16), 0, 1))
		changed_settings()
	end

	local function slot_at(): number
		for i = 1, OUT do
			if (i <= SLOTS or i == OUT or i - GRID0 <= grid_n:peek() * grid_n:peek()) and under(inv_els[i]) then
				return i
			end
		end
		return 0
	end

	-- The cursor moved (in a menu): what it's over is chosen.
	local function hovered()
		local s = screen:peek()
		if s == "inventory" then
			hover_slot:set(slot_at())
			return
		end
		if dragging then
			slider_to_cursor(dragging)
			return
		end
		local id, r, c = button_at()
		if id then
			local now = sel:peek()
			if now[1] ~= r or now[2] ~= c then
				sel:set({ r, c })
			end
		end
	end

	local function sel_id(): string?
		local rows = MENUS[screen:peek()]
		if not rows then
			return nil
		end
		local s = sel:peek()
		local row = rows[s[1]]
		return row and row[min(s[2], #row)]
	end

	local function menu_key(k: string): boolean
		local rows = MENUS[screen:peek()]
		if not rows then
			return false
		end
		local s = sel:peek()
		local id = sel_id()
		if k == "arrowup" or k == "w" then
			local r = (s[1] - 2) % #rows + 1
			sel:set({ r, min(s[2], #rows[r]) })
			play("click", 0.2)
		elseif k == "arrowdown" or k == "s" or k == "tab" then
			local r = s[1] % #rows + 1
			sel:set({ r, min(s[2], #rows[r]) })
			play("click", 0.2)
		elseif k == "arrowleft" or k == "a" or k == "arrowright" or k == "d" then
			local step = if k == "arrowleft" or k == "a" then -1 else 1
			if id and SLIDERS[id] then
				local sl = SLIDERS[id]
				sl.set(clamp(sl.get() + step * 0.05, 0, 1))
				changed_settings()
			else
				local row = rows[s[1]]
				if #row > 1 then
					sel:set({ s[1], (s[2] - 1 + step) % #row + 1 })
					play("click", 0.2)
				end
			end
		elseif k == "enter" or k == " " then
			if id then
				activate(id)
			end
		elseif k == "escape" then
			local now = screen:peek()
			if now == "pause" then
				activate("resume")
			elseif now == "options" or now == "controls" then
				activate("done")
			elseif now == "confirm" then
				activate("cancel")
			end
		else
			return false
		end
		return true
	end

	-- The camera behind the player (third person): pulled in where blocks
	-- are in the way.
	local function third_distance(ex: number, ey: number, ez: number, dx: number, dy: number, dz: number): number
		local d = 0
		while d < 4 do
			local nd = d + 0.1
			local x, y, z = ex - dx * (nd + 0.2), ey - dy * (nd + 0.2), ez - dz * (nd + 0.2)
			if solid(floor(x), floor(y), floor(z)) then
				break
			end
			d = nd
		end
		return d
	end

	-- An animal dies: a puff, its drops, a last sound.
	local function kill(m)
		local k = mobsmod.KINDS[m.kind]
		spawn_bits(WOOL, m.x, m.y + k.h * 0.5, m.z, 14, k.hw * 2)
		for _, dr in mobsmod.drops(m) do
			spawn_drop(dr[1], dr[2], m.x, m.y + 0.3, m.z, (math.random() - 0.5) * 2, 3, (math.random() - 0.5) * 2, 0.4)
		end
		play(k.name .. "_hurt", 0.6)
		for i, o in mobs do
			if o == m then
				table.remove(mobs, i)
				break
			end
		end
	end

	-- A click on an animal in reach (nearer than any block): a hit. True if
	-- the click hit one.
	local function attack(): boolean
		local ex, ey, ez = P.x, P.y + P.eye, P.z
		local dx, dy, dz = look_dir()
		local best, bt = nil, 3.2
		for _, m in mobs do
			local t = mobsmod.ray(m, ex, ey, ez, dx, dy, dz)
			if t and t < bt then
				best, bt = m, t
			end
		end
		if not best then
			return false
		end
		local _, _, tb = raycast()
		if tb and tb < bt then
			return false
		end
		swing()
		if attack_cool > 0 then
			return true
		end
		attack_cool = 0.4
		local h = held_id()
		local k = mobsmod.KINDS[best.kind]
		play(k.name .. "_hurt", 0.7)
		if mobsmod.hit(best, items.DAMAGE[h] or 1, P.x, P.z) then
			kill(best)
		end
		if items.TOOLS[h] then
			wear_tool(if h == items.SWORD then 1 else 2)
		end
		return true
	end

	-- The top of a column, if it's grass open to the sky: where an animal
	-- may stand.
	local function grass_top(x: number, z: number): number?
		if x < 1 or z < 1 or x >= WX - 1 or z >= WZ - 1 then
			return nil
		end
		for y = WY - 2, 1, -1 do
			local b = get_block(w, x, y, z)
			if b ~= AIR then
				return if b == GRASS then y + 1 else nil
			end
		end
		return nil
	end

	-- A few of one kind together, near (x, z).
	local function spawn_herd(x: number, z: number)
		local kind = math.random(1, 3)
		for _ = 1, math.random(2, 4) do
			local mx, mz = x + math.random(-3, 3), z + math.random(-3, 3)
			local y = grass_top(mx, mz)
			if y and #mobs < 24 then
				table.insert(mobs, mobsmod.new(kind, mx + 0.5, y, mz + 0.5))
			end
		end
	end

	local function populate()
		for _ = 1, 40 do
			if #mobs >= 14 then
				break
			end
			spawn_herd(math.random(4, WX - 5), math.random(4, WZ - 5))
		end
	end

	local function update_mobs(dt: number)
		attack_cool = max(0, attack_cool - dt)
		local env = {
			solid = solid,
			water = function(x, y, z)
				return get_block(w, x, y, z) == WATERB
			end,
			px = P.x,
			pz = P.z,
			play = play,
			lay = function(m)
				spawn_drop(items.EGG, 1, m.x, m.y + 0.3, m.z, 0, 1, 0, 0.5)
				play("pop", 0.25)
			end,
		}
		local i = 1
		while i <= #mobs do
			local m = mobs[i]
			mobsmod.update(m, dt, env)
			if m.hp <= 0 then
				kill(m)
			else
				i += 1
			end
		end
		-- New ones come now and then, out of sight, while there are few.
		respawn_at -= dt
		if respawn_at <= 0 then
			respawn_at = 20
			if #mobs < 10 then
				for _ = 1, 10 do
					local x, z = math.random(4, WX - 5), math.random(4, WZ - 5)
					if (x - P.x) ^ 2 + (z - P.z) ^ 2 > 24 * 24 then
						spawn_herd(x, z)
						break
					end
				end
			end
		end
	end

	-- The mobs for the shader: the nearest, four points each.
	local function paint_mobs(): number
		local list = {}
		for _, m in mobs do
			local d = (m.x - P.x) ^ 2 + (m.z - P.z) ^ 2
			if d < 56 * 56 then
				table.insert(list, { d = d, m = m })
			end
		end
		table.sort(list, function(a, b)
			return a.d < b.d
		end)
		local px = {}
		for k = 1, min(#list, MAX_MOBS) do
			local m = list[k].m
			local qx = floor(clamp(m.x, 0, 95.98) * 64 + 0.5)
			local qy = floor(clamp(m.y, 0, 47.98) * 64 + 0.5)
			local qz = floor(clamp(m.z, 0, 95.98) * 64 + 0.5)
			local yaw = floor(((m.yaw % (2 * math.pi)) / (2 * math.pi)) * 64 + 0.5) % 64
			local limb = floor((clamp(mobsmod.limb(m), -1, 1) + 1) / 2 * 63 + 0.5)
			local tilt = floor((clamp(m.tilt / 0.8, -1, 1) + 1) / 2 * 63 + 0.5)
			table.insert(px, hex((qx // 64) * 2, (qy // 64) * 4, (qz // 64) * 2))
			table.insert(px, hex((qx % 64) * 4, (qy % 64) * 4, (qz % 64) * 4))
			table.insert(px, hex(m.kind * 32, yaw * 4, limb * 4))
			table.insert(px, hex(if m.hurt > 0 then 252 else 0, tilt * 4, 0))
		end
		local changed = #px ~= #mob_px
		if not changed then
			for k = 1, #px do
				if px[k] ~= mob_px[k] then
					changed = true
					break
				end
			end
		end
		if changed then
			mob_px = px
			mob_rev:set(mob_rev:peek() + 1)
		end
		return #px // 4
	end

	local function update_entities(dt: number, picking: boolean)
		-- Dropped blocks: they fall, float in water, slide to rest, and come to
		-- the player once near.
		local cx, cy, cz = P.x, P.y + 0.8, P.z
		local i = 1
		while i <= #drops do
			local d = drops[i]
			d.age += dt
			local wet = water_at(d.x, d.y, d.z)
			local dx, dy, dz = cx - d.x, cy - d.y, cz - d.z
			local dist = sqrt(dx * dx + dy * dy + dz * dz)
			local pulled = picking and d.age > d.delay and dist < 1.9
			if pulled then
				local k = min(1, 10 * dt)
				local sp = 9 / max(dist, 0.3)
				d.vx += (dx * sp - d.vx) * k
				d.vy += (dy * sp - d.vy) * k
				d.vz += (dz * sp - d.vz) * k
			elseif wet then
				d.vy += (1.0 - d.vy) * min(1, 3 * dt)
				d.vx *= 1 - min(1, 2 * dt)
				d.vz *= 1 - min(1, 2 * dt)
			else
				d.vy = max(d.vy - 18 * dt, -20)
				local f = if d.ground then 10 else 0.6
				d.vx *= 1 - min(1, f * dt)
				d.vz *= 1 - min(1, f * dt)
			end
			d.ground = false
			local nx = d.x + d.vx * dt
			if not pulled and solid(floor(nx), floor(d.y), floor(d.z)) then
				d.vx = 0
			else
				d.x = nx
			end
			local nz = d.z + d.vz * dt
			if not pulled and solid(floor(d.x), floor(d.y), floor(nz)) then
				d.vz = 0
			else
				d.z = nz
			end
			local ny = d.y + d.vy * dt
			if not pulled and d.vy <= 0 and solid(floor(d.x), floor(ny - 0.13), floor(d.z)) then
				d.y = floor(ny - 0.13) + 1.13
				d.vy = 0
				d.ground = true
			elseif not pulled and d.vy > 0 and solid(floor(d.x), floor(ny + 0.13), floor(d.z)) then
				d.vy = 0
			else
				d.y = ny
			end
			-- A block placed over it pushes it up.
			if not pulled and solid(floor(d.x), floor(d.y), floor(d.z)) then
				d.y = floor(d.y) + 1.13
			end
			local gone = d.age > 300 or d.y < -10
			if pulled and dist < 0.55 then
				local list = table.clone(inv:peek())
				local left = stow(list, d.id, d.n, 1, SLOTS, d.d)
				if left < d.n then
					inv:set(list)
					play("pop", 0.35)
					dirty_save = true
				end
				if left > 0 then
					if left == d.n then
						say("Inventory full")
					end
					d.n = left
					d.delay = d.age + 2
				else
					gone = true
				end
			end
			if gone then
				table.remove(drops, i)
			else
				i += 1
			end
		end
		-- Drops of a kind lying together become one stack.
		merge_at += dt
		if merge_at > 0.5 then
			merge_at = 0
			for a = #drops, 2, -1 do
				local d = drops[a]
				for b = 1, a - 1 do
					local e = drops[b]
					if e.id == d.id and e.n + d.n <= items.max_stack(e.id) and abs(e.x - d.x) < 0.6 and abs(e.y - d.y) < 0.4 and abs(e.z - d.z) < 0.6 then
						e.n += d.n
						table.remove(drops, a)
						break
					end
				end
			end
		end
		-- The bits of broken blocks.
		local j = 1
		while j <= #bits do
			local b = bits[j]
			b.life -= dt
			b.vy -= 16 * dt
			local nx, ny, nz = b.x + b.vx * dt, b.y + b.vy * dt, b.z + b.vz * dt
			if solid(floor(nx), floor(ny), floor(nz)) then
				b.vx *= 0.3
				b.vz *= 0.3
				b.vy = 0
			else
				b.x, b.y, b.z = nx, ny, nz
			end
			if b.life <= 0 then
				table.remove(bits, j)
			else
				j += 1
			end
		end
	end

	-- The entities for the shader: the nearest drops, then the bits.
	local function paint_entities()
		local list = {}
		for _, d in drops do
			local dx, dz = d.x - P.x, d.z - P.z
			table.insert(list, { d = dx * dx + dz * dz, e = d })
		end
		table.sort(list, function(a, b)
			return a.d < b.d
		end)
		local px = {}
		local function put(x: number, y: number, z: number, id: number, turn: number, half: number)
			local qx = floor(clamp(x, 0, 95.98) * 64 + 0.5)
			local qy = floor(clamp(y, 0, 47.98) * 64 + 0.5)
			local qz = floor(clamp(z, 0, 95.98) * 64 + 0.5)
			table.insert(px, hex((qx // 64) * 2, (qy // 64) * 4, (qz // 64) * 2))
			table.insert(px, hex((qx % 64) * 4, (qy % 64) * 4, (qz % 64) * 4))
			local t = floor((turn / (2 * math.pi)) * 64) % 64
			table.insert(px, hex(id * 8, t * 4, min(63, floor(half * 128 + 0.5)) * 4))
		end
		local n = 0
		for _, it in list do
			if n >= MAX_ENTS - 6 then
				break
			end
			-- (It bobs and turns in the shader, on the time: still here.)
			local d = it.e
			put(d.x, d.y, d.z, d.id, d.phase, 0.125)
			n += 1
			if d.n > 1 and n < MAX_ENTS - 6 then
				-- More than one: a second beside it.
				put(d.x + 0.09, d.y + 0.09, d.z + 0.07, d.id, d.phase + 0.5, 0.125)
				n += 1
			end
		end
		for _, b in bits do
			if n >= MAX_ENTS then
				break
			end
			put(b.x, b.y, b.z, b.id, b.turn or 0, b.half)
			n += 1
		end
		local changed = #px ~= #ent_px
		if not changed then
			for k = 1, #px do
				if px[k] ~= ent_px[k] then
					changed = true
					break
				end
			end
		end
		if changed then
			ent_px = px
			ent_rev:set(ent_rev:peek() + 1)
		end
		return n
	end

	local function update(dt: number)
		local shift = ui.modifiers.shift:peek()
		local ctrl = ui.modifiers.control:peek()
		local turn = 2.4 * dt
		if keys.arrowleft then
			P.yaw -= turn
		end
		if keys.arrowright then
			P.yaw += turn
		end
		if keys.arrowup then
			P.pitch += turn
		end
		if keys.arrowdown then
			P.pitch -= turn
		end
		P.pitch = clamp(P.pitch, -1.55, 1.55)

		local f, s = 0, 0
		if keys.w then
			f += 1
		end
		if keys.s then
			f -= 1
		end
		if keys.d then
			s += 1
		end
		if keys.a then
			s -= 1
		end
		P.sneak = shift
		if f <= 0 or P.sneak then
			P.sprint = false
		elseif ctrl then
			P.sprint = true
		end
		local fx, fz = math.sin(P.yaw), -math.cos(P.yaw)
		local rx, rz = math.cos(P.yaw), math.sin(P.yaw)
		local wx, wz = fx * f + rx * s, fz * f + rz * s
		local len = sqrt(wx * wx + wz * wz)
		if len > 0 then
			wx /= len
			wz /= len
		end
		local feet_wet = water_at(P.x, P.y + 0.1, P.z)
		local body_wet = water_at(P.x, P.y + 0.9, P.z)
		local wet = feet_wet or body_wet
		if wet and not P.wet and P.vy < -4 then
			play("splash", 0.45)
		end
		P.wet = wet
		local speed
		if wet then
			speed = if P.sprint then 3.4 else 2.5
		elseif P.sneak then
			speed = 1.35
		else
			speed = if P.sprint then 5.6 else 4.3
		end
		local accel = if P.ground then 16 elseif wet then 6 else 4
		local k = min(1, accel * dt)
		P.vx += (wx * speed - P.vx) * k
		P.vz += (wz * speed - P.vz) * k
		if wet then
			-- Swimming: a slow sink, Space up, Shift down.
			P.vy -= 5 * dt
			P.vy *= 1 - min(1, 2.2 * dt)
			if keys[" "] then
				P.vy = min(P.vy + 16 * dt, 2.8)
			elseif P.sneak then
				P.vy = max(P.vy - 6 * dt, -3)
			end
		else
			P.vy = max(P.vy - 28 * dt, -40)
			if keys[" "] and P.ground then
				P.vy = 8.6
				if P.sprint then
					-- A sprint jump carries ahead.
					P.vx += fx * 1.6
					P.vz += fz * 1.6
				end
			end
		end

		local ox, oz = P.x, P.z
		local was_ground = P.ground
		local vy_before = P.vy
		local most = max(abs(P.vx), abs(P.vy), abs(P.vz)) * dt
		local steps = max(1, math.ceil(most / 0.35))
		local h = dt / steps
		P.ground = false
		local walled = false
		for _ = 1, steps do
			if move_axis(1, P.vx * h) then
				P.vx = 0
				walled = true
			end
			if move_axis(3, P.vz * h) then
				P.vz = 0
				walled = true
			end
			local dy = P.vy * h
			if move_axis(2, dy) then
				if dy < 0 then
					P.ground = true
				end
				P.vy = 0
			end
		end
		-- Out of the water: swimming into a bank lifts you over it.
		if wet and walled and len > 0 and (keys[" "] or f > 0) then
			P.vy = max(P.vy, if keys[" "] then 6.4 else 4.2)
		end
		if walled and P.sprint and len > 0 then
			P.sprint = false
		end
		if P.y < -20 then
			P.x, P.y, P.z = w.spawn[1], w.spawn[2], w.spawn[3]
			P.vx, P.vy, P.vz = 0, 0, 0
		end

		-- Landing: a thud after a real fall.
		if not was_ground and P.ground then
			local fell = P.fall_from - P.y
			local under_id = get_block(w, floor(P.x), floor(P.y - 0.05), floor(P.z))
			if fell > 3.2 and not wet then
				play("land", 0.5)
				block_sound(under_id, 0.5)
			elseif vy_before < -6 then
				block_sound(under_id, 0.22)
			end
		end
		if P.ground or wet then
			P.fall_from = P.y
		else
			P.fall_from = max(P.fall_from, P.y)
		end

		-- The stride: the bob, the legs and the footsteps.
		local moved = sqrt((P.x - ox) ^ 2 + (P.z - oz) ^ 2)
		local striding = P.ground and moved > 0.001
		amp += ((if striding then min(1.2, (moved / dt) / 4.3) else 0) - amp) * min(1, 10 * dt)
		if P.ground then
			walk += moved
		end
		local stride = 1.25
		if P.ground and not P.sneak and walk >= step_at + stride then
			step_at = walk
			block_sound(get_block(w, floor(P.x), floor(P.y - 0.05), floor(P.z)), 0.16)
		elseif walk >= step_at + stride then
			step_at = walk
		end
		if wet and len > 0 then
			swim_at -= dt
			if swim_at <= 0 then
				swim_at = 0.9
				play(if math.random() < 0.5 then "swim1" else "swim2", 0.18)
			end
		end

		-- The eyes lower as you crouch.
		local eye_to = if P.sneak then 1.32 else EYE
		P.eye += (eye_to - P.eye) * min(1, 14 * dt)

		target, before = raycast()

		-- Breaking: the held button wears the targeted block down; looking
		-- at another starts over.
		mine_gap = max(0, mine_gap - dt)
		local hard = target and items.break_time(target[4], held_id())
		if mining and hard and mine_gap <= 0 then
			local key = string.format("%d,%d,%d", target[1], target[2], target[3])
			if key ~= mine_key then
				mine_key, mine_prog = key, 0
				hit_tick = 0
			end
			mine_prog += dt / hard
			hit_tick -= dt
			if hit_tick <= 0 then
				hit_tick = 0.25
				block_sound(target[4], 0.25)
				if before then
					-- Bits off the face being hit.
					local fx2 = target[1] + 0.5 + (before[1] - target[1]) * 0.52
					local fy2 = target[2] + 0.5 + (before[2] - target[2]) * 0.52
					local fz2 = target[3] + 0.5 + (before[3] - target[3]) * 0.52
					spawn_bits(target[4], fx2, fy2, fz2, 2, 0.6)
				end
			end
			if swing_t >= 1 then
				swing()
			end
			if mine_prog >= 1 then
				break_block()
				mine_key, mine_prog = "", 0
				mine_gap = 0.25
			end
		else
			mine_key, mine_prog = "", 0
			if mining and swing_t >= 1 and not target then
				swing()
			end
		end

		-- Water flows, a step every 0.2 s.
		flow_at -= dt
		if flow_at <= 0 then
			flow_at = 0.2
			if #flow > 0 then
				flow_step()
			end
		end
	end

	local function send(now: number, n_ents: number, n_mobs: number)
		if not el then
			return
		end
		local s = screen:peek()
		local panorama = s == "title" or s == "loading" or s == "confirm" or ((s == "options" or s == "controls") and back_to == "title")
		local cx, cy, cz, cyaw, cpitch = P.x, P.y + P.eye, P.z, P.yaw, P.pitch
		local held_v = -1
		local tp = 0
		local limb = 0
		local tx, ty, tz = -1, 0, 0
		local fov = settings.fov
		local under = false
		if panorama then
			-- The title's view: turning slowly over the middle of the island.
			cx, cy, cz = WX / 2, 37, WZ / 2
			cyaw, cpitch = title_turn, -0.2
		else
			local hs = inv:peek()[selected:peek()]
			held_v = (if hs == 0 then 0 else hs.id) + (if P.sneak then 0.5 else 0)
			limb = math.sin(walk * math.pi / 1.25) * 0.75 * amp
			if target then
				tx, ty, tz = target[1], target[2], target[3]
			end
			local dx, dy, dz = look_dir()
			if third then
				tp = third_distance(cx, cy, cz, dx, dy, dz)
				cx, cy, cz = cx - dx * tp, cy - dy * tp, cz - dz * tp
				tp = max(tp, 0.01)
			elseif settings.bob then
				-- The bob: side to side and a dip each step.
				local ph = walk * math.pi / 1.25
				local b = 0.05 * amp
				cx += math.cos(P.yaw) * math.sin(ph) * b
				cz += math.sin(P.yaw) * math.sin(ph) * b
				cy -= abs(math.cos(ph)) * b * 1.2
			end
			under = water_at(cx, cy, cz)
			fov_now += ((if P.sprint then fov * 1.12 else fov) - fov_now) * 0.2
			fov = fov_now
		end
		local flags = (if under then 1 else 0) + 2 + 4 * floor(clamp(fov, 30, 140) + 0.5)
		local sw = if swing_t < 1 then swing_t else 0
		-- (Every frame: the time moves the sea, the clouds and the drops'
		-- bob; params animate the layer without repainting it.)
		local vals = {
			cx,
			cy,
			cz,
			cyaw,
			cpitch,
			(now / 1000) % 1000,
			flags,
			mine_prog,
			tx,
			ty,
			tz,
			held_v,
			sw,
			limb,
			tp,
			n_ents + 64 * n_mobs,
		}
		local p = {}
		for i = 1, 16 do
			p["layerParam" .. tostring(i - 1)] = vals[i]
		end
		anime.utils.set(el, p)
	end

	-- A state to start in, for pictures of the game without a person
	-- (tools/preview): its screen, view, held blocks, mining.
	apply_preview = function(pv)
		if pv.screen then
			go(pv.screen)
		end
		if pv.pos then
			P.x, P.y, P.z = pv.pos[1], pv.pos[2], pv.pos[3]
		end
		P.yaw = pv.yaw or P.yaw
		P.pitch = pv.pitch or P.pitch
		third = pv.third == true
		mining = pv.mining == true
		if pv.items then
			local list = empty_inventory()
			for i, it in pv.items do
				list[i] = if it then { id = it[1], n = it[2] } else 0
			end
			inv:set(list)
		end
		if pv.selected then
			select_slot(pv.selected)
		end
		if pv.held then
			held:set({ id = pv.held[1], n = pv.held[2] })
		end
		if pv.cursor then
			locked_s:set(true)
			cur:set(pv.cursor)
		end
		if pv.hover then
			hover_slot:set(pv.hover)
		end
		if pv.sel then
			sel:set(pv.sel)
		end
		if pv.grid then
			local g = { 0, 0, 0, 0, 0, 0, 0, 0, 0 }
			for k, it in pv.grid do
				g[k] = if it then { id = it[1], n = it[2] } else 0
			end
			grid:set(g)
		end
		if pv.grid_n then
			grid_n:set(pv.grid_n)
		end
		if pv.mobs then
			mobs = {}
			local dx, _, dz = look_dir()
			for k, kind in pv.mobs do
				local mx = P.x + dx * (3 + k * 1.3) + (k % 2 - 0.5) * 2.2
				local mz = P.z + dz * (3 + k * 1.3)
				local top = nil
				for y = WY - 2, 1, -1 do
					if solid(floor(mx), y, floor(mz)) then
						top = y + 1
						break
					end
				end
				local m = mobsmod.new(kind, mx, top or P.y, mz)
				m.yaw = P.yaw + math.pi * (0.5 + k * 0.3)
				m.goal = m.yaw
				m.mode = "walk"
				m.t = 100
				table.insert(mobs, m)
			end
		end
		if pv.drops then
			local dx, _, dz = look_dir()
			for k = 1, pv.drops do
				spawn_drop(({ DIRT, STONE, LOG, SAND, GRASS })[(k - 1) % 5 + 1], 1, P.x + dx * (1.5 + k * 0.5) + (k % 2) * 0.6, P.y + 1, P.z + dz * (1.5 + k * 0.5), 0, 0, 0, 5)
			end
		end
		target, before = raycast()
	end

	local last_frame = ui.now()
	local timer = nil
	local function frame()
		local now = ui.now()
		local dt = min(0.05, (now - last_frame) / 1000)
		last_frame = now
		if gen then
			local ok, err = coroutine.resume(gen)
			if not ok then
				print("block world: world generation failed: " .. tostring(err))
				gen = nil
			elseif coroutine.status(gen) == "dead" then
				gen = nil
				bump_all()
				ready:set(true)
				target, before = raycast()
				if not mobs_restored then
					populate()
				end
				go(start_after)
				if props.preview then
					apply_preview(props.preview)
				end
				send(now, 0, 0)
			end
			return
		end
		if not ready:peek() then
			return
		end
		local s = screen:peek()
		title_turn += dt * 0.05
		if s == "game" then
			update(dt)
		end
		if s == "game" or s == "inventory" or s == "pause" then
			update_entities(if s == "pause" then 0 else dt, s == "game")
		end
		if s ~= "pause" and s ~= "loading" then
			-- (They go on living behind the title and the inventory too.)
			update_mobs(dt)
		end
		if swing_t < 1 then
			swing_t = min(1, swing_t + dt / 0.28)
		end
		local n = paint_entities()
		local nm = paint_mobs()
		send(now, n, nm)
		frames += 1
		if now - fps_at >= 500 then
			fps = floor(frames * 1000 / (now - fps_at) + 0.5)
			frames, fps_at = 0, now
		end
		if now - hud_at > 100 then
			hud_at = now
			now_s:set(now)
			if show_debug:peek() then
				debug:set(string.format(
					"Block World   %d fps\nXYZ %.2f / %.2f / %.2f\nFacing %s   %d drops%s",
					fps,
					P.x,
					P.y,
					P.z,
					({ "north", "east", "south", "west" })[floor(((P.yaw % (2 * math.pi)) / (math.pi / 2)) + 0.5) % 4 + 1],
					#drops,
					if target then "\nLooking at " .. (NAMES[target[4]] or "") else ""
				))
			end
			if notice:peek() ~= "" and now - notice_at > 1800 then
				notice:set("")
			end
		end
		if dirty_save and now - save_at > 3000 then
			save_at = now
			save_now()
		end
	end

	ui.on_cleanup(function()
		if timer then
			pcall(function()
				timer:pause()
			end)
		end
		unlock()
		if dirty_save then
			save_now()
		end
	end)

	-- Input.
	local function on_key(e)
		local k = string.lower(tostring(e.key))
		if e.cmd then
			return false
		end
		local s = screen:peek()
		if k == "f3" then
			show_debug:set(not show_debug:peek())
			return true
		end
		if s == "inventory" then
			if k == "e" or k == "escape" then
				close_inventory()
				if not locked then
					lock()
				end
			end
			return true
		end
		if s ~= "game" then
			return menu_key(k)
		end
		if not locked and (k == "enter" or k == " ") then
			lock()
			return true
		end
		-- (Escape while the pointer is held never gets here: it lets the
		-- pointer go, and `on_pointer_lock` pauses.)
		if k == "escape" then
			unlock()
			go("pause")
			keys = {}
			return true
		end
		if e["repeat"] then
			return true
		end
		local n = tonumber(k)
		if n and n >= 1 and n <= 9 then
			select_slot(n)
		elseif k == "e" then
			open_inventory()
		elseif k == "q" then
			drop_one()
		elseif k == "f5" or k == "v" then
			third = not third
		else
			if k == "w" then
				local now = ui.now()
				if now - last_w < 280 and not P.sneak then
					P.sprint = true
				end
				last_w = now
			end
			keys[k] = true
		end
		return true
	end

	-- The world's data, painted for the shader. Each still part in a layer of
	-- its own (a shader that passes it through): cached, so a change to one
	-- part, or to the entities' row every frame, repaints that part alone,
	-- not every block of the world.
	local pass = ui.layer_shader("fn layer(input: LayerInput) -> vec4<f32> {\n\treturn input.color;\n}")
	local function cached(left: number, top: number, cw: number, ch: number, canvas)
		return ui.div { absolute = true, left = left, top = top, w = cw, h = ch, layer_shader = pass, canvas }
	end
	local data = {}
	for t = 0, 15 do
		local rev = revs[t + 1]
		table.insert(data, cached((t % 4) * WX, (t // 4) * WZ, WX, WZ, ui.canvas {
			w = WX,
			h = WZ,
			draw = function(c)
				rev:get()
				if not w or not ready:get() then
					return
				end
				local ovr = w.ovr
				local y0 = t * 3
				local colors = {}
				for z = 0, WZ - 1 do
					local run_key, run_at = 0, 0
					for x = 0, WX do
						local key = 0
						if x < WX then
							local r = readu8(ovr, idx(x, y0, z))
							local g = readu8(ovr, idx(x, y0 + 1, z))
							local b = readu8(ovr, idx(x, y0 + 2, z))
							key = r * 1024 + g * 32 + b
						end
						if key ~= run_key then
							if run_key ~= 0 then
								local col = colors[run_key]
								if not col then
									col = hex((run_key // 1024) * 8, ((run_key // 32) % 32) * 8, (run_key % 32) * 8)
									colors[run_key] = col
								end
								c:rect(run_at, z, x - run_at, 1, col)
							end
							run_key, run_at = key, x
						end
					end
				end
			end,
		}))
	end
	table.insert(data, cached(4 * WX, 0, WX, WZ, ui.canvas {
		w = WX,
		h = WZ,
		draw = function(c)
			hm_rev:get()
			if not w or not ready:get() then
				return
			end
			for z = 0, WZ - 1 do
				local run_key, run_at = -1, 0
				for x = 0, WX do
					local key = -1
					if x < WX then
						local at = z * WX + x
						key = readu8(w.height, at) * 8 + readu8(w.surf, at)
					end
					if key ~= run_key then
						if run_key >= 0 then
							c:rect(run_at, z, x - run_at, 1, hex((run_key // 8) * 4, (run_key % 8) * 32, 255))
						end
						run_key, run_at = key, x
					end
				end
			end
		end,
	}))
	-- The entities' row (see shaders.luau's tb_ent_px).
	table.insert(data, ui.canvas {
		absolute = true,
		left = 4 * WX,
		top = WZ,
		w = WX,
		h = 1,
		draw = function(c)
			ent_rev:get()
			for k, col in ent_px do
				c:rect(k - 1, 0, 1, 1, col)
			end
		end,
	})
	-- The items' pictures (see shaders.luau's tb_icon).
	table.insert(data, cached(4 * WX, WZ + 2, 96, 96, ui.image {
		src = "icons/atlas.png",
		w = 96,
		h = 96,
		image_rendering = "pixelated",
	}))
	-- The mobs' row (see shaders.luau's tb_mob_px).
	table.insert(data, ui.canvas {
		absolute = true,
		left = 4 * WX,
		top = WZ + 1,
		w = WX,
		h = 1,
		draw = function(c)
			mob_rev:get()
			for k, col in mob_px do
				c:rect(k - 1, 0, 1, 1, col)
			end
		end,
	})

	local view = ui.div {
		absolute = true,
		left = 0,
		top = 0,
		right = 0,
		bottom = 0,
		min_w = DATA_W,
		min_h = DATA_H,
		layer_shader = world_shader,
		layer_params = { { 48, 30, 48, 0 }, { 0, 0, 0, 0 }, { -1, 0, 0, -1 }, { 0, 0, 0, 0 } },
		on_mount = function(e)
			el = e
			last_frame = ui.now()
			timer = anime.createTimer {
				loop = true,
				onUpdate = function()
					frame()
				end,
			}
		end,
		-- Fills the box, so the layer (and the shader over it) spans all of it.
		ui.div { absolute = true, left = 0, top = 0, right = 0, bottom = 0, bg = "#00000001" },
		table.unpack(data),
	}

	-- The crosshair: thin white bars with a dark edge, so it shows on sky
	-- and stone alike. (Nothing over the world reads what's behind it, no
	-- blur, no blend: the world redraws every frame, and a reader of it
	-- flickers in Zeron's renderer.)
	local function crosshair()
		local function bar(l, t, ww, hh)
			return ui.div {
				absolute = true,
				left = l,
				top = t,
				w = ww,
				h = hh,
				rounded = 1,
				bg = "#ffffffeb",
				shadow = { x = 0, y = 0, blur = 2, color = "#000000b3" },
			}
		end
		return ui.div {
			absolute = true,
			left = "50%",
			top = "50%",
			w = 0,
			h = 0,
			bar(-8, -1, 16, 2),
			bar(-1, -8, 2, 6),
			bar(-1, 2, 2, 6),
		}
	end

	local function is_sel(id: string): boolean
		local rows = MENUS[screen:get()]
		if not rows then
			return false
		end
		local s = sel:get()
		local row = rows[s[1]]
		return row ~= nil and row[min(s[2], #row)] == id
	end

	-- A menu button: frosted, its rim lit and a glow under it when chosen
	-- (by the cursor or the keys); a slider fills with the accent to its
	-- value.
	local function Button(id: string, width: number)
		local slider = SLIDERS[id]
		return ui.div {
			w = width,
			h = 46,
			rounded = 11,
			overflow = "hidden",
			bg = function()
				return if is_sel(id) then "#2b2f48f0" else "#12151fd9"
			end,
			border = 1,
			border_color = function()
				return if is_sel(id) then UI.accent else UI.rim
			end,
			shadow = function()
				return if is_sel(id)
					then { x = 0, y = 6, blur = 22, color = UI.glow }
					else { x = 0, y = 4, blur = 14, color = "#00000040" }
			end,
			items = "center",
			justify = "center",
			on_mount = function(e)
				btn_els[id] = e
			end,
			if slider
				then ui.div {
					absolute = true,
					left = 0,
					top = 0,
					bottom = 0,
					bg = UI.accent_soft,
					w = function()
						settings_rev:get()
						return slider.get() * width
					end,
				}
				else false,
			if slider
				then ui.div {
					absolute = true,
					top = 11,
					bottom = 11,
					w = 4,
					rounded = 2,
					bg = "#ffffff",
					left = function()
						settings_rev:get()
						return clamp(slider.get() * width - 2, 6, width - 10)
					end,
				}
				else false,
			text(function()
				return label_of(id)
			end, {
				text_size = 15,
				weight = 600,
				color = function()
					return if is_sel(id) then "#ffffff" else UI.text
				end,
			}),
		}
	end

	local function menu_rows(rows)
		local out = {}
		for _, row in rows do
			if #row == 1 then
				table.insert(out, Button(row[1], 380))
			else
				local cells = {}
				for _, id in row do
					table.insert(cells, Button(id, 186))
				end
				table.insert(out, ui.row { gap = 8, table.unpack(cells) })
			end
		end
		return ui.column { gap = 10, items = "center", table.unpack(out) }
	end

	local function fill(props)
		props.absolute = true
		props.left = 0
		props.top = 0
		props.right = 0
		props.bottom = 0
		return ui.div(props)
	end

	-- A menu's page: the world blurred and dimmed behind, a heading (and a
	-- line under it), then its content.
	local function page(title: string, sub: string?, ...)
		return fill {
			bg = "#06080ecc",
			items = "center",
			justify = "center",
			gap = 26,
			ui.column {
				items = "center",
				gap = 6,
				text(title, { text_size = 28, weight = 800, letter_spacing = 0.5 }),
				if sub then text(sub, { text_size = 14, color = UI.dim }) else false,
			},
			...,
		}
	end

	local function hint(t: string)
		return text(t, { text_size = 12, color = UI.faint })
	end

	-- BLOCKWORLD, stacked: a pale stone face over its depth, a soft
	-- shadow, and under it the line it's known by; the splash, gold and
	-- tilted, beats beside it.
	local function logo()
		local SIZE = 84
		local layers = {}
		table.insert(layers, ui.div {
			-- (sized by an invisible copy, the layers over it)
			opacity = 0,
			pb = 14,
			text("BLOCKWORLD", { text_size = SIZE, weight = 900, letter_spacing = 3 }),
		})
		for i = 8, 1, -1 do
			local v = 22 + (8 - i) * 6
			table.insert(layers, ui.div {
				absolute = true,
				left = 0,
				top = i * 1.5,
				text("BLOCKWORLD", {
					text_size = SIZE,
					weight = 900,
					letter_spacing = 3,
					color = hex(v, v, v + 14),
					text_shadow = if i == 8 then { x = 0, y = 10, blur = 30, color = "#000000aa" } else false,
				}),
			})
		end
		table.insert(layers, ui.div {
			absolute = true,
			left = 0,
			top = 0,
			text("BLOCKWORLD", { text_size = SIZE, weight = 900, letter_spacing = 3, color = "#f5f3ee", text_shadow = false }),
		})
		table.insert(layers, ui.div {
			absolute = true,
			right = -46,
			bottom = -6,
			rotate = -14,
			scale = function()
				local t = now_s:get() / 1000
				return 1 + 0.07 * math.abs(math.sin(t * 6.2832 / 1.1))
			end,
			text(function()
				return splash:get()
			end, { text_size = 19, weight = 800, color = UI.gold, text_shadow = { x = 2, y = 2, blur = 0, color = "#3d3300" } }),
		})
		return ui.column {
			items = "center",
			gap = 10,
			ui.div(layers),
			ui.row {
				items = "center",
				gap = 10,
				ui.div { w = 34, h = 2, rounded = 1, bg = "#ffffffcc", shadow = SHADOW },
				text("INSIDE ZERON", { text_size = 13, weight = 800, letter_spacing = 4, text_shadow = { x = 0, y = 1, blur = 6, color = "#000000b3" } }),
				ui.div { w = 34, h = 2, rounded = 1, bg = "#ffffffcc", shadow = SHADOW },
			},
		}
	end

	local title_screen = fill {
		gradient = { angle = 180, stops = { "#0000001a", "#00000000", "#00000099" } },
		items = "center",
		ui.div { h = "15%" },
		logo(),
		ui.div { h = 56 },
		menu_rows(MENUS.title),
		ui.div {
			absolute = true,
			left = 14,
			bottom = 10,
			text("Block World 1.0", { text_size = 12, color = UI.dim }),
		},
		ui.div {
			absolute = true,
			right = 14,
			bottom = 10,
			text("Made in Zeron", { text_size = 12, color = UI.dim }),
		},
	}

	local loading_screen = fill {
		gradient = { angle = 180, stops = { "#141826", "#0a0c14" } },
		items = "center",
		justify = "center",
		gap = 16,
		text("Generating world", { text_size = 20, weight = 700 }),
		ui.div {
			w = 320,
			h = 6,
			rounded = 3,
			bg = "#ffffff1f",
			overflow = "hidden",
			ui.div {
				h = 6,
				rounded = 3,
				gradient = { angle = 90, stops = { "#7b6bff", "#b3a6ff" } },
				w = function()
					return 320 * progress:get()
				end,
			},
		},
		text(function()
			return string.format("%d%%", floor(progress:get() * 100))
		end, { text_size = 12, color = UI.faint }),
	}

	local pause_screen = page("Paused", nil, menu_rows(MENUS.pause), hint("Esc to go back to the game"))

	local options_screen = page("Options", nil, menu_rows(MENUS.options), hint("← → change a slider   ·   Esc when done"))

	local CONTROLS = {
		{ "Look", "Mouse" },
		{ "Move", "W A S D" },
		{ "Jump / swim up", "Space" },
		{ "Sprint", "Double-tap W, or Control" },
		{ "Crouch / swim down", "Shift" },
		{ "Break / hit an animal", "Hold left click" },
		{ "Place / use a crafting table", "Right click" },
		{ "Hotbar", "1 – 9, or the wheel" },
		{ "Select a block you see", "Middle click" },
		{ "Inventory and crafting", "E" },
		{ "Drop one", "Q" },
		{ "Third person", "F5 or V" },
		{ "Debug info", "F3" },
		{ "Pause", "Esc" },
	}

	local function key_cap(t: string)
		return ui.div {
			px = 8,
			py = 3,
			rounded = 6,
			bg = "#ffffff14",
			border = 1,
			border_color = UI.rim,
			text(t, { text_size = 12, weight = 600, text_shadow = false }),
		}
	end

	local controls_screen = page(
		"Controls",
		nil,
		ui.column {
			p = 18,
			gap = 6,
			rounded = 14,
			bg = UI.glass,
			border = 1,
			border_color = UI.rim,
			table.unpack((function()
				local rows = {}
				for _, c in CONTROLS do
					table.insert(rows, ui.row {
						gap = 16,
						items = "center",
						ui.div { w = 210, items = "end", text(c[1], { text_size = 13, color = UI.dim, text_shadow = false }) },
						ui.div { w = 210, items = "start", key_cap(c[2]) },
					})
				end
				return rows
			end)()),
		},
		menu_rows(MENUS.controls)
	)

	local confirm_screen = page(
		"Create a new world?",
		"This world and everything you've collected will be gone.",
		menu_rows(MENUS.confirm)
	)

	-- A row of slots from `from` to `to`, as state of the inventory.
	local function slot_row(from: number, to: number, look: string)
		local slice = ui.computed(function()
			local list = inv:get()
			local out = {}
			for i = from, to do
				table.insert(out, list[i])
			end
			return out
		end)
		return ui.each(slice, function(entry, j: number)
			local i = from + j - 1
			return Slot {
				entry = entry,
				look = look,
				icon = icon_shader,
				number = if look == "hud" then i else nil,
				lit = if look == "hud"
					then function()
						return selected:get() == i
					end
					else function()
						return hover_slot:get() == i
					end,
				on_mount = if look == "panel"
					then function(e)
						inv_els[i] = e
					end
					else nil,
			}
		end, { direction = "row", gap = if look == "hud" then 4 else 4 })
	end

	-- A row of the crafting grid (`n` by `n`).
	local function grid_row(n: number, r: number)
		local slice = ui.computed(function()
			local g = grid:get()
			local out = {}
			for c = 1, n do
				table.insert(out, g[(r - 1) * n + c])
			end
			return out
		end)
		return ui.each(slice, function(entry, c: number)
			local i = GRID0 + (r - 1) * n + c
			return Slot {
				entry = entry,
				look = "panel",
				icon = icon_shader,
				lit = function()
					return hover_slot:get() == i
				end,
				on_mount = function(e)
					inv_els[i] = e
				end,
			}
		end, { direction = "row", gap = 4 })
	end

	local function grid_of(n: number)
		local rows = {}
		for r = 1, n do
			table.insert(rows, grid_row(n, r))
		end
		return ui.column { gap = 4, table.unpack(rows) }
	end

	local function section(t: string)
		return text(t, { text_size = 11, weight = 700, letter_spacing = 1.5, color = UI.faint, text_shadow = false })
	end

	-- The crafting area: the grid, an arrow, what it makes (lit when it
	-- makes something).
	local crafting = ui.row {
		gap = 20,
		items = "center",
		ui.show(function()
			return grid_n:get() == 2
		end, grid_of(2)),
		ui.show(function()
			return grid_n:get() == 3
		end, grid_of(3)),
		text("→", {
			text_size = 26,
			weight = 700,
			text_shadow = false,
			color = function()
				return if craft_out:get() ~= 0 then UI.accent else UI.faint
			end,
		}),
		ui.each(
			ui.computed(function()
				return { craft_out:get() }
			end),
			function(entry)
				return ui.div {
					rounded = 10,
					shadow = if entry ~= 0
						then { x = 0, y = 0, blur = 20, color = UI.glow }
						else { x = 0, y = 0, blur = 0, color = "#00000000" },
					Slot {
						entry = entry,
						look = "panel",
						big = true,
						icon = icon_shader,
						lit = function()
							return hover_slot:get() == OUT or entry ~= 0
						end,
						on_mount = function(e)
							inv_els[OUT] = e
						end,
					},
				}
			end
		),
	}

	-- What's in slot `i` of the inventory screen (0 for nothing).
	local function entry_at(i: number)
		if i <= 0 then
			return 0
		elseif i <= SLOTS then
			return inv:get()[i]
		elseif i == OUT then
			return craft_out:get()
		end
		return grid:get()[i - GRID0]
	end

	-- The name (and a tool's wear) of what's under the cursor, beside it.
	local tooltip = ui.show(
		function()
			return held:get() == 0 and entry_at(hover_slot:get()) ~= 0
		end,
		ui.div {
			absolute = true,
			left = function()
				return cur:get()[1] + 16
			end,
			top = function()
				return cur:get()[2] - 30
			end,
			px = 10,
			py = 6,
			rounded = 8,
			bg = "#0b0d16f2",
			border = 1,
			border_color = UI.accent_soft,
			shadow = { x = 0, y = 6, blur = 18, color = "#00000080" },
			pointer_events = "none",
			gap = 2,
			text(function()
				local e = entry_at(hover_slot:get())
				return if e == 0 then "" else NAMES[e.id] or ""
			end, { text_size = 13, weight = 700, text_shadow = false }),
			ui.show(
				function()
					local e = entry_at(hover_slot:get())
					return e ~= 0 and items.TOOLS[e.id] ~= nil
				end,
				text(function()
					local e = entry_at(hover_slot:get())
					return if e == 0 then "" else string.format("Durability %d / %d", e.d or items.DURABILITY, items.DURABILITY)
				end, { text_size = 11, color = UI.dim, text_shadow = false })
			),
		}
	)

	local inventory_screen = fill {
		bg = "#06080eb3",
		items = "center",
		justify = "center",
		gap = 14,
		ui.column {
			gap = 14,
			p = 20,
			rounded = 18,
			bg = UI.glass_strong,
			border = 1,
			border_color = UI.rim,
			shadow = LIFT,
			ui.row {
				justify = "between",
				items = "center",
				text(function()
					return if grid_n:get() == 3 then "Crafting Table" else "Inventory"
				end, { text_size = 17, weight = 800 }),
				hint("E to close"),
			},
			ui.column { gap = 8, section("CRAFTING"), crafting },
			ui.div { h = 1, bg = UI.rim },
			ui.column {
				gap = 4,
				section("INVENTORY"),
				ui.div { h = 4 },
				slot_row(10, 18, "panel"),
				slot_row(19, 27, "panel"),
				slot_row(28, 36, "panel"),
				ui.div { h = 8 },
				slot_row(1, 9, "panel"),
			},
		},
		hint("Click: take or put   ·   Right-click: half or one   ·   Shift-click: move across, or craft all"),
		tooltip,
		-- The stack on the cursor.
		ui.show(
			function()
				return held:get() ~= 0
			end,
			ui.div {
				absolute = true,
				pointer_events = "none",
				left = function()
					return cur:get()[1] - 22
				end,
				top = function()
					return cur:get()[2] - 22
				end,
				ui.each(
					ui.computed(function()
						local h = held:get()
						return if h == 0 then {} else { h }
					end),
					function(entry)
						return ui.div {
							w = 44,
							h = 44,
							items = "center",
							justify = "center",
							shadow = { x = 0, y = 8, blur = 18, color = "#00000066" },
							rounded = 8,
							thing(entry.id, 32, icon_shader),
							if entry.n > 1
								then ui.div {
									absolute = true,
									right = 3,
									bottom = 1,
									text(tostring(entry.n), { text_size = 13, weight = 800 }),
								}
								else false,
						}
					end
				),
			}
		),
	}

	local function pill(content)
		return ui.div {
			px = 12,
			py = 5,
			rounded = 999,
			bg = "#0b0d16d9",
			border = 1,
			border_color = UI.rim,
			content,
		}
	end

	local hud = fill {
		crosshair(),
		-- F3: what the game knows, plain, as a debug screen is.
		ui.div {
			absolute = true,
			left = 12,
			top = 12 + (props.bleed or 0),
			ui.show(
				function()
					return show_debug:get()
				end,
				ui.div {
					p = 8,
					rounded = 8,
					bg = "#000000a0",
					text(function()
						return debug:get()
					end, { font = "mono", text_size = 12, text_shadow = false }),
				}
			),
		},
		ui.show(
			function()
				return not locked_s:get() and screen:get() == "game"
			end,
			ui.div {
				absolute = true,
				left = 0,
				right = 0,
				top = "56%",
				items = "center",
				pill(ui.row {
					gap = 8,
					items = "center",
					text("Click to play", { text_size = 14, weight = 700, text_shadow = false }),
					text("Esc pauses", { text_size = 12, color = UI.faint, text_shadow = false }),
				}),
			}
		),
		ui.div {
			absolute = true,
			left = 0,
			right = 0,
			bottom = 14,
			items = "center",
			gap = 8,
			ui.show(function()
				return notice:get() ~= ""
			end, pill(text(function()
				return notice:get()
			end, { text_size = 12, color = UI.dim, text_shadow = false }))),
			-- The selected thing's name, a moment as it changes.
			ui.div {
				opacity = function()
					local age = now_s:get() - name_shown:get()
					local s = inv:get()[selected:get()]
					return if s == 0 then 0 else clamp(1 - (age - 1600) / 400, 0, 1)
				end,
				pill(text(function()
					local s = inv:get()[selected:get()]
					return if s == 0 then " " else NAMES[s.id] or ""
				end, { text_size = 13, weight = 700, text_shadow = false })),
			},
			ui.div {
				p = 6,
				rounded = 14,
				bg = UI.glass,
				border = 1,
				border_color = UI.rim,
				shadow = { x = 0, y = 8, blur = 26, color = "#00000059" },
				slot_row(1, 9, "hud"),
			},
		},
	}

	-- The game's own cursor, while the menus hold the pointer.
	local cursor_node = ui.show(
		function()
			return locked_s:get() and screen:get() ~= "game"
		end,
		ui.div {
			absolute = true,
			pointer_events = "none",
			left = function()
				return cur:get()[1]
			end,
			top = function()
				return cur:get()[2]
			end,
			arrow_canvas(),
		}
	)

	local function on_screen(name: string, node)
		return ui.show(function()
			return screen:get() == name
		end, node)
	end

	-- `bleed`: how far above its box the game reaches (in Zeron, up into
	-- the title bar's strip, whose controls stay drawn over it).
	local bleed = props.bleed or 0
	return ui.div {
		absolute = if bleed > 0 then true else nil,
		left = if bleed > 0 then 0 else nil,
		right = if bleed > 0 then 0 else nil,
		bottom = if bleed > 0 then 0 else nil,
		top = if bleed > 0 then -bleed else nil,
		w_full = if bleed > 0 then nil else true,
		h_full = if bleed > 0 then nil else true,
		min_w = DATA_W,
		min_h = DATA_H,
		overflow = "hidden",
		bg = "#6699f9",
		focusable = true,
		cursor = "default",
		on_mount = function(e)
			root = e
			pcall(function()
				e:focus()
			end)
		end,
		on_key = on_key,
		on_key_up = function(k)
			k = string.lower(tostring(k))
			keys[k] = nil
			if k == "w" then
				P.sprint = false
			end
		end,
		on_blur = function()
			keys = {}
			mining = false
		end,
		-- The pointer held (true) or let go (false): Escape, the window losing
		-- focus. Playing, that pauses; in the inventory it closes and the game
		-- takes the pointer back if it may.
		on_pointer_lock = function(now_locked)
			locked = now_locked
			locked_s:set(now_locked)
			if now_locked then
				return
			end
			keys = {}
			mining = false
			local s = screen:peek()
			if s == "game" then
				go("pause")
			elseif s == "inventory" then
				close_inventory()
				if not lock() then
					go("pause")
				end
			end
		end,
		on_press = function(e)
			local s = screen:peek()
			if s == "game" then
				if not locked then
					lock()
					return
				end
				if attack() then
					return
				end
				mining = true
				swing()
			elseif s == "inventory" then
				local i = slot_at()
				if i > 0 then
					click_slot(i, false, e and e.shift or false)
				end
			else
				local id = button_at()
				if id then
					if SLIDERS[id] then
						dragging = id
						slider_to_cursor(id)
					else
						activate(id)
					end
				end
			end
		end,
		on_pointer_move = function(e)
			local s = screen:peek()
			if e.locked then
				local sens = 0.0012 + settings.sens * 0.004
				if s == "game" then
					P.yaw += (e.dx or 0) * sens
					P.pitch = clamp(P.pitch - (e.dy or 0) * sens, -1.55, 1.55)
					return
				end
				local rw, rh = root_size()
				local c = cur:peek()
				cur:set({ clamp(c[1] + (e.dx or 0), 0, rw - 2), clamp(c[2] + (e.dy or 0), 0, rh - 2) })
			elseif root and root.x then
				cur:set({ e.x - root.x, e.y - root.y })
			else
				cur:set({ e.local_x, e.local_y })
			end
			if s ~= "game" then
				hovered()
			end
		end,
		on_release = function()
			mining = false
			if dragging then
				dragging = nil
				dirty_save = true
			end
		end,
		on_aux_click = function(e)
			if e.button == "middle" and screen:peek() == "game" then
				pick_block()
			end
		end,
		context_menu = function()
			local s = screen:peek()
			if s == "game" and locked then
				if target and target[4] == CRAFT and not P.sneak then
					swing()
					open_inventory(3)
				else
					place_block()
				end
			elseif s == "inventory" then
				local i = slot_at()
				if i > 0 then
					click_slot(i, true, false)
				end
			end
			return {}
		end,
		on_wheel = function(e)
			if screen:peek() ~= "game" then
				return false
			end
			local step = if e.dy > 0 then 1 elseif e.dy < 0 then -1 else 0
			if step ~= 0 then
				select_slot((selected:peek() - 1 + step) % 9 + 1)
			end
			return true
		end,
		view,
		ui.show(function()
			local s = screen:get()
			return s == "game" or s == "inventory" or s == "pause"
		end, hud),
		on_screen("inventory", inventory_screen),
		on_screen("pause", pause_screen),
		on_screen("title", title_screen),
		on_screen("options", options_screen),
		on_screen("controls", controls_screen),
		on_screen("confirm", confirm_screen),
		on_screen("loading", loading_screen),
		cursor_node,
	}
end)
