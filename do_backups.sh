#!/bin/bash

set -e

GPG_PASS_FILE='/tmp/backup_pass'
SSH_CMD="ssh rsyncnet"

DATE=$(date --iso)
DEST_DIR="backups/${DATE}"

function backup_dir {
  BDIR="${1}"
  DIRNAME=$(dirname "${BDIR}")
  BASENAME=$(basename "${BDIR}")
  NAME="${BASENAME}.tar"
  cd "${DIRNAME}"
  ionice -c idle tar -cf /dev/stdout "${BASENAME}" | backup_stdin "${NAME}"
}

function backup_stdin {
  DEST="${DEST_DIR}/${1}.gpg"
  gpg --batch "--passphrase-file=${GPG_PASS_FILE}" --compress-algo=none --symmetric | $SSH_CMD dd "of=${DEST}" bs=1M status=progress
  # Decrypt: gpg -d --batch "--passphrase-file=${GPG_PASS_FILE}"
  echo "Backed up data to ${DEST}"
}

# Create destination directory for this backup
${SSH_CMD} mkdir -p "${DEST_DIR}"

# Back up all of Documents except for videos
find '/home/david/Documents/' -mindepth 1 -maxdepth 1 -type d -print0 -not -name 'videos' \
| while read -r -d $'\0' DOC_DIR;
do
  backup_dir "${DOC_DIR}"
done

# Back up specific paths
backup_dir "/home/david/Documents/vidoes/special"
backup_dir "/home/david/Desktop"
backup_dir "/etc"

# Back up command outputs
tree /home/david/Documents/videos/findable | backup_stdin "cmd_videos_findable"
tree /home/david/Documents/videos/tmp      | backup_stdin "cmd_videos_tmp"

# Delete other/older backups
$SSH_CMD find backups -mindepth 1 -maxdepth 1 -not -name "${DATE}" -exec rm -rf {} \;

#################################
# Other utilities/sample commands
function setup {
  cat ~/.ssh/id_ed25519.pub | ${SSH_CMD} dd of=.ssh/authorized_keys
}

function inspect {
  ${SSH_CMD} find backups
}

function download {
  NAME="${1}"
  REMOTE_PATH=$(${SSH_CMD} find backups -name "${NAME}")
  ${SSH_CMD} dd if=${REMOTE_PATH} bs=1M | dd of="/tmp/${NAME}"
}
