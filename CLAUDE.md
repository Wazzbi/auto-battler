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

**`scenes/main.gd`** owns continuous enemy spawning only (target count/timing/position). It does
not own progression or rewards — those events come back from `GameManager` via signals
(`game_over_triggered`, `game_won_triggered`). **STALE (top-down pivot Fáze 6, 2026-09-27): there
is no more "wave" concept at all** — `wave_started`/`wave_cleared` signals and discrete waves/loops
were removed entirely in favor of a continuous, `GameManager.survival_time`-driven target enemy
count; see "Kontinuální spawn/obtížnost" further below for the full replacement. Enemy count uses a
square-root curve against elapsed time (`enemies_base_count + sqrt(survival_time /
seconds_per_wave_equivalent) * difficulty_growth`, same shape as the old wave-number version) so
difficulty ramps gradually, and `max_concurrent_enemies` caps how many can be alive at once
regardless of how many the target curve currently calls for.

**Design goal for future wave/enemy-count tuning: optimize for a growing on-screen enemy density,
bullet-hell-style "overwhelm" tension — not just total kill count or flat stat scaling.** The
player should feel progressively more surrounded as a wave (or loop) goes on, not face a flat or
instantly-spiking threat level. When adjusting `enemies_base_count`/`difficulty_growth`/
`spawn_interval`/`max_concurrent_enemies` (or redesigning the wave/loop curve — see
`project_balance_deferred` in memory), judge the change by the *shape* of concurrent-enemies-over-
time, not only by win/lose or average survival wave. Planned: a Debug panel telemetry readout
(concurrent enemy count, "close calls" — HP dropping low and recovering) to make this shape
observable during manual playtesting, not yet built.

**TOP-DOWN PIVOT COMPLETE (2026-09-27)**: this project was converted from the horizontal
side-scrolling auto-battler into a top-down "Vampire Survivors"-style game — free 2D player
movement via keyboard input, enemies swarming from all directions, continuous survival-time-driven
spawning instead of discrete waves/loops. All 6 phases landed the same day (PRs #42-#47); the
original phased plan lived at `C:\Users\david\.claude\plans\validated-jumping-fairy.md`, which has
since been reused for later unrelated plans (that file is a scratch workspace, not a permanent
record — treat it as stale/irrelevant to this pivot by the time you're reading this). Three follow-up
changes landed later the same day: moving `BottomBar` into a new `CharacterPanel` behind the avatar
click (see "CharacterPanel" below, PR #48), replacing the schopnosti offer's time-based trigger with
a kill-count one (see "Schopnosti na základě zabití" below, PR #49 — itself superseded a few hours
later, see next), and finally splitting dovednosti/schopnosti into a run-scoped-vs-meta "Lobby a
meta-progrese" structure (see below) — the biggest of the three, on par with the pivot itself in how
much it reshapes the core loop. If you see a section below still describing OLD side-scrolling
behavior without a STALE marker, treat it as a documentation gap, not current truth — the code
itself is fully top-down.

**Camera/scrolling model — TOP-DOWN, updated 2026-09-27**: the `Camera2D` (`Main/Camera2D` in
`main.tscn`, script `scenes/camera_follow.gd`) is an **independent sibling node, not a child of
the player**, and now **centers on the player symmetrically on both axes** — no more left-edge
offset. Both X and Y use the same exponential lerp (`follow_speed`, default 5.0):
`global_position = global_position.lerp(_target.global_position, 1.0 - exp(-follow_speed*delta))`.
`main.gd`'s `_ready()` wires it up explicitly: `camera.set_target(player)` (snaps instantly to the
player's exact position on both axes, so there's no visible "flying in" on start) and
`player.landed.connect(camera.shake)` — the player only emits a `landed` signal and has no
reference to the camera at all. Anything that needs "the visible screen area" (enemy spawn
position in `main.gd`, projectile off-screen cleanup in `projectile.gd`, infinite ground tiling in
`ground.gd` — all still X-only/1D as of this PR, pending their own pivot phases) still computes it
from `camera.global_position` — that stays correct because this camera has no *additional*
built-in smoothing layered on top (`position_smoothing_enabled` is intentionally not used; the
manual lerp *is* the smoothing, so `global_position` is always exactly what's rendered, same
reasoning as the `get_screen_center_position()` note in ground.gd below).

**STALE — the paragraph below described the pre-pivot side-scroller camera** (removed 2026-09-27):
it tracked only the player's X with an exponential lerp offset horizontally by `camera_left_margin`
(player rendered near the left edge, not centered), while Y was copied from the player with no lag
at all. That asymmetry existed for two side-scroller-specific reasons, both now moot: (1) the
left-margin offset gave the player room to see enemies approaching from the direction they were
walking (doesn't apply once movement is free in all directions), and (2) Y needed to be lag-free
specifically because the drop-in intro animation and its shake/squash effects assumed the camera
sat exactly on the player's Y at every instant — **this second point still needed live verification
after making Y lerp too, and was confirmed fine** (intro fall/impact/shake all still read correctly
with symmetric lerp, since `set_target()` still snaps instantly on both axes before the drop-in
animation's own tween begins). The original X-lerp's OWN justification (below) is also mostly moot
in top-down, kept only as historical context: **this was a deliberate fix**, not the original
design — when the camera was a rigid child, its X velocity matched the player's exactly, so the
*instant* the player stopped walking (an enemy came into `attack_range`) the camera's on-screen pan
also stopped instantly — collapsing the *apparent* closing speed of an approaching enemy from
`enemy.speed + player.move_speed` down to just `enemy.speed` in a single frame (a real, measured
~43% perceived slowdown, not a change to `enemy.speed` itself). That specific illusion was a
one-lane, one-direction artifact — in top-down, the player can move toward/away/orthogonally to any
enemy at any moment, so there's no single "walking direction" for the camera to compensate for
anymore. The lerp itself is kept regardless (still makes the camera feel less "sticky" on every
small player movement, independent of that original illusion-fix reasoning).

**Combat resolution is distance-based, not physics-based.** Player attacks, enemy melee, and
projectile hits all use `global_position.distance_to(...)` checks against exported range
constants — there are no `Area2D`/`CollisionShape2D` hit layers. This is intentional for prototype
simplicity per the README; if collision performance ever matters, this is the layer to revisit.

**Enemies don't block each other**: each enemy moves **directly toward the player in 2D**
(`global_position.move_toward(player_ref.global_position, speed * delta)` — top-down pivot
2026-09-27, Fáze 4; used to be X-only, `global_position.x -= speed * delta`, so an enemy spawned
above/below the player would never have approached vertically before this) and stops purely at its
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
the player's own base `attack_range`* (400).

**STALE (2026-09-27, top-down pivot Fáze 1) — the "protected artillery" mechanic described below
no longer exists.** It depended entirely on the old move-when-clear logic (`player.gd` only
advancing when nothing was in its own attack range), which Fáze 1 deleted outright in favor of free
2D movement — the player can now simply walk around or past a closer enemy to reach a sniper, so
nothing "holds the player in place" anymore. **Confirmed as an accepted, deliberate loss for this
pivot** (user sign-off during planning) — no replacement mechanic is planned yet; the sniper is for
now just "a ranged enemy with more range than the player," rebalance after playtesting the top-down
game, not before. Kept below for historical context only:

~~Since `player.gd` only advanced (`global_position.x += move_speed * delta`) when **nothing** was
within its own `get_attack_range()`, and a sniper's engagement range exceeded that, the player could
never reach a sniper to fight back while *any other, closer* enemy was still alive and holding the
player in place — the sniper kept landing free hits until the player cleared the field enough to
advance into its own range. This emergent "protected artillery" behavior wasn't purpose-built; it
fell directly out of the old move-when-clear logic once an enemy's range was allowed to exceed the
player's, which is exactly why `sniper_enemy_chance` (0.15) is set lower than `ranged_enemy_chance`
(0.3) — snipers are~~
meant to read as a rarer, more dangerous variant, not a routine replacement for the base enemy.

**STALE (2026-09-27, top-down pivot Fáze 6): the ranged/sniper ramp is now TIME-based, not
wave-based, and applies for the WHOLE run, not just "loop 1".** `main.gd`'s `variant_ramp_start_wave`/
`variant_ramp_full_wave` (int, wave numbers) became `variant_ramp_start_time`/`variant_ramp_full_time`
(float, seconds of `GameManager.survival_time`) — before `variant_ramp_start_time` (first-pass
guess: 30s) neither variant can spawn at all; between start and `variant_ramp_full_time` (first-pass
guess: 90s) their chance grows linearly from 0 to the full `ranged_enemy_chance`/`sniper_enemy_chance`;
after that it's the full configured value, same shape as before, just against a continuous clock.
**The old "only applies in loop 1" exception is GONE** — without discrete loops there's nothing
analogous to guard against (the old exception existed only because a loop reset `current_wave` but
not player progression; a continuous run has no such reset point at all), so the ramp now simply
always applies for the first `variant_ramp_full_time` seconds of any run. The *numbers* below (from
the original wave-based headless simulation that justified the ramp's existence) have NOT been
re-validated against the new time-based version — they're kept for historical context on *why* a
ramp exists at all, not as evidence the new seconds-based thresholds are correctly tuned:

~~This was a data-backed fix, not a guess — a headless simulation (real `main.tscn`/`player.gd`/
`enemy.gd`, sped up via `Engine.time_scale`, "Auto" draft picking so it plays like a no-strategy
player) showed **0/10 runs surviving even wave 1-4** with both variants active from wave 1 at their
full chance, versus **4/10 runs clearing both of the first two loops** (20 waves) when ranged/sniper
were disabled entirely — the dominant killer was ranged/sniper landing free, unavoidable damage from
outside the player's own `attack_range` before the player had *any* item or level yet, not raw enemy
count. Re-running the same simulation after adding the ramp pushed the average death wave from ~2.3
to ~4.1 — a real improvement, but still short of reliably clearing 20 waves, so the ramp alone was a
partial fix, not a finished balance pass.~~

**Enemy projectiles are their own script, never the player's** (`scenes/enemies/enemy_projectile.gd`,
instantiated by `enemy.gd`'s `_shoot_projectile()`) — this satisfies a constraint flagged before any
ranged enemy existed: since enemies don't block each other and can visually overlap (see above),
`scenes/projectiles/projectile.gd`'s "target lost" fallback (scan the `enemies` group for the
nearest target) would be actively dangerous reused for an enemy's own projectile — it would let one
enemy shoot another in the back the moment its assigned target (the player) became invalid.
`enemy_projectile.gd` has no such fallback at all: if `target` isn't valid, the projectile just
keeps flying in its last-aimed direction and eventually self-cleans up off-screen, full stop, no
scanning for a substitute target of any kind. Its `hit_radius` is a fixed export rather than read
from the target (`projectile.gd` reads `target.hit_radius` because enemies come in different
visual sizes; there's only one possible target type for an enemy projectile — the player — so a
fixed value matching the player's own `Polygon2D` half-width is simpler and sufficient).

**STALE (2026-09-27, top-down pivot Fáze 3)**: this paragraph used to say the enemy projectile
"flies the opposite direction (`position.x -= speed * delta`, vs. the player's projectile flying
right) and cleans up past the left edge of the camera's view instead of the right." Both
projectile scripts now compute an aimed `direction: Vector2` once at `setup()` time
(`global_position.direction_to(target.global_position)`, with a zero-vector guard) and move via
`position += direction * speed * delta` — no more hardcoded axis. Off-screen cleanup in both is
now a full 2D check against the visible rect around `camera.get_screen_center_position()` (not
`camera.global_position` — same `position_smoothing_enabled` reasoning as `ground.gd` below),
not a single-edge X comparison. Neither projectile homes on a moving target — direction is fixed
at the instant of firing, same as before, just no longer locked to a single axis.

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

**Level01 is boundless — there is no level-end marker, and the X-cap machinery is now DORMANT, not
just unused.** `player.gd` still looks up a `level_end` group node (`level_end_x` via
`get_tree().get_first_node_in_group("level_end")` at `_ready()`), but since the top-down pivot's
Fáze 1 removed the old X-only "move-when-clear" walk that used to read `level_end_x` every frame,
NOTHING reads this field anymore even when it's set — `level_01.tscn` also still has no `LevelEnd`
node, so it's doubly moot today. Kept deliberately (not deleted) as a *concept marker* for a future
finite planet/level, but a single X coordinate is the wrong SHAPE for capping movement in a
freely-2D-movable top-down game anyway (a real bounded arena would need a `Rect2`/radius, not one X
value) — so don't assume re-adding a `LevelEnd` `Marker2D` alone would do anything today; the
capping *logic* itself would need to be rebuilt for 2D first. `ground.gd`'s `total_width` export is
gone for the same original reason (boundless level) — see below.

**Ground renders infinitely in 2D, tracking the camera** (`ground.gd`) — top-down pivot
2026-09-27, Fáze 5: instead of drawing a fixed set of tiles up front, `_process()` calls
`queue_redraw()` every frame and `_draw()` recomputes which tile indices are currently visible on
**both axes** from `Camera2D.get_screen_center_position()` (± half the viewport size, plus
`tile_margin_count` tiles of buffer) and draws only that window as a full 2D grid. Tile color
alternates on the **sum** of the tile's absolute X+Y index (`posmod(x_i + y_i, 2)`), not drawing
order, so the checkerboard pattern never shifts or flickers as the visible window scrolls in
*either* axis. The tile-range math lives in its own function, `_get_visible_tile_range() ->
Dictionary` (returns `first_x`/`last_x`/`first_y`/`last_y`), pulled out of `_draw()` specifically
so it's callable and assertable from a headless test — `_draw()` itself returns nothing
inspectable. **Use `get_screen_center_position()`, not `camera.global_position`** — the Camera2D
has `position_smoothing_enabled = true`, so `global_position` is the raw, un-smoothed transform
while `get_screen_center_position()` is what's actually rendered; a large/instant position change
(only really happens in tests, not real gradual gameplay movement) makes those two diverge, and
computing the visible tile range from the wrong one draws tiles for a region the camera isn't
actually showing yet — the ground appeared to vanish entirely during testing until this was fixed
(pre-pivot; the same reasoning was carried forward into the 2D rewrite, and `projectile.gd`'s
Fáze-3 off-screen cleanup rewrite deliberately reused it too).

**STALE — `height`/`top_stripe_height`/`top_stripe_color` are GONE (Fáze 5).** The pre-pivot
ground was a single horizontal strip: a fixed-height "floor band" (`height`) with a thin "grass"
stripe (`top_stripe_height`/`top_stripe_color`) along its top edge, because the side-scroller had
a clear "up" with nothing to draw above the floor. A full 2D top-down ground has no such edge —
the checkerboard grid itself is now the entire visible ground in every direction, so those three
exports and their `_draw()` code were deleted outright rather than adapted.

**Difficulty and spawning are now fully CONTINUOUS, driven by elapsed survival time** (top-down
pivot 2026-09-27, Fáze 6 — the last and largest phase of the pivot, see `C:\Users\david\.claude\
plans\validated-jumping-fairy.md`). **Waves and loops are GONE entirely** — `current_wave`,
`loop_count`, `FINAL_WAVE`, `ENEMY_HP_GROWTH_PER_LOOP`, the `wave_started`/`wave_cleared`/
`loop_changed` signals, `start_next_wave()`/`_start_new_loop()`/`_on_wave_cleared()`,
`debug_force_wave_clear()`/`debug_add_loop()` — all deleted, not deprecated. There is no discrete
"wave" concept anywhere in the codebase anymore.

`GameManager.survival_time: float` is the single new driver — it accumulates in `GameManager`'s own
`_process(delta)` whenever `state == State.PLAYING` (same guard pattern player.gd already used for
HP regen), emits `survival_time_changed`, and resets to 0 only on a true Game Over (`reset_game()`).
Three independent systems key off it now, each replacing a wave/loop-triggered equivalent 1:1 in
*mechanism* (same downstream logic, only the trigger changed):
- **Enemy HP scaling**: `get_enemy_hp_multiplier()` = `1.0 + (survival_time / 60.0) *
  ENEMY_HP_GROWTH_PER_MINUTE` (continuous-in-time, replaces the old stepped
  `1.0 + (loop_count - 1) * ENEMY_HP_GROWTH_PER_LOOP`) — `main.gd`'s `_spawn_around_player()` applies
  it to `enemy.max_hp` *before* `add_child()`, exactly as before (unchanged call site).
- **STALE (2026-09-27, later the same day) — schopnosti offers are no longer time-based at all.**
  This bullet originally described a `_ability_offer_timer` accumulator (`ABILITY_OFFER_INTERVAL_
  SECONDS`, ~45s) — removed the same day in favor of a KILL-COUNT trigger with a world pickup, see
  "Schopnosti na základě zabití" below for the full replacement. The downstream offer/resolve
  machinery (`pending_ability_drafts`/`_try_offer_next_ability_draft()`) is unchanged either way —
  only what increments `pending_ability_drafts` changed.
- **Periodic shop**: an internal `_shop_open_timer` accumulator calls `_open_periodic_shop()` every
  `SHOP_OPEN_INTERVAL_SECONDS` (first-pass guess: 240s/4min) — replaces "every loop transition
  (wave-10 clear)". The `_shop_open_deferred`/`_try_open_pending_shop()` collision-avoidance
  machinery (shop must not auto-open while a schopnosti offer is pending) is UNCHANGED in shape —
  it's just resolving a coincidence between two independent timers now instead of a guaranteed
  same-instant collision at wave 10.
- **Elite enemies**: `main.gd`'s `elite_checkpoints_seconds: Array[float]` (first-pass guess: every
  3 minutes) replaces "only on `wave_number == FINAL_WAVE`" — `_check_elite_checkpoints()` (called
  every `_process()` tick) queues `elite_count_per_checkpoint` Elites into the same
  `elites_left_to_spawn` field once `survival_time` crosses each unconsumed checkpoint, using a
  `while` loop (not `if`) so a single very-fast frame (e.g. `Engine.time_scale` 10x in the Debug
  panel) can't skip past a checkpoint without queuing it.

**Enemy spawning itself is target-count-based, not queue-based**: `main.gd` no longer has an
`enemies_left_to_spawn` counter to drain to zero. `_get_target_concurrent_count()` computes, every
frame, how many enemies *should* be alive right now — `enemies_base_count + floor(sqrt(survival_time
/ seconds_per_wave_equivalent) * difficulty_growth)` — the exact same square-root SHAPE as the old
`enemies_base_count + sqrt(wave_number - 1) * difficulty_growth` curve (deliberately preserved to
keep the already-reasoned-about "gradual, not spiky" density goal — see the bullet-hell design note
in Architecture above), just plotted against continuous time instead of an integer wave number via
`seconds_per_wave_equivalent` (first-pass guess: 20s ≈ one old wave). `_process()` spawns one enemy
per `spawn_timer` tick whenever `enemies_alive < min(target_concurrent, max_concurrent_enemies)` OR
an Elite is queued — no more "wave" to run out of; the target simply keeps climbing as
`survival_time` grows, forever.

**Player progression AND position/HP were already untouched across the old loop boundary, and still
are now that there's no boundary at all** — level, XP, item ranks, currency, world position, and
current HP simply keep accumulating for the whole run, nothing resets except on a true Game Over.
Since the level is boundless (see below) and there's no loop transition to even define, the player
just keeps walking and fighting continuously for as long as they survive. `GameManager.State.WON`
and `VictoryPanel` still exist and work exactly as before, but remain unreachable through normal
play (nothing calls `trigger_win()`) — intentionally kept for a real future ending (e.g. after a
planned finite planet/level, see `level_end_x` below).

**Debug panel**: `debug_skip_wave()` → `debug_kill_all_enemies()` (`main.gd`) — "skip wave" has no
meaning without waves, so it's now just "kill everything alive right now" (still routes through
real `take_damage()` for reward/XP, same as before), no more `debug_force_wave_clear()` companion
call needed since there's no wave-clear state to force. `debug_add_loop()` →
`debug_add_survival_time(seconds: float)` (`GameManager`) — jumps `survival_time` forward directly,
for manually testing the three time-based milestones above without waiting for real time to pass.
HUD's `AddLoopButton`/`SkipWaveButton` were renamed to `AddSurvivalTimeButton`/`KillAllEnemiesButton`
to match (see "HUD layout" below for the renamed top-right label too).

**Verified with headless tests at both layers**: a pure-logic test (fresh `GameManager` instance, no
autoloads) confirmed `survival_time` accumulates only in `State.PLAYING`, each of the three
time-based triggers fires exactly once when its interval is crossed, `get_enemy_hp_multiplier()`
grows continuously, and `format_survival_time()` formats correctly; a scene-level test (real
`main.tscn` + `hud.tscn`) confirmed `_get_target_concurrent_count()` grows with `survival_time`,
Elite checkpoints queue exactly once per crossing (not per frame), the ranged/sniper ramp responds
to time instead of wave number, the HUD's survival-timer label updates from the signal, and
`debug_kill_all_enemies()` actually kills real enemy instances. **Not yet balance-tuned** — every
"first-pass guess" number above (`SHOP_OPEN_INTERVAL_SECONDS`, `ENEMY_HP_GROWTH_PER_MINUTE`,
`seconds_per_wave_equivalent`, `elite_checkpoints_seconds`, `variant_ramp_start_time`/
`variant_ramp_full_time`) is a structural placeholder, not a value derived from playtesting or
simulation — expect all of them to need revisiting once the continuous game is actually played for
a while, same as every other tunable in this project historically has. (`ABILITY_OFFER_INTERVAL_
SECONDS` itself is GONE, replaced the same day — see "Schopnosti na základě zabití" immediately
below.)

**STALE (2026-09-27, později téhož dne — "Lobby a meta-progrese" níže): kill-count/kosočtverec
systém popsaný v téhle sekci je PRYČ, jen několik hodin po tom, co vznikl.** Nabídka schopností se
vrátila zpátky na run-scoped level-up (`_level_up()` v `game_manager.gd` teď přímo volá
`pending_ability_drafts += 1; _try_offer_next_ability_draft()`, stejně jako `begin_intro_ability_
draft()` už dělal) - `enemies_killed`, `_ability_offers_granted_by_kills`, `_ability_kill_
threshold()`, signál `ability_pickup_dropped`, `request_ability_offer()`,
`scenes/pickups/ability_pickup.gd`/`.tscn` jsou všechny SMAZANÉ, ne jen deprecated. Důvod obratu:
zavedení "Lobby a meta-progrese" (viz níže) přesunulo dovednostní strom mimo run-scoped level-upy do
klidné lobby mezi běhy, takže level-up se uvolnil a bylo přirozené ho vrátit zpátky pro schopnosti -
tempo pořád sleduje, co hráč DĚLÁ (level roste jen ze zabíjení), jen přes jinou metriku než syrový
počet zabití. Zbytek téhle sekce je ponechán jen jako historický kontext, PROČ kill-count systém
kdysi vznikl - žádný z popsaných symbolů dnes neexistuje:

~~**Schopnosti na základě zabití — nahrazuje časovač zeleným kosočtvercem** (2026-09-27, později
téhož dne jako Fáze 6 - explicit user request: "tempo voleb se má odvíjet od toho, co hráč dělá,
ne od hodin"). `ABILITY_OFFER_INTERVAL_SECONDS`/`_ability_offer_timer` jsou PRYČ - `GameManager.
_process()` už nabídku schopností vůbec nespouští. Místo toho:

- **`GameManager.enemies_killed: int`** počítá CELKOVÝ počet zabití za aktuální běh (resetuje se v
  `reset_game()`). `enemy_defeated()` po každém zabití zavolá `_register_kill_toward_ability_
  pickup(death_position)`, která porovná `enemies_killed` s `_ability_kill_threshold(
  _ability_offers_granted_by_kills)` - kumulativním prahem pro DALŠÍ nabídku.
- **Odmocninová křivka** (stejná filozofie jako `_get_target_concurrent_count()` v `main.gd` -
  postupný, ne skokový růst): `_ability_kill_threshold(offer_index) = round(ABILITY_KILL_THRESHOLD_
  COEFFICIENT * (offer_index + 1)^1.5)`. S koeficientem 10 (PRVNÍ ODHAD, needoladěné hraním): 10,
  28, 52, 80, 112, 147, 185, 226, 270, 316 zabití pro prvních 10 nabídek - blízko uživatelem
  navržených orientačních bodů (10/30/50), jen jako hladká křivka místo tří čísel natvrdo.
- **Kill, který práh překročí, NEspustí nabídku okamžitě** - jen emitne `ability_pickup_dropped
  (death_position)`. `main.gd` na to reaguje spawnutím `ability_pickup_scene`
  (`scenes/pickups/ability_pickup.tscn`) přesně na místě smrti (`_on_ability_pickup_dropped()`) -
  `GameManager` nezná scény/pozice sám o sobě, jen řekne KDY a KDE main.gd (vlastník veškerého
  spawnování) má něco vytvořit, stejný princip jako u nepřátel.
- **`scenes/pickups/ability_pickup.gd`** - zelený kosočtverec (`Polygon2D`, 4 body, žádný obrázkový
  asset - stejná procedurální filozofie jako zbytek projektu). `_process()` každý snímek kontroluje
  vzdálenost k hráči (`get_first_node_in_group("player")`, stejný vzor jako `enemy.gd`); jakmile je
  hráč do `pickup_radius` (40px), zavolá `GameManager.request_ability_offer()` (veřejná obálka nad
  `pending_ability_drafts += 1`/`_try_offer_next_ability_draft()` - stejná fronta/mechanismus, jaký
  dřív spouštěl časovač) a HNED se zničí (`queue_free()`). **Zmizí při doteku, NE až po skutečném
  výběru v panelu** - explicit user rozhodnutí: vizuálně nerozeznatelné (panel hru pauzne prakticky
  ve stejném snímku), ale jednodušší a bez rizika, že by dva současně ležící kosočtverce (hráč
  ignoruje první, zabije dost na druhý) spletly, který patří ke které nabídce.
- **Více kosočtverců může ležet na poli současně** - žádné omezení na počet, protože fronta
  (`pending_ability_drafts`) už zvládá víc čekajících nabídek sekvenčně (stejný mechanismus, jaký
  dřív řešil kolizi na hranici 10. vlny). Pokud hráč sebere druhý kosočtverec dřív než první, prostě
  dostane dvě nabídky za sebou - žádné speciální řešení pořadí není potřeba.
- **`request_ability_offer()` je nové veřejné rozhraní** nahrazující přímé sahání na privátní
  `_try_offer_next_ability_draft()` zvenčí - `debug_force_ability_draft()` je teď jen tenký alias
  nad ním. Nové Debug tlačítko **"+10 zabití"** (`GameManager.debug_add_kills(10)`) pro rychlé
  přiblížení se dalšímu prahu bez grindění.
- **Obchod zůstává na časovači** (`SHOP_OPEN_INTERVAL_SECONDS`, beze změny) - explicit user
  rozhodnutí "obchod necháme zatím na timing, vyřešíme to později", tahle změna se týká VÝHRADNĚ
  nabídky schopností.
- **Verified with headless tests at both layers**: pure-logic test potvrdil přesné hodnoty křivky
  pro prvních 10 nabídek, že `enemy_defeated()` emitne `ability_pickup_dropped` PŘESNĚ na zabití,
  co práh překročí (ne dřív, ne vícekrát), s korektní pozicí, a že obchodní časovač zůstal
  nedotčený; scéna-level test (real `main.tscn`) potvrdil, že `main.gd` spawne kosočtverec přesně
  na hlášenou pozici, že se nesebere z dálky, že se sebere a vyžádá nabídku při vstupu do
  `pickup_radius`, a že se okamžitě zničí.~~

**Lobby a meta-progrese — dovednostní strom se přesunul MEZI běhy** (2026-09-27, později téhož dne
jako kill-count experiment výše - explicit user request: "chtěl bych dát pryč dvojí systém přidávání
bodů do dovedostí a schopností [...] dovedostní stromy vyjmuli ze hlavního herního loop a bylo by to
součástí herního lobby"). Motivace: dovednostní strom (klik na portrét, kdykoliv za běhu) a schopnosti
(kill-count kosočtverec, viz STALE výše) pauzovaly hru ve dvou nezávislých, nesourodých rytmech -
řešení není další kolizní guard (jako `_shop_open_deferred` mezi obchodem a schopnostmi), ale
rozdělení podle TEMPA: schopnosti (rychlé rozhodování za chodu) zůstávají v běhu, dovednostní strom
(pomalé, promyšlené investování) se přesouvá do klidné **lobby** obrazovky MEZI běhy. Tohle znovu
zavádí koncept "konec běhu", který Fáze 6 záměrně zrušila ve prospěch nekonečného přežití - běh teď
končí buď smrtí, NEBO dosažením časového checkpointu (`main.gd`'s `loop_duration_seconds`, první
odhad 180s/3min), obojí vede do lobby.

- **Dvě oddělené úrovňové osy v `game_manager.gd`**: `player_level`/`player_xp` (beze změny jmen,
  ale teď VÝHRADNĚ run-scoped - řídí jen run-scoped odměny a od téhle změny znovu i spouštění
  nabídky SCHOPNOSTÍ, viz STALE výše) vs. nové `meta_level`/`meta_xp` (TRVALÉ přes běhy, NEresetuje
  je `reset_game()`). `pending_skill_points`/`skill_ranks` (dovednostní strom, beze změny tvaru/
  `invest_skill_point()`/`can_invest_skill_point()`) se staly META - vyřazeny z `reset_game()`'s
  clear listu, takže investice v lobby permanentně zvyšují základní staty i v budoucích bězích
  (`get_stat_bonus()` čte `skill_ranks` beze změny, bez ohledu na to, KDE se investovalo).
- **`_run_xp_earned: int`** (nový, run-scoped) sčítá VŠECHNO XP vydělané za aktuální běh (`add_xp()`
  k němu přičítá bez ohledu na to, kolik z toho padlo do run-scoped level-upů) - na konci běhu se 1:1
  převede na `meta_xp` přes `add_meta_xp()`. `meta_xp_for_next_level()` sdílí stejnou `XP_BASE`/
  `XP_PER_LEVEL_GROWTH` křivku jako `xp_for_next_level()` (první odhad, může se doladit nezávisle).
- **Sdílený konec běhu**: `trigger_game_over()` (smrt, `player.gd`'s `take_damage()`, beze změny
  spouštěče) a `trigger_win()` (dokončení smyčky - `State.WON`/`VictoryPanel`, dřív nedosažitelné
  běžnou hrou, jsou teď reálná, běžná cesta) obě volají novou `_finish_run(reason: String)`, která
  naplní `last_run_summary: Dictionary` ({"reason", "level", "currency", "meta_xp_gained"}, čte ho
  lobby) a zavolá `add_meta_xp(_run_xp_earned)` - PŘED tím, než `main.tscn`'s `_enter_tree()` na
  cestě do dalšího běhu zavolá `reset_game()` a run-scoped stav smaže.
- **`main.gd`'s `_check_loop_completion()`** (nová, stejný vzor jako `_check_elite_checkpoints()`,
  volaná z `_process()`) zavolá `GameManager.trigger_win()`, jakmile `survival_time` překročí
  `loop_duration_seconds` (první odhad 180.0). **Reálná interakce**: `SHOP_OPEN_INTERVAL_SECONDS`
  snížen ze 240 na **90** (jinak by se periodický obchod v 180s běhu prakticky nikdy neotevřel -
  explicit user rozhodnutí "obchod necháme beze změny" jinak fakticky znamenalo "obchod zmizí").
  `elite_checkpoints_seconds` (180/360/540/720/900) zůstal nezměněný, ale s 180s smyčkou se prakticky
  nikdy nedostane přes první prvek - známý follow-up pro balancování, neblokující.
- **Nová scéna `scenes/ui/lobby.tscn`/`lobby.gd`** - samostatná scéna (žádný `Player`/`Main`/kamera,
  čistě UI), na kterou `hud.gd`'s přejmenovaná `_go_to_lobby()` (dřív `_restart_game()`, stejný
  countdown/hover-pauza mechanismus, jen jiný cíl přechodu) přepne přes
  `get_tree().change_scene_to_file(...)` po Game Over/Victory countdownu. Metu úroveň/XP bar (vlevo
  nahoře), dovednostní strom (`_build_skill_tree_ui()`/`_refresh_skill_tree_ui()` PŘESUNUTY beze
  změny logiky z dřívějšího `hud.gd` - `GameManager.SKILL_TREE_BRANCHES`/`invest_skill_point()` pod
  tím se nezměnily), obchod (viz níže) a tlačítko "Další běh"
  (`get_tree().change_scene_to_file("res://scenes/main.tscn")`, spustí `main.gd`'s `_enter_tree()` →
  `reset_game()` stejně jako dřívější restart).
- **STALE (2026-09-28, o den později): lobby už NEMÁ souhrn běhu, a místo toho má taby Dovednosti/
  Obchod.** Explicit user request - obrazovka dřív nahoře ukazovala `GameManager.last_run_summary`
  ("Zemřel jsi."/"Smyčka dokončena!" + úroveň/zlato/meta-XP); `last_run_summary` se pořád plní
  (`_finish_run()`), jen se v lobby už nezobrazuje. Layout je teď: vlevo nahoře meta úroveň/XP bar,
  vpravo nahoře `GoldLabel` ("Zlato: N"), uprostřed nahoře dvě záložková tlačítka
  `DovednostiTabButton`/`ObchodTabButton` (stejný bílá/`LOCKED_ITEM_MODULATE` vzor jako dřívější
  CharacterPanel taby) přepínající `NodesContainer` (dovednostní strom) vs. `ShopTabContent`
  (obchod, viz níže) - `_set_active_tab(show_dovednosti: bool)`. `DovednostiTabButton` nese malý
  žlutý `SkillPointsBadge` s "+N" (`pending_skill_points`) - **na rozdíl od dřívějšího portrétového
  odznáčku je tenhle skutečně akční**, protože v lobby (na rozdíl od běhu) investování reálně funguje.
- **`CharacterPanel` (klik na portrét, v běhu) ztratil záložky úplně** - `InventoryTabButton`/
  `SkillTreeTabButton`/`SkillTreeTabContent` smazány, zůstala jen dřívější Inventář sekce (staty +
  aktivní/sklad itemy), bez tab-bar navrch. `_on_portrait_pressed()` se zjednodušil na prosté
  otevření panelu - žádná "výchozí záložka podle pending_skill_points" logika (ta dovednostní vazba
  teď nemá v běhu kam vést). **STALE (2026-09-28): žlutý odznáček na portrétu je PRYČ úplně**, ne jen
  passivní - `Control/SkillPointBadge`/`SkillPointLabel` smazány z `hud.tscn`, `hud.gd`'s
  `_on_skill_points_changed()` (a připojení na `GameManager.skill_points_changed`) smazáno taky.
  Explicit user request/zdůvodnění: hráč nemůže body dovednosti přidávat BĚHEM hry vůbec (jsou META,
  viz "Lobby a meta-progrese" výše), takže i čistě informativní odznáček na portrétu byl matoucí -
  signalizoval něco, na co portrét v běhu žádnou akcí nereaguje.
- **STALE (2026-09-28): obchod v lobby už NENÍ odložený do follow-up PR - je tam VŽDY dostupný.**
  Předchozí den zůstal obchod v běhu beze změny mechanismu (periodicky na časovači) a jeho ruční
  dostupnost z lobby byla vědomě odložená; explicit user request o den později ji dodal rovnou.
  `ShopTabContent` (obchod tab) znovupoužívá stejná run-scoped data jako `ShopPanel` v běhu
  (`GameManager.shop_offer`/`buy_shop_item()`/`reroll_shop()`/`can_buy_shop_item()` beze změny) přes
  4 `ShopCard0..3` + `RerollButton`, stejný vzor jako dřívější `hud.gd`'s `_setup_shop_cards()`/
  `_refresh_shop_panel()` (kód zvlášť v `lobby.gd`, ne sdílený - viz "known follow-up" o extrakci do
  vlastní scény níže). **STALE (2026-09-28, ještě později): karty i dovednostní dlaždice jsou teď
  celé `Button`, ne `Panel` + vnořené "ActionButton"/"Investovat" tlačítko.** Explicit user request -
  stejný vzor jako `AbilityDraftPanel`'s `Card0..2` (`hud.tscn`), kde je karta sama tlačítko a klik
  kdekoliv na ni rovnou vybere. `ShopCard0..3` (`lobby.tscn`) i procedurálně stavěné dovednostní
  dlaždice (`lobby.gd`'s `_build_skill_tree_ui()`) teď mají žádné vnořené tlačítko - `card.pressed`/
  `tile.pressed` (Button je sám sobě kořenem) volá přímo `_on_shop_card_action_pressed()`/
  `_on_skill_node_pressed()`. Potomci (NameLabel/DescLabel/...) mají `mouse_filter = 2` (IGNORE),
  stejná pojistka jako u `Card0`'s dětí, ať klik na text pořád propadne na tlačítko pod ním. Stavový
  text dřívějšího tlačítka ("Investovat"/"Max"/"Koupit") zmizel úplně - `disabled` stav dlaždice
  (ztlumené tlačítko) spolu s existujícím "Stupeň N/M" popiskem (kde N==M už sám říká "Max") nesou
  stejnou informaci bez extra textu. **"Vždy dostupný" konkrétně znamená**: `lobby.gd`'s `_ensure_shop_offer()`
  (volané z `_ready()`) rovnou nastaví `GameManager.shop_available = true` a zavolá
  `_generate_shop_offer()`, POKUD aktuální běh obchod ještě neotevřel (`shop_available == false`,
  typicky když hráč zemře dřív než `SHOP_OPEN_INTERVAL_SECONDS` časovač poprvé vyprší) - existující
  nabídku z proběhlého běhu naopak nechá beze změny. `ShopEmptyLabel`/"obchod ještě nebyl otevřen"
  placeholder z předchozího dne je pryč, protože je teď nedosažitelný stav.
- **STALE (2026-09-28, ještě později téhož dne): `ShopTabContent` teď ukazuje i aktivní/sklad
  itemy, ne jen nabídku ke koupi.** Explicit user request - stejný obsah, jaký `CharacterPanel`/
  `InventoryTabContent` ukazuje v běhu (`ActiveLabel`/`ActiveItemsContainer`,
  `StashLabel`/`StashContainer`, mini-sloty s "Uskladnit"/"Aktivovat"/"Prodat" tlačítky), přidaný
  POD nabídkové karty + reroll tlačítko (karty zmenšeny z 280 na 190px výšky, ať se všechno vejde do
  `ShopTabContent`'s 590px). `lobby.gd`'s `_build_inventory_ui()`/`_create_inventory_mini_slot()`/
  `_refresh_inventory_ui()`/`_fill_inventory_mini_slot()`/`_clear_inventory_mini_slot()`/
  `_on_active_slot_stash_pressed()`/`_on_stash_slot_activate_pressed()`/`_on_stash_slot_sell_pressed()`
  jsou **doslovná kopie** stejnojmenných funkcí v `hud.gd` (viz "CharacterPanel" výše) - žádná sdílená
  scéna/skript mezi nimi (viz "known follow-up" o extrakci `ShopPanel` do vlastní `.tscn` níže, tenhle
  duplicitní vzor je přesně ten důvod, proč by se to vyplatilo). `_refresh_shop_tab()` volá
  `_refresh_inventory_ui()` na svém konci, takže oboje zůstává synchronní při každém přepnutí na
  Obchod tab, nákupu, i změně zlata.
- **Odstraněno jako mrtvý kód touhle změnou** (kill-count schopnosti systém z předchozí STALE sekce):
  `GameManager.enemies_killed`, `_ability_offers_granted_by_kills`, `_ability_kill_threshold()`,
  `_register_kill_toward_ability_pickup()`, signál `ability_pickup_dropped`, `request_ability_offer()`,
  `enemy_defeated()`'s `death_position` parametr (zpátky na 3 argumenty), `scenes/pickups/
  ability_pickup.gd`/`.tscn`, `main.gd`'s `ability_pickup_scene` export, HUD debug tlačítko
  "+10 zabití".
- **Verified with headless tests at both layers**: pure-logic test (fresh `GameManager` instance)
  potvrdil `_run_xp_earned` sčítání, že `_level_up()` nabízí schopnost přímo (ne přes
  `pending_skill_points`), že `trigger_game_over()`/`trigger_win()` obě naplní `last_run_summary` a
  převedou run-XP na meta-XP přes `add_meta_xp()`, a že `reset_game()` smaže run-scoped stav ale
  NEsmaže `meta_level`/`meta_xp`/`pending_skill_points`/`skill_ranks`; scéna-level test (real
  `main.tscn`) potvrdil, že `_check_loop_completion()` skutečně zavolá `trigger_win()` při přechodu
  `loop_duration_seconds` a že `CharacterPanel` už nemá `SkillTreeTabContent`; samostatný scéna-level
  test `lobby.tscn` potvrdil, že postaví přesně 1 uzel na každou schopnost ve `SKILL_TREE_BRANCHES` a
  že klik na uzel skutečně investuje bod a překreslí UI. **Doplněno 2026-09-28** po dnech-po úpravách
  (souhrn pryč, taby, portrét bez odznáčku, obchod vždy dostupný): další scéna-level test potvrdil, že
  `hud.tscn` už nemá `SkillPointBadge` uzel a `main.tscn` pořád naběhne bez chyby, a že čerstvý
  `reset_game()` (tedy `shop_available == false`) po instanciaci `lobby.tscn` skončí s
  `shop_available == true` a plnou `SHOP_OFFER_SIZE`-položkovou nabídkou hned od prvního snímku, i
  bez jediného volání `_open_periodic_shop()`. Živě v editoru zatím NEodzkoušeno - hlavně celý cyklus
  běh → smrt/checkpoint → lobby → investice/nákup → "Další běh" → nový běh s vyššími staty, a vizuální
  rozložení `lobby.tscn` (žádné hand-authored offsety zatím ověřené okem, jen výpočtem v testu).

**Passive HP regeneration** (`player.gd`): `base_hp_regen` (default 1.0 HP/s, like League of
Legends' base HP5) ticks continuously in `_process()` whenever `hp < max_hp` and the player is
alive and `PLAYING` — not just after a loop transition, and not paused by combat. Routed through
`get_hp_regen()` = `base_hp_regen + GameManager.get_stat_bonus("hp_regen")`, mirroring every other
stat getter, even though nothing currently grants an `"hp_regen"` bonus — free to hook up later
without touching this getter. The HUD shows it as a small green `+X.X/s` label
(`Control/HPBar/RegenLabel`) anchored to the right end of the HP bar, hidden whenever HP
is already full (`_update_hp_regen_label()` in `hud.gd`) so it doesn't clutter the bar when it isn't
doing anything.

**STALE — "Kolo" vs. "Úroveň" no longer applies (2026-09-27, Fáze 6).** `LoopLabel` is deleted;
there's no loop counter anymore. The top-right corner now shows a single `SurvivalTimeLabel`
("Čas: mm:ss", see "Kontinuální spawn/obtížnost" above) where `WaveLabel` used to sit — see "HUD
layout" below for its exact position. "Úroveň" (the player's XP-based character level, badge over
the portrait) is unaffected and still the only thing called that.

**Elite enemy (time checkpoints, not "final wave")**: `scenes/enemies/elite_enemy.tscn` reuses `enemy.gd` (it's fully
data-driven via `@export` vars, so no new script was needed) with `speed` halved, `max_hp` tripled,
and the `Polygon2D` visual scaled 3x — `melee_range` was also bumped (60 → 100) so the much bigger
sprite doesn't visually overlap the player before it stops to attack. `main.gd`'s
`elite_count_per_checkpoint` (default 1) controls how many spawn per checkpoint; `_check_elite_
checkpoints()` queues them once `GameManager.survival_time` crosses each unconsumed entry of
`elite_checkpoints_seconds` (top-down pivot Fáze 6 — replaces the old "only on `wave_number ==
FINAL_WAVE`" gating), and `_spawn_enemy()` always drains the Elite queue before falling back to
normal/variant enemies, so Elite(s) appear first once a checkpoint is crossed, mixed in among the
continuously-spawning regular enemies rather than concentrated into one specific wave.

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
only needed one special case, not four. The stat column also shows it (`StatCrit`, `hud.gd`'s
`_refresh_stat_labels()`) — the 5 existing rows there had to shrink from a 28px step to 22px to fit
a 6th row inside the available height without overflowing (this also incidentally fixed a
pre-existing 6px overflow `StatArmor` already had before this change). **This stat column now lives
in `CharacterPanel`/`InventoryTabContent`, not `BottomBar`** (moved 2026-09-27, see "CharacterPanel"
above) — the 22px step size itself carried over unchanged, just the parent container did not.

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

**Point economy — STALE cadence description (2026-09-27, "Lobby a meta-progrese" above):**
`GameManager.pending_skill_points` grants exactly **1 point per META level-up** now, not per
run-scoped level-up — `add_meta_xp()` increments it, not `_level_up()` (which reverted to offering
a random schopnost instead, see above). It's also no longer run-scoped — it, and `skill_ranks`
below, are explicitly EXCLUDED from `reset_game()`'s clear list, so they persist across runs and get
spent in the lobby (`scenes/ui/lobby.tscn`), not by clicking the in-run portrait. The rest of this
paragraph is otherwise still accurate: `skill_ranks: Dictionary` (`{ability_id: rank}`, missing key
== rank 0) replaces `owned_abilities` — there is at most ONE "copy" of any schopnost now (a growing
rank, not independent stackable instances), so a single Dictionary is sufficient; no active/stash
split either (schopnosti still have no purchase-slot pressure, same as before). `invest_skill_point
(ability_id)` is the only way a rank ever increases: checks `can_invest_skill_point()` (points > 0,
node unlocked, rank < max_rank), then decrements the point and increments the rank atomically,
emitting both `skill_points_changed`/`skill_ranks_changed` — unchanged regardless of WHERE (lobby,
now) it's called from.

**STALE (2026-09-28, "Lobby a meta-progrese" above): the portrait badge described in this whole
paragraph is GONE** — `SkillPointBadge`/`SkillPointLabel` were deleted from `hud.tscn`, and
`hud.gd`'s `_on_skill_points_changed()` (along with its `GameManager.skill_points_changed`
connection) was deleted too. Explicit user reasoning: the badge signaled "you have a point to
spend," but points are META now and can't be spent by clicking the in-run portrait at all (only in
the lobby, which has its own, actually-actionable badge on the `DovednostiTabButton`) — a
non-actionable badge in the run was just confusing. `Control/Portrait` stays a `Button` (still opens
`CharacterPanel`), just with no `modulate`/badge reaction to `pending_skill_points` anymore. Kept
below for historical context on the badge-adjacent `mouse_filter` pattern, which is still relevant
for `LevelBadge`/`LevelLabel`:

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
  reasoning as `debug_kill_all_enemies()` in `main.gd`: routing through the real method keeps reward/XP and
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

**HUD layout — a top-left stack and top-right counters** (`hud.tscn`). Went through several
reshuffles on 2026-09-09 as the user iterated on where things should live, and again 2026-09-27
when `BottomBar` was removed entirely in favor of `CharacterPanel` (see "CharacterPanel" above) —
this describes the current state, current as the authoritative reference (treat any older
description you find elsewhere, including `BottomBar` mentions below, as stale):

- **Top-left**: `Portrait` (`offset_left = 20`, `offset_top = 20` —
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
  `AbilitiesContainer` shifted down to follow both times. **STALE (2026-09-28): `LevelBadge`/
  `LevelLabel` (the small "current level" number overlaid on Portrait's corner) are GONE** —
  explicit user request to remove the in-game level badge on the avatar. Player level is no longer
  shown anywhere during a run at all (only indirectly through higher stats, via
  `LEVEL_STAT_GROWTH`) — it reappears on the Game Over/Victory screen text after the run ends
  (`hud.gd`'s `show_game_over()`/`show_victory()`, unaffected by this change).
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
- **STALE (2026-09-27) — `BottomBar` no longer exists, deleted entirely.** It used to hold the stat
  readouts (`StatDamage`/`StatSpeed`/`StatRange`/`StatHP`/`StatArmor`/`StatCrit`) and `ItemSlot1..6`
  (112×112 squares showing active shop items, read-only) as a trap always-visible strip pinned to
  the bottom 140px of the screen. Both pieces of content moved into `CharacterPanel` (see dedicated
  section below) — the motivation was that a permanently-occupied bottom strip made even less sense
  after the top-down pivot's free 2D movement than it did in the original side-scroller. The
  `DebugButton`-must-come-after-`BottomBar`-in-child-order constraint documented here previously is
  moot now that `BottomBar` doesn't exist — `DebugButton` still needs to render on top of whatever
  panel might visually overlap it, just check current sibling order in `hud.tscn` directly rather
  than trusting this note.

**`CharacterPanel` — a single tabbed screen replacing both the old always-visible `BottomBar` and
the shop's active/stash sections** (added 2026-09-27, explicit user request: move `BottomBar`
somewhere else, put it behind the avatar click alongside the skill tree, and while doing it also
move the shop's stash display there too). Clicking the portrait (`portrait_button`) opens
`CharacterPanel` (renamed from the pre-existing `SkillTreePanel` — same trigger, same
pause-the-game behavior, see "Dovednostní strom" above for why the panel-open mechanics themselves
are unchanged) — an 840×640 panel centered on screen (widened from the old `SkillTreePanel`'s
760×640 specifically to comfortably fit a 9-slot stash row, see below) with two tab buttons
top-center (`InventoryTabButton`/`SkillTreeTabButton`) toggling which of two full-size child
`Control`s is visible: `InventoryTabContent` (default) and `SkillTreeTabContent` (the skill tree's
`PointsLabel`/`NodesContainer`, unchanged content, just reparented one level deeper and no longer
carrying its own `Title` — the tab buttons themselves now serve as the section header). Active tab
is shown white, inactive tab uses `LOCKED_ITEM_MODULATE` (the same dimming color the project already
uses for unavailable items/schopnosti — deliberately no new color introduced just for this).

**STALE (2026-09-27, "Lobby a meta-progrese" above): no more tabs, no more default-tab logic.**
This paragraph described picking Inventář vs. Dovednosti as the default tab depending on
`pending_skill_points` — Dovednosti moved out to `scenes/ui/lobby.tscn` entirely, so
`CharacterPanel` has only the one (former Inventář) section left and `_on_portrait_pressed()` just
opens it unconditionally. The yellow "+N" badge on the portrait still lights up on
`pending_skill_points > 0`, but now purely as a passive "you have something to spend next time
you're in the lobby" indicator — clicking the portrait during a run never leads to investing
anymore.

**`InventoryTabContent` holds three previously-separate pieces, all now in one place**: the stat
labels (moved verbatim from `BottomBar`, same `_refresh_stat_labels()` body, just new `@onready`
paths), and the shop's `ActiveItemsContainer`/`StashContainer` mini-slot grids (moved verbatim from
`ShopPanel`, same procedural-build code in `_build_inventory_ui()` — renamed from
`_build_shop_stash_ui()` — and same refresh code in `_refresh_inventory_ui()` — renamed from
`_refresh_shop_stash_ui()`). **`ShopPanel` now does ONLY buying** — the 4 offer cards + reroll
button — and shrank accordingly (720×520 → 720×310, `CloseButton` moved up to follow). **No
`GameManager` changes were needed for any of this** — `active_shop_items`/`stash_shop_items` and
every function over them (`buy_shop_item()`, `move_shop_item_to_stash()`,
`move_shop_item_to_active()`, `sell_shop_item()`) are exactly as documented below; only the UI
displaying them moved. `_refresh_inventory_ui()` is called from `_refresh_shop_panel()` (buying/
rerolling while the shop is open), `_refresh_progression()`, and `_on_shop_inventory_changed()` —
so the Inventář tab is always current even while `CharacterPanel` itself is closed, same pattern
`_refresh_abilities()` already used. **Verified with a headless test**: `BottomBar` confirmed absent
from the scene tree; portrait click with 0 pending points opens Inventář, with a pending point opens
Dovednosti directly; both tab buttons toggle correctly in both directions; stat labels and a
constructed `active_shop_items` entry both render correctly from their new locations.

**STALE, see the correction under "Schopnosti (dovednostní strom)" below** — this paragraph
described an interim state where `AbilitiesContainer` showed dovednosti ranks too; as of
2026-09-26 it shows ONLY schopnosti from the random draft (`owned_abilities`), rebuilt on
`ability_inventory_changed`, not `skill_ranks_changed`. The rest of this paragraph (positional
slots, one per owned instance, reshuffling on merge) is still accurate for that one remaining
source. **Column wrap keeps the stack from growing unboundedly downward**: slots stack downward and
wrap into a new column to the right after `ABILITY_STACK_MAX_ROWS` (6) — `col = i /
ABILITY_STACK_MAX_ROWS`, `row = i % ABILITY_STACK_MAX_ROWS` — chosen so even a full column (6 × 52px
tall), starting from `AbilitiesContainer`'s `offset_top = 108`, ends (`y = 416`) well within the
project's 720px-tall window. **STALE detail**: this used to be justified specifically as "stays
above `BottomBar`'s top edge" — `BottomBar` is gone (2026-09-27, see "CharacterPanel" above), so the
budget is now just "fits the window," not "avoids a specific sibling." This is a static budget (like
every other HUD offset in this project, see `ground.gd`'s "no dynamic viewport-based layout"
precedent), not computed from the actual viewport height at runtime, so a much shorter window — or
moving `AbilitiesContainer` further down the screen — would need this constant revisited by hand.

**Shop pauses the game via `get_tree().paused`**, which is why the HUD `CanvasLayer` has
`process_mode = 3` (ALWAYS) in `hud.tscn` — without it the shop's own close button would freeze
along with the game. The pause is deliberate *for now*; the user has flagged that they may later
want the game to keep running while the shop is open, so the pause lives only in
`_on_shop_close_pressed()` / `_close_shop()` / `_on_shop_auto_open_requested()` in `hud.gd` and
nothing else depends on it.

**Shop opens periodically, not any time** (`GameManager.shop_available`,
`shop_auto_open_requested` signal, `_open_periodic_shop()`): the shop unlocks and shows a fresh
offer automatically — panel pops open and pauses, no click needed — every `SHOP_OPEN_INTERVAL_
SECONDS` of `GameManager.survival_time` (top-down pivot Fáze 6, 2026-09-27 — see "Kontinuální
spawn/obtížnost" above; this section originally said "the moment wave 10 is cleared," from when
the game had discrete waves/loops — that trigger point no longer exists). This resolved a
long-standing open design question (shop available any time vs. gated to a specific moment) via a
Bazaar-inspired redesign brainstorm — that underlying design intent (periodic, not always-on)
carried through the pivot unchanged, only the trigger mechanism changed. `shop_available` turns
true the first time this fires in a run and stays true for the rest of that run (run-scoped state,
reset in `reset_game()`). **The manual `ShopButton` was removed 2026-09-09** (user asked to move
the gold counter to the top bar and declutter `BottomBar`) — auto-open via
`_on_shop_auto_open_requested()` is still the *only* way the panel appears. Known, accepted
trade-off, unchanged by the pivot: if the player closes the panel before spending/rerolling
everything they want, there is no way to reopen that same offer until the next periodic trigger
generates a new one.

**`_shop_open_deferred`/`_try_open_pending_shop()` still exist and still do the same job** —
deferring the shop's auto-open while a schopnosti offer is pending, so `AbilityDraftPanel` and
`ShopPanel` never stack on top of each other. This mechanism has flip-flopped between "needed" and
"removed" a few times across this project's history as the schopnosti/dovednosti/wave systems were
reworked (see the git history of this section if curious) — as of the Fáze 6 pivot it's back to
"needed," now guarding against two independent `GameManager._process()` timers coincidentally
firing close together rather than a guaranteed same-instant wave-10 collision. `SkillTreePanel`
never force-opens automatically at all (removed 2026-09-26, unrelated to this pivot) — it can never
collide with the shop.

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
only when a *new* offer is generated (periodic shop-timer unlock or a completed reroll), so closing and
reopening the shop does **not** reset the price ramp; the ramp exists specifically to stop
infinite-free-rerolling for a perfect draw. `GameManager.debug_free_reroll` (Debug panel's
"Free reroll" toggle) makes `get_shop_reroll_cost()` always return 0 for fast manual testing — like
`Engine.time_scale`, this is intentionally **not** reset by `reset_game()` (dev convenience across
restarts, not game state).

**`ShopPanel` must stay well under the game's 720px window height** — it once grew to exactly
720px tall (edge-to-edge with the default window, zero margin) after adding a now-removed combine-
items section, which pushed the "Zavřít obchod" button off-screen with no way to close the panel.
**Shrank back to 310px tall (2026-09-27)** when the active/stash sections moved out to
`CharacterPanel` (see "CharacterPanel" above) — `ShopPanel` is now just offer row + reroll button +
close button, comfortably under budget again; any future addition still needs to actively check
this rather than assume there's room.

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

**The 6 active + 9 stash mini-slots are built procedurally in `hud.gd`, not hand-authored in
`hud.tscn`** (`_build_inventory_ui()`/`_create_inventory_mini_slot()`, renamed from
`_build_shop_stash_ui()`/`_create_shop_mini_slot()` when they moved out of `ShopPanel` into
`CharacterPanel`/`InventoryTabContent` — see "CharacterPanel" above) — 15 nearly identical small
widgets (a `Label` + 1-2 `Button`s each) were judged not worth writing by hand in the scene file;
`hud.tscn` only has two empty `Control` containers (`ActiveItemsContainer`/`StashContainer`, now
under `InventoryTabContent`) that the code populates once in `_ready()` and then refreshes in
place via `_refresh_inventory_ui()` (renamed from `_refresh_shop_stash_ui()`). Each widget is
tracked as a plain `Dictionary` (`{"panel", "label", "buttons"}`) in
`_active_slot_widgets`/`_stash_slot_widgets` rather than typed nodes, since they were never
declared in the scene tree to have `@onready`-style paths in the first place.

**STALE (2026-09-27) — `Control/BottomBar/ItemSlot1..6` no longer exists.** It used to be a
read-only, purely-decorative second display of active shop items sitting in the always-visible
`BottomBar` — separate from (and redundant with) the interactive active-items mini-slot grid that
already existed inside the shop. Both were merged into one interactive display when `BottomBar` was
removed (see "CharacterPanel" above) — there is now exactly one place active items are shown, and
it's always the interactive one.

**Debug panel** (`hud.gd`, `scenes/ui/eye_icon.gd`): a dev-only panel toggled by the `DebugButton`
— TEMPORARILY in the bottom-right corner as of 2026-09-09, see "HUD layout" above — which shows
"Debug" plus a procedurally-drawn eye icon (open/closed,
`eye_icon.gd` — no image asset, consistent with the rest of the project's visuals) that mirrors
whether the panel is open. **`DebugPanel` itself was repositioned 2026-09-28** (explicit user
request) — it had grown tall enough over time (bottom at `y=750`, past the 720px viewport, AND
directly overlapping `DebugButton`'s own screen area at the bottom-right) that the toggle button
became unclickable while the panel was open, the only way to close it was via the panel's own
"Zavřít" button. Fixed two ways together: `DebugPanel` moved up and shrunk (`offset_top`/
`offset_bottom` from `50`/`750` to `16`/`650`, now fits entirely within the viewport with room to
spare above `DebugButton`), and its `CloseButton` moved from a centered row at the panel's bottom
(the space that used to overlap `DebugButton`) to a small square icon-only button (text `"X"`, no
more "Zavřít" label) next to `Title` in the top-right corner of the panel — freeing the whole bottom
region, which is what actually made the up-shift+shrink possible without cutting off any existing
button row. `hud.gd`'s `@onready var debug_close_button` path (`$Control/DebugPanel/CloseButton`)
and its `_on_debug_close_pressed()` wiring are unchanged — only the node's position/size/text in
`hud.tscn` moved. Unlike the shop, opening it does **not** pause the game — the point is
to see the effect of an action (kill, skip wave, spawn Elite, ...) happen live. Every action on the
panel is a thin call into a method explicitly named/commented `DEBUG:` on `GameManager`, `player.gd`,
or `main.gd` — the panel itself (`_setup_debug_panel()` and its handlers in `hud.gd`) holds no game
logic of its own, just wiring. A few of these are worth knowing about because they deliberately
reuse the *real* code paths rather than shortcutting past them:
- **Nesmrtelnost** sets `player.debug_invincible`, checked in `take_damage()` right after the
  existing `state != PLAYING` guard — resets to `false` automatically on any scene reload since it
  lives on the player instance, not `GameManager`.
- **Zabít všechny nepřátele** (`main.gd`'s `debug_kill_all_enemies()`, renamed from
  `debug_skip_wave()` in the top-down pivot Fáze 6 — "skip wave" stopped meaning anything once
  waves were removed entirely) kills every currently-alive enemy through their normal
  `take_damage()` (so they still grant currency/XP and go through the double-kill-safe `_is_dead`
  guard from `enemy.gd`) rather than just clearing counters directly. No companion
  "force-clear"-style call needed anymore — the continuous spawner (see "Kontinuální spawn/
  obtížnost" above) just notices `enemies_alive` dropped and refills toward its time-based target
  on its own next tick.
- **Spawnout Elite** / **Spawnout dálkového** / **Spawnout snipera** all share
  `_spawn_around_player()` (renamed from `_spawn_at_edge()` in the top-down pivot, see below) with
  the normal continuous spawner so a debug-spawned enemy gets the same HP-multiplier-before-`add_child()`
  treatment as one spawned by
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
  spendable currency in the first place — it's just a clean slate. **STALE detail (2026-09-27,
  "Lobby a meta-progrese" above)**: this used to say "for the next level-up to build up points
  again" — `pending_skill_points` is now META (grows from `add_meta_xp()` at the end of a run, not
  from a run-scoped level-up), so the clean slate rebuilds from META level-ups across future runs,
  not from levels within the current one.
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
the same day and are live again, unchanged in mechanics, with one change: schopnosti's offer now
triggers after the intro landing (as ORIGINAL) AND periodically thereafter (see "STALE" note below
for what that periodic trigger became after the top-down pivot's Fáze 6), not after every level-up.
`_level_up()` only grants dovednosti points now.

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

**STALE (2026-09-27, top-down pivot Fáze 6): "wave 10" doesn't exist anymore — see "Kontinuální
spawn/obtížnost" further below for the current shape of this collision.** The mechanism itself
(`_shop_open_deferred`/`_try_open_pending_shop()`, deferring the shop's auto-open while a
schopnosti offer is pending, retried at the tail of `resolve_ability_draft()`) is UNCHANGED in
shape and still exists — only the reason a collision can happen changed, from "guaranteed, every
10th wave clear" to "two independent timers (`_ability_offer_timer`/`_shop_open_timer` in
`GameManager._process()`) coincidentally firing close together," which is rarer but structurally
identical to handle.

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
- `scenes/camera_follow.gd` — `follow_speed` (camera lag/responsiveness; `camera_left_margin` is GONE, camera centers symmetrically, see "Camera/scrolling model" above)
- `scenes/main.gd` — `enemies_base_count`/`difficulty_growth`/`seconds_per_wave_equivalent` (continuous target-concurrent-count curve), spawn interval/margin, `max_concurrent_enemies`, `elite_count_per_checkpoint`/`elite_checkpoints_seconds`, `ranged_enemy_chance`, `sniper_enemy_chance`, `variant_ramp_start_time`/`variant_ramp_full_time` (time-based ramp for when ranged/sniper start appearing, applies to the whole run now — see "Kontinuální spawn/obtížnost" above), `loop_duration_seconds` (run ends and sends the player to the lobby once `survival_time` crosses this, see "Lobby a meta-progrese" above)
- `scenes/enemies/enemy.gd` — enemy speed/HP/damage, `melee_range`, `hit_radius`, `reward`, `xp_reward`, `scrap_reward` (see "Suroviny a crafting" above), `is_ranged`/`projectile_scene`
- `scenes/enemies/elite_enemy.tscn` — Elite's stat overrides (speed/max_hp/melee_range/hit_radius) and visual scale, node properties only (script is shared with `enemy.gd`)
- `scenes/enemies/ranged_enemy.tscn` / `sniper_enemy.tscn` — each variant's `melee_range` (engagement distance) and color, also just node properties on the shared `enemy.gd`; sniper's `melee_range` (550) vs. the player's base `attack_range` (400) no longer produces the old "protected artillery" behavior (that was an emergent side effect of movement logic removed in the top-down pivot's Fáze 1 — see the STALE note under "Sniper enemies" above), so this relationship is currently just flavor, not a load-bearing mechanic
- `scenes/enemies/enemy_projectile.gd` — enemy projectile `speed`, `hit_radius`, `cleanup_margin`
- `scenes/levels/level_01.tscn` — has no `LevelEnd` marker (level is boundless); the X-cap machinery this would feed is dormant (see "Level01 is boundless" above), so adding one alone won't do anything today
- `scenes/levels/ground.gd` — `tile_size`, tile colors, `tile_margin_count` (redraw buffer beyond the visible camera window, now on both axes)
- `scripts/autoload/game_manager.gd` — XP curve (`XP_BASE`, `XP_PER_LEVEL_GROWTH`, shared by both run-scoped `xp_for_next_level()` and META `meta_xp_for_next_level()`, see "Lobby a meta-progrese" above), schopnost definitions (`ABILITIES` — passive entries' `"value"` = PER-RANK stat amount, `"max_rank"` per node, active entries' `"trigger_values"` sized to `"max_rank"`), `ABILITY_ORDER`, `SKILL_TREE_BRANCHES` (the 4 branches, root-to-capstone order — see "Schopnosti" above), `ENEMY_HP_GROWTH_PER_MINUTE`/`ABILITY_OFFER_INTERVAL_SECONDS`/`SHOP_OPEN_INTERVAL_SECONDS` (the three continuous time-based milestones — see "Kontinuální spawn/obtížnost" above; `FINAL_WAVE`/`ENEMY_HP_GROWTH_PER_LOOP` are GONE), shop item definitions (`SHOP_ITEMS`, multi-stat), `SHOP_ACTIVE_SLOTS`/`SHOP_STASH_SLOTS`, `SHOP_SELL_REFUND_RATIO`, `SHOP_OFFER_SIZE`, `SHOP_REROLL_BASE_COST`/`SHOP_REROLL_COST_STEP`, `SHOP_RARITY_WEIGHTS` (offer rarity odds), `SHOP_RARITY_MULTIPLIERS`/`SHOP_RARITY_COST_RATIOS` (shop's rarity tier power/cost curves; 3-copy merge threshold is hardcoded in `_try_merge_shop_item()` — schopnosti no longer use `ShopRarity` at all, see "Schopnosti" above), `LEVEL_STAT_GROWTH` (automatic per-level stat floor, small relative to schopnosti/shop), `TAG_DISPLAY_NAMES`/each entry's `"tags"` (tag synergy display categories, see "Tag synergie" above), `ABILITIES["overclock_matrix"]`/`SHOP_ITEMS["resonance_array"]`'s `"synergy"` dicts (per-owned-tagged-thing scaling — `_count_owned_with_tag()` does the counting), `ABILITIES["precision_targeting"]`/`SHOP_ITEMS["precision_scope"]` (flat `crit_chance` sources, see "Critical hits" above)
- `scenes/ui/hud.gd` — `END_SCREEN_RESTART_DELAY`, `DEBUG_SPEED_STEPS` (Debug panel's speed cycle), `ABILITY_STACK_MAX_ROWS` (schopnost stack column-wrap threshold, see "Hromádka VŠECH vlastněných schopností" above)
- `scenes/ui/lobby.gd` — `SKILL_NODE_WIDTH`/`HEIGHT`/`GAP` (skill tree node grid sizing, moved here from `hud.gd` — see "Lobby a meta-progrese" above)
