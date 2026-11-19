#!/usr/bin/env python3
"""Recording stand-in for the docker CLI used by the cheese v2 tests.

Installed on PATH as `docker`. Keeps images/projects in $FAKE_DOCKER_STATE
(JSON) and appends every invocation to calls.jsonl next to it, so tests can
assert both outcomes and that nothing outside the v2 project was touched.
No container is ever started.

Knobs (in the state file): "preflight_exit" (exit code of `docker run`),
"unhealthy_images" (image IDs whose backend reports unhealthy).
"""

import json
import os
import sys
from pathlib import Path

STATE = Path(os.environ["FAKE_DOCKER_STATE"])
CALLS = STATE.with_name("calls.jsonl")


def load():
    if STATE.exists():
        return json.loads(STATE.read_text())
    return {"images": {}, "projects": {}, "preflight_exit": 0, "unhealthy_images": []}


def save(state):
    STATE.write_text(json.dumps(state, indent=1))


def resolve(state, ref):
    if ref in state["images"]:
        return state["images"][ref]
    if ref in state["images"].values():
        return ref
    return None


def option(args, name):
    return args[args.index(name) + 1] if name in args else None


def read_env_file(path):
    env = {}
    for line in Path(path).read_text().splitlines():
        if "=" in line and not line.startswith("#"):
            key, _, value = line.partition("=")
            env[key] = value.strip("'")
    return env


def compose(state, args):
    if args[:1] == ["version"]:
        print("Docker Compose version v2.40.0-fake")
        return 0
    project = option(args, "-p")
    env_file = option(args, "--env-file")
    rest = args[:]
    for flag in ("-p", "-f", "--env-file"):
        while flag in rest:
            i = rest.index(flag)
            del rest[i : i + 2]
    command = rest[0]
    projects = state["projects"]
    if command == "up":
        env = read_env_file(env_file)
        backend_id = resolve(state, env["CHEESE_V2_BACKEND_IMAGE"])
        projects[project] = {"running": True, "backend_id": backend_id, "env": env}
    elif command == "down":
        if project in projects:
            projects[project]["running"] = False
    elif command == "ps":
        info = projects.get(project)
        if info and info["running"]:
            print(f"{project}__{rest[-1]}")
    elif command == "logs":
        print("fake logs")
    else:
        print(f"fake compose: unsupported {command}", file=sys.stderr)
        return 2
    return 0


def main(args):
    state = load()
    with CALLS.open("a") as calls:
        calls.write(json.dumps(args) + "\n")
    try:
        if args[:1] == ["compose"]:
            return compose(state, args[1:])
        if args[:2] == ["image", "inspect"]:
            refs = [a for a in args[2:] if not a.startswith("--") and a != option(args, "--format")]
            ids = [resolve(state, ref) for ref in refs]
            if None in ids:
                return 1
            if "--format" in args:
                print("\n".join(ids))
            return 0
        if args[0] == "save":
            output = option(args, "-o")
            refs = [a for a in args[1:] if a not in ("-o", output)]
            Path(output).write_text(json.dumps({ref: resolve(state, ref) for ref in refs}))
            return 0
        if args[0] == "load":
            for ref, image_id in json.loads(Path(option(args, "-i")).read_text()).items():
                state["images"][ref] = image_id
            return 0
        if args[0] == "tag":
            state["images"][args[2]] = resolve(state, args[1])
            return 0
        if args[0] == "run":
            sys.stdin.read()
            if state["preflight_exit"] == 0:
                print("signature ok (fake)")
            return state["preflight_exit"]
        if args[0] == "ps":
            project = option(args, "--filter").split("=", 2)[2]
            if state["projects"].get(project, {}).get("running"):
                print(f"{project}__backend")
            return 0
        if args[0] == "inspect":
            project, _, service = args[-1].partition("__")
            info = state["projects"].get(project, {})
            if service == "backend" and info.get("backend_id") in state["unhealthy_images"]:
                print("running/unhealthy")
            else:
                print("running/healthy")
            return 0
        if args[0] == "version":
            print("fake")
            return 0
        print(f"fake docker: unsupported {args}", file=sys.stderr)
        return 2
    finally:
        save(state)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
