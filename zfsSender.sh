#!/bin/bash -x

# Styling
TERM=xterm-256color
red="$(tput setaf 1)"
green="$(tput setaf 2)"
yellow="$(tput setaf 3)"
magenta="$(tput setaf 5)"
cyan="$(tput setaf 6)"
bold="$(tput bold)"
reset="$(tput sgr0)"

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

# Make sure zfs is installed

#zfsCheck=$( zfs version 2>&1 > /dev/null )
#if ! [[ $? = 0 ]]; then
#	echo -e "${red}${bold}Error!${yellow} ZFS does not appear to be installed on this machine!${reset}"
#	exit 1
#fi

if ! [[ $sourceDS ]]; then
        echo -n "${yellow}${bold}Enter the SOURCE dataset:${reset} "
        read -r sourceDS
fi

if ! [[ $destinationDS ]]; then
        echo -n "${yellow}${bold}Enter the DESTINATION dataset:${reset} "
        read -r destinationDS
fi

if ! [[ $firstSnap ]]; then
        echo -n "${yellow}${bold}Initial snapshot was not specified.  Using first available snapshot - "
	firstSnap=$( zfs list -o name -H -t snapshot -r $sourceDS | head -n1 | grep -o "@.*" | sed -e 's/@//' )
	echo -e "$firstSnap"
fi

if ! [[ $snapCount ]] | [[ $rangeEnd ]]; then
        echo -e "${yellow}${bold}No end snapshot or snapshot count was entered.  Sending all snapshots after $firstSnap.${reset}"
	snapCount="all"
fi

if [[ $sourceServer ]]; then
	localOnly=0
else
	echo "${yellow}${bold}No source server was specified.  Running in local mode.."
	localOnly=1
fi

if [[ $localOnly = 0 ]]; then
        if ! [[ $sshUser ]]; then
                echo -e "${yellow}${bold}SSH user name was not specified.  Using $( whoami ).."
                sshUser=$( whoami )
        fi
fi

function sshCmd {
	SOURCE_CONTROL_PATH="~/.ssh/ssh-root-$sourceServer-22"
	SOURCE_SSH_PID=$( ssh -O check -o ControlPath=$SOURCE_CONTROL_PATH $sshUser@$sourceServer 2>&1 | grep "Master running" | awk '{print $3}' | sed -e 's/pid\=//' -e 's/(//' -e 's/)//' )
	if ! [[ $SOURCE_SSH_PID ]]; then
		echo -n "${bold}${yellow}Opening SSH session to $sourceServer..${reset}"
		ssh -N -q -o StrictHostKeyChecking=no -o ControlMaster=yes -o ControlPath=$SOURCE_CONTROL_PATH $sshUser@$sourceServer &
		if [[ $? = 0 ]]; then
	        	echo -e "${green}${bold}Ok!${reset}"
		else
			echo -e "${red}${bold}Error!${reset}"
			echo -e "\n\n${yellow}${bold}Unable to establish SSH connection to $SOURCE_SERVER.  Exiting${reset}"
			exit 1
		fi
	fi
	ssh -q -o StrictHostKeyChecking=no -o ControlMaster=no -o ControlPath=$SOURCE_CONTROL_PATH $sshUser@$sourceServer $@
}

function cleanUp {
        echo -en "\n\n${magenta}${bold}Closing SSH sessions.. "
        SSH_PID=$( ssh -O check -o ControlPath=$SOURCE_CONTROL_PATH $sourceServer 2>&1 | grep "Master running" | awk '{print $3}' | sed -e 's/pid\=//' -e 's/(//' -e 's/)//' )
	DEST_SSH_PID=$( ssh -O check -o ControlPath=$DEST_CONTROL_PATH $destServer 2>&1 | grep "Master running" | awk '{print $3}' | sed -e 's/pid\=//' -e 's/(//' -e 's/)//' )
	if [[ $SSH_PID ]]; then
                for PID in "$SSH_PID"; do
			ssh -q -O stop -o ControlPath=$SOURCE_CONTROL_PATH $sshUser@$sourceServer
		done
		SSH_PID=$( ssh -O check -o ControlPath=$SOURCE_CONTROL_PATH $sourceServer 2>&1 | grep "Master running" | awk '{print $3}' | sed -e 's/pid\=//' -e 's/(//' -e 's/)//' )
		if ! [[ $SSH_PID ]]; then
			echo -e "${yellow}${bold}Unable to establish SSH connection to $sourceServer.  Exiting.${reset}"
			cleanUp
		fi
	fi
	if [[ $DEST_SSH_PID ]]; then
		for PID in "$DEST_SSH_PID"; do
			ssh -q -O stop -o ControlPath=$SOURCE_CONTROL_PATH $sshUser@$destServer
		done
		DEST_SSH_PID=$( ssh -O check -o ControlPath=$DEST_CONTROL_PATH $destServer 2>&1 | grep "Master running" | awk '{print $3}' | sed -e 's/pid\=//' -e 's/(//' -e 's/)//' )
                if ! [[ $DEST_SSH_PID ]]; then
                        echo -e "${yellow}${bold}Unable to establish SSH connection to $destServer.  Exiting.${reset}"
			cleanUp
                fi
        fi
        if [[ $? = 0 ]]; then
        	echo -e "${bold}${green}Ok!${reset}"
        fi
}

# Ensure source dataset exists

if [[ $local = 1 ]]; then
	if ! [[ $( zfs list -o name -H -r $sourceDS ) ]]; then
		echo -e "${red}${bold}Error!${yellow}  The source dataset does not exist, or the zpool is not imported!"
 		exit 1
	fi
else
	sshCmd "zfs list -o name -H -r $sourceDS" 2&>1 > /dev/null
	if ! [[ $? = 0  ]]; then
		echo -e "${red}${bold}Error!${yellow}  The source dataset does not exist on $sourceServer, or the zpool is not imported!"
                exit 1
        fi
fi

# Generate and print list of source napshots


if [[ $snapCount = "all" ]]; then
	fullSourceList=$( zfs list -o name -r $sourceDS -H -t snapshot -o name )
	snaps=$( echo $fullSourceList | grep -o "$sourceDS@$firstSnap.*" )
	for snap in $snaps; do
		snapList+=($snap)
	done
else
	snaps=$( grep -A"$snapCount" -o "$sourceDS@$firstSnap" <(zfs list -o name -r $sourceDS -H -t snapshot -o name ) )
	for snap in $snaps; do
		snapList+=($snap)
	done
fi

if ! [[ ${snapList[*]} ]]; then
	echo -e "${red}${bold}Error!  Unable to generate a list of snapshots!"
 	exit 1
 fi

for snap in "${snapList[@]}"; do
	snapName=$( echo "$snap" | grep -o "@.*" | sed -e 's/@//' )
	snapNameList+=($snapName)
done

echo "${cyan}${snapNameList[@]}${reset}"

echo -e "${yellow}${bold}Snapshot List:${reset}\n"

echo -en "\n${yellow}${bold}Would you like to proceed?${reset} "

read -r "yn"

while ! [[ $yn = @(y|Y|N|n) ]]; do
        echo -n "Would you like to proceed (y/n only)? "
        read -r "yn"
done

if ! [[ $yn = @(y|Y) ]]; then
	echo "${red}${bold}You've chosen to not proceed.  Exiting.${reset}"
	exit 0
fi

# Resume function

function resume {
	destLastSnap=$( zfs list -t snapshot -o name -r $destinationDS -H | tail -n1 | grep -o "@.*" | sed -e 's/@//' )
        destNextSnap=$( echo ${snapNameList[*]} | grep -o "$destLastSnap.*" | awk '{print $2}' )
	lastSnap=$( echo "${snapNameList[-1]}" )
	if ! [[ $destNextSnap ]]; then
		echo -e "\n${green}${bold}Transfer is complete.${reset}\n\n"
		${cyan}zfs list -t snapshot -o name,creation -r $destinationDS${reset}
		exit
	else
		echo "${yellow}${bold}Beginning incremental send from ${cyan}$destLastSnap${yellow} to ${cyan}$destNextSnap${yellow}..${reset}"
		if [[ localOnly = 1 ]]; then
	        	snapSize=$( zfs send -i @$destLastSnap $sourceDS@$destNextSnap -nvP | tail -n1 | awk '{print $2}' )
	        elif [[ push=1 ]]; then
			snapSize=$( sshCmd zfs send -i @$destLastSnap $sourceDS@$destNextSnap -nvP | tail -n1 | awk '{print $2}' )
   		else
     			snapSize=$( zfs send -i @$destLastSnap $sourceDS@$destNextSnap -nvP | tail -n1 | awk '{print $2}' )
		fi
		snapBytes=$( numfmt --from auto $snapSize )
		if [[ localOnly = 1 ]]; then
			zfs send -i @$destLastSnap $sourceDS@$destNextSnap | pv --size $snapBytes | zfs recv $destinationDS
		elif [[ push=1 ]]; then
			zfs send -i @$destLastSnap $sourceDS@$destNextSnap | pv --size $snapBytes | sshCmd zfs recv $destinationDS
   		else
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
if [[ push=1 ]]; then
	destCheck=$( sshCmd zfs send $sourceDS@$firstSnap -nvP | tail -n1 | awk '{print $2}' )
else 
	destCheck=$( zfs send $sourceDS@$firstSnap -nvP | tail -n1 | awk '{print $2}' )
fi

if [[ $destCheck ]]; then
	if [[ push=1 ]]; then
		destLastSnap=$( sshCmd zfs list -t snapshot -o name -r $destinationDS -H | tail -n1 | grep -o "@.*" | sed -e 's/@//' )
	else 
		destLastSnap=$( zfs send $sourceDS@$firstSnap -nvP | tail -n1 | awk '{print $2}' )
	fi
 
	lastSnapCheck=$( echo ${snapNameList[*]} | grep -o "$destLastSnap" )
 
	if ! [[ $lastSnapCheck ]]; then 
		echo "${red}${bold}Destination dataset already exists, but the snapshots don't match!  Exiting.${reset}"
	else
		resume
	fi
else
	firstSnap=${snapNameList[0]}
	echo "${yellow}${bold}Beginning full send of ${green}$sourceDS${yellow} beginning with snapshot ${cyan}$firstSnap${yellow}..${reset}"
	if [[ $localOnly = 1 ]]; then
		snapSize=$( zfs send $sourceDS@$firstSnap -nvP | tail -n1 | awk '{print $2}' )
	elif [[ push=1 ]]; then
		snapSize=$( zfs send $sourceDS@$firstSnap -nvP | tail -n1 | awk '{print $2}' )
  	else 
   		snapSize=$( sshCmd zfs send $sourceDS@$firstSnap -nvP | tail -n1 | awk '{print $2}' )
	fi
	snapBytes=$( numfmt --from auto $snapSize )
	if [[ $localOnly = 1 ]]; then
		zfs send $sourceDS@$firstSnap | pv --size $snapBytes | zfs recv $destinationDS
	elif [[ push=1 ]]; then
		sshCmd zfs send $sourceDS@$firstSnap | pv --size $snapBytes | zfs recv $destinationDS
  	else
   		zfs send $sourceDS@$firstSnap | pv --size $snapBytes | sshCmd zfs recv $destinationDS
	fi
fi

	lastSnap=$( echo "${snapNameList[-1]}" )

	if [[ push=1 ]]; then
		destLastSnap=$( sshCmd zfs list -t snapshot -o name -r $destinationDS -H | tail -n1 | grep -o "@.*" | sed -e 's/@//' )
	else 
		destLastSnap=$( zfs send $sourceDS@$firstSnap -nvP | tail -n1 | awk '{print $2}' )
	fi

 
if ! [[ $destLastSnap = $lastSnap ]]; then
	resume
fi
