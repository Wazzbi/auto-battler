extends CanvasLayer
## HUD - zobrazuje HP, vlnu, měnu a nabízí panel pro utrácení skill pointů
## za upgrady. Panel se otevírá/zavírá tlačítkem, hru neblokuje.

const DAMAGE_INCREASE: float = 5.0
const ATTACK_SPEED_INCREASE: float = 0.2
const MAX_HP_INCREASE: float = 20.0
const RANGE_INCREASE: float = 50.0
const MULTISHOT_INCREASE: float = 1.0

@onready var hp_bar: ProgressBar = $Control/HPBar
@onready var wave_label: Label = $Control/WaveLabel
@onready var currency_label: Label = $Control/CurrencyLabel
@onready var wave_cleared_label: Label = $Control/WaveClearedLabel
@onready var wave_cleared_timer: Timer = $WaveClearedTimer

@onready var upgrade_button: Button = $Control/UpgradeButton
@onready var stats_panel: Panel = $Control/StatsPanel
@onready var points_label: Label = $Control/StatsPanel/VBoxContainer/PointsLabel
@onready var damage_label: Label = $Control/StatsPanel/VBoxContainer/DamageRow/DamageLabel
@onready var speed_label: Label = $Control/StatsPanel/VBoxContainer/SpeedRow/SpeedLabel
@onready var hp_label: Label = $Control/StatsPanel/VBoxContainer/HPRow/HPLabel
@onready var range_label: Label = $Control/StatsPanel/VBoxContainer/RangeRow/RangeLabel
@onready var multishot_label: Label = $Control/StatsPanel/VBoxContainer/MultishotRow/MultishotLabel
@onready var damage_plus: Button = $Control/StatsPanel/VBoxContainer/DamageRow/DamagePlus
@onready var speed_plus: Button = $Control/StatsPanel/VBoxContainer/SpeedRow/SpeedPlus
@onready var hp_plus: Button = $Control/StatsPanel/VBoxContainer/HPRow/HPPlus
@onready var range_plus: Button = $Control/StatsPanel/VBoxContainer/RangeRow/RangePlus
@onready var multishot_plus: Button = $Control/StatsPanel/VBoxContainer/MultishotRow/MultishotPlus
@onready var close_button: Button = $Control/StatsPanel/VBoxContainer/CloseButton

@onready var game_over_panel: Panel = $Control/GameOverPanel
@onready var game_over_label: Label = $Control/GameOverPanel/Label
@onready var victory_panel: Panel = $Control/VictoryPanel
@onready var victory_label: Label = $Control/VictoryPanel/Label

var player_ref: Node2D = null


func _ready() -> void:
	GameManager.wave_started.connect(_on_wave_started)
	GameManager.currency_changed.connect(_on_currency_changed)
	GameManager.skill_points_changed.connect(_on_skill_points_changed)

	game_over_panel.hide()
	victory_panel.hide()
	stats_panel.hide()
	wave_cleared_label.hide()

	currency_label.text = "Měna: 0"
	points_label.text = "Body: 0"

	upgrade_button.pressed.connect(_on_upgrade_button_pressed)
	damage_plus.pressed.connect(_on_damage_plus_pressed)
	speed_plus.pressed.connect(_on_speed_plus_pressed)
	hp_plus.pressed.connect(_on_hp_plus_pressed)
	range_plus.pressed.connect(_on_range_plus_pressed)
	multishot_plus.pressed.connect(_on_multishot_plus_pressed)
	close_button.pressed.connect(_on_close_pressed)
	wave_cleared_timer.timeout.connect(func(): wave_cleared_label.hide())


## Zavolá Main po vytvoření hráče, aby se HUD napojil na jeho signály a staty.
func connect_player(player: Node2D) -> void:
	player_ref = player
	player.hp_changed.connect(_on_hp_changed)
	_refresh_stat_labels()


func _on_hp_changed(current_hp: float, max_hp: float) -> void:
	hp_bar.max_value = max_hp
	hp_bar.value = current_hp


func _on_wave_started(wave_number: int) -> void:
	wave_label.text = "Vlna %d" % wave_number


func _on_currency_changed(new_amount: int) -> void:
	currency_label.text = "Měna: %d" % new_amount


func _on_skill_points_changed(new_amount: int) -> void:
	points_label.text = "Body: %d" % new_amount


func show_wave_cleared_message(wave_number: int) -> void:
	wave_cleared_label.text = "Vlna %d splněna! +1 bod" % wave_number
	wave_cleared_label.show()
	wave_cleared_timer.start()


func show_game_over(wave_reached: int, currency: int) -> void:
	game_over_label.text = "Game Over!\nDosažená vlna: %d\nMěna: %d" % [wave_reached, currency]
	game_over_panel.show()


func show_victory(currency: int) -> void:
	victory_label.text = "Level dokončen!\nMěna: %d" % currency
	victory_panel.show()


func _on_upgrade_button_pressed() -> void:
	_refresh_stat_labels()
	stats_panel.visible = not stats_panel.visible


func _on_close_pressed() -> void:
	stats_panel.hide()


func _on_damage_plus_pressed() -> void:
	if GameManager.spend_skill_point("damage", DAMAGE_INCREASE):
		player_ref.on_upgrade_applied()
		_refresh_stat_labels()


func _on_speed_plus_pressed() -> void:
	if GameManager.spend_skill_point("attack_speed", ATTACK_SPEED_INCREASE):
		player_ref.on_upgrade_applied()
		_refresh_stat_labels()


func _on_hp_plus_pressed() -> void:
	if GameManager.spend_skill_point("max_hp", MAX_HP_INCREASE):
		player_ref.on_upgrade_applied()
		_refresh_stat_labels()


func _on_range_plus_pressed() -> void:
	if GameManager.spend_skill_point("attack_range", RANGE_INCREASE):
		player_ref.on_upgrade_applied()
		_refresh_stat_labels()


func _on_multishot_plus_pressed() -> void:
	if GameManager.spend_skill_point("multishot", MULTISHOT_INCREASE):
		player_ref.on_upgrade_applied()
		_refresh_stat_labels()


func _refresh_stat_labels() -> void:
	points_label.text = "Body: %d" % GameManager.skill_points
	if player_ref == null:
		return
	damage_label.text = "Poškození: %.0f" % player_ref.get_damage()
	speed_label.text = "Rychlost útoku: %.1f/s" % player_ref.get_attack_speed()
	hp_label.text = "Max HP: %.0f" % player_ref.max_hp
	range_label.text = "Dostřel: %.0f" % player_ref.get_attack_range()
	multishot_label.text = "Cílů najednou: %d" % player_ref.get_target_count()
