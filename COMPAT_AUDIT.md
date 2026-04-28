# Mod Compatibility Audit — vostok-mod-loader hooks + take_over_path skip-list

**Last updated:** 2026-04-28 (post Apr-26 hook migration)

Goal: minimize permanent script-replacement surface so other mods coexist on the same Road to Vostok scripts.

## Patch surface summary

| Surface | Count | Conflict risk |
|---|---|---|
| **vostok-mod-loader hooks** (`mod/hooks/`) | 21 modules, 97 hook callbacks | Low — multiple mods can hook the same method (RTVModLib stacks pre/post; replace is single-owner) |
| **`take_over_path` patches** (`mod/patches/`) | 2 (Mine, Explosion) | High — last-loaded wins (Godot #83542) |
| **Total scripts intercepted** | 23 | — |

## What changed (Apr 26-28)

- Migrated 22 `take_over_path` patches → vostok-mod-loader hook callbacks via `Engine.get_meta("RTVModLib")`.
- Hook semantics: `name-pre` (before vanilla), `name-post` (after vanilla), `name` (replace, vanilla still runs unless `_lib.skip_super()` called).
- Skip-list (forever on `take_over_path`): `Mine.gd`, `Explosion.gd` — vostok rewriter cannot rewrite these per RTV_SKIP_LIST.
- Apr 28: Hook target verification confirmed all 97 hooks resolve to vanilla methods. Dropped 1 dead hook (`controller-resolvefootstep` — vanilla had no such method).

## Hook modules (21)

| Module | Vanilla script | Coverage |
|---|---|---|
| `ai_hooks` | AI.gd | 17 hooks — multi-player targeting, host-auth logic, remote damage routing, puppet rig |
| `ai_spawner_hooks` | AISpawner.gd | 10 hooks — host-auth spawning, deterministic sync IDs |
| `btr_hooks` | BTR.gd | 2 hooks — host physics, client freeze + lerp |
| `casa_hooks` | CASA.gd | 3 hooks — airdrop plane host-auth, client cosmetic |
| `character_hooks` | Character.gd | 4 hooks — vitals (energy/hydration/stamina/temperature) scaled by host session settings |
| `controller_hooks` | Controller.gd | 10 hooks — input + movement + footsteps + audio pool |
| `event_system_hooks` | EventSystem.gd | 6 hooks — host-auth event rolls, client RPC replay |
| `fish_pool_hooks` | FishPool.gd | 2 hooks — path-seeded RNG, all-peer distance check |
| `furniture_hooks` | Furniture.gd | 4 hooks — placement + pickup sync |
| `grenade_rig_hooks` | GrenadeRig.gd | 4 hooks — throw broadcast |
| `helicopter_hooks` | Helicopter.gd | 2 hooks — host physics, FireRockets |
| `interactor_hooks` | Interactor.gd | 1 hook — coop dispatch choke-point |
| `interface_hooks` | Interface.gd | 5 hooks — drop/trade/task broadcasts |
| `knife_rig_hooks` | KnifeRig.gd | 3 hooks — slash/stab audio + hit decals |
| `loader_hooks` | Loader.gd | 16 hooks — per-world savePath/playerSavePath |
| `loot_simulation_hooks` | LootSimulation.gd | 2 hooks — host-auth loot gen |
| `missile_spawner_hooks` | MissileSpawner.gd | 1 hook — host launch + client mirror |
| `police_hooks` | Police.gd | 2 hooks — host physics |
| `rocket_grad_hooks` | RocketGrad.gd | 1 hook — host physics |
| `rocket_helicopter_hooks` | RocketHelicopter.gd | 1 hook — host physics + collision |
| `trader_hooks` | Trader.gd | 2 hooks — host-auth supply rolls |

## take_over_path skip-list (2)

| Script | Why on skip-list | Class |
|---|---|---|
| `Mine.gd` | RTV_SKIP_LIST in vostok rewriter — host-auth detonation requires structural override | ESSENTIAL |
| `Explosion.gd` | RTV_SKIP_LIST — co-op splash damage host-auth + remote player detection | ESSENTIAL |

## Compatibility guidance

- **Other mods using vostok-mod-loader hooks** can hook the same scripts as RTV-Coop without conflict; vostok stacks pre+post callbacks. `replace` is single-owner — second registration returns -1.
- **Other mods using `take_over_path`** on `Mine.gd` or `Explosion.gd` will conflict (last-loaded wins per Godot #83542). Recommend those mods migrate to vostok-mod-loader hooks if their scripts allow it.
- **Class-name corruption** post-`take_over_path` affects `is X` checks on Mine/Explosion-related types. Use duck-typed `node.get(&"propertyName")` instead.

## Open work (deferred — needs 2-peer Steam test per H15 RPC checksum risk)

| Item | Type | Plan |
|---|---|---|
| Trader shelf sync | Hook-only (no new RPC scripts) | Host snapshots `trader.supply` post-roll → `world_state.broadcast_trader_supply` RPC (new entry on existing script) → clients apply. See `auto-memory: project_trader_shelf_sync.md`. |
| FPS arm anim sync | Hook-only | Hook `tree.animation_started` → broadcast `playback.get_current_node()` state name → remote `tree.travel(stateName)`. See `auto-memory: project_fps_arm_anim_sync.md`. |
| RPC-script file splits | Refactor | `world_state.gd` 1509 lines / 63 RPCs, `coop_manager.gd` 1579, `ai_state.gd` 1039 — split by domain post-test verification. |

## Audit history

- **2026-04-12 → 2026-04-24:** 24 `take_over_path` patches; per-patch classification (ESSENTIAL/HOOKABLE/INJECTABLE/COLLATERAL).
- **2026-04-26:** Adopted vostok-mod-loader; migrated 22 patches → hooks (knife_rig pilot first, then by domain: combat → world → AI → loot → loader).
- **2026-04-27:** Type-safety phase B+C — typed `_lib._caller as <Class>` casts across all 21 hooks.
- **2026-04-28:** Hook target verification + dead-hook drop (`controller-resolvefootstep`); compat audit rewrite.
