#!/bin/bash
#
# arch-bootstrap: Bootstrap a base Arch Linux system.
#
# Dependencies: coreutils, wget, sed, gawk, tar, gzip, chroot, xz.
# Bug tracker: http://code.google.com/p/tokland/issues
# Contact: Arnau Sanchez <tokland@gmail.com>
# Contributions:
#  Steven Armstrong <steven-aur at armstrong.cc>
#     update to work with arch key signing
#
# Install:
#
#   $ sudo install -m 755 arch-bootstrap.sh /usr/local/bin/arch-bootstrap
#
# Some examples:
#
#   $ sudo arch-bootstrap destination
#   $ sudo arch-bootstrap -a x86_64 -r "ftp://ftp.archlinux.org" destination-x86_64 
#
# And then you can chroot to the destination directory (default user: root/root):
#
#   $ sudo chroot destination

set -e -o pipefail -u

# Output to standard error
stderr() { echo "$@" >&2; }

# Output debug message to standard error
debug() { stderr "--- $@"; }

# Extract href attribute from HTML link
extract_href() { sed -n '/<a / s/^.*<a [^>]*href="\([^\"]*\)".*$/\1/p'; }

# Simple wrapper around wget
fetch() { wget -c --passive-ftp --quiet "$@"; }

# Packages needed by pacman (see get-pacman-dependencies.sh)
PACMAN_PACKAGES=(
  acl archlinux-keyring attr bzip2 curl expat glibc gpgme libarchive
  libassuan libgpg-error libssh2 lzo2 openssl pacman pacman-mirrorlist xz zlib
)
BASIC_PACKAGES=("${PACMAN_PACKAGES[@]}" filesystem)
# pacman-key/bash: glibc ncurses readline
BASIC_PACKAGES+=(bash ncurses readline coreutils)
# gpg: bzip2 glibc libassuan libgcrypt libgpg-error ncurses readline zlib
BASIC_PACKAGES+=(gnupg libgcrypt)
EXTRA_PACKAGES=(grep gawk file tar systemd)
COMMUNITY_PACKAGES=(haveged)

# allow PACKDIR to be set from the outside
: ${PACKDIR:='arch-bootstrap'}
DEFAULT_REPO_URL="http://mirrors.kernel.org/archlinux"
DEFAULT_ARCH=i686

configure_pacman() {
  local DEST=$1; local ARCH=$2
  cp "/etc/resolv.conf" "$DEST/etc/resolv.conf"
  [ -d "$DEST/etc/pacman.d" ] || mkdir -m 0755 -p "$DEST/etc/pacman.d"
  echo "Server = $REPO_URL/\$repo/os/$ARCH" >> "$DEST/etc/pacman.d/mirrorlist"
}

minimal_configuration() {
  local DEST=$1
  test -d "$DEST/dev" || mkdir -m 0755 "$DEST/dev"
  echo "root:x:0:0:root:/root:/bin/bash" > "$DEST/etc/passwd"
  # give root a home
  test -d "$DEST/root" || mkdir -m 0750 "$DEST/root"
  # create root user (password: root)
  echo 'root:$1$GT9AUpJe$oXANVIjIzcnmOpY07iaGi/:14657::::::' > "$DEST/etc/shadow"
  touch "$DEST/etc/group"
  echo "bootstrap" > "$DEST/etc/hostname"
  test -e "$DEST/etc/mtab" || echo "rootfs / rootfs rw 0 0" > "$DEST/etc/mtab"
  test -e "$DEST/dev/null" || mknod -m 0666 "$DEST/dev/null" c 1 3
  test -e "$DEST/dev/random" || mknod -m 0644 "$DEST/dev/random" c 1 8
  test -e "$DEST/dev/urandom" || mknod -m 0644 "$DEST/dev/urandom" c 1 9
  sed -i "s/^[[:space:]]*\(CheckSpace\)/# \1/" "$DEST/etc/pacman.conf"
}

check_compressed_integrity() {
  local FILEPATH=$1
  case "$FILEPATH" in
    *.gz) gunzip -t "$FILEPATH";;
    *.xz) xz -t "$FILEPATH";;
    *) debug "Error: unknown package format: $FILEPATH"
       return 1;;
  esac
}

uncompress() {
  local FILEPATH=$1; local DEST=$2
  case "$FILEPATH" in
    *.gz) tar xzf "$FILEPATH" -C "$DEST";;
    *.xz) xz -dc "$FILEPATH" | tar x -C "$DEST";;
    *) debug "Error: unknown package format: $FILEPATH"
       return 1;;
  esac
}  

get_package_list() {
   local _url _list_file _list
   # Force trailing '/' needed by FTP servers.
   _url="${1%/}/"
   _list_file="$2"
   if ! test -s "$_list_file"; then 
     debug "fetch packages list: $_url"
     fetch -O "$_list_file" "$_url" ||
       { debug "Error: cannot fetch packages list: $_url"; exit 1; }
   fi

   debug "packages HTML index: $_list_file"
   _list=$(< "$_list_file" extract_href | awk -F"/" '{print $NF}' | sort -rn)
   test "$_list" || 
     { debug "Error processing list file: $_list_file"; exit 1; }
   echo "$_list"
}

install_packages() {
   local _repo _packages _url _list_file _list _file _filepath _package
   _repo="$1"; shift
   # Convert to array
   _packages=( $@ )
   _url="${REPO_URL%/}/${_repo%/}"
   _list_file="$PACKDIR/${_repo//\//_}-index.html"
   _list=$(get_package_list "$_url" "$_list_file")
   for _package in ${_packages[*]}; do
     debug "installing package: $_package"
     _file=$(echo "$_list" | grep -m1 "^$_package-[[:digit:]].*\(\.gz\|\.xz\)$" || true)
     if [ -z "$_file" ]; then
       debug "Error: cannot find package: $_package"
       exit 1
     fi
     _filepath="$PACKDIR/$_file"
     if ! test -e "$_filepath" || ! check_compressed_integrity "$_filepath" || true; then
       debug "  downloading: $_url/$_file"
       debug "  -> $_filepath"
       fetch -O "$_filepath" "$_url/$_file"
     fi
     debug "  installing: $_filepath"
     uncompress "$_filepath" "$DEST"
   done
}

populate_pacman_keyring() {
  local bin_dir relative_bin_dir
  # create /var/run for haveged to write it's pid
  [ -d "$DEST/var/run" ] || mkdir -p "$DEST/var/run"
  # start haveged inside chroot
  LC_ALL=C chroot "$DEST" /usr/sbin/haveged -w 1024 -v 1
  debug "initializing pacman keyring"
  LC_ALL=C chroot "$DEST" /usr/bin/pacman-key --init

  # inject our own gpg into the PATH so we can run it in batch mode without changing /usr/bin/pacman-key
  [ -d "$DEST/tmp" ] || mkdir -m 1777 "$DEST/tmp"
  bin_dir="$(mktemp -d --tmpdir="$DEST/tmp" "${0##*/}.XXXXXXXXXX")"
  cat > "$bin_dir/gpg" << DONE
#!/bin/sh
/usr/bin/gpg --yes --batch --no-tty \$@
DONE
  chmod +x "$bin_dir/gpg"
  debug "populating pacman keyring"
  relative_bin_dir="${bin_dir#$DEST}"
  LC_ALL=C chroot "$DEST" sh -c "export PATH=\"$relative_bin_dir:\$PATH\"; /usr/bin/pacman-key --populate archlinux"
  rm -rf "$bin_dir"

  # kill haveged from outside chroot
  kill "$(cat "$DEST/var/run/haveged.pid")"
  rm -rf "$DEST/var/run"
}

usage() {
  stderr "Usage: $(basename "$0") [-a i686 | x86_64] [-r REPO_URL] DEST"
}

### Main
main() {
  test $# -eq 0 && set -- "-h"
  local ARCH=$DEFAULT_ARCH;
  local REPO_URL=$DEFAULT_REPO_URL
  while getopts "a:r:h" ARG; do
    case "$ARG" in
      a) ARCH=$OPTARG;;
      r) REPO_URL=$OPTARG;;
      *) usage; exit 1;;
    esac
  done
  shift $(($OPTIND-1))
  test $# -eq 1 || { usage; exit 1; }
  local DEST=$1   

  CORE_REPO="core/os/$ARCH"
  COMMUNITY_REPO="community/os/$ARCH"
  debug "core repository: $CORE_REPO"
  debug "community repository: $COMMUNITY_REPO"
  mkdir -p "$PACKDIR"
  debug "package directory created: $PACKDIR"
  mkdir -p "$DEST"
  debug "destination directory created: $DEST"

  debug "core packages: ${BASIC_PACKAGES[*]}"
  install_packages "$CORE_REPO" "${BASIC_PACKAGES[*]}"
  debug "community packages: ${COMMUNITY_PACKAGES[*]}"
  install_packages "$COMMUNITY_REPO" "${COMMUNITY_PACKAGES[*]}"

  # some packages leave files in /, so cleanup
  rm -f "$DEST/{.INSTALL,.PKGINFO}"

  debug "configure DNS and pacman"
  configure_pacman "$DEST" "$ARCH"

  minimal_configuration "$DEST"

  populate_pacman_keyring "$DEST"

  debug "re-install basic packages and install extra packages: ${EXTRA_PACKAGES[*]}"
  LC_ALL=C chroot "$DEST" /usr/bin/pacman --noconfirm --arch $ARCH \
    -Sy --force ${BASIC_PACKAGES[*]} ${EXTRA_PACKAGES[*]}

  # Pacman must be re-configured
  configure_pacman "$DEST" "$ARCH"

  echo "Done! you can now chroot to the bootstrapped system."
}

main "$@"
