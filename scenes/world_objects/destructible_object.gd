extends Node2D
## Zničitelný statický objekt (hnědý placeholder, viz "Statické objekty ve
## světě" v CLAUDE.md, 2026-09-28) - žádný pohyb, žádný útok, jen HP a
## zásahový poloměr. Přidává se do DVOU skupin: "obstacles" (nepřátelé se mu
## vyhýbají, viz enemy.gd's _avoid_obstacles()) a "destructibles" (hráč na něj
## cílí přes player.gd's _find_nearest_targets() - sdílí `take_damage()`/
## `hit_radius` rozhraní s enemy.gd, takže projectile.gd ho zasáhne beze
## změny). Placeholder pro smysluplnější objekty v budoucnu (zdroje,
## dekorace...) - zatím čistě procedurální barevný čtverec, žádný image asset,
## stejná filozofie jako zbytek projektu.

@export var max_hp: float = 15.0
## Jak blízko svého STŘEDU musí projektil dolétnout, aby se počítal zásah -
## stejná konvence jako enemy.gd's hit_radius (odpovídá vizuálu + malá
## rezerva).
@export var hit_radius: float = 26.0
## Jak blízko musí být nepřítel, než ho tenhle objekt začne odpuzovat - viz
## enemy.gd's _avoid_obstacles(). Nezávislé na hit_radius (to je pro
## projektily hráče, tohle je pro pohyb nepřátel).
@export var avoid_radius: float = 50.0
## Polovina strany ČTVERCOVÉ kolizní oblasti, kterou hráč fyzicky nemůže
## vejít (viz player.gd's _resolve_obstacle_collisions(), 2026-09-28 -
## "aby hráč nemohl těmito statickými předměty procházet", pak téhož dne
## upřesněno na "vlastní tvar čtverce" místo kruhu). Odpovídá PŘESNĚ
## polovině šířky vizuálu (Polygon2D's ±22 rohy níže), na rozdíl od
## hit_radius/avoid_radius (ty mají malou rezervu navíc pro svůj účel) -
## kolize s hráčem má sedět přesně na to, co je vidět.
@export var collision_half_size: float = 22.0
## Odměna za zničení - výchozí 0 (zatím čistý mechanismus, žádná odměna).
## Snadné později zapojit bez další úpravy _die().
@export var reward: int = 0
@export var scrap_reward: int = 0

var hp: float
## Stejná pojistka proti dvojitému započítání smrti jako enemy.gd's _is_dead -
## queue_free() odstraní uzel ze stromu až na konci snímku, takže dva
## projektily (typicky multishot) trefené ve stejném snímku by bez tohohle
## flagu zavolaly _die() dvakrát.
var _is_dead: bool = false


func _ready() -> void:
	add_to_group("obstacles")
	add_to_group("destructibles")
	hp = max_hp


func take_damage(amount: float) -> void:
	if _is_dead:
		return
	hp -= amount
	if hp <= 0:
		_die()


func _die() -> void:
	if _is_dead:
		return
	_is_dead = true
	if reward > 0 or scrap_reward > 0:
		GameManager.currency += reward
		GameManager.currency_changed.emit(GameManager.currency)
		GameManager.scrap += scrap_reward
		GameManager.scrap_changed.emit(GameManager.scrap)
	queue_free()
