extends Node
## Globální singleton (Autoload) - řídí vlny nepřátel, měnu, zkušenosti,
## úrovně hráče a jeho schopnosti. Zaregistrován v Project Settings > Autoload
## jako "GameManager".

signal wave_started(wave_number: int)
signal wave_cleared(wave_number: int)
signal game_over_triggered
signal game_won_triggered
signal currency_changed(new_amount: int)
signal xp_changed(current_xp: int, xp_needed: int)
signal level_changed(new_level: int)
signal ability_points_changed(amount: int)
signal ability_rank_changed(ability_id: String, new_rank: int)

enum State { INTRO, PLAYING, GAME_OVER, WON }

## Hra končí výhrou po vyčištění téhle vlny - viz _on_wave_cleared()
const FINAL_WAVE: int = 10

## XP potřebné na 2. úroveň; každá další úroveň stojí o XP_PER_LEVEL_GROWTH víc
const XP_BASE: int = 60
const XP_PER_LEVEL_GROWTH: int = 40
## Nejvyšší rank jedné schopnosti (jako v MOBA hrách - 5 bodů do schopnosti)
const MAX_ABILITY_RANK: int = 5

## O kolik se automaticky zvednou základní staty za každou získanou úroveň.
## Úroveň 1 = čisté base staty z player.gd, každá další přidá tyto hodnoty.
const LEVEL_STAT_GROWTH := {
	"damage": 5.0,
	"max_hp": 20.0,
	"attack_speed": 0.1,
	"attack_range": 15.0,
}

## Definice čtyř schopností. Aktivní efekty (projektily, animace) zatím nejsou -
## každý rank prozatím jen pasivně přičítá `per_rank` ke statu `stat`, aby body
## do schopností měly herní dopad. Až se budou dělat opravdové aktivní
## schopnosti, mění se jen tahle tabulka a get_stat_bonus().
const ABILITIES := {
	"q": {
		"key": "Q",
		"name": "Salva",
		"desc": "+1 zasažený cíl za rank",
		"stat": "multishot",
		"per_rank": 1.0,
	},
	"w": {
		"key": "W",
		"name": "Průraz",
		"desc": "+4 poškození za rank",
		"stat": "damage",
		"per_rank": 4.0,
	},
	"e": {
		"key": "E",
		"name": "Rychlopalba",
		"desc": "+0.15 útoku/s za rank",
		"stat": "attack_speed",
		"per_rank": 0.15,
	},
	"r": {
		"key": "R",
		"name": "Dalekostřel",
		"desc": "+40 dostřelu za rank",
		"stat": "attack_range",
		"per_rank": 40.0,
	},
}
## Pořadí schopností v HUD - drží layout stabilní nezávisle na pořadí v Dictionary
const ABILITY_ORDER: Array[String] = ["q", "w", "e", "r"]

var current_wave: int = 0
var currency: int = 0
var enemies_alive: int = 0
var enemies_remaining_to_spawn: int = 0
var state: State = State.INTRO

var player_level: int = 1
var player_xp: int = 0
## Nevyužité body do schopností. Hráč dostane 1 na startu a 1 za každou úroveň.
var ability_points: int = 1
var ability_ranks := {"q": 0, "w": 0, "e": 0, "r": 0}


## Volá main.gd v _enter_tree(), tedy DŘÍV než se spustí _ready() hráče a HUD -
## ty už tak čtou čerstvý stav. Kdyby se resetovalo až v _ready() Main uzlu,
## hráč by se po restartu naskočil se staty z předchozí hry.
func reset_game() -> void:
	current_wave = 0
	currency = 0
	enemies_alive = 0
	enemies_remaining_to_spawn = 0
	state = State.INTRO
	player_level = 1
	player_xp = 0
	ability_points = 1
	ability_ranks = {"q": 0, "w": 0, "e": 0, "r": 0}


## Zavolá level/spawner, aby oznámil, že spawnul nepřítele (pro sledování stavu vlny)
func register_enemy_spawned() -> void:
	enemies_alive += 1


## Zavolá nepřítel při své smrti - přidá měnu i XP a zkontroluje stav vlny
func enemy_defeated(reward: int, xp_reward: int) -> void:
	currency += reward
	currency_changed.emit(currency)
	add_xp(xp_reward)
	enemies_alive -= 1

	if enemies_alive <= 0 and enemies_remaining_to_spawn <= 0:
		_on_wave_cleared()


func _on_wave_cleared() -> void:
	wave_cleared.emit(current_wave)
	if current_wave >= FINAL_WAVE:
		trigger_win()
	else:
		# Žádné čekání na vynucený výběr - hra plynule pokračuje další vlnou
		start_next_wave()


func start_next_wave() -> void:
	current_wave += 1
	wave_started.emit(current_wave)


## Kolik XP je potřeba na další úroveň (roste lineárně s úrovní)
func xp_for_next_level() -> int:
	return XP_BASE + (player_level - 1) * XP_PER_LEVEL_GROWTH


## Přidá XP a případně povýší i o víc úrovní naráz (velký přebytek XP)
func add_xp(amount: int) -> void:
	player_xp += amount
	while player_xp >= xp_for_next_level():
		player_xp -= xp_for_next_level()
		_level_up()
	xp_changed.emit(player_xp, xp_for_next_level())


func _level_up() -> void:
	player_level += 1
	ability_points += 1
	# level_changed první - hráč si podle něj přepočítá staty, teprve pak HUD
	# reaguje na nové body do schopností
	level_changed.emit(player_level)
	ability_points_changed.emit(ability_points)


## Utratí 1 bod - buď odemkne zamčenou schopnost (rank 0 -> 1), nebo zvýší rank
## už odemčené. Vrací false, pokud nejsou body nebo je schopnost na max ranku.
func spend_ability_point(ability_id: String) -> bool:
	if ability_points <= 0:
		return false
	if not ability_ranks.has(ability_id):
		return false

	var new_rank: int = int(ability_ranks[ability_id]) + 1
	if new_rank > MAX_ABILITY_RANK:
		return false

	ability_points -= 1
	ability_ranks[ability_id] = new_rank
	ability_rank_changed.emit(ability_id, new_rank)
	ability_points_changed.emit(ability_points)
	return true


## Celkový bonus ke statu = růst za úrovně + ranky schopností, které na stat působí.
## Jediné místo, kde se progrese promítá do statů - player.gd si ho jen přičítá
## ke svým base hodnotám.
func get_stat_bonus(stat_id: String) -> float:
	var bonus: float = float(LEVEL_STAT_GROWTH.get(stat_id, 0.0)) * float(player_level - 1)

	for ability_id in ABILITY_ORDER:
		var definition: Dictionary = ABILITIES[ability_id]
		if definition["stat"] == stat_id:
			bonus += float(definition["per_rank"]) * float(ability_ranks[ability_id])

	return bonus


## Zavolá hráč po dokončení úvodní "drop-in" animace dopadu na zem.
func finish_intro() -> void:
	if state == State.INTRO:
		state = State.PLAYING


func trigger_game_over() -> void:
	if state == State.GAME_OVER:
		return
	state = State.GAME_OVER
	game_over_triggered.emit()
	print("Game Over! Dosažená vlna: ", current_wave, " | Úroveň: ", player_level)


## Zavolá hráč po dosažení konce levelu
func trigger_win() -> void:
	if state == State.WON:
		return
	state = State.WON
	game_won_triggered.emit()
	print("Level dokončen! Vlna: ", current_wave, " | Úroveň: ", player_level)
