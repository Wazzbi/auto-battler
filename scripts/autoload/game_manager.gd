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
## Emitne se, když se změní počet nevyužitých bodů schopnosti (level-up,
## nebo jejich utracení) - viz "Dovednostní strom" v CLAUDE.md. HUD podle
## toho zbarví portrét a odznáček "+N" (žlutě, dokud je co utrácet).
signal skill_points_changed(new_amount: int)
## Emitne se po investování bodu do uzlu stromu - HUD podle toho překreslí
## hromádku vlastněných schopností a otevřený SkillTreePanel, pokud je zrovna
## vidět.
signal skill_ranks_changed
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
	"overcharged_core": {
		"name": "Přebíječ jader",
		"short_name": "Přebíječ",
		"stats": {"damage": 6.0, "attack_speed": 0.2},
		"cost": 200,
		"tags": ["kinetic"],
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
	},
	"nanite_regenerator": {
		"name": "Nanitový regenerátor",
		"short_name": "Regenerátor",
		"stats": {"hp_regen": 1.0, "armor": 3.0},
		"cost": 180,
		"tags": ["support"],
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
## posílit, žádné placené vylepšení už neexistuje. **Tenhle enum se od
## 2026-09-26 týká JEN obchodu** - schopnosti (viz "Schopnosti (dovednostní
## strom)" níže) mají od přechodu na deterministický strom vlastní, prostší
## systém "stupňů" (plain int rank, ne ShopRarity), protože tam už není co
## losovat.
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

## --- Schopnosti (dovednostní strom) --------------------------------------
## Přepracováno 2026-09-26 (explicit user request) z dřívějšího náhodného
## rarity+merge draftu na DETERMINISTICKÝ strom: hráč sbírá "body schopnosti"
## (1 za KAŽDÝ level-up, viz _level_up()/pending_skill_points) a sám si
## vybírá, do kterého uzlu ho investuje - žádná nabídka, žádné losování
## rarity, žádné slučování duplicit. Nahrazuje předchozí owned_abilities
## (Array instancí s nezávislou raritou) jediným `skill_ranks: Dictionary`
## {ability_id: rank}, protože teď existuje nanejvýš JEDNA "kopie" každé
## schopnosti, jen s rostoucím stupněm (rank 0 = nevlastněná).
##
## Pasivní schopnost: {"type": "passive", "stat": String, "value": float,
## "max_rank": int}. "value" je hodnota za JEDEN stupeň - get_stat_bonus()
## násobí "value" * aktuální rank (lineární škálování, žádná multiplikátorová
## křivka jako dřív PASSIVE_EFFECT_MULTIPLIERS - jednodušší a snáz čitelné
## přímo z čísla ve hře, "první průchod" stejně jako zbytek balance v tomhle
## projektu).
##
## Aktivní schopnost: {"type": "active", "trigger": String, "trigger_values":
## Array (JEDNA hodnota na KAŽDÝ stupeň, velikost pole = "max_rank"),
## "effect": String, "effect_params": Dictionary}. Stupeň škáluje FREKVENCI
## triggeru (kratší interval = vyšší uptime), NE sílu efektu (effect_params
## zůstává na všech stupních stejný) - stejná filozofie jako dřív, jen teď
## indexovaná rank-1 místo ShopRarity. Řešení konkrétních trigger/effect
## párů je hardcoded v player.gd (_consume_ability_triggers() pro
## "shot_count", _process_time_based_abilities() pro "time_elapsed") a v
## get_ability_value_text() níže - obecný dispatch teprve až bude třeba pro
## 3. typ.
##
## Strom má 4 VĚTVE podle tagu (SKILL_TREE_BRANCHES níže), každá pole
## ability_id OD KOŘENE PO CAPSTONE - kořen (index 0) nemá prerekvizit,
## každý další uzel se odemkne, jakmile má PŘEDCHOZÍ uzel v poli aspoň 1 bod
## (viz is_skill_node_unlocked()). "Odemčený" ale neznamená "zdarma" - kořen
## taky vyžaduje vlastní investovaný bod jako kterýkoliv jiný uzel, jen nemá
## žádnou podmínku PŘED sebou.
const ABILITIES := {
	"power_core": {
		"name": "Jádro síly", "short_name": "Jádro", "type": "passive",
		"stat": "damage", "value": 4.0, "tags": ["kinetic"], "max_rank": 3,
	},
	"rapid_coils": {
		"name": "Rychlopalné cívky", "short_name": "Palba", "type": "passive",
		"stat": "attack_speed", "value": 0.15, "tags": ["precision"], "max_rank": 3,
	},
	"long_barrel": {
		"name": "Prodloužená hlaveň", "short_name": "Dostřel", "type": "passive",
		"stat": "attack_range", "value": 40.0, "tags": ["precision"], "max_rank": 3,
	},
	"split_rounds": {
		"name": "Dělené střely", "short_name": "Rozptyl", "type": "passive",
		"stat": "multishot", "value": 1.0, "tags": ["kinetic"], "max_rank": 3,
	},
	"reinforced_plating": {
		"name": "Zesílený pancíř", "short_name": "Pancíř", "type": "passive",
		"stat": "max_hp", "value": 20.0, "tags": ["support"], "max_rank": 3,
	},
	"nanite_repair": {
		"name": "Nanitová oprava", "short_name": "Regen", "type": "passive",
		"stat": "hp_regen", "value": 0.5, "tags": ["support"], "max_rank": 3,
	},
	## Capstone podpůrné větve (max_rank 5, viz SKILL_TREE_BRANCHES) - jediný
	## uzel ve větvi, který lze investovat nad 3 stupně.
	"kinetic_dampers": {
		"name": "Kinetické tlumiče", "short_name": "Tlumiče", "type": "passive",
		"stat": "armor", "value": 2.0, "tags": ["support"], "max_rank": 5,
	},
	## Synergická schopnost (přidáno 2026-09-25, viz "Tag synergie" v
	## CLAUDE.md) - na rozdíl od ostatních pasivních schopností nemá pevné
	## "stat"/"value", ale "synergy": bonus roste s POČTEM vlastněných věcí
	## (schopností i aktivních itemů dohromady) se stejným tagem, včetně sebe
	## sama. Zrcadlí shop_items' "resonance_array" - stejný tag (precision),
	## opačný směr (hráč si tohle může vybrat jako schopnost první a pak
	## lovit Přesné itemy v obchodě, nebo naopak). Capstone kinetické větve.
	"overclock_matrix": {
		"name": "Přetěžovací matice", "short_name": "Matice", "type": "passive",
		"synergy": {"stat": "damage", "tag": "kinetic", "value": 1.5}, "tags": ["kinetic"],
		"max_rank": 5,
	},
	## Přidáno 2026-09-25 s novým statem crit_chance (viz player.gd's
	## get_crit_chance()/_shoot()) - tag "precision" stejně jako ostatní
	## schopnosti kolem přesnosti/frekvence útoku (rapid_coils, long_barrel).
	## Capstone přesné větve.
	"precision_targeting": {
		"name": "Přesné zaměřování", "short_name": "Zaměření", "type": "passive",
		"stat": "crit_chance", "value": 0.06, "tags": ["precision"], "max_rank": 5,
	},
	"double_tap": {
		"name": "Dvojitý zásah", "short_name": "D. zásah", "type": "active",
		"trigger": "shot_count",
		"trigger_values": [6, 5, 4],
		"effect": "damage_multiplier",
		"effect_params": {"multiplier": 2.0},
		"tags": ["explosive"], "max_rank": 3,
	},
	## Capstone explozivní větve (max_rank 5) - explozivní má jen 2 uzly
	## celkem (viz SKILL_TREE_BRANCHES), kratší větev než ostatní tři.
	"orbital_bombardment": {
		"name": "Orbitální bombardování", "short_name": "Orbitál", "type": "active",
		"trigger": "time_elapsed",
		## Sekundy nabíjení, první odhad (viz project_balance_deferred v
		## paměti) - nedoladěno playtestingem. 5. stupeň přidán při přechodu
		## na strom, pokračuje stejným klesajícím tempem jako předchozí 4.
		"trigger_values": [20.0, 15.0, 11.0, 8.0, 6.0],
		"effect": "aoe_strike",
		## Zasáhne VŠECHNY živé nepřátele (ne jen okruh kolem hráče) za tuhle
		## hodnotu - "screen-wide" efekt z původního brainstormu (viz
		## project_future_active_abilities v paměti), ne lokalizovaná exploze.
		## První odhad, nedoladěno playtestingem.
		"effect_params": {"damage": 30.0},
		"tags": ["explosive"], "max_rank": 5,
	},
}
## Pořadí schopností v HUD - stejný účel jako SHOP_ITEM_ORDER.
const ABILITY_ORDER: Array[String] = [
	"power_core", "rapid_coils", "long_barrel", "split_rounds", "reinforced_plating",
	"nanite_repair", "kinetic_dampers", "overclock_matrix", "precision_targeting",
	"double_tap", "orbital_bombardment",
]
## 4 větve dovednostního stromu (podle tagu), každá OD KOŘENE PO CAPSTONE -
## viz get_skill_prereq()/is_skill_node_unlocked(). Explozivní větev je
## záměrně kratší (jen 2 uzly, oba existující aktivní schopnosti) - strom
## nevyžaduje stejnou délku všude, jen konzistentní "kořen → ... → capstone"
## tvar.
const SKILL_TREE_BRANCHES: Array[Array] = [
	["power_core", "split_rounds", "overclock_matrix"],
	["rapid_coils", "long_barrel", "precision_targeting"],
	["reinforced_plating", "nanite_repair", "kinetic_dampers"],
	["double_tap", "orbital_bombardment"],
]

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
## Kolik NEVYUŽITÝCH bodů schopnosti hráč aktuálně má - 1 za KAŽDÝ level-up
## (viz _level_up()), utrácí se přes invest_skill_point(). Na rozdíl od
## dřívějšího pending_ability_drafts se NIC nenabízí automaticky - hráč si
## body drží, dokud sám neotevře strom (klik na portrét v HUD) a nevybere
## uzel. Pokud hráč ignoruje portrét přes víc levelů, číslo prostě roste.
var pending_skill_points: int = 0
## Aktuální stupeň KAŽDÉ investované schopnosti - {ability_id: rank}. Chybějící
## klíč (nebo get_skill_rank() vrátí 0) znamená "nevlastní vůbec". Nahrazuje
## dřívější owned_abilities (Array nezávislých instancí s vlastní raritou) -
## teď existuje nanejvýš JEDNA "kopie" každé schopnosti, jen s rostoucím
## rankem, takže stačí jedno číslo na ability_id, žádné pole instancí.
var skill_ranks: Dictionary = {}
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
	pending_skill_points = 0
	skill_ranks.clear()
	active_shop_items.clear()
	stash_shop_items.clear()
	shop_offer.clear()
	shop_reroll_count = 0
	shop_available = false


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
## Body schopnosti se od 2026-09-26 už nenabízí přes žádný pozastavující
## panel na KAŽDÉM level-upu (viz "Dovednostní strom" výše) - jediný panel,
## co se ještě automaticky vynucuje, je SkillTreePanel na úplném začátku hry
## (viz begin_intro_skill_tree()), a to je dávno před tím, než může nastat
## 10. vlna. Otevření obchodu tak už nemůže kolidovat s ničím dalším a může
## emitnout shop_auto_open_requested rovnou, bez dřívějšího odkladu
## (_shop_open_deferred/_try_open_pending_shop(), obojí odstraněno).
func _open_periodic_shop() -> void:
	shop_available = true
	shop_reroll_count = 0
	_generate_shop_offer()
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


## Vylosuje raritu podle zadaných vah (kumulativní pravděpodobnost) - dnes
## volané jen pro obchod (SHOP_RARITY_WEIGHTS); schopnosti od přechodu na
## deterministický strom už žádné losování rarity nemají.
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
## _on_landed()) - přidá 1 bod schopnosti stejně jako běžný level-up, jen bez
## přírůstku úrovně/XP (hráč už je na úrovni 1 z reset_game()). Hra zůstává
## ve State.INTRO (takže pohyb hráče, spawn nepřátel atd. pořád nic nedělají,
## viz jejich `state != State.PLAYING` guardy), dokud hráč PRVNÍ POPRVÉ
## nezavře SkillTreePanel - hud.gd force-otevře panel samo, jakmile si přes
## skill_points_changed všimne State.INTRO (viz "Dovednostní strom" v
## CLAUDE.md), a finish_intro() zavolá až na zavření panelu, ne na
## vyčerpání bodů (hráč nemusí bod hned utratit).
func begin_intro_skill_tree() -> void:
	pending_skill_points += 1
	skill_points_changed.emit(pending_skill_points)


func _level_up() -> void:
	player_level += 1
	# Bod schopnosti přijde na KAŽDÉ úrovni - žádný interval/ramp (viz
	# "Schopnosti" výše). Na rozdíl od dřívějšího draftu se ale NIC
	# nenabízí/nepozastavuje automaticky - hráč si bod jen přičte a utratí
	# ho, až sám otevře strom (klik na portrét).
	pending_skill_points += 1
	# level_changed teď skutečně mění staty (LEVEL_STAT_GROWTH, viz
	# get_stat_bonus()), ne jen UI sync - ale schopnosti pořád zůstávají
	# hlavním zdrojem růstu, level growth je jen malá podlaha navrch.
	level_changed.emit(player_level)
	skill_points_changed.emit(pending_skill_points)


## Prerekvizita uzlu podle jeho pozice v SKILL_TREE_BRANCHES, nebo "" pro
## kořen větve (žádná prerekvizita). O(1) na ability_id díky malému počtu
## větví/uzlů - není potřeba rychlejší vyhledávací struktura.
func get_skill_prereq(ability_id: String) -> String:
	for branch in SKILL_TREE_BRANCHES:
		var index: int = branch.find(ability_id)
		if index > 0:
			return branch[index - 1]
	return ""


## Uzel je odemčený, pokud je to kořen větve (žádná prerekvizita), NEBO má
## jeho prerekvizita aspoň 1 investovaný bod - viz "Dovednostní strom" v
## CLAUDE.md ("odemčený" neznamená "zdarma", kořen pořád vyžaduje vlastní
## investici, jen nemá podmínku před sebou).
func is_skill_node_unlocked(ability_id: String) -> bool:
	var prereq: String = get_skill_prereq(ability_id)
	return prereq == "" or get_skill_rank(prereq) >= 1


## Aktuální stupeň schopnosti, nebo 0, pokud do ní hráč ještě nic
## neinvestoval.
func get_skill_rank(ability_id: String) -> int:
	return int(skill_ranks.get(ability_id, 0))


func get_skill_max_rank(ability_id: String) -> int:
	return int(ABILITIES[ability_id]["max_rank"])


## true, pokud má hráč aspoň 1 nevyužitý bod, uzel je odemčený a ještě
## nedosáhl svého stropu - SkillTreePanel podle tohohle povoluje/zakazuje
## tlačítko "Investovat" u každého uzlu.
func can_invest_skill_point(ability_id: String) -> bool:
	if pending_skill_points <= 0:
		return false
	if not is_skill_node_unlocked(ability_id):
		return false
	return get_skill_rank(ability_id) < get_skill_max_rank(ability_id)


## Utratí 1 nevyužitý bod schopnosti za zvýšení stupně daného uzlu o 1 -
## jediný způsob, jak schopnost ve hře posílit (žádné losování, žádné
## slučování duplicit, na rozdíl od dřívějšího draft systému). Volá HUD při
## kliknutí na tlačítko uzlu v SkillTreePanelu.
func invest_skill_point(ability_id: String) -> bool:
	if not can_invest_skill_point(ability_id):
		return false

	pending_skill_points -= 1
	skill_ranks[ability_id] = get_skill_rank(ability_id) + 1
	skill_points_changed.emit(pending_skill_points)
	skill_ranks_changed.emit()
	return true


## Kolik VLASTNĚNÝCH VĚCÍ (investovaných schopností i aktivních obchodních
## itemů dohromady, ne unikátních ID) nese daný tag - viz "Tag synergie" v
## CLAUDE.md. Schopnost se počítá jako "vlastněná", pokud má rank >= 1, BEZ
## OHLEDU na výši ranku (synergie roste s POČTEM různých věcí stejného tagu,
## ne s tím, jak moc je do nich hráč investoval). Stash itemy se NEpočítají
## (stejné pravidlo jako get_stat_bonus() - jen aktivní itemy přispívají do
## statů). Používá se jak pro výpočet synergických bonusů (get_stat_bonus()),
## tak pro jejich popis (get_ability_value_text()/get_shop_item_desc()).
func _count_owned_with_tag(tag: String) -> int:
	var count: int = 0
	for ability_id in skill_ranks:
		if get_skill_rank(ability_id) <= 0:
			continue
		var tags: Array = ABILITIES[ability_id].get("tags", [])
		if tags.has(tag):
			count += 1
	for entry in active_shop_items:
		var tags: Array = SHOP_ITEMS[entry["item_id"]].get("tags", [])
		if tags.has(tag):
			count += 1
	return count


## Samotný text HODNOTY schopnosti na daném STUPNI (1-based rank, ne rarita -
## viz "Dovednostní strom" výše), BEZ tag suffixu - vytažené z
## get_ability_desc() tak, aby ho mohl SkillTreePanel v HUD zobrazit i
## samostatně (např. náhled "co dostanu na příštím stupni" v budoucnu) bez
## zdvojení tagu, který se pro danou schopnost nemění podle ranku. Škálování
## je LINEÁRNÍ ("value" * rank) - žádná multiplikátorová křivka jako dřív
## PASSIVE_EFFECT_MULTIPLIERS, protože teď existuje jen JEDNA rostoucí
## hodnota na uzel, ne nezávisle rolovatelné kopie.
func get_ability_value_text(ability_id: String, rank: int) -> String:
	var definition: Dictionary = ABILITIES[ability_id]

	if definition["type"] == "passive":
		if definition.has("synergy"):
			var synergy: Dictionary = definition["synergy"]
			var per_count: float = float(synergy["value"]) * float(rank)
			var synergy_tag_name: String = TAG_DISPLAY_NAMES.get(synergy["tag"], synergy["tag"])
			return "%s za každou vlastněnou věc s tagem „%s“" % [
				_format_stat_line(synergy["stat"], per_count), synergy_tag_name
			]
		var value: float = float(definition["value"]) * float(rank)
		return _format_stat_line(definition["stat"], value)

	var params: Dictionary = definition["effect_params"]
	if definition["trigger"] == "shot_count" and definition["effect"] == "damage_multiplier":
		var interval: int = definition["trigger_values"][rank - 1]
		var mult: float = float(params["multiplier"])
		return "Každý %d. výstřel: %sx poškození" % [interval, _format_stat_number(mult)]

	if definition["trigger"] == "time_elapsed" and definition["effect"] == "aoe_strike":
		var charge: float = float(definition["trigger_values"][rank - 1])
		var damage: float = float(params["damage"])
		return "Nabíjí %s s, pak %s poškození všem nepřátelům" % [
			_format_stat_number(charge), _format_stat_number(damage)
		]

	return definition["name"]


## Popis schopnosti na daném stupni. Pasivní schopnosti mají obecný cyklus
## (jako get_shop_item_desc()), aktivní jsou zatím natvrdo podle dvou
## existujících trigger/effect párů - až přibude třetí, přejde i tahle větev
## na obecnější dispatch podle definition["trigger"]/["effect"]. Každá větev
## připojí na konec vlastní tag(y) (viz "Tag synergie" v CLAUDE.md) - i
## nesynergické schopnosti tag ukazují, ať si hráč může předem plánovat, co
## by k nim v budoucnu pasovalo.
func get_ability_desc(ability_id: String, rank: int) -> String:
	var definition: Dictionary = ABILITIES[ability_id]
	var tag_suffix: String = _format_tag_suffix(definition.get("tags", []))
	return "%s%s" % [get_ability_value_text(ability_id, rank), tag_suffix]


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

	for ability_id in skill_ranks:
		var rank: int = get_skill_rank(ability_id)
		if rank <= 0:
			continue
		var definition: Dictionary = ABILITIES[ability_id]
		if definition["type"] != "passive":
			continue
		if definition.has("synergy"):
			var synergy: Dictionary = definition["synergy"]
			if synergy["stat"] == stat_id:
				bonus += float(synergy["value"]) * float(rank) * float(_count_owned_with_tag(synergy["tag"]))
		elif definition["stat"] == stat_id:
			bonus += float(definition["value"]) * float(rank)

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


## Přepne hru ze State.INTRO do State.PLAYING. Volá HUD (hud.gd's
## _on_skill_tree_close_pressed()), jakmile hráč POPRVÉ zavře SkillTreePanel
## force-otevřený begin_intro_skill_tree() (viz player.gd's _on_landed()) -
## ne přímo po dopadové animaci, aby hráč dostal svou první volbu schopnosti
## dřív, než se rozeběhne pohyb/spawnování. Na rozdíl od dřívějšího
## resolve_ability_draft() nezáleží na tom, jestli hráč bod skutečně utratil -
## zavření panelu samo stačí, protože bod zůstává čekat (žádná nabídka
## nevyprší).
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


## DEBUG: rovnou přidá 1 bod schopnosti bez čekání na level-up
func debug_add_skill_point() -> void:
	pending_skill_points += 1
	skill_points_changed.emit(pending_skill_points)


## DEBUG: nastaví KAŽDÝ uzel stromu rovnou na jeho max_rank - nejrychlejší
## cesta k "co nejsilnější build" pro testování. Nevrací nevyužité body
## (žádné nezůstávají, každý uzel je na svém stropu).
func debug_max_skill_tree() -> void:
	skill_ranks.clear()
	for ability_id in ABILITY_ORDER:
		skill_ranks[ability_id] = int(ABILITIES[ability_id]["max_rank"])
	skill_ranks_changed.emit()


## DEBUG: vymaže celý strom VČETNĚ čekajících bodů - pro rychlé vyzkoušení
## jiného buildu od nuly.
func debug_reset_skill_tree() -> void:
	skill_ranks.clear()
	pending_skill_points = 0
	skill_points_changed.emit(pending_skill_points)
	skill_ranks_changed.emit()


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
