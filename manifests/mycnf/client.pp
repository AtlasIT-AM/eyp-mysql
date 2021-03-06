define mysql::mycnf::client(
                              $instance_name = $name,
                              $client_name   = $name,
                              $default       = false,
                              $password      = undef,
                              $socket        = undef,
                            ) {
  if($instance_name=='global')
  {
    $mycnf_path='/etc/mysql/my.cnf'
  }
  else
  {
    $mycnf_path="/etc/mysql/${instance_name}/my.cnf"
  }

  if($default)
  {
    concat::fragment{ "${mycnf_path} mysql default instance":
      target  => $mycnf_path,
      order   => '001',
      content => template("${module_name}/mycnf/mysql/01_default_client.erb"),
    }
  }
  else
  {
    concat::fragment{ "${mycnf_path} mysql client ${instance_name}":
      target  => $mycnf_path,
      order   => '002',
      content => template("${module_name}/mycnf/mysql/02_client.erb"),
    }
  }

}
