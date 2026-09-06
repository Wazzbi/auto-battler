extends Node2D
## Řídí spawnování nepřátel po vlnách. Samotný postup vln a odměny řeší
## GameManager - tady jen spawnujeme nepřátele a reagujeme na jeho signály.

@export var enemy_scene: PackedScene
@export var elite_enemy_scene: PackedScene
@export var enemies_base_count: int = 4
## Násobitel odmocninové křivky obtížnosti - růst je postupný, ne skokový
@export var difficulty_growth: float = 1.2
@export var spawn_interval: float = 1.2
## Jak daleko za pravým okrajem obrazovky se nepřátelé spawnují
@export var spawn_margin: float = 80.0
## Kolik nepřátel smí být živých najednou - brání přehlcení hráče v pozdějších vlnách
@export var max_concurrent_enemies: int = 6
## Kolik Elite nepřátel se přidá do poslední vlny (GameManager.FINAL_WAVE) navíc
## k běžnému počtu - spawnou se první, zbytek vlny doplní normální nepřátelé
@export var elite_count_final_wave: int = 1

@onready var player: Node2D = $Player
@onready var camera: Camera2D = $Player/Camera2D
@onready var hud: CanvasLayer = $HUD

var spawn_timer: float = 0.0
var enemies_left_to_spawn: int = 0
## Elite nepřátelé čekající na spawn - nenulové jen ve finální vlně (viz _on_wave_started)
var elites_left_to_spawn: int = 0


## Reset musí proběhnout v _enter_tree(), ne v _ready() - _ready() rodiče se volá
## až PO _ready() dětí, takže hráč i HUD by se stihly nastartovat se stavem
## z předchozí hry (po restartu přes reload_current_scene).
func _enter_tree() -> void:
	GameManager.reset_game()


func _ready() -> void:
	GameManager.wave_started.connect(_on_wave_started)
	GameManager.wave_cleared.connect(_on_wave_cleared)
	GameManager.game_over_triggered.connect(_on_game_over)
	GameManager.game_won_triggered.connect(_on_game_won)

	hud.connect_player(player)

	GameManager.start_next_wave()


func _process(delta: float) -> void:
	if GameManager.state != GameManager.State.PLAYING:
		return

	var total_left_to_spawn: int = enemies_left_to_spawn + elites_left_to_spawn
	if total_left_to_spawn > 0 and GameManager.enemies_alive < max_concurrent_enemies:
		spawn_timer -= delta
		if spawn_timer <= 0.0:
			_spawn_enemy()
			spawn_timer = spawn_interval


func _spawn_enemy() -> void:
	# Elite se ve finální vlně spawnou jako první, teprve pak normální nepřátelé.
	var scene_to_spawn: PackedScene = enemy_scene
	if elites_left_to_spawn > 0:
		scene_to_spawn = elite_enemy_scene
		elites_left_to_spawn -= 1
	else:
		enemies_left_to_spawn -= 1

	var enemy: Node2D = scene_to_spawn.instantiate()
	add_child(enemy)

	# Spawn vždy kousek za pravým okrajem aktuálního záběru kamery.
	# Kamera NENÍ vystředěná na hráči (je posunutá, aby hráč byl vlevo),
	# takže tady vycházíme z pozice kamery, ne z pozice hráče.
	var half_width: float = get_viewport().get_visible_rect().size.x / 2.0
	var spawn_x: float = camera.global_position.x + half_width + spawn_margin
	enemy.global_position = Vector2(spawn_x, player.global_position.y)

	GameManager.register_enemy_spawned()
	GameManager.enemies_remaining_to_spawn = enemies_left_to_spawn + elites_left_to_spawn


func _on_wave_started(wave_number: int) -> void:
	# Odmocninová křivka obtížnosti - roste postupně, ne lineárně/skokově.
	# Wave 1 = 4, wave 5 ≈ 6, wave 10 ≈ 7, wave 20 ≈ 9 nepřátel.
	enemies_left_to_spawn = enemies_base_count + int(floor(sqrt(wave_number - 1) * difficulty_growth))
	elites_left_to_spawn = elite_count_final_wave if (
		wave_number == GameManager.FINAL_WAVE and elite_enemy_scene != null
	) else 0
	GameManager.enemies_remaining_to_spawn = enemies_left_to_spawn + elites_left_to_spawn
	spawn_timer = 0.0


func _on_wave_cleared(wave_number: int) -> void:
	hud.show_wave_cleared_message(wave_number)


func _on_game_over() -> void:
	hud.show_game_over(GameManager.current_wave, GameManager.currency)


func _on_game_won() -> void:
	hud.show_victory(GameManager.currency)
