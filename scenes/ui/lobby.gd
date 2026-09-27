extends Control
## Klidná obrazovka MEZI běhy (viz "Lobby a meta-progrese" v CLAUDE.md,
## 2026-09-27) - TRVALý dovednostní strom (přesunuto beze změny logiky z
## dřívějšího hud.gd/CharacterPanel - jen se přesunula obrazovka, ne
## GameManager.SKILL_TREE_BRANCHES/invest_skill_point() pod tím), obchod
## (druhý tab, reuse GameManager.shop_offer/buy_shop_item()/reroll_shop() -
## stejná run-scoped nabídka, kterou v běhu otvírá periodický časovač, tady
## jen navíc přístupná manuálně než se run-scoped stav při "Další běh" smaže)
## a tlačítko na spuštění dalšího běhu. GameManager je autoload a scénu
## přežije beze změny - meta_level/meta_xp/skill_ranks i run-scoped
## currency/shop_offer JSOU tu dostupné okamžitě po přechodu z hud.gd's
## _go_to_lobby().
##
## STALE (2026-09-27, později téhož dne): dřív tu byl navrch souhrn právě
## skončeného běhu (`last_run_summary` - "Zemřel jsi."/"Smyčka dokončena!" +
## úroveň/zlato/meta-XP) - odstraněno na explicit user request, obrazovka teď
## začíná rovnou na dovednostech/obchodu. `GameManager.last_run_summary` se
## dál plní (`_finish_run()`), jen se tu už nezobrazuje.

const LOCKED_ITEM_MODULATE := Color(0.45, 0.45, 0.52)
## Rozměry jednoho uzlu stromu a mřížky - 4 sloupce (větve, viz
## GameManager.SKILL_TREE_BRANCHES), max 3 řádky (nejdelší větev). Stejné
## hodnoty jako dřív v hud.gd.
const SKILL_NODE_WIDTH: float = 170.0
const SKILL_NODE_HEIGHT: float = 150.0
const SKILL_NODE_GAP: float = 10.0

@onready var meta_level_label: Label = $MetaLevelLabel
@onready var meta_xp_bar: ProgressBar = $MetaXPBar
@onready var meta_xp_label: Label = $MetaXPBar/MetaXPLabel
@onready var gold_label: Label = $GoldLabel

@onready var dovednosti_tab_button: Button = $DovednostiTabButton
@onready var obchod_tab_button: Button = $ObchodTabButton
@onready var skill_points_badge: ColorRect = $SkillPointsBadge
@onready var skill_points_badge_label: Label = $SkillPointsBadge/SkillPointsBadgeLabel

@onready var nodes_container: Control = $NodesContainer
@onready var shop_tab_content: Control = $ShopTabContent
@onready var shop_cards: Array = [
	$ShopTabContent/ShopCard0,
	$ShopTabContent/ShopCard1,
	$ShopTabContent/ShopCard2,
	$ShopTabContent/ShopCard3,
]
@onready var shop_reroll_button: Button = $ShopTabContent/RerollButton
@onready var shop_empty_label: Label = $ShopTabContent/ShopEmptyLabel

@onready var next_run_button: Button = $NextRunButton

## Dictionary {ability_id: {"panel", "name_label", "rank_label", "desc_label",
## "button"}} - postaveno jednou v _ready(), znovu použito při každém
## _refresh_skill_tree_ui() (žádné přestavování stromu za běhu).
var _skill_node_widgets: Dictionary = {}


func _ready() -> void:
	GameManager.skill_points_changed.connect(_on_skill_points_changed)
	GameManager.skill_ranks_changed.connect(_on_skill_ranks_changed)
	GameManager.meta_level_changed.connect(_on_meta_level_changed)
	GameManager.currency_changed.connect(_on_currency_changed)
	GameManager.shop_offer_changed.connect(_on_shop_offer_changed)
	GameManager.shop_inventory_changed.connect(_on_shop_inventory_changed)

	dovednosti_tab_button.pressed.connect(_on_dovednosti_tab_pressed)
	obchod_tab_button.pressed.connect(_on_obchod_tab_pressed)
	next_run_button.pressed.connect(_on_next_run_pressed)
	_setup_shop_cards()
	shop_reroll_button.pressed.connect(_on_shop_reroll_pressed)

	_build_skill_tree_ui()
	_refresh_meta_ui()
	_on_currency_changed(GameManager.currency)
	_set_active_tab(true)


func _on_meta_level_changed(_new_level: int) -> void:
	_refresh_meta_ui()


func _on_skill_points_changed(_new_amount: int) -> void:
	_refresh_meta_ui()
	_refresh_skill_tree_ui()


func _on_skill_ranks_changed() -> void:
	_refresh_skill_tree_ui()


func _refresh_meta_ui() -> void:
	meta_level_label.text = "Meta úroveň: %d" % GameManager.meta_level
	meta_xp_bar.max_value = GameManager.meta_xp_for_next_level()
	meta_xp_bar.value = GameManager.meta_xp
	meta_xp_label.text = "%d / %d" % [GameManager.meta_xp, GameManager.meta_xp_for_next_level()]

	var pending: int = GameManager.pending_skill_points
	skill_points_badge.visible = pending > 0
	skill_points_badge_label.text = "+%d" % pending


func _on_currency_changed(new_amount: int) -> void:
	gold_label.text = "Zlato: %d" % new_amount
	if shop_tab_content.visible:
		_refresh_shop_tab()


## Přepne mezi dvěma taby (Dovednosti/Obchod) - stejný vzor jako dřívější
## CharacterPanel v hud.gd (bílá = aktivní, LOCKED_ITEM_MODULATE = neaktivní).
func _set_active_tab(show_dovednosti: bool) -> void:
	nodes_container.visible = show_dovednosti
	shop_tab_content.visible = not show_dovednosti
	dovednosti_tab_button.modulate = Color.WHITE if show_dovednosti else LOCKED_ITEM_MODULATE
	obchod_tab_button.modulate = LOCKED_ITEM_MODULATE if show_dovednosti else Color.WHITE

	if not show_dovednosti:
		_refresh_shop_tab()


func _on_dovednosti_tab_pressed() -> void:
	_set_active_tab(true)


func _on_obchod_tab_pressed() -> void:
	_set_active_tab(false)


## Postaví jeden uzel na KAŽDOU schopnost ve GameManager.SKILL_TREE_BRANCHES,
## v mřížce 4 sloupce (větve) x max 3 řádky (nejdelší větev) - přesunuto beze
## změny logiky z dřívějšího hud.gd's _build_skill_tree_ui() (viz "Lobby a
## meta-progrese" v CLAUDE.md, 2026-09-27).
func _build_skill_tree_ui() -> void:
	for col in GameManager.SKILL_TREE_BRANCHES.size():
		var branch: Array = GameManager.SKILL_TREE_BRANCHES[col]
		for row in branch.size():
			var ability_id: String = branch[row]

			var panel := Panel.new()
			panel.name = "SkillNode_%s" % ability_id
			panel.position = Vector2(
				col * (SKILL_NODE_WIDTH + SKILL_NODE_GAP), row * (SKILL_NODE_HEIGHT + SKILL_NODE_GAP)
			)
			panel.size = Vector2(SKILL_NODE_WIDTH, SKILL_NODE_HEIGHT)
			nodes_container.add_child(panel)

			var name_label := Label.new()
			name_label.name = "NameLabel"
			name_label.position = Vector2(6.0, 4.0)
			name_label.size = Vector2(SKILL_NODE_WIDTH - 12.0, 34.0)
			name_label.add_theme_font_size_override("font_size", 13)
			name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			panel.add_child(name_label)

			var rank_label := Label.new()
			rank_label.name = "RankLabel"
			rank_label.position = Vector2(6.0, 38.0)
			rank_label.size = Vector2(SKILL_NODE_WIDTH - 12.0, 16.0)
			rank_label.add_theme_font_size_override("font_size", 11)
			rank_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			panel.add_child(rank_label)

			var desc_label := Label.new()
			desc_label.name = "DescLabel"
			desc_label.position = Vector2(6.0, 56.0)
			desc_label.size = Vector2(SKILL_NODE_WIDTH - 12.0, 58.0)
			desc_label.add_theme_font_size_override("font_size", 10)
			desc_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			panel.add_child(desc_label)

			var button := Button.new()
			button.name = "ActionButton"
			button.position = Vector2(6.0, 116.0)
			button.size = Vector2(SKILL_NODE_WIDTH - 12.0, 28.0)
			button.pressed.connect(_on_skill_node_pressed.bind(ability_id))
			panel.add_child(button)

			_skill_node_widgets[ability_id] = {
				"panel": panel, "name_label": name_label, "rank_label": rank_label,
				"desc_label": desc_label, "button": button,
			}

	_refresh_skill_tree_ui()


func _on_skill_node_pressed(ability_id: String) -> void:
	GameManager.invest_skill_point(ability_id)


## Překreslí zbývající body a všechny uzly - volá se při stavbě a při každé
## změně bodů/ranků (na rozdíl od dřívějšího hud.gd, tahle scéna je vždycky
## vidět, dokud je aktivní, takže žádný ".visible" guard není potřeba).
func _refresh_skill_tree_ui() -> void:
	for ability_id in _skill_node_widgets:
		var widget: Dictionary = _skill_node_widgets[ability_id]
		var definition: Dictionary = GameManager.ABILITIES[ability_id]
		var rank: int = GameManager.get_skill_rank(ability_id)
		var max_rank: int = GameManager.get_skill_max_rank(ability_id)
		var unlocked: bool = GameManager.is_skill_node_unlocked(ability_id)

		widget["name_label"].text = definition["name"]

		if not unlocked:
			widget["panel"].modulate = LOCKED_ITEM_MODULATE
			widget["rank_label"].text = "Zamčeno"
			widget["desc_label"].text = ""
			widget["button"].text = "Zamčeno"
			widget["button"].disabled = true
			continue

		widget["panel"].modulate = Color.WHITE
		widget["rank_label"].text = "Stupeň %d/%d" % [rank, max_rank]
		# Na stupni 0 (odemčeno, ale zatím neinvestováno) rovnou ukážeme
		# efekt PRVNÍHO stupně místo prázdného textu, stejně jako dřív v HUD.
		widget["desc_label"].text = GameManager.get_skill_node_desc(ability_id, max(rank, 1))

		if rank >= max_rank:
			widget["button"].text = "Max"
			widget["button"].disabled = true
		else:
			widget["button"].text = "Investovat"
			widget["button"].disabled = not GameManager.can_invest_skill_point(ability_id)


## Napojí každou kartu na její SLOT INDEX v GameManager.shop_offer - stejný
## vzor jako dřívější hud.gd's _setup_shop_cards() (ShopPanel v běhu, beze
## změny logiky/GameManageru, jen druhá UI nad stejnými daty).
func _setup_shop_cards() -> void:
	for i in shop_cards.size():
		var card: Panel = shop_cards[i]
		var action_button: Button = card.get_node("ActionButton")
		action_button.pressed.connect(_on_shop_card_action_pressed.bind(i))


func _on_shop_card_action_pressed(slot_index: int) -> void:
	GameManager.buy_shop_item(slot_index)


func _on_shop_offer_changed(_offer_ids: Array) -> void:
	if shop_tab_content.visible:
		_refresh_shop_tab()


func _on_shop_inventory_changed() -> void:
	if shop_tab_content.visible:
		_refresh_shop_tab()


func _on_shop_reroll_pressed() -> void:
	GameManager.reroll_shop()


## Obchod je pořád run-scoped (GameManager.shop_available/shop_offer se
## resetují v reset_game()) - dokud se v aktuálním běhu ještě neotevřel
## periodický časovač, není co nabízet. ShopEmptyLabel to řekne přímo místo
## tichého prázdného tabu.
func _refresh_shop_tab() -> void:
	var has_offer: bool = GameManager.shop_available and not GameManager.shop_offer.is_empty()
	shop_empty_label.visible = not has_offer
	shop_reroll_button.visible = has_offer

	for i in shop_cards.size():
		var card: Panel = shop_cards[i]

		if not has_offer or i >= GameManager.shop_offer.size():
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

	if has_offer:
		shop_reroll_button.text = "Přehodit (%d)" % GameManager.get_shop_reroll_cost()
		shop_reroll_button.disabled = not GameManager.can_reroll_shop()


## Spustí main.tscn znovu - main.gd's _enter_tree() zavolá GameManager.
## reset_game(), který smaže run-scoped stav (survival_time/currency/scrap/
## player_level/owned_abilities/shop...), ale NECHÁ meta_level/meta_xp/
## pending_skill_points/skill_ranks beze změny (viz jejich komentáře v
## game_manager.gd) - investice odsud tak permanentně zvýší základní staty
## i v novém běhu.
func _on_next_run_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/main.tscn")
