$root_directory = git rev-parse --show-toplevel
Push-Location "$root_directory"
scoop import Config/scoopfile.json
Pop-Location