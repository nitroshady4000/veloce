# Véloce — handoff UI pour Claude Code

**Demande de Cédric, 30 septembre 2026.** La dictée fonctionne « archi bien ». La petite pill n'a pas encore la beauté de Famulus : reprendre réellement son rendu et créer un beau **V vivant** pour Véloce. Garder la pill et ses couleurs ; remplacer la flamme, sans nouvelle mascotte. Ce handoff porte sur la pill et l'identité visuelle, pas sur le moteur ni une refonte générale de l'app.

## Référence et écart actuel

Projet : `/Users/cedric/Dev/veloce` — GitHub : https://github.com/nitroshady4000/veloce. Base UI inspectée : `5a16e2b`. Référence : `/Users/cedric/Dev/famulus/app/poc`, commit inspecté `b892f517` ; lire les sources présentes avant de travailler, Famulus évolue en parallèle.

- **`Skin.swift`** : skin **Feu follet** par défaut, `DropGlass` (vers ligne 270), tintes et composition native Liquid Glass. Famulus fond une capsule et un bulbe via le conteneur de verre ; sa forme exacte sert au fond et au clipping.
- **`SkinFeuFollet.swift`** : `WispGeometry` (ligne 36), union douce commune au verre et au shader, croissance depuis le bulbe, lumière intérieure, liseré et transitions. **`Magic.swift`** : palette et mouvement organique. **`Pill.swift`** : proportions, typographie, placement et comportements.
- Repères : hauteur 56 pt, bulbe +5 pt, fusion 12 pt, bas du verre à 44 pt au-dessus du `visibleFrame`, caractère 40,48 × 44 pt. Blanc 95/66/46 %, ambre `#FFB547`, or `#FFD66B`, corail `#FF6F5E`, magenta `#F2479B`, violet `#8E5CFF`, cyan `#3FD4FF`, succès menthe `#8FD6AE`.

Véloce n'en est actuellement qu'une adaptation compacte : contour Bézier approximatif, shader simplifié, largeur fixe 360 pt, V fait de deux segments arrondis. La proximité des couleurs ne suffit pas. Reprendre la géométrie, la profondeur du verre, les entrées/sorties et le rythme de Famulus ; adapter le signe animé avec une vraie intention graphique. Attention : le mode d'export hors écran utilise volontairement un fond opaque, il ne valide pas la réfraction du verre en situation réelle.

## Fichiers à travailler dans Véloce

- `Sources/Veloce/Views/VelocePill.swift` : vue de présentation pure, géométrie, texte et contrôles ; `PillPhase` couvre repos/écoute/traitement/succès/erreur.
- `Sources/Veloce/Views/PillLight.swift` : V et lumière dans une seule couche Metal, enveloppe voix, arrêt du rendu caché, réduction des animations.
- `Sources/Veloce/Views/RecordingHUDView.swift` : branchement des états existants. `Sources/Veloce/VeloceApp.swift` : panneau non activant et placement, seulement si nécessaire.
- `Sources/Veloce/Views/DesignSystem.swift` (`VeloceMark`), `scripts/make-icon.swift`, `Resources/AppIcon.png` et `.icns` : un même V reconnaissable en logo, icône et pill ; livrer une source vectorielle ou procédurale reproductible. Nom affiché **Véloce**, identifiants techniques **Veloce**.

Préserver les callbacks et le fonctionnement Fn, l'insertion, les permissions et l'ASR local déjà validés. Le module Réunions est développé en parallèle : ne pas remplacer ses fichiers ou écraser ses branchements. Lire `git status` et coordonner les fichiers partagés. Famulus reste une référence en lecture seule. Toute reprise de code doit conserver les mentions de licence applicables dans `THIRD_PARTY_NOTICES.md`.

## Construire et comparer sans interrompre l'app utilisée

Depuis `/Users/cedric/Dev/veloce` :

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
VELOCE_APP_OUTPUT="$PWD/build/ui-claude/Veloce.app" bash scripts/build-app.sh
build/ui-claude/Veloce.app/Contents/MacOS/Veloce --render-design build/ui-claude/renders
```

L'export produit PNG et GIF sans microphone ni modèle. Ne pas écraser `build/Veloce.app`, ne pas quitter ou relancer la version utilisée pendant un test. La signature ad hoc peut nécessiter une nouvelle autorisation après compilation ; conserver le bundle ID `com.veloce.dictation` et le guide existant.

**Acceptation :** comparaison visuelle avec Famulus, verre et lumière convaincants sur fonds clair/sombre, V lisible petit et animé avec la voix, traitement et succès distincts, aucun vol de focus ni clipping, aucun rendu continu quand caché, options d'accessibilité respectées. Fournir une courte animation et les icônes, compiler et exécuter les tests existants ; validation de la vraie pill avec Cédric après son test en cours.
