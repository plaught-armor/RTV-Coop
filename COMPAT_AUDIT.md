# Mod Compatibility Audit — `take_over_path` surface

Goal: shrink `take_over_path` patches so other mods can coexist on the same
scripts. Other mods patching any row below will conflict and last-loaded wins.

Last updated: 2026-04-24

## Classification

| Class        | Meaning                                                                               |
|--------------|---------------------------------------------------------------------------------------|
| **ESSENTIAL** | Overrides per-frame logic, host-auth physics, or a dispatch choke-point. Must stay.  |
| **HOOKABLE**  | Thin `super` wrap around a method that could be intercepted via signal/group + autoload. |
| **INJECTABLE**| Adds RPC/validation/RNG-seed/flag on a non-signal method. Replaceable by autoload + scene-scan. |
| **COLLATERAL** | Workaround for take_over_path side-effects on another patched script. Cannot drop until upstream patch drops. |

## Current state (23 patches)

| Patch                 | Class        | Why                                                                         | Migration notes                                              |
|-----------------------|--------------|-----------------------------------------------------------------------------|--------------------------------------------------------------|
| ai                    | ESSENTIAL    | `_physics_process` multi-player targeting + LOS + puppet mode               | —                                                            |
| ai_spawner            | ESSENTIAL    | Host sync_id pool tracking, deterministic indexing, host-only spawn gate    | —                                                            |
| btr                   | ESSENTIAL    | Host-auth physics; client freeze + lerp snapshot via vehicle_state          | —                                                            |
| casa                  | ESSENTIAL    | Host `_physics_process` + airdrop edge broadcast; client parachute cosmetic | —                                                            |
| controller            | ESSENTIAL    | Wraps Movement/Inertia/SurfaceDetection/_input + vitals broadcast           | Audio-pool methods could split to child node                 |
| event_system          | ESSENTIAL    | Host-only RNG + client RPC replay (desync prevention)                       | —                                                            |
| helicopter            | ESSENTIAL    | Host-auth physics; client lerp snapshot                                     | —                                                            |
| interactor            | ESSENTIAL    | Dispatch choke-point: intercepts every Interactable Interact                | —                                                            |
| loot_simulation       | ESSENTIAL    | Suppresses client loot gen; headless handoff                                | Scene-scan + role check might replace                        |
| missile_spawner       | ESSENTIAL    | Host launches; clients spawn identical pool via prepare/launch RPC          | —                                                            |
| police                | ESSENTIAL    | Host-auth physics; client freeze + lerp snapshot                            | —                                                            |
| rocket_grad           | ESSENTIAL    | Host physics; client lerp snapshot                                          | —                                                            |
| rocket_helicopter     | ESSENTIAL    | Host physics + collision + explosion broadcast                              | —                                                            |
| character             | HOOKABLE     | Wraps Stamina/Energy/Hydration/Temperature for session multipliers          | No signals; multipliers could route via gameData fields      |
| furniture             | HOOKABLE     | Broadcasts StartMove/ResetMove/Catalog                                      | No signals; group-scan + post-frame poll on isMoving         |
| knife_rig             | HOOKABLE     | Slash/stab/hit RPC broadcasts                                               | No signals; raycast events can't be polled — keep            |
| mine                  | ESSENTIAL    | Host-auth Detonate/InstantDetonate suppress local exec on client             | Detector.gd triggers on each client → polling can broadcast but can't suppress pre-fire local detonation. Requires intercept-before-execute. Keep. (Spawn-side desync solved separately by `mine_spawner_hook.gd` — host generates Mines, broadcasts layout, client suppresses Spawner via `data=null` before _ready.) |
| explosion             | INJECTABLE   | Co-op layer mask + LOS remote damage                                        | Scene-scan, set layer; LOS remote needs Explode override     |
| fish_pool             | INJECTABLE   | Throttled `_physics_process` by nearest-player distance                     | Autoload polls group, calls set_physics_process(false)       |
| grenade_rig           | INJECTABLE   | Captures throw, broadcasts RPC                                              | Hook ThrowHigh/LowExecute via group + post-call poll         |
| interface             | INJECTABLE   | Reimplements Drop/CompleteDeal with RPC                                     | Trade flow needs deep re-routing; Drop hookable              |
| loader                | INJECTABLE   | Adds savePath/playerSavePath + mirror logic + new save fields               | Save-fields drift; coop save layout diverges from vanilla    |
| decor_mode            | COLLATERAL   | Vanilla `child is Furniture` false-positives post-Furniture.gd take_over_path → crash on `.indicator` access. Triggered in coop because shelter auto-loads. | Drops only when furniture_patch drops. NOT a vanilla bug.    |

## Totals

- ESSENTIAL: 14
- HOOKABLE: 3
- INJECTABLE: 5
- COLLATERAL: 1 (decor_mode — chained to furniture_patch)
- **Reachable target:** 14 `take_over_path` (39% reduction from current 23). decor_mode drops automatically when furniture_patch drops.

## Progress since v0.2.0 baseline

v0.2.0 audit had 34 patches. **Migrated since then (11):**
cat_feeder, cat_rescue, trader, instrument, layouts, pickup, radio, simulation,
television, settings, transition.

Net: 34 → 23 (32% reduction). 10 more migrations needed to hit floor of 13.

`transition` removed by inlining saveMirror tail into interactor_patch's
Transition branch (2026-04-24).

## Migration priorities

### Quick wins (low risk)

(none remaining — transition migrated 2026-04-24; decor_mode is COLLATERAL,
chained to furniture_patch.)

### Medium risk

2. **`fish_pool`** — `set_physics_process(false)` toggle from autoload
   polling distance. Patch is single throttle, easy lift.

(`mine` reclassified ESSENTIAL on investigation: client-side Detector triggers
local Detonate before any poll could suppress it. Polling cannot replace
intercept-before-execute pattern.)

### Deep / risky

4. **`character`** — vitals multipliers can route via `gameData` field
   writes if base reads them. Need to verify base Character.gd reads
   gameData multipliers vs. baked constants.

5. **`grenade_rig`** — post-Throw broadcast needs grenade scene + transform.
   State observable post-call (look for new RigidBody3D in scene). Polling
   feasible.

6. **`furniture`** — three methods, no signals. Polling `isMoving` flag +
   `Catalog` queue_free detection. Two state edges to broadcast per piece.

7. **`explosion`** — co-op LOS check on remotes requires Explode override.
   Hard to migrate without behavioral change.

8. **`interface`** — trade flow rewrite blocks migration. Drop side easier.

9. **`loader`** — fundamental save layout change. Cannot migrate without
   accepting save-state drift between coop and vanilla.

## Risks

- Polling-based replication has frame latency (1-tick).
- `queue_free()`-detection misses object identity post-free.
- Base game updates that change method signatures break polling the same way
  they break `take_over_path`. Polling fails silently; patches fail loud.
- Private (`_`-prefixed) methods cannot be hooked externally regardless.

## Verification

After each migration:
- `godot proj:errors` clean.
- Run scenarios from `.wolf/known_bugs.md` test plan.
- MP smoke: host + 1 client, one scenario per migrated patch.
- Diff `modloader_conflicts.txt` — total conflict count drops by 1.
