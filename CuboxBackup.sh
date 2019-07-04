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
# 2019-05-14 Dolorosus  
#        fix: Useless rsync of /boot removed 
#             (imx6 doesn't have a seperate /boot partition)
# 
# 2019-05-12 Dolorosus                  
#        fix: Creation of backupfile works now.
#
# 2019-03-19 Dolorosus                  
#        fix: Define colors only if connected to a terminal.
#             Thus output to file is no more cluttered.
#
# 2019-03-18 Dolorosus: 
#               add: exclusion of files below /tmp,/proc,/run,/sys and 
#                    also the swapfile /var/swap will be excluded from backup.
#
# 2019-03-17 Dolorosus: 
#               add: -s parameter to create an image of a defined size.
#               add: funtion cloneid to clone te UUID and the PTID from 
#                    the SDCARD to the image. So restore is working on 
#                    recent raspian versions.
#
#
#

SDCARD=/dev/mmcblk0

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

do_cloneid () {
	# Check if do_create already attached the SD Image
	if [ $(losetup -f) = ${LOOPBACK} ]; then
		trace "Attaching ${IMAGE} to ${LOOPBACK}"
		losetup ${LOOPBACK} ${IMAGE}
		partx --add ${LOOPBACK}
	fi
	clone
	partx --delete ${LOOPBACK}
	losetup -d ${LOOPBACK}
}

clone () {
	# cloning UUID and PARTUUID
	UUID=$(blkid -s UUID -o value ${SDCARD}p1)
	PTUUID=$(blkid -s PTUUID -o value ${SDCARD})
	e2fsck -f -y ${LOOPBACK}p1
	echo y|tune2fs ${LOOPBACK}p1 -U $UUID
	printf 'p\nx\ni\n%s\nr\np\nw\n' 0x${PTUUID}|fdisk "${LOOPBACK}"
	sync
}

# Mounts the ${IMAGE} to ${LOOPBACK} (if needed) and ${MOUNTDIR}
do_mount () {
	# Check if do_create already attached the SD Image
	if [ $(losetup -f) = ${LOOPBACK} ]; then
		trace "Attaching ${IMAGE} to ${LOOPBACK}"
		losetup ${LOOPBACK} ${IMAGE}
		partx --add ${LOOPBACK}
	fi

	trace "Mounting ${LOOPBACK}1  to ${MOUNTDIR}"
	if [ ! -n "${opt_mountdir}" ]; then
		mkdir ${MOUNTDIR}
	fi
	 mount ${LOOPBACK}p1 ${MOUNTDIR}
}

# Rsyncs content of ${SDCARD} to ${IMAGE} if properly mounted
do_backup () {

	local rsyncopt
	
	rsyncopt="-aEvx --del --stats"

	if mountpoint -q ${MOUNTDIR}; then
		trace "Starting rsync backup of / to ${MOUNTDIR}"

		if [ -n "${opt_log}" ]; then
			rsyncopt="$rsyncopt --log-file ${LOG}"
		fi

		rsync $rsyncopt --exclude='.gvfs/**' \
			--exclude='tmp/**' \
			--exclude='proc/**' \
			--exclude='run/**' \
			--exclude='sys/**' \
			--exclude='mnt/**' \
			--exclude='lost+found/**' \
			--exclude='var/swap ' \
			--exclude='home/la/.cache/**' \
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
	if [ ! -n "${opt_mountdir}" ]; then
		rmdir ${MOUNTDIR}
	fi

	trace "Detaching ${IMAGE} from ${LOOPBACK}"
	partx --delete ${LOOPBACK}
	losetup -d ${LOOPBACK}
}

# Compresses ${IMAGE} to ${IMAGE}.gz using a temp file during compression
do_compress () {
	trace "Compressing ${IMAGE} to ${IMAGE}.gz"
	pv -tpreb ${IMAGE} | gzip > ${IMAGE}.gz.tmp
	if [ -s ${IMAGE}.gz.tmp ]; then
		mv -f ${IMAGE}.gz.tmp ${IMAGE}.gz
		if [ -n "${opt_delete}" ]; then
			rm -f ${IMAGE}
		fi
	fi
}

# Tries to cleanup after Ctrl-C interrupt
ctrl_c () {
	trace "Ctrl-C detected."

	if [ -s ${IMAGE}.gz.tmp ]; then
		rm ${IMAGE}.gz.tmp
	else
		do_umount
	fi

	if [ -n "${opt_log}" ]; then
		trace "See rsync log in ${LOG}"
	fi

	error "SD Image backup process interrupted"
}

# Prints usage information
usage () {
	echo -e ""
	echo -e "${MYNAME}"
	echo -e ""
	echo -e "Usage:"
	echo -e ""
	echo -e "    ${MYNAME} ${BOLD}start${NOATT} [-clzdf] [-L logfile] [-i sdcard] sdimage"
	echo -e "    ${MYNAME} ${BOLD}mount${NOATT} [-c] sdimage [mountdir]"
	echo -e "    ${MYNAME} ${BOLD}umount${NOATT} sdimage [mountdir]"
	echo -e "    ${MYNAME} ${BOLD}gzip${NOATT} [-df] sdimage"
	echo -e ""
	echo -e "    Commands:"
	echo -e ""
	echo -e "        ${BOLD}start${NOATT}      starts complete backup of RPi's SD Card to 'sdimage'"
	echo -e "        ${BOLD}mount${NOATT}      mounts the 'sdimage' to 'mountdir' (default: /mnt/'sdimage'/)"
	echo -e "        ${BOLD}umount${NOATT}     unmounts the 'sdimage' from 'mountdir'"
	echo -e "        ${BOLD}gzip${NOATT}       compresses the 'sdimage' to 'sdimage'.gz"
	echo -e "        ${BOLD}cloneid${NOATT}    clones the UUID/PTUUID from the actual disk to the image"
	echo -e "        ${BOLD}showdf${NOATT}     shows allocation of the image"
	echo -e ""
	echo -e "    Options:"
	echo -e ""
	echo -e "        ${BOLD}-c${NOATT}         creates the SD Image if it does not exist"
	echo -e "        ${BOLD}-l${NOATT}         writes rsync log to 'sdimage'-YYYYmmddHHMMSS.log"
	echo -e "        ${BOLD}-z${NOATT}         compresses the SD Image (after backup) to 'sdimage'.gz"
	echo -e "        ${BOLD}-d${NOATT}         deletes the SD Image after successful compression"
	echo -e "        ${BOLD}-f${NOATT}         forces overwrite of 'sdimage'.gz if it exists"
	echo -e "        ${BOLD}-L logfile${NOATT} writes rsync log to 'logfile'"
	echo -e "        ${BOLD}-i sdcard${NOATT}  specifies the SD Card location (default: $SDCARD)"
	echo -e "        ${BOLD}-s Mb${NOATT}      specifies the size of image in MB (default: Size of $SDCARD)"
	echo -e ""
	echo -e "Examples:"
	echo -e ""
	echo -e "    ${MYNAME} start -c /path/to/imx6_backup.img"
	echo -e "        starts backup to 'imx6_backup.img', creating it if it does not exist"
	echo -e ""
	echo -e "    ${MYNAME} start -c -s 8000 /path/to/imx6_backup.img"
	echo -e "        starts backup to 'imx6_backup.img', creating it with a size of 8000mb." 
	echo -e "        You are responsible for defining a size sufficiant to hold all data."
	echo -e ""
	echo -e "    ${MYNAME} start /path/to/\$(uname -n).img"
	echo -e "        uses the RPi's hostname as the SD Image filename"
	echo -e ""
	echo -e "    ${MYNAME} start -cz /path/to/\$(uname -n)-\$(date +%Y-%m-%d).img"
	echo -e "        uses the RPi's hostname and today's date as the SD Image filename,"
	echo -e "        creating it if it does not exist, and compressing it after backup"
	echo -e ""
	echo -e "    ${MYNAME} mount /path/to/\$(uname -n).img /mnt/rpi_image"
	echo -e "        mounts the RPi's SD Image in /mnt/rpi_image"
	echo -e ""
	echo -e "    ${MYNAME} umount /path/to/raspi-$(date +%Y-%m-%d).img"
	echo -e "        unmounts the SD Image from default mountdir (/mnt/raspi-$(date +%Y-%m-%d).img/)"
	echo -e ""
}

setup

# Read the command from command line
case ${1} in
	start|mount|umount|gzip|cloneid|showdf) 
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
if [ $(id -u) -ne 0 ]; then
	error "Please run as root. Try sudo."
fi

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
if [ -z ${IMAGE} ]; then
	error "No sdimage specified"
fi

# Check if sdimage exists
if [ ${opt_command} = umount ] || [ ${opt_command} = gzip ]; then
	if [ ! -f ${IMAGE} ]; then
		error "${IMAGE} does not exist"
	fi
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
if [ -z ${LOG} ]; then
	LOG=${IMAGE}-$(date +%Y%m%d%H%M%S).log
fi

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
	if [ ! -d ${MOUNTDIR} ]; then
		error "Mount point ${MOUNTDIR} does not exist"
	fi
fi

# Check if default mount point exists
if [ ${opt_command} = umount ]; then
	if [ ! -d ${MOUNTDIR} ]; then
		error "Default mount point ${MOUNTDIR} does not exist"
	fi
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
	gzip)
		do_compress
		;;
	cloneid)
		do_cloneid
		;;
	showdf)
		do_mount
		do_showdf
		do_umount
		;;
	*)
		error "Unknown command: ${opt_command}"
		;;
esac

exit 0
