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
## minuty), needoladěné hraním. STALE poznámka (2026-09-27, "Lobby a
## meta-progrese"): s loop_duration_seconds = 180.0 (viz níže) se běh teď
## typicky ukončí kolem prvního prvku - druhý a další prakticky nikdy
## nepřijdou na řadu v rámci jednoho běhu. Známý follow-up pro balancování,
## neblokující pro tenhle PR.
@export var elite_checkpoints_seconds: Array[float] = [180.0, 360.0, 540.0, 720.0, 900.0]
## Po kolika sekundách reálného přežití se běh považuje za DOKONČENÝ (viz
## _check_loop_completion() níže) - main.gd na to zavolá GameManager.
## trigger_win(), který přes _finish_run() převede vydělané run-XP na trvalé
## meta-XP a přesune hráče do lobby (scenes/ui/lobby.tscn). PRVNÍ ODHAD (3
## minuty), needoladěné hraním - viz "Lobby a meta-progrese" v CLAUDE.md
## (2026-09-27).
@export var loop_duration_seconds: float = 180.0

## Statické objekty ve světě (viz "Statické objekty ve světě" v CLAUDE.md,
## 2026-09-28) - placeholdery pro budoucí smysluplnější objekty, náhodně
## rozmisťované kolem hráče stejným ring-spawn mechanismem jako nepřátelé
## (viz _random_position_around_player()). Zničitelné (hnědé) mají HP a hráč
## je zničí běžnou střelbou; nezničitelné (šedé) jsou trvalé překážky. Obojí
## učí nepřátele objekty obcházet (viz enemy.gd's _avoid_obstacles()).
@export var destructible_object_scene: PackedScene
@export var indestructible_object_scene: PackedScene
@export var destructible_spawn_interval: float = 8.0
## Vzácnější než destructible_spawn_interval - nezničitelné objekty jsou
## trvalé záchytné body ve světě, ne běžná kulisa.
@export var indestructible_spawn_interval: float = 15.0
## Měkký strop na CELKOVÝ počet KDY spawnutých objektů za běh (ne aktuálně
## živých) - zničení zničitelného objektu neuvolní nový slot, stejná
## jednosměrná jednoduchost jako elites_left_to_spawn níže. PRVNÍ ODHAD,
## needoladěné hraním.
@export var max_destructibles: int = 40
@export var max_indestructibles: int = 20
## Stejný účel jako spawn_margin u nepřátel - jak daleko za viditelným
## okrajem obrazovky se objekty spawnují.
@export var object_spawn_margin: float = 60.0
## Minimální extra odstup (navíc k součtu obou objektů collision_half_size/
## pickup_radius) mezi nově spawnutým statickým objektem/pickupem a každým
## už existujícím obstaclem - viz _is_position_clear_of_obstacles() níže.
## Opraveno 2026-10-01 na žádost uživatele (screenshot ukázal zničitelný
## objekt vygenerovaný přímo na nezničitelném) - dřív se tahle kontrola
## vůbec neprováděla (CLAUDE.md to dokumentoval jako vědomé zjednodušení
## pro první verzi, teď dotažené).
@export var object_spacing_margin: float = 10.0
## Kolikrát _spawn_world_object() zkusí novou náhodnou pozici, než spawn
## tenhle cyklus prostě přeskočí - radši chybějící spawn (doplní se příští
## interval) než garantovaně překrývající se objekt.
const MAX_SPAWN_POSITION_ATTEMPTS: int = 10

## Sebratelné předměty (kosočtverce, viz "Sebratelné předměty" v CLAUDE.md) -
## spawnují se stejným ring-spawn mechanismem jako výše, ale strop
## (max_heal_pickups/max_speed_pickups) se NA ROZDÍL od destructible/
## indestructible objektů kontroluje proti AKTUÁLNĚ ŽIVÉMU počtu
## ("heal_pickups"/"speed_pickups" skupiny), ne proti celkovému součtu za
## běh - sebrání kosočtverce uvolní slot pro další, protože jde o průběžně
## spotřebovávaný zdroj, ne trvalý placeholder.
@export var heal_pickup_scene: PackedScene
@export var speed_pickup_scene: PackedScene
@export var heal_pickup_spawn_interval: float = 10.0
@export var speed_pickup_spawn_interval: float = 18.0
@export var max_heal_pickups: int = 5
@export var max_speed_pickups: int = 3

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

var _destructible_spawn_timer: float = 0.0
var _indestructible_spawn_timer: float = 0.0
var _destructibles_spawned: int = 0
var _indestructibles_spawned: int = 0

var _heal_pickup_spawn_timer: float = 0.0
var _speed_pickup_spawn_timer: float = 0.0


## Reset musí proběhnout v _enter_tree(), ne v _ready() - _ready() rodiče se volá
## až PO _ready() dětí, takže hráč i HUD by se stihly nastartovat se stavem
## z předchozí hry (po restartu přes reload_current_scene).
func _enter_tree() -> void:
	GameManager.reset_game()


func _ready() -> void:
	GameManager.game_over_triggered.connect(_on_game_over)
	GameManager.game_won_triggered.connect(_on_game_won)

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
	_check_loop_completion()

	var should_spawn: bool = (
		elites_left_to_spawn > 0
		or GameManager.enemies_alive < mini(_get_target_concurrent_count(), max_concurrent_enemies)
	)
	if should_spawn:
		spawn_timer -= delta
		if spawn_timer <= 0.0:
			_spawn_enemy()
			spawn_timer = spawn_interval

	if destructible_object_scene != null and _destructibles_spawned < max_destructibles:
		_destructible_spawn_timer -= delta
		if _destructible_spawn_timer <= 0.0:
			# Čítač se zvedá jen při SKUTEČNÉM spawnu - pokud _spawn_world_object()
			# nenašlo volné místo (viz jeho MAX_SPAWN_POSITION_ATTEMPTS), vrátí
			# null a "total spawned" strop se tím nesmí vyčerpat nadarmo.
			if _spawn_world_object(destructible_object_scene) != null:
				_destructibles_spawned += 1
			_destructible_spawn_timer = destructible_spawn_interval

	if indestructible_object_scene != null and _indestructibles_spawned < max_indestructibles:
		_indestructible_spawn_timer -= delta
		if _indestructible_spawn_timer <= 0.0:
			if _spawn_world_object(indestructible_object_scene) != null:
				_indestructibles_spawned += 1
			_indestructible_spawn_timer = indestructible_spawn_interval

	if heal_pickup_scene != null and get_tree().get_nodes_in_group("heal_pickups").size() < max_heal_pickups:
		_heal_pickup_spawn_timer -= delta
		if _heal_pickup_spawn_timer <= 0.0:
			_spawn_world_object(heal_pickup_scene)
			_heal_pickup_spawn_timer = heal_pickup_spawn_interval

	if speed_pickup_scene != null and get_tree().get_nodes_in_group("speed_pickups").size() < max_speed_pickups:
		_speed_pickup_spawn_timer -= delta
		if _speed_pickup_spawn_timer <= 0.0:
			_spawn_world_object(speed_pickup_scene)
			_speed_pickup_spawn_timer = speed_pickup_spawn_interval


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


## Jakmile survival_time překročí loop_duration_seconds, běh se považuje za
## DOKONČENÝ (na rozdíl od smrti) - GameManager.trigger_win() zařídí zbytek
## (uložení souhrnu, převod run-XP na meta-XP, State.WON), stejná cesta do
## lobby jako smrt (viz "Lobby a meta-progrese" v CLAUDE.md).
func _check_loop_completion() -> void:
	if GameManager.survival_time >= loop_duration_seconds:
		GameManager.trigger_win()


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
	enemy.global_position = _random_position_around_player(spawn_margin)

	GameManager.register_enemy_spawned()
	return enemy


## Vytvoří a umístí statický objekt (viz "Statické objekty ve světě" v
## CLAUDE.md) na náhodné místo na kruhu kolem hráče - stejný ring-spawn jádro
## jako _spawn_around_player(), jen bez HP škálování/GameManager.enemies_alive
## účetnictví, které objekty vůbec nemají. Zkouší až MAX_SPAWN_POSITION_
## ATTEMPTS náhodných pozic, dokud nenajde jednu, která se nepřekrývá se
## žádným existujícím obstaclem (viz _is_position_clear_of_obstacles()) - při
## neúspěchu objekt vůbec nevytvoří a vrátí null, volající si to musí ohlídat
## (viz _process() - čítač "total spawned" se inkrementuje jen při úspěchu).
func _spawn_world_object(scene: PackedScene) -> Node2D:
	var world_object: Node2D = scene.instantiate()
	var half_size: Variant = world_object.get("collision_half_size")
	if half_size == null:
		half_size = world_object.get("pickup_radius")
	if half_size == null:
		half_size = 0.0

	var position: Vector2 = _random_position_around_player(object_spawn_margin)
	var found_clear_spot: bool = _is_position_clear_of_obstacles(position, half_size)
	var attempts: int = 1
	while not found_clear_spot and attempts < MAX_SPAWN_POSITION_ATTEMPTS:
		position = _random_position_around_player(object_spawn_margin)
		found_clear_spot = _is_position_clear_of_obstacles(position, half_size)
		attempts += 1

	if not found_clear_spot:
		world_object.free()
		return null

	add_child(world_object)
	world_object.global_position = position
	return world_object


## True, pokud by čtverec o polovičním rozměru new_half_size na pozici `pos`
## nepřekrýval (ani se nedotýkal blíž než object_spacing_margin) žádný
## existující obstacle - AABB test na obou osách, stejný "čtverec, ne kruh"
## přístup jako player.gd's _resolve_obstacle_collisions(). Pickupy (nejsou
## v "obstacles" skupině, viz pickup_base.gd) se tak sice touhle kontrolou
## samy neřídí, ale ani jiný objekt se na NĚ spawnem narazit nemůže - chrání
## jen proti obstacle-obstacle překryvu, což je přesně to, co bylo nahlášené.
func _is_position_clear_of_obstacles(pos: Vector2, new_half_size: float) -> bool:
	for obstacle in get_tree().get_nodes_in_group("obstacles"):
		if not is_instance_valid(obstacle):
			continue
		var required_distance: float = new_half_size + obstacle.collision_half_size + object_spacing_margin
		var offset: Vector2 = pos - obstacle.global_position
		if absf(offset.x) < required_distance and absf(offset.y) < required_distance:
			return false
	return true


## Náhodná pozice na kruhu kolem hráče, těsně mimo viditelnou obrazovku
## (top-down pivot 2026-09-27, dřív vždy kousek za pravým okrajem kamery).
## Poloměr = polovina DIAGONÁLY viewportu + margin - půl-šířka by nestačila,
## protože v "rohových" úhlech (blízko nahoře/dole) by spawn bod pořád ležel
## uvnitř viditelné oblasti; půl-diagonála zaručí spawn mimo obrazovku bez
## ohledu na úhel. Sdílené jádro pro spawn nepřátel (_spawn_around_player()) i
## statických objektů (_spawn_world_object()) - vytaženo zvlášť 2026-09-28,
## ať obě spawn logiky používají identickou matematiku, jen s jiným marginem.
func _random_position_around_player(margin: float) -> Vector2:
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	var min_radius: float = viewport_size.length() / 2.0 + margin
	var angle: float = randf() * TAU
	return player.global_position + Vector2.RIGHT.rotated(angle) * min_radius


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
	hud.show_game_over(
		GameManager.survival_time, GameManager.currency,
		GameManager.last_run_summary.get("meta_xp_gained", 0)
	)


func _on_game_won() -> void:
	hud.show_victory(GameManager.currency, GameManager.last_run_summary.get("meta_xp_gained", 0))


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
