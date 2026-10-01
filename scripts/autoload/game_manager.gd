extends Node
## Globální singleton (Autoload) - řídí vlny nepřátel, měnu, zkušenosti,
## úrovně hráče a jeho vylepšení. Zaregistrován v Project Settings > Autoload
## jako "GameManager".

## Emitne se KAŽDÝ snímek, kdy state == State.PLAYING (top-down pivot
## 2026-09-27, Fáze 6 - nahrazuje wave_started/wave_cleared/loop_changed,
## všechny odstraněné spolu s celým vlnovým/kolovým systémem, viz
## "Kontinuální spawn/obtížnost" níže). HUD z toho počítá běžící "Čas: mm:ss".
signal survival_time_changed(new_time: float)
signal game_over_triggered
signal game_won_triggered
signal currency_changed(new_amount: int)
## Emitne se, když se změní množství suroviny (šrotu) - viz "Suroviny a
## crafting" v CLAUDE.md. Stejný vzor jako currency_changed.
signal scrap_changed(new_amount: int)
signal xp_changed(current_xp: int, xp_needed: int)
signal level_changed(new_level: int)
## Emitne se, když se změní počet nevyužitých bodů DOVEDNOSTI (meta level-up,
## nebo jejich utracení v lobby) - viz "Lobby a meta-progrese" v CLAUDE.md.
## HUD (v běhu, passivní odznáček) i lobby (aktivní investování) na to reagují.
## NEplete se s pending_ability_drafts/ability_draft_ready níže - to je
## souběžný, run-scoped systém (SCHOPNOSTI, náhodná nabídka po level-upu).
signal skill_points_changed(new_amount: int)
## Emitne se při META level-upu (dovednostní strom, trvalý přes běhy) - na
## rozdíl od level_changed výše, který je run-scoped a resetuje se každý běh.
signal meta_level_changed(new_level: int)
## Emitne se po investování bodu do uzlu DOVEDNOSTNÍHO stromu - HUD podle
## toho překreslí hromádku vlastněných schopností a otevřený SkillTreePanel,
## pokud je zrovna vidět.
signal skill_ranks_changed
## Emitne se, když je k dispozici nová nabídka SCHOPNOSTI k výběru (viz
## "Schopnosti (náhodná nabídka)" v CLAUDE.md) - HUD podle toho zobrazí
## AbilityDraftPanel. `offered` má vždy ABILITY_CHOICE_COUNT prvků, každý
## {"ability_id": String, "rarity": int}. Souběžný, samostatný systém od
## dovednostního stromu výše - obě sdílí stejný `ABILITIES` katalog, ale
## každý svým vlastním mechanismem (viz "Schopnosti (náhodná nabídka)").
signal ability_draft_ready(offered: Array)
## Emitne se po přidání nebo sloučení SCHOPNOSTI (owned_abilities) - HUD
## podle toho překreslí sloty vlastněných schopností. Bez parametru (jako
## shop_inventory_changed), protože jeden ability_id může mít víc současně
## vlastněných instancí na různých raritách, ne jediné číslo "rank".
signal ability_inventory_changed
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

## STALE (2026-09-27, top-down pivot Fáze 6): vlny/kola (FINAL_WAVE,
## current_wave, loop_count, ENEMY_HP_GROWTH_PER_LOOP, wave_started/
## wave_cleared/loop_changed) jsou PRYČ úplně - nahrazeny kontinuálním,
## časem řízeným systémem, viz "Kontinuální spawn/obtížnost" níže a
## survival_time/get_enemy_hp_multiplier().
##
## CORRECTION (2026-09-27, později téhož dne - "Lobby a meta-progrese" v
## CLAUDE.md): State.WON teď JE dosažitelné - main.gd volá trigger_win(), když
## survival_time překročí loop_duration_seconds ("běh dokončen", ne skutečný
## konec obsahu). Obě cesty (trigger_game_over()/trigger_win()) teď vedou do
## lobby scény (scenes/ui/lobby.tscn), ne do restart-na-místě.

## O kolik procent víc HP dostanou nově spawnutí nepřátelé za každou odehranou
## minutu přežití (spojitě, ne skokově po kolech jako dřív). PROZATÍMNÍ
## jednoduché lineární škálování jen přes HP a PRVNÍ ODHAD čísla (ne
## doladěné hraním, na rozdíl od většiny ostatních konstant v týhle sekci) -
## do budoucna se čeká na komplexnější systém (nové typy nepřátel, jiné
## staty, ...), viz get_enemy_hp_multiplier().
const ENEMY_HP_GROWTH_PER_MINUTE: float = 0.15
## Jak často (v sekundách reálného přežití) se automaticky otevře obchod -
## nahrazuje dřívější "na konci každého kola (10 vln)". Snížené z 240 na 90
## (2026-09-27, "Lobby a meta-progrese") - běh teď obvykle trvá jen
## loop_duration_seconds (main.gd, první odhad 180s), takže 240s by se obchod
## v běhu prakticky nikdy neotevřel. PRVNÍ ODHAD.
const SHOP_OPEN_INTERVAL_SECONDS: float = 90.0

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
	"move_speed": "rychlost pohybu",
	"dash_cooldown_reduction": "zkrácení dobíjení poskoku (s)",
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
	"mobility": "Mobilita",
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
## Barva rarity pro vizuální odlišení (index = ShopRarity) - použito
## kosočtvercovou ikonkou nad názvem v AbilityDraftPanel (viz rarity_icon.gd).
const SHOP_RARITY_COLORS: Array[Color] = [
	Color(0.80, 0.50, 0.20), # Bronz
	Color(0.75, 0.75, 0.78), # Stříbro
	Color(1.00, 0.84, 0.0),  # Zlato
	Color(0.25, 0.85, 1.0),  # Diamant
]

## --- Schopnosti - DVA SOUBĚŽNÉ, SČÍTAJÍCÍ SE systémy nad stejným katalogem -
## 2026-09-26: po zpětné vazbě uživatele ("chtěl jsem systém schopností
## ZACHOVAT, ne nahradit") existují teď vedle sebe DVĚ nezávislé cesty, jak
## stejná pojmenovaná schopnost (`ABILITIES[id]`) roste, a jejich příspěvky
## do `get_stat_bonus()` se SČÍTAJÍ:
##
## 1) **DOVEDNOSTI (strom)** - deterministické, vázané na LEVEL-UP
##    (`pending_skill_points`/`skill_ranks`/`SKILL_TREE_BRANCHES`, viz
##    "Dovednosti (strom)" v CLAUDE.md). Hráč sbírá bod za každý level-up a
##    sám si vybírá uzel k investici - žádná nabídka, žádné losování.
## 2) **SCHOPNOSTI (náhodná nabídka)** - stejné jako PŮVODNÍ systém před
##    2026-09-26 (rarity+merge draft, `owned_abilities`/`pending_ability_drafts`
##    atd., viz "Schopnosti (náhodná nabídka)" níže) - spouštěč: po dopadu
##    (jako vždy) A po KAŽDÉM run-scoped level-upu (`_level_up()` výše - top-
##    down pivot Fáze 6 nejdřív svázal tenhle spouštěč s časem, pak
##    2026-09-27 ráno na počet zabití, a tentýž den odpoledne se vrátil zpátky
##    na level-up, viz "Lobby a meta-progrese" v CLAUDE.md).
##
## Aby oba systémy mohly sdílet stejný `ABILITIES[id]` a přesto škálovat
## nezávisle, má aktivní schopnost DVĚ oddělená pole trigger hodnot:
## `"trigger_values"` (4 prvky, indexováno ShopRarity 0-3, pro SCHOPNOSTI) a
## `"skill_trigger_values"` (`"max_rank"` prvků, indexováno rank-1, pro
## DOVEDNOSTI) - viz get_ability_value_text() (rarita) vs.
## get_skill_node_value_text() (rank). Pasivní schopnosti sdílejí JEDNO
## `"value"` pole beze změny - jen se násobí jinak podle systému
## (`PASSIVE_EFFECT_MULTIPLIERS[rarity]` pro schopnosti, `* rank` lineárně
## pro dovednosti), takže je to pořád jedna základní hodnota za "Bronze
## ekvivalent", ne dvě oddělené čísla k ladění.
##
## Strom (dovednosti) má 4 VĚTVE podle tagu (SKILL_TREE_BRANCHES níže), každá
## pole ability_id OD KOŘENE PO CAPSTONE - kořen (index 0) nemá prerekvizit,
## každý další uzel se odemkne, jakmile má PŘEDCHOZÍ uzel v poli aspoň 1 bod
## (viz is_skill_node_unlocked()). "Odemčený" ale neznamená "zdarma" - kořen
## taky vyžaduje vlastní investovaný bod jako kterýkoliv jiný uzel, jen nemá
## žádnou podmínku PŘED sebou. Schopnosti (náhodná nabídka) nemají žádný
## strom/odemykání - jsou to nezávislé instance s vlastní raritou, viz níže.
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
		"trigger_values": [6, 5, 4, 3],
		"skill_trigger_values": [6, 5, 4],
		"effect": "damage_multiplier",
		"effect_params": {"multiplier": 2.0},
		"tags": ["explosive"], "max_rank": 3,
	},
	## Capstone explozivní větve v dovednostech (max_rank 5) - explozivní
	## větev má jen 2 uzly celkem (viz SKILL_TREE_BRANCHES), kratší než
	## ostatní tři.
	"orbital_bombardment": {
		"name": "Orbitální bombardování", "short_name": "Orbitál", "type": "active",
		"trigger": "time_elapsed",
		## Sekundy nabíjení, první odhad (viz project_balance_deferred v
		## paměti) - nedoladěno playtestingem.
		"trigger_values": [20.0, 15.0, 11.0, 8.0],
		## 5. stupeň pro dovednostní strom, pokračuje stejným klesajícím
		## tempem jako 4-stupňová rarity verze výše.
		"skill_trigger_values": [20.0, 15.0, 11.0, 8.0, 6.0],
		"effect": "aoe_strike",
		## Zasáhne VŠECHNY živé nepřátele (ne jen okruh kolem hráče) za tuhle
		## hodnotu - "screen-wide" efekt z původního brainstormu (viz
		## project_future_active_abilities v paměti), ne lokalizovaná exploze.
		## První odhad, nedoladěno playtestingem.
		"effect_params": {"damage": 30.0},
		"tags": ["explosive"], "max_rank": 5,
	},
	## Kořen Mobility větve (max_rank 3, viz SKILL_TREE_BRANCHES) - trvalý
	## protějšek speed_pickup.gd's DOČASNÉHO +15% bonusu (viz "Sebratelné
	## předměty" v CLAUDE.md), zapojený přes player.gd's get_move_speed().
	"swift_steps": {
		"name": "Hbité nohy", "short_name": "Nohy", "type": "passive",
		"stat": "move_speed", "value": 6.0, "tags": ["mobility"], "max_rank": 3,
	},
	## Capstone Mobility větve (max_rank 5) - flat redukce player.gd's
	## dash_cooldown (viz get_dash_cooldown()), ne % jako u ostatních statů -
	## stejná "flat, ne % " filozofie jako base_armor kvůli MIN_DASH_COOLDOWN
	## podlaze (viz player.gd).
	"rapid_recharge": {
		"name": "Rychlé dobíjení", "short_name": "Dobíjení", "type": "passive",
		"stat": "dash_cooldown_reduction", "value": 0.5, "tags": ["mobility"], "max_rank": 5,
	},
}
## Pořadí schopností v HUD - stejný účel jako SHOP_ITEM_ORDER.
const ABILITY_ORDER: Array[String] = [
	"power_core", "rapid_coils", "long_barrel", "split_rounds", "reinforced_plating",
	"nanite_repair", "kinetic_dampers", "overclock_matrix", "precision_targeting",
	"double_tap", "orbital_bombardment", "swift_steps", "rapid_recharge",
]
## 5 větví DOVEDNOSTNÍHO stromu (podle tagu), každá OD KOŘENE PO CAPSTONE -
## viz get_skill_prereq()/is_skill_node_unlocked(). Explozivní a Mobilita
## jsou záměrně kratší (jen 2 uzly) - strom nevyžaduje stejnou délku všude,
## jen konzistentní "kořen → ... → capstone" tvar. Netýká se schopností
## (náhodné nabídky) níže - ta žádný strom nemá.
const SKILL_TREE_BRANCHES: Array[Array] = [
	["power_core", "split_rounds", "overclock_matrix"],
	["rapid_coils", "long_barrel", "precision_targeting"],
	["reinforced_plating", "nanite_repair", "kinetic_dampers"],
	["double_tap", "orbital_bombardment"],
	["swift_steps", "rapid_recharge"],
]

## --- Schopnosti (náhodná nabídka) -----------------------------------------
## PŮVODNÍ systém (existoval před dovednostním stromem, obnoven 2026-09-26 po
## zpětné vazbě - "chtěl jsem systém schopností zachovat, ne nahradit") -
## náhodná nabídka `ABILITY_CHOICE_COUNT` (3) karet s rarity+merge mechanikou
## sdílenou s obchodem (`ShopRarity` enum/`SHOP_RARITY_NAMES`), nad STEJNÝM
## `ABILITIES` katalogem jako dovednostní strom výše - hráč tak může mít
## třeba "Jádro síly" na dovednostním stupni 2/3 A ZÁROVEŇ vlastnit 1
## nezávislou Stříbrnou kopii z náhodné nabídky, obojí se sčítá do
## `get_stat_bonus()`. Spouštěč: po dopadové animaci (jako vždy) a po sebrání
## kosočtverce, který dropne na dalším prahu zabití (viz "Schopnosti na
## základě zabití" níže) - NE po level-upu, to je jen dovednostní strom
## (viz výše).
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

## Jak dlouho (v sekundách) hráč PŘEŽÍVÁ v aktuálním běhu - tiká jen ve
## State.PLAYING (viz _process() níže), nahrazuje current_wave/loop_count
## jako jediný zdroj obtížnostní/tempové progrese (top-down pivot 2026-09-27,
## Fáze 6). Resetuje se jen na skutečný Game Over (reset_game()).
var survival_time: float = 0.0
## Akumulátor pro SHOP_OPEN_INTERVAL_SECONDS - viz _process() níže. Obchod
## zůstává na časovači beze změny (explicit user request 2026-09-27, "Lobby a
## meta-progrese") - jen interval zkrácen, ať se v kratším běhu stihne otevřít.
var _shop_open_timer: float = 0.0
var currency: int = 0
## Nakrafťovaná surovina (šrot) - vstup pro budoucí blueprinty/crafting v
## obchodě (viz "Suroviny a crafting" v CLAUDE.md). Zatím jediný typ suroviny,
## stejné run-scoped chování jako currency (resetuje se v reset_game()).
var scrap: int = 0
var enemies_alive: int = 0
var state: State = State.INTRO

## Run-scoped úroveň/XP - resetuje se KAŽDÝ běh (reset_game()). Řídí run-scoped
## odměny (LEVEL_STAT_GROWTH, a od "Lobby a meta-progrese" 2026-09-27 znovu i
## spouštění nabídky SCHOPNOSTÍ, viz _level_up() níže) - NEplete se s
## meta_level/meta_xp níže, což je TRVALÁ obdoba přes běhy pro dovednostní strom.
var player_level: int = 1
var player_xp: int = 0
## META úroveň/XP - TRVALÉ přes běhy (NEresetuje se v reset_game()), roste jen
## na konci běhu (smrt nebo dokončení smyčky) o _run_xp_earned, viz
## add_meta_xp()/_finish_run() níže. Zavedeno 2026-09-27 ("Lobby a
## meta-progrese") - dovednostní strom se přesunul z run-scoped level-upů do
## lobby mezi běhy právě proto, aby neinterferoval s tempem schopností v běhu.
var meta_level: int = 1
var meta_xp: int = 0
## Kolik XP hráč vydělal za AKTUÁLNÍ běh (add_xp() k tomu přičítá, bez ohledu
## na to, kolik z toho stihlo padnout do run-scoped level-upů) - na konci běhu
## se tohle číslo 1:1 převede na meta_xp (viz _finish_run()). Resetuje se v
## reset_game().
var _run_xp_earned: int = 0
## Souhrn POSLEDNÍHO dokončeného běhu ({"reason": "died"/"completed",
## "level": int, "currency": int, "meta_xp_gained": int}) - naplní ho
## _finish_run(), čte scenes/ui/lobby.gd při zobrazení souhrnu. NEresetuje se
## v reset_game() (potřebuje přežít do doby, kdy main.tscn._enter_tree()
## reset zavolá PŘED tím, než hráč lobby vůbec uvidí).
var last_run_summary: Dictionary = {}
## Kolik NEVYUŽITÝCH bodů dovednosti hráč aktuálně má - 1 za KAŽDÝ META
## level-up (viz add_meta_xp()), utrácí se přes invest_skill_point() v lobby.
## TRVALÉ přes běhy (NEresetuje se v reset_game(), od "Lobby a meta-progrese"
## 2026-09-27 - dřív se resetovalo, protože šlo o run-scoped level-upy).
var pending_skill_points: int = 0
## Aktuální stupeň KAŽDÉ investované schopnosti - {ability_id: rank}. Chybějící
## klíč (nebo get_skill_rank() vrátí 0) znamená "nevlastní vůbec". TRVALÉ přes
## běhy (stejná změna jako pending_skill_points výše) - investice v lobby tak
## permanentně zvyšují základní staty i v dalších bězích (get_stat_bonus()
## beze změny čte skill_ranks bez ohledu na to, kde se investovalo).
var skill_ranks: Dictionary = {}
## Vlastněné SCHOPNOSTI z náhodné nabídky (samostatný systém od
## skill_ranks výše, viz "Schopnosti (náhodná nabídka)") - pasivní
## přispívají do get_stat_bonus(), aktivní mají vlastní trigger/effect
## logiku v player.gd. Každý prvek je Dictionary {"ability_id": String,
## "rarity": int (ShopRarity)} - stejný tvar jako active_shop_items, jen bez
## "cost_paid" (schopnosti jsou free). Jeden ability_id může mít víc
## současně vlastněných prvků na RŮZNÝCH raritách (např. 1 Stříbrná kopie +
## 1 nová Bronzová po dalším pick-u, dokud nevznikne 2. Bronzová a nesloučí
## se) - žádný strop na počet, na rozdíl od obchodu (SHOP_ACTIVE_SLOTS/
## SHOP_STASH_SLOTS) schopnosti nemají aktivní/sklad dělení, protože nabídka
## je vždy jen ABILITY_CHOICE_COUNT schopností zdarma, ne omezený nákup.
## Víc vlastněných instancí STEJNÉ aktivní schopnosti spouští svůj efekt
## NEZÁVISLE (viz player.gd) - 2 kopie tak mohou na stejném triggeru spustit
## efekt obě najednou (násobiče se násobí, ne sčítají).
var owned_abilities: Array[Dictionary] = []
## Kolik nabídek schopností čeká na vyřízení - víc než 1 může nastat, když
## víc vln čeká na vyřešení naráz (v praxi hlavně na hranici 10. vlny, viz
## _try_open_pending_shop() níže). HUD nabídky vyřizuje jednu po druhé (viz
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
## Aktuálně nabídnuté itemy v obchodě (SHOP_OFFER_SIZE kusů) - každý prvek
## {"item_id": String, "rarity": ShopRarity}, viz _generate_shop_offer().
## Prázdné, dokud hráč poprvé nedohraje 10. vlnu.
var shop_offer: Array[Dictionary] = []
## Kolikrát byla aktuální nabídka přehozená - roste s reroll_shop(), resetuje
## se na 0 při každé nové nabídce. Určuje cenu dalšího rerollu.
var shop_reroll_count: int = 0
## true od chvíle, co v AKTUÁLNÍM běhu poprvé uplynul SHOP_OPEN_INTERVAL_
## SECONDS - do té doby obchod vůbec nemá žádnou nabídku (viz hud.gd).
## Resetuje se v reset_game() jako všechno ostatní run-scoped.
var shop_available: bool = false
## true, když čeká na otevření AUTOMATICKY otevřená nabídka obchodu (viz
## SHOP_OPEN_INTERVAL_SECONDS), ale zrovna běží nevyřízená nabídka schopnosti -
## viz _try_open_pending_shop(). Řeší kolizi: obchodní časovač a run-scoped
## level-up (spouštějící nabídku schopnosti, viz _level_up()) se mohou trefit
## do stejné chvíle, takže bez tohohle odložení by AbilityDraftPanel a
## ShopPanel mohly naskočit na sobě současně.
var _shop_open_deferred: bool = false
## DEBUG: když true, reroll_shop() nic neúčtuje - pro rychlé testování bez
## grindění zlata. Přepíná se v Debug panelu (hud.gd), NEresetuje se v
## reset_game() (stejná logika jako u Engine.time_scale v Debug panelu -
## je to vývojářské pohodlí napříč restarty, ne herní stav).
var debug_free_reroll: bool = false


## Volá main.gd v _enter_tree(), tedy DŘÍV než se spustí _ready() hráče a HUD -
## ty už tak čtou čerstvý stav. Kdyby se resetovalo až v _ready() Main uzlu,
## hráč by se po restartu naskočil se staty z předchozí hry.
## **NEresetuje** meta_level/meta_xp/pending_skill_points/skill_ranks (viz
## jejich komentáře výše) - to je záměrně TRVALÝ stav přes běhy, jediné, co
## reset_game() nesmí smazat (2026-09-27, "Lobby a meta-progrese").
func reset_game() -> void:
	survival_time = 0.0
	_shop_open_timer = 0.0
	_run_xp_earned = 0
	currency = 0
	enemies_alive = 0
	state = State.INTRO
	player_level = 1
	player_xp = 0
	scrap = 0
	pending_ability_drafts = 0
	_current_ability_offer = []
	owned_abilities.clear()
	active_shop_items.clear()
	stash_shop_items.clear()
	shop_offer.clear()
	shop_reroll_count = 0
	shop_available = false
	_shop_open_deferred = false


## Tiká jen ve State.PLAYING (stejný guard pattern jako player.gd's _process()
## pro HP regen atd.) - pohání survival_time a periodický obchod
## (SHOP_OPEN_INTERVAL_SECONDS, zatím zůstává na časovači, viz _shop_open_timer
## výše). Nabídka schopností je run-scoped level-up (_level_up()), ne časová.
func _process(delta: float) -> void:
	if state != State.PLAYING:
		return

	survival_time += delta
	survival_time_changed.emit(survival_time)

	_shop_open_timer += delta
	if _shop_open_timer >= SHOP_OPEN_INTERVAL_SECONDS:
		_shop_open_timer -= SHOP_OPEN_INTERVAL_SECONDS
		_open_periodic_shop()


## Zavolá level/spawner, aby oznámil, že spawnul nepřítele (pro GameManager.
## enemies_alive - main.gd podle něj rozhoduje, kolik dalších ještě spawnout,
## viz _spawn_around_player()/target_concurrent v main.gd).
func register_enemy_spawned() -> void:
	enemies_alive += 1


## Zavolá nepřítel při své smrti - přidá měnu, suroviny i XP. STALE poznámka:
## dřív tu byla i kontrola "vlna vyčištěná" (enemies_alive<=0 &&
## enemies_remaining_to_spawn<=0 -> _on_wave_cleared()) - ta odpadla úplně
## spolu s celým vlnovým systémem (Fáze 6); spawn nepřátel a obchod běží na
## čase (viz _process() výše). Nabídka SCHOPNOSTÍ se spouští z add_xp() →
## _level_up() (run-scoped, ne přímo tady) - viz "Lobby a meta-progrese" v
## CLAUDE.md (2026-09-27, vrací se z mezitímního kill-count/kosočtverec
## systému zpátky na XP/úroveň).
func enemy_defeated(reward: int, xp_reward: int, scrap_reward: int = 0) -> void:
	currency += reward
	currency_changed.emit(currency)
	scrap += scrap_reward
	scrap_changed.emit(scrap)
	add_xp(xp_reward)
	enemies_alive -= 1


## Obchod se odemyká a nabízí novou nabídku po SHOP_OPEN_INTERVAL_SECONDS
## reálného přežití (top-down pivot Fáze 6 - dřív na hranici mezi 10. vlnou a
## další, viz STALE poznámka u enemy_defeated()). shop_available zůstává true
## i pro zbytek běhu (hráč tlačítkem znovu otevře AKTUÁLNÍ nabídku), ale
## novou nabídku (a reset ceny rerollu) dostane jen na téhle hranici, ne při
## každém ručním otevření.
func _open_periodic_shop() -> void:
	shop_available = true
	shop_reroll_count = 0
	_generate_shop_offer()
	_try_open_pending_shop()


## Otevře obchod (emitne shop_auto_open_requested) HNED, pokud zrovna nečeká
## žádná nevyřízená nabídka SCHOPNOSTI - jinak otevření jen ODLOŽÍ
## (_shop_open_deferred) a schová se za resolve_ability_draft(), který tuhle
## funkci zavolá znovu, jakmile se poslední čekající nabídka vyřídí. Volá se
## jak z _open_periodic_shop() (časovač obchodu), tak z konce
## resolve_ability_draft() (dořešení odloženého otevření). Kolize je čistě
## náhodná (dva NEZÁVISLÉ časovače, viz _process() výše, se mohou trefit do
## stejné sekundy) - o nic méně reálná než dřív, jen bez vazby na "10. vlnu".
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


## Násobitel HP nově spawnutých nepřátel - SPOJITĚ podle survival_time (top-down
## pivot Fáze 6, dřív skokově podle loop_count). main.gd ho aplikuje v
## _spawn_around_player() ještě před tím, než nepřítel vstoupí do stromu (aby
## _ready() v enemy.gd nastavil hp = max_hp už se správnou hodnotou).
func get_enemy_hp_multiplier() -> float:
	return 1.0 + (survival_time / 60.0) * ENEMY_HP_GROWTH_PER_MINUTE


## Kolik XP je potřeba na další úroveň (roste lineárně s úrovní)
func xp_for_next_level() -> int:
	return XP_BASE + (player_level - 1) * XP_PER_LEVEL_GROWTH


## Přidá XP a případně povýší i o víc úrovní naráz (velký přebytek XP).
## `_run_xp_earned` sčítá VŠECHNO XP vydělané za tenhle běh (bez ohledu na to,
## kolik z toho padlo do run-scoped level-upů) - na konci běhu se 1:1 převede
## na meta_xp (viz _finish_run()).
func add_xp(amount: int) -> void:
	player_xp += amount
	_run_xp_earned += amount
	while player_xp >= xp_for_next_level():
		player_xp -= xp_for_next_level()
		_level_up()
	xp_changed.emit(player_xp, xp_for_next_level())


## Kolik META-XP je potřeba na další META úroveň - sdílí stejnou křivku jako
## xp_for_next_level() (první odhad, může se doladit nezávisle později).
## `level` je nepovinný (default = aktuální meta_level) - end-game animace
## (viz hud.gd's _animate_meta_xp_gain()) ho používá s konkrétní PROŠLOU
## úrovní, aby dopočítala práh pro KAŽDÝ mezistupeň animace, ne jen ten
## aktuální.
func meta_xp_for_next_level(level: int = 0) -> int:
	var target_level: int = level if level > 0 else meta_level
	return XP_BASE + (target_level - 1) * XP_PER_LEVEL_GROWTH


## Přidá META-XP (voláno jen z _finish_run() na konci běhu, ne za běhu) a
## případně povýší META úroveň i víckrát naráz - stejný while-loop tvar jako
## add_xp(), jen granuje pending_skill_points (TRVALé, viz jejich komentář
## výše) místo run-scoped efektu.
func add_meta_xp(amount: int) -> void:
	meta_xp += amount
	while meta_xp >= meta_xp_for_next_level():
		meta_xp -= meta_xp_for_next_level()
		meta_level += 1
		pending_skill_points += 1
		meta_level_changed.emit(meta_level)
		skill_points_changed.emit(pending_skill_points)


## Run-scoped level-up nabízí SCHOPNOST (náhodný draft) přímo, na KAŽDÉ úrovni
## - žádný interval/ramp, stejně jako celý tenhle systém fungoval PŘED
## 2026-09-27 ranním kill-count/kosočtverec
## experimentem - "Lobby a meta-progrese" ho vrací zpátky na XP/úroveň, ať
## nabídka pořád sleduje, co hráč DĚLÁ /zabíjí a levelu je z XP zabíjení/, jen
## přes jinou metriku). Dovednostní strom (pending_skill_points/skill_ranks)
## se do run-scoped level-upu už NEzapojuje vůbec - je teď META, roste jen na
## konci běhu (viz add_meta_xp()).
func _level_up() -> void:
	player_level += 1
	pending_ability_drafts += 1
	_try_offer_next_ability_draft()
	# level_changed teď skutečně mění staty (LEVEL_STAT_GROWTH, viz
	# get_stat_bonus()), ne jen UI sync.
	level_changed.emit(player_level)


## Vylosuje ABILITY_CHOICE_COUNT náhodných ABILITY_ORDER schopností (bez
## opakování stejného ID v rámci JEDNÉ nabídky, stejně jako
## _generate_shop_offer()) - nabídka se NEfiltruje podle toho, co už hráč
## vlastní PŘES NÁHODNOU NABÍDKU (stejná schopnost, kterou už má, je žádoucí
## - je to potenciální 2. kopie pro sloučení, viz _try_merge_ability()), AŽ
## na jednu výjimku: schopnost už vlastněná na ShopRarity.DIAMOND (nejvyšší
## stupeň) se z nabídkového poolu vyřadí úplně (protože _try_merge_ability()
## nikdy neslučuje nad Diamant, takže tam žádné "vylepšení" reálně
## neexistuje). Pokud by tohle vyřazení nechalo pool prázdný (hráč má VŠECHNY
## schopnosti na Diamantu přes náhodnou nabídku), padá zpátky na nefiltrovaný
## pool - lepší nabídnout "jen další nezávislou kopii" než nechat
## AbilityDraftPanel bez jediné karty. Rarita se losuje NEZÁVISLE
## (ABILITY_RARITY_WEIGHTS) jen pro schopnost, kterou hráč ještě vůbec
## nevlastní PŘES TUHLE NABÍDKU - pokud už vlastní aspoň jednu instanci
## daného ID (z předchozí nabídky), nabídne se na STEJNÉ raritě jako ta
## nejnižší vlastněná (_lowest_owned_ability_rarity()) místo nového
## nezávislého hodu. **Nezávisí na dovednostním stupni stejné schopnosti** -
## `owned_abilities`/rarita a `skill_ranks`/rank jsou dva oddělené stavy
## (viz "Schopnosti - DVA SOUBĚŽNÉ..." výše), takže investovaný dovednostní
## stupeň nijak neovlivňuje, na jaké raritě se tahle nabídka nabídne.
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


## Nejnižší rarita, na které hráč AKTUÁLNĚ vlastní danou schopnost PŘES
## NÁHODNOU NABÍDKU (owned_abilities), nebo -1, pokud ji tak nevlastní vůbec
## - viz _roll_ability_options(). Nekouká na skill_ranks (dovednostní strom).
func _lowest_owned_ability_rarity(ability_id: String) -> int:
	var lowest: int = -1
	for entry in owned_abilities:
		if entry["ability_id"] == ability_id and (lowest < 0 or entry["rarity"] < lowest):
			lowest = entry["rarity"]
	return lowest


## True, pokud hráč aktuálně vlastní aspoň 1 kopii dané schopnosti PŘES
## NÁHODNOU NABÍDKU (na libovolné raritě) - použito HUD pro zelený "vylepší
## vlastněnou schopnost" indikátor v AbilityDraftPanel.
func is_ability_owned(ability_id: String) -> bool:
	return _lowest_owned_ability_rarity(ability_id) >= 0


## Pokud čeká aspoň jedna nabídka A zrovna žádná není rozehraná, vylosuje
## schopnosti a emitne ability_draft_ready. Podmínka
## `_current_ability_offer.is_empty()` je nutná - bez ní by víc zdrojů
## nabídky (konec vlny, intro) najednou mohlo vygenerovat a emitnout VLASTNÍ
## nabídku, i když už jedna čeká na vyřízení.
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
	return true


## Přidá novou instanci schopnosti (náhodná nabídka) a zkusí sloučení -
## stejný vzor jako buy_shop_item()/_try_merge_shop_item() v obchodě, jen
## bez gold/cost_paid.
func _add_ability(ability_id: String, rarity: int) -> void:
	owned_abilities.append({"ability_id": ability_id, "rarity": rarity})
	ability_inventory_changed.emit()
	_try_merge_ability(ability_id, rarity)


## Když má hráč aspoň ABILITY_MERGE_THRESHOLD (2) kopií stejné schopnosti (z
## náhodné nabídky) na stejné raritě, automaticky je sloučí do 1 kopie o
## stupeň výš - stejná logika jako _try_merge_shop_item(), jen s nižším
## prahem a bez active/stash rozlišení (schopnosti nemají sklad, viz
## owned_abilities výše). Platí pro pasivní i aktivní schopnosti stejně.
## Rekurzivní pro řídký případ, kdy sloučení náhodou vytvoří hned další shodu
## (např. hromadný debug přírůstek).
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


## Kolik VLASTNĚNÝCH VĚCÍ nese daný tag - viz "Tag synergie" v CLAUDE.md.
## Sčítá TŘI zdroje: dovednostní strom (schopnost s rank >= 1 se počítá
## JEDNOU bez ohledu na výši ranku - synergie roste s POČTEM různých věcí
## stejného tagu, ne s tím, jak moc je do nich hráč investoval), schopnosti
## z náhodné nabídky (owned_abilities - tady se počítá KAŽDÁ INSTANCE
## zvlášť, i duplicity na různých raritách, protože to jsou nezávislé
## vlastněné kopie) a aktivní obchodní itemy. Stash itemy se NEpočítají
## (stejné pravidlo jako get_stat_bonus() - jen aktivní itemy přispívají do
## statů).
func _count_owned_with_tag(tag: String) -> int:
	var count: int = 0
	for ability_id in skill_ranks:
		if get_skill_rank(ability_id) <= 0:
			continue
		var tags: Array = ABILITIES[ability_id].get("tags", [])
		if tags.has(tag):
			count += 1
	for entry in owned_abilities:
		var tags: Array = ABILITIES[entry["ability_id"]].get("tags", [])
		if tags.has(tag):
			count += 1
	for entry in active_shop_items:
		var tags: Array = SHOP_ITEMS[entry["item_id"]].get("tags", [])
		if tags.has(tag):
			count += 1
	return count


## Samotný text HODNOTY dovednosti na daném STUPNI (1-based rank), BEZ tag
## suffixu - vytažené z get_skill_node_desc() tak, aby ho mohl SkillTreePanel
## v HUD zobrazit i samostatně. Škálování je LINEÁRNÍ ("value" * rank) -
## žádná multiplikátorová křivka, protože dovednostní strom má jen JEDNU
## rostoucí hodnotu na uzel, ne nezávisle rolovatelné kopie. Čte
## "skill_trigger_values" (rank-indexované), NE "trigger_values" (to je
## rarity-indexované pole pro get_ability_value_text() níže - viz "Schopnosti
## - DVA SOUBĚŽNÉ..." výše).
func get_skill_node_value_text(ability_id: String, rank: int) -> String:
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
		var interval: int = definition["skill_trigger_values"][rank - 1]
		var mult: float = float(params["multiplier"])
		return "Každý %d. výstřel: %sx poškození" % [interval, _format_stat_number(mult)]

	if definition["trigger"] == "time_elapsed" and definition["effect"] == "aoe_strike":
		var charge: float = float(definition["skill_trigger_values"][rank - 1])
		var damage: float = float(params["damage"])
		return "Nabíjí %s s, pak %s poškození všem nepřátelům" % [
			_format_stat_number(charge), _format_stat_number(damage)
		]

	return definition["name"]


## Popis dovednosti na daném stupni. Pasivní schopnosti mají obecný cyklus
## (jako get_shop_item_desc()), aktivní jsou zatím natvrdo podle dvou
## existujících trigger/effect párů - až přibude třetí, přejde i tahle větev
## na obecnější dispatch podle definition["trigger"]/["effect"]. Každá větev
## připojí na konec vlastní tag(y) (viz "Tag synergie" v CLAUDE.md) - i
## nesynergické schopnosti tag ukazují, ať si hráč může předem plánovat, co
## by k nim v budoucnu pasovalo.
func get_skill_node_desc(ability_id: String, rank: int) -> String:
	var definition: Dictionary = ABILITIES[ability_id]
	var tag_suffix: String = _format_tag_suffix(definition.get("tags", []))
	return "%s%s" % [get_skill_node_value_text(ability_id, rank), tag_suffix]


## Samotný text HODNOTY schopnosti (náhodná nabídka) na dané RARITĚ, BEZ tag
## suffixu - vytažené z get_ability_desc() tak, aby ho mohl HUD znovupoužít i
## samostatně. Čte "trigger_values" (4 prvky, rarity-indexované) - NE
## "skill_trigger_values" (to je pro dovednostní strom, viz
## get_skill_node_value_text() výše).
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


## Popis schopnosti (náhodná nabídka) na dané raritě.
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
## _consume_ability_triggers()/_process_time_based_abilities()). **SČÍTÁ
## DVA nezávislé zdroje schopností** (viz "Schopnosti - DVA SOUBĚŽNÉ..."
## výše): dovednostní strom (skill_ranks, lineární * rank) a náhodnou
## nabídku (owned_abilities, PASSIVE_EFFECT_MULTIPLIERS podle rarity) - hráč
## tak může mít stejnou schopnost rozestavěnou v OBOU systémech zároveň a
## jejich příspěvky se prostě sečtou.
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


## Přepne hru ze State.INTRO do State.PLAYING. STALE (2026-09-28): dřív ho
## volal resolve_ability_draft(), jakmile se vyřídila JEDINÁ vynucená úvodní
## nabídka SCHOPNOSTI - ta byla zrušená (explicit user request), takže teď
## volá přímo player.gd's `_on_landed()`, jakmile doběhnou kosmetické reakce
## na dopad (otřes kamery, squash tween, dopadový prstenec). Dovednostní
## strom se do intra nezapojuje vůbec (od 2026-09-26) ani teď.
func finish_intro() -> void:
	if state == State.INTRO:
		state = State.PLAYING


func trigger_game_over() -> void:
	if state == State.GAME_OVER:
		return
	_finish_run("died")
	state = State.GAME_OVER
	game_over_triggered.emit()
	print("Game Over! Přežitý čas: ", format_survival_time(survival_time), " | Úroveň: ", player_level)


## Zavolá main.gd, jakmile survival_time překročí loop_duration_seconds (běh
## dokončen bez smrti) - viz _check_loop_completion() a "Lobby a
## meta-progrese" v CLAUDE.md (2026-09-27). State.WON/VictoryPanel tu dřív
## čekaly nedosažitelné na budoucí "skutečný konec obsahu" - teď je "dokončení
## běhu" reálný, běžný způsob, jak se sem dostat, ne jen teoretický zbytek.
func trigger_win() -> void:
	if state == State.WON:
		return
	_finish_run("completed")
	state = State.WON
	game_won_triggered.emit()
	print("Level dokončen! Přežitý čas: ", format_survival_time(survival_time), " | Úroveň: ", player_level)


## Sdílený konec běhu pro smrt i dokončení smyčky (viz trigger_game_over()/
## trigger_win() výše) - uloží souhrn pro lobby (last_run_summary) a převede
## vydělané run-XP na TRVALÉ meta-XP, PŘED tím, než main.tscn._enter_tree()
## na cestě do dalšího běhu zavolá reset_game() a run-scoped stav smaže.
func _finish_run(reason: String) -> void:
	last_run_summary = {
		"reason": reason,
		"level": player_level,
		"currency": currency,
		"meta_xp_gained": _run_xp_earned,
		# Stav PŘED připočtením - end-game XP bar animace (hud.gd's
		# _animate_meta_xp_gain()) z něj animuje NAHORU ke skutečnému stavu
		# (meta_level/meta_xp), aby hráč viděl "líný" přírůstek, ne rovnou
		# hotový výsledek. Samotný stav je ale už finální, viz add_meta_xp()
		# níže - animace je čistě vizuální dohánění.
		"meta_level_before": meta_level,
		"meta_xp_before": meta_xp,
	}
	add_meta_xp(_run_xp_earned)


## Formátuje survival_time jako "mm:ss" - sdílené mezi tímhle debug printem a
## HUD (top-right časovač, Game Over/Victory panely), ať obojí ukazuje
## stejný formát ze stejného místa.
func format_survival_time(seconds: float) -> String:
	var total_seconds: int = int(seconds)
	return "%d:%02d" % [total_seconds / 60, total_seconds % 60]


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


## DEBUG: rovnou vynutí jednu nabídku SCHOPNOSTI (náhodný draft) bez čekání
## na level-up - stejná fronta/mechanismus jako _level_up() teď používá přímo.
func debug_force_ability_draft() -> void:
	pending_ability_drafts += 1
	_try_offer_next_ability_draft()


## DEBUG: nastaví každou schopnost (náhodná nabídka) rovnou na 1 kopii
## nejvyšší rarity (Diamant) - nejrychlejší cesta k "co nejsilnější build"
## pro testování. Nesahá na skill_ranks (dovednostní strom) - to je
## debug_max_skill_tree().
func debug_max_abilities() -> void:
	owned_abilities.clear()
	for ability_id in ABILITY_ORDER:
		owned_abilities.append({"ability_id": ability_id, "rarity": ShopRarity.DIAMOND})
	ability_inventory_changed.emit()


## DEBUG: vymaže všechny vlastněné schopnosti (náhodná nabídka) - pro rychlé
## vyzkoušení jiného buildu. Stejně jako dřív nevrací žádné "body" - schopnosti
## se nekupují, jen se draftí náhodně. Nesahá na skill_ranks (dovednostní
## strom) - to je debug_reset_skill_tree().
func debug_reset_abilities() -> void:
	owned_abilities.clear()
	ability_inventory_changed.emit()


## DEBUG: posune survival_time dopředu bez čekání - pro rychlé ruční
## otestování časových milníků (nabídka schopnosti, obchod, Elite checkpoint
## v main.gd) bez nutnosti skutečně tolik přežít. Nahrazuje dřívější
## debug_add_loop() (skokový přírůstek loop_count) - kontinuální systém
## žádný ekvivalent "kola" nemá, jen plynoucí čas.
func debug_add_survival_time(seconds: float) -> void:
	survival_time += seconds
	survival_time_changed.emit(survival_time)
