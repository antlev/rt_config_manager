#!/bin/bash
# Version 2.0
# This is a configuration script.
# It parses the system's configuration and adapt it to the real-time config
# Modify only the grub configuration file (no other file are impacted)

TOLERATED_INTERRUPTIONS_NUMBER=100

GRUB_CONF_FILE="/etc/default/grub" # (read and write)
CPU_INFO_FILE="/proc/cpuinfo" # (read only)
INTERRUPTION_FILE="/proc/interrupts"  # (read only)
CURRENT_CLOCKSOURCE="/sys/devices/system/clocksource/clocksource0/current_clocksource"  # (read only)
AVAILABLE_CLOCKSOURCE="/sys/devices/system/clocksource/clocksource0/available_clocksource"  # (read only)
 
KERNEL_REALTIME=0 # Will be set to -1 if not RT
# Variable set at 0 and will be 
# set to 1 -> something has been add to the conf
# set to 2 -> something has been replaced in the conf
HYPERTHREADING=0
KERNEL_NOHZ=0
KERNEL_INTELIDLEMAXCSTATE=0
KERNEL_PROCESSORMAXCSTATE=0
KERNEL_IDLEPOLL=0
KERNEL_LAPICTIMER=0
KERNEL_ACPINOAPIC=0
KERNEL_ACPINOIRQ=0
IRQ=0
ISOLCPU=0
TSC_CLOCK=0
TSC_RELIABLE=0

# Global variables
nonIsolCoreTable=()
nbCore=0

main(){
	START=$(date +%s)

	firstCheck
	preparation

	checkHyperThreading
	checkClock
	isolCpu
	checkIRQ
	checkKernel

	clear # Clear the screen
	showResults
	END=$(date +%s)
	ELLAPSED_TIME=$[$END-$START]
	echo "Ellapsed time=$ELLAPSED_TIME second(s)"
}

########## FUNCTIONS ##########
firstCheck(){ # Checks that user has the root rights and that the files used in script exist.	
	if [ "$(id -u)" != "0" ]; then	   
	   exitOnError "This script must be run as root" 
	fi
	if [ ! -f $GRUB_CONF_FILE ]; then
	   exitOnError "The file $GRUB_CONF_FILE does not exist\nPlease check your 'grub configuration file' location ($GRUB_CONF_FILE)"
	fi
	if [ ! -f $CPU_INFO_FILE ]; then
	   exitOnError "The file $CPU_INFO_FILE does not exist\nPlease check your 'cpuinfo' file location ($CPU_INFO_FILE)"
	fi
	if [ ! -f $INTERRUPTION_FILE ]; then
	   exitOnError "The file $INTERRUPTION_FILE does not exist\nPlease check your 'interrupts' file location ($INTERRUPTION_FILE)"
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
	if [[ ! $(uname -a | grep -i 'rt-') ]]; then # unsensible to case
    	KERNEL_REALTIME=-1
	fi
	if [[ ! $(grep -v '#' $GRUB_CONF_FILE | grep 'lapic_timer_c2_ok') ]]; then
		# Appending 'lapic_timer_c2_ok'	
		$(sed -i $GRUB_CONF_FILE -e '/^[ ]*GRUB_CMDLINE_LINUX_DEFAULT/s/$/ lapic_timer_c2_ok/')
		KERNEL_LAPICTIMER=1
	fi
	if [[ ! $(grep -v '#' $GRUB_CONF_FILE | grep 'noapic') ]]; then
		# Appending 'noapic'	
		$(sed -i $GRUB_CONF_FILE -e '/^[ ]*GRUB_CMDLINE_LINUX_DEFAULT/s/$/ noapic/')
		KERNEL_ACPINOAPIC=1
	fi

	if [[ $(grep -v '#' $GRUB_CONF_FILE | grep 'nohz') ]]; then # invert grep (match if the occurence is NOT found)
		if [[ $(grep -v '#' $GRUB_CONF_FILE | grep 'nohz' | sed "s/ //g" | grep 'nohz=on') ]]; then # invert grep (match if the occurence is NOT found)
			# Replacing 'nohz=on' by 'nohz=off'
			$(sed -i $GRUB_CONF_FILE -e "s/^\([ ]*GRUB_CMDLINE_LINUX_DEFAULT.*nohz=\)on/\1off/" )
			KERNEL_NOHZ=2
		fi
	else
		# Appending 'nohz=off'
		$(sed -i $GRUB_CONF_FILE -e '/^[ ]*GRUB_CMDLINE_LINUX_DEFAULT/s/$/ nohz=off/')
		KERNEL_NOHZ=1
	fi

	if [[ $(grep -v '#' $GRUB_CONF_FILE |  grep 'idle') ]]; then
		if [[ $(grep -v '#' $GRUB_CONF_FILE | sed "s/ //g" | grep "idle= *[a-zA-Z0-9][a-zA-Z0-9]*") ]]; then # invert grep (match if the occurence is NOT found)
			# Replacing 'idle=something' by 'idle=poll'
			$(sed -i $GRUB_CONF_FILE -e "s/^\([ ]*GRUB_CMDLINE_LINUX_DEFAULT.*idle=\) *[a-zA-Z0-9][a-zA-Z0-9]*/\1poll/")
			KERNEL_IDLEPOLL=2
		fi
	else
		# Appending 'idle=poll'
		$(sed -i $GRUB_CONF_FILE -e '/^[ ]*GRUB_CMDLINE_LINUX_DEFAULT/s/$/ idle=poll/')
		KERNEL_IDLEPOLL=1
	fi

	if [[ $(grep -v '#' $GRUB_CONF_FILE |  grep 'acpi') ]]; then
		if [[ $(grep -v '#' $GRUB_CONF_FILE | sed "s/ //g" | grep "acpi= *[a-zA-Z0-9][a-zA-Z0-9]*") ]]; then # invert grep (match if the occurence is NOT found)
			# Replacing 'acpi=something' by 'acpi=noirq'
			$(sed -i $GRUB_CONF_FILE -e "s/^\([ ]*GRUB_CMDLINE_LINUX_DEFAULT.*acpi=\) *[a-zA-Z0-9][a-zA-Z0-9]*/\1noirq/")
			KERNEL_ACPINOIRQ=2
		fi
	else
		# Appending 'acpi=noirq'
		$(sed -i $GRUB_CONF_FILE -e '/^[ ]*GRUB_CMDLINE_LINUX_DEFAULT/s/$/ acpi=noirq/')
		KERNEL_ACPINOIRQ=1
	fi


	if [[ $(grep -v '#' $GRUB_CONF_FILE |  grep 'intel_idle\.max_cstate') ]]; then
		if [[ $(grep -v '#' $GRUB_CONF_FILE  | grep -o 'intel_idle\.max_cstate=[0-9]*\s' | cut -d '=' -f2 | cut -d ' ' -f1) -ne 0 ]]; then # -o select only the parts of the string which match
			# Replacing old value by 0
			$(sed -i $GRUB_CONF_FILE -e "s/^\([ ]*GRUB_CMDLINE_LINUX_DEFAULT.*intel_idle\.max_cstate=\) *[a-zA-Z0-9][a-zA-Z0-9]*/\10/")
			KERNEL_INTELIDLEMAXCSTATE=2
		fi
	else
		# Appending 'intel_idle\.max_cstate=0'
		$(sed -i $GRUB_CONF_FILE -e '/^[ ]*GRUB_CMDLINE_LINUX_DEFAULT/s/$/ intel_idle\.max_cstate=0/')
		KERNEL_INTELIDLEMAXCSTATE=1
	fi

	if [[ $(grep -v '#' $GRUB_CONF_FILE |  grep 'processor\.max_cstate') ]]; then
		if [[ $(grep -v '#' $GRUB_CONF_FILE  | grep -o 'processor\.max_cstate=[0-9]*\s' | cut -d '=' -f2 | cut -d ' ' -f1) -ne 0 ]]; then # -o select only the parts of the string which match
			# Replacing old value by 0
			$(sed -i $GRUB_CONF_FILE -e "s/^\([ ]*GRUB_CMDLINE_LINUX_DEFAULT.*processor\.max_cstate=\) *[a-zA-Z0-9][a-zA-Z0-9]*/\10/")
			KERNEL_PROCESSORMAXCSTATE=2
		fi
	else
		# Appending 'processor.max_cstate=0'
		$(sed -i $GRUB_CONF_FILE -e '/^[ ]*GRUB_CMDLINE_LINUX_DEFAULT/s/$/ processor\.max_cstate=0/')
		KERNEL_PROCESSORMAXCSTATE=1
	fi
}
# # Return the correct line in grub conf file to be edited
# spotCorrectLineInGrubConf(){
# 	if [[ ! $(grep -n -v '#' $GRUB_CONF_FILE | grep 'GRUB_CMDLINE_LINUX_DEFAULT') | wc -l) -eq 1 ]]; then
# 		exitOnError "$GRUB_CONF_FILE seems to be corrupted"
# 	else
# 		return $(grep -n -v '#' $GRUB_CONF_FILE | grep 'GRUB_CMDLINE_LINUX_DEFAULT' | cut -d':' -f1) 
# 	fi
# }
exitOnError(){
	   printf "[ERROR] $1" 1>&2
	   exit 1
}
checkClock(){  # Checks that used clock is TSC
	if [[ ! $(cat $CURRENT_CLOCKSOURCE)=tsc ]]; then
		if [[ ! $( cat $AVAILABLE_CLOCKSOURCE | grep 'tsc') ]]; then
			TSC_CLOCK=-1
		else
			echo "tsc" > $CURRENT_CLOCKSOURCE
			TSC_CLOCK=1
		fi
	fi
	if [[ ! $(grep -v '#' $GRUB_CONF_FILE | grep 'tsc' | sed "s/ //g" | grep 'tsc=reliable') ]]; then
		# Appending 'tsc=reliable'
		$(sed -i $GRUB_CONF_FILE -e '/^[ ]*GRUB_CMDLINE_LINUX_DEFAULT/s/$/ tsc=reliable/')
		TSC_RELIABLE=1
	fi
showResults(){ # Display the results in table form
	echo "-----------------------------------------------"
	echo "|           Configuration Checking            |"
	echo "|---------------------------------------------|"
	echo "|****************** RESULTS ******************|"
	echo "|---------------------------------------------|"
	echo "|            Config           |     Status    |"
	echo "|----------------------------------------------"
	if [[ $KERNEL_REALTIME -eq -1 ]]; then
		echo "|       KERNEL_REALTIME       |    [ERROR]    |"
	else
		echo "|       KERNEL_REALTIME       |     [OK]      |"
	fi
	# if [[ $HYPERTHREADING -eq 0 ]]; then
	# 	echo "|        HYPERTHREADING       |    [ERROR]    |"
	# else
	# 	echo "|        HYPERTHREADING       |     [OK]      |"
	# fi
	if [[ $KERNEL_NOHZ -eq 1 ]]; then
		echo "|         KERNEL_NOHZ         |    [ADDED]    |"
	elif [[ $KERNEL_NOHZ -eq 2 ]]; then
		echo "|         KERNEL_NOHZ         |   [REPLACED]  |"
	else
		echo "|         KERNEL_NOHZ         |     [OK]      |"
	fi
	if [[ $KERNEL_IDLEPOLL -eq 1 ]]; then
		echo "|       KERNEL_IDLEPOLL       |    [ADDED]    |"
	elif [[ $KERNEL_IDLEPOLL -eq 2 ]]; then
		echo "|       KERNEL_IDLEPOLL       |   [REPLACED]  |"
	else
		echo "|       KERNEL_IDLEPOLL       |     [OK]      |"
	fi
	if [[ $KERNEL_LAPICTIMER -eq 1 ]]; then
		echo "|      KERNEL_LAPICTIMER      |    [ADDED]    |"
	else
		echo "|      KERNEL_LAPICTIMER      |     [OK]      |"
	fi	
	if [[ $KERNEL_ACPINOIRQ -eq 1 ]]; then
		echo "|      KERNEL_ACPINOIRQ       |    [ADDED]    |"
	elif [[ $KERNEL_ACPINOIRQ -eq 2 ]]; then
		echo "|      KERNEL_ACPINOIRQ       |   [REPLACED]  |"
	else
		echo "|      KERNEL_ACPINOIRQ       |     [OK]      |"
	fi	
	if [[ $KERNEL_ACPINOAPIC -eq 1 ]]; then
		echo "|      KERNEL_ACPINOAPIC      |    [ADDED]    |"
	else
		echo "|      KERNEL_ACPINOAPIC      |     [OK]      |"
	fi
	if [[ $KERNEL_INTELIDLEMAXCSTATE -eq 1 ]]; then
		echo "|  KERNEL_INTELIDLEMAXCSTATE  |    [ADDED]    |"
	elif [[ $KERNEL_INTELIDLEMAXCSTATE -eq 2 ]]; then
		echo "|  KERNEL_INTELIDLEMAXCSTATE  |   [REPLACED]  |"
	else
		echo "|  KERNEL_INTELIDLEMAXCSTATE  |     [OK]      |"
	fi	
	if [[ $KERNEL_PROCESSORMAXCSTATE -eq 1 ]]; then
		echo "|  KERNEL_PROCESSORMAXCSTATE  |    [ADDED]    |"
	elif [[ $KERNEL_PROCESSORMAXCSTATE -eq 2 ]]; then
		echo "|  KERNEL_PROCESSORMAXCSTATE  |   [REPLACED]  |"
	else
		echo "|  KERNEL_PROCESSORMAXCSTATE  |     [OK]      |"
	fi	

	# if [[ ISOLCPU -eq 0 ]]; then
	# 	echo "|           ISOLCPU           |    [ERROR]    |"
	# else
	# 	echo "|           ISOLCPU           |     [OK]      |"
	# fi
	# if [[ IRQ -eq 0 ]]; then
	# 	echo "|           IRQ               |    [ERROR]    |"
	# elif [[ IRQ -eq 1 ]]; then
	# 	echo "|           IRQ               |     [OK]      |"
	# else
	# 	echo "|           IRQ               |   [SKIPPED]   |"
	# fi
	if [[ TSC_CLOCK -eq -1 ]]; then
		echo "|           TSC_CLOCK         |    [ERROR]    |"
	elif [[ TSC_CLOCK -eq 1 ]]; then
		echo "|           TSC_CLOCK         |  [MODIFIED]   |"
	else
		echo "|           TSC_CLOCK         |     [OK]      |"
	fi
	if [[ TSC_RELIABLE -eq 0 ]]; then
		echo "|         TSC_RELIABLE        |     [OK]      |"
	else
		echo "|         TSC_RELIABLE        |    [ERROR]    |"
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
