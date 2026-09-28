extends Node2D
## Hráčova postava. Pohyb je od 2026-09-27 VOLNÝ 2D podle vstupu z klávesnice
## (top-down pivot, viz CLAUDE.md) - `Input.get_vector()` nad
## move_left/right/up/down. Útok je NEZÁVISLÝ na pohybu: pokud je nepřítel v
## dosahu, hráč na něj automaticky střílí (žádné ruční míření), ať už se
## zrovna hýbe, nebo stojí - stejně jako ve Vampire Survivors. Předtím byl
## pohyb čistě automatický (chůze doprava, zastavení jen když byl nepřítel v
## dosahu) - tahle stará "jdi jen když je čisto" logika je pryč beze zbytku.
##
## Kamera NENÍ child tohoto uzlu (viz scenes/camera_follow.gd) - je to
## nezávislý uzel pod Main, který hráče sleduje vlastní plynulou logikou.
## Hráč o kameře vůbec neví, jen emituje signály (`landed`), na které
## kamera podle potřeby reaguje (např. otřesem).
##
## Na startu hry proběhne krátká "drop-in" animace - postava spadne na
## svou pozici shora jako z vesmírné výsadkové kapsle. Dokud animace
## neskončí, je hra ve stavu GameManager.State.INTRO a žádná herní
## logika (spawn, pohyb, útoky) neběží.

signal hp_changed(current_hp: float, max_hp: float)
signal died
## Emitne se po dopadu drop-in animace - kamera na to reaguje otřesem
## (main.gd propojuje player.landed -> camera.shake), ale hráč sám o
## kameře nic neví.
signal landed

@export var base_max_hp: float = 100.0
@export var base_damage: float = 10.0
@export var base_attack_speed: float = 1.0 # útoků za sekundu
@export var base_attack_range: float = 400.0
## Pasivní regenerace HP za sekundu - tiká pořád, ne jen mimo boj (jako
## základní HP regen v League of Legends)
@export var base_hp_regen: float = 1.0
## Plochý odečet poškození z KAŽDÉHO zásahu (ne procento) - viz take_damage().
## Standardní žánrový nástroj proti "umřu na součet spousty malých zásahů":
## na rozdíl od ladění počtu/rychlosti nepřátel škáluje samo s tím, kolik
## jich bude v budoucnu víc, protože každý jednotlivý zásah je relativně
## slabší, ne jen méně častý.
@export var base_armor: float = 2.0
## Šance (0.0-1.0) na kritický zásah při KAŽDÉM jednotlivém výstřelu (u
## multishotu se tedy losuje zvlášť pro každý projektil, stejná granularita
## jako _consume_ability_triggers()) - viz _shoot(). Nemá vlastní
## LEVEL_STAT_GROWTH řádek (stejně jako multishot) - je to čistě
## volbou-řízený stat ze schopností/obchodu, ne automatická podlaha.
@export var base_crit_chance: float = 0.05
## Násobič poškození při kritickém zásahu - pevná hodnota podle zadání
## ("dvojnásobné zranění"), ne další stat k růstu; crit_chance samo o sobě
## roste přes schopnosti/itemy (viz get_crit_chance()).
const CRIT_DAMAGE_MULTIPLIER: float = 2.0
@export var move_speed: float = 60.0 # px/s volného 2D pohybu podle vstupu (viz _process())
## Poskok (Dash) - okamžitý přesun o `dash_distance` pixelů ve směru pohybu,
## aktivace mezerníkem (viz project.godot's "dash" input action). Explicit
## user request 2026-09-28, včetně skici dobíjecího baru v HUD (viz
## hud.tscn's DashLabel/DashCooldownBar, hud.gd's _update_dash_cooldown_bar()).
## Okamžitý posun (ne tween) - jednodušší, žádná kolize s per-frame pohybem
## v _process() níže, a hra beztak nemá žádné kolizní vrstvy (viz "Combat
## resolution is distance-based" v CLAUDE.md), takže "prokliknutí" skrz
## nepřítele není o nic problematičtější než normální pohyb.
@export var dash_distance: float = 150.0
@export var dash_cooldown: float = 5.0
@export var projectile_scene: PackedScene
@export var impact_effect_scene: PackedScene
## Vizuál pro schopnost "Orbitální bombardování" (trigger "time_elapsed",
## efekt "aoe_strike") - stejný script jako impact_effect_scene (ImpactEffect),
## jen s větším poloměrem/jinou barvou v samotné .tscn, viz _trigger_aoe_strike().
@export var orbital_strike_effect_scene: PackedScene

## Nastavení drop-in animace
@export var fall_height: float = 900.0
@export var fall_duration: float = 0.55
@export var fall_tilt_degrees: float = -10.0

@onready var visual: Polygon2D = $Polygon2D

var max_hp: float
var hp: float
var cooldown_timer: float = 0.0
## Odpočítává od dash_cooldown k 0 - HUD (DashCooldownBar) z něj přímo čte
## přes get_dash_cooldown_ratio() na 0.0 (právě použito) - 1.0 (připraveno).
var dash_cooldown_timer: float = 0.0
## Směr posledního NENULOVÉHO pohybového vstupu - použije se jako směr
## poskoku, když hráč zrovna nedrží žádnou pohybovou klávesu (mezerník sám o
## sobě nic o směru neříká). Výchozí doprava, než se hráč poprvé pohne.
var _last_move_direction: Vector2 = Vector2.RIGHT
## X pozice konce levelu - najde se automaticky přes uzel ve skupině "level_end".
## DORMANTNÍ od top-down pivotu (2026-09-27): žádný kód už tuhle hodnotu
## nečte (volný 2D pohyb nemá jednoosý strop), ale pole i vyhledání v
## _ready() zůstávají schválně - jednoosý X strop stejně nedává pro budoucí
## ohraničenou arénu smysl (ta by potřebovala 2D tvar, ne jedno X), takže
## mazání by jen zahodilo bez náhrady. Level01 navíc žádný "level_end" marker
## nemá (level je bezkonečný), takže tohle bylo mrtvé i předtím - viz CLAUDE.md.
var level_end_x: float = INF
## DEBUG: dokud je zapnuté, take_damage() nic neudělá. Ovládá se z Debug
## panelu v HUD (viz hud.gd), na resetu hry (nová instance hráče) se sama
## vrátí na false.
var debug_invincible: bool = false
## Postup KAŽDÉ investované DOVEDNOSTI (viz GameManager.skill_ranks) směrem
## k jejímu dalšímu spuštění - klíčovaný ability_id, protože ve stromu
## existuje nanejvýš JEDNA "kopie" každé schopnosti (rostoucí rank, ne
## nezávislé instance) - ability_id je tak stabilní identita napříč
## investováním dalších bodů. Jednotka závisí na triggeru té konkrétní
## schopnosti: "shot_count" počítá celočíselně výstřely (viz
## _consume_ability_triggers()), "time_elapsed" počítá sekundy (viz
## _process_time_based_abilities()) - float, aby šlo přičítat `delta`.
## NERESETUJE se při investování dalšího bodu do JINÉ dovednosti - jen když
## se dovednost poprvé odemkne (viz _on_skill_ranks_changed()). Souběžný,
## samostatný stav od `_ability_progress` níže (SCHOPNOSTI, náhodná
## nabídka), viz "Schopnosti - DVA SOUBĚŽNÉ..." v game_manager.gd.
var _skill_progress: Dictionary = {}
## Postup KAŽDÉ vlastněné AKTIVNÍ schopnosti Z NÁHODNÉ NABÍDKY (viz
## GameManager.owned_abilities) směrem k jejímu dalšímu spuštění - stejný
## index/pořadí jako owned_abilities. Přebuduje se od nuly při KAŽDÉ změně
## vlastnictví (_on_ability_inventory_changed()), i jen kosmetické (sloučení,
## nebo přidání úplně jiné schopnosti) - vědomý kompromis: sloučená schopnost
## tak ztratí rozpracovaný postup ke svému příštímu spuštění, ale instance v
## poli nemají stabilní identitu napříč sloučeními, takže "zachovat postup"
## by vyžadovalo sledovat identitu navíc jen pro tenhle okrajový případ.
var _ability_progress: Array[float] = []
## Poloviční rozměry hráčova VLASTNÍHO vizuálu (Polygon2D, ±20 x ±30 dnes) -
## spočítané jednou v _ready() z `visual.polygon` samotného (ne natvrdo
## zapsané číslo), ať se automaticky přizpůsobí, kdyby se vizuál hráče někdy
## změnil. Použité v _resolve_obstacle_collisions() (viz níže) - kolize musí
## počítat s tím, že HRÁČ SÁM má nenulovou velikost, ne jen s velikostí
## objektu, jinak by se odsunulo jen hráčovo STŘED mimo objekt a hráčův
## vlastní vizuál by do objektu pořád vizuálně zasahoval (přesně tenhle
## přesah nahlásil uživatel screenshotem 2026-09-28 - "chtěl jsem... aby
## hráč nemohl BÝT UVNITŘ statických objektů").
var _collision_half_extent: Vector2 = Vector2.ZERO


func _ready() -> void:
	add_to_group("player")
	_collision_half_extent = _compute_collision_half_extent()

	# Progrese (úrovně, pasivní schopnosti, nákupy v obchodě) mění staty za
	# běhu - reagujeme na všechny tři signály, HUD do statů hráče nikdy
	# nesahá přímo.
	GameManager.level_changed.connect(_on_level_changed)
	GameManager.shop_inventory_changed.connect(_on_shop_inventory_changed)
	GameManager.skill_ranks_changed.connect(_on_skill_ranks_changed)
	GameManager.ability_inventory_changed.connect(_on_ability_inventory_changed)

	_recalculate_stats()
	hp = max_hp
	hp_changed.emit(hp, max_hp)

	var end_marker := get_tree().get_first_node_in_group("level_end")
	if end_marker != null:
		level_end_x = end_marker.global_position.x

	_play_drop_in_animation()


## Postava začne vysoko nad svou cílovou pozicí a spadne dolů s lehkým
## náklonem, jako by vypadla z výsadkové kapsle. Po dopadu následuje
## krátký squash efekt, otřes kamery a dopadová vlna.
func _play_drop_in_animation() -> void:
	var landing_y: float = position.y
	position.y = landing_y - fall_height
	visual.rotation_degrees = fall_tilt_degrees

	var tween := create_tween()
	tween.set_trans(Tween.TRANS_QUAD)
	tween.set_ease(Tween.EASE_IN)
	tween.tween_property(self, "position:y", landing_y, fall_duration)
	tween.parallel().tween_property(visual, "rotation_degrees", 0.0, fall_duration)
	tween.tween_callback(_on_landed)


## STALE (2026-09-28, explicit user request "dej pryč ten první výběr
## schopnosti co je po dopadu hráče do hry"): po dopadu už NEPROBÍHÁ žádný
## intro krok - `GameManager.finish_intro()` se volá přímo, hra naběhne do
## State.PLAYING hned, jakmile doběhnou kosmetické reakce na dopad (viz
## níže). Dřív tu byla jedna vynucená úvodní nabídka SCHOPNOSTI
## (`GameManager.begin_intro_ability_draft()`/`resolve_ability_draft()`,
## smazáno spolu s touhle změnou) - první schopnost teď hráč dostane úplně
## stejně jako každou další, přes běžný run-scoped level-up
## (`GameManager._level_up()`), ne vynuceně před začátkem hry.
func _on_landed() -> void:
	var impact_effect: Node2D = _spawn_impact_effect()
	landed.emit()
	_play_squash_effect()

	# Dopadový prstenec (impact_effect.gd, výchozí duration 0.4s) je ze všech
	# tří kosmetických reakcí nejdelší - otřes kamery (camera_follow.gd's
	# shake(), výchozí 0.22s) i squash tween (0.08+0.15=0.23s, viz
	# _play_squash_effect()) oba doběhnou dřív, takže stačí počkat na něj.
	if impact_effect != null:
		await get_tree().create_timer(impact_effect.duration).timeout

	GameManager.finish_intro()


func _spawn_impact_effect() -> Node2D:
	if impact_effect_scene == null:
		return null
	var effect: Node2D = impact_effect_scene.instantiate()
	get_tree().current_scene.add_child(effect)
	effect.global_position = global_position
	return effect


func _play_squash_effect() -> void:
	var squash_tween := create_tween()
	squash_tween.tween_property(visual, "scale", Vector2(1.35, 0.65), 0.08)
	squash_tween.tween_property(visual, "scale", Vector2.ONE, 0.15)


## Přepočítá staty na základě base hodnot + bonusů (automatický level growth,
## pasivní schopnosti, obchod - viz GameManager.get_stat_bonus()). Přírůstek
## max HP se přičte i k aktuálnímu HP, takže pasivní schopnost na max HP
## trochu vyléčí.
func _recalculate_stats() -> void:
	var old_max_hp := max_hp if max_hp > 0 else base_max_hp
	max_hp = base_max_hp + GameManager.get_stat_bonus("max_hp")
	if hp > 0:
		hp += max_hp - old_max_hp


func get_damage() -> float:
	return base_damage + GameManager.get_stat_bonus("damage")


func get_attack_speed() -> float:
	return base_attack_speed + GameManager.get_stat_bonus("attack_speed")


func get_attack_range() -> float:
	return base_attack_range + GameManager.get_stat_bonus("attack_range")


## Kolik cílů hráč zasáhne najednou (1 + bonus z itemu "Dělené střely")
func get_target_count() -> int:
	return 1 + int(GameManager.get_stat_bonus("multishot"))


## Kolik HP za sekundu hráč pasivně regeneruje. Stejný vzorec (base + bonus)
## jako ostatní staty, i když teď žádná úroveň/schopnost regen neovlivňuje -
## připravené pro budoucí rozšíření (viz GameManager.get_stat_bonus()).
func get_hp_regen() -> float:
	return base_hp_regen + GameManager.get_stat_bonus("hp_regen")


func get_armor() -> float:
	return base_armor + GameManager.get_stat_bonus("armor")


func get_crit_chance() -> float:
	return base_crit_chance + GameManager.get_stat_bonus("crit_chance")


func _on_level_changed(_new_level: int) -> void:
	_apply_progression_changes()


func _on_shop_inventory_changed() -> void:
	_apply_progression_changes()


## Pasivní dovednosti mění staty (přes get_stat_bonus()), aktivní ne - ale
## obojí sdílí skill_ranks_changed, takže se staty přepočítávají vždy, i pro
## čistě aktivní investici. _skill_progress se čistí jen pro NOVĚ odemčené
## dovednosti (klíč zatím chybí) - postup dovednosti, do které hráč jen
## investoval DALŠÍ bod, se NEresetuje (stabilní ability_id klíč to
## nevyžaduje, viz komentář u _skill_progress výše).
func _on_skill_ranks_changed() -> void:
	_apply_progression_changes()
	for ability_id in GameManager.skill_ranks:
		if not _skill_progress.has(ability_id):
			_skill_progress[ability_id] = 0.0


## Pasivní schopnosti (náhodná nabídka) mění staty, aktivní ne - ale obojí
## sdílí owned_abilities/_ability_progress, takže se přepočítává a
## přerovnává vždy, i pro čistě aktivní přírůstek. Restore z dřívějšího
## systému, viz _ability_progress výše pro plné zdůvodnění resetu.
func _on_ability_inventory_changed() -> void:
	_apply_progression_changes()
	_ability_progress.resize(GameManager.owned_abilities.size())
	_ability_progress.fill(0.0)


func _apply_progression_changes() -> void:
	_recalculate_stats()
	hp_changed.emit(hp, max_hp)


func _process(delta: float) -> void:
	if GameManager.state != GameManager.State.PLAYING:
		return

	if hp < max_hp and hp > 0.0:
		hp = minf(hp + get_hp_regen() * delta, max_hp)
		hp_changed.emit(hp, max_hp)

	_process_time_based_abilities(delta)

	# Pohyb a boj běží NEZÁVISLE na sobě, každý snímek, bez ohledu na stav
	# toho druhého - na rozdíl od staré "jdi jen když je čisto" logiky hráč
	# může střílet A hýbat se zároveň (Vampire Survivors styl).
	var input_dir := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	global_position = _resolve_obstacle_collisions(global_position + input_dir * move_speed * delta)
	if input_dir != Vector2.ZERO:
		_last_move_direction = input_dir.normalized()

	dash_cooldown_timer = maxf(dash_cooldown_timer - delta, 0.0)
	if Input.is_action_just_pressed("dash"):
		_try_dash()

	cooldown_timer -= delta
	var targets := _find_nearest_targets(get_target_count())
	if not targets.is_empty() and cooldown_timer <= 0.0:
		for target in targets:
			_shoot(target)
		cooldown_timer = 1.0 / max(get_attack_speed(), 0.01)


## Okamžitě přesune hráče o dash_distance ve směru aktuálního pohybového
## vstupu (nebo _last_move_direction, drží-li hráč zrovna žádnou pohybovou
## klávesu) a spustí dobíjení. No-op, dokud dash_cooldown_timer neklesne na 0.
func _try_dash() -> void:
	if dash_cooldown_timer > 0.0:
		return

	var input_dir := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var direction: Vector2 = input_dir.normalized() if input_dir != Vector2.ZERO else _last_move_direction
	global_position = _resolve_obstacle_collisions(global_position + direction * dash_distance)
	dash_cooldown_timer = dash_cooldown


## 0.0 (právě použito) - 1.0 (plně dobito/připraveno) - HUD (DashCooldownBar)
## z toho přímo počítá plnění baru, stejná "roste s dobíjením" logika jako
## cooldown bary v jiných hrách (prázdný hned po použití, plný když je
## schopnost připravená).
func get_dash_cooldown_ratio() -> float:
	return 1.0 - dash_cooldown_timer / dash_cooldown


## Změří hráčův vlastní Polygon2D (±20 x ±30 dnes) a vrátí jeho poloviční
## rozměry - viz _collision_half_extent výše pro proč je to potřeba.
func _compute_collision_half_extent() -> Vector2:
	var half_extent: Vector2 = Vector2.ZERO
	for point in visual.polygon:
		half_extent.x = maxf(half_extent.x, absf(point.x))
		half_extent.y = maxf(half_extent.y, absf(point.y))
	return half_extent


## Hráč (na rozdíl od nepřátel, viz enemy.gd's _avoid_obstacles()) statické
## objekty NEOBCHÁZÍ, ale je jimi blokován - nemůže do nich vejít ANI SVÝM
## VLASTNÍM VIZUÁLEM, ne jen svým středem (viz "Statické objekty ve světě" v
## CLAUDE.md, explicit user request 2026-09-28 - screenshot ukázal hráče
## viditelně přesahujícího do objektu, protože dřívější verze počítala jen s
## objektovou stranou kolize a bod (hráčovo `global_position`) bez vlastní
## velikosti). Volá se pro KAŽDOU navrhovanou novou pozici (běžný pohyb i
## dash) - pokud by `pos` skončila blíž k objektu ("obstacles" skupina), než
## dovoluje SOUČET `obstacle.collision_half_size` (polovina strany
## čtvercového objektu) A `_collision_half_extent` (poloviční rozměry
## hráčova vlastního vizuálu) na dané ose - Minkowského součet dvou
## obdélníků, standardní technika pro "box vs box" kolizi převedenou na
## jednodušší "bod vs zvětšený box" - odsune ji ven na NEJBLIŽŠÍ hranu (osa s
## MENŠÍM průnikem = kratší cesta ven, AABB point-clamp vytlačení, žádná
## fyzika). Aplikuje se postupně přes VŠECHNY blízké objekty, ne najednou
## vyřešené - pro řídce rozmístěné placeholder objekty dostatečně přesné, u
## hustě natěsnaných překážek by to nebylo dokonalé (menší priorita než
## skutečná fyzika pro tenhle prototyp).
func _resolve_obstacle_collisions(pos: Vector2) -> Vector2:
	var resolved_pos: Vector2 = pos
	for obstacle in get_tree().get_nodes_in_group("obstacles"):
		if not is_instance_valid(obstacle):
			continue
		var half_x: float = obstacle.collision_half_size + _collision_half_extent.x
		var half_y: float = obstacle.collision_half_size + _collision_half_extent.y
		var local: Vector2 = resolved_pos - obstacle.global_position
		if absf(local.x) >= half_x or absf(local.y) >= half_y:
			continue

		var penetration_x: float = half_x - absf(local.x)
		var penetration_y: float = half_y - absf(local.y)
		if penetration_x < penetration_y:
			var sign_x: float = signf(local.x)
			local.x = half_x * (sign_x if not is_zero_approx(sign_x) else 1.0)
		else:
			var sign_y: float = signf(local.y)
			local.y = half_y * (sign_y if not is_zero_approx(sign_y) else 1.0)
		resolved_pos = obstacle.global_position + local
	return resolved_pos


## Vrátí až `count` nejbližších CÍLŮ v dosahu, seřazené od nejbližšího -
## SLOUČENÝ seznam nepřátel ("enemies" skupina) a zničitelných statických
## objektů ("destructibles" skupina, viz "Statické objekty ve světě" v
## CLAUDE.md, 2026-09-28) - řadí se dohromady podle vzdálenosti bez ohledu na
## typ, takže hráč přirozeně odstřelí i blízký objekt, když zrovna nemá jiný
## cíl. Nezničitelné objekty se do "destructibles" nikdy nezařadí (viz
## indestructible_object.gd), takže se sem vůbec nedostanou. Přejmenováno z
## dřívějšího _find_nearest_enemies() - stejné tělo, jen širší zdroj cílů.
## Kandidát, ke kterému nemá hráč přímou viditelnost (viz _has_line_of_sight()
## níže - úsečka hráč→cíl je zakrytá nezničitelným objektem), se do `in_range`
## vůbec nedostane, takže se řazením podle vzdálenosti automaticky "propadne"
## na dalšího nejbližšího VIDITELNÉHO kandidáta, žádná speciální náhradní
## logika není potřeba.
func _find_nearest_targets(count: int) -> Array:
	var in_range: Array = []
	var range_limit := get_attack_range()

	var candidates: Array = get_tree().get_nodes_in_group("enemies")
	candidates.append_array(get_tree().get_nodes_in_group("destructibles"))

	for candidate in candidates:
		if not is_instance_valid(candidate):
			continue
		var dist: float = global_position.distance_to(candidate.global_position)
		if dist <= range_limit and _has_line_of_sight(candidate.global_position):
			in_range.append({"node": candidate, "dist": dist})

	in_range.sort_custom(func(a, b): return a["dist"] < b["dist"])

	var result: Array = []
	for i in range(min(count, in_range.size())):
		result.append(in_range[i]["node"])
	return result


## True, pokud úsečka od hráče k `target_pos` neprotíná žádný NEZNIČITELNÝ
## statický objekt - zničitelné objekty ("destructibles" skupina) záměrně
## viditelnost nezakrývají, hráč tak nemůže "vidět skrz" jen tu jednu
## kategorii, na kterou nikdy nemůže zaútočit (viz explicit user request -
## cíl za nezničitelným objektem se má přeskočit, za zničitelným ne). Prochází
## celou "obstacles" skupinu a filtruje `is_in_group("destructibles")` místo
## vlastní druhé skupiny jen pro nezničitelné - obě existující scény už tenhle
## rozdíl jednoznačně nesou, není potřeba nic nového zavádět.
func _has_line_of_sight(target_pos: Vector2) -> bool:
	for obstacle in get_tree().get_nodes_in_group("obstacles"):
		if not is_instance_valid(obstacle):
			continue
		if obstacle.is_in_group("destructibles"):
			continue
		if _segment_intersects_square(global_position, target_pos, obstacle.global_position, obstacle.collision_half_size):
			return false
	return true


## Segment-vs-AABB test (slab method) - `from`/`to` je úsečka hráč→cíl,
## `center`/`half_size` je čtvercová kolizní oblast objektu (stejný tvar jako
## _resolve_obstacle_collisions() výše používá pro hráčovu vlastní kolizi,
## jen tady se testuje průnik s úsečkou, ne s bodem). Promítá úsečku na obě
## osy zvlášť jako parametrický interval [t_min, t_max] podél `from`→`to` a
## postupně ho zužuje o průnik s objektovým boxem na dané ose - pokud interval
## zůstane neprázdný (t_min <= t_max) po obou osách, úsečka box protíná.
func _segment_intersects_square(from: Vector2, to: Vector2, center: Vector2, half_size: float) -> bool:
	var box_min: Vector2 = center - Vector2(half_size, half_size)
	var box_max: Vector2 = center + Vector2(half_size, half_size)
	var dir: Vector2 = to - from
	var t_min: float = 0.0
	var t_max: float = 1.0

	for axis in range(2):
		if is_zero_approx(dir[axis]):
			if from[axis] < box_min[axis] or from[axis] > box_max[axis]:
				return false
			continue
		var t1: float = (box_min[axis] - from[axis]) / dir[axis]
		var t2: float = (box_max[axis] - from[axis]) / dir[axis]
		if t1 > t2:
			var tmp: float = t1
			t1 = t2
			t2 = tmp
		t_min = maxf(t_min, t1)
		t_max = minf(t_max, t2)
		if t_min > t_max:
			return false

	return true


func _shoot(target: Node2D) -> void:
	if projectile_scene == null:
		return
	var damage: float = get_damage() * _consume_ability_triggers()
	# Losuje se pro KAŽDÝ jednotlivý výstřel zvlášť (u multishotu tedy pro
	# každý projektil nezávisle) - stejná granularita jako
	# _consume_ability_triggers(). Násobí se AŽ NA konec, po schopnostech
	# jako "Dvojitý zásah" - crit a aktivní trigger multiplikátory se tak
	# stejně jako víc aktivních schopností navzájem násobí, ne sčítají.
	if randf() < get_crit_chance():
		damage *= CRIT_DAMAGE_MULTIPLIER
	var projectile: Node2D = projectile_scene.instantiate()
	get_tree().current_scene.add_child(projectile)
	projectile.global_position = global_position
	projectile.setup(damage, target)


## Každý zavolaný _shoot() je "1 výstřel" pro účely schopností s triggerem
## "shot_count" - u multishotu se tak počítá KAŽDÝ jednotlivý projektil
## zvlášť, ne jeden "kolo" útoku. **Kombinuje OBA souběžné zdroje** (viz
## "Schopnosti - DVA SOUBĚŽNÉ..." v game_manager.gd): dovednostní strom
## (`GameManager.skill_ranks`, nanejvýš 1 aktivní "instance" na ability_id,
## `_skill_progress`, práh podle `skill_trigger_values[rank-1]`) A schopnosti
## z náhodné nabídky (`GameManager.owned_abilities`, NEZÁVISLE stackující
## instance, `_ability_progress`, práh podle `trigger_values[rarity]`) - obě
## smyčky násobí do STEJNÉHO `multiplier`, takže např. dovednostní "Dvojitý
## zásah" na stupni 2 A 2 nezávislé Stříbrné kopie z nabídky mohou všechny
## tři spustit na stejném výstřelu a jejich násobiče se vynásobí dohromady.
## Přeskakuje pasivní schopnosti (nemají "trigger" klíč vůbec) - proto se
## kontroluje "type" jako první.
func _consume_ability_triggers() -> float:
	var multiplier: float = 1.0

	for ability_id in GameManager.skill_ranks:
		var rank: int = GameManager.get_skill_rank(ability_id)
		if rank <= 0:
			continue
		var definition: Dictionary = GameManager.ABILITIES[ability_id]
		if definition["type"] != "active" or definition["trigger"] != "shot_count":
			continue

		_skill_progress[ability_id] += 1.0
		var interval: int = definition["skill_trigger_values"][rank - 1]
		if _skill_progress[ability_id] >= interval:
			_skill_progress[ability_id] = 0.0
			if definition["effect"] == "damage_multiplier":
				multiplier *= float(definition["effect_params"]["multiplier"])

	for i in GameManager.owned_abilities.size():
		var entry: Dictionary = GameManager.owned_abilities[i]
		var definition: Dictionary = GameManager.ABILITIES[entry["ability_id"]]
		if definition["type"] != "active" or definition["trigger"] != "shot_count":
			continue

		_ability_progress[i] += 1.0
		var interval: int = definition["trigger_values"][entry["rarity"]]
		if _ability_progress[i] >= interval:
			_ability_progress[i] = 0.0
			if definition["effect"] == "damage_multiplier":
				multiplier *= float(definition["effect_params"]["multiplier"])

	return multiplier


## Časově spouštěné schopnosti (trigger "time_elapsed", např. "Orbitální
## bombardování") tikají KAŽDÝ frame nezávisle na střelbě/dosahu - na rozdíl
## od _consume_ability_triggers() (volané jen ze _shoot()) běží pořád, i když
## hráč zrovna nemá koho zasáhnout. Stejné dva souběžné zdroje jako výše, jen
## efekt ("aoe_strike") nevrací násobič, rovnou zasáhne nepřátele sám (viz
## _trigger_aoe_strike()).
func _process_time_based_abilities(delta: float) -> void:
	for ability_id in GameManager.skill_ranks:
		var rank: int = GameManager.get_skill_rank(ability_id)
		if rank <= 0:
			continue
		var definition: Dictionary = GameManager.ABILITIES[ability_id]
		if definition["type"] != "active" or definition["trigger"] != "time_elapsed":
			continue

		_skill_progress[ability_id] += delta
		var charge_time: float = float(definition["skill_trigger_values"][rank - 1])
		if _skill_progress[ability_id] >= charge_time:
			_skill_progress[ability_id] = 0.0
			if definition["effect"] == "aoe_strike":
				_trigger_aoe_strike(definition["effect_params"])

	for i in GameManager.owned_abilities.size():
		var entry: Dictionary = GameManager.owned_abilities[i]
		var definition: Dictionary = GameManager.ABILITIES[entry["ability_id"]]
		if definition["type"] != "active" or definition["trigger"] != "time_elapsed":
			continue

		_ability_progress[i] += delta
		var charge_time: float = float(definition["trigger_values"][entry["rarity"]])
		if _ability_progress[i] >= charge_time:
			_ability_progress[i] = 0.0
			if definition["effect"] == "aoe_strike":
				_trigger_aoe_strike(definition["effect_params"])


## "aoe_strike" zasáhne VŠECHNY živé nepřátele (ne jen okruh kolem hráče) -
## "screen-wide" efekt, viz ABILITIES["orbital_bombardment"] v game_manager.gd.
## Volá se přes take_damage(), stejně jako debug_skip_wave() v main.gd, aby
## zásah prošel normální odměnou/XP a double-kill-safe _is_dead pojistkou v
## enemy.gd, ne nějakou zkratkou kolem nich.
func _trigger_aoe_strike(effect_params: Dictionary) -> void:
	var damage: float = float(effect_params["damage"])
	for enemy in get_tree().get_nodes_in_group("enemies"):
		if is_instance_valid(enemy):
			enemy.take_damage(damage)
	_spawn_orbital_strike_effect()


func _spawn_orbital_strike_effect() -> void:
	if orbital_strike_effect_scene == null:
		return
	var effect: Node2D = orbital_strike_effect_scene.instantiate()
	get_tree().current_scene.add_child(effect)
	effect.global_position = global_position


## Kolik % původního poškození projde i přes libovolně vysoké brnění - brání
## tomu, aby naskládané brnění (base + pasivní schopnosti) udělalo hráče
## nezranitelným vůči budoucím silnějším typům zásahů. Plochý odečet níž
## je naopak záměrně bez podlahy pro NEGATIVNÍ hodnoty, takže proti slabým
## zásahům (řádově pod hodnotou brnění) může efektivní poškození klesnout
## skoro na tuhle podlahu.
const MIN_DAMAGE_RATIO: float = 0.1


func take_damage(amount: float) -> void:
	if GameManager.state != GameManager.State.PLAYING:
		return
	if debug_invincible:
		return
	var reduced_amount: float = maxf(amount - get_armor(), amount * MIN_DAMAGE_RATIO)
	# Ořez na nulu musí být před emitem - HUD ukazuje HP i číselně a jinak by
	# na okamžik problikla záporná hodnota
	hp = maxf(hp - reduced_amount, 0.0)
	hp_changed.emit(hp, max_hp)
	if hp <= 0:
		died.emit()
		GameManager.trigger_game_over()
