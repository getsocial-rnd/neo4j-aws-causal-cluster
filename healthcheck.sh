#!/bin/bash

# check if expected ports are open
exitcode=0
ports=(6000 7687 7474)

if [ "$NEO4J_dbms_mode" == "CORE" ]; then
    ports+=(5000)
    ports+=(7000)
fi

for p in ${ports[@]}; do
    nc -w 1 -zv $(hostname) $p
    exitcode=$((exitcode+$?))
done

if [ $exitcode -ne 0 ]; then
    exit $exitcode
fi

# query to get list of nodes in the format:
# http, role
# "http://10.0.y.x:7474", "FOLLOWER"
# "http://10.0.y.x:7474", "LEADER"
# "http://10.0.y.x:7474", "READ_REPLICA"
# "http://10.0.y.x:7474", "FOLLOWER"
COLUMNS="http, role"
QUERY="call dbms.cluster.overview() YIELD addresses, role return addresses[1] as $COLUMNS;"

# save nodes as array
readarray -t nodes < <(echo $QUERY | /var/lib/neo4j/bin/cypher-shell --non-interactive --format plain -u neo4j -p $NEO4J_ADMIN_PASSWORD 2>&1)

if [ "$?" -ne 0 ]; then 
    echo "Query $QUERY failed with error:"
    echo "${nodes[@]}" 
    exit 1
fi

if [ "${nodes[0]}" != "$COLUMNS" ]; then 
    echo "Query response not in the expected format:"
    echo "${nodes[@]}" 
    exit 1
fi

nodes=("${nodes[@]:1}") # remove first element of array, which is word $COLUMNS

# check if this is one node cluster
if [ "${#nodes[@]}" -lt 2 ]; then
    echo "Looks like this node not a part of the cluster. List of nodes:"
    echo "${nodes[@]}" 
    exit 1
fi

exit 0