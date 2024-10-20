$root_directory = git rev-parse --show-toplevel
Push-Location "$root_directory"
scoop export -c > Config/scoopfile.json
Pop-Location