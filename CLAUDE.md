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
single source of truth for game state: current wave, currency, XP/level/item ranks, enemy counts,
and the `State` enum (`INTRO`, `PLAYING`, `GAME_OVER`, `WON`). Almost every gameplay script gates
its `_process` logic behind `if GameManager.state != GameManager.State.PLAYING: return`. Wave
progression is continuous — clearing a wave immediately calls `start_next_wave()`, there is no
forced pause between waves. All player progression lives here, not on the player node.

**`reset_game()` must be called from `main.gd`'s `_enter_tree()`, not `_ready()`.** Godot calls a
parent's `_ready()` *after* its children's, so resetting in `_ready()` would let `player.gd` and
`hud.gd` initialize from the *previous* run's level/item ranks — visible as wrong stats after the
Game Over auto-restart (`reload_current_scene()`), since `GameManager` is an autoload and survives
the reload.

**`scenes/main.gd`** owns wave spawning only (enemy count/timing per wave, spawn position). It does
not own wave progression or rewards — those events come back from `GameManager` via signals
(`wave_started`, `wave_cleared`, `game_over_triggered`, `game_won_triggered`). Enemy count per wave
uses a square-root curve (`enemies_base_count + sqrt(wave_number - 1) * difficulty_growth`) so
difficulty ramps gradually, and `max_concurrent_enemies` caps how many can be alive at once
regardless of how many are left to spawn.

**Design goal for future wave/enemy-count tuning: optimize for a growing on-screen enemy density,
bullet-hell-style "overwhelm" tension — not just total kill count or flat stat scaling.** The
player should feel progressively more surrounded as a wave (or loop) goes on, not face a flat or
instantly-spiking threat level. When adjusting `enemies_base_count`/`difficulty_growth`/
`spawn_interval`/`max_concurrent_enemies` (or redesigning the wave/loop curve — see
`project_balance_deferred` in memory), judge the change by the *shape* of concurrent-enemies-over-
time, not only by win/lose or average survival wave. Planned: a Debug panel telemetry readout
(concurrent enemy count, "close calls" — HP dropping low and recovering) to make this shape
observable during manual playtesting, not yet built.

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

**Ranged enemies** (`scenes/enemies/ranged_enemy.tscn`): the second enemy variant after Elite, and
like Elite it reuses `enemy.gd` rather than needing its own script — `is_ranged = true` switches the
attack branch in `_process()` from a direct `player_ref.take_damage(contact_damage)` call to
`_shoot_projectile()`, which instantiates `projectile_scene` aimed at the player.
`melee_range` doubles as engagement/firing range for a ranged enemy — it's the same "how close
before I stop and attack" field either way, just interpreted as "how far I can shoot" instead of
"how close I need to be to hit." Same size `Polygon2D` as the base enemy, just a different color.
`main.gd`'s `ranged_enemy_chance`/`sniper_enemy_chance` mix ranged variants into the *regular* wave
spawn queue (not wave-10-exclusive like Elite) via one shared `randf()` roll per non-Elite spawn
(`_spawn_enemy()`) — checking `sniper_enemy_chance` first, then `sniper_enemy_chance +
ranged_enemy_chance` for the ranged tier, falling through to the normal melee enemy otherwise. A
single shared roll (not independent per-type rolls) is deliberate: independent rolls could both
succeed for the same spawn with no defined precedence, silently favoring whichever `if` happened to
be checked last.

**Sniper enemies** (`scenes/enemies/sniper_enemy.tscn`): the third variant, same pattern as ranged
(`is_ranged = true`, shares `enemy_projectile.tscn`) but with `melee_range` (550) set *higher than
the player's own base `attack_range`* (400) — this is the entire mechanic, no new code. Since
`player.gd` only advances (`global_position.x += move_speed * delta`) when **nothing** is within its
own `get_attack_range()`, and a sniper's engagement range exceeds that, the player can never reach a
sniper to fight back while *any other, closer* enemy is still alive and holding the player in place —
the sniper keeps landing free hits until the player clears the field enough to advance into its own
range. This emergent "protected artillery" behavior wasn't purpose-built; it falls directly out of
the existing move-when-clear logic once an enemy's range is allowed to exceed the player's, which is
exactly why `sniper_enemy_chance` (0.15) is set lower than `ranged_enemy_chance` (0.3) — snipers are
meant to read as a rarer, more dangerous variant, not a routine replacement for the base enemy.

**Ranged/sniper chance ramps in over the first few waves of loop 1** (`main.gd`'s
`variant_ramp_start_wave`/`variant_ramp_full_wave`, `_variant_chance_multiplier()`): before wave 3
neither variant can spawn at all; between wave 3 and wave 7 their chance grows linearly from 0 up to
the full `ranged_enemy_chance`/`sniper_enemy_chance`; from wave 7 on it's the full configured value.
This was a data-backed fix, not a guess — a headless simulation (real `main.tscn`/`player.gd`/
`enemy.gd`, sped up via `Engine.time_scale`, "Auto" draft picking so it plays like a no-strategy
player) showed **0/10 runs surviving even wave 1-4** with both variants active from wave 1 at their
full chance, versus **4/10 runs clearing both of the first two loops** (20 waves) when ranged/sniper
were disabled entirely — the dominant killer was ranged/sniper landing free, unavoidable damage from
outside the player's own `attack_range` before the player had *any* item or level yet, not raw enemy
count. Re-running the same simulation after adding the ramp pushed the average death wave from ~2.3
to ~4.1 — a real improvement, but still short of reliably clearing 20 waves, so the ramp alone is a
partial fix, not a finished balance pass (see the loop-1-only caveat below for why it isn't applied
more broadly). **The ramp only applies in `loop_count == 1`** — from loop 2 onward both chances are
always full — because by loop 2 the player has already been through the ramp once and carries level/
item progression forward (see "Both player progression AND position/HP persist across loops" above),
so softening the opening again would just make the endless mode easier over time instead of harder.

**Enemy projectiles are their own script, never the player's** (`scenes/enemies/enemy_projectile.gd`,
instantiated by `enemy.gd`'s `_shoot_projectile()`) — this satisfies a constraint flagged before any
ranged enemy existed: since enemies don't block each other and can visually overlap (see above),
`scenes/projectiles/projectile.gd`'s "target lost" fallback (scan the `enemies` group for the
nearest target) would be actively dangerous reused for an enemy's own projectile — it would let one
enemy shoot another in the back the moment its assigned target (the player) became invalid.
`enemy_projectile.gd` has no such fallback at all: if `target` isn't valid, the projectile just
keeps flying left and eventually self-cleans up off-screen, full stop, no scanning for a substitute
target of any kind. It also flies the opposite direction (`position.x -= speed * delta`, vs. the
player's projectile flying right) and cleans up past the *left* edge of the camera's view instead of
the right, and its `hit_radius` is a fixed export rather than read from the target (`projectile.gd`
reads `target.hit_radius` because enemies come in different visual sizes; there's only one possible
target type for an enemy projectile — the player — so a fixed value matching the player's own
`Polygon2D` half-width is simpler and sufficient).

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
persist across loops** — level, XP, item ranks, currency, world position, and current HP
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
(`Control/HPBar/RegenLabel`) anchored to the right end of the HP bar, hidden whenever HP
is already full (`_update_hp_regen_label()` in `hud.gd`) so it doesn't clutter the bar when it isn't
doing anything.

**HUD "Kolo" vs. "Úroveň"**: the top-right `LoopLabel` ("Kolo N") is the loop counter; it's
deliberately *not* called "Úroveň" even though that's the literal translation, because "Úroveň" is
already used for the player's XP-based character level (the badge over the portrait, top-left —
see "HUD layout" below). Reusing the same word for two different counters on screen at once would
be confusing — rename both consistently if this ever needs to change.

**Elite enemy (final wave only)**: `scenes/enemies/elite_enemy.tscn` reuses `enemy.gd` (it's fully
data-driven via `@export` vars, so no new script was needed) with `speed` halved, `max_hp` tripled,
and the `Polygon2D` visual scaled 3x — `melee_range` was also bumped (60 → 100) so the much bigger
sprite doesn't visually overlap the player before it stops to attack. `main.gd`'s
`elite_count_final_wave` (default 1) controls how many spawn; `_on_wave_started()` only queues
Elites when `wave_number == GameManager.FINAL_WAVE`, and `_spawn_enemy()` always drains the Elite
queue before falling back to normal enemies, so the Elite(s) appear first in wave 10, with regular
enemies filling out the rest of the wave's usual sqrt-curve count.

**Scaling a visual around its own center sinks it into the ground** — this bit the Elite once
already: `Polygon2D.scale` scales the shape around the *node's own local origin*, which coincides
with the enemy's `global_position` (the point all gameplay distance math uses). A normal enemy's
polygon is vertically centered on that point (±24px), so scaling it 3x for the Elite made it ±72px
— the bottom edge dropped from `origin + 24` to `origin + 72`, visibly sinking ~48px into the
ground even though `global_position` (and therefore every gameplay check) never moved. Fixed by
also setting the Elite's `Polygon2D.position = Vector2(0, -48)`: since a node's `position` offsets
its *already-scaled* content in the parent's coordinate space, this shifts the whole scaled shape
up by exactly the amount needed to put its bottom edge back at `origin + 24`, matching every other
enemy's ground line — the shape now grows upward from a shared "feet" line instead of expanding
symmetrically from the center. Any future differently-scaled enemy visual needs the same treatment:
`position.y = -(scaled_half_height - unscaled_half_height)` on the scaled `Polygon2D`, purely
cosmetic and independent of `melee_range`/`hit_radius`/spawn math, which all key off the parent
node's `global_position` and were never affected by this bug.

**Intro/drop-in sequence**: on start, the player falls from above into position
(`_play_drop_in_animation` in `player.gd`) while `GameManager.state == State.INTRO`, which blocks
all gameplay `_process` logic automatically. `_on_landed()` triggers a screen shake, a squash
tween, a procedural impact ring (`scenes/effects/impact_effect.gd`), waits for all three to finish
playing, and only then calls `GameManager.begin_intro_ability_draft()` (see "STALE" notes under
"Schopnosti (dovednostní strom)" below — this used to also chain into a forced skill-tree point,
removed 2026-09-26; the wait/timing mechanics described here are unaffected by that change).

**That wait is deliberate, added same-day as a fix**: the intro offer used to fire
immediately, which pauses the tree the instant the panel shows — cutting the screen shake, squash
tween, and impact ring off mid-animation, since none of those cosmetic effects run at
`process_mode = ALWAYS` (unlike the HUD, which does). Fixed by awaiting
`get_tree().create_timer(impact_effect.duration).timeout` before calling
`begin_intro_ability_draft()` — `_spawn_impact_effect()` now returns the instantiated effect node
so `_on_landed()` can read its actual `duration` (0.4s by default) rather than hardcoding a
duplicate number. The impact ring is deliberately the one to wait on: it's the longest of the
three (camera shake's default `duration` in `camera_follow.gd`'s `shake()` is 0.22s, the squash
tween is `0.08 + 0.15 = 0.23s`), so waiting for it covers the other two automatically. **Verified
with a headless test sampling the intro panel's `visible` at several timestamps** — confirmed
`false` at 0.6s and 0.8s post-scene-start (still mid-effects) and `true` by 0.98s (0.55s fall +
0.4s impact ring + a hair of frame slack), not immediately after the 0.55s landing. (That test
predates the 2026-09-26 switch to `SkillTreePanel`, see below — the timing itself is unchanged,
only the panel's name and what it shows.)

**STALE (2026-09-25 → 2026-09-26, then reverted the same day): the player's very first skill point
used to be granted BEFORE the game starts** via a now-deleted `begin_intro_skill_tree()`, force-
opening `SkillTreePanel` during `State.INTRO`. **Removed on explicit user request the same day** —
"první dovednostní bod hráč dostane až na druhém levelu... nezobrazí se panel na začátku hry." The
first skill point now arrives exactly like every other one: through `_level_up()` when the player
reaches level 2, no earlier and with no special-cased panel. `player.gd`'s `_on_landed()` still
kicks off the intro's only remaining step, the random-draft schopnosti offer
(`begin_intro_ability_draft()`), and `resolve_ability_draft()` calls `finish_intro()` **directly**
once that offer resolves — `SkillTreePanel` plays no role in intro sequencing anymore and only
opens when the player clicks the portrait themselves. `hud.gd`'s `_on_skill_points_changed()` and
`_on_skill_tree_close_pressed()` both dropped their `state == State.INTRO` special-casing since
it's unreachable now. **Verified with a headless test**: resolving the intro ability-draft offer
transitions `state` to `PLAYING` while `pending_skill_points` stays `0`, and reaching level 2
(`add_xp(xp_for_next_level())`) is the first point to ever increment it.

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

**Progression (XP → levels → schopnosti)**: enemies grant `reward` (gold) *and* `xp_reward` on
death via `GameManager.enemy_defeated(reward, xp_reward)`. XP accumulates toward
`xp_for_next_level()` (`XP_BASE + (level - 1) * XP_PER_LEVEL_GROWTH`); `add_xp()` loops so one big
XP chunk can grant several levels at once. **`XP_BASE` is tuned to 40, not the curve's original 60**,
specifically so the first level-up lands before the end of wave 1 rather than partway through wave
2 — with the base enemy's `xp_reward` of 12 and `main.gd`'s wave-1 count of 4, that's exactly 48 XP
from clearing wave 1 alone. This was a deliberate pacing choice (verified with a throwaway headless
simulation of waves 1-3, not just eyeballed). Every level grants a small automatic stat bump via
`GameManager.LEVEL_STAT_GROWTH` (a flat per-stat amount × `player_level - 1`, added in
`get_stat_bonus()`); the real *choice*-driven growth comes from "Schopnosti" (see below), offered
on **every** level-up.

**`LEVEL_STAT_GROWTH` was re-added 2026-09-09 after being deliberately removed earlier** (see git
history) — the original removal was about making every stat point trace back to a visible, chosen
pick so nothing was an invisible sum; the re-addition solves a different problem, flagged as the
"Balance caveat" below: a run's power depended *entirely* on draft luck, so a string of bad offers
could leave a level-15 character barely stronger than a level-1 one. `LEVEL_STAT_GROWTH`'s values
are deliberately small relative to a picked schopnost (e.g. one Silver-rarity "Přebíječ jader"
grants +9.6 damage; a level of automatic growth grants +0.5) — it's a floor under a run's power, not
a replacement for schopnosti/shop as the main source of it, so player choices still define *most* of
a build's identity.

**Stats flow**: base stats live as `@export` vars on `player.gd` (`base_damage`,
`base_attack_speed`, `base_attack_range`, `base_max_hp`, `base_armor`, `base_crit_chance`).
Effective stats come from getters (`get_damage()`, `get_attack_speed()`, `get_attack_range()`,
`get_target_count()`, `get_hp_regen()`, `get_armor()`, `get_crit_chance()`) that add
`GameManager.get_stat_bonus(stat_id)` — **the single place where progression turns into numbers**,
summing three sources: `LEVEL_STAT_GROWTH` (automatic, keyed by `player_level`), invested *passive*
schopnosti (see "Schopnosti" below), and the shop's `active_shop_items`. The player recomputes on
the `level_changed` and `skill_ranks_changed` signals. **Balance caveat (partially addressed)**: a
run's power still depends heavily on how the player allocates their skill-tree points and what the
shop happens to offer — but `LEVEL_STAT_GROWTH` guarantees a non-zero floor regardless of either, so
an unlucky/unfocused run is weaker, not stat-flat. Not claimed to fully solve fragility, just to
soften the worst case.

**Critical hits (`base_crit_chance`, `get_crit_chance()`, `CRIT_DAMAGE_MULTIPLIER`)** — added
2026-09-25, explicit user request. `_shoot()` rolls `randf() < get_crit_chance()` **independently
for every individual shot** (same granularity as `_consume_ability_triggers()` — with multishot,
each projectile gets its own roll) and, on a crit, multiplies that shot's damage by
`CRIT_DAMAGE_MULTIPLIER` (**2.0**, fixed per the user's spec — "dvojnásobné zranění" — not itself a
growable stat; only the CHANCE to trigger it grows). The multiply happens **after**
`_consume_ability_triggers()`'s own multiplier (e.g. "Dvojitý zásah"), so a crit on a
double-damage-triggered shot stacks multiplicatively with it, same philosophy as multiple active
schopnosti already stacking multiplicatively rather than additively (see "Schopnosti" above).
`base_crit_chance` defaults to 0.05 (5%) — a small non-zero floor so crits are visible in vanilla
play, mirroring `base_armor`/`base_hp_regen`'s "small always-on baseline" treatment. **Deliberately
has no `LEVEL_STAT_GROWTH` entry**, same precedent as `multishot` — it's a pure choice-driven stat
from schopnosti/shop, not an automatic per-level floor. No damage-number/visual feedback exists for
a crit landing (no floating combat text anywhere in this project yet) — purely a math change for
now; revisit if crits turn out to feel invisible in actual play.

**`crit_chance` is the only stat stored as a fraction (0.08 = 8%), not an absolute number** — every
formatting path that turns a stat into display text special-cases it via
`GameManager._format_stat_line(stat_id, value)` (`+8 % šance na kritický zásah`, `value * 100`)
instead of the generic `STAT_DISPLAY_NAMES`/`_format_stat_number()` pair every other stat uses. Both
`get_ability_desc()` and `get_shop_item_desc()` route ALL their stat-line formatting through this one
helper now (refactored from 4 near-duplicate inline call sites) specifically so adding `crit_chance`
only needed one special case, not four. The `Control/BottomBar` stat column also shows it
(`StatCrit`, `hud.gd`'s `_refresh_stat_labels()`) — the 5 existing rows there had to shrink from a
28px step to 22px to fit a 6th row inside `BottomBar`'s fixed 140px height without overflowing (this
also incidentally fixed a pre-existing 6px overflow `StatArmor` already had before this change).

**Two new entries pay off the new stat, tagged "precision"** (fits alongside the existing
accuracy/rate-of-fire precision entries) — `ABILITIES["precision_targeting"]` (passive, +6%
`crit_chance` at Bronze) and `SHOP_ITEMS["precision_scope"]` (multi-stat: `crit_chance` +
`attack_speed`, so it doesn't read as an isolated crit-only stick). Neither uses the tag-synergy
`"synergy"` shape (see "Tag synergie" above) — both are plain flat-value entries, deliberately not
scaling with owned-tag count, to keep this pass focused on introducing the stat itself rather than
compounding it with the synergy mechanic. **Verified with headless tests**: hand-calculated
`get_stat_bonus("crit_chance")` for a constructed ability+item combination, confirmed every
ability/item description still renders without error at all 4 rarities (regression check on the
`_format_stat_line()` refactor), and a scene-level test that force-set `base_crit_chance` to `0.0`
then `1.0` and asserted real `_shoot()` calls against a real `enemy.tscn` target never/always
produced exactly `get_damage() * CRIT_DAMAGE_MULTIPLIER`.

**Armor (`base_armor`, `get_armor()`, `kinetic_dampers` schopnost)**: a flat, per-hit damage
reduction — `take_damage()` in `player.gd` computes `reduced_amount = max(amount - get_armor(),
amount * MIN_DAMAGE_RATIO)` (`MIN_DAMAGE_RATIO` 0.1, so at least 10% of any hit always gets through,
even against a fully-stacked armor build — this stops armor from ever granting outright immunity to
a future, harder-hitting enemy type). This is a standard genre tool for a specific failure mode:
"death by many small simultaneous hits" (several enemies each landing modest contact damage) rather
than "death by one big hit" — unlike a percentage-based mitigation stat, a *flat* reduction hits
weak/frequent damage sources hardest, which is exactly the profile of this game's enemies (see
"data-backed fix" below). `base_armor` defaults to 2.0 (all current enemies deal exactly 5 contact
damage, so base armor alone cuts that to 3 — a 40% reduction before any item at all);
`kinetic_dampers` grants +2 armor at Bronze rarity (matching `base_armor`'s scale), scaling up with
rarity/merges like any other passive schopnost (see "Schopnosti" below).

**This was a data-backed fix, not a guess** — same headless simulation approach as the ranged/sniper
ramp above (real `main.tscn`, auto-picking progression choices, sped up via `Engine.time_scale`).
Before armor, even with the ranged/sniper ramp already in place, 0/10 runs survived both of the first
two loops (20 waves) and the average death wave was ~4.1; after adding armor, in a follow-up batch of
10 runs, 7 died between wave 5 of loop 1 and wave 10 of **loop 2** (one run died on the very last
wave of loop 1 after clearing it entirely; another died on the very last wave of loop 2, i.e. 19 of
20 waves cleared), and the other 3 were still going when the simulation's time budget ran out. No
config change here is claimed to make the game *strictly* survivable end-to-end — it moved the
typical death point from "wave 2-4 of loop 1" to "deep into loop 1 or partway through loop 2," which
is the kind of improvement that's meant to be judged by playtesting feel, not chased to a specific
number.

**Schopnosti (`GameManager.ABILITIES`/`ABILITY_ORDER`/`SKILL_TREE_BRANCHES`, `Control/SkillTreePanel`
in `hud.tscn`) — a deterministic DOVEDNOSTNÍ STROM (skill tree)**, reworked 2026-09-26 on explicit
user direction from a fully different paradigm: the previous system (documented below only for
historical context — if you see `owned_abilities`, `pending_ability_drafts`,
`_current_ability_offer`, `ability_draft_ready`, `AbilityDraftPanel`, `_roll_ability_options()`,
`_try_merge_ability()`, `ABILITY_CHOICE_COUNT`, `ABILITY_MERGE_THRESHOLD`, `ABILITY_RARITY_WEIGHTS`,
or `PASSIVE_EFFECT_MULTIPLIERS` referenced anywhere, they're all stale) offered 3 RANDOM cards every
level-up and merged accidental duplicates; the tree instead gives the player a fixed pool of 11
schopnosti arranged into 4 branches and lets them deliberately choose exactly where every point
goes, with a strict rank-up-only progression (no RNG, no merging). The user's stated motivation was
giving the player "something to do between levels" beyond just watching the auto-battle, in a form
that reads as deliberate strategic planning (a tech tree) rather than another random draft.

**Every `ABILITIES` entry now has `"max_rank"`** (3 for a branch's non-capstone nodes, 5 for its
final/capstone node) in addition to its existing `"type"` shape:
- **`"passive"`** — `{"stat": String, "value": float, "max_rank": int}` (or `{"synergy": {...},
  "max_rank": int}` for the two tag-synergy nodes, see "Tag synergie" below) — `"value"` is the
  PER-RANK amount; `get_stat_bonus()` multiplies it by the current rank LINEARLY (`value * rank`),
  no multiplier curve. This is a deliberate simplification over the old system's
  `PASSIVE_EFFECT_MULTIPLIERS` — there's only one deterministically-growing number per node now,
  not independently-rolled copies to reconcile, so a flat per-rank value is both simpler to
  implement and easier for the player to read directly off the UI ("rank 2/3" × "+4 per rank" = "+8
  currently, +12 at max" is trivial arithmetic the player can do themselves).
- **`"active"`** (`double_tap`, `orbital_bombardment`) — `{"trigger": String, "trigger_values":
  Array (one value per RANK, sized to exactly `max_rank`), "effect": String, "effect_params":
  Dictionary}`. Rank still scales trigger FREQUENCY, not effect magnitude, same philosophy as
  before — `double_tap`'s `trigger_values` shrank from 4 entries to 3 (`[6, 5, 4]`, it's no longer a
  capstone) and `orbital_bombardment`'s grew from 4 to 5 (`[20.0, 15.0, 11.0, 8.0, 6.0]`, it IS the
  explosive branch's capstone) — continuing the existing diminishing-interval curve for the new 5th
  entry, first-pass number like the rest, not balance-tuned. Resolved entirely in `player.gd` (see
  below), NOT in `get_stat_bonus()`.

**The tree has 4 branches, one per tag, each a plain ordered `Array[String]` from root to capstone**
(`GameManager.SKILL_TREE_BRANCHES`):
```
Kinetická:  power_core → split_rounds → overclock_matrix
Přesná:     rapid_coils → long_barrel → precision_targeting
Podpůrná:   reinforced_plating → nanite_repair → kinetic_dampers
Explozivní: double_tap → orbital_bombardment
```
The explosive branch is deliberately shorter (2 nodes, not 3) — a branch doesn't need to match the
others' length, only the "root → ... → capstone" shape. **A node's prerequisite is derived from its
position in this array, not stored as its own field** (`get_skill_prereq(ability_id)` scans the 4
branches and returns the previous entry, or `""` for index 0) — avoids keeping two sources of truth
(an explicit `"prereq"` key that could drift from the branch order) in sync by hand.
`is_skill_node_unlocked(ability_id)` is true for a root (`prereq == ""`) or once
`get_skill_rank(prereq) >= 1` — **"unlocked" does NOT mean "free"**: a root still needs its own
invested point like any other node, it just has no node before it (explicit user clarification
during design: "kořen taky vyžaduje vlastní investici, jen nemá podmínku před sebou").

**Point economy**: `GameManager.pending_skill_points` (int, run-scoped, reset in `reset_game()`)
grants exactly **1 point per level-up** (`_level_up()`, same cadence as the old draft's "every
level, no interval" — that reasoning still holds, see the git history of this section for the
empirical XP-curve verification that motivated it) — but unlike the old system, a level-up no
longer auto-opens or pauses ANYTHING. `skill_ranks: Dictionary` (`{ability_id: rank}`, missing key
== rank 0) replaces `owned_abilities` — there is at most ONE "copy" of any schopnost now (a growing
rank, not independent stackable instances), so a single Dictionary is sufficient; no active/stash
split either (schopnosti still have no purchase-slot pressure, same as before). `invest_skill_point
(ability_id)` is the only way a rank ever increases: checks `can_invest_skill_point()` (points > 0,
node unlocked, rank < max_rank), then decrements the point and increments the rank atomically,
emitting both `skill_points_changed`/`skill_ranks_changed`.

**The portrét is a clickable `Button` that turns yellow with a "+N" badge whenever points are
pending** (explicit user spec) — `Control/Portrait` changed type from `ColorRect` to `Button`
(keeping its default theme look, `modulate` toggles it yellow `Color(1.0, 0.85, 0.2)` vs. white),
and a new sibling `SkillPointBadge`/`SkillPointLabel` pair (mirrors the existing
`LevelBadge`/`LevelLabel` pattern, just anchored to Portrait's TOP-right corner instead of bottom
-right so the two badges don't collide) shows the literal count. `LevelBadge`/`LevelLabel` and the
new badge pair all need `mouse_filter = 2` (IGNORE) since they're siblings overlapping Portrait's
corners, not children of it — without that, clicking those small badge areas would swallow the
click before it reaches the Button underneath (same pattern as the old draft cards' icon
`mouse_filter` fix). `hud.gd`'s `_on_skill_points_changed(new_amount)` is the single place that
updates the badge AND decides whether to force-open `SkillTreePanel` — it only does the latter when
`new_amount > 0 AND state == State.INTRO` (guards against the handler firing during `_ready()`'s
`_refresh_progression()` call, when `new_amount` is still 0 and nothing should pop up yet). Every
other level-up just updates the badge and leaves the game running — the player decides when (or
whether) to stop and spend, which is the actual mechanism that answers the user's original ask
("something to do between levels" without forcing a stop every time).

**`SkillTreePanel` is built procedurally in `hud.gd`** (`_build_skill_tree_ui()`/
`_refresh_skill_tree_ui()`, same "small but needs per-node dynamic wiring" reasoning as the shop's
mini-slots/blueprint rows) — one node card per `SKILL_TREE_BRANCHES` entry, laid out in a 4-column
(branch) × up to-3-row grid (`SKILL_NODE_WIDTH/HEIGHT/GAP`), each card showing name, "Stupeň N/M",
a value description (`get_ability_desc(ability_id, rank)`, or "Zatím neinvestováno" at rank 0), and
a single stateful `ActionButton`. A locked node (`is_skill_node_unlocked() == false`) is tinted
`LOCKED_ITEM_MODULATE`, shows "Zamčeno" as both its rank line and its (disabled) button text — an
unlocked-but-unaffordable node (0 pending points, or already at `max_rank`) is NOT tinted and shows
real state ("Investovat"/"Max"), just disabled; **these two disabled states look different on
purpose** (grayed card = locked, normal card + disabled button = "you could invest here but not
right now") so the player can tell "not available yet" from "already maxed / no points left" at a
glance. `_on_skill_node_pressed(ability_id)` just calls `GameManager.invest_skill_point(ability_id)`
— all validation lives in GameManager, the button handler is a thin pass-through.

**CORRECTION (2026-09-26, later the same day): the skill tree no longer has any intro-forced
point/panel at all.** The paragraph above describing `begin_intro_skill_tree()` forcing the panel
open before the game starts is now stale — that function and its intro hookup were removed on
explicit user request ("první dovednostní bod hráč dostane až na druhém levelu... nezobrazí se
panel na začátku hry"). The first skill point now arrives exactly like every other one, through the
normal `_level_up()` path when the player reaches **level 2** — there is nothing special about it
at all. `player.gd`'s `_on_landed()` still calls `GameManager.begin_intro_ability_draft()` (the
random-draft schopnosti offer, unaffected by this change), and `resolve_ability_draft()` now calls
`finish_intro()` **directly** once that offer resolves — the dovednosti/skill-tree system plays no
part in intro sequencing anymore, so `SkillTreePanel` never appears until the player clicks the
portrait themselves (which won't have anything to show until level 2 lights up the badge).
`_on_skill_points_changed()` and `_on_skill_tree_close_pressed()` in `hud.gd` both dropped their
`state == State.INTRO` special-casing accordingly, since it's now unreachable.

**Debug panel affordances were renamed, not removed, to match**: "Vynutit schopnost" →
`AddSkillPointButton` ("+1 bod schopnosti", calls the renamed `debug_add_skill_point()`); "Max
schopnosti"/"Reset schopnosti" → `MaxSkillTreeButton`/`ResetSkillTreeButton` (`debug_max_skill_tree()`
sets every node straight to its `max_rank`, `debug_reset_skill_tree()` clears `skill_ranks` AND
`pending_skill_points`); "Auto vylepšení" → `AddManySkillPointsButton` ("+5 bodů schopnosti") — the
old toggle auto-resolved random *draft offers*, which no longer exist (the player always picks
deliberately now), so it was repurposed as a bulk point grant for faster manual tree testing rather
than left as dead functionality.

**Trigger/effect resolution still lives in `player.gd`, not `game_manager.gd`** — GameManager only
owns the *data* (which schopnosti exist, their rank). `player.gd` has TWO separate consumer
functions, one per trigger type, both reading/writing a shared progress store — **now a
`Dictionary` keyed by `ability_id`** (`_ability_progress: Dictionary`, changed from the old
`Array[float]` parallel-indexed to `owned_abilities`) — since a schopnost's identity is now the
stable `ability_id` itself (at most one rank-track per id, no more independently-stackable
instances to index), the progress dictionary genuinely improves over the old array: investing a
LATER point into an ALREADY-unlocked active schopnost no longer resets its in-flight progress
(`_on_skill_ranks_changed()` only zero-initializes a KEY THE FIRST TIME it appears, i.e. when a node
is newly unlocked — an already-tracked key is left alone). The old array-based version had to reset
everything on ANY inventory change because merges reshuffled array indices; that problem doesn't
exist anymore, so the reset was narrowed accordingly, not kept "just in case."
- **`_consume_ability_triggers()`** — called once per individual `_shoot()` (so with multishot, each
  projectile is its own "shot" for trigger-counting purposes, not one shot per volley). For every
  schopnost with `rank >= 1` and `trigger == "shot_count"`, increments its progress by 1; at
  `trigger_values[rank - 1]`, resets to 0 and (for `effect == "damage_multiplier"`) multiplies a
  returned multiplier by `effect_params.multiplier`. `_shoot()` does `get_damage() *
  _consume_ability_triggers()` before handing the number to the projectile — `get_damage()` itself
  stays pure stat math, with the schopnost's burst damage applied only to that one shot.
- **`_process_time_based_abilities(delta)`** — called every frame from `_process()`, independent of
  shooting/range (so it keeps charging even with no enemy in sight). For every schopnost with
  `rank >= 1` and `trigger == "time_elapsed"`, increments its progress by `delta` (a float, not an
  integer shot count); at `trigger_values[rank - 1]`, resets to 0 and (for `effect ==
  "aoe_strike"`) calls `_trigger_aoe_strike()`, which deals `effect_params.damage` to **every alive
  enemy** (`get_tree().get_nodes_in_group("enemies")`) through their normal `take_damage()` — same
  reasoning as `debug_skip_wave()` in `main.gd`: routing through the real method keeps reward/XP and
  the double-kill-safe `_is_dead` guard intact, no shortcut around them — then spawns a visual via
  `orbital_strike_effect_scene` (a `PackedScene` export reusing `impact_effect.gd`'s script with a
  bigger radius/different color set directly in `orbital_strike_effect.tscn`, no new script needed).

**This trigger/effect handling is currently hardcoded for the two existing pairs**
(`shot_count`/`damage_multiplier` and `time_elapsed`/`aoe_strike`) — both in `player.gd` and in
`GameManager.get_ability_value_text()`'s description text — deliberately not yet generalized into a
dispatch table; a third, genuinely different pair is what should drive that generalization, not a
guess at what it'll need in advance.

**Verified with headless tests at both layers**: a pure-logic test (loads a fresh `game_manager.gd`
instance directly, no autoloads) walks the full chain — roots unlocked/non-roots locked from the
start, `can_invest_skill_point()`/`invest_skill_point()` gating, unlocking cascades correctly
(investing a root's first point unlocks its child), `get_stat_bonus()` matches hand-computed values
(including the `overclock_matrix` tag-synergy node at rank 5 with 3 owned kinetic-tagged things, and
the automatic `LEVEL_STAT_GROWTH` floor layered on top), every `ABILITY_ORDER` entry's description
renders at every rank 1..max_rank without error, `debug_max_skill_tree()`/`debug_reset_skill_tree()`
work, `reset_game()` clears everything; a scene-level test (real `main.tscn` + `hud.tscn`) confirms
the intro point force-opens `SkillTreePanel` and pauses, that pressing a real node's button updates
`GameManager` state and refreshes the UI (locked → unlocked, rank text, button text), that closing
the intro panel transitions `state` to `PLAYING` and unpauses, and that a LATER level-up shows the
badge WITHOUT auto-opening anything (confirming the intro case is a real one-time exception, not a
general auto-open-on-points-available rule) — and a live windowed playthrough confirmed the same
sequence visually, including the stat panel updating in real time (`Poškození: 10 → 14` after
investing a Bronze-equivalent rank into "Jádro síly").

**HUD layout — a top-left stack, top-right counters, and a slimmed-down `BottomBar`** (`hud.tscn`).
Went through several reshuffles on 2026-09-09 as the user iterated on where things should live;
this describes the current state, current as the authoritative reference (treat any older
description you find elsewhere as stale):

- **Top-left**: `Portrait`/`LevelBadge`/`LevelLabel` (`offset_left = 20`, `offset_top = 20` —
  top edge deliberately matches `HPBar`'s top edge, see below, AND the top margin deliberately
  matches the 20px left margin) beside `HPBar`/`XPBar` (`offset_left = 118`, same relative
  arrangement/sizing `BottomBar` used to have, just moved as one block), then `GoldLabel` directly
  below `XPBar` and left-aligned with it (`offset_left = 118`, `offset_top = 76`), then
  `AbilitiesContainer` below that (`offset_left = 20` — back to `Portrait`'s left edge, not
  `GoldLabel`'s; explicit user request, an intentional asymmetry, not an inconsistency —
  `offset_top = 108`). All direct children of `Control`. Moved here from `BottomBar` 2026-09-09
  (explicit user request) — none of them are anchored/stretched to a bar width anymore, they're
  all fixed-offset. Alignment fine-tuned in two follow-ups the same day: first `Portrait` nudged up
  10px to match `HPBar`'s top exactly and `GoldLabel` moved from under the whole portrait/bars row
  to sit directly under `XPBar` instead (left-aligned with the bars); then the WHOLE top-left block
  shifted down 10px together (so `Portrait`/`HPBar` stayed aligned with each other) once the user
  noticed the resulting 10px top margin looked inconsistent next to the 20px left margin —
  `AbilitiesContainer` shifted down to follow both times.
- **Top-right**: `LoopLabel` ("Kolo N") and `WaveLabel` ("Vlna N"), right-anchored, side by side
  (`WaveLabel` closest to the corner). Moved here from a fixed absolute position near screen-center
  2026-09-09, same change as the top-left move above. **Both labels are right-aligned
  (`horizontal_alignment = 2`), not centered** like every other label in this HUD — `WaveLabel`'s
  box right edge sits at `offset_right = -20` (a 20px margin, deliberately matching `Portrait`'s
  20px left margin on the opposite corner), but centered text inside a fixed-width box leaves extra
  blank space past the text itself, so centering made the rendered text's margin look bigger than
  20px and inconsistent with `Portrait`'s exact 20px. Right-aligning makes the *text* touch the
  20px boundary directly, matching regardless of how many digits "Vlna N" grows to. `LoopLabel`
  sits 20px to `WaveLabel`'s left (`offset_right = -180`, vs. `WaveLabel`'s `offset_left = -160`)
  and was made right-aligned too (explicit user follow-up) so both labels' text hugs their own
  box's right edge consistently, keeping the visible 20px gap between "Kolo N" and "Vlna N" exact
  regardless of either number's digit count.
- **Bottom-right, TEMPORARY** (user's own wording): `DebugButton`. Moved out of its long-standing
  top-right spot 2026-09-09 to make room for `LoopLabel`/`WaveLabel` — expect this to move again
  once the HUD's visual pass settles. Because `BottomBar` is an opaque `ColorRect`, `DebugButton`'s
  node had to be moved to AFTER `BottomBar` (and its children) in `hud.tscn`'s child order, not just
  re-anchored — an earlier-declared sibling renders UNDERNEATH a later one, so leaving it declared
  before `BottomBar` while visually overlapping it would have made the button invisible and
  unclickable. Keep this node-order dependency in mind if `DebugButton` (or anything else meant to
  float on top of `BottomBar`) moves again.
- **`BottomBar` itself** now holds only the stat readouts (`StatDamage`/`StatSpeed`/`StatRange`/
  `StatHP`/`StatArmor`) and `ItemSlot1..6` — currently decorative/unrelated (future equipment
  loot). `ShopButton` was removed entirely earlier the same day (see "Shop opens periodically"
  below); nothing in `BottomBar` reads `GameManager.shop_available` anymore. **`ItemSlot1..6` are
  112×112 squares, centered horizontally in `BottomBar`** (`offset_left = 264` → `offset_right =
  1016` for the 6-slot row as a whole, out of the project's 1280px baseline width — symmetric
  264px margin on each side) and vertically filling the bar's height minus a 14px margin top and
  bottom (`offset_top = 14`, `offset_bottom = 126`, out of `BottomBar`'s 140px height) — explicit
  user request 2026-09-09 ("center them, grow to fill available height, keep the margin, stay
  square"). Slot-to-slot gap is 16px (`offset_left` steps by 128 = 112 + 16). Squares grew from the
  original 44×44 (were left-aligned at `offset_left = 310`, matching the HP/XP bars' old left edge
  from before those moved) — that original size/position is now stale if you see it referenced
  anywhere. The `Label` child of each slot is untouched (`font_size = 9`, anchored to fill the
  parent) — noticeably small relative to the new 112px box, but wasn't part of this request; revisit
  if it reads as too small once real item icons/text exist here.

**STALE, see the correction under "Schopnosti (dovednostní strom)" below** — this paragraph
described an interim state where `AbilitiesContainer` showed dovednosti ranks too; as of
2026-09-26 it shows ONLY schopnosti from the random draft (`owned_abilities`), rebuilt on
`ability_inventory_changed`, not `skill_ranks_changed`. The rest of this paragraph (positional
slots, one per owned instance, reshuffling on merge) is still accurate for that one remaining
source. **Column wrap keeps the stack
from ever reaching `BottomBar`**: slots stack downward and
wrap into a new column to the right after `ABILITY_STACK_MAX_ROWS` (6) — `col = i /
ABILITY_STACK_MAX_ROWS`, `row = i % ABILITY_STACK_MAX_ROWS` — chosen so even a full column (6 × 52px
tall), starting from `AbilitiesContainer`'s `offset_top = 108`, ends (`y = 416`) well above
`BottomBar`'s top edge for the project's 720px-tall window; this is a static budget (like every
other HUD offset in this project, see `ground.gd`'s "no dynamic viewport-based layout" precedent),
not computed from the actual viewport height at runtime, so a much shorter window — or moving
`AbilitiesContainer` further down the screen — would need this constant revisited by hand.

**Shop pauses the game via `get_tree().paused`**, which is why the HUD `CanvasLayer` has
`process_mode = 3` (ALWAYS) in `hud.tscn` — without it the shop's own close button would freeze
along with the game. The pause is deliberate *for now*; the user has flagged that they may later
want the game to keep running while the shop is open, so the pause lives only in
`_on_shop_close_pressed()` / `_close_shop()` / `_on_shop_auto_open_requested()` in `hud.gd` and
nothing else depends on it.

**Shop opens periodically, not any time** (`GameManager.shop_available`,
`shop_auto_open_requested` signal, `_open_periodic_shop()`/`_start_new_loop()`): the shop unlocks
and shows a fresh offer automatically — panel pops open and pauses, no click needed — the moment
wave 10 is cleared and a new loop starts, reusing the existing loop-boundary code path rather than
adding new event plumbing. This resolved a long-standing open design question (shop available any
time vs. gated to a specific moment) via a Bazaar-inspired redesign brainstorm. `shop_available`
turns true the first time this fires in a run and stays true for the rest of that run (kept as
run-scoped state, reset in `reset_game()` — a new run has to clear wave 10 again, same as it has to
re-collect levels/items). **The manual `ShopButton` was removed 2026-09-09** (user asked to move the
gold counter to the top bar and declutter `BottomBar`) — auto-open via
`_on_shop_auto_open_requested()` is now the *only* way the panel appears. Known, accepted trade-off:
if the player closes the panel (`_on_shop_close_pressed()`) before spending/rerolling everything
they want, there is no way to reopen that same offer until the next wave-10 clear generates a new
one — `shop_offer` itself isn't cleared by closing, so the unspent offer is still sitting in
`GameManager` state, just with no UI path back to it this loop. Revisit if this turns out to be a
real player frustration, not just a theoretical gap.

**Shop auto-open no longer needs to defer for anything (2026-09-26)** — it briefly did
(`GameManager._shop_open_deferred`/`_try_open_pending_shop()`, added 2026-09-09, both since
removed): if the killing blow on wave 10's last enemy granted enough XP to level up, that level-up
used to *synchronously* pop the old `AbilityDraftPanel` (inside `enemy_defeated()` → `add_xp()` →
`_level_up()`, before `enemy_defeated()` even got to notice the wave was clear a few lines later),
which could collide with `ShopPanel` trying to auto-open on the very same frame. That collision is
now structurally impossible: a level-up no longer opens or pauses anything by itself (see
"Schopnosti" above — it just adds a point and lights up the portrait badge), so
`_open_periodic_shop()` can call `shop_auto_open_requested.emit()` directly and unconditionally.
**`SkillTreePanel` no longer force-opens automatically at all** (removed 2026-09-26, see the
correction under "Schopnosti (dovednostní strom)" above) — it can never collide with the shop.

**The offer is `SHOP_OFFER_SIZE` (4) random items out of the full 7-item pool, not all 7 at once**
(`GameManager.shop_offer`, `_generate_shop_offer()`) — picked via `SHOP_ITEM_ORDER.duplicate();
pool.shuffle(); pool.slice(0, SHOP_OFFER_SIZE)`, so duplicates within one offer are impossible.
Already-owned items **can** appear in the offer (not filtered out) — with only 4 discrete items and
no ranks, there'd be no way to ever revisit an owned item otherwise; today buying it again is just
blocked (`can_buy_shop_item()`), but this is deliberately left open for the planned rarity system
(a future item, seeing itself in the offer, becomes an "upgrade" opportunity instead of a dead
click — see `project_shop_implementation_plan` memory). The four `ShopCard0..3` nodes are bound to
their **slot index**, not a fixed item ID (`_setup_shop_cards()`/`_on_shop_card_action_pressed()`)
— unlike the old always-full catalog, what's shown in slot 2 changes every reroll, so the click
handler resolves `GameManager.shop_offer[slot_index]` at click time rather than trusting a
value captured at setup.

**Reroll costs `SHOP_REROLL_BASE_COST` (20) for the first reroll, `+SHOP_REROLL_COST_STEP` (15) for
each further reroll within the same offer** (20, 35, 50, ...) — `shop_reroll_count` resets to 0
only when a *new* offer is generated (wave-10 unlock or a completed reroll), so closing and
reopening the shop does **not** reset the price ramp; the ramp exists specifically to stop
infinite-free-rerolling for a perfect draw. `GameManager.debug_free_reroll` (Debug panel's
"Free reroll" toggle) makes `get_shop_reroll_cost()` always return 0 for fast manual testing — like
`Engine.time_scale`, this is intentionally **not** reset by `reset_game()` (dev convenience across
restarts, not game state).

**`ShopPanel` must stay well under the game's 720px window height** — it once grew to exactly
720px tall (edge-to-edge with the default window, zero margin) after adding a now-removed combine-
items section, which pushed the "Zavřít obchod" button off-screen with no way to close the panel.
Currently 520px tall (offer row + reroll button + active row + stash row + close button) — still
under budget, but with much less spare margin than before now that the active/stash sections exist;
any future addition needs to actively check this rather than assume there's room.

**Tag synergie — schopnosti a itemy sdílejí kategorie, aby šlo plánovat build kolem obou zdrojů
dohromady** (added 2026-09-25, explicit user request: "chci vymýšlet strategii volby itemů podle
schopností, a naopak"). Every `ABILITIES` and `SHOP_ITEMS` entry now carries a `"tags"` array
(currently always exactly 1 tag) from a shared 4-value set: `"kinetic"` (raw damage/multishot),
`"precision"` (attack speed/range), `"explosive"` (the two active schopnosti), `"support"`
(HP/regen/armor) — display names in `TAG_DISPLAY_NAMES`. The tag itself is purely informational for
most entries (shown as a `[TagName]` suffix appended by `_format_tag_suffix()` at the end of
`get_ability_desc()`/`get_shop_item_desc()` — no `hud.tscn`/`hud.gd` changes were needed, since
every card/tooltip in the HUD already renders through those two functions) — it exists so a player
can recognize "this schopnost and that shop item are both Precision" and plan a build around the
category before either the actual synergy piece appears.

**The real payoff is two NEW entries whose bonus scales with how many owned things share a tag** —
`ABILITIES["overclock_matrix"]` ("Přetěžovací matice", Kinetic, scales `damage`, kinetic branch's
capstone) and `SHOP_ITEMS["resonance_array"]` ("Rezonanční pole", Precision, scales `attack_speed`)
— one in each system, deliberately mirroring each other so the synergy works in BOTH directions the
user asked about: invest in the schopnost branch first and hunt for matching-tag shop items
afterward, or buy the item first and prioritize investing in that tag's branch at the next few
level-ups. These use a `"synergy": {"stat": String, "tag": String, "value": float}` dict instead of
the usual flat `"stat"/"value"` (abilities) or `"stats"` dict (shop items) — `value` is the
per-RANK bonus (schopnosti) or Bronze-tier bonus (shop items) **per owned thing carrying that tag,
counting the synergy piece itself**. `_count_owned_with_tag(tag)` (in `game_manager.gd`) sums
matches across `skill_ranks` (schopnosti with `rank >= 1`, counted once each regardless of how high
the rank — synergy scales with how many DIFFERENT things you own in the tag family, not how
invested each one is) AND `active_shop_items` together (stashed items don't count, same rule as
everything else stat-relevant) — a player with `power_core` at any rank plus `overclock_matrix` at
rank 5 has `_count_owned_with_tag("kinetic") == 2`, so `overclock_matrix` alone contributes
`1.5 * 5 * 2` damage, on top of `power_core`'s own `4.0 * its_rank`. **`get_stat_bonus()` branches
on `definition.has("synergy")`** for both the passive-schopnost loop and the active-shop-item loop
(falls through to the existing flat-value path otherwise) — and the shop-item loop reads
`SHOP_ITEMS[id].get("stats", {})` instead of a direct `["stats"]` index, since `resonance_array` has
no `"stats"` key at all (`.get()` with a default avoids the runtime error a missing-key `Dictionary`
index would otherwise throw when assigned to a typed `Dictionary` variable). **This is a first-pass
tag assignment, not a balance pass** — `support` ended up with 6 of the 16 total entries vs.
`explosive`'s 2, so a Support-tag synergy piece (if one gets added later) would be far easier to
stack than an Explosive one; revisit the tag distribution once there are more entries to spread
across all 4, rather than rebalancing prematurely around today's count.

**Shop items are a separate system from passive schopnosti** (`GameManager.SHOP_ITEMS`/
`SHOP_ITEM_ORDER`, `Control/ShopPanel` in `hud.tscn`). Where a passive schopnost is free, randomly
offered, and single-stat, a shop item is: bought with gold from a rotating offer that already
carries a rolled **rarity** (see below), and grants **multiple stats at once** (e.g. "Přebíječ
jader" = +6 damage AND +0.2 attack speed at Bronze) — both now use the same rarity/merge growth
mechanic (see "Schopnosti" above and "Rarity + merge system" below), just with different
thresholds/curves and single- vs multi-stat payloads. This was a deliberate design pivot
mid-brainstorm, modeled after League of Legends' item system (discrete multi-stat items) then
further reshaped after The Bazaar (Steam card/auto-battler) for the rarity/merge/stash mechanics
below — schopnosti and shop are meant to feel like different systems, not two currencies buying the
same thing. `get_stat_bonus(stat_id)` sums both owned *passive* schopnosti and **active** shop
items' `stats` (× rarity multiplier) contribution for a given stat — a player can own both "Jádro
síly" (passive schopnost) *and* "Přebíječ jader" (shop, which also grants damage) at the same time;
their damage bonuses just add together, no conflict. **Only active shop items count — stashed ones
don't** (see below); schopnosti have no such split, every owned instance always counts.

**Rarity + merge system** (`GameManager.ShopRarity` enum, `SHOP_RARITY_NAMES`/
`SHOP_RARITY_WEIGHTS`/`SHOP_RARITY_MULTIPLIERS`/`SHOP_RARITY_COST_RATIOS`): built 2026-09-08,
replacing an earlier same-day "pay gold to upgrade an owned item" version after the user clarified
they wanted The Bazaar's actual mechanic instead. Four tiers — BRONZE → SILVER → GOLD → DIAMOND —
each multiplying an item's base (`stats` dict, always written as Bronze-tier values) by
`SHOP_RARITY_MULTIPLIERS` (1.0×/1.6×/2.6×/4.2×, ~1.6× compounding per tier). **The shop offer rolls
a random rarity per slot** (`_roll_rarity(SHOP_RARITY_WEIGHTS)`, weights 70%/20%/8%/2% —
low rarities common, Diamond rare; `_roll_rarity()` is shared with the draft's own rarity roll, see
"Draft rarity + merge" above) — buying an offered item costs
`SHOP_ITEMS[item_id]["cost"] * SHOP_RARITY_COST_RATIOS[tier]` (ratios 1.0/1.4/2.25/3.75) for
*whatever* rarity got rolled, not always Bronze. **Owning 3 copies of the same item at the same
rarity auto-merges them into 1 copy one rarity higher** (`_try_merge_shop_item()`, called after
every purchase) — this is the *only* way an item gets stronger; there is no paid upgrade path
anymore. The offer intentionally never filters out items the player already owns, since seeing a
duplicate is the entire point. **Buying a slot removes it from `shop_offer`** (`buy_shop_item()`
calls `shop_offer.remove_at(offer_index)`) — the player buys anywhere from 0 to `SHOP_OFFER_SIZE`
(4) items out of one offer, not the same slot repeatedly; wanting a different selection means
paying for a reroll (see below), not re-clicking a card. `get_shop_item_desc(item_id, tier)` formats the *actual* scaled
numbers for a given tier (no static `desc` string in `SHOP_ITEMS` — it would go stale the instant
an item merges up) via `STAT_DISPLAY_NAMES`. **Special "build-enabler" unique effects unlocking at
Gold are still just a design note, not built** — see `project_future_active_abilities` memory.

**Active items vs. stash** (`active_shop_items`/`stash_shop_items: Array[Dictionary]`,
`SHOP_ACTIVE_SLOTS` 6 / `SHOP_STASH_SLOTS` 9): each owned copy is one instance
`{"item_id", "rarity", "cost_paid"}` living in exactly one of these two arrays — there's no
"owned_shop_items" dictionary anymore, ownership *is* being present in one of these lists.
**Only `active_shop_items` feeds `get_stat_bonus()`** — stash is inert storage, purely there so a
player can hold spare/duplicate copies (hunting a 3rd for a merge, or benching something they might
want later) without being forced to make a keep-or-sell decision the instant a purchase doesn't fit
their 6 active slots. `buy_shop_item()` places a new copy into the first active slot with room, and
only overflows to stash once active is full — purchases are never blocked by a full active loadout,
only by *both* collections being completely full. Moving between the two
(`move_shop_item_to_stash(index)` / `move_shop_item_to_active(index)`) and selling
(`sell_shop_item(collection_name, index)`, `"active"` or `"stash"`) all address items by **array
index within that specific collection** — there's no global item-instance ID, so an index is only
meaningful alongside which collection it's in.

**Selling refunds `SHOP_SELL_REFUND_RATIO` (50%) of that specific instance's `cost_paid`** — for a
merged item, `cost_paid` is the *sum* of all 3 consumed copies' `cost_paid` (set once at merge time
in `_try_merge_shop_item()`), so selling a merged Silver item still refunds half of everything spent
building it, not just a fraction of one imaginary "upgrade fee." This preserves the "refund total
investment, not last transaction" principle from the (now-removed) gold-upgrade version, just
computed differently since there's no per-item running total to maintain — it falls out naturally
from summing at merge time.

**There used to be two other approaches to "making a shop item stronger" here, both removed the
same day (2026-09-08) this system was built**: a tier-2 "combine 2 different items into 1" system,
and (later that same day) a "pay gold to upgrade one owned item through 4 tiers" system. Both were
replaced once the user clarified the actual intended mechanic (Bazaar-style: rarity is rolled in
the offer, and 3 matching duplicates auto-merge). If you see references to `combine_shop_item()`,
`SHOP_COMBINE_ORDER`, `recipe`, `owned_shop_items`, `shop_item_investment`, `upgrade_shop_item()`,
or `MAX_SHOP_SLOTS` (renamed `SHOP_ACTIVE_SLOTS`) anywhere, they're all stale.

**The 6 active + 9 stash mini-slots in the shop panel are built procedurally in `hud.gd`, not
hand-authored in `hud.tscn`** (`_build_shop_stash_ui()`/`_create_shop_mini_slot()`) — 15 nearly
identical small widgets (a `Label` + 1-2 `Button`s each) were judged not worth writing by hand in
the scene file; `hud.tscn` only has two empty `Control` containers
(`ActiveItemsContainer`/`StashContainer`) that the code populates once in `_ready()` and then
refreshes in place. Each widget is tracked as a plain `Dictionary` (`{"panel", "label", "buttons"}`)
in `_active_slot_widgets`/`_stash_slot_widgets` rather than typed nodes, since they were never
declared in the scene tree to have `@onready`-style paths in the first place.

**`Control/BottomBar/ItemSlot1..6` display *active* shop items only (name + rarity), positionally**
(`hud.gd`'s `_refresh_shop_slots()`) — stashed items never show here, matching "only active items
matter for gameplay"; this is read-only, unlike the interactive mini-slots inside the open shop
panel. Empty slots trail at the end regardless of which specific slot index was vacated, same
reasoning as before.

**Debug panel** (`hud.gd`, `scenes/ui/eye_icon.gd`): a dev-only panel toggled by the `DebugButton`
— TEMPORARILY in the bottom-right corner as of 2026-09-09, see "HUD layout" above — which shows
"Debug" plus a procedurally-drawn eye icon (open/closed,
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
- **Spawnout Elite** / **Spawnout dálkového** / **Spawnout snipera** all share `_spawn_at_edge()`
  with the normal wave spawner (extracted from `_spawn_enemy()` during the Elite work) so a
  debug-spawned enemy gets the same HP-multiplier-before-`add_child()` treatment as one spawned by
  the real wave queue.
- **Rychlost** cycles `Engine.time_scale` through `1x/2x/5x/10x` — this is global engine state, so
  it also speeds up Timers, Tweens, and the Game Over/Victory countdown, and (unlike everything
  else on this panel) is **not** reset by a scene reload; the button re-syncs its own label from
  the actual `Engine.time_scale` in `_setup_debug_panel()` so it doesn't lie after a restart.
- **+1 bod schopnosti** (node `AddSkillPointButton`, renamed 2026-09-26 from the old draft system's
  `ForceAbilityDraftButton`/`debug_force_ability_draft()`) calls `GameManager.debug_add_skill_point()`
  to grant a point immediately without a level-up — the fastest way to test the tree UI/flow without
  grinding XP.
- **Max strom / Reset strom** (node names `MaxSkillTreeButton`/`ResetSkillTreeButton`, renamed
  2026-09-26 from `MaxItemsButton`/`ResetItemsButton`) are a blunt build-testing tool —
  `debug_max_skill_tree()` sets every `ABILITIES` entry straight to its `max_rank`,
  `debug_reset_skill_tree()` clears `skill_ranks` AND `pending_skill_points` back to nothing. Reset
  does **not** refund points to re-spend elsewhere, because schopnosti were never bought with a
  spendable currency in the first place — it's just a clean slate for the next level-up to build up
  points again.
- **+5 bodů schopnosti** (node `AddManySkillPointsButton`, repurposed 2026-09-26 from the old
  random-autopick "Auto vylepšení" toggle, which no longer makes sense once every pick is
  deliberate) — grants 5 points at once via 5 calls to `debug_add_skill_point()`, for quickly
  reaching deeper/capstone nodes during manual tree testing without grinding levels one at a time.
- **Free reroll** sets `GameManager.debug_free_reroll`, making shop rerolls free (see "Reroll
  costs..." above) — for testing the shop offer/reroll flow without grinding gold. Same
  not-reset-by-`reset_game()` treatment as **Rychlost**, for the same reason (dev convenience
  across restarts, not run state).

**Planned but not yet done**: a live "fun"/pacing telemetry readout (concurrent enemy count,
"close calls") is planned for this panel — see the bullet-hell pacing design goal above. The panel
is also flagged to eventually get **narrower** (~30-50%, exact amount flexible) since its current
two-column button grid is fairly wide — explicitly low priority, only worth doing if it's cheap;
don't proactively redesign the layout for this alone.

**Suroviny a crafting (first slice, 2026-09-26)** — the start of a planned deeper progression
system (blueprints bought in the shop, crafted from raw materials, deliberately priced far below
the equivalent ready-made shop item to make crafting the obviously "correct" choice rather than a
side activity) meant to give the player something to actively pursue mid-run, on top of the
passive schopnost/shop loop. **This first PR is deliberately just the material itself — one type,
called "šrot" (scrap) — with no blueprints/recipes/crafting UI yet**, following the same
"prove the smallest slice first" approach `LEVEL_STAT_GROWTH`/the ranged-enemy ramp/armor were each
introduced with (see their entries above): `enemy.gd`'s new `@export var scrap_reward: int = 1`
(flat for every enemy type today, same as `reward`/`xp_reward` not currently varying by variant -
see "Elite enemy" above, which doesn't override them either) flows through `enemy.gd`'s `_die()` →
`GameManager.enemy_defeated(reward, xp_reward, scrap_reward)` (new third parameter, default `0` so
any future caller that forgets it fails safe rather than erroring) → `GameManager.scrap`
(run-scoped, reset in `reset_game()`, mirrors `currency` exactly) → `scrap_changed` signal → HUD's
new `ScrapLabel` (`Control/ScrapLabel`, positioned directly right of `GoldLabel` at the same
`offset_top`, same row under `XPBar`, so it reads as a second currency alongside gold rather than a
separate concept). **Verified with a headless test** (`enemy_defeated(10, 12, N)` accumulates and
`reset_game()` clears it) and a live windowed run (killed a real enemy at 10x `Engine.time_scale`,
confirmed "Šrot: 1" appeared in the HUD in sync with "Zlato: 10"). **Deliberately not yet built**:
which shop items get a blueprint, the blueprint's gold cost vs. the material quantity a craft
consumes, whether multiple material types eventually exist per enemy variant (discussed but
explicitly deferred to keep this first step small), and the crafting UI/interaction itself (most
likely folded into the existing periodic Shop, which already pauses and is already the "spend
resource on power" moment, rather than a new separate panel — see the brainstorm this came from).

**CORRECTION (2026-09-26, same day as the tree): "Dovednosti (strom)" above does NOT replace
schopnosti — it runs ALONGSIDE the original random-draft schopnosti system, which was fully
restored after user feedback ("chtěl jsem schopnosti zachovat, ne nahradit").** Everywhere above
that says the draft/rarity/merge system, `owned_abilities`, `AbilityDraftPanel`,
`rarity_icon.gd`/`upgrade_icon.gd`, etc. were "removed" — they were NOT; they were undone within
the same day and are live again, unchanged in mechanics, with one change: **schopnosti's offer now
triggers after the intro landing (as ORIGINAL, unwaved) AND after EVERY wave clear
(`_on_wave_cleared()`), not after every level-up.** `_level_up()` only grants dovednosti points now.

**Both systems read/write the SAME `ABILITIES` catalog and their contributions to
`get_stat_bonus()` ADD TOGETHER** — a player can have "Jádro síly" at dovednostní stupeň 2/3
(`skill_ranks`) AND independently own a Silver copy of it from the random draft
(`owned_abilities`) at the same time; both sums are added in `get_stat_bonus()`. To let active
schopnosti scale independently in each system despite sharing one `ABILITIES[id]` entry, each
active entry now carries TWO trigger arrays: `"trigger_values"` (4 entries, `ShopRarity`-indexed,
schopnosti/draft) and `"skill_trigger_values"` (`max_rank`-sized, rank-indexed, dovednosti/tree).
Likewise there are two parallel description/value functions: `get_ability_desc()`/
`get_ability_value_text()` (rarity-based, schopnosti) vs. `get_skill_node_desc()`/
`get_skill_node_value_text()` (rank-based, dovednosti) — passing a rank into the rarity-indexed
ones (or vice versa) is a real bug, not just a stale name, since the two index domains differ in
size (0-3 vs 1-5).

**STALE, reverted 2026-09-26 (same day): intro is back to ONE step, not two.** It briefly became a
two-step chain (schopnosti draft → dovednosti's `begin_intro_skill_tree()`) right after schopnosti
was restored alongside dovednosti, but the user then asked for the skill tree's intro-forced point
to go away entirely (first point should arrive at level 2, panel should never auto-open at game
start). `player.gd`'s `_on_landed()` still calls `begin_intro_ability_draft()` (schopnosti, the only
intro step now), and `resolve_ability_draft()`'s tail calls `finish_intro()` **directly** once that
offer resolves — `begin_intro_skill_tree()` no longer exists at all.

**Wave-10 shop-vs-draft collision is back too, same shape as the original 2026-09-09 fix, just a
guaranteed collision now instead of an occasional one**: `_on_wave_cleared()` ALWAYS generates an
ability-draft offer synchronously before checking `current_wave >= FINAL_WAVE`, so on every single
10th-wave clear a schopnosti offer and a shop auto-open both fire in the same call. `_open_periodic_
shop()` → `_try_open_pending_shop()` defers (`_shop_open_deferred`) if `pending_ability_drafts > 0`,
and `resolve_ability_draft()` retries it at its own tail — restored verbatim from before the
skill-tree rework, just with the trigger reason changed from "level-up happened to coincide" to
"every wave-10 clear, always". **Verified with a scene-level headless test**: forcing wave 10 to
clear shows the ability draft, confirms the shop stays hidden + `_shop_open_deferred == true` while
it's pending, then confirms the shop auto-opens the instant the draft resolves.

**STALE (2026-09-26, later the same day): `_refresh_abilities()` no longer shows dovednosti at
all.** It briefly showed both sources (dovednosti entries first, then schopnosti) right after
schopnosti was restored — but the user then clarified dovednosti should work as an invisible
passive stat bonus in the background (so a future run that starts with pre-invested skill points,
e.g. a meta-progression "start at level 10" mode, just has higher base stats with no card to show
for it), and this stack under the portrait should only ever show the schopnosti the player actively
picked from the random draft. `_refresh_abilities()` now has ONE loop again, over
`GameManager.owned_abilities` only (via `_create_ability_stack_slot(index, label_text,
tooltip_text)`) — `skill_ranks` never touches this list. `hud.gd`'s `_on_skill_ranks_changed()` no
longer calls `_refresh_abilities()` either (it only refreshes `SkillTreePanel` if it happens to be
open) — investing a dovednost point never changes what this stack shows. **Mechanically nothing
changed**: `skill_ranks`' contribution to `get_stat_bonus()` was always independent of what's
displayed here, so removing the cards doesn't touch stat math, only visibility. **Verified with a
scene-level headless test**: invested a dovednost rank into `power_core` with zero owned schopnosti
→ `AbilitiesContainer` has 0 children; then added an owned schopnost copy of the same
`power_core` → exactly 1 child appears (the schopnost, not the dovednost); `get_stat_bonus("damage")`
reflects both contributions regardless.

**Debug panel now has separate controls for each system** — dovednosti keeps `AddSkillPointButton`/
`MaxSkillTreeButton`/`ResetSkillTreeButton`/`AddManySkillPointsButton` (added during the tree work);
schopnosti's original `ForceAbilityDraftButton`/`MaxAbilitiesButton`/`ResetAbilitiesButton`/
`AbilityAutoToggle` were re-added as NEW rows (DebugPanel grew from 618px to 706px tall to fit them)
rather than reusing the tree's renamed buttons, since both systems now need independent testing
affordances.

**Verified with headless tests at every layer** (pure-logic + two scene-level suites): unlock/lock
behavior and additive stacking math for a shared ability_id across both systems; the full two-step
intro sequence (schopnosti panel → resolves → chains into dovednosti panel → closes → `PLAYING`);
wave-clear correctly re-triggers the schopnosti offer; the wave-10 shop/draft collision defers and
resolves in the right order. Not yet re-verified live/visually in a windowed run at time of writing
— do that before treating this as fully settled, particularly the two-panel intro sequencing and
DebugPanel's new height fitting inside the window.

## Key tunables when adjusting gameplay

- `scenes/player/player.gd` — `move_speed`, `attack_range`, `base_hp_regen`, `base_armor`, `base_crit_chance`, `CRIT_DAMAGE_MULTIPLIER` (fixed 2x, see "Critical hits" above), `MIN_DAMAGE_RATIO` (armor damage floor), base stats, fall/intro animation params; `_consume_ability_triggers()`/`_process_time_based_abilities()` are where active-schopnost trigger/effect resolution happens (currently hardcoded for `shot_count`/`damage_multiplier` and `time_elapsed`/`aoe_strike`, see "Schopnosti" above)
- `scenes/camera_follow.gd` — `camera_left_margin`, `follow_speed` (camera lag/responsiveness)
- `scenes/main.gd` — enemies per wave, spawn interval/margin, `max_concurrent_enemies`, `elite_count_final_wave`, `ranged_enemy_chance`, `sniper_enemy_chance`, `variant_ramp_start_wave`/`variant_ramp_full_wave` (loop-1-only ramp for when ranged/sniper start appearing)
- `scenes/enemies/enemy.gd` — enemy speed/HP/damage, `melee_range`, `hit_radius`, `reward`, `xp_reward`, `scrap_reward` (see "Suroviny a crafting" above), `is_ranged`/`projectile_scene`
- `scenes/enemies/elite_enemy.tscn` — Elite's stat overrides (speed/max_hp/melee_range/hit_radius) and visual scale, node properties only (script is shared with `enemy.gd`)
- `scenes/enemies/ranged_enemy.tscn` / `sniper_enemy.tscn` — each variant's `melee_range` (engagement distance) and color, also just node properties on the shared `enemy.gd`; sniper's `melee_range` (550) is the one that matters most — it must stay above the player's base `attack_range` (400) for the "protected artillery" behavior described above to hold
- `scenes/enemies/enemy_projectile.gd` — enemy projectile `speed`, `hit_radius`, `cleanup_margin`
- `scenes/levels/level_01.tscn` — has no `LevelEnd` marker (level is boundless); add a `Marker2D` in the `level_end` group here (or in a new level scene) to reintroduce a movement cap
- `scenes/levels/ground.gd` — `tile_size`, tile colors, `tile_margin_count` (redraw buffer beyond the visible camera window)
- `scripts/autoload/game_manager.gd` — XP curve (`XP_BASE`, `XP_PER_LEVEL_GROWTH`), schopnost definitions (`ABILITIES` — passive entries' `"value"` = PER-RANK stat amount, `"max_rank"` per node, active entries' `"trigger_values"` sized to `"max_rank"`), `ABILITY_ORDER`, `SKILL_TREE_BRANCHES` (the 4 branches, root-to-capstone order — see "Schopnosti" above), `FINAL_WAVE` (which wave triggers a new loop), `ENEMY_HP_GROWTH_PER_LOOP` (difficulty ramp between loops), shop item definitions (`SHOP_ITEMS`, multi-stat), `SHOP_ACTIVE_SLOTS`/`SHOP_STASH_SLOTS`, `SHOP_SELL_REFUND_RATIO`, `SHOP_OFFER_SIZE`, `SHOP_REROLL_BASE_COST`/`SHOP_REROLL_COST_STEP`, `SHOP_RARITY_WEIGHTS` (offer rarity odds), `SHOP_RARITY_MULTIPLIERS`/`SHOP_RARITY_COST_RATIOS` (shop's rarity tier power/cost curves; 3-copy merge threshold is hardcoded in `_try_merge_shop_item()` — schopnosti no longer use `ShopRarity` at all, see "Schopnosti" above), `LEVEL_STAT_GROWTH` (automatic per-level stat floor, small relative to schopnosti/shop), `TAG_DISPLAY_NAMES`/each entry's `"tags"` (tag synergy display categories, see "Tag synergie" above), `ABILITIES["overclock_matrix"]`/`SHOP_ITEMS["resonance_array"]`'s `"synergy"` dicts (per-owned-tagged-thing scaling — `_count_owned_with_tag()` does the counting), `ABILITIES["precision_targeting"]`/`SHOP_ITEMS["precision_scope"]` (flat `crit_chance` sources, see "Critical hits" above)
- `scenes/ui/hud.gd` — `END_SCREEN_RESTART_DELAY`, `DEBUG_SPEED_STEPS` (Debug panel's speed cycle), `ABILITY_STACK_MAX_ROWS` (schopnost stack column-wrap threshold, see "Schopnost slots live OUTSIDE BottomBar" above), `SKILL_NODE_WIDTH`/`HEIGHT`/`GAP` (SkillTreePanel node grid sizing, see "Schopnosti" above)
