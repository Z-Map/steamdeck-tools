# steamdeck-tools

Various tools and helper for the steamdeck / steamos.

# Tool list

## Scripts

- install_docker.sh : install docker static binary in /opt/steamos-docker to
  allow the use of docker in steamos without installing original arch package.
  This should survive reboot, even for the cached image and containers as
  /var/lib/docker is on a writable partition.