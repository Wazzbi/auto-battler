extends Node2D
## Procedurálně vykreslená dvoubarevná ("šachovnicová") podlaha.
## Účel je čistě vizuální - díky opakujícím se dlaždicím je na první
## pohled vidět, že se hráč/kamera skutečně posouvá levelem, i když
## postava samotná zůstává na stejném místě obrazovky.
##
## Level je teď bezkonečný (viz CLAUDE.md - hráč po dokončení kola pokračuje
## dál, nevrací se na start), takže podlaha se nekreslí do pevné šířky, ale
## znovu každý snímek jen pro aktuálně viditelný úsek podle pozice kamery -
## dlaždice se barví podle absolutního indexu (`posmod(i, 2)`), takže vzor
## zůstává stabilní bez ohledu na to, který úsek se zrovna kreslí.

@export var tile_size: float = 150.0
@export var height: float = 100.0
@export var color_a: Color = Color(0.36, 0.24, 0.14, 1.0)
@export var color_b: Color = Color(0.46, 0.32, 0.18, 1.0)
## Tenký zvýrazněný pruh navrchu podlahy (jako "tráva"/okraj)
@export var top_stripe_height: float = 10.0
@export var top_stripe_color: Color = Color(0.32, 0.55, 0.22, 1.0)
## Kolik dlaždic navíc vykreslit za oba okraje viditelné oblasti - rezerva
## proti mezeře při rychlém pohybu kamery/doskakování position smoothingu
@export var tile_margin_count: int = 2


func _process(_delta: float) -> void:
	# Prostá varianta "sleduj kameru" - při téhle velikosti scény (pár desítek
	# obdélníků na snímek) je přepočet a redraw každý snímek zanedbatelný.
	queue_redraw()


func _draw() -> void:
	var view_left: float
	var view_right: float
	var camera := get_viewport().get_camera_2d()
	if camera != null:
		# get_screen_center_position() - NE global_position - protože Camera2D
		# má zapnutý position_smoothing; při skokové změně pozice (typicky jen
		# v editoru/testech, hráč se běžně pohybuje plynule) by global_position
		# běžela napřed před tím, co se skutečně vykresluje na obrazovce, a
		# dlaždice by se počítaly pro úsek, který kamera ještě vůbec nezabírá.
		var half_width: float = get_viewport().get_visible_rect().size.x / 2.0
		var center_x: float = camera.get_screen_center_position().x
		view_left = center_x - half_width
		view_right = center_x + half_width
	else:
		view_left = 0.0
		view_right = get_viewport().get_visible_rect().size.x

	# Ground má vlastní offset (viz level_01.tscn) - _draw() kreslí v lokálních
	# souřadnicích, takže viditelný rozsah musíme převést z world-space.
	var local_left: float = view_left - global_position.x
	var local_right: float = view_right - global_position.x

	var first_tile: int = int(floor(local_left / tile_size)) - tile_margin_count
	var last_tile: int = int(ceil(local_right / tile_size)) + tile_margin_count

	for i in range(first_tile, last_tile + 1):
		var x: float = i * tile_size
		var color: Color = color_a if posmod(i, 2) == 0 else color_b
		draw_rect(Rect2(x, 0.0, tile_size, height), color)

	if top_stripe_height > 0.0:
		var stripe_left: float = first_tile * tile_size
		var stripe_width: float = (last_tile - first_tile + 1) * tile_size
		draw_rect(Rect2(stripe_left, 0.0, stripe_width, top_stripe_height), top_stripe_color)
