extends Node
## Globální singleton (Autoload) - řídí vlny nepřátel, měnu, zkušenosti,
## úrovně hráče a jeho vylepšení. Zaregistrován v Project Settings > Autoload
## jako "GameManager".

signal wave_started(wave_number: int)
signal wave_cleared(wave_number: int)
signal game_over_triggered
signal game_won_triggered
signal currency_changed(new_amount: int)
## Emitne se, když se změní množství suroviny (šrotu) - viz "Suroviny a
## crafting" v CLAUDE.md. Stejný vzor jako currency_changed.
signal scrap_changed(new_amount: int)
signal xp_changed(current_xp: int, xp_needed: int)
signal level_changed(new_level: int)
## Emitne se, když je k dispozici nová nabídka schopností k výběru (viz
## "Schopnosti" níže) - HUD podle toho buď zobrazí AbilityDraftPanel, nebo
## (má-li zapnutý Auto výběr) rovnou zavolá resolve_ability_draft() sám.
## `offered` má vždy ABILITY_CHOICE_COUNT prvků, každý
## {"ability_id": String, "rarity": int}.
signal ability_draft_ready(offered: Array)
## Emitne se po přidání nebo sloučení schopnosti - HUD podle toho překreslí
## sloty vlastněných schopností. Bez parametru (jako shop_inventory_changed),
## protože jeden ability_id může mít víc současně vlastněných instancí na
## různých raritách, ne jediné číslo "rank".
signal ability_inventory_changed
signal loop_changed(new_loop: int)
## Emitne se po nákupu nebo prodeji v obchodě - viz "Obchod" níže.
signal shop_inventory_changed
## Emitne se, kdykoliv se vygeneruje nová nabídka 4 itemů (vlna 10 hotová,
## nebo reroll) - HUD podle toho překreslí karty. offer_ids má vždy
## SHOP_OFFER_SIZE prvků.
signal shop_offer_changed(offer_ids: Array)
## Emitne se JEN při automatickém otevření po 10. vlně (ne při ručním
## otevření tlačítkem ani při rerollu) - HUD na to reaguje zobrazením a
## zapauzováním panelu, i když zrovna nikdo neklikl na tlačítko Obchod.
## Pokud v tu chvíli ještě čeká nevyřízená nabídka schopnosti, emit se
## ODLOŽÍ, dokud se nevyřídí - viz _try_open_pending_shop().
signal shop_auto_open_requested

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

## Automatický přírůstek statu za KAŽDOU úroveň nad 1 (get_stat_bonus() ho
## sčítá k pasivním schopnostem i obchodu, žádné zvláštní zapojení není
## potřeba - hráč se na level_changed přepočítává už kvůli nim). Vrácené 2026-09-09 poté,
## co bylo záměrně odstraněné dřív (viz historie/CLAUDE.md) - tehdy šlo o
## "každý bod statu má mít viditelný původ ve volbě hráče", teď to řeší jiný
## problém: run čistě závislý na draft/shop štěstí může být křehký (viz
## "Balance caveat" v CLAUDE.md). Hodnoty jsou záměrně MALÉ vůči itemům
## (např. jeden Stříbrný "Přebíječ jader" dá +9.6 poškození, tohle dá +0.5
## za úroveň) - je to podlaha, ne hlavní zdroj síly, aby volby pořád byly
## to, co run definuje.
const LEVEL_STAT_GROWTH := {
	"damage": 0.5,
	"attack_speed": 0.02,
	"attack_range": 2.0,
	"max_hp": 3.0,
	"armor": 0.3,
	"hp_regen": 0.05,
}

## --- Obchod -------------------------------------------------------------
## Na rozdíl od schopností (náhodná nabídka, free, viz "Schopnosti" níže) je
## obchod: koupíš za zlato, jsi omezený počtem AKTIVNÍCH slotů
## (SHOP_ACTIVE_SLOTS) - běžná koupě tak vyžaduje reálné rozhodnutí, co
## koupit a co vynechat, ne jen "vezmi všechno". Itemy dávají víc statů
## najednou (na rozdíl od pasivních schopností, kde má každá jen jeden stat) -
## odlišuje to obchod jako vlastní systém, ne jen druhou cestu ke stejným
## číslům.
##
## Dřív tu byl i "combine" strom (2 RŮZNÉ základní itemy -> 1 silnější
## tier-2 item, gold-upgrade rarity) - oboje zrušené ve prospěch systému
## "3 stejné kopie stejné rarity se automaticky sloučí do 1 vyšší rarity"
## (inspirováno hrou The Bazaar), viz _try_merge_shop_item() níže.
##
## "desc" pole tu záměrně NENÍ - popis se generuje dynamicky přes
## get_shop_item_desc(item_id, tier), protože jinak by statický text ukazoval
## Bronz čísla i pro vyšší raritu. "stats" jsou vždy BRONZE (tier 0)
## hodnoty, get_stat_bonus()/get_shop_item_desc() je násobí přes
## SHOP_RARITY_MULTIPLIERS podle rarity konkrétní vlastněné kopie.
const SHOP_ITEMS := {
	## "blueprint_cost"/"craft_scrap_cost" (přidáno 2026-09-26, viz "Suroviny a
	## crafting" v CLAUDE.md) - první 3 vybrané itemy pro první slice
	## blueprint/craft mechaniky. Item BEZ "blueprint_cost" nemá blueprint
	## vůbec (can_buy_blueprint()/can_craft_item() ho odmítnou) - zatím 6 z 9
	## itemů craftovatelných není, dokud se neukáže, že mechanika stojí za
	## rozšíření na celý katalog.
	"overcharged_core": {
		"name": "Přebíječ jader",
		"short_name": "Přebíječ",
		"stats": {"damage": 6.0, "attack_speed": 0.2},
		"cost": 200,
		"tags": ["kinetic"],
		"blueprint_cost": 20,
		"craft_scrap_cost": 15,
	},
	"field_plating": {
		"name": "Terénní pancéřování",
		"short_name": "Pancéřování",
		"stats": {"max_hp": 30.0, "armor": 3.0},
		"cost": 200,
		"tags": ["support"],
	},
	"targeting_module": {
		"name": "Zaměřovací modul",
		"short_name": "Zaměřovač",
		"stats": {"attack_range": 50.0, "multishot": 1.0},
		"cost": 220,
		"tags": ["precision"],
		"blueprint_cost": 20,
		"craft_scrap_cost": 15,
	},
	"nanite_regenerator": {
		"name": "Nanitový regenerátor",
		"short_name": "Regenerátor",
		"stats": {"hp_regen": 1.0, "armor": 3.0},
		"cost": 180,
		"tags": ["support"],
		"blueprint_cost": 20,
		"craft_scrap_cost": 15,
	},
	"overloaded_coils": {
		"name": "Přetížené cívky",
		"short_name": "Cívky",
		"stats": {"attack_speed": 0.2, "multishot": 1.0},
		"cost": 220,
		"tags": ["precision"],
	},
	"gravity_stabilizer": {
		"name": "Gravitační stabilizátor",
		"short_name": "Stabilizátor",
		"stats": {"max_hp": 30.0, "attack_range": 50.0},
		"cost": 200,
		"tags": ["support"],
	},
	"destruction_core": {
		"name": "Jádro destrukce",
		"short_name": "Destrukce",
		"stats": {"damage": 6.0, "max_hp": 30.0},
		"cost": 220,
		"tags": ["kinetic"],
	},
	## Synergický item (přidáno 2026-09-25, viz "Tag synergie" v CLAUDE.md) -
	## na rozdíl od ostatních nemá "stats" (pevný bonus), ale "synergy":
	## bonus roste s POČTEM vlastněných věcí (schopností i aktivních itemů
	## dohromady) se stejným tagem, včetně sebe sama. Umožňuje hráči budovat
	## strategii kolem jednoho tagu ("beru všechno Přesné") oběma směry -
	## koupit tohle první a pak lovit Přesné schopnosti, nebo nasbírat Přesné
	## schopnosti a pak tohle koupit jako vyvrcholení buildu.
	"resonance_array": {
		"name": "Rezonanční pole",
		"short_name": "Rezonance",
		"synergy": {"stat": "attack_speed", "tag": "precision", "value": 0.06},
		"cost": 220,
		"tags": ["precision"],
	},
	## Přidáno 2026-09-25 s novým statem crit_chance (viz player.gd's
	## get_crit_chance()) - kombinuje ho s attack_speed, aby item zapadl mezi
	## ostatní "precision" itemy (rychlejší, přesnější palba), ne jen jako
	## izolovaný crit-stat stick.
	"precision_scope": {
		"name": "Přesná optika",
		"short_name": "Optika",
		"stats": {"crit_chance": 0.05, "attack_speed": 0.15},
		"cost": 210,
		"tags": ["precision"],
	},
}
## Zobrazované jednotky pro get_shop_item_desc()/get_ability_desc() - klíče
## musí sedět se "stat" v pasivních ABILITIES a klíči "stats" dictionary v
## SHOP_ITEMS.
const STAT_DISPLAY_NAMES := {
	"damage": "poškození",
	"attack_speed": "útoku/s",
	"attack_range": "dostřel",
	"multishot": "zasažený cíl",
	"max_hp": "max. HP",
	"hp_regen": "regenerace HP/s",
	"armor": "brnění",
	"crit_chance": "šance na kritický zásah",
}
## "crit_chance" je JEDINÝ stat uložený jako podíl (0.08 = 8 %), všechny
## ostatní jsou absolutní čísla - proto dostává v _format_stat_line() vlastní
## % formátování místo obecného STAT_DISPLAY_NAMES/_format_stat_number páru.
## --- Tag synergie ---------------------------------------------------------
## Přidáno 2026-09-25 na žádost uživatele - umožňuje si vybírat schopnosti
## podle itemů, které chce hráč později najít v obchodě, a naopak (viz
## "Tag synergie" v CLAUDE.md pro celý mechanismus). Každá ABILITIES/SHOP_ITEMS
## položka nese "tags" (zatím vždy přesně 1 tag) čistě informativně - ať hráč
## vidí kategorii i u položek, které samy synergický bonus nedávají. Skutečný
## synergický efekt mají jen položky s klíčem "synergy" (viz
## _count_owned_with_tag()/get_stat_bonus() níže).
const TAG_DISPLAY_NAMES := {
	"kinetic": "Kinetická",
	"precision": "Přesná",
	"explosive": "Explozivní",
	"support": "Podpůrná",
}
## Pořadí itemů v obchodě - 7 itemů na jen SHOP_ACTIVE_SLOTS aktivních slotů,
## takže hráč nutně jeden vynechá (nebo ho odloží do skladu) - záměrný
## trade-off, ne chyba v počtu.
const SHOP_ITEM_ORDER: Array[String] = [
	"overcharged_core", "field_plating", "targeting_module", "nanite_regenerator",
	"overloaded_coils", "gravity_stabilizer", "destruction_core", "resonance_array",
	"precision_scope",
]
## Kolik itemů může být najednou AKTIVNÍCH (přispívají do get_stat_bonus()).
const SHOP_ACTIVE_SLOTS: int = 6
## Kolik itemů může čekat ve SKLADU (nepřispívají do statů, jen čekají na
## sloučení do vyšší rarity nebo na uvolnění místa v aktivních slotech) -
## víc než SHOP_ACTIVE_SLOTS, aby šlo sbírat duplicity bez nutnosti hned
## obětovat aktivní výbavu.
const SHOP_STASH_SLOTS: int = 9
## Kolik % z ceny itemu se vrátí při prodeji - nižší než 100 %, aby obchod
## nešlo použít jako bezplatný "respec" (nakoupit, hned prodat, zkusit jiné).
const SHOP_SELL_REFUND_RATIO: float = 0.5

## Kolik itemů se najednou nabídne v obchodě - záměrně míň než celý
## SHOP_ITEM_ORDER (7), aby obchod nebyl jen "kup si všechno, co chceš", ale
## reálná náhodná nabídka jako draft, s možností si za zlato přehodit
## (viz reroll_shop() níže). Nabídka může obsahovat i itemy, které už hráč
## vlastní (v libovolné raritě) - jinak by nikdy nešlo sehnat 2./3. kopii
## pro sloučení (viz _try_merge_shop_item()).
const SHOP_OFFER_SIZE: int = 4
## Cena prvního rerollu v jedné návštěvě obchodu; každý další přidá
## SHOP_REROLL_COST_STEP navrch (20, 35, 50, ...) - resetuje se při každé
## nové nabídce (viz _generate_shop_offer()), takže vyhnout se drahým
## pozdním rerollům nejde tím, že hráč obchod zavře a otevře znovu.
const SHOP_REROLL_BASE_COST: int = 20
const SHOP_REROLL_COST_STEP: int = 15

## --- Rarita obchodních itemů --------------------------------------------
## Item v nabídce má rovnou náhodně vylosovanou raritu (viz SHOP_RARITY_WEIGHTS
## a _roll_rarity()) - koupě tak nemusí být vždy na BRONZE. Vlastnictví
## 3 kopií STEJNÉHO itemu NA STEJNÉ raritě je automaticky sloučí do 1 kopie
## o stupeň vyšší (_try_merge_shop_item()) - to je JEDINÝ způsob, jak item
## posílit, žádné placené vylepšení už neexistuje. Tenhle enum (a
## SHOP_RARITY_NAMES pro zobrazované názvy) je sdílený i se schopnostmi (viz
## "Schopnosti" níže, ABILITY_MERGE_THRESHOLD/ABILITY_RARITY_WEIGHTS) - obě
## soustavy mají stejné 4 stupně, jen jiné váhy/multiplikátory/práh sloučení.
enum ShopRarity { BRONZE, SILVER, GOLD, DIAMOND }
const SHOP_RARITY_NAMES: Array[String] = ["Bronz", "Stříbro", "Zlato", "Diamant"]
## Pravděpodobnost, že nabídka vylosuje item na daném stupni (index =
## ShopRarity) - musí dát dohromady 1.0. Nízké rarity padají mnohem častěji,
## aby Diamant byl vzácný, ne běžný nález.
const SHOP_RARITY_WEIGHTS: Array[float] = [0.70, 0.20, 0.08, 0.02]
## Násobitel BRONZE (základních) hodnot ve SHOP_ITEMS[item_id]["stats"] -
## ~1.6x na stupeň, aby sloučení bylo vždy citelné, ne kosmetické.
const SHOP_RARITY_MULTIPLIERS: Array[float] = [1.0, 1.6, 2.6, 4.2]
## Cena KOUPĚ itemu na daném stupni rarity, jako násobek vlastní ceny itemu
## (SHOP_ITEMS[item_id]["cost"]) - ne absolutní číslo, aby dražší itemy měly
## úměrně dražší i vyšší rarity. Roste rychleji než síla
## (SHOP_RARITY_MULTIPLIERS), takže vysoko-raritní nabídka je záměrně
## luxusní nákup, ne rutinní - viz "exponenciální cena, téměř lineární
## bonus" z balance brainstormu, který k tomuhle systému vedl.
const SHOP_RARITY_COST_RATIOS: Array[float] = [1.0, 1.4, 2.25, 3.75]
## Barva rarity pro vizuální odlišení (index = ShopRarity) - použito např.
## kosočtvercovou ikonkou nad názvem v AbilityDraftPanel (viz rarity_icon.gd).
const SHOP_RARITY_COLORS: Array[Color] = [
	Color(0.80, 0.50, 0.20), # Bronz
	Color(0.75, 0.75, 0.78), # Stříbro
	Color(1.00, 0.84, 0.0),  # Zlato
	Color(0.25, 0.85, 1.0),  # Diamant
]

## --- Schopnosti -------------------------------------------------------
## JEDINÝ zdroj volitelné progrese vedle automatického LEVEL_STAT_GROWTH a
## koupí v obchodě - nahrazuje dřívější DVA oddělené systémy (2026-09-09):
## "item draft" (3 jednostatové itemy nabízené KAŽDOU úroveň) a "aktivní
## schopnosti" (1 aktivní schopnost nabízená jen jednou za 5 úrovní). Uživatel
## se rozhodl obě sloučit do jedné fronty/nabídky a nechat "schopnost" jako
## jediný název pro obojí - passivní stat-sticky (bývalé draft itemy, teď
## `type: "passive"`) i aktivní trigger/effect efekty (`type: "active"`,
## dřívější "aktivní schopnosti") jsou teď prostě dvě VARIANTY jedné věci,
## ne dva systémy. Nabídka funguje na principu rarity+merge sdíleném s
## obchodem (ShopRarity enum/SHOP_RARITY_NAMES), viz _roll_ability_options()/
## _try_merge_ability() níže.
##
## Pasivní schopnost: {"type": "passive", "stat": String, "value": float}.
## "value" je vždy BRONZE hodnota, get_stat_bonus() ji násobí přes
## PASSIVE_EFFECT_MULTIPLIERS podle rarity konkrétní vlastněné kopie - stejný
## princip, jaký měl dřívější draft (jen bez zvláštního jména navíc).
##
## Aktivní schopnost: {"type": "active", "trigger": String, "trigger_values":
## Array (jedna hodnota na ShopRarity stupeň), "effect": String,
## "effect_params": Dictionary}. Rarita škáluje FREKVENCI triggeru (kratší
## interval = vyšší uptime), NE sílu efektu (effect_params zůstává na všech
## stupních stejný) - přirozenější škálování pro trigger-based schopnost než
## násobení čísla, které už samo je násobič. Řešení konkrétních trigger/
## effect párů je hardcoded v player.gd (_consume_ability_triggers() pro
## "shot_count", _process_time_based_abilities() pro "time_elapsed") a v
## get_ability_desc() níže - obecný dispatch teprve až bude třeba pro 3. typ.
const ABILITIES := {
	"power_core": {
		"name": "Jádro síly", "short_name": "Jádro", "type": "passive",
		"stat": "damage", "value": 4.0, "tags": ["kinetic"],
	},
	"rapid_coils": {
		"name": "Rychlopalné cívky", "short_name": "Palba", "type": "passive",
		"stat": "attack_speed", "value": 0.15, "tags": ["precision"],
	},
	"long_barrel": {
		"name": "Prodloužená hlaveň", "short_name": "Dostřel", "type": "passive",
		"stat": "attack_range", "value": 40.0, "tags": ["precision"],
	},
	"split_rounds": {
		"name": "Dělené střely", "short_name": "Rozptyl", "type": "passive",
		"stat": "multishot", "value": 1.0, "tags": ["kinetic"],
	},
	"reinforced_plating": {
		"name": "Zesílený pancíř", "short_name": "Pancíř", "type": "passive",
		"stat": "max_hp", "value": 20.0, "tags": ["support"],
	},
	"nanite_repair": {
		"name": "Nanitová oprava", "short_name": "Regen", "type": "passive",
		"stat": "hp_regen", "value": 0.5, "tags": ["support"],
	},
	"kinetic_dampers": {
		"name": "Kinetické tlumiče", "short_name": "Tlumiče", "type": "passive",
		"stat": "armor", "value": 2.0, "tags": ["support"],
	},
	## Synergická schopnost (přidáno 2026-09-25, viz "Tag synergie" v
	## CLAUDE.md) - na rozdíl od ostatních pasivních schopností nemá pevné
	## "stat"/"value", ale "synergy": bonus roste s POČTEM vlastněných věcí
	## (schopností i aktivních itemů dohromady) se stejným tagem, včetně sebe
	## sama. Zrcadlí shop_items' "resonance_array" - stejný tag (precision),
	## opačný směr (hráč si tohle může vybrat jako schopnost první a pak
	## lovit Přesné itemy v obchodě, nebo naopak).
	"overclock_matrix": {
		"name": "Přetěžovací matice", "short_name": "Matice", "type": "passive",
		"synergy": {"stat": "damage", "tag": "kinetic", "value": 1.5}, "tags": ["kinetic"],
	},
	## Přidáno 2026-09-25 s novým statem crit_chance (viz player.gd's
	## get_crit_chance()/_shoot()) - tag "precision" stejně jako ostatní
	## schopnosti kolem přesnosti/frekvence útoku (rapid_coils, long_barrel).
	"precision_targeting": {
		"name": "Přesné zaměřování", "short_name": "Zaměření", "type": "passive",
		"stat": "crit_chance", "value": 0.06, "tags": ["precision"],
	},
	"double_tap": {
		"name": "Dvojitý zásah", "short_name": "D. zásah", "type": "active",
		"trigger": "shot_count",
		"trigger_values": [6, 5, 4, 3],
		"effect": "damage_multiplier",
		"effect_params": {"multiplier": 2.0},
		"tags": ["explosive"],
	},
	"orbital_bombardment": {
		"name": "Orbitální bombardování", "short_name": "Orbitál", "type": "active",
		"trigger": "time_elapsed",
		## Sekundy nabíjení, první odhad (viz project_balance_deferred v
		## paměti) - nedoladěno playtestingem.
		"trigger_values": [20.0, 15.0, 11.0, 8.0],
		"effect": "aoe_strike",
		## Zasáhne VŠECHNY živé nepřátele (ne jen okruh kolem hráče) za tuhle
		## hodnotu - "screen-wide" efekt z původního brainstormu (viz
		## project_future_active_abilities v paměti), ne lokalizovaná exploze.
		## První odhad, nedoladěno playtestingem.
		"effect_params": {"damage": 30.0},
		"tags": ["explosive"],
	},
}
## Pořadí schopností v HUD - stejný účel jako SHOP_ITEM_ORDER.
const ABILITY_ORDER: Array[String] = [
	"power_core", "rapid_coils", "long_barrel", "split_rounds", "reinforced_plating",
	"nanite_repair", "kinetic_dampers", "overclock_matrix", "precision_targeting",
	"double_tap", "orbital_bombardment",
]
## Kolik schopností se nabídne v jedné nabídce - vráceno na 3 (stejně jako
## dřívější DRAFT_CHOICE_COUNT) teď, když je pool dost velký na skutečnou
## volbu; dokud existovala jen 1 aktivní schopnost, bylo to dočasně 1.
const ABILITY_CHOICE_COUNT: int = 3
## Kolik stejných kopií stejné rarity stačí na sloučení do vyšší rarity - míň
## než obchodních 3 (viz SHOP_RARITY_* sekce), protože schopnosti se nabízí
## jen náhodně bez placeného rerollu.
const ABILITY_MERGE_THRESHOLD: int = 2
const ABILITY_RARITY_WEIGHTS: Array[float] = [0.70, 0.20, 0.08, 0.02]
## Násobitel BRONZE hodnoty pasivní schopnosti (ABILITIES[id]["value"]) podle
## rarity - vlastní křivka, ne sdílená se SHOP_RARITY_MULTIPLIERS, protože
## nižší merge threshold (2 místo obchodních 3) znamená rychlejší růst síly,
## což je potřeba vyvážit jemnější křivkou násobitelů.
const PASSIVE_EFFECT_MULTIPLIERS: Array[float] = [1.0, 1.5, 2.25, 3.5]

var current_wave: int = 0
## Kolikáté kolo (průchod 10 vlnami) hráč zrovna hraje. Roste, hráčova
## progrese (úroveň/XP/itemy/měna) se ale mezi koly NERESETUJE -
## viz _start_new_loop(). Resetuje se jen na skutečný Game Over (reset_game()).
var loop_count: int = 1
var currency: int = 0
## Nakrafťovaná surovina (šrot) - vstup pro budoucí blueprinty/crafting v
## obchodě (viz "Suroviny a crafting" v CLAUDE.md). Zatím jediný typ suroviny,
## stejné run-scoped chování jako currency (resetuje se v reset_game()).
var scrap: int = 0
var enemies_alive: int = 0
var enemies_remaining_to_spawn: int = 0
var state: State = State.INTRO

var player_level: int = 1
var player_xp: int = 0
## Vlastněné schopnosti - pasivní přispívají do get_stat_bonus(), aktivní mají
## vlastní trigger/effect logiku v player.gd. Každý prvek je Dictionary
## {"ability_id": String, "rarity": int (ShopRarity)} - stejný tvar jako
## active_shop_items, jen bez "cost_paid" (schopnosti jsou free). Jeden
## ability_id může mít víc současně vlastněných prvků na RŮZNÝCH raritách
## (např. 1 Stříbrná kopie + 1 nová Bronzová po dalším pick-u, dokud
## nevznikne 2. Bronzová a nesloučí se) - žádný strop na počet, na rozdíl od
## obchodu (SHOP_ACTIVE_SLOTS/SHOP_STASH_SLOTS) schopnosti nemají aktivní/
## sklad dělení, protože nabídka je vždy jen ABILITY_CHOICE_COUNT schopností
## zdarma, ne omezený nákup - není tu stejný tlak "moc věcí, málo místa" jako
## v obchodě. Víc vlastněných instancí STEJNÉ aktivní schopnosti spouští svůj
## efekt NEZÁVISLE (viz player.gd) - 2 kopie tak mohou na stejném triggeru
## spustit efekt obě najednou (násobiče se násobí, ne sčítají).
var owned_abilities: Array[Dictionary] = []
## Kolik nabídek schopností čeká na vyřízení - víc než 1 může nastat, když
## hráč dostane hodně XP naráz a povýší o víc úrovní v jednom volání add_xp()
## (každá úroveň = 1 nabídka). HUD nabídky vyřizuje jednu po druhé (viz
## resolve_ability_draft()).
var pending_ability_drafts: int = 0
## Schopnosti nabídnuté v AKTUÁLNĚ čekající nabídce (ABILITY_CHOICE_COUNT
## prvků, každý {"ability_id": String, "rarity": int}) - resolve_ability_draft()
## proti indexu v tomhle poli ověřuje, že hráč vybírá opravdu z toho, co bylo
## nabídnuto.
var _current_ability_offer: Array[Dictionary] = []
## Aktivní obchodní itemy - přispívají do get_stat_bonus(). Každý prvek je
## Dictionary {"item_id": String, "rarity": ShopRarity, "cost_paid": int} -
## "cost_paid" je zlato vložené do TÉHLE konkrétní kopie (u sloučeného itemu
## součet všech 3 kopií, co ho vytvořily), použije se pro refund při prodeji.
## Max SHOP_ACTIVE_SLOTS prvků.
var active_shop_items: Array[Dictionary] = []
## Skladované obchodní itemy - stejný tvar prvku jako active_shop_items, ale
## NEpřispívají do get_stat_bonus(). Sem se automaticky přesune nákup, když
## jsou aktivní sloty plné - hráč je musí ručně aktivovat (move_shop_item_to_
## active()), aby začaly něco dělat. Max SHOP_STASH_SLOTS prvků.
var stash_shop_items: Array[Dictionary] = []
## Vlastněné blueprinty (item_id, viz SHOP_ITEMS[id]["blueprint_cost"]) -
## TRVALÝ odemykací nákup za zlato (buy_blueprint()), ne spotřebovatelná
## kopie. Jakmile ho hráč vlastní, může opakovaně craftit nové Bronzové
## kopie toho itemu za šrot (craft_item()) - viz "Suroviny a crafting" v
## CLAUDE.md. Run-scoped jako všechno ostatní, reset v reset_game().
var owned_blueprints: Array[String] = []
## Aktuálně nabídnuté itemy v obchodě (SHOP_OFFER_SIZE kusů) - každý prvek
## {"item_id": String, "rarity": ShopRarity}, viz _generate_shop_offer().
## Prázdné, dokud hráč poprvé nedohraje 10. vlnu.
var shop_offer: Array[Dictionary] = []
## Kolikrát byla aktuální nabídka přehozená - roste s reroll_shop(), resetuje
## se na 0 při každé nové nabídce. Určuje cenu dalšího rerollu.
var shop_reroll_count: int = 0
## true od chvíle, co hráč v AKTUÁLNÍM běhu poprvé dohrál 10. vlnu - do té
## doby je tlačítko Obchod v HUD neaktivní/šedé (viz hud.gd). Resetuje se
## v reset_game() jako všechno ostatní run-scoped - nový běh musí 10. vlnu
## dohrát znovu, stejně jako musí znovu sbírat úrovně a itemy.
var shop_available: bool = false
## true, když čeká na otevření AUTOMATICKY otevřená nabídka obchodu (po 10.
## vlně), ale zrovna běží nevyřízená nabídka schopnosti - viz
## _try_open_pending_shop(). Řeší kolizi, kdy hráč dostane level-up přesně
## ze zabití POSLEDNÍHO nepřítele 10. vlny: level-up proběhne SYNCHRONNĚ
## uvnitř enemy_defeated() (přes add_xp()), tedy ještě předtím, než se
## stihne vyhodnotit konec vlny o pár řádků níž - bez tohohle odložení by
## AbilityDraftPanel a ShopPanel mohly naskočit na sobě současně.
var _shop_open_deferred: bool = false
## DEBUG: když true, reroll_shop() nic neúčtuje - pro rychlé testování bez
## grindění zlata. Přepíná se v Debug panelu (hud.gd), NEresetuje se v
## reset_game() (stejná logika jako u Engine.time_scale v Debug panelu -
## je to vývojářské pohodlí napříč restarty, ne herní stav).
var debug_free_reroll: bool = false


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
	scrap = 0
	pending_ability_drafts = 0
	_current_ability_offer = []
	owned_abilities.clear()
	active_shop_items.clear()
	stash_shop_items.clear()
	owned_blueprints.clear()
	shop_offer.clear()
	shop_reroll_count = 0
	shop_available = false
	_shop_open_deferred = false


## Zavolá level/spawner, aby oznámil, že spawnul nepřítele (pro sledování stavu vlny)
func register_enemy_spawned() -> void:
	enemies_alive += 1


## Zavolá nepřítel při své smrti - přidá měnu, suroviny i XP a zkontroluje
## stav vlny
func enemy_defeated(reward: int, xp_reward: int, scrap_reward: int = 0) -> void:
	currency += reward
	currency_changed.emit(currency)
	scrap += scrap_reward
	scrap_changed.emit(scrap)
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
	_open_periodic_shop()
	start_next_wave()


## Obchod se odemyká a nabízí novou nabídku jednou za kolo, na hranici mezi
## 10. vlnou a další - viz "Periodické otevírání" v CLAUDE.md. shop_available
## zůstává true i pro zbytek běhu (hráč tlačítkem znovu otevře AKTUÁLNÍ
## nabídku), ale novou nabídku (a reset ceny rerollu) dostane jen na téhle
## hranici, ne při každém ručním otevření.
func _open_periodic_shop() -> void:
	shop_available = true
	shop_reroll_count = 0
	_generate_shop_offer()
	_try_open_pending_shop()


## Otevře obchod (emitne shop_auto_open_requested) HNED, pokud zrovna nečeká
## žádná nevyřízená nabídka schopnosti - jinak otevření jen ODLOŽÍ
## (_shop_open_deferred) a schová se za resolve_ability_draft(), který tuhle
## funkci zavolá znovu, jakmile se poslední čekající nabídka vyřídí. Volá se
## jak z _open_periodic_shop() (nová nabídka po 10. vlně), tak z konce
## resolve_ability_draft() (dořešení odloženého otevření).
func _try_open_pending_shop() -> void:
	if pending_ability_drafts > 0 or not _current_ability_offer.is_empty():
		_shop_open_deferred = true
		return

	_shop_open_deferred = false
	shop_auto_open_requested.emit()


## Vybere SHOP_OFFER_SIZE náhodných itemů (bez opakování stejného ID v rámci
## JEDNÉ nabídky) ze SHOP_ITEM_ORDER a KAŽDÉMU nezávisle vylosuje raritu podle
## SHOP_RARITY_WEIGHTS - na rozdíl od dřívějška, kdy byla nabídka vždy na
## BRONZE, teď hráč může narazit rovnou na vzácnější kus (za odpovídající
## cenu, viz get_shop_item_cost()). Nesahá na shop_reroll_count - o to se
## stará volající (_open_periodic_shop() ho vynuluje, reroll_shop() ho
## zvyšuje), protože "nová nabídka" znamená něco jiného v obou případech.
func _generate_shop_offer() -> void:
	var pool: Array[String] = SHOP_ITEM_ORDER.duplicate()
	pool.shuffle()
	var picked_ids: Array = pool.slice(0, SHOP_OFFER_SIZE)

	shop_offer = []
	for item_id in picked_ids:
		shop_offer.append({"item_id": item_id, "rarity": _roll_rarity(SHOP_RARITY_WEIGHTS)})
	shop_offer_changed.emit(shop_offer)


## Vylosuje raritu podle zadaných vah (kumulativní pravděpodobnost) - sdílené
## mezi obchodem (SHOP_RARITY_WEIGHTS) a schopnostmi (ABILITY_RARITY_WEIGHTS),
## obě soustavy používají stejný ShopRarity enum (4 stupně), jen jiné váhy/
## multiplikátory.
func _roll_rarity(weights: Array[float]) -> ShopRarity:
	var roll: float = randf()
	var cumulative: float = 0.0
	for tier in weights.size():
		cumulative += weights[tier]
		if roll < cumulative:
			return tier
	return weights.size() - 1 as ShopRarity # pojistka pro zaokrouhlovací chyby


## Cena dalšího rerollu - roste s každým rerollem v AKTUÁLNÍ nabídce (viz
## shop_reroll_count), 0 když je zapnuté DEBUG: debug_free_reroll.
func get_shop_reroll_cost() -> int:
	if debug_free_reroll:
		return 0
	return SHOP_REROLL_BASE_COST + shop_reroll_count * SHOP_REROLL_COST_STEP


func can_reroll_shop() -> bool:
	return currency >= get_shop_reroll_cost()


func reroll_shop() -> bool:
	if not can_reroll_shop():
		return false

	currency -= get_shop_reroll_cost()
	currency_changed.emit(currency)
	shop_reroll_count += 1
	_generate_shop_offer()
	return true


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


## Zavolá hráč po dopadu úvodní "drop-in" animace (viz player.gd's
## _on_landed()) - vyžádá první nabídku schopnosti stejným mechanismem jako
## běžný level-up (pending_ability_drafts/_try_offer_next_ability_draft()),
## jen bez přírůstku úrovně/XP (hráč už je na úrovni 1 z reset_game()). Hra
## zůstává ve State.INTRO (takže pohyb hráče, spawn nepřátel atd. pořád nic
## nedělají, viz jejich `state != State.PLAYING` guardy), dokud se tahle
## úvodní nabídka nevyřeší - přechod do PLAYING zajišťuje finish_intro()
## volané z konce resolve_ability_draft(), ne tahle funkce.
func begin_intro_ability_draft() -> void:
	pending_ability_drafts += 1
	_try_offer_next_ability_draft()


func _level_up() -> void:
	player_level += 1
	# Nabídka schopnosti přijde na KAŽDÉ úrovni - žádný interval/ramp (viz
	# "Schopnosti" výše, zjednodušeno 2026-09-09 poté, co simulace ukázala,
	# že XP křivka sama o sobě dá první schopnosti dost rychle za sebou).
	pending_ability_drafts += 1
	# level_changed teď skutečně mění staty (LEVEL_STAT_GROWTH, viz
	# get_stat_bonus()), ne jen UI sync - ale schopnosti pořád zůstávají
	# hlavním zdrojem růstu, level growth je jen malá podlaha navrch.
	level_changed.emit(player_level)
	_try_offer_next_ability_draft()


## Vylosuje ABILITY_CHOICE_COUNT náhodných ABILITY_ORDER schopností (bez
## opakování stejného ID v rámci JEDNÉ nabídky, stejně jako
## _generate_shop_offer()) - nabídka se NEfiltruje podle toho, co už hráč
## vlastní (stejná schopnost, kterou už má, je žádoucí - je to potenciální
## 2. kopie pro sloučení, viz _try_merge_ability()), AŽ na jednu výjimku:
## schopnost už vlastněná na ShopRarity.DIAMOND (nejvyšší stupeň) se z
## nabídkového poolu vyřadí úplně (nahlášeno 2026-09-25 - hráč dostal
## "vylepšení" už Diamantového "Dvojitý zásah", které ve skutečnosti jen
## přidalo druhou nezávislou kopii, ne skutečné vylepšení - matoucí, protože
## _try_merge_ability() nikdy neslučuje nad Diamant, takže tam žádné
## "vylepšení" reálně neexistuje). Pokud by tohle vyřazení nechalo pool
## prázdný (hráč má VŠECHNY schopnosti na Diamantu), padá zpátky na
## nefiltrovaný pool - lepší nabídnout "jen další nezávislou kopii" než
## nechat AbilityDraftPanel bez jediné karty. Rarita se losuje NEZÁVISLE
## (ABILITY_RARITY_WEIGHTS) jen pro schopnost, kterou hráč ještě vůbec
## nevlastní - pokud už vlastní aspoň jednu instanci daného ID, nabídne
## se na STEJNÉ raritě jako ta nejnižší vlastněná (_lowest_owned_ability_rarity())
## místo nového nezávislého hodu. Bez tohohle by dvě nezávisle vylosované
## kopie stejné schopnosti mohly skončit na RŮZNÝCH raritách a nikdy by se
## nesloučily (nahlášeno 2026-09-25 - hráč měl "Jádro Bronz" i "Jádro Stříbro"
## současně). Vlastnictví se hledá na nejnižší raritě záměrně: sloučení se tak
## "propadne" postupně vzhůru přes všechny už vlastněné vyšší rarity téhož ID
## (viz rekurze v _try_merge_ability()), ne jen mezi dvěma konkrétními kopiemi.
func _roll_ability_options() -> Array[Dictionary]:
	var pool: Array[String] = ABILITY_ORDER.duplicate()

	var upgradeable_pool: Array[String] = []
	for ability_id in pool:
		if _lowest_owned_ability_rarity(ability_id) != ShopRarity.DIAMOND:
			upgradeable_pool.append(ability_id)
	if not upgradeable_pool.is_empty():
		pool = upgradeable_pool

	pool.shuffle()
	var picked_ids: Array = pool.slice(0, mini(ABILITY_CHOICE_COUNT, pool.size()))

	var offered: Array[Dictionary] = []
	for ability_id in picked_ids:
		var owned_rarity: int = _lowest_owned_ability_rarity(ability_id)
		var rarity: int = owned_rarity if owned_rarity >= 0 else _roll_rarity(ABILITY_RARITY_WEIGHTS)
		offered.append({"ability_id": ability_id, "rarity": rarity})
	return offered


## Nejnižší rarita, na které hráč AKTUÁLNĚ vlastní danou schopnost, nebo -1,
## pokud ji nevlastní vůbec - viz _roll_ability_options().
func _lowest_owned_ability_rarity(ability_id: String) -> int:
	var lowest: int = -1
	for entry in owned_abilities:
		if entry["ability_id"] == ability_id and (lowest < 0 or entry["rarity"] < lowest):
			lowest = entry["rarity"]
	return lowest


## True, pokud hráč aktuálně vlastní aspoň 1 kopii dané schopnosti (na
## libovolné raritě) - použito HUD pro zelený "vylepší vlastněnou schopnost"
## indikátor v AbilityDraftPanel (viz "Card0..2" v CLAUDE.md).
func is_ability_owned(ability_id: String) -> bool:
	return _lowest_owned_ability_rarity(ability_id) >= 0


## Pokud čeká aspoň jedna nabídka A zrovna žádná není rozehraná, vylosuje
## schopnosti a emitne ability_draft_ready. Podmínka
## `_current_ability_offer.is_empty()` je nutná - bez ní by každý _level_up()
## ve stejném volání add_xp() (velký přísun XP naráz povýší o víc úrovní ve
## smyčce) mohl vygenerovat a emitnout VLASTNÍ nabídku, i když už jedna čeká
## na vyřízení.
func _try_offer_next_ability_draft() -> void:
	if pending_ability_drafts <= 0 or not _current_ability_offer.is_empty():
		return

	_current_ability_offer = _roll_ability_options()
	ability_draft_ready.emit(_current_ability_offer)


## Zavolá HUD, když hráč (nebo Auto výběr) vybere schopnost z aktuální
## nabídky na daném indexu (stejný vzor jako buy_shop_item(offer_index) v
## obchodě). Vrací false, pokud zrovna žádná nabídka nečeká nebo index je
## mimo rozsah (ochrana proti zastaralému/duplicitnímu kliknutí).
func resolve_ability_draft(offer_index: int) -> bool:
	if pending_ability_drafts <= 0 or offer_index < 0 or offer_index >= _current_ability_offer.size():
		return false

	var offer_entry: Dictionary = _current_ability_offer[offer_index]
	pending_ability_drafts -= 1
	_current_ability_offer = []

	_add_ability(offer_entry["ability_id"], offer_entry["rarity"])

	_try_offer_next_ability_draft()
	# Kdyby zrovna čekalo odložené otevření obchodu (viz _shop_open_deferred) -
	# ať už proto, že tohle byla poslední čekající nabídka, nebo proto, že
	# _try_offer_next_ability_draft() zrovna žádnou další nevygeneroval -
	# zkusí ho otevřít teď. _try_open_pending_shop() si samo ověří, jestli
	# fronta schopností doopravdy doběhla do prázdna.
	if _shop_open_deferred:
		_try_open_pending_shop()
	# Úvodní nabídka schopnosti (viz begin_intro_ability_draft()) drží hru ve
	# State.INTRO, dokud ji hráč nevyřídí - jakmile fronta doběhne do prázdna,
	# přepneme na PLAYING tady, ne v player.gd (viz finish_intro()).
	if state == State.INTRO and pending_ability_drafts <= 0:
		finish_intro()
	return true


## Přidá novou instanci schopnosti a zkusí sloučení - stejný vzor jako
## buy_shop_item()/_try_merge_shop_item() v obchodě, jen bez gold/cost_paid.
func _add_ability(ability_id: String, rarity: int) -> void:
	owned_abilities.append({"ability_id": ability_id, "rarity": rarity})
	ability_inventory_changed.emit()
	_try_merge_ability(ability_id, rarity)


## Když má hráč aspoň ABILITY_MERGE_THRESHOLD (2) kopií stejné schopnosti na
## stejné raritě, automaticky je sloučí do 1 kopie o stupeň výš - stejná
## logika jako _try_merge_shop_item(), jen s nižším prahem a bez
## active/stash rozlišení (schopnosti nemají sklad, viz owned_abilities
## výše). Platí pro pasivní i aktivní schopnosti stejně. Rekurzivní pro
## řídký případ, kdy sloučení náhodou vytvoří hned další shodu (např.
## hromadný debug přírůstek).
func _try_merge_ability(ability_id: String, rarity: int) -> void:
	if rarity >= ShopRarity.DIAMOND:
		return

	var matching_indices: Array = []
	for i in owned_abilities.size():
		if owned_abilities[i]["ability_id"] == ability_id and owned_abilities[i]["rarity"] == rarity:
			matching_indices.append(i)

	if matching_indices.size() < ABILITY_MERGE_THRESHOLD:
		return

	var to_consume: Array = matching_indices.slice(0, ABILITY_MERGE_THRESHOLD)
	to_consume.sort_custom(func(a, b): return a > b)
	for index in to_consume:
		owned_abilities.remove_at(index)

	owned_abilities.append({"ability_id": ability_id, "rarity": rarity + 1})
	ability_inventory_changed.emit()
	_try_merge_ability(ability_id, rarity + 1)


## Kolik OWNED INSTANCÍ (schopností i aktivních obchodních itemů dohromady,
## ne unikátních ID) nese daný tag - viz "Tag synergie" v CLAUDE.md. Stash
## itemy se NEpočítají (stejné pravidlo jako get_stat_bonus() - jen aktivní
## itemy přispívají do statů). Používá se jak pro výpočet synergických
## bonusů (get_stat_bonus()), tak pro jejich popis (get_ability_desc()/
## get_shop_item_desc()).
func _count_owned_with_tag(tag: String) -> int:
	var count: int = 0
	for entry in owned_abilities:
		var tags: Array = ABILITIES[entry["ability_id"]].get("tags", [])
		if tags.has(tag):
			count += 1
	for entry in active_shop_items:
		var tags: Array = SHOP_ITEMS[entry["item_id"]].get("tags", [])
		if tags.has(tag):
			count += 1
	return count


## Samotný text HODNOTY schopnosti na dané raritě, BEZ tag suffixu -
## vytažené z get_ability_desc() (2026-09-25) tak, aby ho mohl HUD
## znovupoužít i samostatně pro zobrazení "výsledné" hodnoty po sloučení
## (viz "Zelené 'výsledné' hodnoty..." v CLAUDE.md, AbilityDraftPanel's
## ResultValueLabel) bez zdvojení tagu, který se pro danou schopnost
## nemění podle rarity.
func get_ability_value_text(ability_id: String, rarity: int) -> String:
	var definition: Dictionary = ABILITIES[ability_id]

	if definition["type"] == "passive":
		if definition.has("synergy"):
			var synergy: Dictionary = definition["synergy"]
			var per_count: float = float(synergy["value"]) * PASSIVE_EFFECT_MULTIPLIERS[rarity]
			var synergy_tag_name: String = TAG_DISPLAY_NAMES.get(synergy["tag"], synergy["tag"])
			return "%s za každou vlastněnou věc s tagem „%s“" % [
				_format_stat_line(synergy["stat"], per_count), synergy_tag_name
			]
		var value: float = float(definition["value"]) * PASSIVE_EFFECT_MULTIPLIERS[rarity]
		return _format_stat_line(definition["stat"], value)

	var params: Dictionary = definition["effect_params"]
	if definition["trigger"] == "shot_count" and definition["effect"] == "damage_multiplier":
		var interval: int = definition["trigger_values"][rarity]
		var mult: float = float(params["multiplier"])
		return "Každý %d. výstřel: %sx poškození" % [interval, _format_stat_number(mult)]

	if definition["trigger"] == "time_elapsed" and definition["effect"] == "aoe_strike":
		var charge: float = float(definition["trigger_values"][rarity])
		var damage: float = float(params["damage"])
		return "Nabíjí %s s, pak %s poškození všem nepřátelům" % [
			_format_stat_number(charge), _format_stat_number(damage)
		]

	return definition["name"]


## Popis schopnosti na dané raritě. Pasivní schopnosti mají obecný cyklus
## (jako get_shop_item_desc()), aktivní jsou zatím natvrdo podle dvou
## existujících trigger/effect párů - až přibude třetí, přejde i tahle větev
## na obecnější dispatch podle definition["trigger"]/["effect"]. Každá větev
## připojí na konec vlastní tag(y) (viz "Tag synergie" v CLAUDE.md) - i
## nesynergické schopnosti tag ukazují, ať si hráč může předem plánovat, co
## by k nim v budoucnu pasovalo.
func get_ability_desc(ability_id: String, rarity: int) -> String:
	var definition: Dictionary = ABILITIES[ability_id]
	var tag_suffix: String = _format_tag_suffix(definition.get("tags", []))
	return "%s%s" % [get_ability_value_text(ability_id, rarity), tag_suffix]


## Celkový bonus ke statu - jediné místo, kde se progrese promítá do statů,
## player.gd si ho jen přičítá ke svým base hodnotám. Sčítá ČTYŘI zdroje:
## automatický LEVEL_STAT_GROWTH (malá podlaha), pasivní schopnosti (pevné i
## tag-synergické), aktivní obchodní itemy (pevné i tag-synergické). AKTIVNÍ
## schopnosti (type "active") sem záměrně NEpatří - nedávají pasivní bonus ke
## statu, mají vlastní trigger/effect logiku (viz player.gd's
## _consume_ability_triggers()/_process_time_based_abilities()).
func get_stat_bonus(stat_id: String) -> float:
	var bonus: float = 0.0

	if LEVEL_STAT_GROWTH.has(stat_id):
		bonus += float(LEVEL_STAT_GROWTH[stat_id]) * float(player_level - 1)

	for entry in owned_abilities:
		var definition: Dictionary = ABILITIES[entry["ability_id"]]
		if definition["type"] != "passive":
			continue
		var multiplier: float = PASSIVE_EFFECT_MULTIPLIERS[entry["rarity"]]
		if definition.has("synergy"):
			var synergy: Dictionary = definition["synergy"]
			if synergy["stat"] == stat_id:
				bonus += float(synergy["value"]) * multiplier * float(_count_owned_with_tag(synergy["tag"]))
		elif definition["stat"] == stat_id:
			bonus += float(definition["value"]) * multiplier

	for entry in active_shop_items:
		var definition: Dictionary = SHOP_ITEMS[entry["item_id"]]
		var multiplier: float = SHOP_RARITY_MULTIPLIERS[entry["rarity"]]
		var stats: Dictionary = definition.get("stats", {})
		if stats.has(stat_id):
			bonus += float(stats[stat_id]) * multiplier
		var synergy: Dictionary = definition.get("synergy", {})
		if not synergy.is_empty() and synergy["stat"] == stat_id:
			bonus += float(synergy["value"]) * multiplier * float(_count_owned_with_tag(synergy["tag"]))

	return bonus


## Cena KOUPĚ itemu na daném stupni rarity - poměr ceny itemu podle
## SHOP_RARITY_COST_RATIOS.
func get_shop_item_cost(item_id: String, tier: ShopRarity) -> int:
	var base_cost: float = float(SHOP_ITEMS[item_id]["cost"])
	return int(round(base_cost * SHOP_RARITY_COST_RATIOS[tier]))


## Popis itemu se staty přepočítanými na danou raritu - na rozdíl od
## statického textu (co SHOP_ITEMS už nemá, viz komentář výše) tohle vždy
## odpovídá tomu, co item na daném stupni skutečně dává. `.get("stats", {})`
## místo přímého `["stats"]`, protože synergické itemy (viz "resonance_array")
## tenhle klíč vůbec nemají - mají "synergy" místo toho.
func get_shop_item_desc(item_id: String, tier: ShopRarity) -> String:
	var definition: Dictionary = SHOP_ITEMS[item_id]
	var multiplier: float = SHOP_RARITY_MULTIPLIERS[tier]
	var lines: Array[String] = []

	var stats: Dictionary = definition.get("stats", {})
	for stat_id in stats:
		var value: float = float(stats[stat_id]) * multiplier
		lines.append(_format_stat_line(stat_id, value))

	if definition.has("synergy"):
		var synergy: Dictionary = definition["synergy"]
		var per_count: float = float(synergy["value"]) * multiplier
		var synergy_tag_name: String = TAG_DISPLAY_NAMES.get(synergy["tag"], synergy["tag"])
		lines.append("%s za každou vlastněnou věc s tagem „%s“" % [
			_format_stat_line(synergy["stat"], per_count), synergy_tag_name
		])

	return "\n".join(lines) + _format_tag_suffix(definition.get("tags", []))


## Sdílené formátování tagu na konec popisu (get_ability_desc()/
## get_shop_item_desc()) - prázdný řetězec, když položka žádný tag nemá.
func _format_tag_suffix(tags: Array) -> String:
	if tags.is_empty():
		return ""
	var names: Array = []
	for tag in tags:
		names.append(TAG_DISPLAY_NAMES.get(tag, tag))
	return "\n[%s]" % ", ".join(names)


## Sdílené formátování jedné statové řádky v popisu (get_ability_desc()/
## get_shop_item_desc()) - "crit_chance" je JEDINÝ stat uložený jako podíl
## (0.08 = 8 %), takže dostává vlastní % formátování místo obecného
## STAT_DISPLAY_NAMES/_format_stat_number páru (viz komentář u
## STAT_DISPLAY_NAMES výše).
func _format_stat_line(stat_id: String, value: float) -> String:
	if stat_id == "crit_chance":
		return "+%s %% šance na kritický zásah" % _format_stat_number(value * 100.0)
	var stat_name: String = STAT_DISPLAY_NAMES.get(stat_id, stat_id)
	return "+%s %s" % [_format_stat_number(value), stat_name]


func _format_stat_number(value: float) -> String:
	if is_equal_approx(value, round(value)):
		return str(int(round(value)))
	return "%.1f" % value


## true, pokud nabídka na daném indexu existuje, hráč má dost zlata na její
## cenu (podle rarity, kterou nabídka vylosovala) a je volný aspoň jeden
## slot (aktivní NEBO sklad) - _refresh_shop_panel() v hud.gd tímhle
## rozhoduje, jestli má tlačítko "Koupit" být aktivní.
func can_buy_shop_item(offer_index: int) -> bool:
	if offer_index < 0 or offer_index >= shop_offer.size():
		return false
	var offer_entry: Dictionary = shop_offer[offer_index]
	if currency < get_shop_item_cost(offer_entry["item_id"], offer_entry["rarity"]):
		return false
	return active_shop_items.size() < SHOP_ACTIVE_SLOTS or stash_shop_items.size() < SHOP_STASH_SLOTS


## Koupí item z nabídky na indexu offer_index, v RARITĚ, kterou nabídka
## vylosovala (ne vždy BRONZE, viz _generate_shop_offer()). Koupený slot se
## z nabídky ODEBERE (hráč z jedné nabídky koupí 0 až SHOP_OFFER_SIZE kusů,
## ne opakovaně pořád ten samý) - kdo chce zkusit štěstí na jiný výběr, musí
## zaplatit reroll (viz reroll_shop()), ne překlikávat stejný slot. Nová
## kopie jde přednostně do aktivních slotů, do skladu jen když jsou aktivní
## plné - koupě tak hráče nikdy zbytečně neblokuje, jen mu časem zaplní
## sklad. Po přidání se zkusí sloučení (viz _try_merge_shop_item()).
func buy_shop_item(offer_index: int) -> bool:
	if not can_buy_shop_item(offer_index):
		return false

	var offer_entry: Dictionary = shop_offer[offer_index]
	var item_id: String = offer_entry["item_id"]
	var rarity: int = offer_entry["rarity"]
	var cost: int = get_shop_item_cost(item_id, rarity)

	currency -= cost
	currency_changed.emit(currency)

	var instance: Dictionary = {"item_id": item_id, "rarity": rarity, "cost_paid": cost}
	if active_shop_items.size() < SHOP_ACTIVE_SLOTS:
		active_shop_items.append(instance)
	else:
		stash_shop_items.append(instance)

	shop_offer.remove_at(offer_index)
	shop_offer_changed.emit(shop_offer)

	shop_inventory_changed.emit()
	_try_merge_shop_item(item_id, rarity)
	return true


## true, pokud item_id má blueprint vůbec (viz "blueprint_cost" v
## SHOP_ITEMS), hráč ho ještě nevlastní a má dost zlata na jeho JEDNORÁZOVOU
## cenu - viz "Suroviny a crafting" v CLAUDE.md.
func can_buy_blueprint(item_id: String) -> bool:
	if not SHOP_ITEMS.has(item_id) or not SHOP_ITEMS[item_id].has("blueprint_cost"):
		return false
	if owned_blueprints.has(item_id):
		return false
	return currency >= int(SHOP_ITEMS[item_id]["blueprint_cost"])


## Koupí blueprint za zlato - na rozdíl od buy_shop_item() jde o TRVALÝ
## odemykací nákup, ne spotřebovatelnou kopii itemu. Neplní aktivní/sklad
## sloty, jen odemyká craft_item() pro tenhle konkrétní item_id do konce
## běhu (reset v reset_game()).
func buy_blueprint(item_id: String) -> bool:
	if not can_buy_blueprint(item_id):
		return false

	currency -= int(SHOP_ITEMS[item_id]["blueprint_cost"])
	currency_changed.emit(currency)
	owned_blueprints.append(item_id)
	shop_inventory_changed.emit()
	return true


## true, pokud hráč vlastní blueprint na item_id, item má recept
## ("craft_scrap_cost"), hráč má dost šrotu a je volný aspoň jeden slot
## (aktivní NEBO sklad) - stejná dvojpodmínka jako can_buy_shop_item().
func can_craft_item(item_id: String) -> bool:
	if not owned_blueprints.has(item_id):
		return false
	if not SHOP_ITEMS.has(item_id) or not SHOP_ITEMS[item_id].has("craft_scrap_cost"):
		return false
	if scrap < int(SHOP_ITEMS[item_id]["craft_scrap_cost"]):
		return false
	return active_shop_items.size() < SHOP_ACTIVE_SLOTS or stash_shop_items.size() < SHOP_STASH_SLOTS


## Vyrobí novou BRONZE kopii item_id výměnou za šrot (recept
## SHOP_ITEMS[item_id]["craft_scrap_cost"]) - opakovatelné, dokud má hráč
## šrot a volný slot. Nová kopie jde do STEJNÉHO systému jako koupená (aktivní
## přednostně, jinak sklad, s automatickým sloučením 3 stejných na stejné
## raritě přes _try_merge_shop_item()) - crafting je jen další VSTUPNÍ bod do
## existující rarity+merge mechaniky, žádný nový power systém navíc.
## "cost_paid" je 0 (za TUHLE konkrétní kopii nebylo utraceno žádné zlato,
## jen jednorázově za blueprint) - prodej crafted kopie tak nic nevrátí,
## což brání smyčce "vyrob a hned prodej za zlato zdarma".
func craft_item(item_id: String) -> bool:
	if not can_craft_item(item_id):
		return false

	scrap -= int(SHOP_ITEMS[item_id]["craft_scrap_cost"])
	scrap_changed.emit(scrap)

	var instance: Dictionary = {"item_id": item_id, "rarity": ShopRarity.BRONZE, "cost_paid": 0}
	if active_shop_items.size() < SHOP_ACTIVE_SLOTS:
		active_shop_items.append(instance)
	else:
		stash_shop_items.append(instance)

	shop_inventory_changed.emit()
	_try_merge_shop_item(item_id, ShopRarity.BRONZE)
	return true


## Když má hráč (napříč aktivními sloty I skladem dohromady) aspoň 3 kopie
## stejného itemu na stejné raritě, automaticky je sloučí do 1 kopie o
## stupeň vyšší - jediný způsob, jak item ve hře posílit (žádné placené
## vylepšení). "cost_paid" sloučené kopie je součet všech 3 spotřebovaných,
## aby prodej pořád vracel poměrnou část ze VŠÍ investice (viz
## sell_shop_item()). Rekurzivní pro řídký případ, kdy sloučení náhodou
## vytvoří hned třetí kopii vyšší rarity (např. hromadný debug nákup).
func _try_merge_shop_item(item_id: String, rarity: int) -> void:
	if rarity >= ShopRarity.DIAMOND:
		return

	var matches: Array = []
	for i in active_shop_items.size():
		if active_shop_items[i]["item_id"] == item_id and active_shop_items[i]["rarity"] == rarity:
			matches.append({"collection": "active", "index": i})
	for i in stash_shop_items.size():
		if stash_shop_items[i]["item_id"] == item_id and stash_shop_items[i]["rarity"] == rarity:
			matches.append({"collection": "stash", "index": i})

	if matches.size() < 3:
		return

	var to_consume: Array = matches.slice(0, 3)
	# Mazat od nejvyššího indexu v každé kolekci, jinak by se nižší indexy
	# posunuly a další remove_at() by smazal špatný prvek.
	to_consume.sort_custom(func(a, b): return a["index"] > b["index"])

	var total_cost: int = 0
	for m in to_consume:
		var collection: Array = active_shop_items if m["collection"] == "active" else stash_shop_items
		total_cost += int(collection[m["index"]]["cost_paid"])
		collection.remove_at(m["index"])

	var merged_instance: Dictionary = {
		"item_id": item_id, "rarity": rarity + 1, "cost_paid": total_cost
	}
	if active_shop_items.size() < SHOP_ACTIVE_SLOTS:
		active_shop_items.append(merged_instance)
	else:
		stash_shop_items.append(merged_instance)

	shop_inventory_changed.emit()
	_try_merge_shop_item(item_id, rarity + 1)


## Přesune kopii z aktivních slotů do skladu (přestane přispívat do statů).
func move_shop_item_to_stash(index: int) -> bool:
	if index < 0 or index >= active_shop_items.size():
		return false
	if stash_shop_items.size() >= SHOP_STASH_SLOTS:
		return false

	var instance: Dictionary = active_shop_items[index]
	active_shop_items.remove_at(index)
	stash_shop_items.append(instance)
	shop_inventory_changed.emit()
	return true


## Přesune kopii ze skladu do aktivních slotů (začne přispívat do statů).
func move_shop_item_to_active(index: int) -> bool:
	if index < 0 or index >= stash_shop_items.size():
		return false
	if active_shop_items.size() >= SHOP_ACTIVE_SLOTS:
		return false

	var instance: Dictionary = stash_shop_items[index]
	stash_shop_items.remove_at(index)
	active_shop_items.append(instance)
	shop_inventory_changed.emit()
	return true


## Vrátí SHOP_SELL_REFUND_RATIO ze "cost_paid" prodávané kopie (u sloučeného
## itemu je to součet všech kopií, co ho vytvořily, viz _try_merge_shop_item())
## a kopie zmizí úplně z dané kolekce ("active" nebo "stash").
func sell_shop_item(collection_name: String, index: int) -> bool:
	var collection: Array = active_shop_items if collection_name == "active" else stash_shop_items
	if index < 0 or index >= collection.size():
		return false

	var instance: Dictionary = collection[index]
	var refund: int = int(round(float(instance["cost_paid"]) * SHOP_SELL_REFUND_RATIO))
	collection.remove_at(index)
	currency += refund
	currency_changed.emit(currency)
	shop_inventory_changed.emit()
	return true


## Přepne hru ze State.INTRO do State.PLAYING. Volá se z resolve_ability_draft(),
## jakmile hráč vyřídí úvodní nabídku schopnosti spuštěnou
## begin_intro_ability_draft() (viz player.gd's _on_landed()) - ne přímo po
## dopadové animaci, aby hráč dostal svou první volbu schopnosti dřív, než se
## rozeběhne pohyb/spawnování.
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


## DEBUG: rovnou vynutí jednu nabídku schopnosti bez čekání na level-up
func debug_force_ability_draft() -> void:
	pending_ability_drafts += 1
	_try_offer_next_ability_draft()


## DEBUG: nastaví každou schopnost rovnou na 1 kopii nejvyšší rarity
## (Diamant) - nejrychlejší cesta k "co nejsilnější build" pro testování.
func debug_max_abilities() -> void:
	owned_abilities.clear()
	for ability_id in ABILITY_ORDER:
		owned_abilities.append({"ability_id": ability_id, "rarity": ShopRarity.DIAMOND})
	ability_inventory_changed.emit()


## DEBUG: vymaže všechny vlastněné schopnosti - pro rychlé vyzkoušení jiného
## buildu. Stejně jako dřív nevrací žádné "body" - schopnosti se nekupují,
## jen se draftí při level-upu.
func debug_reset_abilities() -> void:
	owned_abilities.clear()
	ability_inventory_changed.emit()


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
