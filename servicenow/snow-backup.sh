#!/bin/bash

# USAGE INFO
usage() {
  cat <<EOUSAGE

  USAGE: $0
      [--src_dir=src_dir]   -> /data/glide/nodes
      [--des_dir=des_dir]   -> /mnt/backup
      [--log_dir=log_dir]   -> /data/glide/logs
      [--help]

EOUSAGE
}

if [ $# -eq 0 ]; then
  usage
  exit 1
fi

# PARSE PARAMETERS
while [ $# -gt 0 ]; do
  case "$1" in
    --src_dir=*)
      src_dir="${1#*=}"
      ;;
    --des_dir=*)
      des_dir="${1#*=}"
      ;;
    --log_dir=*)
      log_dir="${1#*=}"
      ;;      
    --help=*)
      usage
      exit
      ;;
    *)
      usage
      exit 1
  esac
  shift
done

# VARIABLES
export LOG_DIR=${log_dir}
export LOG_FILE=${LOG_DIR}/sncBackup.log
export TS=`date '+%Y%m%d-%R'`
export SRC_DIR=${src_dir}
export DES_DIR=${des_dir}/$TS
export INSTANCE_LIST=/tmp/instance.list
export RESULT_LIST=/tmp/instance.result

# PREPARING
test ! -d ${SRC_DIR} && exit 0
test -f ${INSTANCE_LIST} && rm -f ${INSTANCE_LIST}
test -f ${RESULT_LIST} && rm -f ${RESULT_LIST}


export NOW=`date '+%Y-%m-%d %H:%M:%S'`
echo -n "Start:$NOW" >> $LOG_FILE

# LIST INSTANCES
ls $SRC_DIR | grep -v [.] > $INSTANCE_LIST

cat $INSTANCE_LIST | while read instance_name
do
  test ! -d ${DES_DIR}/$instance_name/conf && mkdir -p ${DES_DIR}/$instance_name/conf
  rsync -rvuh --delete ${SRC_DIR}/$instance_name/conf/ ${DES_DIR}/$instance_name/conf/
  echo $? >> $RESULT_LIST
done

# CHECK RESULTS
RESULTS=`grep 0 $RESULT_LIST | wc -l`
export NOW=`date '+%Y-%m-%d %H:%M:%S'`
echo -n ", End:$NOW" >> $LOG_FILE

if [ $RESULTS == "4" ]; then
  echo ", Exit:0. DONE" >> $LOG_FILE
else
  echo ", Exit:1. ERROR" >> $LOG_FILE
fi

exit 0
