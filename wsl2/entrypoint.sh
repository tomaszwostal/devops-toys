#!/usr/bin/env sh
set -e

cd /build
git init
git remote add origin https://github.com/microsoft/WSL2-Linux-Kernel.git
git config --local gc.auto 0
git -c protocol.version=2 fetch --no-tags --prune --progress --no-recurse-submodules --depth=1 origin +linux-msft-wsl-5.15.137.3:refs/remotes/origin/build/linux-msft-wsl-5.15.y
git checkout --progress --force -B build/linux-msft-wsl-5.15.y refs/remotes/origin/build/linux-msft-wsl-5.15.y
sed -i 's/# CONFIG_NETFILTER_XT_MATCH_RECENT is not set/CONFIG_NETFILTER_XT_MATCH_RECENT=y/' Microsoft/config-wsl
make -j2 KCONFIG_CONFIG=Microsoft/config-wsl

