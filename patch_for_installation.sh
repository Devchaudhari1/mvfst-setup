sudo apt install cmake

sudo apt install libssl-dev openssl

sudo apt-get install         \
    g++                      \
    cmake                    \
    libboost-all-dev         \
    libevent-dev             \
    libdouble-conversion-dev \
    libgoogle-glog-dev       \
    libgflags-dev            \
    libiberty-dev            \
    liblz4-dev               \
    liblzma-dev              \
    libsnappy-dev            \
    make                     \
    zlib1g-dev               \
    binutils-dev             \
    libjemalloc-dev          \
    libssl-dev               \
    pkg-config               \
    libsodium-dev

export OPENSSL_ROOT_DIR=/usr

mkdir tmp
mkdir ./tmp/fbcode_builder_getdeps-ZhomeZdev976ZmvfstZbuildZfbcode_builder/
mkdir ./tmp/fbcode_builder_getdeps-ZhomeZdev976ZmvfstZbuildZfbcode_builder/downloads/
# /tmp/fbcode_builder_getdeps-ZhomeZdevZDesktopZmvfstZbuildZfbcode_builder/ in my case  
# search your path in /tmp?fbcode_builder folder
cp /home/dev/Desktop/mvfst/xz-5.2.5.tar.gz ./tmp/fbcode_builder_getdeps-ZhomeZdevZDesktopZmvfstZbuildZfbcode_builder/downloads/



# Boost wasn´t installing my linux-amd64+kali-6.13.7
python3 -m venv ~/boost183-venv
source ~/boost183-venv/bin/activate

pip install "numpy<2"

# comment --with-python flag in build/fbcode_builder/manifests/boost and build/fbcode_builder/manifests/boost-python

#manual installation 
#of  /tmp/fbcode_builder_getdeps-ZhomeZdevZDesktopZmvfstZbuildZfbcode_builder-root/downloads/libaio-libaio-libaio-0.3.113.tar.gz
cp   /tmp/fbcode_builder_getdeps-ZhomeZdevZDesktopZmvfstZbuildZfbcode_builder-root/downloads/libaio-libaio-libaio-0.3.113.tar.gz
# move to


mkdir -p ~/mvfst-tmp
export TMPDIR=$HOME/mvfst-tmp
export CMAKE_BUILD_PARALLEL_LEVEL=1

#use the --with-systempackage flag to allow kali system packages to be substituted for kali

cd /home/dev/Desktop/mvfst

./build/fbcode_builder/getdeps.py \
    --allow-system-packages \
    build mvfst \
    --num-jobs 2\
    --install-prefix="$(pwd)/_build"

# Enable and build the CMake echo sample:
cd ~/mvfst-tmp/fbcode_builder_getdeps-ZhomeZchetanZProjectsZmvfstZbuildZfbcode_builder/build/mvfst
cmake -DBUILD_SAMPLES=ON .
ninja -j1 echo

    
./getdeps.sh
