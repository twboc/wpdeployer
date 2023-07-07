#!/bin/bash

echo "Stopping all containers..."
docker kill $(docker ps -q)
echo "Removing all containers..."
docker rm $(docker ps -a -q)

docker kill $(docker ps -q)

