extends Node2D
## Řídí KONTINUÁLNÍ spawnování nepřátel (top-down pivot 2026-09-27, Fáze 6 -
## dřív po diskrétních vlnách/kolech, viz STALE poznámky u GameManager).
## Neexistuje žádná "vlna" ani fronta k vyprázdnění - místo toho se každý
## snímek porovnává GameManager.enemies_alive s cílovým počtem podle
## GameManager.survival_time (_get_target_concurrent_count()) a chybějící
## se doplňují přes spawn_timer/spawn_interval, stejně jako dřív v rámci
## jedné vlny. Samotné odměny/progrese řeší GameManager - tady jen
## spawnujeme nepřátele.

@export var enemy_scene: PackedScene
@export var elite_enemy_scene: PackedScene
@export var ranged_enemy_scene: PackedScene
## Pravděpodobnost, že se dálkový nepřítel objeví místo normálního při
## běžném spawnu (Elite se touhle logikou neřídí - ta má vlastní frontu,
## viz _spawn_enemy())
@export var ranged_enemy_chance: float = 0.3
@export var sniper_enemy_scene: PackedScene
## Nižší než ranged_enemy_chance - sniper (dostřel přes hráčův attack_range)
## je vzácnější a nebezpečnější varianta, ne běžná náhrada za normálního nepřítele
@export var sniper_enemy_chance: float = 0.15
## Do téhle chvíle (sekundy reálného přežití od startu běhu) se ranged/sniper
## nepřátelé vůbec neobjevují - viz _variant_chance_multiplier(). Bez
## rozjezdu umírali noví hráči často už v první minutě, dřív než stihli
## zabít jediného nepřítele (ranged/sniper dávají poškození zdarma z
## bezpečné vzdálenosti, na kterou hráč na začátku nemá dosah ani itemy).
## PRVNÍ ODHAD čísla (dřív to byly čísla vln 3/7, teď čas - nepřevedeno 1:1,
## jen podle stejného DUCHU "pár prvních okamžiků žádné, pak rozjezd").
@export var variant_ramp_start_time: float = 30.0
## Od téhle chvíle mají ranged_enemy_chance/sniper_enemy_chance svou plnou
## nakonfigurovanou hodnotu - mezi start a full lineárně narůstá. Platí VŽDY
## (ne jen "první kolo" jako dřív - bez kol není vůči čemu tu výjimku dělat,
## viz _variant_chance_multiplier()).
@export var variant_ramp_full_time: float = 90.0
@export var enemies_base_count: int = 4
## Násobitel odmocninové křivky obtížnosti - růst je postupný, ne skokový
@export var difficulty_growth: float = 1.2
## Kolik sekund reálného přežití odpovídá jedné "vlně" staré křivky
## (enemies_base_count + sqrt((survival_time/seconds_per_wave_equivalent) *
## difficulty_growth)) - PRVNÍ ODHAD, žádný přesný převod neexistuje (stará
## dálka vlny závisela na tom, jak rychle hráč zabíjel).
@export var seconds_per_wave_equivalent: float = 20.0
@export var spawn_interval: float = 1.2
## Jak daleko za viditelným okrajem obrazovky (v libovolném směru od hráče,
## viz _spawn_around_player()) se nepřátelé spawnují
@export var spawn_margin: float = 80.0
## Kolik nepřátel smí být živých najednou - brání přehlcení hráče
@export var max_concurrent_enemies: int = 6
## Kolik Elite nepřátel se spawne na každém časovém checkpointu (viz
## elite_checkpoints_seconds níže)
@export var elite_count_per_checkpoint: int = 1
## Časové značky (sekundy reálného přežití), na kterých se spawnou Elite
## nepřátelé - nahrazuje dřívější "jen na 10. vlně". PRVNÍ ODHAD (každé 3
## minuty), needoladěné hraním.
@export var elite_checkpoints_seconds: Array[float] = [180.0, 360.0, 540.0, 720.0, 900.0]
## Scéna zeleného kosočtverce (viz "Schopnosti na základě zabití" v
## CLAUDE.md) - main.gd ho spawne na místě smrti nepřítele, který překročil
## další práh zabití (GameManager.ability_pickup_dropped), stejně jako
## spawnuje nepřátele - vlastní scénu/pozici, GameManager jen řekne KDY a KDE.
@export var ability_pickup_scene: PackedScene

@onready var player: Node2D = $Player
@onready var camera: Camera2D = $Camera2D
@onready var hud: CanvasLayer = $HUD

var spawn_timer: float = 0.0
## Elite nepřátelé čekající na spawn - naplní se, jakmile survival_time
## překročí další nekonzumovaný checkpoint (viz _check_elite_checkpoints()).
var elites_left_to_spawn: int = 0
## Kolik prvků elite_checkpoints_seconds už bylo spotřebováno - INDEX
## do pole, ne časová hodnota (viz _check_elite_checkpoints()).
var _elite_checkpoints_consumed: int = 0


## Reset musí proběhnout v _enter_tree(), ne v _ready() - _ready() rodiče se volá
## až PO _ready() dětí, takže hráč i HUD by se stihly nastartovat se stavem
## z předchozí hry (po restartu přes reload_current_scene).
func _enter_tree() -> void:
	GameManager.reset_game()


func _ready() -> void:
	GameManager.game_over_triggered.connect(_on_game_over)
	GameManager.game_won_triggered.connect(_on_game_won)
	GameManager.ability_pickup_dropped.connect(_on_ability_pickup_dropped)

	hud.connect_player(player)
	hud.connect_main(self)

	# Kamera je nezávislý uzel (viz camera_follow.gd) - hráč jí nic nepředává
	# přímo, jen emituje signály a Main je propojuje.
	camera.set_target(player)
	player.landed.connect(camera.shake)


func _process(delta: float) -> void:
	if GameManager.state != GameManager.State.PLAYING:
		return

	_check_elite_checkpoints()

	var should_spawn: bool = (
		elites_left_to_spawn > 0
		or GameManager.enemies_alive < mini(_get_target_concurrent_count(), max_concurrent_enemies)
	)
	if should_spawn:
		spawn_timer -= delta
		if spawn_timer <= 0.0:
			_spawn_enemy()
			spawn_timer = spawn_interval


## Odmocninová křivka obtížnosti proti UPLYNULÉMU ČASU místo čísla vlny (top-down
## pivot Fáze 6) - stejný TVAR růstu jako dřív (postupný, ne skokový), jen jiná
## osa X. Vrací, kolik nepřátel by mělo být živých najednou PRÁVĚ TEĎ (ne kolik
## jich ještě zbývá spawnout - žádná fronta k vyprázdnění už neexistuje).
func _get_target_concurrent_count() -> int:
	var wave_equivalent: float = GameManager.survival_time / seconds_per_wave_equivalent
	return enemies_base_count + int(floor(sqrt(wave_equivalent) * difficulty_growth))


## Jakmile survival_time překročí další nekonzumovaný prvek
## elite_checkpoints_seconds, přidá elite_count_per_checkpoint Elite nepřátel
## do fronty (spawnou se přednostně, viz _spawn_enemy()). Kontroluje jen
## JEDEN checkpoint za snímek přes _elite_checkpoints_consumed jako index -
## i kdyby hra běžela extrémně rychle (Engine.time_scale v Debug panelu),
## checkpointy se spotřebují postupně, ne všechny najednou.
func _check_elite_checkpoints() -> void:
	if elite_enemy_scene == null:
		return
	while (
		_elite_checkpoints_consumed < elite_checkpoints_seconds.size()
		and GameManager.survival_time >= elite_checkpoints_seconds[_elite_checkpoints_consumed]
	):
		elites_left_to_spawn += elite_count_per_checkpoint
		_elite_checkpoints_consumed += 1


func _spawn_enemy() -> void:
	# Elite se spawnou přednostně, jakmile je fronta neprázdná (viz
	# _check_elite_checkpoints()), teprve pak normální/variantní nepřátelé.
	var scene_to_spawn: PackedScene = enemy_scene
	if elites_left_to_spawn > 0:
		scene_to_spawn = elite_enemy_scene
		elites_left_to_spawn -= 1
	else:
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

	_spawn_around_player(scene_to_spawn)


## Vytvoří a umístí nepřítele na náhodné místo na kruhu kolem hráče, těsně
## mimo viditelnou obrazovku (top-down pivot 2026-09-27, dřív vždy kousek za
## pravým okrajem kamery). Poloměr = polovina DIAGONÁLY viewportu + spawn_margin
## - půl-šířka by nestačila, protože v "rohových" úhlech (blízko nahoře/dole)
## by spawn bod pořád ležel uvnitř viditelné oblasti; půl-diagonála zaručí
## spawn mimo obrazovku bez ohledu na úhel. Sdílené jádro pro běžné spawnování
## z fronty vlny i pro debug_spawn_elite()/_ranged_enemy()/_sniper_enemy() -
## všechny cesty musí dopadnout stejně (naškálované HP, správně zapsaný
## GameManager.enemies_alive) - signatura je stejná jako dřív
## (PackedScene in, Node2D out), takže žádné volací místo se nemuselo měnit.
func _spawn_around_player(scene: PackedScene) -> Node2D:
	var enemy: Node2D = scene.instantiate()
	# Musí se stát PŘED add_child() - enemy.gd nastavuje hp = max_hp ve svém
	# _ready(), který proběhne synchronně při vstupu do stromu.
	enemy.max_hp *= GameManager.get_enemy_hp_multiplier()
	add_child(enemy)

	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	var min_radius: float = viewport_size.length() / 2.0 + spawn_margin
	var angle: float = randf() * TAU
	enemy.global_position = player.global_position + Vector2.RIGHT.rotated(angle) * min_radius

	GameManager.register_enemy_spawned()
	return enemy


## Násobitel 0-1 pro ranged_enemy_chance/sniper_enemy_chance - lineárně roste
## od variant_ramp_start_time (0) do variant_ramp_full_time (1) sekund
## reálného přežití. Platí VŽDY teď (dřív jen "1. kolo" - bez kol není vůči
## čemu tu výjimku dělat, viz vars výše).
func _variant_chance_multiplier() -> float:
	if GameManager.survival_time < variant_ramp_start_time:
		return 0.0
	if GameManager.survival_time >= variant_ramp_full_time:
		return 1.0
	var span: float = variant_ramp_full_time - variant_ramp_start_time
	return (GameManager.survival_time - variant_ramp_start_time) / span


func _on_game_over() -> void:
	hud.show_game_over(GameManager.survival_time, GameManager.currency)


func _on_game_won() -> void:
	hud.show_victory(GameManager.currency)


## Zavolá GameManager.enemy_defeated(), když zabitý nepřítel překročí další
## kumulativní práh zabití (viz "Schopnosti na základě zabití" v CLAUDE.md) -
## spawne zelený kosočtverec na místě smrti. Samotné vyžádání nabídky
## (GameManager.request_ability_offer()) proběhne až při sebrání, viz
## ability_pickup.gd.
func _on_ability_pickup_dropped(position: Vector2) -> void:
	if ability_pickup_scene == null:
		return
	var pickup: Node2D = ability_pickup_scene.instantiate()
	add_child(pickup)
	pickup.global_position = position


# --- Debug panel ---------------------------------------------------------

## DEBUG: okamžitě dobije všechny živé nepřátele (přes jejich normální
## take_damage(), aby dostali odměnu/XP stejnou cestou jako v běžné hře).
## Nahrazuje dřívější debug_skip_wave() - bez vln nemá "přeskočit vlnu"
## smysl, tohle je čistě "vyčisti obrazovku" pro rychlé testování; nový
## spawn okamžitě doplní chybějící počet podle _get_target_concurrent_count().
func debug_kill_all_enemies() -> void:
	elites_left_to_spawn = 0
	for enemy in get_tree().get_nodes_in_group("enemies"):
		if is_instance_valid(enemy):
			enemy.take_damage(999999.0)


## DEBUG: spawne jednoho Elite nepřítele na vyžádání, mimo běžnou frontu vln
func debug_spawn_elite() -> void:
	if elite_enemy_scene != null:
		_spawn_around_player(elite_enemy_scene)


## DEBUG: spawne jednoho dálkového nepřítele na vyžádání, mimo běžnou frontu vln
func debug_spawn_ranged_enemy() -> void:
	if ranged_enemy_scene != null:
		_spawn_around_player(ranged_enemy_scene)


## DEBUG: spawne jednoho snipera na vyžádání, mimo běžnou frontu vln
func debug_spawn_sniper_enemy() -> void:
	if sniper_enemy_scene != null:
		_spawn_around_player(sniper_enemy_scene)
