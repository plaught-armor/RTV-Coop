## Hook callbacks for Character.gd — scales vitals ticks by host session settings.
## Replaces patches/character_patch.gd. Requires vostok-mod-loader (RTVModLib API).
## Each replace fully reimplements the vital math (vanilla used fixed divisors).
extends RefCounted


var _lib: Object = null
var _logged: bool = false


func register(lib: Object) -> void:
    _lib = lib
    lib.hook("character-stamina", _on_stamina)
    lib.hook("character-energy", _on_energy)
    lib.hook("character-hydration", _on_hydration)
    lib.hook("character-temperature", _on_temperature)


func _maybe_log() -> void:
    if _logged:
        return
    _logged = true
    if !is_instance_valid(CoopManager):
        return
    CoopManager._log("[character_hooks] multipliers regen=%.2f drain=%.2f temp=%.2f decay=%.2f" % [
        CoopManager.settings.get("stamina_regen_multiplier", 1.0),
        CoopManager.settings.get("stamina_drain_multiplier", 1.0),
        CoopManager.settings.get("temperature_loss_multiplier", 1.0),
        CoopManager.settings.get("vitals_decay_multiplier", 1.0),
    ])


func _on_stamina(delta: float) -> void:
    _maybe_log()
    _lib.skip_super()
    var ch: Node3D = _lib._caller as Node3D
    if ch == null:
        return
    var gd: Resource = ch.gameData
    var drain: float = CoopManager.settings.get("stamina_drain_multiplier", 1.0)
    var regen: float = CoopManager.settings.get("stamina_regen_multiplier", 1.0)

    if gd.bodyStamina > 0 && (gd.isRunning || gd.overweight || (gd.isSwimming && gd.isMoving)):
        if gd.overweight || gd.starvation || gd.dehydration:
            gd.bodyStamina -= delta * 4.0 * drain
        else:
            gd.bodyStamina -= delta * 2.0 * drain
    elif gd.bodyStamina < 100:
        if gd.starvation || gd.dehydration:
            gd.bodyStamina += delta * 5.0 * regen
        else:
            gd.bodyStamina += delta * 10.0 * regen

    if gd.armStamina > 0 && ((gd.primary || gd.secondary) && (gd.weaponPosition == 2 || gd.isAiming || gd.isCanted || gd.isInspecting || gd.overweight) || (gd.isSwimming && gd.isMoving)):
        if gd.overweight || gd.starvation || gd.dehydration:
            gd.armStamina -= delta * 4.0 * drain
        else:
            gd.armStamina -= delta * 2.0 * drain
    elif gd.armStamina < 100:
        if gd.starvation || gd.dehydration:
            gd.armStamina += delta * 10.0 * regen
        else:
            gd.armStamina += delta * 20.0 * regen


func _on_energy(delta: float) -> void:
    _lib.skip_super()
    var ch: Node3D = _lib._caller as Node3D
    if ch == null:
        return
    var gd: Resource = ch.gameData
    var decay: float = CoopManager.settings.get("vitals_decay_multiplier", 1.0)
    if !gd.starvation:
        gd.energy -= (delta / 30.0) * decay
    if gd.energy <= 0 && !gd.starvation:
        ch.Starvation(true)
    elif gd.energy > 0 && gd.starvation:
        ch.Starvation(false)


func _on_hydration(delta: float) -> void:
    _lib.skip_super()
    var ch: Node3D = _lib._caller as Node3D
    if ch == null:
        return
    var gd: Resource = ch.gameData
    var decay: float = CoopManager.settings.get("vitals_decay_multiplier", 1.0)
    if !gd.dehydration:
        gd.hydration -= (delta / 22.0) * decay
    if gd.hydration <= 0 && !gd.dehydration:
        ch.Dehydration(true)
    elif gd.hydration > 0 && gd.dehydration:
        ch.Dehydration(false)


func _on_temperature(delta: float) -> void:
    _lib.skip_super()
    var ch: Node3D = _lib._caller as Node3D
    if ch == null:
        return
    var gd: Resource = ch.gameData
    var tempMul: float = CoopManager.settings.get("temperature_loss_multiplier", 1.0)
    var insulation: float = ch.insulation

    if gd.season == 1 || gd.shelter || gd.tutorial || gd.heat:
        gd.temperature += delta
    elif gd.season == 2:
        if !gd.frostbite:
            if gd.isSubmerged:
                gd.temperature -= (delta * 8.0) * insulation * tempMul
            elif gd.isWater:
                gd.temperature -= (delta * 4.0) * insulation * tempMul
            elif gd.indoor:
                gd.temperature -= (delta / 10.0) * insulation * tempMul
            else:
                gd.temperature -= (delta / 5.0) * insulation * tempMul

    if gd.temperature <= 0 && !gd.frostbite:
        ch.Frostbite(true)
    elif gd.temperature > 0 && gd.frostbite:
        ch.Frostbite(false)
