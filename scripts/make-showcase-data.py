#!/usr/bin/env python3
"""Write a synthetic Docker Engine API dataset for screenshots.

The captured test fixtures describe a throwaway daemon with a few megabytes in
it, which makes for a truthful but dull picture. This writes a made-up install
of a size a working developer would recognise, in the same wire format, so
`scripts/fake-docker.py --fixtures <dir>` can serve it to the real app.

Nothing here comes from a real daemon: the names, digests, and sizes are
invented. It is media source material, not a test fixture.

    scripts/make-showcase-data.py [--out media-sources/showcase-daemon]
"""

import argparse
import hashlib
import json
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUT = REPOSITORY_ROOT / "media-sources" / "showcase-daemon"

MB = 1_000_000


def digest(seed: str) -> str:
    """A stable 64 hex digit id derived from a name.

    Hashed rather than counted so the ids look like real ones and, more to the
    point, differ in their leading digits: Docker and DockVac both abbreviate to
    the first twelve characters.
    """
    return hashlib.sha256(("dockvac showcase/" + seed).encode()).hexdigest()


def image_id(seed: str) -> str:
    return "sha256:" + digest(seed)


# Layers shared between images are counted once on disk. `SharedSize` is the
# part of an image that some other image also uses, so `Size - SharedSize` is
# what removing that image would actually free.
NODE20_LAYERS = 1_098 * MB  # the whole of node:20, reused by everything built on it
BOOKWORM_BASE = 97 * MB  # inside NODE20_LAYERS; also under python, golang, postgres
ALPINE_LAYERS = 8 * MB

# repo tags, total size, shared size, containers using it, created
IMAGES = [
    (["myapp:2.4.1", "myapp:latest", "registry.internal:5000/team/myapp:2.4.1"],
     1_240 * MB, NODE20_LAYERS, 2, 1_788_300_000),
    ([], 1_210 * MB, NODE20_LAYERS, 0, 1_788_100_000),  # dangling: an earlier build
    ([], 1_198 * MB, NODE20_LAYERS, 0, 1_787_600_000),  # dangling: an earlier build
    (["node:20-bookworm"], NODE20_LAYERS, NODE20_LAYERS, 1, 1_785_000_000),
    (["node:18-bookworm"], 1_012 * MB, BOOKWORM_BASE, 0, 1_772_000_000),
    (["python:3.12-bookworm"], 1_024 * MB, BOOKWORM_BASE, 0, 1_784_000_000),
    (["golang:1.23"], 843 * MB, BOOKWORM_BASE, 0, 1_783_000_000),
    (["mysql:8.4"], 617 * MB, 0, 0, 1_770_000_000),
    (["postgres:16"], 438 * MB, BOOKWORM_BASE, 1, 1_786_000_000),
    (["nginx:1.27"], 192 * MB, 0, 1, 1_786_500_000),
    (["ubuntu:24.04"], 78 * MB, 0, 0, 1_780_000_000),
    (["redis:7-alpine"], 41 * MB, ALPINE_LAYERS, 1, 1_786_200_000),
    (["alpine:3.20"], ALPINE_LAYERS, ALPINE_LAYERS, 2, 1_776_000_000),
]

# name, image tag, image seed, state, status, writable layer, volumes, created
CONTAINERS = [
    ("api", "myapp:2.4.1", "myapp:2.4.1", "running", "Up 6 days", 48 * MB,
     ["api_uploads"], 1_788_400_000),
    ("db", "postgres:16", "postgres:16", "running", "Up 6 days (healthy)", 2 * MB,
     ["pgdata"], 1_788_400_000),
    ("web", "nginx:1.27", "nginx:1.27", "running", "Up 6 days", 0,
     [], 1_788_400_000),
    ("cache", "redis:7-alpine", "redis:7-alpine", "running", "Up 6 days", 0,
     [], 1_788_400_000),
    ("worker", "node:20-bookworm", "node:20-bookworm", "exited", "Exited (137) 9 days ago",
     340 * MB, ["node_modules_cache"], 1_787_000_000),
    ("old-test-runner", "alpine:3.20", "alpine:3.20", "exited", "Exited (0) 3 weeks ago",
     780 * MB, [], 1_786_000_000),
    ("migrate-once", "myapp:2.4.1", "myapp:2.4.1", "exited", "Exited (0) 6 days ago",
     1 * MB, [], 1_788_350_000),
    ("tmp-shell", "alpine:3.20", "alpine:3.20", "created", "Created", 0,
     [], 1_788_450_000),
]

# name, size, containers referencing it, labels
VOLUMES = [
    ("pgdata", 2_400 * MB, 1, {"com.docker.compose.project": "shop"}),
    ("old_project_data", 1_800 * MB, 0, {}),
    ("node_modules_cache", 890 * MB, 1, {}),
    ("api_uploads", 156 * MB, 1, {"com.docker.compose.project": "shop"}),
    (digest("anonymous volume"), 45 * MB, 0, {"com.docker.volume.anonymous": ""}),
    ("redis_data", 12 * MB, 0, {}),
]

# id seed, type, description, size, shared
BUILD_CACHE = [
    ("bc-1", "regular", "[builder 4/7] RUN npm ci --omit=dev", 1_140 * MB, False),
    ("bc-2", "regular", "[builder 6/7] RUN npm run build", 612 * MB, False),
    ("bc-3", "exec.cachemount", "cached mount /root/.npm from exec /bin/sh -c npm ci",
     498 * MB, False),
    ("bc-4", "source.local", "local source for context", 310 * MB, False),
    ("bc-5", "regular", "[stage-1 3/5] COPY --from=builder /app/dist /app/dist",
     142 * MB, True),
    ("bc-6", "regular", "[builder 2/7] COPY package.json package-lock.json ./",
     96 * MB, False),
    ("bc-7", "exec.cachemount", "cached mount /go/pkg/mod from exec /bin/sh -c go build",
     88 * MB, False),
    ("bc-8", "regular", "[stage-1 2/5] WORKDIR /app", NODE20_LAYERS, True),
    ("bc-9", "source.local", "local source for dockerfile", 4_312, False),
    ("bc-10", "regular", "from local", 0, True),
]


def build():
    images = []
    for tags, size, shared, containers, created in IMAGES:
        seed = tags[0] if tags else "dangling-%d" % created
        repository = tags[0].split(":")[0] if tags else None
        images.append({
            "Containers": containers,
            "Created": created,
            "Id": image_id(seed),
            "Labels": None,
            "ParentId": "",
            # A locally built image has no registry digest; a pulled one does.
            "RepoDigests": (
                None if not tags or repository.startswith(("myapp", "registry"))
                else ["%s@sha256:%s" % (repository, digest(seed + "@")[:64])]
            ),
            "RepoTags": tags or None,
            "SharedSize": shared,
            "Size": size,
        })

    containers = []
    for name, tag, seed, state, status, size_rw, volumes, created in CONTAINERS:
        root_fs = next(i["Size"] for i in images if (i["RepoTags"] or [""])[0] == tag)
        entry = {
            "Command": {"api": "node server.js", "db": "postgres",
                        "web": "nginx -g 'daemon off;'", "cache": "redis-server",
                        "worker": "node worker.js", "old-test-runner": "sh -c ./run-tests.sh",
                        "migrate-once": "node migrate.js", "tmp-shell": "sh"}[name],
            "Created": created,
            "Id": digest("container " + name),
            "Image": tag,
            "ImageID": image_id(seed),
            "Labels": {"com.docker.compose.project": "shop",
                       "com.docker.compose.service": name}
                      if name in ("api", "db", "web", "cache") else {},
            "Mounts": [
                {"Destination": {"api_uploads": "/app/uploads", "pgdata": "/var/lib/postgresql/data",
                                 "node_modules_cache": "/app/node_modules"}[volume],
                 "Driver": "local", "Mode": "z", "Name": volume, "Propagation": "",
                 "RW": True, "Source": "/var/lib/docker/volumes/%s/_data" % volume,
                 "Type": "volume"}
                for volume in volumes
            ],
            "Names": ["/" + name],
            "NetworkSettings": {"Networks": {}},
            "Ports": [],
            "SizeRootFs": root_fs,
            "State": state,
            "Status": status,
        }
        if size_rw:
            entry["SizeRw"] = size_rw
        containers.append(entry)

    volumes = []
    for name, size, references, labels in VOLUMES:
        volumes.append({
            "CreatedAt": "2026-08-14T09:12:41Z",
            "Driver": "local",
            "Labels": labels or None,
            "Mountpoint": "/var/lib/docker/volumes/%s/_data" % name,
            "Name": name,
            "Options": None,
            "Scope": "local",
            "UsageData": {"RefCount": references, "Size": size},
        })

    build_cache = []
    for index, (seed, kind, description, size, shared) in enumerate(BUILD_CACHE):
        build_cache.append({
            "CreatedAt": "2026-09-01T11:0%d:12.482913Z" % (index % 10),
            "Description": description,
            "ID": digest(seed)[:25],
            "InUse": False,
            "LastUsedAt": "2026-09-06T18:2%d:03.118447Z" % (index % 10),
            "Parents": [],
            "Shared": shared,
            "Size": size,
            "Type": kind,
            "UsageCount": 1 + index % 4,
        })

    # Docker counts each layer once, so the total is the images' unique bytes
    # plus the shared pool: the whole of node:20, and alpine's base.
    unique = sum(i["Size"] - i["SharedSize"] for i in images)
    layers_size = unique + NODE20_LAYERS + ALPINE_LAYERS

    return images, containers, volumes, build_cache, layers_size


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    arguments = parser.parse_args()
    arguments.out.mkdir(parents=True, exist_ok=True)

    images, containers, volumes, build_cache, layers_size = build()

    def write(name, payload):
        (arguments.out / name).write_text(json.dumps(payload, indent=1, sort_keys=True) + "\n")

    write("version.json", {
        "ApiVersion": "1.54", "Arch": "arm64", "GitCommit": "f78c987",
        "GoVersion": "go1.25.8", "KernelVersion": "6.10.14-linuxkit", "MinAPIVersion": "1.40",
        "Os": "linux", "Platform": {"Name": "Docker Desktop 4.48.0"}, "Version": "29.3.1",
    })
    write("system_df.json", {
        "BuildCache": build_cache, "Containers": containers, "Images": images,
        "LayersSize": layers_size, "Volumes": volumes,
    })
    write("system_df_image.json", {"Images": images, "LayersSize": layers_size})
    write("system_df_container.json", {"Containers": containers})
    write("system_df_volume.json", {"Volumes": volumes})
    write("system_df_build_cache.json", {"BuildCache": build_cache})
    write("images_json_all_shared.json", images)
    write("containers_json_all_size.json", containers)
    write("volumes.json", {
        "Volumes": [{k: v for k, v in volume.items() if k != "UsageData"} for volume in volumes],
        "Warnings": None,
    })

    total = layers_size + sum(c.get("SizeRw", 0) for c in containers)
    total += sum(v["UsageData"]["Size"] for v in volumes)
    total += sum(b["Size"] for b in build_cache if not b["Shared"])
    print("%s: %d images, %d containers, %d volumes, %d cache records, %.2f GB total"
          % (arguments.out, len(images), len(containers), len(volumes), len(build_cache),
             total / 1e9))


if __name__ == "__main__":
    main()
