```
mysql -hproxysql -P6032 -uradmin -pradmin --prompt "ProxySQL Admin> "
```

```
update global_variables set variable_value='false' where variable_name='admin-hash_passwords';
```

```
load admin variables to runtime; save admin variables to disk;
```

```
load mysql users to runtime; save mysql users to disk;
```

```
update global_variables set variable_value="8.0.4 (ProxySQL)" where variable_name='mysql-server_version';
load mysql variables to run;
save mysql variables to disk;
```

```
mysql -uroot -pMHMN3gZn5zYsWHO
```