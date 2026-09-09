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

**Progression (XP → levels → item draft)**: enemies grant `reward` (gold) *and* `xp_reward` on
death via `GameManager.enemy_defeated(reward, xp_reward)`. XP accumulates toward
`xp_for_next_level()` (`XP_BASE + (level - 1) * XP_PER_LEVEL_GROWTH`); `add_xp()` loops so one big
XP chunk can grant several levels at once. **`XP_BASE` is tuned to 40, not the curve's original 60**,
specifically so the first level-up (and first draft choice) lands before the end of wave 1 rather
than partway through wave 2 — with the base enemy's `xp_reward` of 12 and `main.gd`'s wave-1 count
of 4, that's exactly 48 XP from clearing wave 1 alone. This was a deliberate pacing choice (verified
with a throwaway headless simulation of waves 1-3, not just eyeballed): a new run should show the
player *something* — a draft card — almost immediately, rather than several minutes of pure combat
before the first meaningful choice appears. Each level queues one "item draft" (see below) *and*
grants a small automatic stat bump via `GameManager.LEVEL_STAT_GROWTH` (a flat per-stat amount ×
`player_level - 1`, added in `get_stat_bonus()`) — there is still no per-stat purchasing or ability
tree, so the draft remains the only *choice*-driven growth, but a bare level-up is no longer a
complete no-op for stats.

**`LEVEL_STAT_GROWTH` was re-added 2026-09-09 after being deliberately removed earlier** (see git
history) — the original removal was about making every stat point trace back to a visible, chosen
item so nothing was an invisible sum; the re-addition solves a different problem, flagged as the
"Balance caveat" below: a run's power depended *entirely* on draft luck, so a string of bad draft
offers could leave a level-15 character barely stronger than a level-1 one. `LEVEL_STAT_GROWTH`'s
values are deliberately small relative to items (e.g. one Silver-rarity "Přebíječ jader" grants +9.6
damage; a level of automatic growth grants +0.5) — it's a floor under a run's power, not a
replacement for the draft/shop as the main source of it, so player choices still define *most* of a
build's identity.

**Stats flow**: base stats live as `@export` vars on `player.gd` (`base_damage`,
`base_attack_speed`, `base_attack_range`, `base_max_hp`, `base_armor`). Effective stats come from
getters (`get_damage()`, `get_attack_speed()`, `get_attack_range()`, `get_target_count()`,
`get_hp_regen()`, `get_armor()`) that add `GameManager.get_stat_bonus(stat_id)` — **the single place
where progression turns into numbers**, summing three sources: `LEVEL_STAT_GROWTH` (automatic, keyed
by `player_level`), the draft's `draft_items`, and the shop's `active_shop_items`. The player
recomputes on the `level_changed` and `draft_inventory_changed` signals — `level_changed` now
actually changes stats again (via the level-growth term), not just a UI sync no-op. **Balance caveat
(partially addressed)**: a run's power still depends heavily on what the (currently small, 7-item)
draft pool happens to offer — going several levels without seeing a given stat's item is possible
(~57% chance per level to miss any one specific item with `DRAFT_CHOICE_COUNT` 3 of 7) — but
`LEVEL_STAT_GROWTH` now guarantees a non-zero floor regardless of draft luck, so a bad-luck run is
weaker, not stat-flat. Not claimed to fully solve fragility, just to soften the worst case.

**Armor (`base_armor`, `get_armor()`, `kinetic_dampers` item)**: a flat, per-hit damage reduction —
`take_damage()` in `player.gd` computes `reduced_amount = max(amount - get_armor(), amount *
MIN_DAMAGE_RATIO)` (`MIN_DAMAGE_RATIO` 0.1, so at least 10% of any hit always gets through, even
against a fully-stacked armor build — this stops armor from ever granting outright immunity to a
future, harder-hitting enemy type). This is a standard genre tool for a specific failure mode:
"death by many small simultaneous hits" (several enemies each landing modest contact damage) rather
than "death by one big hit" — unlike a percentage-based mitigation stat, a *flat* reduction hits
weak/frequent damage sources hardest, which is exactly the profile of this game's enemies (see
"data-backed fix" below). `base_armor` defaults to 2.0 (all current enemies deal exactly 5 contact
damage, so base armor alone cuts that to 3 — a 40% reduction before any item at all);
`kinetic_dampers` grants +2 armor at Bronze rarity (matching `base_armor`'s scale), scaling up with
rarity/merges like any other draft item (see "Draft rarity + merge" above).

**This was a data-backed fix, not a guess** — same headless simulation approach as the ranged/sniper
ramp above (real `main.tscn`, "Auto" draft picking, sped up via `Engine.time_scale`). Before armor,
even with the ranged/sniper ramp already in place, 0/10 runs survived both of the first two loops (20
waves) and the average death wave was ~4.1; after adding armor, in a follow-up batch of 10 runs, 7
died between wave 5 of loop 1 and wave 10 of **loop 2** (one run died on the very last wave of loop 1
after clearing it entirely; another died on the very last wave of loop 2, i.e. 19 of 20 waves
cleared), and the other 3 were still going when the simulation's time budget ran out. No config
change here is claimed to make the game *strictly* survivable end-to-end — it moved the typical
death point from "wave 2-4 of loop 1" to "deep into loop 1 or partway through loop 2," which is the
kind of improvement that's meant to be judged by playtesting feel, not chased to a specific number.

**Item/loot draft replaced the old ability tree** (`GameManager.ITEMS`/`ITEM_ORDER`, `hud.gd`,
`Control/DraftPanel` in `hud.tscn`): instead of a fixed Q/W/E/R grid the player spent points into,
each level-up now queues an offer of `DRAFT_CHOICE_COUNT` (3) *random* items — same "pick one of
three" pattern as Vampire Survivors' level-up cards. This was a deliberate replacement, not an
addition: the previous ability system gave a flat, always-the-same choice every run (see the
brainstorm this came from), while randomized offers make each run's build meaningfully different.

**Draft rarity + merge (2026-09-09)**: draft items now use the SAME rarity/merge principle as the
shop (see "Rarity + merge system" below) — each offered item also rolls a rarity
(`DRAFT_RARITY_WEIGHTS`), and owning `DRAFT_MERGE_THRESHOLD` (**2**, not the shop's 3) identical
copies at the same rarity auto-merges them into 1 copy one tier higher
(`_try_merge_draft_item()`). The lower threshold is deliberate: draft offers are free and random
with no reroll, so the player has far less control than in the shop over which duplicate they get
next — requiring fewer copies compensates for that lost control. `DRAFT_RARITY_MULTIPLIERS` is its
own (gentler) curve, not shared with `SHOP_RARITY_MULTIPLIERS` — a 2-copy threshold grows power
faster than a 3-copy one for the same multiplier curve, so draft's curve was tuned down to
compensate; both enum and rarity *names* (`ShopRarity`, `SHOP_RARITY_NAMES`) ARE shared, since both
systems display the same 4 tiers (Bronz/Stříbro/Zlato/Diamant), just with different weights/
multipliers/thresholds. **Draft deliberately stays single-stat** (`ITEMS[item_id]["value"]` is a
single Bronze-tier stat value, unlike the shop's multi-stat `"stats"` dict) — that's still what
differentiates draft as its own system, not just a second path to the same numbers as the shop.
Like the shop, an item's rarity/desc text is generated dynamically (`get_draft_item_desc()`) rather
than stored statically, so it always matches what the specific rolled tier actually gives.

**`draft_items: Array[Dictionary]`** (each `{"item_id": String, "rarity": int}`) replaced the old
flat `item_ranks: Dictionary` (item_id → single rank int) — since a merge can leave a player owning
several *different* rarities of the same item_id simultaneously (e.g. 1 already-merged Silver copy
+ 1 fresh Bronze copy picked afterward, before a 2nd Bronze triggers another merge), a single
"rank" number can no longer represent an item's state; `get_stat_bonus()` now sums every owned
instance's Bronze `"value"` × `DRAFT_RARITY_MULTIPLIERS[rarity]`, same pattern as the shop's
`active_shop_items` loop. Unlike the shop, there's no active/stash split for draft — every owned
instance always counts, since draft offers are always just `DRAFT_CHOICE_COUNT` free items with no
purchase-slot pressure to manage.

**Draft flow / one offer at a time**: `_level_up()` increments `GameManager.pending_drafts` and
calls `_try_offer_next_draft()`, which only actually rolls and emits `item_draft_ready` if
`_current_offer` is empty — **this guard is load-bearing**, not decorative: a single big XP grant
(e.g. the Debug panel's "+500 XP") can call `_level_up()` several times synchronously inside
`add_xp()`'s loop, and without the guard each of those calls would roll and emit its own offer,
stomping `_current_offer` and desyncing `pending_drafts` from what's actually on screen. Offers are
resolved one at a time via `resolve_draft(offer_index: int)` (indexed, like the shop's
`buy_shop_item(offer_index)` — not by item_id, since the offer now also carries a rolled rarity
that an item_id alone wouldn't identify), which clears `_current_offer` and calls
`_try_offer_next_draft()` again — so a big XP grant queues N drafts that the HUD walks through
sequentially, not simultaneously.

**Draft pauses the game, unlike the old ability buttons did** (`_show_draft_panel()` /
`_on_draft_pick_pressed()` in `hud.gd`, mirroring the Shop's `get_tree().paused` pattern) — a
level-up card is meant to be a deliberate stop-and-choose moment. The "Auto vylepšení" toggle
(`Control/DebugPanel/AutoUpgradeToggle`, **default OFF**) resolves offers with a uniformly random
pick and skips the panel/pause entirely. Toggling it **on** while a draft is already showing must
proactively resolve it (`_on_draft_auto_toggled()`) — otherwise the panel would stay stuck open
forever, since nothing else would ever call `resolve_draft()` for it.

**Auto-resolve lives in the Debug panel, not the main HUD** — it started out as a regular
`Control/BottomBar` button (like the old ability system's Auto-assign), but was moved into
`DebugPanel` and renamed from "Auto" to "Auto vylepšení": the entire point of switching to
randomized item drafts was to give the player a real, visible choice each level, so a literal
random-pick button sitting permanently next to real player-facing controls (Shop, item slots)
undercut that and only ever made sense as a playtesting/debug convenience anyway — CLAUDE.md already
described it that way before the move. It defaults OFF for the same reason (deliberate flip from the
old ability system's default-ON Auto). The random-pick logic itself is still a deliberately simple
placeholder (no weighting by current build) — same caveat the old ability Auto-assign had.
**Noted for later**: once the game loops indefinitely past wave 10 (see below), an experienced
player who already has a settled build might legitimately want to "farm" further loops without
stopping for every draft card — if that turns out to be a real desired playstyle during a future
QoL/balance pass, auto-resolve could earn a real, non-debug home again (e.g. only unlocked after
finishing loop 1, or with build-aware weighting instead of a uniform random pick). Not worth building
now — just don't be surprised if this resurfaces as a real feature request later.

**HUD is one bottom bar** (`Control/BottomBar` in `hud.tscn`) styled after MOBA HUDs: stat readouts,
portrait with a level badge, HP bar, XP bar, seven picked-item slots (`PickedItemSlot0..6`, indexed
to match `GameManager.ITEM_ORDER` — grayed out while `draft_items` has no instance of that item_id,
otherwise shows `short_name` + copy count + the *highest* owned rarity, e.g. "Jádro / 2x Stříbro",
since one item_id can have multiple simultaneously-owned instances at different rarities — see
"Draft rarity + merge" above), six (currently decorative, unrelated — future equipment loot)
`ItemSlot1..6` rects, gold, and the shop button. Right-side elements are anchored to the right edge
and the bars stretch, so the bar survives window resizing.

**Shop pauses the game via `get_tree().paused`**, which is why the HUD `CanvasLayer` has
`process_mode = 3` (ALWAYS) in `hud.tscn` — without it the shop's own close button would freeze
along with the game. The pause is deliberate *for now*; the user has flagged that they may later
want the game to keep running while the shop is open, so the pause lives only in
`_on_shop_button_pressed()` / `_on_shop_close_pressed()` / `_close_shop()` /
`_on_shop_auto_open_requested()` in `hud.gd` and nothing else depends on it.

**Shop opens periodically, not any time** (`GameManager.shop_available`,
`shop_auto_open_requested` signal, `_open_periodic_shop()`/`_start_new_loop()`): the shop unlocks
and shows a fresh offer automatically — panel pops open and pauses, no click needed — the moment
wave 10 is cleared and a new loop starts, reusing the existing loop-boundary code path rather than
adding new event plumbing. This resolved a long-standing open design question (shop available any
time vs. gated to a specific moment) via a Bazaar-inspired redesign brainstorm. `shop_available`
turns true the first time this fires in a run and **stays true for the rest of that run** — the
`ShopButton` in `Control/BottomBar` re-enables and its label drops the "(po 10. vlně)" suffix once
unlocked, and stays clickable afterward purely to **re-open the current offer** (e.g. if the player
closed it by accident) — clicking it never generates a new offer or costs anything; only the next
wave-10 clear or a paid reroll does that. Before the first unlock, `_on_shop_button_pressed()`
silently no-ops if clicked (shouldn't be reachable anyway since the button is disabled).
`shop_available`/`shop_offer`/`shop_reroll_count` are run-scoped and reset in `reset_game()` like
everything else — a new run has to clear wave 10 again, same as it has to re-collect levels/items.

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

**Shop items are a separate system from the item draft** (`GameManager.SHOP_ITEMS`/
`SHOP_ITEM_ORDER`, `Control/ShopPanel` in `hud.tscn`). Where a draft item is free, randomly offered,
and single-stat, a shop item is: bought with gold from a rotating offer that already carries a
rolled **rarity** (see below), and grants **multiple stats at once** (e.g. "Přebíječ jader" = +6
damage AND +0.2 attack speed at Bronze) — both now use the same rarity/merge growth mechanic (see
"Draft rarity + merge" above and "Rarity + merge system" below), just with different thresholds/
curves and single- vs multi-stat payloads. This was a deliberate design pivot mid-brainstorm,
modeled after League of Legends' item system (discrete multi-stat items) then further reshaped
after The Bazaar (Steam card/auto-battler) for the rarity/merge/stash mechanics below — the draft
and shop are meant to feel like different systems, not two currencies buying the same thing.
`get_stat_bonus(stat_id)` sums both the draft's `draft_items` contribution and **active** shop
items' `stats` (× rarity multiplier) contribution for a given stat — a player can own both "Jádro
síly" (draft) *and* "Přebíječ jader" (shop, which also grants damage) at the same time; their
damage bonuses just add together, no conflict. **Only active shop items count — stashed ones
don't** (see below); draft items have no such split, every owned instance always counts.

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
- **Spawnout Elite** / **Spawnout dálkového** / **Spawnout snipera** all share `_spawn_at_edge()`
  with the normal wave spawner (extracted from `_spawn_enemy()` during the Elite work) so a
  debug-spawned enemy gets the same HP-multiplier-before-`add_child()` treatment as one spawned by
  the real wave queue.
- **Rychlost** cycles `Engine.time_scale` through `1x/2x/5x/10x` — this is global engine state, so
  it also speeds up Timers, Tweens, and the Game Over/Victory countdown, and (unlike everything
  else on this panel) is **not** reset by a scene reload; the button re-syncs its own label from
  the actual `Engine.time_scale` in `_setup_debug_panel()` so it doesn't lie after a restart.
- **Vynutit draft** calls `GameManager.debug_force_draft()` to queue an offer immediately, bypassing
  the level-up requirement — the fastest way to test the draft UI/flow without grinding XP.
- **Max/Reset itemy** are a blunt build-testing tool — max gives every item exactly 1 Diamond-rarity
  instance, reset clears `draft_items` entirely. Unlike the old ability respec, reset does **not**
  refund anything to re-spend, because items were never bought with a spendable currency in the
  first place — they're free picks from a draft, so "reset" is just a clean slate for the next
  level-up.
- **Auto vylepšení** is the moved/renamed old BottomBar "Auto" toggle (see above) — it's here rather
  than in the main HUD specifically because its only real use is skipping the draft-choice pause
  during testing.
- **Free reroll** sets `GameManager.debug_free_reroll`, making shop rerolls free (see "Reroll
  costs..." above) — for testing the shop offer/reroll flow without grinding gold. Same
  not-reset-by-`reset_game()` treatment as **Rychlost**, for the same reason (dev convenience
  across restarts, not run state).

**Planned but not yet done**: a live "fun"/pacing telemetry readout (concurrent enemy count,
"close calls") is planned for this panel — see the bullet-hell pacing design goal above. The panel
is also flagged to eventually get **narrower** (~30-50%, exact amount flexible) since its current
two-column button grid is fairly wide — explicitly low priority, only worth doing if it's cheap;
don't proactively redesign the layout for this alone.

## Key tunables when adjusting gameplay

- `scenes/player/player.gd` — `move_speed`, `attack_range`, `base_hp_regen`, `base_armor`, `MIN_DAMAGE_RATIO` (armor damage floor), base stats, fall/intro animation params
- `scenes/camera_follow.gd` — `camera_left_margin`, `follow_speed` (camera lag/responsiveness)
- `scenes/main.gd` — enemies per wave, spawn interval/margin, `max_concurrent_enemies`, `elite_count_final_wave`, `ranged_enemy_chance`, `sniper_enemy_chance`, `variant_ramp_start_wave`/`variant_ramp_full_wave` (loop-1-only ramp for when ranged/sniper start appearing)
- `scenes/enemies/enemy.gd` — enemy speed/HP/damage, `melee_range`, `hit_radius`, `reward`, `xp_reward`, `is_ranged`/`projectile_scene`
- `scenes/enemies/elite_enemy.tscn` — Elite's stat overrides (speed/max_hp/melee_range/hit_radius) and visual scale, node properties only (script is shared with `enemy.gd`)
- `scenes/enemies/ranged_enemy.tscn` / `sniper_enemy.tscn` — each variant's `melee_range` (engagement distance) and color, also just node properties on the shared `enemy.gd`; sniper's `melee_range` (550) is the one that matters most — it must stay above the player's base `attack_range` (400) for the "protected artillery" behavior described above to hold
- `scenes/enemies/enemy_projectile.gd` — enemy projectile `speed`, `hit_radius`, `cleanup_margin`
- `scenes/levels/level_01.tscn` — has no `LevelEnd` marker (level is boundless); add a `Marker2D` in the `level_end` group here (or in a new level scene) to reintroduce a movement cap
- `scenes/levels/ground.gd` — `tile_size`, tile colors, `tile_margin_count` (redraw buffer beyond the visible camera window)
- `scripts/autoload/game_manager.gd` — XP curve (`XP_BASE`, `XP_PER_LEVEL_GROWTH`), draft item definitions (`ITEMS`, single-stat, `"value"` = Bronze-tier amount), `DRAFT_CHOICE_COUNT`, `DRAFT_MERGE_THRESHOLD` (2-copy draft merge), `DRAFT_RARITY_WEIGHTS`/`DRAFT_RARITY_MULTIPLIERS` (draft's own rarity curve, gentler than the shop's), `FINAL_WAVE` (which wave triggers a new loop), `ENEMY_HP_GROWTH_PER_LOOP` (difficulty ramp between loops), shop item definitions (`SHOP_ITEMS`, multi-stat), `SHOP_ACTIVE_SLOTS`/`SHOP_STASH_SLOTS`, `SHOP_SELL_REFUND_RATIO`, `SHOP_OFFER_SIZE`, `SHOP_REROLL_BASE_COST`/`SHOP_REROLL_COST_STEP`, `SHOP_RARITY_WEIGHTS` (offer rarity odds), `SHOP_RARITY_MULTIPLIERS`/`SHOP_RARITY_COST_RATIOS` (shop's rarity tier power/cost curves; 3-copy merge threshold is hardcoded in `_try_merge_shop_item()`), `LEVEL_STAT_GROWTH` (automatic per-level stat floor, small relative to items/shop)
- `scenes/ui/hud.gd` — `END_SCREEN_RESTART_DELAY`, `DEBUG_SPEED_STEPS` (Debug panel's speed cycle)
