--!nonstrict
-- Block World's things: every block and item by id, how each block breaks
-- (by hand, and with the tool that's quicker), what it drops, the tools,
-- and the crafting recipes.
--
-- Ids 1..21 are blocks (they live in the world: shaders.luau reads them,
-- (id + 1) * 8 in a colour channel, so at most 30). 22 and on are items,
-- never placed: their pictures are Pixel Perfection's (CC BY-SA 4.0;
-- icons/, made by tools/make_icons.py), in M.ICONS, in id order in
-- icons/atlas.png.

local M = {}

M.AIR, M.GRASS, M.DIRT, M.STONE, M.COBBLE, M.PLANKS, M.LOG, M.LEAVES, M.SAND, M.WATER = 0, 1, 2, 3, 4, 5, 6, 7, 8, 9
M.GLASS, M.BRICKS, M.BEDROCK, M.COAL, M.IRON, M.SNOW, M.GRAVEL, M.GOLD, M.WOOL, M.STONEBRICK, M.BOOKS =
	10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20
M.CRAFT = 21
M.STICK, M.PICK, M.AXE, M.SHOVEL, M.SWORD, M.EGG, M.PORK, M.APPLE = 22, 23, 24, 25, 26, 27, 28, 29
M.FIRST_ITEM = 22

-- Each item's picture: icons/<name>.png.
M.ICONS = {
	[M.STICK] = "stick",
	[M.PICK] = "pickaxe",
	[M.AXE] = "axe",
	[M.SHOVEL] = "shovel",
	[M.SWORD] = "sword",
	[M.EGG] = "egg",
	[M.PORK] = "porkchop",
	[M.APPLE] = "apple",
}

M.NAMES = {
	[M.GRASS] = "Grass Block",
	[M.DIRT] = "Dirt",
	[M.STONE] = "Stone",
	[M.COBBLE] = "Cobblestone",
	[M.PLANKS] = "Planks",
	[M.LOG] = "Log",
	[M.LEAVES] = "Leaves",
	[M.SAND] = "Sand",
	[M.WATER] = "Water",
	[M.GLASS] = "Glass",
	[M.BRICKS] = "Bricks",
	[M.BEDROCK] = "Bedrock",
	[M.COAL] = "Coal Ore",
	[M.IRON] = "Iron Ore",
	[M.SNOW] = "Snowy Grass",
	[M.GRAVEL] = "Gravel",
	[M.GOLD] = "Gold Ore",
	[M.WOOL] = "Wool",
	[M.STONEBRICK] = "Stone Bricks",
	[M.BOOKS] = "Bookshelf",
	[M.CRAFT] = "Crafting Table",
	[M.STICK] = "Stick",
	[M.PICK] = "Wooden Pickaxe",
	[M.AXE] = "Wooden Axe",
	[M.SHOVEL] = "Wooden Shovel",
	[M.SWORD] = "Wooden Sword",
	[M.EGG] = "Egg",
	[M.PORK] = "Raw Porkchop",
	[M.APPLE] = "Apple",
}

-- How each block breaks. `hand`: seconds by hand. `tool`: the tool that
-- breaks it quicker; `need`: only with that tool does it drop anything (by
-- hand it takes long and gives nothing, as stone does). `drop`: what it
-- drops (itself if not given; 0 nothing). Not here: it can't be broken.
M.BLOCKS = {
	[M.GRASS] = { hand = 0.9, tool = "shovel", drop = M.DIRT },
	[M.DIRT] = { hand = 0.75, tool = "shovel" },
	[M.SAND] = { hand = 0.75, tool = "shovel" },
	[M.GRAVEL] = { hand = 0.9, tool = "shovel" },
	[M.SNOW] = { hand = 0.9, tool = "shovel", drop = M.DIRT },
	[M.LEAVES] = { hand = 0.35, tool = "sword", drop = 0 },
	[M.LOG] = { hand = 3.0, tool = "axe" },
	[M.PLANKS] = { hand = 3.0, tool = "axe" },
	[M.BOOKS] = { hand = 2.25, tool = "axe" },
	[M.CRAFT] = { hand = 3.75, tool = "axe" },
	[M.WOOL] = { hand = 1.2 },
	[M.GLASS] = { hand = 0.45, drop = 0 },
	[M.STONE] = { hand = 7.5, tool = "pick", need = true, drop = M.COBBLE },
	[M.COBBLE] = { hand = 10, tool = "pick", need = true },
	[M.BRICKS] = { hand = 10, tool = "pick", need = true },
	[M.STONEBRICK] = { hand = 7.5, tool = "pick", need = true },
	[M.COAL] = { hand = 15, tool = "pick", need = true },
	[M.IRON] = { hand = 15, tool = "pick", need = true },
	[M.GOLD] = { hand = 15, tool = "pick", need = true },
}

M.TOOLS = {
	[M.PICK] = "pick",
	[M.AXE] = "axe",
	[M.SHOVEL] = "shovel",
	[M.SWORD] = "sword",
}
M.DURABILITY = 60 -- uses a wooden tool lasts

-- Damage to a mob by what's in hand.
M.DAMAGE = { [M.SWORD] = 4, [M.AXE] = 3, [M.PICK] = 2, [M.SHOVEL] = 1.5 }

function M.is_block(id: number): boolean
	return id >= 1 and id < M.FIRST_ITEM and id ~= M.WATER and id ~= M.BEDROCK
end

function M.max_stack(id: number): number
	return if M.TOOLS[id] then 1 elseif id == M.EGG then 16 else 64
end

-- Seconds to break `block` holding `held` (an id, 0 for none), and whether
-- it then drops anything.
function M.break_time(block: number, held: number): (number?, boolean)
	local b = M.BLOCKS[block]
	if not b then
		return nil, false
	end
	local right = b.tool ~= nil and M.TOOLS[held] == b.tool
	if right then
		return b.hand / (if b.need then 6.5 else 2), true
	end
	return b.hand, not b.need
end

-- What breaking `block` gives: a list of { id, n } (rolled where it's luck).
function M.drops_of(block: number, rand: () -> number): { { number } }
	local b = M.BLOCKS[block]
	if not b then
		return {}
	end
	if block == M.LEAVES then
		local r = rand()
		return if r < 0.06 then { { M.STICK, 1 } } elseif r < 0.10 then { { M.APPLE, 1 } } else {}
	end
	local id = if b.drop == nil then block else b.drop
	if id == 0 then
		return {}
	end
	return { { id, 1 } }
end

-- Recipes: each `shape` a few rows of keys (a space empty), what it makes.
-- A shape matches wherever it sits in the grid; `mirror` also matches it
-- flipped side to side.
local KEY = { L = M.LOG, P = M.PLANKS, S = M.STICK }
M.RECIPES = {
	{ shape = { "L" }, out = { M.PLANKS, 4 } },
	{ shape = { "P", "P" }, out = { M.STICK, 4 } },
	{ shape = { "PP", "PP" }, out = { M.CRAFT, 1 } },
	{ shape = { "PPP", " S ", " S " }, out = { M.PICK, 1 } },
	{ shape = { "PP", "PS", " S" }, out = { M.AXE, 1 }, mirror = true },
	{ shape = { "P", "S", "S" }, out = { M.SHOVEL, 1 } },
	{ shape = { "P", "P", "S" }, out = { M.SWORD, 1 } },
}

-- What a crafting grid (`n` by `n`, its cells in rows: 0 or { id, n })
-- makes: { id, n } or nil.
function M.craft(grid, n: number)
	-- The grid's filled part.
	local r0, r1, c0, c1 = n + 1, 0, n + 1, 0
	for r = 1, n do
		for c = 1, n do
			if grid[(r - 1) * n + c] ~= 0 then
				r0, r1 = math.min(r0, r), math.max(r1, r)
				c0, c1 = math.min(c0, c), math.max(c1, c)
			end
		end
	end
	if r1 == 0 then
		return nil
	end
	local h, w = r1 - r0 + 1, c1 - c0 + 1
	for _, rec in M.RECIPES do
		local shape = rec.shape
		if #shape == h and #shape[1] == w then
			for _, flip in (if rec.mirror then { false, true } else { false }) do
				local ok = true
				for r = 1, h do
					for c = 1, w do
						local ch = string.sub(shape[r], if flip then w - c + 1 else c, if flip then w - c + 1 else c)
						local want = KEY[ch] or 0
						local have = grid[(r0 + r - 2) * n + (c0 + c - 1)]
						local id = if have == 0 then 0 else have.id
						if id ~= want then
							ok = false
						end
					end
				end
				if ok then
					return { id = rec.out[1], n = rec.out[2] }
				end
			end
		end
	end
	return nil
end

return M
