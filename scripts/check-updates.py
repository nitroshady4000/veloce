"""Read-only release watch. Never installs packages or changes model pins."""
import json
import pathlib
import urllib.request
import tomllib

project = tomllib.loads((pathlib.Path(__file__).resolve().parents[1] / "Engine/pyproject.toml").read_text())
dependencies = project["project"]["dependencies"] + project["project"]["optional-dependencies"]["parakeet"]
print("# Véloce — veille des moteurs\n")
print("| Moteur | Version verrouillée | Version publiée | État |")
print("|---|---|---|---|")
for dependency in dependencies:
    name, pinned = dependency.split("==")
    with urllib.request.urlopen(f"https://pypi.org/pypi/{name}/json", timeout=30) as response:
        current = json.load(response)["info"]["version"]
    print(f"| {name} | {pinned} | {current} | {'À évaluer' if current != pinned else 'À jour'} |")
print("\nExaminer aussi les nouveaux modèles Qwen, NVIDIA et MLX ; comparer le corpus français avant de modifier les révisions des poids. Aucun remplacement automatique.")
