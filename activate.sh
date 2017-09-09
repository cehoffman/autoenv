#!/usr/bin/env bash
AUTOENV_AUTH_FILE=~/.autoenv_authorized
if [ -z "$AUTOENV_ENV_FILENAME" ]; then
    AUTOENV_ENV_FILENAME=.env
fi
if [ -z "$AUTOENV_UNENV_FILENAME" ]; then
    AUTOENV_UNENV_FILENAME=.unenv
fi

if [[ -n "${ZSH_VERSION}" ]]
then __array_offset=0
else __array_offset=1
fi

autoenv_common_path() {
    if [ "${#}" -ne 2 ]; then
        return 2
    fi

    # Remove repeated slashes
    for param; do
        param="$(printf %s. "${1}" | tr -s "/")"
        set -- "$@" "${param%.}"
        shift
    done

    common_path="${1}"
    shift

    for param; do
        while case "${param%/}/" in "${common_path%/}/"*) false;; esac; do
            new_common_path="${common_path%/*}"
            if [ "${new_common_path}" = "${common_path}" ]; then
                return 1 # Dead end
            fi
            common_path="${new_common_path}"
        done
    done
    printf %s "${common_path}"
}

autoenv_init() {
  local _file _unfile _envfile _root _origIFS
  typeset -a _files _unfiles

  _origIFS="${IFS}"
  IFS="$(echo -en "\n\b")"

  _root=$(echo -n "${OLDPWD}" | sed -E "s:/+:/:g")
  while [ -n "$_root" ]; do
    if [ -e "${_root}/${AUTOENV_UNENV_FILENAME}" ]; then
      _unfiles=($_unfiles "${_root}/${AUTOENV_UNENV_FILENAME}")
    fi
    _root="${_root%/*}"
  done

  _unfile=${#_unfiles[@]}
  while (( _unfile > 0 )); do
    _envfile=${_unfiles[_unfile-__array_offset]}
    if [[ ! "$PWD" =~ "$(dirname ${_envfile})" ]] ; then
      autoenv_check_authz_and_run "${_envfile}"
    fi
    : $(( _unfile -= 1 ))
  done

  _root=$(echo -n "$PWD" | sed -E "s:/+:/:g")
  while [ -n "$_root" ]; do
    if [ -e "${_root}/${AUTOENV_ENV_FILENAME}" ]; then
      _files=($_files "${_root}/${AUTOENV_ENV_FILENAME}")
    fi
    _root="${_root%/*}"
  done

  local common=""
  # Force evaulation of env files  if OLDPWD == PWD, e.g. on a new shell at PWD
  if [ "${OLDPWD}" != "${PWD}" ]; then
    common="$(autoenv_common_path "${OLDPWD}" "${PWD}")"
  fi

  _file=${#_files[@]}
  while (( _file > 0 )); do
    _envfile=${_files[_file-__array_offset]}
    if (( ${#common} < ${#$(dirname "${_envfile}")} )); then
      autoenv_check_authz_and_run "${_envfile}"
    fi
    : $(( _file -= 1 ))
  done

  IFS="${_origIFS}"
}

autoenv_hashline() {
  local _envfile _hash
  _envfile="${1}"
  _hash=$(autoenv_shasum "${_envfile}" | \cut -d' ' -f 1)
  \printf '%s\n' "${_envfile}:${_hash}"
}

autoenv_check_authz() {
  local _envfile _hash
  _envfile="${1}"
  _hash=$(autoenv_hashline "${_envfile}")
  \touch -- "${AUTOENV_AUTH_FILE}"
  \grep -q "${_hash}" -- "${AUTOENV_AUTH_FILE}"
}

autoenv_check_authz_and_run() {
  local _envfile
  _envfile="${1}"
  if autoenv_check_authz "${_envfile}"; then
    autoenv_source "${_envfile}"
    \return 0
  fi
  if [ -n "${AUTOENV_ASSUME_YES}" ]; then # Don't ask for permission if "assume yes" is switched on
    autoenv_authorize_env "${_envfile}"
    autoenv_source "${_envfile}"
    \return 0
  fi
  if [ -z "${MC_SID}" ]; then # Make sure mc is not running
    \echo "autoenv:"
    \echo "autoenv: WARNING:"
    \printf '%s\n' "autoenv: This is the first time you are about to source ${_envfile}":
    \echo "autoenv:"
    \echo "autoenv:   --- (begin contents) ---------------------------------------"
    \cat -e "${_envfile}" | LC_ALL=C \sed 's/.*/autoenv:     &/'
    \echo "autoenv:"
    \echo "autoenv:   --- (end contents) -----------------------------------------"
    \echo "autoenv:"
    \printf "%s" "autoenv: Are you sure you want to allow this? (y/N) "
    \read answer
    if [ "${answer}" = "y" ] || [ "${answer}" = "Y" ]; then
      autoenv_authorize_env "${_envfile}"
      autoenv_source "${_envfile}"
    fi
  fi
}

autoenv_deauthorize_env() {
  local _envfile _noclobber
  _envfile="${1}"
  \cp -- "${AUTOENV_AUTH_FILE}" "${AUTOENV_AUTH_FILE}.tmp"
  _noclobber="$(set +o | \grep noclobber)"
  set +C
  \grep -Gv "${_envfile}:" -- "${AUTOENV_AUTH_FILE}.tmp" > "${AUTOENV_AUTH_FILE}"
  \eval "${_noclobber}"
  \rm -- "${AUTOENV_AUTH_FILE}.tmp" 2>/dev/null || :
}

autoenv_authorize_env() {
  local _envfile
  _envfile="${1}"
  autoenv_deauthorize_env "${_envfile}"
  autoenv_hashline "${_envfile}" >> "${AUTOENV_AUTH_FILE}"
}

autoenv_source() {
  local _allexport _pushdignoredups
  _allexport=$(set +o | \grep allexport)
  _pushdignoredups=$(set +o | \grep pushdignoredups)
  set -o allexport
  [ -n "${ZSH_VERSION}" ] && set +o pushdignoredups
  AUTOENV_CUR_FILE="${1}"
  AUTOENV_CUR_DIR="$(dirname "${1}")"
  [ -n "${ZSH_VERSION}" ] && \pushd -q $(dirname "${1}")
  \source "${1}"
  [ "$(\dirs -v | wc -l)" -gt 1 ] && \popd -q
  \eval "${_allexport};${_pushdignoredups}"
  \unset AUTOENV_CUR_FILE AUTOENV_CUR_DIR
}

autoenv_cd() {
  \command -v chdir >/dev/null 2>&1 && \chdir "${@}" || builtin cd "${@}"
  if [ "${?}" -eq 0 ]; then
    autoenv_init
    \return 0
  else
    \return "${?}"
  fi
}

enable_autoenv() {
  if [ -z "${ZSH_VERSION}" ]; then
    cd() {
      autoenv_cd "$@"
    }
  else
    chpwd_functions=( autoenv_init $chpwd_functions )
  fi

  cd .
}

# Probe to see if we have access to a shasum command, otherwise disable autoenv
if command -v gsha1sum 2>/dev/null >&2 ; then
  autoenv_shasum() {
    gsha1sum "${@}"
  }
  enable_autoenv
elif command -v sha1sum 2>/dev/null >&2; then
  autoenv_shasum() {
    sha1sum "${@}"
  }
  enable_autoenv
elif command -v shasum 2>/dev/null >&2; then
  autoenv_shasum() {
    shasum "${@}"
  }
  enable_autoenv
else
  \echo "autoenv: can not locate a compatible shasum binary; not enabling"
fi
