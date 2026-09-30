# Véloce — handoff UI pour Claude Code

**Dernière demande de Cédric, 30 septembre 2026.** Garder une **pill simple, sans logo V**, avec une lumière et des couleurs qui réagissent davantage à la voix. L’ensemble doit vivre plus. Ajouter une présentation discrète par **petit glyphe animé dans la barre de menus**, au choix dans les réglages. Cette demande remplace le précédent brief sur un V animé dans la pill.

Projet : `/Users/cedric/Dev/veloce` — GitHub : https://github.com/nitroshady4000/veloce. La dictée fonctionne déjà ; travailler la présentation avec les états et actions existants. Lire `git status` avant toute modification : les fonctions Dictée et Réunions évoluent en parallèle.

## Direction visuelle actuelle

- Capsule de 360 × 56 pt, fond de verre sombre, texte simple et lisible, aucun logo ni mascotte dans la pill. Éviter une zone vide réservée à l’ancien V.
- Réaction voix visiblement amplifiée, montée rapide et retour doux. La lumière se renforce, s’élargit et traverse les couleurs avec la parole ; une respiration discrète signale l’écoute même avant la première phrase. Cela concerne le rendu visuel, pas le gain audio ou la transcription.
- Traitement : lumière qui parcourt le contour ; succès : éclair bref couleur menthe ; erreur : corail calme. Arrêter le rendu lorsque la pill est cachée et une fois le succès terminé.
- Présentation « Barre de menus » : glyphe de 18 pt, cinq traits arrondis qui réagissent à la voix puis ondulent pendant le traitement. Image template native pour rester lisible en mode clair et sombre. Aucun rendu continu au repos.
- macOS décide du placement initial de l’icône ; Cédric peut la déplacer avec ⌘-glisser vers la caméra. Ne pas tenter de positionner automatiquement un élément natif autour de l’encoche.
- Respecter Réduire les animations et Réduire la transparence. Avec la réduction des animations, garder une réponse de couleur/amplitude directe à la parole, sans déplacement ni horloge d’animation.

## Fichiers et interfaces

- `Sources/Veloce/Views/VelocePill.swift` : capsule, textes et boutons ; `PillPhase(appPhase:)` traduit les états existants. `PillVoiceResponse.amplitude(_:)` amplifie seulement la présentation du niveau micro.
- `Sources/Veloce/Views/PillLight.swift` : une petite couche Metal pour la lumière, enveloppe voix rapide, arrêt quand cachée. `previewTime` permet de figer des images sans horloge.
- `Sources/Veloce/Views/RecordingHUDView.swift` : branchement de la dictée et callbacks Arrêter/Annuler.
- `Sources/Veloce/Views/MenuGlyph.swift` : `MenuGlyph(phase:level:)` pour le label de `MenuBarExtra`, images natives renouvelées pendant l’écoute et le traitement. `MenuGlyphAnimator` est également utilisable directement.
- `Sources/Veloce/VeloceApp.swift` : panneau non activant, placement, choix de présentation ; `AppModel.presentationMode` propose `.pill` / `.menuBar`. Coordonner les changements de ces fichiers partagés avec le développeur du moteur.

Les couleurs restent inspirées de Famulus, référence en lecture seule : `/Users/cedric/Dev/famulus/app/poc`. Repères : blanc 95/66/46 %, ambre `#FFB547`, or `#FFD66B`, corail `#FF6F5E`, magenta `#F2479B`, violet `#8E5CFF`, cyan `#3FD4FF`, succès menthe `#8FD6AE`. Toute reprise de code tiers doit conserver les mentions de licence dans `THIRD_PARTY_NOTICES.md`.

## Construire et vérifier

Depuis `/Users/cedric/Dev/veloce` :

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
VELOCE_APP_OUTPUT="$PWD/build/ui-claude/Veloce.app" bash scripts/build-app.sh
build/ui-claude/Veloce.app/Contents/MacOS/Veloce --render-design build/ui-claude/renders
```

L’export est sans microphone ni modèle. Il utilise volontairement un fond opaque pour la pill ; vérifier aussi le verre en situation réelle sur fonds clair et sombre. Préparer une version distincte pendant que Cédric teste, préserver la signature et le guide d’autorisations existants.

**Acceptation :** pill sans V, voix normale produisant une lumière franchement visible, traitements et succès distincts, texte lisible, aucun vol de focus, aucun clipping, mode barre de menus fonctionnel, arrêt du rendu caché/au repos, accessibilité respectée. Fournir une courte animation et compiler avec les tests existants.
