# Mod Compatibility Audit — take_over_path surface reduction

Goal: reduce 24 `take_over_path` patches so other mods can coexist.
Other mods taking the same script = conflict.

## Classification

- **ESSENTIAL** — overrides per-frame logic, must stay take_over.
- **HOOKABLE** — pure signal wrap, replaceable with autoload + signal connect.
- **INJECTABLE** — adds RPC calls, collision flags, or RNG seeds; replaceable with autoload scan + monkey-patch on scene_changed.
- **DECORATOR** — UI restructure, pure listener.

## Results

| Patch            | Class      | Why                                                                | Alternative                                              |
|------------------|------------|--------------------------------------------------------------------|----------------------------------------------------------|
| ai               | ESSENTIAL  | _physics_process multi-player targeting + raycast                  | —                                                        |
| ai_spawner       | ESSENTIAL  | Host sync_id pool tracking, deterministic indexing                 | —                                                        |
| event_system     | ESSENTIAL  | Host-only RNG + client RPC replay (desync prevention)              | —                                                        |
| controller       | ESSENTIAL  | Wraps Movement/Inertia/SurfaceDetection per-frame                  | Partial split possible (audio pool → OPTIONAL)           |
| bed              | HOOKABLE   | Blocks Interact, tooltip only                                      | Signal hook on sleep attempt                             |
| character        | HOOKABLE   | Broadcasts death via super                                         | Death signal → autoload relays RPC                       |
| door             | HOOKABLE   | Wraps Interact, state via super                                    | Group scan + intercept Interact signal                   |
| fire             | HOOKABLE   | Wraps Interact, broadcasts state                                   | Group Interact listener                                  |
| loot_container   | HOOKABLE   | Wraps Interact, serializes loot                                    | LootContainer group + patch Interact                     |
| mine             | HOOKABLE   | Wraps Detonate/InstantDetonate                                     | Connect Detonate signals, RPC relay                      |
| switch           | HOOKABLE   | Wraps Interact, RPC state                                          | Switch group + patch Interact                            |
| trader           | HOOKABLE   | Routes client Interact to host RPC                                 | Patch Interact via group scan                            |
| explosion        | INJECTABLE | Co-op layer mask + LOS remote damage                               | Scan on scene_changed, set layer, hook damage RPC        |
| fish_pool        | INJECTABLE | Seeded RNG + player scan (with remotes)                            | Autoload pre-seeds by path hash                          |
| furniture        | INJECTABLE | Broadcasts ResetMove/Catalog                                       | Connect ResetMove/Catalog signals                        |
| grenade_rig      | INJECTABLE | Captures throw, RPC broadcasts                                     | Hook ThrowHigh/LowExecute                                |
| interface        | INJECTABLE | Reimplements Drop/CompleteDeal with RPC                            | Intercept Drop signal, inject broadcasts                 |
| knife_rig        | INJECTABLE | Slash/stab/hit RPC broadcasts                                      | Connect audio/raycast signals                            |
| layouts          | INJECTABLE | Seeds RNG by node path for shared layout pick                      | Hash node path in _ready, pre-select child               |
| loader           | INJECTABLE | Adds savePath/playerSavePath + mirror logic                        | Autoload patches Loader fields, hooks Save calls         |
| loot_simulation  | INJECTABLE | Suppresses client gen, checks headless snapshot                    | Detect client role, skip _ready gen                      |
| pickup           | INJECTABLE | Wraps Interact, broadcasts sync_id                                 | Patch Interact for sync_id + broadcast                   |
| settings         | DECORATOR  | UI tab restructure, no state mutation                              | Standalone UI-only mod; could split                      |
| transition       | INJECTABLE | Routes client skip-save + user:// mirror                           | Detect client, skip save, hook Interact                  |

## Totals

- ESSENTIAL: 4 (ai, ai_spawner, event_system, controller)
- HOOKABLE: 7 (bed, character, door, fire, loot_container, mine, switch, trader)
- INJECTABLE: 12 (explosion, fish_pool, furniture, grenade_rig, interface, knife_rig, layouts, loader, loot_simulation, pickup, transition)
- DECORATOR: 1 (settings)

Target: **24 → 4** take_over_paths (83% reduction).

## Migration Strategy (Fri 2026-04-18)

### Phase 1 — Hookable (low risk)
Move 7 patches to `mod/hooks/` module. Pattern:
1. Autoload scans scene on `on_scene_changed` for target group.
2. For each match, connect to base-game signal (Interact, Detonate, etc.).
3. Handler broadcasts via existing RPC machinery.
4. No script replacement.

### Phase 2 — Injectable (medium risk)
For methods without signals, use `Callable` + monkey-patch:
1. On scene_changed, find target node.
2. Store original method ref.
3. Replace via `.call_deferred` or attach child helper that intercepts via physics_process.
For collision layer / RNG seed / save path: autoload writes directly on scene_changed.

### Phase 3 — Settings split
Extract settings_patch → standalone optional mod (separate vmz). User can disable without breaking coop.

### Risks
- Signals may not exist for every Interact target. Check base-game scripts for explicit `signal` decls.
- Private methods (leading `_`) cannot be hooked via signal. Those remain take_over.
- `super()` chain loss — RPC relay must fully reproduce base-game side effects.

### Verification
- Conflict summary: modloader_conflicts.txt should show `Conflicting resource paths: 0` unchanged.
- Run all test scenarios from known_bugs.md after each phase.
