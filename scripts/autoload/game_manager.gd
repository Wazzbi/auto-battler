extends Node
## Globální singleton (Autoload) - řídí vlny nepřátel, měnu, skill pointy
## a stav hry. Zaregistrován v Project Settings > Autoload jako "GameManager".

signal wave_started(wave_number: int)
signal wave_cleared(wave_number: int)
signal game_over_triggered
signal game_won_triggered
signal currency_changed(new_amount: int)
signal skill_points_changed(new_amount: int)

enum State { INTRO, PLAYING, GAME_OVER, WON }

## Kolik skill pointů hráč dostane za vyčištění jedné vlny
const SKILL_POINTS_PER_WAVE: int = 1

var current_wave: int = 0
var currency: int = 0
var skill_points: int = 0
var enemies_alive: int = 0
var enemies_remaining_to_spawn: int = 0
var state: State = State.INTRO

## Trvalé upgrady hráče, nakoupené za skill pointy v HUD panelu
var player_upgrades := {
	"damage": 0.0,
	"attack_speed": 0.0,
	"max_hp": 0.0,
	"attack_range": 0.0,
	"multishot": 0.0,
}


func reset_game() -> void:
	current_wave = 0
	currency = 0
	skill_points = 0
	enemies_alive = 0
	state = State.INTRO
	player_upgrades = {
		"damage": 0.0,
		"attack_speed": 0.0,
		"max_hp": 0.0,
		"attack_range": 0.0,
		"multishot": 0.0,
	}


## Zavolá level/spawner, aby oznámil, že spawnul nepřítele (pro sledování stavu vlny)
func register_enemy_spawned() -> void:
	enemies_alive += 1


## Zavolá nepřítel při své smrti - přidá odměnu a zkontroluje, jestli je vlna hotová
func enemy_defeated(reward: int) -> void:
	currency += reward
	currency_changed.emit(currency)
	enemies_alive -= 1

	if enemies_alive <= 0 and enemies_remaining_to_spawn <= 0:
		_on_wave_cleared()


func _on_wave_cleared() -> void:
	skill_points += SKILL_POINTS_PER_WAVE
	skill_points_changed.emit(skill_points)
	wave_cleared.emit(current_wave)
	# Žádné čekání na vynucený výběr - hra plynule pokračuje další vlnou
	start_next_wave()


func start_next_wave() -> void:
	current_wave += 1
	wave_started.emit(current_wave)


## Utratí 1 skill point za konkrétní upgrade. Vrací false, pokud hráč nemá body.
func spend_skill_point(upgrade_id: String, amount: float) -> bool:
	if skill_points <= 0:
		return false
	if not player_upgrades.has(upgrade_id):
		return false
	skill_points -= 1
	player_upgrades[upgrade_id] += amount
	skill_points_changed.emit(skill_points)
	return true


## Zavolá hráč po dokončení úvodní "drop-in" animace dopadu na zem.
func finish_intro() -> void:
	if state == State.INTRO:
		state = State.PLAYING


func trigger_game_over() -> void:
	if state == State.GAME_OVER:
		return
	state = State.GAME_OVER
	game_over_triggered.emit()
	print("Game Over! Dosažená vlna: ", current_wave, " | Měna: ", currency)


## Zavolá hráč po dosažení konce levelu
func trigger_win() -> void:
	if state == State.WON:
		return
	state = State.WON
	game_won_triggered.emit()
	print("Level dokončen! Vlna: ", current_wave, " | Měna: ", currency)
