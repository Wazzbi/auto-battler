extends Node2D
## Procedurálně vykreslená dvoubarevná ("šachovnicová") podlaha - top-down
## pivot 2026-09-27, Fáze 5: teď PLNĚ 2D mřížka dlaždic (dřív jen 1D
## vodorovný pruh s pevnou výškou "podlahového pásu", protože hra byla
## plošinovka a nad/pod pásem nebylo nic k vykreslení). Účel je čistě
## vizuální - díky opakujícím se dlaždicím je na první pohled vidět, že se
## hráč/kamera skutečně posouvá, i když postava samotná zůstává na stejném
## místě obrazovky.
##
## Level je bezkonečný ve VŠECH směrech (hráč se může volně pohybovat, viz
## player.gd), takže podlaha se nekreslí do pevné velikosti, ale znovu každý
## snímek jen pro aktuálně viditelný obdélník podle pozice kamery - dlaždice
## se barví podle SOUČTU absolutních indexů (`posmod(x_i + y_i, 2)`), takže
## šachovnicový vzor zůstává stabilní a nekmitá bez ohledu na to, kterým
## směrem se zrovna kamera posouvá.

@export var tile_size: float = 150.0
@export var color_a: Color = Color(0.36, 0.24, 0.14, 1.0)
@export var color_b: Color = Color(0.46, 0.32, 0.18, 1.0)
## Kolik dlaždic navíc vykreslit za okraje viditelné oblasti (na všech 4
## stranách) - rezerva proti mezeře při rychlém pohybu kamery/doskakování
## position smoothingu
@export var tile_margin_count: int = 2


func _process(_delta: float) -> void:
	# Prostá varianta "sleduj kameru" - při téhle velikosti scény (pár desítek
	# obdélníků na snímek) je přepočet a redraw každý snímek zanedbatelný.
	queue_redraw()


## Spočítá viditelný rozsah dlaždic (min/max index na obou osách) podle
## aktuální kamery, v LOKÁLNÍCH souřadnicích dlaždic (Ground má vlastní
## world-space offset, viz level_01.tscn). Vytažené jako samostatná funkce
## z _draw() konkrétně proto, aby šla otestovat headless - _draw() sám o
## sobě nevrací nic ověřitelného.
func _get_visible_tile_range() -> Dictionary:
	var view_center: Vector2
	var camera := get_viewport().get_camera_2d()
	if camera != null:
		# get_screen_center_position() - NE global_position - protože Camera2D
		# má zapnutý position_smoothing; při skokové změně pozice (typicky jen
		# v editoru/testech, hráč se běžně pohybuje plynule) by global_position
		# běžela napřed před tím, co se skutečně vykresluje na obrazovce, a
		# dlaždice by se počítaly pro úsek, který kamera ještě vůbec nezabírá.
		view_center = camera.get_screen_center_position()
	else:
		view_center = get_viewport().get_visible_rect().size / 2.0

	var half_size: Vector2 = get_viewport().get_visible_rect().size / 2.0
	var local_center: Vector2 = view_center - global_position

	var first_x: int = int(floor((local_center.x - half_size.x) / tile_size)) - tile_margin_count
	var last_x: int = int(ceil((local_center.x + half_size.x) / tile_size)) + tile_margin_count
	var first_y: int = int(floor((local_center.y - half_size.y) / tile_size)) - tile_margin_count
	var last_y: int = int(ceil((local_center.y + half_size.y) / tile_size)) + tile_margin_count

	return {"first_x": first_x, "last_x": last_x, "first_y": first_y, "last_y": last_y}


func _draw() -> void:
	var tile_range: Dictionary = _get_visible_tile_range()

	for x_i in range(tile_range["first_x"], tile_range["last_x"] + 1):
		for y_i in range(tile_range["first_y"], tile_range["last_y"] + 1):
			var color: Color = color_a if posmod(x_i + y_i, 2) == 0 else color_b
			draw_rect(Rect2(x_i * tile_size, y_i * tile_size, tile_size, tile_size), color)
