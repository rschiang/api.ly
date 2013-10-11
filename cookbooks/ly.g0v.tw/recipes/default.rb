include_recipe "runit"
include_recipe "database"
include_recipe "cron"
include_recipe "postgresql::ruby"
#include_recipe "ly.g0v.tw::libreoffice"

git "/opt/nginx-rtmp-module" do
  repository "git://github.com/arut/nginx-rtmp-module"
  reference "v1.0.4"
  action :sync
end

include_recipe "nginx::source"

directory "/opt/ly" do
  action :create
end

execute "install LiveScript" do
  command "npm i -g LiveScript@1.1.1"
  not_if "test -e /usr/bin/lsc"
end

execute "install bower" do
  command "npm i -g bower@1.2.6"
  not_if "test -e /usr/bin/bower"
end

git "/opt/ly/twlyparser" do
  repository "git://github.com/g0v/twlyparser.git"
  enable_submodules true
  reference "master"
  action :sync
end

execute "install twlyparser" do
  cwd "/opt/ly/twlyparser"
  action :nothing
  subscribes :run, resources(:git => "/opt/ly/twlyparser"), :immediately
  command "npm i && npm link"
end


postgresql_connection_info = {:host => "127.0.0.1",
                              :port => node['postgresql']['config']['port'],
                              :username => 'postgres',
                              :password => node['postgresql']['password']['postgres']}

database 'ly' do
  connection postgresql_connection_info
  provider Chef::Provider::Database::Postgresql
  action :create
end

db_user = postgresql_database_user 'ly' do
  connection postgresql_connection_info
  database_name 'ly'
  password 'password'
  privileges [:all]
  action :create
end

postgresql_database "grant schema" do
  connection postgresql_connection_info
  database_name 'ly'
  sql "grant CREATE on database ly to ly"
  action :nothing
  subscribes :query, resources(:postgresql_database_user => 'ly'), :immediately
end

connection_info = postgresql_connection_info.clone()
connection_info[:username] = 'ly'
connection_info[:password] = 'password'
conn = "postgres://#{connection_info[:username]}:#{connection_info[:password]}@#{connection_info[:host]}/ly"

# XXX: use whitelist
postgresql_database "plv8" do
  connection postgresql_connection_info
  database_name 'ly'
  sql "create extension plv8"
  action :nothing
  subscribes :query, resources(:postgresql_database_user => 'ly'), :immediately
end

# XXX: when used with vagrant, use /vagrant_git as source
git "/opt/ly/api.ly" do
  repository "git://github.com/g0v/api.ly.git"
  reference "master"
  action :sync
end

# XXX: use nobody user instead
execute "install api.ly" do
  cwd "/opt/ly/api.ly"
  action :nothing
  subscribes :run, resources(:git => "/opt/ly/api.ly"), :immediately
  command "npm link twlyparser pgrest && npm i && npm run prepublish && bower install --allow-root jquery"
  notifies :run, "execute[boot api.ly]", :immediately
  notifies :restart, "service[lyapi]"
end

execute "boot api.ly" do
  cwd "/opt/ly/api.ly"
  action :nothing
  user "nobody"
  command "lsc app.ls --db #{conn} --boot"
end

# XXX: ensure londiste is not enabled yet
bash 'init db' do
  code <<-EOH
    curl https://dl.dropboxusercontent.com/u/30657009/ly/api.ly.bz2 | bzcat | psql #{conn}
  EOH
  action :nothing
  subscribes :run, resources(:postgresql_database_user => 'ly')
end

runit_service "lyapi" do
  default_logger true
  action [:enable, :start]
  subscribes :restart, "execute[install api.ly]"
end

template "/etc/nginx/sites-available/lyapi" do
  source "site-lyapi.erb"
  owner "root"
  group "root"
  variables {}
  mode 00755
end
nginx_site "lyapi"

cron "populate-calendar" do
  minute "30"
  mailto "clkao@clkao.org"
  action :create
  user "nobody"
  command "cd /opt/ly/api.ly && lsc populate-calendar --db #{conn}"
end

# pgqd

package "skytools3"
package "skytools3-ticker"
package "postgresql-9.2-pgq3"

directory "/var/log/postgresql" do
  owner "postgres"
  group "postgres"
end

template "/opt/ly/londiste.ini" do
  source "londiste.erb"
  owner "root"
  group "root"
  variables {}
  mode 00644
end

template "/opt/ly/pgq.ini" do
  source "pgq.erb"
  owner "root"
  group "root"
  variables {}
  mode 00644
end

execute "init londiste" do
  command "londiste3 /opt/ly/londiste.ini create-root apily 'dbname=ly'"
  user "postgres"
end

execute "init pgq" do
  command "londiste3 /opt/ly/londiste.ini add-table calendar sittings"
  user "postgres"
end

runit_service "pgqd" do
  default_logger true
  action [:enable, :start]
end


# lisproxy
# XXX: use carton

package "cpanminus"

execute "install plack" do
  command "cpanm Plack::App::Proxy"
end

runit_service "lisproxy" do
  default_logger true
  action [:enable, :start]
end

if node['twitter']
  template "/opt/ly/api.ly/twitter.json" do
    source "twitter.conf.erb"
    owner "root"
    group "root"
    variables {}
    mode 00644
  end

  # calendar-twitter
  # also tell the admin to apply a role with [:twitter] when bootstrap is ready
  # and pgq is flushed automatically somehow
  runit_service "sitting-twitter" do
    default_logger true
    action [:enable, :stop]
    subscribes :restart, "execute[install api.ly]"
  end
end

runit_service "calendar-sitting" do
  default_logger true
  action [:enable, :start]
  subscribes :restart, "execute[install api.ly]"
end

# autorun debates generation
# TODO: clarify TTS auto parsing?

git "/opt/plv8x" do
  repository "git://github.com/clkao/plv8x.git"
  reference "master"
  action :sync
end

execute "install plv8x" do
  cwd "/opt/ly/plv8x"
  action :nothing
  subscribes :run, resources(:git => "/opt/ly/twlyparser"), :immediately
  command "npm i && npm link"
end

cron "gen-debates" do
  minute "0"
  hour "6"
  weekday "1"
  command "env PLV8XDB=ly /opt/ly/api.ly/scripts/gen-debates.ls | curl -i -H \"Content-Type: application/json\" -X POST -d @- http://127.0.0.1:3000/collections/debates"
end
