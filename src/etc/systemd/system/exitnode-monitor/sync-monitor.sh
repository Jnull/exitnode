ROUTES=$(ip route | grep via | grep -v default | awk '{print $1 "," $3  }' | sort | uniq | tr '\n' '|')
TOTAL_ROUTES=$(ip route | grep via | grep -v default | awk '{print $1 "\t" $3  }' | sort | uniq | wc -l)
TOTAL_GATEWAYS=$(ip route | grep via | grep -v default | awk '{print $3 }' | sort | uniq | wc -l)

curl --silent -H 'Content-Type: text/plain' -d $ROUTES -X POST https://peoplesopen.herokuapp.com/api/v0/nodes > /dev/null
curl --silent -H "Content-Type: application/json"  -d "{ \"numberOfRoutes\": $TOTAL_ROUTES, \"numberOfGateways\": $TOTAL_GATEWAYS }" -X POST https://peoplesopen.herokuapp.com/api/v0/monitor > /dev/null
