#!/bin/bash
#
# Utility script to backup  SD Card to a sparse image file
# mounted as a filesystem in a file, allowing for efficient incremental
# backups using rsync
#
# The backup is taken while the system is up, so it's a good idea to stop
# programs and services which modifies the filesystem and needed a consistant state
# of their file.
# Especially applications which use databases needs to be stopped (and the database systems too).
#
#  So it's a smart idea to put all these stop commands in a script and perfom it before
#  starting the backup. After the backup terminates normally you may restart all stopped
#  applications or just reboot the system.
#


SDCARD=/dev/mmcblk1

setup () {
    #
    # Define some fancy colors only if connected to a terminal.
    # Thus output to file is no more cluttered
    #
    [ -t 1 ] && {
        RED=$(tput setaf 1)
        GREEN=$(tput setaf 2)
        YELLOW=$(tput setaf 3)
        BLUE=$(tput setaf 4)
        MAGENTA=$(tput setaf 5)
        CYAN=$(tput setaf 6)
        WHITE=$(tput setaf 7)
        RESET=$(tput setaf 9)
        BOLD=$(tput bold)
        NOATT=$(tput sgr0)
        }||{
        RED=""
        GREEN=""
        YELLOW=""
        BLUE=""
        MAGENTA=""
        CYAN=""
        WHITE=""
        RESET=""
        BOLD=""
        NOATT=""
    }
    MYNAME=$(basename $0)
    MYDIR=$(dirname $0)
}


# Echos traces with yellow text to distinguish from other output
trace () {
    echo -e "${YELLOW}${1}${NOATT}"
}

# Echos en error string in red text and exit
error () {
    echo -e "${RED}${1}${NOATT}" >&2
    exit 1
}

version () {
    trace "$Date$"
    trace "$Revision$"
    trace " "
}

# Creates a sparse ${IMAGE} clone of ${SDCARD} and attaches to ${LOOPBACK}
do_create () {

    local ubootdir

    SIZE=${SIZE:-6000}
    #
    # https://images.solid-build.xyz/IMX6/U-Boot/spl-imx6-sdhc.bin
    # https://images.solid-build.xyz/IMX6/U-Boot/u-boot-imx6-sdhc.img
    #

    ubootdir=$MYDIR/uboot
    [ -d  ${ubootdir} ] || mkdir ${ubootdir}
    export SPL=${ubootdir}/spl-imx6-sdhc.bin
    export UBOOT=${ubootdir}/u-boot-imx6-sdhc.img

    [ -f ${SPL} ] || wget -O $SPL https://images.solid-build.xyz/IMX6/U-Boot/spl-imx6-sdhc.bin
    [ -f ${UBOOT} ] || wget -O $UBOOT https://images.solid-build.xyz/IMX6/U-Boot/u-boot-imx6-sdhc.img

    [ -f ${SPL} ] || error "SPL not found."
    [ -f ${UBOOT} ] || error "UBOOT not found."

    trace "Creating sparse ${IMAGE}, the apparent size of $SDCARD"
    rm ${IMAGE}>/dev/null 2>&1
    dd if=/dev/zero of=${IMAGE} bs=${BLOCKSIZE} count=0 seek=${SIZE}
    if [ -s ${IMAGE} ]; then
        trace "Attaching ${IMAGE} to ${LOOPBACK}"
        losetup ${LOOPBACK} ${IMAGE}
    else
        error "${IMAGE} was not created or has zero size"
    fi

    LOOP=$(losetup -f)
    losetup ${LOOP} ${IMAGE}

    trace "Creating partitions on ${LOOPBACK}"
    parted -s ${LOOPBACK} mktable msdos
    parted -s ${LOOPBACK} mkpart primary ext4 4MiB 100%
    trace "Formatting partitions"
    partx --add ${LOOPBACK}
    mkfs.ext4 ${LOOPBACK}p1

    dd if=${SPL} of=${LOOP} bs=1k seek=1 oflag=sync
    dd if=${UBOOT} of=${LOOP} bs=1k seek=69 oflag=sync

    losetup -d ${LOOP}

    clone

}


# Mounts the ${IMAGE} to ${LOOPBACK} (if needed) and ${MOUNTDIR}
do_mount () {
    # Check if do_create already attached the SD Image
    [ $(losetup -f) = ${LOOPBACK} ] && {
        trace "Attaching ${IMAGE} to ${LOOPBACK}"
        losetup ${LOOPBACK} ${IMAGE}
        partx --add ${LOOPBACK}
    }

    trace "Mounting ${LOOPBACK}p1  to ${MOUNTDIR}"
    [ ! -n "${opt_mountdir}" ] &&  mkdir ${MOUNTDIR}
    mount ${LOOPBACK}p1 ${MOUNTDIR}
}

do_check () {

    do_umount

    # Check if do_create already attached the SD Image
    [ $(losetup -f) = ${LOOPBACK} ] && {
        msg "Attaching ${IMAGE} to ${LOOPBACK}"
        losetup ${LOOPBACK} "${IMAGE}"
        partx --add ${LOOPBACK}
    }

    fsck -y ${LOOPBACK}p1 || {
        msgwarn "Checking ${LOOPBACK}p1 returned_:$err"
        return 1
    }


    msg "Detaching ${IMAGE} from ${LOOPBACK}"
    partx --delete ${LOOPBACK}
    losetup -d ${LOOPBACK}
}


# Rsyncs content of ${SDCARD} to ${IMAGE} if properly mounted
do_backup () {

    local rsyncopt

    rsyncopt="-aEvx --del --stats"
    [ -n "${opt_log}" ] && rsyncopt="$rsyncopt --log-file ${LOG}"

    if mountpoint -q ${MOUNTDIR}; then
        trace "Starting rsync backup of / to ${MOUNTDIR}"

        rsync $rsyncopt --exclude='.gvfs/**' \
        --exclude='tmp/**' \
        --exclude='proc/**' \
        --exclude='run/**' \
        --exclude='sys/**' \
        --exclude='mnt/**' \
        --exclude='lost+found/**' \
        --exclude='var/swap ' \
        --exclude='home/*/.cache/**' \
        --exclude='var/cache/apt/archives/**' \
        --exclude='var/lib/docker/' \
        --exclude='var/lib/containerd/' \
        / ${MOUNTDIR}/

    else
        trace "Skipping rsync since ${MOUNTDIR} is not a mount point"
    fi
}

do_showdf () {

    echo -n "${GREEN}"
    df -m ${LOOPBACK}p1
    echo -n "$NOATT"
}

# Unmounts the ${IMAGE} from ${MOUNTDIR} and ${LOOPBACK}
do_umount () {
    trace "Flushing to disk"
    sync; sync

    trace "Unmounting ${LOOPBACK}1  from ${MOUNTDIR}"
    umount ${MOUNTDIR}
    [ ! -n "${opt_mountdir}" ] &&   rmdir ${MOUNTDIR}

    trace "Detaching ${IMAGE} from ${LOOPBACK}"
    partx --delete ${LOOPBACK}
    losetup -d ${LOOPBACK}
}

#
# resize image
#
do_resize () {
    do_umount >/dev/null 2>&1
    truncate --size=+1G "${IMAGE}"
    losetup ${LOOPBACK} "${IMAGE}"
    parted -s ${LOOPBACK} resizepart 1 100%
    partx --add ${LOOPBACK}
    e2fsck -f ${LOOPBACK}p1
    resize2fs ${LOOPBACK}p1
}

# Compresses ${IMAGE} to ${IMAGE}.gz using a temp file during compression
do_compress () {
    trace "Compressing ${IMAGE} to ${IMAGE}.gz"
    pv -tpreb ${IMAGE} | gzip > ${IMAGE}.gz.tmp
    [ -s ${IMAGE}.gz.tmp ] && {
        mv -f ${IMAGE}.gz.tmp ${IMAGE}.gz
        [ -n "${opt_delete}" ] &&   rm -f ${IMAGE}
    }
}

# Tries to cleanup after Ctrl-C interrupt
ctrl_c () {
    trace "Ctrl-C detected."

    if [ -s ${IMAGE}.gz.tmp ]; then
        rm ${IMAGE}.gz.tmp
    else
        do_umount
    fi

    [ -n "${opt_log}" ] &&  trace "See rsync log in ${LOG}"

    error "SD Image backup process interrupted"
}

# Prints usage information
usage () {
cat<<EOF
    ${MYNAME}

    Usage:

        ${MYNAME} ${BOLD}start${NOATT} [-clzdf] [-L logfile] [-i sdcard] sdimage
        ${MYNAME} ${BOLD}mount${NOATT} [-c] sdimage [mountdir]
        ${MYNAME} ${BOLD}umount${NOATT} sdimage [mountdir]
        ${MYNAME} ${BOLD}gzip${NOATT} [-df] sdimage

        Commands:

            ${BOLD}start${NOATT}      starts complete backup of the SD Card to 'sdimage'
            ${BOLD}mount${NOATT}      mounts the 'sdimage' to 'mountdir' (default: /mnt/'sdimage'/)
            ${BOLD}umount${NOATT}     unmounts the 'sdimage' from 'mountdir'
            ${BOLD}check${NOATT}      filesystemcheck on 'sdimage'
            ${BOLD}gzip${NOATT}       compresses the 'sdimage' to 'sdimage'.gz
            ${BOLD}cloneid${NOATT}    clones the UUID/PTUUID from the actual disk to the image
            ${BOLD}showdf${NOATT}     shows allocation of the image
            ${BOLD}version${NOATT}    show script version

        Options:

            ${BOLD}-c${NOATT}         creates the SD Image if it does not exist
            ${BOLD}-l${NOATT}         writes rsync log to 'sdimage'-YYYYmmddHHMMSS.log
            ${BOLD}-z${NOATT}         compresses the SD Image (after backup) to 'sdimage'.gz
            ${BOLD}-d${NOATT}         deletes the SD Image after successful compression
            ${BOLD}-f${NOATT}         forces overwrite of 'sdimage'.gz if it exists
            ${BOLD}-L logfile${NOATT} writes rsync log to 'logfile'
            ${BOLD}-i sdcard${NOATT}  specifies the SD Card location (default: $SDCARD)
            ${BOLD}-s Mb${NOATT}      specifies the size of image in MB (default: Size of $SDCARD)

    Examples:

        ${MYNAME} start -c /path/to/imx6_backup.img
            starts backup to 'imx6_backup.img', creating it if it does not exist

        ${MYNAME} start -c -s 8000 /path/to/imx6_backup.img
            starts backup to 'imx6_backup.img', creating it with a size of 8000mb.
            You are responsible for defining a size sufficiant to hold all data.

        ${MYNAME} start /path/to/\$(uname -n).img
            uses the hostname as the SD Image filename

        ${MYNAME} start -cz /path/to/\$(uname -n)-\$(date +%Y-%m-%d).img
            uses the hostname and today's date as the SD Image filename,
            creating it if it does not exist, and compressing it after backup

        ${MYNAME} mount /path/to/\$(uname -n).img /mnt/cubox_image
            mounts the SD Image in /mnt/cubox_image

        ${MYNAME} umount /path/to/cubox-$(date +%Y-%m-%d).img
            unmounts the SD Image from default mountdir (/mnt/cubox-$(date +%Y-%m-%d).img/)

EOF

}


setup

# Read the command from command line
case ${1} in
    start|mount|umount|gzip|cloneid|showdf|resize|version)
        opt_command=${1}
    ;;
    -h|--help)
        usage
        exit 0
    ;;
    *)
    error "Invalid command or option: ${1}\nSee '${MYNAME} --help' for usage";;
esac
shift 1

# Make sure we have root rights
[ $(id -u) -ne 0 ] &&  error "Please run as root. Try sudo."

# Default size, can be overwritten by the -s option
SIZE=$(blockdev --getsz $SDCARD)
BLOCKSIZE=$(blockdev --getss $SDCARD)

# Read the options from command line
while getopts ":czdflL:i:s:" opt; do
    case ${opt} in
        c)  opt_create=1;;
        z)  opt_compress=1;;
        d)  opt_delete=1;;
        f)  opt_force=1;;
        l)  opt_log=1;;
        L)  opt_log=1
            LOG=${OPTARG}
        ;;
        i)  SDCARD=${OPTARG};;
        s)  SIZE=${OPTARG}
        BLOCKSIZE=1M ;;
        \?) error "Invalid option: -$OPTARG\nSee '${MYNAME} --help' for usage";;
        :)  error "Option -${OPTARG} requires an argument\nSee '${MYNAME} --help' for usage";;
    esac
done
shift $((OPTIND-1))

# Read the sdimage path from command line
IMAGE=${1}
[ -z ${IMAGE} ] &&  error "No sdimage specified"

# Check if sdimage exists
if [ ${opt_command} = umount ] || [ ${opt_command} = gzip ]; then
    [ ! -f ${IMAGE} ] &&  error "${IMAGE} does not exist"
else
    if [ ! -f ${IMAGE} ] && [ ! -n "${opt_create}" ]; then
        error "${IMAGE} does not exist\nUse -c to allow creation"
    fi
fi

# Check if we should compress and sdimage.gz exists
if [ -n "${opt_compress}" ] || [ ${opt_command} = gzip ]; then
    if [ -s ${IMAGE}.gz ] && [ ! -n "${opt_force}" ]; then
        error "${IMAGE}.gz already exists\nUse -f to force overwriting"
    fi
fi

# Define default rsync logfile if not defined
[ -z ${LOG} ] && LOG=${IMAGE}-$(date +%Y%m%d%H%M%S).log


# Identify which loopback device to use
LOOPBACK=$(losetup -j ${IMAGE} | grep -o ^[^:]*)
if [ ${opt_command} = umount ]; then
    if [ -z ${LOOPBACK} ]; then
        error "No /dev/loop<X> attached to ${IMAGE}"
    fi
    elif [ ! -z ${LOOPBACK} ]; then
    error "${IMAGE} already attached to ${LOOPBACK} mounted on $(grep ${LOOPBACK}p1 /etc/mtab | cut -d ' ' -f 2)/"
else
    LOOPBACK=$(losetup -f)
fi


# Read the optional mountdir from command line
MOUNTDIR=${2}
if [ -z ${MOUNTDIR} ]; then
    MOUNTDIR=/mnt/$(basename ${IMAGE})/
else
    opt_mountdir=1
    [ ! -d ${MOUNTDIR} ] && error "Mount point ${MOUNTDIR} does not exist"
fi

# Check if default mount point exists
if [ ${opt_command} = umount ]; then
    [ ! -d ${MOUNTDIR} ] &&  error "Default mount point ${MOUNTDIR} does not exist"
else
    if [ ! -n "${opt_mountdir}" ] && [ -d ${MOUNTDIR} ]; then
        error "Default mount point ${MOUNTDIR} already exists"
    fi
fi

# Trap keyboard interrupt (ctrl-c)
trap ctrl_c SIGINT SIGTERM

# Check for dependencies
for c in dd losetup parted sfdisk partx mkfs.vfat mkfs.ext4 mountpoint rsync; do
    command -v ${c} >/dev/null 2>&1 || error "Required program ${c} is not installed"
done
if [ -n "${opt_compress}" ] || [ ${opt_command} = gzip ]; then
    for c in pv gzip; do
        command -v ${c} >/dev/null 2>&1 || error "Required program ${c} is not installed"
    done
fi

# Do the requested functionality
case ${opt_command} in
    start)
        trace "Starting SD Image backup process"
        if [ ! -f ${IMAGE} ] && [ -n "$opt_create" ]; then
            do_create
        fi
        do_mount
        do_backup
        do_showdf
        do_umount
        if [ -n "${opt_compress}" ]; then
            do_compress
        fi
        trace "SD Image backup process completed."
        if [ -n "$opt_log" ]; then
            trace "See rsync log in $LOG"
        fi
    ;;
    mount)
        if [ ! -f ${IMAGE} ] && [ -n "$opt_create" ]; then
            do_create
        fi
        do_mount
        trace "SD Image has been mounted and can be accessed at:\n    ${MOUNTDIR}"
    ;;
    umount)
        do_umount
    ;;
    check)
        do_check
    ;;
    gzip)
        do_compress
    ;;
    cloneid)
        do_cloneid
    ;;
    resize)
        do_resize
    ;;
    showdf)
        do_mount
        do_showdf
        do_umount
    ;;
    version)
        version
    ;;
    *)
        error "Unknown command: ${opt_command}"
    ;;
esac

exit 0
