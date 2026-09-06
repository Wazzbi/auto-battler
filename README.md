# Auto-Battler Demo — Godot 4.7

## Jak spustit
1. Otevři Godot 4.7 (Forward+ nebo Mobile renderer).
2. "Import" → vyber tuto složku (soubor `project.godot`).
3. Stiskni F5 (Run Project). Hlavní scéna je `main.tscn`.

## Herní smyčka (aktuální verze)
- **Hráč** stojí a střílí, pokud má nepřítele v dosahu (`attack_range`).
  Pokud nikdo v dosahu není, postupuje doprava (`move_speed`) směrem
  ke konci levelu.
- **Kamera** je child node hráče (`scenes/player/player.tscn`), ale
  s vodorovným odsazením (`camera_left_margin`, výchozí 220 px) - hráč
  tak vychází poblíž levého okraje obrazovky, ne uprostřed. Odsazení se
  přepočítává i při změně velikosti okna (`get_viewport().size_changed`).
- **Nepřátelé** se spawnují kousek za pravým okrajem aktuálního záběru
  kamery (ne hráče - kamera je teď posunutá), takže spawn vždy drží
  krok s postupem levelem.
- **Podlaha** je procedurálně vykreslená dvoubarevná "šachovnice"
  (`scenes/levels/ground.gd`, přes `_draw()`) - žádný externí obrázek
  není potřeba a hlavně je na první pohled vidět, že se level pod
  hráčem skutečně posouvá.
- Po vyčištění vlny hráč dostane **1 skill point** a hra rovnou plynule
  pokračuje další (těžší) vlnou - žádné vynucené zastavení.
- Skill pointy se utrácí kdykoliv přes tlačítko **Upgrade** v HUD
  (otevře panel se staty a tlačítky +5 poškození / +0.2 rychlost útoku
  / +20 max HP). Panel hru nepauzuje.
- **Konec hry**: prohra při 0 HP, výhra při dosažení markeru `LevelEnd`
  na konci levelu (`scenes/levels/level_01.tscn`).

## Úvodní "drop-in" animace
Na startu hry postava spadne na svou startovní pozici shora (jako z
vesmírné výsadkové kapsle) - lehký náklon za letu, dopad se squash
efektem, krátký otřes kamery a expandující dopadová vlna
(`scenes/effects/impact_ring.gd`, čistě procedurální kreslení).

Dopadový efekt je čistě procedurální kreslení v
`scenes/effects/impact_effect.gd` (žádný externí obrázek).

Dokud animace neskončí, je hra ve stavu `GameManager.State.INTRO` -
veškerá herní logika (spawn nepřátel, pohyb hráče, útoky) je díky
existujícím kontrolám `if GameManager.state != State.PLAYING: return`
automaticky pozastavená, žádné další úpravy jinde nebyly potřeba.

Nastavitelné v `scenes/player/player.gd`:
- `fall_height` — z jaké výšky postava padá
- `fall_duration` — jak dlouho pád trvá
- `fall_tilt_degrees` — náklon za letu

## Oprava: "zkracující se dostřel"
Byl nalezen skutečný bug v `scenes/projectiles/projectile.gd`: úklid
projektilů mimo obrazovku porovnával světovou X pozici s fixní
velikostí okna (`get_viewport_rect().size.x`), místo s aktuální pozicí
kamery. Jakmile hráč postoupil levelem, projektily se ničily téměř
okamžitě po vystřelení, aniž by stihly cokoliv zasáhnout - proto to
vypadalo, že se dostřel s každou vlnou zkracuje. Opraveno tak, že se
teď porovnává vůči `get_viewport().get_camera_2d().global_position`.

Zároveň bylo přidáno:
- **Rozestupy mezi nepřáteli** (`enemy.gd`) - nezastavují se všichni
  na stejné pozici, ale vytvoří přirozenou "frontu"
- **Odmocninová křivka obtížnosti** (`main.gd`) - počet nepřátel ve
  vlně roste postupně místo skokově, plus limit `max_concurrent_enemies`
  brání přehlcení hráče
- **Dva nové upgrady** v HUD panelu: Dostřel (+50 px) a Cílů najednou
  (+1 multishot - hráč zasáhne více nepřátel jedním útokem)

## Co si projít a případně upravit
- `scenes/player/player.gd` — `move_speed`, `attack_range`,
  `camera_left_margin` (jak blízko levému okraji hráč zůstává), base staty
- `scenes/levels/level_01.tscn` — pozice `LevelEnd` markeru = délka levelu
- `scenes/levels/ground.gd` — `tile_size`, barvy dlaždic, `total_width`
  (mělo by pokrývat aspoň po `LevelEnd`, jinak podlaha "skončí" dřív)
- `scenes/main.gd` — počet nepřátel ve vlně, interval spawnování
- `scripts/autoload/game_manager.gd` — hodnoty upgradů, body za vlnu

## Důležité: skupina "level_end"
Marker `LevelEnd` v `level_01.tscn` musí být ve skupině **level_end** -
podle toho ho hráč při startu najde a zjistí, kde level končí. Pokud
by po otevření v editoru marker ve skupině nebyl (např. kvůli ručně
psanému souboru), stačí ho v editoru vybrat → záložka "Node" vpravo →
"Groups" → přidat `level_end`. Bez toho hráč jen nekonečně postupuje
dál (level_end_x zůstane nekonečno) a výhra se nikdy nespustí - snadno
poznatelné při testování.

## Známá zjednodušení (dobré vědět jako začátečník)
- Kolize/zásahy se řeší přes kontrolu vzdálenosti (`distance_to`), ne
  přes fyzikální Area2D/CollisionShape2D vrstvy - spolehlivé pro
  prototyp, ale při stovkách nepřátel by to chtělo optimalizovat.
- Vizuály jsou obarvené `Polygon2D` tvary místo sprite obrázků.
- Žádný Input Map není potřeba - hráč nic neovládá přímo, jen klikáním
  utrácí skill pointy v HUD.

## Pokud se projekt při otevření na něco stěžuje
Godot je citlivý na drobné nesrovnalosti v ručně psaných `.tscn`
souborech (např. `load_steps` počítadlo). Pokud uvidíš varování,
otevři danou scénu v Godot editoru a ulož ji (Ctrl+S) - engine si
soubor sám opraví/přepočítá.
