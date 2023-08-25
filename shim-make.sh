#!/bin/sh
#
# Copyright © 2023 Mike Beaton. All rights reserved.
# SPDX-License-Identifier: BSD-3-Clause
#
# To debug shim (e.g. within OVMF) make with
# shim-make.sh make OPTIMIZATIONS="-O0"
# and set 605dab50-e046-4300-abb6-3dd810dd8b23:SHIM_DEBUG to (UINT8)1 (<data>AQ==</data>) in NVRAM
#

SHIM_ROOT=~/shim_root
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

    mount_path ${SHIM_ROOT}

    if [ ! -d shim ] ; then
        echo
        echo "Cloning rhboot/shim..."
        git clone https://github.com/rhboot/shim.git || exit 1
        pushd shim 1>/dev/null || exit 1
        git submodule update --init || exit 1
        popd 1>/dev/null || exit 1
    else
        pushd shim 1>/dev/null || exit 1
        if ! git remote -v | grep "rhboot/shim" 1>/dev/null ; then
            echo "FATAL: Subdirectory shim is already present, but does not contain rhboot/shim!"
            exit 1
        fi
        popd 1>/dev/null || exit 1
        echo "rhboot/shim already cloned..."
    fi

    pushd shim 1>/dev/null || exit 1
    if ! grep "${SHIM_ROOT}" Make.defaults 1>/dev/null ; then
        echo
        echo "Updating Make.defaults..."
        TMP=mktmp || exit 1
        cat Make.defaults | sed s^-DDEBUGDIR=\'L\"/usr/lib/debug/usr/share/shim/^-DDEBUGDIR=\'L\"${SHIM_ROOT}/usr/src/debug/^g > $TMP
        cp "$TMP" Make.defaults
        rm $TMP
        echo
    else
        echo "Make.defaults already updated..."
    fi
    popd 1>/dev/null || exit 1

    mount_path shim '~/shim'

    if ! multipass exec ${OC_SHIM} -- command -v gcc ] ; then
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
    multipass exec ${OC_SHIM} --working-directory shim -- make clean
elif [ "$1" = "make" ] ; then
    echo "Making..."
    shift
    multipass exec ${OC_SHIM} --working-directory shim -- make DEFAULT_LOADER="\\\\\\\\OpenCore.efi" "$@"
elif [ "$1" = "install" ] ; then
    echo "Installing..."
    rm -rf ${SHIM_ROOT}/usr
    multipass exec ${OC_SHIM} --working-directory shim DESTDIR=${SHIM_ROOT} EFIDIR="OC" OSLABEL="OpenCore" make install
    if [ ! "$2" = "" ] ; then
        echo "Installing to ESP ${2}..."
        cp ${SHIM_ROOT}/boot/efi/EFI/OC/* ${2}/EFI/OC || exit 1
    fi
else
    echo "Unrecognised option: $1"
    exit 1
fi
