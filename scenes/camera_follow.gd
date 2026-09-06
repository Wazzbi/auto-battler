extends Camera2D
## Kamera je NEZÁVISLÝ uzel (sourozenec hráče pod Main, ne jeho dítě) -
## sleduje hráče vlastní plynulou logikou na ose X místo toho, aby s ním byla
## rigidně spojená transformací (jako dřív, kdy byla child node hráče).
##
## Důvod: dokud byla kamera child hráče, její pohyb byl 1:1 svázaný s jeho
## pohybem - jakmile hráč najednou zastavil (nepřítel vešel do dosahu a hráč
## přestal chodit), kamera se zastavila úplně stejně náhle. To způsobovalo
## skokovou změnu vnímané rychlosti nepřátel na obrazovce (viz CLAUDE.md) -
## dokud hráč chodil, k jejich vlastní rychlosti se přičítal i posun kamery,
## po zastavení hráče najednou ne. Kamera teď hráče plynule "dohání" (lerp),
## takže se dobrzďuje postupně a tenhle skok mizí.
##
## Osa Y se NEDOBRZĎUJE (sleduje hráče okamžitě) - drop-in animace a její
## efekty (otřes, squash) počítají s tím, že kamera je přesně na hráčově Y.

## Kolik px od levého okraje obrazovky má hráč zůstat
@export var camera_left_margin: float = 220.0
## Jak rychle kamera dohání hráče na ose X (vyšší = svižnější, méně setrvačnosti)
@export var follow_speed: float = 5.0

var _target: Node2D = null
var _x_offset: float = 0.0


func _ready() -> void:
	_recalculate_offset()
	get_viewport().size_changed.connect(_recalculate_offset)


func _recalculate_offset() -> void:
	var viewport_width: float = get_viewport().get_visible_rect().size.x
	_x_offset = (viewport_width / 2.0) - camera_left_margin
	if _target != null:
		global_position.x = _target.global_position.x + _x_offset


## Zavolá main.gd po vytvoření hráče. Kamera se hned napozicuje přesně (bez
## plynutí) - jinak by na startu bylo vidět, jak kamera "přiletí" odjinud.
func set_target(target: Node2D) -> void:
	_target = target
	global_position = Vector2(_target.global_position.x + _x_offset, _target.global_position.y)


func _process(delta: float) -> void:
	if _target == null:
		return

	var desired_x: float = _target.global_position.x + _x_offset
	var weight: float = 1.0 - exp(-follow_speed * delta)
	global_position.x = lerp(global_position.x, desired_x, weight)
	global_position.y = _target.global_position.y


## Krátký otřes kamery - volá se přes signál player.landed (viz main.gd),
## hráč sám o kameře nic neví a jen oznámí, že dopadl.
func shake(strength: float = 10.0, duration: float = 0.22) -> void:
	var steps := 6
	var shake_tween := create_tween()
	for i in range(steps):
		var shake_offset := Vector2(randf_range(-strength, strength), randf_range(-strength, strength))
		shake_tween.tween_property(self, "offset", shake_offset, duration / steps)
	shake_tween.tween_property(self, "offset", Vector2.ZERO, duration / steps)
