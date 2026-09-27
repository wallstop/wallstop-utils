"""Read-only diff comparison: alternating order, one warm-up, three measured rounds."""

import datetime
import json
import shutil
import statistics
import subprocess
import time


def main():
    git = shutil.which("git")
    if not git:
        raise SystemExit("E_GIT_EXPERIENCE_GIT_NOT_AVAILABLE: git must be on PATH")

    def run(*args):
        return subprocess.run([git, "--no-pager", *args], capture_output=True,
                              check=True, timeout=30).stdout

    commits = run("log", "--no-merges", "-n", "8", "--format=%H", "--", "Scripts").decode().splitlines()
    records = []
    for iteration in range(4):
        algorithms = ("myers", "histogram") if iteration % 2 == 0 else ("histogram", "myers")
        for algorithm in algorithms:
            for commit in commits:
                start = time.perf_counter()
                patch = run("-c", f"diff.algorithm={algorithm}", "show", "--format=", "--no-ext-diff", "--no-color", commit, "--", "Scripts")
                elapsed = (time.perf_counter() - start) * 1000
                if not patch:
                    raise SystemExit(f"Empty sample: {commit}")
                records.append(dict(algorithm=algorithm, commit=commit, warmup=iteration == 0,
                                    milliseconds=round(elapsed, 3), bytes=len(patch)))
    medians = {algorithm: statistics.median(row["milliseconds"] for row in records
               if row["algorithm"] == algorithm and not row["warmup"])
               for algorithm in ("myers", "histogram")}
    print(json.dumps(dict(git=run("--version").decode().strip(),
                         utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                         medianMilliseconds=medians, records=records), indent=2))


if __name__ == "__main__":
    main()
