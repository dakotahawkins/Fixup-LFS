#!/bin/bash

# MIT License
#
# Copyright (c) 2016 Dakota Hawkins
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

# Usage: fixup-lfs.sh [OPTION]
# Fixes non-LFS files that should have been in LFS all along.
#
#   -l, --list    Don't fix anything, just list what would be fixed.
#   -v, --verify  Like --list, but exits with an error if files need to be fixed.
#   -h, --help    Display this help and exit.

lfs_temp_dir=
main() {
    if [[ "$#" -gt "1" ]]; then
        error-exit "Unrecognized command line arguments."
    fi

    local list_only=0
    local verify_only=0
    if [[ "$#" -eq "1" ]]; then
        if [[ "$1" == "-h" || "$1" == "--help" ]]; then
            display-usage
            exit 0
        elif [[ "$1" == "-l" || "$1" == "--list" ]]; then
            list_only=1
        elif [[ "$1" == "-v" || "$1" == "--verify" ]]; then
            verify_only=1
        else
            error-exit "Unrecognized command line arguments."
        fi
    fi

    # cd to the top-level directory
    local top_level_dir=$(git rev-parse --show-toplevel)
    if ! [[ $? -eq 0 && -d "$top_level_dir" ]]; then
        error-exit "Unable to find top-level working directory."
    fi
    pushd "$top_level_dir" > /dev/null || {
        error-exit "Failed to cd to top-level working directory."
    }

    # Make a temporary folder in the .git directory
    if ! [[ $list_only -eq 1  || $verify_only -eq 1 ]]; then
        lfs_temp_dir="$(git rev-parse --git-dir)/lfs/fixup-lfs/"
        if ! [[ $? -eq 0 ]]; then
            error-exit "Unable to find .git directory."
        fi

        if [[ -d "$lfs_temp_dir" ]]; then
            rm -rf "$lfs_temp_dir" || {
                error-exit "Failed to delete temporary directory."
            }
        fi

        mkdir -p "$lfs_temp_dir" || {
            error-exit "Failed to create temporary directory."
        }
    fi

    echo "Looking for files matching LFS globs..."

    # Find .gitattributes files
    local attr_files=($(git ls-files -- '.gitattributes' '**/.gitattributes'))
    if ! [[ $? -eq 0 ]]; then
        error-exit "Unable to find .gitattribute files."
    fi

    # Go into every diretory with a .gitattributes file, pull out its LFS globs and use them to find
    # potential LFS files
    local lfs_file_glob_matches=
    for attr_file in "${attr_files[@]}"; do
        local attr_file_dir=$(dirname $(readlink -f "$attr_file"))
        if ! [[ $? -eq 0 ]]; then
            error-exit "Unable to get directory containing .gitattribute file."
        fi

        pushd "$attr_file_dir" > /dev/null || {
            error-exit "Failed to cd to directory containing .gitattribute file."
        }

        # Pull out the globs
        local lfs_file_globs=$(grep 'filter=lfs' .gitattributes | grep 'diff=lfs' | grep 'merge=lfs' | while read line; do eval get-first-arg "$line"; done | sort | uniq)
        if ! [[ $? -eq 0 ]]; then
            popd > /dev/null
            error-exit "Unable to find LFS file globs in .gitattributes file."
        fi

        # Find files matching them
        lfs_file_glob_matches+=$(echo "$lfs_file_globs" | xargs git ls-files --full-name -- )$'\n'
        if ! [[ $? -eq 0 ]]; then
            popd > /dev/null
            error-exit "Failed to find git files matching LFS file globs."
        fi

        popd > /dev/null || {
            error-exit "Failed to cd from directory containing .gitattribute file."
        }
    done

    # Check potential LFS files with git-check-attr to make SURE the files should actually be LFS
    # files.
    echo "Ensuring they have LFS attributes actually set..."

    # Files must have filter=lfs...
    local files_with_lfs_attrs=$(echo "$lfs_file_glob_matches" | sort | uniq | git check-attr --stdin filter | grep 'filter: lfs$' | cut -d : -f 1)
    if ! [[ $? -eq 0 ]]; then
        error-exit "Failed to check files for LFS attributes."
    fi

    # ...and diff=lfs
    files_with_lfs_attrs=$(echo "$files_with_lfs_attrs" | sort | uniq | git check-attr --stdin diff | grep 'diff: lfs$' | cut -d : -f 1)
    if ! [[ $? -eq 0 ]]; then
        error-exit "Failed to check files for LFS attributes."
    fi

    # ...and merge=lfs
    files_with_lfs_attrs=$(echo "$files_with_lfs_attrs" | sort | uniq | git check-attr --stdin merge | grep 'merge: lfs$' | cut -d : -f 1)
    if ! [[ $? -eq 0 ]]; then
        error-exit "Failed to check files for LFS attributes."
    fi

    local header_msg="Fix non-LFS files that should have been in LFS all along"
    local empty_files_msg="Deleted 0 byte LFS candidates:"
    local fat_files_msg="Converted to LFS files:"

    if [[ $list_only -eq 1  || $verify_only -eq 1 ]]; then
        empty_files_msg="Delete 0 byte LFS candidates:"
        fat_files_msg="Convert to LFS files:"
    fi

    echo "Comparing against list of files managed by LFS..."

    # Diff files actually managed by LFS with files that SHOULD be managed by LFS, resulting in a
    # list of files that should be but aren't.
    local files_to_fix=$(comm -13 <(git-lfs ls-files | cut -d ' ' -f 3- | sort | uniq) <(echo "$files_with_lfs_attrs"))
    if ! [[ $? -eq 0 ]]; then
        error-exit "Failed to identify files to fix."
    fi
    local num_files_to_fix=$(echo -n "$files_to_fix" | wc -l)
    if [[ $num_files_to_fix -eq 0 ]]; then
        echo
        echo "Nothing to do!"
        return
    fi

    # LFS won't handle empty (0 byte) files, so we can just delete these (I hope!)
    local empty_files_to_rm=$(echo "$files_to_fix" | while read file_name; do if [[ ! -s "$file_name" ]]; then echo "$file_name"; fi; done)
    if ! [[ $? -eq 0 ]]; then
        error-exit "Failed to identify empty files to delete."
    fi
    local num_empty_files_to_rm=$(echo -n "$empty_files_to_rm" | wc -l)

    # Everything else is a file we need to turn into an LFS file
    local fat_files_to_lfsify=$(echo "$files_to_fix" | while read file_name; do if [[ -s "$file_name" ]]; then echo "$file_name"; fi; done)
    if ! [[ $? -eq 0 ]]; then
        error-exit "Failed to identify files to fix."
    fi
    local num_fat_files_to_lfsify=$(echo -n "$fat_files_to_lfsify" | wc -l)

    local commit_msg=$(
        echo "$header_msg"
        echo

        if [[ $num_empty_files -gt 0 ]]; then
            echo $num_empty_files
            echo "$empty_files_msg"
            echo
            echo "$empty_files_to_rm"
            echo
        fi

        if [[ $num_fat_files_to_lfsify -gt 0 ]]; then
            echo "$fat_files_msg"
            echo

            echo "$fat_files_to_lfsify"
            echo
        fi
    )
    echo
    echo "$commit_msg"
    echo

    if [[ $list_only -eq 1 ]]; then
        return
    elif [[ $verify_only -eq 1 ]]; then
        error-exit "The above files need to be fixed up."
    fi

    # Delete the empty files.
    echo "Deleting empty files..."
    echo "$empty_files_to_rm" | tr '\n' '\0' | xargs -0 -I {} rm {} > /dev/null || {
        error-exit "Failed to remove empty files."
    }

    # Copy the others to the temporary directory...
    echo "Copying remaining files to fix into temporary directory..."
    echo "$fat_files_to_lfsify" | tr '\n' '\0' | xargs -0 -I {} cp --parents -t "$lfs_temp_dir" {} > /dev/null || {
        error-exit "Failed to copy files to temporary directory."
    }

    # ...and then delete them.
    echo "Removing files..."
    echo "$fat_files_to_lfsify" | tr '\n' '\0' | xargs -0 -I {} rm {} > /dev/null || {
        error-exit "Failed to remove files."
    }

    # Add and commit the file removals.
    echo "Staging file removal..."
    git add -f -A > /dev/null || {
        error-exit "Failed to stage file removal."
    }
    echo "Commiting file removal..."
    git commit -m "${commit_msg}" > /dev/null || {
        error-exit "Failed to commit file removal."
    }

    # Bring back the files from the temporary directory, re-add them and amend our commit.
    echo "Copying files back from temporary directory..."
    cp -r "${lfs_temp_dir}." "./" > /dev/null || {
        error-exit "Failed to copy files from temporary directory."
    }
    echo "Re-adding files..."
    git -c core.autocrlf=input add -f -A > /dev/null || {
        error-exit "Failed to stage file re-addition."
    }
    echo "Amending commit..."
    git commit --amend || {
        error-exit "Failed to commit file re-addition."
    }

    echo "Done!"
}

get-first-arg() {
    echo "'$1'"
}

display-usage() {
    echo "Usage: fixup-lfs.sh [OPTION]"
    echo "Fixes non-LFS files that should have been in LFS all along."
    echo
    echo "  -l, --list    Don't fix anything, just list what would be fixed."
    echo "  -v, --verify  Like --list, but exits with an error if files need to be fixed."
    echo "  -h, --help    Display this help and exit."
    echo
}

cleanup() {
    popd > /dev/null 2>&1
    if [[ -d "$lfs_temp_dir" ]]; then
        rm -rf "$lfs_temp_dir" > /dev/null || {
            error-exit "Failed to delete temporary directory."
        }
    fi
}

error-exit() {
    echo "$1" >&2
    echo
    display-usage
    cleanup
    exit 1
}

main "$@"
cleanup
exit 0
