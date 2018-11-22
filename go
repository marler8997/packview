t#!/bin/bash
set -ex
./build
sudo mkdir -p /var/cache/packview
sudo chown $(whoami) /var/cache/packview
rmr view
./bin/packview --apt view base-files
rmr view
./bin/packview --apt view build-essential
rmr view
./bin/packview --apt view make
rmr view
./bin/packview --apt view gcc
rmr view
./bin/packview --apt view gcc make
rmr view
./bin/packview --dirs --apt gcc make
rmr view
