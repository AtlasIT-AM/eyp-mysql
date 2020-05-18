#!/bin/bash

# puppet managed file

function initbck
{
  LOGDIR=${LOGDIR-$DESTINATION}

  if [ -z "${LOGDIR}" ];
  then
    echo "no destination defined"
    BCKFAILED=1
  else
    mkdir -p $LOGDIR
    BACKUPTS=$(date +%Y%m%d%H%M)

    CURRENTBACKUPLOG="$LOGDIR/$BACKUPTS.log"

    BCKFAILED=0

    if [ -z "$LOGDIR" ];
    then
      exec 2>&1
    else
      exec >> $CURRENTBACKUPLOG 2>&1
    fi
  fi
}

function mailer
{
  MAILCMD=$(which mail 2>/dev/null)
  if [ -z "$MAILCMD" ];
  then
    echo "mail not found, skipping"
  else
    if [ -z "$MAILTO" ];
    then
      echo "mail skipped, no MAILTO defined"
      exit $BCKFAILED
    else
      if [ -z "$LOGDIR" ];
      then
        if [ "$BCKFAILED" -eq 0 ];
        then
          echo "OK" | $MAILCMD -s "$IDHOST-${BACKUP_NAME_ID}-OK" $MAILTO
        else
          echo "ERROR - no log file configured" | $MAILCMD -s "$IDHOST-MySQL-ERROR" $MAILTO
        fi
      else
        if [ "$BCKFAILED" -eq 0 ];
        then
          $MAILCMD -s "$IDHOST-${BACKUP_NAME_ID}-OK" $MAILTO < $CURRENTBACKUPLOG
        else
          $MAILCMD -s "$IDHOST-${BACKUP_NAME_ID}-ERROR" $MAILTO < $CURRENTBACKUPLOG
        fi
      fi
    fi
  fi
}

function dobackup
{
  DUMPDEST="$DESTINATION"

  mkdir -p $DUMPDEST

  #aqui logica fulls/diferencials:

  if [ ! -z "$FULL_ON_MONTHDAY" ] && [ ! -z "$FULL_ON_WEEKDAY" ];
  then
    echo "FULL_ON_MONTHDAY and FULL_ON_WEEKDAY cannot be both defined"
    BCKFAILED=1
  elif [ ! -z "$FULL_ON_MONTHDAY" ];
  then
    # backup full on monthday definit
    TODAY_MONTHDAY="$(date +%e | awk '{ print $NF }')"
    TODAY_IS_FULL=0

    for i in $FULL_ON_MONTHDAY;
    do
      if [[ "$i" == "$TODAY_MONTHDAY" ]];
      then
        TODAY_IS_FULL=1
      fi
    done

  elif [ ! -z "$FULL_ON_WEEKDAY" ];
  then
    # backup full on weekday definit
    TODAY_WEEKDAY="$(date +%u)"
    TODAY_IS_FULL=0

    for i in $FULL_ON_WEEKDAY;
    do
      if [[ "$i" == "$TODAY_WEEKDAY" ]];
      then
        TODAY_IS_FULL=1
      fi
    done
  else
    # comportament no definit, fem fulls sempre
    TODAY_IS_FULL=1
  fi

  if [ "$TODAY_IS_FULL" -eq 1 ];
  then
    # full
    echo "BACKUP FULL:"
    if [ -z "${XTRABACKUPBIN_24}" ];
    then
      innobackupex ${MYSQL_INSTANCE_OPTS} ${DUMPDEST}
    else
      ${XTRABACKUPBIN} ${MYSQL_INSTANCE_OPTS} --backup --target-dir="${DUMPDEST}/${CURRENT_BACKUP_DIR}"
    fi
  else
    # incremental si trobo full
    if [ -L "${DUMPDEST}/last_full" ];
    then
      LAST_FULL_DIR=$(readlink "${DUMPDEST}/last_full")
      echo "INCREMENTAL MODE / BACKUP INCREMENTAL:"
      if [ -z "${XTRABACKUPBIN_24}" ];
      then
        innobackupex ${MYSQL_INSTANCE_OPTS} --incremental "${DUMPDEST}" --incremental-basedir="${LAST_FULL_DIR}"
      else
        ${XTRABACKUPBIN} ${MYSQL_INSTANCE_OPTS} --incremental --target-dir="${DUMPDEST}/${CURRENT_BACKUP_DIR}" --incremental-basedir="${LAST_FULL_DIR}"
      fi
    else
      echo "INCREMENTAL MODE / BACKUP FULL:"
      if [ -z "${XTRABACKUPBIN_24}" ];
      then
        innobackupex ${MYSQL_INSTANCE_OPTS} ${DUMPDEST}
      else
        ${XTRABACKUPBIN} ${MYSQL_INSTANCE_OPTS} --backup --target-dir="${DUMPDEST}/${CURRENT_BACKUP_DIR}"
      fi
    fi
  fi

  if [ "$?" -ne 0 ];
  then
    echo "innobackupex error, check logs - error code: $?"
    BCKFAILED=1
  else
    grep "completed OK!" ${CURRENTBACKUPLOG} > /dev/null 2>&1

    if [ "$?" -ne 0 ];
    then
      echo "innobackupex error - completed OK not found - unexpected log output, please check logs"
      BCKFAILED=1
    else
      # asumim OK
      for file in $(find ${DUMPDEST} -maxdepth 2 -iname xtrabackup_info | grep -v last_full | sort -r);
      do
        grep "incremental = N" $file >/dev/null 2>&1
        if [ "$?" -eq 0 ];
        then
          if [ -e "${DUMPDEST}/last_full" ];
          then
            unlink "${DUMPDEST}/last_full"
          fi
          ln -s $(dirname $file) ${DUMPDEST}/last_full
          break
        fi
      done
    fi
  fi


}

function cleanup
{
  if [ -z "$RETENTION" ];
  then
    echo "cleanup skipped, no RETENTION defined"
  else
    find $LOGDIR -maxdepth 1 -mtime +$RETENTION -exec rm -fr {} \;
  fi
}

PATH="/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin"

BASEDIRBCK=$(dirname $0)
BASENAMEBCK=$(basename $0)
IDHOST=${IDHOST-$(hostname -s)}
BACKUP_NAME_ID=${BACKUP_NAME_ID-MySQL}

if [ ! -z "$1" ] && [ -f "$1" ];
then
  . $1 2>/dev/null
else
  if [[ -s "$BASEDIRBCK/${BASENAMEBCK%%.*}.config" ]];
  then
    . $BASEDIRBCK/${BASENAMEBCK%%.*}.config 2>/dev/null
  else
    echo "config file missing"
    BCKFAILED=1
  fi
fi

INSTANCE_NAME=${INSTANCE_NAME-$1}

XTRABACKUPBIN=${XTRABACKUPBIN-$(which xtrabackup 2>/dev/null)}
if [ -z "$XTRABACKUPBIN" ];
then
  XTRABACKUPBIN=${XTRABACKUPBIN-$(which innobackupex 2>/dev/null)}
  if [ -z "$XTRABACKUPBIN" ];
  then
    echo "ERROR: Neither xtrabackup nor innobackupex have been found, exiting"
    BCKFAILED=1
  fi
fi

MIN_VER=$(echo "2.4\n$($XTRABACKUPBIN --version 2>&1 | tail -n1 | awk '{ print $3 }')" | sort -V | head -n1)

if [[ ${MIN_VER} == 2.4* ]];
then
  XTRABACKUPBIN_24="1"
fi

#
#
#

if [ ! -z "${INSTANCE_NAME}" ];
then
  MYSQL_INSTANCE_OPTS="--defaults-file=/etc/mysql/${INSTANCE_NAME}/my.cnf"
fi

CURRENT_BACKUP_DIR=$(date +%Y-%m-%d_%H-%M-%S)

initbck

if [ "$BCKFAILED" -ne 1 ];
then
  date
  dobackup
  date
fi

cleanup
mailer
