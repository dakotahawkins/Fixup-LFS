At work, we had several files that were SUPPOSED to be managed by LFS but weren't for some reason. I blame the tool we used to convert our repo.

This caused some persistent issues for people, mostly particular files getting "stuck" as modified in git. I'm not sure exactly (yet) what causes that particular problem, but I suspect the root cause is that files match an LFS glob from .gitattributes and something goes wrong with the LFS filters if they're not currently LFS files.

You can run this script to list those files (`-l`), or you can run it to "fix" them (no options) by creating a commit that removes them and re-adds them to make them the LFS files they want to be.

This also exposed an oddity that might ALMOST be a git-lfs bug: git-lfs won't handle 0 byte files. Now, I don't know why we had some of those, but it seems like if they match an LFS glob in .gitattributes then git-lfs could track them. This script just deletes them.

Run from inside of a git repo:

    Usage: fixup-lfs.sh [OPTION]
    Fixes non-LFS files that should have been in LFS all along.
    
      -l, --list    Don't fix anything, just list what would be fixed.
      -v, --verify  Like --list, but exits with an error if files need to be fixed.
      -h, --help    Display this help and exit.
