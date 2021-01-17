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
      die "Request failed with HTTP ${status_code}. Please check the provided username (-${which}_adminuser) and password (-${which}_password) for the ${which} Artifactory"
      ;;
    *)
      die "Request failed with HTTP ${status_code}. Please check the ${which} Artifactory URL (-${which}_art) and Target Repository (-${which}_repo) make sure its correct."
  esac
}

if [ "$#" = 0 ] ; then
  help_wanted=1
fi

args="$(getopt \
          --name "$(basename "$0")" \
          --alternative \
          --options 'h' \
          --longoptions source_adminuser:,target_adminuser:,source_art:,target_art:,source_repo:,target_repo:,source_password:,target_password:,download_missingfiles::,count_extensions::,show_missing::,fail_on_missing::,help \
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
      if [[ "${2,,:-yes}" =~ ^y(es)?$ ]] ; then
        download_missingfiles=1
      else
        unset download_missingfiles
      fi
      shift
      ;;
    --count_extensions)
      if [[ "${2,,:-yes}" =~ ^y(es)?$ ]] ; then
        count_extensions=1
      else
        unset count_extensions
      fi
      shift
      ;;
    --show_missing)
      if [[ "${2,,:-yes}" =~ ^y(es)?$ ]] ; then
        show_missing=1
      else
        unset show_missing
      fi
      shift
      ;;
    --fail_on_missing)
      if [[ "${2,,:-yes}" =~ ^y(es)?$ ]] ; then
        fail_on_missing=1
      else
        unset fail_on_missing
      fi
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
  --download_missingfiles[=<yn>]  download files missing in the target repository
  --count_extensions[=<yn>]i      count grouped by file extension
  --show_missing[=<yn>]           show missing files
  --fail_on_missing[=<yn>]        fail with exit code if some files are missing
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


tempdir="$(mktemp --directory)"
trap 'rm -rf -- "${tempdir}"' EXIT
cd "${tempdir}"

status_code="$(curl --request GET --user "${source_adminuser}:${source_password}" "${source_art}/api/storage/${source_repo}/?list&deep=1&listFolders=0&mdTimestamps=1&statsTimestamps=1&includeRootPath=1" --location --output source.json --write-out %{http_code} --silent 2>/dev/null ||:)"
handle_http_status "${status_code}" source

status_code="$(curl --request GET --user "${target_adminuser}:${target_password}" "${target_art}/api/storage/${target_repo}/?list&deep=1&listFolders=0&mdTimestamps=1&statsTimestamps=1&includeRootPath=1" --location --output target.json --write-out %{http_code} --silent 2>/dev/null ||:)"
handle_http_status "${status_code}" target

for json in source.json target.json ; do
  declare -i count
  count="$(jq '.files | length' "${json}")"
  for (( i=0 ; $i < $count ; i+=1 )) ; do
    jq -r '.files['$i'].sha2 + " " + .files['$i'].uri' "${json}"
  done | grep -v '^ */$' | sed '
    /maven-metadata.xml/d;
    /Packages.bz2/d;
    /.*gemspec.rz$/d;
    /Packages.gz/d;
    /Release/d;
    /.*json$/d;
    /Packages/d;
    /by-hash/d;
    /filelists.xml.gz/d;
    /other.xml.gz/d;
    /primary.xml.gz/d;
    /repomd.xml/d;
    /repomd.xml.asc/d;
    /repomd.xml.key/d;
    /specs.4.8.gz/d;
  ' | sort > "${json%.json}_files.sha2_uri" ||:
  echo "$(wc --lines < "${json%.json}_files.sha2_uri") ${json%.json} files."
done

diff --new-line-format="" --unchanged-line-format="" source_files.sha2_uri target_files.sha2_uri > diff.sha2_uri ||:

declare -i count_missing="$(wc --lines < diff.sha2_uri)"
echo "${count_missing} missing or changed."

if [ "${count_extensions:-}" ] ; then
  echo
  echo
  echo "Here is the count of files sorted according to the file extension that are present in the source repository and are missing in the target repository. Please note that if there are SHA files in these repositories which will have no extension, then the entire URL will be seen in the output. The SHA files will be seen for docker repositories whose layers are named as per their SHA value. "
  echo
  grep --extended-regexp ".*\.[a-zA-Z0-9]*$" diff.sha2_uri | sed --expression 's/.*\(\.[a-zA-Z0-9]*\)$/\1/' | sort | uniq --count | sort -n
  echo
fi


if [ "${download_missingfiles:-}" ] ; then
  while read _ uri ; do
    (
      mkdir -p replication_downloads/"${source_repo}"
      cd replication_downloads/"${source_repo}"
      curl --silent --show-error --location --remote-name --user "${source_adminuser}:${source_password}" "${source_art}/${source_repo}/${uri}"
    )
  done < diff.sha2_uri
  mv replication_downloads $OLDPWD/replication_downloads
  echo "Downloaded all the files that are present in Source repository and missing from the target repository to a folder 'replication_downloads/${source_repo}' in the current working directory"
fi

if [ "${show_missing:-}" ] ; then
  while read _ uri ; do
    if grep -Fq " ${uri}" target_files.sha2_uri ; then
      echo "${source_art}/${source_repo}/${uri##/}   !=    ${target_art}/${target_repo}/${uri##/}"
    else
      echo "${target_art}/${target_repo}/${uri##/} MISSING"
    fi
  done < diff.sha2_uri
fi

if [ "${count_missing}" = 0 ] ; then
  echo Ok
else
  echo Not Ok
  if [ "${fail_on_missing:-}" ] ; then
    exit 1
  fi
fi

