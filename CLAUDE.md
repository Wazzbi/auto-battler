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
before the first meaningful choice appears. Each level queues one "item draft" (see below) — there
is no per-stat purchasing, no ability tree, and (as of this note) **no automatic stat growth from
levelling either**: `LEVEL_STAT_GROWTH` was deliberately removed, so a bare level-up (before the
resulting draft is resolved) changes nothing about the player's stats. This was a conscious
simplification, not an oversight — with both an automatic per-level bump *and* item picks
contributing to the same numbers, a stat like "Poškození: 28" was a sum of an invisible part (level
growth) and a visible, chosen part (item rank), so the player's choices didn't fully explain their
own power. Now every point of every stat traces back to a specific picked item, which also matters
more once real active/passive abilities join the item pool (see below) — there's one unified
"level-up = one upgrade slot" model instead of two parallel growth tracks to keep straight.

**Stats flow**: base stats live as `@export` vars on `player.gd` (`base_damage`,
`base_attack_speed`, `base_attack_range`, `base_max_hp`, `base_armor`). Effective stats come from
getters (`get_damage()`, `get_attack_speed()`, `get_attack_range()`, `get_target_count()`,
`get_hp_regen()`, `get_armor()`) that add `GameManager.get_stat_bonus(stat_id)` — **the single place
where progression turns into numbers**, and now purely a sum of picked-item ranks (no level term at
all). The player recomputes on the `level_changed` and `item_rank_changed` signals — `level_changed`
alone is a no-op for stats now, kept only so UI (the level badge, etc.) stays in sync; the HUD never
touches player stats directly. **Balance caveat**: removing the automatic floor means a run's power
now depends entirely on what the (currently small, 7-item) draft pool happens to offer — going
several levels without seeing a given stat's item is possible (~57% chance per level to miss any one
specific item with `DRAFT_CHOICE_COUNT` 3 of 7), so a fragile-feeling run from bad luck is a known,
accepted trade-off for now, not yet tuned away.

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
`kinetic_dampers` grants +2 armor per rank, matching `base_armor`'s scale, up to `MAX_ITEM_RANK` (5).

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
Mechanically the payoff is identical to before — each item has a `stat` + `per_rank` pair and a
rank up to `MAX_ITEM_RANK`, so it's still just a passive bonus, not a real active effect (same
placeholder status the abilities had; when real active effects get built, `ITEMS` and
`get_stat_bonus()` are still the only things that need to change).

**Draft flow / one offer at a time**: `_level_up()` increments `GameManager.pending_drafts` and
calls `_try_offer_next_draft()`, which only actually rolls and emits `item_draft_ready` if
`_current_offer` is empty — **this guard is load-bearing**, not decorative: a single big XP grant
(e.g. the Debug panel's "+500 XP") can call `_level_up()` several times synchronously inside
`add_xp()`'s loop, and without the guard each of those calls would roll and emit its own offer,
stomping `_current_offer` and desyncing `pending_drafts` from what's actually on screen. Offers are
resolved one at a time via `resolve_draft(item_id)`, which clears `_current_offer` and calls
`_try_offer_next_draft()` again — so a big XP grant queues N drafts that the HUD walks through
sequentially, not simultaneously.

**Draft pauses the game, unlike the old ability buttons did** (`_show_draft_panel()` /
`_on_draft_pick_pressed()` in `hud.gd`, mirroring the Shop's `get_tree().paused` pattern) — a
level-up card is meant to be a deliberate stop-and-choose moment. The "Auto" toggle
(`Control/BottomBar/AutoAssignToggle`, **default OFF** — this is a deliberate flip from the old
ability system's default-ON Auto, see below) resolves offers with a uniformly random pick and skips
the panel/pause entirely. Toggling Auto **on** while a draft is already showing must proactively
resolve it (`_on_draft_auto_toggled()`) — otherwise the panel would stay stuck open forever, since
nothing else would ever call `resolve_draft()` for it.

**Why Auto defaults OFF now, unlike the old ability-point Auto-assign (which defaulted ON)**: the
entire point of switching to randomized item drafts was to give the player a real, visible choice
each level — defaulting Auto to on would silently defeat that by never showing the player the
choice is happening at all. Auto is kept as an opt-in convenience for fast playtesting/debugging,
not as the expected default experience. The random-pick logic itself is still a deliberately
simple placeholder (no weighting by current build) — same caveat the old ability Auto-assign had.

**HUD is one bottom bar** (`Control/BottomBar` in `hud.tscn`) styled after MOBA HUDs: stat readouts,
portrait with a level badge, HP bar, XP bar, six picked-item slots (`PickedItemSlot0..5`, indexed
to match `GameManager.ITEM_ORDER` — grayed out at rank 0, shows `short_name` + rank once picked),
six (currently decorative, unrelated — future equipment loot) `ItemSlot1..6` rects, gold, and the
shop button. Right-side elements are anchored to the right edge and the bars stretch, so the bar
survives window resizing.

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
- **Max/Reset itemy** are a blunt build-testing tool — max sets every item straight to
  `MAX_ITEM_RANK`, reset zeroes every rank. Unlike the old ability respec, reset does **not** refund
  anything to re-spend, because items were never bought with a spendable currency in the first
  place — they're free picks from a draft, so "reset" is just a clean slate for the next level-up.

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
- `scripts/autoload/game_manager.gd` — XP curve (`XP_BASE`, `XP_PER_LEVEL_GROWTH`), item definitions (`ITEMS`) and `MAX_ITEM_RANK`, `DRAFT_CHOICE_COUNT`, `FINAL_WAVE` (which wave triggers a new loop), `ENEMY_HP_GROWTH_PER_LOOP` (difficulty ramp between loops) — there is no per-level stat growth table anymore, all stat growth comes from `ITEMS`
- `scenes/ui/hud.gd` — `END_SCREEN_RESTART_DELAY`, `DEBUG_SPEED_STEPS` (Debug panel's speed cycle)
