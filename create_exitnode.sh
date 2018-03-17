#!/bin/sh

IP=$1
GATEWAY_IP=$2

MESH_IP=100.64.0.42
MESH_PREFIX=32
MESHNET=100.64.0.0/10
ETH_IF=eth0
PUBLIC_IP=$IP
PUBLIC_SUBNET="$IP/29"

EXITNODE_REPO=jhpoelen/exitnode
TUNNELDIGGER_REPO=wlanslovenija/tunneldigger
TUNNELDIGGER_COMMIT=210037aabf8538a0a272661e08ea142784b42b2c

DEBIAN_FRONTEND=noninteractive apt-get update && apt-get install -yq --force-yes \
  build-essential \
  ca-certificates \
  curl \
  git \
  libssl-dev \
  libxslt1-dev \
  module-init-tools \
  openssh-server \
  openssl \
  perl \
  dnsmasq \
  procps \
  python-psycopg2 \
  python-software-properties \
  software-properties-common \
  python \
  python-dev \
  python-pip \
  libnetfilter-conntrack3 \
  ebtables \
  vim \
  iproute \
  bridge-utils \
  libnetfilter-conntrack-dev \
  libnfnetlink-dev \
  libffi-dev \
  libevent-dev \
  tmux

KERNEL_VERSION=$(uname -r)
echo kernel version [$KERNEL_VERSION]

DEBIAN_FRONTEND=noninteractive apt-get install -yq --force-yes \
  cmake \
  libnl-3-dev \
  libnl-genl-3-dev \
  build-essential \
  pkg-config \
  linux-image-extra-$(uname -r)

mkdir ~/babel_build
git clone https://github.com/sudomesh/babeld.git ~/babel_build/
cd ~/babel_build

make && make install

REQUIRED_MODULES="nf_conntrack_netlink nf_conntrack nfnetlink l2tp_netlink l2tp_core l2tp_eth"

for module in $REQUIRED_MODULES
do
  if grep -q "$module" /etc/modules
  then
    echo "$module already in /etc/modules"
  else
    echo "\n$module" >> /etc/modules
  fi
  modprobe $module
done

pip install --upgrade pip

pip install netfilter
pip install virtualenv

TUNNELDIGGER_HOME=/opt/tunneldigger
git clone https://github.com/${TUNNELDIGGER_REPO} $TUNNELDIGGER_HOME
cd $TUNNELDIGGER_HOME
git checkout $TUNNELDIGGER_COMMIT
virtualenv $TUNNELDIGGER_HOME/broker/env_tunneldigger
source broker/env_tunneldigger/bin/activate
cd broker
python setup.py install

TUNNELDIGGER_UPHOOK_SCRIPT=$TUNNELDIGGER_HOME/broker/scripts/up_hook.sh
TUNNELDIGGER_DOWNHOOK_SCRIPT=$TUNNELDIGGER_HOME/broker/scripts/down_hook.sh

cat >$TUNNELDIGGER_UPHOOK_SCRIPT <<EOF
#!/bin/sh
ip link set \$3 up
ip addr add $MESH_IP/$MESH_PREFIX dev \$3
ip link set dev \$3 mtu \$4
babeld -a \$3
EOF

chmod 755 $TUNNELDIGGER_UPHOOK_SCRIPT 

cat >$TUNNELDIGGER_DOWNHOOK_SCRIPT <<EOF
#!/bin/sh
babeld -x \$3
EOF

chmod 755 $TUNNELDIGGER_DOWNHOOK_SCRIPT 

cat >/etc/babeld.conf <<EOF
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

git clone https://github.com/${EXITNODE_REPO} /opt/exitnode
cp -r /opt/exitnode/src/etc/* /etc/
cp /opt/exitnode/l2tp_broker.cfg $TUNNELDIGGER_HOME/broker/l2tp_broker.cfg

# Setup public ip in tunneldigger.cfg
CFG="$TUNNELDIGGER_HOME/broker/l2tp_broker.cfg"

sed -i.bak "s#address=[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+#address=$PUBLIC_IP#" $CFG
sed -i.bak "s#interface=lo#interface=$ETH_IF#" $CFG 

# for Digital Ocean only
sed -i 's/dns-nameservers.*/dns-nameservers 8.8.8.8/g' /etc/network/interfaces.d/50-cloud-init.cfg
sed -i '/address/a \   \ dns-nameservers 8.8.8.8' /etc/network/interfaces.d/50-cloud-init.cfg 



# start babeld and tunnel digger on reboot
systemctl enable sudomesh-gateway
systemctl enable tunneldigger
systemctl enable babeld

service sudomesh-gateway start
service tunneldigger start
service babeld start

reboot now
