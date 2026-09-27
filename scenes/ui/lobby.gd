extends Control
## Klidná obrazovka MEZI běhy (viz "Lobby a meta-progrese" v CLAUDE.md,
## 2026-09-27) - ukazuje souhrn právě skončeného běhu, nechá hráče investovat
## TRVALÉ meta body do dovednostního stromu (přesunuto beze změny logiky z
## dřívějšího hud.gd/CharacterPanel - jen se přesunula obrazovka, ne
## GameManager.SKILL_TREE_BRANCHES/invest_skill_point() pod tím) a spustí
## další běh. GameManager je autoload a scénu přežije beze změny -
## last_run_summary/meta_level/meta_xp/skill_ranks jsou tu dostupné okamžitě
## po přechodu z hud.gd's _go_to_lobby().

const LOCKED_ITEM_MODULATE := Color(0.45, 0.45, 0.52)
## Rozměry jednoho uzlu stromu a mřížky - 4 sloupce (větve, viz
## GameManager.SKILL_TREE_BRANCHES), max 3 řádky (nejdelší větev). Stejné
## hodnoty jako dřív v hud.gd.
const SKILL_NODE_WIDTH: float = 170.0
const SKILL_NODE_HEIGHT: float = 150.0
const SKILL_NODE_GAP: float = 10.0

@onready var summary_label: Label = $SummaryLabel
@onready var meta_level_label: Label = $MetaLevelLabel
@onready var meta_xp_bar: ProgressBar = $MetaXPBar
@onready var meta_xp_label: Label = $MetaXPBar/MetaXPLabel
@onready var skill_points_label: Label = $SkillPointsLabel
@onready var nodes_container: Control = $NodesContainer
@onready var next_run_button: Button = $NextRunButton

## Dictionary {ability_id: {"panel", "name_label", "rank_label", "desc_label",
## "button"}} - postaveno jednou v _ready(), znovu použito při každém
## _refresh_skill_tree_ui() (žádné přestavování stromu za běhu).
var _skill_node_widgets: Dictionary = {}


func _ready() -> void:
	GameManager.skill_points_changed.connect(_on_skill_points_changed)
	GameManager.skill_ranks_changed.connect(_on_skill_ranks_changed)
	GameManager.meta_level_changed.connect(_on_meta_level_changed)

	next_run_button.pressed.connect(_on_next_run_pressed)

	_show_run_summary()
	_build_skill_tree_ui()
	_refresh_meta_ui()


## GameManager.last_run_summary je vždycky naplněné, když sem hráč dorazí
## normální cestou (_finish_run() ho nastaví PŘED přechodem sem, viz
## trigger_game_over()/trigger_win()) - prázdné jen při ručním otevření téhle
## scény samotné v editoru (F6), proto ten fallback.
func _show_run_summary() -> void:
	var summary: Dictionary = GameManager.last_run_summary
	if summary.is_empty():
		summary_label.text = "Vítej!"
		return

	var reason_text: String = (
		"Smyčka dokončena!" if summary.get("reason") == "completed" else "Zemřel jsi."
	)
	summary_label.text = "%s\nÚroveň: %d   Zlato: %d   +%d meta-XP" % [
		reason_text, summary.get("level", 1), summary.get("currency", 0), summary.get("meta_xp_gained", 0),
	]


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
	skill_points_label.text = "Dostupné body dovednosti: %d" % GameManager.pending_skill_points


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


## Spustí main.tscn znovu - main.gd's _enter_tree() zavolá GameManager.
## reset_game(), který smaže run-scoped stav (survival_time/currency/scrap/
## player_level/owned_abilities/shop...), ale NECHÁ meta_level/meta_xp/
## pending_skill_points/skill_ranks beze změny (viz jejich komentáře v
## game_manager.gd) - investice odsud tak permanentně zvýší základní staty
## i v novém běhu.
func _on_next_run_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/main.tscn")
