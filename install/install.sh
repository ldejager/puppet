#!/bin/bash
#
# Puppet master installation steps based on history

# Create SWAP file
dd if=/dev/zero of=/swap bs=1M count=1024
mkswap /swap
swapon /swap

# Install Packages
rpm -ivh http://yum.puppetlabs.com/puppetlabs-release-el-6.noarch.rpm
yum -y install puppet-server httpd httpd-devel mod_ssl ruby-devel rubygems gcc-c++ curl-devel zlib-devel make automake openssl-devel

# Run puppet in the foreground to create SSL certificates
puppet master --verbose --no-daemonize

# Install librarian
gem install librarian-puppet
touch /etc/puppet/Modulefile
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




