#!/bin/bash
#
# Puppet master installation steps based on history

# Create SWAP file
dd if=/dev/zero of=/swap bs=1M count=1024
mkswap /swap
swapon /swap

# Install Packages
rpm -ivh http://yum.puppetlabs.com/puppetlabs-release-el-6.noarch.rpm
yum -y install puppet-server httpd httpd-devel mod_ssl ruby-devel rubygems gcc-c++ curl-devel zlib-devel make automake openssl-devel puppet-dashboard mysql-server

# Run puppet in the foreground to create SSL certificates
puppet master --verbose --no-daemonize

# Install librarian
gem install librarian-puppet
touch /etc/puppet/Modulefile

# Initialize skeleton Puppetfile - Dont need to do as you're creating the Puppetfile in the next step
librarian-puppet init

# Configure librarian
cat >/etc/puppet/Puppetfile <<EOF
#!/usr/bin/env ruby
#^syntax detection

forge "http://forge.puppetlabs.com"

# use dependencies defined in Modulefile
modulefile

mod 'puppetlabs/stdlib'
mod 'puppetlabs/concat'
mod 'puppetlabs/firewall'
mod 'puppetlabs/ntp'
mod 'puppetlabs/haproxy'
mod 'puppetlabs/nginx'
mod 'puppetlabs/git'
mod 'example42/logrotate'
mod 'dwerder/graphite'
mod 'pdxcat/collectd'

#mod 'ntp',
#  :git => 'git://github.com/puppetlabs/puppetlabs-ntp.git'

# mod 'apt',
#   :git => 'https://github.com/puppetlabs/puppetlabs-apt.git',
#   :ref => 'feature/master/dans_refactor'
EOF

# Install above listed modules
librarian-puppet install --verbose

# Run puppetmaster as a passenger module
gem install rack passenger
passenger-install-apache2-module

# Configure puppetmaster
cat >/etc/httpd/conf.f/puppetmaster.conf <<EOF
LoadModule passenger_module /usr/lib/ruby/gems/1.8/gems/passenger-4.0.44/buildout/apache2/mod_passenger.so
<IfModule mod_passenger.c>
  PassengerRoot /usr/lib/ruby/gems/1.8/gems/passenger-4.0.44
  PassengerDefaultRuby /usr/bin/ruby
</IfModule>

PassengerHighPerformance On
PassengerMaxPoolSize 2
PassengerMaxRequests 1000
PassengerPoolIdleTime 600

Listen 8140

<VirtualHost *:8140>
    SSLEngine On

    SSLProtocol             All -SSLv2
    SSLCipherSuite          HIGH:!ADH:RC4+RSA:-MEDIUM:-LOW:-EXP
    SSLCertificateFile      /var/lib/puppet/ssl/certs/puppet.pem
    SSLCertificateKeyFile   /var/lib/puppet/ssl/private_keys/puppet.pem
    SSLCertificateChainFile /var/lib/puppet/ssl/ca/ca_crt.pem
    SSLCACertificateFile    /var/lib/puppet/ssl/ca/ca_crt.pem
    SSLCARevocationFile     /var/lib/puppet/ssl/ca/ca_crl.pem
    SSLVerifyClient         optional
    SSLVerifyDepth          1
    SSLOptions              +StdEnvVars +ExportCertData

    RequestHeader set X-SSL-Subject %{SSL_CLIENT_S_DN}e
    RequestHeader set X-Client-DN %{SSL_CLIENT_S_DN}e
    RequestHeader set X-Client-Verify %{SSL_CLIENT_VERIFY}e

    DocumentRoot /usr/share/puppet/rack/puppetmasterd/public/
    <Directory /usr/share/puppet/rack/puppetmasterd/>
        Options None
        AllowOverride None
        Order Allow,Deny
        Allow from All
    </Directory>
</VirtualHost>
EOF

# Create puppetmaster directories
mkdir -p /usr/share/puppet/rack/puppetmasterd
mkdir /usr/share/puppet/rack/puppetmasterd/public /usr/share/puppet/rack/puppetmasterd/tmp
cp /usr/share/puppet/ext/rack/config.ru /usr/share/puppet/rack/puppetmasterd/
chown puppet /usr/share/puppet/rack/puppetmasterd/config.ru

# Restart apache
apachectl configtest
service httpd restart

# Puppet modules syntax highlighting
mkdir -p ~/.vim/syntax
cd ~/.vim/syntax/
curl -sO http://downloads.puppetlabs.com/puppet/puppet.vim

# Create an alias in .bashrc
cat >>~/.bashrc <<EOF
alias vi="vim"
EOF

# Create MySQL database and user account for the dashboard

CREATE DATABASE dashboard CHARACTER SET utf8;
CREATE USER 'dashboard'@'localhost' IDENTIFIED BY 'something';
GRANT ALL PRIVILEGES ON dashboard.* TO 'dashboard'@'localhost';

# Configured dashboard database settings

cat >/usr/share/puppet-dashboard/config/database.yml <<EOF
# config/database.yml
#
# IMPORTANT NOTE: Before starting Dashboard, you will need to ensure that the
# MySQL user and databases you've specified in this file exist, and that the
# user has all permissions on the relevant databases. This will have to be done
# with an external database administration tool. If using the command-line
# `mysql` client, the commands to do this will resemble the following:
#
# CREATE DATABASE dashboard_production CHARACTER SET utf8;
# CREATE USER 'dashboard'@'localhost' IDENTIFIED BY 'my_password';
# GRANT ALL PRIVILEGES ON dashboard_production.* TO 'dashboard'@'localhost';
#
#
production:
  database: dashboard_production
  username: dashboard
  password: something
  encoding: utf8
  adapter: mysql

development:
  database: dashboard_development
  username: dashboard
  password:
  encoding: utf8
  adapter: mysql

test:
  database: dashboard_test
  username: dashboard
  password:
  encoding: utf8
  adapter: mysql
EOF

# Create tables etc
cd /usr/share/puppet-dashboard/
rake RAILS_ENV=production db:migrate

# Setup dashboard through apache
cat >/etc/httpd/conf.d/dashboard.conf <<EOF
<IfModule mod_passenger.c>
  PassengerRoot /usr/lib/ruby/gems/1.8/gems/passenger-4.0.44
  PassengerDefaultRuby /usr/bin/ruby
</IfModule>

PassengerHighPerformance On
PassengerMaxPoolSize 2
PassengerMaxRequests 1000
PassengerPoolIdleTime 600
PassengerStatThrottleRate 120

<VirtualHost *:80>
    ServerName dashboard.domain.com
    DocumentRoot /usr/share/puppet-dashboard/public/
    <Directory /usr/share/puppet-dashboard/public/>
        Options None
        AllowOverride None
        Order Allow,Deny
        Allow from All
    </Directory>

    ErrorLog /var/log/httpd/dashboard.domain.com_error.log
    LogLevel warn
    CustomLog /var/log/httpd/dashboard.domain.com_access.log combined

    <Location /reports/upload>
       <Limit POST>
           Order allow,deny
           Allow from localhost
           Allow from 127.0.0.1
	       Allow from 1.1.1.1
           Satisfy any
       </Limit>
   </Location>

   <Location /nodes>
       <Limit GET>
           Order allow,deny
           Allow from localhost
           Allow from 127.0.0.1
	       Allow from 1.1.1.1
           Satisfy any
       </Limit>
   </Location>

   <Location "/">
       AuthType basic
       AuthName "Puppet Dashboard"
       Require valid-user
       AuthBasicProvider file
       AuthUserFile /etc/httpd/users
   </Location>

</VirtualHost>
EOF

# Create apache users
htpasswd -c /etc/httpd/users user1

# Create dashboard log file
touch /usr/share/puppet-dashboard/log/production.log
chmod 0666 /usr/share/puppet-dashboard/log/production.log

# Disable puppetmaster and dashboard services as they are now served through apache
chkconfig puppetmaster off
chkconfig puppetmaster off
chkconfig puppet-dashboard off

# Enable required services
chkconfig httpd on
chkconfig mysqld on
chkconfig puppet-dashboard-workers on

# Cleanup by removing compilers from system
yum remove gcc-c++ make automake

