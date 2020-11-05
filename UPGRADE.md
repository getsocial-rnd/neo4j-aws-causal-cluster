# Upgrade from 3.5.x to 4.x.x

**Important** upgrade can be done only to **offline** database. So instead we will create new upgraded cluster and switch our application to use it.

We tried to automate upgrade upgrade as much as possible, based on the [one of the official migration guides](https://neo4j.com/docs/migration-guide/4.0/online-backup-copy-database/#tutorial-online-backup-copy-database), however, some manual operations are needed in any case.

1. (Optionally) Enable logging of **all queries** (set `SlowQueryLog` to `0ms`) on the current cluster.

1. Create **NEW** neo4j stack, similar to existing one with following differences:
   - Set `UpgradeMode` to `true`
   - Set `BackupPath` to latest s3 backup path from current cluster, for example: `neo4j-testing-cluster-backup/hourly/neo4j-backup-1611139867.zip`
   - Use some different `CloudMapNamespaceName` from the one used in the old cluster.
   - Make sure, to create disk big enough to store ~2.5x of current data: DB size + Unzipped backup size and to have free space left.

1. Wait for Neo4j node to come online

1. Open the CloudWatch logs (can be found in CloudFormation UI -> Stack -> **Resources** tab -> `CloudwatchLogsGroup`):
    1. Find following line:

            You have to manually apply the above commands to the database when it is stared to recreate the indexes and constraints

        Well, it means what it says, this commands will be needed to run manually once cluster is ready

    1. Find the result of S3 upload of `.dump` file, and copy its S3 path (like `neo4j-test-cluster/dumps/neo4j-1611146313.dump`)

1. [Stop cluster](README.md#stop-cluster) as described in (`README.md`)

1. Now we need to update our stack changing following parameters:
    - Set `UpgradeMode` to `false`
    - Set `BackupPath` to the `.dump` file from previous step

1. Wait for cluster to come online

1. Apply the queries from the step before:
    Can be done via WebUI, copying queries from CloudWatch one by one or

    SSH to the instance, that were used for initial migration:

        docker exec -it <container_id> bash
        cat logs/neo4j-admin-copy-*.log | grep "CALL"`
        # Copy results into buffer
        /var/lib/neo4j/bin/cypher-shell -u neo4j -p $NEO4J_ADMIN_PASSWORD -a neo4j://core.<neo4j-domain>:7687
        # Paste results from buffer
        # (keep in mind, that last query is missing `;` for some reason, so you will have to add it)


1. Done. Now you would want to point your application so the new cluster.

   However, while you were performing this steps, old cluster were still in use and some new data were written there.
   And now your data is outdated, what you can do, is to find all the relevant write queries made to your old cluster mad **after the backup you used to create new cluster from**
   and replay them on the new cluster. This is not perfect, but at least something :shrug:
