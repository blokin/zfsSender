#!/bin/bash -x
set -eu

# Styling
TERM=xterm-256color
red="$(tput setaf 1)"
green="$(tput setaf 2)"
yellow="$(tput setaf 3)"
magenta="$(tput setaf 5)"
cyan="$(tput setaf 6)"
bold="$(tput bold)"
reset="$(tput sgr0)"

# Command validation function
function check_command {
    command -v "$1" >/dev/null 2>&1 || { echo >&2 "${red}${bold}Error:${reset} $1 is required but not installed. Exiting."; exit 1; }
}

# Validate required commands
check_command "zfs"
check_command "ssh"
check_command "pv"

# Help function
function help {
    echo -e "\nThis script was written to aid in the sending and receiving of specific ZFS snapshots from one Zpool to another.\n"
    echo -e "\nScript usage:\n"
    echo -e "\n./zfsSender.sh -o [source dataset] -d [destination dataset]\n"
    echo -e "\nOptions:\n"
    echo -e "\n-o  -  Source dataset"
    echo -e "\n-d  -  Destination dataset"
    echo -e "\n-s  -  IP address of the remote host machine with the source zpool imported."
    echo -e "\n-u  -  SSH username of remote host."
    echo -e "\n-f  -  Initial snapshot to send"
    echo -e "\n-c  -  Number of snapshots to send after the initial.  (If you set this to 4, you will transfer 5 total snapshots)"
    echo -e "\n\n-h  -  View help menu"
}

# Logging function
function log_message {
    local log_level=$1
    local message=$2
    local log_file="script.log"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    if [[ $log_level = INFO ]]; then
    	echo "$timestamp ${cyan}[${green}${bold}$log_level${reset}${cyan}] ${reset}$message" >> $log_file
    elif [[ $log_level = ERROR ]]; then
    	echo "$timestamp ${cyan}[${red}${bold}$log_level${reset}${cyan}] ${reset}$message" >> $log_file
    elif [[ $log_level = WARNING ]]; then
    	echo "$timestamp ${cyan}[${yellow}${bold}$log_level${reset}${cyan}] ${reset}$message" >> $log_file
    elif [[ $log_level = DEBUG ]]; then
    	echo "$timestamp ${cyan}[${magenta}${bold}$log_level${reset}${cyan}] ${reset}$message" >> $log_file
     fi
}

# Set variables and gather information
while getopts ':o:d:f:c:r:s:u:P' opt ; do
    case $opt in
        o) sourceDS=${OPTARG} ;;
        d) destinationDS=${OPTARG} ;;
        f) firstSnap=${OPTARG} ;;
        c) snapCount=${OPTARG} ;;
        r) rangeEnd=${OPTARG} ;;
        s) sourceServer=${OPTARG} ;;
        u) sshUser=${OPTARG} ;;
        P) push=1
        \?) echo "${red}${bold}Invalid option -$OPTARG${reset}"; help; exit ;;
    esac
done

if ! [[ $sourceDS ]]; then
    echo -n "${yellow}${bold}Enter the SOURCE dataset:${reset} "
    read -r sourceDS
fi

if ! [[ $destinationDS ]]; then
    echo -n "${yellow}${bold}Enter the DESTINATION dataset:${reset} "
    read -r destinationDS
fi

if ! [[ $firstSnap ]]; then
    firstSnap=$( timeout 180 zfs list -o name -H -t snapshot -r $sourceDS | head -n1 | grep -o "@.*" | sed -e 's/@//' )
    log_message "INFO" "Initial snapshot was not specified.  Using first available snapshot - $firstSnap"${reset}
fi

if ! [[ $snapCount ]] | [[ $rangeEnd ]]; then
    log_message "INFO" "${yellow}${bold}No end snapshot or snapshot count was entered.  Sending all snapshots after $firstSnap.${reset}"
    snapCount="all"
fi

if [[ $sourceServer ]]; then
    localOnly=0
else
    log_message "INFO" "${yellow}${bold}No source server was specified.  Running in local mode.."
    localOnly=1
fi

if [[ $localOnly = 0 ]]; then
    if ! [[ $sshUser ]]; then
    	sshUser=$( whoami )
        log_message "INFO" "${yellow}${bold}SSH user name was not specified.  Using $sshUser.."
    fi
fi

function sshCmd {
    if [[ $sourceServer ]]; then
        SOURCE_CONTROL_PATH="~/.ssh/ssh-root-$sourceServer-22"
        SOURCE_SSH_PID=$( ssh -O check -o ControlPath=$SOURCE_CONTROL_PATH $sshUser@$sourceServer 2>&1 | grep "Master running" | awk '{print $3}' | sed -e 's/pid\=//' -e 's/(//' -e 's/)//' )
        if ! [[ $SOURCE_SSH_PID ]]; then
            log_message "INFO" "Opening SSH session to $sourceServer.."
            timeout 30 ssh -N -q -o StrictHostKeyChecking=no -o ControlMaster=yes -o ControlPath=$SOURCE_CONTROL_PATH $sshUser@$sourceServer &
            if ! [[ $? = 0 ]]; then
                log_message "ERROR" "Unable to establish SSH connection to $sourceServer.  Exiting"
	        exit 1
            fi
	    timeout 30 ssh -q -o StrictHostKeyChecking=no -o ControlMaster=no -o ControlPath=$SOURCE_CONTROL_PATH $sshUser@$sourceServer $@
    fi
}

# Ensure source dataset exists
if [[ $localOnly = 1 ]]; then
    if ! [[ $( timeout 180 zfs list -o name -H -r $sourceDS ) ]]; then
        log_message "ERROR" "The source dataset does not exist, or the zpool is not imported!"
        exit 1
    fi
else
    sshCmd "timeout 180 zfs list -o name -H -r $sourceDS" 2&>1 > /dev/null
    if ! [[ $? = 0  ]]; then
        log_message "ERROR" "The source dataset does not exist on $sourceServer, or the zpool is not imported!"
        exit 1
    fi
fi

# Generate and print list of source snapshots
if [[ $snapCount = "all" ]]; then
    fullSourceList=$( timeout 180 zfs list -o name -r $sourceDS -H -t snapshot -o name )
    snaps=$( echo $fullSourceList | grep -o "$sourceDS@$firstSnap.*" )
    for snap in $snaps; do
        snapList+=($snap)
    done
else
    snaps=$( grep -A"$snapCount" -o "$sourceDS@$firstSnap" <(timeout 180 zfs list -o name -r $sourceDS -H -t snapshot -o name ) )
    for snap in $snaps; do
        snapList+=($snap)
    done
fi

if ! [[ ${snapList[*]} ]]; then
    log_message "ERROR" "Unable to generate a list of snapshots!"
    exit 1
fi

for snap in "${snapList[@]}"; do
    snapName=$( echo "$snap" | grep -o "@.*" | sed -e 's/@//' )
    snapNameList+=($snapName)
done

log_message "INFO" "${snapNameList[@]}"

log_message "INFO" "Snapshot List:${reset}\n"

echo -en "\n${yellow}${bold}Would you like to proceed?${reset} "
read -r "yn"

while ! [[ $yn = @(y|Y|N|n) ]]; do
    echo -n "Would you like to proceed (y/n only)? "
    read -r "yn"
done

if ! [[ $yn = @(y|Y) ]]; then
    log_message "ERROR" "You've chosen to not proceed.  Exiting."
    exit 0
fi

# Resume function
function resume {
    destLastSnap=$( timeout 180 zfs list -t snapshot -o name -r $destinationDS -H | tail -n1 | grep -o "@.*" | sed -e 's/@//' )
    destNextSnap=$( echo ${snapNameList[*]} | grep -o "$destLastSnap.*" | awk '{print $2}' )
    lastSnap=$( echo "${snapNameList[-1]}" )
    if ! [[ $destNextSnap ]]; then
        log_message "INFO" "Transfer is complete."
        log_message "INFO" "$( timeout 180 zfs list -t snapshot -o name,creation -r $destinationDS )"
        exit
    else
        log_message "INFO" "Beginning incremental send from ${cyan}$destLastSnap${yellow} to ${cyan}$destNextSnap${yellow}..${reset}"
        if [[ localOnly = 1 ]]; then
            snapSize=$( zfs send -i @$destLastSnap $sourceDS@$destNextSnap -nvP | tail -n1 | awk '{print $2}' )
        elif [[ $push = 1 ]]; then
            snapSize=$( sshCmd zfs send -i @$destLastSnap $sourceDS@$destNextSnap -nvP | tail -n1 | awk '{print $2}' )
        else
            snapSize=$( zfs send -i @$destLastSnap $sourceDS@$destNextSnap -nvP | tail -n1 | awk '{print $2}' )
        fi
        snapBytes=$( numfmt --from auto $snapSize )
        if [[ localOnly = 1 ]]; then
	    log_message "INFO" "Starting local ZFS send from $sourceDS to $destinationDS."
            zfs send -i @$destLastSnap $sourceDS@$destNextSnap | pv --size $snapBytes | zfs recv $destinationDS
        elif [[ $push = 1 ]]; then
	    log_message "INFO" "Starting ZFS send over SSH from local $sourceDS to remote $destinationDS on $destServer."
            zfs send -i @$destLastSnap $sourceDS@$destNextSnap | pv --size $snapBytes | sshCmd zfs recv $destinationDS
        else
	    log_message "INFO" "Starting ZFS send over SSH from remote $sourceDS on $sourceServer to local $destinationDS."
            sshCmd zfs send -i @$destLastSnap $sourceDS@$destNextSnap | pv --size $snapBytes | zfs recv $destinationDS
        fi
    fi
    if ! [[ $destLastSnap = $lastSnap ]]; then
        resume
    else
        exit
    fi
}

# Check to see if destination exists
if [[ $push = 1 ]]; then
    destCheck=$( sshCmd zfs send $sourceDS@$firstSnap -nvP | tail -n1 | awk '{print $2}' )
else
    destCheck=$( zfs send $sourceDS@$firstSnap -nvP | tail -n1 | awk '{print $2}' )
fi

if [[ $destCheck ]]; then
    if [[ $push = 1 ]]; then
        destLastSnap=$( sshCmd timeout 180 zfs list -t snapshot -o name -r $destinationDS -H | tail -n1 | grep -o "@.*" | sed -e 's/@//' )
    else
        destLastSnap=$( zfs send $sourceDS@$firstSnap -nvP | tail -n1 | awk '{print $2}' )
    fi

    lastSnapCheck=$( echo ${snapNameList[*]} | grep -o "$destLastSnap" )

    if ! [[ $lastSnapCheck ]]; then
        log_message "ERROR" "Destination dataset already exists, but the snapshots don't match!  Exiting."
	exit
    else
        resume
    fi
else
    firstSnap=${snapNameList[0]}
    log_message "INFO" "Beginning full send of $sourceDS beginning with snapshot $firstSnap."
    if [[ $localOnly = 1 ]]; then
        snapSize=$( zfs send $sourceDS@$firstSnap -nvP | tail -n1 | awk '{print $2}' )
    elif [[ $push = 1 ]]; then
        snapSize=$( zfs send $sourceDS@$firstSnap -nvP | tail -n1 | awk '{print $2}' )
    else
        snapSize=$( sshCmd zfs send $sourceDS@$firstSnap -nvP | tail -n1 | awk '{print $2}' )
    fi
    snapBytes=$( numfmt --from auto $snapSize )
    if [[ $localOnly = 1 ]]; then
        zfs send $sourceDS@$firstSnap | pv --size $snapBytes | zfs recv $destinationDS
    elif [[ $push = 1 ]]; then
        sshCmd zfs send $sourceDS@$firstSnap | pv --size $snapBytes | zfs recv $destinationDS
    else
        zfs send $sourceDS@$firstSnap | pv --size $snapBytes | sshCmd zfs recv $destinationDS
    fi
fi

lastSnap=$( echo "${snapNameList[-1]}" )

if [[ $push = 1 ]]; then
    destLastSnap=$( sshCmd timeout 180 zfs list -t snapshot -o name -r $destinationDS -H | tail -n1 | grep -o "@.*" | sed -e 's/@//' )
else
    destLastSnap=$( zfs send $sourceDS@$firstSnap -nvP | tail -n1 | awk '{print $2}' )
fi

if ! [[ $destLastSnap = $lastSnap ]]; then
    resume
fi
