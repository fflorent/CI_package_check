#!/bin/bash

#=================================================
# Grab the script directory
#=================================================

if [ "${0:0:1}" == "/" ]; then script_dir="$(dirname "$0")"; else script_dir="$(echo $PWD/$(dirname "$0" | cut -d '.' -f2) | sed 's@/$@@')"; fi

CI_domain="$(grep DOMAIN= "$script_dir/auto_build/auto.conf" | cut --delimiter='=' --fields=2)"
CI_path="$(grep CI_PATH= "$script_dir/auto_build/auto.conf" | cut --delimiter='=' --fields=2)"
CI_url="https://$CI_domain/$CI_path"

# FIXME : wtf if this exists then why parse the domain/path previously...
ci_url=$(grep ^CI_URL= "$script_dir/config" | cut --delimiter='=' --fields=2)

CI_service=$(grep ^CI_SERVICE= "$script_dir/auto_build/auto.conf" | cut --delimiter='=' --fields=2)
CI_service=${CI_service:-yunorunner}

#=================================================
# Time out
#=================================================

set_timeout () {
	# Get the maximum timeout value
	timeout=$(grep "^timeout=" "$script_dir/config" | cut --delimiter="=" --fields=2)

	# Set the starting time
	starttime=$(date +%s)
}

# Check if the timeout has expired
timeout_expired () {
	# Compare the current time with the max timeout
	if [ $(( $(date +%s) - $starttime )) -ge $timeout ]
	then
		echo -e "\e[91m\e[1m!!! Timeout reached ($(( $timeout / 60 )) min). !!!\e[0m"
		return 1
	fi
}

# Print date in CI.lock
# To allow to follow the execution of package check.
lock_update_date () {
	local date_to_add="$1"
	local current_content=$(cat "$lock_pcheckCI")
	# Do not overwite the lock file if is empty (ending of analyseCI), or contains Remove or Finish.
	if [ -n "$current_content" ] && [ "$current_content" != "Remove" ] && [ "$current_content" != "Finish" ] && [ "$current_content" != "Force_stop" ]
	then
		# Update the file only if there a new information to add into it.
		if [ "$current_content" != "$id:$date_to_add" ]
		then
			echo -e "$id:$date_to_add" > "$lock_pcheckCI"
		fi
	fi
}

# Check if the timeout has expired, but take the starttime in the lock of package check
timeout_expired_during_test () {
	# The lock file of package check contains the date of ending of the last test.
	if [ -e "$lock_package_check" ]
	then
		starttime=$(cat "$lock_package_check" | cut -d':' -f2)
	else
		starttime=$(date +%s)
	fi
	# Update CI.lock with the last date of lock_package_check
	lock_update_date "$starttime"
	timeout_expired
}

#=================================================
# Check analyseCI execution
#=================================================

# Check if the analyseCI is still running
check_analyseCI () {

	sleep 120

	# Get the pid of analyseCI
	local analyseCI_pid=$(cat "$analyseCI_indic" | cut --delimiter=';' --fields=1)
	local analyseCI_id=$(cat "$analyseCI_indic" | cut --delimiter=';' --fields=2)
	local finish=1


	# Infinite loop
	while true
	do

		# Check if analyseCI still running by its pid
		if ! ps --pid $analyseCI_pid | grep --quiet $analyseCI_pid
		then
			echo "analyseCI stopped."
			# Check if the lock file contains "Remove". That means analyseCI has finish normally
			[ "$(cat "$lock_pcheckCI")" == "Remove" ] && finish=0
			break
		fi

		# Check if analyseCI wait for the correct id.
		if [ "$analyseCI_id" != "$id" ]
		then
			echo "analyseCI wait for another id."
			finish=2
			break
		fi

		# Check if the lock file contains "Force_stop", used to stop a test through an ssh connection.
		if [ "$(cat "$lock_pcheckCI")" == "Force_stop" ]
		then
			echo "analyseCI force to stopped."
			finish=3
			break
		fi

		# Wait 30 secondes and recheck
		sleep 30
	done

	# If finish equal 0, analyseCI finished correctly. It's the normal way to ending this script. So remove the lock file
	if [ $finish -eq 0 ]
	then
		# Remove the lock file
		rm -f "$lock_pcheckCI"
		date
		echo -e "Lock released for $test_name (id: $id)\n"

	# finish equal 1 to 3. The current test has be killed.
	else
		if [ $finish -eq 1 ]; then
			echo -e "\e[91m\e[1m!!! analyseCI was cancelled, stop this test !!!\e[0m"
		fi
		# Stop all current tests
		"$script_dir/force_stop.sh"
		# Terminate all child processes
		pgrep -P $$
		pkill -SIGTERM -P $$
		exit 1
	fi
}

# The work list contains the next test to performed
work_list="$script_dir/work_list"

# FIXME : wtf...
# If the list is empty, Check if the service is still available
if ! test -s "$work_list"
then

    # If it's an official CI
    if test -e "$script_dir/auto_build/auto.conf"
    then

        # Try to resolv the domain 10 times maximum.
        for i in `seq 1 10`; do
            curl_exit_code=$(curl --location --insecure --silent --write-out "%{http_code}\n" $CI_url --output /dev/null)
            if [ "${curl_exit_code:0:1}" = "0" ] || [ "${curl_exit_code:0:1}" = "4" ] || [ "${curl_exit_code:0:1}" = "5" ]
            then
                # If the http code is a 0xx 4xx or 5xx, it's an error code.
                service_broken=1
                sleep 1
            else
                service_broken=0
                break
            fi
        done

        if [ $service_broken -eq 1 ]
        then
            date
            echo "The CI seems to be down..."
            echo "Try to restart the CI"
            systemctl restart $CI_service
        fi
    fi
    exit
fi

#=================================================
# Main test process
#=================================================

# Check the two lock files before continuing

lock_pcheckCI="$script_dir/CI.lock"
lock_package_check="$script_dir/package_check/pcheck.lock"

# If at least one lock file exist, cancel this execution
if test -e "$lock_package_check" || test -e "$lock_pcheckCI"
then

    # Start the time counter
    set_timeout

    # Simply print the date, for information
    date

    remove_lock=0

    if_file_overdate () {
        local file="$1"
        local maxage=$2

        # Get the last modification time of the file
        local last_change=$(stat --printf=%Y "$file")
        # Determine the max age of the file
        local maxtime=$(( $last_change + $maxage ))
        if [ $(date +%s) -gt $maxtime ]
        then # If $maxtime is outdated, this lock file is too old.
            echo 1
        else
            echo 0
        fi
    }

    if test -e "$lock_package_check"; then
        echo "The file $(basename "$lock_package_check") exist. Package check is already used."
        # Keep the lock if is younger than $timeout + 30 minutes
        remove_lock=$(if_file_overdate "$lock_package_check" $(( $timeout + 1800 )))
    fi

    if test -e "$lock_pcheckCI"; then
        echo "The file $(basename "$lock_pcheckCI") exist. Another test is already in progress."
        if [ "$(cat "$lock_pcheckCI")" == "Finish" ] || [ "$(cat "$lock_pcheckCI")" == "Remove" ] || [ "$(cat "$lock_pcheckCI")" == "Force_stop" ]
        then
            # If the lock file contains Finish or Remove, keep the lock only if is younger than 15 minutes
            remove_lock=$(if_file_overdate "$lock_pcheckCI" 900)
        else
            # Else, keep it if is younger than $timeout + 30 minutes
            remove_lock=$(if_file_overdate "$lock_pcheckCI" $(( $timeout + 1800 )))
        fi
    fi

    echo "Execution cancelled..."

    if [ $remove_lock -eq 1 ]; then
        echo "The lock files are too old. We're going to kill them !"
        "$script_dir/force_stop.sh"
    fi

    exit 0
fi

#=================================================
# Create the file analyseCI_last_exec
#=================================================

analyseCI_indic="$script_dir/analyseCI_exec"
if [ ! -e "$analyseCI_indic" ]
then
    # Create the file for exec_indicator from analyseCI.sh
    touch "$analyseCI_indic"
    # And give enought right to allow analyseCI.sh to modify this file.
    chmod 666 "$analyseCI_indic"
fi

#=================================================
# Parse the first line of work_list
#=================================================

# Read the first line of work_list
repo=$(head --lines=1 "$work_list")
# Get the id
id=$(echo $repo | cut --delimiter=';' --fields=2)
# Get the name of the test
test_name=$(echo $repo | cut --delimiter=';' --fields=3)
# Keep only the repositery
repo=$(echo $repo | cut --delimiter=';' --fields=1)
# Find the architecture name from the test name
architecture="$(echo $(expr match "$test_name" '.*\((~.*~)\)') | cut --delimiter='(' --fields=2 | cut --delimiter=')' --fields=1)"

# Obviously that's too simple to have a unique nomenclature, so we have several of them
arch="amd64"
if [ "$architecture" = "~x86-32b~" ]
then
    arch="i386"
elif [ "$architecture" = "~ARM~" ]
then
    arch="armhf"
fi

#=================================================
# Check the execution of analyseCI
#=================================================

check_analyseCI &

#=================================================
# Define the type of test
#=================================================

local ynh_branch="stable"
log_dir=""
if echo "$test_name" | grep --quiet "(testing)"
then
    local ynh_branch="testing"
    log_dir="logs_$ynh_branch/"
elif echo "$test_name" | grep --quiet "(unstable)"
then
    local ynh_branch="unstable"
    log_dir="logs_$ynh_branch/"
fi

echo "Test on yunohost $ynh_branch"

#=================================================
# Create the lock file
#=================================================

# Create the lock file, and fill it with id of the current test.
echo "$id" > "$lock_pcheckCI"

# And give enought right to allow analyseCI.sh to modify this file.
chmod 666 "$lock_pcheckCI"

#=================================================
# Define the app log file
#=================================================

# From the repositery, remove http(s):// and replace all / by _ to build the log name
app_log=${log_dir}$(echo "${repo#http*://}" | sed 's@[/ ]@_@g')$architecture.log
# The complete log is the same of the previous log, with complete at the end.
complete_app_log=${log_dir}$(basename --suffix=.log "$app_log")_complete.log
test_json_results=${log_dir}$(basename --suffix=.log "$app_log")_results.json

#=================================================
# Launch the test with Package check
#=================================================

# Simply print the date, for information
date
echo "A test with Package check will begin on $test_name (id: $id)"

# Start the time counter
set_timeout

cli_log="$script_dir/package_check/Test_results_cli.log"
rm -f "$script_dir/package_check/Complete.log"
rm -f "$script_dir/package_check/results.json"

# Exec package check according to the architecture

echo -n "Start a test on $arch architecture on yunohost $ynh_branch" > "$cli_log"

# Start package check and pass to background
# Use nice to reduce the priority of processes during the test.
ARCH="$arch" YNH_BRANCH="$ynh_branch" nice --adjustment=10 "$script_dir/package_check/package_check.sh" "$repo" > "$cli_log" 2>&1 &

# Get the pid of package check
package_check_pid=$!

# Start a loop while package check is working
while ps --pid $package_check_pid | grep --quiet $package_check_pid
do
    sleep 120
    # Check if the timeout is not expired
    if ! timeout_expired_during_test > "$cli_log" 2>&1
    then
        echo -e "\e[91m\e[1m!!! Package check was too long, its execution was aborted. !!! (PCHECK_AVORTED)\e[0m" | tee --append "$cli_log"

        # Stop all current tests
        ARCH="$arch" YNH_BRANCH="$ynh_branch" "$script_dir/package_check/package_check.sh" --force-stop > "$cli_log" 2>&1
        exit 1
    fi
done

# Copy the complete log
cp "$script_dir/package_check/Complete.log" "$script_dir/logs/$complete_app_log"
cp "$script_dir/package_check/results.json" "$script_dir/logs/$test_json_results"

#=================================================
# Remove the first line of the work list
#=================================================

# After the test, it's removed from the work list
grep --quiet "$id" "$work_list" & sed --in-place "/$id/d" "$work_list"

#=================================================
# Add in the cli log that the complete log was duplicated
#=================================================

echo -n "The complete log for this application was duplicated and is accessible at " >> "$cli_log"

if [ -n "$ci_url" ]
then
    # Print a url to access this log
    echo "https://$ci_url/logs/$complete_app_log" >> "$cli_log"
else
    # Print simply the path for this log
    echo "$script_dir/logs/$complete_app_log" >> "$cli_log"
fi


# Copy the cli log, next to the complete log
cp "$cli_log" "$script_dir/logs/$app_log"


# Add the name of the test at the beginning of the log
sed --in-place "1i-> Test $test_name\n" "$script_dir/logs/$app_log"

#=================================================
# Check / update level of the app, send corresponding message on XMPP
#=================================================

public_result_list="$script_dir/logs/list_level_${ynh_branch}_$arch.json"
app="$(echo $test_name | awk '{print $1}')"

[ -e "$public_result_list" ] || echo "{}" > "$public_result_list"

# Get new level and previous level
app_level=""
previous_level=$(jq -r ".$app" "$public_result_list")

if [ -e "$script_dir/logs/$test_json_results" ]
then
    app_level="$(jq -r ".level" "$script_dir/logs/$test_json_results")"
    cp "$script_dir/badges/level${app_level}.svg" "$script_dir/logs/$app.svg"
    # Update/add the results from package_check in the public result list
    jq --slurpfile results "$script_dir/logs/$test_json_results" ".\"$app\"=\$results" > $public_result_list.new
    mv $public_result_list.new $public_result_list
fi

# We post message on XMPP if we're running for tests on stable/amd64
xmpppost="$script_dir/auto_build/xmpp_bot/xmpp_post.sh"
if [[ -e "$xmpppost" ]] && [[ "$ynh_branch" == "stable" ]] && [[ "$arch" == "amd64" ]]
then
    message="${message}Application $app_name"

    if [ -z "$app_level" ]; then
        message+="completely failed the continuous integration tests"
    elif [ -z "$previous_level" ]; then
        message="just reached the level $app_level"
    elif [ $app_level -gt $previous_level ]; then
        message+="rises from level $previous_level to level $app_level"
    elif [ $app_level -lt $previous_level ]; then
        message+="goes down from level $previous_level to level $app_level"
    else
        message="stays at level $app_level"
    fi

    "$xmpppost" "$message"
fi

#=================================================
# Finishing
#=================================================

date
echo "Test finished on $test_name (id: $id)"

# Inform analyseCI.sh that the test was finish
echo Finish > "$lock_pcheckCI"

# Start the time counter
set_timeout
# But shorten the time out
timeout=120

# Wait for the cleaning of the lock file. That means analyseCI.sh finished on its side.
while test -s "$lock_pcheckCI"
do
    # Check the timeout
    sleep 5
    if ! timeout_expired
    then
        echo "analyseCI.sh was too long to liberate the lock file, break the lock file."
        break
    fi
done

# Inform check_analyseCI that the test is over
echo Remove > "$lock_pcheckCI"

