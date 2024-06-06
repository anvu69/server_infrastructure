/* proxysql user */
CREATE USER IF NOT EXISTS 'monitor' @'%' IDENTIFIED BY 'monitor';

FLUSH PRIVILEGES;

/* start replication */
CHANGE MASTER TO MASTER_HOST = 'mysql-master1',MASTER_USER = 'slave_user',MASTER_PASSWORD = 'slave',MASTER_AUTO_POSITION = 1;

STOP SLAVE;
RESET SLAVE;
START SLAVE;