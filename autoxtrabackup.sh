#!/bin/bash
# MySQL backup script
# https://github.com/gregorystorme/autoxtrabackup
# Copyright (c) 2014 Gregory Storme
# Version: 0.2


backupDir=/ftp/backup/xtra
hoursBeforeFull=240
mysqlUser=root
mysqlPwd=root
compression=true
compressThreads=4
keepDays=11
keepFullDays=22
sendEmail=never
emailAddress=


#帮助函数
usage () {
        echo -e "\t 恢复完整备份";
        echo -e "\t\t 恢复压缩过的备份:";
        echo -e "\t\t\t innobackupex --decompress $backupDir/BACKUP-DIR";
        echo -e "\t\t\t 继续执行非压缩备份步骤";
        echo -e "\t\t 恢复未经压缩过的备份:";
        echo -e "\t\t\t innobackupex --apply-log $backupDir/BACKUP-DIR";
        echo -e "\t\t\t 停止MySQL服务";
        echo -e "\t\t\t 删除所有MySQL数据目录文件";
        echo -e "\t\t\t innobackupex --copy-back $backupDir/BACKUP-DIR";
        echo -e "\t\t\t 设置 MySQL 数据目录权限 (chown -R mysql:mysql /var/lib/mysql/)";
        echo -e "\t\t\t 启动MySQL server";
        echo -e "\t恢复增量备份";
        echo -e "\t\t\t 如果是压缩过的备份，需要先解压备份";
        echo -e "\t\t\t 然后准备备份文件";
        echo -e "\t\t\t innobackupex --apply-log --redo-only $backupDir/FULL-BACKUP-DIR";
        echo -e "\t\t\t 从基础包上导入增量包.";
        echo -e "\t\t\t 如果你有多个增量备份包，请依次准备增量包";
        echo -e "\t\t\t innobackupex --apply-log --redo-only $backupDir/FULL-BACKUP-DIR --incremental-dir=$backupDir/INC-BACKUP-DIR";
        echo -e "\t\t\t 将基础与所有增量合并后，准备回滚未提交的事务:";
        echo -e "\t\t\t innobackupex --apply-log $backupDir/BACKUP-DIR";
}

while getopts ":h" opt; do
  case $opt in
        h)
                usage;
                exit 0
                ;;
        \?)
                echo "Invalid option: -$OPTARG" >&2
                exit 1
                ;;
  esac
done

dateNow=`date +%Y-%m-%d_%H-%M-%S`
dateNowUnix=`date +%s`
backupLog=/ftp/backup/xtra/"$dateNow".log
delDay=`date -d "-$keepDays days" +%Y-%m-%d`

# Check if innobackupex is installed (percona-xtrabackup)
if [[ -z "$(command -v innobackupex)" ]]; then
        echo "备份程序未找到，请检查"
        exit 1
fi

# Check if backup directory exists
if [ ! -d "$backupDir" ]; then
        echo "备份目录不存在"
        exit 1
fi

# Check if mail is installed
if [[ $sendEmail == always ]] || [[ $sendEmail == onerror ]]; then
        if [[ -z "$(command -v mail)" ]]; then
                echo "You have enabled mail, but mail is not installed or not in PATH environment variable"
                exit 1
        fi
fi

# Check if you set a correct retention
if [ $(($keepDays * 24)) -le $hoursBeforeFull ]; then
        echo "ERROR: You have set hoursBeforeFull to $hoursBeforeFull and keepDays to $keepDays, this will delete all your backups... Change this"
        exit 1
fi

# If you enabled sendEmail, check if you also set a recipient
if [[ -z $emailAddress ]] && [[ $sendEmail == onerror ]]; then
        echo "Error, you have enabled sendEmail but you have not configured any recipient"
        exit 1
elif [[ -z $emailAddress ]] && [[ $sendEmail == always ]]; then
        echo "Error, you have enabled sendEmail but you have not configured any recipient"
        exit 1
fi

# If compression is enabled, pass it on to the backup command
if [[ $compression == true ]]; then
        compress="--compress"
        compressThreads="--compress-threads=$compressThreads"
else
        compress=
        compressThreads=
fi

if [ -f "$backupDir"/latest_full ]; then
        lastFull=`cat "$backupDir"/latest_full`
fi

# Check for an existing full backup
if [ ! -f "$backupDir"/latest_full ]; then
        #echo "Latest full backup information not found... taking a first full backup now"
        echo $dateNowUnix > "$backupDir"/latest_full
        lastFull=`cat "$backupDir"/latest_full`
        /usr/bin/innobackupex --user=$mysqlUser --password=$mysqlPwd --no-timestamp $compress $compressThreads --rsync "$backupDir"/"$dateNow"_full > $backupLog 2>&1
else
        # Calculate the time since the last full backup
        difference=$((($dateNowUnix - $lastFull) / 60 / 60))

        # Check if we must take a full or incremental backup
        if [ $difference -lt $hoursBeforeFull ]; then
                echo "自上次备份以来已经过去了 $difference 小时, 开始增量备份"
                lastFullDir=`date -d@"$lastFull" '+%Y-%m-%d_%H-%M-%S'`
                /usr/bin/innobackupex --user=$mysqlUser --password=$mysqlPwd --no-timestamp $compress $compressThreads --rsync --incremental --incremental-basedir="$backupDir"/"$lastFullDir"_full "$backupDir"/"$dateNow"_incr > $backupLog 2>&1
                #删除超过时间的增量备份和日志
                rm -rf $backupDir/$delDay*
        else
                echo "自上次完整备份以来已经过去了 $difference 小时，是时候进行新的完整备份了"
                echo $dateNowUnix > "$backupDir"/latest_full
                /usr/bin/innobackupex --user=$mysqlUser --password=$mysqlPwd --no-timestamp $compress $compressThreads --rsync "$backupDir"/"$dateNow"_full > $backupLog 2>&1

                #删除超过时间的备份和日志
                find $backupDir -type f -ctime "+$keepFullDays" -ok rm {} \;
        fi
fi

# Check if the backup succeeded or failed, and e-mail the logfile, if enabled
if grep -q "completed OK" $backupLog; then
        echo "备份完成"
        if [[ $sendEmail == always ]]; then
                cat $backupLog | mail -s "AutoXtraBackup log" $emailAddress
        fi
else
        echo "备份失败"
        if [[ $sendEmail == always ]] || [[ $sendEmail == onerror ]]; then
                cat $backupLog | mail -s "AutoXtraBackup log" $emailAddress
        fi
        exit 1
fi

