#!/usr/bin/env bash

typeset MYSELF="$(readlink -e $0 || realpath $0)"
typeset MYPATH="${MYSELF%/*}"

set -o nounset -o noclobber
shopt -s dotglob nullglob

export LC_ALL=C
export PATH="/bin:/sbin:/usr/bin:/usr/sbin:$PATH"
export PS4=' (${BASH_SOURCE##*/}::${FUNCNAME[0]:-main}::$LINENO)  '

# Exclude useless files
typeset -a EXCLUDE=(
	"/proc/kcore"          # core too big and useless
	"/proc/kmem"           # core
	"/proc/mem"            # core
	"/proc/kmsg"           # Infinite wait
	"/proc/self"           # Symlink to current pid
	"/proc/thread-self"    # Symlink
	"/proc/kallsyms"       # kallsyms is sensitive per node
	"/proc/[0-9]*"         # Dont gather details about processes
	"/sys/kernel/debug"    # Full of infinite files
)

# Files to be anonymzed
typeset -a ANONYMIZE=(
	"/sys/class/net/*/address"
	"/proc/mounts"
	"/proc/key*"
)


function getUuid {
	if [[ -e "/proc/sys/kernel/random/uuid" ]]; then
		echo $(< "/proc/sys/kernel/random/uuid")
	elif binExists "uuidgen"; then
		\uuidgen
	else
		# From ammString::UUIDGenerate
		typeset -l uuid="" str=""
		for i in {1..16}; do
			str="$(printf "%x" "$(( $RANDOM+256))" )"
			uuid+="${str:0:2}"
		done
		# After v4, there should be the variant on 2 or 3 bits... don't care here
		echo "${uuid:0:8}-${uuid:8:4}-4${uuid:12:3}-${uuid:16:4}-${uuid:20:12}"
	fi
}


function containsExclude {
	typeset folder="$1"

	typeset e
	for e in "${EXCLUDE[@]}"; do
		# If the current folder is a root of an exclusion, it can contain it
		[[ "${e##$folder}" != "${e}" ]] && return 0
	done

	return 1
}

function isExcluded {
	typeset file="$1"
	typeset e f

	# Iterate on all element
	for e in "${EXCLUDE[@]}"; do
		# For wildcard expansion
		for f in $e; do
			[[ "$file" == "$f" ]] && return 0
		done
	done
	return 1
}


function binExists {
	type -P "$1" >/dev/null
}

function copy {
	typeset dst="$1"; shift

	# Other tools like rsync or tar works on the file-size,which is 0 in procfs or sysfs
	# we need a dumb tool to just read & copy
	if ! binExists "cp"; then
		echo >&2 "No cp bin found. check \$PATH"
		return 1
	fi

	# For each element in args (eg /proc /sys)
	typeset f e
	for f in "$@"; do
		f="${f%/}"
		typeset dstpath="${f%/*}"

		# Folder need recursion from cp
		if [[ -d "$f" ]]; then

			# If our current folder might contain an exclusion, filter every item
			if containsExclude "$f"; then
				typeset e
				for e in $f/*; do
					# Don't even recurse for excluded element
					isExcluded "$e" && continue
					$FUNCNAME "$dst" "$e"
				done

			# Simple path, not excluded. Use 'cp -r' for recusive copy
			else
				# We don't care about content, but presency is nice even for non-readable files
				typeset failline

				#cp -r "$f" "${dst}/${dstpath}"
				cp -r "$f" "${dst}/${dstpath}" 2>&1 | while read failline; do
					typeset failpath="${failline#cp: cannot open \'}"
					failpath="${failpath%%\' for *}"
					if [[ "$failpath" != "$failline" ]] && [[ -e "$failpath" ]]; then
						typeset faildst="${dst}/${failpath}"
						if [[ -d "$failpath" ]]; then
							mkdir "$faildst"
						else
							[[ -d "${faildst%/*}" ]] || mkdir -p "${faildst%/*}"
							chmod u+wx "${faildst%/*}"
							touch "$faildst" 2>/dev/null
						fi
					fi
				done
			fi
		# Simple file just need exclusion
		elif [[ -f "$f" ]] || [[ -L "$f" ]]; then
			if ! isExcluded "$f"; then
				mkdir -p "${dst}/${dstpath}"
				chmod u+wx "${dst}/${dstpath}"
				cp "$f" "${dst}/${dstpath}/" 2>/dev/null || touch "$dst/$dstpath/${f##*/}"
			fi
		fi
	done

}


typeset ASROOT=
if [[ "$(id -u)" != "0" ]] && binExists sudo; then
	ASROOT="sudo -n "
fi


typeset TMPDIR="$(mktemp -d || (t="/tmp/tmp.$PID$RANDOM"; mkdir "$t" && echo "$t") )"
typeset DSTDIR="$TMPDIR/$(uname -s)-$(uname -m)/$(uname -r)/$(date +%s)-$(getUuid)"
typeset INFDIR="$DSTDIR/info"

mkdir -p "$DSTDIR" "$INFDIR"

echo "Storing data into '$TMPDIR'"

# Gather some details to fill info
echo "Gathering OS info"
(
	uname -a > "$INFDIR/uname"
	cpuid    > "$INFDIR/cpuid"
	$ASROOT dmidecode > "$INFDIR/dmidecode"
	cp /etc/*release "$INFDIR"
) 2>/dev/null


# Copying the real interesting data
echo "Copying /proc"
copy "$DSTDIR" "/proc"
echo "Copying /sys"
copy "$DSTDIR" "/sys"


# Do some anonymzation (don't quote to allow glob)
echo "Anonymzing some files"
for f in ${ANONYMIZE[@]}; do
	# Replace all letters and numbers by a single one
	sed -i "$DSTDIR/$f" -E -e 's/[a-zA-Z]/X/g' -e 's/[0-9]/0/g'
done

# Remove hostname from certain files
# I'll keep info/ folder to be able to track the hostname and add new files
# The info folder will not be published, only selected for interesting elements
typeset hname="$(uname -n)"
for f in \
	proc/sys/kernel/hostname \
	proc/version \
	proc/spl/kstat/zfs/dbgmsg \
	proc/asound/oss/sndstat; do
	sed -i "$DSTDIR/$f" -E -e "s/$hname/MyHostName/g"
done



# The copied files will seem huge: each file contains only a few bytes, but allocates a full page
# so each file is at least 4k. Use an index to send

echo "Creating index"
(
	cd "$DSTDIR"
	find > index
)


echo "Creating archive"
typeset archive="$TMPDIR.tar.gz"
tar -jc -C "$TMPDIR" -f "$archive" .

echo "Data has been stored in '$TMPDIR'"
echo
echo " ====> Archive created as '$archive'"
echo "       Please send this archive to 'adrien.mahieux [at] gmail.com'"
echo "       I'll do the extract & publishing in branch 'db' of https://github.com/Saruspete/procsysfs_db"
echo "       Thanks"
