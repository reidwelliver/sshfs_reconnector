#!/bin/bash


####################
# Global variables #
####################
#Global Run Variable
DO_RUN=1
#Global State of Mounts
FN_RESULT=0
#Host list from args
HOSTS=""
#Global list of hosts currently disconnected
PROB_HST=""
#Root of mounts
MNTROOT="/mnt/ssh"
#Verbosity
VERBOSE=0
#User to connect with
USER="root"
#Frequency of check
FREQ=58


###########################
# Print usage information #
###########################
function usage(){
cat << EOF
usage: $0 [options]

This script will manage SSHFS connections. It should be run with superuser priveledges.

OPTIONS:
   Sw   Option Ex.  [default (if appl.)]   Name        -  Description
----------------------------------------------------------------------------------------------------------------
   -s   'server1 server2 serverN'          Hostname(s) -  Servers to connect to, single quote for multiple
   -u   username    [default:root]         Username    -  Username to connect with (allow_other enabled)
   -f   60          [default:58]           Frequency   -  Frequency (sec) of health check. Must be positive int
   -d   '/pth/to'   [default:/mnt/ssh]     Local path  -  Each server mounts in /pth/to/<hostname>
   -q               [default:false]        Quick run   -  Checks for problems, mounts, exits instead of looping
   -v               [default:false]        Verbose     -  Prints all output
   -i               [default:false]        Info        -  Prints only helpful event messages
   -h                                      Help        -  Show help message
EOF
}


####################################################
# force disconnects and then reconnects all mounts #
# currently not called anywhere, but nice to have  #
####################################################
function reconnectAll(){
	for host in $HOSTS
	do

		isMnt=$(mount | grep $host)

		if [[ ! "$isMnt" ]]
		then
			if [ ! -d "$MNTROOT/$host" ]
			then
				 mkdir $MNTROOT/$host
			fi

			sshfs -o allow_other $USER@$host:/ $MNTROOT/$host
		else
			#force unmount (sshfs usually hangs as busy).
			#If force unmount fails, try again (2x usually sufficient)
			umount -f $MNTROOT/$host || umount -l -f $MNTROOT/$host
			sshfs -o allow_other $USER@$host:/ $MNTROOT/$host
		fi
	done
}


################################################################
# force disconnects and then reconnects all broken connections #
# This is determined by checkConnection and added to PROB_HST  #
################################################################
function reconnectProbs(){
	PROB_HST=( "$PROB_HST" )
	for host in $PROB_HST
	do
		isMnt=$(mount | grep $host)
		if [[ ! "$isMnt" ]]
		then
			if [ ! -d "$MNTROOT/$host" ]
			then
				 mkdir $MNTROOT/$host
			fi
			sshfs -o allow_other $USER@$host:/ $MNTROOT/$host
		else
			#force unmount (sshfs usually hangs as busy).
			#If force unmount fails, try again (2x usually sufficient)
			umount -f $MNTROOT/$host || umount -l -f $MNTROOT/$host
			sshfs -o allow_other $USER@$host:/ $MNTROOT/$host
		fi
		curtime=$(date +%T)
		echo "** [ $curtime ] Reconnect: reestablished SSHFS connection to $host"
	done
	#clear the problem host list
	PROB_HST=""
}


########################################################
# checks connection by seeing if lsing mount dir hangs #
# then checks to make sure dir has something in it     #
# Both are pretty sure canaries of broken sshfs mounts #
########################################################
function checkConnection(){
	FN_RESULT=0
	LOOP_FN_RESULT=0
	timeout=4

	for host in $HOSTS
	do
		ls $MNTROOT/$host &
		lspid=("$!")
		sleep .5
		while (($timeout > 0)); do
			#checks if ps exits, -0 sends no signal
			kill -0 $lspid && LOOP_FN_RESULT=1 || LOOP_FN_RESULT=0 && timeout=0
			if [[ $timeout -gt 0 ]]
			then
				sleep .5
				((timeout -= 1))
			fi
		 done

		 #ls is hanging, so there's probably some shennanigans going on
		 #let's kill it and tell reconnectProbs to do some work
		if [[ $LOOP_FN_RESULT -gt 0 ]]; then
			kill -s SIGTERM $lspid && kill -0 $lspid
			kill -s SIGKILL $lspid
		fi

		#check if the directory has files (discard errors to /dev/null)
		#if it doesn't, a mount is broken, and we want to reconnect
		hasfiles="$(ls -A $MNTROOT/$host 2> /dev/null)"
		if [[ ! "$hasfiles" ]]; then
			LOOP_FN_RESULT=1
		fi

		if [[ $LOOP_FN_RESULT -ge 1 ]]; then
			FN_RESULT=$LOOP_FN_RESULT
			PROB_HST="$host $PROB_HST"
			curtime=$(date +%T)
			echo "** [ $curtime ] checkConnection: host $host seems disconnected"
		fi
	done
	curtime=$(date +%T)
	echo "** [ $curtime ] checkConnection: Finished with status $FN_RESULT (0 = Good)"
}


##################################################################
# Pipe things here to filter the output based on verbosity set   #
# Considers anything with two stars at line beginning to be info #
# Only explicitly deals with stdout, so pipe stderr to stdout    #
##################################################################
function mngPrint(){
	while read data
	do
		if [[ $VERBOSE -eq 2 ]]; then
			echo "$data"
		elif [[ $VERBOSE -eq 1 ]]; then
			echo "$data" | grep '^\*\*'
		fi
	done
}


##############################
# Get Options from arguments #
##############################
while getopts “hqivu:s:f:d:” OPTION
do
     case $OPTION in
         h) #NOARG
             usage
             exit 1
             ;;
         q) #NOARG
             DO_RUN=0
             ;;
         i) #NOARG
             VERBOSE=1
             ;;
         v) #NOARG
             VERBOSE=2
             ;;
         s)
             HOSTS=$OPTARG
             ;;
         f)
             if [[ $OPTARG -gt 0 ]]; then
             	FREQ=$OPTARG
             else
             	usage
             	exit
             fi
             ;;
         u)
             USER=$OPTARG
             ;;
         d)
             MNTROOT=$OPTARG
             ;;

         ?) #NOARG
             usage
             exit
             ;;
     esac
done


###########################################################
# Main loop, and also a place to put some setup/breakdown #
###########################################################
function main(){
	curtime=$(date +%T)
	echo "** [ $curtime ] Managing SSHFS connections for hosts $HOSTS with user $USER, mounting locally in $MNTROOT"
	if [ ! -d "$MNTROOT" ]; then
		mkdir $MNTROOT
	fi
	
	if [[ "$HOSTS" ]]; then
		#Do it once for -q
		checkConnection
		curtime=$(date +%T)
		echo "** [ $curtime ] First Check completed with status $FN_RESULT (0 = Good)"
		if [[ $FN_RESULT -gt 0 ]]
		then
			reconnectProbs
		fi
		#Continue if looped
		while [[ $DO_RUN -gt 0 ]]
		do
			sleep $FREQ
			checkConnection
			if [[ $FN_RESULT -gt 0 ]]; then
				reconnectProbs
			fi
			curtime=$(date +%T)
			echo "** [ $curtime ] Check completed"
		done
	fi
	exit 0
}


############################################
# Actually run, pipe all to output manager #
############################################
main 2>&1 | mngPrint
exit 0
