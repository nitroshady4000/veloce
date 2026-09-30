# Véloce

**L’esprit libre. Les mots suivent.**

Une petite app de dictée pour macOS et Apple Silicon. Maintenez **Fn**, parlez, relâchez : votre texte revient dans le champ où vous écriviez. Interface SwiftUI, inférence MLX sur le Mac, aucun compte ni service de transcription.

`Veloce` pour le dépôt et l’application ; **Véloce** dans l’interface.

## Première version de développement

- Dictée avec Fn / Globe, pill en verre et V animé au rythme de la voix.
- Palette Feu follet de Famulus : graphite, ambre et lumière colorée. Interface SwiftUI native, animations Metal, prise en compte de Réduire les animations et Réduire la transparence.
- Trois modèles locaux : Qwen3-ASR 1.7B 8-bit (Précision), Qwen3-ASR 0.6B 8-bit (Équilibre), Parakeet TDT 0.6B v3 (Alternative).
- Modèle conservé en mémoire entre deux dictées ; pas de lancement Python à chaque phrase.
- Français ou détection automatique. Vocabulaire personnel transmis à Qwen.
- Insertion dans l’application de départ lorsque le champ et la sélection n’ont pas changé. Sinon, bouton Copier.
- Presse-papiers restauré après le collage, sauf si vous l’avez modifié entre-temps.
- Audio temporaire supprimé après traitement. Historique persistant désactivé par défaut ; le dernier résultat reste en mémoire pour être copié.
- Moteur indépendant de l’interface, utilisable depuis Famulus via JSONL.

Ce dépôt contient une **version de développement**, pas encore un DMG signé et notarié. La dictée est limitée à deux minutes. L’import de meetings, la diarisation, les résumés et la réécriture par LLM ne font pas partie de cette première version.

## Lancer

Requis : Mac Apple Silicon, macOS 14+, outils de développement Swift 6.2+, [uv](https://docs.astral.sh/uv/getting-started/installation/). Xcode complet n’est pas nécessaire au moteur Python.

Les tests Swift utilisent XCTest et nécessitent Xcode complet sélectionné comme répertoire développeur. Sur une machine avec plusieurs Xcode, utilisez `DEVELOPER_DIR=/chemin/vers/Xcode.app/Contents/Developer` devant la commande de build/test.

```sh
git clone https://github.com/nitroshady4000/veloce.git
cd veloce
bash scripts/build-app.sh --open
```

Dans **Modèles**, choisissez un profil puis préparez-le. Véloce crée un environnement Python 3.12 isolé, installe les dépendances verrouillées et télécharge les poids à une révision précise. Le premier chargement prend plusieurs minutes selon votre connexion. Comptez environ 1 Go pour Équilibre, 2,5 Go pour Précision. Ensuite, la transcription reste locale.

Les builds de développement utilisent `Engine/` dans le checkout : conservez le dépôt à cet emplacement. Le packaging autonome d’un runtime signé reste à faire avant distribution publique.

Dans Véloce, les boutons **Microphone** et **Fn et insertion** ouvrent un guide. Il déclenche la demande native ou ouvre le panneau approprié de Réglages Système, puis vérifie automatiquement les accès. Fn est déclaré prêt seulement quand son écouteur a réellement démarré. L’accessibilité sert à écouter Fn et à insérer le texte.

Si Globe ouvre toujours le sélecteur d’émojis, réglez « Appuyer sur la touche 🌐 pour » sur « Ne rien faire » dans Réglages Système → Clavier.

La signature ad hoc de développement change à chaque recompilation : macOS peut conserver une ancienne autorisation cochée. Dans l’aide du guide, **Retrouver cette app** montre le bundle en cours d’exécution. Retirez l’ancienne entrée dans Accessibilité, ajoutez ce bundle et activez-le ; relancez Véloce si macOS le demande. Pour des builds utilisant une identité de signature installée dans votre trousseau :

```sh
VELOCE_SIGN_IDENTITY="Apple Development: Votre nom (TEAMID)" bash scripts/build-app.sh
```

Véloce ne modifie pas les autorisations système à votre place. Une identité de signature stable est nécessaire pour rendre les mises à jour fiables ; la signature et la notarisation des releases restent à mettre en place.

Placez le curseur dans un champ texte, maintenez Fn, parlez puis relâchez. **Échap** annule pendant l’enregistrement. Les raccourcis Fn combinés avec d’autres touches annulent la dictée. Les champs protégés et les applications qui n’exposent pas un champ texte accessible utilisent le bouton Copier.

Installation du moteur en terminal, si nécessaire :

```sh
bash Engine/bootstrap.sh              # Qwen
bash Engine/bootstrap.sh --parakeet   # Qwen + Parakeet
```

## Architecture

```text
SwiftUI + AppKit
  Fn → WAV temporaire 16 kHz mono → EngineClient
                                      │ JSONL / pipes, aucun port réseau
                               worker Python persistant
                                      │
                             Qwen MLX / Parakeet MLX
                                      │
                           texte → insertion / copie
```

`VeloceCore` contient le contrat de transport et les types. `Engine/` est réutilisable sans l’interface macOS. Voir [le protocole du moteur](Engine/README.md), [le choix des modèles](docs/research-asr.md) et [les alternatives existantes](docs/alternatives.md).

Pour vérifier le design pendant qu’une autre version tourne, construisez un bundle distinct et rendez ses vues hors écran. Cette commande ne démarre ni microphone, ni raccourci global, ni moteur de transcription :

```sh
VELOCE_APP_OUTPUT="$PWD/build/design-preview/Veloce.app" bash scripts/build-app.sh
build/design-preview/Veloce.app/Contents/MacOS/Veloce --render-design build/design-preview/renders
```

## Vérifier et faire évoluer les modèles

```sh
swift test --disable-sandbox
python3 -m unittest discover -s Engine -p 'test_*.py' -v
```

« SOTA » est un objectif de mesure, pas une promesse accolée à un modèle. Les versions Python et les révisions des poids sont verrouillées. Une mise à jour doit améliorer les résultats d’un corpus français représentatif, en conservant les noms propres, sans régression de latence après relâchement ni de mémoire sur le M2 Pro 16 Go de référence. Le protocole de benchmark est documenté dans la recherche ASR. Les chiffres externes et les mesures synthétiques ne remplacent pas ce corpus réel.

Une veille hebdomadaire des versions est fournie en CI ; elle produit un rapport, sans changer silencieusement les modèles installés. Les mises à jour effectives restent des changements de code revus et testés.

## Confidentialité et limites

Le téléchargement initial contacte les registres Python et Hugging Face. Les dictées ne leur sont pas envoyées. Aucune télémétrie applicative. Historique optionnel dans `~/Library/Application Support/Veloce/history.json` ; les builds de développement gardent les modèles dans `Engine/.models`. Le moteur autonome utilise `~/Library/Caches/Veloce/models` (sauf `VELOCE_MODEL_CACHE`).

Le collage simule Cmd+V : macOS ne confirme pas que l’application destinataire a accepté le texte. Le résultat reste donc accessible dans Véloce. L’audio temporaire peut subsister après un arrêt brutal du processus ou de macOS. Avant une release : signature, notarisation, installation autonome, test des autorisations et de Fn sur plusieurs claviers, validation du cycle de vie et benchmark français réel.

## Licence

Code Véloce : [MIT](LICENSE). Les moteurs, dépendances et poids conservent leurs propres licences ; voir [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Aucun code de Famulus n’est modifié par ce projet.
