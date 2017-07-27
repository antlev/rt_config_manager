#!/bin/bash
# Version 2.0
# This is a report script.
# It parses the system's configuration and
# produce a report about the real-time config
# It won't modify the system's config

TOLERATED_INTERRUPTIONS_NUMBER=100

GRUB_CONF_FILE="/etc/default/grub"
CPU_INFO_FILE="/proc/cpuinfo"
INTERRUPTION_FILE="/proc/interrupts"
CURRENT_CLOCKSOURCE="/sys/devices/system/clocksource/clocksource0/current_clocksource"
AVAILABLE_CLOCKSOURCE="/sys/devices/system/clocksource/clocksource0/available_clocksource"

# Variable set at 0 and will be set to 1 , if correctly configured
HYPERTHREADING=0
KERNEL_REALTIME=0
KERNEL_NOHZ=0
KERNEL_INTELIDLEMAXCSTATE=0
KERNEL_PROCESSORMAXCSTATE=0
KERNEL_IDLEPOOL=0
KERNEL_LAPICTIMER=0
KERNEL_ACPINOAPIC=0
IRQ=0
ISOLCPU=0
TSC_CLOCK=0
TSC_RELIABLE=0

# Global variables
nonIsolCoreTable=()
nbCore=0

main(){
	START=$(date +%s)
	clear # Clear the screen

	firstCheck
	preparation

	checkHyperThreading
	checkClock
	isolCpu
	checkIRQ
	checkKernel

	showResults
	END=$(date +%s)
	ELLAPSED_TIME=$[$END-$START]
	echo "Ellapsed time=$ELLAPSED_TIME second(s)"
}

########## FUNCTIONS ##########
firstCheck(){ # Checks that user has the root rights and that the files used in script exist.	
	if [ "$(id -u)" != "0" ]; then
	   echo "[ERROR] This script must be run as root" 1>&2
	   exit 1
	fi
	if [ ! -f $GRUB_CONF_FILE ]; then
	   echo "[ERROR] The file $GRUB_CONF_FILE does not exist"
	   echo "[ERROR] Please check your 'grub configuration file' location ($GRUB_CONF_FILE)"
	   exit 1
	fi
	if [ ! -f $CPU_INFO_FILE ]; then
	   echo "[ERROR] The file $CPU_INFO_FILE does not exist"
	   echo "[ERROR] Please check your 'cpuinfo' file location ($CPU_INFO_FILE)"
	   exit 1
	fi
	if [ ! -f $INTERRUPTION_FILE ]; then
	   echo "[ERROR] The file $INTERRUPTION_FILE does not exist"
	   echo "[ERROR] Please check your 'interrupts' file location ($INTERRUPTION_FILE)"
	   exit 1
	fi
}
preparation(){ # Set both variable : $nbCore and $NONISOLCOREETABLE
	if [ isIntel ]; then # Checks if the system architecture is Intel or not
		echo "[INFO] Interruptions counting less than $TOLERATED_INTERRUPTIONS_NUMBER are ignored"

		nbCore=$(lscpu | grep 'CPU(s):' | head -1 | cut -d ':' -f2 | sed 's/[^0-9]//g') # Count the number of cores

		parseIsolCores
	else
		echo "Your architecture isn't supported yet..."
		exit 1
	fi
}
parseIsolCores(){ # Parse the grub config file to spot which core has been isolated
	if [[ $(grep -v '#' $GRUB_CONF_FILE | grep 'isolcpus=[0-9,]*') ]]; then

    	ISOLCORES_STRING=$(grep -v '#' $GRUB_CONF_FILE | grep -o 'isolcpus=[0-9,]*' | cut -d '=' -f2) # Stock the isolated cores as a string
		
		IFS=',' read -r -a isolCoreTable <<< "$ISOLCORES_STRING"

		for (( i=0; i<$nbCore; i++ )) 
		do 							  # if not, we put it in a table stocking the non-isolated cores
			if [[ " ${isolCoreTable[*]} " != *" $i "* ]]; then
				nonIsolCoreTable+=($i)
			fi
		done
	else
		nonIsolCoreTable="NONE"
		isolCoreTable="NONE"

		echo "isolCoreTable:${isolCoreTable[@]}"
		echo "nonIsolCoreTable:${nonIsolCoreTable[@]}"

		echo "titi:${isolCoreTable[0]}"
	fi
}
isolCpu(){ # Print isolated cores and non isolated cores (those for the system).
		   # The program will always consider that the number of isolated cores is OK.
		   # However it will check if the isolated cores are optimised on the same socket.
	# IS NOW GLOBAL : nbCore=$(lscpu | grep 'CPU(s):' | head -1 | cut -d ':' -f2 | sed 's/[^0-9]//g') # Count the number of cores
	corePerSocket=$(lscpu | grep 'Core(s) per socket:' | head -1 | cut -d ':' -f2 | sed 's/[^0-9]//g') # Count the number of core per CPU
	nbSocket=$(lscpu | grep 'Socket(s):' | head -1 | cut -d ':' -f2 | sed 's/[^0-9]//g') # Count the number of Sockets

	if [[ ${#isolCoreTable[@]} -gt $nbCore ]]; then
		return
	fi

	# According to the number of non-isolated cores and the core per CPU, 
	nbSocketNonIsolMax=$(((${#nonIsolCoreTable[@]} / corePerSocket)+1)) 
	for (( i=0; i<=${#nonIsolCoreTable[@]}; i++))
	do
		# Proper to Intel architecture
		nonIsolSocket=$((nonIsolCoreTable[$i] % nbSocket)) # recover the CPU on which is the non-isolated core
		# If the CPU is not contained in the array nonIsolSocketTable, we append it
		if !( array_contains nonIsolSocketTable $nonIsolSocket ); then
			nonIsolSocketTable+=($nonIsolSocket) # nonIsolSocketTable contains all the sockets that contains a non-isolated core
		fi
	done


	echo "[INFO] Isolated core(s) : ${isolCoreTable[@]}"
	echo "[INFO] Core(s) reserved for system : ${nonIsolCoreTable[@]}"
	# echo "[INFO] Socket number containing isolated core(s) : ${isolSocketTable[@]} "

	# We now check that the number of CPU containing a non-isolated core, is not greater than the max that we calculate (nbSocketNonIsolMax)
	if [[ ${#nonIsolSocketTable[@]} -le nbSocketNonIsolMax ]]; then
		ISOLCPU=1
	fi
}
checkIRQ(){ # Checks that isolated cores are never interrupted more than the limit fixed on the variable 'TOLERATED_INTERRUPTIONS_NUMBER'
	IRQ=1  	# If a process interrupts too much a core, it will be notified on the screen and the results will show an error.
			# Interruptions on non-isolated cores are ignored 

	if [[ ${isolCoreTable[0]} == "NONE" ]]; then
		IRQ=666
		return		
	fi
	re='^[0-9]+$' # Regex used to check if a variable is numeric
		
	nbligne=`wc -l $INTERRUPTION_FILE | cut -d ' ' -f1`
	for (( j=2; j<=$nbligne; j++ )) 
	do
		interruptionNumber=$(sed -n "$j p" $INTERRUPTION_FILE  | awk "{print \$1}" | cut -d ':' -f1)
		interruptionDesc1=$(sed -n "$j p" $INTERRUPTION_FILE  | awk "{print \$$[$nbCore+2]}")
		interruptionDesc2=$(sed -n "$j p" $INTERRUPTION_FILE  | awk "{print \$$[$nbCore+3]}")

		if [[ $(sed -n "$j p" $INTERRUPTION_FILE | awk '{print $1}' | cut -d ':' -f1)  =~ $re ]]; then
			for (( col=1; col<=$nbCore; col++ ))
			do
				numberOfInterruption=$(sed -n "$j p" $INTERRUPTION_FILE  | awk "{print \$$[col+1]}")
				if [[ $numberOfInterruption -gt TOLERATED_INTERRUPTIONS_NUMBER ]]; then

					if ( array_contains nonIsolCoreTable $[$col-1] ); then
						:
					else
						echo "The isolated core $[$col-1] is interrupted ($numberOfInterruption times) by interrupt $interruptionNumber : $interruptionDesc1 $interruptionDesc2"
						IRQ=0
					fi
				fi
		 	done
		fi
	done
	if [[ IRQ -eq 0 ]]; then
		echo "[INFO] see interrupts in file : $INTERRUPTION_FILE"
	fi 
}
isIntel(){ # Returns 1 if the system architecture is Intel, otherwise, returns 0.
    if [[ $(lscpu | grep -i "intel") ]]; then
    	return 1
    else 
    	return 0
    fi
}
array_contains() { # 1st argument is a table, 2nd argument is the searched element
				   # Returns 1 if the element  has been find in the table, otherwise, returns 0
    local array="$1[@]"
    local seeking=$2
    local in=1
    for element in "${!array}"; do
        if [[ $element == $seeking ]]; then
            in=0
            break
        fi
    done
    return $in
}
checkHyperThreading(){ # Checks that Hyperthreading is off (Only one thread per core)
	threadPerCore=$(lscpu | grep 'Thread(s) per core:' | head -1 | cut -d ':' -f2 | sed 's/[^0-9]//g')
	if [[ threadPerCore -eq 1 ]]; then
		HYPERTHREADING=1
	fi
}
checkKernel(){ # Checks for the Kernel configuration...
	if [[ $(uname -a | grep -i 'rt-') ]]; then # unsensible to case
    	KERNEL_REALTIME=1
	fi
	if [[ $(grep -v '#' $GRUB_CONF_FILE | grep 'nohz' | sed "s/ //g" | grep 'nohz=off') ]]; then # invert grep (match if the occurence is NOT found)
		KERNEL_NOHZ=1
	fi
	if [[ $(grep -v '#' $GRUB_CONF_FILE  | grep -o 'intel_idle\.max_cstate=[0-9]*\s' | cut -d '=' -f2 | cut -d ' ' -f1) -eq 0 ]]; then # -o select only the parts of the string which match
		KERNEL_INTELIDLEMAXCSTATE=1
	fi

	if [[ $(grep -v '#'  $GRUB_CONF_FILE | grep -o 'processor.max_cstate=[0-9]*\s' | cut -d '=' -f2 | cut -d ' ' -f1) -eq 0 ]]; then
		KERNEL_PROCESSORMAXCSTATE=1
	fi
	if [[ $(grep -v '#' $GRUB_CONF_FILE |  grep 'idle' | sed "s/ //g" | grep 'idle=poll' ) ]]; then
		KERNEL_IDLEPOOL=1
	fi
	if [[ $(grep -v '#' $GRUB_CONF_FILE | grep 'lapic_timer_c2_ok') ]]; then
		KERNEL_LAPICTIMER=1
	fi
	if [[ $(grep -v '#' $GRUB_CONF_FILE | grep 'noapic') ]]; then
		KERNEL_ACPINOAPIC=1
	fi
}
checkClock(){  # Checks that used clock is TSC
	if [[ $(cat $CURRENT_CLOCKSOURCE)=tsc ]]; then
		TSC_CLOCK=1
	else
		if ![[ $( cat $AVAILABLE_CLOCKSOURCE | grep 'tsc') ]]; then
			echo "Cannot find TSC clock on system"
		fi
	fi

	if [[ $( cat $GRUB_CONF_FILE | grep 'tsc=reliable' | grep -v '#') ]]; then
		TSC_RELIABLE=1
	fi
}
showResults(){ # Display the results in table form
	echo "-----------------------------------------------"
	echo "|           Configuration Checking            |"
	echo "|---------------------------------------------|"
	echo "|****************** RESULTS ******************|"
	echo "|---------------------------------------------|"
	echo "|            Config           |     Status    |"
	echo "|----------------------------------------------"
	if [[ $KERNEL_REALTIME -eq 0 ]]; then
		echo "|       KERNEL_REALTIME       |    [ERROR]    |"
	else
		echo "|       KERNEL_REALTIME       |     [OK]      |"
	fi
	if [[ $HYPERTHREADING -eq 0 ]]; then
		echo "|        HYPERTHREADING       |    [ERROR]    |"
	else
		echo "|        HYPERTHREADING       |     [OK]      |"
	fi
	if [[ $KERNEL_NOHZ -eq 0 ]]; then
		echo "|         KERNEL_NOHZ         |    [ERROR]    |"
	else 
		echo "|         KERNEL_NOHZ         |     [OK]      |"
	fi
	if [[ $KERNEL_INTELIDLEMAXCSTATE -eq 0 ]]; then
		echo "|  KERNEL_INTELIDLEMAXCSTATE  |    [ERROR]    |"
	else
		echo "|  KERNEL_INTELIDLEMAXCSTATE  |     [OK]      |"
	fi
	if [[ KERNEL_PROCESSORMAXCSTATE -eq 0 ]]; then
		echo "|  KERNEL_PROCESSORMAXCSTATE  |    [ERROR]    |"
	else 
		echo "|  KERNEL_PROCESSORMAXCSTATE  |     [OK]      |"
	fi
	if [[ KERNEL_IDLEPOOL -eq 0 ]]; then
		echo "|        KERNEL_IDLEPOOL      |    [ERROR]    |"
	else
		echo "|        KERNEL_IDLEPOOL      |     [OK]      |"
	fi
	if [[ $KERNEL_LAPICTIMER -eq 0 ]]; then
		echo "|       KERNEL_LAPICTIMER     |    [ERROR]    |"
	else
		echo "|       KERNEL_LAPICTIMER     |     [OK]      |"
	fi
	if [[ KERNEL_ACPINOAPIC -eq 0 ]]; then
		echo "|       KERNEL_ACPINOAPIC     |    [ERROR]    |"
	else
		echo "|       KERNEL_ACPINOAPIC     |     [OK]      |"

	fi
	if [[ ISOLCPU -eq 0 ]]; then
		echo "|           ISOLCPU           |    [ERROR]    |"
	else
		echo "|           ISOLCPU           |     [OK]      |"
	fi
	if [[ IRQ -eq 0 ]]; then
		echo "|           IRQ               |    [ERROR]    |"
	elif [[ IRQ -eq 1 ]]; then
		echo "|           IRQ               |     [OK]      |"
	else
		echo "|           IRQ               |   [SKIPPED]   |"
	fi
	if [[ TSC_CLOCK -eq 0 ]]; then
		echo "|           TSC_CLOCK         |    [ERROR]    |"
	else
		echo "|           TSC_CLOCK         |     [OK]      |"
	fi
	if [[ TSC_RELIABLE -eq 0 ]]; then
		echo "|         TSC_RELIABLE        |    [ERROR]    |"
	else
		echo "|         TSC_RELIABLE        |     [OK]      |"
	fi
	echo "|*********************************************|"
	echo "|Unfortunatly we are not able to spot if the  |"
	echo "|TurboBoost is active...                      |"
	echo "|Please check by yourself that the TurboBoost |"
	echo "|is disable                                   |"
	echo "-----------------------------------------------"

}
#Execute the main program
main
