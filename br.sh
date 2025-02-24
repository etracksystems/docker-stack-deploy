#!/bin/zsh

docker context use default
docker build -t ghcr.io/etracksystems/docker-stack-deploy:latest .

docker run --rm \
  -v "$(pwd)":/github/workspace \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --env-file=.env.deploy \
  -e REMOTE_PRIVATE_KEY="$(cat ~/.ssh/id_ed25519)" \
  ghcr.io/etracksystems/docker-stack-deploy:latest
