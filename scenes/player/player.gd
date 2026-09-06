extends Node2D
## Hráčova postava. Pokud má nepřítele v dosahu, stojí na místě a střílí.
## Jinak postupuje doprava směrem ke konci levelu. Kamera je child node
## tohoto uzlu s vodorovným odsazením, takže hráč zůstává poblíž levého
## okraje obrazovky (ne uprostřed) a je vidět, jak level okolo něj ubíhá.
##
## Na startu hry proběhne krátká "drop-in" animace - postava spadne na
## svou pozici shora jako z vesmírné výsadkové kapsle. Dokud animace
## neskončí, je hra ve stavu GameManager.State.INTRO a žádná herní
## logika (spawn, pohyb, útoky) neběží.

signal hp_changed(current_hp: float, max_hp: float)
signal died

@export var base_max_hp: float = 100.0
@export var base_damage: float = 10.0
@export var base_attack_speed: float = 1.0 # útoků za sekundu
@export var base_attack_range: float = 400.0
@export var move_speed: float = 60.0 # px/s postupu, když nikdo není v dosahu
@export var projectile_scene: PackedScene
@export var impact_effect_scene: PackedScene
## Kolik px od levého okraje obrazovky má hráč zůstat
@export var camera_left_margin: float = 220.0

## Nastavení drop-in animace
@export var fall_height: float = 900.0
@export var fall_duration: float = 0.55
@export var fall_tilt_degrees: float = -10.0

@onready var camera: Camera2D = $Camera2D
@onready var visual: Polygon2D = $Polygon2D

var max_hp: float
var hp: float
var cooldown_timer: float = 0.0
## X pozice konce levelu - najde se automaticky přes uzel ve skupině "level_end"
var level_end_x: float = INF


func _ready() -> void:
	add_to_group("player")
	# Progrese (úrovně, ranky schopností) mění staty za běhu - reagujeme na oba
	# signály, HUD do statů hráče nikdy nesahá přímo.
	GameManager.level_changed.connect(_on_level_changed)
	GameManager.ability_rank_changed.connect(_on_ability_rank_changed)

	_recalculate_stats()
	hp = max_hp
	hp_changed.emit(hp, max_hp)

	var end_marker := get_tree().get_first_node_in_group("level_end")
	if end_marker != null:
		level_end_x = end_marker.global_position.x

	_update_camera_offset()
	get_viewport().size_changed.connect(_update_camera_offset)

	_play_drop_in_animation()


func _update_camera_offset() -> void:
	var viewport_width: float = get_viewport().get_visible_rect().size.x
	camera.position.x = (viewport_width / 2.0) - camera_left_margin


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
	_shake_camera()
	_play_squash_effect()
	GameManager.finish_intro()


func _spawn_impact_effect() -> void:
	if impact_effect_scene == null:
		return
	var effect: Node2D = impact_effect_scene.instantiate()
	get_tree().current_scene.add_child(effect)
	effect.global_position = global_position


func _shake_camera(strength: float = 10.0, duration: float = 0.22) -> void:
	var steps := 6
	var shake_tween := create_tween()
	for i in range(steps):
		var offset := Vector2(randf_range(-strength, strength), randf_range(-strength, strength))
		shake_tween.tween_property(camera, "offset", offset, duration / steps)
	shake_tween.tween_property(camera, "offset", Vector2.ZERO, duration / steps)


func _play_squash_effect() -> void:
	var squash_tween := create_tween()
	squash_tween.tween_property(visual, "scale", Vector2(1.35, 0.65), 0.08)
	squash_tween.tween_property(visual, "scale", Vector2.ONE, 0.15)


## Přepočítá staty na základě base hodnot + bonusů za úrovně a schopnosti.
## Přírůstek max HP se přičte i k aktuálnímu HP, takže level-up trochu vyléčí.
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


## Kolik cílů hráč zasáhne najednou (1 + bonus ze schopnosti Salva)
func get_target_count() -> int:
	return 1 + int(GameManager.get_stat_bonus("multishot"))


func _on_level_changed(_new_level: int) -> void:
	_apply_progression_changes()


func _on_ability_rank_changed(_ability_id: String, _new_rank: int) -> void:
	_apply_progression_changes()


func _apply_progression_changes() -> void:
	_recalculate_stats()
	hp_changed.emit(hp, max_hp)


func _process(delta: float) -> void:
	if GameManager.state != GameManager.State.PLAYING:
		return

	cooldown_timer -= delta
	var targets := _find_nearest_enemies(get_target_count())

	if not targets.is_empty():
		# Aspoň jeden nepřítel v dosahu - zastav se a střílej
		if cooldown_timer <= 0.0:
			for target in targets:
				_shoot(target)
			cooldown_timer = 1.0 / max(get_attack_speed(), 0.01)
	else:
		# Nikdo v dosahu - postupuj dál k cíli levelu
		if global_position.x < level_end_x:
			global_position.x += move_speed * delta
		if global_position.x >= level_end_x:
			GameManager.trigger_win()


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
	var projectile: Node2D = projectile_scene.instantiate()
	get_tree().current_scene.add_child(projectile)
	projectile.global_position = global_position
	projectile.setup(get_damage(), target)


func take_damage(amount: float) -> void:
	if GameManager.state != GameManager.State.PLAYING:
		return
	# Ořez na nulu musí být před emitem - HUD ukazuje HP i číselně a jinak by
	# na okamžik problikla záporná hodnota
	hp = maxf(hp - amount, 0.0)
	hp_changed.emit(hp, max_hp)
	if hp <= 0:
		died.emit()
		GameManager.trigger_game_over()
