extends CanvasLayer
## HUD - spodní lišta ve stylu MOBA her: staty, portrét s úrovní, HP a XP bar,
## čtyři schopnosti (Q/W/E/R), sloty na předměty, zlato a tlačítko obchodu.
## Body se neutrácí za jednotlivé staty (ty rostou samy s úrovní), ale klikáním
## přímo na schopnosti - kliknutí odemkne zamčenou nebo zvýší rank odemčené.
##
## Uzel má process_mode = ALWAYS (nastaveno ve scéně), aby lišta i obchod
## reagovaly i když je strom pozastavený přes get_tree().paused (otevřený obchod).

## Za kolik sekund se hra po Game Over nebo výhře automaticky restartuje,
## pokud kurzor nestojí nad příslušným panelem (viz _process a
## _on_end_panel_mouse_entered/exited). Stejná logika pro oba konce hry -
## jen jeden z panelů může být zobrazený najednou (GAME_OVER, nebo WON).
const END_SCREEN_RESTART_DELAY: float = 10.0

## Ztlumení ikony schopnosti, která ještě není odemčená
const LOCKED_ABILITY_MODULATE := Color(0.45, 0.45, 0.52)

@onready var loop_label: Label = $Control/LoopLabel
@onready var wave_label: Label = $Control/WaveLabel
@onready var wave_cleared_label: Label = $Control/WaveClearedLabel
@onready var wave_cleared_timer: Timer = $WaveClearedTimer

@onready var bottom_bar: ColorRect = $Control/BottomBar
@onready var stat_damage: Label = $Control/BottomBar/StatDamage
@onready var stat_speed: Label = $Control/BottomBar/StatSpeed
@onready var stat_range: Label = $Control/BottomBar/StatRange
@onready var stat_hp: Label = $Control/BottomBar/StatHP
@onready var level_label: Label = $Control/BottomBar/LevelBadge/LevelLabel
@onready var hp_bar: ProgressBar = $Control/BottomBar/HPBar
@onready var hp_label: Label = $Control/BottomBar/HPBar/HPLabel
@onready var xp_bar: ProgressBar = $Control/BottomBar/XPBar
@onready var xp_label: Label = $Control/BottomBar/XPBar/XPLabel
@onready var ability_points_label: Label = $Control/BottomBar/AbilityPointsLabel
@onready var auto_assign_toggle: Button = $Control/BottomBar/AutoAssignToggle
@onready var gold_label: Label = $Control/BottomBar/GoldLabel
@onready var shop_button: Button = $Control/BottomBar/ShopButton

@onready var shop_panel: Panel = $Control/ShopPanel
@onready var shop_close_button: Button = $Control/ShopPanel/CloseButton

@onready var game_over_panel: Panel = $Control/GameOverPanel
@onready var game_over_label: Label = $Control/GameOverPanel/Label
@onready var game_over_countdown_label: Label = $Control/GameOverPanel/CountdownLabel
@onready var game_over_continue_button: Button = $Control/GameOverPanel/ContinueButton
@onready var victory_panel: Panel = $Control/VictoryPanel
@onready var victory_label: Label = $Control/VictoryPanel/Label
@onready var victory_countdown_label: Label = $Control/VictoryPanel/CountdownLabel
@onready var victory_continue_button: Button = $Control/VictoryPanel/ContinueButton

var player_ref: Node2D = null

## Zbývající čas do auto-restartu po Game Over/výhře. Počítá se ručně (ne přes
## Timer uzel), protože potřebujeme jednoduše pozastavit/obnovit odpočet podle
## toho, jestli je kurzor nad panelem - viz CLAUDE.md poznámku k mobilnímu portu.
var _end_screen_countdown: float = 0.0
var _end_screen_countdown_active: bool = false
## Label aktuálně zobrazeného konečného panelu (Game Over, nebo Victory) -
## nastaví ho show_game_over()/show_victory() při spuštění odpočtu.
var _active_countdown_label: Label = null
var _countdown_label_prefix: String = ""

var _ability_buttons := {}
var _ability_rank_labels := {}

## Dokud je zapnuté, nově získané body do schopností se rozdají samy - viz
## _maybe_auto_assign(). _auto_assigning hlídá reentranci, protože
## spend_ability_point() synchronně emituje signály zpátky do tohoto skriptu.
var _auto_assign_enabled: bool = true
var _auto_assigning: bool = false


func _ready() -> void:
	GameManager.wave_started.connect(_on_wave_started)
	GameManager.currency_changed.connect(_on_currency_changed)
	GameManager.xp_changed.connect(_on_xp_changed)
	GameManager.level_changed.connect(_on_level_changed)
	GameManager.ability_points_changed.connect(_on_ability_points_changed)
	GameManager.ability_rank_changed.connect(_on_ability_rank_changed)
	GameManager.loop_changed.connect(_on_loop_changed)

	game_over_panel.hide()
	victory_panel.hide()
	shop_panel.hide()
	wave_cleared_label.hide()

	_cache_ability_nodes()

	auto_assign_toggle.button_pressed = _auto_assign_enabled
	auto_assign_toggle.toggled.connect(_on_auto_assign_toggled)

	shop_button.pressed.connect(_on_shop_button_pressed)
	shop_close_button.pressed.connect(_on_shop_close_pressed)
	wave_cleared_timer.timeout.connect(func(): wave_cleared_label.hide())

	game_over_continue_button.pressed.connect(_restart_game)
	game_over_panel.mouse_entered.connect(_on_end_panel_mouse_entered)
	game_over_panel.mouse_exited.connect(_on_end_panel_mouse_exited)

	victory_continue_button.pressed.connect(_restart_game)
	victory_panel.mouse_entered.connect(_on_end_panel_mouse_entered)
	victory_panel.mouse_exited.connect(_on_end_panel_mouse_exited)

	_refresh_progression()
	_maybe_auto_assign()


func _process(delta: float) -> void:
	if not _end_screen_countdown_active:
		return
	_end_screen_countdown -= delta
	if _end_screen_countdown <= 0.0:
		_end_screen_countdown_active = false
		_restart_game()
	else:
		_update_end_screen_countdown_label()


func _cache_ability_nodes() -> void:
	for ability_id in GameManager.ABILITY_ORDER:
		var suffix: String = ability_id.to_upper()
		var button: Button = bottom_bar.get_node("Ability" + suffix)
		_ability_buttons[ability_id] = button
		_ability_rank_labels[ability_id] = bottom_bar.get_node("AbilityRank" + suffix)
		button.pressed.connect(_on_ability_pressed.bind(ability_id))


## Zavolá Main po vytvoření hráče, aby se HUD napojil na jeho signály a staty.
func connect_player(player: Node2D) -> void:
	player_ref = player
	player.hp_changed.connect(_on_hp_changed)
	_refresh_stat_labels()


func _on_hp_changed(current_hp: float, max_hp: float) -> void:
	hp_bar.max_value = max_hp
	hp_bar.value = current_hp
	hp_label.text = "%.0f / %.0f" % [current_hp, max_hp]
	_refresh_stat_labels()


func _on_wave_started(wave_number: int) -> void:
	wave_label.text = "Vlna %d" % wave_number


func _on_loop_changed(new_loop: int) -> void:
	loop_label.text = "Kolo %d" % new_loop


func _on_currency_changed(new_amount: int) -> void:
	gold_label.text = "Zlato: %d" % new_amount


func _on_xp_changed(current_xp: int, xp_needed: int) -> void:
	xp_bar.max_value = xp_needed
	xp_bar.value = current_xp
	xp_label.text = "XP %d / %d" % [current_xp, xp_needed]


func _on_level_changed(new_level: int) -> void:
	level_label.text = str(new_level)
	_refresh_stat_labels()


func _on_ability_points_changed(_amount: int) -> void:
	_refresh_abilities()
	_maybe_auto_assign()


func _on_ability_rank_changed(_ability_id: String, _new_rank: int) -> void:
	_refresh_abilities()
	_refresh_stat_labels()


func _on_ability_pressed(ability_id: String) -> void:
	GameManager.spend_ability_point(ability_id)


func _on_auto_assign_toggled(enabled: bool) -> void:
	_auto_assign_enabled = enabled
	_maybe_auto_assign()


## Náhodně rozdá všechny nevyužité body do schopností, které ještě nejsou na
## maximálním ranku. PROZATÍMNÍ pravidlo bez váhování/priorit - jen rovnoměrně
## náhodné mezi způsobilými schopnostmi. Bude se dál vylepšovat (např. váhy
## podle buildu, preferovat odemykání nových před navyšováním ranku, ...).
func _maybe_auto_assign() -> void:
	if not _auto_assign_enabled or _auto_assigning:
		return

	_auto_assigning = true
	while GameManager.ability_points > 0:
		var eligible: Array = []
		for ability_id in GameManager.ABILITY_ORDER:
			if GameManager.ability_ranks[ability_id] < GameManager.MAX_ABILITY_RANK:
				eligible.append(ability_id)
		if eligible.is_empty():
			break
		var pick: String = eligible[randi() % eligible.size()]
		GameManager.spend_ability_point(pick)
	_auto_assigning = false


## Přenačte všechno, co se odvíjí od progrese. Volá se v _ready(), protože
## GameManager přežívá restart scény a HUD se s jeho stavem musí srovnat sám -
## signály při resetu už proběhly dřív, než se HUD stihl připojit.
func _refresh_progression() -> void:
	loop_label.text = "Kolo %d" % GameManager.loop_count
	level_label.text = str(GameManager.player_level)
	gold_label.text = "Zlato: %d" % GameManager.currency
	_on_xp_changed(GameManager.player_xp, GameManager.xp_for_next_level())
	_refresh_abilities()
	_refresh_stat_labels()


func _refresh_abilities() -> void:
	ability_points_label.text = "Body schopností: %d" % GameManager.ability_points

	for ability_id in GameManager.ABILITY_ORDER:
		var definition: Dictionary = GameManager.ABILITIES[ability_id]
		var rank: int = GameManager.ability_ranks[ability_id]
		var button: Button = _ability_buttons[ability_id]

		var can_upgrade: bool = (
			GameManager.ability_points > 0 and rank < GameManager.MAX_ABILITY_RANK
		)

		button.disabled = not can_upgrade
		# Ztlumená je jen schopnost, se kterou teď nejde nic dělat - zamčená
		# s volným bodem musí být vidět jako nabídka, ne jako neaktivní prvek
		button.modulate = Color.WHITE if rank > 0 or can_upgrade else LOCKED_ABILITY_MODULATE
		button.tooltip_text = "%s (%s)\n%s" % [definition["name"], definition["key"], definition["desc"]]

		var rank_text := "%d/%d" % [rank, GameManager.MAX_ABILITY_RANK]
		_ability_rank_labels[ability_id].text = rank_text + " +" if can_upgrade else rank_text


func _refresh_stat_labels() -> void:
	if player_ref == null:
		return
	stat_damage.text = "Poškození: %.0f" % player_ref.get_damage()
	stat_speed.text = "Rychlost: %.1f/s" % player_ref.get_attack_speed()
	stat_range.text = "Dostřel: %.0f" % player_ref.get_attack_range()
	stat_hp.text = "Max HP: %.0f" % player_ref.max_hp


func show_wave_cleared_message(wave_number: int) -> void:
	wave_cleared_label.text = "Vlna %d splněna!" % wave_number
	wave_cleared_label.show()
	wave_cleared_timer.start()


## Obchod hru pozastaví přes get_tree().paused. HUD má process_mode ALWAYS,
## takže jeho UI dál reaguje. Pauza je zatím záměrná, ale počítá se s tím, že
## se může zrušit - pak stačí vypustit řádky s `paused` (viz CLAUDE.md).
func _on_shop_button_pressed() -> void:
	if GameManager.state != GameManager.State.PLAYING:
		return
	shop_panel.show()
	get_tree().paused = true


func _on_shop_close_pressed() -> void:
	shop_panel.hide()
	get_tree().paused = false


func show_game_over(wave_reached: int, currency: int) -> void:
	_close_shop()
	game_over_label.text = "Game Over!\nDosažená vlna: %d\nÚroveň: %d\nZlato: %d" % [
		wave_reached, GameManager.player_level, currency
	]
	game_over_panel.show()
	_start_end_screen_countdown(game_over_countdown_label, "Restart za")


func show_victory(currency: int) -> void:
	_close_shop()
	victory_label.text = "Level dokončen!\nÚroveň: %d\nZlato: %d" % [GameManager.player_level, currency]
	victory_panel.show()
	_start_end_screen_countdown(victory_countdown_label, "Nová hra za")


func _close_shop() -> void:
	shop_panel.hide()
	get_tree().paused = false


func _start_end_screen_countdown(countdown_label: Label, prefix: String) -> void:
	_active_countdown_label = countdown_label
	_countdown_label_prefix = prefix
	_end_screen_countdown = END_SCREEN_RESTART_DELAY
	_end_screen_countdown_active = true
	_update_end_screen_countdown_label()


func _on_end_panel_mouse_entered() -> void:
	_end_screen_countdown_active = false


func _on_end_panel_mouse_exited() -> void:
	_end_screen_countdown_active = true


func _update_end_screen_countdown_label() -> void:
	_active_countdown_label.text = "%s: %d s" % [_countdown_label_prefix, int(ceil(_end_screen_countdown))]


func _restart_game() -> void:
	_end_screen_countdown_active = false
	game_over_panel.hide()
	victory_panel.hide()
	get_tree().paused = false
	get_tree().reload_current_scene()
