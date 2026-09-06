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

**Camera/scrolling model**: the `Camera2D` (`Main/Camera2D` in `main.tscn`, script
`scenes/camera_follow.gd`) is an **independent sibling node, not a child of the player**. It tracks
the player's X position with its own exponential lerp (`follow_speed`, default 5.0) offset
horizontally by `camera_left_margin` so the player renders near the left edge, not centered; Y is
copied from the player with no lag (needed for the drop-in animation and shake to look right).
`main.gd`'s `_ready()` wires it up explicitly: `camera.set_target(player)` (which snaps instantly,
so there's no visible "flying in" on start) and `player.landed.connect(camera.shake)` — the player
only emits a `landed` signal and has no reference to the camera at all. **This decoupling was a
deliberate fix**, not the original design: when the camera was a rigid child, its X velocity
matched the player's exactly, so the *instant* the player stopped walking (an enemy came into
`attack_range`) the camera's on-screen pan also stopped instantly — collapsing the *apparent*
closing speed of an approaching enemy from `enemy.speed + player.move_speed` down to just
`enemy.speed` in a single frame (a real, measured ~43% perceived slowdown, not a change to
`enemy.speed` itself). The lerp-follow smooths that transition away. Anything that needs "the
visible screen area" (enemy spawn position in `main.gd`, projectile off-screen cleanup in
`projectile.gd`, infinite ground tiling in `ground.gd`) still computes it from `camera.global_position`
— that stays correct because this camera has no *additional* built-in smoothing layered on top
(`position_smoothing_enabled` is intentionally not used; the manual lerp *is* the smoothing, so
`global_position` is always exactly what's rendered, same reasoning as the `get_screen_center_position()`
note in ground.gd below). The horizontal offset is recalculated on `get_viewport().size_changed` too.

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

**Projectile hit radius lives on the enemy, not the projectile**: `enemy.gd` exports `hit_radius`
(20.0, matching its 18px `Polygon2D` half-width plus a small margin); `elite_enemy.tscn` overrides
it to 58.0 to match its 3x-scaled 54px half-width. `projectile.gd` reads `target.hit_radius` (and
`enemy.hit_radius` in its "target lost" fallback scan) instead of carrying its own fixed radius.
This was a real, measured visual bug: with a single shared radius, a normal enemy (visual
half-width 18) registered a hit while the projectile was still ~6px short of its visible edge, and
an Elite (half-width 54) would have needed a projectile to fly *30px into* its silhouette before
registering — both because a flat hit radius doesn't scale with an enemy's actual size. If a new
enemy type gets a different visual scale, give it its own `hit_radius` override the same way
Elite does, rather than tuning `projectile.gd`.

**Design constraint for future enemy projectiles**: enemies are melee-only right now
(`contact_damage`), but if ranged enemies get added later, their projectiles must only ever check
distance against the player — never scan the `enemies` group the way `projectile.gd`'s
"target lost" fallback does for the player's own projectiles (see `_process()` in
`scenes/projectiles/projectile.gd`). Since enemies can now stand on top of each other, a
generic "hit whatever's in range" fallback would let enemies shoot each other in the back;
projectiles fired *by* enemies must pass through other enemies untouched and only ever resolve
against the player.

**Enemies guard against dying twice in the same frame** (`enemy.gd`'s `_is_dead` flag, checked at
the top of `take_damage()` and set at the top of `_die()`): `queue_free()` doesn't remove a node
from the tree/groups until the end of the frame, so an enemy that just died is still a valid,
`is_instance_valid()`-passing target for that same frame. Two projectiles both aimed at the same
enemy (easy to hit with multishot, or just two shots in flight close together against a low-HP
target) could both land in the same frame — without the guard, the second `take_damage()` call
would push `hp` further negative and call `_die()` again, double-decrementing
`GameManager.enemies_alive`. That's not just a cosmetic counting error: it could make
`enemies_alive` hit 0 (or go negative) *before* every wave-10 enemy was actually dead, which
`enemy_defeated()`'s wave-clear check reads directly — so the game would start the next loop's
wave 1 while old wave-10 enemies were still alive and on screen. Found via the `enemies_alive`
counter going to -1 after a deliberate double-hit in a headless test, not via a visible symptom.

**Level01 is boundless — there is no level-end marker.** `player.gd` still supports finding one
(`level_end_x` looks up a node in the `level_end` group via
`get_tree().get_first_node_in_group("level_end")` at `_ready()`, capping forward movement at
`global_position.x = min(..., level_end_x)`), but `level_01.tscn` deliberately has no `LevelEnd`
node anymore, so `level_end_x` stays at its default `INF` and the player always keeps walking
right. This machinery is kept (not deleted) specifically so a *future*, genuinely finite
planet/level can reuse it — add a `Marker2D` in the `level_end` group to any new level scene to cap
movement there again. `ground.gd`'s `total_width` export is gone for the same reason — see below.

**Ground renders infinitely, tracking the camera** (`ground.gd`): instead of drawing a fixed set of
tiles up front, `_process()` calls `queue_redraw()` every frame and `_draw()` recomputes which tile
indices are currently visible from `Camera2D.get_screen_center_position()` (± half the viewport
width, plus `tile_margin_count` tiles of buffer) and draws only that window. Tile color alternates
on the tile's *absolute* index (`posmod(i, 2)`), not drawing order, so the checkerboard pattern
never shifts or flickers as the visible window scrolls. **Use `get_screen_center_position()`, not
`camera.global_position`** — the Camera2D has `position_smoothing_enabled = true`, so
`global_position` is the raw, un-smoothed transform while `get_screen_center_position()` is what's
actually rendered; a large/instant position change (only really happens in tests, not real gradual
gameplay movement) makes those two diverge, and computing the visible tile range from the wrong one
draws tiles for a region the camera isn't actually showing yet — the ground appeared to vanish
entirely during testing until this was fixed.

**The game loops instead of ending at `GameManager.FINAL_WAVE`**: clearing wave 10
(`FINAL_WAVE`) doesn't call `trigger_win()` anymore — `_on_wave_cleared()` calls
`_start_new_loop()` instead, which increments `loop_count`, resets `current_wave` to 0, and calls
`start_next_wave()` to jump straight back into wave 1. **Both player progression AND position/HP
persist across loops** — level, XP, ability ranks/points, currency, world position, and current HP
are all untouched by a loop transition (there is no `reset_game()` call anywhere in this path, and
`player.gd` no longer reacts to `loop_changed` at all). Since the level is boundless, the player
just keeps walking forward through loop after loop rather than restarting from the spawn point.
Newly spawned enemies get more HP per loop via `GameManager.get_enemy_hp_multiplier()`
(`1.0 + (loop_count - 1) * ENEMY_HP_GROWTH_PER_LOOP`, currently +50%/loop) — `main.gd`'s
`_spawn_enemy()` applies it to `enemy.max_hp` *before* `add_child()`, since `enemy.gd`'s `_ready()`
sets `hp = max_hp` synchronously on entering the tree. **This is deliberately the simplest possible
version** (linear, HP-only scaling) to prototype whether repeated 10-wave loops are fun at all
before investing in more planets/levels or a richer scaling system (new enemy types, other stats,
per-loop modifiers, etc.) — see the brainstorm this came from. `GameManager.State.WON` and
`VictoryPanel` still exist and work exactly as before, but are currently unreachable through normal
play (nothing calls `trigger_win()`); they're intentionally kept for a real future ending (e.g.
after the last planet). Only a true Game Over (`reset_game()`) resets `loop_count` back to 1 and
teleports the player back to spawn (via the normal scene reload, not anything loop-specific).

**Passive HP regeneration** (`player.gd`): `base_hp_regen` (default 1.0 HP/s, like League of
Legends' base HP5) ticks continuously in `_process()` whenever `hp < max_hp` and the player is
alive and `PLAYING` — not just after a loop transition, and not paused by combat. Routed through
`get_hp_regen()` = `base_hp_regen + GameManager.get_stat_bonus("hp_regen")`, mirroring every other
stat getter, even though nothing currently grants an `"hp_regen"` bonus — free to hook up later
without touching this getter. The HUD shows it as a small green `+X.X/s` label
(`Control/BottomBar/HPBar/RegenLabel`) anchored to the right end of the HP bar, hidden whenever HP
is already full (`_update_hp_regen_label()` in `hud.gd`) so it doesn't clutter the bar when it isn't
doing anything.

**HUD "Kolo" vs. "Úroveň"**: the top-of-screen `LoopLabel` ("Kolo N") is the loop counter above;
it's deliberately *not* called "Úroveň" even though that's the literal translation, because
"Úroveň" is already used in the bottom bar for the player's XP-based character level (the badge
over the portrait). Reusing the same word for two different counters on screen at once would be
confusing — rename both consistently if this ever needs to change.

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

**Debug panel** (`hud.gd`, `scenes/ui/eye_icon.gd`): a dev-only panel toggled by the `DebugButton`
in the top-right corner, which shows "Debug" plus a procedurally-drawn eye icon (open/closed,
`eye_icon.gd` — no image asset, consistent with the rest of the project's visuals) that mirrors
whether the panel is open. Unlike the shop, opening it does **not** pause the game — the point is
to see the effect of an action (kill, skip wave, spawn Elite, ...) happen live. Every action on the
panel is a thin call into a method explicitly named/commented `DEBUG:` on `GameManager`, `player.gd`,
or `main.gd` — the panel itself (`_setup_debug_panel()` and its handlers in `hud.gd`) holds no game
logic of its own, just wiring. A few of these are worth knowing about because they deliberately
reuse the *real* code paths rather than shortcutting past them:
- **Nesmrtelnost** sets `player.debug_invincible`, checked in `take_damage()` right after the
  existing `state != PLAYING` guard — resets to `false` automatically on any scene reload since it
  lives on the player instance, not `GameManager`.
- **Přeskočit vlnu** (`main.gd`'s `debug_skip_wave()`) kills every currently-alive enemy through
  their normal `take_damage()` (so they still grant currency/XP and go through the
  double-kill-safe `_is_dead` guard from `enemy.gd`) rather than just clearing counters directly.
  It only calls `GameManager.debug_force_wave_clear()` — which itself refuses to act unless
  `enemies_alive`/`enemies_remaining_to_spawn` are already both zero — to cover the edge case where
  no enemy was alive to begin with (so no death naturally triggered the wave-clear check).
- **Spawnout Elite** shares `_spawn_at_edge()` with the normal wave spawner (extracted from
  `_spawn_enemy()` during this work) so a debug-spawned Elite gets the same HP-multiplier-before-
  `add_child()` treatment as one spawned by wave 10 for real.
- **Rychlost** cycles `Engine.time_scale` through `1x/2x/5x/10x` — this is global engine state, so
  it also speeds up Timers, Tweens, and the Game Over/Victory countdown, and (unlike everything
  else on this panel) is **not** reset by a scene reload; the button re-syncs its own label from
  the actual `Engine.time_scale` in `_setup_debug_panel()` so it doesn't lie after a restart.
- **Max/Reset schopností** double as a quick respec tool — reset refunds every spent point rather
  than just zeroing ranks, so ability point math stays internally consistent (verified in tests: HP
  regen bonus stays derivable the same way, nothing about `get_stat_bonus()` needed to change).

## Key tunables when adjusting gameplay

- `scenes/player/player.gd` — `move_speed`, `attack_range`, `base_hp_regen`, base stats, fall/intro animation params
- `scenes/camera_follow.gd` — `camera_left_margin`, `follow_speed` (camera lag/responsiveness)
- `scenes/main.gd` — enemies per wave, spawn interval/margin, `max_concurrent_enemies`, `elite_count_final_wave`
- `scenes/enemies/enemy.gd` — enemy speed/HP/damage, `melee_range`, `hit_radius`, `reward`, `xp_reward`
- `scenes/enemies/elite_enemy.tscn` — Elite's stat overrides (speed/max_hp/melee_range/hit_radius) and visual scale, node properties only (script is shared with `enemy.gd`)
- `scenes/levels/level_01.tscn` — has no `LevelEnd` marker (level is boundless); add a `Marker2D` in the `level_end` group here (or in a new level scene) to reintroduce a movement cap
- `scenes/levels/ground.gd` — `tile_size`, tile colors, `tile_margin_count` (redraw buffer beyond the visible camera window)
- `scripts/autoload/game_manager.gd` — XP curve (`XP_BASE`, `XP_PER_LEVEL_GROWTH`), per-level stat growth (`LEVEL_STAT_GROWTH`), ability definitions and `MAX_ABILITY_RANK`, `FINAL_WAVE` (which wave triggers a new loop), `ENEMY_HP_GROWTH_PER_LOOP` (difficulty ramp between loops)
- `scenes/ui/hud.gd` — `END_SCREEN_RESTART_DELAY`, `DEBUG_SPEED_STEPS` (Debug panel's speed cycle)
