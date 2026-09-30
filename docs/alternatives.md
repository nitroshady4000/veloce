# Pourquoi Véloce ?

Recherche du 30 septembre 2026, vérifiée sur les dépôts et leurs releases. Les fonctions annoncées par les auteurs ne remplacent pas un essai sur nos propres dictées françaises.

**Si le besoin est simplement de dicter localement avec Fn aujourd’hui, MacParakeet existe déjà.** Il propose une application SwiftUI, un installateur notarisé, Parakeet v3 pour le français et des mises à jour Sparkle. Véloce se justifie par une interface plus restreinte, une attention particulière au français et un moteur facile à partager avec Famulus. Il ne faut pas recréer les réunions, les résumés, les calendriers et tous les exports dans Véloce.

| Projet | Licence du code | Ce qu’il apporte | Limite pour Véloce |
| --- | --- | --- | --- |
| [MacParakeet](https://github.com/moona3k/macparakeet) | [GPL-3.0](https://github.com/moona3k/macparakeet/blob/main/LICENSE) | SwiftUI, Fn, Parakeet v3 local, WhisperKit et autres moteurs, dictée et réunions. Stable 0.8.9, projet actif au 30 septembre. | Beaucoup plus large que la dictée. Le « Qwen » des fournisseurs AI n’implique pas Qwen-ASR. Une reprise de code doit respecter le copyleft. |
| [Petal](https://github.com/Aayush9029/petal) | [MIT](https://github.com/Aayush9029/petal/blob/main/LICENSE) | SwiftUI, capsule soignée, Qwen3-ASR via MLX, Whisper et Voxtral. Dernier push le 25 septembre. | Le catalogue courant choisit Parakeet 110M anglais par défaut et a remplacé Parakeet v3 par Unified anglais. Ce défaut convient mal au français. Source plus large que le strict besoin. |
| [FreeFlow de Zach Latta](https://github.com/zachlatta/freeflow) | [MIT](https://github.com/zachlatta/freeflow/blob/main/LICENSE) | Application Mac, Fn, contexte et correction, projet actif au 28 septembre. | API Groq par défaut ; les fournisseurs locaux passent par un serveur compatible OpenAI à configurer. Ce n’est pas un moteur ASR local directement embarqué. |
| [FreeFlow Mac de Rohan Arun](https://github.com/rohanarun/freeflow-mac) | [MIT](https://github.com/rohanarun/freeflow-mac/blob/main/LICENSE) | Petit projet SwiftUI : Fn, FluidAudio/Parakeet v3 et Qwen3.5 0.8B pour corriger le texte. Release 0.2.0 notarisée du 21 août. | Qwen est ici le correcteur de texte, pas le moteur ASR. Projet créé et mis à jour le même jour ; recul limité. |
| [Handy](https://github.com/cjpais/Handy) | [MIT](https://github.com/cjpais/Handy/blob/main/LICENSE) | Alternative gratuite, locale, très active ; Whisper/Parakeet, raccourcis configurables. Release 0.9.7 du 18 septembre. | Rust/Tauri multiplateforme ; moins adapté à un socle SwiftUI exclusivement Mac. |
| [Qwen Scribe](https://github.com/VladUZH/qwen-scribe) | [Apache-2.0](https://github.com/VladUZH/qwen-scribe/blob/main/LICENSE) | Qwen3-ASR 0.6B/1.7B, dictée Fn configurable, vocabulaire, historique et fichiers. Actif au 26 septembre. | Version bêta, interface web locale et Python embarqué. Moins adapté comme socle d’interface native. |

## Ce qu’on réutilise, ce qu’on apprend

Le moteur d’inférence est une dépendance dédiée, séparée de l’interface, des permissions, de la capture et de l’insertion. Un fork complet d’une application n’est pas nécessaire pour garder cette architecture simple.

Les petits composants de [FreeFlow Mac](https://github.com/rohanarun/freeflow-mac/tree/main/Sources) illustrent deux idées utiles : conserver le moteur chargé dans un actor, et capturer l’application, l’élément d’accessibilité et la sélection au début de la dictée. Son service d’insertion tente Accessibility, puis Cmd-V en préservant les éléments et formats du presse-papiers. Son écouteur Fn est très simple ; il ne vérifie que les flags de modification. Ce n’est pas une implémentation de référence à recopier sans vérifier les touches physiques et les combinaisons.

[Petal](https://github.com/Aayush9029/petal/tree/main/PetalKit/Sources/UI/FloatingCapsule) fournit des exemples MIT de capsule, de visualisation du niveau sonore et de transitions. Ses [notes de version](https://github.com/Aayush9029/petal/releases) documentent notamment le préchauffage du micro, les fenêtres qui ne prennent pas le focus et les erreurs de raccourcis globaux.

[Handy documente](https://github.com/cjpais/Handy#previous-clipboard-content-is-pasted-instead-of-the-transcription) un piège important : restaurer le presse-papiers après un délai fixe peut le faire trop tôt pour une application occupée. Une insertion doit préserver le presse-papiers, respecter le focus et garder un moyen de recopier un texte en cas d’échec.

Une licence permissive autorise la reprise avec conservation des notices. Les modèles et dépendances ont leurs propres licences : la licence de l’application ne couvre pas automatiquement leurs poids. Aucun code de ces applications n’est copié dans cette première interface Véloce ; les liens servent à documenter la recherche et les choix.

## Ce qu’on peut honnêtement appeler « meilleur »

Il n’existe pas ici de benchmark français commun, effectué sur la machine cible, qui départage les applications. Les noms « Précision », « Équilibre » et « Vitesse » décrivent les profils visés, pas une supériorité mesurée. Il faut comparer la fidélité, les noms propres, les mélanges français/anglais, la latence après relâchement de Fn, le chargement initial et la mémoire sur les mêmes enregistrements avant de changer le modèle conseillé.
