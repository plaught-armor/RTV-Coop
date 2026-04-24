## Shared constants for puppet rig spawning. Read by presentation (runtime
## puppet) and UI (character picker preview); avoids UI→presentation preload.
extends RefCounted


const BODY_SCENES: Dictionary[String, String] = {
    "Bandit": "res://AI/Bandit/AI_Bandit.tscn",
    "Guard": "res://AI/Guard/AI_Guard.tscn",
    "Military": "res://AI/Military/AI_Military.tscn",
    "Punisher": "res://AI/Punisher/AI_Punisher.tscn",
}
