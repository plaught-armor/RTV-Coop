## Patch for Character.gd — scales vitals ticks by host session settings:
## stamina_regen_multiplier, stamina_drain_multiplier, temperature_loss_multiplier, vitals_decay_multiplier.
## Each override reimplements the base rate math since base uses fixed divisors.
extends "res://Scripts/Character.gd"


func Stamina(delta: float) -> void:
    var drain: float = CoopManager.settings.get("stamina_drain_multiplier", 1.0)
    var regen: float = CoopManager.settings.get("stamina_regen_multiplier", 1.0)

    if gameData.bodyStamina > 0 && (gameData.isRunning || gameData.overweight || (gameData.isSwimming && gameData.isMoving)):
        if gameData.overweight || gameData.starvation || gameData.dehydration:
            gameData.bodyStamina -= delta * 4.0 * drain
        else:
            gameData.bodyStamina -= delta * 2.0 * drain
    elif gameData.bodyStamina < 100:
        if gameData.starvation || gameData.dehydration:
            gameData.bodyStamina += delta * 5.0 * regen
        else:
            gameData.bodyStamina += delta * 10.0 * regen

    if gameData.armStamina > 0 && ((gameData.primary || gameData.secondary) && (gameData.weaponPosition == 2 || gameData.isAiming || gameData.isCanted || gameData.isInspecting || gameData.overweight) || (gameData.isSwimming && gameData.isMoving)):
        if gameData.overweight || gameData.starvation || gameData.dehydration:
            gameData.armStamina -= delta * 4.0 * drain
        else:
            gameData.armStamina -= delta * 2.0 * drain
    elif gameData.armStamina < 100:
        if gameData.starvation || gameData.dehydration:
            gameData.armStamina += delta * 10.0 * regen
        else:
            gameData.armStamina += delta * 20.0 * regen


func Energy(delta: float) -> void:
    var decay: float = CoopManager.settings.get("vitals_decay_multiplier", 1.0)
    if !gameData.starvation:
        gameData.energy -= (delta / 30.0) * decay
    if gameData.energy <= 0 && !gameData.starvation:
        Starvation(true)
    elif gameData.energy > 0 && gameData.starvation:
        Starvation(false)


func Hydration(delta: float) -> void:
    var decay: float = CoopManager.settings.get("vitals_decay_multiplier", 1.0)
    if !gameData.dehydration:
        gameData.hydration -= (delta / 22.0) * decay
    if gameData.hydration <= 0 && !gameData.dehydration:
        Dehydration(true)
    elif gameData.hydration > 0 && gameData.dehydration:
        Dehydration(false)


func Temperature(delta: float) -> void:
    var tempMul: float = CoopManager.settings.get("temperature_loss_multiplier", 1.0)

    if gameData.season == 1 || gameData.shelter || gameData.tutorial || gameData.heat:
        gameData.temperature += delta
    elif gameData.season == 2:
        if !gameData.frostbite:
            if gameData.isSubmerged:
                gameData.temperature -= (delta * 8.0) * insulation * tempMul
            elif gameData.isWater:
                gameData.temperature -= (delta * 4.0) * insulation * tempMul
            elif gameData.indoor:
                gameData.temperature -= (delta / 10.0) * insulation * tempMul
            else:
                gameData.temperature -= (delta / 5.0) * insulation * tempMul

    if gameData.temperature <= 0 && !gameData.frostbite:
        Frostbite(true)
    elif gameData.temperature > 0 && gameData.frostbite:
        Frostbite(false)
