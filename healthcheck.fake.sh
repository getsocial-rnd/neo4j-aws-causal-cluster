#!/bin/bash

# this helathcheck will be used during the backup restore process
# to make sure, that container will not be killed due to healthcheck
# before restore completed

echo "Fake healthcheck executed"

exit 0