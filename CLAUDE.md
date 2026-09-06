# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Godot 4.7 (Forward+/Mobile renderer) 2D auto-battler prototype. Written in GDScript. No external
build system, package manager, or automated test suite — this is a pure Godot editor project.

Code comments and in-editor labels are written in Czech; keep new comments/labels consistent with
that unless told otherwise.

## Running the game

There is no CLI build/test workflow — everything happens through the Godot editor:
1. Open Godot 4.7, import this folder (`project.godot`).
2. Press F5 to run. Main scene is `scenes/main.tscn`.

If Godot warns about a `.tscn` file on open (e.g. a stale `load_steps` count), open that scene in
the editor and save it (Ctrl+S) — Godot recalculates and fixes the file itself. Don't hand-edit
`load_steps` or other generated `.tscn` metadata.

There are no automated tests, linters, or CLI build commands in this project.

## Architecture

**Autoload singleton (`scripts/autoload/game_manager.gd`, registered as `GameManager`)** is the
single source of truth for game state: current wave, currency, skill points, enemy counts, and the
`State` enum (`INTRO`, `PLAYING`, `GAME_OVER`, `WON`). Almost every gameplay script gates its
`_process` logic behind `if GameManager.state != GameManager.State.PLAYING: return`. Wave
progression is continuous — clearing a wave immediately calls `start_next_wave()`, there is no
forced pause between waves. Player upgrades bought via the HUD are stored here
(`player_upgrades` dict) and read by `player.gd`, not stored on the player itself.

**`scenes/main.gd`** owns wave spawning only (enemy count/timing per wave, spawn position). It does
not own wave progression or rewards — those events come back from `GameManager` via signals
(`wave_started`, `wave_cleared`, `game_over_triggered`, `game_won_triggered`). Enemy count per wave
uses a square-root curve (`enemies_base_count + sqrt(wave_number - 1) * difficulty_growth`) so
difficulty ramps gradually, and `max_concurrent_enemies` caps how many can be alive at once
regardless of how many are left to spawn.

**Camera/scrolling model**: the `Camera2D` is a *child of the player* (`scenes/player/player.tscn`)
but offset horizontally by `camera_left_margin` so the player renders near the left edge, not
centered. Because of this offset, anything that needs "the visible screen area" (enemy spawn
position in `main.gd`, projectile off-screen cleanup in `projectile.gd`) must compute it from
`camera.global_position`, **not** from the player's position or a fixed viewport size — that
mismatch was a real bug once (projectiles get cleaned up using world-space camera position, not a
static viewport coordinate). The offset is recalculated on `get_viewport().size_changed` too.

**Combat resolution is distance-based, not physics-based.** Player attacks, enemy melee, and
projectile hits all use `global_position.distance_to(...)` checks against exported range
constants — there are no `Area2D`/`CollisionShape2D` hit layers. This is intentional for prototype
simplicity per the README; if collision performance ever matters, this is the layer to revisit.

**Enemy queueing**: enemies move left toward the player and stop at `melee_range` (plus a random
per-enemy jitter). `enemy.gd`'s `_get_effective_stop_distance()` checks other enemies' distance to
the player and increases its own stop distance if another enemy is already closer, so enemies form
a natural queue instead of stacking on the same pixel.

**Level end detection**: `player.gd` finds the level-end X coordinate by looking up a node in the
`level_end` group (`get_tree().get_first_node_in_group("level_end")`) at `_ready()`. The `LevelEnd`
marker in `scenes/levels/level_01.tscn` must belong to that group or `level_end_x` stays `INF` and
the player walks forever without ever triggering a win. If a hand-edited `.tscn` loses this group
membership, re-add it in the editor: select the marker → Node tab → Groups → add `level_end`.

**Intro/drop-in sequence**: on start, the player falls from above into position
(`_play_drop_in_animation` in `player.gd`) while `GameManager.state == State.INTRO`, which blocks
all gameplay `_process` logic automatically. `_on_landed()` triggers a screen shake, a squash
tween, a procedural impact ring (`scenes/effects/impact_effect.gd`), and finally
`GameManager.finish_intro()` to switch state to `PLAYING`.

**Game Over / auto-restart flow**: `hud.gd`'s `GameOverPanel` counts down
`GAME_OVER_RESTART_DELAY` (10s) via a manually decremented float in `_process`, not a `Timer`
node — `_game_over_countdown_active` gets flipped off/on by the panel's `mouse_entered`/
`mouse_exited` signals so hovering the panel pauses the countdown and moving off resumes it.
Reaching zero, or pressing the panel's "Pokračovat" button, both call `_restart_game()`, which
just does `get_tree().reload_current_scene()` — `GameManager` is an autoload so it survives the
reload untouched, and `main.gd`'s `_ready()` calls `GameManager.reset_game()` on the way back up,
so that's the only reset path; there's no separate "restart" signal or function on `GameManager`
itself. **Mobile port note**: the pause-on-hover mechanic has no equivalent on touch (no hover
state), so this will need a different interaction — e.g. pause while a finger is down, or drop the
pause and just show the countdown — when a mobile port is attempted.

**Visuals are all procedural** — colored `Polygon2D` shapes for characters, and `_draw()`-based
rendering for the checkerboard ground (`scenes/levels/ground.gd`) and the impact ring effect.
There are no sprite assets to manage; if you need to change how something looks, look for a
`_draw()` override or `Polygon2D` node rather than an image file.

**Stats/upgrades flow**: base stats live as `@export` vars on `player.gd`
(`base_damage`, `base_attack_speed`, `base_attack_range`, `base_max_hp`). Effective stats are
computed via getters (`get_damage()`, `get_attack_speed()`, `get_attack_range()`,
`get_target_count()`) that add `GameManager.player_upgrades[...]`. The HUD
(`scenes/ui/hud.gd`) spends skill points through `GameManager.spend_skill_point(upgrade_id, amount)`
and then calls `player_ref.on_upgrade_applied()` to make the player recompute derived stats
immediately; it never mutates player stats directly.

## Key tunables when adjusting gameplay

- `scenes/player/player.gd` — `move_speed`, `attack_range`, `camera_left_margin`, base stats, fall/intro animation params
- `scenes/main.gd` — enemies per wave, spawn interval/margin, `max_concurrent_enemies`
- `scenes/enemies/enemy.gd` — enemy speed/HP/damage, `melee_range`, `min_spacing`
- `scenes/levels/level_01.tscn` — `LevelEnd` marker position = level length
- `scenes/levels/ground.gd` — `tile_size`, tile colors, `total_width` (must cover past `LevelEnd` or the floor visibly ends early)
- `scripts/autoload/game_manager.gd` — upgrade amounts, skill points per wave
