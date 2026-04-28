## Hook callbacks for Trader.gd — host-authoritative supply rolls.
## Replaces patches/trader_patch.gd. Requires vostok-mod-loader (RTVModLib API).
extends RefCounted


var _lib: Object = null


func register(lib: Object) -> void:
    _lib = lib
    lib.hook("trader-createsupply", _on_create_supply)
    lib.hook("trader-createsupply-post", _on_create_supply_post)


func _on_create_supply() -> void:
    if CoopManager == null || !CoopManager.is_session_active():
        return  # vanilla runs
    if !CoopManager.isHost:
        _lib.skip_super()  # client: no vanilla, no filter; supply set later via RPC
        return
    # Host: vanilla runs after this returns, then post hook handles filter + broadcast.


func _on_create_supply_post() -> void:
    var t: Trader = _lib._caller as Trader
    if t == null:
        return
    if CoopManager == null:
        _filter_supply(t)
        return
    if !CoopManager.is_session_active():
        _filter_supply(t)
        return
    if !CoopManager.isHost:
        return
    _filter_supply(t)
    var scene: Node = t.get_tree().current_scene
    if !is_instance_valid(scene):
        return
    var traderPath: String = scene.get_path_to(t)
    var packedSupply: Array[Dictionary] = CoopManager.slotSerializer.pack_array(t.supply)
    CoopManager.worldState.sync_trader_supply_update.rpc(traderPath, packedSupply)


func _filter_supply(t: Trader) -> void:
    var filtered: Array[SlotData] = []
    for slot: SlotData in t.supply:
        if slot == null:
            continue
        if slot.itemData == null:
            continue
        var fileVar: Variant = slot.itemData.get(&"file")
        if !(fileVar is String) || (fileVar as String).is_empty():
            continue
        filtered.append(slot)
    t.supply = filtered
