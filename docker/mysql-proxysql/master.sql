/* proxysql user */
CREATE USER IF NOT EXISTS 'monitor' @'%' IDENTIFIED BY 'monitor';

GRANT PROCESS,REPLICATION CLIENT,SELECT ON *.* TO 'monitor' @'%';

/* slave user */
CREATE USER IF NOT EXISTS 'slave_user' @'%' IDENTIFIED BY 'slave';

GRANT REPLICATION SLAVE ON *.* TO 'slave_user' @'%' WITH GRANT OPTION;

FLUSH PRIVILEGES;