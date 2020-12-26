#!/bin/bash

# Récupère le dossier du script
if [ "${0:0:1}" == "/" ]; then script_dir="$(dirname "$0")"; else script_dir="$(echo $PWD/$(dirname "$0" | cut -d '.' -f2) | sed 's@/$@@')"; fi

dest=$(cat "$script_dir/auto.conf" | grep MAIL_DEST= | cut -d '=' -f2)

sudo rm -r "$script_dir/../../apps"	# Supprime le précédent clone de YunoHost/apps
git clone -q git@github.com:YunoHost/apps.git "$script_dir/../../apps"	# Récupère la dernière version de https://github.com/YunoHost/apps

cd "$script_dir/../../apps"	# Se place dans le dossier du dépot git pour le script python

git checkout -b modify_level	# Créer une nouvelle branche pour commiter les changements

public_result_list="$script_dir/../logs/list_level_stable_amd64.json"

# For each app in the result file
for APP in $(jq -r 'keys[]' "$public_result_list")
do
    # Get the level from the stable+amd64 tests
    level="$(jq -r ".\"$APP\".level" "$public_result_list")"
    # Inject the new level value to apps.json
    jq --args $level ".\"$APP\".level=\$level" apps.json > apps.json.new
    mv apps.json.new apps.json
done

git diff -U2 --raw | tee "$script_dir/mail_content"	# Affiche les changements (2 lignes de contexte suffisent à voir l'app)
git add --all *.json | tee -a "$script_dir/mail_content"	# Ajoute les modifications des listes au prochain commit
git commit -q -m "Update app's level" | tee -a "$script_dir/mail_content"

# Git doit être configuré sur la machine.
# git config --global user.email "MAIL..."
# git config --global user.name "yunohost-bot"
# ssh-keygen -t rsa -f $HOME/.ssh/github -P ''		Pour créer une clé ssh sans passphrase
# Host github.com
# IdentityFile ~/.ssh/github
# Dans le config ssh
# Et la clé doit être enregistrée dans le compte github de yunohost-bot
git push -q -u origin modify_level | tee -a "$script_dir/mail_content"

mail -s "[YunoHost] Modification du niveau des applications" "$dest" < "$script_dir/mail_content"	# Envoi le log de git par mail.
