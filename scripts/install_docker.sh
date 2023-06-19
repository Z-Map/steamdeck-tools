#! /bin/bash
# This is part of the steamdeck-tools package and under the EUPL v 1.2 license
# Read it here : https://joinup.ec.europa.eu/sites/default/files/custom-page/attachment/2020-03/EUPL-1.2%20EN.txt

set -e

DOCKER_VERSION=${DOCKER_VERSION:-24.0.2}
DOCKER_ROOTLESS=${DOCKER_ROOTLESS:-false}

if [ $(id -u) -eq 0 ]; then
    echo "Do not run this script as root." >&2
    exit 1
fi

echo "Please note that this script will use sudo to run as root when needed."
echo "You need to have setup the password on your account."
echo "This implies that you know what you're doing and you have"
echo "read this script to trust that it's not doing anything problematic."
# See at the end of the file for the use of sudo
read -p "Are you ok with that ? [y/N]" -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]
then
    echo "Aborting ..."
    [[ "$0" = "$BASH_SOURCE" ]] && exit 1 || return 1
fi

if [ "$1" = "uninstall" ]; then
    sudo systemctl disable --now docker.service || true
    sudo systemctl disable --now docker.socket || true
    sudo systemctl disable --now containerd.service || true
    sudo rm -rf \
        /opt/steamos-docker \
        /etc/systemd/system/docker.s* \
        /etc/systemd/system/containerd.service \
        /etc/sysusers.d/docker.conf \
        /etc/udev/rules.d/80-docker.rules \
        /etc/profile.d/steamos-docker.sh
    sudo systemctl daemon-reload
    echo Docker uninstalled.
    exit 0
fi

if $DOCKER_ROOTLESS; then
  docker_mode=docker-rootless-extras
else
  docker_mode=docker
fi

tmp_dir=$(mktemp -d)

function cleanup_tmpdir {
    cd ~
    rm -rf $tmp_dir
}
trap cleanup_tmpdir EXIT

cd $tmp_dir
pwd

curl --fail -o ${tmp_dir}/docker_bin.tgz "https://download.docker.com/linux/static/stable/x86_64/${docker_mode}-${DOCKER_VERSION}.tgz"
tar xzvf docker_bin.tgz

#curl --fail -o ${tmp_dir}/docker_moby.tar.gz "https://codeload.github.com/moby/moby/tar.gz/refs/tags/v${DOCKER_VERSION}"
#tar xzvf docker_moby.tar.gz

echo Create sysusers conf file
echo "g docker - -" > ${tmp_dir}/docker.sysusers
#return 0
echo Download containerd.service
curl --fail -L -o ${tmp_dir}/original-containerd.service "https://raw.githubusercontent.com/containerd/containerd/$(${tmp_dir}/docker/containerd -v | cut -d ' ' -f 4)/containerd.service"

sed -i 's,/usr/local,/opt/steamos-docker,' ${tmp_dir}/original-containerd.service
grep -B 100 '^ExecStart=' ${tmp_dir}/original-containerd.service > ${tmp_dir}/containerd.service
echo "Environment=\"PATH=/opt/steamos-docker/bin:$(systemd-path search-binaries-default)\"" >> ${tmp_dir}/containerd.service
grep -A 100 '^ExecStart=' ${tmp_dir}/original-containerd.service  | tail -n +2 >> ${tmp_dir}/containerd.service
cat containerd.service

# Service unit file
echo Download docker.service
curl --fail -L -o "${tmp_dir}/original-docker.service" "https://raw.github.com/moby/moby/v${DOCKER_VERSION}/contrib/init/systemd/docker.service"
sed -i 's,/usr,/opt/steamos-docker,' "${tmp_dir}/original-docker.service"
grep -B 100 '^ExecReload' ${tmp_dir}/original-docker.service > ${tmp_dir}/docker.service
echo "Environment=\"PATH=/opt/steamos-docker/bin:$(systemd-path search-binaries-default)\"" >> ${tmp_dir}/docker.service
grep -A 100 '^ExecReload' ${tmp_dir}/original-docker.service  | tail -n +2 >> ${tmp_dir}/docker.service
cat docker.service

echo Download docker.socket
curl --fail -L -o "${tmp_dir}/docker.socket" "https://raw.github.com/moby/moby/v${DOCKER_VERSION}/contrib/init/systemd/docker.socket"
echo Download udev rules
curl --fail -L -o "${tmp_dir}/80-docker.rules" "https://raw.github.com/moby/moby/v${DOCKER_VERSION}/contrib/udev/80-docker.rules"


echo Create path script
echo 'append_path "/opt/steamos-docker/bin"' > ${tmp_dir}/steamos-docker.sh


bin_dir="${tmp_dir}/${docker_mode}"
#moby_dir="${tmp_dir}/moby-${DOCKER_VERSION}"
target_dir="${tmp_dir}/fakeroot"
mkdir $target_dir

# Copy binaries
install -Dm755 ${bin_dir}/docker-init "${target_dir}/opt/steamos-docker/bin/docker-init"
install -Dm755 ${bin_dir}/dockerd "${target_dir}/opt/steamos-docker/bin/dockerd"
install -Dm755 ${bin_dir}/docker-proxy "${target_dir}/opt/steamos-docker/bin/docker-proxy"
install -Dm755 ${bin_dir}/docker "${target_dir}/opt/steamos-docker/bin/docker"
install -Dm755 ${bin_dir}/runc "${target_dir}/opt/steamos-docker/bin/runc"
install -Dm755 ${bin_dir}/containerd "${target_dir}/opt/steamos-docker/bin/containerd"
install -Dm755 ${bin_dir}/containerd-shim-runc-v2 "${target_dir}/opt/steamos-docker/bin/containerd-shim-runc-v2"
install -Dm755 ${bin_dir}/ctr "${target_dir}/opt/steamos-docker/bin/ctr"

# Service unit files
install -Dm644 "${tmp_dir}/docker.service" "${target_dir}/etc/systemd/system/docker.service"
install -Dm644 "${tmp_dir}/docker.socket" "${target_dir}/etc/systemd/system/docker.socket"
install -Dm644 "${tmp_dir}/containerd.service" "${target_dir}/etc/systemd/system/containerd.service"

# systemd rules
install -Dm644 "${tmp_dir}/80-docker.rules" "${target_dir}/etc/udev/rules.d/80-docker.rules"
# systemd users
install -Dm644 "${tmp_dir}/docker.sysusers" "${target_dir}/etc/sysusers.d/docker.conf"

# Profile script
install -Dm755  "${tmp_dir}/steamos-docker.sh" "${target_dir}/etc/profile.d/steamos-docker.sh"

# All sudo calls
sudo chown -R root:root ${target_dir}
# Ensure that cleanup will work with the target_dir as root
function cleanup_tmpdir {
    cd ~
    if [[ "${target_dir}" != "/" ]]; then
        sudo rm -rf $tmp_dir
    fi
}
sudo rsync -avh  ${target_dir}/opt /
sudo rsync -avh  ${target_dir}/etc /
# Cleanup
if [[ "${target_dir}" != "/" ]]; then
    sudo rm -rf ${target_dir}
    trap '' EXIT
fi
sudo systemd-sysusers
sudo systemctl daemon-reload

echo "Docker is installed. If you want to use it now please run the following command :"
echo 'export PATH="/opt/steamos-docker/bin:$PATH"'
echo 'You will also need to start / enable the docker service :'
echo 'sudo systemctl start docker'
echo "To use docker without sudo add your user to the docker group."
echo 'sudo usermod -a -G docker $USER'

echo "Yay !"
