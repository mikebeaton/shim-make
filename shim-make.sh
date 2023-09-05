#!/bin/bash
#
# Copyright © 2023 Mike Beaton. All rights reserved.
# SPDX-License-Identifier: BSD-3-Clause
#
# Makes own-build shim which launches OpenCore.efi and includes specified vendor certificate lists.
# Builds on macOS using Ubuntu multipass or on Linux directly (Ubuntu, *TODO* Fedora tested).
#
# To debug shim (e.g. within OVMF) make with
# ./shim-make.sh make OPTIMIZATIONS="-O0"
# and set 605dab50-e046-4300-abb6-3dd810dd8b23:SHIM_DEBUG to (UINT8)1 (<data>AQ==</data>) in NVRAM
#

unamer() {
  NAME="$(uname)"

  if [ "$(echo "${NAME}" | grep MINGW)" != "" ] || [ "$(echo "${NAME}" | grep MSYS)" != "" ]; then
    echo "Windows"
  else
    echo "${NAME}"
  fi
}

shim_command () {
    DIR=$1
    shift
    if [ $DARWIN -eq 1 ] ; then
        if [ $ECHO -eq 1 ] ; then
            echo multipass exec ${OC_SHIM} --working-directory "'${DIR}'" -- $@ 1>/dev/stderr
        fi
        eval multipass exec ${OC_SHIM} --working-directory "'${DIR}'" -- $@
    else
        if [ $ECHO -eq 1 ] ; then
            echo "[${DIR}]" $@ 1>/dev/stderr
        fi
        pushd "${DIR}" 1>/dev/null
        eval $@
        retval=$?
        popd 1>/dev/null
        return $retval
    fi
}

usage() {
    echo "Usage:"
    echo " ./${SELFNAME} [args] [setup|clean|make [options]|install [esp-root-path]|mount [multipass-path]]"
    echo
    echo "Args:"
    echo "  -r : Specify shim output root, default '${ROOT}'"
    echo "  -s : Specify shim source location, default '${SHIM}'"
    echo "If used -r/-s:"
    echo " - Should be specified on every call, they are not remembered from setup"
    echo " - Should be specified before the ${SELFNAME} command"
    echo
    echo "Examples:"
    echo "  ./${SELFNAME} setup (sets up directories and installs rhboot/shim source)"
    echo "  ./${SELFNAME} clean (cleans after previous make)"
    LOCATION="."
    if [ $DARWIN -eq 1 ] ; then
        LOCATION="${ROOT}"
    fi
    echo -n "  ./${SELFNAME} make VENDOR_DB_FILE='${LOCATION}/combined/vendor.db' VENDOR_DBX_FILE='${LOCATION}/combined/vendor.dbx' (makes shim with db and dbx contents"
    if [ $DARWIN -eq 1 ] ; then
        echo -n "; note VENDOR_DB_FILE and VENDOR_DBX_FILE are inside a directory shared with VM"
    fi
    echo ")"
    echo "  ./${SELFNAME} install '${EXAMPLE_ESP}' (installs made files to ESP mounted at '${EXAMPLE_ESP}')"
    echo
    echo "After installation shimx64.efi and mmx64.efi must be signed by user ISK; OpenCore.efi must have an .sbat section added and be signed by user ISK."
}

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

    if [ ! -d "${SRC}" ] ; then
        echo "Adding ${SRC}..."
        mkdir "${SRC}"
    else
        echo "${SRC} already present..."
    fi

    if ! multipass info ${OC_SHIM} | grep "${DEST}" 1>/dev/null ; then
        echo "Mounting ${SRC}..."
        multipass mount "${SRC}" "${OC_SHIM}:${DEST}"
    else
        echo "${SRC} already mounted..."
    fi
}

get_ready () {
    if [ $DARWIN -eq 1 ] ; then
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

        mount_path "${ROOT}"
    fi

    # Make sure parent directory exists
    #shim_command . sudo mkdir -p "'$(dirname "${SHIM}")'" || exit 1

    #
    # For debug/develop purposes on Darwin it would be nicer to keep the source code in
    # macOS, just mounted and built in multipass, but the build is about 1/3 the speed of
    # building in a native multipass directory.
    # For the purposes of having a fast build but code which can be opened e.g.
    # within an IDE within macOS, sshfs can be used to mount out from multipass
    # to macOS using ./shim-make mount:
    #  - https://github.com/canonical/multipass/issues/1070
    #  - https://osxfuse.github.io/
    #
    if ! shim_command . test -d "'${SHIM}'"  ; then
        echo "Cloning rhboot/shim..."
        shim_command . git clone https://github.com/rhboot/shim.git "'${SHIM}'"  || exit 1
        shim_command "${SHIM}" git submodule update --init || exit 1
    else
        if ! shim_command "${SHIM}" git remote -v | grep "rhboot/shim" 1>/dev/null ; then
            echo "FATAL: VM subdirectory ${SHIM} is already present, but does not contain rhboot/shim!"
            exit 1
        fi
        echo "rhboot/shim already cloned..."
    fi

    echo "Make.defaults:"

    # These two modifications to Make.defaults only required for debugging
    FOUND=$(shim_command "${SHIM}" grep "gdwarf" Make.defaults | wc -l)
    if [ $FOUND -eq 0 ] ; then
        echo "  Updating gdwarf flags..."
        shim_command "${SHIM}" sed -i "'s^-ggdb \\\\^-ggdb -gdwarf-4 -gstrict-dwarf \\\\^g'" Make.defaults
    else
        echo "  gdwarf flags already updated..."
    fi

    FOUND=$(shim_command "${SHIM}" grep "'${ROOT}'" Make.defaults | wc -l)
    if [ $FOUND -eq 0 ] ; then
        echo "  Updating debug directory..."
        shim_command "${SHIM}" sed -i "\"s^-DDEBUGDIR='L\\\"/usr/lib/debug/usr/share/shim/\\\$(ARCH_SUFFIX)-\\\$(VERSION)\\\$(DASHRELEASE)/\\\"'^-DDEBUGDIR='L\\\"${ROOT}/usr/lib/debug/boot/efi/EFI/OC/\\\"'^g\"" Make.defaults
    else
        echo "  Debug directory already updated..."
    fi

    # Work-around for https://github.com/rhboot/shim/issues/596
    FOUND=$(shim_command "${SHIM}" grep "'export DEFINES'" Make.defaults | wc -l)
    if [ $FOUND -eq 0 ] ; then
        echo "  Updating exports..."
        # var assignment to make output piping work normally
        temp=$(echo "export DEFINES" | shim_command "${SHIM}" tee -a Make.defaults) 1>/dev/null
    else
        echo "  Exports already updated..."
    fi

    FOUND=$(shim_command . command -v gcc | wc -l)
    if [ $FOUND -eq 0 ] ; then
        echo "Installing dependencies..."
        shim_command . sudo apt-get update
        shim_command . sudo apt install -y gcc make git libelf-dev
    else
        echo "Dependencies already installed..."
    fi
}

# ROOT=~/shim_root
# SHIM=~/OpenSource/shim
ROOT=~/shim\ root
SHIM=~/Open\ Source/my\ shim
OC_SHIM=oc-shim

SELFNAME="$(/usr/bin/basename "${0}")"

ECHO=0

if [ "$(unamer)" = "Darwin" ] ; then
    DARWIN=1
    EXAMPLE_ESP='/Volumes/EFI'
else
    DARWIN=0
    EXAMPLE_ESP='/boot/efi'
fi

OPTS=0
while [ "${1:0:1}" = "-" ] ; do
    OPTS=1
    if [ "$1" = "-r" ] ; then
        shift
        if [ "$1" != "" ] && ! [ "${1:0:1}" = "-" ] ; then
            ROOT=$1
            shift
        else
            echo "No root directory specified" && exit 1
        fi
    elif [ "$1" = "-s" ] ; then
        shift
        if [ "$1" != "" ] && ! [ "${1:0:1}" = "-" ] ; then
            SHIM=$1
            shift
        else
            echo "No shim directory specified" && exit 1
        fi
    elif [ "$1" = "--echo" ] ; then
        ECHO=1
        shift
    else
        echo "Unknown option: $1"
        exit 1
    fi
done

if [ "$1" = "setup" ] ; then
    get_ready
    echo "Installation complete."
    exit 0
elif [ "$1" = "clean" ] ; then
    echo "Cleaning..."
    shim_command "${SHIM}" make clean
    exit 0
elif [ "$1" = "make" ] ; then
    echo "Making..."
    shift
    shim_command "${SHIM}" make DEFAULT_LOADER="\\\\\\\\OpenCore.efi" OVERRIDE_SECURITY_POLICY=1 "$@"
    exit 0
elif [ "$1" = "install" ] ; then
    echo "Installing..."
    rm -rf "'${ROOT}/usr'"
    shim_command "${SHIM}" DESTDIR="'${ROOT}'" EFIDIR='OC' OSLABEL='OpenCore' make install
    if [ ! "$2" = "" ] ; then
        echo "Installing to ESP ${2}..."
        cp ${ROOT}/boot/efi/EFI/OC/* ${2}/EFI/OC || exit 1
    fi
    exit 0
elif [ "$1" = "mount" ] ; then
    MOUNT="$2"
    if [ "${MOUNT}" = "" ] ; then
        MOUNT=$SHIM
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
    exit 0
elif [ "$1" = "" ] ; then
    if [ $OPTS -eq 0 ] ; then
        usage
    else
        echo "No command specified."
    fi
    exit 1
else
    echo "Unkown command: $1"
    exit 1
fi
