#!/bin/sh

AULA_IMAGE=quay.io/liqd/aula:aula-docker-0.4

if [ "$1" = "--connect" ]; then
    export CONNECT_TO_RUNNING_CONTAINER=1
fi

export VOLUMES="-v `pwd`:/liqd/aula"

if [ "$AULA_SAMPLES" != "" ]; then
    export VOLUMES="$VOLUMES -v $AULA_SAMPLES:/liqd/html-templates"
fi

if [ "$CONNECT_TO_RUNNING_CONTAINER" = "1" ]; then
    docker exec -it `docker ps -q --filter="ancestor=$AULA_IMAGE"` /bin/bash
else
    docker run -it --rm -p 8080:8080 -p 5900:5900 -p 8888:8888 $VOLUMES $AULA_IMAGE /bin/bash
fi
