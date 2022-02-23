#!/bin/bash
#
# api_check.sh: Check API compatibility between two pg_stat_monitor branches.
#
# Usage: api_check.sh [source_branch] target_branch
#        OR
#        api_check.sh clean
#
# source_branch is optional, if omitted the script will use the current git branch
# as the source.
#
# If invoked as api_check.sh clean, it will remove all generated objects that could
# be used for further inspection.
#
# The script works by compiling the pg_stat_monitor extension on both source and
# target branches, then it (re)creates the extension on PostgreSQL, dump the
# database objects (views, functions) and compare the results.
# 
# All the relevant log is output on console (stdout/1).
#
# Following exit codes are used:
#    0   (SUCCESS)     API between branches hasn't changed.
#    1   (ERROR)       Script failed to execute some step.
#    10  (API CHANGED) Target branch has either removed or modified some database
#                      object that was exported by the source branch.
# 
#
# REQUIRES: Following environment variables must be properly set.
#	PATH    Must include path to the pg_config relative to the PostgreSQL instance to be used.
#   PGDATA  Must point to the database cluster directory to be used.

function usage() {
	echo "[*] Usage: $0 [source_branch/commit_id] target_branch/commit_id"
	echo "[*] OR"
	echo "[*] Usage: $0 clean"
	echo
	echo "$0 checks for API compatibility between the source_branch and"\
		  "target_branch."
	echo
	echo "If invoked with clean argument, the script just removes all generated"\
		 "files that could be used for further inspection."
	exit 1
}

# Check number of command line arguments.
[ $# -eq 0 ] &&
{
	usage
}

[ "$1" = "-h" -o "$1" = "--help" ] &&
{
	usage
}

if [ "$1" = "clean" ]; then
	rm -vf api_pgsmview.*
	rm -vf api_pgsmerrview.*
	rm -vf api_histogramfn.*
	rm -vf api_resetfn.*
	rm -vf api_reseterrfn.*	
	exit 0
fi

# Get absolute directory path to the script.
# https://stackoverflow.com/questions/4774054/reliable-way-for-a-bash-script-to-get-the-full-path-to-itself
SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
# Change working dir to the project directory to be able to run git commands.
cd "${SCRIPTPATH}"

# Save original git branch.
ORIG_BRANCH="`git rev-parse --abbrev-ref HEAD`"

if [ $# -gt 1 ]; then
	# Source git branch.
	SOURCE_BRANCH="$1"
	# Target branch to compare API with.
	TARGET_BRANCH="$2"
	# Check if source branch actually exists.
	if ! git rev-parse --verify "${SOURCE_BRANCH}"; then
		echo "[*] ERROR: Source branch do not exist: ${SOURCE_BRANCH}"
		exit 1
	fi
else
	# Current git branch.
	SOURCE_BRANCH="`git rev-parse --abbrev-ref HEAD`"
	# Target branch to compare API with.
	TARGET_BRANCH="$1"
fi

# Check that target branch actually exists.
if ! git rev-parse --verify "${TARGET_BRANCH}"; then
	echo "[*] ERROR: Target branch do not exist: ${TARGET_BRANCH}"
	exit 1
fi

# Check for pg_config, POSIX compatible way.
if ! command -v pg_config > /dev/null 2>&1; then
	echo "[*] ERROR: Could not locate pg_config, please adjust PATH"
	exit 1
fi

PG_BINDIR=`pg_config --bindir`
PGCTL="${PG_BINDIR}/pg_ctl"
PSQL="${PG_BINDIR}/psql"

[ ! -x "${PGCTL}" ] &&
{
	echo "[*] ERROR: pg_ctl not found/no +x permission: ${PGCTL}"
	exit 1
}

[ ! -x "${PSQL}" ] &&
{
	echo "[*] ERROR: psql not found/no +x permission: ${PSQL}"
	exit 1
}

[ -z "$PGDATA" ] &&
{
	echo "[*] ERROR: PGDATA environment must be set and point to your\
		  PostgreSQL database directory"
	exit 1
}

[ ! -d "$PGDATA" ] &&
{
	echo "[*] ERROR: PGDATA directory not found: $PGDATA"
	exit 1
}

# Remove temporary files when script exits.
function cleanup() {
	rm -f err
	if [ -f pgconf.orig ]; then
		cp -f pgconf.orig "${PGDATA}/postgresql.conf"
		rm -f pgconf.orig
	fi
	rm -f pgsm.conf
	git checkout $ORIG_BRANCH
}

trap cleanup EXIT

PG_VER="`cat ${PGDATA}/PG_VERSION 2> /dev/null`"

# Make a copy of original postgresql.conf.
cp -f "${PGDATA}"/postgresql.conf ./pgconf.orig
# Remove any shared_preload_libraries configuration.
grep -v shared_preload_libraries pgconf.orig > pgsm.conf
# Add pg_stat_monitor extension to the config.
echo "shared_preload_libraries = 'pg_stat_monitor'" >> pgsm.conf
# Overwrite postgresql configuration.
cp pgsm.conf "${PGDATA}/postgresql.conf"

function restart_postgres() {
	echo "[*] Restarting PostgreSQL ${PG_VER}..."
	cd "$PGDATA"
	if ! $PGCTL -D "$PGDATA" restart 2> err > /dev/null; then
		echo "[*] ERROR: Failed to restart PostgreSQL ${PG_VER}: `cat err`"
		exit 1
	fi
	cd -
}

# Dump information about views, functions, or any object used as API.
# 1. Compile and install pg_stat_monitor.
# 2. Restart PostgreSQL.
# 3. Create the extension.
# 4. Dump pg_stat_monitor views, functions, etc...
function dump_pgsm_api() {
	BRANCH="$1"
	echo "[*] Compiling pg_stat_monitor ($BRANCH)"
	make USE_PGXS=1 clean
	if ! make USE_PGXS=1 install; then
		echo "[*] Compilation failed, aborting..."
		exit 1
	fi
	restart_postgres
	"$PSQL" -c 'DROP EXTENSION IF EXISTS pg_stat_monitor;' 2> /dev/null
	"$PSQL" -c 'CREATE EXTENSION pg_stat_monitor;' 2> /dev/null
	"$PSQL" -c '\d pg_stat_monitor' 2> /dev/null > api_pgsmview."${BRANCH}"
	"$PSQL" -c '\d pg_stat_monitor_settings' 2> /dev/null > api_pgsm_settings."${BRANCH}"
	"$PSQL" -c 'SELECT * FROM pg_stat_monitor_settings' 2> /dev/null > api_pgsm_settings_values."${BRANCH}"
	"$PSQL" -c '\d pg_stat_monitor_errors' 2> /dev/null > api_pgsmerrview."${BRANCH}"
	"$PSQL" -c '\sf histogram' 2> /dev/null > api_histogramfn."${BRANCH}"
	"$PSQL" -c '\sf pg_stat_monitor_reset' 2> /dev/null > api_resetfn."${BRANCH}"
	"$PSQL" -c '\sf pg_stat_monitor_reset_errors' 2> /dev/null > api_reseterrfn."${BRANCH}"
}

# Checkout source branch.
# If source branch was not given on command line, use current
# git branch (skip checkout).
TMP_SRC_BRANCH=""
if [ $# -gt 1 ]; then
	RANDSTR=`echo $RANDOM | md5sum | head -c 20`
	TMP_SRC_BRANCH="source_${RANDSTR}_${SOURCE_BRANCH}"
	echo "[*] Checking out ${SOURCE_BRANCH} on temporary branch ${TMP_SRC_BRANCH}"

	if ! git checkout -b "${TMP_SRC_BRANCH}" "${SOURCE_BRANCH}" 2> /dev/null; then
		echo "[*] ERROR: Failed to checkout branch ${SOURCE_BRANCH}"
		exit 1
	fi
fi

echo "[*] Dumping API (${SOURCE_BRANCH})..."
dump_pgsm_api "${SOURCE_BRANCH}"
make USE_PGXS=1 clean

RANDSTR=`echo $RANDOM | md5sum | head -c 20`
TMP_DST_BRANCH="target_${RANDSTR}_${TARGET_BRANCH}"1
echo "[*] Checking out ${TARGET_BRANCH} on temporary branch ${TMP_DST_BRANCH}"

if ! git checkout -b "${TMP_DST_BRANCH}" "${TARGET_BRANCH}" 2> /dev/null;
then
	echo "[*] ERROR: Failed to checkout branch ${TARGET_BRANCH}"
	exit 1
fi

# Remove temporary source branch (if created).
[ -z "${TMP_SRC_BRANCH}" ] || git branch -D "${TMP_SRC_BRANCH}"

echo "[*] Dumping API (${TARGET_BRANCH})..."
dump_pgsm_api "${TARGET_BRANCH}"
make USE_PGXS=1 clean

# Restore original branch and remove temporary one.
git checkout "${ORIG_BRANCH}"
git branch -D "${TMP_DST_BRANCH}"

echo
echo "[*] ------ API comparison results ------"
echo "[*]"

# Input files
INPUT=(api_pgsmview api_pgsm_settings api_pgsm_settings_values api_pgsmerrview api_histogramfn api_resetfn api_reseterrfn)
# Real API object names.
API_OBJECTS=("pg_stat_monitor" "pg_stat_monitor_settings"
"pg_stat_monitor_settings(values)" "pg_stat_monitor_errors" "histogram" "pg_stat_monitor_reset" "pg_stat_monitor_reset_errors")

STATUS=0
i=0
while [ $i -lt ${#API_OBJECTS[@]} ]; do
	echo "[*] ${API_OBJECTS[$i]}:"

	# Compute input file sizes.
	fs0=$(stat -c '%s' ${INPUT[$i]}."${SOURCE_BRANCH}")
	fs1=$(stat -c '%s' ${INPUT[$i]}."${TARGET_BRANCH}")

	if [ $fs0 -eq 0 ]; then
		echo -e "\tNot present in branch ${SOURCE_BRANCH}"
		if [ $fs1 -gt 0 ]; then
			echo -e "\tObject added on target branch ${TARGET_BRANCH}"
		fi
	fi

	if [ $fs1 -eq 0 ]; then
		if [ $fs0 -gt 0 ]; then
			# Object was present in original but removed on target branch.
			echo -e "\tRemoved on branch ${TARGET_BRANCH}"
			STATUS=10
		else
			echo -e "\tNot present in branch ${TARGET_BRANCH}"
		fi
	fi

	if [ $fs0 -gt 0 -a $fs1 -gt 0 ]; then
		if ! diff ${INPUT[$i]}."${SOURCE_BRANCH}" ${INPUT[$i]}."${TARGET_BRANCH}" > ${API_OBJECTS[$i]}.diff; then
			echo -e "\tAPI is different, diff (${API_OBJECTS[$i]}.diff):"
			cat ${API_OBJECTS[$i]}.diff
			STATUS=10
		else
			echo -e "\tAPI is compatible (OK)"
		fi
	fi

	echo "[*] -----------------------------"

	i=`expr $i + 1`
done

exit $STATUS
