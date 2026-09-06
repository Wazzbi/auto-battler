extends Node2D
## Procedurálně vykreslená dvoubarevná ("šachovnicová") podlaha.
## Účel je čistě vizuální - díky opakujícím se dlaždicím je na první
## pohled vidět, že se hráč/kamera skutečně posouvá levelem, i když
## postava samotná zůstává na stejném místě obrazovky.

@export var tile_size: float = 150.0
@export var height: float = 100.0
@export var total_width: float = 6480.0
@export var color_a: Color = Color(0.36, 0.24, 0.14, 1.0)
@export var color_b: Color = Color(0.46, 0.32, 0.18, 1.0)
## Tenký zvýrazněný pruh navrchu podlahy (jako "tráva"/okraj)
@export var top_stripe_height: float = 10.0
@export var top_stripe_color: Color = Color(0.32, 0.55, 0.22, 1.0)


func _draw() -> void:
	var tile_count: int = int(ceil(total_width / tile_size))
	for i in range(tile_count):
		var x: float = i * tile_size
		var color: Color = color_a if i % 2 == 0 else color_b
		draw_rect(Rect2(x, 0.0, tile_size, height), color)

	if top_stripe_height > 0.0:
		draw_rect(Rect2(0.0, 0.0, total_width, top_stripe_height), top_stripe_color)
