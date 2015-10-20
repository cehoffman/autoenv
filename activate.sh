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

autoenv_common_path()
{
    if [ $# -ne 2 ]
    then
        return 2
    fi

    # Remove repeated slashes
    for param
    do
        param="$(printf %s. "$1" | tr -s "/")"
        set -- "$@" "${param%.}"
        shift
    done

    common_path="$1"
    shift

    for param
    do
        while case "${param%/}/" in "${common_path%/}/"*) false;; esac; do
            new_common_path="${common_path%/*}"
            if [ "$new_common_path" = "$common_path" ]
            then
                return 1 # Dead end
            fi
            common_path="$new_common_path"
        done
    done
    printf %s "$common_path"
}

autoenv_init()
{
  defIFS=$IFS
  IFS=$(echo -en "\n\b")

  typeset target _file
  typeset -a _files _unfiles
  target=$1

  root="$OLDPWD"
  while [ -n "$root" ]; do
    if [ -e "${root}/${AUTOENV_UNENV_FILENAME}" ]; then
      _unfiles=($_files "${root}/${AUTOENV_UNENV_FILENAME}")
    fi
    root="${root%/*}"
  done

  _unfile=${#_unfiles[@]}
  while (( _unfile > 0 ))
  do
    envfile=${_unfiles[_unfile-__array_offset]}
    if [[ ! "$PWD" =~ "$(dirname $envfile)" ]] ; then
      autoenv_check_authz_and_run "$envfile"
    fi
    : $(( _unfile -= 1 ))
  done

  root="$PWD"
  while [ -n "$root" ]; do
    if [ -e "${root}/${AUTOENV_ENV_FILENAME}" ]; then
      _files=($_files "${root}/${AUTOENV_ENV_FILENAME}")
    fi
    root="${root%/*}"
  done

  local common=""
  # Force evaulation of env files  if OLDPWD == PWD, e.g. on a new shell at PWD
  if [ "$OLDPWD" != "$PWD" ]; then
    common="$(autoenv_common_path "$OLDPWD" "$PWD")"
  fi

  _file=${#_files[@]}
  while (( _file > 0 ))
  do
    envfile=${_files[_file-__array_offset]}
    if (( ${#common} < ${#$(dirname "$envfile")} )); then
      autoenv_check_authz_and_run "$envfile"
    fi
    : $(( _file -= 1 ))
  done

  IFS=$defIFS
}

autoenv_run() {
  typeset _file
  _file="$(realpath "$1")"
  autoenv_check_authz_and_run "${_file}"
}

autoenv_env() {
  builtin echo "autoenv:" "$@"
}

autoenv_printf() {
  builtin printf "autoenv: "
  builtin printf "$@"
}

autoenv_indent() {
  sed 's/.*/autoenv:     &/' $@
}

autoenv_hashline()
{
  typeset envfile hash
  envfile=$1
  if command -v shasum &> /dev/null
  then hash=$(shasum "$envfile" | cut -d' ' -f 1)
  else hash=$(sha1sum "$envfile" | cut -d' ' -f 1)
  fi
  echo "$envfile:$hash"
}

autoenv_check_authz()
{
  typeset envfile hash
  envfile=$1
  hash=$(autoenv_hashline "$envfile")
  touch $AUTOENV_AUTH_FILE
  \grep -Gq "$hash" $AUTOENV_AUTH_FILE
}

autoenv_check_authz_and_run()
{
  typeset envfile
  envfile=$1
  if autoenv_check_authz "$envfile"; then
    autoenv_source "$envfile"
    return 0
  fi
  if [[ -z $MC_SID ]]; then #make sure mc is not running
    autoenv_env
    autoenv_env "WARNING:"
    autoenv_env "This is the first time you are about to source $envfile":
    autoenv_env
    autoenv_env "    --- (begin contents) ---------------------------------------"
    autoenv_indent "$envfile"
    autoenv_env
    autoenv_env "    --- (end contents) -----------------------------------------"
    autoenv_env
    autoenv_printf "Are you sure you want to allow this? (y/N) "
    read answer
    if [[ "$answer" == "y" ]]; then
      autoenv_authorize_env "$envfile"
      autoenv_source "$envfile"
    fi
  fi
}

autoenv_deauthorize_env() {
  typeset envfile
  envfile=$1
  \cp "$AUTOENV_AUTH_FILE" "$AUTOENV_AUTH_FILE.tmp"
  \grep -Gv "$envfile:" "$AUTOENV_AUTH_FILE.tmp" > $AUTOENV_AUTH_FILE
}

autoenv_authorize_env() {
  typeset envfile
  envfile=$1
  autoenv_deauthorize_env "$envfile"
  autoenv_hashline "$envfile" >> $AUTOENV_AUTH_FILE
}

autoenv_source() {
  typeset allexport
  allexport=$(set +o | grep allexport)
  set -a
  [[ -z "$ZSH_VERSION" ]] || chpwd_functions=("${(@)chpwd_functions:#autoenv_init}")
  cd $(dirname "$1")
  source "$1"
  cd "$OLDPWD"
  [[ -z "$ZSH_VERSION" ]] || chpwd_functions=(autoenv_init $chpwd_functions)
  eval "$allexport"
}

autoenv_cd()
{
  if builtin cd "$@"
  then
    autoenv_init
    return 0
  else
    return $?
  fi
}

if [[ -z "$ZSH_VERSION" ]]; then
  cd() {
    autoenv_cd "$@"
  }
else
  chpwd_functions=( autoenv_init $chpwd_functions )
fi

cd .
