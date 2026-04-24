## Applies RPC-received state mutations to GameData. Keeps network layer pure
## transport; state writes funnel through this helper for single-entry auditing.
extends RefCounted


var _cm: Node
var _gd: GameData = preload("res://Resources/GameData.tres")


func init_manager(manager: Node) -> void:
    _cm = manager


func apply_sleep_start() -> void:
    _gd.isSleeping = true
    _gd.freeze = true


func apply_sleep_end() -> void:
    _gd.energy -= 20.0
    _gd.hydration -= 20.0
    _gd.mental += 20.0
    _gd.isSleeping = false
    _gd.freeze = false


# Monotonic: catFound/catDead only transition to true. Hydration clamped.
# Returns whether caller should rebroadcast (host-side validation path).
func apply_cat_state_host(catFound: bool, catDead: bool, catHydration: float) -> bool:
    if _gd.catDead:
        return false
    if catFound:
        _gd.catFound = true
    if catDead:
        _gd.catDead = true
    var clamped: float = clampf(catHydration, 0.0, 100.0)
    _gd.cat = minf(_gd.cat, clamped) if _gd.catFound else clamped
    return true


func apply_cat_state_client(catFound: bool, catDead: bool, catHydration: float) -> void:
    if catFound:
        _gd.catFound = true
    if catDead:
        _gd.catDead = true
    _gd.cat = catHydration
