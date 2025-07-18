#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

if [ ! -z "$TAG_BASE" ] && version_gt $TAG_BASE "7.9.99" && [ ! -z "$CONNECTOR_TAG" ] && ! version_gt $CONNECTOR_TAG "2.14.8"
then
     logwarn "minimal supported connector version is 2.14.9 for CP 8.0"
     logwarn "see https://docs.confluent.io/platform/current/connect/supported-connector-version-8.0.html#supported-connector-versions-in-cp-8-0"
     exit 111
fi

if [ ! -z "$GITHUB_RUN_NUMBER" ]
then
     # running with github actions
     remove_cdb_oracle_image "LINUX.X64_213000_db_home.zip" "../../connect/connect-cdc-oracle21-source/ora-setup-scripts-cdb-table"
fi

create_or_get_oracle_image "LINUX.X64_213000_db_home.zip" "../../connect/connect-cdc-oracle21-source/ora-setup-scripts-pdb-table"

PLAYGROUND_ENVIRONMENT=${PLAYGROUND_ENVIRONMENT:-"plaintext"}
playground start-environment --environment "${PLAYGROUND_ENVIRONMENT}" --docker-compose-override-file "${PWD}/docker-compose.plaintext.pdb-table.yml"


playground container logs --container oracle --wait-for-log "DATABASE IS READY TO USE" --max-wait 600
log "Oracle DB has started!"
log "Setting up Oracle Database Prerequisites"
docker exec -i oracle bash -c "ORACLE_SID=ORCLCDB;export ORACLE_SID;sqlplus /nolog" << EOF
     CONNECT sys/Admin123 AS SYSDBA
     ALTER SESSION SET CONTAINER=CDB\$ROOT;
     CREATE ROLE C##CDC_PRIVS;
     CREATE USER C##MYUSER IDENTIFIED BY mypassword CONTAINER=ALL;
     ALTER USER C##MYUSER QUOTA UNLIMITED ON USERS;
     ALTER USER C##MYUSER SET CONTAINER_DATA = (CDB\$ROOT, ORCLPDB1) CONTAINER=CURRENT;
     GRANT C##CDC_PRIVS to C##MYUSER CONTAINER=ALL;

     GRANT CREATE SESSION TO C##CDC_PRIVS CONTAINER=ALL;
     GRANT EXECUTE ON SYS.DBMS_LOGMNR TO C##CDC_PRIVS CONTAINER=ALL;
     GRANT LOGMINING TO C##CDC_PRIVS CONTAINER=ALL;
     GRANT SELECT ON V_\$LOGMNR_CONTENTS TO C##CDC_PRIVS CONTAINER=ALL;
     GRANT SELECT ON V_\$DATABASE TO C##CDC_PRIVS CONTAINER=ALL;
     GRANT SELECT ON V_\$THREAD TO C##CDC_PRIVS CONTAINER=ALL;
     GRANT SELECT ON V_\$PARAMETER TO C##CDC_PRIVS CONTAINER=ALL;
     GRANT SELECT ON V_\$NLS_PARAMETERS TO C##CDC_PRIVS CONTAINER=ALL;
     GRANT SELECT ON V_\$TIMEZONE_NAMES TO C##CDC_PRIVS CONTAINER=ALL;
     GRANT CONNECT TO C##CDC_PRIVS CONTAINER=ALL;
     GRANT SELECT ON DBA_PDBS TO C##CDC_PRIVS CONTAINER=ALL;
     GRANT SELECT ON CDB_TABLES TO C##CDC_PRIVS CONTAINER=ALL;

     GRANT CREATE TABLE TO C##MYUSER container=all;
     GRANT CREATE SEQUENCE TO C##MYUSER container=all;
     GRANT CREATE TRIGGER TO C##MYUSER container=all;
     GRANT FLASHBACK ANY TABLE TO C##MYUSER container=all;

     -- The following privileges are required additionally for 21c compared to 12c.
     GRANT SELECT ON V_\$ARCHIVED_LOG TO C##CDC_PRIVS CONTAINER=ALL;
     GRANT SELECT ON V_\$LOG TO C##CDC_PRIVS CONTAINER=ALL;
     GRANT SELECT ON V_\$LOGFILE TO C##CDC_PRIVS CONTAINER=ALL;
     GRANT SELECT ON V_\$INSTANCE to C##CDC_PRIVS CONTAINER=ALL;
     GRANT EXECUTE ON SYS.DBMS_LOGMNR TO C##CDC_PRIVS;
     GRANT EXECUTE ON SYS.DBMS_LOGMNR_D TO C##CDC_PRIVS;
     
     -- Enable Supplemental Logging for All Columns
     ALTER SESSION SET CONTAINER=cdb\$root;
     ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;
     ALTER DATABASE ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

     -- Check Database Instance Version
     GRANT SELECT ON V_\$INSTANCE to C##CDC_PRIVS;
     
     GRANT CREATE materialized view to C##CDC_PRIVS container=all;
EOF

log "Inserting initial data"
docker exec -i oracle sqlplus C\#\#MYUSER/mypassword@//localhost:1521/ORCLPDB1 << EOF

     create table CUSTOMERS (
          id NUMBER(10) GENERATED BY DEFAULT ON NULL AS IDENTITY (START WITH 42) NOT NULL PRIMARY KEY,
          first_name VARCHAR(50),
          last_name VARCHAR(50),
          email VARCHAR(50),
          gender VARCHAR(50),
          club_status VARCHAR(20),
          comments VARCHAR(90),
          create_ts timestamp DEFAULT CURRENT_TIMESTAMP ,
          update_ts timestamp
     );

     CREATE OR REPLACE TRIGGER TRG_CUSTOMERS_UPD
     BEFORE INSERT OR UPDATE ON CUSTOMERS
     REFERENCING NEW AS NEW_ROW
     FOR EACH ROW
     BEGIN
     SELECT SYSDATE
          INTO :NEW_ROW.UPDATE_TS
          FROM DUAL;
     END;
     /

     insert into CUSTOMERS (first_name, last_name, email, gender, club_status, comments) values ('Rica', 'Blaisdell', 'rblaisdell0@rambler.ru', 'Female', 'bronze', 'Universal optimal hierarchy');
     insert into CUSTOMERS (first_name, last_name, email, gender, club_status, comments) values ('Ruthie', 'Brockherst', 'rbrockherst1@ow.ly', 'Female', 'platinum', 'Reverse-engineered tangible interface');
     insert into CUSTOMERS (first_name, last_name, email, gender, club_status, comments) values ('Mariejeanne', 'Cocci', 'mcocci2@techcrunch.com', 'Female', 'bronze', 'Multi-tiered bandwidth-monitored capability');
     insert into CUSTOMERS (first_name, last_name, email, gender, club_status, comments) values ('Hashim', 'Rumke', 'hrumke3@sohu.com', 'Male', 'platinum', 'Self-enabling 24/7 firmware');
     insert into CUSTOMERS (first_name, last_name, email, gender, club_status, comments) values ('Hansiain', 'Coda', 'hcoda4@senate.gov', 'Male', 'platinum', 'Centralized full-range approach');
    
     
     CREATE MATERIALIZED VIEW CUSTOMERS_MV AS SELECT * FROM CUSTOMERS;
     
      exit;
     
EOF

log "Grant select on CUSTOMERS table"
docker exec -i oracle sqlplus C\#\#MYUSER/mypassword@//localhost:1521/ORCLPDB1 << EOF
     ALTER SESSION SET CONTAINER=ORCLPDB1;
     GRANT select on CUSTOMERS_MV TO C##MYUSER;
     
EOF

log "Creating Oracle source connector"
playground connector create-or-update --connector cdc-oracle-source-pdb-mview --package "io.confluent.connect.oracle.cdc.util.metrics.MetricsReporter" --level DEBUG  << EOF
{
     "connector.class": "io.confluent.connect.oracle.cdc.OracleCdcSourceConnector",
     "log.sensitive.data": "true",
     "tasks.max":2,
     "key.converter": "io.confluent.connect.avro.AvroConverter",
     "key.converter.schema.registry.url": "http://schema-registry:8081",
     "value.converter": "io.confluent.connect.avro.AvroConverter",
     "value.converter.schema.registry.url": "http://schema-registry:8081",
     "confluent.license": "",
     "confluent.topic.bootstrap.servers": "broker:9092",
     "confluent.topic.replication.factor": "1",
     "oracle.server": "oracle",
     "oracle.port": 1521,
     "oracle.sid": "ORCLCDB",
     "oracle.pdb.name": "ORCLPDB1",
     "oracle.username": "C##MYUSER",
     "oracle.password": "mypassword",
     "start.from":"snapshot",
     "enable.metrics.collection": "true",
     "redo.log.topic.name": "redo-log-topic",
     "redo.log.consumer.bootstrap.servers":"broker:9092",
     "table.inclusion.regex": "ORCLPDB1[.].*[.]CUSTOMERS_MV",
     "table.topic.name.template": "\${databaseName}.\${schemaName}.\${tableName}",
     "numeric.mapping": "best_fit",
     "connection.pool.max.size": 20,
     "oracle.dictionary.mode": "auto",
     "topic.creation.groups": "redo",
     "topic.creation.redo.include": "redo-log-topic",
     "topic.creation.redo.replication.factor": 1,
     "topic.creation.redo.partitions": 1,
     "topic.creation.redo.cleanup.policy": "delete",
     "topic.creation.redo.retention.ms": 1209600000,
     "topic.creation.default.replication.factor": 1,
     "topic.creation.default.partitions": 1,
     "topic.creation.default.cleanup.policy": "delete",
     "use.transaction.begin.for.mining.session": "true"
}
EOF

log "Waiting 20s for connector to read existing data"
sleep 20

log "Insert new records"
docker exec -i oracle sqlplus C\#\#MYUSER/mypassword@//localhost:1521/ORCLPDB1 << EOF
     insert into CUSTOMERS (first_name, last_name, email, gender, club_status, comments) values ('Frantz', 'Kafka', 'fkafka@confluent.io', 'Male', 'bronze', 'Evil is whatever distracts');
     insert into CUSTOMERS (first_name, last_name, email, gender, club_status, comments) values ('Gregor', 'Samsa', 'gsamsa@confluent.io', 'Male', 'platinium', 'How about if I sleep a little bit longer and forget all this nonsense');
     insert into CUSTOMERS (first_name, last_name, email, gender, club_status, comments) values ('Josef', 'K', 'jk@confluent.io', 'Male', 'bronze', 'How is it even possible for someone to be guilty');
     update CUSTOMERS set club_status = 'silver' where email = 'gsamsa@confluent.io';
EOF

log "Refresh the MVIEW"
docker exec -i oracle sqlplus C\#\#MYUSER/mypassword@//localhost:1521/ORCLPDB1 << EOF
exec dbms_mview.refresh( 'customers_mv', 'C' );
EOF

log "Waiting 20s for connector to read new data"
sleep 20

log "Verifying topic ORCLPDB1.C__MYUSER.CUSTOMERS_MV: there should be 18 records"
playground topic consume --topic ORCLPDB1.C__MYUSER.CUSTOMERS_MV --min-expected-messages 18 --timeout 60

log "Verifying topic redo-log-topic: there should be 14 records"
playground topic consume --topic redo-log-topic --min-expected-messages 14 --timeout 60

log "🚚 If you're planning to inject more data, have a look at https://github.com/vdesabou/kafka-docker-playground/blob/master/connect/connect-cdc-oracle21-source/README.md#note-on-redologrowfetchsize"

