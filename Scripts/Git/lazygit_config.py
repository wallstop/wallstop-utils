"""Prepare a reversible lazygit renderer edit; stdout is JSON, no files are written."""

import argparse
import base64
import io
import json
from pathlib import Path

from ruamel.yaml import YAML
from ruamel.yaml.comments import CommentedMap


RENDERER = {"command": "delta --paging=never", "colorArg": "always"}


def references(value, target, visited):
    if value is target:
        return 1
    if not isinstance(value, (dict, list)) or id(value) in visited:
        return 0
    visited.add(id(value))
    children = value.values() if isinstance(value, dict) else value
    return sum(references(child, target, visited) for child in children)


def encode(text):
    return base64.b64encode(text.encode("utf-8")).decode("ascii")


def prepare(path, previous=None, replace=False, remove=False):
    yaml = YAML(typ="rt")
    yaml.preserve_quotes = True
    yaml.allow_duplicate_keys = False
    raw = path.read_bytes() if path.exists() else None
    before = base64.b64encode(raw).decode("ascii") if raw is not None else None
    document = yaml.load(raw.decode("utf-8-sig")) if raw else CommentedMap()
    if document is None:
        document = CommentedMap()
    if not isinstance(document, dict):
        raise ValueError("configuration must be a YAML mapping")
    git = document.get("git")
    if git is not None and not isinstance(git, dict):
        raise ValueError("git must be a YAML mapping")
    if git is not None and references(document, git, set()) > 1:
        raise ValueError("git mapping is shared by YAML aliases; expand that mapping before installation")
    renderers = git.get("diffRenderers") if git else None
    if previous and previous.get("Managed"):
        if renderers != [RENDERER]:
            raise ValueError("E_GIT_EXPERIENCE_DRIFT: managed lazygit renderer was edited")
        if not remove:
            return {"Change": {"Path": str(path), "Before": before, "After": before}, "State": previous}
        # Restore byte-for-byte when nothing else changed. Otherwise change only our key.
        if before == previous["After"]:
            after = previous["Before"]
        else:
            if previous["HadRenderer"]:
                original = yaml.load(base64.b64decode(previous["Before"]).decode("utf-8-sig"))
                git["diffRenderers"] = original["git"]["diffRenderers"]
            else:
                del git["diffRenderers"]
                if not git and not previous["HadGit"]:
                    del document["git"]
            stream = io.StringIO()
            yaml.dump(document, stream)
            after = encode(stream.getvalue())
        return {"Path": str(path), "Before": before, "After": after}
    if remove:
        return {"Path": str(path), "Before": before, "After": before}
    # Legacy renderer settings also represent an existing preference.
    if git and ("diffRenderers" in git or "paging" in git) and not replace:
        return {"Change": {"Path": str(path), "Before": before, "After": before}, "State": {"Managed": False, "Path": str(path)}}
    had_git = "git" in document
    had_renderer = git is not None and "diffRenderers" in git
    if git is None:
        git = CommentedMap()
        document["git"] = git
    git["diffRenderers"] = [RENDERER]
    stream = io.StringIO()
    yaml.dump(document, stream)
    after = encode(stream.getvalue())
    state = {"Managed": True, "Path": str(path), "Before": before, "After": after, "HadGit": had_git, "HadRenderer": had_renderer}
    return {"Change": {"Path": str(path), "Before": before, "After": after}, "State": state}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path)
    parser.add_argument("--previous", type=Path)
    parser.add_argument("--replace", action="store_true")
    parser.add_argument("--remove", action="store_true")
    args = parser.parse_args()
    previous = json.loads(args.previous.read_text(encoding="utf-8")) if args.previous else None
    try:
        print(json.dumps(prepare(args.path, previous, args.replace, args.remove)))
    except Exception as error:
        parser.exit(1, f"E_GIT_EXPERIENCE_YAML: {error}\n")


if __name__ == "__main__":
    main()
