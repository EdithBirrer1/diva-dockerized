#!/usr/bin/env bash
#
# Copyright (C) 2020 diva.exchange
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
# Author/Maintainer: Konrad Bächler <konrad@diva.exchange>
#
# -e  Exit immediately if a simple command exits with a non-zero status
set -e

PROJECT_PATH="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"/../
cd ${PROJECT_PATH}
PROJECT_PATH=`pwd`/

IP_SUBNET=172.20.101.
T_IP=3
MAX_IP_RANGE=250

DOMAIN=${DOMAIN:-testnet.diva.i2p}
NAME_NETWORK=${NAME_NETWORK:-network.${DOMAIN}}

if [[ ! -f ${PROJECT_PATH}data/instance ]]
then
  INSTANCE=${INSTANCE:-1}
else
  INSTANCE=$(<${PROJECT_PATH}data/instance)
  ((INSTANCE++))
fi
echo ${INSTANCE} >${PROJECT_PATH}data/instance
chown --reference ${PROJECT_PATH}data ${PROJECT_PATH}data/instance

IDENT=${IDENT:-nx${INSTANCE}}
NAME_I2P=i2p.${DOMAIN}
NAME_IROHA=${IDENT}.${DOMAIN}
NAME_DB=${IDENT}.db.${DOMAIN}
NAME_API=${IDENT}.api.${DOMAIN}

# network
echo "Creating network ${NAME_NETWORK}..."
if [[ ! `docker network ls | fgrep ${NAME_NETWORK}` ]]
then
  docker network create \
    --driver bridge \
    --ipam-driver default \
    --subnet ${IP_SUBNET}0/24 \
    ${NAME_NETWORK} \
    >/dev/null
fi

# get IP's
if [[ ! `docker ps -a | fgrep ${NAME_I2P}` ]]
then
  while [[ `ping -c 1 -w 1 ${IP_SUBNET}${T_IP} >/dev/null ; echo $?` -eq 0 ]]; do ((T_IP++)); done
  IP_I2P=${IP_SUBNET}${T_IP}
  ((T_IP++))
else
  IP_I2P=`docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ${NAME_I2P}`
fi
echo "IP I2P container, ${NAME_I2P}: ${IP_I2P}"

while [[ `ping -c 1 -w 1 ${IP_SUBNET}${T_IP} >/dev/null ; echo $?` -eq 0 ]]; do ((T_IP++)); done
IP_IROHA=${IP_SUBNET}${T_IP}
((T_IP++))
echo "IP Iroha container, ${NAME_IROHA}: ${IP_IROHA}"

while [[ `ping -c 1 -w 1 ${IP_SUBNET}${T_IP} >/dev/null ; echo $?` -eq 0 ]]; do ((T_IP++)); done
IP_DB=${IP_SUBNET}${T_IP}
((T_IP++))
echo "IP database container, ${NAME_DB}: ${IP_DB}"

while [[ `ping -c 1 -w 1 ${IP_SUBNET}${T_IP} >/dev/null ; echo $?` -eq 0 ]]; do ((T_IP++)); done
IP_API=${IP_SUBNET}${T_IP}
((T_IP++))
echo "API container, ${NAME_API}: ${IP_API}"

[[ ${T_IP} -lt ${MAX_IP_RANGE} ]] || exit 128

if [[ ! `docker ps | fgrep ${NAME_I2P}` ]]
then
  echo "Starting ${NAME_I2P} on ${IP_I2P}..."
  docker run \
    --detach \
    --name ${NAME_I2P} \
    --restart unless-stopped \
    --network ${NAME_NETWORK} \
    --ip ${IP_I2P} \
    --env ENABLE_TUNNELS=1 \
    --volume ${NAME_I2P}:/home/i2pd/data/ \
    divax/i2p:latest \
    >/dev/null
  sleep 10
fi

# add tunnel
# replace variables in the tunnel file
sed \
  's!\$IDENT!'"${IDENT}"'!g ; s!\$DOMAIN!'"${DOMAIN}"'!g ; s!\$IP_IROHA!'"${IP_IROHA}"'!g ; s!\$IP_API!'"${IP_API}"'!g' \
  ${PROJECT_PATH}tunnels.conf.d/join.conf >${PROJECT_PATH}data/tunnel.conf
docker cp ${PROJECT_PATH}data/tunnel.conf ${NAME_I2P}:/home/i2pd/tunnels.source.conf.d/${IDENT}.${DOMAIN}.conf
rm ${PROJECT_PATH}data/tunnel.conf
docker restart ${NAME_I2P}
sleep 10

# locally accessible peers
ADD_HOSTS=""
NO_PROXY=""
for nameFile in `docker exec ${NAME_I2P} ls -1 data/destinations/`
do
  b32=$(basename "${nameFile}" .dat)".b32.i2p"
  NO_PROXY="${NO_PROXY}${b32},"
  if [[ ! -f ${PROJECT_PATH}data/${b32} ]]
  then
    # check if b32 address is valid: iroha requires a peer name to start with [a-z].
    # the b32 address will be the peer name.
    if [[ ${b32} =~ ^[^a-z] ]]
    then
      # remove the keys and the tunnel, restart i2p and then exit
      docker exec ${NAME_I2P} rm /home/i2pd/data/${IDENT}.${DOMAIN}.dat
      docker exec ${NAME_I2P} rm /home/i2pd/data/destinations/$(basename "${nameFile}")
      docker exec ${NAME_I2P} rm /home/i2pd/tunnels.source.conf.d/${IDENT}.${DOMAIN}.conf
      docker restart ${NAME_I2P}
      exit 129
    fi

    ADD_HOSTS="${ADD_HOSTS}--add-host ${b32}:${IP_IROHA} "
    echo ${IP_IROHA} >${PROJECT_PATH}data/${b32}
    chown --reference ${PROJECT_PATH}data ${PROJECT_PATH}data/${b32}
    echo ${NAME_IROHA} >${PROJECT_PATH}data/${b32}.name
    chown --reference ${PROJECT_PATH}data ${PROJECT_PATH}data/${b32}.name
  else
    ADD_HOSTS="${ADD_HOSTS}--add-host ${b32}:$(<${PROJECT_PATH}data/${b32}) "
    ADD_HOSTS="${ADD_HOSTS}--add-host $(<${PROJECT_PATH}data/${b32}.name):$(<${PROJECT_PATH}data/${b32}) "
    NO_PROXY="${NO_PROXY}$(<${PROJECT_PATH}data/${b32}.name),"
  fi
done
ADD_HOSTS="${ADD_HOSTS}--add-host ${NAME_IROHA}:${IP_IROHA}"
NO_PROXY="${NO_PROXY}${NAME_IROHA}"
echo "ADD_HOSTS: ${ADD_HOSTS}"
echo "NO_PROXY: ${NO_PROXY}"

# database
echo "Starting ${NAME_DB} on ${IP_DB}..."
docker run \
  --detach \
  --name ${NAME_DB} \
  --restart unless-stopped \
  --stop-timeout 5 \
  --network ${NAME_NETWORK} \
  --ip ${IP_DB} \
  --env POSTGRES_DATABASE=iroha \
  --env POSTGRES_USER=iroha \
  --env POSTGRES_PASSWORD=iroha \
  --volume ${NAME_DB}:/var/lib/postgresql/data/ \
  postgres:10-alpine \
  >/dev/null

# iroha
echo "Starting ${NAME_IROHA} on ${IP_IROHA}..."
docker run \
  ${ADD_HOSTS} \
  --detach \
  --name ${NAME_IROHA} \
  --restart unless-stopped \
  --stop-timeout 5 \
  --network ${NAME_NETWORK} \
  --ip ${IP_IROHA} \
  --env IP_POSTGRES=${IP_DB} \
  --env NAME_DATABASE=iroha \
  --env NAME_PEER="" \
  --env BLOCKCHAIN_NETWORK=testnet.diva.i2p \
  --env IP_HTTP_PROXY=${IP_I2P} \
  --env PORT_HTTP_PROXY=4444 \
  --env NO_PROXY=${NO_PROXY} \
  --volume ${NAME_IROHA}:/opt/iroha/ \
  divax/iroha:latest \
  >/dev/null

# api
echo "Starting ${NAME_API} on ${IP_API}..."
docker run \
  --detach \
  --name ${NAME_API} \
  --restart unless-stopped \
  --network ${NAME_NETWORK} \
  --ip ${IP_API} \
  --env NODE_ENV=development \
  --env IP_LISTEN=${IP_API} \
  --env PORT_LISTEN=19012 \
  --env TORII=${IP_IROHA}:50051 \
  --env I2P_HOSTNAME=${IP_I2P} \
  --env I2P_HTTP_PROXY_PORT=4444 \
  --env I2P_WEBCONSOLE_PORT=7070 \
  --env BOOTSTRAP_PEER="" \
  --env PATH_IROHA=/tmp/iroha/ \
  --volume ${NAME_API}:/home/node/data/ \
  --volume ${NAME_IROHA}:/tmp/iroha/ \
  divax/iroha-node:api-ws \
  >/dev/null
