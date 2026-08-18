#!/usr/bin/env bash
#
# Build the Ascender production image and push it to a registry using podman.
#
# Usage:
#   ./build_push.sh --org <org> [--registry <host>] [--tag <tag>] [--headless]
#
# Options:
#   -o, --org <org>       required, image becomes <registry>/<org>/ascender:<tag>
#   -r, --registry <host> registry host, default: quay.io
#   -t, --tag <tag>       optional, defaults to <sanitized scm version>-<epoch timestamp>
#       --headless        build without the UI
#   -h, --help            show this help
#
# Preconditions (not checked by this script):
#   - python3.12 with pip and setuptools-scm on PATH
#   - ansible (ansible-core) providing ansible-playbook on PATH, to render the Dockerfile
#   - podman installed with network access for the in-container dnf/npm build
#   - podman logged into the target registry (podman login)
#   - a git checkout that includes the repo tags (the scm version depends on them)
set -euo pipefail

cd "$(dirname "$0")"

REGISTRY="quay.io"
IMAGE_ORG=""
IMAGE_TAG=""
HEADLESS="no"

usage() {
    echo "Usage: $0 --org <org> [--registry <host>] [--tag <tag>] [--headless]"
    echo ""
    echo "Options:"
    echo "  -o, --org <org>       required, image becomes <registry>/<org>/ascender:<tag>"
    echo "  -r, --registry <host> registry host, default: quay.io"
    echo "  -t, --tag <tag>       optional, defaults to <sanitized scm version>-<epoch timestamp>"
    echo "      --headless        build without the UI"
    echo "  -h, --help            show this help"
    exit 1
}

OPTIONS=$(getopt -o o:r:t:h --long org:,registry:,tag:,headless,help -- "$@") || usage
eval set -- "$OPTIONS"

while true; do
    case "$1" in
        -o | --org) IMAGE_ORG="$2"; shift 2 ;;
        -r | --registry) REGISTRY="$2"; shift 2 ;;
        -t | --tag) IMAGE_TAG="$2"; shift 2 ;;
        --headless) HEADLESS="yes"; shift ;;
        -h | --help) usage ;;
        --) shift; break ;;
        *) usage ;;
    esac
done

[ -n "$IMAGE_ORG" ] || { echo "error: --org is required" >&2; usage; }

if [ -z "$IMAGE_TAG" ]; then
    IMAGE_TAG="$(make print-VERSION | tr '+' '_')-$(date +%s)"
fi
IMAGE_REF="$REGISTRY/$IMAGE_ORG/ascender:$IMAGE_TAG"
VERSION="$(make print-VERSION)"

echo "Rendering Dockerfile ..."
make Dockerfile

echo "App version: $VERSION"
echo "Building image $IMAGE_REF ..."
podman build \
    -f Dockerfile \
    --build-arg VERSION="$VERSION" \
    --build-arg SETUPTOOLS_SCM_PRETEND_VERSION="$VERSION" \
    --build-arg HEADLESS="$HEADLESS" \
    -t "$IMAGE_REF" .

echo "Pushing image $IMAGE_REF ..."
podman push "$IMAGE_REF"

echo "$IMAGE_REF" > .image_tag
echo "ascender image: $IMAGE_REF"