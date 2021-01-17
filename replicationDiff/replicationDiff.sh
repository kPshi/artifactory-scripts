#!/bin/bash

set -o errexit
set -o pipefail
set -o nounset

stackdump() {
  local err=$?
  set +o xtrace
  local code="${1:-1}"
  echo 1>&2 "Error in ${PPID}->$$: ${BASH_SOURCE[1]}:${BASH_LINENO[0]}. '${BASH_COMMAND}', \$PWD: $PWD exited with status $err"

  if [ ${#FUNCNAME[@]} -gt 2 ]
  then
    echo 1>&2 "Call tree:"
    for ((i=1;i<${#FUNCNAME[@]}-1;i++))
    do
      echo 1>&2 " $i: ${BASH_SOURCE[$i+1]}:${BASH_LINENO[$i]} ${FUNCNAME[$i]}(...)"
    done
  fi
}
trap stackdump ERR

die() {
  echo
  [ "${*:-}" ] && cat <<<"$*" || cat
  echo "$*"
  echo
  exit 1
}

handle_http_status() {
  local -i code="$1"; shift
  local which="$1"; shift

  case "${code}" in
    200)
      return
      ;;
    401)
      die "Request failed with HTTP ${status_code}. Please check the provided username (-${which}_adminuser) and password (-${which}_password) for the Target Artifactory"
      ;;
    *)
      die "Request failed with HTTP ${status_code}. Please check the Target Artifactory URL (-${which}_art) and Target Repository (-${which}_repo) make sure its correct."
  esac
}

if [ "$#" = 0 ] ; then
  help_wanted=1
fi

args="$(getopt \
          --name "$(basename "$0")" \
          --alternative \
          --options 'h' \
          --longoptions source_adminuser:,target_adminuser:,source_art:,target_art:,source_repo:,target_repo:,source_password:,target_password:,download_missingfiles:,help \
          -- \
          "$@"
      )"
eval set -- "${args}"

while [ "$1" != -- ] ; do
  case "$1" in
    --source_adminuser)
      source_adminuser=$2
      shift
      ;;
    --target_adminuser)
      target_adminuser=$2
      shift
      ;;
    --source_art)
      source_art=$2
      shift
      ;;
    --target_art)
      target_art=$2
      shift
      ;;
    --source_repo)
      source_repo=$2
      shift
      ;;
    --target_repo)
      target_repo=$2
      shift
      ;;
    --source_password)
      source_password=$2
      shift
      ;;
    --target_password)
      target_password=$2
      shift
      ;;
    --download_missingfiles)
      download_missingfiles=$2
      shift
      ;;
    --help|-h)
      help_wanted=1
      ;;
    *)
      die "$1 is not a recognized flag!"
      ;;
  esac
  shift
done
shift

if [ $# != 0 ] ; then
  die "Extra parameters: $*"
fi

if [ "${help_wanted:-}" ] ; then
  die <<-END
Syntax: $(basename "$0") <options>
Where options are
  --source_adminuser <name>       username to authenticate with the source
  --source_art <url>              base URL of the source artifactory
  --source_repo <name>            which source repo to compare
  --source_password <password>    password fpr the source Artifactory
  --target_adminuser <name>       username to authenticate with the target
  --target_art <url>              base URL of the target artifactory
  --target_repo <name>            which target repo to compare
  --target_password <password>    password fpr the target Artifactory
  --download_missingfiles=[yn]    download files missing in the target repository
  --help|-h                       show this help
END
fi

if [ "${source_art:-}" = "" ] ; then
  echo "Enter your source Artifactory URL: "
  read source_art
fi

if [ "${target_art:-}" = "" ] ; then
  echo "Enter your target Artifactory URL: "
  read target_art
fi

if [ "${source_repo:-}" = "" ] ; then
  echo "Enter your source repository name: "
  read source_repo
fi

if [ "${target_repo:-}" = "" ] ; then
  echo "Enter your target repository name: "
  read target_repo
fi

if [ "${source_adminuser:-}" = "" ] ; then
  echo "Enter admin username for source Artifactory: "
  read source_adminuser
fi

if [ "${source_password:-}" = "" ] ; then
  echo "Password for source Artifactory: "
  read -s source_password
fi

if [ "${target_adminuser:-}" = "" ] ; then
  echo "Enter admin username for target Artifactory: "
  read target_adminuser
fi

if [ "${target_password:-}" = "" ] ; then
  echo "Password for target Artifactory: "
  read -s target_password
fi

source_art="${source_art%/}"
target_art="${target_art%/}"


trap 'rm source.list target.list diff_output.txt cleanpaths.txt' EXIT

status_code="$(curl --request GET --user "${source_adminuser}:${source_password}" "${source_art}/api/storage/${source_repo}/?list&deep=1&listFolders=0&mdTimestamps=1&statsTimestamps=1&includeRootPath=1" --location --output source.list --write-out %{http_code} --silent 2>/dev/null ||:)"
handle_http_status "${status_code}" source

status_code="$(curl --request GET --user "${target_adminuser}:${target_password}" "${target_art}/api/storage/${target_repo}/?list&deep=1&listFolders=0&mdTimestamps=1&statsTimestamps=1&includeRootPath=1" --location --output target.list --write-out %{http_code} --silent 2>/dev/null ||:)"
handle_http_status "${status_code}" target

diff --new-line-format="" --unchanged-line-format="" source.list target.list > diff_output.txt
grep uri diff_output.txt | sed 's/[<>,]//g; /https/d; /http/d; s/ //g; s/[",]//g; s/uri://g' > cleanpaths.txt
awk -v prefix="${source_art}/${source_repo}" '{print prefix $0}' cleanpaths.txt > filepaths_uri.txt

if [ "${count_extensions}" ] ; then
  echo
  echo
  echo "Here is the count of files sorted according to the file extension that are present in the source repository and are missing in the target repository. Please note that if there are SHA files in these repositories which will have no extension, then the entire URL will be seen in the output. The SHA files will be seen for docker repositories whose layers are named as per their SHA value. "
  echo
  grep --extended-regexp ".*\.[a-zA-Z0-9]*$" filepaths_uri.txt | sed --expression 's/.*\(\.[a-zA-Z0-9]*\)$/\1/' filepaths_uri.txt | sort | uniq --count | sort -n
  sed '/maven-metadata.xml/d' filepaths_uri.txt |  sed '/Packages.bz2/d' | sed '/.*gemspec.rz$/d' |  sed '/Packages.gz/d' | sed '/Release/d' | sed '/.*json$/d' | sed '/Packages/d' | sed '/by-hash/d' | sed '/filelists.xml.gz/d' | sed '/other.xml.gz/d' | sed '/primary.xml.gz/d' | sed '/repomd.xml/d' | sed '/repomd.xml.asc/d' | sed '/repomd.xml.key/d' > filepaths_nometadatafiles.txt
  echo
fi


if [[ "${download_missingfiles,,:-}" =~ ^y(es)?$ ]] ; then
  mkdir replication_downloads
  cd replication_downloads
  cat ../filepaths_nometadatafiles.txt | xargs --max-args 1 curl --silent --show-error --location --remote-name --user "${source_adminuser}:${source_password}"
  echo "Downloading all the files that are present in Source repository and missing from the target repository to a folder '"replication_downloads"' in the current working directory"
fi

exit 0
