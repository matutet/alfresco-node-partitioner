#!/bin/bash
# Alfresco PostgreSQL partitioner.

set -o errexit
set -o pipefail
set -o nounset
# set -o xtrace

# PSQL COMMAND
psql="sudo -u postgres psql"
pg_dump="sudo -u postgres pg_dump"

# THE DEFAULTS INITIALIZATION
_arg_database_name=
_arg_nodes_per_partition=
_arg_dump_directory=
_arg_restore_file=

# CONSTANTS
PARTITIONS=
MAX_BLOCK_INSERT=1000000

### FUNCTIONS
function existsDatabase {
    if $psql -lqt | cut -d \| -f 1 | grep -qw $_arg_database_name; then
        echo "Database $_arg_database_name exists in local PostgreSQL"
    else
        echo "ERROR: database $_arg_database_name does NOT exist in local PostgreSQL!"
        exit
    fi
}

function initNumberOfNodes {
    COUNT_NODES=$(numberOfNodes)
    PARTITIONS=$((($COUNT_NODES / $_arg_nodes_per_partition) + 1))
}

function numberOfNodes {
    NONODES=`$psql -d $_arg_database_name -t -c "select max(node_id) from alf_node_properties"`
    echo "$NONODES";
}

function dumpDB {
    echo "Dumping DB..."
    mkdir -p $_arg_dump_directory
    $pg_dump $_arg_database_name > $_arg_dump_directory/$_arg_database_name.dump
    echo "Dumping DB done!"
}

function restoreDB {
    echo "Restoring DB..."
    $psql -t -c "drop database $_arg_database_name;"
    $psql -t -c "create database $_arg_database_name with encoding 'utf8';"
    $psql $_arg_database_name < $_arg_restore_file
    echo "Restoring DB done!"    
}

function createMasterTable {

    echo "Creating Master Table ..."

    $psql -d $_arg_database_name -t -c "CREATE TABLE alf_node_properties_intermediate (LIKE alf_node_properties INCLUDING ALL);"
    $psql -d $_arg_database_name -t -c "CREATE FUNCTION alf_node_properties_insert_trigger()
                                 RETURNS trigger AS \$\$ 
                                    BEGIN 
                                RAISE EXCEPTION 'Create partitions first.'; 
                                 END;
                                 \$\$ LANGUAGE plpgsql;"
    $psql -d $_arg_database_name -t -c "CREATE TRIGGER alf_node_properties_insert_trigger 
                                 BEFORE INSERT ON alf_node_properties_intermediate 
                                 FOR EACH ROW EXECUTE PROCEDURE alf_node_properties_insert_trigger();"

    echo "... table alf_node_properties_intermediate created!"
    echo "Creating Master Table done!"

}

# Internal use
# $1 = Part name
# $2 = Min level for the partition
# $3 = Max level for the partition
# $4 = Inherits table
function createPartition {

  PART_NAME=$1
  MIN_LEVEL=$2
  MAX_LEVEL=$3
  INHERITS_TABLE=$4

  $psql -d $_arg_database_name -t -c "CREATE TABLE alf_node_properties_$PART_NAME
                                                (CHECK (node_id > $MIN_LEVEL AND node_id <= $MAX_LEVEL))
                                                INHERITS ($INHERITS_TABLE);"
  $psql -d $_arg_database_name -t -c "ALTER TABLE alf_node_properties_$PART_NAME ADD PRIMARY KEY (node_id, qname_id, list_index, locale_id);"
  $psql -d $_arg_database_name -t -c "CREATE INDEX fk_alf_nprop_n_$PART_NAME ON alf_node_properties_$PART_NAME (node_id);"
  $psql -d $_arg_database_name -t -c "CREATE INDEX fk_alf_nprop_qn_$PART_NAME ON alf_node_properties_$PART_NAME (qname_id);"
  $psql -d $_arg_database_name -t -c "CREATE INDEX fk_alf_nprop_loc_$PART_NAME ON alf_node_properties_$PART_NAME (locale_id);"
  $psql -d $_arg_database_name -t -c "CREATE INDEX idx_alf_nprop_s_$PART_NAME ON alf_node_properties_$PART_NAME (qname_id, string_value, node_id);"
  $psql -d $_arg_database_name -t -c "CREATE INDEX idx_alf_nprop_l_$PART_NAME ON alf_node_properties_$PART_NAME (qname_id, long_value, node_id);"
  $psql -d $_arg_database_name -t -c "CREATE INDEX idx_alf_nprop_b_$PART_NAME ON alf_node_properties_$PART_NAME (qname_id, boolean_value, node_id);"
  $psql -d $_arg_database_name -t -c "CREATE INDEX idx_alf_nprop_f_$PART_NAME ON alf_node_properties_$PART_NAME (qname_id, float_value, node_id);"
  $psql -d $_arg_database_name -t -c "CREATE INDEX idx_alf_nprop_d_$PART_NAME ON alf_node_properties_$PART_NAME (qname_id, double_value, node_id);"

  $psql -d $_arg_database_name -t -c "GRANT ALL PRIVILEGES ON TABLE alf_node_properties_$PART_NAME TO alfresco" 

  echo "Partition alf_node_properties_$PART_NAME created"

}

function createPartitions {

    initNumberOfNodes

    echo "Creating $PARTITIONS partitions..."

    for i in `seq 1 $PARTITIONS`;
    do

      PART_NAME=$i
      MIN_LEVEL=$((($i - 1) * $_arg_nodes_per_partition))
      MAX_LEVEL=$(($MIN_LEVEL + $_arg_nodes_per_partition))

      createPartition $PART_NAME $MIN_LEVEL $MAX_LEVEL "alf_node_properties_intermediate"

    done
    
    echo "$PARTITIONS have been created!"
    echo "Creating partitions done!"
}

function addPartition {

    initNumberOfNodes

    echo "Adding new partition ..."

    MIN_LEVEL=$((($PARTITIONS - 1) * $_arg_nodes_per_partition))
    MAX_LEVEL=$(($MIN_LEVEL + $_arg_nodes_per_partition))
    PCT_FILLED=$(($COUNT_NODES * 100 / $MAX_LEVEL))

    # Check if every intermediate partition has been created
    for i in `seq 1 $PARTITIONS`;
    do

      PART_NAME=$i
      MIN_LEVEL=$((($i - 1) * $_arg_nodes_per_partition))
      MAX_LEVEL=$(($MIN_LEVEL + $_arg_nodes_per_partition))

      # Check if partition exists
      OUTPUT=$($psql -d $_arg_database_name -t -c "SELECT EXISTS (
                   SELECT 1
                   FROM   information_schema.tables 
                   WHERE  table_name = 'alf_node_properties_$PART_NAME'
                   );")
        
      if [[ "$OUTPUT" == " f" ]]; then
          createPartition $PART_NAME $MIN_LEVEL $MAX_LEVEL "alf_node_properties"
          echo "Partition alf_node_properties_$PART_NAME created"
          triggerInsertRows
          echo "Adding gap partition done!"
      fi

    done

    # 50 % storage from last partition is full
    if [[ $PCT_FILLED > 50 ]]; then

        PARTITIONS=$(($PARTITIONS + 1))
        MIN_LEVEL=$((($PARTITIONS - 1) * $_arg_nodes_per_partition))
        MAX_LEVEL=$(($MIN_LEVEL + $_arg_nodes_per_partition))
        PART_NAME=$PARTITIONS

        # Check if partition exists
        OUTPUT=$($psql -d $_arg_database_name -t -c "SELECT EXISTS (
                   SELECT 1
                   FROM   information_schema.tables 
                   WHERE  table_name = 'alf_node_properties_$PART_NAME'
                   );")

        if [[ "$OUTPUT" == " f" ]]; then

            createPartition $PART_NAME $MIN_LEVEL $MAX_LEVEL "alf_node_properties"
            triggerInsertRows
            echo "Adding new partition done!"

        else

            echo "No new partition is required, partition has not been created!"

        fi
    
    else
        echo "No new partition is required, partition has not been created!"
    fi
     
}

function triggerInsertRows {

    # Can be used from addPartition with pre-calculated number of partitions
    if [[ -z "$PARTITIONS" ]]; then
        initNumberOfNodes
    fi

    echo "Creating Trigger..."

    body=
    for i in `seq 1 $PARTITIONS`;
    do
     PART_NAME=$i
     MIN_LEVEL=$((($i - 1) * $_arg_nodes_per_partition))
     MAX_LEVEL=$(($MIN_LEVEL + $_arg_nodes_per_partition))
     if [ "$i" = "$PARTITIONS" ]
     then
         body="IF (NEW.node_id > $MIN_LEVEL AND NEW.node_id <= $MAX_LEVEL) THEN INSERT INTO alf_node_properties_$PART_NAME VALUES (NEW.*); $body"
     else
        body="ELSIF (NEW.node_id > $MIN_LEVEL AND NEW.node_id <= $MAX_LEVEL) THEN INSERT INTO alf_node_properties_$PART_NAME VALUES (NEW.*); $body "
     fi
    done

    $psql -d $_arg_database_name -t -c "CREATE OR REPLACE FUNCTION alf_node_properties_insert_trigger()
            RETURNS trigger AS
              \$\$
              BEGIN 
              $body
              ELSE
                  RAISE EXCEPTION 'Ensure partitions are created';
              END IF;
              RETURN NULL;
              END;
              \$\$ LANGUAGE plpgsql;"

    echo "Trigger alf_node_properties_insert_trigger has been created!"
    echo "Creating Trigger done!"

}

function insertInto {

   $psql -d $_arg_database_name -t -c "INSERT INTO alf_node_properties_intermediate (
                        node_id,
                        actual_type_n,
                        persisted_type_n,
                        boolean_value,
                        long_value,
                        float_value,
                        double_value,
                        string_value,
                        serializable_value,
                        qname_id,
                        list_index,
                        locale_id
                )
                    SELECT node_id,
                    actual_type_n,
                    persisted_type_n,
                    boolean_value,
                    long_value,
                    float_value,
                    double_value,
                    string_value,
                    serializable_value,
                    qname_id,
                    list_index,
                    locale_id 
                    FROM alf_node_properties
                    WHERE node_id > $1 AND node_id <= $2;"

}

function fill {

    initNumberOfNodes

    echo "Copying rows..."

    for i in `seq 1 $PARTITIONS`;
    do

     MIN_LEVEL=$((($i - 1) * $_arg_nodes_per_partition))
     MAX_LEVEL=$(($MIN_LEVEL + $_arg_nodes_per_partition))

     # Split INSERT INTO to ensure performance 
     if [[ $_arg_nodes_per_partition -gt $MAX_BLOCK_INSERT ]]; then

       CURRENT_MIN_LEVEL=$(($MIN_LEVEL))
       CURRENT_MAX_LEVEL=$(($MIN_LEVEL + $MAX_BLOCK_INSERT))
       while [[ $CURRENT_MAX_LEVEL -le $MAX_LEVEL && $CURRENT_MIN_LEVEL -le $COUNT_NODES ]]; do
           insertInto $CURRENT_MIN_LEVEL $CURRENT_MAX_LEVEL
           echo "Rows $CURRENT_MIN_LEVEL to $CURRENT_MAX_LEVEL for partition $i have been copied"
           CURRENT_MAX_LEVEL=$(($CURRENT_MAX_LEVEL + $MAX_BLOCK_INSERT))
           CURRENT_MIN_LEVEL=$(($CURRENT_MIN_LEVEL + $MAX_BLOCK_INSERT))
       done

     else

       insertInto $MIN_LEVEL $MAX_LEVEL

    fi
    
    echo "Rows for partition $i have been copied"

    done

     echo "Copying rows done!"
}

function analyze {

    initNumberOfNodes

    echo "Analyzing new tables..."

    for i in `seq 1 $PARTITIONS`;
    do
     PART_NAME=$i
     $psql -d $_arg_database_name -t -c "ANALYZE VERBOSE alf_node_properties_$PART_NAME" 
    done
    $psql -d $_arg_database_name -t -c "ANALYZE VERBOSE alf_node_properties_intermediate" 

    echo "Analyzing tables done!"
}

function swap {

    initNumberOfNodes

    echo "Swapping tables..."

    $psql -d $_arg_database_name -t -c "ALTER TABLE alf_node_properties RENAME TO alf_node_properties_retired"
    $psql -d $_arg_database_name -t -c "ALTER TABLE alf_node_properties_intermediate RENAME TO alf_node_properties"
    $psql -d $_arg_database_name -t -c "DROP TABLE alf_node_properties_retired"
    $psql -d $_arg_database_name -t -c "GRANT ALL PRIVILEGES ON TABLE alf_node_properties TO alfresco"
    for i in `seq 1 $PARTITIONS`;
    do
     PART_NAME=$i
     $psql -d $_arg_database_name -t -c "GRANT ALL PRIVILEGES ON TABLE alf_node_properties_$PART_NAME TO alfresco" 
    done

    echo "Swapping tables done!"

}

function vacuum {

    initNumberOfNodes    

    echo "Performing VACUUM FULL..."

    for i in `seq 1 $PARTITIONS`;
    do
     PART_NAME=$i
     $psql -d $_arg_database_name -t -c "VACUUM VERBOSE alf_node_properties_$PART_NAME" 
    done
    $psql -d $_arg_database_name -t -c "VACUUM VERBOSE alf_node_properties_intermediate" 

    echo "VACUUM FULL done!"
}

function unswap {

    echo "Undo swapping..."

# To be done

    echo "... currently not implemented!"

}

function printHelp {
    printf 'Usage: %s <command> -db <database> -np <nodes-per-partition> -d <folder-path> -f <dump-file> \n' "$0"
    printf "\t%s\n" "<command>: create-master | create-partitions | create-trigger | fill | analyze | vacuum | swap"
    printf "\t%s\n" "           unswap | count-nodes | dump | restore"
    printf "\t%s\n" "-db: Alfresco database name"
    printf "\t%s\n" "-np: Number of nodes to be stored on each partition"
    printf "\t%s\n" "-d: Folder to store a dump"           
    printf "\t%s\n" "-f: File to restore a dump from"           
}

# db np d f
function checkParams {

    for i in $1; do
        if [ "$i" = "db" ]; then
            if [[ -z "$_arg_database_name" ]]; then
                echo "ERROR: Database name is required!"
                printHelp
                exit 0
            fi
            existsDatabase
        fi
        if [ "$i" = "np" ]; then            
            if [[ -z "$_arg_nodes_per_partition" ]]; then
                echo "ERROR: Nodes per partition is required!"
                printHelp
                exit 0
            fi
        fi
        if [ "$i" = "d" ]; then
            if [[ -z "$_arg_dump_directory" ]]; then
                echo "ERROR: Directory to store the dump is required!"
                printHelp
                exit 0
            fi
        fi
        if [ "$i" = "f" ]; then
            if [[ -z "$_arg_restore_file" ]]; then
                echo "ERROR: File containing database dump is required!"
                printHelp
                exit 0
            fi
        fi
    done

}

if [ $# -eq 0 ]; then
    printHelp
    exit 0
fi

## EXECUTION 
call_func=
required_params=
while test $# -gt 0
do
    case "$1" in
        create-master)
            call_func="createMasterTable"
            required_params="db"
        ;;
        create-partitions)
            call_func="createPartitions"
            required_params="db np"
        ;;
        create-trigger) 
            call_func="triggerInsertRows"
            required_params="db np"
        ;;
        fill)
            call_func="fill"
            required_params="db np"
        ;;
        analyze)
            call_func="analyze"
            required_params="db np"
        ;;
        vacuum)
            call_func="vacuum"
            required_params="db np"
        ;;
        swap)
            call_func="swap"
            required_params="db np"
        ;;
        unswap)
            call_func="unswap"
        ;;
        add-partition)
            call_func="addPartition"
            required_params="db np"
        ;;
        count-nodes)
            call_func="numberOfNodes"
            required_params="db"
        ;;
        dump)
            call_func="dumpDB"
            required_params="db d"
        ;;
        restore)
            call_func="restoreDB"
            required_params="db f"
        ;;
        -db)
            _arg_database_name="$2"
        ;;
        -np)
            _arg_nodes_per_partition="$2"
        ;;
        -d)
            _arg_dump_directory="$2"
        ;;
        -f)
            _arg_restore_file="$2"
        ;;
        -h) printHelp
    esac
    shift
done

checkParams "$required_params"
$call_func
