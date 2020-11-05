#!/bin/bash

# wait for Neo4j Bolt port is open
while ! nc -z $(hostname) 7687; do
  sleep 0.1 # wait for 1/10 of the second before check again
done

sleep 10


# Run APOC's warmup.
warmup() {
    query="CALL apoc.warmup.run();"

    echo "Warmup: Running..."
    echo
    echo "===================="
    echo ${query} | /var/lib/neo4j/bin/cypher-shell -d system
    echo "===================="
    echo
    echo "Warmup: Done."
    echo
}

# NOTE: for these tasks neo4j admin credentials are read from environment.

# create guest user
if [ "${GUEST_USERNAME}" != "" ] && [ "${GUEST_PASSWORD}" != "" ] ; then
    query="CALL dbms.security.createUser('${GUEST_USERNAME}', '${GUEST_PASSWORD}', false);"

    # XXX: this is commented now since 3.4 has a warmup mechanism built-in.
    # if you want an older version, feel free to uncomment and use APOC's warmup.

    # warmup
    #

    echo "Guest user: Creating user '${GUEST_USERNAME}'..."
    # this may fail if user already exists. alright, fine.
    echo "===================="
    echo ${query} | /var/lib/neo4j/bin/cypher-shell -d system
    status=$?
    if [ "$status" -eq 0 ] ; then
        echo "Guest user: Created."
    else
        echo "Guest user: Failed to create. Proceeding..."
    fi
    echo "===================="
    echo

    query="CALL dbms.security.addRoleToUser('reader', '${GUEST_USERNAME}');"
    echo "Guest user: Adding 'reader' role."
    echo "===================="
    echo ${query} | /var/lib/neo4j/bin/cypher-shell -d system
    status=$?
    if [ "$status" -eq 0 ] ; then
        echo "Guest user: Role added."
    else
        echo "Guest user: Failed to add role. Proceeding..."
    fi
    echo "===================="
    echo
fi
