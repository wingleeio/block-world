--!nonstrict
-- Block World's animals: chickens, pigs and sheep. Each wanders (stands a
-- while, walks a while), hops up a block in its way, keeps off cliffs and
-- out of water unless it's fleeing, floats if it falls in, runs when hit,
-- and drops what it drops when it dies. shaders.luau draws them (tb_mobs).

local items = require("./items")

local M = {}

M.CHICKEN, M.PIG, M.SHEEP = 1, 2, 3

M.KINDS = {
	[M.CHICKEN] = { name = "chicken", hp = 4, speed = 1.3, hw = 0.2, h = 0.7, drops = { { items.EGG, 0, 1 } } },
	[M.PIG] = { name = "pig", hp = 10, speed = 1.3, hw = 0.45, h = 0.9, drops = { { items.PORK, 1, 3 } } },
	[M.SHEEP] = { name = "sheep", hp = 8, speed = 1.2, hw = 0.45, h = 1.3, drops = { { items.WOOL, 1, 1 } } },
}

local floor, abs, min, max, sqrt = math.floor, math.abs, math.min, math.max, math.sqrt

function M.new(kind: number, x: number, y: number, z: number)
	return {
		kind = kind,
		x = x,
		y = y,
		z = z,
		vx = 0,
		vy = 0,
		vz = 0,
		yaw = math.random() * math.pi * 2,
		goal = 0,
		hp = M.KINDS[kind].hp,
		mode = "idle",
		t = math.random() * 3,
		panic = 0,
		ground = false,
		walk = 0,
		amp = 0,
		hurt = 0,
		tilt = 0,
		graze = 0,
		say = 4 + math.random() * 12,
		-- (a chicken lays an egg every few minutes)
		lay = 120 + math.random() * 240,
	}
end

local function collides(m, k, x: number, y: number, z: number, solid): boolean
	for by = floor(y), floor(y + k.h - 1e-6) do
		for bz = floor(z - k.hw), floor(z + k.hw - 1e-6) do
			for bx = floor(x - k.hw), floor(x + k.hw - 1e-6) do
				if solid(bx, by, bz) then
					return true
				end
			end
		end
	end
	return false
end

-- Moves along one axis; true when something stopped it.
local function move(m, k, axis: number, d: number, solid): boolean
	if d == 0 then
		return false
	end
	local x, y, z = m.x, m.y, m.z
	if axis == 1 then
		x += d
	elseif axis == 2 then
		y += d
	else
		z += d
	end
	if not collides(m, k, x, y, z, solid) then
		m.x, m.y, m.z = x, y, z
		return false
	end
	if axis == 2 and d < 0 then
		m.y = floor(y) + 1
	end
	return true
end

-- One step of a mob's life. `env`: solid(x, y, z) and water(x, y, z) of
-- whole blocks, `px`, `pz` the player.
function M.update(m, dt: number, env)
	local k = M.KINDS[m.kind]
	m.t -= dt
	m.hurt = max(0, m.hurt - dt)
	m.panic = max(0, m.panic - dt)
	local solid, water = env.solid, env.water
	local wet = water(floor(m.x), floor(m.y + 0.2), floor(m.z))

	-- Deciding what to do next.
	if m.panic > 0 then
		if m.t <= 0 then
			m.t = 0.5 + math.random() * 0.6
			m.goal = math.random() * math.pi * 2
			m.mode = "walk"
		end
	elseif m.t <= 0 then
		if m.mode == "walk" or math.random() < 0.35 then
			m.mode = "idle"
			m.t = 2 + math.random() * 5
			-- Sheep and pigs graze now and then: the head goes down a while.
			m.graze = if m.kind ~= M.CHICKEN and math.random() < 0.4 then 1.5 + math.random() * 1.5 else 0
		else
			m.mode = "walk"
			m.t = 1.5 + math.random() * 3.5
			m.goal = math.random() * math.pi * 2
		end
	end
	m.graze = max(0, m.graze - dt)
	m.tilt += ((if m.graze > 0 then 0.7 else 0) - m.tilt) * min(1, 6 * dt)

	-- Turning toward where it's going.
	local diff = (m.goal - m.yaw + math.pi) % (2 * math.pi) - math.pi
	local rate = if m.panic > 0 then 8 else 3.5
	m.yaw += math.clamp(diff, -rate * dt, rate * dt)

	local speed = 0
	if m.mode == "walk" then
		speed = k.speed * (if m.panic > 0 then 2.1 else 1)
	end
	local fx, fz = math.sin(m.yaw), -math.cos(m.yaw)
	-- Keeping off a drop of more than two blocks, and out of water, unless
	-- running.
	if speed > 0 and m.panic <= 0 and m.ground then
		local ax, az = floor(m.x + fx * (k.hw + 0.4)), floor(m.z + fz * (k.hw + 0.4))
		local by = floor(m.y)
		local cliff = not solid(ax, by - 1, az) and not solid(ax, by - 2, az) and not solid(ax, by - 3, az)
		if cliff or water(ax, by, az) or water(ax, by - 1, az) then
			m.goal = m.yaw + math.pi
			m.mode = "idle"
			m.t = 0.5 + math.random()
			speed = 0
		end
	end
	local accel = if m.ground then 12 else 3
	local kk = min(1, accel * dt)
	m.vx += (fx * speed - m.vx) * kk
	m.vz += (fz * speed - m.vz) * kk
	if wet then
		m.vy += (1.4 - m.vy) * min(1, 4 * dt)
	else
		m.vy = max(m.vy - 26 * dt, if m.kind == M.CHICKEN then -3.5 else -30)
	end

	local ox, oz = m.x, m.z
	local was_ground = m.ground
	m.ground = false
	local blocked = false
	if move(m, k, 1, m.vx * dt, solid) then
		m.vx = 0
		blocked = true
	end
	if move(m, k, 3, m.vz * dt, solid) then
		m.vz = 0
		blocked = true
	end
	if move(m, k, 2, m.vy * dt, solid) then
		if m.vy < 0 then
			m.ground = true
		end
		m.vy = 0
	end
	-- A block in the way: a hop up onto it.
	if blocked and speed > 0 and (was_ground or wet) then
		m.vy = if wet then 5 else 7.2
	end
	if m.y < -10 then
		m.hp = 0
	end

	local moved = sqrt((m.x - ox) ^ 2 + (m.z - oz) ^ 2)
	m.walk += moved
	m.amp += ((if moved > 0.002 then 1 else 0) - m.amp) * min(1, 8 * dt)

	-- A chicken lays an egg now and then.
	if m.kind == M.CHICKEN and m.ground then
		m.lay = (m.lay or 200) - dt
		if m.lay <= 0 then
			m.lay = 300 + math.random() * 300
			if env.lay then
				env.lay(m)
			end
		end
	end

	-- Now and then a sound, if the player's near.
	m.say -= dt
	if m.say <= 0 then
		m.say = 6 + math.random() * 14
		local d = sqrt((m.x - env.px) ^ 2 + (m.z - env.pz) ^ 2)
		if d < 16 then
			env.play(k.name .. tostring(math.random(1, 2)), 0.5 * (1 - d / 16))
		end
	end
end

-- The legs' swing now, -1..1.
function M.limb(m): number
	return math.sin(m.walk * math.pi / (if m.kind == M.CHICKEN then 0.45 else 0.8)) * m.amp
end

-- Hit for `dmg` from (fx, fz): knocked back, set running. True if it died.
function M.hit(m, dmg: number, fx: number, fz: number): boolean
	m.hp -= dmg
	m.hurt = 0.35
	local dx, dz = m.x - fx, m.z - fz
	local l = sqrt(dx * dx + dz * dz)
	if l > 1e-3 then
		m.vx, m.vz = dx / l * 5, dz / l * 5
	end
	m.vy = 4.5
	m.panic = 5
	m.mode = "walk"
	m.t = 0
	m.goal = math.atan2(dx, -dz)
	m.yaw = m.goal
	return m.hp <= 0
end

-- Where a ray from (ox, oy, oz) along (dx, dy, dz) first meets its box, or nil.
function M.ray(m, ox: number, oy: number, oz: number, dx: number, dy: number, dz: number): number?
	local k = M.KINDS[m.kind]
	local lo: { number } = { m.x - k.hw, m.y, m.z - k.hw }
	local hi: { number } = { m.x + k.hw, m.y + k.h, m.z + k.hw }
	local o: { number } = { ox, oy, oz }
	local d: { number } = { dx, dy, dz }
	local tn: number, tf: number = -math.huge, math.huge
	for i = 1, 3 do
		if abs(d[i]) < 1e-9 then
			if o[i] < lo[i] or o[i] > hi[i] then
				return nil
			end
		else
			local a: number, b: number = (lo[i] - o[i]) / d[i], (hi[i] - o[i]) / d[i]
			if a > b then
				a, b = b, a
			end
			tn, tf = max(tn, a), min(tf, b)
		end
	end
	if tf < max(tn, 0) then
		return nil
	end
	return max(tn, 0)
end

-- What it drops when it dies: a list of { id, n }.
function M.drops(m): { { number } }
	local out = {}
	for _, d in M.KINDS[m.kind].drops do
		local n = d[2] + floor(math.random() * (d[3] - d[2] + 1))
		if n > 0 then
			table.insert(out, { d[1], n })
		end
	end
	return out
end

return M
