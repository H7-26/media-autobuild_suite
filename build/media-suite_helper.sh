#!/bin/bash

vcs_clone() {
    if [[ "$vcsType" = "svn" ]]; then
        svn checkout -r "$ref" "$vcsURL" "$vcsFolder"-svn
    else
        "$vcsType" clone "$vcsURL" "$vcsFolder-$vcsType"
    fi
}

vcs_update() {
    if [[ "$vcsType" = "svn" ]]; then
        oldHead=$(svnversion)
        svn update -r "$ref"
        newHead=$(svnversion)
    elif [[ "$vcsType" = "hg" ]]; then
        oldHead=$(hg id --id)
        hg pull
        hg update -C -r "$ref"
        newHead=$(hg id --id)
    elif [[ "$vcsType" = "git" ]]; then
        local unshallow=""
        [[ -f .git/shallow ]] && unshallow="--unshallow"
        [[ "$vcsURL" != "$(git config --get remote.origin.url)" ]] &&
            git remote set-url origin "$vcsURL"
        [[ "ab-suite" != "$(git rev-parse --abbrev-ref HEAD)" ]] && git reset -q --hard @{u}
        [[ "$(git config --get remote.origin.fetch)" = "+refs/heads/master:refs/remotes/origin/master" ]] &&
            git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
        git checkout -qf --no-track -B ab-suite "$ref"
        git fetch -qt $unshallow origin
        oldHead=$(git rev-parse HEAD)
        git checkout -qf --no-track -B ab-suite "$ref"
        newHead=$(git rev-parse HEAD)
    fi
}

vcs_log() {
    if [[ "$vcsType" = "git" ]]; then
        git log --no-merges --pretty="%ci %h %s" \
            --abbrev-commit "$oldHead".."$newHead" >> "$LOCALBUILDDIR"/newchangelog
    elif [[ "$vcsType" = "hg" ]]; then
        hg log --template "{date|localdate|isodatesec} {node|short} {desc|firstline}\n" \
            -r "reverse($oldHead:$newHead)" >> "$LOCALBUILDDIR"/newchangelog
    fi
}

# get source from VCS
# example:
#   do_vcs "url#branch|revision|tag|commit=NAME" "folder" "lib/libname.a"
do_vcs() {
    local vcsType="${1%::*}"
    local vcsURL="${1#*::}"
    [[ "$vcsType" = "$vcsURL" ]] && vcsType="git"
    local vcsBranch="${vcsURL#*#}"
    [[ "$vcsBranch" = "$vcsURL" ]] && vcsBranch=""
    local vcsFolder="$2"
    local vcsCheck="$3"
    local ref=""
    if [[ -n "$vcsBranch" ]]; then
        vcsURL="${vcsURL%#*}"
        case ${vcsBranch%%=*} in
            commit|tag|revision)
                ref=${vcsBranch##*=}
                ;;
            branch)
                ref=origin/${vcsBranch##*=}
                ;;
        esac
    else
        if [[ "$vcsType" = "git" ]]; then
            ref="origin/HEAD"
        elif [[ "$vcsType" = "hg" ]]; then
            ref="tip"
        elif [[ "$vcsType" = "svn" ]]; then
            ref="HEAD"
        fi
    fi
    compile="false"

    echo -ne "\033]0;compiling $vcsFolder $bits\007"
    if [ ! -d "$vcsFolder-$vcsType" ]; then
        vcs_clone
        if [[ -d "$vcsFolder-$vcsType" ]]; then
            cd "$vcsFolder-$vcsType"
            touch recently_updated
        else
            echo "$vcsFolder $vcsType seems to be down"
            echo "Try again later or <Enter> to continue"
            do_prompt "if you're sure nothing depends on it."
            return
        fi
    else
        cd "$vcsFolder-$vcsType"
    fi
    vcs_update
    if [[ "$oldHead" != "$newHead" ]]; then
        touch recently_updated
        rm -f build_successful{32,64}bit
        if [[ $build32 = "yes" && $build64 = "yes" ]] && [[ $bits = "64bit" ]]; then
            new_updates="yes"
            new_updates_packages="$new_updates_packages [$vcsFolder]"
        fi
        echo "$vcsFolder" >> "$LOCALBUILDDIR"/newchangelog
        vcs_log
        echo "" >> "$LOCALBUILDDIR"/newchangelog
        compile="true"
    elif [[ -f recently_updated && ! -f "build_successful$bits" ]] ||
         [[ -z "$vcsCheck" && ! -f "$LOCALDESTDIR/lib/pkgconfig/$vcsFolder.pc" ]] ||
         [[ ! -z "$vcsCheck" && ! -f "$LOCALDESTDIR/$vcsCheck" ]]; then
        compile="true"
    else
        echo -------------------------------------------------
        echo "$vcsFolder is already up to date"
        echo -------------------------------------------------
    fi
}

# get wget download
do_wget() {
    local url="$1"
    local archive="$2"
    local dirName="$3"
    if [[ -z $archive ]]; then
        # remove arguments and filepath
        archive=${url%%\?*}
        archive=${archive##*/}
    fi
    # accepted: zip, 7z, tar.gz, tar.bz2 and tar.xz
    local archive_type=$(expr $archive : '.\+\(tar\(\.\(gz\|bz2\|xz\)\)\?\|7z\|zip\)$')
    [[ -z "$dirName" ]] && dirName=$(expr $archive : '\(.\+\)\.\(tar\(\.\(gz\|bz2\|xz\)\)\?\|7z\|zip\)$')
    if [[ -d "$dirName" && $archive_type = tar* ]] &&
        { [[ $build32 = "yes" && ! -f "$dirName"/build_successful32bit ]] ||
          [[ $build64 = "yes" && ! -f "$dirName"/build_successful64bit ]]; }; then
        rm -rf $dirName
    fi
    local response_code=$(curl --retry 20 --retry-max-time 5 -L -k -f -w "%{response_code}" -o "$archive" "$url")
    if [[ $response_code = "200" || $response_code = "226" ]]; then
        case $archive_type in
        zip)
            unzip "$archive"
            [[ $deleteSource = "y" ]] && rm "$archive"
            ;;
        7z)
            7z x -o"$dirName" "$archive"
            [[ $deleteSource = "y" ]] && rm "$archive"
            ;;
        tar*)
            tar -xaf "$archive"
            [[ $deleteSource = "y" ]] && rm "$archive"
            cd "$dirName"
            ;;
        esac
    elif [[ $response_code -gt 400 ]]; then
        echo "Error $response_code while downloading $URL"
        echo "Try again later or <Enter> to continue"
        do_prompt "if you're sure nothing depends on it."
    fi
}

do_wget_sf() {
    local url="$1"
    shift 1
    local dir="${url:0:1}/${url:0:2}"
    do_wget "https://www.mirrorservice.org/sites/download.sourceforge.net/pub/sourceforge/${dir}/${url}" $@
}

# check if compiled file exist
do_checkIfExist() {
    local packetName=$(get_first_subdir)
    local fileName="$1"
    local fileExtension=${fileName##*.}
    local buildSuccess="n"

    if [[ "$fileExtension" = "a" ]] || [[ "$fileExtension" = "dll" ]]; then
        if [ -f "$LOCALDESTDIR/lib/$fileName" ]; then
            buildSuccess="y"
        fi
    else
        if [ -f "$LOCALDESTDIR/$fileName" ]; then
            buildSuccess="y"
        fi
    fi

    if [[ $buildSuccess = "y" ]]; then
        echo -
        echo -------------------------------------------------
        echo "Building of $packetName done..."
        echo -------------------------------------------------
        echo -
        if [[ -d "$LOCALBUILDDIR/$packetName" ]]; then
            touch $LOCALBUILDDIR/$packetName/build_successful$bits
        fi
    else
        if [[ -d "$LOCALBUILDDIR/$packetName" ]]; then
            rm -f $LOCALBUILDDIR/$packetName/build_successful$bits
        fi
        echo -------------------------------------------------
        echo "Building of $packetName failed..."
        echo "Delete the source folder under '$LOCALBUILDDIR' and start again."
        echo "If you're sure there are no dependencies <Enter> to continue building."
        do_prompt "Close this window if you wish to stop building."
    fi
}

do_pkgConfig() {
    local pkg=${1%% *}
    local version=$2
    [[ -z "$version" ]] && version="${1##*= }"
    [[ "$version" = "$1" ]] && version="" || version=" $version"
    echo -ne "\033]0;compiling $pkg $bits\007"
    local prefix=$(pkg-config --variable=prefix --silence-errors "$1")
    [[ ! -z "$prefix" ]] && prefix="$(cygpath -u "$prefix")"
    if [[ "$prefix" = "$LOCALDESTDIR" || "$prefix" = "/trunk${LOCALDESTDIR}" ]]; then
        echo -------------------------------------------------
        echo "${pkg}${version} is already compiled"
        echo -------------------------------------------------
        return 1
    fi
}

do_getFFmpegConfig() {
    [[ -z "$license" && -n "$1" ]] && local license="$1"
    configfile="$LOCALBUILDDIR"/ffmpeg_options.txt
    if [[ -f "$configfile" ]] && [[ $ffmpegChoice != "n" ]]; then
        FFMPEG_OPTS="$FFMPEG_BASE_OPTS $(cat "$configfile" | sed -e 's:\\::g' -e 's/#.*//')"
        echo "Imported FFmpeg options from ffmpeg_options.txt"
    elif [[ -f "/trunk/media-autobuild_suite.bat" ]] && [[ $ffmpegChoice != "y" ]]; then
        FFMPEG_DEFAULT_OPTS=$(sed -rne '/ffmpeg_options=/,/[^^]$/p' /trunk/media-autobuild_suite.bat | \
            sed -e 's/.*ffmpeg_options=//' -e 's/ ^//g' | tr '\n' ' ')
        FFMPEG_OPTS="$FFMPEG_BASE_OPTS $FFMPEG_DEFAULT_OPTS"
        echo "Imported default FFmpeg options from .bat"
    else
        FFMPEG_OPTS="$FFMPEG_BASE_OPTS $FFMPEG_DEFAULT_OPTS"
        echo "Using default FFmpeg options"
    fi

    if [[ $bits = "32bit" ]]; then
        arch=x86
    else
        arch=x86_64
    fi
    export arch

    # we set these accordingly for static or shared
    do_removeOption "--(en|dis)able-(shared|static)"

    # OK to use GnuTLS for rtmpdump if not nonfree since GnuTLS was built for rtmpdump anyway
    # If nonfree will use SChannel if neither openssl or gnutls are in the options
    if ! do_checkForOptions "--enable-openssl --enable-gnutls" &&
        do_checkForOptions "--enable-librtmp"; then
        [[ $license = gpl* ]] && do_addOption "--enable-gnutls" || do_addOption "--enable-openssl"
        do_removeOption "--enable-(gmp|gcrypt)"
    fi

    if do_checkForOptions "--enable-openssl" && [[ $license != gpl* ]]; then
        # prefer openssl if both are in options and not gpl
        do_removeOptions "--enable-gnutls"
    elif do_checkForOptions "--enable-openssl"; then
        # prefer gnutls if both are in options and gpl
        do_removeOption "--enable-openssl"
        do_addOption "--enable-gnutls"
    fi

    # handle WinXP-incompatible libs
    if [[ $xpcomp = "y" ]]; then
        do_removeOptions "--enable-libmfx --enable-decklink --enable-tesseract \
            --enable-opencl --enable-libcaca"
    fi
}

do_changeFFmpegConfig() {
    [[ -z "$license" && -n "$1" ]] && local license="$1"
    # if w32threads is disabled, pthreads is used and needs this cflag
    # decklink depends on pthreads
    if do_checkForOptions "--disable-w32threads --enable-pthreads --enable-decklink"; then
        do_removeOption "--enable-w32threads"
        do_addOptions "--disable-w32threads --extra-cflags=-DPTW32_STATIC_LIB \
            --extra-libs=-lpthread --extra-libs=-lwsock32"
    fi

    # add options for static kvazaar
    if do_checkForOptions "--enable-libkvazaar"; then
        do_addOption "--extra-cflags=-DKVZ_STATIC_LIB"
    fi

    # handle gpl libs
    local gpl="--enable-frei0r --enable-libcdio --enable-librubberband \
        --enable-libutvideo --enable-libvidstab --enable-libx264 --enable-libx265 \
        --enable-libxavs --enable-libxvid --enable-libzvbi"
    if [[ $license = gpl* || $license = nonfree ]] && do_checkForOptions "$gpl"; then
        do_addOption "--enable-gpl"
    else
        do_removeOptions "$gpl --enable-gpl"
    fi

    # handle (l)gplv3 libs
    local version3="--enable-libopencore-amrwb --enable-libopencore-amrnb \
        --enable-libvo-aacenc --enable-libvo-amrwbenc --enable-gmp"
    if [[ $license = *v3 || $license = nonfree ]] && do_checkForOptions "$version3"; then
        do_addOption "--enable-version3"
    else
        do_removeOptions "$version3 --enable-version3"
    fi

    # handle non-free libs
    local nonfree="--enable-nvenc --enable-libfaac"
    if [[ $license = "nonfree" ]] && do_checkForOptions "$nonfree"; then
        do_addOption "--enable-nonfree"
    else
        do_removeOptions "$nonfree --enable-nonfree"
    fi

    # handle gpl-incompatible libs
    local nonfreegpl="--enable-libfdk-aac --enable-openssl"
    if do_checkForOptions "$nonfreegpl"; then
        if [[ $license = "nonfree" ]]; then
            do_addOption "--enable-nonfree"
        elif [[ $license = gpl* ]]; then
            do_removeOptions "$nonfreegpl"
        fi
        # no lgpl here because they are accepted with it
    fi

    if do_checkForOptions "--enable-frei0r"; then
        do_addOption "--enable-filter=frei0r"
    fi

    if do_checkForOptions "--enable-debug"; then
        # fix issue with ffprobe not working with debug and strip
        do_addOption "--disable-stripping"
    else
        do_addOption "--disable-debug"
    fi

    if do_checkForOptions "--enable-openssl"; then
        do_removeOptions "--enable-gcrypt --enable-gmp"
    fi

    # remove libs that don't work with shared
    if [[ $ffmpeg = "s" || $ffmpeg = "b" ]]; then
        FFMPEG_OPTS_SHARED=$FFMPEG_OPTS
        do_removeOptions "--enable-decklink --enable-libutvideo --enable-libgme" y
        FFMPEG_OPTS_SHARED="$FFMPEG_OPTS_SHARED --extra-ldflags=-static-libgcc"
    fi
}

do_checkForOptions() {
    local option=
    local option2=
    for option in "$@"; do
        for option2 in $option; do
            if grep -qE -e "$option2" <(echo "$FFMPEG_OPTS"); then
                return 0
            fi
        done
    done
    return 1
}

do_addOption() {
    local option=${1%% *}
    if ! do_checkForOptions "$option"; then
        FFMPEG_OPTS="$FFMPEG_OPTS $option"
    fi
}

do_addOptions() {
    local option=
    for option in $1; do
        do_addOption "$option"
    done
}

do_removeOption() {
    local option=${1%% *}
    local shared=$2
    if [[ $shared = "y" ]]; then
        FFMPEG_OPTS_SHARED=$(echo "$FFMPEG_OPTS_SHARED" | sed -r "s/ *$option//g")
    else
        FFMPEG_OPTS=$(echo "$FFMPEG_OPTS" | sed -r "s/ *$option//g")
    fi
}

do_removeOptions() {
    local option=
    local shared=$2
    for option in $1; do
        do_removeOption "$option" "$shared"
    done
}

do_patch() {
    local patch=${1%% *}
    local am=$2     # "am" to apply patch with "git am"
    local strip=$3  # value of "patch" -p i.e. leading directories to strip
    if [[ -z $strip ]]; then
        strip="1"
    fi
    local patchpath=""
    local response_code="$(curl --retry 20 --retry-max-time 5 -L -k -f -w "%{response_code}" \
        -O "https://raw.github.com/jb-alvarado/media-autobuild_suite/master${LOCALBUILDDIR}/patches/$patch")"

    if [[ $response_code != "200" ]]; then
        echo "Patch not found online. Trying local patch. Probably not up-to-date."
        if [[ -f ./"$patch" ]]; then
            patchpath="$patch"
        elif [[ -f "$LOCALBUILDDIR/patches/${patch}" ]]; then
            patchpath="$LOCALBUILDDIR/patches/${patch}"
        fi
    else
        patchpath="$patch"
    fi
    if [[ -n "$patchpath" ]]; then
        if [[ "$am" = "am" ]]; then
            if ! git am --ignore-whitespace "$patchpath"; then
                git am --abort
                echo "Patch couldn't be applied with 'git am'. Continuing without patching."
            fi
        else
            if patch --dry-run -N -p$strip -i "$patchpath"; then
                patch -N -p$strip -i "$patchpath"
            else
                echo "Patch couldn't be applied with 'patch'. Continuing without patching."
            fi
        fi
    else
        echo "No patch found anywhere. Continuing without patching."
    fi
}

do_cmakeinstall() {
    if [ -d "build" ]; then
        rm -rf ./build/*
    else
        mkdir build
    fi
    cd build
    cmake .. -G Ninja -DBUILD_SHARED_LIBS=off -DCMAKE_INSTALL_PREFIX="$LOCALDESTDIR" -DUNIX=on "$@"
    ninja $([[ -n "$cpuCount" ]] && echo "-j $cpuCount") install
}

do_generic_conf() {
    local bindir=""
    case "$1" in
    global)
        bindir="--bindir=$LOCALDESTDIR/bin-global"
        ;;
    audio)
        bindir="--bindir=$LOCALDESTDIR/bin-audio"
        ;;
    video)
        bindir="--bindir=$LOCALDESTDIR/bin-video"
        ;;
    *)
        bindir="$1"
        ;;
    esac
    shift 1
    ./configure --build=$MINGW_CHOST --prefix=$LOCALDESTDIR --disable-shared "$bindir" "$@"
}

do_makeinstall() {
    make -j $cpuCount "$@"
    make install
}

do_generic_confmake() {
    do_generic_conf "$@"
    make -j $cpuCount
}

do_generic_confmakeinstall() {
    do_generic_confmake "$@"
    make install
}

do_hide_pacman_sharedlibs() {
    local packages="$1"
    local revert="$2"
    local files=$(pacman -Qql $packages 2>/dev/null | grep .dll.a)

    for file in $files; do
        if [[ -f "${file%*.dll.a}.a" ]]; then
            if [[ -z "$revert" ]]; then
                mv -f "${file}" "${file}.dyn"
            elif [[ -n "$revert" && -f "${file}.dyn" && ! -f "${file}" ]]; then
                mv -f "${file}.dyn" "${file}"
            elif [[ -n "$revert" && -f "${file}.dyn" ]]; then
                rm -f "${file}.dyn"
            fi
        fi
    done
}

do_hide_all_sharedlibs() {
    [[ x"$1" = "xdry" ]] && local dryrun="y"
    local files=$(find /mingw{32,64} -name *.dll.a)
    for file in $files; do
        [[ -f "${file%*.dll.a}.a" ]] &&
            { [[ $dryrun != "y" ]] && mv -f "${file}" "${file}.dyn" || echo "${file}"; }
    done
}

do_unhide_all_sharedlibs() {
    [[ x"$1" = "xdry" ]] && local dryrun="y"
    local files=$(find /mingw{32,64} -name *.dll.a.dyn)

    for file in $files; do
        if [[ -f "${file%*.dyn}" ]]; then
            [[ $dryrun != "y" ]] && rm -f "${file}" || echo "rm ${file}"
        else
            [[ $dryrun != "y" ]] && mv -f "${file}" "${file%*.dyn}" || echo "${file}"
        fi
    done
}

do_pacman_install() {
    local packages="$1"
    local mingw=""
    [[ $bits = "32bit" ]] && mingw=mingw-w64-i686
    [[ $bits = "64bit" ]] && mingw=mingw-w64-x86_64
    local install=()
    local installed="$(pacman -Qqe | grep "^${mingw}-")"
    for pkg in $packages; do
        if [[ "$pkg" = "${mingw}-"* ]]; then
            grep -q "^${pkg}$" <(echo "$installed") || install+=("$pkg")
        else
            grep -q "^${mingw}-${pkg}$" <(echo "$installed") || install+=("${mingw}-${pkg}")
        fi
        grep -q "^${pkg}$" /etc/pac-mingw-extra.pk || echo "${pkg}" >> /etc/pac-mingw-extra.pk
    done
    if [[ -n "$install" ]]; then
        pacman -S --noconfirm --needed ${install[*]} >/dev/null
        pacman -D --asexplicit ${install[*]} >/dev/null
    fi
    do_hide_all_sharedlibs
}

do_pacman_remove() {
    local packages="$1"
    local mingw=""
    [[ $bits = "32bit" ]] && mingw=mingw-w64-i686
    [[ $bits = "64bit" ]] && mingw=mingw-w64-x86_64
    local uninstall=""
    local installed="$(pacman -Qqe | grep "^${mingw}-")"
    for pkg in $packages; do
        if [[ "$pkg" = "${mingw}-"* ]]; then
            grep -q "^${pkg}$" <(echo "$installed") && uninstall="$pkg"
        else
            grep -q "^${mingw}-${pkg}$" <(echo "$installed") && uninstall="${mingw}-${pkg}"
        fi
        sed -i "/^${pkg}$/d" /etc/pac-mingw-extra.pk
        if [[ -n "$uninstall" ]]; then
            do_hide_pacman_sharedlibs "$uninstall" revert
            if ! pacman -Rs --noconfirm "$uninstall"; then
                pacman -D --asdeps "$uninstall" >/dev/null
            fi
        fi
    done
    do_hide_all_sharedlibs
}

do_prompt() {
    # from http://superuser.com/a/608509
    while read -s -e -t 0.1; do : ; done
    read -p "$1" ret
}

do_autoreconf() {
    local basedir="$LOCALBUILDDIR/$(get_first_subdir)"
    if [[ -f "$basedir"/recently_updated &&
        -z "$(ls "$basedir"/build_successful* 2> /dev/null)" ]]; then
        autoreconf -fiv
    fi
}

do_autogen() {
    local basedir="$LOCALBUILDDIR/$(get_first_subdir)"
    if [[ -f "$basedir"/recently_updated &&
        -z "$(ls "$basedir"/build_successful* 2> /dev/null)" ]]; then
        git clean -xfd -e "/build_successful*" -e "/recently_updated"
        ./autogen.sh
    fi
}

get_first_subdir() {
    local subdir="${PWD#*build/}"
    if [[ "$subdir" != "$PWD" ]]; then
        subdir="${subdir%%/*}"
        echo "$subdir"
    else
        echo "."
    fi
}

get_last_version() {
    local filelist="$1"
    local filter="$2"
    local version="$3"
    local ret=
    ret=$(echo "$filelist" | grep -E "$filter" | sort -V | tail -1)
    if [[ -z "$version" ]]; then
        echo $ret
    else
        echo $ret | grep -oP "$version"
    fi
}

create_debug_link() {
    local file=
    for file in $@; do
        if [[ -f "$file" && ! -f "$file".debug ]]; then
            echo "Stripping and creating debug link for ${file##*/}..."
            objcopy --only-keep-debug "$file" "$file".debug
            strip -s "$file"
            objcopy --add-gnu-debuglink="$file".debug "$file"
        fi
    done
}
