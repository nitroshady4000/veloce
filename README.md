# Véloce

Une petite app de dictée pour macOS et Apple Silicon. Maintenez **Fn**, parlez, relâchez : votre texte revient dans le champ où vous écriviez. Interface SwiftUI, inférence MLX sur le Mac, aucun compte ni service de transcription.

`Veloce` pour le dépôt et l’application ; **Véloce** dans l’interface.

## Version de développement

Véloce est une app de dictée et de réunions pour macOS et Apple Silicon. La reconnaissance vocale tourne localement avec MLX ; aucun compte ni service cloud de transcription. Le téléchargement initial des modèles et dépendances nécessite Internet.

La version de développement 0.2.4 intègre :

- Dictée Fn avec Qwen3-ASR 0.6B par défaut ; le profil 1.7B et Parakeet TDT v3 sont aussi disponibles. Un seul modèle de transcription finale tourne à la fois. Le double Fn active le mode mains libres.
- Capture de la dictée suivante pendant le traitement, avec file FIFO bornée à quatre dictées, un seul ASR, puis collage dans l’ordre. Échap annule la capture en cours et laisse le traitement actif continuer. Fn ne lance pas de nouvelle dictée pendant une réunion.
- Texte brut conservé, nettoyage Apple Intelligence facultatif, snippets et réécriture ou traduction vocale d’une sélection avec prévisualisation.
- Pill sans mascotte, mots progressifs et lumière réactive à la voix, ou glyphe animé dans la barre de menus. Fn pendant le chargement affiche l’état de préchauffe.
- Réunions à deux pistes, import avec file audio et MP4/MOV/M4V, relecture par segment, corrections du texte, renommage/fusion/réattribution des interlocuteurs, recherche locale et exports TXT/VTT.
- Service Finder accessible par clic droit → Services → Transcrire dans Véloce. Il crée à côté du média un `.txt` ou `.md` portant la même base de nom, sans écraser un fichier existant, et ajoute la transcription à l’historique.
- Transcription en direct facultative, avec mise à jour environ toutes les 30 secondes sur un worker Qwen 0.6B ; calendrier et rappels facultatifs, ainsi que questions de recherche lexicale locale avec Apple Intelligence et passages de référence.

Le nettoyage, la réécriture, la traduction et les questions avec Apple Intelligence exigent macOS 26 et un modèle disponible prenant en charge le français. Les tests Swift, Python et les contrôles natifs sur données synthétiques couvrent les files de traitement, le collage et les imports. Cela ne valide pas un véritable appel, le service Finder sur une machine utilisateur, les résultats Apple Intelligence ni les performances sur un corpus français représentatif.

Les versions de développement utilisent une signature locale et des mises à jour Sparkle signées. La notarisation Apple et la validation sur d’autres Mac restent à faire avant une distribution grand public. La durée maximale d’une dictée est de deux minutes.

## Installer et mettre à jour

Installez `Veloce.app` dans `/Applications`. Dans **Réglages → Application**, le bouton **Rechercher une mise à jour…** propose les versions publiées sur [GitHub Releases](https://github.com/nitroshady4000/veloce/releases). Les mises à jour automatiques sont activées par défaut : elles téléchargent les versions signées puis les installent à la fermeture. Un redémarrage demandé pour mettre à jour attend la fin d’un enregistrement ou traitement en cours.

Le réglage **Ouvrir Véloce au démarrage du Mac** utilise les éléments d’ouverture natifs de macOS. macOS peut demander une confirmation dans ses réglages.

Les modèles et l’historique restent en dehors de l’application et sont conservés pendant les mises à jour. Pour publier la version suivante, voir [RELEASING.md](docs/RELEASING.md).

Le **texte en direct** de la pill utilise la reconnaissance Apple sur ce Mac. Sous macOS 26+, son modèle est préparé au démarrage et installé si nécessaire, sans demander l’ancienne autorisation de reconnaissance vocale. Sur les systèmes plus anciens, celle-ci reste nécessaire pour le moteur Apple local. L’état et les actions de dépannage se trouvent dans **Réglages → Texte en direct**. Le texte collé provient toujours du modèle choisi dans Véloce.

## Compiler

Requis : Mac Apple Silicon, macOS 14+, outils de développement Swift 6.2+, [uv](https://docs.astral.sh/uv/getting-started/installation/). Xcode complet n’est pas nécessaire au moteur Python.

Les tests Swift utilisent XCTest et nécessitent Xcode complet sélectionné comme répertoire développeur. Sur une machine avec plusieurs Xcode, utilisez `DEVELOPER_DIR=/chemin/vers/Xcode.app/Contents/Developer` devant la commande de build/test.

```sh
git clone https://github.com/nitroshady4000/veloce.git
cd veloce
bash scripts/build-app.sh --open
```

Dans **Modèles**, choisissez un profil puis préparez-le. Véloce crée un environnement Python 3.12 isolé, installe les dépendances verrouillées et télécharge les poids à une révision précise. Le premier chargement prend plusieurs minutes selon votre connexion. Comptez environ 1 Go pour Équilibre, 2,5 Go pour Précision. Ensuite, la transcription reste locale.

L’app compilée embarque le code du moteur et uv. Python est installé dans `~/Library/Application Support/Veloce/Engine`, et les modèles dans `~/Library/Caches/Veloce/models`. Le dépôt peut ensuite être déplacé sans casser l’app installée.

Dans Véloce, les boutons **Microphone** et **Fn et insertion** ouvrent un guide. Il déclenche la demande native ou ouvre le panneau approprié de Réglages Système, puis vérifie automatiquement les accès. Fn est déclaré prêt seulement quand son écouteur a réellement démarré. L’accessibilité sert à écouter Fn et à insérer le texte.

Si Globe ouvre toujours le sélecteur d’émojis, réglez « Appuyer sur la touche 🌐 pour » sur « Ne rien faire » dans Réglages Système → Clavier.

La signature ad hoc de développement change à chaque recompilation : macOS peut conserver une ancienne autorisation cochée. Dans l’aide du guide, **Retrouver cette app** montre le bundle en cours d’exécution. Retirez l’ancienne entrée dans Accessibilité, ajoutez ce bundle et activez-le ; relancez Véloce si macOS le demande. La dictée Fn nécessite macOS 14 ou ultérieur ; la capture système des réunions nécessite macOS 15 ou ultérieur. Pour des builds utilisant une identité de signature installée dans votre trousseau :

```sh
VELOCE_SIGN_IDENTITY="Apple Development: Votre nom (TEAMID)" bash scripts/build-app.sh
```

Véloce ne modifie pas les autorisations système à votre place. Les releases successives conservent la même identité de signature et la même clé Sparkle. La notarisation Apple reste distincte de la signature locale de développement.

Placez le curseur dans un champ texte, maintenez Fn, parlez puis relâchez. **Échap** annule pendant l’enregistrement. Les raccourcis Fn combinés avec d’autres touches annulent la dictée. Le collage fonctionne aussi lorsque l’app expose un champ texte sans position de curseur accessible. Les champs protégés utilisent le bouton Copier. Si la destination change pendant le traitement, le texte reste disponible dans Véloce.

Au lancement, Véloce recharge le dernier modèle préparé depuis le cache local, sans téléchargement. Le bouton Préparer sert à charger un autre modèle ou à télécharger les fichiers manquants.

Vous pouvez redicter pendant le traitement du texte précédent : les dictées sont traitées et collées dans leur ordre d’enregistrement, sans charger un second modèle. Chaque dictée garde sa destination. Le curseur d’une capture suivante avance après notre propre collage seulement si la fenêtre, le champ, le texte et la position sont vérifiés ; si vous changez de destination ou modifiez le texte, le résultat reste disponible avec Copier.

Installation du moteur en terminal, si nécessaire :

```sh
bash Engine/bootstrap.sh              # Qwen
bash Engine/bootstrap.sh --parakeet   # Qwen + Parakeet
bash Engine/bootstrap.sh --meetings   # Qwen + détection des voix (combinable avec --parakeet)
```

## Réunions

Dans **Réunions**, donnez un titre puis cliquez sur **Enregistrer la réunion**. macOS 15+ est requis pour la capture simultanée du microphone et de l’audio système. L’autorisation macOS peut s’appeler « Enregistrement de l’écran et audio système » : Véloce n’enregistre aucune image. La capture couvre les sons des autres apps ; un casque évite de réenregistrer leurs voix dans le micro.

Deux WAV mono 16 kHz sont écrits progressivement sur une horloge commune : `microphone.wav` et `system.wav`. Ils restent dans `~/Library/Application Support/Veloce/Meetings/<UUID>/` avec les informations et les textes de la réunion. L’option d’historique des dictées n’affecte pas ces enregistrements. Arrêt automatique après environ quatre heures, soit environ 230 Mo d’audio par heure pour les deux pistes. Quitter normalement l’app finalise les fichiers avant de fermer.

- **Arrêter et transcrire**, ou sauvegarder les pistes pour les traiter plus tard. Le même worker et les mêmes modèles ASR servent à la dictée et aux réunions ; les deux traitements ne tournent pas simultanément.
- **Importer un audio…** ouvre le sélecteur natif de fichiers. Formats audio pris en charge : WAV, M4A, MP3, AIFF et CAF ; les vidéos MP4, MOV et M4V sont importées via leur piste audio. La conversion se fait progressivement, sans charger tout l’audio en mémoire, et peut être annulée. Une copie WAV mono 16 kHz est conservée dans Véloce (environ 115 Mo par heure, quatre heures maximum) ; les canaux sont réunis, le fichier d’origine reste intact. Cochez **Transcrire après l’import**, ou gardez l’audio pour plus tard. La suppression d’un import dans Véloce ne supprime pas le fichier d’origine.
- **Préparer la détection des voix** installe Sherpa ONNX et télécharge une fois environ 28 Mo de modèles verrouillés. Activez ensuite **Distinguer les interlocuteurs**. Sans ce modèle, les étiquettes restent **Vous / Participants** pour une capture, ou **Audio importé** pour un fichier : elles indiquent les sources, pas les personnes. Avec ce modèle, les voix sont détectées dans la piste système ou dans l’ensemble du fichier importé.
- Les voix sont des groupes acoustiques anonymes, pas des identités reconnues. Le texte et les noms peuvent être corrigés, les passages réattribués et des groupes de voix fusionnés. Les voix proches, courtes ou superposées peuvent être mal attribuées ; les repères temporels sont ceux des passages, pas des mots alignés.
- La transcription peut être recherchée localement, relue avec lecture synchronisée par segment, corrigée et exportée en **TXT**, **VTT**, **Markdown**, **SRT** ou **JSON**. Les pistes peuvent être exportées en WAV. Le glisser-déposer ajoute des médias à la file d’import.
- **Créer le compte rendu** utilise exclusivement le modèle local Apple Intelligence, disponible sur macOS 26+ lorsqu’il est activé et prend en charge le français. Toutes les portions de la transcription sont traitées par blocs avant synthèse. Le résultat est modifiable et à relire ; il reste facultatif et n’est jamais envoyé à un service cloud. Les notes sont conservées lors d’une retranscription.

La diarisation a été vérifiée sur des voix synthétiques, la conversion et l’alignement sur des paquets audio synthétiques. La capture d’un véritable appel, le cycle du service Finder sur une installation utilisateur, les voix superposées et les changements de périphérique restent à valider sur les applications de réunion utilisées. Un arrêt brutal peut laisser une réunion marquée interrompue ; Véloce conserve ses fichiers pour récupération.

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
# Convertisseur natif + WAV, sur données synthétiques uniquement, dossier neuf :
build/Veloce.app/Contents/MacOS/Veloce --verify-text-insertion
build/Veloce.app/Contents/MacOS/Veloce --verify-meeting-audio /tmp/veloce-audio-check
build/Veloce.app/Contents/MacOS/Veloce --verify-audio-import /tmp/veloce-import-check
build/Veloce.app/Contents/MacOS/Veloce --verify-finder-service /tmp/veloce-finder-check
build/Veloce.app/Contents/MacOS/Veloce --verify-meeting-workflows /tmp/veloce-workflow-check
```

Sur macOS 26+, l’aperçu peut être vérifié sans microphone avec une phrase de
synthèse française. Ce contrôle prépare le modèle Apple local si nécessaire,
alimente le même convertisseur et le même analyseur à vitesse réelle, et exige
des résultats progressifs avant la fin du fichier :

```sh
say -v Thomas -o /tmp/veloce-preview-fr.aiff 'Bonjour, ceci est un test du texte en direct. Les mots apparaissent pendant que je parle. Nous préparons la réunion de jeudi avec toute notre équipe.'
build/Veloce.app/Contents/MacOS/Veloce --verify-live-preview /tmp/veloce-preview-fr.aiff
```

« SOTA » est un objectif de mesure, pas une promesse accolée à un modèle. Les versions Python et les révisions des poids sont verrouillées. Une mise à jour doit améliorer les résultats d’un corpus français représentatif, en conservant les noms propres, sans régression de latence après relâchement ni de mémoire sur le M2 Pro 16 Go de référence. Le protocole de benchmark est documenté dans la recherche ASR. Les chiffres externes et les mesures synthétiques ne remplacent pas ce corpus réel.

Une veille hebdomadaire des versions est fournie en CI ; elle produit un rapport, sans changer silencieusement les modèles installés. Les mises à jour effectives restent des changements de code revus et testés.

## Confidentialité et limites

Le téléchargement initial contacte les registres Python et Hugging Face. Les dictées ne leur sont pas envoyées. Aucune télémétrie applicative. Historique des dictées optionnel dans `~/Library/Application Support/Veloce/history.json` ; les transcriptions de réunions, y compris celles lancées depuis Finder, sont conservées dans leur historique local ; les builds de développement gardent les modèles dans `Engine/.models`. Le moteur autonome utilise `~/Library/Caches/Veloce/models` (sauf `VELOCE_MODEL_CACHE`).

Le collage simule Cmd+V. Lorsque l’app expose son texte, Véloce vérifie l’insertion avant de restaurer les formats lisibles du presse-papiers. Sans confirmation, la transcription reste dans le presse-papiers pour permettre un collage retardé ou manuel ; une nouvelle copie faite par l’utilisateur est toujours préservée. Le résultat reste également accessible dans Véloce. L’audio temporaire peut subsister après un arrêt brutal du processus ou de macOS. Les builds sans identité de signature utilisent une signature ad hoc. La notarisation Apple reste à faire ; la validation d’un vrai appel, du service Finder sur une machine utilisateur et un benchmark français réel restent également ouverts.

## Licence

Code Véloce : [MIT](LICENSE). Les moteurs, dépendances et poids conservent leurs propres licences ; voir [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Aucun code de Famulus n’est modifié par ce projet.
