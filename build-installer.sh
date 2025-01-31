#!/usr/bin/env bash
set -eo pipefail

BUILDNAME="${1}"
GITREPO="${2}"
GITREF="${3}"

declare -A DEPS=(
  [convert]=Imagemagick
  [curl]=curl
  [envsubst]=gettext
  [git]=git
  [inkscape]=inkscape
  [jq]=jq
  [makensis]=NSIS
  [pip]=pip
  [pynsist]=pynsist
  [unzip]=unzip
)

WHEELS_IGNORE=(
  setuptools
)

PIP_ARGS=(
  --isolated
  --disable-pip-version-check
)

GIT_FETCHDEPTH=300

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || dirname "$(readlink -f "${0}")")
CONFIG="${ROOT}/config.json"
DIR_CACHE="${ROOT}/cache"
DIR_DIST="${ROOT}/dist"
DIR_FILES="${ROOT}/files"


# ----


SELF=$(basename "$(readlink -f "${0}")")
log() {
  echo "[${SELF}] ${@}"
}
err() {
  log >&2 "${@}"
  exit 1
}

[[ "${CI}" ]] || [[ "${VIRTUAL_ENV}" ]] || err "Can only be built in a virtual environment"

for dep in "${!DEPS[@]}"; do
  command -v "${dep}" 2>&1 >/dev/null || err "${DEPS["${dep}"]} is required to build the installer. Aborting."
done

[[ -f "${CONFIG}" ]] \
  || err "Missing config file: ${CONFIG}"
CONFIGJSON=$(cat "${CONFIG}")

[[ -n "${BUILDNAME}" ]] \
  && jq -e ".builds[\"${BUILDNAME}\"]" 2>&1 >/dev/null <<< "${CONFIGJSON}" \
  || err "Invalid build name"

read -r appname apprel \
  < <(jq -r '.app | "\(.name) \(.rel)"' <<< "${CONFIGJSON}")
read -r gitrepo gitref \
  < <(jq -r '.git | "\(.repo) \(.ref)"' <<< "${CONFIGJSON}")
read -r implementation pythonversion platform \
  < <(jq -r ".builds[\"${BUILDNAME}\"] | \"\(.implementation) \(.pythonversion) \(.platform)\"" <<< "${CONFIGJSON}")
read -r pythonversionfull pythonfilename pythonurl pythonsha256 \
  < <(jq -r ".builds[\"${BUILDNAME}\"].pythonembed | \"\(.version) \(.filename) \(.url) \(.sha256)\"" <<< "${CONFIGJSON}")

gitrepo="${GITREPO:-${gitrepo}}"
gitref="${GITREF:-${gitref}}"


# ----


TEMP=$(mktemp -d) && trap "rm -rf '${TEMP}'" EXIT || exit 255

DIR_REPO="${TEMP}/source.git"
DIR_BUILD="${TEMP}/build"
DIR_ASSETS="${TEMP}/assets"
DIR_PKGS="${TEMP}/pkgs"
DIR_WHEELS="${TEMP}/wheels"

mkdir -p \
  "${DIR_CACHE}" \
  "${DIR_DIST}" \
  "${DIR_BUILD}" \
  "${DIR_ASSETS}" \
  "${DIR_WHEELS}"


get_sources() {
  log "Getting sources"
  git \
    -c advice.detachedHead=false \
    clone \
    --depth="${GIT_FETCHDEPTH}" \
    -b "${gitref}" \
    "${gitrepo}" \
    "${DIR_REPO}"

  log "Commit information"
  GIT_PAGER=cat git \
    -C "${DIR_REPO}" \
    log \
    -1 \
    --pretty=full
}

get_python() {
  local filepath="${DIR_CACHE}/${pythonfilename}"
  if ! [[ -f "${filepath}" ]]; then
    log "Downloading Python"
    curl -SLo "${filepath}" "${pythonurl}"
  fi
  log "Checking Python"
  sha256sum -c - <<< "${pythonsha256} ${filepath}"
}

get_assets() {
  local assetname
  while read -r assetname; do
    local filename url sha256
    read -r filename url sha256 \
      < <(jq -r ".assets[\"${assetname}\"] | \"\(.filename) \(.url) \(.sha256)\"" <<< "${CONFIGJSON}")
    if ! [[ -f "${DIR_CACHE}/${filename}" ]]; then
      log "Downloading asset: ${assetname}"
      curl -SLo "${DIR_CACHE}/${filename}" "${url}"
    fi
    log "Checking asset: ${assetname}"
    sha256sum -c - <<< "${sha256} ${DIR_CACHE}/${filename}"
  done < <(jq -r ".builds[\"${BUILDNAME}\"].assets[]" <<< "${CONFIGJSON}")
}

build_app() {
  log "Building app"
  pip install \
    "${PIP_ARGS[@]}" \
    --no-cache-dir \
    --platform="${platform}" \
    --python-version="${pythonversion}" \
    --implementation="${implementation}" \
    --no-deps \
    --target="${DIR_PKGS}" \
    --no-compile \
    --upgrade \
    "${DIR_REPO}"

  log "Removing unneeded dist files"
  ( set -x; rm -r "${DIR_PKGS}/bin" "${DIR_PKGS}"/*.dist-info/direct_url.json; )
  sed -i -E \
    -e '/^.+\.dist-info\/direct_url\.json,sha256=/d' \
    -e '/^\.\.\/\.\.\//d' \
    "${DIR_PKGS}"/*.dist-info/RECORD

  log "Creating icon"
  for size in 16 32 48 256; do
    # --without-gui and --export-png have been deprecated since Inkscape 1.0.0
    # Ubuntu 20.04 CI runner is using Inkscape 0.92.5
    inkscape \
      --without-gui \
      --export-png="${DIR_BUILD}/icon-${size}.png" \
      -w ${size} \
      -h ${size} \
      "${DIR_REPO}/icon.svg"
  done
  convert \
    "${DIR_BUILD}/icon-"{16,32,48,256}.png \
    "${DIR_BUILD}/icon.ico"
}

build_wheels() {
  log "Downloading wheels"
  pip download \
    "${PIP_ARGS[@]}" \
    --require-hashes \
    --only-binary=:all: \
    --platform="${platform}" \
    --python-version="${pythonversion}" \
    --implementation="${implementation}" \
    --dest="${DIR_WHEELS}" \
    --requirement=/dev/stdin \
    < <(jq -r ".builds[\"${BUILDNAME}\"].dependencies.wheels | to_entries[] | \"\(.key)==\(.value)\"" <<< "${CONFIGJSON}")

  log "Downloading and building sdists"
  pip wheel \
    "${PIP_ARGS[@]}" \
    --require-hashes \
    --no-binary=:all: \
    --wheel-dir="${DIR_WHEELS}" \
    --requirement=/dev/stdin \
    < <(jq -r ".builds[\"${BUILDNAME}\"].dependencies.sdists | to_entries[] | \"\(.key)==\(.value)\"" <<< "${CONFIGJSON}")

  log "Removing ignored wheels"
  ( shopt -s nullglob; set -x; cd "${DIR_WHEELS}" && rm -f -- ${WHEELS_IGNORE[@]/%/-*.whl}; )
}

prepare_python() {
  log "Preparing Python"
  local arch
  [[ "${platform}" == "win_amd64" ]] && arch="amd64" || arch="win32"
  install -v "${DIR_CACHE}/${pythonfilename}" "${DIR_BUILD}/python-${pythonversionfull}-embed-${arch}.zip"
}

prepare_assets() {
  log "Preparing assets"
  local assetname
  while read -r assetname; do
    log "Preparing asset: ${assetname}"
    local type filename sourcedir targetdir
    read -r type filename sourcedir targetdir \
      < <(jq -r ".assets[\"${assetname}\"] | \"\(.type) \(.filename) \(.sourcedir) \(.targetdir)\"" <<< "${CONFIGJSON}")
    case "${type}" in
      zip)
        mkdir -p "${DIR_ASSETS}/${assetname}"
        unzip "${DIR_CACHE}/${filename}" -d "${DIR_ASSETS}/${assetname}"
        sourcedir="${DIR_ASSETS}/${assetname}/${sourcedir}"
        ;;
      *)
        sourcedir="${DIR_CACHE}"
        ;;
    esac
    while read -r from to; do
      install -vDT "${sourcedir}/${from}" "${DIR_BUILD}/${targetdir}/${to}"
    done < <(jq -r ".assets[\"${assetname}\"].files[] | \"\(.from) \(.to)\"" <<< "${CONFIGJSON}")
  done < <(jq -r ".builds[\"${BUILDNAME}\"].assets[]" <<< "${CONFIGJSON}")
}

prepare_files() {
  log "Copying license file with file extension"
  install -v "${DIR_REPO}/LICENSE" "${DIR_BUILD}/LICENSE.txt"

  log "Copying config file"
  # don't use pynsist's Include.files option, as this always overwrites files,
  # which we don't want for the config file
  install -v "${DIR_FILES}/config" "${DIR_BUILD}/config"
}

prepare_installer() {
  log "Reading version string"
  local versionstring versionplain versionmeta vi_version installerversion

  versionstring="$(PYTHONPATH="${DIR_PKGS}" python -c "from importlib.metadata import version;print(version('${appname}'))")"
  versionplain="${versionstring%%+*}"
  versionmeta="${versionstring##*+}"
  distinfo="${DIR_PKGS}/${appname}-${versionstring}.dist-info"

  # Not a custom git reference (assume that only tagged releases are used as source)
  # Use plain version string with app release number and no abbreviated commit ID
  if [[ -z "${GITREF}" ]]; then
    vi_version="${versionplain}.0"
    installerversion="${versionplain}-${apprel}"

  # Custom ref -> tagged release (no build metadata in version string)
  # Add abbreviated commit ID to the plain version string to distinguish it from regular releases, set 0 as app release number
  elif [[ "${versionstring}" != *+* ]]; then
    local _commit="$(cd "${DIR_REPO}" && git -c core.abbrev=7 rev-parse --short HEAD)"
    vi_version="${versionplain}.0"
    installerversion="${versionplain}-0-g${_commit}"

  # Custom ref -> arbitrary untagged commit (version string includes build metadata)
  # Translate into correct format
  else
    vi_version="${versionplain}.${versionmeta%%.*}"
    installerversion="${versionplain}-${versionmeta/./-}"
  fi

  log "Preparing installer template"
  env -i \
    DIR_BUILD="${DIR_BUILD}" \
    VERSION="${installerversion}" \
    VI_VERSION="${vi_version}" \
    envsubst '$DIR_BUILD $VERSION $VI_VERSION' \
    < "${ROOT}/installer.nsi" \
    > "${DIR_BUILD}/installer.nsi"

  log "Preparing pynsist config"
  env -i \
    DIR_BUILD="${DIR_BUILD}" \
    DIR_WHEELS="${DIR_WHEELS}" \
    DIR_DISTINFO="${distinfo}" \
    VERSION="${installerversion}" \
    PYTHONVERSION="${pythonversionfull}" \
    BITNESS="$([[ "${platform}" == "win_amd64" ]] && echo 64 || echo 32)" \
    INSTALLER_NAME="${DIR_DIST}/${appname}-${installerversion}-${BUILDNAME}.exe" \
    NSI_TEMPLATE="installer.nsi" \
    envsubst '$DIR_BUILD $DIR_DISTINFO $DIR_WHEELS $VERSION $ENTRYPOINT $PYTHONVERSION $BITNESS $INSTALLER_NAME $NSI_TEMPLATE' \
    < "${ROOT}/installer.cfg" \
    > "${DIR_BUILD}/installer.cfg"
}

build_installer() {
  log "Building installer"
  PYTHONPATH="${DIR_PKGS}" PYNSIST_CACHE_DIR="${DIR_BUILD}" pynsist "${DIR_BUILD}/installer.cfg"
}


build() {
  log "Building ${BUILDNAME}, using git reference ${gitref}"
  get_sources
  get_python
  get_assets
  build_app
  build_wheels
  prepare_python
  prepare_assets
  prepare_files
  prepare_installer
  build_installer
  log "Success!"
}

build
