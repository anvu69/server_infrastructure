/* proxysql user */
CREATE USER IF NOT EXISTS 'monitor' @'%' IDENTIFIED BY 'monitor';

/* mysql exporter user */
CREATE USER IF NOT EXISTS 'exporter' @'%' IDENTIFIED BY 'password' WITH MAX_USER_CONNECTIONS 3;

GRANT PROCESS,
REPLICATION CLIENT,
SELECT
  ON *.* TO 'exporter' @'%';

/* slave user */
CREATE USER IF NOT EXISTS 'slave_user' @'%' IDENTIFIED BY 'slave';

GRANT REPLICATION SLAVE ON *.* TO 'slave_user' @'%' WITH GRANT OPTION;

FLUSH PRIVILEGES;