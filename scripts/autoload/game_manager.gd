extends Node
## Globální singleton (Autoload) - řídí vlny nepřátel, měnu, zkušenosti,
## úrovně hráče a jeho vylepšení. Zaregistrován v Project Settings > Autoload
## jako "GameManager".

signal wave_started(wave_number: int)
signal wave_cleared(wave_number: int)
signal game_over_triggered
signal game_won_triggered
signal currency_changed(new_amount: int)
signal xp_changed(current_xp: int, xp_needed: int)
signal level_changed(new_level: int)
## Emitne se, když je k dispozici nová nabídka itemů k výběru (viz
## "Item/loot draft" níže) - HUD podle toho buď zobrazí DraftPanel, nebo
## (má-li zapnutý Auto výběr) rovnou zavolá resolve_draft() sám.
signal item_draft_ready(offered_ids: Array)
signal item_rank_changed(item_id: String, new_rank: int)
signal loop_changed(new_loop: int)
## Emitne se po nákupu nebo prodeji v obchodě - viz "Obchod" níže.
signal shop_inventory_changed

enum State { INTRO, PLAYING, GAME_OVER, WON }

## Po vyčištění téhle vlny se hra NEKONČÍ, ale spustí se další "kolo" (loop) -
## viz _on_wave_cleared()/_start_new_loop(). State.WON a VictoryPanel jsou teď
## nedosažitelné běžnou hrou, ale záměrně ponechané pro budoucí skutečný konec
## (např. až budou existovat i další planety/levely).
const FINAL_WAVE: int = 10

## O kolik procent víc HP dostanou nově spawnutí nepřátelé za každé další
## odehrané kolo (kolo 1 = žádný bonus). PROZATÍMNÍ jednoduché lineární
## škálování jen přes HP - do budoucna se čeká na komplexnější systém
## (nové typy nepřátel, jiné staty, ...), viz get_enemy_hp_multiplier().
const ENEMY_HP_GROWTH_PER_LOOP: float = 0.5

## XP potřebné na 2. úroveň; každá další úroveň stojí o XP_PER_LEVEL_GROWTH víc.
## Sníženo z 60 na 40, aby první level-up padl už ve vlně 1, ne až v půlce vlny 2.
const XP_BASE: int = 40
const XP_PER_LEVEL_GROWTH: int = 40

## --- Item/loot draft --------------------------------------------------
## Náhrada za dřívější strom schopností (Q/W/E/R). Místo utrácení bodů do
## pevně daných 4 schopností si hráč při každém level-upu vybírá 1 ze 3
## náhodně nabídnutých itemů - stejný princip jako "level-up card" ve
## Vampire Survivors. Efekt je záměrně stejně jednoduchý jako dřív u
## schopností (pasivní bonus `per_rank` ke statu `stat` za každý rank) -
## mění se JEN zdroj volby (náhodná nabídka místo pevného stromu), ne
## herní dopad. Až budou mít itemy skutečné aktivní efekty, mění se jen
## tahle tabulka a get_stat_bonus().
const ITEMS := {
	"power_core": {
		"name": "Jádro síly",
		"short_name": "Jádro",
		"desc": "+4 poškození za úroveň itemu",
		"stat": "damage",
		"per_rank": 4.0,
	},
	"rapid_coils": {
		"name": "Rychlopalné cívky",
		"short_name": "Palba",
		"desc": "+0.15 útoku/s za úroveň itemu",
		"stat": "attack_speed",
		"per_rank": 0.15,
	},
	"long_barrel": {
		"name": "Prodloužená hlaveň",
		"short_name": "Dostřel",
		"desc": "+40 dostřelu za úroveň itemu",
		"stat": "attack_range",
		"per_rank": 40.0,
	},
	"split_rounds": {
		"name": "Dělené střely",
		"short_name": "Rozptyl",
		"desc": "+1 zasažený cíl za úroveň itemu",
		"stat": "multishot",
		"per_rank": 1.0,
	},
	"reinforced_plating": {
		"name": "Zesílený pancíř",
		"short_name": "Pancíř",
		"desc": "+20 max. HP za úroveň itemu",
		"stat": "max_hp",
		"per_rank": 20.0,
	},
	"nanite_repair": {
		"name": "Nanitová oprava",
		"short_name": "Regen",
		"desc": "+0.5 regenerace HP/s za úroveň itemu",
		"stat": "hp_regen",
		"per_rank": 0.5,
	},
	"kinetic_dampers": {
		"name": "Kinetické tlumiče",
		"short_name": "Tlumiče",
		"desc": "+2 snížení poškození z každého zásahu za úroveň itemu",
		"stat": "armor",
		"per_rank": 2.0,
	},
}
## Pořadí itemů v HUD - drží layout stabilní nezávisle na pořadí v Dictionary
const ITEM_ORDER: Array[String] = [
	"power_core", "rapid_coils", "long_barrel", "split_rounds", "reinforced_plating", "nanite_repair",
	"kinetic_dampers"
]
const MAX_ITEM_RANK: int = 5
## Kolik itemů se nabídne v jedné draft nabídce
const DRAFT_CHOICE_COUNT: int = 3

## --- Obchod -------------------------------------------------------------
## Na rozdíl od draftu (náhodná nabídka, free, staví se rankem stejného
## itemu) je obchod: koupíš za zlato, každý item JEN JEDNOU (žádné ranky) a
## jsi omezený počtem slotů (MAX_SHOP_SLOTS) - běžná koupě tak vyžaduje
## reálné rozhodnutí, co koupit a co vynechat, ne jen "vezmi všechno".
## Itemy dávají víc statů najednou (na rozdíl od draftu, kde má každý item
## jen jeden stat) - odlišuje to obchod jako vlastní systém, ne jen druhou
## cestu ke stejným číslům.
##
## Dřív tu byl i "combine" strom (2 základní itemy -> 1 silnější tier-2 item)
## - zrušený ve prospěch plánovaného systému rarity (Bronz/Stříbro/Zlato/
## Diamant, opakovaná koupě stejného itemu zvedá jeho raritu), který dělá v
## podstatě totéž (odměna za opakovanou investici), ale jako jeden sjednocený
## systém místo dvou paralelních. Rarita zatím není implementovaná - tohle
## je jen odstranění toho, co nahrazuje.
const SHOP_ITEMS := {
	"overcharged_core": {
		"name": "Přebíječ jader",
		"short_name": "Přebíječ",
		"desc": "+6 poškození\n+0.2 útoku/s",
		"stats": {"damage": 6.0, "attack_speed": 0.2},
		"cost": 200,
	},
	"field_plating": {
		"name": "Terénní pancéřování",
		"short_name": "Pancéřování",
		"desc": "+30 max. HP\n+3 brnění",
		"stats": {"max_hp": 30.0, "armor": 3.0},
		"cost": 200,
	},
	"targeting_module": {
		"name": "Zaměřovací modul",
		"short_name": "Zaměřovač",
		"desc": "+50 dostřel\n+1 zasažený cíl",
		"stats": {"attack_range": 50.0, "multishot": 1.0},
		"cost": 220,
	},
	"nanite_regenerator": {
		"name": "Nanitový regenerátor",
		"short_name": "Regenerátor",
		"desc": "+1.0 regenerace HP/s\n+3 brnění",
		"stats": {"hp_regen": 1.0, "armor": 3.0},
		"cost": 180,
	},
	"overloaded_coils": {
		"name": "Přetížené cívky",
		"short_name": "Cívky",
		"desc": "+0.2 útoku/s\n+1 zasažený cíl",
		"stats": {"attack_speed": 0.2, "multishot": 1.0},
		"cost": 220,
	},
	"gravity_stabilizer": {
		"name": "Gravitační stabilizátor",
		"short_name": "Stabilizátor",
		"desc": "+30 max. HP\n+50 dostřel",
		"stats": {"max_hp": 30.0, "attack_range": 50.0},
		"cost": 200,
	},
	"destruction_core": {
		"name": "Jádro destrukce",
		"short_name": "Destrukce",
		"desc": "+6 poškození\n+30 max. HP",
		"stats": {"damage": 6.0, "max_hp": 30.0},
		"cost": 220,
	},
}
## Pořadí itemů v obchodě - 7 itemů na jen 6 slotů (viz MAX_SHOP_SLOTS), takže
## hráč nutně jeden vynechá - záměrný trade-off, ne chyba v počtu.
const SHOP_ITEM_ORDER: Array[String] = [
	"overcharged_core", "field_plating", "targeting_module", "nanite_regenerator",
	"overloaded_coils", "gravity_stabilizer", "destruction_core"
]
const MAX_SHOP_SLOTS: int = 6
## Kolik % z ceny itemu se vrátí při prodeji - nižší než 100 %, aby obchod
## nešlo použít jako bezplatný "respec" (nakoupit, hned prodat, zkusit jiné).
const SHOP_SELL_REFUND_RATIO: float = 0.5

var current_wave: int = 0
## Kolikáté kolo (průchod 10 vlnami) hráč zrovna hraje. Roste, hráčova
## progrese (úroveň/XP/itemy/měna) se ale mezi koly NERESETUJE -
## viz _start_new_loop(). Resetuje se jen na skutečný Game Over (reset_game()).
var loop_count: int = 1
var currency: int = 0
var enemies_alive: int = 0
var enemies_remaining_to_spawn: int = 0
var state: State = State.INTRO

var player_level: int = 1
var player_xp: int = 0
var item_ranks: Dictionary = {}
## Kolik draft nabídek čeká na vyřízení - víc než 1 může nastat, když hráč
## dostane hodně XP naráz a povýší o víc úrovní v jednom volání add_xp().
## HUD nabídky vyřizuje jednu po druhé (viz resolve_draft()).
var pending_drafts: int = 0
## Itemy nabídnuté v AKTUÁLNĚ čekající draft nabídce - resolve_draft() proti
## nim ověřuje, že hráč vybírá opravdu z toho, co bylo nabídnuto.
var _current_offer: Array = []
## ID vlastněných obchodních itemů (viz "Obchod" výše) - na rozdíl od
## item_ranks tu nejsou ranky, item buď je v tomhle poli (koupený), nebo
## není. Velikost pole je omezená na MAX_SHOP_SLOTS.
var owned_shop_items: Array[String] = []


## Volá main.gd v _enter_tree(), tedy DŘÍV než se spustí _ready() hráče a HUD -
## ty už tak čtou čerstvý stav. Kdyby se resetovalo až v _ready() Main uzlu,
## hráč by se po restartu naskočil se staty z předchozí hry.
func reset_game() -> void:
	current_wave = 0
	loop_count = 1
	currency = 0
	enemies_alive = 0
	enemies_remaining_to_spawn = 0
	state = State.INTRO
	player_level = 1
	player_xp = 0
	pending_drafts = 0
	_current_offer = []
	item_ranks.clear()
	for item_id in ITEM_ORDER:
		item_ranks[item_id] = 0
	owned_shop_items.clear()


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
		_start_new_loop()
	else:
		# Žádné čekání na vynucený výběr - hra plynule pokračuje další vlnou
		start_next_wave()


func start_next_wave() -> void:
	current_wave += 1
	wave_started.emit(current_wave)


## Vyčištěním FINAL_WAVE hra nekončí - vlny se vrátí na 1 se silnějšími
## nepřáteli (viz get_enemy_hp_multiplier()), ale hráčova progrese (úroveň,
## XP, itemy, měna) i pozice a HP zůstávají přesně tak, jak byly - level
## je bezkonečný, takže postava jen pokračuje dál dopředu (viz player.gd,
## HP se doplňuje pasivní regenerací, ne skokově při každém kole).
func _start_new_loop() -> void:
	loop_count += 1
	current_wave = 0
	loop_changed.emit(loop_count)
	start_next_wave()


## Násobitel HP nově spawnutých nepřátel pro aktuální kolo - main.gd ho
## aplikuje v _spawn_enemy() ještě před tím, než nepřítel vstoupí do stromu
## (aby _ready() v enemy.gd nastavil hp = max_hp už se správnou hodnotou).
func get_enemy_hp_multiplier() -> float:
	return 1.0 + float(loop_count - 1) * ENEMY_HP_GROWTH_PER_LOOP


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
	pending_drafts += 1
	# Level sám o sobě už žádný stat automaticky nezvedá (viz get_stat_bonus) -
	# level_changed tu zůstává jen kvůli UI (odznak úrovně v HUD apod.), veškerý
	# reálný růst statů přijde teprve s vybraným itemem z nabídky.
	level_changed.emit(player_level)
	_try_offer_next_draft()


## Vylosuje až DRAFT_CHOICE_COUNT náhodných itemů, které ještě nejsou na
## maximálním ranku. Volá se pokaždé znovu (ne jednou dopředu), aby nabídka
## odrážela aktuální stav itemů v okamžiku, kdy se skutečně zobrazí.
func _roll_draft_options() -> Array:
	var eligible: Array = []
	for item_id in ITEM_ORDER:
		if item_ranks[item_id] < MAX_ITEM_RANK:
			eligible.append(item_id)
	eligible.shuffle()
	return eligible.slice(0, mini(DRAFT_CHOICE_COUNT, eligible.size()))


## Pokud čeká aspoň jedna draft nabídka A zrovna žádná není rozehraná,
## vylosuje itemy a emitne item_draft_ready. Když už nejsou žádné itemy pod
## maximem (nic k nabídnutí), nabídku potichu "spotřebuje" bez zobrazení a
## zkusí další frontu. Podmínka `_current_offer.is_empty()` je nutná - bez
## ní by každý _level_up() ve stejném volání add_xp() (velký přísun XP naráz
## povýší o víc úrovní ve smyčce) vygeneroval a emitnul VLASTNÍ nabídku, i
## když už jedna čeká na vyřízení.
func _try_offer_next_draft() -> void:
	if pending_drafts <= 0 or not _current_offer.is_empty():
		return

	var offered: Array = _roll_draft_options()
	if offered.is_empty():
		pending_drafts -= 1
		_try_offer_next_draft()
		return

	_current_offer = offered
	item_draft_ready.emit(offered)


## Zavolá HUD, když hráč (nebo Auto výběr) vybere item z aktuální nabídky.
## Vrací false, pokud zrovna žádná nabídka nečeká nebo item_id není mezi
## nabídnutými (ochrana proti zastaralému/duplicitnímu kliknutí).
func resolve_draft(item_id: String) -> bool:
	if pending_drafts <= 0 or not _current_offer.has(item_id):
		return false

	pending_drafts -= 1
	_current_offer = []

	var new_rank: int = int(item_ranks[item_id]) + 1
	item_ranks[item_id] = new_rank
	item_rank_changed.emit(item_id, new_rank)

	_try_offer_next_draft()
	return true


## Celkový bonus ke statu = součet ranků vybraných itemů, které na stat
## působí. Jediné místo, kde se progrese promítá do statů - player.gd si ho
## jen přičítá ke svým base hodnotám. Úroveň sama o sobě už bonus nedává -
## veškerý růst jde přes vybrané itemy, ať je jasné, čím je která hodnota
## daná (žádný "neviditelný" automatický přírůstek vedle viditelné volby).
func get_stat_bonus(stat_id: String) -> float:
	var bonus: float = 0.0

	for item_id in ITEM_ORDER:
		var definition: Dictionary = ITEMS[item_id]
		if definition["stat"] == stat_id:
			bonus += float(definition["per_rank"]) * float(item_ranks[item_id])

	for item_id in owned_shop_items:
		var stats: Dictionary = SHOP_ITEMS[item_id]["stats"]
		if stats.has(stat_id):
			bonus += float(stats[stat_id])

	return bonus


## true, pokud je pro item volný slot, hráč ho ještě nevlastní a má na něj
## dost zlata - _on_shop_buy_pressed() v hud.gd tímhle rozhoduje, jestli má
## tlačítko "Koupit" být aktivní.
func can_buy_shop_item(item_id: String) -> bool:
	if owned_shop_items.has(item_id):
		return false
	if owned_shop_items.size() >= MAX_SHOP_SLOTS:
		return false
	return currency >= int(SHOP_ITEMS[item_id]["cost"])


func buy_shop_item(item_id: String) -> bool:
	if not can_buy_shop_item(item_id):
		return false

	currency -= int(SHOP_ITEMS[item_id]["cost"])
	currency_changed.emit(currency)
	owned_shop_items.append(item_id)
	shop_inventory_changed.emit()
	return true


## Vrátí SHOP_SELL_REFUND_RATIO z ceny itemu a item zmizí ze slotů úplně -
## na rozdíl od draftu tu nejsou ranky, které by šlo snižovat po jednom.
func sell_shop_item(item_id: String) -> bool:
	if not owned_shop_items.has(item_id):
		return false

	var refund: int = int(round(float(SHOP_ITEMS[item_id]["cost"]) * SHOP_SELL_REFUND_RATIO))
	currency += refund
	currency_changed.emit(currency)
	owned_shop_items.erase(item_id)
	shop_inventory_changed.emit()
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
	print("Game Over! Dosažená vlna: ", current_wave, " | Úroveň: ", player_level)


## Zavolá hráč po dosažení konce levelu
func trigger_win() -> void:
	if state == State.WON:
		return
	state = State.WON
	game_won_triggered.emit()
	print("Level dokončen! Vlna: ", current_wave, " | Úroveň: ", player_level)


# --- Debug panel ---------------------------------------------------------
# Metody pro vývojářský Debug panel v HUD (scenes/ui/hud.gd). Jsou to jen
# přímé zkratky/manipulace stavu bez herního zdůvodnění (žádná odměna za
# "boj") - jasně oddělené v sekci, ať je zřejmé, že se nemají volat odjinud
# než z debug UI.

## DEBUG: přidá měnu bez zabití nepřítele - pro rychlé testování obchodu
func debug_add_currency(amount: int) -> void:
	currency += amount
	currency_changed.emit(currency)


## DEBUG: rovnou vynutí jednu draft nabídku bez čekání na level-up
func debug_force_draft() -> void:
	pending_drafts += 1
	_try_offer_next_draft()


## DEBUG: nastaví všechny itemy rovnou na maximální rank
func debug_max_items() -> void:
	for item_id in ITEM_ORDER:
		if item_ranks[item_id] < MAX_ITEM_RANK:
			item_ranks[item_id] = MAX_ITEM_RANK
			item_rank_changed.emit(item_id, MAX_ITEM_RANK)


## DEBUG: vynuluje ranky všech itemů - pro rychlé vyzkoušení jiného buildu.
## Na rozdíl od dřívějšího respecu schopností nevrací žádné "body" - itemy
## se nekupují za body, jen se draftí při level-upu.
func debug_reset_items() -> void:
	for item_id in ITEM_ORDER:
		if item_ranks[item_id] > 0:
			item_ranks[item_id] = 0
			item_rank_changed.emit(item_id, 0)


## DEBUG: přeskočí rovnou na další kolo (jen zvýší multiplikátor HP
## nepřátel přes get_enemy_hp_multiplier()) - na vlnovém postupu nic nemění
func debug_add_loop() -> void:
	loop_count += 1
	loop_changed.emit(loop_count)


## DEBUG: force-dokončí aktuální vlnu. main.gd před zavoláním musí sám dobít
## všechny živé nepřátele přes jejich normální take_damage() (aby dostali
## odměnu/XP a započítali se přes enemy_defeated() stejnou cestou jako v
## běžné hře) - smrt posledního z nich už tak _on_wave_cleared() spustí sama.
## Tahle metoda pak řeší jen okrajový případ, kdy mezi vlnami zrovna nikdo
## naživu nebyl, takže žádná smrt neproběhla a wave-clear se nespustil.
func debug_force_wave_clear() -> void:
	if enemies_alive > 0 or enemies_remaining_to_spawn > 0:
		return
	_on_wave_cleared()
