#!/bin/sh
#
# Copyright © 2023 Mike Beaton. All rights reserved.
# SPDX-License-Identifier: BSD-3-Clause
#
# To debug shim (e.g. within OVMF) make with
# shim-make.sh make OPTIMIZATIONS="-O0"
# and set 605dab50-e046-4300-abb6-3dd810dd8b23:SHIM_DEBUG to (UINT8)1 (<data>AQ==</data>) in NVRAM
#

ROOT=~/shim_root
SHIM=~/OpenSource/shim
OC_SHIM=oc-shim

mount_path () {
    SRC=$1
    if [ "${SRC}" = "" ] ; then
        echo "Incorrect call to mount_path!"
        exit 1
    fi
    DEST=$2
    if [ "${DEST}" = "" ] ; then
        DEST=${SRC}
    fi

    if [ ! -d ${SRC} ] ; then
        echo "Adding ${SRC}..."
        mkdir ${SRC}
    else
        echo "${SRC} already present..."
    fi

    if ! multipass info ${OC_SHIM} | grep "${DEST}" 1>/dev/null ; then
        echo "Mounting ${SRC}..."
        multipass mount ${SRC} ${OC_SHIM}:${DEST}
    else
        echo "${SRC} already mounted..."
    fi
}

get_ready () {
    if ! command -v multipass 1>/dev/null ; then
        echo "Installing Ubuntu multipass..."
        brew install --cask multipass || exit 1
    else
        echo "Ubuntu multipass already installed..."
    fi

    if ! multipass info ${OC_SHIM} &>/dev/null ; then
        echo "Launching ${OC_SHIM} multipass instance..."
        multipass launch -n ${OC_SHIM} || exit 1
    else
        echo "${OC_SHIM} multipass instance already launched..."
    fi

    mount_path ${ROOT}

    #
    # For debug/develop purposes, it would be nicer to keep the source code in
    # macOS, just mounted and built in multipass, but the build is about 1/3 the
    # speed of building in a native multipass directory.
    # For the purposes of having a fast build, but code which can be opened e.g.
    # within an IDE within macOS, sshfs can be used to mount out from multipass
    # to macOS:
    #  - https://github.com/canonical/multipass/issues/1070
    #  - https://osxfuse.github.io/
    #
    if ! multipass exec ${OC_SHIM} -- test -d ${SHIM} ; then
        echo "Cloning rhboot/shim..."
        multipass exec ${OC_SHIM} -- git clone https://github.com/rhboot/shim.git ${SHIM} || exit 1
        multipass exec ${OC_SHIM} --working-directory ${SHIM} -- git submodule update --init || exit 1
    else
        if ! multipass exec ${OC_SHIM} --working-directory ${SHIM} -- git remote -v | grep "rhboot/shim" 1>/dev/null ; then
            echo "FATAL: VM subdirectory ${SHIM} is already present, but does not contain rhboot/shim!"
            exit 1
        fi
        echo "rhboot/shim already cloned..."
    fi

    # Both modifications to Make.defaults only required for debugging
    FOUND=$(multipass exec ${OC_SHIM} --working-directory ${SHIM} -- grep "gdwarf" Make.defaults | wc -l)
    if [ $FOUND -eq 0 ] ; then
        echo "Updating Make.defaults gdwarf flags..."
        multipass exec ${OC_SHIM} --working-directory ${SHIM} -- sed -i 's^-ggdb \\^-ggdb -gdwarf-4 -gstrict-dwarf \\^g' Make.defaults
    else
        echo "Make.defaults gdwarf flags already updated..."
    fi

    FOUND=$(multipass exec ${OC_SHIM} --working-directory ${SHIM} -- grep "${ROOT}" Make.defaults | wc -l)
    if [ $FOUND -eq 0 ] ; then
        echo "Updating Make.defaults debug directory..."
        multipass exec ${OC_SHIM} --working-directory ${SHIM} -- sed -i s^-DDEBUGDIR=\'L\"/usr/lib/debug/usr/share/shim/$\(ARCH_SUFFIX\)-$\(VERSION\)$\(DASHRELEASE\)/\"\'^-DDEBUGDIR=\'L\"${ROOT}/usr/lib/debug/boot/efi/EFI/OC/\"\'^g Make.defaults
    else
        echo "Make.defaults debug directory already updated..."
    fi

    FOUND=$(multipass exec ${OC_SHIM} -- command -v gcc | wc -l)
    if [ $FOUND -eq 0 ] ; then
        echo "Installing dependencies..."
        multipass exec ${OC_SHIM} -- sudo apt-get update
        multipass exec ${OC_SHIM} -- sudo apt install -y gcc make git libelf-dev
    else
        echo "Dependencies already installed..."
    fi
}

if [ "$1" = "" ] ; then
    get_ready
    echo "Installation complete."
    echo
    echo "Usage: $0 [clean|make <options>|install <esp-root-path>]"
    echo
elif [ "$1" = "clean" ] ; then
    echo "Cleaning..."
    multipass exec ${OC_SHIM} --working-directory ${SHIM} -- make clean
elif [ "$1" = "make" ] ; then
    echo "Making..."
    shift
    multipass exec ${OC_SHIM} --working-directory ${SHIM} -- make DEFAULT_LOADER="\\\\\\\\OpenCore.efi" OVERRIDE_SECURITY_POLICY=1 "$@"
elif [ "$1" = "install" ] ; then
    echo "Installing..."
    rm -rf ${ROOT}/usr
    multipass exec ${OC_SHIM} --working-directory ${SHIM} -- DESTDIR=${ROOT} EFIDIR="OC" OSLABEL="OpenCore" make install
    if [ ! "$2" = "" ] ; then
        echo "Installing to ESP ${2}..."
        cp ${ROOT}/boot/efi/EFI/OC/* ${2}/EFI/OC || exit 1
    fi
elif [ "$1" = "mount" ] ; then
    MOUNT="$2"
    if [ "${MOUNT}" = "" ] ; then
        MOUNT="${SHIM}"
    fi

    #
    # Useful for devel/debug only.
    # Note: We are only mounting in the reverse direction because we get much faster build speeds.
    #
    if ! command -v sshfs 1>/dev/null ; then
        echo "sshfs (https://osxfuse.github.io/) is required for mounting directories from multipass into macOS (https://github.com/canonical/multipass/issues/1070)"
        exit 1
    fi

    if [ ! -d ${MOUNT} ] ; then
        echo "Making local directory ${MOUNT}..."
        mkdir -p ${MOUNT} || exit 1
    fi

    ls ${MOUNT} 1>/dev/null
    if [ $? -ne 0 ] ; then
        echo "Directory may be mounted but not ready (no authorized key?)"
        echo "Try: umount ${MOUNT}"
        exit 1
    fi

    if mount | grep ":${MOUNT}" ; then
        echo "Already mounted at ${MOUNT}"
        exit 0
    fi

    if [ $(ls -1 ${MOUNT} | wc -l) -ne 0 ] ; then
        echo "Directory ${MOUNT} is not empty!"
        exit 1
    fi

    IP=$(multipass info ${OC_SHIM} | grep IPv4 | cut -d ":" -f 2 | sed 's/ //g')
    if [ "${IP}" = "" ] ; then
        echo "Cannot obtain IPv4 for ${OC_SHIM}"
        exit 1
    fi
    if sshfs ubuntu@${IP}:$(realpath ${MOUNT}) ${MOUNT} ; then
        echo "Mounted at ${MOUNT}"
        exit 0
    else
        umount ${MOUNT}
        echo "Directory cannot be mounted, add your ssh public key to .ssh/authorized_keys in the VM and try again."
        exit 1
    fi
else
    echo "Unrecognised option: $1"
    exit 1
fi
