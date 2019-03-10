#!/bin/sh

if [ "$#" -ne 2 ]; then
  echo "You did not pass the correct number of arguments.

If you are not sure how to use this script, have a look at the README.md.
This script installs software and writes config files onto the computer on which it is executed.

Usage: sudo create_exitnode.sh <PUBLIC_IP> <DEFAULT_INTERFACE_NAME>" 1>&2
  exit 1
fi

if [ "$(id -u)" != "0" ]; then
  echo "This script must be run as root" 1>&2
  exit 1
fi

set -x
set -e

PUBLIC_IP=$1
PUBLIC_SUBNET="$PUBLIC_IP/29"

MESH_IP=100.64.0.42
MESH_PREFIX=32
MESHNET=100.64.0.0/10
ETH_IF=$2

EXITNODE_REPO=sudomesh/exitnode
TUNNELDIGGER_REPO=wlanslovenija/tunneldigger
TUNNELDIGGER_COMMIT=210037aabf8538a0a272661e08ea142784b42b2c
BABEL_REPO=/jech/babeld
BABEL_TAG="babeld-1.8.2"

echo kernel version ["$(uname -r)"]

release_info="$(cat /etc/*-release)"
echo "release_info=$release_info"
release_name="$(echo "$release_info" | grep ^NAME= | cut -d'=' -f2)"
echo "release_name=[$release_name]"
DEBIAN_FRONTEND=noninteractive apt-get update

if [ "$release_name" = '"Ubuntu"' ]; then
  DEBIAN_FRONTEND=noninteractive apt-get install -yq --force-yes \
      "linux-modules-extra-$(uname -r)"
fi 

DEBIAN_FRONTEND=noninteractive apt-get install -yq --force-yes \
  build-essential \
  ca-certificates \
  curl \
  git \
  zlib1g \
  zlib1g-dev \
  libssl-dev \
  libxslt1-dev \
  kmod \
  bridge-utils \
  openssh-server \
  openssl \
  perl \
  dnsmasq \
  procps \
  python-psycopg2 \
  software-properties-common \
  python \
  python-dev \
  python-pip \
  iproute \
  libnetfilter-conntrack3 \
  libevent-dev \
  ebtables \
  vim \
  iproute2 \
  bridge-utils \
  libnetfilter-conntrack-dev \
  libnfnetlink-dev \
  libffi-dev \
  libevent-dev \
  tmux \
  netcat-openbsd

DEBIAN_FRONTEND=noninteractive apt-get install -yq --force-yes \
  cmake \
  libnl-3-dev \
  libnl-genl-3-dev \
  build-essential \
  pkg-config

BABEL_BUILD=/root/babel_build
if [ -e $BABEL_BUILD ]; then
    rm -r $BABEL_BUILD
fi

mkdir $BABEL_BUILD
cd $BABEL_BUILD 
git clone https://github.com/$BABEL_REPO $BABEL_BUILD 
git checkout tags/$BABEL_TAG

make && make install

REQUIRED_MODULES="nf_conntrack_netlink nf_conntrack nfnetlink l2tp_netlink l2tp_core l2tp_eth"

for module in $REQUIRED_MODULES
do
  if grep -q "$module" /etc/modules
  then
    echo "$module already in /etc/modules"
  else
    echo "$module" >> /etc/modules
  fi
  modprobe "$module"
done

# see https://askubuntu.com/questions/561377/pip-wont-run-throws-errors-instead
easy_install -U pip

pip install netfilter
pip install virtualenv

TUNNELDIGGER_HOME=/opt/tunneldigger
if [ -e "$TUNNELDIGGER_HOME" ]; then
    rm -r $TUNNELDIGGER_HOME
fi
git clone https://github.com/$TUNNELDIGGER_REPO $TUNNELDIGGER_HOME
cd $TUNNELDIGGER_HOME
git checkout $TUNNELDIGGER_COMMIT
virtualenv $TUNNELDIGGER_HOME/broker/env_tunneldigger
# shellcheck disable=SC1091
. broker/env_tunneldigger/bin/activate
cd broker
python setup.py install

TUNNELDIGGER_UPHOOK_SCRIPT=$TUNNELDIGGER_HOME/broker/scripts/up_hook.sh
TUNNELDIGGER_DOWNHOOK_SCRIPT=$TUNNELDIGGER_HOME/broker/scripts/down_hook.sh

cat >$TUNNELDIGGER_UPHOOK_SCRIPT <<EOF
#!/bin/sh
ip link set \$3 up
ip addr add $MESH_IP/$MESH_PREFIX dev \$3
ip link set dev \$3 mtu \$4
# babeld is listening on port 31337
(echo "interface \$3") | nc -q1 ::1 31337
EOF

chmod 755 $TUNNELDIGGER_UPHOOK_SCRIPT 

cat >$TUNNELDIGGER_DOWNHOOK_SCRIPT <<EOF
#!/bin/sh
# babeld is listening on port 31337
(echo "flush interface \$3") | nc -q1 ::1 31337
EOF

chmod 755 $TUNNELDIGGER_DOWNHOOK_SCRIPT 

cat >/etc/babeld.conf <<EOF
local-port-readwrite 31337
redistribute local ip $MESH_IP/$MESH_PREFIX allow
redistribute local ip 0.0.0.0/0 proto 3 metric 128 allow
redistribute if $ETH_IF metric 128
redistribute local ip $PUBLIC_SUBNET proto 0 deny
redistribute local deny
EOF

cat >/etc/default/sudomesh-gateway <<EOF
# generated by create_exitnode.sh 
# sourced by /etc/init.d/sudomesh-gateway

MESHNET="$MESHNET"

# make sure that default route has static protocol for babeld to work
# see https://github.com/jech/babeld/blob/1a6135dca042f0f22dc450699a900e3ca7bc06ca/README#L88
DEFAULT_ROUTE="$(ip route | head -n1 | sed 's/onlink/proto static/g')"
EOF

EXITNODE_HOME=/opt/exitnode
if [ -e $EXITNODE_HOME ]; then
    rm -r $EXITNODE_HOME 
fi
git clone https://github.com/$EXITNODE_REPO -b upgrade-babeld $EXITNODE_HOME 
cp -r $EXITNODE_HOME/src/etc/* /etc/
cp -r $EXITNODE_HOME/src/opt/* /opt/
mkdir -p /var/lib/babeld
cp $EXITNODE_HOME/l2tp_broker.cfg $TUNNELDIGGER_HOME/broker/l2tp_broker.cfg

# Setup public ip in tunneldigger.cfg
CFG="$TUNNELDIGGER_HOME/broker/l2tp_broker.cfg"

# Disabling stylistic shellcheck warning to favor readability.
# shellcheck disable=SC1117
sed -i.bak "s#address=[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+#address=$PUBLIC_IP#" $CFG
sed -i.bak "s#interface=lo#interface=$ETH_IF#" $CFG 

DIGITAL_OCEAN_CLOUD_INIT=/etc/network/interfaces.d/50-cloud-init.cfg
if [ -f $DIGITAL_OCEAN_CLOUD_INIT ]; then
  # for Digital Ocean only
  sed -i 's/dns-nameservers.*/dns-nameservers 8.8.8.8/g' $DIGITAL_OCEAN_CLOUD_INIT
  sed -i '/address/a \   \ dns-nameservers 8.8.8.8' $DIGITAL_OCEAN_CLOUD_INIT
fi 

# start babeld and tunnel digger on reboot
systemctl enable sudomesh-gateway
systemctl enable tunneldigger
systemctl enable babeld

service sudomesh-gateway start
service tunneldigger start
service babeld start

systemctl start babeld-monitor.timer
systemctl enable babeld-monitor.timer

reboot now
