extends CanvasLayer
## HUD - portrét s úrovní, HP a XP bar, hromádka vlastněných schopností, zlato
## a časovač přežití nahoře. Staty a aktivní/sklad itemy žijí v CharacterPanel
## (klik na portrét, viz "CharacterPanel" v CLAUDE.md).
##
## STALE (2026-09-27, "Lobby a meta-progrese"): CharacterPanel dřív měl i
## druhou záložku s DOVEDNOSTNÍM STROMEM - ten se přesunul výhradně do
## scenes/ui/lobby.gd/tscn (klidná obrazovka MEZI běhy, ne za chodu), aby
## nekolidoval tempem s run-scoped nabídkou SCHOPNOSTÍ. CharacterPanel tu
## proto zůstal jen s jedinou (dřívější "Inventář") sekcí, bez záložek.
## Portrét žlutě signalizuje `pending_skill_points > 0` čistě jako PASIVNÍ
## odznáček ("máš co investovat, až budeš v lobby") - klik na portrét v běhu
## vždy jen otevře Inventář, žádnou investici tu už neřeší.
##
## Uzel má process_mode = ALWAYS (nastaveno ve scéně), aby lišta i
## obchod/CharacterPanel reagovaly i když je hra pozastavená přes
## get_tree().paused (otevřený obchod, panel, nebo čekající nabídka schopnosti).

## Za kolik sekund se hra po Game Over nebo výhře automaticky restartuje,
## pokud kurzor nestojí nad příslušným panelem (viz _process a
## _on_end_panel_mouse_entered/exited). Stejná logika pro oba konce hry -
## jen jeden z panelů může být zobrazený najednou (GAME_OVER, nebo WON).
const END_SCREEN_RESTART_DELAY: float = 10.0

## Ztlumení slotu itemu/schopnosti, který hráč ještě nevlastní
const LOCKED_ITEM_MODULATE := Color(0.45, 0.45, 0.52)

## Běžící časovač přežití "mm:ss" (top-down pivot Fáze 6, nahrazuje dřívější
## LoopLabel/WaveLabel dvojici - žádné vlny/kola už neexistují, viz
## _on_survival_time_changed()). Uzel v .tscn přejmenován z "WaveLabel", ať
## jméno odpovídá aktuálnímu účelu.
@onready var survival_time_label: Label = $Control/SurvivalTimeLabel

## Staty žijí uvnitř CharacterPanel/InventoryTabContent (viz níže) - dřív
## v trvale viditelném BottomBar, přesunuto 2026-09-27 (viz "CharacterPanel"
## v CLAUDE.md - BottomBar trvale zabíral spodní pruh obrazovky, což vadilo
## ještě víc po top-down pivotaci s volným pohybem ve všech směrech).
@onready var stat_damage: Label = $Control/CharacterPanel/InventoryTabContent/StatDamage
@onready var stat_speed: Label = $Control/CharacterPanel/InventoryTabContent/StatSpeed
@onready var stat_range: Label = $Control/CharacterPanel/InventoryTabContent/StatRange
@onready var stat_hp: Label = $Control/CharacterPanel/InventoryTabContent/StatHP
@onready var stat_armor: Label = $Control/CharacterPanel/InventoryTabContent/StatArmor
@onready var stat_crit: Label = $Control/CharacterPanel/InventoryTabContent/StatCrit
## Portrét je klikatelné tlačítko (viz "CharacterPanel" v CLAUDE.md) - klik
## otevře CharacterPanel (Inventář). STALE (2026-09-28): dřív se žlutě
## zbarvoval a nesl odznáček "+N" čekajících bodů dovednosti - odstraněno,
## protože body dovednosti jsou od "Lobby a meta-progrese" META a hráč je
## stejně nemůže během běhu utratit (portrét v běhu na ně nijak nereaguje),
## takže odznáček jen matl. **Odznáček s úrovní hráče (LevelBadge/LevelLabel)
## byl odstraněn stejný den** (explicit user request) - úroveň teď v běhu
## nikde vidět není (jen nepřímo přes vyšší staty, viz LEVEL_STAT_GROWTH),
## zpátky se objeví jen na Game Over/Victory obrazovce po konci běhu.
@onready var portrait_button: Button = $Control/Portrait
@onready var hp_bar: ProgressBar = $Control/HPBar
@onready var hp_label: Label = $Control/HPBar/HPLabel
@onready var hp_regen_label: Label = $Control/HPBar/RegenLabel
@onready var xp_bar: ProgressBar = $Control/XPBar
@onready var xp_label: Label = $Control/XPBar/XPLabel
@onready var gold_label: Label = $Control/GoldLabel
@onready var scrap_label: Label = $Control/ScrapLabel

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
## Aktivní/sklad sekce žijí od 2026-09-27 v CharacterPanel/InventoryTabContent
## (dřív uvnitř ShopPanelu vedle nabídky ke koupi) - obchod teď slouží
## VÝHRADNĚ k nákupu, správa vlastněných itemů (aktivovat/uskladnit/prodat)
## je čistě záležitost Inventáře. GameManager.active_shop_items/
## stash_shop_items a jejich funkce (move_shop_item_to_stash() atd.) se
## touhle změnou vůbec nezměnily, jen se přemístilo UI nad nimi.
@onready var inventory_active_label: Label = $Control/CharacterPanel/InventoryTabContent/ActiveLabel
@onready var inventory_active_container: Control = $Control/CharacterPanel/InventoryTabContent/ActiveItemsContainer
@onready var inventory_stash_label: Label = $Control/CharacterPanel/InventoryTabContent/StashLabel
@onready var inventory_stash_container: Control = $Control/CharacterPanel/InventoryTabContent/StashContainer
## Šířka/mezera miniaturních slotů pro aktivní/sklad itemy v Inventáři -
## vytváří se procedurálně (viz _build_inventory_ui()), ne ručně v hud.tscn,
## protože 6+9=15 skoro identických bloků by bylo zbytečně křehké psát
## ručně. Každý widget je Dictionary {"panel", "label", "buttons": Array}.
const SHOP_MINI_SLOT_WIDTH: float = 74.0
const SHOP_MINI_SLOT_GAP: float = 6.0
var _active_slot_widgets: Array = []
var _stash_slot_widgets: Array = []

## Stejný princip jako obchodní mini-sloty, jen bez tlačítek. Hromádka
## schopností je vlevo nad zemí a POZIČNÍ - jeden slot na KAŽDOU investovanou
## schopnost (rank >= 1, viz _refresh_abilities()), sloupce rostou svisle a
## při ABILITY_STACK_MAX_ROWS se zalomí do dalšího sloupce vpravo - viz
## "Hromádka schopností" v CLAUDE.md (výškový limit dřív hlídal BottomBar,
## ten je od 2026-09-27 pryč, ale zalamování zůstává stejné, jen bez
## konkrétní spodní hranice, kterou by musel respektovat).
const ABILITY_MINI_SLOT_WIDTH: float = 60.0
const ABILITY_MINI_SLOT_HEIGHT: float = 48.0
const ABILITY_MINI_SLOT_GAP: float = 4.0
const ABILITY_STACK_MAX_ROWS: int = 6
@onready var abilities_container: Control = $Control/AbilitiesContainer

## CharacterPanel (přejmenováno z dřívějšího samostatného SkillTreePanel,
## 2026-09-27) - dřív dvouzáložková obrazovka (Inventář/Dovednosti), od
## "Lobby a meta-progrese" (téhož dne, později) jen JEDNA sekce (staty +
## aktivní/sklad itemy) - Dovednosti se přesunuly do scenes/ui/lobby.gd/tscn.
## Otevírá se VŽDY jen kliknutím na portrét (viz portrait_button výše).
@onready var character_panel: Panel = $Control/CharacterPanel
@onready var character_panel_close_button: Button = $Control/CharacterPanel/CloseButton

## Panel volby SCHOPNOSTI (náhodná nabídka, viz "Schopnosti (náhodná
## nabídka)" v CLAUDE.md) - 3 karty, GameManager.ABILITY_CHOICE_COUNT.
## Souběžný systém vedle SkillTreePanelu výše, obnoven 2026-09-26 po zpětné
## vazbě ("schopnosti zachovat, ne nahradit"). Spouštěč: po dopadu (první ze
## dvou intro kroků) a po KAŽDÉ vlně.
@onready var ability_draft_panel: Panel = $Control/AbilityDraftPanel
@onready var ability_cards: Array[Button] = [
	$Control/AbilityDraftPanel/Card0,
	$Control/AbilityDraftPanel/Card1,
	$Control/AbilityDraftPanel/Card2,
]

@onready var game_over_panel: Panel = $Control/GameOverPanel
@onready var game_over_label: Label = $Control/GameOverPanel/Label
## Progres bar META XP (viz "Lobby a meta-progrese" v CLAUDE.md) - žije tady
## místo v lobby (2026-09-28, explicit user request "vyjmout progres bar s
## XP v lobby a dát to pod meta-xp do end-game okénka") - ukazuje AKTUÁLNÍ
## meta_xp/meta_xp_for_next_level() PO připočtení tohohle běhu (_finish_run()
## proběhne dřív, než tenhle panel vůbec zavolá show_game_over(), viz
## GameManager.trigger_game_over()), takže bar rovnou vizualizuje čerstvý zisk.
@onready var game_over_meta_xp_bar: ProgressBar = $Control/GameOverPanel/MetaXPBar
@onready var game_over_meta_xp_label: Label = $Control/GameOverPanel/MetaXPBar/MetaXPLabel
## Ukazuje "+N úroveň" pod barem, dokud animace (viz _animate_meta_xp_gain())
## prochází aspoň jedním META level-upem - schované, dokud animace nedojde
## na první přeplnění baru. Čistě vizuální, viz doc komentář u
## _animate_meta_xp_gain().
@onready var game_over_level_up_label: Label = $Control/GameOverPanel/LevelUpLabel
@onready var game_over_countdown_label: Label = $Control/GameOverPanel/CountdownLabel
@onready var game_over_continue_button: Button = $Control/GameOverPanel/ContinueButton
@onready var victory_panel: Panel = $Control/VictoryPanel
@onready var victory_label: Label = $Control/VictoryPanel/Label
@onready var victory_meta_xp_bar: ProgressBar = $Control/VictoryPanel/MetaXPBar
@onready var victory_meta_xp_label: Label = $Control/VictoryPanel/MetaXPBar/MetaXPLabel
@onready var victory_level_up_label: Label = $Control/VictoryPanel/LevelUpLabel
@onready var victory_countdown_label: Label = $Control/VictoryPanel/CountdownLabel
@onready var victory_continue_button: Button = $Control/VictoryPanel/ContinueButton

@onready var debug_button: Button = $Control/DebugButton
@onready var debug_eye_icon: Control = $Control/DebugButton/EyeIcon
@onready var debug_panel: Panel = $Control/DebugPanel
@onready var debug_kill_button: Button = $Control/DebugPanel/KillButton
@onready var debug_invincible_toggle: Button = $Control/DebugPanel/InvincibleToggle
@onready var debug_kill_all_enemies_button: Button = $Control/DebugPanel/KillAllEnemiesButton
@onready var debug_add_xp_small_button: Button = $Control/DebugPanel/AddXpSmallButton
@onready var debug_add_xp_big_button: Button = $Control/DebugPanel/AddXpBigButton
@onready var debug_add_gold_small_button: Button = $Control/DebugPanel/AddGoldSmallButton
@onready var debug_add_gold_big_button: Button = $Control/DebugPanel/AddGoldBigButton
@onready var debug_add_skill_point_button: Button = $Control/DebugPanel/AddSkillPointButton
@onready var debug_max_skill_tree_button: Button = $Control/DebugPanel/MaxSkillTreeButton
@onready var debug_reset_skill_tree_button: Button = $Control/DebugPanel/ResetSkillTreeButton
## Posune GameManager.survival_time dopředu o 60s - pro rychlé testování
## časových milníků (schopnost/obchod/Elite checkpoint) bez skutečného
## čekání. Nahrazuje dřívější AddLoopButton (kola už neexistují).
@onready var debug_add_survival_time_button: Button = $Control/DebugPanel/AddSurvivalTimeButton
## Bulk přídavek bodů DOVEDNOSTI pro rychlé testování stromu bez grindění
## levelů - NEplete se s ForceAbilityDraftButton/AbilityAutoToggle níže, ty
## se týkají souběžného systému SCHOPNOSTÍ (náhodná nabídka).
@onready var debug_add_many_skill_points_button: Button = $Control/DebugPanel/AddManySkillPointsButton
@onready var debug_force_ability_draft_button: Button = $Control/DebugPanel/ForceAbilityDraftButton
@onready var debug_max_abilities_button: Button = $Control/DebugPanel/MaxAbilitiesButton
@onready var debug_reset_abilities_button: Button = $Control/DebugPanel/ResetAbilitiesButton
@onready var debug_ability_auto_toggle: Button = $Control/DebugPanel/AbilityAutoToggle
@onready var debug_spawn_elite_button: Button = $Control/DebugPanel/SpawnEliteButton
@onready var debug_spawn_ranged_button: Button = $Control/DebugPanel/SpawnRangedButton
@onready var debug_spawn_sniper_button: Button = $Control/DebugPanel/SpawnSniperButton
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

## Dokud je zapnuté, nabídky SCHOPNOSTI (náhodná nabídka) se vyřizují samy
## (náhodný pick) bez zobrazení AbilityDraftPanelu - vypnuto defaultně,
## protože smysl nabídky je, že hráč vidí a dělá skutečnou volbu. Ovládá se
## přes "Auto výběr" v Debug panelu (`AbilityAutoToggle`). NEplete se s
## dovednostním stromem - ten žádnou nabídku nemá, co by šlo auto-řešit.
var _ability_auto_enabled: bool = false
## Poslední nabídnuté schopnosti, každá {"ability_id": String, "rarity": int}
## (viz _on_ability_draft_ready) - potřeba, aby _on_ability_auto_toggled()
## mohl doresit nabídku, na kterou hráč zrovna kouká, i když je zrovna
## otevřená přes AbilityDraftPanel, ne přes Auto větev.
var _last_ability_offer: Array = []


func _ready() -> void:
	GameManager.survival_time_changed.connect(_on_survival_time_changed)
	GameManager.currency_changed.connect(_on_currency_changed)
	GameManager.scrap_changed.connect(_on_scrap_changed)
	GameManager.xp_changed.connect(_on_xp_changed)
	GameManager.level_changed.connect(_on_level_changed)
	GameManager.ability_draft_ready.connect(_on_ability_draft_ready)
	GameManager.ability_inventory_changed.connect(_on_ability_inventory_changed)
	GameManager.shop_inventory_changed.connect(_on_shop_inventory_changed)
	GameManager.shop_offer_changed.connect(_on_shop_offer_changed)
	GameManager.shop_auto_open_requested.connect(_on_shop_auto_open_requested)

	game_over_panel.hide()
	victory_panel.hide()
	shop_panel.hide()
	character_panel.hide()
	ability_draft_panel.hide()

	_setup_shop_cards()
	_build_inventory_ui()

	portrait_button.pressed.connect(_on_portrait_pressed)
	character_panel_close_button.pressed.connect(_on_character_panel_close_pressed)

	shop_close_button.pressed.connect(_on_shop_close_pressed)
	shop_reroll_button.pressed.connect(_on_shop_reroll_pressed)

	game_over_continue_button.pressed.connect(_go_to_lobby)
	game_over_panel.mouse_entered.connect(_on_end_panel_mouse_entered)
	game_over_panel.mouse_exited.connect(_on_end_panel_mouse_exited)

	victory_continue_button.pressed.connect(_go_to_lobby)
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
		_go_to_lobby()
	else:
		_update_end_screen_countdown_label()


## Zavolá Main po vytvoření hráče, aby se HUD napojil na jeho signály a staty.
func connect_player(player: Node2D) -> void:
	player_ref = player
	player.hp_changed.connect(_on_hp_changed)
	_refresh_stat_labels()


## Zavolá Main na sebe - Debug panel potřebuje volat main.gd's
## debug_kill_all_enemies()/debug_spawn_elite() (main.gd vlastní spawnování).
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


func _on_survival_time_changed(new_time: float) -> void:
	survival_time_label.text = "Čas: %s" % GameManager.format_survival_time(new_time)


func _on_currency_changed(new_amount: int) -> void:
	gold_label.text = "Zlato: %d" % new_amount
	if shop_panel.visible:
		_refresh_shop_panel()


func _on_scrap_changed(new_amount: int) -> void:
	scrap_label.text = "Šrot: %d" % new_amount


func _on_xp_changed(current_xp: int, xp_needed: int) -> void:
	xp_bar.max_value = xp_needed
	xp_bar.value = current_xp
	xp_label.text = "XP %d / %d" % [current_xp, xp_needed]


func _on_level_changed(_new_level: int) -> void:
	_refresh_stat_labels()


## Klik na portrét vždy otevře CharacterPanel (jen Inventář - staty + aktivní/
## sklad itemy). Dovednostní strom už tu není (přesunut do lobby, viz doc
## komentář nad hud.gd).
func _on_portrait_pressed() -> void:
	_refresh_inventory_ui()
	character_panel.show()
	get_tree().paused = true


func _on_character_panel_close_pressed() -> void:
	character_panel.hide()
	get_tree().paused = false


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
	# Stejná pojistka jako v _on_ability_pick_pressed() - resolve_ability_draft()
	# mohl synchronně otevřít ShopPanel (odložené auto-otevření obchodu, viz
	# _shop_open_deferred v game_manager.gd).
	if not shop_panel.visible and not character_panel.visible:
		get_tree().paused = false


func _on_ability_inventory_changed() -> void:
	_refresh_abilities()


## Přijde vždy, když je k dispozici nová nabídka SCHOPNOSTI (po dopadu, nebo
## po konci vlny - viz game_manager.gd). S vypnutým Auto výběrem zobrazí
## AbilityDraftPanel a hru pozastaví (stejně jako Obchod) - hráč musí
## vybrat, než se hra pustí dál. Se zapnutým Auto výběrem nabídku rovnou
## vyřídí náhodným pickem bez zastavení hry (viz GameManager.resolve_ability_
## draft() - samo zavolá další nabídku, pokud nějaká čeká).
func _on_ability_draft_ready(offered: Array) -> void:
	_last_ability_offer = offered

	if _ability_auto_enabled:
		var pick_index: int = randi() % offered.size()
		GameManager.resolve_ability_draft(pick_index)
		return

	_show_ability_draft_panel(offered)


func _show_ability_draft_panel(offered: Array) -> void:
	for i in ability_cards.size():
		var card: Button = ability_cards[i]
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
		card.get_node("RarityIcon").rarity_color = GameManager.SHOP_RARITY_COLORS[rarity]

		var already_owned: bool = GameManager.is_ability_owned(ability_id)
		card.get_node("UpgradeIndicator").visible = already_owned

		var result_label: Label = card.get_node("ResultValueLabel")
		if already_owned and rarity < GameManager.ShopRarity.DIAMOND:
			var next_rarity: int = rarity + 1
			result_label.text = "→ %s (%s)" % [
				GameManager.get_ability_value_text(ability_id, next_rarity),
				GameManager.SHOP_RARITY_NAMES[next_rarity],
			]
		else:
			result_label.text = ""

		for connection in card.pressed.get_connections():
			card.pressed.disconnect(connection["callable"])
		card.pressed.connect(_on_ability_pick_pressed.bind(i))

	ability_draft_panel.show()
	get_tree().paused = true


func _on_ability_pick_pressed(offer_index: int) -> void:
	GameManager.resolve_ability_draft(offer_index)
	# resolve_ability_draft() může synchronně vyvolat DALŠÍ ability_draft_ready
	# (víc čekajících nabídek naráz), který už _show_ability_draft_panel()
	# znovu zavolal a panel nechal otevřený s novým obsahem - tady ho proto
	# zavíráme jen když už doopravdy nic dalšího nečeká. Stejně tak může
	# synchronně otevřít ShopPanel (odložené automatické otevření obchodu,
	# viz _shop_open_deferred v game_manager.gd) - odpauzovat smí, jen když
	# ho zrovna NEPŘEVZAL pauzu za nás.
	if GameManager.pending_ability_drafts <= 0:
		ability_draft_panel.hide()
		if not shop_panel.visible and not character_panel.visible:
			get_tree().paused = false


## Hromádka VŠECH vlastněných schopností VLEVO nad zemí (viz AbilitiesContainer
## v hud.tscn) - POZIČNÍ, kombinuje OBA souběžné systémy
## (viz "Schopnosti - DVA SOUBĚŽNÉ..." v game_manager.gd): nejdřív dovednostní
## strom (jeden slot na KAŽDOU schopnost s rank >= 1, v pevném pořadí
## GameManager.ABILITY_ORDER - stabilní pořadí, investování dalšího bodu do
## schopnosti z náhodné nabídky (jeden slot na KAŽDOU vlastněnou INSTANCI z
## owned_abilities, tenhle blok se přeskupuje při sloučení). **Dovednosti
## (skill tree) se v tomhle listu NEUKAZUJÍ** (2026-09-26, explicit user
## request) - fungují čistě jako neviditelný pasivní statistický bonus na
## pozadí (viz get_stat_bonus() v game_manager.gd, kam skill_ranks přispívá
## bez ohledu na to, co se kde zobrazuje), takže i budoucí run se
## zvýhodněným startem (např. hráč začne s už investovanými dovednostmi)
## bude mít vyšší ZÁKLADNÍ staty bez jediné karty navíc v téhle hromádce -
## viditelné schopnosti tu zůstávají výhradně ty z náhodné nabídky. Sloupec
## roste svisle a po ABILITY_STACK_MAX_ROWS se zalomí do dalšího sloupce
## vpravo bez ohledu na to, kolik toho hráč nasbírá.
func _refresh_abilities() -> void:
	for child in abilities_container.get_children():
		child.queue_free()

	var slot_index: int = 0

	for entry in GameManager.owned_abilities:
		var ability_id: String = entry["ability_id"]
		var rarity: int = entry["rarity"]
		var definition: Dictionary = GameManager.ABILITIES[ability_id]
		_create_ability_stack_slot(
			slot_index,
			"%s\n%s" % [definition["short_name"], GameManager.SHOP_RARITY_NAMES[rarity]],
			"%s (%s)\n%s" % [definition["name"], GameManager.SHOP_RARITY_NAMES[rarity], GameManager.get_ability_desc(ability_id, rarity)]
		)
		slot_index += 1


func _create_ability_stack_slot(index: int, label_text: String, tooltip_text: String) -> void:
	var col: int = index / ABILITY_STACK_MAX_ROWS
	var row: int = index % ABILITY_STACK_MAX_ROWS

	var panel := Panel.new()
	panel.position = Vector2(
		col * (ABILITY_MINI_SLOT_WIDTH + ABILITY_MINI_SLOT_GAP),
		row * (ABILITY_MINI_SLOT_HEIGHT + ABILITY_MINI_SLOT_GAP)
	)
	panel.size = Vector2(ABILITY_MINI_SLOT_WIDTH, ABILITY_MINI_SLOT_HEIGHT)
	abilities_container.add_child(panel)

	var label := Label.new()
	label.position = Vector2(2.0, 2.0)
	label.size = Vector2(ABILITY_MINI_SLOT_WIDTH - 4.0, ABILITY_MINI_SLOT_HEIGHT - 4.0)
	label.add_theme_font_size_override("font_size", 8)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.text = label_text
	label.tooltip_text = tooltip_text
	panel.add_child(label)


## Přenačte všechno, co se odvíjí od progrese. Volá se v _ready(), protože
## GameManager přežívá restart scény a HUD se s jeho stavem musí srovnat sám -
## signály při resetu už proběhly dřív, než se HUD stihl připojit.
func _refresh_progression() -> void:
	_on_survival_time_changed(GameManager.survival_time)
	gold_label.text = "Zlato: %d" % GameManager.currency
	scrap_label.text = "Šrot: %d" % GameManager.scrap
	_on_xp_changed(GameManager.player_xp, GameManager.xp_for_next_level())
	_refresh_abilities()
	_refresh_inventory_ui()
	_refresh_stat_labels()


func _refresh_stat_labels() -> void:
	if player_ref == null:
		return
	stat_damage.text = "Poškození: %.0f" % player_ref.get_damage()
	stat_speed.text = "Rychlost: %.1f/s" % player_ref.get_attack_speed()
	stat_range.text = "Dostřel: %.0f" % player_ref.get_attack_range()
	stat_hp.text = "Max HP: %.0f" % player_ref.max_hp
	stat_armor.text = "Brnění: %.0f" % player_ref.get_armor()
	stat_crit.text = "Kritický zásah: %.0f %%" % (player_ref.get_crit_chance() * 100.0)


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
	_refresh_inventory_ui()
	if shop_panel.visible:
		_refresh_shop_panel()


## Nová nabídka (periodické otevření NEBO reroll) - překreslí karty, pokud je
## panel zrovna otevřený (aby byl vždy aktuální).
func _on_shop_offer_changed(_offer_ids: Array) -> void:
	if shop_panel.visible:
		_refresh_shop_panel()


## Jediný způsob, jak se ShopPanel otevírá (tlačítko Obchod bylo odstraněno
## 2026-09-09 - obchod je teď čistě automatický, po GameManager.
## SHOP_OPEN_INTERVAL_SECONDS reálného přežití, viz "Kontinuální spawn/
## obtížnost" v CLAUDE.md). ShopPanel od 2026-09-27 slouží VÝHRADNĚ k
## nákupu - správa vlastněných itemů (aktivovat/uskladnit/prodat) žije v
## CharacterPanel/InventoryTabContent, viz _refresh_inventory_ui() níže.
func _on_shop_auto_open_requested() -> void:
	_refresh_shop_panel()
	shop_panel.show()
	get_tree().paused = true


func _on_shop_reroll_pressed() -> void:
	GameManager.reroll_shop()


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

	_refresh_inventory_ui()


## Vytvoří 6 aktivních + 9 sklad miniaturních slotů PROCEDURÁLNĚ (viz
## _create_inventory_mini_slot()) - psát 15 skoro identických bloků ručně v
## hud.tscn by bylo zbytečně křehké. Volá se jednou v _ready(). Uzly žijí v
## CharacterPanel/InventoryTabContent (přesunuto ze ShopPanelu 2026-09-27,
## viz "CharacterPanel" v CLAUDE.md) - obchod teď slouží jen k nákupu.
func _build_inventory_ui() -> void:
	for i in GameManager.SHOP_ACTIVE_SLOTS:
		var widget: Dictionary = _create_inventory_mini_slot(inventory_active_container, i, ["Uskladnit"])
		widget["buttons"][0].pressed.connect(_on_active_slot_stash_pressed.bind(i))
		_active_slot_widgets.append(widget)

	for i in GameManager.SHOP_STASH_SLOTS:
		var widget: Dictionary = _create_inventory_mini_slot(inventory_stash_container, i, ["Aktivovat", "Prodat"])
		widget["buttons"][0].pressed.connect(_on_stash_slot_activate_pressed.bind(i))
		widget["buttons"][1].pressed.connect(_on_stash_slot_sell_pressed.bind(i))
		_stash_slot_widgets.append(widget)


## Jeden miniaturní slot: Panel s Labelem (2 řádky - krátký název + rarita)
## a N tlačítky pod sebou. Vrací Dictionary s referencemi, aby refresh/
## wiring nemusely znovu procházet strom uzlů přes get_node().
func _create_inventory_mini_slot(parent: Control, index: int, button_texts: Array) -> Dictionary:
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


## Překreslí aktivní/sklad miniaturní sloty a hlavičky "(N/6)"/"(N/9)" v
## Inventáři - volá se z _refresh_shop_panel() (nákup/reroll v otevřeném
## obchodě), _refresh_progression() a _on_shop_inventory_changed(), takže
## zůstává čerstvé i když CharacterPanel zrovna není otevřený (stejný vzor
## jako _refresh_abilities()).
func _refresh_inventory_ui() -> void:
	inventory_active_label.text = "Aktivní itemy (%d/%d)" % [
		GameManager.active_shop_items.size(), GameManager.SHOP_ACTIVE_SLOTS
	]
	inventory_stash_label.text = "Sklad (%d/%d)" % [
		GameManager.stash_shop_items.size(), GameManager.SHOP_STASH_SLOTS
	]

	for i in _active_slot_widgets.size():
		var widget: Dictionary = _active_slot_widgets[i]
		if i < GameManager.active_shop_items.size():
			var entry: Dictionary = GameManager.active_shop_items[i]
			_fill_inventory_mini_slot(widget, entry)
			widget["buttons"][0].disabled = false
		else:
			_clear_inventory_mini_slot(widget)
			widget["buttons"][0].disabled = true

	for i in _stash_slot_widgets.size():
		var widget: Dictionary = _stash_slot_widgets[i]
		if i < GameManager.stash_shop_items.size():
			var entry: Dictionary = GameManager.stash_shop_items[i]
			_fill_inventory_mini_slot(widget, entry)
			widget["buttons"][0].disabled = GameManager.active_shop_items.size() >= GameManager.SHOP_ACTIVE_SLOTS
			widget["buttons"][1].disabled = false
		else:
			_clear_inventory_mini_slot(widget)
			widget["buttons"][0].disabled = true
			widget["buttons"][1].disabled = true


func _fill_inventory_mini_slot(widget: Dictionary, entry: Dictionary) -> void:
	var definition: Dictionary = GameManager.SHOP_ITEMS[entry["item_id"]]
	var label: Label = widget["label"]
	label.text = "%s\n%s" % [definition["short_name"], GameManager.SHOP_RARITY_NAMES[entry["rarity"]]]
	widget["panel"].modulate = Color.WHITE
	label.tooltip_text = "%s (%s)\n%s" % [
		definition["name"], GameManager.SHOP_RARITY_NAMES[entry["rarity"]],
		GameManager.get_shop_item_desc(entry["item_id"], entry["rarity"])
	]


func _clear_inventory_mini_slot(widget: Dictionary) -> void:
	widget["label"].text = "-"
	widget["label"].tooltip_text = ""
	widget["panel"].modulate = LOCKED_ITEM_MODULATE


## Obchod hru pozastaví přes get_tree().paused. HUD má process_mode ALWAYS,
## takže jeho UI dál reaguje. Pauza je zatím záměrná, ale počítá se s tím, že
## se může zrušit - pak stačí vypustit řádky s `paused` (viz CLAUDE.md).
func _on_shop_close_pressed() -> void:
	shop_panel.hide()
	get_tree().paused = false


func show_game_over(survival_time: float, currency: int, meta_xp_gained: int) -> void:
	_close_shop()
	_close_character_panel()
	_close_ability_draft_panel()
	game_over_label.text = "Game Over!\nPřežitý čas: %s\nÚroveň: %d\nZlato: %d\n+%d meta-XP" % [
		GameManager.format_survival_time(survival_time), GameManager.player_level, currency, meta_xp_gained
	]
	game_over_panel.show()
	_start_end_screen_countdown(game_over_countdown_label, "Lobby za")
	_animate_meta_xp_gain(game_over_meta_xp_bar, game_over_meta_xp_label, game_over_level_up_label)


func show_victory(currency: int, meta_xp_gained: int) -> void:
	_close_shop()
	_close_character_panel()
	_close_ability_draft_panel()
	victory_label.text = "Smyčka dokončena!\nÚroveň: %d\nZlato: %d\n+%d meta-XP" % [
		GameManager.player_level, currency, meta_xp_gained
	]
	victory_panel.show()
	_start_end_screen_countdown(victory_countdown_label, "Lobby za")
	_animate_meta_xp_gain(victory_meta_xp_bar, victory_meta_xp_label, victory_level_up_label)


const META_XP_BAR_SEGMENT_DURATION: float = 0.6
const META_XP_BAR_LEVEL_UP_PAUSE: float = 0.25

## Animuje META XP bar od stavu PŘED tímhle během (GameManager.last_run_
## summary's meta_level_before/meta_xp_before) k aktuálnímu, už FINÁLNÍMU
## stavu (GameManager.meta_level/meta_xp - _finish_run() ho nastavil dřív,
## viz trigger_game_over()/trigger_win() v game_manager.gd, dřív než tahle
## funkce vůbec doběhla zavolat show_game_over()/show_victory()). Explicit
## user request 2026-09-28 - čistě vizuální dohánění: skutečný herní stav
## (meta_level/meta_xp/pending_skill_points) je hotový hned, tahle coroutine
## jen kreslí, JAK se k němu došlo. Pokud hráč klikne "Pokračovat" (→
## _go_to_lobby()) nebo countdown doběhne dřív, než animace skončí, na nic to
## nemá vliv - lobby čte rovnou finální GameManager stav, ne nic z týhle
## animace. Přeteče-li bar víckrát (víc META level-upů z jednoho běhu), pod
## barem se objeví "+N úroveň", kde N postupně roste s každým přeplněním.
## `is_instance_valid(bar)` kontrola po každém `await` bezpečně ukončí
## animaci, kdyby mezitím scéna zmizela (change_scene_to_file), místo pádu na
## přístupu ke smazanému uzlu.
func _animate_meta_xp_gain(bar: ProgressBar, label: Label, level_up_label: Label) -> void:
	level_up_label.hide()
	level_up_label.text = ""

	var summary: Dictionary = GameManager.last_run_summary
	var level: int = summary.get("meta_level_before", GameManager.meta_level)
	var xp: int = summary.get("meta_xp_before", GameManager.meta_xp)
	var final_xp: int = GameManager.meta_xp
	var levels_gained: int = GameManager.meta_level - level

	bar.max_value = GameManager.meta_xp_for_next_level(level)
	bar.value = xp
	label.text = "%d / %d" % [xp, int(bar.max_value)]

	for i in levels_gained:
		await _tween_meta_xp_bar(bar, label, GameManager.meta_xp_for_next_level(level))
		if not is_instance_valid(bar):
			return

		level += 1
		level_up_label.text = "+%d úroveň" % (i + 1)
		level_up_label.show()

		bar.value = 0
		bar.max_value = GameManager.meta_xp_for_next_level(level)
		label.text = "0 / %d" % int(bar.max_value)

		await get_tree().create_timer(META_XP_BAR_LEVEL_UP_PAUSE).timeout
		if not is_instance_valid(bar):
			return

	await _tween_meta_xp_bar(bar, label, final_xp)


## Jeden segment animace - plynule převede bar.value (a text labelu s ním) z
## AKTUÁLNÍ hodnoty na `target`; bar.max_value beze změny, o tu se stará
## volající (_animate_meta_xp_gain()), protože se mezi segmenty mění (jiná
## META úroveň = jiný práh). tween_method() místo tween_property() na
## bar.value, ať se text labelu překreslí při KAŽDÉM kroku tweenu, ne jen na
## jeho konci.
func _tween_meta_xp_bar(bar: ProgressBar, label: Label, target: int) -> void:
	var max_value: int = int(bar.max_value)
	var tween := create_tween()
	tween.tween_method(
		func(v: float):
			bar.value = v
			label.text = "%d / %d" % [int(round(v)), max_value],
		bar.value, float(target), META_XP_BAR_SEGMENT_DURATION
	)
	await tween.finished


func _close_shop() -> void:
	shop_panel.hide()
	get_tree().paused = false


## Nouzové zavření - Debug panel má process_mode ALWAYS, takže "Zabít postavu"
## zafunguje i přes pauzu otevřeného stromu; kdyby to vyvolalo Game Over
## uprostřed otevřeného panelu, tohle ho zavře stejně jako _close_shop() dělá
## pro Obchod.
func _close_character_panel() -> void:
	character_panel.hide()
	get_tree().paused = false


## Stejná nouzová logika, pro AbilityDraftPanel (náhodná nabídka schopností).
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


## Konec běhu (smrt nebo dokončení smyčky) vede do lobby, ne do restartu na
## místě - main.tscn se znovu spustí až po kliknutí na "Další běh" v lobby
## (viz scenes/ui/lobby.gd), ne automaticky. GameManager je autoload a scénu
## přežije beze změny, takže last_run_summary/meta stav je pro lobby.gd
## dostupný okamžitě po přechodu.
func _go_to_lobby() -> void:
	_end_screen_countdown_active = false
	game_over_panel.hide()
	victory_panel.hide()
	character_panel.hide()
	ability_draft_panel.hide()
	get_tree().paused = false
	get_tree().change_scene_to_file("res://scenes/ui/lobby.tscn")


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
	debug_kill_all_enemies_button.pressed.connect(_on_debug_kill_all_enemies_pressed)
	debug_add_xp_small_button.pressed.connect(func(): GameManager.add_xp(100))
	debug_add_xp_big_button.pressed.connect(func(): GameManager.add_xp(500))
	debug_add_gold_small_button.pressed.connect(func(): GameManager.debug_add_currency(100))
	debug_add_gold_big_button.pressed.connect(func(): GameManager.debug_add_currency(1000))
	debug_add_skill_point_button.pressed.connect(func(): GameManager.debug_add_skill_point())
	debug_max_skill_tree_button.pressed.connect(func(): GameManager.debug_max_skill_tree())
	debug_reset_skill_tree_button.pressed.connect(func(): GameManager.debug_reset_skill_tree())
	debug_add_survival_time_button.pressed.connect(func(): GameManager.debug_add_survival_time(60.0))
	debug_spawn_elite_button.pressed.connect(_on_debug_spawn_elite_pressed)
	debug_spawn_ranged_button.pressed.connect(_on_debug_spawn_ranged_pressed)
	debug_spawn_sniper_button.pressed.connect(_on_debug_spawn_sniper_pressed)
	debug_add_many_skill_points_button.pressed.connect(func():
		for i in 5:
			GameManager.debug_add_skill_point()
	)
	debug_force_ability_draft_button.pressed.connect(func(): GameManager.debug_force_ability_draft())
	debug_max_abilities_button.pressed.connect(func(): GameManager.debug_max_abilities())
	debug_reset_abilities_button.pressed.connect(func(): GameManager.debug_reset_abilities())
	debug_ability_auto_toggle.button_pressed = _ability_auto_enabled
	debug_ability_auto_toggle.toggled.connect(_on_ability_auto_toggled)
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


func _on_debug_kill_all_enemies_pressed() -> void:
	if main_ref != null:
		main_ref.debug_kill_all_enemies()


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
