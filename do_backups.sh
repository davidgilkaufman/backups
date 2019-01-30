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
    echo "Found remote hash file for ${NAME}.gpg in ${REMOTE_DIR}"
    $SSH_CMD ln "${REMOTE_DIR}/${NAME}.gpg" "${DEST_DIR}/${NAME}.gpg"
    echo
  else
    SIZE=$(du --apparent-size -sh "${BDIR}")
    echo "Backing up ~${SIZE} bytes for to ${NAME}.gpg"
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

echo "Running prechecks"
EXPECTED_DOC_DIRS=(
  "/home/david/Documents/Anki"
  "/home/david/Documents/archive"
  "/home/david/Documents/blair"
  "/home/david/Documents/books"
  "/home/david/Documents/code"
  "/home/david/Documents/coursera"
  "/home/david/Documents/doorcomics"
  "/home/david/Documents/jobs"
  "/home/david/Documents/journal"
  "/home/david/Documents/misc"
  "/home/david/Documents/mit"
  "/home/david/Documents/MuseScore2"
  "/home/david/Documents/music"
  "/home/david/Documents/notes"
  "/home/david/Documents/passwords"
  "/home/david/Documents/photos"
  "/home/david/Documents/projects"
  "/home/david/Documents/renting_information"
  "/home/david/Documents/sheet_music"
  "/home/david/Documents/tax_stuff"
)
DOC_DIRS=$(find '/home/david/Documents/' -mindepth 1 -maxdepth 1 -type d -not -name 'videos' | sort | tr "\n" " " | sed 's/ *$//')
if [ "${DOC_DIRS}" != "${EXPECTED_DOC_DIRS[*]}" ]; then
  echo "Mismatched doc dirs:"
  echo "Expected: ${EXPECTED_DOC_DIRS[*]}"
  echo "Actual  : ${DOC_DIRS}"
  exit 1
fi

# Create destination directory for this backup, archiving an old directory of the same name if relevant
echo "Setup backup environment"
DEST_EXISTS=$($SSH_CMD ls -d "${DEST_DIR}" 2>/dev/null || :)
DEST_BAK_EXISTS=$($SSH_CMD ls -d "${DEST_DIR_BAK}" 2>/dev/null || :)
if [ -n "$DEST_EXISTS" ]; then
  if [ -z "$DEST_BAK_EXISTS" ]; then
    echo "Backing up backup directory of the same name"
    $SSH_CMD mv "$DEST_DIR" "$DEST_DIR_BAK"
  else
    echo "Backup-backup already exists; cleaning the backup directory"
    $SSH_CMD rm -rf "${DEST_DIR}"
  fi
fi
${SSH_CMD} mkdir -p "${DEST_DIR}"
echo

QUOTA_BEGIN=$($SSH_CMD quota)

# Back up all of Documents except for videos
for DOC_DIR in ${DOC_DIRS}
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
echo "Deleting old backups"
QUOTA_MAX=$($SSH_CMD quota)
$SSH_CMD find backups -mindepth 1 -maxdepth 1 -not -name "${DATE}" -exec rm -rf "{}" "\;"

QUOTA_END=$($SSH_CMD quota)

echo "Quotas begin/max/end:"
echo "${QUOTA_BEGIN}"
echo
echo "${QUOTA_MAX}"
echo
echo "${QUOTA_END}"

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
