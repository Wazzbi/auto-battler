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
single source of truth for game state: current wave, currency, XP/level/ability ranks, enemy counts,
and the `State` enum (`INTRO`, `PLAYING`, `GAME_OVER`, `WON`). Almost every gameplay script gates
its `_process` logic behind `if GameManager.state != GameManager.State.PLAYING: return`. Wave
progression is continuous — clearing a wave immediately calls `start_next_wave()`, there is no
forced pause between waves. All player progression lives here, not on the player node.

**`reset_game()` must be called from `main.gd`'s `_enter_tree()`, not `_ready()`.** Godot calls a
parent's `_ready()` *after* its children's, so resetting in `_ready()` would let `player.gd` and
`hud.gd` initialize from the *previous* run's level/ability ranks — visible as wrong stats after the
Game Over auto-restart (`reload_current_scene()`), since `GameManager` is an autoload and survives
the reload.

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

**Enemies don't block each other**: each enemy moves left toward the player and stops purely at its
own `melee_range` (plus a random per-enemy jitter) — it never looks at other enemies' positions.
This is deliberate, not an oversight: an earlier version made each enemy stop farther back if
another enemy was already closer to the player (a "queueing" effect), but that broke down once
enemies could have different speeds (a slow Elite would back up fast normal enemies behind it,
stalling them). Visual overlap between enemies is an accepted trade-off — there's no collision
layer to prevent it anyway (see "Combat resolution is distance-based" below). `melee_range_jitter`
still exists purely so enemies of the *same* type don't all stop at the exact same pixel.

**Design constraint for future enemy projectiles**: enemies are melee-only right now
(`contact_damage`), but if ranged enemies get added later, their projectiles must only ever check
distance against the player — never scan the `enemies` group the way `projectile.gd`'s
"target lost" fallback does for the player's own projectiles (see `_process()` in
`scenes/projectiles/projectile.gd`). Since enemies can now stand on top of each other, a
generic "hit whatever's in range" fallback would let enemies shoot each other in the back;
projectiles fired *by* enemies must pass through other enemies untouched and only ever resolve
against the player.

**Level end detection**: `player.gd` finds the level-end X coordinate by looking up a node in the
`level_end` group (`get_tree().get_first_node_in_group("level_end")`) at `_ready()`. The `LevelEnd`
marker in `scenes/levels/level_01.tscn` must belong to that group or `level_end_x` stays `INF`. If a
hand-edited `.tscn` loses this group membership, re-add it in the editor: select the marker → Node
tab → Groups → add `level_end`. **`level_end_x` is now just a movement cap, not a win trigger** —
the player stops advancing there (`global_position.x = min(..., level_end_x)`) but reaching it does
nothing else. This is deliberate: see the win-condition note below.

**Win condition is wave-based, not position-based**: the game ends in victory when
`GameManager.FINAL_WAVE` (10) is cleared — `_on_wave_cleared()` calls `trigger_win()` instead of
`start_next_wave()` once `current_wave >= FINAL_WAVE`. This *replaced* the old "player walks to
`level_end_x`" win condition, which was removed from `player.gd` on purpose: with a fixed 10-wave
campaign, letting position also trigger a win risked the player winning early by outrunning combat
before wave 10 was actually cleared. If the level length or enemy count ever changes, make sure
`Level01/Ground` (`scenes/levels/level_01.tscn` + `ground.gd`'s `total_width`) stays comfortably
longer than however far the player can realistically walk across 10 waves — right now both were
sized 20% longer than the original single-screen-ish layout to give the fixed campaign room.

**Elite enemy (final wave only)**: `scenes/enemies/elite_enemy.tscn` reuses `enemy.gd` (it's fully
data-driven via `@export` vars, so no new script was needed) with `speed` halved, `max_hp` tripled,
and the `Polygon2D` visual scaled 3x — `melee_range` was also bumped (60 → 100) so the much bigger
sprite doesn't visually overlap the player before it stops to attack. `main.gd`'s
`elite_count_final_wave` (default 1) controls how many spawn; `_on_wave_started()` only queues
Elites when `wave_number == GameManager.FINAL_WAVE`, and `_spawn_enemy()` always drains the Elite
queue before falling back to normal enemies, so the Elite(s) appear first in wave 10, with regular
enemies filling out the rest of the wave's usual sqrt-curve count.

**Intro/drop-in sequence**: on start, the player falls from above into position
(`_play_drop_in_animation` in `player.gd`) while `GameManager.state == State.INTRO`, which blocks
all gameplay `_process` logic automatically. `_on_landed()` triggers a screen shake, a squash
tween, a procedural impact ring (`scenes/effects/impact_effect.gd`), and finally
`GameManager.finish_intro()` to switch state to `PLAYING`.

**Game Over / Victory auto-restart flow**: `hud.gd` drives both `GameOverPanel` and `VictoryPanel`
with the *same* countdown mechanism — `_end_screen_countdown` ticks down via a manually decremented
float in `_process` (not a `Timer` node), and `_active_countdown_label` points at whichever panel's
`CountdownLabel` is currently showing (`show_game_over()`/`show_victory()` set it, along with a
prefix string — "Restart za" vs. "Nová hra za" — since the two panels only differ in copy, not
behavior). This works because the two panels are mutually exclusive: `GameManager.state` is either
`GAME_OVER` or `WON`, never both, so there's never a question of *which* panel's countdown is
running. Both panels' `mouse_entered`/`mouse_exited` connect to the same
`_on_end_panel_mouse_entered`/`_exited` handlers (hovering pauses, moving off resumes), and both
"Pokračovat" buttons connect to the same `_restart_game()`, which just calls
`get_tree().reload_current_scene()` — `GameManager` is an autoload so it survives the reload
untouched, and `main.gd`'s `_enter_tree()` calls `GameManager.reset_game()` on the way back up, so
that's the only reset path; there's no separate "restart" signal or function on `GameManager`
itself. **Mobile port note**: the pause-on-hover mechanic has no equivalent on touch (no hover
state), so this will need a different interaction — e.g. pause while a finger is down, or drop the
pause and just show the countdown — when a mobile port is attempted.

**Visuals are all procedural** — colored `Polygon2D` shapes for characters, and `_draw()`-based
rendering for the checkerboard ground (`scenes/levels/ground.gd`) and the impact ring effect.
There are no sprite assets to manage; if you need to change how something looks, look for a
`_draw()` override or `Polygon2D` node rather than an image file.

**Progression (XP → levels → abilities)**: enemies grant `reward` (gold) *and* `xp_reward` on death
via `GameManager.enemy_defeated(reward, xp_reward)`. XP accumulates toward
`xp_for_next_level()` (`XP_BASE + (level - 1) * XP_PER_LEVEL_GROWTH`); `add_xp()` loops so one big
XP chunk can grant several levels at once. Each level raises every base stat automatically by
`LEVEL_STAT_GROWTH` and grants 1 ability point. The player starts at level 1 *with 1 point already
banked*, so the first click always unlocks one ability — matching the MOBA rule the design is based
on ("at the start you have exactly one ability"). There is no per-stat purchasing anymore.

**Stats flow**: base stats live as `@export` vars on `player.gd` (`base_damage`,
`base_attack_speed`, `base_attack_range`, `base_max_hp`). Effective stats come from getters
(`get_damage()`, `get_attack_speed()`, `get_attack_range()`, `get_target_count()`) that add
`GameManager.get_stat_bonus(stat_id)` — **the single place where progression turns into numbers**
(level growth + ability ranks summed together). The player recomputes on the `level_changed` and
`ability_rank_changed` signals; the HUD never touches player stats, it only calls
`GameManager.spend_ability_point(ability_id)` and re-reads the getters for display.

**Abilities are placeholders**: `GameManager.ABILITIES` defines four abilities (Q/W/E/R) with a
`stat` + `per_rank` pair instead of real active effects — a rank currently just adds passively to a
stat, so spending points has a gameplay effect while actual spells don't exist yet. Ranks cap at
`MAX_ABILITY_RANK`. When real active abilities get built, that table and `get_stat_bonus()` are the
only things that need to change; the HUD iterates `ABILITY_ORDER` and reads `ABILITIES` generically,
so adding/renaming abilities does not require touching UI code (only the matching
`Ability<KEY>` / `AbilityRank<KEY>` nodes in `hud.tscn`).

**Auto ability-point assignment**: the "Auto" toggle button in `hud.gd` (default ON) spends new
ability points for the player automatically - `_maybe_auto_assign()` picks uniformly at random
among abilities not yet at `MAX_ABILITY_RANK` and calls `GameManager.spend_ability_point()` in a
loop until points run out or every ability is maxed. **This is a deliberately temporary/placeholder
rule** (no weighting, no preference for unlocking a new ability over ranking up an existing one) -
it's flagged to be revisited once real active abilities exist and some builds become better than
others. Toggling Auto off just stops the auto-spend; points bank up and go back to manual clicking,
same as before this feature existed. The reentrancy guard (`_auto_assigning`) exists because
`spend_ability_point()` emits `ability_points_changed` synchronously, which would otherwise call
`_maybe_auto_assign()` again mid-loop.

**HUD is one bottom bar** (`Control/BottomBar` in `hud.tscn`) styled after MOBA HUDs: stat readouts,
portrait with a level badge, HP bar, XP bar, the four ability buttons with rank labels, six
(currently decorative) item slots, gold, and the shop button. Right-side elements are anchored to
the right edge and the bars stretch, so the bar survives window resizing. The old "Upgrade" button
and its stats panel are gone — ability points are spent by clicking the ability buttons directly.

**Shop pauses the game via `get_tree().paused`**, which is why the HUD `CanvasLayer` has
`process_mode = 3` (ALWAYS) in `hud.tscn` — without it the shop's own close button would freeze
along with the game. The pause is deliberate *for now*; the user has flagged that they may later
want the game to keep running while the shop is open, so the pause lives only in
`_on_shop_button_pressed()` / `_on_shop_close_pressed()` / `_close_shop()` in `hud.gd` and nothing
else depends on it. The shop is intentionally empty apart from its close button.

## Key tunables when adjusting gameplay

- `scenes/player/player.gd` — `move_speed`, `attack_range`, `camera_left_margin`, base stats, fall/intro animation params
- `scenes/main.gd` — enemies per wave, spawn interval/margin, `max_concurrent_enemies`, `elite_count_final_wave`
- `scenes/enemies/enemy.gd` — enemy speed/HP/damage, `melee_range`, `reward`, `xp_reward`
- `scenes/enemies/elite_enemy.tscn` — Elite's stat overrides (speed/max_hp/melee_range) and visual scale, node properties only (script is shared with `enemy.gd`)
- `scenes/levels/level_01.tscn` — `LevelEnd` marker position = level length (movement cap, no longer a win trigger)
- `scenes/levels/ground.gd` — `tile_size`, tile colors, `total_width` (must cover past `LevelEnd` or the floor visibly ends early)
- `scripts/autoload/game_manager.gd` — XP curve (`XP_BASE`, `XP_PER_LEVEL_GROWTH`), per-level stat growth (`LEVEL_STAT_GROWTH`), ability definitions and `MAX_ABILITY_RANK`, `FINAL_WAVE` (which wave ends the game)
- `scenes/ui/hud.gd` — `GAME_OVER_RESTART_DELAY`
