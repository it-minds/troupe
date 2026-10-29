"""The first administration of a plane-light, through the break-glass door.

A fresh plane has a database and nothing in it: no profile, no registered machine, no
team. The console could do each of these, but a stack that needs a person to click
through three screens before its own worker can enrol is not one command to install. So
this does, with the standard library alone, what docs/admin/single-machine.md has a
person do:

1. `admin.profile.put`: the profile `local`, whose workers are registered machines
   (`provisioner: ssh`), on the worker image of this release.
2. `admin.host.register`: this box as `this-box`, once; the secret the answer carries
   and the control CA go to the volume the worker reads them from. A box whose secret
   file is gone but which the plane still knows is rotated, since nothing shows a secret
   twice.
3. The team. A group becomes known to the plane at a member's first sign-in, so this
   waits for `TROUPE_LIGHT_TEAM_GROUP` to appear in `admin.groups.list`, then makes it a
   team, allows that team where nothing is enforced (a machine gives none of a cluster's
   guarantees, and the plane refuses the grant until a platform admin says so by name),
   and grants it `local`.

Every step reads before it writes and does nothing where the thing is already there, so
a second run, and every restart of the stack, changes nothing. The break-glass token is
exchanged for a plane token good for fifteen minutes and exchanged again when that is
nearly up; every call it makes is in the audit trail as `breakglass`.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request

PLANE = os.environ.get("PLANE_URL", "http://plane:4000").rstrip("/")
BREAKGLASS = os.environ["TROUPE_BREAKGLASS_TOKEN"]
TEAM_GROUP = os.environ.get("TROUPE_LIGHT_TEAM_GROUP", "troupe-users")
HOST_DIR = os.environ.get("HOST_DIR", "/run/troupe/host")
PROFILE = "local"
HOST = "this-box"

_token = {"value": None, "at": 0.0}


def log(line):
    print(f"bootstrap: {line}", flush=True)


def http(method, path, body=None, headers=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(PLANE + path, data=data, method=method)
    req.add_header("content-type", "application/json")
    req.add_header("accept", "application/json")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    with urllib.request.urlopen(req, timeout=30) as res:
        return res.status, json.loads(res.read() or b"null")


def wait_for_plane():
    while True:
        try:
            status, doc = http("GET", "/.well-known/troupe")
            if status == 200 and doc.get("breakglass"):
                return
            if status == 200:
                log("the plane answers but has no break-glass door: set TROUPE_BREAKGLASS_TOKEN")
        except (urllib.error.URLError, ConnectionError, TimeoutError, OSError):
            pass
        time.sleep(2)


def token():
    # Exchanged again well inside the fifteen minutes a plane token lasts.
    if _token["value"] is None or time.time() - _token["at"] > 600:
        status, doc = http("POST", "/auth/breakglass", {"token": BREAKGLASS})
        _token["value"] = doc["token"]
        _token["at"] = time.time()
    return _token["value"]


class RpcError(Exception):
    def __init__(self, method, error):
        super().__init__(f"{method}: {json.dumps(error)}")
        self.code = error.get("code")
        self.data = error.get("data") or {}


def rpc(method, params=None):
    _status, msg = http(
        "POST",
        "/rpc",
        {"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}},
        {"authorization": f"Bearer {token()}"},
    )
    if msg.get("error"):
        raise RpcError(method, msg["error"])
    return msg.get("result")


def names(rows, key="name"):
    return {row.get(key) for row in rows or []}


def ensure_profile():
    if PROFILE in names(rpc("admin.profiles.list")):
        log(f"profile {PROFILE} is there")
        return
    rpc(
        "admin.profile.put",
        {
            "profile": {
                "name": PROFILE,
                "image": "release",
                "provisioner": "ssh",
                "size_class": "standard",
                "spec": {},
            }
        },
    )
    log(f"profile {PROFILE} written: its workers are registered machines")


def write_secret(answer):
    os.makedirs(HOST_DIR, exist_ok=True)
    for name, text in (("secret", answer["secret"]), ("ca.crt", answer["ca"])):
        path = os.path.join(HOST_DIR, name)
        fd = os.open(path + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o400)
        with os.fdopen(fd, "w") as f:
            f.write(text)
        os.chown(path + ".tmp", 1000, 1000)
        os.replace(path + ".tmp", path)


def ensure_host():
    secret = os.path.join(HOST_DIR, "secret")
    hosts = names(rpc("admin.hosts.list", {"profile": PROFILE}))
    if HOST in hosts and os.path.exists(secret) and os.path.getsize(secret) > 0:
        log(f"{HOST} is registered and its secret is in place")
        return
    if HOST in hosts:
        answer = rpc("admin.host.rotate", {"profile": PROFILE, "name": HOST})
        log(f"{HOST} was registered but its secret was gone: rotated")
    else:
        answer = rpc(
            "admin.host.register",
            {"profile": PROFILE, "host": {"name": HOST, "address": os.environ.get("TROUPE_LIGHT_HOST", "")}},
        )
        log(f"{HOST} registered against {PROFILE}")
    write_secret(answer)
    log(f"the secret and the control CA are written to {HOST_DIR}")


def ensure_team():
    waited = False
    while TEAM_GROUP not in names(rpc("admin.groups.list"), "external_id"):
        if not waited:
            log(f"waiting for somebody in the group {TEAM_GROUP} to sign in once, which is when the plane learns of it")
            waited = True
        time.sleep(10)

    teams = {row["name"]: row for row in rpc("admin.teams.list") or []}
    team = teams.get(TEAM_GROUP)
    if team is None:
        team = rpc("admin.team.enable", {"group": TEAM_GROUP, "attrs": {"name": TEAM_GROUP}})
        log(f"the group {TEAM_GROUP} is now the team {TEAM_GROUP}")
    if not team.get("allow_unenforced_workers"):
        rpc("admin.team.update", {"name": TEAM_GROUP, "attrs": {"allow_unenforced_workers": True}})
        log(f"team {TEAM_GROUP} may run where nothing is enforced: a machine gives none of a cluster's guarantees")
    granted = {g.get("profile") for g in team.get("grants") or []}
    if PROFILE not in granted:
        rpc("admin.team.grant", {"name": TEAM_GROUP, "profile": PROFILE})
        log(f"team {TEAM_GROUP} is granted {PROFILE}")
    else:
        log(f"team {TEAM_GROUP} already has {PROFILE}")


def main():
    log(f"waiting for the plane at {PLANE}")
    wait_for_plane()
    ensure_profile()
    ensure_host()
    ensure_team()
    log("done")


if __name__ == "__main__":
    try:
        main()
    except RpcError as error:
        log(f"refused: {error}")
        sys.exit(1)
