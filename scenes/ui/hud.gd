extends CanvasLayer
## HUD - spodní lišta ve stylu MOBA her: staty, portrét s úrovní, HP a XP bar,
## sloty vlastněných schopností, sloty na předměty (budoucí loot), zlato a
## tlačítko obchodu. Progrese schopností funguje jako nabídka (viz
## AbilityDraftPanel) - při KAŽDÉM level-upu se nabídnou 3 náhodné schopnosti
## (pasivní i aktivní, viz "Schopnosti" v CLAUDE.md) a hráč jednu vybere;
## hráč sám do nich nic neinvestuje ručně
## mimo tuhle volbu.
##
## Uzel má process_mode = ALWAYS (nastaveno ve scéně), aby lišta i
## obchod/panel schopností reagovaly i když je strom pozastavený přes
## get_tree().paused (otevřený obchod nebo čekající nabídka schopnosti).

## Za kolik sekund se hra po Game Over nebo výhře automaticky restartuje,
## pokud kurzor nestojí nad příslušným panelem (viz _process a
## _on_end_panel_mouse_entered/exited). Stejná logika pro oba konce hry -
## jen jeden z panelů může být zobrazený najednou (GAME_OVER, nebo WON).
const END_SCREEN_RESTART_DELAY: float = 10.0

## Ztlumení slotu itemu/schopnosti, který hráč ještě nevlastní
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
@onready var stat_armor: Label = $Control/BottomBar/StatArmor
@onready var level_label: Label = $Control/BottomBar/LevelBadge/LevelLabel
@onready var hp_bar: ProgressBar = $Control/BottomBar/HPBar
@onready var hp_label: Label = $Control/BottomBar/HPBar/HPLabel
@onready var hp_regen_label: Label = $Control/BottomBar/HPBar/RegenLabel
@onready var xp_bar: ProgressBar = $Control/BottomBar/XPBar
@onready var xp_label: Label = $Control/BottomBar/XPBar/XPLabel
@onready var gold_label: Label = $Control/BottomBar/GoldLabel
@onready var shop_button: Button = $Control/BottomBar/ShopButton

@onready var shop_panel: Panel = $Control/ShopPanel
@onready var shop_close_button: Button = $Control/ShopPanel/CloseButton
@onready var shop_reroll_button: Button = $Control/ShopPanel/RerollButton
## Jedna karta na jeden slot AKTUÁLNÍ nabídky (GameManager.shop_offer, vždy
## SHOP_OFFER_SIZE položek). Nabídka teď nese i raritu (viz
## _generate_shop_offer() v game_manager.gd), takže karty jsou vždy jen
## "Koupit" - žádné vlastnictví/vylepšení/prodej se tu neřeší, to je práce
## aktivních/sklad slotů níže.
@onready var shop_cards: Array = [
	$Control/ShopPanel/ShopCard0,
	$Control/ShopPanel/ShopCard1,
	$Control/ShopPanel/ShopCard2,
	$Control/ShopPanel/ShopCard3,
]
@onready var shop_active_label: Label = $Control/ShopPanel/ActiveLabel
@onready var shop_active_container: Control = $Control/ShopPanel/ActiveItemsContainer
@onready var shop_stash_label: Label = $Control/ShopPanel/StashLabel
@onready var shop_stash_container: Control = $Control/ShopPanel/StashContainer
## Zobrazuje AKTIVNÍ obchodní itemy v BottomBaru (jen zobrazení, žádná
## interakce - prodej/přesun do skladu se řeší jen uvnitř otevřeného
## obchodu, viz _active_slot_widgets). Na rozdíl od schopností (procedurální
## sloty, pevné pořadí podle ABILITY_ORDER, viz _build_abilities_ui()) se
## tyhle plní pozičně podle GameManager.active_shop_items, viz
## _refresh_shop_slots().
@onready var shop_slot_nodes: Array = [
	$Control/BottomBar/ItemSlot1,
	$Control/BottomBar/ItemSlot2,
	$Control/BottomBar/ItemSlot3,
	$Control/BottomBar/ItemSlot4,
	$Control/BottomBar/ItemSlot5,
	$Control/BottomBar/ItemSlot6,
]
## Šířka/mezera miniaturních slotů pro aktivní/sklad itemy uvnitř obchodu -
## vytváří se procedurálně (viz _build_shop_stash_ui()), ne ručně v hud.tscn,
## protože 6+9=15 skoro identických bloků by bylo zbytečně křehké psát
## ručně. Každý widget je Dictionary {"panel", "label", "buttons": Array}.
const SHOP_MINI_SLOT_WIDTH: float = 74.0
const SHOP_MINI_SLOT_GAP: float = 6.0
var _active_slot_widgets: Array = []
var _stash_slot_widgets: Array = []

## Stejný princip pro schopnosti (viz _build_abilities_ui()) - užší než
## obchodní sloty, protože nemají tlačítka, jen text.
const ABILITY_MINI_SLOT_WIDTH: float = 60.0
const ABILITY_MINI_SLOT_GAP: float = 4.0
@onready var abilities_container: Control = $Control/BottomBar/AbilitiesContainer

## Jediný panel volby schopnosti (viz "Schopnosti" v CLAUDE.md) - 3 karty,
## GameManager.ABILITY_CHOICE_COUNT. Nahradil dřívější oddělené DraftPanel
## (itemy, každou úroveň) a 1-kartové AbilityDraftPanel (aktivní schopnosti,
## jen 1 za 5 úrovní) po sloučení obou systémů do jednoho 2026-09-09.
@onready var ability_draft_panel: Panel = $Control/AbilityDraftPanel
@onready var ability_cards: Array = [
	$Control/AbilityDraftPanel/Card0,
	$Control/AbilityDraftPanel/Card1,
	$Control/AbilityDraftPanel/Card2,
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
@onready var debug_force_ability_draft_button: Button = $Control/DebugPanel/ForceAbilityDraftButton
@onready var debug_max_abilities_button: Button = $Control/DebugPanel/MaxItemsButton
@onready var debug_reset_abilities_button: Button = $Control/DebugPanel/ResetItemsButton
@onready var debug_add_loop_button: Button = $Control/DebugPanel/AddLoopButton
@onready var debug_spawn_elite_button: Button = $Control/DebugPanel/SpawnEliteButton
@onready var debug_spawn_ranged_button: Button = $Control/DebugPanel/SpawnRangedButton
@onready var debug_spawn_sniper_button: Button = $Control/DebugPanel/SpawnSniperButton
@onready var debug_auto_upgrade_toggle: Button = $Control/DebugPanel/AutoUpgradeToggle
@onready var debug_free_reroll_toggle: Button = $Control/DebugPanel/FreeRerollToggle
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

## Procedurální mini-sloty pro vlastněné schopnosti v BottomBaru, indexované
## stejně jako GameManager.ABILITY_ORDER - vytváří se v _build_abilities_ui()
## (stejný princip jako obchodní _active_slot_widgets/_stash_slot_widgets),
## ne ručně v hud.tscn, protože 9+ skoro identických bloků (a jejich údržba
## při každé nové schopnosti) by bylo zbytečně křehké psát ručně.
var _ability_slot_widgets: Array = []

## Dokud je zapnuté, nabídky schopností se vyřizují samy (náhodný pick) bez
## zobrazení AbilityDraftPanelu - vypnuto defaultně, protože smysl nabídky
## je, že hráč vidí a dělá skutečnou volbu. Ovládá se přes "Auto vylepšení"
## v Debug panelu (`AutoUpgradeToggle`), ne přes tlačítko v běžném HUD -
## žádný důvod, proč by si "finální" hráč měl chtít nechat vybírat schopnosti
## náhodně místo skutečné volby, takže to patří mezi dev/testovací nástroje,
## ne mezi trvale viditelné ovládací prvky.
var _ability_auto_enabled: bool = false
## Poslední nabídnuté schopnosti, každá {"ability_id": String, "rarity": int}
## (viz _on_ability_draft_ready) - potřeba, aby _on_ability_auto_toggled()
## mohl doresit nabídku, na kterou hráč zrovna kouká, i když je zrovna
## otevřená přes AbilityDraftPanel, ne přes Auto větev.
var _last_ability_offer: Array = []


func _ready() -> void:
	GameManager.wave_started.connect(_on_wave_started)
	GameManager.currency_changed.connect(_on_currency_changed)
	GameManager.xp_changed.connect(_on_xp_changed)
	GameManager.level_changed.connect(_on_level_changed)
	GameManager.ability_draft_ready.connect(_on_ability_draft_ready)
	GameManager.ability_inventory_changed.connect(_on_ability_inventory_changed)
	GameManager.loop_changed.connect(_on_loop_changed)
	GameManager.shop_inventory_changed.connect(_on_shop_inventory_changed)
	GameManager.shop_offer_changed.connect(_on_shop_offer_changed)
	GameManager.shop_auto_open_requested.connect(_on_shop_auto_open_requested)

	game_over_panel.hide()
	victory_panel.hide()
	shop_panel.hide()
	ability_draft_panel.hide()
	wave_cleared_label.hide()

	_build_abilities_ui()
	_setup_shop_cards()
	_build_shop_stash_ui()
	_refresh_shop_button_state()

	shop_button.pressed.connect(_on_shop_button_pressed)
	shop_close_button.pressed.connect(_on_shop_close_pressed)
	shop_reroll_button.pressed.connect(_on_shop_reroll_pressed)
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


## Vytvoří jeden mini-slot na schopnost PROCEDURÁLNĚ pro každou položku
## ABILITY_ORDER (stejný princip jako obchodní _create_shop_mini_slot(), jen
## bez tlačítek - schopnosti se neprodávají ani nepřesouvají, jen zobrazují).
## Volá se jednou v _ready(); počet slotů roste automaticky s ABILITY_ORDER,
## žádná ruční úprava hud.tscn není potřeba, když přibude další schopnost.
func _build_abilities_ui() -> void:
	for i in GameManager.ABILITY_ORDER.size():
		var panel := Panel.new()
		panel.position = Vector2(i * (ABILITY_MINI_SLOT_WIDTH + ABILITY_MINI_SLOT_GAP), 0.0)
		panel.size = Vector2(ABILITY_MINI_SLOT_WIDTH, 48.0)
		abilities_container.add_child(panel)

		var label := Label.new()
		label.position = Vector2(2.0, 2.0)
		label.size = Vector2(ABILITY_MINI_SLOT_WIDTH - 4.0, 44.0)
		label.add_theme_font_size_override("font_size", 8)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		panel.add_child(label)

		_ability_slot_widgets.append({"panel": panel, "label": label})


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
	if shop_panel.visible:
		_refresh_shop_panel()


func _on_xp_changed(current_xp: int, xp_needed: int) -> void:
	xp_bar.max_value = xp_needed
	xp_bar.value = current_xp
	xp_label.text = "XP %d / %d" % [current_xp, xp_needed]


func _on_level_changed(new_level: int) -> void:
	level_label.text = str(new_level)
	_refresh_stat_labels()


## Když hráč zapne Auto výběr zatímco AbilityDraftPanel zrovna čeká na jeho
## volbu, dořešíme ji (a případné další zařazené nabídky) rovnou za něj místo
## aby panel zůstal viset otevřený, dokud by si toho nevšiml a neklikl sám.
func _on_ability_auto_toggled(enabled: bool) -> void:
	_ability_auto_enabled = enabled
	if not enabled or GameManager.pending_ability_drafts <= 0:
		return

	var pick_index: int = randi() % _last_ability_offer.size()
	GameManager.resolve_ability_draft(pick_index) # se zapnutým Auto se přes _on_ability_draft_ready samo prořeže i případné další čekající
	ability_draft_panel.hide()
	get_tree().paused = false


func _on_ability_inventory_changed() -> void:
	_refresh_abilities()


## Přijde vždy, když je k dispozici nová nabídka schopnosti (při KAŽDÉM
## level-upu, viz game_manager.gd). S vypnutým Auto
## výběrem zobrazí AbilityDraftPanel a hru pozastaví (stejně jako Obchod) -
## hráč musí vybrat, než se hra pustí dál. Se zapnutým Auto výběrem nabídku
## rovnou vyřídí náhodným pickem bez zastavení hry (viz
## GameManager.resolve_ability_draft() - samo zavolá další nabídku, pokud
## nějaká čeká).
func _on_ability_draft_ready(offered: Array) -> void:
	_last_ability_offer = offered

	if _ability_auto_enabled:
		var pick_index: int = randi() % offered.size()
		GameManager.resolve_ability_draft(pick_index)
		return

	_show_ability_draft_panel(offered)


func _show_ability_draft_panel(offered: Array) -> void:
	for i in ability_cards.size():
		var card: Panel = ability_cards[i]
		if i >= offered.size():
			card.hide()
			continue

		var offer_entry: Dictionary = offered[i]
		var ability_id: String = offer_entry["ability_id"]
		var rarity: int = offer_entry["rarity"]
		var definition: Dictionary = GameManager.ABILITIES[ability_id]

		card.show()
		card.get_node("NameLabel").text = definition["name"]
		card.get_node("DescLabel").text = GameManager.get_ability_desc(ability_id, rarity)
		card.get_node("RarityLabel").text = GameManager.SHOP_RARITY_NAMES[rarity]

		var pick_button: Button = card.get_node("PickButton")
		for connection in pick_button.pressed.get_connections():
			pick_button.pressed.disconnect(connection["callable"])
		pick_button.pressed.connect(_on_ability_pick_pressed.bind(i))

	ability_draft_panel.show()
	get_tree().paused = true


func _on_ability_pick_pressed(offer_index: int) -> void:
	GameManager.resolve_ability_draft(offer_index)
	# resolve_ability_draft() může synchronně vyvolat DALŠÍ ability_draft_ready
	# (víc úrovní najednou z velkého přísunu XP), který už _show_ability_draft_panel()
	# znovu zavolal a panel nechal otevřený s novým obsahem - tady ho proto
	# zavíráme jen když už doopravdy nic dalšího nečeká.
	if GameManager.pending_ability_drafts <= 0:
		ability_draft_panel.hide()
		get_tree().paused = false


## Sloty vlastněných schopností v BottomBaru - ukazuje počet vlastněných
## kopií a nejvyšší vlastněnou raritu (na rozdíl od jediného čísla "rank",
## protože jeden ability_id může mít víc současně vlastněných instancí na
## RŮZNÝCH raritách, viz GameManager.owned_abilities).
func _refresh_abilities() -> void:
	for i in GameManager.ABILITY_ORDER.size():
		var ability_id: String = GameManager.ABILITY_ORDER[i]
		var definition: Dictionary = GameManager.ABILITIES[ability_id]
		var widget: Dictionary = _ability_slot_widgets[i]
		var label: Label = widget["label"]

		var count: int = 0
		var highest_rarity: int = -1
		for entry in GameManager.owned_abilities:
			if entry["ability_id"] == ability_id:
				count += 1
				highest_rarity = maxi(highest_rarity, entry["rarity"])

		if count > 0:
			label.text = "%s\n%dx %s" % [definition["short_name"], count, GameManager.SHOP_RARITY_NAMES[highest_rarity]]
			widget["panel"].modulate = Color.WHITE
			label.tooltip_text = "%s\n%s" % [definition["name"], GameManager.get_ability_desc(ability_id, highest_rarity)]
		else:
			label.text = "%s\n-" % definition["short_name"]
			widget["panel"].modulate = LOCKED_ITEM_MODULATE
			label.tooltip_text = definition["name"]


## Přenačte všechno, co se odvíjí od progrese. Volá se v _ready(), protože
## GameManager přežívá restart scény a HUD se s jeho stavem musí srovnat sám -
## signály při resetu už proběhly dřív, než se HUD stihl připojit.
func _refresh_progression() -> void:
	loop_label.text = "Kolo %d" % GameManager.loop_count
	level_label.text = str(GameManager.player_level)
	gold_label.text = "Zlato: %d" % GameManager.currency
	_on_xp_changed(GameManager.player_xp, GameManager.xp_for_next_level())
	_refresh_abilities()
	_refresh_shop_slots()
	_refresh_stat_labels()


func _refresh_stat_labels() -> void:
	if player_ref == null:
		return
	stat_damage.text = "Poškození: %.0f" % player_ref.get_damage()
	stat_speed.text = "Rychlost: %.1f/s" % player_ref.get_attack_speed()
	stat_range.text = "Dostřel: %.0f" % player_ref.get_attack_range()
	stat_hp.text = "Max HP: %.0f" % player_ref.max_hp
	stat_armor.text = "Brnění: %.0f" % player_ref.get_armor()


## Napojí každou kartu na její SLOT INDEX (0-3) v GameManager.shop_offer -
## nabídka teď nese i vylosovanou raritu (viz _generate_shop_offer()), takže
## karta je vždy jen "Koupit za cenu odpovídající téhle raritě", žádné
## vlastnictví/vylepšení/prodej se tu neřeší (to dělají aktivní/sklad sloty).
func _setup_shop_cards() -> void:
	for i in shop_cards.size():
		var card: Panel = shop_cards[i]
		var action_button: Button = card.get_node("ActionButton")
		action_button.pressed.connect(_on_shop_card_action_pressed.bind(i))


func _on_shop_card_action_pressed(slot_index: int) -> void:
	GameManager.buy_shop_item(slot_index)


func _on_shop_inventory_changed() -> void:
	_refresh_shop_slots()
	if shop_panel.visible:
		_refresh_shop_panel()


## Nová nabídka (periodické otevření NEBO reroll) - překreslí karty a stav
## tlačítka Obchod, i když je panel zrovna zavřený (aby byl při příštím
## otevření/refreshi vždy aktuální).
func _on_shop_offer_changed(_offer_ids: Array) -> void:
	if shop_panel.visible:
		_refresh_shop_panel()
	_refresh_shop_button_state()


## Automatické otevření po vyčištění 10. vlny - na rozdíl od
## _on_shop_button_pressed() se nekontroluje shop_available (to už je
## pravda, GameManager ho nastavil, než tohle emitnul) ani se nečeká na
## klik hráče.
func _on_shop_auto_open_requested() -> void:
	_refresh_shop_panel()
	shop_panel.show()
	get_tree().paused = true


func _on_shop_reroll_pressed() -> void:
	GameManager.reroll_shop()


## Tlačítko Obchod v BottomBaru je šedé/neaktivní, dokud hráč v aktuálním
## běhu nedohraje 10. vlnu poprvé - viz GameManager.shop_available.
func _refresh_shop_button_state() -> void:
	shop_button.disabled = not GameManager.shop_available
	shop_button.text = "Obchod" if GameManager.shop_available else "Obchod (po 10. vlně)"


## Aktualizuje karty podle AKTUÁLNÍ nabídky (GameManager.shop_offer, vždy
## SHOP_OFFER_SIZE položek, každá s vlastní vylosovanou raritou) a cenu/
## dostupnost rerollu - volá se při otevření obchodu a při každé změně
## zlata/inventáře/nabídky, dokud je obchod otevřený.
func _refresh_shop_panel() -> void:
	for i in shop_cards.size():
		var card: Panel = shop_cards[i]

		if i >= GameManager.shop_offer.size():
			card.hide()
			continue
		card.show()

		var offer_entry: Dictionary = GameManager.shop_offer[i]
		var item_id: String = offer_entry["item_id"]
		var rarity: int = offer_entry["rarity"]
		var definition: Dictionary = GameManager.SHOP_ITEMS[item_id]

		card.get_node("NameLabel").text = definition["name"]
		card.get_node("RarityLabel").text = GameManager.SHOP_RARITY_NAMES[rarity]
		card.get_node("DescLabel").text = GameManager.get_shop_item_desc(item_id, rarity)
		card.get_node("CostLabel").text = "Cena: %d" % GameManager.get_shop_item_cost(item_id, rarity)

		var action_button: Button = card.get_node("ActionButton")
		action_button.text = "Koupit"
		action_button.disabled = not GameManager.can_buy_shop_item(i)

	shop_reroll_button.text = "Přehodit (%d)" % GameManager.get_shop_reroll_cost()
	shop_reroll_button.disabled = not GameManager.can_reroll_shop()

	_refresh_shop_stash_ui()


## Vytvoří 6 aktivních + 9 sklad miniaturních slotů PROCEDURÁLNĚ (viz
## _create_shop_mini_slot()) - psát 15 skoro identických bloků ručně v
## hud.tscn by bylo zbytečně křehké. Volá se jednou v _ready().
func _build_shop_stash_ui() -> void:
	for i in GameManager.SHOP_ACTIVE_SLOTS:
		var widget: Dictionary = _create_shop_mini_slot(shop_active_container, i, ["Uskladnit"])
		widget["buttons"][0].pressed.connect(_on_active_slot_stash_pressed.bind(i))
		_active_slot_widgets.append(widget)

	for i in GameManager.SHOP_STASH_SLOTS:
		var widget: Dictionary = _create_shop_mini_slot(shop_stash_container, i, ["Aktivovat", "Prodat"])
		widget["buttons"][0].pressed.connect(_on_stash_slot_activate_pressed.bind(i))
		widget["buttons"][1].pressed.connect(_on_stash_slot_sell_pressed.bind(i))
		_stash_slot_widgets.append(widget)


## Jeden miniaturní slot: Panel s Labelem (2 řádky - krátký název + rarita)
## a N tlačítky pod sebou. Vrací Dictionary s referencemi, aby refresh/
## wiring nemusely znovu procházet strom uzlů přes get_node().
func _create_shop_mini_slot(parent: Control, index: int, button_texts: Array) -> Dictionary:
	var panel := Panel.new()
	panel.position = Vector2(index * (SHOP_MINI_SLOT_WIDTH + SHOP_MINI_SLOT_GAP), 0.0)
	panel.size = Vector2(SHOP_MINI_SLOT_WIDTH, 28.0 + button_texts.size() * 18.0)
	parent.add_child(panel)

	var label := Label.new()
	label.position = Vector2(2.0, 2.0)
	label.size = Vector2(SHOP_MINI_SLOT_WIDTH - 4.0, 24.0)
	label.add_theme_font_size_override("font_size", 8)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(label)

	var buttons: Array = []
	for bi in button_texts.size():
		var button := Button.new()
		button.position = Vector2(2.0, 28.0 + bi * 18.0)
		button.size = Vector2(SHOP_MINI_SLOT_WIDTH - 4.0, 16.0)
		button.add_theme_font_size_override("font_size", 7)
		button.text = button_texts[bi]
		panel.add_child(button)
		buttons.append(button)

	return {"panel": panel, "label": label, "buttons": buttons}


func _on_active_slot_stash_pressed(index: int) -> void:
	GameManager.move_shop_item_to_stash(index)


func _on_stash_slot_activate_pressed(index: int) -> void:
	GameManager.move_shop_item_to_active(index)


func _on_stash_slot_sell_pressed(index: int) -> void:
	GameManager.sell_shop_item("stash", index)


## Překreslí aktivní/sklad miniaturní sloty a hlavičky "(N/6)"/"(N/9)" -
## volá se z _refresh_shop_panel(), takže pokaždé, když je obchod otevřený
## a něco se změnilo (nákup, sloučení, přesun, prodej).
func _refresh_shop_stash_ui() -> void:
	shop_active_label.text = "Aktivní itemy (%d/%d)" % [
		GameManager.active_shop_items.size(), GameManager.SHOP_ACTIVE_SLOTS
	]
	shop_stash_label.text = "Sklad (%d/%d)" % [
		GameManager.stash_shop_items.size(), GameManager.SHOP_STASH_SLOTS
	]

	for i in _active_slot_widgets.size():
		var widget: Dictionary = _active_slot_widgets[i]
		if i < GameManager.active_shop_items.size():
			var entry: Dictionary = GameManager.active_shop_items[i]
			_fill_shop_mini_slot(widget, entry)
			widget["buttons"][0].disabled = false
		else:
			_clear_shop_mini_slot(widget)
			widget["buttons"][0].disabled = true

	for i in _stash_slot_widgets.size():
		var widget: Dictionary = _stash_slot_widgets[i]
		if i < GameManager.stash_shop_items.size():
			var entry: Dictionary = GameManager.stash_shop_items[i]
			_fill_shop_mini_slot(widget, entry)
			widget["buttons"][0].disabled = GameManager.active_shop_items.size() >= GameManager.SHOP_ACTIVE_SLOTS
			widget["buttons"][1].disabled = false
		else:
			_clear_shop_mini_slot(widget)
			widget["buttons"][0].disabled = true
			widget["buttons"][1].disabled = true


func _fill_shop_mini_slot(widget: Dictionary, entry: Dictionary) -> void:
	var definition: Dictionary = GameManager.SHOP_ITEMS[entry["item_id"]]
	var label: Label = widget["label"]
	label.text = "%s\n%s" % [definition["short_name"], GameManager.SHOP_RARITY_NAMES[entry["rarity"]]]
	widget["panel"].modulate = Color.WHITE
	label.tooltip_text = "%s (%s)\n%s" % [
		definition["name"], GameManager.SHOP_RARITY_NAMES[entry["rarity"]],
		GameManager.get_shop_item_desc(entry["item_id"], entry["rarity"])
	]


func _clear_shop_mini_slot(widget: Dictionary) -> void:
	widget["label"].text = "-"
	widget["label"].tooltip_text = ""
	widget["panel"].modulate = LOCKED_ITEM_MODULATE


## Zobrazuje AKTIVNÍ obchodní itemy v BottomBaru (mimo obchod samotný) - na
## rozdíl od _refresh_abilities() (pevné pořadí podle ABILITY_ORDER) se sloty
## plní POZIČNĚ podle GameManager.active_shop_items (Array), takže prázdné sloty
## jsou vždy na konci bez ohledu na to, který konkrétní item byl prodán/
## uskladněn. Sklad se tu nezobrazuje vůbec - ten je vidět jen uvnitř
## otevřeného obchodu (viz _refresh_shop_stash_ui()).
func _refresh_shop_slots() -> void:
	for i in shop_slot_nodes.size():
		var slot: ColorRect = shop_slot_nodes[i]
		var label: Label = slot.get_node("Label")

		if i < GameManager.active_shop_items.size():
			var entry: Dictionary = GameManager.active_shop_items[i]
			var definition: Dictionary = GameManager.SHOP_ITEMS[entry["item_id"]]
			label.text = "%s\n%s" % [definition["short_name"], GameManager.SHOP_RARITY_NAMES[entry["rarity"]]]
			slot.modulate = Color.WHITE
			slot.tooltip_text = "%s (%s)\n%s" % [
				definition["name"], GameManager.SHOP_RARITY_NAMES[entry["rarity"]],
				GameManager.get_shop_item_desc(entry["item_id"], entry["rarity"])
			]
		else:
			label.text = "-"
			slot.modulate = LOCKED_ITEM_MODULATE
			slot.tooltip_text = ""


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
	if not GameManager.shop_available:
		return
	_refresh_shop_panel()
	shop_panel.show()
	get_tree().paused = true


func _on_shop_close_pressed() -> void:
	shop_panel.hide()
	get_tree().paused = false


func show_game_over(wave_reached: int, currency: int) -> void:
	_close_shop()
	_close_ability_draft_panel()
	game_over_label.text = "Game Over!\nDosažená vlna: %d\nÚroveň: %d\nZlato: %d" % [
		wave_reached, GameManager.player_level, currency
	]
	game_over_panel.show()
	_start_end_screen_countdown(game_over_countdown_label, "Restart za")


func show_victory(currency: int) -> void:
	_close_shop()
	_close_ability_draft_panel()
	victory_label.text = "Level dokončen!\nÚroveň: %d\nZlato: %d" % [GameManager.player_level, currency]
	victory_panel.show()
	_start_end_screen_countdown(victory_countdown_label, "Nová hra za")


func _close_shop() -> void:
	shop_panel.hide()
	get_tree().paused = false


## Nouzové zavření - Debug panel má process_mode ALWAYS, takže "Zabít postavu"
## zafunguje i přes pauzu nabídky schopnosti; kdyby to vyvolalo Game Over
## uprostřed otevřené nabídky, tohle ji zavře stejně jako _close_shop() dělá
## pro Obchod.
func _close_ability_draft_panel() -> void:
	ability_draft_panel.hide()
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
	ability_draft_panel.hide()
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
	debug_force_ability_draft_button.pressed.connect(func(): GameManager.debug_force_ability_draft())
	debug_max_abilities_button.pressed.connect(func(): GameManager.debug_max_abilities())
	debug_reset_abilities_button.pressed.connect(func(): GameManager.debug_reset_abilities())
	debug_add_loop_button.pressed.connect(func(): GameManager.debug_add_loop())
	debug_spawn_elite_button.pressed.connect(_on_debug_spawn_elite_pressed)
	debug_spawn_ranged_button.pressed.connect(_on_debug_spawn_ranged_pressed)
	debug_spawn_sniper_button.pressed.connect(_on_debug_spawn_sniper_pressed)
	debug_auto_upgrade_toggle.button_pressed = _ability_auto_enabled
	debug_auto_upgrade_toggle.toggled.connect(_on_ability_auto_toggled)
	debug_speed_button.pressed.connect(_on_debug_speed_pressed)

	# GameManager.debug_free_reroll je stejně jako Engine.time_scale záměrně
	# NEresetované v reset_game() (vývojářské pohodlí napříč restarty), takže
	# se popisek musí při startu srovnat se skutečnou hodnotou stejně jako u
	# Rychlosti níže.
	debug_free_reroll_toggle.button_pressed = GameManager.debug_free_reroll
	_update_debug_free_reroll_label(GameManager.debug_free_reroll)
	debug_free_reroll_toggle.toggled.connect(_on_debug_free_reroll_toggled)

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


func _on_debug_free_reroll_toggled(enabled: bool) -> void:
	GameManager.debug_free_reroll = enabled
	_update_debug_free_reroll_label(enabled)
	if shop_panel.visible:
		_refresh_shop_panel()


func _update_debug_free_reroll_label(enabled: bool) -> void:
	debug_free_reroll_toggle.text = "Free reroll: %s" % ("Zapnuto" if enabled else "Vypnuto")


func _on_debug_skip_wave_pressed() -> void:
	if main_ref != null:
		main_ref.debug_skip_wave()


func _on_debug_spawn_elite_pressed() -> void:
	if main_ref != null:
		main_ref.debug_spawn_elite()


func _on_debug_spawn_ranged_pressed() -> void:
	if main_ref != null:
		main_ref.debug_spawn_ranged_enemy()


func _on_debug_spawn_sniper_pressed() -> void:
	if main_ref != null:
		main_ref.debug_spawn_sniper_enemy()


func _on_debug_speed_pressed() -> void:
	_debug_speed_index = (_debug_speed_index + 1) % DEBUG_SPEED_STEPS.size()
	Engine.time_scale = DEBUG_SPEED_STEPS[_debug_speed_index]
	_update_debug_speed_label()


func _update_debug_speed_label() -> void:
	debug_speed_button.text = "Rychlost: %dx" % int(DEBUG_SPEED_STEPS[_debug_speed_index])
