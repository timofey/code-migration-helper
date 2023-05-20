#!/usr/bin/env bash
#
# MIT License
#
# Copyright (c) 2023 Timofey Klyubin
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

RED=$'\e[0;31m'
GREEN=$'\e[0;32m'
YELLOW=$'\e[0;33m'
BLUE=$'\e[0;34m'
MAGENTA=$'\e[0;35m'
CYAN=$'\e[0;36m'
GREY=$'\e[0;90m'
NC=$'\e[0m'

if [ -z "$DIFF_TOOL_CMD" ]; then
    DIFF_TOOL_CMD="{onprem_file} {cloud_file}"
fi

if [ -z "$DIFF_TOOL_BIN" ]; then
    echo "${YELLOW}Using meld as a default diff tool, as the 'DIFF_TOOL_BIN' env var is not set${NC}"
    echo
    DIFF_TOOL_BIN="meld"
else
    echo "${GREEN}Using '$DIFF_TOOL_BIN' as the diff tool${NC}"
fi



if [ $# -lt 2 ]; then
    echo "Usage options:"
    echo "./migration-diff-helper CLOUD-BASE-DIR ONPREM-BASE-DIR [PATH-PREFIX] [FILENAME-FILTER]"
    echo ""
    echo "Options description:"
    echo -e "\tCLOUD-BASE-DIR\t\tCloud version installation dir (where you have your 'custom' and 'config' folders)"
    echo -e "\tONPREM-BASE-DIR\t\tOn-prem version installation dir (where you have your 'custom' and 'config' folders)"
    echo -e "\tPATH-PREFIX\t\tUse if you want to only compare specific folders inside the repos"
    echo -e "\tFILENAME-FILTER\t\tFilter output to only some file extensions"
    exit 1
fi

cloud_base_dir="$1"
onprem_base_dir="$2"
path_prefix="$3"
filename_filter="$4"

full_cloud_search_path="$cloud_base_dir/$path_prefix"
full_onprem_search_path="$onprem_base_dir/$path_prefix"

MIGRATION_IGNORE_FILE="$onprem_base_dir/.migration_ignore"
ignore_opts=()
find_opts=()
if [ -f "$MIGRATION_IGNORE_FILE" ]; then
    readarray -t ignore_opts < "$MIGRATION_IGNORE_FILE"
    for ignore_opt in ${ignore_opts[@]}; do
        find_opts+=(-o -name "$ignore_opt")
    done
fi

# if [ -z "$path_prefix" ]; then
#     path_prefix="./"
# fi

if [ -z "$filename_filter" ]; then
    filename_filter="*"
fi

function stop_difftool_on_sigint() {
    if [ ! -z "$DIFF_TOOL_PID" ]; then
        kill -SIGQUIT "$DIFF_TOOL_PID"
    fi
    echo
    echo "${RED}Caught interrupt signal, stopping...${NC}"
    exit 1
}

trap stop_difftool_on_sigint SIGINT SIGHUP SIGTERM


onprem_files=$(find "$full_onprem_search_path" -type f -iname "$filename_filter" -not '(' "${find_opts[@]:1}" ')' | sed "s#$full_onprem_search_path##" | sort)
cloud_files=$(find "$full_cloud_search_path" -type f -iname "$filename_filter" -not '(' "${find_opts[@]:1}" ')' | sed "s#$full_cloud_search_path##" | sort)

files_diff=$(comm -23 <(echo "$onprem_files") <(echo "$cloud_files"))
files_diff_formatted=$(awk '{ printf "(%s) %s\n", NR, $0}' <<< "$files_diff")

proceed='n'

while [ "$proceed" != "y" ]; do

    echo "${RED}New files that are NOT in the Cloud installation:${NC}"
    echo ""
    echo "$files_diff_formatted"
    echo
    echo "${BLUE}Select which files to copy over to the cloud installation:${NC}"
    echo "Use comma-separated list, you can also use ranges (e.g. 2,3,5-10)"
    echo -n "Files to copy> "
    read -a numbers_input

    selected_files=()

    for range in $(echo "$numbers_input" | sed "s/,/ /g"); do
        _st=$(echo "$range" | cut -d'-' -f1)
        _en=$(echo "$range" | cut -d'-' -f2)
        for (( i=_st ; i <= _en ; i++ )); do
            selected_files+=($i)
        done
    done

    echo "Please confirm your selection:"
    echo
    for i in "${selected_files[@]}"; do
        echo "$files_diff_formatted" | sed "${i}q;d"
    done
    echo "Is this right? (y/n): "
    read proceed
    continue
done

echo "Copying files..."
for i in "${selected_files[@]}"; do
    selected_file=$(echo "$files_diff" | sed "${i}q;d")
    source_file="$full_onprem_search_path/$selected_file"
    target_file="$full_cloud_search_path/$selected_file"
    echo "$source_file → $target_file"
    cp "$source_file" "$target_file"
done

echo
echo "${GREEN}Copying new files - done!${NC}"
echo
echo "${BLUE}Generating files diffs...${NC}"

MIGRATION_INDEX_FILE="$onprem_base_dir/.last_migration"
onprem_git_head=$(git --git-dir="$onprem_base_dir/.git" rev-parse HEAD)

if [ -f "$MIGRATION_INDEX_FILE" ]; then
    last_git_head=$(sed "1q;d" "$MIGRATION_INDEX_FILE")
    echo "${GREEN}Found migration index file, last migration was from $last_git_head.${NC}"

    common_files=$(comm -12 <(echo "$onprem_files") <(echo "$cloud_files"))

    # Now check which files are actually have different content

    different_files=()

    while read -r file_to_check; do
        source_file="$full_onprem_search_path/$file_to_check"
        target_file="$full_cloud_search_path/$file_to_check"

        # Skip ignored files
        for ignore_pattern in ${ignore_opts[@]}; do
            if [[ "$source_file" == $ignore_pattern ]]; then
                continue
            fi
        done

        # echo "${CYAN}[DEBUG] Checking if '$file_to_check' is different...${NC}"
        _DIFF=$(comm --nocheck-order -3 "$source_file" "$target_file")
        # echo -e "${CYAN}[DEBUG] _DIFF is: \n$_DIFF${NC}"
    
        if [ ! -z "$_DIFF" ]; then
            # echo "${CYAN}[DEBUG] Adding '$file_to_check' to the different_files list${NC}"
            different_files+=("$file_to_check")
        fi
    done < <(echo "$common_files")


    # echo "${CYAN}[DEBUG] different_files = ${different_files[@]}${NC}"
    
    # Calculating the patch between the last commit and now
    echo "${BLUE}Generating patches for changes since the last script run...${NC}"
    if [ "$last_git_head" != "$onprem_git_head" ]; then
        script_for_applying_patch=()

        truncated_last_commit=$(cut -c -7 <<< "$last_git_head")
        git_numstat=$(git --git-dir="$onprem_base_dir/.git" diff --numstat $last_git_head..$onprem_git_head)
         # echo "${CYAN}[DEBUG] last_git_head = $last_git_head${NC}"
         # echo "${CYAN}[DEBUG] onprem_git_head = $onprem_git_head${NC}"
         # echo "${CYAN}[DEBUG] git_numstat: $git_numstat${NC}"
        for file_to_diff in ${different_files[@]}; do
            if (grep -o "$file_to_diff" "$MIGRATION_INDEX_FILE" >/dev/null 2>/dev/null); then
                continue
            fi

            fname_for_matching=$(echo -n "$path_prefix/$file_to_diff" | tr -s '/')
            # echo "${CYAN}[DEBUG] fname_for_matching = $fname_for_matching${NC}"
            if grep -o "$fname_for_matching" <(echo "$git_numstat") >/dev/null 2>/dev/null; then
                patch_file_name="${truncated_last_commit}_"$(sed 's#/#_#g' <<< "$fname_for_matching")".patch"
                git --git-dir="$onprem_base_dir/.git" diff -p $last_git_head..$onprem_git_head -- "$fname_for_matching" > "$cloud_base_dir/$patch_file_name"
                script_for_applying_patch+=("git apply -3 --whitespace=nowarn '$patch_file_name'")
                echo "${GREEN}Generated patch file '$patch_file_name'${NC}"
            fi
        done

        sed -i "s/$last_git_head/$onprem_git_head/" "$MIGRATION_INDEX_FILE"
        echo "${BLUE}Updated the last migrated commit to be '$onprem_git_head'$NC"
    fi

    echo
    echo "${YELLOW}Bash commands for applying generated patches:$NC"
    echo "-------------------------"
    printf "${GREY}%s${NC}\n" "${script_for_applying_patch[@]}"
    echo "-------------------------"
    echo

    
    if [ $(wc -l < "$MIGRATION_INDEX_FILE") -gt 1 ]; then
        echo "Detected unmerged files from the initial script run. Do you want to continue merging now?"
        echo -n "(y/n)> "
        read answer
        if [ "$answer" == "y" ]; then
            set -e

            readarray -t different_files < <(sed '1d' < "$MIGRATION_INDEX_FILE")
            for file_to_diff in ${different_files[@]}; do
                source_file="$full_onprem_search_path/$file_to_diff"
                target_file="$full_cloud_search_path/$file_to_diff"
                command_to_run="$DIFF_TOOL_BIN "$(echo -n "$DIFF_TOOL_CMD" | sed "s#{onprem_file}#$source_file#" | sed "s#{cloud_file}#$target_file#")
                eval "$command_to_run" &
                DIFF_TOOL_PID=$!
                wait $DIFF_TOOL_PID

                if [ "$?" -eq "0" ]; then
                    sed -i "\#${file_to_diff}#d" "$MIGRATION_INDEX_FILE"
                    echo "Finished merging $file_to_diff"
                else
                    echo "${RED}Couldn't diff $file_to_diff${NC}"
                fi
            done

            set +e
        fi
    fi
else # First time running the script
    echo "${YELLOW}Migration index file doesn't exist, doing full diff${NC}"
    echo "$onprem_git_head" > "$MIGRATION_INDEX_FILE"

    common_files=$(comm -12 <(echo "$onprem_files") <(echo "$cloud_files"))

    # Now check which files are actually have different content

    different_files=()

    while read -r file_to_check; do
        source_file="$full_onprem_search_path/$file_to_check"
        target_file="$full_cloud_search_path/$file_to_check"

        # Skip ignored files
        for ignore_pattern in ${ignore_opts[@]}; do
            if [[ "$source_file" == $ignore_pattern ]]; then
                continue
            fi
        done

        # echo "${CYAN}[DEBUG] Checking if '$file_to_check' is different...${NC}"
        _DIFF=$(comm --nocheck-order -3 "$source_file" "$target_file")
        # echo -e "${CYAN}[DEBUG] _DIFF is: \n$_DIFF${NC}"
    
        if [ ! -z "$_DIFF" ]; then
            # echo "${CYAN}[DEBUG] Adding '$file_to_check' to the different_files list${NC}"
            different_files+=("$file_to_check")
        fi
    done < <(echo "$common_files")

    num_dif_files="${#different_files[@]}"
    printf '%s\n' "${different_files[@]}" | tee -a "$MIGRATION_INDEX_FILE"
    echo
    echo "${YELLOW}Found $num_dif_files different files:${NC}"
    echo

    read -p "${YELLOW}Press any key to start the diff tool, or Ctrl-C to stop. The progress will be saved.${NC}"

    set -e

    for file_to_diff in ${different_files[@]}; do
        source_file="$full_onprem_search_path/$file_to_diff"
        target_file="$full_cloud_search_path/$file_to_diff"
        command_to_run="$DIFF_TOOL_BIN "$(echo -n "$DIFF_TOOL_CMD" | sed "s#{onprem_file}#$source_file#" | sed "s#{cloud_file}#$target_file#")
        eval "$command_to_run"
        if [ "$?" -eq "0" ]; then
            sed -i "\#${file_to_diff}#d" "$MIGRATION_INDEX_FILE"
        else
            echo "${RED}Couldn't diff $file_to_diff${NC}"
        fi
    done

    set +e
fi



echo "${GREEN}Done!$NC"
