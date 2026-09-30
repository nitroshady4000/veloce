# Pourquoi Véloce ?

Recherche du 30 septembre 2026, vérifiée sur les dépôts et leurs releases. Les fonctions annoncées par les auteurs ne remplacent pas un essai sur nos propres dictées françaises.

**Si le besoin est simplement de dicter localement avec Fn aujourd’hui, MacParakeet existe déjà.** Il propose une application SwiftUI, un installateur notarisé, Parakeet v3 pour le français et des mises à jour Sparkle. Véloce se justifie par une interface plus restreinte, une attention particulière au français et un moteur facile à partager avec Famulus. Le périmètre a ensuite été étendu à la demande de Cédric : réunions locales, interlocuteurs, compte rendu facultatif et import audio. Les autres fonctions restent à choisir, pas une liste à recopier intégralement.

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

Une licence permissive autorise la reprise avec conservation des notices. Les modèles et dépendances ont leurs propres licences : la licence de l’application ne couvre pas automatiquement leurs poids. Le code de ces projets peut être repris lorsque sa licence le permet, en conservant les notices et en respectant les obligations de redistribution ; la GPL de MacParakeet impose notamment ses propres conditions. La branche actuelle documente ces références sans attribuer de code repris.

## Ce qu’on peut honnêtement appeler « meilleur »

Il n’existe pas ici de benchmark français commun, effectué sur la machine cible, qui départage les applications. Les profils « Précision », « Équilibre » et « Alternative » décrivent des usages visés, pas une supériorité mesurée. Il faut comparer la fidélité, les noms propres, les mélanges français/anglais, la latence après relâchement de Fn, le chargement initial et la mémoire sur les mêmes enregistrements avant de changer le modèle conseillé.

## Périmètre demandé pour Véloce — 30 septembre 2026

Les choix produit sont maintenant définis. Le code correspondant est en cours d’intégration dans la branche ; ce tableau décrit le périmètre visé, pas des fonctionnalités validées ni des résultats mesurés.

| Domaine | Périmètre | Limite à garder visible |
| --- | --- | --- |
| Dictée | Qwen3-ASR 1.7B et 0.6B, Parakeet TDT v3 ; Équilibre (0.6B) par défaut ; un seul modèle ASR actif. Nettoyage Apple Intelligence facultatif avec texte brut conservé, snippets, double Fn/mains libres, transformation ou traduction du texte sélectionné. | Apple Intelligence nécessite macOS 26 et la disponibilité du français. Aucun benchmark de qualité n’est revendiqué. |
| Présence | Pill sans logo V, détection vocale et lumière/couleur plus expressives ; option glyphe animé dans la barre de menus. | Le rendu et l’écoute micro restent à valider en usage réel. |
| Réunions | Relecture synchronisée par segment, édition du texte, renommage/fusion/réattribution des voix, recherche textuelle locale, glisser-déposer et file d’import audio/vidéo, exports TXT/VTT. Transcription en direct facultative, mise à jour environ toutes les 30 secondes, désactivable. | La diarisation regroupe des voix acoustiques anonymes et peut se tromper ; la qualité française n’est pas mesurée ici. |
| Finder | Service macOS sur clic droit : transcrire audio/vidéo, créer un `.txt` ou `.md` de même nom à côté du média selon le format choisi, et ajouter la réunion à l’historique. | Un sidecar existant n’est jamais remplacé. Le fonctionnement est à valider après packaging et installation du service. |
| Calendrier et questions | Connexion calendrier EventKit et rappels opt-in. Questions sur les réunions traitées localement avec extraits de preuve. | Questions et fonctions Apple Intelligence exigent macOS 26 et la prise en charge du français. |
| Confidentialité | Transcription et traitement local après téléchargement initial ; aucune copie vers un service cloud. | Modèles et dépendances sont téléchargés au premier usage ; les autorisations macOS restent nécessaires. |

**Sources primaires vérifiées :**

- [Wispr fonctionnalités](https://wisprflow.ai/features), [Notetaker](https://wisprflow.ai/notetaker), [Transforms](https://docs.wisprflow.ai/articles/8068950331-how-to-use-transforms-beta), [snippets](https://docs.wisprflow.ai/articles/5784437944-create-and-use-snippets). Les styles automatiques par application sont documentés en anglais sur desktop. La capture sans bot ne signifie pas que l’inférence est locale.
- [Wispr exclut explicitement l’import audio/vidéo](https://docs.wisprflow.ai/articles/7689167034-can-i-upload-audio-files-to-wispr-flow-for-transcription). Son import Granola/Otter reprend des transcriptions texte, pas les enregistrements. La relecture audio desktop est contradictoire entre notes de version et aide ; ne pas l’utiliser comme référence confirmée pour les réunions.
- [FreeFlow Zach](https://github.com/zachlatta/freeflow), [changelog](https://github.com/zachlatta/freeflow/blob/main/CHANGELOG.md), [réglages et macros](https://github.com/zachlatta/freeflow/blob/main/Sources/SettingsView.swift). Centré dictée ; réunions, import et locuteurs non documentés. API Groq par défaut, endpoints configurables.
- [FreeFlow Mac Rohan](https://github.com/rohanarun/freeflow-mac) exclut explicitement le rôle d’enregistreur de réunions. Parakeet reconnaît la parole ; Qwen nettoie le texte. Historique local recherchable et comparaison brut/nettoyé.
- [MacParakeet](https://macparakeet.com), [fonctionnalités](https://github.com/moona3k/macparakeet/blob/main/spec/02-features.md), [état livré et feature flags](https://github.com/moona3k/macparakeet/blob/main/spec/README.md#release-channels-and-feature-flags). Ne pas attribuer à la version stable les fonctions présentes seulement dans le code : Ask transversal, commandes générales, profils vocaux persistants, partage chiffré et profils de formatage par application restent gated. Apple Intelligence y sert au nettoyage ; les analyses longues utilisent un autre fournisseur, éventuellement local avec Ollama/LM Studio.
