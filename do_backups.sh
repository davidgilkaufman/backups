#!/bin/bash

set -e

GPG_PASS_FILE='/tmp/backup_pass'
SSH_CMD="ssh rsyncnet"

DATE=$(date --iso)
BACKUPS_DIR="backups"
DEST_DIR="${BACKUPS_DIR}/${DATE}"
DEST_DIR_BAK="${DEST_DIR}.bak"

function tar_dir {
  BDIR="${1}"
  DIRNAME=$(dirname "${BDIR}")
  BASENAME=$(basename "${BDIR}")
  cd "${DIRNAME}"
  ionice -c idle tar -cf /dev/stdout "${BASENAME}" 2>/dev/null
}

function backup_dir {
  BDIR="${1}"
  BASENAME=$(basename "${BDIR}")
  NAME="${BASENAME}.tar"

  # Compute hash
  HASH=$(tar_dir "${BDIR}" | sha512sum | awk '{print $1}')
  HASH_FILE="${NAME}.${HASH}"

  # Search for hash file on backup server
  REMOTE_HASH_FILE=$($SSH_CMD find "${BACKUPS_DIR}" -name "${HASH_FILE}" | head -n1)
  if [ -n "${REMOTE_HASH_FILE}" ] ; then
    REMOTE_DIR=$(dirname "${REMOTE_HASH_FILE}")
    echo "Found remote hash file in ${REMOTE_DIR}"
    $SSH_CMD ln "${REMOTE_DIR}/${NAME}.gpg" "${DEST_DIR}/${NAME}.gpg"
  else
    tar_dir "${BDIR}" | backup_stdin "${NAME}"
  fi

  # Upload hash file
  $SSH_CMD touch "${DEST_DIR}/${HASH_FILE}"
}

function backup_stdin {
  DEST="${DEST_DIR}/${1}.gpg"
  echo "Backing up data to ${DEST}..."
  gpg --batch "--passphrase-file=${GPG_PASS_FILE}" --compress-algo=none --symmetric | $SSH_CMD dd "of=${DEST}" bs=1M status=progress
  # Decrypt: gpg -d --batch "--passphrase-file=${GPG_PASS_FILE}"
  echo "Backed up data to ${DEST}."
  echo
}

# Create destination directory for this backup, archiving an old directory of the same name if relevant
DEST_EXISTS=$($SSH_CMD ls -d "${DEST_DIR}" 2>/dev/null || :)
DEST_BAK_EXISTS=$($SSH_CMD ls -d "${DEST_DIR_BAK}" 2>/dev/null || :)
if [ -n "$DEST_EXISTS" ]; then
  if [ -z "$DEST_BAK_EXISTS" ]; then
    $SSH_CMD mv "$DEST_DIR" "$DEST_DIR_BAK"
  else
    $SSH_CMD rm -rf "${DEST_DIR}"
  fi
fi
${SSH_CMD} mkdir -p "${DEST_DIR}"

# Back up all of Documents except for videos
find '/home/david/Documents/' -mindepth 1 -maxdepth 1 -type d -not -name 'videos' -print0 \
| while read -r -d $'\0' DOC_DIR;
do
  backup_dir "${DOC_DIR}"
done

# Back up specific paths
backup_dir "/home/david/Documents/videos/special"
backup_dir "/home/david/Desktop"
backup_dir "/etc"

# Back up command outputs
tree /home/david/Documents/videos/findable | backup_stdin "cmd_videos_findable"
tree /home/david/Documents/videos/tmp      | backup_stdin "cmd_videos_tmp"

# Delete other/older backups
$SSH_CMD find backups -mindepth 1 -maxdepth 1 -not -name "${DATE}" -exec rm -rf "{}" "\;"

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
