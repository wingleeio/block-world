# Block World

A blocky voxel survival world on a page of its own in Zeron's sidebar: an island of grass, sand, snowy peaks, trees and ores in an open sea. You start with nothing. Break blocks and they drop; walk over them to pick them up, then build with what you've gathered. No crafting, just collecting and placing.


## Installing

Block World is a Zeron plugin. In Zeron, open **Settings → Plugins** and install from a link: `https://github.com/wingleeio/block-world` (or ask an agent in Zeron to install the plugin `wingleeio/block-world`). Zeron checks the signature, shows what it asks for (a sidebar page, and running macOS's `afplay` for sounds), and waits for you to allow it. Its page then shows in the sidebar.

**Sounds:** a plugin can't learn where its own folder is, so `init.luau` names it in `SOUNDS`. It's set for the author's Mac; if you hear nothing, set it to your plugins folder's `block-world/sounds/` (usually `/Users/<you>/.zeron/plugins/block-world/sounds/`). The game plays the same without sound.
## Playing

The title screen shows the island turning slowly behind BLOCKWORLD. Every menu works with the mouse (the game draws its own cursor while it holds the pointer) and with the keyboard: arrows or W/S to choose, Enter or Space to press, ←/→ to move a slider, Esc to go back.

| | |
| --- | --- |
| Look | Mouse (the game takes it: pointer lock) |
| Move | W A S D |
| Jump / swim up | Space |
| Sprint | Double-tap W, or Control |
| Crouch / swim down | Shift (crouching, you won't walk off an edge) |
| Break | Hold left click: cracks spread, then it drops |
| Place | Right click |
| Hotbar | 1–9, or the wheel |
| Select a block you see | Middle click |
| Inventory | E (click: take or put; right-click: half or one; Shift-click: move across) |
| Drop one | Q |
| Third person | F5 or V |
| Debug info | F3 |
| Pause | Esc |

Options: mouse sensitivity, field of view, sound volume, view bobbing.

## Surviving

Blocks break as they do in Minecraft: dirt in under a second by hand, a log in three, and stone takes seven and gives nothing without a pickaxe. Grass gives dirt, stone gives cobblestone, leaves sometimes a stick.

Crafting (E opens a 2×2 grid; right-click a crafting table for 3×3; Shift-click the result to craft all you can):

| Makes | From |
| --- | --- |
| 4 Planks | a Log |
| 4 Sticks | 2 Planks, one above the other |
| Crafting Table | 4 Planks, 2×2 |
| Wooden Pickaxe | 3 Planks across the top, 2 Sticks down the middle |
| Wooden Axe | 3 Planks in an L, 2 Sticks |
| Wooden Shovel | a Plank over 2 Sticks |
| Wooden Sword | 2 Planks over a Stick |

The right tool halves the time (a pickaxe makes stone six times quicker). Wooden tools last 60 uses; a bar under each shows its wear.

Chickens, pigs and sheep wander the island in small herds, graze, hop up blocks and keep off cliffs and water. Hit one and it runs; chickens drop eggs (and lay them now and then), pigs porkchops, sheep wool. Leaves sometimes drop a stick or an apple. A sword hits hardest. New ones come, out of sight, while there are few.

Water is real water now: dig beside the sea below its level and it floods in, step by step. In water you sink slowly, Space swims up, and swimming into a bank lifts you out.

## How it's made

- `shaders.luau`: the renderer, a voxel ray caster (a zgx layer shader) with the Zeron film's look (smooth bevelled blocks, a round sun, soft clouds), ambient occlusion, water and fog; plus the cracks, the dropped blocks and bits, the first-person hand (posed and swung on Minecraft's own curves) and the player seen from behind, all ray-traced in the same pass. `icon` draws the inventory's block icons.
- `game.luau`: world generation, physics, water, inventory and crafting screens, menus, input, HUD.
- `items.luau`: every block and item, how each block breaks and what it drops, the tools, the recipes.
- `mobs.luau`: the animals' wandering, physics, hits and drops.
- `icons/`: the items' pictures: 16×16 pixel art from Pixel Perfection (Chorus Edition), by XSSheep and the Pixel Perfection community, CC BY-SA 4.0 (`icons/LICENSE.txt`). `tools/make_icons.py` scales them, pixel for pixel: 64 px for the inventory, and `atlas.png`, which the shader reads for drops and the item in hand.
- `sounds/`: original sounds synthesized by `tools/make_sounds.py` (no samples, the animals' voices included), played through macOS's `afplay` (the plugin's `commands` permission).
- `init.luau`: the page, the store, the sound player.

Speed: the shader reads the world from data canvases inside its layer. Each still part of that data (16 tiles of blocks, the height map) sits in a cached layer of its own, so the entities' and animals' rows, which change every frame, repaint only themselves; the camera, time and the rest go in as layer params, which animate without repainting anything.

Your world, inventory, dropped blocks and settings are saved with `zeron.store`.

The `preview` prop on the game starts it in a given state (a screen, a view, an inventory), for rendering pictures of it headlessly with `zgx video still`.

## License

The code, shaders, sounds and tools are MIT (`LICENSE`). The item icons are CC BY-SA 4.0 (below).

## Credits

Item icons (`icons/`): from [Pixel Perfection CE](https://github.com/Athemis/PixelPerfectionCE), originally by XSSheep, maintained by the Pixel Perfection community; licensed [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). Scaled (each pixel 4 by 4, and 2 by 2 in the atlas) with no other change; the scaled files are CC BY-SA 4.0 too. Everything else in this folder (code, shaders, sounds) was made for Block World.
