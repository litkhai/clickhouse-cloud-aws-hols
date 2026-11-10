-- Source schema, sample rows and the ClickPipes user. 02-source.sh replaces __CP_PW__.
CREATE DATABASE IF NOT EXISTS shop;
CREATE TABLE IF NOT EXISTS shop.orders (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  customer_id INT NOT NULL,
  amount DECIMAL(10,2) NOT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
USE shop;
INSERT INTO shop.orders (customer_id, amount)
SELECT seq % 100, (seq % 1000) / 10 FROM seq_1_to_1000;   -- MariaDB Sequence engine

CREATE USER IF NOT EXISTS 'clickpipes_user'@'%' IDENTIFIED BY '__CP_PW__';
GRANT SELECT ON shop.* TO 'clickpipes_user'@'%';                     -- each replicated database
GRANT REPLICATION CLIENT ON *.* TO 'clickpipes_user'@'%';            -- shown as BINLOG MONITOR on MariaDB 10.5+
GRANT REPLICATION SLAVE ON *.* TO 'clickpipes_user'@'%';
GRANT SLAVE MONITOR ON *.* TO 'clickpipes_user'@'%';                 -- the create call checks replica status
GRANT SELECT ON mysql.rds_configuration TO 'clickpipes_user'@'%';    -- the create call reads binlog retention here

CALL mysql.rds_set_configuration('binlog retention hours', 72);

SELECT @@version, @@binlog_format, @@binlog_row_image, @@binlog_row_metadata, @@log_bin;
CALL mysql.rds_show_configuration;
SHOW GRANTS FOR 'clickpipes_user'@'%';
