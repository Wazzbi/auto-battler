extends Node2D
## Hráčova postava. Pokud má nepřítele v dosahu, stojí na místě a střílí.
## Jinak postupuje doprava směrem ke konci levelu.
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
@export var move_speed: float = 60.0 # px/s postupu, když nikdo není v dosahu
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
## X pozice konce levelu - najde se automaticky přes uzel ve skupině "level_end".
## Level01 už žádný takový marker nemá (level je bezkonečný), takže tohle
## zůstává na výchozím INF a pohyb hráče se nikdy neomezí - viz CLAUDE.md.
var level_end_x: float = INF
## DEBUG: dokud je zapnuté, take_damage() nic neudělá. Ovládá se z Debug
## panelu v HUD (viz hud.gd), na resetu hry (nová instance hráče) se sama
## vrátí na false.
var debug_invincible: bool = false
## Postup KAŽDÉ vlastněné AKTIVNÍ schopnosti (viz GameManager.owned_abilities)
## směrem k jejímu dalšímu spuštění - stejný index/pořadí jako owned_abilities.
## Jednotka závisí na triggeru té konkrétní instance: "shot_count" počítá
## celočíselně výstřely (viz _consume_ability_triggers()), "time_elapsed"
## počítá sekundy (viz _process_time_based_abilities()) - float, aby šlo
## přičítat `delta`. Přebuduje se od nuly při KAŽDÉ změně vlastnictví
## (_on_ability_inventory_changed()), i jen kosmetické (sloučení, nebo přidání
## úplně jiné schopnosti) - vědomý kompromis: sloučená schopnost tak ztratí
## rozpracovaný postup ke svému příštímu spuštění, ale instance v poli nemají
## stabilní identitu napříč sloučeními, takže "zachovat postup" by
## vyžadovalo sledovat identitu navíc jen pro tenhle okrajový případ.
var _ability_progress: Array[float] = []


func _ready() -> void:
	add_to_group("player")

	# Progrese (úrovně, pasivní schopnosti, nákupy v obchodě) mění staty za
	# běhu - reagujeme na všechny tři signály, HUD do statů hráče nikdy
	# nesahá přímo.
	GameManager.level_changed.connect(_on_level_changed)
	GameManager.shop_inventory_changed.connect(_on_shop_inventory_changed)
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


func _on_landed() -> void:
	_spawn_impact_effect()
	landed.emit()
	_play_squash_effect()
	GameManager.finish_intro()


func _spawn_impact_effect() -> void:
	if impact_effect_scene == null:
		return
	var effect: Node2D = impact_effect_scene.instantiate()
	get_tree().current_scene.add_child(effect)
	effect.global_position = global_position


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


func _on_level_changed(_new_level: int) -> void:
	_apply_progression_changes()


func _on_shop_inventory_changed() -> void:
	_apply_progression_changes()


## Pasivní schopnosti mění staty (přes get_stat_bonus()), aktivní ne - ale
## obojí sdílí owned_abilities/_ability_progress, takže se přepočítává
## a přerovnává vždy, i pro čistě aktivní přírůstek.
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

	cooldown_timer -= delta
	var targets := _find_nearest_enemies(get_target_count())

	if not targets.is_empty():
		# Aspoň jeden nepřítel v dosahu - zastav se a střílej
		if cooldown_timer <= 0.0:
			for target in targets:
				_shoot(target)
			cooldown_timer = 1.0 / max(get_attack_speed(), 0.01)
	else:
		# Nikdo v dosahu - postupuj dál k cíli levelu. level_end_x je teď jen
		# vizuální strop pohybu - výhra se váže na dokončení GameManager.FINAL_WAVE,
		# ne na dosažení konce mapy (viz GameManager._on_wave_cleared()).
		if global_position.x < level_end_x:
			global_position.x = min(global_position.x + move_speed * delta, level_end_x)


## Vrátí až `count` nejbližších nepřátel v dosahu, seřazené od nejbližšího.
func _find_nearest_enemies(count: int) -> Array:
	var in_range: Array = []
	var range_limit := get_attack_range()

	for enemy in get_tree().get_nodes_in_group("enemies"):
		if not is_instance_valid(enemy):
			continue
		var dist: float = global_position.distance_to(enemy.global_position)
		if dist <= range_limit:
			in_range.append({"node": enemy, "dist": dist})

	in_range.sort_custom(func(a, b): return a["dist"] < b["dist"])

	var result: Array = []
	for i in range(min(count, in_range.size())):
		result.append(in_range[i]["node"])
	return result


func _shoot(target: Node2D) -> void:
	if projectile_scene == null:
		return
	var damage: float = get_damage() * _consume_ability_triggers()
	var projectile: Node2D = projectile_scene.instantiate()
	get_tree().current_scene.add_child(projectile)
	projectile.global_position = global_position
	projectile.setup(damage, target)


## Každý zavolaný _shoot() je "1 výstřel" pro účely schopností s triggerem
## "shot_count" - u multishotu se tak počítá KAŽDÝ jednotlivý projektil
## zvlášť, ne jeden "kolo" útoku. Pro každou vlastněnou AKTIVNÍ schopnost s
## tímhle triggerem zvýší JEJÍ VLASTNÍ postup (viz _ability_progress) a při
## dosažení prahu (podle rarity té konkrétní instance) ho vynuluje a
## aplikuje efekt. Víc vlastněných instancí se vyhodnocuje NEZÁVISLE - pokud
## by dvě spustily efekt na stejném výstřelu, jejich násobiče se navzájem
## vynásobí (ne sečtou), proto vrací násobič přes návratovou hodnotu místo
## přímé úpravy get_damage(). Přeskakuje pasivní schopnosti (nemají "trigger"
## klíč vůbec) - proto se kontroluje "type" jako první.
func _consume_ability_triggers() -> float:
	var multiplier: float = 1.0
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
## hráč zrovna nemá koho zasáhnout. Stejný nezávislý-víc-instancí princip
## jako u shot_count (viz výše), jen efekt ("aoe_strike") nevrací násobič,
## rovnou zasáhne nepřátele sám (viz _trigger_aoe_strike()).
func _process_time_based_abilities(delta: float) -> void:
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
