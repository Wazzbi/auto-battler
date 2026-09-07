extends CanvasLayer
## HUD - spodní lišta ve stylu MOBA her: staty, portrét s úrovní, HP a XP bar,
## sloty vybraných itemů, sloty na předměty (budoucí loot), zlato a tlačítko
## obchodu. Item progrese funguje jako "draft" (viz DraftPanel) - při každém
## level-upu se nabídnou 3 náhodné itemy a hráč jeden vybere; hráč sám do
## itemů nic neinvestuje ručně mimo tuhle volbu.
##
## Uzel má process_mode = ALWAYS (nastaveno ve scéně), aby lišta i
## obchod/draft panel reagovaly i když je strom pozastavený přes
## get_tree().paused (otevřený obchod nebo čekající draft nabídka).

## Za kolik sekund se hra po Game Over nebo výhře automaticky restartuje,
## pokud kurzor nestojí nad příslušným panelem (viz _process a
## _on_end_panel_mouse_entered/exited). Stejná logika pro oba konce hry -
## jen jeden z panelů může být zobrazený najednou (GAME_OVER, nebo WON).
const END_SCREEN_RESTART_DELAY: float = 10.0

## Ztlumení slotu itemu, který ještě nemá žádný rank
const LOCKED_ITEM_MODULATE := Color(0.45, 0.45, 0.52)

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
@onready var hp_regen_label: Label = $Control/BottomBar/HPBar/RegenLabel
@onready var xp_bar: ProgressBar = $Control/BottomBar/XPBar
@onready var xp_label: Label = $Control/BottomBar/XPBar/XPLabel
@onready var auto_assign_toggle: Button = $Control/BottomBar/AutoAssignToggle
@onready var gold_label: Label = $Control/BottomBar/GoldLabel
@onready var shop_button: Button = $Control/BottomBar/ShopButton

@onready var shop_panel: Panel = $Control/ShopPanel
@onready var shop_close_button: Button = $Control/ShopPanel/CloseButton

@onready var draft_panel: Panel = $Control/DraftPanel
@onready var draft_cards: Array = [
	$Control/DraftPanel/Card0,
	$Control/DraftPanel/Card1,
	$Control/DraftPanel/Card2,
]

@onready var game_over_panel: Panel = $Control/GameOverPanel
@onready var game_over_label: Label = $Control/GameOverPanel/Label
@onready var game_over_countdown_label: Label = $Control/GameOverPanel/CountdownLabel
@onready var game_over_continue_button: Button = $Control/GameOverPanel/ContinueButton
@onready var victory_panel: Panel = $Control/VictoryPanel
@onready var victory_label: Label = $Control/VictoryPanel/Label
@onready var victory_countdown_label: Label = $Control/VictoryPanel/CountdownLabel
@onready var victory_continue_button: Button = $Control/VictoryPanel/ContinueButton

@onready var debug_button: Button = $Control/DebugButton
@onready var debug_eye_icon: Control = $Control/DebugButton/EyeIcon
@onready var debug_panel: Panel = $Control/DebugPanel
@onready var debug_kill_button: Button = $Control/DebugPanel/KillButton
@onready var debug_invincible_toggle: Button = $Control/DebugPanel/InvincibleToggle
@onready var debug_skip_wave_button: Button = $Control/DebugPanel/SkipWaveButton
@onready var debug_add_xp_small_button: Button = $Control/DebugPanel/AddXpSmallButton
@onready var debug_add_xp_big_button: Button = $Control/DebugPanel/AddXpBigButton
@onready var debug_add_gold_small_button: Button = $Control/DebugPanel/AddGoldSmallButton
@onready var debug_add_gold_big_button: Button = $Control/DebugPanel/AddGoldBigButton
@onready var debug_force_draft_button: Button = $Control/DebugPanel/ForceDraftButton
@onready var debug_max_items_button: Button = $Control/DebugPanel/MaxItemsButton
@onready var debug_reset_items_button: Button = $Control/DebugPanel/ResetItemsButton
@onready var debug_add_loop_button: Button = $Control/DebugPanel/AddLoopButton
@onready var debug_spawn_elite_button: Button = $Control/DebugPanel/SpawnEliteButton
@onready var debug_speed_button: Button = $Control/DebugPanel/SpeedButton
@onready var debug_close_button: Button = $Control/DebugPanel/CloseButton

var player_ref: Node2D = null
## Main uzel (scenes/main.gd) - jen pro Debug panel (přeskočit vlnu, spawn
## Elite na vyžádání), nastaví ho connect_main(). Zbytek HUD s ním nepočítá,
## normální tok jde přes GameManager.
var main_ref: Node = null

## Kroky rychlosti hry pro Debug panel - cyklické tlačítko prochází tímhle
## polem. Mění Engine.time_scale globálně (zpomalí/zrychlí i Timery,
## Tweeny a countdown na Game Over/Victory panelu - to je záměr).
const DEBUG_SPEED_STEPS: Array[float] = [1.0, 2.0, 5.0, 10.0]
var _debug_speed_index: int = 0
var _debug_panel_open: bool = false

## Zbývající čas do auto-restartu po Game Over/výhře. Počítá se ručně (ne přes
## Timer uzel), protože potřebujeme jednoduše pozastavit/obnovit odpočet podle
## toho, jestli je kurzor nad panelem - viz CLAUDE.md poznámku k mobilnímu portu.
var _end_screen_countdown: float = 0.0
var _end_screen_countdown_active: bool = false
## Label aktuálně zobrazeného konečného panelu (Game Over, nebo Victory) -
## nastaví ho show_game_over()/show_victory() při spuštění odpočtu.
var _active_countdown_label: Label = null
var _countdown_label_prefix: String = ""

## Sloty vybraných itemů v BottomBaru, indexované stejně jako GameManager.ITEM_ORDER
var _item_slots: Array = []

## Dokud je zapnuté, draft nabídky se vyřizují samy (náhodný pick) bez
## zobrazení DraftPanelu - vypnuto defaultně, protože smysl draftu je, že
## hráč vidí a dělá skutečnou volbu (na rozdíl od dřívějšího Auto-přiřazení
## bodů do schopností, kde volba byla plochá a Auto dávalo smysl jako výchozí).
var _draft_auto_enabled: bool = false
## Poslední nabídnuté itemy (viz _on_item_draft_ready) - potřeba, aby
## _on_draft_auto_toggled() mohl doresit nabídku, na kterou hráč zrovna
## kouká, i když je zrovna otevřená přes DraftPanel, ne přes Auto větev.
var _last_offered_ids: Array = []


func _ready() -> void:
	GameManager.wave_started.connect(_on_wave_started)
	GameManager.currency_changed.connect(_on_currency_changed)
	GameManager.xp_changed.connect(_on_xp_changed)
	GameManager.level_changed.connect(_on_level_changed)
	GameManager.item_draft_ready.connect(_on_item_draft_ready)
	GameManager.item_rank_changed.connect(_on_item_rank_changed)
	GameManager.loop_changed.connect(_on_loop_changed)

	game_over_panel.hide()
	victory_panel.hide()
	shop_panel.hide()
	draft_panel.hide()
	wave_cleared_label.hide()

	_cache_item_nodes()

	auto_assign_toggle.button_pressed = _draft_auto_enabled
	auto_assign_toggle.toggled.connect(_on_draft_auto_toggled)

	shop_button.pressed.connect(_on_shop_button_pressed)
	shop_close_button.pressed.connect(_on_shop_close_pressed)
	wave_cleared_timer.timeout.connect(func(): wave_cleared_label.hide())

	game_over_continue_button.pressed.connect(_restart_game)
	game_over_panel.mouse_entered.connect(_on_end_panel_mouse_entered)
	game_over_panel.mouse_exited.connect(_on_end_panel_mouse_exited)

	victory_continue_button.pressed.connect(_restart_game)
	victory_panel.mouse_entered.connect(_on_end_panel_mouse_entered)
	victory_panel.mouse_exited.connect(_on_end_panel_mouse_exited)

	_setup_debug_panel()

	_refresh_progression()


func _process(delta: float) -> void:
	if not _end_screen_countdown_active:
		return
	_end_screen_countdown -= delta
	if _end_screen_countdown <= 0.0:
		_end_screen_countdown_active = false
		_restart_game()
	else:
		_update_end_screen_countdown_label()


func _cache_item_nodes() -> void:
	for i in GameManager.ITEM_ORDER.size():
		_item_slots.append(bottom_bar.get_node("PickedItemSlot%d" % i))


## Zavolá Main po vytvoření hráče, aby se HUD napojil na jeho signály a staty.
func connect_player(player: Node2D) -> void:
	player_ref = player
	player.hp_changed.connect(_on_hp_changed)
	_refresh_stat_labels()


## Zavolá Main na sebe - Debug panel potřebuje volat main.gd's
## debug_skip_wave()/debug_spawn_elite() (main.gd vlastní frontu spawnování).
func connect_main(main: Node) -> void:
	main_ref = main


func _on_hp_changed(current_hp: float, max_hp: float) -> void:
	hp_bar.max_value = max_hp
	hp_bar.value = current_hp
	hp_label.text = "%.0f / %.0f" % [current_hp, max_hp]
	_update_hp_regen_label(current_hp, max_hp)
	_refresh_stat_labels()


## Ukazuje se jen když má regen co dohánět (jinak by "+X/s" viselo u HP baru
## i na plném HP, kde nemá žádný viditelný efekt).
func _update_hp_regen_label(current_hp: float, max_hp: float) -> void:
	var regen: float = player_ref.get_hp_regen() if player_ref != null else 0.0
	if player_ref == null or current_hp >= max_hp or regen <= 0.0:
		hp_regen_label.hide()
	else:
		hp_regen_label.text = "+%.1f/s" % regen
		hp_regen_label.show()


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


func _on_item_rank_changed(_item_id: String, _new_rank: int) -> void:
	_refresh_items()
	_refresh_stat_labels()


## Když hráč zapne Auto výběr zatímco DraftPanel zrovna čeká na jeho volbu,
## dořešíme ji (a případné další zařazené nabídky) rovnou za něj místo aby
## panel zůstal viset otevřený, dokud by si toho nevšiml a neklikl sám.
func _on_draft_auto_toggled(enabled: bool) -> void:
	_draft_auto_enabled = enabled
	if enabled and GameManager.pending_drafts > 0:
		var pick: String = _last_offered_ids[randi() % _last_offered_ids.size()]
		GameManager.resolve_draft(pick) # se zapnutým Auto se přes _on_item_draft_ready samo prořeže i případné další čekající
		draft_panel.hide()
		get_tree().paused = false


## Přijde vždy, když je k dispozici nová draft nabídka (typicky po level-upu).
## S vypnutým Auto výběrem zobrazí DraftPanel a hru pozastaví (stejně jako
## Obchod) - hráč musí vybrat, než se hra pustí dál. Se zapnutým Auto výběrem
## nabídku rovnou vyřídí náhodným pickem bez zastavení hry (viz
## GameManager.resolve_draft() - samo zavolá další nabídku, pokud nějaká čeká).
func _on_item_draft_ready(offered_ids: Array) -> void:
	_last_offered_ids = offered_ids

	if _draft_auto_enabled:
		var pick: String = offered_ids[randi() % offered_ids.size()]
		GameManager.resolve_draft(pick)
		return

	_show_draft_panel(offered_ids)


func _show_draft_panel(offered_ids: Array) -> void:
	for i in draft_cards.size():
		var card: Panel = draft_cards[i]
		if i >= offered_ids.size():
			card.hide()
			continue

		var item_id: String = offered_ids[i]
		var definition: Dictionary = GameManager.ITEMS[item_id]
		var current_rank: int = GameManager.item_ranks[item_id]

		card.show()
		card.get_node("NameLabel").text = definition["name"]
		card.get_node("DescLabel").text = definition["desc"]
		card.get_node("RankLabel").text = "%d/%d -> %d/%d" % [
			current_rank, GameManager.MAX_ITEM_RANK, current_rank + 1, GameManager.MAX_ITEM_RANK
		]

		var pick_button: Button = card.get_node("PickButton")
		# Karty se v draft_cards nemění, jen se přepisuje jejich obsah - proto
		# je nutné staré spojení nejdřív odpojit, jinak by kliknutí na tutéž
		# kartu po druhé nabídce zavolalo resolve_draft() se starým item_id.
		for connection in pick_button.pressed.get_connections():
			pick_button.pressed.disconnect(connection["callable"])
		pick_button.pressed.connect(_on_draft_pick_pressed.bind(item_id))

	draft_panel.show()
	get_tree().paused = true


func _on_draft_pick_pressed(item_id: String) -> void:
	GameManager.resolve_draft(item_id)
	# resolve_draft() může synchronně vyvolat DALŠÍ item_draft_ready (víc
	# úrovní najednou z velkého přísunu XP), který už _show_draft_panel()
	# znovu zavolal a panel nechal otevřený s novým obsahem - tady ho proto
	# zavíráme jen když už doopravdy nic dalšího nečeká.
	if GameManager.pending_drafts <= 0:
		draft_panel.hide()
		get_tree().paused = false


## Přenačte všechno, co se odvíjí od progrese. Volá se v _ready(), protože
## GameManager přežívá restart scény a HUD se s jeho stavem musí srovnat sám -
## signály při resetu už proběhly dřív, než se HUD stihl připojit.
func _refresh_progression() -> void:
	loop_label.text = "Kolo %d" % GameManager.loop_count
	level_label.text = str(GameManager.player_level)
	gold_label.text = "Zlato: %d" % GameManager.currency
	_on_xp_changed(GameManager.player_xp, GameManager.xp_for_next_level())
	_refresh_items()
	_refresh_stat_labels()


func _refresh_items() -> void:
	for i in GameManager.ITEM_ORDER.size():
		var item_id: String = GameManager.ITEM_ORDER[i]
		var definition: Dictionary = GameManager.ITEMS[item_id]
		var rank: int = GameManager.item_ranks[item_id]
		var slot: ColorRect = _item_slots[i]
		var label: Label = slot.get_node("Label")

		label.text = "%s\n%d/%d" % [definition["short_name"], rank, GameManager.MAX_ITEM_RANK]
		slot.modulate = Color.WHITE if rank > 0 else LOCKED_ITEM_MODULATE
		slot.tooltip_text = "%s\n%s" % [definition["name"], definition["desc"]]


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
	_close_draft_panel()
	game_over_label.text = "Game Over!\nDosažená vlna: %d\nÚroveň: %d\nZlato: %d" % [
		wave_reached, GameManager.player_level, currency
	]
	game_over_panel.show()
	_start_end_screen_countdown(game_over_countdown_label, "Restart za")


func show_victory(currency: int) -> void:
	_close_shop()
	_close_draft_panel()
	victory_label.text = "Level dokončen!\nÚroveň: %d\nZlato: %d" % [GameManager.player_level, currency]
	victory_panel.show()
	_start_end_screen_countdown(victory_countdown_label, "Nová hra za")


func _close_shop() -> void:
	shop_panel.hide()
	get_tree().paused = false


## Nouzové zavření - Debug panel má process_mode ALWAYS, takže "Zabít postavu"
## zafunguje i přes pauzu draftu; kdyby to vyvolalo Game Over uprostřed
## otevřené nabídky, tohle ji zavře stejně jako _close_shop() dělá pro Obchod.
func _close_draft_panel() -> void:
	draft_panel.hide()
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
	draft_panel.hide()
	get_tree().paused = false
	get_tree().reload_current_scene()


# --- Debug panel ---------------------------------------------------------
# Vývojářský panel pro rychlé testování - žádná herní logika tu nežije,
# jen zkratky volající metody v GameManageru/main.gd/player.gd označené
# jako "DEBUG:". Otevírá/zavírá se tlačítkem s ikonkou oka (eye_icon.gd)
# v pravém horním rohu; panel hru nepozastavuje (na rozdíl od Obchodu), ať
# je vidět efekt akcí v reálném čase.

func _setup_debug_panel() -> void:
	debug_panel.hide()
	debug_eye_icon.is_open = false

	debug_button.pressed.connect(_on_debug_toggle_pressed)
	debug_close_button.pressed.connect(_on_debug_close_pressed)

	debug_kill_button.pressed.connect(_on_debug_kill_pressed)
	debug_invincible_toggle.toggled.connect(_on_debug_invincible_toggled)
	debug_skip_wave_button.pressed.connect(_on_debug_skip_wave_pressed)
	debug_add_xp_small_button.pressed.connect(func(): GameManager.add_xp(100))
	debug_add_xp_big_button.pressed.connect(func(): GameManager.add_xp(500))
	debug_add_gold_small_button.pressed.connect(func(): GameManager.debug_add_currency(100))
	debug_add_gold_big_button.pressed.connect(func(): GameManager.debug_add_currency(1000))
	debug_force_draft_button.pressed.connect(func(): GameManager.debug_force_draft())
	debug_max_items_button.pressed.connect(func(): GameManager.debug_max_items())
	debug_reset_items_button.pressed.connect(func(): GameManager.debug_reset_items())
	debug_add_loop_button.pressed.connect(func(): GameManager.debug_add_loop())
	debug_spawn_elite_button.pressed.connect(_on_debug_spawn_elite_pressed)
	debug_speed_button.pressed.connect(_on_debug_speed_pressed)

	# Engine.time_scale je globální a restart scény ho sám neresetuje - popisek
	# tlačítka rychlosti se proto při startu musí srovnat s tím, co skutečně
	# platí (jinak by po restartu ukazoval "1x", i když hra běží rychleji).
	_debug_speed_index = maxi(DEBUG_SPEED_STEPS.find(Engine.time_scale), 0)
	_update_debug_speed_label()


func _on_debug_toggle_pressed() -> void:
	_debug_panel_open = not _debug_panel_open
	debug_panel.visible = _debug_panel_open
	debug_eye_icon.is_open = _debug_panel_open


func _on_debug_close_pressed() -> void:
	_debug_panel_open = false
	debug_panel.hide()
	debug_eye_icon.is_open = false


func _on_debug_kill_pressed() -> void:
	if player_ref != null:
		player_ref.take_damage(999999.0)


func _on_debug_invincible_toggled(enabled: bool) -> void:
	if player_ref != null:
		player_ref.debug_invincible = enabled
	debug_invincible_toggle.text = "Nesmrtelnost: %s" % ("Zapnuto" if enabled else "Vypnuto")


func _on_debug_skip_wave_pressed() -> void:
	if main_ref != null:
		main_ref.debug_skip_wave()


func _on_debug_spawn_elite_pressed() -> void:
	if main_ref != null:
		main_ref.debug_spawn_elite()


func _on_debug_speed_pressed() -> void:
	_debug_speed_index = (_debug_speed_index + 1) % DEBUG_SPEED_STEPS.size()
	Engine.time_scale = DEBUG_SPEED_STEPS[_debug_speed_index]
	_update_debug_speed_label()


func _update_debug_speed_label() -> void:
	debug_speed_button.text = "Rychlost: %dx" % int(DEBUG_SPEED_STEPS[_debug_speed_index])
