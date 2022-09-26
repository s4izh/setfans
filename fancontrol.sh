#!/bin/bash                                          
############################################         
#                                          #         
#  Name: fanControl                        #         
#  Version: 0.2                            #         
#  Description:                            #         
#     Control fans on Apple Macintosh      #         
#  Dependencies:                           #         
#     applesmc                             #         
#  Author: Kenny Lasse Hoff Levinsen       #         
#     Alias: Joushou                       #         
#  Use at own risk                         #         
#                                          #         
############################################         

appleSMCPath=/sys/devices/platform/applesmc.768
                        # Path to applesmc (Seems static)

minTemp=48              # Lowest temperature
maxOnlineTemp=80        # Highest temperature when online
maxOfflineTemp=75       # Highest temperature when offline

fanMinSpeed=2200        # Lowest fan-speed
fanMaxSpeed=6000        # Highest fan-speed

tempCalc=highest        # Temperature calculation ("highest" uses highest temperature, "average" takes the average                                                                                                
sensorsUsed=4           # How many sensors to use                                                        
debug=onChange          # Set to onLoop for every loop, onChange on state-changes, or false for off      
manFanControl=false     # Set to true if you want to define direct output, instead of fan minimum speeds 
debugTo=/var/log/smcfancontrol.log                                                                       
                        # Where to write our debugging to (/dev/stdout for standard output)              

debug() # Prints text with a timestamp, when $debug
{                                                  
        [[ $debug == onChange ]] && [[ $stateChange == true ]] && echo "$(date "+%d/%m %H:%M:%S"): $@" >> $debugTo                                                                                                
        [[ $debug == onLoop ]] && echo "$(date "+%d/%m %H:%M:%S"): $@" >> $debugTo                       
}                                                                                                        

fatal() # Fatal error
{                    
        stateChange=true
        debug "FATAL: Failing at: $1"
        echo "$(date "+%d/%m %H:%M:%S"): FATAL: Failing at: $1" > /dev/stderr
        debug "Attempting to set fans to safe values"                        
        for i in $appleSMCPath/fan*_manual                                   
        do                                                                   
                echo 0 > $i                                                  
        done                                                                 
        fanEnd="_min"                                                        
        counter=0                                                            
        until [[ $counter == $fans ]]                                        
        do                                                                   
                ((counter++))                                                
                echo 4000 > /sys/devices/platform/applesmc.768/fan${counter}${fanEnd}
        done                                                                         
        debug "Commit suicide. Bye."                                                 
        exit 1                                                                       
}                                                                                    

initSetup() # Initialize
{                       
        [[ $debugTo != "/dev/stdout" ]] && [ -e $debugTo ] && mv ${debugTo} ${debugTo}.0
        fans=0                                                                          
        debug "Detecting configuration"                                                 
        for i in $appleSMCPath/fan*_output # Count fans                                 
        do                                                                              
                ((fans++))                                                              
        done                                                                            

        if [[ $manFanControl == true ]]
        then                           
                for i in $appleSMCPath/fan*_manual
                do                                
                        echo 1 > $i               
                done                              
                fanEnd="_output"                  
        else                                      
                for i in $appleSMCPath/fan*_manual
                do                                
                        echo 0 > $i               
                done                              
                fanEnd="_min"                     
        fi                                        

        debug "  Fans: $fans $([[ $manFanControl == true ]] && echo ', Manually controlled')"
        debug "    Min fan-speed: $fanMinSpeed"                                              
        debug "    Max fan-speed: $fanMaxSpeed"                                              

        sensors=0
        for i in $appleSMCPath/temp*_input # Count temperature sensors
        do                                                            
                ((sensors++))                                         
        done                                                          

        debug "  Sensors: $sensors"
        debug "    Limited by user to $sensorsUsed"

        (cat /proc/acpi/battery/BAT0/state | grep "yes" > /dev/null) && laptop=true || online=true
        (cat /proc/acpi/ac_adapter/ADP1/state | grep on-line > /dev/null) && online=true || online=false

        debug "  Laptop: $laptop"
        debug "    ACPI-State: $([[ $online == true ]] && echo online || echo offline)"
        debug "Configuration detected"                                                 

}

setFans() # Adjust fan-speeds
{                            
        # counter=0            
        # until [[ $counter == $fans ]]
        # do                           
        #         ((counter++))        
        #         echo $1 > /sys/devices/platform/applesmc.768/fan${counter}${fanEnd} || fatal "setting fans"                                                                                                       
        # done                                                                                             
        echo $1 > /sys/devices/platform/applesmc.768/fan1_output || fatal "setting fans"                                                                                                       
}                                                                                                        

update() # Update temperatures and ACPI state
{                                            

        counter=1
        until [[ $counter == $sensors ]]
        do                              
                tempVar=$(cat $appleSMCPath/temp${counter}_input) || fatal
                ((tempSensor[$counter]=tempVar/1000))                     
                ((counter++))                                             
        done                                                              

        if [[ $tempCalc == "highest" ]]
        then                           
                counter=0              
                temp=0                 
                until [[ $counter == $sensorsUsed ]] || [[ $counter == $sensors ]]
                do                                                                
                        ((counter++))                                             
                        [[ ${tempSensor[$counter]} > $temp ]] && temp=${tempSensor[$counter]}
                done                                                                         
                [[ $oldTemp != $temp ]] && stateChange=true && oldTemp=$temp                 
        else                                                                                 
                counter=0                                                                    
                temp=0                                                                       
                until [[ $counter == $sensorsUsed ]] || [[ $counter == $sensors ]]           
                do                                                                           
                        ((counter++))                                                        
                        let "temp = ${tempSensor[$counter]} + $temp"                         
                done                                                                         
                ((temp=temp/(counter-1)))                                                    
                [[ $oldTemp != $temp ]] && stateChange=true && oldTemp=$temp                 
        fi                                                                                   

        if [[ $laptop == true ]]
        then                    
                (cat /proc/acpi/ac_adapter/ADP1/state | grep on-line > /dev/null) && online=true || online=false                                                                                                  

                if [[ $oldOnline != $online ]]
                then                          
                        [[ $online == true ]] && maxTemp=$maxOnlineTemp || maxTemp=$maxOfflineTemp
                        ((ratio=(fanMaxSpeed-fanMinSpeed)/(maxTemp-minTemp)))                     
                        oldOnline=$online
                        stateChange=true
                fi
        fi
}

stateChange=true
initSetup

while : # Lets loop
do
        update || fatal "calling update"
        if [[ $stateChange == true ]]
        then
                ((speed=((temp-minTemp)*ratio)+fanMinSpeed))
                (( $speed >= $fanMaxSpeed )) && speed=$fanMaxSpeed                              # Don't try to set fan-speed over $fanMaxSpeed
                (( $speed <= $fanMinSpeed )) && speed=$fanMinSpeed                              # Don't try to set fan-speed under $fanMinSpeed
                setFans $speed || fatal "calling setFans"
        fi
        debug "Temperature: $temp, Fan-speed: $speed, ACPI-State: $([[ $online == true ]] && echo online || echo offline)"
        stateChange=false
        sleep 5
done
