#!/bin/bash
set -e

# Use root home folder
SSH_DIR="/root/.ssh"
SSH_KEY="${SSH_DIR}/docker"
KNOWN_HOSTS="${SSH_DIR}/known_hosts"
ENV_FILE_PATH="/root/.env"

login() {
  echo "${PASSWORD}" | docker login "${REGISTRY}" -u "${USERNAME}" --password-stdin
}

configure_ssh() {
  mkdir -p "${SSH_DIR}"
  printf '%s' "UserKnownHostsFile=${KNOWN_HOSTS}" >> "${SSH_DIR}/config"
  chmod 600 "${SSH_DIR}/config"
}

configure_ssh_key() {
  echo "---- CONFIGURING PRIVATE KEY ------"
  printf '%s' "$REMOTE_PRIVATE_KEY" > "${SSH_KEY}"
  lastLine=$(tail -n 1 "${SSH_KEY}")
  if [ "${lastLine}" != "" ]; then
    printf '\n' >> "${SSH_KEY}";
  fi
  chmod 600 "${SSH_KEY}"
  eval "$(ssh-agent)"
  ssh-add "${SSH_KEY}"
  echo "-----------------------------------"
}

configure_env_file() {
  printf '%s' "$ENV_FILE" > "${ENV_FILE_PATH}"
  env_file_len=$(grep -v '^#' ${ENV_FILE_PATH}|grep -v '^$' -c)
  if [[ $env_file_len -gt 0 ]]; then
    echo "Environment Variables: Additional values"
    if [ "${DEBUG}" != "0" ]; then
      echo "Environment vars before: $(env|wc -l)"
    fi
    # shellcheck disable=SC2046
    export $(grep -v '^#' ${ENV_FILE_PATH} | grep -v '^$' | xargs -d '\n')
    if [ "${DEBUG}" != "0" ]; then
      echo "Environment vars after: $(env|wc -l)"
    fi
  fi
}

configure_ssh_jumpbox() {
  echo "---- CONFIGURING JUMPBOX -----"
  ssh-keyscan -p "${REMOTE_PORT}" "${REMOTE_JUMPBOX}" >> "${KNOWN_HOSTS}"
  ssh "${REMOTE_USER}"@"${REMOTE_JUMPBOX}" ssh-keyscan -p "${REMOTE_PORT}" "${REMOTE_HOST}" >> "${KNOWN_HOSTS}"
  printf "Host %s\n    User %s\n\nHost %s\n    ProxyJump %s\n    User %s\n\n" "${REMOTE_JUMPBOX}" "${REMOTE_USER}" "${REMOTE_HOST}" "${REMOTE_JUMPBOX}" "${REMOTE_USER}" >> "${SSH_DIR}/config"
  cat ${SSH_DIR}/config
  echo "------------------------------"
}

configure_ssh_host() {
  if [ "${REMOTE_JUMPBOX}" = "" ]; then
    ssh-keyscan -p "${REMOTE_PORT}" "${REMOTE_HOST}" >> "${KNOWN_HOSTS}"
  fi
}

connect_ssh() {
  cmd="ssh"
  if [ "${SSH_VERBOSE}" != "" ]; then
    cmd="ssh ${SSH_VERBOSE}"
  fi
  user=$(${cmd} -p "${REMOTE_PORT}" "${REMOTE_USER}@${REMOTE_HOST}" whoami)
  if [ "${user}" != "${REMOTE_USER}" ]; then
    exit 1;
  fi
}

deploy() {
  docker stack deploy --with-registry-auth -c "${STACK_FILE}" "${STACK_NAME}"
}

check_deploy() {
  echo "Deploy: Checking status"
  /stack-wait.sh -t "${DEPLOY_TIMEOUT}" "${STACK_NAME}"
}

[ -z ${DEBUG+x} ] && export DEBUG="0"

# ADDITIONAL ENV VARIABLES
if [[ -z "${ENV_FILE}" ]]; then
  export ENV_FILE=""
else
  configure_env_file;
fi

# SET DEBUG
if [ "${DEBUG}" != "0" ]; then
  OUT=/dev/stdout;
  SSH_VERBOSE="-vvv"
  echo "Verbose logging"
else
  OUT=/dev/null;
  SSH_VERBOSE=""
fi

# PROCEED WITH LOGIN
if [ -z "${USERNAME+x}" ] || [ -z "${PASSWORD+x}" ]; then
  echo "Container Registry: No authentication provided"
else
  [ -z ${REGISTRY+x} ] && export REGISTRY=""
  if login > /dev/null 2>&1; then
    echo "Container Registry: Logged in ${REGISTRY} as ${USERNAME}"
  else
    echo "Container Registry: Login to ${REGISTRY} as ${USERNAME} failed"
    exit 1
  fi
fi

if [[ -z "${DEPLOY_TIMEOUT}" ]]; then
  export DEPLOY_TIMEOUT=600
fi

# CHECK REMOTE VARIABLES
if [[ -z "${REMOTE_HOST}" ]]; then
  echo "Input remote_host is required!"
  exit 1
fi
if [[ -z "${REMOTE_PORT}" ]]; then
  export REMOTE_PORT="22"
fi
if [[ -z "${REMOTE_USER}" ]]; then
  echo "Input remote_user is required!"
  exit 1
fi
if [[ -z "${REMOTE_PRIVATE_KEY}" ]]; then
  echo "Input private_key is required!"
  exit 1
fi
# CHECK STACK VARIABLES
if [[ -z "${STACK_FILE}" ]]; then
  echo "Input stack_file is required!"
  exit 1
else
  if [ ! -f "${STACK_FILE}" ]; then
    echo "${STACK_FILE} does not exist."
    exit 1
  fi
fi

if [[ -z "${STACK_NAME}" ]]; then
  echo "Input stack_name is required!"
  exit 1
fi

# Dump env
echo "--- ENVIRONMENT ---"
env
echo "-------------------"

# Make required files/directories
mkdir -p "${SSH_DIR}"
touch "${SSH_DIR}"/config
touch "${SSH_DIR}"/known_hosts
chmod 0600 "${SSH_DIR}"/known_hosts

if configure_ssh_key > $OUT 2>&1; then
  echo "SSH client: Added private key"
else
  echo "SSH client: Private key failed"
  exit 1
fi

# Configure SSH Jumpbox
if [ "${REMOTE_JUMPBOX}" != "" ]; then
  if configure_ssh_jumpbox > $OUT 2>&1; then
    echo "SSH Jumpbox: Configured"
  else
    echo "SSH Jumpbox: Configuration failed"
  fi
fi

# CONFIGURE SSH CLIENT
if configure_ssh > $OUT 2>&1; then
  echo "SSH client: Configured"
else
  echo "SSH client: Configuration failed"
  exit 1
fi


if configure_ssh_host > $OUT 2>&1; then
  echo "SSH remote: Keys added to ${KNOWN_HOSTS}"
  cat "${KNOWN_HOSTS}"
else
  echo "SSH remote: Server ${REMOTE_HOST} on port ${REMOTE_PORT} not available"
  exit 1
fi

if connect_ssh > $OUT; then
  echo "SSH connect: Success"
else
  echo "SSH connect: Failed to connect to remote server"
  exit 1
fi

export DOCKER_HOST="ssh://${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT}"

if deploy > $OUT; then
  echo "Deploy: Updated services"
else
  echo "Deploy: Failed to deploy ${STACK_NAME} from file ${STACK_FILE}"
  exit 1
fi

if check_deploy; then
  echo "Deploy: Completed"
else
  echo "Deploy: Failed"
  exit 1
fi
