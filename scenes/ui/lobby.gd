extends Control
## Klidná obrazovka MEZI běhy (viz "Lobby a meta-progrese" v CLAUDE.md,
## 2026-09-27) - TRVALý dovednostní strom (přesunuto beze změny logiky z
## dřívějšího hud.gd/CharacterPanel - jen se přesunula obrazovka, ne
## GameManager.SKILL_TREE_BRANCHES/invest_skill_point() pod tím) a obchod
## (druhý tab, reuse GameManager.shop_offer/buy_shop_item()/reroll_shop() -
## stejná run-scoped data, jaká v běhu otvírá periodický časovač) a tlačítko
## na spuštění dalšího běhu. GameManager je autoload a scénu přežije beze
## změny - meta_level/meta_xp/skill_ranks i run-scoped currency/shop_offer
## JSOU tu dostupné okamžitě po přechodu z hud.gd's _go_to_lobby().
##
## **Obchod je v lobby VŽDY dostupný** (2026-09-28, explicit user request) -
## na rozdíl od v běhu (kde čeká na SHOP_OPEN_INTERVAL_SECONDS), `_ready()`
## zavolá `_ensure_shop_offer()`, které nabídku rovnou vygeneruje, pokud
## aktuální běh ještě žádnou neotevřel (typicky když hráč zemře brzy). Pokud
## nabídka z proběhlého běhu už existuje, necháme ji beze změny.
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
## Šířka/mezera miniaturních slotů pro aktivní/sklad itemy - stejné hodnoty
## a stejný _create_inventory_mini_slot() vzor jako dřívější hud.gd (viz
## "CharacterPanel" v CLAUDE.md), teď duplikované sem, protože Obchod v
## lobby ukazuje aktivní/sklad itemy vedle nabídky ke koupi (explicit user
## request 2026-09-28 - "může shop v lobby ukazovat taky UI s aktivními
## předměty hráče a stash jako u ingame shopu?").
const SHOP_MINI_SLOT_WIDTH: float = 74.0
const SHOP_MINI_SLOT_GAP: float = 6.0

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
@onready var inventory_active_label: Label = $ShopTabContent/ActiveLabel
@onready var inventory_active_container: Control = $ShopTabContent/ActiveItemsContainer
@onready var inventory_stash_label: Label = $ShopTabContent/StashLabel
@onready var inventory_stash_container: Control = $ShopTabContent/StashContainer

@onready var next_run_button: Button = $NextRunButton

## Dictionary {ability_id: {"panel", "name_label", "rank_label", "desc_label",
## "button"}} - postaveno jednou v _ready(), znovu použito při každém
## _refresh_skill_tree_ui() (žádné přestavování stromu za běhu).
var _skill_node_widgets: Dictionary = {}
## Stejný princip jako u dovednostního stromu - Dictionary {"panel", "label",
## "buttons": Array} na slot, postaveno jednou v _build_inventory_ui().
var _active_slot_widgets: Array = []
var _stash_slot_widgets: Array = []


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
	_build_inventory_ui()

	_ensure_shop_offer()
	_build_skill_tree_ui()
	_refresh_meta_ui()
	_on_currency_changed(GameManager.currency)
	_set_active_tab(true)


## Obchod je v lobby VŽDY dostupný (explicit user request 2026-09-28) -
## na rozdíl od v běhu, kde se odemyká až periodickým časovačem
## (SHOP_OPEN_INTERVAL_SECONDS). Pokud aktuální běh obchod ještě neotevřel
## (nebo právě začínáme v lobby s čerstvým GameManagerem), rovnou mu
## vygenerujeme nabídku stejným mechanismem, jaký by jinak spustil časovač -
## existující nabídku z proběhlého běhu naopak necháme beze změny.
func _ensure_shop_offer() -> void:
	if not GameManager.shop_available or GameManager.shop_offer.is_empty():
		GameManager.shop_available = true
		GameManager._generate_shop_offer()


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
## v mřížce 4 sloupce (větve) x max 3 řádky (nejdelší větev). **Celá dlaždice
## je sama o sobě `Button`** (2026-09-28, explicit user request - "ať v nich
## nejsou tlačítka a jsou celé dlaždice klikatelné jako v panelu výběru
## schopností") - stejný vzor jako `Card0..2` v `AbilityDraftPanel`
## (`hud.tscn`/`hud.gd`'s `_show_ability_draft_panel()`): žádné samostatné
## "Investovat" tlačítko uvnitř, klik kdekoliv na dlaždici rovnou investuje.
## Popisky (Název/Stupeň/Popis) jsou potomci tlačítka, ne obráceně.
func _build_skill_tree_ui() -> void:
	for col in GameManager.SKILL_TREE_BRANCHES.size():
		var branch: Array = GameManager.SKILL_TREE_BRANCHES[col]
		for row in branch.size():
			var ability_id: String = branch[row]

			var tile := Button.new()
			tile.name = "SkillNode_%s" % ability_id
			tile.position = Vector2(
				col * (SKILL_NODE_WIDTH + SKILL_NODE_GAP), row * (SKILL_NODE_HEIGHT + SKILL_NODE_GAP)
			)
			tile.size = Vector2(SKILL_NODE_WIDTH, SKILL_NODE_HEIGHT)
			tile.pressed.connect(_on_skill_node_pressed.bind(ability_id))
			nodes_container.add_child(tile)

			var name_label := Label.new()
			name_label.name = "NameLabel"
			name_label.position = Vector2(6.0, 4.0)
			name_label.size = Vector2(SKILL_NODE_WIDTH - 12.0, 34.0)
			name_label.add_theme_font_size_override("font_size", 13)
			name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
			tile.add_child(name_label)

			var rank_label := Label.new()
			rank_label.name = "RankLabel"
			rank_label.position = Vector2(6.0, 38.0)
			rank_label.size = Vector2(SKILL_NODE_WIDTH - 12.0, 16.0)
			rank_label.add_theme_font_size_override("font_size", 11)
			rank_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			rank_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
			tile.add_child(rank_label)

			var desc_label := Label.new()
			desc_label.name = "DescLabel"
			desc_label.position = Vector2(6.0, 56.0)
			desc_label.size = Vector2(SKILL_NODE_WIDTH - 12.0, 88.0)
			desc_label.add_theme_font_size_override("font_size", 10)
			desc_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			desc_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
			tile.add_child(desc_label)

			_skill_node_widgets[ability_id] = {
				"panel": tile, "name_label": name_label, "rank_label": rank_label,
				"desc_label": desc_label, "button": tile,
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
			widget["button"].disabled = true
			continue

		widget["panel"].modulate = Color.WHITE
		widget["rank_label"].text = "Stupeň %d/%d" % [rank, max_rank]
		# Na stupni 0 (odemčeno, ale zatím neinvestováno) rovnou ukážeme
		# efekt PRVNÍHO stupně místo prázdného textu, stejně jako dřív v HUD.
		widget["desc_label"].text = GameManager.get_skill_node_desc(ability_id, max(rank, 1))
		# Dlaždice sama nese žádný stavový text ("Investovat"/"Max") - stejně
		# jako AbilityDraftPanel's karty, disabled stav (ztlumené tlačítko)
		# spolu s "Stupeň N/M" (kde N==M už samo říká "Max") stačí.
		widget["button"].disabled = rank >= max_rank or not GameManager.can_invest_skill_point(ability_id)


## Napojí každou kartu na její SLOT INDEX v GameManager.shop_offer. **Celá
## karta je sama `Button`** (2026-09-28, stejná změna a stejný důvod jako u
## dovednostních dlaždic výše - žádné samostatné "Koupit" tlačítko, klik
## kdekoliv na kartu rovnou koupí, stejný vzor jako AbilityDraftPanel's
## Card0..2).
func _setup_shop_cards() -> void:
	for i in shop_cards.size():
		var card: Button = shop_cards[i]
		card.pressed.connect(_on_shop_card_action_pressed.bind(i))


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


## Obchod je v lobby vždy dostupný (viz _ensure_shop_offer()), takže tahle
## funkce se na rozdíl od dřívější verze nemusí ptát, jestli vůbec něco
## nabídnout - GameManager.shop_offer má vždy SHOP_OFFER_SIZE položek.
func _refresh_shop_tab() -> void:
	for i in shop_cards.size():
		var card: Button = shop_cards[i]

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
		card.disabled = not GameManager.can_buy_shop_item(i)

	shop_reroll_button.text = "Přehodit (%d)" % GameManager.get_shop_reroll_cost()
	shop_reroll_button.disabled = not GameManager.can_reroll_shop()

	_refresh_inventory_ui()


## Vytvoří 6 aktivních + 9 sklad miniaturních slotů PROCEDURÁLNĚ - přesunuto
## beze změny logiky z dřívějšího hud.gd's _build_inventory_ui() (viz
## "CharacterPanel" v CLAUDE.md pro historii, "Lobby a meta-progrese" pro
## proč obchod teď žije tady). Volá se jednou v _ready().
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
## a N tlačítky pod sebou - identické tělo jako dřívější hud.gd's
## _create_inventory_mini_slot().
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


## Překreslí aktivní/sklad miniaturní sloty a hlavičky "(N/6)"/"(N/9)" -
## volá se z _refresh_shop_tab(), takže zůstává čerstvé pokaždé, když se
## Obchod tab otevře nebo se cokoliv v nabídce/inventáři změní.
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


## Spustí main.tscn znovu - main.gd's _enter_tree() zavolá GameManager.
## reset_game(), který smaže run-scoped stav (survival_time/currency/scrap/
## player_level/owned_abilities/shop...), ale NECHÁ meta_level/meta_xp/
## pending_skill_points/skill_ranks beze změny (viz jejich komentáře v
## game_manager.gd) - investice odsud tak permanentně zvýší základní staty
## i v novém běhu.
func _on_next_run_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/main.tscn")
