extends Node2D
## Řídí spawnování nepřátel po vlnách. Samotný postup vln a odměny řeší
## GameManager - tady jen spawnujeme nepřátele a reagujeme na jeho signály.

@export var enemy_scene: PackedScene
@export var elite_enemy_scene: PackedScene
@export var ranged_enemy_scene: PackedScene
## Pravděpodobnost, že se dálkový nepřítel objeví místo normálního při
## běžném spawnu z fronty vlny (Elite frontu neovlivňuje - ta má vlastní
## pořadí, viz _spawn_enemy())
@export var ranged_enemy_chance: float = 0.3
@export var sniper_enemy_scene: PackedScene
## Nižší než ranged_enemy_chance - sniper (dostřel přes hráčův attack_range)
## je vzácnější a nebezpečnější varianta, ne běžná náhrada za normálního nepřítele
@export var sniper_enemy_chance: float = 0.15
## Do téhle vlny (v 1. kole) se ranged/sniper nepřátelé vůbec neobjevují -
## viz _variant_chance_multiplier(). Bez rozjezdu umírali noví hráči často
## už ve vlně 1-2, dřív než stihli zabít jediného nepřítele (ranged/sniper
## dávají poškození zdarma z bezpečné vzdálenosti, na kterou hráč na začátku
## nemá dosah ani itemy).
@export var variant_ramp_start_wave: int = 3
## Od téhle vlny (v 1. kole) mají ranged_enemy_chance/sniper_enemy_chance
## svou plnou nakonfigurovanou hodnotu - mezi start a full lineárně narůstá.
@export var variant_ramp_full_wave: int = 7
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
@onready var camera: Camera2D = $Camera2D
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
	hud.connect_main(self)

	# Kamera je nezávislý uzel (viz camera_follow.gd) - hráč jí nic nepředává
	# přímo, jen emituje signály a Main je propojuje.
	camera.set_target(player)
	player.landed.connect(camera.shake)

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
		# Jeden společný hod rozhoduje mezi variantami - nezávislé hody by se
		# mohly obě "trefit" najednou a bez smyslu upřednostnit tu poslední
		# zkontrolovanou podmínku.
		var roll: float = randf()
		var variant_multiplier: float = _variant_chance_multiplier()
		var effective_sniper_chance: float = sniper_enemy_chance * variant_multiplier
		var effective_ranged_chance: float = ranged_enemy_chance * variant_multiplier
		if sniper_enemy_scene != null and roll < effective_sniper_chance:
			scene_to_spawn = sniper_enemy_scene
		elif ranged_enemy_scene != null and roll < effective_sniper_chance + effective_ranged_chance:
			scene_to_spawn = ranged_enemy_scene

	_spawn_at_edge(scene_to_spawn)
	GameManager.enemies_remaining_to_spawn = enemies_left_to_spawn + elites_left_to_spawn


## Vytvoří a umístí nepřítele kousek za pravým okrajem aktuálního záběru
## kamery. Sdílené jádro pro běžné spawnování z fronty vlny i pro
## debug_spawn_elite() - obě cesty musí dopadnout stejně (naškálované HP,
## správně zapsaný GameManager.enemies_alive).
func _spawn_at_edge(scene: PackedScene) -> Node2D:
	var enemy: Node2D = scene.instantiate()
	# Musí se stát PŘED add_child() - enemy.gd nastavuje hp = max_hp ve svém
	# _ready(), který proběhne synchronně při vstupu do stromu.
	enemy.max_hp *= GameManager.get_enemy_hp_multiplier()
	add_child(enemy)

	# Kamera NENÍ vystředěná na hráči (je posunutá, aby hráč byl vlevo),
	# takže tady vycházíme z pozice kamery, ne z pozice hráče.
	var half_width: float = get_viewport().get_visible_rect().size.x / 2.0
	var spawn_x: float = camera.global_position.x + half_width + spawn_margin
	enemy.global_position = Vector2(spawn_x, player.global_position.y)

	GameManager.register_enemy_spawned()
	return enemy


## Násobitel 0-1 pro ranged_enemy_chance/sniper_enemy_chance - lineárně roste
## od variant_ramp_start_wave (0) do variant_ramp_full_wave (1). Platí JEN
## v 1. kole (loop_count == 1) - od 2. kola dál je vždy plný, protože hráč
## už jednou rozjezdem prošel a má z předchozího kola úroveň i itemy, takže
## další "měkký start" by jen zbytečně zjednodušil endless škálování.
func _variant_chance_multiplier() -> float:
	if GameManager.loop_count > 1:
		return 1.0
	if GameManager.current_wave < variant_ramp_start_wave:
		return 0.0
	if GameManager.current_wave >= variant_ramp_full_wave:
		return 1.0
	var span: int = variant_ramp_full_wave - variant_ramp_start_wave
	return float(GameManager.current_wave - variant_ramp_start_wave) / float(span)


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


# --- Debug panel ---------------------------------------------------------

## DEBUG: okamžitě dobije všechny živé nepřátele (přes jejich normální
## take_damage(), aby dostali odměnu/XP stejnou cestou jako v běžné hře) a
## vyprázdní frontu zbytku vlny. Pokud v tu chvíli náhodou nikdo naživu
## nebyl (např. mezi vlnami), smrt posledního nepřítele wave-clear sama
## nevyvolá - o to se pak postará GameManager.debug_force_wave_clear().
func debug_skip_wave() -> void:
	var had_enemies_alive: bool = GameManager.enemies_alive > 0

	enemies_left_to_spawn = 0
	elites_left_to_spawn = 0
	GameManager.enemies_remaining_to_spawn = 0

	for enemy in get_tree().get_nodes_in_group("enemies"):
		if is_instance_valid(enemy):
			enemy.take_damage(999999.0)

	if not had_enemies_alive:
		GameManager.debug_force_wave_clear()


## DEBUG: spawne jednoho Elite nepřítele na vyžádání, mimo běžnou frontu vln
func debug_spawn_elite() -> void:
	if elite_enemy_scene != null:
		_spawn_at_edge(elite_enemy_scene)


## DEBUG: spawne jednoho dálkového nepřítele na vyžádání, mimo běžnou frontu vln
func debug_spawn_ranged_enemy() -> void:
	if ranged_enemy_scene != null:
		_spawn_at_edge(ranged_enemy_scene)


## DEBUG: spawne jednoho snipera na vyžádání, mimo běžnou frontu vln
func debug_spawn_sniper_enemy() -> void:
	if sniper_enemy_scene != null:
		_spawn_at_edge(sniper_enemy_scene)
