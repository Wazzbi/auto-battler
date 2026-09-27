extends Camera2D
## Kamera je NEZÁVISLÝ uzel (sourozenec hráče pod Main, ne jeho dítě) -
## sleduje hráče vlastní plynulou logikou (lerp) místo toho, aby s ním byla
## rigidně spojená transformací (jako dřív, kdy byla child node hráče).
##
## Top-down pivot (2026-09-27): kamera teď VYSTŘEDĚNÁ na hráči SYMETRICKY na
## obou osách (žádné odsazení k levému okraji) - se starou plošinovkovou
## chůzí-jen-doprava dávalo smysl mít hráče blíž levému okraji, aby bylo
## vidět dopředu; s volným 2D pohybem (viz player.gd) není žádný "dopředný"
## směr k rezervování místa pro. Obě osy teď lerpují stejně (dřív X lerpovalo,
## Y bylo instantní - ten rozdíl byl specifický pro plošinovkovou intro pádovou
## animaci, viz níže, a se symetrickým top-down pohybem už nedává smysl).
##
## STARÝ důvod pro lerp (X, dřív): dokud byla kamera child hráče, její pohyb
## byl 1:1 svázaný s jeho pohybem - jakmile hráč najednou zastavil (nepřítel
## vešel do dosahu a hráč přestal chodit), kamera se zastavila úplně stejně
## náhle, což způsobovalo skokovou změnu vnímané rychlosti nepřátel na
## obrazovce. Tahle konkrétní iluze byla specifická pro jednosměrnou chůzi a
## v top-down s volným pohybem už neplatí ve stejné podobě (hráč se může
## pohybovat k/od/kolmo k libovolnému nepříteli kdykoliv) - lerp ale zůstává,
## protože obecně dělá kameru příjemnější (méně "lepkavou" na každý drobný
## pohyb hráče), ne kvůli téhle konkrétní iluzi.
@export var follow_speed: float = 5.0

var _target: Node2D = null


## Zavolá main.gd po vytvoření hráče. Kamera se hned napozicuje přesně (bez
## plynutí) - jinak by na startu bylo vidět, jak kamera "přiletí" odjinud.
func set_target(target: Node2D) -> void:
	_target = target
	global_position = _target.global_position


func _process(delta: float) -> void:
	if _target == null:
		return

	var weight: float = 1.0 - exp(-follow_speed * delta)
	global_position = global_position.lerp(_target.global_position, weight)


## Krátký otřes kamery - volá se přes signál player.landed (viz main.gd),
## hráč sám o kameře nic neví a jen oznámí, že dopadl.
func shake(strength: float = 10.0, duration: float = 0.22) -> void:
	var steps := 6
	var shake_tween := create_tween()
	for i in range(steps):
		var shake_offset := Vector2(randf_range(-strength, strength), randf_range(-strength, strength))
		shake_tween.tween_property(self, "offset", shake_offset, duration / steps)
	shake_tween.tween_property(self, "offset", Vector2.ZERO, duration / steps)
