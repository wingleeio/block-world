local zeron = require("./zeron")("block-world")
local Game = require("./game")

-- Block World: a blocky voxel survival world on a page of its own in the
-- sidebar. game.luau is the game, shaders.luau its renderer (a voxel ray
-- caster run on the GPU as a layer shader). The world (its seed, every
-- block changed, where you stand, your inventory and settings) is kept
-- with zeron.store.

local world = zeron.store("world", nil)

-- Sounds: the WAVs in sounds/ (made by tools/make_sounds.py), played by
-- macOS's afplay (the "commands" permission). Zeron gives a plugin no path
-- of its own folder, so it's named here: set it to yours if the game is
-- silent (your plugins folder's block-world/sounds/).
local SOUNDS = "/Users/winglee/.zeron/plugins/block-world/sounds/"
local sound_ok = true

local function play(name: string, volume: number)
	if not sound_ok then
		return
	end
	local ok = pcall(function()
		zeron.run("afplay", { "-v", string.format("%.2f", volume), SOUNDS .. name .. ".wav" }, { timeout = 10 })
	end)
	if not ok then
		-- (Not allowed, or no afplay: quiet from here on.)
		sound_ok = false
	end
end

zeron.page {
	id = "play",
	title = "Block World",
	build = function(_page)
		-- Zeron starts a plugin's page below the title bar's strip (its
		-- height, 38, less the card's inset): the game reaches up through it
		-- to the card's top, the title bar's buttons staying over it.
		local ok, gap = pcall(function()
			return ui.theme.get("zeron.inset.gap")
		end)
		local inset = if ok and type(gap) == "number" then gap else 4
		return Game {
			bleed = 38 - inset,
			play = play,
			store = {
				get = function()
					return world:peek()
				end,
				set = function(v)
					world:set(v)
				end,
			},
		}
	end,
}
