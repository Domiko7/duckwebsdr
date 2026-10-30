#!/usr/bin/env bash
set -euo pipefail

export DH_PROJECT="openwebrxplus"
export DH_USERNAME="slechev"

#IMAGES="${DH_PROJECT}-rtlsdr ${DH_PROJECT}-sdrplay ${DH_PROJECT}-hackrf ${DH_PROJECT}-airspy ${DH_PROJECT}-rtlsdr-soapy ${DH_PROJECT}-plutosdr ${DH_PROJECT}-limesdr ${DH_PROJECT}-soapyremote ${DH_PROJECT}-perseus ${DH_PROJECT}-fcdpp ${DH_PROJECT}-radioberry ${DH_PROJECT}-uhd ${DH_PROJECT}-rtltcp ${DH_PROJECT}-runds ${DH_PROJECT}-hpsdr ${DH_PROJECT}-bladerf ${DH_PROJECT}-full ${DH_PROJECT}"
IMAGES="${DH_PROJECT}-full"

ARCH=${ARCH:-$(uname -m)}
TAG=${TAG:-"latest"}
ARCHTAG="${TAG}-${ARCH}"
NIGHTLY_BUILD=$(date +%F)
CORES=$(cat /proc/cpuinfo | grep processor | wc -l)
MAKEFLAGS="${MAKEFLAGS:-"-j$CORES"}"

usage () {
  echo "Usage: ${0} [command]"
  echo "Available commands:"
  echo "  help       Show this usage information"
  echo "  buildn     Build full docker nightly image (current sources)"
  echo "  buildr     Build full docker release image (form Marat's apt repo)"
  echo
  echo "Environment variables:"
  echo "       ARCH - build for different architecture,        ex: ARCH=arm64 ${0} buildn"
  echo "        TAG - use different TAG (default is 'latest'), ex: TAG=mytag ${0} buildn"
  echo "  MAKEFLAGS - set MAKEFLAGS for the compiler,          ex: MAKEFLAGS='-j12' ${0} buildn"
}

nightly () {
  # this build method is used for multiplatform automated builds every night
  # NOTE: this will not work with podman, since it requires specidic docker bulder
  if docker buildx ls >/dev/null 2>&1; then
    echo "Building with docker..."
  else
    echo "This cannot be done with Podman, we need docker buildx drivers."
    exit
  fi

  # create docker builder https://docs.docker.com/build/building/multi-platform/
  # we enable networking so the builder container has access to the host netwoerk (needed for registry)
  echo -e "\n\nCreating docker builder for multiarch...\n\n"
  docker buildx create --name owrxp-builder --driver docker-container --bootstrap --use --driver-opt network=host || true # ignore errors if already created

  # create another docker container for local registry.
  # we need this to store our -base image, because docker builder always try to pull the -base image
  # from dockerhub and not use the localy present -base image for building the -full image.
  echo -e "\n\nCreating local docker registry...\n\n"
  docker container rm -vf registry 2>/dev/null || true # remove an existing registry container (ignoring errors)
  docker run -d --name registry --network=host registry:2 # create new registry container

  # build the -base image and store it in local registry (see the tags)
  echo -e "\n\nBuilding the base image for AMD64, ARM64v8 and ARM32v7.\n\n"
  time docker buildx build \
    --platform linux/amd64,linux/arm64,linux/arm/v7 \
    --build-arg MAKEFLAGS="$MAKEFLAGS" \
    -t localhost:5000/${DH_PROJECT}-base:${NIGHTLY_BUILD} \
    -t localhost:5000/${DH_PROJECT}-base \
    --push --pull -f docker/Dockerfiles/Dockerfile-base .

  GIT_HASH=$(git rev-parse --short master)

  # build the -full image using the -base from LOCAL_REGISTRY
  echo -e "\n\nBuilding the full image for AMD64, ARM64v8 and ARM32v7.\n\n"
  time docker buildx build \
    --platform linux/amd64,linux/arm64,linux/arm/v7 \
    --build-arg LOCAL_REGISTRY="localhost:5000/" \
    --build-arg GIT_HASH=${GIT_HASH} \
    --build-arg ARCHTAG=latest \
    --build-arg PROJECT=${DH_PROJECT} \
    --build-arg MAKEFLAGS="$MAKEFLAGS" \
    -t ${DH_USERNAME}/${DH_PROJECT}-nightly:${NIGHTLY_BUILD} \
    -t ${DH_USERNAME}/${DH_PROJECT}-nightly \
    --pull=false \
    --push -f docker/Dockerfiles/Dockerfile-full .

  echo -e "\n\nRemoving docker builder (keeping state/caches for next use)...\n\n"
  docker buildx rm --keep-state owrxp-builder # keep state is needed to keep the caches for the next build

  echo -e "\n\nRemoving local docker registry...\n\n"
  docker container rm -vf registry
}

release () {
  # this build method is used for multiplatform release builds
  # NOTE: this will not work with podman, since it requires specidic docker bulder
  if docker buildx ls >/dev/null 2>&1; then
    echo "Building with docker..."
  else
    echo "This cannot be done with Podman, we need docker buildx drivers."
    exit
  fi

  if [[ -z ${1:-} ]] ; then
    echo "Usage: ${0} dorelease [version]"
    echo "NOTE: The version param will be used for tagging only."
    echo "The image will be built from the current packages in the apt-repo."
    echo; echo;
    return
  fi

  # create docker builder https://docs.docker.com/build/building/multi-platform/
  # we enable networking so the builder container has access to the host netwoerk (needed for registry)
  echo -e "\n\nCreating docker builder for multiarch...\n\n"
  docker buildx create --name owrxp-builder --driver docker-container --bootstrap --use --driver-opt network=host || true # ignore errors if already created

  echo -ne "\n\nBuilding release image: $1.\n\n"
	docker buildx build \
    --platform linux/amd64,linux/arm64,linux/arm/v7 \
    --build-arg VERSION=$1 \
    --build-arg MAKEFLAGS="$MAKEFLAGS" \
    -t ${DH_USERNAME}/${DH_PROJECT}:${1} \
    -t ${DH_USERNAME}/${DH_PROJECT} \
    --pull --push -f docker/deb_based/Dockerfile .

  echo -e "\n\nRemoving docker builder (keeping state/caches for next use)...\n\n"
  docker buildx rm --keep-state owrxp-builder # keep state is needed to keep the caches for the next build
}

buildn () {
  PLATFORM=""
  if [[ "${ARCH}" != "$(uname -m)" ]]; then
    PLATFORM="--platform=linux/$ARCH"
  fi

  echo -ne "\n\nBuilding the base image for $ARCH.\n\n"
  time docker build $PLATFORM \
    --build-arg MAKEFLAGS="$MAKEFLAGS" \
    -t ${DH_PROJECT}-base:${ARCHTAG} \
    --pull -f docker/Dockerfiles/Dockerfile-base .

  # NOTE: uncomment next 2 lines if you're building all images
  #echo -ne "\n\nBuilding soapysdr image.\n\n"
  #docker build $PLATFORM --build-arg ARCHTAG=${ARCHTAG} --build-arg PROJECT=${DH_PROJECT} --build-arg MAKEFLAGS="$MAKEFLAGS" -t ${DH_PROJECT}-soapysdr-base:${ARCHTAG} -f docker/Dockerfiles/Dockerfile-soapysdr .

  GIT_HASH=$(git rev-parse --short master)
  for image in ${IMAGES}; do
    i=$(echo ${image} | rev | cut -d- -f1 | rev)
    # "openwebrx" is a special image that gets tag-aliased later on
    if [[ ! -z "${i}" && "${i}" != "${DH_PROJECT}" ]] ; then
      echo -ne "\n\nBuilding ${i} image for $ARCH.\n\n"
      time docker build $PLATFORM \
        --build-arg GIT_HASH=${GIT_HASH} \
        --build-arg ARCHTAG=$ARCHTAG \
        --build-arg PROJECT=${DH_PROJECT} \
        --build-arg MAKEFLAGS="$MAKEFLAGS" \
        -t ${DH_USERNAME}/${image}:${ARCHTAG} \
        -f docker/Dockerfiles/Dockerfile-${i} .
    fi
  done

  # tag full image alias image
  docker tag ${DH_USERNAME}/${DH_PROJECT}-full:${ARCHTAG} ${DH_USERNAME}/${DH_PROJECT}-nightly:${NIGHTLY_BUILD}
  docker tag ${DH_USERNAME}/${DH_PROJECT}-full:${ARCHTAG} ${DH_USERNAME}/${DH_PROJECT}-nightly
}

buildr () {
  if [[ -z ${1:-} ]] ; then
    echo "Usage: ${0} buildr [version]"
    echo "NOTE: The version param will be used for tagging only."
    echo "The image will be built from the current packages in the apt-repo."
    echo; echo;
    return
  fi

  PLATFORM=""
  if [[ "${ARCH}" != "$(uname -m)" ]]; then
    PLATFORM="--platform=linux/$ARCH"
  fi

  echo -ne "\n\nBuilding release image for $ARCH: $1.\n\n"
	docker build $PLATFORM \
    --build-arg VERSION=$1 \
    --build-arg MAKEFLAGS="$MAKEFLAGS" \
    -t ${DH_USERNAME}/${DH_PROJECT}:${1}-${ARCH} \
    -t ${DH_USERNAME}/${DH_PROJECT}:${1} \
    -t ${DH_USERNAME}/${DH_PROJECT} \
    --pull -f docker/deb_based/Dockerfile .
}

dev () {
  if [[ -z ${1:-} ]] ; then
    echo "Usage: ${0} dev [ImageId]"; echo; echo;
    docker image ls
    return
  fi
  docker run --rm -it --entrypoint /bin/bash -p 8073:8073 --device /dev/bus/usb ${1}
}

run () {
  docker run --rm -it -p 8073:8073 --device /dev/bus/usb openwebrxplus-full:latest-${ARCH}
}

case ${1:-} in
  build) buildn ;; # alias for buildn
  buildn) buildn ;;
  buildr) buildr ${@:2} ;;
  dev) dev ${@:2} ;;
  run) run ;;
  donightly) nightly ;;
  dorelease) release ${@:2} ;;
  *) usage ;;
esac
