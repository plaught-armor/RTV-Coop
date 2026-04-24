# Mod Compatibility Audit — `take_over_path` surface

Goal: shrink the 34 `take_over_path` patches so other mods can coexist on the
same scripts. Other mods patching any row below will conflict and last-loaded
wins.

Last updated: 2026-04-24 (v0.2.0)

## Classification

| Class        | Meaning                                                                               |
|--------------|---------------------------------------------------------------------------------------|
| **ESSENTIAL** | Overrides per-frame logic, host-auth physics, or a dispatch choke-point. Must stay.  |
| **HOOKABLE**  | Thin `super` wrap around a signal-emitting method. Replaceable by signal connect.    |
| **INJECTABLE**| Adds RPC/validation/RNG-seed/flag on a non-signal method. Replaceable by autoload + scene-scan monkey-patch. |
| **DECORATOR** | Cosmetic restructure (UI, null-guards). Could ship as its own optional mod.          |
| **BUGFIX**    | Null-guards or crash avoidance for vanilla; unrelated to co-op. Should upstream.     |

## Results (34 patches)

| Patch                 | Class        | Why                                                                         | Alternative / Notes                                  |
|-----------------------|--------------|-----------------------------------------------------------------------------|------------------------------------------------------|
| ai                    | ESSENTIAL    | `_physics_process` multi-player targeting + LOS + puppet mode                | —                                                    |
| ai_spawner            | ESSENTIAL    | Host sync_id pool tracking, deterministic indexing, host-only spawn gate     | —                                                    |
| btr                   | ESSENTIAL    | Host-auth physics; client freeze + lerp snapshot via vehicle_state           | —                                                    |
| casa                  | ESSENTIAL    | Host `_physics_process` + airdrop edge-broadcast; client parachute cosmetic  | —                                                    |
| controller            | ESSENTIAL    | Wraps Movement/Inertia/SurfaceDetection/_input per-frame + vitals broadcast  | Audio-pool could be OPTIONAL split                    |
| event_system          | ESSENTIAL    | Host-only RNG + client RPC replay (desync prevention)                        | —                                                    |
| helicopter            | ESSENTIAL    | Host-auth physics; client lerp snapshot                                      | —                                                    |
| interactor            | ESSENTIAL    | Dispatch choke-point: intercepts every Interactable Interact on client/host  | —                                                    |
| loot_simulation       | ESSENTIAL    | Suppresses client loot gen; headless handoff                                 | Detect role in `_ready`, skip parent gen              |
| missile_spawner       | ESSENTIAL    | Host launches; clients spawn identical pool via prepare/launch RPC           | —                                                    |
| police                | ESSENTIAL    | Host-auth physics; client freeze + lerp snapshot                             | —                                                    |
| rocket_grad           | ESSENTIAL    | Host physics; client lerp snapshot from vehicle_state                        | —                                                    |
| rocket_helicopter     | ESSENTIAL    | Host physics + collision + explosion broadcast; client lerp snapshot         | —                                                    |
| transition            | ESSENTIAL    | Routes client skip-save + user:// mirror                                     | Needs save-state gating before base Interact runs    |
| character             | HOOKABLE     | Broadcasts death via `super`                                                 | Hook Death signal if one exists, else INJECTABLE     |
| cat_feeder            | HOOKABLE     | Broadcasts `gameData.cat` edge after feeding via `super`                     | Hook `Interact` on feeder node                        |
| cat_rescue            | HOOKABLE     | Broadcasts `catFound` after rescue pickup                                    | Hook rescue pickup Interact                           |
| furniture             | HOOKABLE     | Broadcasts ResetMove/Catalog                                                 | Connect ResetMove/Catalog signals                     |
| knife_rig             | HOOKABLE     | Slash/stab/hit RPC broadcasts                                                | Connect audio/raycast signals                         |
| mine                  | HOOKABLE     | Wraps Detonate/InstantDetonate                                               | Connect Detonate signals                              |
| trader                | HOOKABLE     | Routes client Interact to host RPC                                           | Patch Interact via Trader group                       |
| explosion             | INJECTABLE   | Co-op layer mask + LOS remote damage                                         | Scene-scan, set layer, hook damage signal             |
| fish_pool             | INJECTABLE   | Seeded RNG + player scan (with remotes)                                      | Autoload pre-seeds by path hash                       |
| grenade_rig           | INJECTABLE   | Captures throw, broadcasts RPC                                               | Hook ThrowHigh/LowExecute                             |
| instrument            | INJECTABLE   | Edge-detects audioPlayer start/stop → 3D audio RPC                           | Connect audioPlayer.playing signals                   |
| interface             | INJECTABLE   | Reimplements Drop/CompleteDeal with RPC                                      | Intercept Drop signal; RPC wrap                       |
| layouts               | INJECTABLE   | Seeds RNG by node path for shared pick                                       | Autoload hashes node path in _ready                   |
| loader                | INJECTABLE   | Adds savePath/playerSavePath + mirror logic                                  | Autoload patches Loader fields, hooks Save calls      |
| pickup                | INJECTABLE   | Wraps Interact, broadcasts sync_id                                           | Patch Interact for sync_id + broadcast                |
| radio                 | INJECTABLE   | Routes Interact() toggle through host                                        | Hook Radio group Interact                             |
| simulation            | INJECTABLE   | Applies host-auth day/night rate multipliers on top of vanilla tick          | Autoload tweaks `timeScale`                           |
| television            | INJECTABLE   | Routes Interact() toggle through host                                        | Hook Television group Interact                        |
| settings              | DECORATOR    | UI tab restructure + multiplayer tab                                         | Ship as standalone vmz; optional                      |
| decor_mode            | BUGFIX       | Null-guards child.indicator (vanilla crash)                                  | Upstream PR candidate                                 |

## Totals

- ESSENTIAL: 14
- HOOKABLE: 7
- INJECTABLE: 11
- DECORATOR: 1
- BUGFIX: 1

Reachable target: **34 → 14** `take_over_path` (59% reduction) if HOOKABLE +
INJECTABLE + DECORATOR + BUGFIX all migrate. Actual reduction depends on
signal availability in base game scripts — `_`-prefixed privates can't be
hooked externally.

## Migration Strategy

### Phase 1 — Hookable (low risk, 7 patches)
Move to `mod/hooks/` module. Pattern:
1. Autoload scans scene on `scene_changed` for target group.
2. Connect to base-game signal (Interact, Detonate, etc.).
3. Handler broadcasts via existing RPC on `coop_manager`.
4. No script replacement.

### Phase 2 — Injectable (medium risk, 11 patches)
For methods without signals, two sub-strategies:
- **State inject:** collision layer / RNG seed / save path → autoload writes
  directly on `scene_changed`. No method override.
- **Monkey-patch:** store original method `Callable`, replace with a wrapper
  that `.call()`s the original + adds broadcast. Attach via `set_script`
  chain or runtime `Object.get_method_list` swap.

### Phase 3 — Decorator / Bugfix
- `settings` → extract to standalone optional vmz; user can disable without
  breaking coop.
- `decor_mode` → upstream PR; drop patch when vanilla fixed.

### Phase 4 — Essential reduction (stretch)
- `controller` audio-pool split: extract `warm_audio_pool` + `play_pooled`
  to a child node so `Controller.gd` itself is untouched.
- `transition` save-mirror gate: move to autoload intercepting SceneTree
  before base `Interact` fires; then patch is only needed for client-skip.

## Risks

- Signals may not exist for every Interact target. Check base-game scripts
  for explicit `signal` decls before migrating.
- Private methods (`_`-prefixed) cannot be hooked via signal.
- `super()` chain loss: RPC relay must fully reproduce base-game side
  effects. Easy to miss a sibling-node mutation.
- Base game updates that rename or remove target signals break hooks the
  same way they'd break `take_over_path`. Hooks generally fail louder
  (missing-signal error vs. silent miss on replaced script).

## Verification

After each phase:
- Run `godot proj:errors` — expect clean.
- Run all test scenarios from `.wolf/known_bugs.md` test plan.
- Diff `modloader_conflicts.txt` — total conflict count should drop.
- MP smoke: host + 1 client, one scenario per migrated patch class.

## v0.2.0 baseline

34 `take_over_path` scripts (up from 24 at the 0.1.0 audit). New additions
since 0.1.0 were all ESSENTIAL vehicles (BTR/Helicopter/Police/missile/rocket
variants), ESSENTIAL Interactor dispatch, plus HOOKABLE cat quest + INJECTABLE
instrument/radio/television toggles. The essentials-heavy growth reflects
the parity sweep against competitor mod behaviors; not all are amenable to
migration without base-game signal additions.
